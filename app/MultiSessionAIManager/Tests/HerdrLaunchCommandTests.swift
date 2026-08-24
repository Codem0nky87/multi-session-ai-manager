import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HerdrLaunchCommandTests {
    @Test func defaultSessionLaunchesPlainHerdrThroughALoginShell() {
        let command = HerdrLaunchCommand.launch(sessionName: nil)
        #expect(command.hasPrefix("$SHELL -lc "))
        #expect(command.contains("exec herdr"))
        #expect(!command.contains("--session"))
    }

    @Test func namedSessionIsPassedAndShellQuoted() {
        let script = HerdrLaunchCommand.remoteScript(sessionName: "build box")
        #expect(script.contains("--session 'build box'"))
    }

    @Test func sessionNameCannotEscapeIntoAnotherCommand() {
        let script = HerdrLaunchCommand.remoteScript(sessionName: "a'; rm -rf ~; echo '")
        // the dangerous text survives as DATA inside one quoted argument,
        // never as a command separator the shell would act on
        #expect(script.contains("--session 'a'\\''; rm -rf ~; echo '\\'''"))
        #expect(!script.contains("; rm -rf ~; echo ;"))
    }

    @Test func launchWrapsTheScriptInASingleQuotedArgument() {
        let command = HerdrLaunchCommand.launch(sessionName: "build box")
        #expect(command.hasPrefix("$SHELL -lc '"))
        #expect(command.hasSuffix("'"))
        // inner quotes are escaped by the outer quoting, which is what makes this safe
        #expect(command.contains("'\\''"))
    }

    @Test func blankSessionNameIsTreatedAsDefault() {
        #expect(HerdrLaunchCommand.launch(sessionName: "   ") == HerdrLaunchCommand.launch(sessionName: nil))
    }

    // Restored from the deleted `HerdrProvisionerTests`: `POSIXShell.quote` sits
    // on the app's only remote-command path and had NO test at all after that
    // file went away. Exact output, not a `contains` -- a quoter that dropped or
    // doubled an escape would still satisfy a substring check.
    @Test func posixQuotingHandlesQuotesNewlinesAndMetacharacters() {
        let value = "a'b\nc; $(touch /tmp/nope) `whoami` * ?"
        #expect(POSIXShell.quote(value)
            == "'a'\\''b\nc; $(touch /tmp/nope) `whoami` * ?'")
    }

    @Test func aMaliciousSessionNameSurvivesTheWholeLaunchAsInertShellData() {
        let payload = "a'b\nc; $(touch /tmp/nope) `whoami` * ?"
        let command = HerdrLaunchCommand.launch(sessionName: payload)

        // `$SHELL -lc` must receive exactly ONE word. Recover it the way `sh`
        // would -- strip the outer quotes, undo the '\'' escaping -- and check
        // what the remote shell would actually run.
        let prefix = "$SHELL -lc "
        #expect(command.hasPrefix(prefix))
        let word = command.dropFirst(prefix.count)
        #expect(word.hasPrefix("'"))
        #expect(word.hasSuffix("'"))
        let script = word.dropFirst().dropLast()
            .replacingOccurrences(of: "'\\''", with: "'")

        // The PATH prefix is part of the single word too: a login shell is not
        // guaranteed to include ~/.local/bin, where Herdr's installer writes.
        #expect(script == """
        PATH="$HOME/.local/bin:$PATH"; export PATH; command -v herdr >/dev/null 2>&1 || { printf 'MSAM_HERDR_%s\\n' MISSING; exit 127; }; exec herdr --session 'a'\\''b
        c; $(touch /tmp/nope) `whoami` * ?'
        """)
    }

    @Test func launchCommandNeverContainsTheSentinelLiterally() {
        // A PTY echoes the command back; a literal sentinel in the command text
        // would be indistinguishable from a real detection.
        #expect(!HerdrLaunchCommand.remoteScript(sessionName: nil).contains(HerdrLaunchCommand.missingSentinel))
        #expect(!HerdrLaunchCommand.launch(sessionName: nil).contains(HerdrLaunchCommand.missingSentinel))
        // but the pieces that produce it at runtime are present
        #expect(HerdrLaunchCommand.remoteScript(sessionName: nil).contains("MSAM_HERDR_%s"))
        #expect(HerdrLaunchCommand.remoteScript(sessionName: nil).contains("command -v herdr"))
    }
}

/// A host reported Herdr as "not installed" while Herdr was installed and
/// working on it, because the launch command trusted the login shell's PATH.
@Suite struct HerdrLaunchPathTests {

    @Test func theLaunchCommandPutsTheInstallDirectoryOnPATH() {
        // Herdr's installer writes to ~/.local/bin. On Debian/Ubuntu the line
        // that adds that to PATH lives in ~/.profile, which bash reads ONLY when
        // neither ~/.bash_profile nor ~/.bash_login exists -- so any user with a
        // ~/.bash_profile silently loses it.
        let script = HerdrLaunchCommand.remoteScript(sessionName: nil)
        #expect(script.contains("$HOME/.local/bin"))
        #expect(script.contains("export PATH"))
    }

    @Test func thePATHIsSetBEFOREHerdrIsLookedFor() {
        // Setting it afterwards would leave `command -v` searching the old PATH
        // and still emit the missing sentinel.
        let script = HerdrLaunchCommand.remoteScript(sessionName: nil)
        let pathSet = try! #require(script.range(of: "export PATH"))
        let lookup = try! #require(script.range(of: "command -v herdr"))
        #expect(pathSet.lowerBound < lookup.lowerBound)
    }

    @Test func itMatchesWhatBoundedCommandsAlreadyGot() {
        // Install and verify succeeded while launching failed precisely because
        // these two disagreed. They must not drift apart again.
        #expect(SSHService.provisioningShellCommand("x").contains("$HOME/.local/bin"))
        #expect(HerdrLaunchCommand.remoteScript(sessionName: nil).contains("$HOME/.local/bin"))
    }

    @Test func theSentinelIsStillNeverContiguousInTheScript() {
        // A PTY echoes the command it was sent, so a literal sentinel in the
        // text would be mistaken for a detection on every healthy session.
        let script = HerdrLaunchCommand.remoteScript(sessionName: nil)
        #expect(!script.contains(HerdrLaunchCommand.missingSentinel))
    }

    @Test func aNamedSessionStillReachesTheInvocation() {
        let script = HerdrLaunchCommand.remoteScript(sessionName: "build")
        #expect(script.contains("--session"))
        #expect(script.contains("exec herdr"))
    }
}
