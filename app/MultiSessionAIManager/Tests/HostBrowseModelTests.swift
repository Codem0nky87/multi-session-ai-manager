import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import MultiSessionAIManager

/// Browsing through a host: when its proxy runs, what the browser is told, and
/// what the user is told when the host will not open something.
@Suite @MainActor struct HostBrowseModelTests {
    private final class Listener: HostBrowseProxyListener, @unchecked Sendable {
        let localPort: Int
        private let lock = NSLock()
        private var stops = 0
        private var listening = true
        private var asked = 0
        /// Holds an `accepts` until released, to catch what arrives meanwhile.
        var gate: (@Sendable () async -> Void)?
        init(localPort: Int) { self.localPort = localPort }
        var stopCount: Int { lock.withLock { stops } }
        var timesAsked: Int { lock.withLock { asked } }
        func stop() async { lock.withLock { stops += 1 } }
        /// What iOS does to a suspended app's sockets: the port answers nobody.
        func dies() { lock.withLock { listening = false } }
        func accepts() async -> Bool {
            lock.withLock { asked += 1 }
            await gate?()
            return lock.withLock { listening }
        }
    }

    private final class Server: HostBrowseProxyServing, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Listener] = []
        private var given: [HostBrowseProxyCredentials] = []
        private var refuse: [@Sendable (HostBrowseRefusal) -> Void] = []
        var failure: Error?
        /// Holds `start` until released, to catch a stop that arrives meanwhile.
        var gate: (@Sendable () async -> Void)?

        func start(credentials: HostBrowseProxyCredentials,
                   onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) async throws -> any HostBrowseProxyListener {
            await gate?()
            if let failure { throw failure }
            return lock.withLock {
                let listener = Listener(localPort: 51_000 + made.count)
                made.append(listener)
                given.append(credentials)
                refuse.append(onRefusal)
                return listener
            }
        }

        var listeners: [Listener] { lock.withLock { made } }
        var credentials: [HostBrowseProxyCredentials] { lock.withLock { given } }
        /// The proxy of the given session (the latest by default) reports a refusal.
        func hostRefuses(_ refusal: HostBrowseRefusal, session: Int? = nil) {
            let all = lock.withLock { refuse }
            (session.map { all[$0] } ?? all.last)?(refusal)
        }
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func openingTheBrowserStartsAProxyOnlyItCanUse() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        #expect(model.state == .idle)
        #expect(!model.isActive)

        await model.start()

        let credentials = server.credentials[0]
        #expect(model.state == .ready(.init(port: 51_000, credentials: credentials)))
        #expect(model.isActive)
        #expect(credentials.username.count >= 16 && credentials.password.count >= 16, "Nothing guessable")
    }

    @Test func everyBrowsingSessionHasAPasswordOfItsOwn() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        await model.stop()
        await model.start()

        #expect(server.credentials.count == 2)
        #expect(server.credentials[0] != server.credentials[1])
    }

    @Test func closingTheBrowserStopsTheProxy() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()

        await model.stop()

        #expect(model.state == .idle)
        #expect(!model.isActive)
        #expect(server.listeners[0].stopCount == 1)
    }

    @Test func aHostThatCannotBeReachedIsSaidInsteadOfStartingAProxy() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { "Forge is not reachable: connection timed out." })

        await model.start()

        #expect(model.state == .failed("Forge is not reachable: connection timed out."))
        #expect(server.listeners.isEmpty)
        #expect(!model.isActive)
    }

    @Test func aProxyThatWillNotStartIsReported() async {
        let server = Server()
        server.failure = SSHTransportError.commandFailed("no port")
        let model = HostBrowseModel(server: server, connect: { nil })

        await model.start()

        guard case .failed(let message) = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(message.contains("Could not start browsing"))
    }

    @Test func openingItTwiceStartsOneProxy() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        await model.start()
        #expect(server.listeners.count == 1)
    }

    @Test func aBrowserClosedWhileItsProxyWasStartingLeavesNoProxyBehind() async {
        let server = Server()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        server.gate = {
            entered.continuation.yield()
            for await _ in release.stream { break }
        }
        let model = HostBrowseModel(server: server, connect: { nil })

        let starting = Task { await model.start() }
        for await _ in entered.stream { break }
        await model.stop()
        release.continuation.yield()
        await starting.value

        #expect(model.state == .idle)
        #expect(server.listeners.count == 1)
        #expect(server.listeners[0].stopCount == 1, "The proxy that came up late is stopped at once")
    }

    @Test func whatTheHostRefusedIsKeptForThePageThatFailed() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        let refusal = HostBrowseRefusal(destination: "nowhere.internal:443", reason: "administratively prohibited")

        server.hostRefuses(refusal)
        await eventually("the refusal to arrive") { model.lastRefusal != nil }

        #expect(model.lastRefusal == refusal)
        model.clearRefusal()
        #expect(model.lastRefusal == nil)
    }

    @Test func aRefusalFromAnEarlierSessionIsNotShownInALaterOne() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        await model.stop()
        await model.start()

        // The first session's proxy reports late.
        server.hostRefuses(HostBrowseRefusal(destination: "old.internal:80", reason: "late"), session: 0)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(model.lastRefusal == nil)
        // While the current one is heard.
        server.hostRefuses(HostBrowseRefusal(destination: "new.internal:80", reason: "refused"))
        await eventually("the current session's refusal") { model.lastRefusal?.destination == "new.internal:80" }
    }

    // MARK: A proxy that has stopped listening

    /// The proxy listens on this device. Once it had stopped (iOS takes the
    /// sockets of an app it suspended) every page failed with "Could not
    /// connect to the server" and went on failing, because nothing looked.
    @Test func aProxyThatHasStoppedListeningIsReplacedByANewOne() async throws {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        server.listeners[0].dies()

        let replaced = await model.repair()

        #expect(replaced)
        try #require(server.listeners.count == 2)
        // A new port and a new password: the browser's pages have to be pointed at it.
        #expect(model.state == .ready(.init(port: 51_001, credentials: server.credentials[1])))
        #expect(server.credentials[0] != server.credentials[1])
        #expect(server.listeners[0].stopCount == 1, "The dead one is let go of")
        #expect(server.listeners[1].stopCount == 0)
    }

    @Test func aProxyThatStillListensIsLeftAlone() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        let before = model.state

        let replaced = await model.repair()

        #expect(!replaced)
        #expect(model.state == before)
        #expect(server.listeners.count == 1)
        #expect(server.listeners[0].stopCount == 0)
        #expect(server.listeners[0].timesAsked == 1)
    }

    @Test func aClosedBrowserHasNothingToRepair() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })

        #expect(await !model.repair())
        #expect(server.listeners.isEmpty, "Looking at the proxy never opens the browser")

        await model.start()
        await model.stop()
        #expect(await !model.repair())
        #expect(server.listeners.count == 1)
        #expect(model.state == .idle)
    }

    @Test func aRepairThatCannotReachTheHostSaysSo() async {
        let server = Server()
        let reachable = NIOLockedValueBox(true)
        let model = HostBrowseModel(server: server, connect: {
            reachable.withLockedValue { $0 } ? nil : "Forge is not reachable: connection timed out."
        })
        await model.start()
        server.listeners[0].dies()
        reachable.withLockedValue { $0 = false }

        let replaced = await model.repair()

        #expect(replaced, "The dead proxy is gone either way")
        #expect(model.state == .failed("Forge is not reachable: connection timed out."))
        #expect(server.listeners.count == 1)
        #expect(server.listeners[0].stopCount == 1)
    }

    @Test func twoLooksAtOnceReplaceItOnce() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        let dead = server.listeners[0]
        dead.dies()
        let entered = NIOLockedValueBox(false)
        let release = AsyncStream<Void>.makeStream()
        dead.gate = {
            entered.withLockedValue { $0 = true }
            for await _ in release.stream { break }
        }

        let first = Task { await model.repair() }
        await eventually("the first look to begin") { entered.withLockedValue { $0 } }
        // A page fails and the app comes to the front in the same moment.
        let second = await model.repair()
        release.continuation.yield()

        #expect(!second, "The look that is already under way will do")
        #expect(await first.value)
        #expect(server.listeners.count == 2)
    }

    /// Every start asks something of the host, so a proxy that will not stay
    /// up must not be started over and over as fast as pages can fail.
    @Test func aProxyThatWasJustReplacedIsNotReplacedAgainAtOnce() async throws {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil }, repairGap: .milliseconds(300))
        await model.start()
        server.listeners[0].dies()
        #expect(await model.repair())
        try #require(server.listeners.count == 2)
        server.listeners[1].dies()

        #expect(await !model.repair(), "Too soon after the last one")
        #expect(server.listeners.count == 2)

        try await Task.sleep(for: .milliseconds(350))
        #expect(await model.repair())
        #expect(server.listeners.count == 3)
    }

    @Test func aBrowserClosedWhileItsProxyWasLookedAtStaysClosed() async {
        let server = Server()
        let model = HostBrowseModel(server: server, connect: { nil })
        await model.start()
        let dead = server.listeners[0]
        dead.dies()
        let entered = NIOLockedValueBox(false)
        let release = AsyncStream<Void>.makeStream()
        dead.gate = {
            entered.withLockedValue { $0 = true }
            for await _ in release.stream { break }
        }

        let looking = Task { await model.repair() }
        await eventually("the look to begin") { entered.withLockedValue { $0 } }
        await model.stop()
        release.continuation.yield()

        #expect(await !looking.value)
        #expect(model.state == .idle)
        #expect(server.listeners.count == 1, "No proxy is started for a browser that was closed")
    }
}

