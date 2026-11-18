import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// OpenSSH commands executed on the already-connected first SSH host.
///
/// Every value derived from a tunnel definition or runtime credential is
/// single-quoted for the remote shell. Password mode creates a mode-700 temporary
/// askpass helper on the first host and removes it on exit and listener shutdown.
///
/// The helper is an `ssh -f` on the first host: it goes into the background there
/// and lives until it is told to exit. When the app is closed, updated or loses
/// its connection without stopping the forward, nobody tells it, and it stays
/// behind holding its port. So every start first removes the helpers left behind
/// for the same forward, and the helper's port is one of the first host's own
/// choosing rather than the port the forward has on this device.
struct SessionWebTunnelRemoteForwardCommands: Equatable {
    static let readyMarker = "__AI_MANAGER_SSH_FORWARD_READY__"
    static let controlPathPrefix = "/tmp/ai-manager-web-tunnel-"

    let start: String
    let stop: String
    let cancel: String
    /// The command lines of the helpers `start` removes before it starts its
    /// own, as extended regular expressions.
    let leftBehindPatterns: [String]

    /// Which forward a helper serves, as it appears in its control path.
    static func tag(for tunnelID: UUID) -> String {
        String(tunnelID.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// A control socket for one start of one forward. Short on purpose: ssh adds
    /// 17 characters of its own while it creates the socket, and a socket path
    /// may be only 103 characters long on macOS.
    static func controlPath(for tunnelID: UUID) -> String {
        let start = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(controlPathPrefix)\(tag(for: tunnelID))-\(start).sock"
    }

    /// Whether ssh's complaint is about the port the helper was to listen on.
    static func portWasTaken(_ output: String) -> Bool {
        output.contains("Address already in use") || output.contains("cannot listen to port")
    }

    init(
        tunnelID: UUID,
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
            // The leg from this host to the hop idles as well. Keep-alives stop a
            // firewall between them from dropping it, and end the process when
            // the hop is truly gone instead of leaving a forward that goes nowhere.
            "-o \(Self.quote("ServerAliveInterval=30"))",
            "-o \(Self.quote("ServerAliveCountMax=3"))",
        ]
        if hasPassword {
            options.append("-o \(Self.quote("NumberOfPasswordPrompts=1"))")
            // Password mode must not let the first host's agent or on-disk keys
            // burn the hop's MaxAuthTries before the password is offered: ssh
            // would then die with "Too many authentication failures" even
            // though the entered password is correct.
            options.append("-o \(Self.quote("PreferredAuthentications=password,keyboard-interactive"))")
            options.append("-o \(Self.quote("PubkeyAuthentication=no"))")
            options.append("-o \(Self.quote("GSSAPIAuthentication=no"))")
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
        // Askpass env vars prefix the ssh simple command (inside the brace
        // group built later): zsh rejects VAR=value prefixes before `{ ... }`,
        // which silently killed password hops whenever the first host's login
        // shell was zsh (macOS default).
        let askpassEnv = hasPassword
            ? "DISPLAY=\(Self.quote("ai-manager:0")) SSH_ASKPASS=\(Self.quote(askpassPath)) SSH_ASKPASS_REQUIRE=\(Self.quote("force")) "
            : ""
        let sshStart = "\(askpassEnv)ssh \(options.joined(separator: " ")) 2>&1"

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

        // The ssh step must never fail the whole command: its merged output is
        // the only diagnostic the user can act on ("permission denied",
        // "connection timed out"), and a non-zero exit would make the transport
        // throw away everything ssh said. Emit the ready marker only on success
        // and report the exit status otherwise, always returning 0.
        let sshLaunch =
            "{ \(sshStart); rc=$?; if [ $rc -eq 0 ]; then "
            + "printf '%s' \(Self.quote(Self.readyMarker)); "
            + "else printf 'ssh exited with status %s' $rc; fi; }"
        if let hopPassword, hasPassword {
            let helper = """
            #!/bin/sh
            printf '%s\\n' \(Self.quote(hopPassword))
            """
            launch += [
                "printf '%s' \(Self.quote(helper)) > \(Self.quote(askpassPath))",
                "chmod 700 \(Self.quote(askpassPath))",
                sshLaunch
            ]
        } else {
            launch.append(sshLaunch)
        }

        // Helpers left behind, matched by their command line: the options every
        // helper is started with, in the order they are given above, so that
        // nothing else a user runs can look like one. A pattern cannot match the
        // shell that carries it in its own command line either (pkill would
        // kill that shell with the helpers): where a helper has a socket name,
        // the pattern has the expression for one.
        let leftBehind = [
            // Of this forward, from any earlier start of it.
            "-M -S \(Self.controlPathPrefix)\(Self.tag(for: tunnelID))-[0-9a-f]+[.]sock -f -N ",
            // Of this forward as builds before this one started it: a control
            // path that names no forward, so the forward is told by where it goes.
            "-M -S \(Self.controlPathPrefix)[0-9A-F-]{36}[.]sock -f -N -p [0-9]+ -L 127[.]0[.]0[.]1:[0-9]+:"
                + "\(Self.literal(targetHost)):\(targetPort) \(Self.literal(destination))$",
        ]
        leftBehindPatterns = leftBehind
        let sweep = leftBehind
            .map { "pkill -u \"$(id -u)\" -f -- \(Self.quote($0)) >/dev/null 2>&1" }
            .joined(separator: "; ")

        start = "\(setup); \(sweep); \(launch.joined(separator: " && "))"
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

    /// `value` as an extended regular expression that matches only itself.
    private static func literal(_ value: String) -> String {
        value.map { character -> String in
            if character.isLetter || character.isNumber || "-_:@/, ".contains(character) { return String(character) }
            // A bracket makes anything literal except these two.
            return character == "^" || character == "\\" ? "\\\(character)" : "[\(character)]"
        }.joined()
    }
}

/// Loopback-only TCP listener. Each accepted WebKit socket is paired with one
/// `direct-tcpip` child channel on the already-connected `SSHService`.
final class NIOSessionWebTunnelServer: SessionWebTunnelServing, @unchecked Sendable {
    private let service: SSHService
    private let group: EventLoopGroup
    private let remoteForwardControlPath: @Sendable (UUID) -> String
    private let remoteForwardPort: @Sendable () -> Int

    /// How often a hop helper is started again on another port when the one it
    /// was given turns out to be taken on the first host.
    static let remoteForwardPortAttempts = 3

    /// - Parameters:
    ///   - remoteForwardControlPath: the control socket for one start of the forward with this id.
    ///   - remoteForwardPort: a port for the hop helper on the first host's loopback.
    ///     Below every system's range for outgoing connections and above the
    ///     ports services usually claim, so one picked at random is almost always free.
    init(
        service: SSHService,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        remoteForwardControlPath: @escaping @Sendable (UUID) -> String = {
            SessionWebTunnelRemoteForwardCommands.controlPath(for: $0)
        },
        remoteForwardPort: @escaping @Sendable () -> Int = { Int.random(in: 20_000...32_000) }
    ) {
        self.service = service
        self.group = group
        self.remoteForwardControlPath = remoteForwardControlPath
        self.remoteForwardPort = remoteForwardPort
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
            var started: (commands: SessionWebTunnelRemoteForwardCommands, port: Int)?
            for attempt in 1...Self.remoteForwardPortAttempts {
                // A port of the first host's own. The forward's port on this
                // device says nothing about what is free over there: the same
                // number may belong to a service of that host, or to a helper
                // that an earlier run of the app left behind.
                let port = remoteForwardPort()
                let commands = SessionWebTunnelRemoteForwardCommands(
                    tunnelID: tunnel.id,
                    hop: hop,
                    targetHost: tunnel.targetHost,
                    targetPort: tunnel.targetPort,
                    remoteForwardPort: port,
                    controlPath: remoteForwardControlPath(tunnel.id),
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
                        // A concurrent reconnect (metrics bar, sheet re-entry) can
                        // briefly drop the client; settle and retry once before
                        // declaring the connection dead.
                        let output: String
                        do {
                            output = try await service.runCommand(commands.start)
                        } catch SSHTransportError.notConnected {
                            try await Task.sleep(nanoseconds: 1_500_000_000)
                            try Task.checkCancellation()
                            output = try await service.runCommand(commands.start)
                        }
                        try Task.checkCancellation()
                        return output
                    } onCancel: {
                        cancellationCleanup.schedule()
                    }
                    if output.contains(SessionWebTunnelRemoteForwardCommands.readyMarker) {
                        started = (commands, port)
                        break
                    }
                    if SessionWebTunnelRemoteForwardCommands.portWasTaken(output),
                       attempt < Self.remoteForwardPortAttempts {
                        // Something on the first host has that port. Clear away
                        // what this attempt wrote there and take another.
                        _ = try? await service.runCommand(commands.stop)
                        continue
                    }
                    let detail = Self.diagnosticSuffix(
                        output,
                        hopPassword: hopPassword
                    )
                    // The ssh output IS the diagnosis when we have it; the
                    // generic guidance only fills in when nothing came back.
                    let advice = detail.isEmpty
                        ? Self.authenticationGuidance(hopPassword: hopPassword)
                        : detail
                    throw SessionWebTunnelError.couldNotStart(
                        "Could not start SSH hop \(hop.username)@\(hop.host):\(hop.port)."
                        + advice
                    )
                } catch {
                    if error is CancellationError {
                        await cancellationCleanup.run()
                        throw error
                    }
                    await failureCleanup.run()
                    // A nil client means the host connection itself is gone —
                    // blaming the hop password there only misleads the user.
                    if error as? SSHTransportError == .notConnected {
                        throw SessionWebTunnelError.couldNotStart(
                            "The SSH connection to the first host is not established. "
                            + "Reconnect the host and start the tunnel again."
                        )
                    }
                    // The inner error already carries ssh's own diagnosis (or the
                    // right guidance); re-wrapping it here only buries the real
                    // complaint under a password accusation.
                    if let tunnelError = error as? SessionWebTunnelError {
                        throw tunnelError
                    }
                    // The command did not run: ssh on the first host said
                    // nothing, about the hop or anything else. Pointing at the
                    // hop's key or password sends the reader after the wrong thing.
                    if case .commandFailed(let detail)? = error as? SSHTransportError {
                        throw SessionWebTunnelError.couldNotStart(
                            "The SSH connection to the first host failed while the forward was starting. "
                            + "Start it again."
                            + Self.diagnosticSuffix("(\(detail))", hopPassword: hopPassword)
                        )
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
            }
            // The loop leaves only with a started helper or by throwing.
            guard let started else {
                throw SessionWebTunnelError.couldNotStart(
                    "Could not start SSH hop \(hop.username)@\(hop.host):\(hop.port)."
                )
            }
            destination.set(host: "127.0.0.1", port: started.port)
            remoteForwardCommands = started.commands
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

    /// Surfaces the remote ssh diagnostic so "verify the password" is evidence
    /// rather than a guess: the password itself is redacted from the detail,
    /// but everything else (permission denied, no matching key exchange,
    /// refused connection, MFA prompts) must reach the user.
    private static func diagnosticSuffix(
        _ detail: String,
        hopPassword: String?
    ) -> String {
        var trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hopPassword, !hopPassword.isEmpty {
            trimmed = trimmed.replacingOccurrences(of: hopPassword, with: "[redacted]")
        }
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

    /// The event loop keeps a bound server channel alive on its own, so a listener
    /// that is dropped without `stop()` would hold its port until the app quits and
    /// every later start on that port would fail with "already in use". Whoever
    /// loses track of a listener therefore still gets the port back.
    deinit {
        guard !stopped.withLockedValue({ $0 }) else { return }
        tracker.closeAll()
        serverChannel.close(promise: nil)
        if let remoteForwardStopCommand {
            let service = self.service
            Task { _ = try? await service.runCommand(remoteForwardStopCommand) }
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
