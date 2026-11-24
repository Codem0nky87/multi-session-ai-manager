import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// The name and password one browsing session's proxy asks for.
///
/// The proxy listens on this device's loopback, where any app on the device can
/// connect. Without a password each of them could reach whatever the SSH host
/// can reach. The browser is given the pair when it is created; nothing else is.
struct HostBrowseProxyCredentials: Equatable, Sendable {
    let username: String
    let password: String

    static func random() -> HostBrowseProxyCredentials {
        func token() -> String {
            (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        }
        return HostBrowseProxyCredentials(username: token(), password: token())
    }
}

/// A destination the SSH host would not, or could not, open for the browser.
struct HostBrowseRefusal: Equatable, Sendable {
    /// `name:port`, as the browser asked for it.
    let destination: String
    let reason: String

    /// The host's own words out of what the SSH layer reports for a channel it
    /// could not open, for example
    /// `direct-tcpip wiki:80 failed: NIOSSHError.channelSetupRejected: Reason: 2 Name or service not known`.
    /// SSH gives a code and a description: 1 means the server does not permit
    /// the connection, 2 that it tried and failed, with the reason in words.
    static func reason(fromChannelFailure message: String) -> String {
        guard let marker = message.range(of: "Reason: ") else { return message }
        let rest = message[marker.upperBound...]
        let code = rest.prefix { $0.isNumber }
        let words = rest.dropFirst(code.count).trimmingCharacters(in: .whitespaces)
        if code == "1" {
            return "Its SSH server does not allow connections to that address."
        }
        return words.isEmpty ? message : words + "."
    }
}

protocol HostBrowseProxyListener: AnyObject, Sendable {
    var localPort: Int { get }
    func stop() async
    /// Whether a connection to the proxy is still taken. A listener can die
    /// underneath the app: iOS takes the sockets of an app it has suspended,
    /// and nothing says so.
    func accepts() async -> Bool
}

protocol HostBrowseProxyServing: Sendable {
    /// Starts a proxy on this device's loopback whose every connection is made
    /// by the SSH host, to the name the browser gives, looked up over there.
    func start(
        credentials: HostBrowseProxyCredentials,
        onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void
    ) async throws -> any HostBrowseProxyListener

    /// The same, and `onRequest` is told every destination ("name:port") the
    /// browser puts to the proxy, before the host is asked for it. A page that
    /// fails without that having happened was never the host's to open.
    func start(
        credentials: HostBrowseProxyCredentials,
        onRequest: @escaping @Sendable (String) -> Void,
        onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void
    ) async throws -> any HostBrowseProxyListener
}

extension HostBrowseProxyServing {
    func start(
        credentials: HostBrowseProxyCredentials,
        onRequest: @escaping @Sendable (String) -> Void,
        onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void
    ) async throws -> any HostBrowseProxyListener {
        try await start(credentials: credentials, onRefusal: onRefusal)
    }
}

/// The part of SOCKS5 (RFC 1928) and its password method (RFC 1929) a browser
/// uses, read from whatever bytes have arrived so far.
enum SOCKS5 {
    enum Parsed<Value: Equatable>: Equatable {
        /// Not all of it has arrived yet.
        case incomplete
        /// Not SOCKS5, or not something this proxy does.
        case invalid
        case value(Value, consumed: Int)
    }

    struct Login: Equatable {
        let username: String
        let password: String
    }

    struct Request: Equatable {
        /// 1 is CONNECT, the only command a browser sends.
        let command: UInt8
        /// A name exactly as the browser gave it, or an address in text form.
        let host: String
        let port: Int
    }

    static let noAuthentication: UInt8 = 0x00
    static let passwordAuthentication: UInt8 = 0x02

    enum Reply: UInt8 {
        case succeeded = 0
        case generalFailure = 1
        case hostUnreachable = 4
        case commandNotSupported = 7
        case addressTypeNotSupported = 8
    }

    /// The authentication methods the client offers.
    static func greeting(_ bytes: [UInt8]) -> Parsed<[UInt8]> {
        guard bytes.count >= 2 else { return .incomplete }
        guard bytes[0] == 5, bytes[1] > 0 else { return .invalid }
        let end = 2 + Int(bytes[1])
        guard bytes.count >= end else { return .incomplete }
        return .value(Array(bytes[2..<end]), consumed: end)
    }