@Suite struct HostBrowserAddressTests {
    @Test(arguments: [
        ("intranet", "http://intranet"),
        ("app.internal.example/wiki?page=1", "http://app.internal.example/wiki?page=1"),
        ("10.200.109.26:8443", "http://10.200.109.26:8443"),
        ("https://qas.internal.example:8443/login", "https://qas.internal.example:8443/login"),
        ("  http://localhost:3000/  ", "http://localhost:3000/"),
        ("HTTPS://Example.internal", "HTTPS://Example.internal"),
    ])
    func whatIsTypedBecomesAnAddress(typed: String, address: String) {
        #expect(HostBrowserAddress.url(from: typed)?.absoluteString == address)
    }

    @Test(arguments: ["", "   ", "two words", "file:///etc/passwd", "javascript://alert(1)", "ftp://files.internal/", "http://"])
    func whatIsNotAWebAddressIsNotLoaded(typed: String) {
        #expect(HostBrowserAddress.url(from: typed) == nil)
    }
}

@Suite struct HostBrowseCertificateExceptionTests {
    private let trust = NSURLAuthenticationMethodServerTrust

    @Test func noCertificateIsAcceptedUntilTheUserSaysSoForThatSite() {
        var exceptions = HostBrowseCertificateExceptions()
        #expect(!exceptions.allows(authenticationMethod: trust, host: "qas.internal.example", port: 8443, hasServerTrust: true))

        exceptions.accept(siteOf: URL(string: "https://QAS.internal.example:8443/login")!)

        #expect(exceptions.allows(authenticationMethod: trust, host: "qas.internal.example", port: 8443, hasServerTrust: true))
    }

