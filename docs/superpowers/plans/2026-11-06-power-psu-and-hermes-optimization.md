# Power Telemetry PSU Ceiling & Hermes Agent Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Calculate recommended PSU wattage ceiling from CPU and GPU TDP using `(CPU TDP + GPU TDP + 80W) * 1.4` rounded up to standard PSU tiers, display live wattage fill and ceiling in the liquid gauge, and optimize Hermes agent integration with SQLite state queries, interactive CLI rollover, and unmetered local quota status.

**Architecture:** 
1. `msam-metrics.py` detects CPU TDP (via RAPL power constraints or CPU model heuristics) and GPU TDP (via `nvidia-smi` query or DRM power caps), computes `psuCeilingWatts` using standard hardware tiers, and includes them in the `power` payload.
2. Swift models (`PowerMetrics`) and UI views (`MetricsLiquidGauge`, `PowerMetricsDetailView`) use `psuCeilingWatts` as the liquid gauge fill denominator while rendering live wattage (`displayValue: "150 W"`) and caption (`caption: "of 850W"`), plus hardware grid cards.
3. `msam-provider-pulse.py` queries `~/.hermes/state.db` SQLite database for active session models, tokens, and titles, sets `transcript_path: "hermes:<id>"`, provides interactive turn extraction for `analyze_session_task`, and executes `hermes chat -q ... --oneshot -Q`.
4. `HerdrSessionRollover.swift` launches interactive Hermes chat via `hermes chat -q "\(taskPrompt)" \(yoloFlag)-m \(model)` so the session stays open in the terminal pane.

**Tech Stack:** Python 3 (standard library, SQLite3, RAPL, NVML), Swift 6 / SwiftUI, XCTest, pytest, Fastlane.

**Spec:** User request:
- Power: replace percentage gauge fill with Watt value ceiling computed by: `Recommended PSU Wattage = (CPU TDP + GPU TDP + 80W) * 1.4` rounded UP to standard size assumption (150W, 250W, 350W, 450W, 500W, 550W, 600W, 650W, 700W, 750W, 850W, 1000W, 1200W, 1300W, 1500W, 1600W, 2000W).
- Hermes: resolve missing agent session state, query local `~/.hermes/state.db`, display active model in quota plan name, prevent erroneous sign-in required status on local/custom endpoints, and fix pane rollover command to stay interactive.

## Global Constraints
- Preserve existing comments and docstrings.
- Python scripts must use Python 3 standard library only (no external pip dependencies).
- Swift code must build with zero warnings and pass all unit tests on iOS Simulator.
- All file links must use GitHub markdown `file://` format.

---

### Task 1: Add Hardware TDP & PSU Ceiling to `msam-metrics.py`

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-metrics.py:1330-1435`
- Test: `tests/test_msam_metrics.py`

**Interfaces:**
- Produces:
  - `get_cpu_tdp(sys_root: str = "/sys") -> float | None`
  - `get_gpu_tdp(sys_root: str = "/sys") -> float | None`
  - `calculate_recommended_psu(cpu_tdp: float | None, gpu_tdp: float | None) -> float | None`
  - `PowerSampler.sample()` returns `cpuTdpWatts`, `gpuTdpWatts`, `psuCeilingWatts` in power dict.

- [ ] **Step 1: Write failing unit tests in `tests/test_msam_metrics.py`**
Add tests for `get_cpu_tdp`, `get_gpu_tdp`, `calculate_recommended_psu`, and `PowerSampler` returning `cpuTdpWatts`, `gpuTdpWatts`, and `psuCeilingWatts`.

- [ ] **Step 2: Run pytest to verify tests fail**
Run: `pytest tests/test_msam_metrics.py -k "psu or tdp" -v`
Expected: FAIL with `ImportError` or `AttributeError: get_cpu_tdp not found`.

- [ ] **Step 3: Implement TDP detection and PSU ceiling calculation in `msam-metrics.py`**
Implement `get_cpu_tdp`, `get_gpu_tdp`, `calculate_recommended_psu`, and update `PowerSampler.__init__` and `PowerSampler.sample()`.

- [ ] **Step 4: Run pytest to verify tests pass**
Run: `pytest tests/test_msam_metrics.py -k "psu or tdp" -v`
Expected: PASS.

- [ ] **Step 5: Run all python metric tests**
Run: `pytest tests/test_msam_metrics.py -v`
Expected: ALL PASS.

- [ ] **Step 6: Commit**
`git commit -m "feat(metrics): add CPU and GPU TDP detection and recommended PSU ceiling"`

---

### Task 2: Optimize Hermes Integration in `msam-provider-pulse.py`

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-provider-pulse.py:1-40, 509-620, 710-770, 770-850`
- Test: `tests/test_msam_provider_pulse.py`

