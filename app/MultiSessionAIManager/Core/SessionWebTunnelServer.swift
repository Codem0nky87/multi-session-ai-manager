import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// OpenSSH commands executed on the already-connected first SSH host.
///
/// Every value derived from a tunnel definition or runtime credential is
/// single-quoted for the remote shell. Password mode creates a mode-700 temporary
/// askpass helper on the first host and removes it on exit and listener shutdown.
struct SessionWebTunnelRemoteForwardCommands: Equatable {
    static let readyMarker = "__AI_MANAGER_SSH_FORWARD_READY__"

    let start: String
    let stop: String
    let cancel: String

    init(
        hop: SessionWebTunnelHop,
        targetHost: String,
        targetPort: Int,
        remoteForwardPort: Int,
        controlPath: String,
        hopPassword: String? = nil
    ) {
        let destination = "\(hop.username)@\(hop.host)"
        let forwarding = "127.0.0.1:\(remoteForwardPort):\(targetHost):\(targetPort)"
        let hasPassword = !(hopPassword?.isEmpty ?? true)
        let askpassPath = controlPath + ".askpass"
        let cancelPath = controlPath + ".cancel"
        var options = [
            "-o \(Self.quote(hasPassword ? "BatchMode=no" : "BatchMode=yes"))",
            "-o \(Self.quote("StrictHostKeyChecking=accept-new"))",
            "-o \(Self.quote("ExitOnForwardFailure=yes"))",
        ]
        if hasPassword {
            options.append("-o \(Self.quote("NumberOfPasswordPrompts=1"))")
        }
        options += [
            "-M",
            "-S \(Self.quote(controlPath))",
            "-f",
            "-N",
            "-p \(Self.quote(String(hop.port)))",
            "-L \(Self.quote(forwarding))",
            Self.quote(destination)
        ]
        let sshStart = "ssh \(options.joined(separator: " ")) 2>&1"

        let sshStop = [
            "ssh",
            "-S \(Self.quote(controlPath))",
            "-p \(Self.quote(String(hop.port)))",
            "-O \(Self.quote("exit"))",
            Self.quote(destination),
            ">/dev/null 2>&1"
        ].joined(separator: " ")

        let removeTransientFiles = [
            "rm -f --",
            Self.quote(askpassPath),
            Self.quote(cancelPath)
        ].joined(separator: " ")
        let removeCancelFile = "rm -f -- \(Self.quote(cancelPath))"
        let cancellationTrap = [
            "if [ -e \(Self.quote(cancelPath)) ]; then",
            sshStop + ";",
            removeCancelFile + ";",
            "fi"
        ].joined(separator: " ")
        let setup = [
            "umask 077",
            "forward_cleanup() { rm -f -- \(Self.quote(askpassPath)); "
                + cancellationTrap + "; }",
            "trap forward_cleanup EXIT HUP INT TERM"
        ].joined(separator: "; ")
        var launch = ["test ! -e \(Self.quote(cancelPath))"]

        if let hopPassword, hasPassword {
            let helper = """
            #!/bin/sh
            printf '%s\\n' \(Self.quote(hopPassword))
            """
            launch += [
                "printf '%s' \(Self.quote(helper)) > \(Self.quote(askpassPath))",
                "chmod 700 \(Self.quote(askpassPath))",
                [
                    "DISPLAY=\(Self.quote("ai-manager:0"))",
                    "SSH_ASKPASS=\(Self.quote(askpassPath))",
                    "SSH_ASKPASS_REQUIRE=\(Self.quote("force"))",
                    sshStart
                ].joined(separator: " ")
            ]
        } else {
            launch.append(sshStart)
        }
        launch.append("printf '%s' \(Self.quote(Self.readyMarker))")

        start = "\(setup); \(launch.joined(separator: " && "))"
        stop = "\(sshStop); \(removeTransientFiles)"
        cancel = [
            "umask 077",
            ": > \(Self.quote(cancelPath))",
            "if \(sshStop); then \(removeCancelFile); fi",
            "rm -f -- \(Self.quote(askpassPath))"
        ].joined(separator: "; ")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Loopback-only TCP listener. Each accepted WebKit socket is paired with one
/// `direct-tcpip` child channel on the already-connected `SSHService`.
final class NIOSessionWebTunnelServer: SessionWebTunnelServing, @unchecked Sendable {
    private let service: SSHService
    private let group: EventLoopGroup
    private let remoteForwardControlPath: @Sendable () -> String

    init(
        service: SSHService,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        remoteForwardControlPath: @escaping @Sendable () -> String = {
            "/tmp/ai-manager-web-tunnel-\(UUID().uuidString).sock"
        }
    ) {
        self.service = service
        self.group = group
        self.remoteForwardControlPath = remoteForwardControlPath
    }

    func start(
        tunnel: SessionWebTunnel,
        hopPassword: String?,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws -> any SessionWebTunnelListener {
        if let validationError = tunnel.validationError {
            throw SessionWebTunnelError.couldNotStart(validationError)
        }

        let tracker = TunnelChannelTracker()
        let destination = TunnelDestinationBox()
        let service = self.service
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { localChannel in
                tracker.add(localChannel)
                return localChannel.pipeline.addHandler(
                    LoopbackToSSHHandler(
                        localChannel: localChannel,
                        service: service,
                        destination: destination,
                        onConnectionError: onConnectionError
                    )
                )
            }

        let serverChannel: Channel
        do {
            serverChannel = try await bootstrap.bind(
                host: "127.0.0.1",
                port: tunnel.localPort ?? 0
            ).get()
        } catch {
            if let fixedPort = tunnel.localPort {
                throw SessionWebTunnelError.couldNotStart(
                    "Local port \(fixedPort) is already in use. "
                    + "Stop the other listener or choose Automatic."
                )
            }
            throw SessionWebTunnelError.couldNotStart(
                "Could not start the loopback tunnel: \(error.localizedDescription)"
            )
        }

        guard let localPort = serverChannel.localAddress?.port else {
            serverChannel.close(promise: nil)
            throw SessionWebTunnelError.couldNotStart(
                "The loopback tunnel did not receive a local port."
            )
        }
        if Task.isCancelled {
            tracker.closeAll()
            try? await serverChannel.close()
            throw CancellationError()
        }

        let remoteForwardCommands: SessionWebTunnelRemoteForwardCommands?
        if let hop = tunnel.hop {
            let commands = SessionWebTunnelRemoteForwardCommands(
                hop: hop,
                targetHost: tunnel.targetHost,
                targetPort: tunnel.targetPort,
                remoteForwardPort: localPort,
                controlPath: remoteForwardControlPath(),
                hopPassword: hopPassword
            )
            let cancellationCleanup = RemoteForwardStartupCleanup(
                serverChannel: serverChannel,
                tracker: tracker,
                service: service,
                cleanupCommand: commands.cancel
            )
            let failureCleanup = RemoteForwardStartupCleanup(
                serverChannel: serverChannel,
                tracker: tracker,
                service: service,
                cleanupCommand: commands.stop
            )
            do {
                let output = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let output = try await service.runCommand(commands.start)
                    try Task.checkCancellation()
                    return output
                } onCancel: {
                    cancellationCleanup.schedule()
                }
                guard output.contains(SessionWebTunnelRemoteForwardCommands.readyMarker) else {
                    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = Self.diagnosticSuffix(
                        detail,
                        hopPassword: hopPassword
                    )
                    throw SessionWebTunnelError.couldNotStart(
                        "Could not start SSH hop \(hop.username)@\(hop.host):\(hop.port). "
                        + Self.authenticationGuidance(hopPassword: hopPassword)
                        + suffix
                    )
                }
            } catch {
                if error is CancellationError {
                    await cancellationCleanup.run()
                    throw error
                }
                await failureCleanup.run()
                if let tunnelError = error as? SessionWebTunnelError,
                   hopPassword?.isEmpty ?? true {
                    throw tunnelError
                }
                throw SessionWebTunnelError.couldNotStart(
                    "Could not start SSH hop \(hop.username)@\(hop.host):\(hop.port). "
                    + Self.authenticationGuidance(hopPassword: hopPassword)
                    + Self.diagnosticSuffix(
                        error.localizedDescription,
                        hopPassword: hopPassword
                    )
                )
            }
            destination.set(host: "127.0.0.1", port: localPort)
            remoteForwardCommands = commands
        } else {
            destination.set(host: tunnel.targetHost, port: tunnel.targetPort)
            remoteForwardCommands = nil
        }

        return NIOSessionWebTunnelListener(
            localPort: localPort,
            serverChannel: serverChannel,
            tracker: tracker,
            service: service,
            remoteForwardStopCommand: remoteForwardCommands?.stop
        )
    }

    private static func authenticationGuidance(hopPassword: String?) -> String {
        if !(hopPassword?.isEmpty ?? true) {
            return "Verify the SSH password for that hop."
        }
        return "Verify that the first host has a usable key, SSH config, "
            + "or agent for that hop."
    }

    private static func diagnosticSuffix(
        _ detail: String,
        hopPassword: String?
    ) -> String {
        guard hopPassword?.isEmpty ?? true else { return "" }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " \(trimmed)"
    }
}

private final class RemoteForwardStartupCleanup: @unchecked Sendable {
    private let serverChannel: Channel
    private let tracker: TunnelChannelTracker
    private let service: SSHService
    private let cleanupCommand: String
    private let cleanupTask = NIOLockedValueBox<Task<Void, Never>?>(nil)

    init(
        serverChannel: Channel,
        tracker: TunnelChannelTracker,
        service: SSHService,
        cleanupCommand: String
    ) {
        self.serverChannel = serverChannel
        self.tracker = tracker
        self.service = service
        self.cleanupCommand = cleanupCommand
    }

    func schedule() {
        let serverChannel = serverChannel
        let tracker = tracker
        let service = service
        let cleanupCommand = cleanupCommand

        cleanupTask.withLockedValue { task in
            guard task == nil else { return }
            task = Task.detached {
                tracker.closeAll()
                try? await serverChannel.close()
                _ = try? await service.runCommand(cleanupCommand)
            }
        }
    }

    func run() async {
        schedule()
        let task = cleanupTask.withLockedValue { $0 }
        await task?.value
    }
}

private final class NIOSessionWebTunnelListener: SessionWebTunnelListener, @unchecked Sendable {
    let localPort: Int
    private let serverChannel: Channel
    private let tracker: TunnelChannelTracker
    private let service: SSHService
    private let remoteForwardStopCommand: String?
    private let stopped = NIOLockedValueBox(false)

    init(
        localPort: Int,
        serverChannel: Channel,
        tracker: TunnelChannelTracker,
        service: SSHService,
        remoteForwardStopCommand: String?
    ) {
        self.localPort = localPort
        self.serverChannel = serverChannel
        self.tracker = tracker
        self.service = service
        self.remoteForwardStopCommand = remoteForwardStopCommand
    }

    func stop() async {
        let shouldStop = stopped.withLockedValue { stopped in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }

        tracker.closeAll()
        try? await serverChannel.close()
        if let remoteForwardStopCommand {
            _ = try? await service.runCommand(remoteForwardStopCommand)
        }
    }
}

private struct TunnelDestination {
    let host: String
    let port: Int
}

private final class TunnelDestinationBox: @unchecked Sendable {
    private let destination = NIOLockedValueBox<TunnelDestination?>(nil)

    func set(host: String, port: Int) {
        destination.withLockedValue {
            $0 = TunnelDestination(host: host, port: port)
        }
    }

    func get() -> TunnelDestination? {
        destination.withLockedValue { $0 }
    }
}

private final class TunnelChannelTracker: @unchecked Sendable {
    private let channels = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])

