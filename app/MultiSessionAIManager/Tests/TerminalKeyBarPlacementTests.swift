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

    /// Where a view ended up in the window.
    private struct FrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    /// The narrow bar's frame in a phone-sized window, with its "more" panel open or not.
    private func barFrame(moreOpen: Bool) async throws -> CGRect {
        final class Seen { var frame = CGRect.zero }
        let seen = Seen()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let screen = ZStack(alignment: .bottomLeading) {
            Color.black
            TerminalQuickKeyBar(emulator: TerminalEmulator(frameClock: TestTerminalFrameClock()),
                                controller: KeyInputController(), keyboard: KeyboardVisibilityModel(),
                                app: TerminalBarAppActions(sendFile: {}, toggleIntelligence: {}, openSettings: {}),
                                isCompact: true, moreOpen: .constant(moreOpen), onInputBytes: { _ in })
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FrameKey.self, value: proxy.frame(in: .global))
                })
        }
        .onPreferenceChange(FrameKey.self) { seen.frame = $0 }
        .ignoresSafeArea()
        window.rootViewController = UIHostingController(rootView: screen)
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await soon { seen.frame.height > 0 })
        try await Task.sleep(for: .milliseconds(200))
        return seen.frame
    }

    /// The panel behind "more" stands on the bar, inside the bar's own frame: the
    /// bar grows upward by it and its foot stays where it was. It once hung down
    /// from the bar's top edge instead, off the bottom of the screen.
    @Test func theMorePanelStandsOnTheBarAndTheBarsFootStaysPut() async throws {
        let setting = UserDefaults.standard
        setting.set(false, forKey: TerminalKeyBar.collapsedKey)
        setting.set("", forKey: TerminalKeyBar.hiddenKey)
        defer {
            setting.removeObject(forKey: TerminalKeyBar.collapsedKey)
            setting.removeObject(forKey: TerminalKeyBar.hiddenKey)
        }

        let closed = try await barFrame(moreOpen: false)
        let open = try await barFrame(moreOpen: true)

        #expect(abs(open.maxY - closed.maxY) < 1, "foot: \(open.maxY) against \(closed.maxY)")
        // Four rows of tiles and their frame.
        #expect(open.height > closed.height + 200, "open \(open.height), closed \(closed.height)")
        #expect(open.minY >= 0, "the panel is on the screen")
        #expect(abs(open.width - closed.width) < 1)
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
