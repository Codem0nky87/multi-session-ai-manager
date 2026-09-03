# Event-Driven Terminal Performance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the terminal's accumulating layout, timer, and row-view costs while keeping Herdr scrollback on the host and repainting only the selected tab on demand.

**Architecture:** Replace each emulator's permanent display link with a coalesced, demand-driven frame clock: hidden terminals drain PTY bytes into SwiftTerm without publishing SwiftUI rows, while a visible terminal starts a temporary clock only until its pending work settles. Give Herdr terminals zero client scrollback so Herdr remains the history owner, represent rendered rows as stable equatable values, and make scroll anchoring a single-flight post-layout operation that never invalidates layout itself.

**Tech Stack:** Swift 6, SwiftUI, UIKit (`UIScrollView`/`UIHostingController`), QuartzCore (`CADisplayLink`), SwiftTerm, Swift Testing, XcodeGen, XCTest/Xcode Simulator.

---

Implementation work happens in:

```text
/Users/rufus/Projects/multi-session-ai-manager/.worktrees/terminal-performance
```

The baseline is 560 passing unit tests with one intentionally skipped live SSH diagnostic. Run every command below from `app/MultiSessionAIManager` unless a step says otherwise.

### Task 1: Make layout anchoring single-flight

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalEmulatorView.swift:785-876`
- Modify: `app/MultiSessionAIManager/Tests/TerminalGridSizingTests.swift:84-106`

**Step 1: Write the failing gate tests**

Add tests beside `TerminalScrollAnchorTests` for a small value-type gate that permits only one queued anchor operation and permits another only after the first is consumed:

```swift
@Suite struct TerminalLayoutAnchorGateTests {
    @Test func repeatedRequestsCoalesceUntilThePendingAnchorRuns() {
        var gate = TerminalLayoutAnchorGate()

        #expect(gate.request())
        #expect(!gate.request())
        #expect(gate.consume())
        #expect(!gate.consume())
        #expect(gate.request())
    }

    @Test func cancellingDropsTheQueuedAnchor() {
        var gate = TerminalLayoutAnchorGate()

        #expect(gate.request())
        gate.cancel()

        #expect(!gate.consume())
        #expect(gate.request())
    }
}
```

**Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalLayoutAnchorGateTests test
```

Expected: compilation fails because `TerminalLayoutAnchorGate` does not exist.

**Step 3: Add the minimal gate**

Add this internal helper near `TerminalScrollAnchor` so the test target can exercise the state machine without constructing UIKit controllers:

```swift
struct TerminalLayoutAnchorGate {
    private var pending = false

    mutating func request() -> Bool {
        guard !pending else { return false }
        pending = true
        return true
    }

    mutating func consume() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }

    mutating func cancel() {
        pending = false
    }
}
```

In `TerminalScrollContainer.Controller`:

- store `private var anchorGate = TerminalLayoutAnchorGate()`;
- replace `scrollToBottomAfterLayout()` and `pinToTopAfterLayout()` scheduling with one `scheduleAnchorAfterLayout()` method;
- call `invalidateHostedContentLayout()` exactly once from `update(...)`, before scheduling;
- allow both `update(...)` and `viewDidLayoutSubviews()` to call the coalescing scheduler;
- inside the dispatched closure, consume the gate, re-check user interaction and current alternate-screen/follow-tail state, then set the top or bottom offset only when it differs;
- do **not** call `invalidateHostedContentLayout()`, `layoutIfNeeded()`, or `setNeedsLayout()` from the dispatched anchor closure;
- cancel a queued anchor when user dragging begins so it cannot fight direct manipulation.

The resulting scheduler should have this shape:

```swift
private func scheduleAnchorAfterLayout() {
    guard anchorGate.request() else { return }
    DispatchQueue.main.async { [weak self] in
        guard let self, self.anchorGate.consume() else { return }
        guard !self.coordinator.isUserInteracting else { return }

        if TerminalScrollAnchor.pinsToTop(isAltScreen: self.coordinator.isAltScreen) {
            let top = -self.scrollView.adjustedContentInset.top
            guard self.scrollView.contentOffset.y != top else { return }
            self.scrollView.setContentOffset(CGPoint(x: self.scrollView.contentOffset.x, y: top),
                                             animated: false)
        } else if self.canAutoFollow {
            let bottom = self.scrollView.bottomContentOffset
            guard self.scrollView.contentOffset != bottom else { return }
            self.scrollView.setContentOffset(bottom, animated: false)
            self.coordinator.onBottomStateChange(true)
        }
    }
}
```

