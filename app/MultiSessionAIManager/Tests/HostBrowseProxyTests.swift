import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
@testable import MultiSessionAIManager

/// What a browser says to the proxy before any page travels, read from however
/// much of it has arrived.
@Suite struct SOCKS5ParsingTests {
    /// CONNECT to `name:port`, the way a browser asks when it has not looked the name up.
    private func connect(to name: String, port: Int) -> [UInt8] {
        [5, 1, 0, 3, UInt8(name.utf8.count)] + Array(name.utf8) + [UInt8(port >> 8), UInt8(port & 0xff)]
    }

    @Test func aGreetingListsTheWaysTheClientCanProveItself() {
        #expect(SOCKS5.greeting([5, 2, 0, 2]) == .value([0, 2], consumed: 4))
        #expect(SOCKS5.greeting([5, 2, 0]) == .incomplete)
        #expect(SOCKS5.greeting([5]) == .incomplete)
        #expect(SOCKS5.greeting([4, 1, 0]) == .invalid, "SOCKS4 is not spoken here")
        #expect(SOCKS5.greeting([5, 0]) == .invalid)
    }

    @Test func aLoginCarriesANameAndAPassword() {
        let login: [UInt8] = [1, 2] + Array("me".utf8) + [3] + Array("pw!".utf8)
        #expect(SOCKS5.login(login) == .value(.init(username: "me", password: "pw!"), consumed: login.count))
        for cut in 0..<login.count {
            #expect(SOCKS5.login(Array(login[..<cut])) == .incomplete, "cut at \(cut)")
        }
        #expect(SOCKS5.login([5, 1, 0]) == .invalid)
    }

    @Test func aRequestKeepsTheNameExactlyAsTheBrowserGaveIt() {
        // The whole point: the name is not looked up on this device.
        let request = connect(to: "app.internal.example", port: 8443)
        #expect(SOCKS5.request(request) == .value(.init(command: 1, host: "app.internal.example", port: 8443),
                                                  consumed: request.count))
        for cut in 0..<request.count {
            #expect(SOCKS5.request(Array(request[..<cut])) == .incomplete, "cut at \(cut)")
        }
    }

    @Test func addressesTheBrowserAlreadyHasAreWrittenOutAsText() {
        #expect(SOCKS5.request([5, 1, 0, 1, 10, 200, 109, 26, 0x20, 0xfb])
                == .value(.init(command: 1, host: "10.200.109.26", port: 8443), consumed: 10))
        let loopback: [UInt8] = [5, 1, 0, 4] + [UInt8](repeating: 0, count: 15) + [1, 0, 80]
        #expect(SOCKS5.request(loopback) == .value(.init(command: 1, host: "0:0:0:0:0:0:0:1", port: 80), consumed: 22))
    }

    @Test func somethingThatIsNotARequestIsRefused() {
        #expect(SOCKS5.request([5, 1, 0, 9, 1, 2, 3, 4, 0, 80]) == .invalid, "unknown kind of address")
        #expect(SOCKS5.request([5, 1, 0, 3, 0, 0, 80]) == .invalid, "an empty name")
        #expect(SOCKS5.request([4, 1, 0, 1, 1, 2, 3, 4, 0, 80]) == .invalid)
    }

    @Test func aReplySaysWhatHappenedAndNothingAboutAnAddress() {
        #expect(SOCKS5.reply(.succeeded) == [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(SOCKS5.reply(.hostUnreachable) == [5, 4, 0, 1, 0, 0, 0, 0, 0, 0])
    }
}

