import Foundation
import Darwin
import NIOConcurrencyHelpers
import Testing
@testable import MultiSessionAIManager

@Suite struct SessionWebTunnelDefinitionTests {

    @Test func definitionSupportsAnyTargetReachableFromTheSSHHost() {
        let tunnel = SessionWebTunnel.internalConsole

        #expect(tunnel.label == "Internal Console")
        #expect(tunnel.targetHost == "10.44.0.25")
        #expect(tunnel.targetPort == 9443)
        #expect(tunnel.validationError == nil)
    }

    @Test func aTargetIsWrittenAsHostAndPortWithoutDigitGrouping() {
        let tunnel = SessionWebTunnel(label: "Grafana", targetHost: "10.0.0.8", targetPort: 13000)
        #expect(tunnel.targetAddress == "10.0.0.8:13000")
    }

    @Test func aPlainWebServiceOpensOverHTTPOnTheListenersPort() {
        let address = TunnelWebAddress(localPort: 49152, secure: false)
        #expect(address?.loopbackURL.absoluteString == "http://127.0.0.1:49152")
        #expect(address?.localhostURL.absoluteString == "http://localhost:49152")
    }

    @Test func aTLSServiceOpensOverHTTPSOnTheListenersPort() {
        let address = TunnelWebAddress(localPort: 5602, secure: true)
        #expect(address?.loopbackURL.absoluteString == "https://127.0.0.1:5602")
        #expect(address?.localhostURL.absoluteString == "https://localhost:5602")
    }

    @Test func thereIsNoWebAddressForAnImpossiblePort() {
        #expect(TunnelWebAddress(localPort: 0, secure: false) == nil)
        #expect(TunnelWebAddress(localPort: 70_000, secure: true) == nil)
    }

