# Power Metrics, SQLite Time-Series Storage, and Reporting Engine Design

## Overview
This document specifies the architecture, data models, host collectors, SQLite time-series storage, reporting engine, and iOS UI additions for real-time power monitoring and historical telemetry reporting in Multi-Session AI Manager.

## Background & Empirical Research
On-device probing was conducted across target environments:
1. **Linux x86 (`forge`)**:
   - Intel/AMD CPU Package Energy is available via RAPL MSRs (`/sys/class/powercap/intel-rapl:0/energy_uj`). Restricted by Linux kernel to root by default; accessible via `sudo -n` or udev rules. Verified live: 42.48 W.
   - NVIDIA GPU: `nvidia-smi --query-gpu=power.draw` is accessible by unprivileged users, returning live board wattage. Verified live: 16.23 W (RTX 5070 Ti).
2. **Linux ARM / DGX (`spark`)**:
   - NVIDIA Grace Blackwell GB10: `nvidia-smi` reports live wattage (verified live: 67.23 W).
3. **macOS Apple Silicon (`IronMentorMac`)**:
   - `sudo -n powermetrics -n 1 -i 100 --samplers cpu_power` measures on-die calibrated sensors for CPU, GPU, ANE, and Combined Package Power in milliwatts with ~290ms execution time.
   - Verified live: CPU 4.30 W, GPU 0.04 W, Combined 4.34 W.

---

## 1. Host Data Storage: SQLite Time-Series Database

### Database Location & Configuration
- **Linux/macOS**: `~/.local/state/msam/metrics-history.db`
- **Windows**: `%LOCALAPPDATA%\msam\metrics-history.db`
- **Engine PRAGMAs**:
  ```sql
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA auto_vacuum = INCREMENTAL;
  ```

### Table Schema: `metrics_samples`
```sql
CREATE TABLE IF NOT EXISTS metrics_samples (
    timestamp REAL PRIMARY KEY,          -- Unix epoch (seconds, float precision)
    cpu_util REAL,                       -- CPU utilization %
    cpu_temp REAL,                       -- CPU temperature °C
    cpu_watts REAL,                      -- CPU package Watts
    mem_used_gb REAL,                    -- Memory used in GB
    mem_total_gb REAL,                   -- Total system memory in GB
    gpu_util REAL,                       -- GPU utilization %
    gpu_temp REAL,                       -- GPU temperature °C
    gpu_watts REAL,                      -- GPU board Watts
    net_down_kbps REAL,                  -- Download speed KB/s
    net_up_kbps REAL,                    -- Upload speed KB/s
    system_watts REAL,                   -- System total Watts
    power_source TEXT                    -- Source ("rapl+nvml", "powermetrics", "battery")
);

CREATE INDEX IF NOT EXISTS idx_metrics_samples_timestamp ON metrics_samples(timestamp);
```

### Retention & Pruning
- The metrics sampling loop executes continuous ~5s logging.
- An hourly background task executes pruning:
  ```sql
  DELETE FROM metrics_samples WHERE timestamp < unixepoch('now', '-30 days');
  ```
- 30-day storage footprint: ~18 MB.

---

## 2. Multi-Platform Power Telemetry

### Linux Collector (`msam-metrics.py`)
- **CPU**: Read `intel-rapl:0/energy_uj` directly or via `sudo -n cat`. Differentiate $\Delta \text{energy} / \Delta t$ taking account of `max_energy_range_uj` rollover.
- **GPU**: Query `nvidia-smi --query-gpu=power.draw --format=csv,nounits,noheader`. AMD fallback: `/sys/class/drm/card*/device/hwmon/hwmon*/power1_average`.
- **System Total**:
  - Laptops: Battery discharge `/sys/class/power_supply/*/power_now` (or `current_now * voltage_now`).
  - Desktops / DGX: Component sum (`cpu_watts + gpu_watts + baseboard_overhead`), tagged `"rapl+nvml"`.

### macOS Collector (`msam-metrics.py`)
- Apple Silicon: Parse `sudo -n powermetrics -n 1 -i 100 --samplers cpu_power`. Extract `CPU Power`, `GPU Power`, `Combined Power`.
- Fallback: `pmset -g rawbatt` for laptop battery power.

### Windows Collector (`msam-metrics.ps1`)
- GPU: `nvidia-smi`.
- Battery / Global: WMI `BatteryStatus.DischargeRate` or component sum.

### Additive JSON Payload Structure
```json
{
  "cpu": {
    "utilization": 14.5,
    "temperature": 48.0,
    "powerWatts": 42.5
  },
  "gpu": {
    "usagePercent": 18.0,
    "temperature": 52.0,
    "powerWatts": 16.2
  },
  "power": {
    "totalWatts": 58.7,
    "cpuWatts": 42.5,
    "gpuWatts": 16.2,
    "source": "rapl+nvml"
  }
}
```

---

## 3. Reporting Engine & Host CLI

### CLI Subcommand
```bash
msam-metrics report [--period 1h|24h|7d|30d] [--from ISO] [--to ISO] [--format table|json|csv] [--cost-per-kwh RATE]
```

### Summary Aggregation
- **CPU**: Avg/Max %, Avg Temp, Avg/Peak Watts
- **Memory**: Avg/Peak Used GB, Total GB
- **GPU**: Avg/Max %, Avg Temp, Avg/Peak Watts
- **Network**: Total Down/Up volume (MB/GB), Peak Down/Up speed
- **Power**: Avg/Max/Min System Watts, **Total Energy (kWh)**:
  $$\text{kWh} = \sum \frac{\text{System Watts} \times \Delta t_{\text{hours}}}{1000}$$
  Optional cost calculation via `--cost-per-kwh`.

### Host Agent API
- Endpoint: `GET /api/metrics/report?period=24h&format=json`

---

## 4. Swift Models & iOS UI

### Swift Models (`HostMetricsModel.swift`)
- Add `struct PowerMetrics: Decodable`:
  - `totalWatts: Double?`
  - `cpuWatts: Double?`
  - `gpuWatts: Double?`
  - `source: String?`
  - `formattedTotalWatts: String`
  - `hasPower: Bool`
- In `CPUMetrics`: `powerWatts: Double?`
- In `GPUMetrics`: `powerWatts: Double?`
- In `HostMetricsModel`:
  - `var power = PowerMetrics()`
  - `var powerHistory: [Double] = []`

### iOS UI Updates
- **`HostMetricsBarView.swift`**:
  - Insert global power glyph immediately to the right of Network:
    `[Port Tunnels] [CPU 14%] [GPU 18%] [RAM 23%] [DSK 45%] [NET ↓145KB/s] [⚡ 98W]`
  - Yellow `bolt.fill` icon when active, muted `—` when unmeasured.
- **`PowerMetricsDetailView.swift`**:
  - Popover displaying Total System Power, CPU Draw, GPU Draw, Baseboard/Other, Telemetry Source, and 30-sample mini sparkline.
- **Detail Popovers**:
  - `CPUMetricsDetailView`: Displays live package power.
  - `GPUMetricsDetailView`: Displays live GPU board draw.

---

## 5. Verification & Testing Strategy
- Unit tests in `tests/test_msam_metrics.py` for RAPL parsing, power sampling, SQLite inserts, rolling retention, and report aggregation.
- Unit tests in `tests/test_msam_host_agent.py` for `/api/metrics/report` endpoint.
- Swift unit tests for `PowerMetrics` decoding, history accumulation, and `HostMetricsBarView` rendering.
- Live testing on `forge`, `IronMentorMac`, and `spark`.
