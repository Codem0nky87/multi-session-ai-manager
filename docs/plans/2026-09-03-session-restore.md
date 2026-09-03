# Resilient Session Restore Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore the selected foreground Herdr tab after PTY or host loss with at most three attempts, and provision native conversation-restore integrations for every supported AI agent detected on a host.

**Architecture:** Promote PTY termination to an exactly-once transport event, then route both PTY EOF and failed SSH heartbeat through one generation-fenced recovery coordinator owned by `HerdrHostSession`. Keep selection/foreground policy in `HostTabsModel`/`RootView`. Add a separate Host Setup integration manager that detects only fixed, supported agent commands, parses Herdr's status output, installs missing/outdated integrations sequentially, and verifies the result.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, SwiftNIO SSH/Citadel, XcodeGen, Herdr 0.8.2 CLI.

---

### Task 1: Make PTY closure observable exactly once

**Files:**
- Modify: `app/MultiSessionAIManager/Core/SSHTransport.swift:77-82`
- Modify: `app/MultiSessionAIManager/Core/SSHService.swift:110-122`
- Modify: `app/MultiSessionAIManager/Core/NIOSSHTransport.swift:468-540`
- Modify: `app/MultiSessionAIManager/Core/FakeSSHTransport.swift:145-151,214-251`
- Modify: `app/MultiSessionAIManager/Tests/RemoteFileUploadTests.swift:169-177`
- Modify: `app/MultiSessionAIManager/Tests/SessionWebTunnelTests.swift:698-705`
- Test: `app/MultiSessionAIManager/Tests/SSHTransportFakeTests.swift`

**Step 1: Write the failing fake-transport test**

Add a test that opens a fake PTY with `onClose`, calls `close()` twice, and asserts the callback count is exactly one. Keep the callback count in the existing locked `Box`.

**Step 2: Run the test and verify RED**

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests test
```

Expected: compilation fails because `openPTY` has no `onClose` argument.

**Step 3: Add the transport seam**

Make the protocol require `openPTY(command:cols:rows:onOutput:onClose:)`. Add a compatibility overload that accepts only `onOutput` and supplies an empty close callback. Thread `onClose` through `SSHService`, and update every test transport conformance.

In `FakePTYChannel`, store `onClose` and call it only on the first transition from open to closed. In `NIOSSHTransport`, use a lock-backed notifier shared by the pump and returned channel. Notify after the PTY pump ends; local `close()` trips the pump and reaches the same exactly-once path. Never invoke callbacks while holding the notifier lock.

**Step 4: Run the unit target and verify GREEN**

Run the command from Step 2. Expected: the new callback test and existing tests pass.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core app/MultiSessionAIManager/Tests
git commit -m "feat: surface remote PTY closure"
```

### Task 2: Recover unexpected PTY and SSH loss three times

**Files:**
- Modify: `app/MultiSessionAIManager/Core/HostConnection.swift:108-121`
- Modify: `app/MultiSessionAIManager/Core/HerdrHostSession.swift:47-112,125-196,280-369`
- Modify: `app/MultiSessionAIManager/Core/FakeSSHTransport.swift`
- Test: `app/MultiSessionAIManager/Tests/HerdrHostSessionTests.swift`

**Step 1: Write failing recovery tests**

Add focused tests using zero/millisecond delays:

- unexpected Herdr PTY close over healthy SSH opens a replacement PTY;
- host loss makes no more than three attach/connect attempts;
- success on attempt two prevents attempt three;
- disabling automatic recovery cancels delayed attempts;
- manual Retry after exhaustion starts a fresh budget;
- deliberate `stop()` never triggers recovery through `onClose`.

Extend the fake only as needed with queued PTY-open or connect results so every attempt is deterministic.

**Step 2: Run `HerdrHostSessionTests` and verify RED**

```bash
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/HerdrHostSessionTests test
```

Expected: new tests fail because close events are ignored and recovery is one shot.

**Step 3: Implement one recovery coordinator**

Add an injectable recovery policy whose default attempt delays are `.zero`, two seconds, and five seconds. Add `automaticRecoveryEnabled`, one recovery task, and a recovery-generation guard. Disabling recovery cancels only pending retries.

The Herdr PTY close callback hops to `@MainActor`, verifies its operation generation, and begins recovery only for an unexpected close from `.live`. Before every attempt, probe an apparently connected SSH service, disconnect a dead service, run the same named Herdr attach, and reopen the outbox watch. Coalesce heartbeat and EOF triggers. A successful attach ends the task. The third failure remains `.failed`. Manual Retry cancels the old cycle and starts a fresh budget.

**Step 4: Run the focused suite and verify GREEN**

Run the command from Step 2. Expected: all `HerdrHostSessionTests` pass.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core app/MultiSessionAIManager/Tests/HerdrHostSessionTests.swift
git commit -m "feat: retry selected Herdr session recovery"
```

### Task 3: Gate recovery on selected foreground lifecycle

**Files:**
- Modify: `app/MultiSessionAIManager/UI/RootView.swift:9-69,202-227,268-307`
- Test: `app/MultiSessionAIManager/Tests/RootViewModelTests.swift`

**Step 1: Write failing lifecycle tests**

Add tests proving only the selected session has automatic recovery enabled; switching selection transfers that state; inactive scene state disables every session; a lazily created selected session inherits the context; and context changes do not eagerly create sessions.

**Step 2: Run `RootViewModelTests` and verify RED**

Use the focused `xcodebuild` invocation with `-only-testing:MultiSessionAIManagerTests/RootViewModelTests`. Expected: compilation fails because recovery context does not exist.

**Step 3: Implement lifecycle wiring**

Let `HostTabsModel` store the selected recovery tab ID and foreground flag. Add `setRecoveryContext(selectedTabID:isForeground:)` to update only existing sessions. When `session(for:)` lazily creates a session, initialize it from that context.

Have `RootView` set the context on initial task, selection changes, and scene changes. Preserve selected-tab `ensureLive()` and never iterate through stored tabs to create sessions.

**Step 4: Run focused session and root-model suites**

Expected: both suites pass and no unselected tab is connected.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/UI/RootView.swift app/MultiSessionAIManager/Tests/RootViewModelTests.swift
git commit -m "feat: limit recovery to the selected foreground tab"
```