    @Test func validationRejectsMissingFieldsAndInvalidPorts() {
        #expect(SessionWebTunnel(label: "", targetHost: "10.0.0.8", targetPort: 443).validationError
                == "Enter a label.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: " ", targetPort: 443).validationError
                == "Enter a target host.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 0).validationError
                == "Target port must be between 1 and 65535.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 65_536).validationError
                == "Target port must be between 1 and 65535.")
    }

    @Test func validationRejectsInvalidFixedLocalPort() {
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 443,
                                localPort: 0).validationError
                == "Fixed local port must be between 1 and 65535.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 443,
                                localPort: 65_536).validationError
                == "Fixed local port must be between 1 and 65535.")
    }

    @Test func hopRequiresUsernameHostAndValidPort() {
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 443,
                                hop: .init(username: "", host: "jump", port: 22))
            .validationError == "Enter an SSH hop username.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 443,
                                hop: .init(username: "root", host: " ", port: 22))
            .validationError == "Enter an SSH hop host.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 443,
                                hop: .init(username: "root", host: "jump", port: 0))
            .validationError == "SSH hop port must be between 1 and 65535.")
        #expect(SessionWebTunnel(label: "Dashboard", targetHost: "10.0.0.8", targetPort: 443,
                                hop: nil).validationError == nil)
    }

    @Test func chainedTunnelPersistsHopWithoutSecretsAndExplainsCredentials() throws {
        let runtimeHopPassword = "secret-hop-pw"
        let tunnel = SessionWebTunnel(
            label: "Security dashboard",
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
            "kept only in memory while AI Manager is running"
        ))
        #expect(SessionWebTunnel.hopCredentialExplanation.contains(
            "never saved"
        ))
        #expect(SessionWebTunnel.hopCredentialExplanation.contains(
            "reused when you restart this tunnel"
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

    @Test(arguments: ["https", "http", "vnc"])
    func aTunnelSavedWithASchemeByAnOlderBuildStillLoads(scheme: String) throws {
        let json = """
        [{"id": "\(UUID().uuidString)", "label": "Studio desktop", "scheme": "\(scheme)",
          "targetHost": "192.168.50.10", "targetPort": 5901, "localPort": 5901}]
        """
        let tunnels = try JSONDecoder().decode([SessionWebTunnel].self, from: Data(json.utf8))
        #expect(tunnels.map(\.label) == ["Studio desktop"])
        #expect(tunnels[0].targetPort == 5901)
        #expect(tunnels[0].localPort == 5901)
        #expect(tunnels[0].validationError == nil)
    }

    @Test func aTunnelIsSavedWithoutAScheme() throws {
        let tunnel = SessionWebTunnel(label: "RDP", targetHost: "127.0.0.1", targetPort: 3391, localPort: 13389)
        let data = try JSONEncoder().encode(tunnel)
        #expect(try JSONDecoder().decode(SessionWebTunnel.self, from: data) == tunnel)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("scheme"))
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
            remoteForwardControlPath: { _ in controlPath },
            remoteForwardPort: { 28_443 }
        )
        let tunnel = SessionWebTunnel(
            label: "Chained dashboard",
            targetHost: "10.200.108.30",
            targetPort: 5602,
            hop: .init(
                username: "root",
                host: "10.200.107.247",
                port: 22
            )
        )
        let listener = try await server.start(tunnel: tunnel) { _ in }

        let startCommand = try #require(transport.commandsRun.last)
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
            .init(host: "127.0.0.1", port: 28_443)
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
            remoteForwardControlPath: { _ in controlPath },
            remoteForwardPort: { 28_443 }
        )
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
            targetHost: "10.200.108.30",
            targetPort: 5602,
            hop: .init(username: "root", host: "10.200.107.247")
        )

        let listener = try await server.start(
            tunnel: tunnel,
            hopPassword: "secret-hop-pw"
        ) { _ in }

        let startCommand = try #require(transport.commandsRun.last)
        #expect(startCommand.contains("secret-hop-pw"))
        #expect(startCommand.contains("SSH_ASKPASS"))
        #expect(startCommand.contains("SSH_ASKPASS_REQUIRE"))
        #expect(startCommand.contains("force"))
        #expect(startCommand.contains("NumberOfPasswordPrompts=1"))
        #expect(startCommand.contains("BatchMode=no"))
        #expect(!startCommand.contains("BatchMode=yes"))
        // Password mode must offer the password before the first host's keys
        // can burn the hop's MaxAuthTries.
        #expect(startCommand.contains("PreferredAuthentications=password"))
        #expect(startCommand.contains("PubkeyAuthentication=no"))
        #expect(!startCommand.contains("PreferredAuthentications=publickey"))

        let socket = try connectLoopback(port: listener.localPort)
        try await waitUntil {
            !transport.openedDirectTCPIPTargets.isEmpty
        }
        #expect(transport.openedDirectTCPIPTargets == [
            .init(host: "127.0.0.1", port: 28_443)
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
            targetHost: "10.0.0.8",
            targetPort: 8080
        )
        let firstListener = try await server.start(tunnel: automatic) { _ in }
        let fixed = SessionWebTunnel(
            label: "Second listener",
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

    @Test func aListenerDroppedWithoutBeingStoppedGivesItsPortBack() async throws {
        // What an abandoned session does: it lets go of the listener and never
        // calls stop(). The port must come back, or the next Start fails with
        // "already in use" until the app is quit.
        let (service, _) = try await connectedSSHService()
        let server = NIOSessionWebTunnelServer(service: service)
        var forgotten: (any SessionWebTunnelListener)? = try await server.start(
            tunnel: SessionWebTunnel(label: "Forgotten", targetHost: "10.0.0.8", targetPort: 8080)
        ) { _ in }
        let port = try #require(forgotten?.localPort)
        forgotten = nil

        let again = SessionWebTunnel(label: "Same port", targetHost: "10.0.0.8", targetPort: 8080, localPort: port)
        var restarted: (any SessionWebTunnelListener)?
        for _ in 0..<50 {
            // The close is handed to the event loop, so it lands a moment later.
            restarted = try? await server.start(tunnel: again) { _ in }
            if restarted != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(restarted?.localPort == port)
        await restarted?.stop()
    }

    @Test func theHopLegSendsItsOwnKeepAlives() {
        // The leg from the first host to the hop idles too. Without keep-alives a
        // firewall between them drops it silently and the forward goes dead.
        for password in [nil, "secret"] as [String?] {
            let commands = SessionWebTunnelRemoteForwardCommands(
                tunnelID: UUID(),
                hop: .init(username: "root", host: "jump"), targetHost: "target", targetPort: 3389,
                remoteForwardPort: 13389, controlPath: "/tmp/keepalive.sock", hopPassword: password)
            #expect(commands.start.contains("-o 'ServerAliveInterval=30'"))
            #expect(commands.start.contains("-o 'ServerAliveCountMax=3'"))
        }
    }

    @Test func remoteForwardCommandsShellQuoteGeneratedValues() {
        let commands = SessionWebTunnelRemoteForwardCommands(
            tunnelID: UUID(),
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
            tunnelID: UUID(),
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
            tunnelID: UUID(),
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
        let connectedCommandCount = transport.commandsRun.count
        transport.defaultCommandResponse = "authentication failed"
        let controlPath = "/tmp/failed-password-forward.sock"
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: { _ in controlPath }
        )
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
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

        #expect(transport.commandsRun.count == connectedCommandCount + 2)
        let cleanupCommand = try #require(transport.commandsRun.last)
        #expect(cleanupCommand.contains("\(controlPath).askpass"))
        #expect(cleanupCommand.contains("rm"))
    }

    @Test func tunnelStartWithoutHostConnectionBlamesConnectionNotHopPassword() async throws {
        // A never-connected transport throws SSHTransportError.notConnected.
        // The user must be told the host connection is missing — not that the
        // (perfectly correct) hop password is wrong.
        let transport = FakeSSHTransport()
        let host = Host(
            name: "first-hop", address: "192.0.2.24", port: 22,
            username: "operator", keyID: "test-key", defaultWorkdir: "/"
        )
        let suite = "session-web-tunnel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let service = SSHService(
            host: host, transport: transport,
            knownHosts: KnownHostsStore(defaults: defaults)
        )
        let server = NIOSessionWebTunnelServer(service: service)
        let tunnel = SessionWebTunnel(
            label: "Dead connection", targetHost: "target", targetPort: 8443,
            hop: .init(username: "root", host: "jump")
        )

        do {
            _ = try await server.start(tunnel: tunnel, hopPassword: "correct-password") { _ in }
            Issue.record("Expected startup over a dead connection to fail")
        } catch {
            #expect(error.localizedDescription.contains("first host is not established"))
            #expect(!error.localizedDescription.contains("Verify the SSH password"))
        }
    }

    @Test func aLinkThatDiesUnderAStartIsNotBlamedOnTheHop() async throws {
        // The command never reached the first host, so ssh said nothing about the
        // hop. "Verify that the first host has a usable key" sent the reader after
        // a key that was fine.
        let (service, transport) = try await connectedSSHService()
        transport.commandError = SSHTransportError.commandFailed(
            "remote command failed: NIOSSHError.creatingChannelAfterClosure")
        let server = NIOSessionWebTunnelServer(service: service)

        do {
            _ = try await server.start(tunnel: qasProxy()) { _ in }
            Issue.record("Expected the start to fail")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("connection to the first host"), "\(message)")
            #expect(!message.contains("usable key"), "\(message)")
            #expect(!message.contains("error 0"), "\(message)")
        }
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
            remoteForwardControlPath: { _ in
                "/tmp/redacted-password-forward.sock"
            }
        )
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
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

        let connectedCommandCount = transport.commandsRun.count
        let controlPath = "/tmp/cancelled-password-forward.sock"
        let server = NIOSessionWebTunnelServer(
            service: service,
            remoteForwardControlPath: { _ in controlPath }
        )
        let model = SessionWebTunnelModel(server: server)
        let tunnel = SessionWebTunnel(
            label: "Password dashboard",
            targetHost: "target",
            targetPort: 8443,
            hop: .init(username: "root", host: "jump")
        )
        let startTask = Task {
            await model.start(tunnel, hopPassword: "secret-hop-pw")
        }

        await transport.waitUntilStartCommandEntered()
        await model.stop(tunnel.id)

        for _ in 0..<25 {
            if transport.commandsRun.count >= connectedCommandCount + 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cleanupStarted = transport.commandsRun.count >= connectedCommandCount + 2
        #expect(cleanupStarted)
        if cleanupStarted {
            let cleanupCommand = transport.commandsRun[connectedCommandCount + 1]
            #expect(cleanupCommand.contains("\(controlPath).askpass"))
            #expect(cleanupCommand.contains("\(controlPath).cancel"))
            #expect(cleanupCommand.contains("rm"))
        }
        #expect(model.status(for: tunnel.id) == .idle)

        await transport.allowStartCommandToReturn()
        await startTask.value
        #expect(model.status(for: tunnel.id) == .idle)
        #expect(transport.commandsRun.count == connectedCommandCount + 2)
    }

    // MARK: - A helper left behind on the first host

    /// What ssh says, on the first host, when the helper's port is taken there.
    private static let portTaken = """
        bind [127.0.0.1]:18443: Address already in use\r
        channel_setup_fwd_listener_tcpip: cannot listen to port: 18443\r
        Could not request local forwarding.\r
        ssh exited with status 255
        """

    private func qasProxy() -> SessionWebTunnel {
        SessionWebTunnel(label: "QAS Proxy", targetHost: "10.200.109.26", targetPort: 8443,
                         hop: .init(username: "root", host: "10.200.107.247"))
    }

    @Test func theHopHelperListensOnAPortOfTheFirstHostNotOnThisDevicesPort() async throws {
        // The forward's port on this device was also asked for on the first host.
        // A helper that an earlier run of the app left behind still held it there,
        // and every Start failed with "bind [127.0.0.1]:18443: Address already in use".
        let (service, transport) = try await connectedSSHService()
        transport.defaultCommandResponse = SessionWebTunnelRemoteForwardCommands.readyMarker
        let server = NIOSessionWebTunnelServer(service: service, remoteForwardPort: { 28_443 })

        let listener = try await server.start(tunnel: qasProxy()) { _ in }

        let start = try #require(transport.commandsRun.last)
        #expect(start.contains("127.0.0.1:28443:10.200.109.26:8443"))
        #expect(!start.contains("127.0.0.1:\(listener.localPort):"))
        let socket = try connectLoopback(port: listener.localPort)
        try await waitUntil { !transport.openedDirectTCPIPTargets.isEmpty }
        #expect(transport.openedDirectTCPIPTargets == [.init(host: "127.0.0.1", port: 28_443)])
        Darwin.close(socket)
        await listener.stop()
    }

    @Test func aHelperPortThatIsTakenOnTheFirstHostIsReplacedByAnother() async throws {
        let (service, transport) = try await connectedSSHService()
        let ports = NIOLockedValueBox([28_443, 28_444, 28_445])
        transport.beforeCommand = { [unowned transport] command in
            transport.defaultCommandResponse = command.contains("127.0.0.1:28443:")
                ? Self.portTaken : SessionWebTunnelRemoteForwardCommands.readyMarker
        }
        let server = NIOSessionWebTunnelServer(
            service: service, remoteForwardPort: { ports.withLockedValue { $0.removeFirst() } })

        let listener = try await server.start(tunnel: qasProxy()) { _ in }

        let starts = transport.commandsRun.filter { $0.contains(" -L ") }
        #expect(starts.count == 2)
        #expect(starts.last?.contains("127.0.0.1:28444:10.200.109.26:8443") == true)
        let socket = try connectLoopback(port: listener.localPort)
        try await waitUntil { !transport.openedDirectTCPIPTargets.isEmpty }
        #expect(transport.openedDirectTCPIPTargets == [.init(host: "127.0.0.1", port: 28_444)])
        Darwin.close(socket)
        await listener.stop()
    }

    @Test func whenEveryHelperPortIsTakenTheUserReadsWhatSshSaid() async throws {
        let (service, transport) = try await connectedSSHService()
        transport.defaultCommandResponse = Self.portTaken
        let ports = NIOLockedValueBox([28_443, 28_444, 28_445, 28_446])
        let server = NIOSessionWebTunnelServer(
            service: service, remoteForwardPort: { ports.withLockedValue { $0.removeFirst() } })
        let forward = qasProxy()

        await #expect {
            _ = try await server.start(tunnel: forward) { _ in }
        } throws: { error in
            "\(error.localizedDescription)".contains("Address already in use")
        }
        // No more attempts than that, and a different port each time.
        #expect(transport.commandsRun.filter { $0.contains(" -L ") }.count == 3)
        #expect(ports.withLockedValue { $0 } == [28_446])
    }

    @Test func aFailureThatIsNotAboutThePortIsNotRetried() async throws {
        let (service, transport) = try await connectedSSHService()
        transport.defaultCommandResponse =
            "root@10.200.107.247: Permission denied (publickey,password).\r\nssh exited with status 255"
        let server = NIOSessionWebTunnelServer(service: service, remoteForwardPort: { 28_443 })
        let forward = qasProxy()

        await #expect(throws: SessionWebTunnelError.self) {
            _ = try await server.start(tunnel: forward) { _ in }
        }
        #expect(transport.commandsRun.filter { $0.contains(" -L ") }.count == 1)
    }

    /// The helper commands for the QAS proxy forward, with a known forward id.
    private func qasCommands(_ forward: UUID) -> SessionWebTunnelRemoteForwardCommands {
        SessionWebTunnelRemoteForwardCommands(
            tunnelID: forward, hop: .init(username: "root", host: "10.200.107.247"),
            targetHost: "10.200.109.26", targetPort: 8443, remoteForwardPort: 28_443,
            controlPath: SessionWebTunnelRemoteForwardCommands.controlPath(for: forward))
    }

    @Test func startingFirstRemovesTheHelpersLeftBehindForTheSameForward() throws {
        let forward = try #require(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        let commands = qasCommands(forward)

        #expect(commands.leftBehindPatterns == [
            // Of this forward, whichever start of it left them.
            "-M -S /tmp/ai-manager-web-tunnel-3f2504e04f89-[0-9a-f]+[.]sock -f -N ",
            // Of this forward as older builds started it: no forward in the
            // control path, so it is known by where it goes.
            "-M -S /tmp/ai-manager-web-tunnel-[0-9A-F-]{36}[.]sock -f -N -p [0-9]+ "
                + "-L 127[.]0[.]0[.]1:[0-9]+:10[.]200[.]109[.]26:8443 root@10[.]200[.]107[.]247$",
        ])
        // Each is handed to pkill, for this user's processes only, before the
        // new helper is started: after it, the new helper would go with them.
        let launch = try #require(commands.start.range(of: " -M -S '"))
        for pattern in commands.leftBehindPatterns {
            let sweep = try #require(commands.start.range(of: #"pkill -u "$(id -u)" -f -- '\#(pattern)'"#))
            #expect(sweep.upperBound < launch.lowerBound)
        }
        // Stopping a forward stops its own helper and no other.
        #expect(!commands.stop.contains("pkill"))
        #expect(!commands.cancel.contains("pkill"))
    }

    @Test func theSweepMatchesHelpersAndNothingThatOnlyMentionsOne() throws {
        let forward = UUID()
        let commands = qasCommands(forward)
        let tag = SessionWebTunnelRemoteForwardCommands.tag(for: forward)
        let patterns = try commands.leftBehindPatterns.map { try Regex($0) }
        func matched(_ commandLine: String) -> Bool { patterns.contains { commandLine.firstMatch(of: $0) != nil } }
        let options = "ssh -o BatchMode=yes -o ExitOnForwardFailure=yes"

        // An earlier start of this forward, and one from a build before this one.
        #expect(matched("\(options) -M -S /tmp/ai-manager-web-tunnel-\(tag)-0a1b2c3d.sock -f -N -p 22 -L 127.0.0.1:28443:10.200.109.26:8443 root@10.200.107.247"))
        #expect(matched("\(options) -M -S /tmp/ai-manager-web-tunnel-3F2504E0-4F89-11D3-9A0C-0305E82C3301.sock -f -N -p 22 -L 127.0.0.1:18443:10.200.109.26:8443 root@10.200.107.247"))

        // pkill -f reads whole command lines, and the shell that runs the start
        // command has the patterns in its own. Matching it would kill the start.
        #expect(!matched(commands.start))
        // Another forward of the same user: to another target, or with another id.
        #expect(!matched("\(options) -M -S /tmp/ai-manager-web-tunnel-3F2504E0-4F89-11D3-9A0C-0305E82C3301.sock -f -N -p 22 -L 127.0.0.1:13389:10.200.109.26:3389 root@10.200.107.247"))
        #expect(!matched("\(options) -M -S /tmp/ai-manager-web-tunnel-aaaaaaaaaaaa-0a1b2c3d.sock -f -N -p 22 -L 127.0.0.1:28443:10.200.109.26:8443 root@10.200.107.247"))
        // The command that tells a helper to exit, and a user looking at its socket.
        #expect(!matched("ssh -S /tmp/ai-manager-web-tunnel-\(tag)-0a1b2c3d.sock -p 22 -O exit root@10.200.107.247"))
        #expect(!matched("ls -l /tmp/ai-manager-web-tunnel-\(tag)-0a1b2c3d.sock"))
    }

    @Test func aHelpersControlPathNamesItsForwardAndFitsASocketPath() throws {
        let forward = try #require(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        let first = SessionWebTunnelRemoteForwardCommands.controlPath(for: forward)
        let second = SessionWebTunnelRemoteForwardCommands.controlPath(for: forward)

        #expect(first.hasPrefix("/tmp/ai-manager-web-tunnel-3f2504e04f89-"))
        #expect(first.hasSuffix(".sock"))
        #expect(first != second, "Each start has a socket of its own")
        // ssh appends 17 characters while it creates the socket, and macOS allows 103.
        #expect(first.count + 17 <= 103)
    }

    @Test func aTargetWithRegexCharactersCannotWidenTheSweep() {
        let commands = SessionWebTunnelRemoteForwardCommands(
            tunnelID: UUID(), hop: .init(username: "root", host: "jump.*"),
            targetHost: "target|sshd", targetPort: 8443, remoteForwardPort: 28_443,
            controlPath: "/tmp/x.sock")

        // Each character that means something to a regular expression is made
        // literal, so the pattern can match no process but the one it names.
        #expect(commands.start.contains(":target[|]sshd:8443 root@jump[.][*]$'"))
    }
}

