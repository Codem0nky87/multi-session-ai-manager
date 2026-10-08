# Host setup

A host is the machine that runs Herdr. The app needs three things from it: a
reachable SSH endpoint, an account it can authenticate as, and `herdr` on that
account's login PATH.

## Adding a host

**⚙︎ → Manage Hosts → +**. Required fields:

| Field | Notes |
|---|---|
| Name | Label only; shown on the tab |
| Address | Hostname or IP |
| Port | Defaults to 22 |
| Username | The account Herdr runs as |
| Key | Generate on-device, or import an OpenSSH private key |

A default working directory is optional. **Browse remote folders…** opens an
authenticated remote explorer using SSH commands. No SFTP subsystem is required.
The explorer starts in the remote home directory when no workdir is set.
Navigate folders, go up or use the breadcrumbs, then tap **Use this folder**.
Linked directories are navigable. The selected path is retained when
moving back and forward through the wizard.

The add-host wizard has four steps:

1. **Connection details** — enter the fields above, generate or import a key,
   and use **Install key on host…** for one-time password-based installation.
   With no key selected, that action generates one before opening the installer.
   Required fields must be valid before **Next** becomes available.
2. **Herdr and host services** — connect and automatically discover Herdr first.
   If absent, **Install Herdr** runs the displayed official installer and verifies
   the result. An older unsupported version must be updated. After a successful
   install or update, the agent-status-verb sidebar default (`state_text` rows)
   is applied to the host's effective Herdr config when unset, validated with
   `herdr config check`, and rolled back if rejected; a failure there is shown
   as a warning and never fails the install. Only then can
   **Install or Check Services** install hardware metrics and verify or repair
   the background updater. Linux and macOS setup uploads use SSH commands and
   do not require SFTP. Errors and required host-side actions remain visible;
   **Next** requires successful setup, or an explicit **Continue without
   Background Updater** choice after a service failure. Skipped setup is saved
   with the existing degraded-capability warning, never as ready.
3. **Updater settings and session restore** — choose the persisted macOS
   downloaded-app approval policy, inspect detected agent integrations, and
   optionally enable or repair them. The updater processes explicitly queued
   updates; this step does not claim to schedule automatic daily installation.
4. **Summary** — review the connection and workdir, then save the host with its
   verified updater readiness and selected approval policy.

**Back** retains the draft; returning to connection details closes the setup
connection and the next attempt checks the current endpoint again. Cancelling
the wizard cancels outstanding setup work and closes its SSH connection.

## Installing AI agent CLIs

In **Manage Hosts → Edit host → AI Agent CLIs**, select **Manage AI agent CLIs**.
MSAM checks Codex, Claude Code, and Antigravity on that host using their version
commands. **Install** is available for missing tools. Dependencies are checked,
the official native installer is downloaded over HTTPS, and the installed CLI
must return a valid version before the app reports success. Existing working
installations are kept; a broken existing installation is reported for repair.
Sign in by opening the installed CLI in a host terminal.