/// What the SSH layer reports for a channel the host did not open, in the user's terms.
@Suite struct HostBrowseRefusalReasonTests {
    @Test(arguments: [
        ("direct-tcpip no-such-name.invalid:80 failed: NIOSSHError.channelSetupRejected: Reason: 2 Name or service not known",
         "Name or service not known."),
        ("direct-tcpip ip6-loopback:18097 failed: NIOSSHError.channelSetupRejected: Reason: 2 Connection refused",
         "Connection refused."),
        ("direct-tcpip ip6-localhost:18099 failed: NIOSSHError.channelSetupRejected: Reason: 1 open failed",
         "Its SSH server does not allow connections to that address."),
        ("something else entirely", "something else entirely"),
        ("direct-tcpip x:1 failed: NIOSSHError.channelSetupRejected: Reason: 2 ", "direct-tcpip x:1 failed: NIOSSHError.channelSetupRejected: Reason: 2 "),
    ])
    func theHostsOwnWordsAreKept(message: String, reason: String) {
        // The first three are what the real transport reported against a real sshd on 2026-11-18.
        #expect(HostBrowseRefusal.reason(fromChannelFailure: message) == reason)
    }
}

/// The proxy itself, over a real loopback socket, with the SSH host stood in for.
@Suite(.serialized) struct HostBrowseProxyServerTests {
    private static let credentials = HostBrowseProxyCredentials(username: "browser", password: "only-the-browser-knows")

    /// A client socket that reads with a deadline, so a proxy that says nothing fails a test instead of hanging it.
    private final class Client {
        let fd: Int32