**Interfaces:**
- Produces:
  - `_query_hermes_session(home: Path, session_id: str | None = None) -> dict | None`
  - `collect_hermes_quota()` reports model in plan name (e.g. `custom (qwen3.8-flash-next)`) and `HEALTHY` for custom/local endpoints.
  - `collect_terminal_agents()` attaches model, session_tokens, and transcript_path `hermes:<id>` from `state.db`.
  - `analyze_session_task()` reads messages from `~/.hermes/state.db` and invokes `hermes chat -q ... --oneshot -Q`.

- [ ] **Step 1: Write failing unit tests in `tests/test_msam_provider_pulse.py`**
Add tests for `_query_hermes_session`, `collect_hermes_quota` with custom provider, and `analyze_session_task` with Hermes transcript.

- [ ] **Step 2: Run pytest to verify tests fail**
Run: `pytest tests/test_msam_provider_pulse.py -k "hermes" -v`
Expected: FAIL.

- [ ] **Step 3: Implement Hermes SQLite integration and runner in `msam-provider-pulse.py`**
Implement `_query_hermes_session`, update `collect_terminal_agents`, update `collect_hermes_quota`, and update `analyze_session_task`. Add shebang `#!/usr/bin/env python3` and CLI entrypoint.

- [ ] **Step 4: Run pytest to verify tests pass**
Run: `pytest tests/test_msam_provider_pulse.py -k "hermes" -v`
Expected: PASS.

- [ ] **Step 5: Run all python provider pulse tests**
Run: `pytest tests/test_msam_provider_pulse.py -v`
Expected: ALL PASS.

- [ ] **Step 6: Commit**
`git commit -m "feat(hermes): integrate state.db SQLite session lookup and interactive runner"`

---

### Task 3: Update `HerdrSessionRollover.swift` Hermes Launch Command

**Files:**
- Modify: `app/MultiSessionAIManager/Core/HerdrSessionRollover.swift:130-145`
- Test: `MultiSessionAIManagerTests/HerdrSessionRolloverTests.swift`

**Interfaces:**
- Produces:
  - `makeLaunchCommand(targetProvider: "hermes", ...)` returns `hermes chat -q "\(taskPrompt)" \(yoloFlag)-m \(model)`.

- [ ] **Step 1: Update test in `MultiSessionAIManagerTests/HerdrSessionRolloverTests.swift`**
Add assertion that Hermes launch command uses `hermes chat -q "<taskPrompt>" --yolo -m <model>`.

- [ ] **Step 2: Update `HerdrSessionRollover.swift`**
Change Hermes branch in `makeLaunchCommand` to use `hermes chat -q "\(taskPrompt)" \(yoloFlag)-m \(model)`.

- [ ] **Step 3: Run unit tests on macOS runner**
Run `xcodebuild test` for `HerdrSessionRolloverTests`.

- [ ] **Step 4: Commit**
`git commit -m "fix(rollover): update Hermes launch command to hermes chat interactive query"`

---

### Task 4: Update `HostMetricsModel.swift`, `MetricsInstruments.swift`, and `PowerMetricsDetailView.swift`

**Files:**
- Modify: `app/MultiSessionAIManager/Core/HostMetricsModel.swift:180-230`
- Modify: `app/MultiSessionAIManager/Presentation/Components/MetricsInstruments.swift:120-170`
- Modify: `app/MultiSessionAIManager/Presentation/Views/PowerMetricsDetailView.swift:1-120`
- Test: `MultiSessionAIManagerTests/PowerMetricsDetailViewTests.swift`

**Interfaces:**
- Produces:
  - `PowerMetrics.cpuTdpWatts: Double?`, `PowerMetrics.gpuTdpWatts: Double?`, `PowerMetrics.psuCeilingWatts: Double?`, `PowerMetrics.effectivePsuWatts: Double`.
  - `MetricsLiquidGauge(percent:displayValue:caption:tintColor:)`.
  - `PowerMetricsDetailView` renders liquid gauge with live wattage, `of <PSU>W` caption, and hardware grid metrics.

