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
        spaces.remember(.init(addresses: ["http://grafana.internal:3000/", "http://wiki.internal/"], selected: 0), for: "7f3a2c")
        let tabs = spaces.tabs(for: "7f3a2c")
        let page = tabs.selected.page
        let window = try window(HostBrowserPane(spaceID: "7f3a2c", tabs: tabs, forwarding: forwarding, spaces: spaces),
                                size: CGSize(width: 600, height: 400))
        defer { window.isHidden = true }

        #expect(await soon { if case .ready = forwarding.browse.state { true } else { false } },
                "The pane starts the host's proxy itself")
        #expect(await soon { page.isLoading || page.currentAddress.contains("grafana.internal") },
                "The address the space showed last is opened without being typed again")

        // The other tab opens what it showed last when it is shown, not before.
        let other = tabs.tabs[1]
        #expect(other.page.webView == nil && !other.page.isLoading)
        tabs.select(other.id)
        #expect(await soon { other.page.isLoading || other.page.currentAddress.contains("wiki.internal") })

        // And "+" gives an empty page with nothing loading in it.
        let added = try #require(tabs.add())
        #expect(await soon { added.page.webView != nil })
        #expect(!added.page.hasPage && !added.page.isLoading && added.page.currentAddress.isEmpty)
        #expect(page.webView != nil, "The first tab's page is still there to go back to")
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

    @Test func theBrowserStaysWhileAShorterTerminalWaitsForItsHost() async throws {
        let keys = KeyStore(backing: InMemoryKeychain())
        let connection = HostConnection(host: try host(keys), keyStore: keys,
                                        knownHosts: KnownHostsStore(defaults: store()), transport: FakeSSHTransport())
        let session = HerdrHostSession(
            connection: connection, sessionName: nil,
            terminal: TerminalEmulator(history: .hostOwned, frameClock: TestTerminalFrameClock()))
        let window = try window(HostTerminalView(session: session).environment(TerminalSettings(defaults: store())),
                                size: CGSize(width: 900, height: 600))
        defer { window.isHidden = true }
        let watching = TerminalVisibilityOwner()
        _ = session.terminal.setVisibility(true, for: watching)
        #expect(await soon { session.terminal.cols >= 80 && session.terminal.rows >= 14 })
        let tall = session.terminal.rows

        // A browser space over the whole height, as its placeholder draws it.
        var bytes = "\u{1b}[?1049h"
        for row in 2...(tall - 1) { bytes += "\u{1b}[\(row);21H" + String(repeating: "░", count: 40) }
        bytes += "\u{1b}[2;21H" + BrowserSpaceMarker.text(id: "7f3a2c", columns: 40, rows: tall - 2)
        session.terminal.feed(Data(bytes.utf8))
        #expect(await soon { session.terminal.tick(); return session.browserSpaces.regions.count == 1 })

        // The keyboard comes up: the window's terminal gets shorter. No host
        // answers here, as none has yet in the moment a real one takes.
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 320)
        #expect(await soon { session.terminal.tick(); return session.terminal.rows < tall })
        for _ in 0..<40 {
            session.terminal.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.browserSpaces.regions.count == 1,
                "A browser dropped here loses the keyboard its page just raised")
        await session.stop()
    }

    // MARK: The panes take no part in the terminal's layout

    @MainActor @Observable final class Measured { var height: CGFloat = 0 }

    /// How tall the terminal's place is with these panes over it, in a window
    /// that leaves it little room.
    private func terminalHeight(under panes: [BrowserSpaceRegion]) async throws -> CGFloat {
        let measured = Measured()
        let screen = VStack(spacing: 0) {
            ZStack {
                Color.blue
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size, initial: true) { _, size in measured.height = size.height }
                    })
                BrowserSpacePaneLayout(regions: panes, cell: CGSize(width: 10, height: 10)) { _ in Color.red }
            }
            Color.gray.frame(height: 150)
        }
        let window = try window(screen, size: CGSize(width: 600, height: 400))
        defer { window.isHidden = true }
        _ = await soon { measured.height > 0 }
        try await Task.sleep(for: .milliseconds(100))
        return measured.height
    }

    @Test func aPaneTallerThanTheTerminalDoesNotHoldTheTerminalsHeightUp() async throws {
        // The terminal has just become shorter (the keyboard came up) and the
        // pane is still as tall as the host last drew it. If the pane props the
        // terminal up, the terminal can only shrink a few rows per redraw, and
        // Herdr lays the screen out again for every one of them.
        let alone = try await terminalHeight(under: [])
        let tallPane = BrowserSpaceRegion(id: "7f3a2c", column: 2, row: 1, columns: 30, rows: 60)   // 600 points
        let underATallPane = try await terminalHeight(under: [tallPane])

        #expect(alone > 50 && alone < 300, "The window leaves the terminal some room: \(alone)")
        #expect(underATallPane == alone, "\(underATallPane) with the pane, \(alone) without")
    }
}