    @Test func anExceptionCoversThatSiteAndPortAndNothingElse() {
        var exceptions = HostBrowseCertificateExceptions()
        exceptions.accept(siteOf: URL(string: "https://qas.internal.example:8443/")!)

        #expect(!exceptions.allows(authenticationMethod: trust, host: "qas.internal.example", port: 443, hasServerTrust: true))
        #expect(!exceptions.allows(authenticationMethod: trust, host: "other.internal.example", port: 8443, hasServerTrust: true))
        #expect(!exceptions.allows(authenticationMethod: trust, host: "qas.internal.example", port: 8443, hasServerTrust: false))
        #expect(!exceptions.allows(authenticationMethod: NSURLAuthenticationMethodHTTPBasic, host: "qas.internal.example",
                                   port: 8443, hasServerTrust: true), "A password prompt is not a certificate")
    }

    @Test func aSiteWithoutAPortMeansTheUsualOne() {
        var exceptions = HostBrowseCertificateExceptions()
        exceptions.accept(siteOf: URL(string: "https://wiki.internal.example/")!)
        #expect(exceptions.allows(authenticationMethod: trust, host: "wiki.internal.example", port: 443, hasServerTrust: true))
    }

    @Test func aPlainHTTPPageHasNoCertificateToAccept() {
        var exceptions = HostBrowseCertificateExceptions()
        exceptions.accept(siteOf: URL(string: "http://wiki.internal.example/")!)
        #expect(exceptions == HostBrowseCertificateExceptions())
    }

    @Test func onlyAnUntrustedCertificateIsOfferedToBePassed() {
        func failure(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }
        #expect(HostBrowseCertificateExceptions.isCertificateProblem(failure(NSURLErrorServerCertificateUntrusted)))
        #expect(HostBrowseCertificateExceptions.isCertificateProblem(failure(NSURLErrorServerCertificateHasUnknownRoot)))
        #expect(HostBrowseCertificateExceptions.isCertificateProblem(failure(NSURLErrorServerCertificateHasBadDate)))
        #expect(!HostBrowseCertificateExceptions.isCertificateProblem(failure(NSURLErrorCannotFindHost)))
        #expect(!HostBrowseCertificateExceptions.isCertificateProblem(failure(NSURLErrorTimedOut)))
        #expect(!HostBrowseCertificateExceptions.isCertificateProblem(NSError(domain: "other", code: NSURLErrorServerCertificateUntrusted)))
    }
}

@Suite struct HostBrowserFailureTests {
    private func failure(_ code: Int, _ text: String = "It failed.") -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private let page = URL(string: "https://qas.internal.example:8443/login")!