Preserve the existing rules: alternate-screen content pins to top; normal-screen output follows the bottom only when the user is following and not interacting.

**Step 4: Run the layout and terminal-input suites and verify GREEN**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalLayoutAnchorGateTests \
  -only-testing:MultiSessionAIManagerTests/TerminalScrollAnchorTests \
  -only-testing:MultiSessionAIManagerTests/TerminalTouchPolicyTests \
  -only-testing:MultiSessionAIManagerTests/TerminalSelectionAutoScrollTests test
```

Expected: all selected tests pass.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/UI/Terminal/TerminalEmulatorView.swift \
  app/MultiSessionAIManager/Tests/TerminalGridSizingTests.swift
git commit -m "fix: coalesce terminal scroll anchoring"
```

### Task 2: Replace permanent display links with a demand-driven frame clock

**Files:**
- Create: `app/MultiSessionAIManager/UI/Terminal/TerminalFrameClock.swift`
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalEmulator.swift:67-226,269-334,397-451`
- Modify: `app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift:1-40`
- Modify: `app/MultiSessionAIManager/Tests/TerminalGridSizingTests.swift:176-228`
- Modify: `app/MultiSessionAIManager/Tests/HerdrHostSessionTests.swift:108-131`

**Step 1: Write a controllable test clock and failing scheduler tests**

Define a `@MainActor` fake inside `TerminalEmulatorTests.swift`:

```swift
private final class TestTerminalFrameClock: TerminalFrameClock {
    private var action: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var isRunning: Bool { action != nil }

    func start(_ action: @escaping () -> Void) {
        guard self.action == nil else { return }
        startCount += 1
        self.action = action
    }

    func stop() {
        guard action != nil else { return }
        stopCount += 1
        action = nil
    }

    func fire() { action?() }
}
```

Add these tests, using `await Task.yield()` after `feed` so the coalesced main-actor wake can run:

```swift
@Test func idleTerminalHasNoScheduledFrame() {
    let clock = TestTerminalFrameClock()
    _ = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
    #expect(!clock.isRunning)
}

@Test func anInputBurstStartsOneFrameAndStopsWhenSettled() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)

    for byte in "hello".utf8 { emulator.feed(Data([byte])) }
    await Task.yield()

    #expect(clock.startCount == 1)
    clock.fire()
    #expect(emulator.coreCursorColumn == 5)
    #expect(!emulator.lines.isEmpty)
    #expect(!clock.isRunning)
}

@Test func hiddenInputDrainsWithoutStartingAFrameOrPublishingRows() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
    emulator.isVisible = false

    emulator.feed(Data("hello".utf8))
    await Task.yield()

    #expect(emulator.coreCursorColumn == 5)
    #expect(emulator.lines.isEmpty)
    #expect(!clock.isRunning)
}

@Test func showingAHiddenTerminalRequestsExactlyOneViewportFrame() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
    emulator.isVisible = false
    emulator.feed(Data("hello".utf8))
    await Task.yield()

    emulator.isVisible = true
    #expect(clock.startCount == 1)
    clock.fire()

    #expect(!emulator.lines.isEmpty)
    #expect(!clock.isRunning)
}

@Test func stoppedTerminalCannotRestartFromLateOutput() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(frameClock: clock)
    emulator.stop()
    emulator.feed(Data("late".utf8))
    await Task.yield()

    #expect(clock.startCount == 0)
    #expect(emulator.coreCursorColumn == 0)
}
```

Update the old lifecycle expectations: construction is idle with no clock, output causes a temporary clock, and session teardown leaves it stopped. Remove tests that treat a permanent link immediately after initialization as healthy behavior.

**Step 2: Run the focused suites and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalEmulatorTests \
  -only-testing:MultiSessionAIManagerTests/TerminalRenderLoopLifecycleTests \
  -only-testing:MultiSessionAIManagerTests/HerdrHostSessionTests test
```

Expected: compilation fails because `TerminalFrameClock` and the injected initializer do not exist, and old lifecycle assertions still expose the permanent clock.

**Step 3: Introduce the production frame clock**

Create an internal `@MainActor` protocol and a `CADisplayLink` implementation:

