import Foundation
import Testing
import UIKit
import WebKit
@testable import MultiSessionAIManager

/// A browser space worked, and then every page failed with "Could not connect
/// to the server" until the app was closed (user report, 2026-11-24). That is
/// what a web view says when the proxy on this device no longer takes its
/// connections; a dead SSH link or a refusal by the host read differently. The
/// proxy had stopped listening (iOS takes the sockets of an app it suspended),
/// the app still called it ready, and nothing looked.
///
/// Now it is looked at when the app comes back to the front, on every
/// keep-alive beat, and whenever a page fails; a dead one is replaced and the
/// page that failed is opened again.
@Suite(.serialized) @MainActor struct HostBrowseRepairTests {
    private final class Listener: HostBrowseProxyListener, @unchecked Sendable {
        let localPort: Int
        private let lock = NSLock()
        private var listening = true
        private var asked = 0
        init(localPort: Int) { self.localPort = localPort }
        var timesAsked: Int { lock.withLock { asked } }
        func stop() async {}
        func dies() { lock.withLock { listening = false } }
        func accepts() async -> Bool {
            lock.withLock {
                asked += 1
                return listening
            }
        }
    }

    private final class Server: HostBrowseProxyServing, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Listener] = []
        func start(credentials: HostBrowseProxyCredentials,
                   onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) async throws -> any HostBrowseProxyListener {
            lock.withLock {
                let listener = Listener(localPort: 52_000 + made.count)
                made.append(listener)
                return listener
            }
        }
        var listeners: [Listener] { lock.withLock { made } }
    }

    /// A host with a browser space open.
    @MainActor private final class Rig {
        let transport = FakeSSHTransport()
        let server = Server()
        let session: PortForwardingSession

        init(beat: Duration = .seconds(3600)) async throws {
            let keys = KeyStore(backing: InMemoryKeychain())
            let host = Host(name: "Forge", address: "10.0.0.1", username: "alice",
                            keyID: try keys.generateEd25519(label: "browse"), defaultWorkdir: "/home/alice")
            session = PortForwardingSession(
                host: host, keyStore: keys,
                knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.browserepair.\(UUID())")!),
                tunnels: [], transport: transport, browseServer: server,
                keepAlive: .init(interval: beat, probeTimeout: .seconds(1)))
            await session.browse.start()
        }

        var endpoint: HostBrowseModel.Endpoint? {
            if case .ready(let endpoint) = session.browse.state { endpoint } else { nil }
        }
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    private static func couldNotConnect(to url: URL) -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                userInfo: [NSURLErrorFailingURLErrorKey: url, NSLocalizedDescriptionKey: "Could not connect to the server."])
    }

    @Test func comingBackToTheAppReplacesAProxyThatDiedMeanwhile() async throws {
        let rig = try await Rig()
        #expect(rig.endpoint?.port == 52_000)
        rig.server.listeners[0].dies()

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await eventually("a new proxy") { rig.endpoint?.port == 52_001 }
        #expect(rig.server.listeners.count == 2)
        await rig.session.shutdown()
    }

    @Test func theBeatReplacesAProxyThatDied() async throws {
        let rig = try await Rig(beat: .milliseconds(30))
        rig.server.listeners[0].dies()

        await eventually("a new proxy") { rig.endpoint?.port == 52_001 }
        await rig.session.shutdown()
    }

    @Test func aProxyThatListensIsLookedAtAndLeftAlone() async throws {
        let rig = try await Rig(beat: .milliseconds(30))

        await eventually("a look at the proxy") { rig.server.listeners[0].timesAsked >= 2 }

        #expect(rig.server.listeners.count == 1)
        #expect(rig.endpoint?.port == 52_000)
        await rig.session.shutdown()
    }

    @Test func aPageThatFailsHasTheProxyLookedAtAndReplaced() async throws {
        let rig = try await Rig()
        let hostID = UUID()
        // In a scope of its own: a web view that is still held keeps its data on the device.
        do {
            let page = HostBrowserPage()
            page.attach(to: try #require(rig.endpoint), hostID: hostID, hostName: "Forge", browse: rig.session.browse)
            let view = try #require(page.webView)
            let wanted = try #require(URL(string: "https://localhost:8443/"))
            rig.server.listeners[0].dies()

            page.webView(view, didFailProvisionalNavigation: nil, withError: Self.couldNotConnect(to: wanted))

            #expect(page.failure?.message == "Could not connect to the server.")
            await eventually("a new proxy") { rig.endpoint?.port == 52_001 }

            // The pane then points the tab at the new proxy, which opens what failed.
            page.attach(to: try #require(rig.endpoint), hostID: hostID, hostName: "Forge", browse: rig.session.browse)

            #expect(page.webView !== view)
            #expect(page.webView?.url == wanted)
            #expect(page.isLoading)
            #expect(page.failure == nil)
            page.stopLoading()
        }
        await rig.session.shutdown()
        await removeTestBrowserData(of: hostID)
    }

    @Test func aPageThatFailsWhileTheProxyListensIsLeftAsItIs() async throws {
        let rig = try await Rig()
        let hostID = UUID()
        do {
            let page = HostBrowserPage()
            page.attach(to: try #require(rig.endpoint), hostID: hostID, hostName: "Forge", browse: rig.session.browse)
            let view = try #require(page.webView)
            let wanted = try #require(URL(string: "https://localhost:8443/"))

            page.webView(view, didFailProvisionalNavigation: nil, withError: Self.couldNotConnect(to: wanted))

            await eventually("a look at the proxy") { rig.server.listeners[0].timesAsked >= 1 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.server.listeners.count == 1)
            #expect(page.failure?.message == "Could not connect to the server.", "The failure stays for the user to read")
            #expect(page.webView === view)
        }
        await rig.session.shutdown()
        await removeTestBrowserData(of: hostID)
    }

    @Test func aTabGivenANewProxyStaysEmptyWhenItHadNothingOpen() async throws {
        let rig = try await Rig()
        let hostID = UUID()
        do {
            let page = HostBrowserPage()
            page.attach(to: try #require(rig.endpoint), hostID: hostID, hostName: "Forge", browse: rig.session.browse)
            rig.server.listeners[0].dies()
            #expect(await rig.session.browse.repair())

            page.attach(to: try #require(rig.endpoint), hostID: hostID, hostName: "Forge", browse: rig.session.browse)

            #expect(page.webView?.url == nil)
            #expect(!page.isLoading)
        }
        await rig.session.shutdown()
        await removeTestBrowserData(of: hostID)
    }
}
