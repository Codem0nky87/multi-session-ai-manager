# Homebrew Cask Agent Updates Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Recognize Homebrew cask installations of Claude Code and Codex and update them safely through the existing rolling session coordinator.

**Architecture:** Extend the fixed installation-owner model with a Homebrew cask case, then make both the remote inventory probe and installed host helper explicitly distinguish formulae from casks. Preserve the current fail-closed owner/path checks and session lifecycle; only the owner-specific lookup and update commands change.

**Tech Stack:** Swift 6, Swift Testing, POSIX shell, ShellCheck, Xcode/XCTest, Homebrew, Fastlane.

---

### Task 1: Model and display Homebrew cask ownership

**Files:**
- Modify: `app/MultiSessionAIManager/Core/AgentToolUpdate.swift`
- Modify: `app/MultiSessionAIManager/Core/AgentUpdatePresentation.swift`
- Test: `app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift`
- Test: `app/MultiSessionAIManager/Tests/AgentUpdatePresentationTests.swift`

**Step 1: Write the failing model and presentation tests**

Add expectations that `homebrew-cask` parses as a distinct
`AgentInstallMethod.homebrewCask`, that the generated Codex probe contains
explicit formula and cask ownership/latest commands, and that a current cask
row displays `Homebrew cask`.

**Step 2: Run the focused tests to verify RED**

Run:

```bash
xcodebuild -project app/MultiSessionAIManager/MultiSessionAIManager.xcodeproj \
  -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,id=49A8BA08-250A-4FDC-8D5D-2471B3E0D911' \
  -derivedDataPath /tmp/msam-cask-derived \
  -only-testing:MultiSessionAIManagerTests/AgentToolVersionProbeTests \
  -only-testing:MultiSessionAIManagerTests/AgentUpdatePresentationTests test
```

Expected: compilation/test failure because `homebrewCask` and the cask command
contract do not exist.

**Step 3: Implement the minimal Swift owner model and probe**

Add:

```swift
case homebrewCask = "homebrew-cask"
```

Parse the marker and expose a human-readable owner label. In the generated
probe, check both:

```sh
brew list --formula --versions "$package"
brew list --cask --versions "$package"
```

Use `brew info --formula --json=v2` for formulae and
`brew info --cask --json=v2` for casks. Keep the existing owner count and exact
selected-launcher check.

**Step 4: Run the focused tests to verify GREEN**

Run the command from Step 2.

Expected: both selected suites pass.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/AgentToolUpdate.swift \
  app/MultiSessionAIManager/Core/AgentUpdatePresentation.swift \
  app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift \
  app/MultiSessionAIManager/Tests/AgentUpdatePresentationTests.swift
git commit -m "fix: recognize Homebrew cask agent installs"
```

### Task 2: Execute cask updates through the host-owned worker

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-agent-updater.sh`
- Modify: `scripts/fixtures/fake-agent-command.sh`
- Modify: `scripts/test-msam-agent-updater.sh`

**Step 1: Write a failing shell integration test**

Teach the fake Homebrew command to model a cask-owned Codex executable, then
add a harness scenario that expects:

```text
brew upgrade --cask --yes codex
```

and confirms all eligible Claude, Codex, and Antigravity conversations are
exited and restored through the existing coordinator.

**Step 2: Run the updater harness to verify RED**

Run:

```bash
bash scripts/test-msam-agent-updater.sh
```

Expected: failure because the worker still performs formula-only ownership
detection and never invokes the cask update.

**Step 3: Implement owner-matched worker commands**

Make the helper count formula and cask ownership separately. Dispatch only the
matched command:

```sh
brew upgrade --formula --yes "$brew_package"
brew upgrade --cask --yes "$brew_package"
```

Do not add uninstalls, migrations, global Homebrew configuration, or a direct
update path outside the rolling coordinator.

**Step 4: Run shell verification to verify GREEN**

Run:

```bash
shellcheck -x app/MultiSessionAIManager/Resources/msam-agent-updater.sh \
  scripts/test-msam-agent-updater.sh scripts/fixtures/fake-agent-command.sh
bash scripts/test-msam-agent-updater.sh
```

Expected: ShellCheck exits 0 and the harness prints
`PASS: msam-agent-updater`.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Resources/msam-agent-updater.sh \
  scripts/fixtures/fake-agent-command.sh scripts/test-msam-agent-updater.sh
git commit -m "fix: update Homebrew cask agents safely"
```

### Task 3: Verify, integrate, and release

**Files:**
- Verify: all files changed in Tasks 1 and 2
- Build artifact: `app/MultiSessionAIManager/build/MultiSessionAIManager.ipa`

**Step 1: Run all static and host-helper checks**

Run ShellCheck and `bash scripts/test-msam-agent-updater.sh` again from a clean
checkout. Expected: all pass.

**Step 2: Run the complete iOS suite**

Run `xcodegen generate`, then run the full `xcodebuild ... test` command on the
known iPad simulator. Expected: every Swift and UI test passes.

**Step 3: Review the final diff and commit state**

Run `git diff --check`, `git status --short --branch`, and inspect the complete
branch diff from `main`. Expected: no uncommitted source changes and only the
approved cask-support commits.

**Step 4: Fast-forward local main and clean the worktree**

After successful verification, fast-forward local `main`, remove only this
feature worktree, and delete its now-merged local branch. Do not push.

**Step 5: Build and upload TestFlight from merged main**

Run:

```bash
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  FASTLANE_SKIP_UPDATE_CHECK=1 fastlane beta
```

Expected: signed IPA export and successful App Store Connect upload with a new
timestamp build number.

**Step 6: Audit the release artifact**

Read the IPA version/build, confirm `msam-agent-updater.sh` is embedded and
executable, verify the code signature, and confirm the Fastlane upload receipt.