```swift
@MainActor
protocol TerminalFrameClock: AnyObject {
    var isRunning: Bool { get }
    func start(_ action: @escaping () -> Void)
    func stop()
}

@MainActor
final class DisplayLinkTerminalFrameClock: TerminalFrameClock {
    private var displayLink: CADisplayLink?
    private var action: (() -> Void)?
    private lazy var proxy = Proxy(owner: self)

    var isRunning: Bool { displayLink != nil }

    func start(_ action: @escaping () -> Void) {
        guard displayLink == nil else { return }
        self.action = action
        let link = CADisplayLink(target: proxy, selector: #selector(Proxy.fire))
        proxy.link = link
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        action = nil
    }

    fileprivate func fire() { action?() }

    private final class Proxy: NSObject {
        weak var owner: DisplayLinkTerminalFrameClock?
        weak var link: CADisplayLink?
        init(owner: DisplayLinkTerminalFrameClock) { self.owner = owner }
        @MainActor @objc func fire() {
            guard let owner else {
                link?.invalidate()
                return
            }
            owner.fire()
        }
    }
}
```

Keep the weak proxy so a missed teardown cannot leave an emulator retained by a run-loop timer.

**Step 4: Make the inbound buffer coalesce wakeups and support permanent shutdown**

Change `InboundBuffer.append` to return `true` only for the transition from no queued wake to queued wake. Under the same lock, add:

```swift
private var wakeQueued = false
private var acceptingInput = true

func append(_ newBytes: [UInt8]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard acceptingInput else { return false }
    bytes.append(contentsOf: newBytes)
    guard !wakeQueued else { return false }
    wakeQueued = true
    return true
}

func drain() -> [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    let drained = bytes
    bytes.removeAll(keepingCapacity: true)
    wakeQueued = false
    return drained
}

func shutdown() {
    lock.lock()
    acceptingInput = false
    wakeQueued = false
    bytes.removeAll(keepingCapacity: false)
    lock.unlock()
}

var hasPendingBytes: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !bytes.isEmpty
}
```

This lock ordering avoids a lost wake: an append after a drain observes `wakeQueued == false` and queues a new main-actor handoff.

**Step 5: Convert `TerminalEmulator` to demand-driven scheduling**

Inject `TerminalFrameClock` with a production default, remove `startDisplayLink()` from `init`, and delete `DisplayLinkProxy`. Preserve `tick()` as an internal render-frame entry point for existing focused tests.

The essential transitions are:

```swift
@ObservationIgnored private let frameClock: TerminalFrameClock
@ObservationIgnored private var stopped = false

nonisolated func feed(_ data: Data) {
    let filtered = Self.dropSizeReportQueries([UInt8](data))
    guard !filtered.isEmpty, inbound.append(filtered) else { return }
    Task { @MainActor [weak self] in self?.inboundBecameReady() }
}

private func inboundBecameReady() {
    guard !stopped else { return }
    if isVisible {
        requestFrame()
    } else {
        drainIntoCore()
    }
}

private func requestFrame() {
    guard !stopped, !frameClock.isRunning else { return }
    frameClock.start { [weak self] in self?.tick() }
}

func tick() {
    guard !stopped else { return }
    drainIntoCore()
    guard isVisible else {
        frameClock.stop()
        return
    }
    renderDirtyRowsOrForcedViewport()
    if !inbound.hasPendingBytes && !forceFullRebuild {
        frameClock.stop()
    }
}
```

Also:

- when visibility becomes false, stop the clock and immediately drain any queued bytes without building rows;
- when visibility becomes true, set `forceFullRebuild`, reset the last cursor, and request one frame;
- make `setFontSize`, `setTheme`, and a real `resize` request a frame after marking the viewport dirty;
- make `stop()` idempotently set `stopped`, stop the clock, and call `inbound.shutdown()`;
- expose `isRenderLoopRunning` as `frameClock.isRunning` so lifecycle tests retain a useful diagnostic;
- update comments to describe event-driven processing rather than a perpetual timer.

Do not wrap `terminal.feed` in a per-chunk `Task`; only the first buffered chunk schedules the main-actor handoff.

**Step 6: Make existing manual-render tests deterministic**

Tests that currently call `stop()` before `feed` use `stop()` as a timer-control hack. Replace that pattern with an injected `TestTerminalFrameClock`, call `feed`, `await Task.yield()`, then `clock.fire()`. Keep `stop()` exclusively for permanent teardown tests.

