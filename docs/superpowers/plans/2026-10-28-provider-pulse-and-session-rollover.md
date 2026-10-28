# Provider Pulse Toolbar and Session Rollover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate live Provider Pulse quota and agent session telemetry into MultiSessionAIManager's top toolbar (with tailored regular and compact layouts), and provide an automated session rollover workflow with pre-analysis of model and effort level when rate limits occur.

**Architecture:** A bundled Python collector module (`msam-provider-pulse.py`) runs inside `msam-host-agent` on each host to query provider quotas and Herdr agent transcripts, streaming data through the existing SSH metrics channel into an observable `ProviderPulseModel`. The UI removes the theme icon from the header strip, presents authentic provider icons with live `%` badges on iPad/Mac, consolidates hardware and AI metrics into single icons on iPhone, and offers an interactive rollover modal that runs a hidden analyzer before launching the new adjacent terminal tab.

**Tech Stack:** Python 3 (asyncio, JSON-RPC, stdio), Swift 5.10 / 6 (SwiftUI, Observation, CryptoKit, Citadel/NIOSSH), Herdr CLI (`herdr agent list`, `herdr pane close`).

**Spec:** [`docs/superpowers/specs/2026-10-28-provider-pulse-toolbar-and-session-rollover-design.md`](file:///home/rufus/Projects/multi-session-ai-manager/docs/superpowers/specs/2026-10-28-provider-pulse-toolbar-and-session-rollover-design.md)

## Global Constraints
- Strictly preserve existing comments, docstrings, and tests across all modified files.
- All Python changes must run under standard library where possible (no external unbundled dependencies).
- Cache Claude usage queries with a 5-minute cooldown (`FRESH_SECONDS = 300`) to avoid Anthropic API 429 throttling.
- Provider brand icons must match authentic brand colors (Claude: `#D97757`, Codex: `#202820` with white prompt, Antigravity: Google DeepMind colors).
- On iPhone (compact width), hardware metrics must be consolidated into 1 icon button and AI providers into 1 icon button.
- Theme selection must be completely removed from the header toolbar (persisted only in Settings and Herdr sessions).
- When rolling over a session, the previous session transcript file path must be passed directly in the continuation command to optimize token usage.
- Prior to opening the new tab, a hidden analysis execution must run to resolve the optimal model and effort level for the replacement provider.

---

### Task 1: Host Telemetry & Analyzer Module (`msam-provider-pulse.py`)

**Files:**
- Create: `app/MultiSessionAIManager/Resources/msam-provider-pulse.py`
- Create: `tests/test_msam_provider_pulse.py`

**Interfaces:**
- Produces:
  - `collect_provider_telemetry(home_dir: Path) -> dict`: Returns dictionary with `providers` (Claude, Codex, Antigravity, Hermes) and `terminal_agents` (panes, states, tokens, transcript paths).
  - `analyze_session_task(transcript_path: str, target_provider: str) -> dict`: Evaluates task complexity from transcript and returns recommended model and effort level (e.g. `{"model": "gpt-6.1-sol", "effort": "high", "summary": "..."}`).

- [ ] **Step 1: Write unit tests for provider quota parsing and task analysis**
  - Create `tests/test_msam_provider_pulse.py` testing Claude OAuth usage parsing, 5-minute cache cooldown, Codex JSON-RPC response handling, Antigravity `/usage` output parsing, Herdr agent list matching, and model/effort analysis.
- [ ] **Step 2: Run pytest to confirm tests fail before implementation**
  - Run `pytest tests/test_msam_provider_pulse.py` and verify `ModuleNotFoundError`.
- [ ] **Step 3: Implement `msam-provider-pulse.py`**
  - Implement `collect_claude()`, `collect_codex()`, `collect_antigravity()`, `collect_hermes()`, `collect_terminal_agents()`, and `analyze_session_task()`.
- [ ] **Step 4: Run pytest and confirm all tests pass**
  - Run `pytest tests/test_msam_provider_pulse.py` and confirm GREEN.
- [ ] **Step 5: Commit changes**
  - Git commit: `Add msam-provider-pulse telemetry and task analysis module with tests`.

---

### Task 2: Host Service Integration & Resource Packaging

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-host-agent.py`
- Modify: `app/MultiSessionAIManager/Resources/msam-host-agent-install.py`
- Modify: `app/MultiSessionAIManager/Core/HostServiceInstaller.swift:25-45`
- Test: `tests/test_msam_host_agent.py`

**Interfaces:**
- Consumes: `msam-provider-pulse.py` from Task 1.
- Produces:
  - `msam-host-agent.py` includes `providers` and `terminal_agents` in `sample_metrics()`.
  - `msam-host-agent.py analyze-task <transcript> <provider>` CLI subcommand.
  - `HostServiceInstaller.resources` includes `"msam-provider-pulse.py"`.

- [ ] **Step 1: Write unit tests for host-agent provider integration**
  - Add test in `tests/test_msam_host_agent.py` verifying `sample_metrics()` includes `providers` and `terminal_agents` when pulse module is present.
  - Add test for `analyze-task` subcommand.
- [ ] **Step 2: Run pytest to verify test failure**
  - Run `pytest tests/test_msam_host_agent.py -k provider` and confirm failure.
- [ ] **Step 3: Update `msam-host-agent.py` and installation manifests**
  - Update `sample_metrics()` in `msam-host-agent.py` to call `collect_provider_telemetry()` and merge into payload.
  - Add `analyze-task` command parser in `msam-host-agent.py`.
  - Add `"msam-provider-pulse.py"` to `FILES` in `msam-host-agent-install.py`.
  - Add `"msam-provider-pulse.py"` to `HostServiceInstaller.resources` in `HostServiceInstaller.swift`.
- [ ] **Step 4: Run all Python tests**
  - Run `pytest tests/test_msam_host_agent.py tests/test_msam_provider_pulse.py` and verify passing.
- [ ] **Step 5: Commit changes**
  - Git commit: `Integrate msam-provider-pulse into msam-host-agent and install manifests`.

---

### Task 3: Swift Models & Provider Pulse Engine

**Files:**
- Create: `app/MultiSessionAIManager/Core/ProviderPulseModel.swift`
- Modify: `app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift:250-320`
- Modify: `app/MultiSessionAIManager/Core/HerdrHostSession.swift:445-470`
- Test: `app/MultiSessionAIManager/Tests/ProviderPulseModelTests.swift`

**Interfaces:**
- Produces:
  - `ProviderQuota`: Decodable struct representing provider health, used %, resets, windows, and credits.
  - `TerminalAgentSession`: Decodable struct representing active agents, projects, token counts, and transcript paths.
  - `@Observable ProviderPulseModel`: Exposes `activeProviders`, `terminals(for:)`, and `rateLimitedTerminals`.

- [ ] **Step 1: Write Swift unit tests for decoding and model updates**
  - Create `ProviderPulseModelTests.swift` testing decoding of mock JSON payload with Claude (rate-limited), Codex (healthy with reset credits), Antigravity, and active terminals.
- [ ] **Step 2: Implement `ProviderPulseModel.swift` and update `HostMetricsModel.swift`**
  - Define `ProviderQuota`, `TerminalAgentSession`, `UsageWindow`, `ResetCredits`.
  - Add `providers: [String: ProviderQuota]?` and `terminalAgents: [TerminalAgentSession]?` to `HostMetricsModel.MetricsPayload`.
  - Implement `@Observable final class ProviderPulseModel`.
- [ ] **Step 3: Connect `ProviderPulseModel` inside `HerdrHostSession`**
  - Add `public let pulse = ProviderPulseModel()` to `HerdrHostSession`.
  - In `processMetrics()`, update `pulse.update(from: parsed)`.
- [ ] **Step 4: Commit changes**
  - Git commit: `Add ProviderPulseModel and integrate into HerdrHostSession metrics pipeline`.

---

### Task 4: Header Strip Clean-Up & Layout Restructuring

**Files:**
- Create: `app/MultiSessionAIManager/UI/Metrics/ProviderPulseBarView.swift`
- Create: `app/MultiSessionAIManager/UI/Metrics/ProviderPulseIcons.swift`
- Modify: `app/MultiSessionAIManager/UI/RootView.swift:130-285`
- Test: `app/MultiSessionAIManager/Tests/ProviderPulseBarViewTests.swift`

**Interfaces:**
- Consumes: `ProviderPulseModel` from Task 3.
- Produces:
  - Authentic provider vector icons (`ProviderPulseIcons`).
  - `ProviderPulseBarView` with live `%` text badges.
  - Consolidated iPhone hardware metrics button (`gauge.with.needle`) and AI provider button (`sparkles`).
  - Removed theme palette menu from header toolbar.

- [ ] **Step 1: Create authentic provider vector views in `ProviderPulseIcons.swift`**
  - Implement SwiftUI vector shapes/views for Claude Code (terracotta emblem), Codex (terminal prompt badge), Antigravity (Google DeepMind emblem), and Hermes (winged helmet).
- [ ] **Step 2: Implement `ProviderPulseBarView.swift`**
  - Renders provider icons with percentage badges and status dots.
  - Handles tap to toggle provider details popover.
- [ ] **Step 3: Update `RootView.swift`**
  - Delete `paintpalette` button (lines 214–247) and "Tab Theme" compact section (lines 266–284).
  - On regular width: Place `ProviderPulseBarView` next to `HostMetricsBarView`.
  - On compact width (iPhone): Show 1 Hardware icon button and 1 AI Provider icon button.
- [ ] **Step 4: Commit changes**
  - Git commit: `Restructure app header toolbar with Provider Pulse icons and consolidated compact buttons`.

---

### Task 5: Provider Details & Running Terminals View

**Files:**
- Create: `app/MultiSessionAIManager/UI/Metrics/ProviderDetailSheet.swift`
- Modify: `app/MultiSessionAIManager/UI/Metrics/ProviderPulseBarView.swift`
- Modify: `app/MultiSessionAIManager/UI/RootView.swift`

**Interfaces:**
- Consumes: `ProviderQuota`, `TerminalAgentSession` from Task 3.
- Produces:
  - `ProviderDetailSheet`: Interactive popover/sheet with quota windows, reset timers, reset credits, and terminal list with limit flags and `Continue session` button.

- [ ] **Step 1: Implement `ProviderDetailSheet.swift`**
  - Quota summary header (state badge, used %, 5h and 7d progress bars, countdown).
  - Available reset credits section (e.g. Codex 2 available).
  - Active terminals list showing project cwd, model, token usage, and status.
  - Prominent `Continue session` button when an agent is rate-limited or blocked.
- [ ] **Step 2: Connect popover presentation in `ProviderPulseBarView` and iPhone sheet**
  - Tap on provider icon opens `ProviderDetailSheet`.
- [ ] **Step 3: Commit changes**
  - Git commit: `Add ProviderDetailSheet displaying quota windows, credits, and active terminals`.

---

### Task 6: Hidden Analysis Window & Session Rollover Engine

**Files:**
- Modify: `app/MultiSessionAIManager/Core/HostTab.swift:35-65`
- Create: `app/MultiSessionAIManager/UI/Terminal/SessionRolloverSheet.swift`
- Modify: `app/MultiSessionAIManager/UI/Metrics/ProviderDetailSheet.swift`
- Test: `app/MultiSessionAIManager/Tests/SessionRolloverTests.swift`

**Interfaces:**
- Consumes: `TerminalAgentSession`, `SSHService`.
- Produces:
  - `HostTabStore.open(hostID:sessionName:insertAfter:)` for adjacent tab creation.
  - `SessionRolloverSheet`: Modal for picking provider with live %, toggle for `--yolo` / `--dangerously-skip-permissions`.
  - Background hidden task analyzer execution before opening tab.
  - PTY continuation command dispatch and retirement of old tab & pane.

- [ ] **Step 1: Write Swift unit tests for `HostTabStore` adjacent insertion and command builder**
  - Verify `insertAfter` places tab immediately after target tab.
  - Verify continuation command includes resolved model, effort, yolo flag, and transcript path.
- [ ] **Step 2: Update `HostTabStore.swift`**
  - Implement `open(hostID: UUID, sessionName: String?, insertAfter: UUID? = nil)`.
- [ ] **Step 3: Implement `SessionRolloverSheet.swift`**
  - Renders replacement provider selection list with live % badges.
  - Auto-approve permissions toggle.
  - Execution handler:
    1. Runs hidden analyzer via `SSHService.run("msam-host-agent analyze-task <transcript> <provider>")`.
    2. Receives recommended model and effort level.
    3. Opens new adjacent tab in `HostTabStore`.
    4. Delivers continuation command to terminal PTY:
       `<provider> --model <model> -c model_effort=<effort> <yolo_flag> "Continue previous task from session at <transcript_path> in <cwd>..."`
    5. Closes old Herdr pane via `SSHService.run("herdr pane close <old_pane>")`.
    6. Closes old tab in `HostTabStore`.
- [ ] **Step 4: Commit changes**
  - Git commit: `Implement SessionRolloverSheet with hidden task analysis and adjacent tab continuation`.

---

### Task 7: End-to-End Verification & TestFlight Release

**Files:**
- All modified and created files across Tasks 1–6.

- [ ] **Step 1: Run all Python tests**
  - `pytest tests/test_msam_metrics.py tests/test_msam_host_agent.py tests/test_msam_provider_pulse.py`
  - Ensure 100% passing.
- [ ] **Step 2: Run Swift tests on IronMentorMac**
  - Run `xcodegen` and `xcodebuild build-for-testing` on `IronMentorMac`.
- [ ] **Step 3: Verify live on `forge` and `IronMentorMac`**
  - Check `msam-host-agent metrics` on `forge` and verify `providers` JSON payload.
- [ ] **Step 4: Build and upload new TestFlight release**
  - Run `ssh IronMentorMac "~/.local/bin/msam-testflight beta"`.
  - Confirm successful upload to App Store Connect.
- [ ] **Step 5: Commit and push all changes to GitHub `origin/main`**
