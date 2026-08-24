import Foundation
import Darwin
import Testing
@testable import MultiSessionAIManager

@Suite struct SessionWebTunnelDefinitionTests {

    @Test func definitionSupportsAnyTargetReachableFromTheSSHHost() {
        let tunnel = SessionWebTunnel.internalConsole

        #expect(tunnel.label == "Internal Console")
        #expect(tunnel.scheme == .https)
        #expect(tunnel.targetHost == "10.44.0.25")
        #expect(tunnel.targetPort == 9443)
        #expect(tunnel.validationError == nil)
    }

    @Test func loopbackURLUsesSchemeAndEphemeralListenerPort() {
        let tunnel = SessionWebTunnel(
            label: "Internal dashboard",
            scheme: .http,
            targetHost: "10.0.0.8",
            targetPort: 8080
        )

        #expect(tunnel.loopbackURL(localPort: 49152)?.absoluteString == "http://127.0.0.1:49152")
    }

    @Test func fixedLocalPortCreatesStableLoopbackAndSafariURLs() {
        let tunnel = SessionWebTunnel(
            label: "Security dashboard",
            scheme: .https,
            targetHost: "10.200.108.30",
            targetPort: 5602,
            localPort: 5602
        )

        #expect(tunnel.loopbackURL(localPort: 5602)?.absoluteString
                == "https://127.0.0.1:5602")
        #expect(tunnel.localhostURL(localPort: 5602)?.absoluteString
                == "https://localhost:5602")
    }

    @Test func validationRejectsMissingFieldsAndInvalidPorts() {
        #expect(SessionWebTunnel(label: "", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443).validationError
                == "Enter a label.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: " ", targetPort: 443).validationError
                == "Enter a target host.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 0).validationError
                == "Target port must be between 1 and 65535.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 65_536).validationError
                == "Target port must be between 1 and 65535.")
    }

    @Test func validationRejectsInvalidFixedLocalPort() {
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443,
                                localPort: 0).validationError
                == "Fixed local port must be between 1 and 65535.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443,
                                localPort: 65_536).validationError
                == "Fixed local port must be between 1 and 65535.")
    }

    @Test func hopRequiresUsernameHostAndValidPort() {
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443,
                                hop: .init(username: "", host: "jump", port: 22))
            .validationError == "Enter an SSH hop username.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443,
                                hop: .init(username: "root", host: " ", port: 22))
            .validationError == "Enter an SSH hop host.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443,
                                hop: .init(username: "root", host: "jump", port: 0))
            .validationError == "SSH hop port must be between 1 and 65535.")
        #expect(SessionWebTunnel(label: "Dashboard", scheme: .https,
                                targetHost: "10.0.0.8", targetPort: 443,
                                hop: nil).validationError == nil)
    }

    @Test func chainedTunnelPersistsHopWithoutSecretsAndExplainsCredentials() throws {
        let runtimeHopPassword = "secret-hop-pw"
        let tunnel = SessionWebTunnel(
            label: "Security dashboard",
            scheme: .https,
            targetHost: "10.200.108.30",
            targetPort: 5602,
            localPort: 5602,
            hop: .init(
                username: "root",
                host: "10.200.107.247",
                port: 22
            )
        )

        let data = try JSONEncoder().encode(tunnel)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(SessionWebTunnel.self, from: data)

        #expect(decoded.hop?.username == "root")
        #expect(decoded.hop?.host == "10.200.107.247")
        #expect(decoded.hop?.port == 22)
        #expect(!json.lowercased().contains("password"))
        #expect(!json.lowercased().contains("secret"))
        #expect(!json.contains(runtimeHopPassword))
        #expect(SessionWebTunnel.hopCredentialExplanation.contains(
            "key, SSH config, or agent available on the connected first host"
        ))
        #expect(SessionWebTunnel.hopCredentialExplanation.contains(
            "kept only while this SSH Web Tunnels sheet is open"
        ))
        #expect(SessionWebTunnel.hopCredentialExplanation.contains(
            "temporary SSH_ASKPASS helper on the connected first host"
        ))
        #expect(SessionWebTunnel.hopCredentialExplanation.contains(
            "removed after tunnel startup"
        ))
    }

    @Test func legacyTunnelDecodesWithAutomaticPortAndNoHop() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "label": "Legacy dashboard",
          "scheme": "https",
          "targetHost": "10.0.0.8",
          "targetPort": 443
        }
        """

        let tunnel = try JSONDecoder().decode(
            SessionWebTunnel.self,
            from: Data(json.utf8)
        )

        #expect(tunnel.localPort == nil)
        #expect(tunnel.hop == nil)
        #expect(tunnel.validationError == nil)
    }

    @Test func preparingNewTunnelStartImmediatelyForgetsPreviousPassword() {
        let previousID = UUID()
        let nextID = UUID()
        var passwords = [
            previousID: "previous-secret",
            nextID: "next-secret"
        ]

        let nextPassword = prepareHopPasswordForTunnelStart(
            passwords: &passwords,
            previousTunnelID: previousID,
            nextTunnelID: nextID
        )

        #expect(nextPassword == "next-secret")
        #expect(passwords[previousID] == nil)
        #expect(passwords[nextID] == "next-secret")
    }
}

@Suite struct TunnelCertificatePolicyTests {

    @Test func acceptsServerTrustOnlyForExactHTTPSLoopbackOrigin() {
        let url = URL(string: "https://127.0.0.1:49152")!
        let policy = TunnelCertificatePolicy(loopbackURL: url)

        #expect(policy.allows(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                              host: "127.0.0.1", port: 49152, hasServerTrust: true))
        #expect(!policy.allows(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                               host: "localhost", port: 49152, hasServerTrust: true))
        #expect(!policy.allows(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                               host: "127.0.0.1", port: 49153, hasServerTrust: true))
        #expect(!policy.allows(authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                               host: "127.0.0.1", port: 49152, hasServerTrust: true))
        #expect(!policy.allows(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                               host: "10.44.0.25", port: 9443, hasServerTrust: true))
        #expect(!policy.allows(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                               host: "127.0.0.1", port: 49152, hasServerTrust: false))
    }

    @Test func rejectsTrustOverrideForHTTP() {
        let policy = TunnelCertificatePolicy(
            loopbackURL: URL(string: "http://127.0.0.1:49152")!
        )

        #expect(!policy.allows(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                               host: "127.0.0.1", port: 49152, hasServerTrust: true))
    }
}

@Suite(.serialized)
struct NIOSessionWebTunnelServerTests {

    @Test func directModeOpensDirectTCPIPToFinalTarget() async throws {
        let (service, transport) = try await connectedSSHService()
        let server = NIOSessionWebTunnelServer(service: service)
        let tunnel = SessionWebTunnel(
            label: "Direct dashboard",
            scheme: .http,
            targetHost: "10.44.0.25",
            targetPort: 9443
        )
        let listener = try await server.start(tunnel: tunnel) { _ in }

        let socket = try connectLoopback(port: listener.localPort)
        try await waitUntil {
            !transport.openedDirectTCPIPTargets.isEmpty
        }

        #expect(transport.openedDirectTCPIPTargets == [
            .init(host: "10.44.0.25", port: 9443)
        ])

        Darwin.close(socket)
        await listener.stop()
    }

    @Test func jumpModeStartsRemoteForwardAndConnectsThroughFirstHostLoopback() async throws {
        let (service, transport) = try await connectedSSHService()
        transport.defaultCommandResponse =
            SessionWebTunnelRemoteForwardCommands.readyMarker
        let controlPath = "/tmp/ai-manager-web-tunnel-test.sock"
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: { controlPath }
        )
        let tunnel = SessionWebTunnel(
            label: "Chained dashboard",
            scheme: .https,
            targetHost: "10.200.108.30",
            targetPort: 5602,
            hop: .init(
                username: "root",
                host: "10.200.107.247",
                port: 22
            )
        )
        let listener = try await server.start(tunnel: tunnel) { _ in }

        let startCommand = try #require(transport.commandsRun.first)
        #expect(startCommand.contains("BatchMode=yes"))
        #expect(startCommand.contains("StrictHostKeyChecking=accept-new"))
        #expect(startCommand.contains("ExitOnForwardFailure=yes"))
        #expect(startCommand.contains("10.200.108.30"))
        #expect(startCommand.contains("5602"))
        #expect(startCommand.contains("root@10.200.107.247"))
        #expect(startCommand.contains(controlPath))

        let socket = try connectLoopback(port: listener.localPort)
        try await waitUntil {
            !transport.openedDirectTCPIPTargets.isEmpty
        }
        #expect(transport.openedDirectTCPIPTargets == [
            .init(host: "127.0.0.1", port: listener.localPort)
        ])

        Darwin.close(socket)
        await listener.stop()

        let stopCommand = try #require(transport.commandsRun.last)
        #expect(stopCommand.contains("-O"))
        #expect(stopCommand.contains("exit"))
        #expect(stopCommand.contains(controlPath))
    }

    @Test func passwordJumpModePassesRuntimePasswordToAskpassAndStillUsesFirstHostLoopback() async throws {
        let (service, transport) = try await connectedSSHService()
        transport.defaultCommandResponse =
            SessionWebTunnelRemoteForwardCommands.readyMarker
        let controlPath = "/tmp/ai-manager-password-tunnel-test.sock"
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: { controlPath }
        )
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
            scheme: .https,
            targetHost: "10.200.108.30",
            targetPort: 5602,
            hop: .init(username: "root", host: "10.200.107.247")
        )

        let listener = try await server.start(
            tunnel: tunnel,
            hopPassword: "secret-hop-pw"
        ) { _ in }

        let startCommand = try #require(transport.commandsRun.first)
        #expect(startCommand.contains("secret-hop-pw"))
        #expect(startCommand.contains("SSH_ASKPASS"))
        #expect(startCommand.contains("SSH_ASKPASS_REQUIRE"))
        #expect(startCommand.contains("force"))
        #expect(startCommand.contains("NumberOfPasswordPrompts=1"))
        #expect(startCommand.contains("BatchMode=no"))
        #expect(!startCommand.contains("BatchMode=yes"))

        let socket = try connectLoopback(port: listener.localPort)
        try await waitUntil {
            !transport.openedDirectTCPIPTargets.isEmpty
        }
        #expect(transport.openedDirectTCPIPTargets == [
            .init(host: "127.0.0.1", port: listener.localPort)
        ])

        Darwin.close(socket)
        await listener.stop()

        let stopCommand = try #require(transport.commandsRun.last)
        #expect(stopCommand.contains("\(controlPath).askpass"))
        #expect(stopCommand.contains("rm"))
    }

    @Test func occupiedFixedLocalPortHasUserReadableError() async throws {
        let (service, _) = try await connectedSSHService()
        let server = NIOSessionWebTunnelServer(service: service)
        let automatic = SessionWebTunnel(
            label: "First listener",
            scheme: .http,
            targetHost: "10.0.0.8",
            targetPort: 8080
        )
        let firstListener = try await server.start(tunnel: automatic) { _ in }
        let fixed = SessionWebTunnel(
            label: "Second listener",
            scheme: .http,
            targetHost: "10.0.0.8",
            targetPort: 8080,
            localPort: firstListener.localPort
        )

        do {
            _ = try await server.start(tunnel: fixed) { _ in }
            Issue.record("Expected the occupied fixed local port to fail")
        } catch {
            #expect(error.localizedDescription ==
                    "Local port \(firstListener.localPort) is already in use. "
                    + "Stop the other listener or choose Automatic.")
        }

        await firstListener.stop()
    }

    @Test func remoteForwardCommandsShellQuoteGeneratedValues() {
        let commands = SessionWebTunnelRemoteForwardCommands(
            hop: .init(username: "ro'ot", host: "jump';echo unsafe", port: 2222),
            targetHost: "target';echo unsafe",
            targetPort: 8443,
            remoteForwardPort: 49152,
            controlPath: "/tmp/control';echo unsafe"
        )

        #expect(commands.start.contains("'ro'\\''ot@jump'\\'';echo unsafe'"))
        #expect(commands.start.contains(
            "'127.0.0.1:49152:target'\\'';echo unsafe:8443'"
        ))
        #expect(commands.start.contains("'/tmp/control'\\'';echo unsafe'"))
        #expect(commands.stop.contains("'ro'\\''ot@jump'\\'';echo unsafe'"))
        #expect(commands.stop.contains("'/tmp/control'\\'';echo unsafe'"))
    }

    @Test func passwordRemoteForwardUsesTemporaryAskpassAndCleansItUp() {
        let commands = SessionWebTunnelRemoteForwardCommands(
            hop: .init(username: "root", host: "jump", port: 2222),
            targetHost: "target",
            targetPort: 8443,
            remoteForwardPort: 49152,
            controlPath: "/tmp/password-forward.sock",
            hopPassword: "secret-hop-pw'quoted"
        )

        #expect(commands.start.contains("SSH_ASKPASS"))
        #expect(commands.start.contains("SSH_ASKPASS_REQUIRE"))
        #expect(commands.start.contains("DISPLAY"))
        #expect(commands.start.contains("NumberOfPasswordPrompts=1"))
        #expect(commands.start.contains("BatchMode=no"))
        #expect(!commands.start.contains("BatchMode=yes"))
        #expect(commands.start.contains("secret-hop-pw"))
        #expect(!commands.start.contains("secret-hop-pw'quoted"))
        #expect(commands.start.contains("umask"))
        #expect(commands.start.contains("chmod"))
        #expect(commands.start.contains("trap"))
        #expect(commands.start.contains("rm"))
        #expect(commands.start.contains("'/tmp/password-forward.sock.askpass'"))
        #expect(commands.start.contains("'/tmp/password-forward.sock.cancel'"))
        #expect(commands.stop.contains("rm"))
        #expect(commands.stop.contains("'/tmp/password-forward.sock.askpass'"))
        #expect(commands.stop.contains("'/tmp/password-forward.sock.cancel'"))
        #expect(commands.cancel.contains(": > '/tmp/password-forward.sock.cancel'"))
        #expect(commands.cancel.contains("-O"))
        #expect(commands.cancel.contains("exit"))
        #expect(commands.cancel.contains("'/tmp/password-forward.sock.askpass'"))
    }

    @Test func noPasswordRemoteForwardKeepsNonInteractiveKeyAuthentication() {
        let commands = SessionWebTunnelRemoteForwardCommands(
            hop: .init(username: "root", host: "jump"),
            targetHost: "target",
            targetPort: 8443,
            remoteForwardPort: 49152,
            controlPath: "/tmp/key-forward.sock",
            hopPassword: nil
        )

        #expect(commands.start.contains("BatchMode=yes"))
        #expect(!commands.start.contains("BatchMode=no"))
        #expect(!commands.start.contains("SSH_ASKPASS"))
        #expect(!commands.start.contains("NumberOfPasswordPrompts"))
    }

    @Test func passwordRemoteForwardFailureRunsDefensiveAskpassCleanup() async throws {
        let (service, transport) = try await connectedSSHService()
        transport.defaultCommandResponse = "authentication failed"
        let controlPath = "/tmp/failed-password-forward.sock"
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: { controlPath }
        )
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
            scheme: .https,
            targetHost: "target",
            targetPort: 8443,
            hop: .init(username: "root", host: "jump")
        )

        do {
            _ = try await server.start(
                tunnel: tunnel,
                hopPassword: "secret-hop-pw"
            ) { _ in }
            Issue.record("Expected password hop startup to fail")
        } catch {
            #expect(error.localizedDescription.contains("Could not start SSH hop"))
        }

        #expect(transport.commandsRun.count == 2)
        let cleanupCommand = try #require(transport.commandsRun.last)
        #expect(cleanupCommand.contains("\(controlPath).askpass"))
        #expect(cleanupCommand.contains("rm"))
    }

    @Test func passwordRemoteForwardFailureDoesNotSurfaceHopPassword() async throws {
        let (service, transport) = try await connectedSSHService()
        let password = "secret-hop-pw"
        transport.commandError = NSError(
            domain: "SessionWebTunnelTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "transport failed while running askpass with \(password)"
            ]
        )
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: {
                "/tmp/redacted-password-forward.sock"
            }
        )
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
            scheme: .https,
            targetHost: "target",
            targetPort: 8443,
            hop: .init(username: "root", host: "jump")
        )

        do {
            _ = try await server.start(
                tunnel: tunnel,
                hopPassword: password
            ) { _ in }
            Issue.record("Expected password hop startup to fail")
        } catch {
            #expect(error.localizedDescription.contains("Could not start SSH hop"))
            #expect(!error.localizedDescription.contains(password))
        }
    }

    @MainActor
    @Test func stoppingPendingPasswordStartupRunsCleanupBeforeStartupReturns() async throws {
        let transport = BlockingWebTunnelSSHTransport()
        let host = Host(
            name: "first-hop",
            address: "192.0.2.24",
            port: 22,
            username: "operator",
            keyID: "test-key",
            defaultWorkdir: "/"
        )
        let defaults = try #require(UserDefaults(
            suiteName: "pending-web-tunnel-\(UUID().uuidString)"
        ))
        let service = SSHService(
            host: host,
            transport: transport,
            knownHosts: KnownHostsStore(defaults: defaults)
        )
        try await service.connect(
            key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))
        ) { _, _ in true }

        let controlPath = "/tmp/cancelled-password-forward.sock"
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: { controlPath }
        )
        let model = SessionWebTunnelModel(server: server)
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
            scheme: .https,
            targetHost: "target",
            targetPort: 8443,
            hop: .init(username: "root", host: "jump")
        )
        let startTask = Task {
            await model.start(tunnel, hopPassword: "secret-hop-pw")
        }

        await transport.waitUntilStartCommandEntered()
        await model.stop()

        for _ in 0..<25 {
            if transport.commandsRun.count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cleanupStarted = transport.commandsRun.count >= 2
        #expect(cleanupStarted)
        if cleanupStarted {
            let cleanupCommand = transport.commandsRun[1]
            #expect(cleanupCommand.contains("\(controlPath).askpass"))
            #expect(cleanupCommand.contains("\(controlPath).cancel"))
            #expect(cleanupCommand.contains("rm"))
        }
        #expect(model.status == .idle)

        await transport.allowStartCommandToReturn()
        await startTask.value
        #expect(model.status == .idle)
        #expect(transport.commandsRun.count == 2)
    }
}

@MainActor
@Suite struct SessionWebTunnelModelTests {

    @Test func startThenWebLoadReportsConnectingListeningAndOpen() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        let model = SessionWebTunnelModel(server: server)
        let startTask = Task { await model.start(.internalConsole) }

        await server.waitUntilStartEntered()
        #expect(model.status == .connecting)
        await server.allowStart()
        await startTask.value

        #expect(model.status == .listening(localPort: 49152))
        #expect(model.loopbackURL?.absoluteString == "https://127.0.0.1:49152")
        #expect(model.localhostURL?.absoluteString == "https://localhost:49152")

        model.webViewDidFinish()
        #expect(model.status == .open(localPort: 49152))

        await model.stop()
        #expect(model.status == .idle)
        #expect(server.listener.stopCallCount == 1)
    }

    @Test func listenerStartupFailureIsUserReadable() async {
        let server = FakeSessionWebTunnelServer(
            localPort: 49152,
            startError: SessionWebTunnelError.couldNotStart("Loopback port unavailable.")
        )
        await server.allowStart()
        let model = SessionWebTunnelModel(server: server)

        await model.start(.internalConsole)

        #expect(model.status == .failed(message: "Loopback port unavailable."))
        #expect(model.loopbackURL == nil)
    }

    @Test func sshTargetOpenFailureReplacesListeningStatus() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        await server.allowStart()
        let model = SessionWebTunnelModel(server: server)
        await model.start(.internalConsole)

        server.emitConnectionError("SSH host could not reach 10.44.0.25:9443.")
        await Task.yield()

        #expect(model.status == .failed(
            message: "SSH host could not reach 10.44.0.25:9443."
        ))
    }

    @Test func startPassesHopPasswordAsRuntimeOnlyServerInput() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        await server.allowStart()
        let model = SessionWebTunnelModel(server: server)

        await model.start(.internalConsole, hopPassword: "secret-hop-pw")

        #expect(server.lastHopPassword == "secret-hop-pw")
    }

    @Test func stopWhileStartupIsPendingStopsLateListenerAndRemainsIdle() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        let model = SessionWebTunnelModel(server: server)
        let startTask = Task {
            await model.start(
                .internalConsole,
                hopPassword: "secret-hop-pw"
            )
        }

        await server.waitUntilStartEntered()
        #expect(model.status == .connecting)

        await model.stop()
        #expect(model.status == .idle)

        await server.allowStart()
        await startTask.value

        #expect(model.status == .idle)
        #expect(model.activeTunnel == nil)
        #expect(model.loopbackURL == nil)
        #expect(model.localhostURL == nil)
        #expect(server.listener.stopCallCount == 1)
    }
}

private func connectedSSHService() async throws -> (SSHService, FakeSSHTransport) {
    let transport = FakeSSHTransport()
    let host = Host(
        name: "first-hop",
        address: "192.0.2.24",
        port: 22,
        username: "operator",
        keyID: "test-key",
        defaultWorkdir: "/"
    )
    let suite = "session-web-tunnel-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let service = SSHService(
        host: host,
        transport: transport,
        knownHosts: KnownHostsStore(defaults: defaults)
    )
    try await service.connect(
        key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))
    ) { _, _ in true }
    return (service, transport)
}

private final class BlockingWebTunnelSSHTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let startGate = StartGate()
    private var connected = false
    private var recordedCommands: [String] = []

    var commandsRun: [String] {
        lock.withLock { recordedCommands }
    }

    func connect(
        host: Host,
        key: SSHKeyMaterial,
        hostKeyValidator: @escaping @Sendable (String) -> Bool
    ) async throws {
        guard hostKeyValidator("AAAAFAKEFINGERPRINTBASE64NOPAD") else {
            throw SSHTransportError.hostKeyRejected
        }
        lock.withLock { connected = true }
    }

    func runCommand(_ cmd: String) async throws -> String {
        guard lock.withLock({ connected }) else {
            throw SSHTransportError.notConnected
        }
        lock.withLock { recordedCommands.append(cmd) }
        if cmd.contains(SessionWebTunnelRemoteForwardCommands.readyMarker) {
            await startGate.enterAndWait()
            return SessionWebTunnelRemoteForwardCommands.readyMarker
        }
        return ""
    }

    func openPTY(
        command: String,
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> PTYChannel {
        throw SSHTransportError.commandFailed("not implemented")
    }

    func disconnect() async {
        lock.withLock { connected = false }
    }

    func waitUntilStartCommandEntered() async {
        await startGate.waitUntilEntered()
    }

    func allowStartCommandToReturn() async {
        await startGate.allow()
    }
}

private func connectLoopback(port: Int) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(.ENOTSOCK)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        Darwin.close(descriptor)
        throw POSIXError(.EINVAL)
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard result == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
        Darwin.close(descriptor)
        throw POSIXError(code)
    }
    return descriptor
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ condition: () -> Bool
) async throws {
    let interval: UInt64 = 10_000_000
    var waited: UInt64 = 0
    while !condition() {
        guard waited < timeoutNanoseconds else {
            throw POSIXError(.ETIMEDOUT)
        }
        try await Task.sleep(nanoseconds: interval)
        waited += interval
    }
}

private extension SessionWebTunnel {
    static let internalConsole = SessionWebTunnel(
        label: "Internal Console",
        scheme: .https,
        targetHost: "10.44.0.25",
        targetPort: 9443
    )
}

private final class FakeSessionWebTunnelListener: SessionWebTunnelListener, @unchecked Sendable {
    let localPort: Int
    private let lock = NSLock()
    private var _stopCallCount = 0

    init(localPort: Int) {
        self.localPort = localPort
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCallCount
    }

    func stop() async {
        lock.withLock { _stopCallCount += 1 }
    }
}

private final class FakeSessionWebTunnelServer: SessionWebTunnelServing, @unchecked Sendable {
    let listener: FakeSessionWebTunnelListener
    private let startError: Error?
    private let startGate = StartGate()
    private let lock = NSLock()
    private var onConnectionError: (@Sendable (String) -> Void)?
    private var _lastHopPassword: String?

    init(localPort: Int, startError: Error? = nil) {
        listener = FakeSessionWebTunnelListener(localPort: localPort)
        self.startError = startError
    }

    func start(
        tunnel: SessionWebTunnel,
        hopPassword: String?,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws -> any SessionWebTunnelListener {
        lock.withLock {
            self.onConnectionError = onConnectionError
            _lastHopPassword = hopPassword
        }
        await startGate.enterAndWait()

        if let startError { throw startError }
        return listener
    }

    func waitUntilStartEntered() async {
        await startGate.waitUntilEntered()
    }

    func allowStart() async {
        await startGate.allow()
    }

    func emitConnectionError(_ message: String) {
        let callback = lock.withLock { onConnectionError }
        callback?(message)
    }

    var lastHopPassword: String? {
        lock.withLock { _lastHopPassword }
    }
}

private actor StartGate {
    private var entered = false
    private var allowed = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !allowed else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func allow() {
        allowed = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