Installation instructions follow the official [Codex](https://learn.chatgpt.com/docs/codex/cli),
[Claude Code](https://code.claude.com/docs/en/setup), and
[Antigravity](https://www.antigravity.google/docs/cli/install/) documentation.
The software helper runs under the host's SSH account using the Python 3.9+
runtime already required by host setup. It is uploaded on demand, so these
controls do not require a metrics daemon update.

## Managing plugins

**Manage Hosts → Edit host → Manage plugins** manages Herdr plugins on that
machine over the same authenticated connection.

- **Installed** shows versions, origins, activation, setup checks, and uninstall.
  Refresh checks the host again instead of remembering that a button was tapped.
- **Search** finds repositories tagged `herdr-plugin` on GitHub.
- **Install from a repository** accepts `owner/repo[/subdir]` and an optional ref.
  Private repositories reuse the host’s existing Git credentials when public
  metadata is unavailable; authentication prompts cannot be answered during
  automatic installation.

A listing is not an endorsement: installing a plugin runs its code on the host.
The catalogue tag alone does not prove that a repository contains a plugin.

### Dependency checks and activation

Before installing, MSAM resolves the requested revision to a commit, checks its
manifest and platform, and reads build metadata such as Cargo.toml, package.json,
and go.mod. Supported missing tools are installed before Herdr builds the plugin.
Rust uses rustup in the user's home directory. System dependencies use the host's
available package manager: apt, dnf, apk, pacman, Homebrew, or WinGet. Unix system
packages require root or working passwordless sudo; if access is unavailable,
installation stops with the package names needed. It never waits for a password
on an SSH exec channel. Unknown missing tools are reported rather than guessed.

The same checked commit is passed to Herdr. Success requires the expected plugin
ID, repository, resolved commit, and enabled state in the resulting inventory.
An unrelated plugin appearing, a zero exit code, or a stale previous installation
does not count as success. Disabled newly installed plugins are enabled and then
checked again.

### Setup action verification

Ferry's keybinding action reads the host's actual Herdr TOML configuration,
including HERDR_CONFIG_PATH and XDG_CONFIG_HOME overrides. Missing `prefix+m`
enables its installer; an existing binding to `shadowfax.ferry.open` displays
**Configured**. Conflicts are displayed without overwriting another command.
After invocation, the action log must report success and a fresh configuration
check must pass. The plugin executable is also checked for presence and execute
permission. These checks verify configuration and installation, not a simulated
interactive use of the plugin.

Other plugins can declare keybinding postconditions without an app-specific
button by adding this optional metadata to their manifest:

```toml
[metadata.msam.actions.install-keybindings]
keybindings = [{ key = "prefix+x", command = "example.plugin.open" }]
```

The action ID must match an existing non-contextual manifest action. A setup
action with no known verification contract remains visible as unverified and
cannot be invoked from the setup manager. File viewer transfer setup is checked
against its bindings, open command, and msam-send executable. Windows file viewer
transfer setup remains unavailable.

### Progress

Plugin work can take minutes. A modal names the step it is on and counts
elapsed time. There is deliberately **no percentage**: the host reports nothing
until it finishes, so any bar would be invented. The counter restarts when the step changes, covering dependency setup, plugin
installation, and verification separately.

## Function keys on iPad

Tap **fn** beside the attachment button to display F1–F12. Selecting a key sends
the same terminal escape sequence as a physical keyboard to the selected host
session. Herdr routes it to the currently focused tab or split. The button is
disabled when the selected session is disconnected.

## Opening a session

**+** in the tab strip → pick the host → optionally name a session.

An unnamed tab runs `herdr`; a named one runs `herdr --session <name>`. Both
mean "launch or attach", so reopening the app returns you to the same live
session. Two tabs on the same host with different names are independent.

If the selected tab loses its PTY or SSH connection while the app is active,
the three attempts wait 0 seconds, then 2 seconds, then 5 seconds respectively.
The third starts roughly 7 seconds after detection, plus time spent in the first
two failed attempts. AI Manager then stops; **Retry** starts a new three-attempt
budget. Unselected tabs remain lazy, and backgrounding the app cancels pending
automatic attempts.

When only the app's Herdr client PTY dies and the remote server survives,
recovery probes and reuses the authenticated SSH connection, then reattaches to
the original processes. An explicit Herdr server/session stop also leaves SSH
up, so recovery reuses that transport; its attach starts Herdr's snapshot
restoration because the pane processes were killed. A host reboot or SSH loss
instead fails the probe, disconnects the cached service, and redials SSH before
attaching. Snapshot restoration returns the layout, but not arbitrary shells,
servers, tests, or commands. Eligible supported-agent panes may resume their
native conversations only when the global restore setting remains enabled and
the other prerequisites above hold; other panes return as new shells in their
saved directories.
