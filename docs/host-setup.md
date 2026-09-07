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

A default working directory is optional. Nothing else is required.

### Getting to the host

**How the iPad reaches the host is deliberately out of scope.** A LAN address, a
VPN, Tailscale, a Cloudflare WARP private network — the app does not care and
does not manage any of it. It opens a TCP connection to `address:port` and
speaks SSH. `HostReadiness` treats an unreachable route as *the user's own
business* and says so rather than guessing at a cause.

(Earlier builds embedded Cloudflare Zero Trust enrolment and connector
management. That was removed: it tied the app to one specific network topology.
A `herdr` metadata blob persisted by such a build is simply ignored on decode.)

### Keys

`KeyStore` generates Ed25519 keys on the device and stores them in the iOS
Keychain; the private key never leaves it. Import accepts OpenSSH private-key
PEM text. The matching public key is exported in `authorized_keys` format for
copying.

**Install Key** authenticates once with a password and appends the public key to
the host's `~/.ssh/authorized_keys` for you. The password is used for that one
connection and is never stored. If you would rather not hand the app a password,
copy the exported public key and paste it in yourself — the result is identical.

**Delete key…** removes a key from the Keychain. It is irreversible — the
private half exists nowhere else — so it refuses outright while another saved
host still uses that key, naming the hosts in the way. The host you are editing
does not block its own key: clearing that selection is recoverable, since a key
is required to save.

### Host-key pinning

The first successful connection pins the host's key fingerprint
(`KnownHostsStore`, keyed by address, or `[address]:port` for a non-default
port). Every later connection verifies against that pin.

If the fingerprint changes, the tab enters `hostKeyChanged` and shows the
presented fingerprint. There is **no Retry** — retrying could only re-detect the
same mismatch. The only action is *Trust new key & reconnect*, marked
destructive, because an unexpected host-key change is what an intercepted SSH
connection looks like. Verify the fingerprint out of band before you take it.

## The guided Host Setup sheet

**Manage Hosts → (host) → Host Setup** walks five steps. Host-changing actions
require an explicit tap. Herdr install/update commands and integration targets
come from fixed app-owned values. Plugin `owner/repo[/subdir]` and ref inputs,
plus manifest action IDs, are validated and shell-quoted as appropriate before
commands are constructed.

### 1 · Test the private route

Opens a bare TCP connection to `address:port` and reports whether it completed.
It sends no SSH, HTTP, or TLS data.

This proves reachability on the *current* network path and nothing more. It does
not prove which transport carried the traffic, and it authenticates nothing —
SSH auth and host-key verification still happen when the tab connects.

Failures are classified into something actionable (`routeUnavailable`,
`networkUnavailable`, `sshPortRefused`, `reachabilityTimedOut`,
`sshAuthenticationRequired`, `herdrConfigurationMissing`) rather than reported as
a generic timeout.

### 2 · Herdr on this host

Probes for `herdr`, reports its version, and offers to install or update it.

- Install runs Herdr's official installer: `curl -fsSL https://herdr.dev/install.sh | sh`
- Update runs `herdr update --handoff` (performing live handoff to transfer sessions to the new server binary)
- The app requires **0.8.2 or newer**; anything older is reported as a failure,
  not a successful install

This is the highest-privilege thing the app does — it pipes a remote script to a
shell as the connecting user — which is why it is probe-then-confirm, and why
the command shown to you and the command sent to the host come from a single
constant that cannot drift apart.

Install is allowed up to 600 s. That is deliberate: Herdr's installer allows
20 s for the release manifest plus 120 s per binary download with up to three
retries, and a deadline that expires mid-install surfaces as "the connection
dropped", hiding the real cause.

If Herdr is missing when a tab connects, the tab says so directly rather than
showing an opaque shell error — see the sentinel in
[architecture.md](architecture.md).

### 3 · Plugins

