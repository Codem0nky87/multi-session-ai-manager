import SwiftUI
import Testing
import UIKit
@testable import MultiSessionAIManager

/// The key bar under a real terminal view, in a real window.
@Suite(.serialized) @MainActor struct TerminalKeyBarPlacementTests {
    private func store() -> UserDefaults { UserDefaults(suiteName: "msam.keybar.\(UUID())")! }

    /// Whether `condition` came true within three seconds. Never hangs.
    private func soon(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func collapsingTheBarGivesTheTerminalItsRowsAndOpeningItTakesThemBack() async throws {
        let setting = UserDefaults.standard
        setting.set(false, forKey: TerminalKeyBar.collapsedKey)
        defer { setting.removeObject(forKey: TerminalKeyBar.collapsedKey) }

        let keys = KeyStore(backing: InMemoryKeychain())
        let host = Host(name: "Build host", address: "192.0.2.10", username: "alice",
                        keyID: try keys.generateEd25519(label: "bar"), defaultWorkdir: "/home/alice")
        let connection = HostConnection(host: host, keyStore: keys,
                                        knownHosts: KnownHostsStore(defaults: store()), transport: FakeSSHTransport())
        let session = HerdrHostSession(
            connection: connection, sessionName: nil,
            terminal: TerminalEmulator(history: .hostOwned, frameClock: TestTerminalFrameClock()))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        window.rootViewController = UIHostingController(
            rootView: HostTerminalView(session: session).environment(TerminalSettings(defaults: store())))
        window.isHidden = false
        defer { window.isHidden = true }

        // The view first sizes the terminal to the window, less the open bar.
        #expect(await soon { session.terminal.cols >= 80 && session.terminal.rows >= 14 })
        try await Task.sleep(for: .milliseconds(300))
        let open = session.terminal.rows

        setting.set(true, forKey: TerminalKeyBar.collapsedKey)
        #expect(await soon { session.terminal.rows > open },
                "collapsed: \(session.terminal.rows) rows, open: \(open)")

        setting.set(false, forKey: TerminalKeyBar.collapsedKey)
        #expect(await soon { session.terminal.rows == open },
                "open again: \(session.terminal.rows) rows, first: \(open)")
        await session.stop()
    }
}