**Step 7: Run scheduler and lifecycle tests and verify GREEN**

Run the command from Step 2 again.

Expected: all selected tests pass; idle and hidden clocks report stopped after work settles.

**Step 8: Commit**

```bash
git add app/MultiSessionAIManager/UI/Terminal/TerminalFrameClock.swift \
  app/MultiSessionAIManager/UI/Terminal/TerminalEmulator.swift \
  app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift \
  app/MultiSessionAIManager/Tests/TerminalGridSizingTests.swift \
  app/MultiSessionAIManager/Tests/HerdrHostSessionTests.swift
git commit -m "perf: render terminals only on demand"
```

### Task 3: Make Herdr the scrollback owner

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalEmulator.swift:97-115`
- Modify: `app/MultiSessionAIManager/Core/HerdrHostSession.swift:132-154`
- Modify: `app/MultiSessionAIManager/Core/InteractiveCommandSession.swift:20-34`
- Modify: `app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift`
- Modify: `app/MultiSessionAIManager/Tests/HerdrHostSessionTests.swift`
- Modify: `app/MultiSessionAIManager/Tests/BuildToolchainInstallerTests.swift:146-195`
- Verify: `app/MultiSessionAIManager/Tests/TerminalMouseTests.swift`

**Step 1: Write failing history-ownership tests**

Add a type-safe policy and assert it through the session boundaries rather than relying only on line counts:

```swift
@Test func herdrUsesHostOwnedHistory() async throws {
    let session = try makeSession(transport: FakeSSHTransport())
    #expect(session.terminal.history == .hostOwned)
    #expect(session.terminal.localScrollbackLimit == 0)
}

@Test func interactiveCommandsKeepBoundedLocalHistory() {
    let session = session("true")
    #expect(session.terminal.history == .local(limit: 1_000))
}
```

Add a viewport-bound regression using the test clock:

```swift
@Test func hostOwnedHistoryPublishesOnlyTheCurrentViewport() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(cols: 30, rows: 6,
                                    history: .hostOwned,
                                    frameClock: clock)
    emulator.feed(Data((0..<2_000).map { "line\($0)\r\n" }.joined().utf8))
    await Task.yield()
    clock.fire()

    #expect(emulator.lines.count <= emulator.rows)
    #expect(emulator.visibleText().contains("line1999"))
}
```

Keep the existing scrollback-trim selection test on the default local policy so command-terminal selection coverage is not lost.

**Step 2: Run the focused suites and verify RED**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalEmulatorTests \
  -only-testing:MultiSessionAIManagerTests/HerdrHostSessionTests \
  -only-testing:MultiSessionAIManagerTests/InteractiveCommandSessionTests test
```

Expected: compilation fails because `TerminalHistoryPolicy`, `history`, and the configurable initializer do not exist.

**Step 3: Add explicit terminal history policies**

Add near `TerminalEmulator`:

```swift
enum TerminalHistoryPolicy: Equatable, Sendable {
    case hostOwned
    case local(limit: Int)

    var localLimit: Int {
        switch self {
        case .hostOwned: 0
        case .local(let limit): max(limit, 0)
        }
    }
}
```

Change the initializer to accept `history: TerminalHistoryPolicy = .local(limit: 1_000)`, store it as an internal read-only property, expose `localScrollbackLimit`, and pass that value to `TerminalOptions.scrollback`.

Default `HerdrHostSession` to:

```swift
terminal: TerminalEmulator = TerminalEmulator(history: .hostOwned)
```

Leave `InteractiveCommandSession` on `TerminalEmulator()` so one-off shell/setup terminals retain the existing 1,000-line local bound.

Do not enable Herdr `pane_history` or add a client paging cache. Herdr's alternate screen remains pinned and existing pan/wheel paths continue calling `TerminalEmulator.scrollWheel`, which asks the running host process to redraw older or newer content.

**Step 4: Run history and remote-scroll tests and verify GREEN**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalEmulatorTests \
  -only-testing:MultiSessionAIManagerTests/HerdrHostSessionTests \
  -only-testing:MultiSessionAIManagerTests/InteractiveCommandSessionTests \
  -only-testing:MultiSessionAIManagerTests/TerminalMouseTests \
  -only-testing:MultiSessionAIManagerTests/TerminalTouchPolicyTests test
