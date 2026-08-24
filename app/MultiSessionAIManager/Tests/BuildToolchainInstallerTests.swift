import Foundation
import Testing
@testable import MultiSessionAIManager

/// Some plugins ship no prebuilt binary and build from source, so a host without
/// the toolchain cannot install them. The app already has an authenticated shell
/// on that host, so it installs the toolchain rather than sending the user away.
@Suite struct BuildToolchainPlatformTests {

    @Test func unameIdentifiesTheHost() {
        #expect(BuildToolchainInstaller.platform(from: "Darwin\n") == .macOS)
        #expect(BuildToolchainInstaller.platform(from: "Linux\n") == .linux)
    }

    @Test func aWindowsShellIsNotMistakenForLinux() {
        // MINGW/MSYS report a uname that mentions neither "windows" nor "linux"
        // in the obvious place; getting this wrong would run a curl|sh installer
        // on a host that needs winget.
        #expect(BuildToolchainInstaller.platform(from: "MINGW64_NT-10.0-22631") == .windows)
        #expect(BuildToolchainInstaller.platform(from: "MSYS_NT-10.0") == .windows)
        #expect(BuildToolchainInstaller.platform(from: "CYGWIN_NT-10.0") == .windows)
        #expect(BuildToolchainInstaller.platform(from: "Windows") == .windows)
    }

    @Test func anUnrecognisedHostIsNotGuessedAt() {
        #expect(BuildToolchainInstaller.platform(from: "SunOS") == .unknown)
        #expect(BuildToolchainInstaller.platform(from: "") == .unknown)
    }
}

@Suite struct BuildToolchainCommandTests {

    @Test func macOSPrefersHomebrewWhenItIsThere() {
        // Homebrew needs no root and puts cargo somewhere already on PATH —
        // which matters because HERDR runs the plugin build, in its own
        // environment, not the app's.
        let command = BuildToolchainInstaller.installCommand(
            for: .cargo, platform: .macOS, hasBrew: true
        )
        #expect(command == "brew install rust")
    }

    @Test func macOSWithoutHomebrewFallsBackToRustup() {
        let command = BuildToolchainInstaller.installCommand(
            for: .cargo, platform: .macOS, hasBrew: false
        )
        #expect(command == BuildToolchainInstaller.rustupCommand)
    }

    @Test func linuxUsesRustupRatherThanAPackageManager() {
        // THE constraint: apt/dnf/pacman all need root, and an SSH exec channel
        // cannot answer a sudo password prompt — the install would hang until it
        // timed out. rustup installs entirely under $HOME.
        let command = try! #require(BuildToolchainInstaller.installCommand(
            for: .cargo, platform: .linux, hasBrew: false
        ))
        #expect(command.contains("rustup"))
        #expect(!command.contains("sudo"))
        #expect(!command.contains("apt"))
    }

    @Test func everyInstallerRunsWithoutAPrompt() {
        // stdin is not a terminal on an exec channel, so anything that asks a
        // question hangs rather than failing.
        #expect(BuildToolchainInstaller.rustupCommand.contains("-y"))
        let windows = try! #require(BuildToolchainInstaller.installCommand(
            for: .cargo, platform: .windows, hasBrew: false
        ))
        #expect(windows.contains("--accept-package-agreements"))
    }

    @Test func rustupDoesNotEditPATHItself() {
        // rustup would append to ~/.profile, which bash ignores when a
        // ~/.bash_profile exists — the exact shadowing that stopped Herdr itself
        // being found. The path is written explicitly instead.
        #expect(BuildToolchainInstaller.rustupCommand.contains("--no-modify-path"))
        #expect(BuildToolchainInstaller.persistPathCommand.contains(".bash_profile"))
        #expect(BuildToolchainInstaller.persistPathCommand.contains(".profile"))
    }

    @Test func thePATHWriteIsIdempotent() {
        // Re-running setup must not append the same export a second time.
        #expect(BuildToolchainInstaller.persistPathCommand.contains("grep -qF"))
    }

    @Test func anUnknownPlatformYieldsNoCommandRatherThanAGuess() {
        #expect(BuildToolchainInstaller.installCommand(
            for: .cargo, platform: .unknown, hasBrew: false
        ) == nil)
    }

    @Test func verificationLooksWhereRustupInstalls() {
        // ~/.cargo/bin is not on a login PATH by default — the same trap as
        // ~/.local/bin.
        #expect(BuildToolchainInstaller.verifyCommand(for: .cargo).contains(".cargo/bin"))
    }

    @Test func theBrewProbeIsRecognised() {
        #expect(BuildToolchainInstaller.hasBrew("HAS_BREW"))
        #expect(!BuildToolchainInstaller.hasBrew(""))
    }
}

/// "Let an app install a compiler on my server" deserves an answer to "as
/// root?" before the button is pressed, and a way out when it does not work.
@Suite struct BuildToolchainDisclosureTests {

