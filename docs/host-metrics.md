# Host metrics

The Python collector in `app/MultiSessionAIManager/Resources/msam-metrics.py`
and the Windows PowerShell collector use protocol version **2.3.0**. All five
SwiftUI popovers share `MetricsPopover.swift` for presentation and scroll bounds,
with animated instruments in `MetricsInstruments.swift`.

## Additive payload fields

All new fields are optional in the Swift decoder. No existing keys were removed
or renamed. An absent or null field in an older collector remains usable.

| Field | Shape / units |
| --- | --- |
| `memory.topProcesses` | Up to ten entries, descending RSS: `{id: String, pid: Int, name: String, rssBytes: Number}` |
| `disk.platform` | `linux`, `darwin`, or `win32` |
| `disk.temperatures` | Physical devices: `{id: String, model: String, temperature: Number}`; Celsius |
| `disk.disks[].volumes[].availableGB` | GiB available to ordinary users, excluding reserved blocks |
| `disk.disks[].volumes[].isCriticalMount` | Whether the mount contributes to overall capacity status |
| `disk.physicalDisks` | Hardware inventory: `id`, `model`, `volumes: []`, optional Celsius `temperature`, GiB `totalGB`, and optional GiB `availableGB` |
| `gpu.utilizationAvailable` | Whether utilization was measured; a known model alone does not imply an idle GPU |

Physical capacity comes from Linux sysfs, macOS `diskutil`, or Windows
`Get-PhysicalDisk`. Physical `availableGB` means free space in attributable
mounted filesystems, not unpartitioned space. Unmounted disks and ambiguous pool
members report null. LVM, Btrfs, Storage Spaces and multi-store APFS free space is
not divided across hardware members. Single-store APFS container free space is
counted once. NVMe namespaces remain separate capacity entries and share their
controller's temperature. Legacy sensors can populate the physical list, but
logical groups are never invented as hardware.

The historical `GB` field names continue to carry GiB (`1024³` bytes). The UI
now labels those values GiB. `rssBytes` is bytes on both Linux and macOS; it is
independent of CPU process `usage`. Linux process IDs include the process start
tick (`pid:start`) so PID reuse cannot attach a different process's name to RSS.
RSS includes shared resident pages, so process values should not be summed as
an estimate of total physical memory used.

`disk.temperatures` is independent of filesystem grouping, including disks that
back LVM or have no mounted filesystem. Multiple hwmon sensors use their maximum
reading for one physical device. NVMe identities are now controller IDs such as
`nvme0` (formerly the disk grouping could be `nvme0n1`); the model comes from
`/sys/class/nvme/nvme0/model`. Separate drives with the same model remain separate
rows. The legacy per-disk `temperature` field is retained.

## Calculation and presentation

- CPU percentages remain floating point in transport and history. The UI rounds
  them to whole numbers, including process shares of total CPU capacity.
- Linux samples `/proc/stat` over the same monotonic window as CPU processes and
  network counters. Aggregate utilization sums valid per-core tick deltas, which
  is a weighted mean by elapsed ticks across the collector's allowed logical
  CPUs. Reset/hotplug samples are omitted; zero-delta samples retain the previous
  reading. Decreasing iowait is clamped per core. Guest counters are not counted
  twice; steal remains in the denominator but is not executing CPU work.
- CPU temperature is the maximum of recognized CPU package/core sensors. An
  unrelated chipset sensor is never presented as CPU temperature.
- Linux enumerates local mounted filesystems, including ZFS datasets. Memory,
  pseudo, loop and RAM filesystems are excluded. Bind/device aliases do not
  double-count storage. APFS system helper volumes remain excluded.
- Free percentage is `available / (used + available) × 100`, consistent with the
  ordinary-user capacity reported by `df`. Below 20% is a warning; below 10% is
  critical. Linux watches each reported mount, macOS watches `/`, and Windows
  watches `C:\`. The worst eligible mount drives the disk bar colour, displayed
  percentage, and primary details. Thus `/data` at 82% used warns even if the
  aggregate is mostly empty.
- Older payloads use `totalGB - usedGB` for free space and infer the host OS from
  drive paths. New fields remain optional, including physical inventory.
- Windows matches physical and OS disks by stable IDs, not device numbers.
  Temperatures use `Get-StorageReliabilityCounter` when the driver and current
  permissions allow it; failure does not hide the disk.
- Logical-core activity uses Linux interval counters, macOS Mach processor
  counters, and Windows CIM processor information (including processor groups).
  macOS needs two samples. Missing readings leave the core map unavailable.
- macOS network rates use named byte columns and one link row per Ethernet/Wi-Fi
  interface, with monotonic timing and interface reset handling.
- The app keeps the latest 30 samples for CPU, RAM, GPU, and each mount. Histories
  are local state, not new payload fields. Disk history follows the selected
  mount rather than mixing samples from different filesystems. Download and
  upload each retain 30 measured byte-rate samples as well.

Linux counter semantics are described in the
[kernel `/proc` documentation](https://kernel.org/doc/html/v6.10/filesystems/proc.html).

## Display

Physical disks appear first with model, temperature, size and attributable free
space. Logical volumes follow with animated liquid-fill containers and the
existing green/amber/red pressure colours. Free space and size remain numerical.
RAM uses a liquid reservoir; CPU and GPU use 0–100% dials alongside history.
Logical CPU tiles form a chip-style heatmap, explicitly labelled as activity
rather than a physical die topology. Network uses directional flow animation
and two rate charts with the same scale; no link utilization or lifetime totals
are inferred. The old hard-coded network totals and connectivity badges are gone.

Animations run at up to 20 fps while active, respect Reduce Motion, and live only
inside open detail views. Unknown GPU readings render as unavailable. GPU support
remains dependent on host drivers: NVIDIA telemetry on Linux, IOAccelerator on
macOS, and Windows counters/NVIDIA tooling on Windows.

## Verification

Run `python3 -m unittest discover -s tests`. Collector fixtures cover weighted
CPU windows, resets, affinity, RSS ranking and PID reuse, `/data` at 82% used,
reserved blocks, ZFS, NVMe controller/model deduplication, SCSI drivetemp,
macOS RSS and APFS, and Windows volume paths.

`HostMetricsModelTests.swift` covers whole-number formatting while retaining
float samples, optional-field decoding, mount selection and threshold boundaries,
physical temperature decoding, and bounded history. Run these with the Xcode
test target on a Swift-equipped machine; the Linux workspace has no Swift
toolchain and cannot validate the rendered popovers.

Additional fixtures in `test_metrics_storage_inventory.py` cover unmounted
drives, LVM ambiguity, NVMe namespaces, single-store and shared APFS containers.
`test_metrics_mac_activity.py` covers core deltas/resets, network byte columns
and duplicate rows, and GPU identity without utilization. Run Windows fixtures
with `pwsh -NoProfile -File tests/test_msam_metrics_windows.ps1` (or
`powershell.exe`); they execute collector functions with OS command fixtures,
including single-core JSON serialization, storage identity and sensor failures.
These are fixture tests, not a substitute for native hardware checks.

Relevant APIs: [Windows reliability counters](https://learn.microsoft.com/en-us/powershell/module/storage/get-storagereliabilitycounter),
[Windows volume associations](https://learn.microsoft.com/en-us/powershell/module/storage/get-volume),
and [SwiftUI animation schedule](https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)).
