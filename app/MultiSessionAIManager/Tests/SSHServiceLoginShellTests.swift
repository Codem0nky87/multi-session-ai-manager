import Testing
@testable import MultiSessionAIManager

/// `SSHService.loginShellCommand` wraps a command so it runs in a LOGIN+INTERACTIVE
/// shell (`$SHELL -lic '…' 2>/dev/null`). This makes provisioned tools visible on
/// the PATH for non-interactive SSH execs.
@Suite struct SSHServiceLoginShellTests {

    @Test func wrapsPlainCommand() {
        #expect(SSHService.loginShellCommand("herdr --version") == "$SHELL -lic 'herdr --version' 2>/dev/null")
    }

    @Test func probeCommandsUseNonInteractiveLoginShell() {
        #expect(SSHService.probeShellCommand("command -v herdr") == "$SHELL -lc 'command -v herdr' 2>/dev/null")
    }

    @Test func escapesEmbeddedSingleQuote() {
        // a'b  ->  'a'\''b'
        #expect(SSHService.loginShellCommand("a'b") == "$SHELL -lic 'a'\\''b' 2>/dev/null")
    }

    @Test func roundTripsHerdrCommandWithQuotedArgs() {
        #expect(
            SSHService.loginShellCommand("herdr plugin link '/srv/herdr gateway'")
            == "$SHELL -lic 'herdr plugin link '\\''/srv/herdr gateway'\\''' 2>/dev/null"
        )
    }
}