Opens the plugin manager for this host — see [Managing plugins](#managing-plugins)
below. It appears only once Herdr is confirmed present, because `herdr plugin`
is Herdr's own CLI and there is nothing to talk to before then.

There used to be a separate *File viewer & transfer* card that installed the
`herdr-file-viewer` plugin itself. It is gone: installing plugins belongs in one
place. The wiring that is specific to that plugin now lives on its row in the
manager, as **Send files here**.

### 4 · Session restore

Appears after Herdr is confirmed present. It checks the host's login PATH for
every AI agent in the app's fixed Herdr 0.8.2 integration registry, then
compares only those detected agents with `herdr integration status`.

- **Ready** integrations need no change.
- **Not enabled**, **update needed**, and **repair needed** integrations are
  included in **Enable or repair all**. This is an explicit host mutation; the
  app runs one fixed `herdr integration install <target>` command at a time and
  verifies status again afterwards.
- An unknown status is shown as unavailable and is never treated as ready or
  installed speculatively.
- Installation continues after an individual failure. The final card keeps the
  status of every detected agent visible and names any per-agent failures, so a
  partial result is not mistaken for all-or-nothing success.

These integrations allow Herdr to record native session references exposed by
supported agents. They do not make arbitrary terminal processes restartable,
and detection alone does not guarantee a conversation will resume: the
integration must be current, the pane must have reported a usable reference,
Herdr's global `[session] resume_agents_on_restore` setting must remain enabled,
and the agent must still be able to resume it. Herdr 0.8.2 enables that setting
by default, but the Session restore card checks integrations only; it neither
inspects nor changes this host-wide setting. A **Ready** row is therefore a
prerequisite, not a restore guarantee.

Herdr always saves enough session state to recreate its workspace/tab/pane
layout after its server restarts. Pane screen history is separate and opt-in
because terminal output can contain credentials, prompts, source, and other
sensitive data. AI Manager does not enable `[experimental] pane_history` or
automatically retain a terminal transcript.

### 5 · Background agent updates

Installs a host-owned, per-user helper for Claude Code, Codex, and Antigravity.
This is what lets a queued update continue when the iPad disconnects or the app
is backgrounded. It does not run as root, store a password, or depend on the
iPad remaining connected.

The card verifies the helper protocol, service state, writable state directory,
and a helper self-test before reporting **Ready**. On macOS, the SSH user must
have an active GUI login domain; sign in to that user's desktop, leave the user
logged in, and tap **Test Again**. On Linux, an administrator must enable linger
when prompted:

```sh
loginctl enable-linger USERNAME
```

Without linger, the user service stops when that SSH user logs out. If setup is
skipped or fails, the host remains usable, but its host-list warning remains:
background version checks, durable queueing, and rolling restore while the iPad
is disconnected are unavailable.

#### Versions and installation ownership

Each host's **AI Agent Updates** sheet reads all three fixed tools lazily when
the sheet is visible. It reports:

- **Installed**: the version returned by the executable currently on the host's
  login PATH.
- **Latest**: the newest parseable version available from the same detected
  installation owner and channel. It may be unknown when the vendor lookup is
  unreachable, changes format, or cannot be proved; unknown never enables an
  Update button.
- **Current**: latest is known and is not numerically newer than installed.
  Prerelease identifiers are compared deterministically.

Supported owners are Homebrew, npm, pnpm, bun, and the tool's native installer.
An update uses only the detected owner; it never silently migrates a Homebrew
install to npm, for example. Multiple detected owners, an unsupported owner, or
an unparseable version requires administrator attention. A tool that is absent
is reported as **Not installed** rather than installed automatically from this
screen. An otherwise unowned executable is considered native only at the fixed
per-user launcher (`~/.local/bin/claude`, `~/.local/bin/codex`, or
`~/.local/bin/agy`); another executable merely found on `PATH` is not guessed to
be vendor-managed.

Vendor, package-manager, signature, and Herdr commands also have host-side
wall-clock limits. After installation, the helper re-reads the executable that
is still selected by `PATH` and requires a strictly newer version. A no-op,
downgrade, missing launcher, or unreadable version fails before any conversation
is asked to exit.

#### Rolling conversation contract

After confirmation, the selected tool update is persisted on the host. Once
the executable is ready, the batch covers every eligible Claude Code, Codex,
and Antigravity conversation in every discovered Herdr session—even when only
one of the three tools was updated. When executables are already current, a
rolling re-launch request bypasses package-manager updates and immediately rolls
and recovers active conversations on the existing binary using this same contract:

- `idle` and `done`: cleanly exit, then resume from the same native conversation
  reference;
- `working`: remain running and are acted on by the host service as soon as
  Herdr reports that work finished;
- `blocked`, `unknown`, and `error`: receive no input and remain marked for
  attention;
- stale, duplicate, changed, or missing native identity or foreground PID: fail
  closed and remain untouched;
- failed restore: retry at most three times, then stop for that conversation.

Every target is revalidated immediately before `/exit`. Ordinary shell panes,
servers, tests, and processes are neither targeted nor restarted. The queue,
per-conversation phase, and retry count live on the host, so a service restart
continues from its last durable boundary without repeating a completed tool
update.

#### macOS downloaded-app approval

**Manual approval** is the recommended default. If macOS blocks a newly updated
executable, the batch pauses before any conversation exits. Sign in to the Mac,
launch the exact updated executable, approve **Open** in macOS, then refresh the
sheet. The durable status names the tool awaiting approval, and the sheet shows
its exact executable path plus **Test Again**. AI Manager never clicks the
dialog, requests Accessibility control, or disables Gatekeeper.

The opt-in **Verified artifacts** policy may remove only
`com.apple.quarantine` from the exact resolved executable after all of these
checks pass: strict code-signature verification, the fixed tool-specific Team
Identifier and signing identifier, the designated requirement, Gatekeeper's
execute assessment, and a final path/inode recheck. A directory, glob, parent
path, symlink/path swap, unsigned artifact, publisher mismatch, or failed
assessment falls back to manual approval. Current standalone CLI distributions
may not satisfy Gatekeeper's app assessment even when code-signed; that safe
fallback is expected.

#### Service locations and operator commands

The app owns only these per-user updater files:

| Purpose | macOS | Linux |
|---|---|---|
| Helper | `~/.local/libexec/msam-agent-updater` | same |
| Durable queue/status/logs | `~/.local/state/msam-agent-updater/` | same |
| Service | `~/Library/LaunchAgents/com.codem0nky87.msam-agent-updater.plist` | `~/.config/systemd/user/msam-agent-updater.service` |

Read-only status is safe on either platform:

```sh
~/.local/libexec/msam-agent-updater status
~/.local/libexec/msam-agent-updater verify-service
```

Use **Repair Service** in the app to replace the helper/service definitions and
verify them. To uninstall manually while preserving the durable updater state
and every Herdr/agent conversation, stop the service and remove only the helper
and service definition:

macOS:

```sh
launchctl bootout gui/$(id -u)/com.codem0nky87.msam-agent-updater
rm "$HOME/Library/LaunchAgents/com.codem0nky87.msam-agent-updater.plist"
rm "$HOME/.local/libexec/msam-agent-updater"
```

Linux:

```sh
systemctl --user disable --now msam-agent-updater.service
rm "$HOME/.config/systemd/user/msam-agent-updater.service"
rm "$HOME/.local/libexec/msam-agent-updater"
systemctl --user daemon-reload
```

These commands intentionally do not delete
`~/.local/state/msam-agent-updater/`, any Herdr state, or native agent state.

## Managing plugins

**Host Setup → 3 · Plugins** manages Herdr plugins on that machine, over the
same authenticated connection.

- **Installed** — what is on the host, its version and origin repository, which
  are disabled, and an **Uninstall** for each. A ↻ re-reads the list.
- **Search** — community plugins, found by searching GitHub for the
  `herdr-plugin` topic, ranked by stars, capped at 30 results.
- **Install from a repository** — any `owner/repo[/subdir]`, with an optional
  `--ref`, for plugins that are not tagged or not public.

> **A listing is not an endorsement.** The `herdr-plugin` topic is self-applied:
> anyone can add it to their own repository, and the highest-starred results
> are frequently not Herdr plugins at all. Installing one runs its code on your
> host as your user. Treat the list as a search result, not a reviewed registry.

Because the topic proves nothing, a repository is checked for a
`herdr-plugin.toml` **when you pick it**, not for the whole page — unauthenticated
GitHub search allows roughly ten requests a minute, and verifying a page would
spend that in one go. A rate-limited check does not block the install; a
rate-limited *search* says so rather than rendering as an empty catalogue.

### What decides success

Never the exit status. `herdr plugin install` can exit **0 while failing**, and
Citadel does not surface a remote exit status reliably in either direction. What
decides is whether the plugin is **present in `herdr plugin list` afterwards**.

That also covers two cases that otherwise read as failures:

- a long install whose channel drops before it reports — over a slow link the
  binary download outlasts the connection while the install completes;
- a **reinstall**, which replaces rather than adds, so the plugin count does not
  grow.

### Plugins that build from source

A plugin with no prebuilt binary for the host is compiled there, and the install
fails if the toolchain is missing. The app says which tool is missing rather
than reporting a blank failure, and offers to install it:

| Host | Method | Privileges |
|---|---|---|
| macOS with Homebrew | `brew install rust` | none |
| macOS without, and Linux | `rustup` | none — installs under `$HOME` |
| Windows | `winget install Rustlang.Rustup` | *untested* |

**Linux deliberately does not use `apt`/`dnf`/`pacman`.** They need root, and an
SSH exec channel cannot answer a `sudo` password prompt — the install would hang
until it timed out rather than failing usefully. `rustup` needs no privileges.

`rustup` runs with `--no-modify-path` and the app writes the PATH entry itself,
to `~/.profile` *and* `~/.bash_profile`, idempotently. Left alone `rustup`
appends only to `~/.profile`, which bash ignores when a `~/.bash_profile`
exists — the same shadowing that can hide Herdr itself.

Once the toolchain is in, the plugin install is **retried automatically**: it is
a prerequisite, not the thing you asked for.

If the automatic install fails, the exact commands are listed so you can run
them yourself, and **Run it in a terminal** opens a live PTY on the same
connection — which is the only way to answer a `sudo` password, since an exec
channel has no terminal on stdin.

### Progress

Plugin work can take minutes. A modal names the step it is on and counts
elapsed time. There is deliberately **no percentage**: the host reports nothing
until it finishes, so any bar would be invented. The counter restarts when the
step changes, so installing a toolchain and the retry after it are timed
separately.

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