    func add(_ channel: Channel) {
        let id = ObjectIdentifier(channel as AnyObject)
        channels.withLockedValue { $0[id] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            _ = self?.channels.withLockedValue { $0.removeValue(forKey: id) }
        }
    }

    func closeAll() {
        let active = channels.withLockedValue { value -> [Channel] in
            let snapshot = Array(value.values)
            value.removeAll()
            return snapshot
        }
        for channel in active {
            channel.close(promise: nil)
        }
    }
}

private final class LoopbackToSSHHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let localChannel: Channel
    private let service: SSHService
    private let destination: TunnelDestinationBox
    private let onConnectionError: @Sendable (String) -> Void
    private var sshChannel: (any DirectTCPIPChannel)?

    init(
        localChannel: Channel,
        service: SSHService,
        destination: TunnelDestinationBox,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) {
        self.localChannel = localChannel
        self.service = service
        self.destination = destination
        self.onConnectionError = onConnectionError
    }

    func channelActive(context: ChannelHandlerContext) {
        let localChannel = self.localChannel
        guard let destination = destination.get() else {
            onConnectionError("The SSH tunnel route is not ready.")
            context.close(promise: nil)
            context.fireChannelActive()
            return
        }
        let service = self.service
        let onConnectionError = self.onConnectionError

        Task { [weak self] in
            do {
                let sshChannel = try await service.openDirectTCPIP(
                    targetHost: destination.host,
                    targetPort: destination.port,
                    onOutput: { data in
                        localChannel.eventLoop.execute {
                            guard localChannel.isActive else { return }
                            var buffer = localChannel.allocator.buffer(capacity: data.count)
                            buffer.writeBytes(data)
                            localChannel.writeAndFlush(buffer, promise: nil)
                        }
                    },
                    onClose: {
                        localChannel.eventLoop.execute {
                            localChannel.close(promise: nil)
                        }
                    }
                )

                localChannel.eventLoop.execute { [weak self] in
                    guard let self, localChannel.isActive else {
                        sshChannel.close()
                        return
                    }
                    self.sshChannel = sshChannel
                    localChannel.setOption(ChannelOptions.autoRead, value: true).whenSuccess {
                        localChannel.read()
                    }
                }
            } catch {
                onConnectionError(
                    "SSH host could not reach \(destination.host):\(destination.port). "
                    + String(describing: error)
                )
                localChannel.eventLoop.execute {
                    localChannel.close(promise: nil)
                }
            }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        sshChannel?.send(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        sshChannel?.close()
        sshChannel = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sshChannel?.close()
        sshChannel = nil
        context.close(promise: nil)
    }
}
