# Architecture

The app's whole thesis is that **Herdr's interface does not need reimplementing**.
`ssh -tt <host> herdr` already renders it byte-for-byte, so the app's job is to
open that channel, paint the bytes, and add only what a tablet needs on top.

Everything below the host tab strip is the untouched remote TUI.

## From a tab to a running Herdr

```
RootView
  └ HostTabStore          persisted tabs (host id + optional session name)
      └ HostTabsModel     one HerdrHostSession per open tab
          └ HerdrHostSession
              ├ HostConnection       auth, host-key policy, reconnect
              │   └ NIOSSHTransport  SwiftNIO SSH + Citadel
              │       └ PTYChannel   the SSH channel with a PTY
              └ TerminalEmulator     headless SwiftTerm core → SwiftUI
```

A tab is `HostTab { hostID, sessionName? }` and nothing more. `HostTabsModel`
lazily builds one `HerdrHostSession` per tab, each with **its own**
`HostConnection` — so two tabs on the same host are genuinely independent
sessions, and closing one cannot disturb the other.

### The remote command

`HerdrLaunchCommand` builds what the PTY runs:

```sh
$SHELL -lc 'command -v herdr >/dev/null 2>&1 || { printf "MSAM_HERDR_%s\n" MISSING; exit 127; }; exec herdr --session <name>'
```

Three things are deliberate here:

- **`$SHELL -lc`** — Herdr usually lives somewhere only a *login* shell's PATH
  includes.
- **`exec`** — Herdr replaces the shell, so there is no stray process between
  the PTY and the TUI.
- **The split sentinel.** The script prints `MSAM_HERDR_%s` with `MISSING` as a
  separate argument, so the literal string `MSAM_HERDR_MISSING` never appears in
  the command text. A PTY echoes the command it was sent — a contiguous sentinel
  would arrive in every healthy session's output stream and be mistaken for a
  detection.

`herdr` means *launch **or attach to*** the persistent session. A dropped
connection therefore lands back in the same live session, which is why this app
has no reconnect state machine, no frame sequencing, and no baseline
negotiation.

### Session states

`HerdrHostSession.Status` is the whole model:

| State | Meaning | Recovery offered |
|---|---|---|
| `idle` | Not connected | Retry |
| `connecting` | Dialing or opening the PTY | — |
| `live` | PTY open, Herdr painting | — |
| `herdrMissing` | Sentinel seen; Herdr is not installed | Retry + install instructions |
| `hostKeyChanged(fp)` | Pinned fingerprint no longer matches | **Trust new key** (destructive) — never a plain Retry |
| `failed(reason)` | Classified transport/auth failure | Retry |

`hostKeyChanged` is kept distinct from `failed` on purpose: a Retry button can
do nothing there but re-detect the same mismatch forever. The only real recovery
is an explicit decision to trust a new key, so it is presented as exactly that.

### `ensureLive()` is the only entry point

Every UI trigger — first appearance, tab switch, scene becoming active, the
Retry button — calls `ensureLive()`, never `start()`. `start()` early-returns on
a cached `.live` and reuses a cached `HostConnection`, and neither is
invalidated when the transport dies underneath them. `ensureLive()` reconciles
that cached state against reality first:

- `.live` but the channel is closed → reset to `.idle` without disconnecting
  (the SSH connection is fine and Herdr will reattach).
- `.failed` → drop the possibly-dead connection so `start()` dials a fresh one.
- Always → reconcile the outbox watch channel too.

### Generation fencing

`HerdrHostSession.operationGeneration` is bumped by every `start()` and by any
`stop()` that supersedes work in flight. An in-flight `start()` re-checks it
after each `await` and abandons — closing any channel it already obtained —
if it no longer matches. Without it, a `stop()` racing a slow connect gets
clobbered by the connect finishing afterwards, and the tab silently revives.
`HostConnection` carries the same mechanism for its own operations.

### Concurrency

The app is `@MainActor` throughout; SSH output arrives **off** the main actor on
a NIO event loop. Two patterns keep that safe:

- Output closures are `@Sendable` and touch no actor-isolated state. The
  missing-Herdr scan keeps its accumulator in a `NIOLockedValueBox` captured by
  value, and the outbox watcher keeps its `LineAccumulator` the same way. Only
  complete results hop to the main actor.
- The sentinel scan is **bounded** to the first 4 KB of a fresh channel. The
  sentinel only ever appears in the pre-`exec` preamble, and bounding it stops
  later output — someone grepping for the string, or opening the source file
  inside the session — from mislabelling a healthy tab.

Framework completion handlers that fire off-main must be `nonisolated`/`@Sendable`;
under Swift 6 a `@MainActor` callback invoked off-main traps at runtime.

## Module map

| Path | Responsibility |
|---|---|
| `Core/HerdrHostSession.swift` | One tab's live state: connection + PTY + terminal + file bridge |
| `Core/HerdrLaunchCommand.swift` | The remote command and the missing-Herdr sentinel |
| `Core/HerdrInstaller.swift` | Probe / install / verify Herdr on a host (min 0.8.2) |
| `Core/HostConnection.swift` | Auth, host-key policy, connection lifecycle |
| `Core/NIOSSHTransport.swift` | SwiftNIO SSH + Citadel transport, PTY channels, forwarding |
| `Core/SSHService.swift` | Bounded remote commands with a normalised PATH |
| `Core/KnownHostsStore.swift` | Trust-on-first-use fingerprint pinning |
| `Core/KeyStore.swift` + `KeychainBacking.swift` | Private keys in the iOS Keychain |
| `Core/RemoteFileUpload/Download.swift` | The two-way file bridge |
| `Core/SessionWebTunnel*.swift` | Port forwarding model and listener |
| `UI/RootView.swift` | App shell: tab strip, chrome buttons, sheets |
| `UI/Terminal/` | SwiftTerm emulator, key input, mouse, selection, themes |
| `UI/Hosts/` | Host list/edit, key install, guided Host Setup |
| `UI/Settings/` | Settings sheet, port-forwarding entry point |
| `UI/WebTunnel/` | In-app browser over a forwarded port |
| `UI/Design/` | Theme tokens matched to Herdr's own palette |

## Terminal rendering

`TerminalEmulator` drives a **headless** SwiftTerm core and renders it to SwiftUI
each frame, rather than embedding SwiftTerm's iOS `TerminalView`. This keeps the
grid, selection, and gesture handling under the app's control — which matters,
because a full-screen TUI and a touch surface want the same gestures.

The gesture rules that hold this together are load-bearing and easy to break:

- The key-input overlay must **not** hit-test, or scrolling dies.
- Taps must be `simultaneousGesture`, or pane focus fights the scroll view.
- Auto-scroll is gated on a bottom anchor, not on output arriving.
- Pane-divider drags need a UIKit `UIPanGestureRecognizer`; a SwiftUI
  `DragGesture` over a `UIScrollView` does not fire reliably.
