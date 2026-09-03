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
connection can therefore land back in the same live session. The app has a
bounded reconnect coordinator for transport loss; Herdr, not the app, owns the
remote session snapshot and any agent-native restore reference.

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

### Recovery after PTY or SSH loss

`ensureLive()` is the lifecycle entry point for initial appearance, tab
selection, and return to the foreground. A manual **Retry** uses `retry()` so it
can cancel an old cycle and grant a fresh attempt budget.

Only the selected tab has automatic recovery enabled, and only while the app is
active. `HostTabsModel` applies that flag to sessions it has already created;
stored background tabs remain dormant. Selecting one lazily creates its session
and gives it the current foreground context.

One coordinator handles both ways a dead session becomes observable:

```text
PTY EOF/error ───────────────┐
                            ├─ selected + foreground?
failed idle SSH heartbeat ──┘          │
                                       ▼
                       per-attempt waits: 0 s, 2 s, 5 s
                         (third starts around t+7 s)
                                       │
                          probe cached authenticated SSH
                              │ alive             │ dead
                              ▼                   ▼
                            reuse          disconnect + redial
                              └──────────┬─────────┘
                                         ▼
                            attach the same Herdr session
                                         ▼
                          attempt to reopen outbox watcher
```

Each cycle makes at most three attach/connect attempts. Success cancels the
remaining delays. The waits apply before their respective attempts: 0 seconds,
then 2 seconds, then 5 seconds, so the third begins roughly 7 seconds after loss
detection plus the time spent in earlier failed attempts. Three failures leave
`.failed`; the user can then press **Retry** for a fresh three attempts.
Deselection or backgrounding cancels a pending automatic cycle, and a deliberate
tab close is generation-fenced so its PTY callback cannot revive the session.

Before every attempt, the coordinator probes a cached authenticated SSH
connection. A healthy connection is reused when only the Herdr client PTY died;
a failed probe retires it so the attempt reconnects SSH. A successful attach
also attempts to reopen the separate `tail -F` watcher for `~/.msam/outbox`.
Watcher setup is non-fatal; later lifecycle reconciliation, or a later manual
Retry that reattaches the session, can attempt it again.

### What a host restart restores

Recovery re-runs the same command and session name; it does not reconstruct
remote state on the iPad.

| Remote condition | What comes back |
|---|---|
| Client/SSH detached; Herdr server still running | The same live pane PTYs and processes. |
| Herdr server stopped or host rebooted | Herdr's saved workspaces, tabs, pane layout, working directories, and focus. Old shell processes, servers, tests, and other arbitrary commands do not survive. |
| Restored pane with a valid supported-agent session reference | Herdr may launch that agent's native resume command when the matching official integration is current, `[session] resume_agents_on_restore` remains enabled, and the agent still accepts the reference. |
| Other restored pane | A new shell in the saved directory. |

Herdr's pane screen-history replay is a separate opt-in feature. It stores
terminal contents, which may include secrets, tokens, prompts, and command
output. AI Manager never enables `[experimental] pane_history` and never
captures a transcript as part of recovery.

Host Setup's `HerdrIntegrationManager` detects only the Herdr 0.8.2 targets in
its compiled registry whose executables are present in the remote login PATH.
It compares them with `herdr integration status`; one explicit action installs
or repairs missing, outdated, or repair-needed integrations sequentially, then
re-probes. Results remain per-agent, so one failure does not conceal successful
or already-current integrations. An unsupported agent, a missing/stale native
reference, or an agent-side resume failure cannot be promised to restore. Herdr
0.8.2 enables `[session] resume_agents_on_restore` by default, but a host can
disable it globally; a current integration is insufficient while that setting
is false, and the Host Setup readiness card does not change it.

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
| `Core/HerdrIntegrationManager.swift` | Detect supported agents and verify/provision native restore integrations |
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
