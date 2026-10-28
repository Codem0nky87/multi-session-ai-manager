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

- [x] **Step 1: Write failing unit tests for provider CLI analysis**
- [x] **Step 2: Run pytest to verify the new tests fail**
- [x] **Step 3: Implement provider CLI invocation in `msam-provider-pulse.py`**
- [x] **Step 4: Run pytest to verify all tests pass**
- [x] **Step 5: Commit changes**

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

- [x] **Step 1: Write unit tests for HerdrSessionRollover command generation and parsing**
- [x] **Step 2: Run Swift tests on Mac to verify test suite fails or is missing**
- [x] **Step 3: Implement `HerdrSessionRollover.swift`**
- [x] **Step 4: Run Swift tests on Mac to verify PASS**
- [x] **Step 5: Commit changes**

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

- [x] **Step 1: Write unit tests for `AILoaderState`**
- [x] **Step 2: Implement `AILoaderModalView.swift`**
- [x] **Step 3: Verify build and tests on Mac**
- [x] **Step 4: Commit changes**

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

- [x] **Step 1: Update `SessionRolloverSheet.swift` callback signature and action**
- [x] **Step 2: Update `RootView.swift` to present `AILoaderModalView` and execute remote Herdr rollover**
- [x] **Step 3: Run full Swift test suite on Mac**
- [x] **Step 4: Commit changes**

---

### Task 5: Deploy Updated Daemons & Build TestFlight

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-host-agent.py` (version bump to 1.1.2)
- TestFlight release via Fastlane

- [x] **Step 1: Bump version in `msam-host-agent.py` to 1.1.2**
- [x] **Step 2: Deploy updated `msam-provider-pulse.py` and `msam-host-agent.py` to `forge` and `IronMentorMac`**
- [x] **Step 3: Verify host daemons are active and healthy**
- [x] **Step 4: Push git commit to `origin/main`**
- [x] **Step 5: Run Fastlane beta build and upload to TestFlight**
- [x] **Step 6: Confirm upload on App Store Connect**

---
