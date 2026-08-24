# The terminal

Each tab is one SSH PTY running `herdr`, painted by a custom SwiftUI renderer
over SwiftTerm's emulator. Herdr owns everything inside the pane; the app owns
getting input to it and pixels back.

## Text selection

Selection is **modal**, reached with the **⬚** button in the top bar.

It works that way because a one-finger drag is already scrollback. An inline
long-press-to-select recognizer competed with the scroll view's pan and lost —
so entering a mode removes the arbitration problem instead of trying to win it.

While selecting:

- scrollback panning is off, and touches are not forwarded to Herdr — otherwise
  a drag would scrub Herdr's own selection while fighting the local one;
- the keyboard is not raised, because that resizes the grid (SIGWINCH) and
  reflows the very text being selected;
- dragging near the top or bottom edge auto-scrolls, so a selection can run past
  what is on screen.

**📄 Copy** puts the selection on the iPad pasteboard. It is inert until a range
exists, so the control states plainly whether tapping it will do anything.

## Sending files in

The **paperclip** button uploads from the clipboard, Photos, or Files, and types
the resulting remote path into the pane. See [file-transfer.md](file-transfer.md).

## Pointer and touch

| Input | Effect |
|---|---|
| Tap | forwarded to Herdr as a left click (pane focus, border drag) |
| **Right-click** | forwarded as SGR button 2 — raises Herdr's context menu |
| Scroll wheel | forwarded as wheel events |
| One-finger drag | scrollback |
| Pinch | font size |

Right-click is **pointer-only**, and that is enforced by touch type rather than
by `buttonMaskRequired` alone: a finger carries no buttons, so UIKit does not
apply a button mask to direct touches and every tap would otherwise raise the
context menu.

The pan recognizers are restricted the *opposite* way — direct touches only — so
a mouse drag is not swallowed as a scroll before the click lands. The two
restrictions look interchangeable and are not.

## Geometry

The grid is derived from the **scroll view's own bounds**, not the frame the
view was allotted: an ancestor can clip it, and sizing from the allotted frame
tells the remote it has rows there is no room to draw.

One row is held back beyond that. The viewport height is sampled and can be
briefly stale during a resize or first layout; sampled high, Herdr draws rows
that do not fit, and on the alternate screen — which is pinned to the top —
those rows are simply unreachable.

The alternate screen **pins to the top and never follows the tail**. A TUI
repaints a fixed frame and keeps its own scrollback, so there is no tail to
follow, and any mismatch would otherwise be absorbed by hiding the *first* rows —
exactly where Herdr draws its tab bar and pane labels.

A strip is reserved at the bottom for the window-resize grip iPadOS draws in the
corners. That grip consumes clicks before the app sees them, so anything Herdr
puts on its last row would otherwise be unclickable. There is no API to opt a
corner out.

## Agent status verbs

Herdr's sidebar shows agent state as an icon by default. To get the word as
well — `working  claude` — add to the host's `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["state_text", "agent"]]
```

`state_text` is a built-in row token; the default rows simply omit it. Then
`herdr config check` and `herdr server reload-config` — no session restart.
