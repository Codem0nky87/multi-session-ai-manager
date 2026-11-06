# Hardware Reference Database (`msam-hardware-db.json`) & TestFlight Release Plan

## Overview
Build a curated, local manufacturer reference database (`msam-hardware-db.json`) bundled with the host service and app resources, enabling accurate hardware TDP and PSU capacity lookup for both integrated SoCs (e.g., NVIDIA DGX Spark, Apple Silicon) and modular custom desktop rigs (e.g., AMD Ryzen 9 9950X3D2 + RTX 5070 Ti).

---

## File Structure

### Data & Resources
- `app/MultiSessionAIManager/Resources/msam-hardware-db.json`:
  - Curated database of known OEM systems, CPU architectures (AMD, Intel, Apple), and GPUs (NVIDIA, AMD).
  - Versioned and updatable per TestFlight build.

### Python Engine
- `app/MultiSessionAIManager/Resources/msam-metrics.py`:
  - `load_hardware_db(db_path=None)`: Loads and caches the hardware database with fallback.
  - `get_system_info(sys_root)`: Inspects DMI `/sys/class/dmi/id/product_name` and `/proc/device-tree/model`.
  - `get_cpu_tdp`: Matches against `systems` first (for integrated SoCs like DGX Spark), then `cpu` entries.
  - `get_gpu_tdp`: Matches against `systems` first, then `gpu` entries.
  - `calculate_recommended_psu`: Uses `psu_capacity_watts` if defined by matched OEM system (e.g. 240W for DGX Spark), otherwise calculates via `(CPU + GPU + 80) * 1.4` rounded to standard PSU tiers.
- `app/MultiSessionAIManager/Resources/msam-host-agent.py`:
  - Add `'msam-hardware-db.json'` to `COMPONENT_DIGEST_FILES`.

### Swift App Resources
- `app/MultiSessionAIManager/Core/HostServiceInstaller.swift`:
  - Add `"msam-hardware-db.json"` to `resources` array.
- `app/MultiSessionAIManager/Tests/HostServiceTests.swift`:
  - Verify `"msam-hardware-db.json"` is bundled and accessible.

### Tests
- `tests/test_msam_metrics.py`:
  - Test database loading, validation, OEM system resolution, and fallback behavior.

---

## Tasks

### Task 1: Create Curated `msam-hardware-db.json` & Swift Bundling
- **Files:** `app/MultiSessionAIManager/Resources/msam-hardware-db.json`, `app/MultiSessionAIManager/Core/HostServiceInstaller.swift`, `app/MultiSessionAIManager/Resources/msam-host-agent.py`, `app/MultiSessionAIManager/Tests/HostServiceTests.swift`
- **Steps:**
  1. Author `msam-hardware-db.json` with researched manufacturer specs:
     - `systems`: `NVIDIA DGX Spark` (SoC TDP 140W, full load 233.2W, OEM PSU 240W), `DGX Station A100`.
     - `cpu`: AMD Ryzen 9 9950X3D2 (200W), 9950X3D (170W), 9950X (170W), 9900X (120W), 9800X3D (120W), 7800X3D (120W), 7950X, 7900X, 7700X, 7600X, 5000 series; Intel Core Ultra 200 series (285K/265K/245K), 14th/13th gen i9/i7/i5; Apple M1/M2/M3/M4 (Base, Pro, Max, Ultra).
     - `gpu`: NVIDIA RTX 50 series (5090 575W, 5080 360W, 5070 Ti 300W, 5070 250W), RTX 40 series, RTX 30 series, GB10 (140W), GB200 (1000W), GH200 (900W), H100 (700W), A100 (400W); AMD RX 7900 XTX/XT, 7800 XT, etc.
  2. Register `"msam-hardware-db.json"` in `HostServiceInstaller.resources` and `msam-host-agent.py` `COMPONENT_DIGEST_FILES`.
  3. Add test in `HostServiceTests.swift` verifying `msam-hardware-db.json` is listed and loaded.

### Task 2: Integrate Database Lookups into `msam-metrics.py`
- **Files:** `app/MultiSessionAIManager/Resources/msam-metrics.py`, `tests/test_msam_metrics.py`
- **Steps:**
  1. Write failing tests in `tests/test_msam_metrics.py` testing database lookup for:
     - OEM integrated systems (DGX Spark -> 140W SoC TDP, 240W OEM PSU).
     - Modular desktop components (Ryzen 9 9950X3D2 -> 200W, RTX 5070 Ti -> 300W -> 850W PSU).
     - Fallback when file is missing.
  2. Implement `load_hardware_db`, `get_system_product_name`, and database-driven matching in `get_cpu_tdp`, `get_gpu_tdp`, and `calculate_recommended_psu`.
  3. Run `pytest tests/test_msam_metrics.py` to confirm all tests pass.

### Task 3: Live Verification Across Hosts & TestFlight Release
- **Hosts:** `forge`, `spark`, `IronMentorMac`
- **Steps:**
  1. Commit and push to `origin/main`.
  2. Deploy `msam-hardware-db.json` and updated scripts to `forge`, `spark`, and `IronMentorMac`.
  3. Verify live metrics on `spark`: CPU/GPU TDP 140W, PSU ceiling 240W.
  4. Verify live metrics on `forge`: CPU TDP 200W, GPU TDP 300W, PSU ceiling 850W.
  5. Pull on `IronMentorMac`, run `xcodebuild test` on simulator (all suites passing).
  6. Run `fastlane beta` to build, sign, and upload TestFlight release.
