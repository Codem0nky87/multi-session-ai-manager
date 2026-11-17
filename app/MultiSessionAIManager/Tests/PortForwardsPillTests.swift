import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import MultiSessionAIManager

/// The pill sits in the monitor bar, and the monitor bar is the top edge of the
/// screen. Its list of forwards was told to open above the pill, where there is
/// no room: it showed as an empty sliver under the status bar, with none of the
/// forwards and no way to stop one.
@Suite(.serialized) @MainActor struct PortForwardsPillTests {
    private final class Listener: SessionWebTunnelListener, @unchecked Sendable {
        let localPort: Int
        init(localPort: Int) { self.localPort = localPort }
        func stop() async {}
    }

    private final class Server: SessionWebTunnelServing, @unchecked Sendable {
        func start(tunnel: SessionWebTunnel, hopPassword: String?,
                   onConnectionError: @escaping @Sendable (String) -> Void) async throws -> any SessionWebTunnelListener {
            Listener(localPort: tunnel.localPort ?? 50_000)
        }
    }

    /// A host's forwarding session with these forwards running.
    private func running(_ forwards: [SessionWebTunnel]) async throws -> PortForwardingSession {
        let keys = KeyStore(backing: InMemoryKeychain())
        let host = Host(name: "Forge", address: "10.0.0.1", username: "alice",
                        keyID: try keys.generateEd25519(label: "forwards"), defaultWorkdir: "/home/alice")
        let session = PortForwardingSession(
            host: host, keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.forwardspill.\(UUID())")!),
            tunnels: forwards, model: SessionWebTunnelModel(server: Server()), transport: FakeSSHTransport(),
            keepAlive: .init(interval: .seconds(3600), probeTimeout: .seconds(1)))
        for forward in forwards { await session.model.start(forward) }
        #expect(session.activeTunnelCount == forwards.count)
        return session
    }

    /// Puts the bar with the session's pill on the simulator's screen.
    private func show(_ session: PortForwardingSession, bar: Bar) async throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = UIHostingController(rootView: Screen(bar: bar, session: session))
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        await eventually("the pill to be on screen") { bar.pillFrame.height > 0 }
        return (window, screen)
    }

    /// What a tap on the pill does, waited for until the list is up.
    private func openList(of bar: Bar, on screen: UIViewController) async throws -> UIViewController {
        bar.isShowingForwards = true
        await eventually("the list to open") {
            guard let list = screen.presentedViewController else { return false }
            return !list.isBeingPresented && list.view.window != nil
        }
        return try #require(screen.presentedViewController)
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func theListOfForwardsOpensBelowThePillWithRoomForAllOfIt() async throws {
        let session = try await running([
            SessionWebTunnel(label: "RDP", targetHost: "127.0.0.1", targetPort: 3391, localPort: 13389),
            SessionWebTunnel(label: "Admin", targetHost: "127.0.0.1", targetPort: 2229, localPort: 12229),
        ])
        let bar = Bar()
        let (window, screen) = try await show(session, bar: bar)

        let list = try await openList(of: bar, on: screen)
        let listFrame = list.view.convert(list.view.bounds, to: nil)

        #expect(listFrame.minY >= bar.pillFrame.maxY - 1,
                "The list opens below the pill (pill \(bar.pillFrame), list \(listFrame)): above it is the edge of the screen")
        // Two forwards, each a row with its Stop, under a title and above Stop all.
        #expect(list.preferredContentSize.height > 120, "The list asks for the height of its rows")
        #expect(listFrame.height >= list.preferredContentSize.height - 1,
                "The list gets the height it asks for (\(list.preferredContentSize.height)), not \(listFrame.height)")

        list.dismiss(animated: false)
        window.isHidden = true
        await session.shutdown()
    }

    @Test func theListStaysClosedWhenAForwardIsStartedAfterTheLastOneWasStoppedFromIt() async throws {
        let forward = SessionWebTunnel(label: "RDP", targetHost: "127.0.0.1", targetPort: 3391, localPort: 13389)
        let session = try await running([forward])
        let bar = Bar()
        let (window, screen) = try await show(session, bar: bar)
        _ = try await openList(of: bar, on: screen)

        // The row's own Stop. Nothing runs any more, so the pill goes, and its list with it.
        await session.model.stop(forward.id)
        await eventually("the list to close with its pill") { screen.presentedViewController == nil }
        await eventually("the bar to know the list is closed") { !bar.isShowingForwards }

        await session.model.start(forward)
        await eventually("the pill to come back") { session.activeTunnelCount == 1 }
        try await Task.sleep(for: .milliseconds(700))
        #expect(screen.presentedViewController == nil, "A list nobody asked for opened with the new forward")

        window.isHidden = true
        await session.shutdown()
    }
}

/// What the monitor bar holds for the pill, and where the pill ended up.
@Observable @MainActor private final class Bar {
    var isShowingForwards = false
    var pillFrame = CGRect.zero
}

/// The pill where the app shows it: in a bar along the top edge of the screen,
/// and only while a forward runs.
private struct Screen: View {
    @Bindable var bar: Bar
    let session: PortForwardingSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if session.activeTunnelCount > 0 {
                    PortForwardsPill(session: session, isShowingForwards: $bar.isShowingForwards) {}
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bar.pillFrame = $0 }
                }
                Spacer()
            }
            .frame(height: 36)
            .background(HerdrTheme.panel)
            Spacer()
        }
        .background(HerdrTheme.background)
    }
}