@MainActor
@Suite struct SessionWebTunnelModelTests {
    private func tunnel(_ label: String, port: Int = 8080) -> SessionWebTunnel {
        SessionWebTunnel(label: label, targetHost: "10.0.0.8", targetPort: port)
    }

    private func openServer(localPort: Int = 49152) async -> FakeSessionWebTunnelServer {
        let server = FakeSessionWebTunnelServer(localPort: localPort)
        await server.allowStart()
        return server
    }

    @Test func startingReportsConnectingThenTheListeningPort() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        let model = SessionWebTunnelModel(server: server)
        let console = SessionWebTunnel.internalConsole
        #expect(model.status(for: console.id) == .idle)
        let startTask = Task { await model.start(console) }

        await server.waitUntilStartEntered()
        #expect(model.status(for: console.id) == .connecting)
        #expect(model.runningCount == 1, "A tunnel mid-start already counts as running")
        await server.allowStart()
        await startTask.value

        #expect(model.status(for: console.id) == .listening(localPort: 49152))
        #expect(model.running == [console])

        await model.stop(console.id)
        #expect(model.status(for: console.id) == .idle)
        #expect(model.running.isEmpty)
        #expect(server.listener(for: console.id)?.stopCallCount == 1)
    }

    @Test func severalTunnelsRunAtOnceEachOnItsOwnPort() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let rdp = tunnel("RDP", port: 3391), other = tunnel("Other", port: 2229)

        await model.start(rdp)
        await model.start(other)

        #expect(model.status(for: rdp.id) == .listening(localPort: 49152))
        #expect(model.status(for: other.id) == .listening(localPort: 49153))
        #expect(model.running == [rdp, other])
        #expect(model.runningCount == 2)
        #expect(server.listener(for: rdp.id)?.stopCallCount == 0, "Starting a second tunnel must not stop the first")
    }

    @Test func stoppingOneTunnelLeavesTheOthersRunning() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let rdp = tunnel("RDP"), other = tunnel("Other")
        await model.start(rdp)
        await model.start(other)

        await model.stop(rdp.id)

        #expect(model.status(for: rdp.id) == .idle)
        #expect(model.status(for: other.id) == .listening(localPort: 49153))
        #expect(model.running == [other])
        #expect(server.listener(for: rdp.id)?.stopCallCount == 1)
        #expect(server.listener(for: other.id)?.stopCallCount == 0)
    }

    @Test func aSixthTunnelIsRefusedUntilOneIsStopped() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let five = (1...5).map { tunnel("Forward \($0)") }
        for forward in five { await model.start(forward) }
        #expect(model.runningCount == 5)
        #expect(!model.canStartAnother)

        let sixth = tunnel("Forward 6")
        await model.start(sixth)

        #expect(model.status(for: sixth.id) == .failed(
            message: "5 forwards are already running. Stop one to start another."))
        #expect(model.runningCount == 5)
        #expect(!server.startedTunnelIDs.contains(sixth.id), "A refused tunnel never reaches the host")

        await model.stop(five[0].id)
        #expect(model.canStartAnother)
        await model.start(sixth)
        #expect(model.status(for: sixth.id) == .listening(localPort: 49157))
    }

    @Test func aTunnelThatFailsToStartDoesNotDisturbARunningOne() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let good = tunnel("Good"), bad = tunnel("Bad")
        server.failStart(of: bad.id, with: SessionWebTunnelError.couldNotStart("Loopback port unavailable."))
        await model.start(good)

        await model.start(bad)

        #expect(model.status(for: bad.id) == .failed(message: "Loopback port unavailable."))
        #expect(model.status(for: good.id) == .listening(localPort: 49152))
        #expect(model.running == [good], "A failed start holds no port and takes no slot")
    }

    @Test func aDefinitionThatIsNotValidFailsWithoutAskingTheHost() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let broken = SessionWebTunnel(label: "Broken", targetHost: "10.0.0.8", targetPort: 0)

        await model.start(broken)

        #expect(model.status(for: broken.id) == .failed(message: "Target port must be between 1 and 65535."))
        #expect(server.startedTunnelIDs.isEmpty)
    }

    @Test func aTargetThatCannotBeReachedKeepsTheListenerUpAndSaysWhy() async {
        // The listener still holds its port, and the service may come up later: the
        // tunnel stays in the running list with the reason beside it.
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let console = SessionWebTunnel.internalConsole, other = tunnel("Other")
        await model.start(console)
        await model.start(other)
        #expect(model.connectionProblem(for: console.id) == nil)

        server.emitConnectionError("SSH host could not reach 10.44.0.25:9443.", for: console.id)
        await Task.yield()

        #expect(model.status(for: console.id) == .listening(localPort: 49152))
        #expect(model.connectionProblem(for: console.id) == "SSH host could not reach 10.44.0.25:9443.")
        #expect(model.connectionProblem(for: other.id) == nil)

        await model.start(console)
        #expect(model.connectionProblem(for: console.id) == nil, "A restart begins with a clean slate")
    }

    @Test func startPassesHopPasswordAsRuntimeOnlyServerInput() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)

        await model.start(.internalConsole, hopPassword: "secret-hop-pw")

        #expect(server.lastHopPassword == "secret-hop-pw")
    }

    @Test func stopWhileStartupIsPendingStopsLateListenerAndRemainsIdle() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        let model = SessionWebTunnelModel(server: server)
        let console = SessionWebTunnel.internalConsole
        let startTask = Task { await model.start(console, hopPassword: "secret-hop-pw") }

        await server.waitUntilStartEntered()
        #expect(model.status(for: console.id) == .connecting)

        await model.stop(console.id)
        #expect(model.status(for: console.id) == .idle)

        await server.allowStart()
        await startTask.value

        #expect(model.status(for: console.id) == .idle)
        #expect(model.running.isEmpty)
        #expect(server.listener(for: console.id)?.stopCallCount == 1)
    }

    @Test func startingARunningTunnelAgainReplacesItsListener() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let console = SessionWebTunnel.internalConsole
        await model.start(console)

        await model.start(console)

        #expect(server.listeners(for: console.id).map(\.stopCallCount) == [1, 0])
        #expect(model.status(for: console.id) == .listening(localPort: 49153))
        #expect(model.runningCount == 1)
    }

    @Test func aForwardShowsAsStartingWhileItsLinkIsMadeReady() async {
        // Checking a link that stopped answering takes seconds. A forward that
        // looked idle meanwhile would invite a second Start.
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let link = LinkCheck()
        model.beforeStart = { await link.run() }
        let console = SessionWebTunnel.internalConsole
        let startTask = Task { await model.start(console) }

        #expect(await link.wasAskedFor(), "Every start first makes its link ready")
        #expect(model.status(for: console.id) == .connecting)
        #expect(server.startedTunnelIDs.isEmpty, "Nothing is started before the link is ready")

        await link.finish()
        await startTask.value
        #expect(model.status(for: console.id) == .listening(localPort: 49152))
    }

    @Test func aForwardStoppedWhileItsLinkIsMadeReadyIsNeverStarted() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let link = LinkCheck()
        model.beforeStart = { await link.run() }
        let console = SessionWebTunnel.internalConsole
        let startTask = Task { await model.start(console) }
        #expect(await link.wasAskedFor())

        await model.stop(console.id)
        await link.finish()
        await startTask.value

        #expect(model.status(for: console.id) == .idle)
        #expect(server.startedTunnelIDs.isEmpty)
    }

    @Test func stoppingEverythingStopsEveryListener() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let forwards = (1...3).map { tunnel("Forward \($0)") }
        for forward in forwards { await model.start(forward) }

        await model.stopAll()

        #expect(model.running.isEmpty)
        #expect(forwards.allSatisfy { server.listener(for: $0.id)?.stopCallCount == 1 })
        #expect(forwards.allSatisfy { model.status(for: $0.id) == .idle })
    }

    @Test func problemsAreForgottenOnceTheLinkIsBack() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let console = SessionWebTunnel.internalConsole
        await model.start(console)
        server.emitConnectionError("SSH host could not reach 10.44.0.25:9443.", for: console.id)
        await Task.yield()
        #expect(model.connectionProblem(for: console.id) != nil)

        model.clearConnectionProblems()

        #expect(model.connectionProblem(for: console.id) == nil)
        #expect(model.status(for: console.id) == .listening(localPort: 49152))
    }

    @Test func aProblemOnAForwardIsReportedToWhoeverKeepsTheLinkAlive() async {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        var reported = 0
        model.onConnectionProblem = { reported += 1 }
        let console = SessionWebTunnel.internalConsole
        await model.start(console)

        server.emitConnectionError("SSH host could not reach 10.44.0.25:9443.", for: console.id)
        await Task.yield()

        #expect(reported == 1)
    }

    @Test func theBrowserUsesHTTPSOnlyWhenThePortSpeaksTLS() async {
        let server = await openServer()
        let probe = FakeTLSProbe(tlsPorts: [49153])
        let model = SessionWebTunnelModel(server: server, probe: probe)
        let plain = tunnel("Plain"), secure = tunnel("Secure")
        await model.start(plain)
        await model.start(secure)

        #expect(await model.webAddress(for: plain.id)?.localhostURL.absoluteString == "http://localhost:49152")
        #expect(await model.webAddress(for: secure.id)?.loopbackURL.absoluteString == "https://127.0.0.1:49153")
    }

    @Test func thePortIsAskedOncePerRun() async {
        let server = await openServer()
        let probe = FakeTLSProbe(tlsPorts: [49152])
        let model = SessionWebTunnelModel(server: server, probe: probe)
        let console = SessionWebTunnel.internalConsole
        await model.start(console)

        _ = await model.webAddress(for: console.id)
        _ = await model.webAddress(for: console.id)
        #expect(probe.asked == [49152])

        // A restart is a new listener, and the service behind it may have changed.
        await model.start(console)
        #expect(await model.webAddress(for: console.id)?.loopbackURL.absoluteString == "http://127.0.0.1:49153")
        #expect(probe.asked == [49152, 49153])
    }

    @Test func theMonitorCountsEveryRunningForwardOfAHost() async throws {
        let server = await openServer()
        let model = SessionWebTunnelModel(server: server)
        let keys = KeyStore(backing: InMemoryKeychain())
        let keyID = try keys.generateEd25519(label: "forwards")
        let session = PortForwardingSession(
            host: Host(name: "h", address: "10.0.0.1", username: "alice", keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.forwards.\(UUID())")!),
            tunnels: [], model: model, transport: FakeSSHTransport())
        #expect(session.activeTunnelCount == 0)

        let rdp = tunnel("RDP"), other = tunnel("Other"), bad = tunnel("Bad")
        server.failStart(of: bad.id, with: SessionWebTunnelError.couldNotStart("no route"))
        await model.start(rdp)
        await model.start(other)
        await model.start(bad)
        #expect(session.activeTunnelCount == 2, "A forward that failed to start is not running")

        await session.shutdown()
        #expect(session.activeTunnelCount == 0)
        #expect(server.listener(for: rdp.id)?.stopCallCount == 1)
        #expect(server.listener(for: other.id)?.stopCallCount == 1)
    }

    @Test func aTunnelThatIsNotListeningHasNoWebAddress() async {
        let server = FakeSessionWebTunnelServer(localPort: 49152)
        let probe = FakeTLSProbe(tlsPorts: [])
        let model = SessionWebTunnelModel(server: server, probe: probe)
        #expect(await model.webAddress(for: UUID()) == nil)
        #expect(probe.asked.isEmpty)
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
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
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

/// Hands out a new listener, on the next port up, for every start.
private final class FakeSessionWebTunnelServer: SessionWebTunnelServing, @unchecked Sendable {
    private let startError: Error?
    private let startGate = StartGate()
    private let lock = NSLock()
    private var nextPort: Int
    private var listenersByTunnel: [UUID: [FakeSessionWebTunnelListener]] = [:]
    private var callbacks: [UUID: @Sendable (String) -> Void] = [:]
    private var failures: [UUID: Error] = [:]
    private var _startedTunnelIDs: [UUID] = []
    private var _lastHopPassword: String?

    init(localPort: Int, startError: Error? = nil) {
        nextPort = localPort
        self.startError = startError
    }

    func start(
        tunnel: SessionWebTunnel,
        hopPassword: String?,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws -> any SessionWebTunnelListener {
        lock.withLock {
            callbacks[tunnel.id] = onConnectionError
            _lastHopPassword = hopPassword
            _startedTunnelIDs.append(tunnel.id)
        }
        await startGate.enterAndWait()

        if let startError { throw startError }
        return try lock.withLock {
            if let failure = failures[tunnel.id] { throw failure }
            let listener = FakeSessionWebTunnelListener(localPort: nextPort)
            nextPort += 1
            listenersByTunnel[tunnel.id, default: []].append(listener)
            return listener
        }
    }

    func waitUntilStartEntered() async {
        await startGate.waitUntilEntered()
    }

    func allowStart() async {
        await startGate.allow()
    }

    func failStart(of id: UUID, with error: Error) {
        lock.withLock { failures[id] = error }
    }

    func emitConnectionError(_ message: String, for id: UUID) {
        let callback = lock.withLock { callbacks[id] }
        callback?(message)
    }

    /// Every listener this tunnel was given, oldest first.
    func listeners(for id: UUID) -> [FakeSessionWebTunnelListener] {
        lock.withLock { listenersByTunnel[id] ?? [] }
    }

    func listener(for id: UUID) -> FakeSessionWebTunnelListener? {
        listeners(for: id).last
    }

    var startedTunnelIDs: [UUID] {
        lock.withLock { _startedTunnelIDs }
    }

    var lastHopPassword: String? {
        lock.withLock { _lastHopPassword }
    }
}

private final class FakeTLSProbe: TunnelTLSProbing, @unchecked Sendable {
    private let tlsPorts: Set<Int>
    private let lock = NSLock()
    private var _asked: [Int] = []

    init(tlsPorts: Set<Int>) {
        self.tlsPorts = tlsPorts
    }

    func speaksTLS(localPort: Int) async -> Bool {
        lock.withLock { _asked.append(localPort) }
        return tlsPorts.contains(localPort)
    }

    var asked: [Int] {
        lock.withLock { _asked }
    }
}

/// A link check that takes as long as the test lets it.
private actor LinkCheck {
    private var asked = false
    private var finished = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run() async {
        asked = true
        guard !finished else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Whether the check was asked for, waiting a moment for it. Never hangs.
    func wasAskedFor() async -> Bool {
        for _ in 0..<200 where !asked {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return asked
    }

    func finish() {
        finished = true
        waiting.forEach { $0.resume() }
        waiting = []
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