```

Expected: all selected tests pass; Herdr row storage stays at viewport size and alternate-screen wheel bytes are unchanged.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/UI/Terminal/TerminalEmulator.swift \
  app/MultiSessionAIManager/Core/HerdrHostSession.swift \
  app/MultiSessionAIManager/Core/InteractiveCommandSession.swift \
  app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift \
  app/MultiSessionAIManager/Tests/HerdrHostSessionTests.swift \
  app/MultiSessionAIManager/Tests/BuildToolchainInstallerTests.swift
git commit -m "perf: keep Herdr scrollback on the host"
```

### Task 4: Replace type-erased row views with stable equatable row data

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalStringSupplier.swift`
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalEmulator.swift:24-36,174-226`
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalEmulatorView.swift:196-225`
- Modify: `app/MultiSessionAIManager/Tests/TerminalRunSplitterTests.swift`
- Modify: `app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift`

**Step 1: Write failing stable-row tests**

Extend `TerminalRunSplitterTests`:

```swift
@Test func renderedRunsCarryStablePositionalIDsAndColumnCounts() {
    let attribute = Attribute.empty
    let row = TerminalRenderedRow.make(
        id: 7,
        runs: TerminalRunSplitter.runs(cells: [
            (char: "a", attribute: attribute, isCursor: false),
            (char: "b", attribute: attribute, isCursor: false)
        ])
    )

    #expect(row.id == 7)
    #expect(row.runs.map(\.id) == [0])
    #expect(row.runs.map(\.columns) == [2])
    #expect(row.runs.map(\.text) == ["ab"])
}
```

Extend `TerminalEmulatorTests` to prove a single-row edit preserves all unaffected row values:

```swift
@Test func dirtyRowRenderingPreservesUnchangedRowValues() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
    emulator.feed(Data("one\r\ntwo".utf8))
    await Task.yield()
    clock.fire()
    let before = emulator.lines

    emulator.feed(Data("!".utf8))
    await Task.yield()
    clock.fire()

    #expect(emulator.lines[0] == before[0])
    #expect(emulator.lines[1] != before[1])
}
```

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalRunSplitterTests \
  -only-testing:MultiSessionAIManagerTests/TerminalEmulatorTests test
```

Expected: compilation fails because `TerminalRenderedRow` does not exist and `lines` still contains `AnyView`.

**Step 3: Introduce value-based rows and runs**

In `TerminalStringSupplier.swift`, add:

```swift
struct TerminalRenderedRun: Identifiable, Equatable {
    let id: Int
    let text: String
    let attribute: Attribute
    let isCursor: Bool
    let columns: Int
}

struct TerminalRenderedRow: Identifiable, Equatable {
    let id: Int
    let runs: [TerminalRenderedRun]

    static func make(
        id: Int,
        runs: [(text: String, attribute: Attribute, isCursor: Bool)]
    ) -> Self {
        Self(id: id, runs: runs.enumerated().map { index, run in
            TerminalRenderedRun(
                id: index,
                text: run.text,
                attribute: run.attribute,
                isCursor: run.isCursor,
                columns: run.text.unicodeScalars.reduce(0) {
                    $0 + UnicodeUtil.columnWidth(rune: $1)
                }
            )
        })
    }
}
```

Change `TerminalStringSupplier.attributedString(...)` into `row(forScrollInvariantRow:) -> TerminalRenderedRow`. It should read SwiftTerm cells and split runs exactly as today, but return data rather than `AnyView`. Missing lines become a row with the requested id and no runs.

Change `TerminalEmulator.lines` to `[TerminalRenderedRow]`. When growing the array, append empty rows whose `id` equals their scroll-invariant index. Dirty-row replacement keeps all other array elements equal and unchanged.

**Step 4: Move SwiftUI construction into an equatable row view**

Add `TerminalRenderedRowView: View, Equatable` in `TerminalStringSupplier.swift`. It receives one row, `TerminalColorMap`, `TerminalFontMetrics`, and a `styleGeneration`. Its custom equality compares `row` and `styleGeneration`; its body performs the existing foreground/background/font/inverse/underline/strikethrough logic for each run.

```swift
struct TerminalRenderedRowView: View, Equatable {
    let row: TerminalRenderedRow
    let colorMap: TerminalColorMap
    let fontMetrics: TerminalFontMetrics
    let styleGeneration: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.styleGeneration == rhs.styleGeneration
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(row.runs) { run in
                terminalText(run)
            }
        }
    }
}
```

