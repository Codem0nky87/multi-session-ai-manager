# The terminal

Each tab is one SSH PTY running `herdr`, painted by a custom SwiftUI renderer
over SwiftTerm's emulator. Herdr owns everything inside the pane; the app owns
getting input to it and pixels back.

## Text selection

Selection is **modal**, reached with **Select text** behind the scissors button
on the [key bar](#the-key-bar).

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

**Copy selection**, behind the same button, puts the selection on the iPad
pasteboard. It is inert until a range exists, so the control states plainly
whether tapping it will do anything.

## Sending files in

The **paperclip** button on the [key bar](#the-key-bar) uploads from the
clipboard, Photos, or Files, and types
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

## The key bar

Under the terminal floats one pill of icon buttons. An iOS keyboard has no Esc,
Tab, arrows or Control, so the app supplies them. Left to right, in five groups:

| Group | Buttons |
|---|---|
| Typing | keyboard (show or hide it), voice (hold to talk), Esc, Tab, Return |
| Modifiers | Shift, Control, Alt: each is sticky and applies to the next key |
| Moving | up, down, left, right, Home, End, page up, page down |
| Sending | clipboard, shortcuts, function keys, password |
| App | send a file to the host, Apple Intelligence |

The two buttons at the right end belong to the bar itself. The cog opens the
app's settings, whose **Toolbar** section has a switch for every button (kept on
the device). The arrow collapses the bar to a small pill in the bottom-left
corner with only the keyboard button and the way back.

Everything that acts on the terminal is on this bar. The strip above the
terminal only informs: the host tabs, the host's metrics and the state of the
AI providers. With no host open there is no bar, so the cog is in the top strip
for that case alone.

Where the buttons do not fit, on a phone or in a narrow window, the row scrolls
sideways and fades at the edge; the two right-hand buttons stay put. It is one
row on every device. Hiding buttons is how to see more of the rest at once.

**Sticky Shift and Alt** change what the next button types. Shift with an arrow,
Home, End or Tab sends xterm's Shift coding (Codex opens its queued messages on
Shift-Left). Alt with left and right moves a word. Shift or Alt with Return sends
Escape and then Return, which the agent TUIs take as "a new line, do not send".

**Page up and down** send scroll-wheel notches while the host is on its alternate
screen, because a TUI keeps its own scrollback, and the page keys otherwise.

**Clipboard** holds Select text, Copy selection and Paste. Paste is the system's
own paste button, which reads the clipboard without the "allow paste" question a
plain button raises every time.

**Shortcuts** holds the chords that mean the same in every shell, Ctrl-C to
Ctrl-\, one tap each. For any other chord tap Control and then the key.

**Password** types a password saved for this host into its terminal: at a sudo
prompt, say. It is not the SSH sign-in, which uses keys. The first tap offers to
save one; after that a tap asks for Face ID, Touch ID or the passcode and then
types it. Nothing is typed after it, so the Return is pressed by the person who
can see where the cursor is. Press and hold the button to replace or forget the
password. See [the security model](security.md#secrets) for where it is kept.

## Links

A tap on a web address in the terminal asks what to do with it: open it, or
copy it. The address is taken whole when it is drawn over several rows
(`Core/TerminalLinkFinder.swift`).

- **Inside its pane.** A row of the screen is not always one line of one
  program: Herdr draws its sidebar to the left and its panes side by side, each
  behind a vertical line. A link that is too long for its pane goes on in the
  next row of that pane, after the same line, so that is where the rest of it
  is looked for. Looked for at the start of the row instead, a sign-in link
  beside a sidebar full of text was cut off where its first row ended.
- **What is the side of a pane.** A vertical line that runs down from a
  corner, or from the top of the screen. The lines between the columns of a
  table run down from a `┬`; they divide one pane's text, and a link in one
  cell is not joined to the cell under it.
- **When a link goes on below.** When its row is full to the edge of its pane
  (a few columns short still counts, for programs that wrap their own lines),
  when the terminal itself says it ran the row on, or when it stops after a
  separator (`-` `/` `&` `=` `?` `#` `_`), where programs break a link they
  wrap. A link that simply ends its line does not take the first word of the
  next line with it.
- **Where it ends.** At the first character that cannot be part of an address,
  at a row that starts with a link of its own, or at a blank row.
- An address a program marks as a link itself (OSC 8) is taken as marked.

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

While the key bar is collapsed, a strip is reserved at the bottom for the
window-resize grip iPadOS draws in the corners. That grip consumes clicks before
the app sees them, so anything Herdr puts on its last row would otherwise be
unclickable. There is no API to opt a corner out. With the bar open, the bar is
that margin: its pill stops short of both corners. A collapsed bar floats over
the terminal's bottom-left corner and takes no rows from it.

## Agent status verbs

Herdr's sidebar shows agent state as an icon by default. To get the word as
well — `working  claude` — the rows need the `state_text` token:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["state_text", "agent"]]
```

**Install Herdr** and **Update to latest** in AI Manager apply this default
automatically after a successful install: the effective config is resolved
(honouring `HERDR_CONFIG_PATH`, then `XDG_CONFIG_HOME`), the rows are added
only when `ui.sidebar.agents.rows` is unset — custom rows are never
overwritten — and the result is validated with `herdr config check` and
rolled back if the edit broke it. A config that already fails the check is
left untouched and the sheet says so. `state_text` is a built-in row token;
the default rows simply omit it. `herdr server reload-config` applies it
without a session restart.

## Terminal themes

MSAM ships with built-in color palettes (`dark`, `light`, `catppuccin`, `solarizedDark`,
`solarizedLight`, `dracula`, `nord`, `highContrastDark`, `highContrastLight`, `midnight`,
`amber`, `ice`, `colorBlindSafe`), matching Herdr's built-in themes:

- **Global preference**: Set in MSAM Settings (`TerminalPreferencesSection`), persisted in `terminal.theme`.
- **Per-tab theme control**: Each tab's theme can be overridden via the palette button (**🎨**) in the top action bar or through the tab's context menu in the tab strip. When set, that tab's `HerdrHostSession` isolates its `TerminalEmulator` to that palette; unset tabs inherit the global default.
- **Per-view overrides**: Any view hosting `TerminalEmulatorView` can pass an explicit `theme` override.
- **Pane behavior in Herdr**: Within a tab's PTY, Herdr multiplexes split panes into a single terminal grid. When Herdr is configured with its default `panel_bg = "reset"`, all split panes in that tab seamlessly inherit that tab's active terminal theme.
