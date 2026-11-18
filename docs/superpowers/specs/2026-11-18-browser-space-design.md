# Browser Space Design

**Date:** 2026-11-18
**Target:** `MultiSessionAIManager` (iOS / iPadOS 17.0+), Unix hosts running Herdr
**Status:** Approved in conversation on 2026-11-18; implementation follows.

---

## 1. Context and problem

Build 202611181323 added an In App browser whose every request is made by the
SSH host, so a page reachable only from that host (including by a name only it
resolves) opens on the iPad. It was reached through **Port Forwarding → Browse
Through <host>** and covered the whole screen.

That is the wrong place. The request is for the browser to be **a space in the
normal Herdr layout**, opened from where spaces are opened, with the sidebar and
everything else still on screen, and not reached through port forwarding.

The sidebar and its "new" label are drawn by Herdr inside the terminal. The app
does not own them. This design makes the browser a real Herdr space anyway.

## 2. Goals and non-goals

### Goals

1. A browser appears in Herdr's **spaces** list as its own space and is switched
   to, resized, split and closed like any other.
2. While that space's pane is on screen, the page fills the pane; the rest of
   the Herdr layout stays visible and usable.
3. Tapping **new** under spaces offers **Workspace** or **Browser**.
4. The page survives switching spaces, and its address survives a reconnect and
   an app restart.
5. The browser is no longer offered in the Port Forwarding sheet.

### Non-goals

- Several tabs, bookmarks or downloads inside one browser space.
- Showing the page in other terminals attached to the same Herdr. They see the
  placeholder.
- Pictures in the terminal (still refused, see `docs/architecture.md`).
- Windows hosts.
- A host-side command that opens an address on the iPad.

## 3. How it works

```
 Herdr on the host                         AI Manager on the iPad
 ─────────────────                         ──────────────────────
 space "Browser"                           terminal grid (already rendered)
   pane runs the placeholder   ── PTY ──▶    row r: [[AIM-BROWSER 7f3a 113x39]]░░░░
   (marker + fill, redrawn                   rows r+1…: ░░░░░░░░░░░░░░░░░░░░░░░░░
    on every resize)                                │ locate
                                                    ▼
                                           region 7f3a at (col c, row r) 113×39
                                                    │ cells → points
                                                    ▼
                                           browser pane laid over that rectangle
                                           (pages fetched by the host over SSH)
```

A browser space is an ordinary Herdr workspace whose only pane runs a
**placeholder**: a small shell script that paints a marker and a fill and then
waits. The app already renders the terminal; it looks for the marker in its own
grid, reads the pane's rectangle from it, and lays the In App browser over
exactly those cells. Herdr decides where the pane is; the app follows.

### 3.1 The placeholder (`Resources/msam-browser-space.sh`)

Plain POSIX `sh`, no Python. Given an id, it:

- reads the pane's size with `stty size`;
- fills every row with `░` and writes `[[AIM-BROWSER <id> <cols>x<rows>]]` at the
  top left (omitted when the pane is narrower than the marker);
- repaints on `SIGWINCH`;
- ignores `INT`, `QUIT` and `TSTP` so a stray Ctrl-C does not close the space,
  and exits on `HUP` and `TERM`, which is how Herdr closes a pane;
- holds one `sleep` child at a time.

The marker is ASCII so that it cannot be split by a terminal that measures a
character differently. It carries the pane's own size, so the app needs nothing
but the marker's position.

Verified in a throwaway Herdr 0.9.5 session on 2026-11-18: the pane showed 39
rows of fill with the marker on the first, and after the client was resized the
marker read the new size. `stty size` reports one column fewer than
`herdr pane layout` (113 against 114); the marker's number is the one that is
used.

### 3.2 Opening a browser space (`Core/BrowserSpaceCommands.swift`)

Run over the tab's existing SSH connection
(`HerdrHostSession.connection.provisioningCommandRunner`), in the Herdr session
the tab is attached to (`herdr --session <name> …` when the tab names one;
verified to reach a named session):

1. `herdr workspace create --label Browser --focus`, whose JSON answer names the
   new pane.
