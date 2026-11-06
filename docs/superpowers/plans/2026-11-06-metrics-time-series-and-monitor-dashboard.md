# Metrics Time-Series Export, PSU Info Glyph, and Monitor Herdr Space Implementation Plan

## Overview
This plan implements:
1. **AMD Ryzen 9 9950X3D2 TDP refinement (200W)** in `msam-metrics.py`.
2. **Metrics Time-Series Readings in JSON Export** with ISO and epoch reading timestamps and adaptive downsampling for LLM consumption.
3. **Recommended PSU Info `(i)` Glyph** in `PowerMetricsDetailView.swift` explaining the calculation formula and standard size rounding.
4. **Terminal Monitor Dashboard (`msam-host-agent monitor`)** combining live hardware telemetry (CPU, GPU, RAM, Power, Network) with multi-agent fleet activity (Codex, Claude, Antigravity, Hermes).
5. **"Open Monitor Space" button** in both Manage Host Settings (`HostServiceSheet`) and the Metrics screen (`HostMetricsDetailView`) that focuses/creates a Herdr workspace labeled `monitor` and launches the terminal dashboard.

---

## File Structure

### Python (Host Service Resources & Tests)
- `app/MultiSessionAIManager/Resources/msam-metrics.py`:
  - Update `CPU_TDP_MODELS` to detect `9950X3D` at 200.0W before general `9950X`.
  - Update `get_report_data` to query and return a `samples` list with `time` (ISO 8601), `timestamp` (epoch), and all metrics. Apply downsampling if count > 1500 to keep JSON LLM-friendly.
  - Implement `run_monitor_tui()` live dashboard renderer.
- `app/MultiSessionAIManager/Resources/msam-host-agent.py`:
  - Add `monitor` subcommand routing to `msam-metrics.py run_monitor_tui()`.
- `tests/test_msam_metrics.py`:
  - Add tests for `9950X3D` TDP lookup.
  - Add tests for `get_report_data` and `generate_metrics_report` verifying `samples` list structure, timestamps, and downsampling.
  - Add tests for monitor dashboard output.
- `tests/test_msam_host_agent.py`:
  - Add tests verifying `msam-host-agent monitor` command argument handling.

### Swift (iOS / iPadOS App UI & Core)
- `app/MultiSessionAIManager/Core/HerdrSessionRollover.swift`:
  - Add helper `makeOpenMonitorWorkspaceCommand()` generating the shell script to check/create/focus the `monitor` Herdr workspace and run `msam-host-agent monitor`.
- `app/MultiSessionAIManager/UI/Metrics/PowerMetricsDetailView.swift`:
  - Add `(i)` info button (`info.circle`) next to Recommended PSU / PSU capacity with popover explaining `(CPU TDP + GPU TDP + 80W) × 1.4` rounded up to standard PSU sizes.
- `app/MultiSessionAIManager/UI/Hosts/HostServiceSheet.swift`:
  - Add "Open Monitor Space" button in the Metrics history section alongside "Download Metrics Report".
- `app/MultiSessionAIManager/UI/Metrics/HostMetricsDetailView.swift`:
  - Add "Open Monitor Space" button / toolbar item in the metrics view.
- `app/MultiSessionAIManager/Tests/HerdrSessionRolloverTests.swift`:
  - Add tests for `makeOpenMonitorWorkspaceCommand()`.
- `app/MultiSessionAIManager/Tests/PowerMetricsDetailViewTests.swift`:
  - Add tests for PSU info popover / view rendering.

---

## Tasks

### Task 1: 9950X3D TDP Refinement & JSON Report Time-Series Samples
- **Files:** `app/MultiSessionAIManager/Resources/msam-metrics.py`, `tests/test_msam_metrics.py`
- **Steps:**
  1. Write failing unit tests in `tests/test_msam_metrics.py` testing:
     - `get_cpu_tdp("AMD Ryzen 9 9950X3D2 16-Core Processor") == 200.0`.
     - `get_report_data` returns a `"samples"` list where each item contains `timestamp`, `time` (ISO 8601), `cpu_util_pct`, `cpu_temp_c`, `cpu_watts`, `mem_used_gb`, `mem_total_gb`, `gpu_util_pct`, `gpu_temp_c`, `gpu_watts`, `net_down_kbps`, `net_up_kbps`, `system_watts`.
     - Large sample lists (> 1500) are cleanly downsampled while keeping start and end points.
  2. Implement `9950X3D` rule in `get_cpu_tdp` in `msam-metrics.py`.
  3. Implement `samples` query and formatting in `MetricsHistoryDB.get_report_data` in `msam-metrics.py`.
  4. Run `pytest tests/test_msam_metrics.py` to verify all tests pass.

