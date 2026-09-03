# AI Manager — a Herdr client for iPad

**This is a client for [Herdr](https://herdr.dev), the terminal agent manager.**
It is not a fork of Herdr and it does not reimplement it — it runs the real
`herdr` on your own machines over plain SSH and renders it natively on an iPad.
You need Herdr installed on each host (the app can install it for you).

Herdr is a TUI, and `ssh -tt <host> herdr` already renders its interface
byte-for-byte — so reproducing it would be wasted work. Instead the app opens an
SSH channel per host, runs `herdr` inside a PTY, and paints the genuine remote
interface with a native terminal emulator. What you get on the iPad is Herdr
itself — its sidebar, its panes, its keybindings — wrapped in the few things a
tablet needs that a terminal cannot provide: a host tab strip, text selection
you can copy, two-way file transfer, and SSH port forwarding with an in-app
browser.

There is no hub, no daemon, and no server-side component of our own. Herdr
listens on a Unix socket (`~/.config/herdr/herdr.sock`), and the app reaches it
through the SSH channel — so **no Herdr port is ever exposed**. The remote
attack surface is `sshd` alone.

## How it works

```
iPad (AI Manager)                                    host
┌────────────────────────────┐                ┌────────────────────┐
│  mac  │  build-01  │  +    │                │  sshd              │
├────────────────────────────┤   SSH :22 ───▶ │    └ herdr         │
│                            │                │      (persistent   │
│  SwiftTerm renders the     │                │       session)     │
│  real remote herdr TUI     │                └────────────────────┘
└────────────────────────────┘
```

One tab = one SSH channel = `herdr` (or `herdr --session <name>`) on that host.
`herdr` means *launch **or attach to*** the persistent session. If the selected
tab loses its PTY or SSH connection while the app is active, the app tries the
same session immediately, then after 2 seconds, then after 5 seconds. After the
third failure it stops and offers **Retry**, which starts a fresh three-attempt
budget. Other tabs remain lazy and do not reconnect until selected.

If Herdr's server survived, this reattaches to the original live panes and
processes. If a host reboot or `herdr server stop` killed it, Herdr recreates the
saved workspace/tab/pane layout; arbitrary shell processes are gone. A supported
AI agent can resume its native conversation only when its current official
Herdr integration captured a valid session reference. AI Manager does not
enable Herdr's opt-in pane screen-history persistence, so recovery does not
silently turn terminal output into a stored transcript.

## Features

- **Host tabs** — each tab is a host, optionally pinned to a named Herdr
  session. Two tabs on the same host are independent sessions. Tabs persist
  across launches; the one you left reopens and reattaches, and the rest
  reattach as you switch to them.
- **Native terminal** — a headless SwiftTerm core rendered to SwiftUI each
  frame. Truecolor, SGR mouse forwarding (tap a Herdr pane to focus it), and
  pinch-to-zoom text sizing (7–26 pt, also a slider in Settings).
- **Text selection** — a modal select mode with edge auto-scroll, so you can
  drag a range out of a full-screen TUI and copy it to the iPad pasteboard
  without fighting the terminal's own scroll.
- **Send files to the host** — clipboard image, Photos, or anything in Files.
  The file rides the tab's existing authenticated connection to
  `~/.msam/uploads/`, and its absolute path is typed into the pane (never
  followed by a newline — you decide when to submit).
- **Receive files from the host** — press **`O`** (capital O) on a file in the
  `herdr-file-viewer` plugin and it arrives on the iPad, with Save to Files and
  Share. See [docs/file-transfer.md](docs/file-transfer.md).
- **Port forwarding + in-app browser** — forward a port on the host (optionally
  through a second SSH hop) to a loopback listener on the iPad and open it in an
  embedded web view. See [docs/port-forwarding.md](docs/port-forwarding.md).
- **Guided host setup** — a four-step sheet that tests the route to the host,
  installs or updates Herdr, manages its plugins, and checks native session
  restore for every supported AI agent detected in the host's login PATH. One
  explicit action enables or repairs the integrations that need work, and
  reports per-agent partial failures without hiding integrations already ready.
  Host-changing actions require a tap. Herdr install/update commands and
  integration targets come from fixed app-owned values; plugin repository,
  subdirectory, ref, and manifest action IDs are validated and shell-quoted
  as appropriate before commands are constructed. Herdr's verified state on the
  host decides what is reported — never an exit status alone.
- **One-time password key install** — authenticate once with a password and the
  app appends your public key to the host's `authorized_keys`. The password is
  used for that single connection and is **never stored**. Copying the exported
  public key in by hand gives an identical result.
- **Plugin manager** — browse Herdr plugins from GitHub's `herdr-plugin` topic,
  install by `owner/repo`, and uninstall what is on the host. A plugin that
  builds from source will say which toolchain the host is missing and offer to
  install it (under `$HOME`, no root), then retry — or hand you a live terminal
  if something needs a `sudo` password. The topic is self-applied, so a listing
  is a search result rather than a review — see
  [docs/security.md](docs/security.md).
- **Direct SSH** — SwiftNIO SSH + [Citadel](https://github.com/orlandos-nl/Citadel),
  with on-device key generation and import, OpenSSH public-key export, and
  trust-on-first-use known-hosts pinning.

## Requirements

- iPadOS 17 or newer
- Xcode 16+ (Swift 6)
- A host reachable over SSH with [Herdr](https://herdr.dev) **0.8.2 or newer**
  (the app can install it for you)

## Getting started

```sh
brew install xcodegen
cd app/MultiSessionAIManager
xcodegen generate
open MultiSessionAIManager.xcodeproj
```

Build and run on an iPad. Then:

1. **⚙︎ → Manage Hosts → +** — name, address, port, username, and an SSH key
   (generate one on-device or import an existing OpenSSH private key).
2. **Install the key** on the host, or paste the exported public key into the
   host's `~/.ssh/authorized_keys` yourself.
3. **Host Setup** — walks the remaining steps, including installing Herdr.
4. **+** in the tab strip — pick the host, optionally name a session, and the
   tab goes live.

On first connect the host's key fingerprint is pinned. If it ever changes, the
tab refuses to connect and offers an explicit, destructive *Trust new key*
action — never a plain Retry.

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How a tab becomes an SSH PTY running Herdr; the module map |
| [docs/host-setup.md](docs/host-setup.md) | Keys, host-key pinning, Herdr install, plugins |
| [docs/terminal.md](docs/terminal.md) | Select mode, copy, pointer vs touch, and terminal geometry |
| [docs/file-transfer.md](docs/file-transfer.md) | The two-way file bridge and the `herdr-file-viewer` seam |
| [docs/port-forwarding.md](docs/port-forwarding.md) | SSH web tunnels, second hops, and the in-app browser |
| [docs/development.md](docs/development.md) | Project generation, tests, and TestFlight delivery |
| [docs/security.md](docs/security.md) | Trust boundaries, secret storage, and what leaves the device |

## Project layout

```
app/MultiSessionAIManager/     SwiftUI iPadOS app (the only product)
├── App/          Entry point + generated Info.plist
├── Core/         SSH transport, host model, Herdr session, file transfer
├── UI/
│   ├── Terminal/ SwiftTerm-backed emulator, input, selection, themes
│   ├── Hosts/    Host list/edit, key install, guided setup
│   ├── Settings/ Settings sheet, port forwarding
│   ├── WebTunnel/ In-app browser for forwarded ports
│   └── Design/   Herdr-matched theme tokens and components
├── Tests/        Swift Testing unit tests (hermetic)
├── UITests/      Live XCUITests, env-gated against a real host
└── fastlane/     TestFlight delivery
```

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Edit [`project.yml`](app/MultiSessionAIManager/project.yml) — **not** the
generated `.pbxproj` or `App/Info.plist`.

## Status

**v1 beta.** The app is in daily use and covered by a hermetic unit suite of
over 550 tests, but it has not been through a public release cycle. Expect rough
edges, and treat the host-key and file-transfer paths as the ones worth reading
before you trust them.

## License

[MIT](LICENSE) © Swart Cyber Security Systems (Pty) Ltd

Herdr itself is a separate project with its own license, as are the Swift
packages this app depends on.
