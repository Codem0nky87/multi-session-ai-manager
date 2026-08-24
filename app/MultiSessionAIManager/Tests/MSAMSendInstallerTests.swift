import Foundation
import Testing
@testable import MultiSessionAIManager

/// The host side of host -> iPad transfer.
@Suite struct MSAMSendScriptTests {

    @Test func theScriptQueuesAnAbsolutePath() {
        // The iPad refuses relative entries, so resolving here is what makes the
        // two halves agree.
        #expect(MSAMSendInstaller.script.contains("outbox"))
        #expect(MSAMSendInstaller.script.contains("pwd"))
    }

    @Test func theScriptSkipsAnythingThatIsNotAFile() {
        // A directory or a dangling path would surface on the iPad as a failed
        // download with nothing explaining it.
        #expect(MSAMSendInstaller.script.contains("[ -f \"$path\" ] || continue"))
    }

    @Test func theScriptLivesSomewhereAlreadyOnThePATH() {
        // SSHService.provisioningShellCommand puts $HOME/.local/bin on PATH, so
        // the plugin config can name the command without an absolute path.
        #expect(MSAMSendInstaller.scriptRelativePath.hasPrefix(".local/bin/"))
    }
}

@Suite struct MSAMSendConfigOutcomeTests {

    @Test func aFreshHostReportsAdded() {
        #expect(MSAMSendInstaller.parseConfigOutcome("ADDED") == .added)
    }

    @Test func aRerunReportsAlreadySetRatherThanAppendingAgain() {
        #expect(MSAMSendInstaller.parseConfigOutcome("ALREADY") == .alreadySet)
    }

    @Test func anExistingDifferentOpenCommandIsReportedNotOverwritten() {
        // `open` is a setting the user may have chosen deliberately; replacing
        // it silently would break whatever they wired up.
        #expect(MSAMSendInstaller.parseConfigOutcome("CONFLICT") == .conflict)
    }

    @Test func loginShellNoiseAroundTheMarkerDoesNotChangeTheVerdict() {
        // A login shell prints motd, direnv output, whatever -- the marker is
        // searched for, never compared against the whole of stdout.
        #expect(MSAMSendInstaller.parseConfigOutcome("Welcome to Ubuntu\nCONFLICT\n") == .conflict)
        #expect(MSAMSendInstaller.parseConfigOutcome("motd\nALREADY") == .alreadySet)
    }
}

@Suite @MainActor struct MSAMSendInstallTests {

    /// Ordered per-command results: the installer runs three distinct commands
    /// and each must answer for itself. A single canned response would let the
    /// home probe swallow the other two commands' output.
    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map { output in
            .success(SSHCommandResult(exitStatus: 0, stdout: Data(output.utf8), stderr: Data()))
        }
    }

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.inst.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 5, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func aSuccessfulInstallWritesTheScriptAndReportsTheConfigOutcome() async throws {
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice",
                         "MSAM_CONFIG_PATH=/home/alice/.config/herdr/plugins/config/herdr-file-viewer/config.toml\nADDED",
                         "MSAM_SEND_OK"])

        let result = try await MSAMSendInstaller.install(using: service)

        #expect(result.configOutcome == .added)
        #expect(result.configPath == "/home/alice/.config/herdr/plugins/config/herdr-file-viewer/config.toml")
        #expect(transport.writtenFiles["/home/alice/.local/bin/msam-send"] != nil)
    }

    @Test func theScriptIsUploadedNotEchoedThroughAShell() async throws {
        // Writing it over SFTP keeps a multi-line shell script's quoting out of
        // the command line entirely.
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice",
                         "MSAM_CONFIG_PATH=/home/alice/.config/herdr/plugins/config/herdr-file-viewer/config.toml\nADDED",
                         "MSAM_SEND_OK"])

        _ = try await MSAMSendInstaller.install(using: service)

        let uploaded = try #require(transport.writtenFiles["/home/alice/.local/bin/msam-send"])
        #expect(String(decoding: uploaded, as: UTF8.self).hasPrefix("#!/bin/sh"))
    }

    @Test func aHostWhereTheCommandIsNotOnPATHFailsVerification() async throws {
        // Exit status is not trusted anywhere in this codebase; the capability
        // check is the authority.
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice", "ADDED", ""])   // verify returns no MSAM_SEND_OK

        await #expect(throws: MSAMSendInstaller.Failure.self) {
            try await MSAMSendInstaller.install(using: service)
        }
    }

    @Test func aHostThatCannotReportHomeFailsRatherThanGuessing() async throws {
        let (service, _) = try await makeService()

        await #expect(throws: MSAMSendInstaller.Failure.self) {
            try await MSAMSendInstaller.install(using: service)
        }
    }
}

/// The plugin half. Without it `open = "msam-send"` configures a plugin that is
/// not there — a setup that reports success and does nothing.
@Suite struct HerdrPluginInstallerCommandTests {

    @Test func theInstallPassesYesBecauseSSHStdinIsNeverInteractive() {
        // `herdr plugin install` refuses outright on a non-interactive stdin,
        // which an SSH exec channel always is. Verified against herdr 0.8.2.
        #expect(HerdrPluginInstaller.installCommand.contains("--yes"))
        #expect(HerdrPluginInstaller.installCommand.contains("smarzban/herdr-file-viewer"))
    }

    @Test func theTimeoutAllowsForABuildFromSource() {
        // The install fetches a prebuilt and falls back to cargo on ANY miss;
        // a 60s timeout would abort a legitimate build partway.
        #expect(HerdrPluginInstaller.installTimeout >= .seconds(600))
    }

    @Test func theKeybindReloadsTheRunningServer() {
        // Otherwise the binding only takes effect on the user's next session,
        // which reads as "the setup did not work".
        #expect(HerdrPluginInstaller.keybindCommand.contains("herdr server reload-config"))
    }

