import Foundation
import Testing
@testable import MultiSessionAIManager

/// Moved out of `HerdrSettingsTests` alongside the source move of
/// `HerdrPortForwardingSheet` + `HerdrSSHConnectionLifecycle` into
/// `UI/Settings/HostPortForwarding.swift`. Port forwarding outlives the Herdr
/// gateway settings section, so its coverage must too.
@MainActor
@Suite(.serialized)
struct HostPortForwardingTests {
    @Test func portForwardingLifecycleStopsTunnelBeforeDisconnectAndRetiresLateConnect() async {
        let probe = PortForwardingLifecycleProbe()
        let lifecycle = HerdrSSHConnectionLifecycle(
            connect: { await probe.connect() },
            disconnect: { await probe.record("disconnect") }
        )

        lifecycle.connect()
        await probe.waitUntilConnecting()
        await lifecycle.close {
            await probe.record("stop")
        }
        #expect(await probe.events == ["connect", "stop", "disconnect"])

        await probe.releaseConnect()
        for _ in 0..<20 {
            if await probe.events.count >= 4 { break }
            await Task.yield()
        }
        #expect(await probe.events == ["connect", "stop", "disconnect"])
    }

    @Test func newerPortForwardingConnectIsNotDisconnectedByOlderCompletion() async {
        let probe = OverlappingPortForwardingLifecycleProbe()
        let lifecycle = HerdrSSHConnectionLifecycle(
            connect: { await probe.connect() },
            disconnect: { await probe.disconnect() }
        )

        lifecycle.connect()
        await probe.waitForConnects(1)
        lifecycle.connect()
        await probe.waitForConnects(2)

        await probe.release(2)
        await Task.yield()
        await probe.release(1)
        for _ in 0..<20 { await Task.yield() }

        #expect(await probe.disconnectCount == 0)
    }

    @Test func settingsSourcesExposeSafeHostKeyRecoveryAndIndependentTerminalButtons() throws {
        let forwarding = try sourceFile("UI/Settings/HostPortForwarding.swift")
        #expect(forwarding.contains("Trust new key & reconnect"))
        #expect(forwarding.contains("fingerprint"))
        #expect(forwarding.contains("interactiveDismissDisabled"))

        let terminal = try sourceFile("UI/Settings/TerminalPreferencesSection.swift")
        #expect(terminal.components(separatedBy: ".buttonStyle(.borderless)").count - 1 >= 2)
    }

    /// Port forwarding lives in EACH HOST's settings, not app settings: a tunnel
    /// is a property of one host, and the app-level version had to guess which
    /// host the user meant from whichever tab happened to be active.
    @Test func portForwardingIsReachableFromTheHostEditorAndNotAppSettings() throws {
        let editor = try sourceFile("UI/Hosts/HostEditView.swift")
        #expect(editor.contains("HerdrPortForwardingSheet"))
        #expect(editor.contains("host.port-forwarding.manage"))

        // Gone from app settings -- two entry points to one host-scoped feature
        // is how the "which host?" ambiguity comes back.
        let settings = try sourceFile("UI/Settings/MSAMSettingsView.swift")
        #expect(!settings.contains("HerdrPortForwardingSheet"))
        #expect(!settings.contains("HerdrSceneModel"))

        // The tunnel UI itself is presented by the sheet, not by whoever opens
        // it. Asserting this against the caller was satisfiable by a `//`
        // comment there, so the assertion could not fail.
        let forwarding = try sourceFile("UI/Settings/HostPortForwarding.swift")
        #expect(forwarding.contains("SessionWebTunnelSheet("))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private actor OverlappingPortForwardingLifecycleProbe {
    private var nextConnectID = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var disconnectCount = 0

    func connect() async {
        nextConnectID += 1
        let id = nextConnectID
        let ready = waiters.filter { nextConnectID >= $0.count }
        waiters.removeAll { nextConnectID >= $0.count }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuations[id] = $0 }
    }

    func waitForConnects(_ count: Int) async {
        if nextConnectID >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume()
    }

    func disconnect() {
        disconnectCount += 1
    }
}

private actor PortForwardingLifecycleProbe {
    private(set) var events: [String] = []
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var connectingWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async {
        events.append("connect")
        let waiters = connectingWaiters
        connectingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { connectContinuation = $0 }
    }

    func record(_ event: String) {
        events.append(event)
    }

    func waitUntilConnecting() async {
        if events.contains("connect") { return }
        await withCheckedContinuation { connectingWaiters.append($0) }
    }

    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }
}

/// Port forwarding moved from app settings to each host's own settings, where a
/// tunnel actually belongs. These pin the rule that decides when it is offerable.
@Suite struct HostPortForwardingAvailabilityTests {

    private func host(keyID: String = "key-1", address: String = "10.0.0.1") -> Host {
        Host(name: "server", address: address, port: 22,
             username: "alice", keyID: keyID, defaultWorkdir: "/home/alice")
    }

    @Test func aSavedHostWithAKeyCanForward() {
        #expect(HostPortForwardingAvailability.isOfferable(host: host(), isSaved: true))
    }

    @Test func anUnsavedDraftCannotForward() {
        // The sheet opens an authenticated SSH connection; a host the user is
        // still typing has nothing to connect to, and offering it would present
        // a sheet that can only fail.
        #expect(!HostPortForwardingAvailability.isOfferable(host: host(), isSaved: false))
    }

    @Test func aHostWithoutAKeyCannotForward() {
        #expect(!HostPortForwardingAvailability.isOfferable(host: host(keyID: ""), isSaved: true))
    }

    @Test func aHostThatFailsValidationCannotForward() {
        #expect(!HostPortForwardingAvailability.isOfferable(host: host(address: "  "), isSaved: true))
    }
}
