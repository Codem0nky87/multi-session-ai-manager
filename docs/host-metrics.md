# Host metrics

The Python collector in `app/MultiSessionAIManager/Resources/msam-metrics.py`
uses protocol version **2.2.0**. The four existing SwiftUI popovers share
`MetricsPopover.swift` for presentation and scroll bounds.

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
  drive paths. The separate Windows PowerShell collector's existing payload is
  supported without changing its protocol.
- The app keeps the latest 30 samples for CPU, RAM, GPU, and each mount. Histories
  are local state, not new payload fields. Disk history follows the selected
  mount rather than mixing samples from different filesystems.

Linux counter semantics are described in the
[kernel `/proc` documentation](https://kernel.org/doc/html/v6.10/filesystems/proc.html).

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