    @Test func theKeybindStanzaBindsBothSplitAndTab() {
        #expect(HerdrPluginInstaller.keybindStanza.contains("prefix+f"))
        #expect(HerdrPluginInstaller.keybindStanza.contains("prefix+shift+f"))
        #expect(HerdrPluginInstaller.keybindStanza.contains("open-file-viewer-tab"))
    }

    @Test func aMissingToolchainIsToldApartFromAGenericFailure() {
        // Its fix is specific -- install Rust -- so it must not surface as a
        // wall of installer output.
        #expect(HerdrPluginInstaller.mentionsMissingToolchain("sh: 1: cargo: not found"))
        #expect(HerdrPluginInstaller.mentionsMissingToolchain("zsh: command not found: cargo"))
        #expect(!HerdrPluginInstaller.mentionsMissingToolchain("error: checksum mismatch"))
    }

    @Test func keybindOutcomesAreParsedFromNoisyOutput() {
        #expect(HerdrPluginInstaller.parseKeybindOutcome("KEYS_BOUND") == .bound)
        #expect(HerdrPluginInstaller.parseKeybindOutcome("noise\nKEYS_ALREADY\n") == .alreadyBound)
        #expect(HerdrPluginInstaller.parseKeybindOutcome("x\nKEYS_CONFLICT") == .conflict)
    }

    @Test func installerOutputIsTrimmedToTheLinesThatSayWhy() {
        let output = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let tail = HerdrPluginInstaller.tail(of: output, lines: 3)
        #expect(tail == "line 18\nline 19\nline 20")
        #expect(!HerdrPluginInstaller.tail(of: "").isEmpty)
    }
}

@Suite @MainActor struct HerdrPluginInstallTests {

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map { output in
            .success(SSHCommandResult(exitStatus: 0, stdout: Data(output.utf8), stderr: Data()))
        }
    }

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.plug.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 9, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func anAlreadyInstalledPluginSkipsTheSlowInstall() async throws {
        // home, probe(present), keybind
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice", "PLUGIN_ALREADY", "KEYS_ALREADY"])

        let result = try await HerdrPluginInstaller.install(using: service)

        #expect(result.plugin == .alreadyInstalled)
        #expect(result.keybind == .alreadyBound)
        // The multi-minute install must not have run.
        #expect(!transport.commandsRun.contains { $0.contains("plugin install") })
    }

    @Test func afreshHostInstallsThePluginAndBindsTheKeys() async throws {
        // home, probe(absent), install, verify(present), keybind
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice", "", "installed ok", "PLUGIN_ALREADY", "KEYS_BOUND"])

        let result = try await HerdrPluginInstaller.install(using: service)

        #expect(result.plugin == .installed)
        #expect(result.keybind == .bound)
        #expect(transport.commandsRun.contains { $0.contains("plugin install") })
    }

    @Test func aHostWithNoRustToolchainSaysSoRatherThanDumpingOutput() async throws {
        // home, probe(absent), install(cargo missing), verify(still absent)
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice", "", "sh: 1: cargo: not found", "", ""])

        await #expect(throws: HerdrPluginInstaller.Failure.noToolchain) {
            try await HerdrPluginInstaller.install(using: service)
        }
    }

    @Test func anInstallThatDoesNotVerifyFailsRatherThanReportingSuccess() async throws {
        let (service, transport) = try await makeService()
        stub(transport, ["/home/alice", "", "error: checksum mismatch", "", ""])

        await #expect(throws: HerdrPluginInstaller.Failure.self) {
            try await HerdrPluginInstaller.install(using: service)
        }
    }
}


/// The viewer reads its config from a DIFFERENT place depending on how it runs,
/// and writing to the wrong one produces an install that reports success while
/// `O` silently does nothing.
@Suite struct MSAMSendConfigLocationTests {

    @Test func theFinaliseScriptAsksHerdrWhereTheConfigLives() {
        // Under herdr the live file is `$HERDR_PLUGIN_CONFIG_DIR/config.toml`;
        // `~/.config/herdr-file-viewer/` is only read when the viewer runs
        // STANDALONE. Hard-coding the standalone path was the original bug.
        #expect(MSAMSendInstaller.finaliseCommand.contains("herdr plugin config-dir herdr-file-viewer"))
    }

    @Test func itFallsBackToTheStandalonePathWhenHerdrCannotAnswer() {
        #expect(MSAMSendInstaller.finaliseCommand.contains(MSAMSendInstaller.standaloneConfigDirectory))
    }

    @Test func theHostReportsWhereItActuallyWrote() {
        // Reported rather than assumed, so a conflict message names the real file.
        let output = "MSAM_CONFIG_PATH=/home/alice/.config/herdr/plugins/config/herdr-file-viewer/config.toml\nADDED"
        #expect(MSAMSendInstaller.parseConfigPath(output)
            == "/home/alice/.config/herdr/plugins/config/herdr-file-viewer/config.toml")
    }

    @Test func aMissingOrRelativePathReportIsIgnoredRatherThanTrusted() {
        #expect(MSAMSendInstaller.parseConfigPath("ADDED") == nil)
        #expect(MSAMSendInstaller.parseConfigPath("MSAM_CONFIG_PATH=relative/path") == nil)
    }

    @Test func loginNoiseAroundThePathDoesNotBreakIt() {
        let output = "motd line\nMSAM_CONFIG_PATH=/x/config.toml\nALREADY"
        #expect(MSAMSendInstaller.parseConfigPath(output) == "/x/config.toml")
        #expect(MSAMSendInstaller.parseConfigOutcome(output) == .alreadySet)
    }
}
