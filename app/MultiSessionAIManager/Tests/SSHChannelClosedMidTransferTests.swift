import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import MultiSessionAIManager

/// A connection the app forwards through a host can be closed while the host is
/// still sending on it: a page left half loaded, a download given up on, a
/// forward whose local side went away. The SSH library the app was built with
/// until 2026-11-19 trapped at that moment, in
/// `ChildChannelStateMachine.sendChannelWindowAdjust`, and took the whole app
/// down (two TestFlight crash reports that day). It answered data that arrived
/// after its own "close" with more room to send, which its own rules forbid.
///
/// The test holds the app's real transport against an SSH server that keeps
/// sending. With the faulty library the test run itself dies.
@Suite(.serialized) struct SSHChannelClosedMidTransferTests {
    /// What the server does with a forwarded connection, chosen by the port asked for.
    private enum Served {
        /// Answers the first bytes with far more than the app has made room for.
        static let downloadPort = 80
        /// Sends back what it is sent.
        static let echoPort = 7
    }

    private final class Connection: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData

        private let floods: Bool
        private var flooding = false

        init(floods: Bool) {
            self.floods = floods
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .byteBuffer(let bytes) = unwrapInboundIn(data).data else { return }
            guard floods else {
                context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: nil)
                return
            }
            guard !flooding else { return }
            flooding = true
            // One megabyte handed over at once. The app makes room for 128 KiB at a
            // time, so that much is on its way before the app can say anything.
            for _ in 0..<64 {
                var chunk = context.channel.allocator.buffer(capacity: 16 * 1024)
                chunk.writeRepeatingByte(0x2e, count: 16 * 1024)
                context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(chunk))), promise: nil)
            }
            context.flush()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }
    }

    private final class AnyoneMayEnter: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    /// An SSH server on this device, for forwarded connections only.
    private final class Server: @unchecked Sendable {
        let port: Int
        private let listener: Channel
        private let group: MultiThreadedEventLoopGroup

        private init(port: Int, listener: Channel, group: MultiThreadedEventLoopGroup) {
            self.port = port
            self.listener = listener
            self.group = group
        }

        static func start() async throws -> Server {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture(withResultOf: {
                        let role = SSHConnectionRole.server(SSHServerConfiguration(
                            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: AnyoneMayEnter()))
                        try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                            role: role, allocator: channel.allocator,
                            inboundChildChannelInitializer: { child, type in
                                guard case .directTCPIP(let target) = type else {
                                    return child.eventLoop.makeFailedFuture(
                                        SSHTransportError.commandFailed("This server only forwards connections."))
                                }
                                return child.pipeline.addHandler(Connection(floods: target.targetPort == Served.downloadPort))
                            }))
                    })
                }
            let listener = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            guard let port = listener.localAddress?.port else {
                try? await listener.close()
                throw SSHTransportError.commandFailed("The test's SSH server did not get a port.")
            }
            return Server(port: port, listener: listener, group: group)
        }

        func stop() async {
            try? await listener.close()
            try? await group.shutdownGracefully()
        }
    }

    /// Fails rather than hangs when the transport never answers.
    private func within<T: Sendable>(_ limit: Duration, _ what: String,
                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SSHTransportError.commandFailed("timed out waiting for: \(what)")
            }
            defer { group.cancelAll() }
            return try #require(try await group.next())
        }
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func closingAForwardedConnectionWhileTheHostIsStillSendingLeavesTheAppRunning() async throws {
        let server = try await Server.start()
        let transport = NIOSSHTransport()
        let host = Host(name: "flood", address: "127.0.0.1", port: server.port, username: "operator",
                        keyID: "test-key", defaultWorkdir: "/")
        try await within(.seconds(10), "the SSH connection") {
            try await transport.connect(host: host, key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _ in true }
        }

        for round in 1...5 {
            let received = NIOLockedValueBox(0)
            let download = NIOLockedValueBox<(any DirectTCPIPChannel)?>(nil)
            let opened = try await within(.seconds(5), "the download's connection") {
                try await transport.openDirectTCPIP(
                    targetHost: "files.internal.example", targetPort: Served.downloadPort,
                    onOutput: { data in
                        let isFirst = received.withLockedValue { total -> Bool in
                            defer { total += data.count }
                            return total == 0
                        }
                        // The moment the app gives the download up: the rest of what
                        // it made room for is already on its way.
                        if isFirst { download.withLockedValue { $0 }?.close() }
                    },
                    onClose: {})
            }
            download.withLockedValue { $0 = opened }
            opened.send(Data("GET /big HTTP/1.1\r\n\r\n".utf8))
            await eventually("the first of the download, round \(round)") { received.withLockedValue { $0 } > 0 }

            // Whatever the server sent on that connection reaches the app before
            // the answer on this one does, so once the echo is back the app has
            // been through all of it.
            let echoed = NIOLockedValueBox(Data())
            let echo = try await within(.seconds(5), "a second connection") {
                try await transport.openDirectTCPIP(
                    targetHost: "files.internal.example", targetPort: Served.echoPort,
                    onOutput: { data in echoed.withLockedValue { $0.append(data) } },
                    onClose: {})
            }
            echo.send(Data("still here \(round)".utf8))
            await eventually("the SSH connection to carry data after round \(round)") {
                echoed.withLockedValue { $0 } == Data("still here \(round)".utf8)
            }
            echo.close()
        }

        await transport.disconnect()
        await server.stop()
    }
}