    @Test func thePrivilegeNoticeSaysPlainlyThatNoRootIsUsed() {
        let notice = BuildToolchainInstaller.privilegeNotice.lowercased()
        #expect(notice.contains("no root"))
        #expect(notice.contains("sudo"))
        #expect(notice.contains("home directory"))
    }

    @Test func manualStepsMatchWhatTheInstallerWouldHaveRun() {
        // Steps that differ from the automatic path would send the user down a
        // road the app itself does not take.
        #expect(BuildToolchainInstaller.manualSteps(for: .cargo, platform: .macOS, hasBrew: true)
            == ["brew install rust"])
        let linux = BuildToolchainInstaller.manualSteps(for: .cargo, platform: .linux, hasBrew: false)
        #expect(linux.first == BuildToolchainInstaller.rustupCommand)
    }

    @Test func linuxStepsMentionTheRootAlternativeAsAComment() {
        // Offered, but marked so it is not run blindly by the terminal button —
        // which filters comment lines.
        let linux = BuildToolchainInstaller.manualSteps(for: .cargo, platform: .linux, hasBrew: false)
        let sudoLine = try! #require(linux.first { $0.contains("sudo") })
        #expect(sudoLine.hasPrefix("#"))
    }

    @Test func stepsSourceTheEnvironmentSoCargoIsUsableImmediately() {
        // rustup runs with --no-modify-path, so a shell that has not re-read its
        // profile still needs this to see cargo.
        let linux = BuildToolchainInstaller.manualSteps(for: .cargo, platform: .linux, hasBrew: false)
        #expect(linux.contains { $0.contains("cargo/env") })
    }

    @Test func anUnknownPlatformStillGetsSomethingActionable() {
        let steps = BuildToolchainInstaller.manualSteps(for: .cargo, platform: .unknown, hasBrew: false)
        #expect(!steps.isEmpty)
        #expect(steps.joined().contains("rustup.rs"))
    }
}

@Suite @MainActor struct InteractiveCommandSessionTests {

    private func session(_ command: String) -> InteractiveCommandSession {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = (try? keyStore.generateEd25519(label: "ic")) ?? "k"
        return InteractiveCommandSession(
            connection: HostConnection(
                host: Host(name: "h", address: "10.0.0.1", username: "alice",
                           keyID: keyID, defaultWorkdir: "/home/alice"),
                keyStore: keyStore,
                knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.ic.\(UUID())")!),
                transport: FakeSSHTransport()
            ),
            command: command
        )
    }

    @Test func theCommandRunsInALoginShellSoItSeesTheUsersPATH() {
        // An installer that has just written to ~/.profile is invisible
        // otherwise, which is the whole reason this sheet exists.
        #expect(session("brew install rust").remoteCommand.hasPrefix("$SHELL -lc "))
    }

    @Test func aHostileCommandStaysOneInertShellWord() {
        // The command is assembled from steps, so it must survive quoting the
        // same way the Herdr launch command does.
        let remote = session("echo 'a'; rm -rf ~").remoteCommand
        #expect(remote.hasPrefix("$SHELL -lc '"))
        #expect(remote.hasSuffix("'"))
    }

    @Test func anUnconnectedHostFailsRatherThanHangingOnABlankTerminal() async {
        let s = session("true")
        await s.start()
        guard case .failed = s.status else {
            Issue.record("expected failure, got \(s.status)")
            return
        }
    }

    @Test func stoppingReleasesTheChannelAndTheDisplayLink() async {
        // Without this every closed sheet leaves a display link ticking for the
        // life of the process.
        let s = session("true")
        await s.stop()
        #expect(s.terminal.pty == nil)
    }
}

/// Plugin work can take minutes; a row-sized spinner does not carry that, and
/// the screen reads as idle while a build runs on the host.
@Suite @MainActor struct PluginOperationProgressTests {

    @Test func elapsedTimeIsShownInSecondsThenMinutes() {
        // Counting is what separates "slow" from "hung" without pretending to a
        // percentage we cannot measure.
        #expect(PluginOperationOverlay.elapsedLabel(0) == "0s elapsed")
        #expect(PluginOperationOverlay.elapsedLabel(45) == "45s elapsed")
        #expect(PluginOperationOverlay.elapsedLabel(60) == "1:00 elapsed")
        #expect(PluginOperationOverlay.elapsedLabel(605) == "10:05 elapsed")
    }

    @Test func aSlowOperationSaysSoRatherThanLookingStuck() {
        let build = HerdrPluginManagerModel.Operation(
            title: "owner/thing", step: "Installing on the host…", isSlow: true
        )
        #expect(build.isSlow)
        // A quick step must not claim it will take minutes.
        let remove = HerdrPluginManagerModel.Operation(title: "x", step: "Removing…")
        #expect(!remove.isSlow)
    }

    @Test func aChangedStepIsADistinctOperationForTheUser() {
        // Installing cargo and the retry that follows are separate waits; timing
        // them cumulatively would make the retry look far slower than it is.
        var op = HerdrPluginManagerModel.Operation(title: "t", step: "Installing cargo…")
        let before = op
        op.step = "Retrying the plugin…"
        #expect(op != before)
    }
}