Preserve exact run width, font fallback isolation, backgrounds, and cursor inverse rendering from the old supplier.

Add `private(set) var renderStyleGeneration = 0` to the emulator and increment it when font size or theme changes. In `TerminalEmulatorView.rowsContent`, remove `Array(zip(...))` and render values directly:

```swift
ForEach(emulator.lines) { row in
    TerminalRenderedRowView(
        row: row,
        colorMap: emulator.colorMap,
        fontMetrics: emulator.fontMetrics,
        styleGeneration: emulator.renderStyleGeneration
    )
    .equatable()
    .frame(/* preserve existing exact row frame */)
    .background(backgroundColor)
    .drawingGroup(opaque: true)
    .id(row.id)
}
```

Keep `.drawingGroup(opaque: true)` in this pass; removing it changes seam/glyph behavior and is outside the approved scope.

**Step 5: Run renderer tests and verify GREEN**

Run the command from Step 2, then also run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalEraseTests \
  -only-testing:MultiSessionAIManagerTests/TerminalThemeTests \
  -only-testing:MultiSessionAIManagerTests/TerminalFontMetricsTests \
  -only-testing:MultiSessionAIManagerTests/TerminalSelectionModeTests test
```

Expected: all selected tests pass and no production `AnyView` remains in terminal row storage.

**Step 6: Commit**

```bash
git add app/MultiSessionAIManager/UI/Terminal/TerminalStringSupplier.swift \
  app/MultiSessionAIManager/UI/Terminal/TerminalEmulator.swift \
  app/MultiSessionAIManager/UI/Terminal/TerminalEmulatorView.swift \
  app/MultiSessionAIManager/Tests/TerminalRunSplitterTests.swift \
  app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift
git commit -m "perf: render stable terminal row values"
```

### Task 5: Integrate visibility, scrolling, and session teardown regressions

**Files:**
- Modify: `app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift`
- Modify: `app/MultiSessionAIManager/Tests/TerminalGridSizingTests.swift`
- Modify if needed: `app/MultiSessionAIManager/UI/Terminal/TerminalEmulatorView.swift`
- Modify if needed: `app/MultiSessionAIManager/Core/HerdrHostSession.swift`
- Modify if needed: `app/MultiSessionAIManager/Core/InteractiveCommandSession.swift`

**Step 1: Add end-to-end state-transition tests**

Add regressions that cover transitions which isolated component tests do not:

```swift
@Test func outputArrivingWhileVisibilityChangesIsRenderedOnceWhenSelected() async {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(cols: 20, rows: 5,
                                    history: .hostOwned,
                                    frameClock: clock)
    emulator.isVisible = false
    emulator.feed(Data("hidden".utf8))
    await Task.yield()
    #expect(emulator.renderGeneration == 0)

    emulator.isVisible = true
    emulator.feed(Data(" selected".utf8))
    await Task.yield()
    #expect(clock.startCount == 1)
    clock.fire()

    #expect(emulator.visibleText().contains("hidden selected"))
    #expect(emulator.renderGeneration == 1)
    #expect(!clock.isRunning)
}

@Test func repeatedVisibilityAssignmentsDoNotScheduleExtraFrames() {
    let clock = TestTerminalFrameClock()
    let emulator = TerminalEmulator(frameClock: clock)

    emulator.isVisible = true
    emulator.isVisible = true

    #expect(clock.startCount == 0)
}
```

Keep or update session teardown assertions so `HerdrHostSession.stop()` and `InteractiveCommandSession.stop()` both permanently stop pending frame work and clear their PTY binding.

**Step 2: Run transition tests and verify RED if integration is incomplete**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalEmulatorTests \
  -only-testing:MultiSessionAIManagerTests/TerminalRenderLoopLifecycleTests \
  -only-testing:MultiSessionAIManagerTests/HerdrHostSessionTests \
  -only-testing:MultiSessionAIManagerTests/InteractiveCommandSessionTests test
```

Expected: any missing visibility/teardown transition fails deterministically, without timing a real display link.

**Step 3: Apply only the integration fixes exposed by the tests**

Check these invariants in production code:

- `TerminalEmulatorView.onAppear` makes only the selected mounted terminal visible;
- `onDisappear` suspends rendering but does not permanently stop a still-owned tab;
- session `stop()` remains the sole permanent emulator teardown path;
- a visibility change to hidden drains already queued inbound bytes before stopping frame work;
- a visibility change back to visible forces exactly one full current-viewport repaint;
- alternate-screen pointer and touch gestures still forward remote wheel events and do not attempt local app scrollback.

