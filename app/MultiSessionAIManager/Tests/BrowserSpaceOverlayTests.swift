import SwiftUI
import Testing
import UIKit
@testable import MultiSessionAIManager

/// The browser of a browser space, in a real window so its `onChange`s run.
@Suite(.serialized) @MainActor struct BrowserSpaceOverlayTests {
    private func store() -> UserDefaults { UserDefaults(suiteName: "msam.overlay.\(UUID())")! }

    private func host(_ keys: KeyStore) throws -> Host {
        Host(name: "Forge", address: "10.0.0.1", username: "alice",
             keyID: try keys.generateEd25519(label: "space"), defaultWorkdir: "/home/alice")
    }

    private func window<Content: View>(_ content: Content, size: CGSize) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        return window
    }

    /// Whether `condition` came true within three seconds. Never hangs.
    private func soon(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aPaneStartsBrowsingAndOpensWhatItsSpaceShowedLast() async throws {
        let keys = KeyStore(backing: InMemoryKeychain())
        let forwarding = PortForwardingSession(
            host: try host(keys), keyStore: keys, knownHosts: KnownHostsStore(defaults: store()),
            tunnels: [], transport: FakeSSHTransport(),
            keepAlive: .init(interval: .seconds(3600), probeTimeout: .seconds(1)))
        let spaces = BrowserSpaceModel(hostID: forwarding.host.id, defaults: store())
        spaces.remember(address: "http://grafana.internal:3000/", for: "7f3a2c")
        let page = spaces.page(for: "7f3a2c")
        let window = try window(HostBrowserPane(spaceID: "7f3a2c", page: page, forwarding: forwarding, spaces: spaces),
                                size: CGSize(width: 600, height: 400))
        defer { window.isHidden = true }

        #expect(await soon { if case .ready = forwarding.browse.state { true } else { false } },
                "The pane starts the host's proxy itself")
        #expect(await soon { page.isLoading || page.currentAddress.contains("grafana.internal") },
                "The address the space showed last is opened without being typed again")
        await forwarding.shutdown()
    }

    @Test func whatTheTerminalDrawsDecidesWhereTheBrowserGoes() async throws {
        let keys = KeyStore(backing: InMemoryKeychain())
        let connection = HostConnection(host: try host(keys), keyStore: keys,
                                        knownHosts: KnownHostsStore(defaults: store()), transport: FakeSSHTransport())
        let session = HerdrHostSession(
            connection: connection, sessionName: nil,
            terminal: TerminalEmulator(history: .hostOwned, frameClock: TestTerminalFrameClock()))
        let window = try window(HostTerminalView(session: session).environment(TerminalSettings(defaults: store())),
                                size: CGSize(width: 900, height: 600))
        defer { window.isHidden = true }
        // The terminal draws only while something visible owns it. The view is
        // one such owner while its scene is active, which a test host's scene
        // is not for long; this test is another.
        let watching = TerminalVisibilityOwner()
        _ = session.terminal.setVisibility(true, for: watching)
        // The view first sizes the terminal to the window.
        #expect(await soon { session.terminal.cols >= 80 && session.terminal.rows >= 14 })

        // What the placeholder writes into its pane, to the right of a sidebar.
        var bytes = "\u{1b}[?1049h"
        for row in 2...11 { bytes += "\u{1b}[\(row);21H" + String(repeating: "░", count: 40) }
        bytes += "\u{1b}[2;21H" + BrowserSpaceMarker.text(id: "7f3a2c", columns: 40, rows: 10)
        session.terminal.feed(Data(bytes.utf8))
        session.terminal.tick()

        let expected = [BrowserSpaceRegion(id: "7f3a2c", column: 20, row: 1, columns: 40, rows: 10)]
        #expect(await soon { session.terminal.tick(); return session.browserSpaces.regions == expected },
                "\(session.browserSpaces.regions)")
        await session.stop()
    }
}