    static func login(_ bytes: [UInt8]) -> Parsed<Login> {
        guard bytes.count >= 2 else { return .incomplete }
        guard bytes[0] == 1 else { return .invalid }
        let nameEnd = 2 + Int(bytes[1])
        guard bytes.count > nameEnd else { return .incomplete }
        let passwordEnd = nameEnd + 1 + Int(bytes[nameEnd])
        guard bytes.count >= passwordEnd else { return .incomplete }
        return .value(Login(username: String(decoding: bytes[2..<nameEnd], as: UTF8.self),
                            password: String(decoding: bytes[(nameEnd + 1)..<passwordEnd], as: UTF8.self)),
                      consumed: passwordEnd)
    }

    static func request(_ bytes: [UInt8]) -> Parsed<Request> {
        guard bytes.count >= 4 else { return .incomplete }
        guard bytes[0] == 5 else { return .invalid }
        let host: String
        var index = 4
        switch bytes[3] {
        case 1:
            guard bytes.count >= index + 4 else { return .incomplete }
            host = bytes[index..<(index + 4)].map(String.init).joined(separator: ".")
            index += 4
        case 3:
            guard bytes.count > index else { return .incomplete }
            let length = Int(bytes[index])
            guard length > 0 else { return .invalid }
            guard bytes.count >= index + 1 + length else { return .incomplete }
            host = String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self)
            index += 1 + length
        case 4:
            guard bytes.count >= index + 16 else { return .incomplete }
            host = stride(from: index, to: index + 16, by: 2)
                .map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
                .joined(separator: ":")
            index += 16
        default:
            return .invalid
        }
        guard bytes.count >= index + 2 else { return .incomplete }
        let port = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        return .value(Request(command: bytes[1], host: host, port: port), consumed: index + 2)
    }

    static func reply(_ reply: Reply) -> [UInt8] {
        // No bound address to report: the connection was made by the SSH host.
        [5, reply.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]
    }
}

/// A SOCKS5 proxy on this device's loopback. Each connection the browser makes
/// through it becomes one `direct-tcpip` channel on the host's SSH connection,
/// opened to the name the browser asked for. The device never looks the name
/// up; the SSH host does, so a name that exists only over there works.
final class NIOHostBrowseProxyServer: HostBrowseProxyServing, @unchecked Sendable {
    private let service: SSHService
    private let group: EventLoopGroup
    private let connectTimeout: TimeAmount

    /// - Parameter connectTimeout: how long the SSH host may take to open a
    ///   destination before the browser is told it failed.
    init(service: SSHService,
         group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
         connectTimeout: TimeAmount = .seconds(20)) {
        self.service = service
        self.group = group
        self.connectTimeout = connectTimeout
    }

    func start(
        credentials: HostBrowseProxyCredentials,
        onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void
    ) async throws -> any HostBrowseProxyListener {
        try await start(credentials: credentials, onRequest: { _ in }, onRefusal: onRefusal)
    }

    func start(
        credentials: HostBrowseProxyCredentials,
        onRequest: @escaping @Sendable (String) -> Void,
        onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void
    ) async throws -> any HostBrowseProxyListener {
        let connections = BrowseConnections()
        let service = self.service
        let connectTimeout = self.connectTimeout
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            // No half-closed connections: when the browser is done sending it is
            // done, and the SSH host's end must not be left open behind it.
            .childChannelInitializer { channel in
                connections.add(channel)
                return channel.pipeline.addHandler(SOCKSToSSHHandler(
                    channel: channel, service: service, credentials: credentials,
                    connectTimeout: connectTimeout, onRequest: onRequest, onRefusal: onRefusal))
            }
        // Loopback only, and a port of the system's choosing: nothing has to know
        // it but the browser this proxy is started for.
        let server = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = server.localAddress?.port else {
            try? await server.close()
            throw SSHTransportError.commandFailed("The browsing proxy did not get a local port.")
        }
        return Listener(localPort: port, server: server, connections: connections)
    }

    private final class Listener: HostBrowseProxyListener, @unchecked Sendable {
        let localPort: Int
        private let server: Channel
        private let connections: BrowseConnections
        private let stopped = NIOLockedValueBox(false)

        init(localPort: Int, server: Channel, connections: BrowseConnections) {
            self.localPort = localPort
            self.server = server
            self.connections = connections
        }

        func stop() async {
            let first = stopped.withLockedValue { stopped -> Bool in
                defer { stopped = true }
                return !stopped
            }
            guard first else { return }
            connections.closeAll()
            try? await server.close()
        }