- [ ] **Step 1: Add unit tests in `PowerMetricsDetailViewTests.swift`**
Add tests asserting `PowerMetrics` decodes `cpuTdpWatts`, `gpuTdpWatts`, `psuCeilingWatts`, computes `effectivePsuWatts`, and `PowerMetricsDetailView` uses PSU ceiling.

- [ ] **Step 2: Update `HostMetricsModel.swift`**
Add fields, coding keys, and `effectivePsuWatts` property to `PowerMetrics`.

- [ ] **Step 3: Update `MetricsInstruments.swift`**
Add `displayValue` and `caption` parameters to `MetricsLiquidGauge`. Render `displayValue` in center when present.

- [ ] **Step 4: Update `PowerMetricsDetailView.swift`**
Pass live wattage to `MetricsLiquidGauge` with `caption: "of " + PowerMetrics.formatWatts(psuCeiling)`. Add hardware TDP cards to grid.

- [ ] **Step 5: Run tests on `IronMentorMac`**
Run `xcodebuild test` for `PowerMetricsDetailViewTests` and `HostMetricsModelTests`.

- [ ] **Step 6: Commit**
`git commit -m "feat(ui): display live wattage and PSU ceiling in power liquid gauge"`

---

### Task 5: Implement iPad Host Tab Dragging and Reordering

**Files:**
- Modify: `app/MultiSessionAIManager/Core/HostTab.swift:40-70`
- Modify: `app/MultiSessionAIManager/UI/HostTabStrip.swift:20-65`
- Test: `app/MultiSessionAIManager/Tests/HostTabStoreTests.swift`
- Test: `app/MultiSessionAIManager/Tests/HostTabStripTests.swift`

**Interfaces:**
- Produces:
  - `HostTabStore.moveTab(from: Int, to: Int)`
  - `HostTabStrip` with `.draggable(tab.id.uuidString)` and `.dropDestination(for: String.self)` for interactive drag-and-drop tab rearrangement.

- [ ] **Step 1: Write unit tests in `HostTabStoreTests.swift`**
Add tests asserting `moveTab(from:to:)` moves tabs and persists new order, clamping or ignoring out-of-bounds indices.

- [ ] **Step 2: Implement `moveTab` in `HostTabStore.swift`**
Implement `moveTab(from sourceIndex: Int, to destinationIndex: Int)` and call `save()`.

- [ ] **Step 3: Update `HostTabStrip.swift` with SwiftUI drag-and-drop**
Attach `.draggable(tab.id.uuidString)` and `.dropDestination(for: String.self)` to tab buttons.

- [ ] **Step 4: Run unit tests on macOS runner**
Run `xcodebuild test` for `HostTabStoreTests` and `HostTabStripTests`.

- [ ] **Step 5: Commit**
`git commit -m "feat(ui): add drag-and-drop host tab reordering for iPad"`

---

### Task 6: Deploy to Host, Run Full Test Suite, and Publish TestFlight Release

**Files:**
- Deploy: `app/MultiSessionAIManager/Resources/msam-metrics.py` -> `/home/rufus/.local/libexec/msam-host-agent/current/`
- Deploy: `app/MultiSessionAIManager/Resources/msam-provider-pulse.py` -> `/home/rufus/.local/libexec/msam-host-agent/current/`
- Test: Full `pytest tests/` on Linux and `xcodebuild test` on macOS.
- Release: Build and upload TestFlight release via `fastlane beta`.

- [ ] **Step 1: Deploy scripts to `forge` and restart host agent**
Copy updated python scripts to `/home/rufus/.local/libexec/msam-host-agent/current/`, restart `msam-host-agent.py` processes, and verify live telemetry output.

- [ ] **Step 2: Run full Python test suite**
Run: `pytest tests/`

- [ ] **Step 3: Run full Swift test suite on Mac**
Run: `ssh IronMentorMac "cd ~/Projects/multi-session-ai-manager && git pull && xcodebuild test ..."`

- [ ] **Step 4: Build and upload TestFlight release**
Run: `ssh IronMentorMac "source ~/.appstoreconnect/env && cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && fastlane beta"`

- [ ] **Step 5: Clean up background processes and verify App Store Connect status**
Ensure no orphaned transporter or log stream processes remain.
