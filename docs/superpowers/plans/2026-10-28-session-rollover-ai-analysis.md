# Host-Native Session Rollover with AI Analysis & iPad Loader Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide an end-to-end host-native session rollover workflow where selecting a replacement AI provider displays an AI loader modal on the iPad, runs a background provider analysis session on the remote host to select the optimal model and effort, and opens/executes an adjacent tab directly inside the host's Herdr workspace.

**Architecture:** 
1. The host agent (`msam-provider-pulse.py` & `msam-host-agent.py`) executes a background analysis turn using the selected provider's non-interactive CLI (`agy -p`, `codex exec`, `claude -p`) on the session transcript with fallback heuristics, returning `{model, effort, summary}`.
2. The iPad UI presents a dedicated, animated `AILoaderModalView` during this analysis.
3. On completion of the analysis, `RootView` executes host-side Herdr commands (`herdr tab create` and `herdr pane run`) over SSH so the adjacent tab opens and launches natively on the remote host.

**Tech Stack:** Python 3 (standard library `subprocess`, `json`, `pathlib`), Swift 5.10 / 6 (SwiftUI, Observation, Citadel/NIOSSH), Herdr CLI socket API (`herdr tab create`, `herdr pane run`).

**Spec:** User instructions:
1. Relaunch command must execute on the remote host, not typed into local iPad PTY buffers.
2. Background provider session must run on the host analyzing the task to select the appropriate model and effort.
3. An AI loader modal must be displayed on the iPad screen showing it is busy with the analysis.
4. Once analysis completes, a new tab next to the target session is created in Herdr on the host, and the agent launch command is executed in that pane.

## Global Constraints
- Preserve existing comment headers, docstrings, and tests across all modified files.
- Python host agent collectors must only use Python standard library.
- Provider CLI analysis calls on the host must be bounded by timeouts (maximum 20 seconds) with reliable fallback to heuristic evaluation so the UI is never blocked or left hung.
- Swift code must build cleanly on Xcode 27.1 / iOS 17+ and pass all unit tests on `IronMentorMac`.
- Deploy updated host agent daemons to `forge` (Linux systemd) and `IronMentorMac` (macOS launchd) after verification.

---