### Task 4: Detect and provision installed-agent integrations

**Files:**
- Create: `app/MultiSessionAIManager/Core/HerdrIntegrationManager.swift`
- Create: `app/MultiSessionAIManager/Tests/HerdrIntegrationManagerTests.swift`

**Step 1: Write failing registry/parser tests**

Cover every fixed Herdr target and command alias, including `kilo-code`, `cursor-agent`, and `agy`. Assert the generated detection command contains only registry values and emits stable `MSAM_AGENT:<target>` markers. Cover `current`, `not installed`, `outdated`, and `needs repair` status lines. Classify only detected agents.

**Step 2: Regenerate, run the new suite, and verify RED**

```bash
xcodegen generate
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests/HerdrIntegrationManagerTests test
```

Expected: compilation fails because the manager is absent.

**Step 3: Implement the registry and probe**

Create immutable target records with user-facing name, Herdr target, and executable names. Generate a POSIX detection command from the registry and never incorporate remote output into command text.

The observable manager uses the existing `HostConnection` runner and bounded commands. `probe()` runs detection plus `herdr integration status`, then publishes detected statuses. Parsing keys on the target and state prefixes, not host-specific paths.

**Step 4: Write failing installation tests**

Assert installation runs one safe command per missing/outdated/repair-needed detected target, skips current targets, continues after an individual command failure, re-probes, and reports any target still not current as a partial failure.

**Step 5: Verify RED, implement, and verify GREEN**

Run the focused suite, confirm expected failures, implement sequential bounded installation plus verification, then rerun until all manager tests pass. Preserve per-agent failure messages.

**Step 6: Commit**

```bash
git add app/MultiSessionAIManager/Core/HerdrIntegrationManager.swift \
  app/MultiSessionAIManager/Tests/HerdrIntegrationManagerTests.swift
git commit -m "feat: provision Herdr agent restore integrations"
```

### Task 5: Add Session Restore to Host Setup

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Hosts/HostSetupHelpSheet.swift:6-99,144-189`
- Test: `app/MultiSessionAIManager/Tests/HerdrIntegrationManagerTests.swift`
- Test: `app/MultiSessionAIManager/Tests/RootViewModelTests.swift`

**Step 1: Write failing UI-wiring assertions**

Add source-level assertions for a `4 · Session restore` card, stable accessibility identifiers, probe task, and install action. Add pure summary tests for no agents, all-current, work-needed, installing, partial-failure, and probe-failure states.

**Step 2: Run focused tests and verify RED**

Run the two named suites. Expected: card/wiring assertions fail.

**Step 3: Implement the card**

Construct one `HerdrIntegrationManager` from the same `HostConnection` used by Herdr installation and plugins. Render the fourth card only after Herdr is present. Probe when it appears. List detected agents and statuses. Offer one enable/repair action when work exists, disable it while installing, and show partial failures without hiding current integrations.

Explain that layouts restore after restart, arbitrary processes do not, and agent conversations require these integrations.

**Step 4: Run focused tests and verify GREEN**

Expected: manager and wiring tests pass.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/UI/Hosts/HostSetupHelpSheet.swift app/MultiSessionAIManager/Tests
git commit -m "feat: expose session restore readiness in host setup"
```

### Task 6: Document semantics and verify the product

**Files:**
- Modify: `README.md:35-43`
- Modify: `docs/architecture.md`
- Modify: `docs/host-setup.md:189-196`
- Modify: `docs/development.md`

**Step 1: Update documentation**

Replace the outdated claim that the app has no reconnect state machine. Document the selected-tab three-attempt policy, distinguish live reattach from snapshot reconstruction, describe integration readiness, and explain why pane history remains opt-in.

Add an explicitly destructive, opt-in diagnostic recipe for a disposable test host. The ordinary hermetic suite must never stop a user's Herdr server.

**Step 2: Run formatting and static checks**

```bash
swift-format lint --recursive app/MultiSessionAIManager/Core \
  app/MultiSessionAIManager/UI app/MultiSessionAIManager/Tests
git diff --check
```

If the formatter reports unrelated pre-existing files, check only files changed by this branch and report that scope.

**Step 3: Regenerate and run the complete hermetic suite**

```bash
cd app/MultiSessionAIManager
xcodegen generate
xcodebuild -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:MultiSessionAIManagerTests test
```

Expected: build succeeds and every unit test passes. Live diagnostics skip unless their explicit local prerequisites are present.

**Step 4: Review scope and commit**

```bash
git status --short --branch
git diff --check
git log --oneline --decorate -8
git add README.md docs app/MultiSessionAIManager
git commit -m "docs: explain host restart session recovery"
```

Confirm no generated, derived-data, credential, or unrelated files are staged.