2. Write the placeholder to `~/.local/share/msam/browser-space.sh` (every time,
   so the host always has this build's version).
3. `herdr pane run <pane> exec sh ~/.local/share/msam/browser-space.sh <id>`.
   `exec` makes the placeholder the pane's process, so closing the space ends
   it, and ending it closes the space.

The id is six hex digits chosen by the app. Failures (not connected, Herdr
missing, a Windows host, Herdr refusing) are shown as a toast with Herdr's own
words where there are any.

### 3.3 Finding it (`Core/BrowserSpaceLocator.swift`)

A pure function from the visible rows to regions:

```swift
struct BrowserSpaceRegion: Equatable {
    let id: String
    let column: Int, row: Int      // top left cell
    let columns: Int, rows: Int    // from the marker
}
enum BrowserSpaceLocator {
    static func regions(in rows: [String]) -> [BrowserSpaceRegion]
}
```

A region is reported only when **every** cell of its rectangle is the fill,
apart from the marker itself. Anything else drawn there (a Herdr menu or dialog
over the pane, a half-finished repaint, a rectangle that runs off the grid)
means the pane is not wholly visible, and the browser must not cover it.
Several regions may be visible at once (a split with two browser panes).

### 3.4 Showing it (`Core/BrowserSpaceModel.swift`, `UI/Browser/`)

`BrowserSpaceModel` (`@MainActor @Observable`, one per host tab) holds:

- the regions currently shown. A region that appears or moves is followed at
  once. A region that disappears is dropped after a short grace period
  (120 ms), so a repaint does not flicker the page while a Herdr menu still
  gets its space promptly;
- one `HostBrowserPage` (the existing web view wrapper) per id, kept while its
  space is off screen so the page is still there on return;
- each id's last address, saved per host in `UserDefaults`
  (`msam.browser-spaces.<host id>`, newest twelve) and loaded when a marker
  with that id is first seen after a reconnect or relaunch.

`HostTerminalView` scans `session.terminal.lines` whenever
`renderGeneration` changes and hands the result to the model. Rows are first
searched for the marker's prefix, so a screen without a browser costs one
substring search per row.

`BrowserSpaceOverlay` sits above `TerminalEmulatorView` in `HostTerminalView`'s
`ZStack` and places one `HostBrowserPane` per region at
`x = column × cellWidth`, `y = row × cellHeight`. Herdr runs on the alternate
screen, which the terminal view pins to the top with no inset, so grid
coordinates are view coordinates. Touches inside the rectangle go to the
browser; everywhere else they reach the terminal as before.

`HostBrowserPane` is the browser without a navigation bar: one compact row
(back, forward, reload or stop, the address field) above the web view, and the
existing notices (connecting, could not connect, the host refused the address,
certificate not trusted with **Visit Anyway**). It replaces
`HostBrowserScreen`.

Pages are fetched exactly as today: through the host's `PortForwardingSession`
and its `HostBrowseModel` proxy. The proxy starts when the first browser region
of a host is seen and stops when the host's tab is closed.

### 3.5 "new" offers a choice (`Core/TerminalNewSpaceButton.swift`)

`TerminalEmulatorView.handleTerminalTap` gains an optional interception hook,
asked before a tap is forwarded (links already return early at the same
place). `HostTerminalView` answers with a pure hit test: the tapped row's
sidebar part must read `new` … `menu` and the tap must be on `new`.

When it matches, a small popover at that cell offers:

- **Workspace**: the original tap is sent to Herdr unchanged. Herdr creates a
  workspace at once on that tap (verified), so this is exactly today's
  behaviour.
- **Browser**: section 3.2.

When the label cannot be found (collapsed sidebar, a Herdr that words it
differently) the tap goes to Herdr as it always did. Because that fallback is
silent, the host tab's long-press menu also gets **New Browser Space**, which
does not depend on what Herdr draws.

### 3.6 What is removed

- The **Browse Through <host>** row and its full-screen cover in
  `SessionWebTunnelSheet`.
- `HostBrowserScreen`. `HostBrowserPage` and the proxy stay.

## 4. Behaviour at the edges

| Situation | What happens |
|---|---|
| Another space is selected | The marker is gone; the browser is hidden, its page kept. |
| A Herdr menu or dialog over the pane | The rectangle is no longer all fill; the browser steps aside until it is. |
| The pane is resized, split, zoomed, the iPad rotated | The placeholder repaints with its new size; the browser follows. |
| The pane is too small for the marker | No marker, no browser; the fill shows. |
| Reconnect or app restart | Herdr repaints the placeholder; the id's last address is loaded. |
| The space is closed in Herdr | The marker never returns; its page is dropped with the tab. |
| Another terminal attached to the same Herdr | It shows the fill and the marker. |
| The link to the host is gone | The pane's own notice says so and offers **Try Again**. |
| Keyboard | Typing goes to whichever was tapped last, the page or the terminal. Herdr's key bindings do not reach Herdr while the page has the keyboard. |

## 5. Testing

- **Placeholder** (Python, `tests/`): run under a real pty; marker format and
  size, fill on every row, repaint after a resize, one `sleep` child, exit on
  `HUP`.
- **Locator** (Swift Testing): a full region, a moved one, two regions, an
  obstructed one, one cut off by the grid edge, a marker inside ordinary text,
  no marker. One test feeds bytes captured from a real Herdr session through
  `TerminalEmulator` and expects the pane's true rectangle.
- **Commands**: the three commands for a named and an unnamed session, quoting,
  parsing Herdr's answer, and Herdr's refusals.
- **Model**: follow at once, drop after the grace period, keep the page across
  a hide, restore the saved address, cap the saved addresses.
- **"new" hit test**: the real sidebar row, a tap beside the label, a collapsed
  sidebar, text that merely contains "new".
- **End to end** (throwaway, on the simulator): the app's own session attached
  to a throwaway Herdr session on a test SSH server; open a browser space, load
  a page through the host, and take a picture of the screen.
- Touch and keyboard behaviour is confirmed on the iPad from a TestFlight build.

## 6. Risks

- **The marker depends on what the terminal shows.** A future Herdr that draws
  something inside the pane's rectangle (a border, a scroll bar) would make the
  region look obstructed and the browser would not appear. The fill would show
  instead, so the failure is visible and harmless.
- **"new" is matched by its text.** Covered by the silent fallback and the tab
  menu entry.
- **The keep-alive beat runs while a browser space exists**, even when it is
  not on screen, because the page may hold connections open.