        init(port: Int) throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port)).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        }

        deinit { Darwin.close(fd) }

        func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }

        /// The next `count` bytes; fewer when the proxy closed or said no more in time.
        func receive(_ count: Int) -> [UInt8] {
            var out = [UInt8]()
            while out.count < count {
                var chunk = [UInt8](repeating: 0, count: count - out.count)
                let n = Darwin.read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                out += chunk[..<n]
            }
            return out
        }

        /// True when the proxy has closed the connection.
        var isClosedByProxy: Bool {
            var byte: UInt8 = 0
            return Darwin.read(fd, &byte, 1) == 0
        }

        /// Greeting and login, as the In App browser does them.
        func logIn(_ credentials: HostBrowseProxyCredentials) -> (method: [UInt8], status: [UInt8]) {
            send([5, 2, 0, 2])
            let method = receive(2)
            send([1, UInt8(credentials.username.utf8.count)] + Array(credentials.username.utf8)
                 + [UInt8(credentials.password.utf8.count)] + Array(credentials.password.utf8))
            return (method, receive(2))
        }

        func ask(for name: String, port: Int) {
            send([5, 1, 0, 3, UInt8(name.utf8.count)] + Array(name.utf8) + [UInt8(port >> 8), UInt8(port & 0xff)])
        }
    }

    private func connectedService() async throws -> (SSHService, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        let host = Host(name: "first-hop", address: "192.0.2.24", port: 22, username: "operator",
                        keyID: "test-key", defaultWorkdir: "/")
        let defaults = try #require(UserDefaults(suiteName: "host-browse-\(UUID().uuidString)"))
        let service = SSHService(host: host, transport: transport, knownHosts: KnownHostsStore(defaults: defaults))
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        return (service, transport)
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func theBrowserReachesTheNameItAskedForThroughTheSSHHost() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        let browser = try Client(port: listener.localPort)

        let login = browser.logIn(Self.credentials)
        #expect(login.method == [5, 2], "The proxy asks for the password")
        #expect(login.status == [1, 0])
        browser.ask(for: "app.internal.example", port: 8443)

        #expect(browser.receive(10) == SOCKS5.reply(.succeeded))
        // Opened on the SSH host, by the name as written: this device never resolved it.
        #expect(transport.openedDirectTCPIPTargets == [.init(host: "app.internal.example", port: 8443)])

        // And from then on it is a plain pipe, both ways.
        browser.send(Array("GET / HTTP/1.1\r\n\r\n".utf8))
        let remote = try #require(transport.openedDirectTCPIPChannels.first)
        await eventually("the request to reach the host") { remote.sent == Data("GET / HTTP/1.1\r\n\r\n".utf8) }
        remote.emit(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        #expect(browser.receive(19) == Array("HTTP/1.1 200 OK\r\n\r\n".utf8))

        await listener.stop()
    }

    @Test func aWrongPasswordReachesNothing() async throws {
        // Any app on the device can connect to a loopback port. Only the browser has the password.
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        let intruder = try Client(port: listener.localPort)

        let login = intruder.logIn(HostBrowseProxyCredentials(username: "browser", password: "a guess"))

        #expect(login.status == [1, 1])
        #expect(intruder.isClosedByProxy)
        #expect(transport.openedDirectTCPIPTargets.isEmpty)
        await listener.stop()
    }

    @Test func aClientThatOffersNoPasswordIsTurnedAway() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        let intruder = try Client(port: listener.localPort)

        intruder.send([5, 1, 0])                // "no authentication" is all it offers
        #expect(intruder.receive(2) == [5, 0xff])
        intruder.ask(for: "app.internal.example", port: 80)

        #expect(intruder.isClosedByProxy)
        #expect(transport.openedDirectTCPIPTargets.isEmpty)
        await listener.stop()
    }

    @Test func aDestinationTheHostRefusesIsToldToTheBrowserAndToTheApp() async throws {
        let (service, transport) = try await connectedService()
        transport.directTCPIPError = SSHTransportError.commandFailed("direct-tcpip nowhere.internal:443 failed: administratively prohibited")
        let refusals = NIOLockedValueBox<[HostBrowseRefusal]>([])
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { refusal in
            refusals.withLockedValue { $0.append(refusal) }
        }
        let browser = try Client(port: listener.localPort)
        _ = browser.logIn(Self.credentials)

        browser.ask(for: "nowhere.internal", port: 443)

        #expect(browser.receive(10) == SOCKS5.reply(.hostUnreachable))
        #expect(browser.isClosedByProxy)
        #expect(refusals.withLockedValue { $0 } == [HostBrowseRefusal(
            destination: "nowhere.internal:443",
            reason: "direct-tcpip nowhere.internal:443 failed: administratively prohibited")],
                "A message in no known shape is passed on whole")
        await listener.stop()
    }

    @Test func aRefusalStillReachesTheBrowserWhenTheSSHLayerSaysClosedFirst() async throws {
        // What really happens: for a destination the host refuses, the SSH layer
        // reports "closed" a few milliseconds before the refusal. The proxy hung
        // up on the browser at that point, lost the reason, and the browser, left
        // without an answer, waited instead of failing.
        let (service, transport) = try await connectedService()
        transport.directTCPIPClosesBeforeFailing = true
        transport.directTCPIPError = SSHTransportError.commandFailed(
            "direct-tcpip wiki.internal:80 failed: NIOSSHError.channelSetupRejected: Reason: 2 Name or service not known")
        let refusals = NIOLockedValueBox<[HostBrowseRefusal]>([])
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { refusal in
            refusals.withLockedValue { $0.append(refusal) }
        }
        let browser = try Client(port: listener.localPort)
        _ = browser.logIn(Self.credentials)

        browser.ask(for: "wiki.internal", port: 80)

        #expect(browser.receive(10) == SOCKS5.reply(.hostUnreachable), "The browser is answered, not hung up on")
        #expect(refusals.withLockedValue { $0 } == [HostBrowseRefusal(destination: "wiki.internal:80",
                                                                       reason: "Name or service not known.")])
        await listener.stop()
    }

    @Test func aConnectionTheHostClosesLaterEndsTheBrowsersToo() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        let browser = try Client(port: listener.localPort)
        _ = browser.logIn(Self.credentials)
        browser.ask(for: "app.internal.example", port: 80)
        #expect(browser.receive(10) == SOCKS5.reply(.succeeded))
        let remote = try #require(transport.openedDirectTCPIPChannels.first)

        remote.close()

        #expect(browser.isClosedByProxy)
        await listener.stop()
    }

    @Test func aDestinationThatNeverAnswersIsGivenUpOn() async throws {
        let (service, transport) = try await connectedService()
        transport.beforeDirectTCPIP = { try await Task.sleep(for: .seconds(30)) }
        let refusals = NIOLockedValueBox<[HostBrowseRefusal]>([])
        let server = NIOHostBrowseProxyServer(service: service, connectTimeout: .milliseconds(150))
        let listener = try await server.start(credentials: Self.credentials) { refusal in
            refusals.withLockedValue { $0.append(refusal) }
        }
        let browser = try Client(port: listener.localPort)
        _ = browser.logIn(Self.credentials)

        browser.ask(for: "silent.internal", port: 80)

        #expect(browser.receive(10) == SOCKS5.reply(.hostUnreachable))
        #expect(refusals.withLockedValue { $0.first?.destination } == "silent.internal:80")
        #expect(refusals.withLockedValue { $0.first?.reason.contains("No answer") } == true)
        await listener.stop()
    }

    @Test func somethingOtherThanAConnectionIsNotOffered() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        let client = try Client(port: listener.localPort)
        _ = client.logIn(Self.credentials)

        client.send([5, 2, 0, 1, 127, 0, 0, 1, 0, 80])      // BIND: let others connect in

        #expect(client.receive(10) == SOCKS5.reply(.commandNotSupported))
        #expect(transport.openedDirectTCPIPTargets.isEmpty)
        await listener.stop()
    }

    @Test func whenTheBrowserClosesAConnectionTheHostsEndIsClosedToo() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        var browser: Client? = try Client(port: listener.localPort)
        _ = browser?.logIn(Self.credentials)
        browser?.ask(for: "app.internal.example", port: 80)
        _ = browser?.receive(10)
        let remote = try #require(transport.openedDirectTCPIPChannels.first)

        browser = nil

        await eventually("the host's end to close") { remote.closed }
        await listener.stop()
    }

    @Test func stoppingTheProxyEndsItsConnectionsAndGivesThePortBack() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }
        let port = listener.localPort
        let browser = try Client(port: port)
        _ = browser.logIn(Self.credentials)
        browser.ask(for: "app.internal.example", port: 80)
        _ = browser.receive(10)
        let remote = try #require(transport.openedDirectTCPIPChannels.first)

        await listener.stop()

        await eventually("the host's end to close") { remote.closed }
        #expect(browser.isClosedByProxy)
        #expect(throws: POSIXError.self) { _ = try Client(port: port) }
    }

    @Test func theProxySaysWhatTheBrowserAsksItFor() async throws {
        let (service, _) = try await connectedService()
        let asked = NIOLockedValueBox<[String]>([])
        let listener = try await NIOHostBrowseProxyServer(service: service).start(
            credentials: Self.credentials,
            onRequest: { destination in asked.withLockedValue { $0.append(destination) } },
            onRefusal: { _ in })
        let browser = try Client(port: listener.localPort)
        _ = browser.logIn(Self.credentials)

        browser.ask(for: "app.internal.example", port: 8443)

        #expect(browser.receive(10) == SOCKS5.reply(.succeeded))
        #expect(asked.withLockedValue { $0 } == ["app.internal.example:8443"])
        await listener.stop()
    }

    @Test func aProxySaysWhetherItStillTakesConnections() async throws {
        let (service, transport) = try await connectedService()
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: Self.credentials) { _ in }

        #expect(await listener.accepts())
        #expect(await listener.accepts(), "Looking does not wear it out")
        #expect(transport.openedDirectTCPIPTargets.isEmpty, "And asks nothing of the host")

        // The browser still gets through after it was looked at.
        let browser = try Client(port: listener.localPort)
        #expect(browser.logIn(Self.credentials).status == [1, 0])

        await listener.stop()

        #expect(await !listener.accepts())
    }
}