        /// Found out the only way that cannot be wrong: by connecting, as the
        /// browser would. Nothing is said on the connection, so nothing is
        /// asked of the host.
        func accepts() async -> Bool {
            guard !stopped.withLockedValue({ $0 }), server.isActive else { return false }
            do {
                let probe = try await ClientBootstrap(group: server.eventLoop)
                    .connectTimeout(.seconds(2))
                    .connect(host: "127.0.0.1", port: localPort).get()
                try? await probe.close()
                return true
            } catch {
                return false
            }
        }

        /// A bound listener outlives whoever forgot it; see the same note on the
        /// port forwarding listener.
        deinit {
            guard !stopped.withLockedValue({ $0 }) else { return }
            connections.closeAll()
            server.close(promise: nil)
        }
    }
}

private final class BrowseConnections: @unchecked Sendable {
    private let channels = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])

    func add(_ channel: Channel) {
        let id = ObjectIdentifier(channel as AnyObject)
        channels.withLockedValue { $0[id] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            _ = self?.channels.withLockedValue { $0.removeValue(forKey: id) }
        }
    }

    func closeAll() {
        let open = channels.withLockedValue { value -> [Channel] in
            defer { value.removeAll() }
            return Array(value.values)
        }
        for channel in open { channel.close(promise: nil) }
    }
}

private final class WeakHandler: @unchecked Sendable {
    /// Read only on the handler's own event loop.
    weak var value: SOCKSToSSHHandler?
    init(_ value: SOCKSToSSHHandler) { self.value = value }
}

