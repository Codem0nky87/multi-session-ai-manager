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

### Host-owned agent updates

Agent updating has a deliberately different lifetime from a tab connection.
The app discovers and confirms work, but a per-user host service owns execution
so the iPad can disconnect immediately after enqueueing:

```text
visible AI Agent Updates sheet
  ├─ AgentToolVersionProbe        installed/latest, same owner/channel
  ├─ HerdrAgentInventory         all named/default sessions + native identity
  └─ AgentUpdateManager
       └─ SFTP atomic request → host incoming directory
            └─ helper submit → durable queue
                 └─ Resources/msam-host-agent.py serve
                      ├─ update selected executable(s)
                      └─ roll every eligible supported-agent conversation
```

Opening the sheet creates one host connection and refreshes lazily. Dismissing
it cancels app-side refresh/status work and closes that connection; it does not
cancel the host batch. The sheet does not poll or cache growing terminal
history while hidden.

The request protocol is versioned, tab-separated, size-bounded, and contains
only fixed tool IDs plus prevalidated Herdr identity fields. The app writes it
to a random incoming filename over SFTP and atomically renames it before asking
the helper to `submit`. The helper independently validates the protocol and
moves accepted work to its queue. It permits one current batch, takes a
filesystem lock, and writes phases/attempt counts atomically under
`~/.local/state/msam-agent-updater/`. Logs and status output are bounded and do
not contain SSH keys, passwords, or arbitrary terminal transcripts.

Installation ownership is fail-closed. An unowned launcher is native only at
the fixed `~/.local/bin` path for that tool; multiple owners and other `PATH`
locations require administrator attention. External update, inspection,
signature, and Herdr operations have worker-side wall-clock limits. The worker
must observe a strictly newer version before it reaches the rolling boundary.

The host phase progression is:

```text
queued → updating → [approval_required] → rolling
                                      └─ restored / attention / failed per target
                                               └─ complete | completed_with_failures
```

No target receives `/exit` until every requested executable update has crossed
the durable update boundary. The inventory includes Claude Code, Codex, and
Antigravity targets even when only one tool changed, and pure rolling re-launch
requests (with no executable updates requested) roll and recover active
conversations on current binaries without running package managers. Each target
is re-fetched from Herdr and compared with its original native conversation reference, kind,
pane, and required foreground process before exit. Idle/done agents roll immediately;
working agents stay pending; blocked/unknown/error states receive no input.
Restore calls use only the registry-owned arguments and stop after three failed
attempts. An ordinary pane can never become a target because it has no valid,
current supported-agent identity.

The app follows a batch by its id. `status` describes the batch the worker is
on or, when it is idle, the last one it finished, and a submitted request waits
in the queue for up to two seconds before the worker activates it. Right after
a submit the status therefore still names the previous batch, and that batch
being finished says nothing about the new one. The guided upgrade
(`AgentUpgradeFlow`) queues two batches, the tool update and then the re-launch
of that tool's sessions, and moves on only when the status carries the id it
queued (`AgentBatchWatch`). If a different batch is running when a step starts,
nothing is queued and the step says so.

`approval_required` is also a durable boundary. On macOS, manual policy leaves
Gatekeeper to the signed-in user. The opt-in verified policy resolves the exact
post-update executable, requires strict signature and fixed publisher identity,
requires `spctl --assess --type execute`, re-resolves and compares the inode,
then removes only that file's `com.apple.quarantine` attribute. Any uncertainty
returns to approval without terminating a conversation. There is no AppleScript,
Accessibility automation, root daemon, password storage, or global Gatekeeper
mutation.

`AgentUpdaterInstaller` provisions
`com.codem0nky87.msam-host-agent` as an Aqua per-user LaunchAgent on macOS,
`msam-host-agent.service` as a systemd user unit on Linux, or native
`MSAMHostAgent` under the agent account on Windows. The service owns one metrics
collector, inventory, and a durable update worker (`msam-agent-updater.sh` on
POSIX, `msam-agent-updater-windows.py` on Windows). Metrics readers use SSH exec
streams so terminal wrapping and console escapes cannot corrupt JSON. It verifies
capabilities after install instead of trusting an exec-channel exit status.
macOS requires the user's GUI login domain; Linux requires linger for work to
survive logout. Missing approval produces explicit Test Again instructions and
keeps the host's degraded-setup warning persistent when setup is skipped.

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

## What is waiting on a host

Each host tab shows a small pill beside the host's name when something there
wants the user: red with a count for agents that are **blocked** (waiting for an
answer or a permission), amber for a **rate-limited provider**, blue for agents
that have **finished** and not been looked at. The most severe one wins. A quiet
host shows nothing.

Herdr has no feed of the notifications it pops up. What it reports is the agent
state behind them, `blocked` and `done`, and it clears `done` itself once the
agent's pane is viewed. So the pill follows Herdr's own state and there is
nothing to dismiss in the app.

```
Herdr sessions ──herdr agent list, every 3 s──▶ host service ──agents.json
                                                       │
                             msam-host-agent attention --loop   (one line per change, heartbeat every 15 s)
                                                       │
iPad: HostAttentionCenter ── one SSH connection per host with an open tab ──▶ pill on the tab
```

- **Host side.** `msam-host-agent.py` polls every Herdr session's agents every
  3 seconds (the session list itself every 15) and `attention()` reduces that,
  plus the provider states it already keeps, to a summary. It reports
  `available: false` when it could not read Herdr or the inventory is older than
  30 seconds, because "nothing is known" must not look like "nothing is blocked".
