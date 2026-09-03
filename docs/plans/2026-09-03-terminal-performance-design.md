# Event-Driven Terminal Performance Design

**Date:** 2026-09-03

## Goal

Remove the terminal renderer's accumulating main-thread and memory cost while
keeping Herdr tabs live, responsive, and remotely scrollable. Herdr owns pane
history; the iPad retains only the current Herdr viewport.

## Current failure mode

The scroll host creates a layout feedback loop. `viewDidLayoutSubviews()`
schedules a top/bottom anchor operation, and that operation invalidates and
forces layout again. The resulting layout schedules another anchor operation
even when the offset is already correct.

Each `TerminalEmulator` also owns a permanently scheduled `CADisplayLink`.
Hidden tabs lower it to roughly eight frames per second but do not stop it, so
every tab that has been selected adds a permanent main-run-loop wakeup. On a
render update, the hosting controller receives a complete SwiftUI root value,
and the row body traverses a non-lazy array of type-erased row views.

The prior display-link fix retires links whose emulator has been destroyed. It
does not address the live layout feedback loop or links retained by open hidden
tabs.

## History ownership

Herdr panes already own live scrollback on the host. In the alternate screen,
the app forwards scroll gestures as terminal wheel events, and Herdr redraws
the requested historical viewport. Explicit paging through `herdr pane read`
is not used: the command exposes trailing snapshots rather than a stable page
cursor, would resend overlapping content, and cannot reconstruct arbitrary
alternate-screen ANSI state.

`HerdrHostSession` creates a viewport-only terminal with zero local scrollback.
Interactive setup command sheets retain their existing bounded local
scrollback because they run ordinary shell commands rather than a remote
scrollback-owning TUI.

This design does not enable Herdr's disk-backed `pane_history`. Live history is
available while the host session is alive; visual history lost in a host
restart is not reconstructed. Native supported-agent conversation restore is
a separate Herdr integration feature.

## Render scheduling

PTY callbacks continue appending bytes to a lock-backed inbound buffer. The
buffer also owns a single-flight wake flag, so the first pending chunk requests
main-actor processing and subsequent chunks coalesce behind it.

For a visible terminal, pending work starts a temporary display link. Its next
frame drains the pending bytes, feeds SwiftTerm, rebuilds dirty rows, and then
invalidates the link when no more input or forced repaint remains. There is no
idle display link.

For a hidden terminal, the coalesced main-actor wake drains bytes into
SwiftTerm but skips SwiftUI row production. This keeps the current viewport
state accurate without a periodic timer. Becoming visible forces one complete
viewport rebuild and schedules one render frame.

`stop()` permanently retires the scheduler and ignores later callbacks from a
superseded PTY generation. Visibility suspension is reversible and remains
distinct from permanent session teardown.

## Row representation

The string supplier produces stable, equatable row and run data instead of
`AnyView` values. Rows use their scroll-invariant index as identity. A dirty
terminal row replaces only that row's value, and equatable row views prevent
unchanged rows from reconstructing their text-run tree.

The Herdr row collection is bounded to the current viewport because local
scrollback is zero. The temporary command terminal remains bounded by its
existing configured scrollback limit. Per-row opaque drawing remains initially
to preserve the existing seam-free glyph rendering; profiling can remove it
later only if it remains material.

## Layout and scroll anchoring

Content changes invalidate intrinsic layout once. A single-flight anchor gate
coalesces repeated update and layout callbacks into one post-layout operation.
That operation may set the scroll offset when it is wrong, but it never
invalidates layout itself.

Alternate-screen Herdr content remains pinned to the top. Normal-screen command
output follows the bottom only while the user is already following it. User
interaction cancels or suppresses automatic anchoring exactly as today.

## Failure handling

- Host or PTY loss continues through the existing bounded recovery coordinator.
- Hidden input is processed rather than discarded, preventing terminal-state
  corruption when a tab is selected again.
- If the main actor is temporarily busy, inbound bytes remain ordered in the
  bounded-by-transport pending burst; the renderer never drops arbitrary ANSI
  deltas.
- A stopped emulator cannot restart its display link or publish row updates.
- Host history remains unavailable after a restart unless the user separately
  opts into Herdr pane-history persistence.

## Verification

Automated tests will prove:

- an idle visible terminal has no active display link after its render settles;
- a hidden terminal has no active display link;
- an output burst schedules one render cycle rather than one task per chunk;
- hidden output updates SwiftTerm state without publishing rows;
- selecting a hidden terminal forces one viewport repaint;
- Herdr terminals retain zero local scrollback and never grow beyond their
  viewport, while command terminals retain bounded local history;
- repeated layout callbacks coalesce and anchoring cannot trigger another
  layout invalidation;
- remote scroll gestures still produce Herdr wheel events;
- stopped sessions and dismissed command sheets retire all scheduling;
- the complete unit suite remains green.

A manual Instruments pass will compare idle main-thread wakeups, sustained
output, tab switching, and memory before and after the change. Real-host tests
remain opt-in and must not stop a user's Herdr server.

## Implementation result and verification

Automated verification on 2026-09-03:

- `xcodegen generate` exited 0, produced no tracked project-file change, and
  included `TerminalFrameClock.swift` in the generated application source
  phase.
- The complete `MultiSessionAIManagerTests` run on the iPad Pro 13-inch (M5)
  iOS Simulator exited 0 with 607 tests executed: 606 passed, 1 intentionally
  skipped live SSH diagnostic (`realSSHTransportRunsCommandAndOpensPTY()`), and
  0 failed.
- The Release build for `generic/platform=iOS Simulator` exited 0 with
  `BUILD SUCCEEDED` and no Swift concurrency errors. Xcode emitted one
  unrelated metadata warning because the app has no App Intents framework
  dependency.
- The removed-hazard search found no permanent frame-rate setting, legacy
  display-link startup/proxy, `[AnyView]` row array, or `Array(zip(...))` row
  traversal. The post-layout anchor search found no layout invalidation in the
  anchor path. `CADisplayLink` is isolated to
  `DisplayLinkTerminalFrameClock` in `TerminalFrameClock.swift`, and the only
  direct `isVisible` assignment is internal to `TerminalEmulator`.

### Manual device Instruments acceptance — NOT RUN / pending

These checks require a physical iPad Instruments pass; they are acceptance
criteria, not measured results:

- idle on one selected Herdr tab: no continuously running terminal display
  link;
- ten open hidden tabs: no terminal frame timers and no growing SwiftUI row
  stores;
- sustained agent output: one temporary display link per visible burst, then
  it retires;
- select a previously hidden tab: one current-viewport repaint;
- scroll inside Herdr: the host redraws older/newer pane content while iPad row
  count remains viewport-bounded;
- repeat tab switching/output for ten minutes under Time Profiler and
  Allocations: no upward idle-wakeup slope and no retained row-tree growth.

No device performance numbers are claimed until this pending Instruments pass
is run.
