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

**Manage Hosts → (host) → Host Setup** walks three steps. Every command it would
run on the host is shown before it runs, and can be copied out and run yourself.

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
- Update runs `herdr update`
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