### Task 1: Host-Side AI Provider Analysis in `msam-provider-pulse.py`

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-provider-pulse.py:587-633`
- Modify: `tests/test_msam_provider_pulse.py:184-196`

**Interfaces:**
- Produces: `analyze_session_task(transcript_path: str, target_provider: str, home_dir: Path | str | None, env: dict | None) -> dict`
  Returns:
  ```json
  {
    "model": "gpt-6.1-sol",
    "effort": "high",
    "is_complex": true,
    "summary": "Deep reasoning recommended for complex compiler deadlock"
  }
  ```

- [ ] **Step 1: Write failing unit tests for provider CLI analysis**

Add tests to `tests/test_msam_provider_pulse.py` that verify:
1. `test_analyze_session_task_invokes_provider_cli`: When a supported provider CLI is available (e.g. `codex`, `claude`, `agy`), `analyze_session_task` invokes the CLI with transcript context and parses the JSON output.
2. `test_analyze_session_task_falls_back_when_cli_fails`: When the provider CLI command returns an error or invalid JSON, it falls back to the heuristic analyzer without throwing.

- [ ] **Step 2: Run pytest to verify the new tests fail**

Run: `pytest tests/test_msam_provider_pulse.py -k "analyze_session_task_invokes"`
Expected: FAIL

- [ ] **Step 3: Implement provider CLI invocation in `msam-provider-pulse.py`**

In `analyze_session_task`:
1. Extract the last 50 lines of user and assistant turns from `transcript_path`.
2. Construct the provider command:
   - For `codex`: `codex exec -c shell_environment_policy.inherit=all "..."`
   - For `claude`: `claude -p --dangerously-skip-permissions "..."`
   - For `agy` / `antigravity`: `agy -p --dangerously-skip-permissions "..."`
3. Execute via `subprocess.run(..., timeout=20, capture_output=True, text=True)`.
4. Parse the returned JSON for `model`, `effort`, and `summary`.
5. If parsing fails, subprocess errors, or times out, fall back to the heuristic evaluation.

- [ ] **Step 4: Run pytest to verify all tests pass**

Run: `pytest tests/test_msam_provider_pulse.py`
Expected: 97 passed

- [ ] **Step 5: Commit changes**

```bash
git add app/MultiSessionAIManager/Resources/msam-provider-pulse.py tests/test_msam_provider_pulse.py
git commit -m "feat(host): add live AI provider CLI analysis for session rollover"
```

---

### Task 2: Host Herdr Tab & Pane Execution Commands in Swift

**Files:**
- Create: `app/MultiSessionAIManager/Core/HerdrSessionRollover.swift`
- Create: `app/MultiSessionAIManager/Tests/HerdrSessionRolloverTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct HerdrSessionRollover {
      public struct AnalysisResult: Codable, Equatable, Sendable {
          public let model: String
          public let effort: String
          public let isComplex: Bool?
          public let summary: String?
      }

      public static func makeAnalysisCommand(transcriptPath: String, provider: String) -> String
      public static func parseAnalysisResult(json: String) -> AnalysisResult?
      public static func makeCreateTabCommand(workspaceID: String?, cwd: String, label: String) -> String
      public static func parseCreatedTabResult(json: String) -> (tabID: String, paneID: String)?
      public static func makeRunCommand(paneID: String, command: String) -> String
      public static func makeLaunchCommand(provider: String, model: String, effort: String, autoApprove: Bool, transcriptPath: String?, project: String) -> String
  }
  ```

- [ ] **Step 1: Write unit tests for HerdrSessionRollover command generation and parsing**

Create `app/MultiSessionAIManager/Tests/HerdrSessionRolloverTests.swift` testing:
1. Analysis command construction with correct quoting.
2. JSON parsing for analysis result.
3. Herdr tab create command generation with workspace and label.
4. Parsing `herdr tab create` response JSON (`root_pane.pane_id` and `tab.tab_id`).
5. Herdr pane run command generation.
6. Launch command generation for Codex, Claude, Antigravity, and Hermes with `--yolo` / `--dangerously-skip-permissions` flags.

- [ ] **Step 2: Run Swift tests on Mac to verify test suite fails or is missing**

Run: `ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:MultiSessionAIManagerTests/HerdrSessionRolloverTests"`
Expected: Build error or file missing.

- [ ] **Step 3: Implement `HerdrSessionRollover.swift`**

Implement all command builders, JSON parsers, and command formatters using `POSIXShell.quote` and robust Decodable structs.

- [ ] **Step 4: Run Swift tests on Mac to verify PASS**

Run: `ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:MultiSessionAIManagerTests/HerdrSessionRolloverTests"`
Expected: PASS

- [ ] **Step 5: Commit changes**

```bash
git add app/MultiSessionAIManager/Core/HerdrSessionRollover.swift app/MultiSessionAIManager/Tests/HerdrSessionRolloverTests.swift
git commit -m "feat(core): add HerdrSessionRollover command builders and parsers"
```

---

### Task 3: iPad AI Loader Modal Component (`AILoaderModalView.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/UI/Terminal/AILoaderModalView.swift`
- Create: `app/MultiSessionAIManager/Tests/AILoaderModalViewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AILoaderState: Equatable, Sendable {
      public var provider: String
      public var terminal: TerminalAgentSession
      public var statusMessage: String
      public var detailedMessage: String?
      public var isComplete: Bool = false
  }

  public struct AILoaderModalView: View {
      public let state: AILoaderState
      public var onCancel: (() -> Void)?
  }
  ```

- [ ] **Step 1: Write unit tests for `AILoaderState`**