Avoid adding polling, timers, client paging, or another cache.

**Step 4: Run all terminal-related tests and verify GREEN**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/TerminalEmulatorTests \
  -only-testing:MultiSessionAIManagerTests/TerminalRenderLoopLifecycleTests \
  -only-testing:MultiSessionAIManagerTests/TerminalLayoutAnchorGateTests \
  -only-testing:MultiSessionAIManagerTests/TerminalScrollAnchorTests \
  -only-testing:MultiSessionAIManagerTests/TerminalRunSplitterTests \
  -only-testing:MultiSessionAIManagerTests/TerminalMouseTests \
  -only-testing:MultiSessionAIManagerTests/TerminalTouchPolicyTests \
  -only-testing:MultiSessionAIManagerTests/TerminalSelectionModeTests \
  -only-testing:MultiSessionAIManagerTests/TerminalSelectionAutoScrollTests \
  -only-testing:MultiSessionAIManagerTests/TerminalEraseTests \
  -only-testing:MultiSessionAIManagerTests/TerminalThemeTests test
```

Expected: all terminal-related tests pass.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/UI/Terminal/TerminalEmulatorView.swift \
  app/MultiSessionAIManager/Core/HerdrHostSession.swift \
  app/MultiSessionAIManager/Core/InteractiveCommandSession.swift \
  app/MultiSessionAIManager/Tests/TerminalEmulatorTests.swift \
  app/MultiSessionAIManager/Tests/TerminalGridSizingTests.swift
git commit -m "test: cover terminal performance transitions"
```

If Step 3 required no production edits, commit only the new regression tests.

### Task 6: Verify the full app and document the profiling handoff

**Files:**
- Modify: `docs/plans/2026-09-03-terminal-performance-design.md`
- Verify: `app/MultiSessionAIManager/project.yml`
- Verify: entire unit-test target

**Step 1: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
```

Expected: generation succeeds and includes `TerminalFrameClock.swift` automatically through the `UI` source directory.

**Step 2: Run the complete unit suite**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests test
```

Expected: all unit tests pass; the existing live SSH diagnostic may remain intentionally skipped. Record the exact test count in the design document's verification section.

**Step 3: Run a release build**

Run:

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: `BUILD SUCCEEDED` with no Swift concurrency errors.

**Step 4: Check for the removed performance hazards**

Run:

```bash
rg -n 'preferredFrameRateRange|startDisplayLink|DisplayLinkProxy|\[AnyView\]|Array\(zip\(' \
  UI/Terminal Core Tests
```

Expected: no permanent/hidden frame-rate throttling, old proxy, type-erased row array, or zipped row traversal remains. A `CADisplayLink` reference should exist only inside `DisplayLinkTerminalFrameClock`.

Run:

```bash
rg -n -U 'AfterLayout[\s\S]{0,900}(invalidateIntrinsicContentSize|layoutIfNeeded|setNeedsLayout)' \
  UI/Terminal/TerminalEmulatorView.swift
```

Expected: no match; anchor application cannot restart layout.

**Step 5: Record manual Instruments acceptance checks**

Append a short implementation-result block to the design document with the automated test count and these device checks for the next iPad run:

- idle on one selected Herdr tab: no continuously running terminal display link;
- ten open hidden tabs: no terminal frame timers and no growing SwiftUI row stores;
- sustained agent output: one temporary display link per visible burst, then it retires;
- select a previously hidden tab: one current-viewport repaint;
- scroll inside Herdr: the host redraws older/newer pane content while iPad row count remains viewport-bounded;
- repeat tab switching/output for ten minutes under Time Profiler and Allocations: no upward idle-wakeup slope and no retained row-tree growth.

Do not claim device performance numbers until this Instruments pass is actually run.

**Step 6: Commit verification notes**

```bash
git add docs/plans/2026-09-03-terminal-performance-design.md
git commit -m "docs: record terminal performance verification"
```

**Step 7: Perform final branch checks**

Use `@verification-before-completion`, then run from the worktree root:

```bash
git status --short
git log --oneline --decorate main..HEAD
```

Expected: clean worktree and a reviewable sequence of focused commits. Do not merge, push, or delete the worktree without the user's explicit choice at handoff.