    @Test func whatTheHostSaidIsToldInsteadOfAGenericProxyError() {
        let refusal = HostBrowseRefusal(destination: "QAS.internal.example:8443", reason: "administratively prohibited")
        let described = HostBrowserFailure.describe(failure(NSURLErrorCannotConnectToHost, "Could not connect to the proxy."),
                                                    url: page, refusal: refusal, hostName: "Sithabile - 22")
        #expect(described == HostBrowserFailure(
            message: "Sithabile - 22 could not open QAS.internal.example:8443. administratively prohibited",
            canVisitAnyway: false))
    }

    @Test func aRefusalForAnotherAddressIsNotBlamedOnThisPage() {
        let refusal = HostBrowseRefusal(destination: "ads.example.com:443", reason: "refused")
        let described = HostBrowserFailure.describe(failure(NSURLErrorTimedOut, "The request timed out."),
                                                    url: page, refusal: refusal, hostName: "Forge")
        #expect(described == HostBrowserFailure(message: "The request timed out.", canVisitAnyway: false))
    }

    @Test func thePortIsTheUsualOneWhenTheAddressNamesNone() {
        let refusal = HostBrowseRefusal(destination: "wiki.internal.example:80", reason: "Name or service not known")
        let described = HostBrowserFailure.describe(failure(NSURLErrorCannotConnectToHost), url: URL(string: "http://wiki.internal.example/"),
                                                    refusal: refusal, hostName: "Forge")
        #expect(described?.message == "Forge could not open wiki.internal.example:80. Name or service not known")
    }

    @Test func anUntrustedCertificateCanBePassedAndSaysWhichSite() {
        let described = HostBrowserFailure.describe(
            failure(NSURLErrorServerCertificateUntrusted, "The certificate for this server is invalid."),
            url: page, refusal: nil, hostName: "Forge")
        #expect(described?.canVisitAnyway == true)
        #expect(described?.message == "The certificate of qas.internal.example is not trusted by this device. The certificate for this server is invalid.")
    }

    @Test func aLoadThatWasOnlyReplacedIsNotAFailure() {
        #expect(HostBrowserFailure.describe(failure(NSURLErrorCancelled), url: page, refusal: nil, hostName: "Forge") == nil)
        #expect(HostBrowserFailure.describe(NSError(domain: "WebKitErrorDomain", code: 102), url: page, refusal: nil, hostName: "Forge") == nil)
    }
}

/// The browser shares the host's SSH connection with its forwards, and needs it kept alive the same way.
@Suite(.serialized) @MainActor struct HostBrowseConnectionTests {
    private func session() throws -> (PortForwardingSession, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        let keys = KeyStore(backing: InMemoryKeychain())
        let host = Host(name: "Forge", address: "10.0.0.1", username: "alice",
                        keyID: try keys.generateEd25519(label: "browse"), defaultWorkdir: "/home/alice")
        let session = PortForwardingSession(
            host: host, keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.browse.\(UUID())")!),
            tunnels: [], transport: transport, keepAlive: .init(interval: .seconds(3600), probeTimeout: .seconds(1)))
        return (session, transport)
    }

    @Test func openingTheBrowserConnectsToTheHostByItself() async throws {
        let (session, transport) = try session()
        #expect(transport.connectAttemptCount == 0)

        await session.browse.start()

        #expect(transport.connectAttemptCount == 1)
        guard case .ready = session.browse.state else {
            Issue.record("expected a running proxy, got \(session.browse.state)")
            return
        }
        await session.shutdown()
    }

    @Test func anOpenBrowserIsKeptAliveLikeARunningForward() async throws {
        let (session, transport) = try session()
        await session.connection.connect()
        await session.keepAlive()
        #expect(!transport.commandsRun.contains("true"), "Nothing open: nothing to keep alive")

        await session.browse.start()
        // Opening the browser checks the link once itself.
        let before = transport.commandsRun.filter { $0 == "true" }.count
        await session.keepAlive()

        #expect(transport.commandsRun.filter { $0 == "true" }.count == before + 1)
        await session.shutdown()
    }

    @Test func closingTheHostsSessionStopsItsBrowserProxy() async throws {
        let (session, _) = try session()
        await session.browse.start()

        await session.shutdown()

        #expect(session.browse.state == .idle)
    }

    @Test func aHostThatCannotBeReachedIsNamedInTheMessage() async throws {
        let (session, transport) = try session()
        transport.connectError = SSHTransportError.commandFailed("connection refused")

        await session.browse.start()

        guard case .failed(let message) = session.browse.state else {
            Issue.record("expected a failure, got \(session.browse.state)")
            return
        }
        #expect(message.hasPrefix("Could not connect to Forge"))
    }
}
