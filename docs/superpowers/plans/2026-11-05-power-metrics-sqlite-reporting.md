# Power Metrics, SQLite Time-Series Storage, and Reporting Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement hardware-accurate power telemetry (CPU, GPU, and total system Watts), SQLite time-series storage with rolling 30-day retention and reporting CLI, and integrate component power and a global power glyph into the Multi-Session AI Manager iOS app.

**Architecture:** A multi-platform `PowerSampler` in `msam-metrics.py` samples RAPL, NVML, and Apple Silicon `powermetrics`. An embedded WAL-mode SQLite database (`metrics-history.db`) records 5-second snapshots with automatic 30-day pruning and supports an ASCII/JSON/CSV `report` CLI command. The iOS client decodes additive `PowerMetrics` fields and displays live component wattage and a dedicated `bolt.fill` power glyph with popover details in `HostMetricsBarView`.

**Tech Stack:** Python 3 (standard library, `sqlite3`, `subprocess`), PowerShell 5.1/Core, Swift 6 / SwiftUI (iOS 17+), macOS IOKit/powermetrics.

**Spec:** [`docs/superpowers/specs/2026-11-05-power-metrics-sqlite-reporting-design.md`](file:///home/rufus/Projects/multi-session-ai-manager/docs/superpowers/specs/2026-11-05-power-metrics-sqlite-reporting-design.md)

## Global Constraints
- Python standard library only for host services: zero third-party dependencies (`sqlite3` built-in).
- Zero breaking changes: all additions to `metrics` JSON payloads must be purely additive (`powerWatts`, `power`).
- Database write latency must not block network or metrics sampling loop (WAL mode enabled).
- Preserve all existing unit tests and maintain 100% green test passes across both Python and Swift suites.

---

### Task 1: Multi-Platform Power Sampling Engine (`msam-metrics.py`)

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-metrics.py`
- Test: `tests/test_msam_metrics.py`

**Interfaces:**
- Produces: `PowerSampler.sample(now, cpu_info, gpu_info) -> dict` returning:
  `{"totalWatts": float | None, "cpuWatts": float | None, "gpuWatts": float | None, "source": str}`
  and injects `cpu.powerWatts` and `gpu.powerWatts` into the payload.

- [ ] **Step 1: Write failing unit tests for `PowerSampler`**
  - Add tests in `tests/test_msam_metrics.py` for:
    - Linux RAPL energy calculation and counter rollover handling.
    - NVIDIA NVML `nvidia-smi` power.draw parsing.
    - Apple Silicon `powermetrics` output parsing (CPU mW, GPU mW, Combined mW).
    - Battery discharge rate parsing (`/sys/class/power_supply`).
    - Additive JSON structure in `get_metrics()`.

- [ ] **Step 2: Run tests to verify failure**
  - Run `python3 -m unittest tests/test_msam_metrics.py` and confirm new tests fail.

- [ ] **Step 3: Implement `PowerSampler` in `msam-metrics.py`**
  - Implement `read_linux_rapl_energy()`, `read_linux_battery_power()`, `read_macos_powermetrics()`, and `get_gpu_power()`.
  - Update `get_metrics()` to include `powerWatts` under `cpu` and `gpu`, plus the top-level `power` dict.

- [ ] **Step 4: Run tests to verify pass**
  - Run `python3 -m unittest tests/test_msam_metrics.py` and confirm all tests pass.

- [ ] **Step 5: Commit changes**
  - Git commit: `feat(metrics): implement multi-platform power sampling engine`.

---

### Task 2: SQLite Time-Series Database & Rolling 30-Day Retention

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-metrics.py`
- Test: `tests/test_msam_metrics.py`

**Interfaces:**
- Produces: `MetricsHistoryDB` class:
  - `__init__(db_path=None)`
  - `record_sample(timestamp, cpu_util, cpu_temp, cpu_watts, mem_used_gb, mem_total_gb, gpu_util, gpu_temp, gpu_watts, net_down_kbps, net_up_kbps, system_watts, power_source)`
  - `prune_older_than(days=30)`
  - `close()`

- [ ] **Step 1: Write failing unit tests for `MetricsHistoryDB`**
  - Test database initialization, WAL pragma verification, table creation.
  - Test recording samples and querying them back.
  - Test pruning entries older than 30 days while preserving recent entries.

- [ ] **Step 2: Run tests to verify failure**
  - Run `python3 -m unittest tests/test_msam_metrics.py` and confirm failure.

- [ ] **Step 3: Implement `MetricsHistoryDB` in `msam-metrics.py`**
  - Resolve default path (`~/.local/state/msam/metrics-history.db`).
  - Configure connection with `WAL` and `NORMAL` synchronous mode.
  - Hook into `_sample_loop()` to record each sample and run hourly pruning.

- [ ] **Step 4: Run tests to verify pass**
  - Run `python3 -m unittest tests/test_msam_metrics.py` and confirm all tests pass.

- [ ] **Step 5: Commit changes**
  - Git commit: `feat(metrics): add sqlite time-series database with 30-day retention`.

---

### Task 3: Reporting Engine & Host CLI (`msam-metrics report`)

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-metrics.py`
- Modify: `app/MultiSessionAIManager/Resources/msam-host-agent.py`
- Test: `tests/test_msam_metrics.py`
- Test: `tests/test_msam_host_agent.py`

**Interfaces:**
- Produces: `generate_metrics_report(db, start_time, end_time, format="table", cost_per_kwh=None) -> str | dict`
- CLI: `msam-metrics report [--period 1h|24h|7d|30d] [--from ISO] [--to ISO] [--format table|json|csv] [--cost-per-kwh RATE]`
- API: `GET /api/metrics/report` in `msam-host-agent.py`.

- [ ] **Step 1: Write failing unit tests for report generation**
  - Test statistical aggregation (averages, peaks, totals) for CPU, Memory, GPU, Network, and Power.
  - Test kWh calculation and cost multiplication.
  - Test output formatting for table, json, and csv.
  - Test `/api/metrics/report` endpoint on `msam-host-agent.py`.

- [ ] **Step 2: Run tests to verify failure**
  - Run `python3 -m unittest discover -s tests -p "test_*.py"` and confirm failure.

- [ ] **Step 3: Implement report generation and CLI/API integration**
  - Add query aggregation functions to `MetricsHistoryDB`.
  - Add `report` CLI parser to `msam-metrics.py`.
  - Add `/api/metrics/report` handler to `msam-host-agent.py`.

- [ ] **Step 4: Run tests to verify pass**
  - Run full test discovery: `python3 -m unittest discover -s tests -p "test_*.py"`.

- [ ] **Step 5: Commit changes**
  - Git commit: `feat(metrics): implement historical usage and power reporting CLI & API`.

---

### Task 4: Windows Power & Metrics Parity (`msam-metrics.ps1`)

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-metrics.ps1`
- Test: `tests/test_msam_host_agent.py`

**Interfaces:**
- Produces: PowerShell metrics payload matching Python schema with `cpu.powerWatts`, `gpu.powerWatts`, and `power: { totalWatts, cpuWatts, gpuWatts, source }`.

- [ ] **Step 1: Write unit tests verifying Windows metrics payload compatibility**
  - Check that Windows payload conforms to expected schema in `tests/test_msam_host_agent.py`.

- [ ] **Step 2: Update `msam-metrics.ps1`**
  - Add `nvidia-smi` power query for Windows GPU.
  - Add WMI `BatteryStatus` query for laptop discharge rate.
  - Inject additive fields into JSON output.

- [ ] **Step 3: Run tests to verify pass**
  - Run `python3 -m unittest tests/test_msam_host_agent.py`.

- [ ] **Step 4: Commit changes**
  - Git commit: `feat(metrics-win): add power metrics support to Windows collector`.

---

### Task 5: Swift Models & History Tracking (`HostMetricsModel.swift`)

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift`
- Test: `app/MultiSessionAIManager/Tests/HostMetricsModelTests.swift` (or new test file)

**Interfaces:**
- Produces:
  - `struct PowerMetrics: Decodable`
  - `CPUMetrics.powerWatts: Double?`
  - `GPUMetrics.powerWatts: Double?`
  - `HostMetricsModel.power: PowerMetrics`
  - `HostMetricsModel.powerHistory: [Double]`

- [x] **Step 1: Write failing Swift unit tests for `PowerMetrics`**
  - Test decoding payload with and without `power`, `cpu.powerWatts`, `gpu.powerWatts`.
  - Test `formattedTotalWatts` formatting logic (<100W vs >=100W vs nil).
  - Test `powerHistory` rolling window (capped at 30 items).

- [x] **Step 2: Run Swift tests to verify failure**
  - Run `ssh IronMentorMac 'cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPhone 17"'`.

- [x] **Step 3: Implement Swift model changes in `HostMetricsModel.swift`**
  - Define `PowerMetrics` struct with `totalWatts`, `cpuWatts`, `gpuWatts`, `source`.
  - Add `powerWatts` to `CPUMetrics` and `GPUMetrics`.
  - Update `MetricsPayload` and `HostMetricsModel.update(from:)`.

- [x] **Step 4: Run Swift tests to verify pass**
  - Confirm tests compile and pass.

- [x] **Step 5: Commit changes**
  - Git commit: `feat(ios-model): add PowerMetrics model and history tracking`.

---

### Task 6: iOS UI Integration: Component Wattage, Global Power Glyph, and Detail Popover

**Files:**
- Create: `app/MultiSessionAIManager/UI/Metrics/PowerMetricsDetailView.swift`
- Modify: `app/MultiSessionAIManager/UI/Metrics/HostMetricsBarView.swift`
- Modify: `app/MultiSessionAIManager/UI/Metrics/CPUMetricsDetailView.swift`
- Modify: `app/MultiSessionAIManager/UI/Metrics/GPUMetricsDetailView.swift`
- Modify: `app/MultiSessionAIManager/Core/HostServiceInstaller.swift` (resource manifest version bump if needed)
- Test: `app/MultiSessionAIManager/Tests/HostMetricsBarViewTests.swift`

**Interfaces:**
- UI: Global power button with `bolt.fill` glyph next to Network in `HostMetricsBarView`.
- UI: Popover `PowerMetricsDetailView` showing live Watts, component breakdown, telemetry source, and sparkline.
- UI: Live wattage in `CPUMetricsDetailView` and `GPUMetricsDetailView`.

- [ ] **Step 1: Implement `PowerMetricsDetailView.swift`**
  - Create view with Header, Component Breakdown (CPU, GPU, Other), Source badge, and mini sparkline.
  - Add `#Preview` with mock data.

- [ ] **Step 2: Update `HostMetricsBarView.swift`**
  - Insert `Button` with `Image(systemName: "bolt.fill")` and `metricsModel.power.formattedTotalWatts` next to Network button.
  - Wire up `.popover` presenting `PowerMetricsDetailView`.

- [ ] **Step 3: Update `CPUMetricsDetailView.swift` and `GPUMetricsDetailView.swift`**
  - Display live wattage if available.

- [ ] **Step 4: Run full Swift test suite on Mac**
  - Run all tests on `IronMentorMac` iOS Simulator and confirm 100% green.

- [ ] **Step 5: Commit changes**
  - Git commit: `feat(ios-ui): add global power glyph, power detail popover, and component wattage`.

---

### Task 7: Live Host Deployment, Verification & Fastlane TestFlight Release

**Files:**
- All touched files
- Bump metrics version in `msam-metrics.py` and `msam-metrics.ps1` to `2.5.0`

- [ ] **Step 1: Deploy updated release to `forge`**
  - Install release to `~/.local/libexec/msam-host-agent/` and verify `msam-host-agent.service` is active.
  - Run `msam-metrics report --period 1h` and confirm database writes and report output.
  - Verify `metrics` JSON contains `powerWatts` and `power`.

- [ ] **Step 2: Deploy updated release to `IronMentorMac`**
  - Install release, verify launchd service, and test `msam-metrics report`.

- [ ] **Step 3: Run full regression tests**
  - Full Python suite: `python3 -m unittest discover -s tests -p "test_*.py"` (all pass).
  - Full Swift suite on Mac: `xcodebuild test` (all pass).

- [ ] **Step 4: Build and ship TestFlight release via Fastlane on `IronMentorMac`**
  - Run `fastlane beta`.
  - Verify successful upload and record TestFlight build number.

- [ ] **Step 5: Commit, push git, and report completion**
  - Push branch to `origin/main`.