Create `app/MultiSessionAIManager/Tests/AILoaderModalViewTests.swift` verifying initialization and state transitions.

- [ ] **Step 2: Implement `AILoaderModalView.swift`**

Build a modern SwiftUI view featuring:
- Fullscreen dimming overlay (`Color.black.opacity(0.65)`).
- Centered rounded modal card with `HerdrTheme.panel` background and border.
- Animated pulsating provider badge (using `ProviderIconView`).
- Glowing indeterminate spinner.
- Main title: "Analyzing Task with \(provider.capitalized)…"
- Subtitle / dynamic phase description: "Inspecting prior session transcript to determine optimal model and reasoning effort."
- Cancel button calling `onCancel`.

- [ ] **Step 3: Verify build and tests on Mac**

Run: `ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:MultiSessionAIManagerTests/AILoaderModalViewTests"`
Expected: PASS

- [ ] **Step 4: Commit changes**

```bash
git add app/MultiSessionAIManager/UI/Terminal/AILoaderModalView.swift app/MultiSessionAIManager/Tests/AILoaderModalViewTests.swift
git commit -m "feat(ui): add AILoaderModalView for AI model and effort analysis"
```

---

### Task 4: Connect Workflow in `SessionRolloverSheet.swift` & `RootView.swift`

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Terminal/SessionRolloverSheet.swift:140-238`
- Modify: `app/MultiSessionAIManager/UI/RootView.swift:425-455`

**Interfaces:**
- In `SessionRolloverSheet.swift`:
  - When user selects provider and taps "Resume Task", it immediately invokes `onSelectRollover(selectedProvider, autoApprove, terminal)` and dismisses the selection sheet.
- In `RootView.swift`:
  - Maintain `@State private var rolloverLoaderState: AILoaderState? = nil`.
  - Present `AILoaderModalView` when `rolloverLoaderState != nil`.
  - `handleSessionRollover`:
    1. Set `rolloverLoaderState` with initial message.
    2. Over SSH via `session.connection.provisioningCommandRunner`:
       - Run `HerdrSessionRollover.makeAnalysisCommand`.
       - Update `rolloverLoaderState.statusMessage` with "Recommended: \(model) (\(effort) effort)".
       - Extract workspace ID from `terminal.tabID` (e.g. `wQ:t1` -> `wQ`).
       - Run `HerdrSessionRollover.makeCreateTabCommand`.
       - Parse `paneID` and `tabID`.
       - Run `HerdrSessionRollover.makeRunCommand(paneID: newPaneID, command: launchCmd)`.
    3. Dismiss `rolloverLoaderState` and show `toastCenter.success("Relaunched with \(provider.capitalized) (\(model))")`.

- [ ] **Step 1: Update `SessionRolloverSheet.swift` callback signature and action**
- [ ] **Step 2: Update `RootView.swift` to present `AILoaderModalView` and execute remote Herdr rollover**
- [ ] **Step 3: Run full Swift test suite on Mac**

Run: `ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'"`
Expected: All tests PASS.

- [ ] **Step 4: Commit changes**

```bash
git add app/MultiSessionAIManager/UI/Terminal/SessionRolloverSheet.swift app/MultiSessionAIManager/UI/RootView.swift
git commit -m "feat: wire host-native session rollover with AI loader modal and Herdr execution"
```

---

### Task 5: Deploy Updated Daemons & Build TestFlight

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-host-agent.py` (version bump to 1.1.2)
- TestFlight release via Fastlane

- [ ] **Step 1: Bump version in `msam-host-agent.py` to 1.1.2**
- [ ] **Step 2: Deploy updated `msam-provider-pulse.py` and `msam-host-agent.py` to `forge` and `IronMentorMac`**
- [ ] **Step 3: Verify host daemons are active and healthy**
- [ ] **Step 4: Push git commit to `origin/main`**
- [ ] **Step 5: Run Fastlane beta build and upload to TestFlight**
- [ ] **Step 6: Confirm upload on App Store Connect**

---