- **The stream.** `attention --loop` prints `MSAM_ATTENTION=<json>` when the
  summary changes and repeats it every 15 seconds. It reads the service's state
  files and calls nothing.
- **App side.** `HostAttentionCenter` keeps one `HostAttentionWatch` per host
  that has a tab open, including tabs not opened since launch. A watch is its
  own SSH connection carrying only that stream: no terminal, no metrics, and no
  attach to Herdr, so it never takes over the layout of a session the way a
  second terminal client would. Watches run while the app is in front and are
  closed when it goes to the background.

What a watch will not do:

- **Trust a host first.** It connects only to a host whose key is already
  pinned, which happens when the user opens the host. A changed key is left for
  the user to resolve in the host's own tab; the watch neither trusts it nor
  keeps retrying.
- **Believe a quiet socket.** 45 seconds without a line means the stream is
  dead; the pill is removed and the stream reopened. While nothing is known
  there is no pill.
- **Hammer an old host.** A service installed before this command exists ends
  the stream at once without a line; that host is asked again every 10 minutes.
  The service is upgraded the normal way, when its tab connects.

A tab bound to a named Herdr session counts only that session's agents; a tab
on the host as a whole counts every session. A rate limit belongs to the host.

The pill says how many; the tab's long-press menu says which: each agent by
name with the Herdr session it runs in, grouped as *Waiting for you*, *Rate
limited* and *Finished*. Choosing a row goes to that host's tab.

## Module map

| Path | Responsibility |
|---|---|
| `Core/HerdrHostSession.swift` | One tab's live state: connection + PTY + terminal + file bridge |
| `Core/HerdrLaunchCommand.swift` | The remote command and the missing-Herdr sentinel |
| `Core/HerdrInstaller.swift` | Probe / install / verify Herdr on a host (min 0.8.2) |
| `Core/HerdrIntegrationManager.swift` | Detect supported agents and verify/provision native restore integrations |
| `Core/AgentToolUpdate.swift` | Fixed three-tool registry, publisher identities, version parsing/probes |
| `Core/HerdrAgentInventory.swift` | Fail-closed Herdr inventory and native conversation identity validation |
| `Core/AgentUpdateRequest.swift` | Validated durable request/status line protocols |
| `Core/AgentUpdateManager.swift` | Visible-sheet refresh, preview, generation fencing, and atomic host enqueue |
| `Core/AgentUpdaterInstaller.swift` | Per-user LaunchAgent/systemd installation and capability verification |
| `Resources/msam-agent-updater.sh` | Host-owned durable update/rolling-restore worker |
| `Core/HostHelperScript.swift` | On-demand host helpers uploaded by content hash (`msam-host-software.py`, `msam-disk-usage.py`) |
| `Core/VolumeUsage*.swift` | Largest files on a volume: the scan request and the per-host result cache |
| `Core/HostAttention*.swift` | What is waiting on a host: the summary, and the background connection per host that keeps it current |
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

### No pictures

The terminal shows text only. SwiftTerm's core does understand the kitty
graphics protocol, though: it answers "supported" when a program asks, and
decodes and keeps every picture it is sent, while the app's own renderer draws
none of them. So `TerminalPictureFilter` removes picture commands
(`ESC _ G … ESC \`) from a host's output before the core sees it. The core then
has no question to answer, and nothing to decode.

When a command that draws arrives, `TerminalEmulator.isRefusingPictures` turns
on and the tab shows **Pictures are not supported**, until a few seconds after
the last one or until dismissed. A program that only asks is not announced.

The filter cannot stop the pictures from being sent. Under Herdr the app is
never asked: Herdr tells every program in a pane that pictures work (measured
on 0.9.5) and forwards them to each attached client as whole uncompressed
frames, about 3.8 MB each for a full pane and 14 MB/s from a browser running in
one. Over a slow link that stream alone freezes the session. Only Herdr can
stop it, with `kitty_graphics = false` under `[terminal]` in the host's Herdr
config: clients that attach afterwards get no pictures, and once Herdr has
restarted, programs are told there are none. For the same reason the plugin
manager does not install plugins that draw pictures (see
[host setup](host-setup.md#plugins-that-draw-pictures)).

### The grid the host draws for

The text size only changes the app's cell metrics; what the host draws for is the
grid (columns × rows) the app sends it. Two things have to hold for the size in
Settings to be the size on screen, and both were once broken.

**The PTY has the grid the app computed.** `TerminalEmulator.resize` only tells
the PTY about a grid that differs from its own, so a size that is lost or
overtaken is never repeated. `PTYResizeSender` therefore delivers sizes one at a
time, in order, ending on the newest (each used to leave in its own task, and of
two computed milliseconds apart the older could land last), and a session
re-sends the grid if it changed while its PTY was still opening.

**Herdr is laying the session out for this client.** Herdr keeps one layout for
a whole session, every space and tab, and gives it to the client that last
attached, changed size, typed, clicked inside a pane, or regained focus. With a
host open on two devices the other one's use leaves this one showing panes laid
out for a different grid, and re-sending an unchanged size does nothing. The app
reports focus the way any terminal does (xterm mode 1004, which Herdr switches
on): lost when a terminal leaves view, gained when its tab is shown or the app
returns to the foreground. A tap also reports lost-then-gained, at most once a
second, because a tap on Herdr's own sidebar, which is how a space or a pane is
opened, does not claim the layout by itself. Herdr acts on focus being
*regained*; when this client already has the layout it resizes nothing.

To see the layout a session currently has, ask for a pane's area on the host:
`herdr pane layout --pane <id>` (120×40 means no client is attached).