### Task 2: Terminal Monitor Dashboard in `msam-metrics.py` and `msam-host-agent.py`
- **Files:** `app/MultiSessionAIManager/Resources/msam-metrics.py`, `app/MultiSessionAIManager/Resources/msam-host-agent.py`, `tests/test_msam_host_agent.py`
- **Steps:**
  1. Write failing unit test in `tests/test_msam_host_agent.py` verifying `msam-host-agent monitor --help` or `--oneshot` exits with 0 and prints the dashboard frame.
  2. Implement `render_monitor_frame(metrics, agents_data)` in `msam-metrics.py`:
     - System hardware block: CPU bar + temp + watts, GPU bar + temp + watts, Memory bar, Power draw vs Recommended PSU ceiling, Network speeds.
     - AI agent fleet block: Active sessions for Codex, Claude, Antigravity, Hermes (models, tokens, tasks).
  3. Implement `run_monitor_tui()` in `msam-metrics.py` with in-place ANSI redraw and clean exit on `q` or `SIGINT`.
  4. Wire `monitor` subcommand into `msam-host-agent.py`.
  5. Run `pytest tests/test_msam_host_agent.py tests/test_msam_metrics.py` to verify.

### Task 3: Recommended PSU Info `(i)` Glyph in Power Metrics UI
- **Files:** `app/MultiSessionAIManager/UI/Metrics/PowerMetricsDetailView.swift`, `app/MultiSessionAIManager/Tests/PowerMetricsDetailViewTests.swift`
- **Steps:**
  1. Write failing test in `PowerMetricsDetailViewTests.swift` checking for the info button and explanatory text.
  2. In `PowerMetricsDetailView.swift`, add `@State private var showingPsuInfo = false`.
  3. Add an `info.circle` button alongside "Recommended PSU" with a `.popover` (or alert) detailing:
     - Header: "Recommended PSU Minimum"
     - Formula: `(CPU TDP + GPU TDP + 80W) × 1.4`
     - Explanation: "Hardware power supplies do not expose digital capacity sensors to the OS. The ceiling is calculated from component TDPs plus 80W motherboard/storage overhead with a 40% transient buffer, rounded up to standard PSU sizes."
  4. Verify compilation and test on macOS simulator.

### Task 4: Herdr Monitor Workspace Command & App UI Integration
- **Files:** `app/MultiSessionAIManager/Core/HerdrSessionRollover.swift`, `app/MultiSessionAIManager/UI/Hosts/HostServiceSheet.swift`, `app/MultiSessionAIManager/UI/Metrics/HostMetricsDetailView.swift`, `app/MultiSessionAIManager/Tests/HerdrSessionRolloverTests.swift`
- **Steps:**
  1. Write unit test in `HerdrSessionRolloverTests.swift` for `HerdrSessionRollover.makeOpenMonitorWorkspaceCommand()`.
  2. Implement `makeOpenMonitorWorkspaceCommand()`:
     - Script lists Herdr workspaces (`herdr workspace list`).
     - If `monitor` workspace exists, focuses it (`herdr workspace focus <id>`).
     - If not, creates it (`herdr workspace create --label "monitor" --focus`).
     - In that workspace's pane, runs `"$HOME/.local/bin/msam-host-agent" monitor`.
  3. In `HostServiceSheet.swift`, add an "Open Monitor Space" button in the Metrics history section.
  4. In `HostMetricsDetailView.swift`, add an "Open Monitor Space" button in the toolbar / header.
  5. Wire both buttons to execute the command via the active host session / SSH service, dismiss the sheet/popover, and switch focus to the Herdr terminal.
  6. Verify unit tests pass.

### Task 5: Live Verification Across Hosts & TestFlight Release
- **Hosts:** `forge`, `spark`, `IronMentorMac`
- **Steps:**
  1. Deploy updated host scripts (`msam-metrics.py`, `msam-host-agent.py`) to `forge`, `spark`, and `IronMentorMac`.
  2. Test `msam-host-agent monitor --oneshot` on `forge` and `spark` to verify live rendering.
  3. Test `msam-host-agent report --format json` on `forge` to verify `samples` array with ISO timestamps.
  4. Pull changes on `IronMentorMac` and run `xcodebuild test` on the iPad simulator (0 failures).
  5. Run `fastlane beta` to build, sign, and upload the new TestFlight release.
