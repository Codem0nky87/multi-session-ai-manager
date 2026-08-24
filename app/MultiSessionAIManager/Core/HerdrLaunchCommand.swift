import Foundation

/// Builds the remote command that launches Herdr inside an SSH PTY.
///
/// Runs through `$SHELL -lc` so the user's own login environment applies, and
/// puts `~/.local/bin` on PATH explicitly — a login shell is NOT guaranteed to
/// include it. Stderr is deliberately retained: a missing binary must be
/// reportable, not silently swallowed.
enum HerdrLaunchCommand {
    /// Printed by the remote shell when `herdr` is not installed.
    ///
    /// The launch script deliberately never contains this string contiguously —
    /// it prints `MSAM_HERDR_%s` with `MISSING` as a separate argument. A PTY
    /// echoes the command it was sent, so a literal sentinel in the command text
    /// would arrive in the output stream of every healthy session and be
    /// mistaken for a detection.
    static let missingSentinel = "MSAM_HERDR_MISSING"

    /// The script as the remote shell will see it, before outer quoting.
    /// Exposed so tests can assert on content without fighting the outer
    /// `POSIXShell.quote` that wraps it in `launch(sessionName:)`.
    /// Where Herdr's own installer puts the binary, prepended to PATH.
    ///
    /// A login shell does NOT reliably include this. On Debian/Ubuntu the line
    /// that adds it lives in `~/.profile`, and bash reads `~/.profile` only when
    /// neither `~/.bash_profile` nor `~/.bash_login` exists — so a host whose
    /// user has a `~/.bash_profile` (to set a token, or extend PATH for
    /// something else) silently loses it. The tab then reported Herdr as not
    /// installed on a host where it was installed and working.
    ///
    /// Bounded commands already did this via `SSHService.provisioningShellCommand`,
    /// which is why install and verify succeeded while launching failed.
    static let pathPrefix = "PATH=\"$HOME/.local/bin:$PATH\"; export PATH"

    static func remoteScript(sessionName: String?) -> String {
        var invocation = "herdr"
        let trimmed = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            invocation += " --session \(POSIXShell.quote(trimmed))"
        }
        return "\(pathPrefix); command -v herdr >/dev/null 2>&1 || { printf 'MSAM_HERDR_%s\\n' MISSING; exit 127; }; exec \(invocation)"
    }

    static func launch(sessionName: String?) -> String {
        "$SHELL -lc \(POSIXShell.quote(remoteScript(sessionName: sessionName)))"
    }
}