/// One browser connection: the SOCKS5 exchange, then bytes both ways.
private final class SOCKSToSSHHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum State {
        case greeting, login, request
        /// The SSH host has been asked for the destination.
        case opening(id: Int)
        case relaying
        case finished
    }

    private let channel: Channel
    private let service: SSHService
    private let credentials: HostBrowseProxyCredentials
    private let connectTimeout: TimeAmount
    private let onRequest: @Sendable (String) -> Void
    private let onRefusal: @Sendable (HostBrowseRefusal) -> Void
    private var state = State.greeting
    /// What has arrived and not been understood yet. A handshake is a few dozen
    /// bytes; anything much longer is not one.
    private var pending: [UInt8] = []
    private var sshChannel: (any DirectTCPIPChannel)?
    private var openings = 0
    /// The SSH layer said "closed" while the destination was still being opened.
    private var closedWhileOpening = false

    init(channel: Channel, service: SSHService, credentials: HostBrowseProxyCredentials,
         connectTimeout: TimeAmount, onRequest: @escaping @Sendable (String) -> Void,
         onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) {
        self.channel = channel
        self.service = service
        self.credentials = credentials
        self.connectTimeout = connectTimeout
        self.onRequest = onRequest
        self.onRefusal = onRefusal
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch state {
        case .relaying:
            sshChannel?.send(Data(buffer.readableBytesView))
        case .finished:
            break
        case .greeting, .login, .request, .opening:
            pending.append(contentsOf: buffer.readableBytesView)
            guard pending.count <= 1024 else { return finish(context) }
            advance(context)
        }
    }

    private func advance(_ context: ChannelHandlerContext) {
        while true {
            switch state {
            case .greeting:
                switch SOCKS5.greeting(pending) {
                case .incomplete: return
                case .invalid: return finish(context)
                case .value(let methods, let consumed):
                    pending.removeFirst(consumed)
                    // Only a client that will prove who it is: see the credentials.
                    guard methods.contains(SOCKS5.passwordAuthentication) else {
                        return finish(context, sending: [5, 0xff])
                    }
                    write(context, [5, SOCKS5.passwordAuthentication])
                    state = .login
                }
            case .login:
                switch SOCKS5.login(pending) {
                case .incomplete: return
                case .invalid: return finish(context)
                case .value(let login, let consumed):
                    pending.removeFirst(consumed)
                    guard login.username == credentials.username, login.password == credentials.password else {
                        return finish(context, sending: [1, 1])
                    }
                    write(context, [1, 0])
                    state = .request
                }
            case .request:
                switch SOCKS5.request(pending) {
                case .incomplete: return
                case .invalid: return finish(context, sending: SOCKS5.reply(.addressTypeNotSupported))
                case .value(let request, let consumed):
                    pending.removeFirst(consumed)
                    guard request.command == 1 else {
                        return finish(context, sending: SOCKS5.reply(.commandNotSupported))
                    }
                    open(request, context)
                    return
                }
            case .opening, .relaying, .finished:
                return
            }
        }
    }

    private func open(_ request: SOCKS5.Request, _ context: ChannelHandlerContext) {
        openings += 1
        let id = openings
        state = .opening(id: id)
        let channel = self.channel
        let service = self.service
        // The web view asks for the host's own loopback by a stand-in address,
        // because it keeps `localhost` to itself. The host is asked for
        // `localhost`, and that is the name everything else hears.
        let host = request.host == HostBrowserAddress.hostItself ? "localhost" : request.host
        let destination = "\(host):\(request.port)"
        onRequest(destination)

        // A destination that never answers must not leave the browser waiting
        // for ever: the SSH host is given this long.
        let seconds = max(connectTimeout.nanoseconds / 1_000_000_000, 1)
        context.eventLoop.scheduleTask(in: connectTimeout) { [weak self] in
            self?.failed(id, destination, "No answer within \(seconds) seconds.")
        }
        // Reached from closures that run elsewhere and later; none of them may
        // keep this handler alive once its connection is gone.
        let handler = WeakHandler(self)
        Task {
            do {
                // The name goes to the SSH host exactly as the browser gave it.
                let opened = try await service.openDirectTCPIP(
                    targetHost: host,
                    targetPort: request.port,
                    onOutput: { data in
                        channel.eventLoop.execute {
                            guard channel.isActive else { return }
                            var buffer = channel.allocator.buffer(capacity: data.count)
                            buffer.writeBytes(data)
                            channel.writeAndFlush(buffer, promise: nil)
                        }
                    },
                    onClose: { channel.eventLoop.execute { handler.value?.hostClosed() } }
                )
                channel.eventLoop.execute {
                    guard let self = handler.value, channel.isActive,
                          case .opening(let current) = self.state, current == id else {
                        // The browser gave up, or the wait ran out, while the host was opening it.
                        opened.close()
                        return
                    }
                    guard !self.closedWhileOpening else {
                        opened.close()
                        return self.failed(id, destination, "The connection was closed at once.")
                    }
                    self.sshChannel = opened
                    self.state = .relaying
                    var reply = channel.allocator.buffer(capacity: 10)
                    reply.writeBytes(SOCKS5.reply(.succeeded))
                    channel.writeAndFlush(reply, promise: nil)
                    // Whatever the browser sent ahead of the answer goes first.
                    if !self.pending.isEmpty {
                        opened.send(Data(self.pending))
                        self.pending.removeAll()
                    }
                }
            } catch {
                let reason = Self.reason(for: error)
                channel.eventLoop.execute { handler.value?.failed(id, destination, reason) }
            }
        }
    }

    /// The host's end of the connection is gone.
    ///
    /// For a destination the host refuses, the SSH layer says this a moment
    /// BEFORE it reports the refusal. Hanging up on the browser then would lose
    /// the reason, and a proxy that hangs up mid-handshake leaves the browser
    /// waiting instead of failing. So while the destination is still being
    /// opened this is only noted, and the refusal that follows does the telling.
    private func hostClosed() {
        switch state {
        case .opening:
            closedWhileOpening = true
        case .relaying:
            state = .finished
            channel.close(promise: nil)
        case .greeting, .login, .request, .finished:
            break
        }
    }

    /// Tells the browser and the app that the host did not open `destination`.
    private func failed(_ id: Int, _ destination: String, _ reason: String) {
        guard case .opening(let current) = state, current == id else { return }
        state = .finished
        onRefusal(HostBrowseRefusal(destination: destination, reason: reason))
        guard channel.isActive else { return }
        var reply = channel.allocator.buffer(capacity: 10)
        reply.writeBytes(SOCKS5.reply(.hostUnreachable))
        channel.writeAndFlush(reply).whenComplete { [channel] _ in channel.close(promise: nil) }
    }

    private static func reason(for error: Error) -> String {
        switch error as? SSHTransportError {
        case .notConnected: "The SSH connection to the host is not established."
        case .commandFailed(let message): HostBrowseRefusal.reason(fromChannelFailure: message)
        case .hostKeyRejected, nil: String(describing: error)
        }
    }

    private func write(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    private func finish(_ context: ChannelHandlerContext, sending bytes: [UInt8] = []) {
        state = .finished
        guard !bytes.isEmpty else { return context.close(promise: nil) }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(buffer)).whenComplete { [channel] _ in channel.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state = .finished
        sshChannel?.close()
        sshChannel = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
