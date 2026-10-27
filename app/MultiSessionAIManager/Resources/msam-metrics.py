#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import time
import math
import plistlib
import re
import shutil
from pathlib import Path

METRICS_VERSION = "2.4.0"

_mac_network_previous = None
_mac_cpu_previous = None

def format_bytes(bytes_per_sec):
    if bytes_per_sec < 1024:
        return f"{int(bytes_per_sec)} B/s"
    elif bytes_per_sec < 1024 * 1024:
        return f"{int(bytes_per_sec / 1024)} KB/s"
    else:
        return f"{bytes_per_sec / (1024 * 1024):.1f} MB/s"


def get_windows_disks():
    metrics = {
        "usagePercent": 0.0,
        "totalGB": 0.0,
        "usedGB": 0.0,
        "platform": "win32",
        "disks": []
    }
    try:
        ps_script = r"""
        $volumes = Get-Volume | Where-Object DriveType -eq 'Fixed' | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
        $result = @()
        foreach ($vol in $volumes) {
            $result += [PSCustomObject]@{
                id = if ($vol.DriveLetter) { $vol.DriveLetter + ':' } else { 'Vol' }
                name = $vol.FileSystemLabel
                mountPoint = if ($vol.DriveLetter) { $vol.DriveLetter + ':\' } else { '' }
                totalGB = $vol.Size / 1GB
                usedGB = ($vol.Size - $vol.SizeRemaining) / 1GB
            }
        }
        $result | ConvertTo-Json
        """
        import subprocess, json
        out = subprocess.check_output(["powershell", "-NoProfile", "-Command", ps_script]).decode('utf-8')
        vols = json.loads(out)
        if isinstance(vols, dict):
            vols = [vols]
            
        disk_obj = {
            "id": "disk0",
            "model": "Windows Disks",
            "volumes": []
        }
        
        total_size = 0.0
        total_used = 0.0
        
        for v in vols:
            disk_obj["volumes"].append({
                "id": v.get("id", ""),
                "name": v.get("name", "") if v.get("name") else "Local Disk",
                "mountPoint": v.get("mountPoint", ""),
                "totalGB": v.get("totalGB", 0.0),
                "usedGB": v.get("usedGB", 0.0)
            })
            disk_obj["volumes"][-1].update(
                availableGB=max(0, v.get("totalGB", 0.0) - v.get("usedGB", 0.0)),
                isCriticalMount=v.get("mountPoint", "").rstrip("\\/").upper() == "C:")
            total_size += v.get("totalGB", 0.0)
            total_used += v.get("usedGB", 0.0)
            
        metrics["disks"] = [disk_obj]
        metrics["totalGB"] = total_size
        metrics["usedGB"] = total_used
        metrics["usagePercent"] = (total_used / total_size * 100.0) if total_size > 0 else 0.0
    except Exception:
        pass
    return metrics

def linux_disk_identity(device, sys_root='/sys'):
    # Preserve complete mapper names; partitions share their parent disk's model.
    name = device[5:]
    resolved_name = os.path.basename(os.path.realpath(device))
    controller = re.fullmatch(r'(nvme\d+)(?:n\d+)?(?:p\d+)?', resolved_name)
    if controller:
        name = controller.group(1)
        return name, linux_disk_model(name, sys_root)
    block = Path(sys_root) / 'class/block' / resolved_name
    if (block / 'partition').exists():
        block = block.resolve().parent
        if not name.startswith('mapper/'):
            name = block.name
    try:
        model = (block / 'device/model').read_text().strip()
    except OSError:
        model = 'Logical Volume' if name.startswith('mapper/') else 'Linux Disk'
    return name, model or 'Linux Disk'


def linux_disk_model(device, sys_root='/sys'):
    root = Path(sys_root)
    path = (root / 'class/nvme' / device / 'model' if re.fullmatch(r'nvme\d+', device)
            else root / 'class/block' / device / 'device/model')
    try:
        return path.read_text().strip() or device
    except OSError:
        return device


def linux_disk_temperatures(sys_root='/sys'):
    # Map physical device names (sda, nvme0) to SMART temperatures exposed via
    # hwmon: NVMe drives publish an "nvme<N>" hwmon, SATA/USB drives one named
    # after the block device via the drivetemp driver.
    temps = {}

    def read_temp(path):
        try:
            value = float(path.read_text().strip()) / 1000.0
            return value if math.isfinite(value) and 0 < value < 150 else None
        except (OSError, ValueError):
            return None

    try:
        monitors = sorted((Path(sys_root) / 'class/hwmon').glob('hwmon*'))
    except OSError:
        return temps
    for monitor in monitors:
        try:
            name = (monitor / 'name').read_text().strip()
            if name not in ('nvme', 'drivetemp'):
                continue
            device_path = Path(os.path.realpath(str(monitor / 'device')))
            if name == 'nvme':
                # Some hwmon links point below the controller directory.
                device = next((part for part in reversed(device_path.parts)
                               if re.fullmatch(r'nvme\d+', part)), None)
            else:
                device = device_path.name if re.fullmatch(r'[sh]d[a-z]+', device_path.name) else None
                # drivetemp usually links to a SCSI device (H:C:T:L), whose
                # block/ child names the actual drive.
                if device is None:
                    device = next((p.name for p in sorted((device_path / 'block').glob('*'))
                                   if re.fullmatch(r'[sh]d[a-z]+', p.name)), None)
            if device is None:
                continue
            values = [v for v in (read_temp(sensor) for sensor in monitor.glob('temp*_input'))
                      if v is not None]
            if values:
                temps[device] = max(temps.get(device, 0), max(values))
        except OSError:
            continue
    return temps


def disk_temperature(disk_id, temps, sys_root='/sys'):
    # disk_id is a physical block name (sda, nvme0n1) or a mapper name; for
    # LVM, resolve the dm device's slaves and report the hottest one.
    if not temps:
        return None
    # NVMe hwmon sensors are keyed by controller (nvme0) while block devices
    # carry the namespace (nvme0n1); strip the namespace suffix to match.
    match = re.match(r'(nvme\d+)n\d+$', disk_id)
    if match:
        disk_id = match.group(1)
    direct = temps.get(disk_id)
    if direct is not None:
        return direct
    if disk_id.startswith('mapper/'):
        # /dev/mapper/vg-lv resolves to /dev/dm-N; the dm device lists its
        # physical slaves under /sys/class/block/dm-N/slaves.
        dm = Path(sys_root) / 'class/block' / os.path.basename(os.path.realpath('/dev/' + disk_id))
        try:
            slaves = [temps.get(p.name) for p in (dm / 'slaves').iterdir()]
        except OSError:
            return None
        values = [t for t in slaves if t is not None]
        if values:
            return max(values)
    return None


def linux_mount_types(proc_root='/proc'):
    types = {}
    try:
        for line in (Path(proc_root) / 'self/mountinfo').read_text().splitlines():
            try:
                mount, filesystem = line.split(' - ', 1)
                path = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), mount.split()[4])
                types[path] = filesystem.split()[0]
            except (ValueError, IndexError):
                continue
    except OSError:
        pass
    return types


def linux_physical_disks(groups, temperatures, sys_root='/sys'):
    """Inventory hardware independently of mounts, without apportioning pool free space."""
    result = []
    volumes = [v for group in groups for v in group['volumes']]
    for block in sorted((Path(sys_root) / 'class/block').glob('*')):
        name = block.name
        if (block / 'partition').exists() or name.startswith(('loop', 'ram', 'zram', 'dm-', 'md', 'sr')):
            continue
        if not (block / 'device').exists() and not re.fullmatch(r'nvme\d+n\d+', name):
            continue
        try:
            size = int((block / 'size').read_text()) * 512
            if size <= 0:
                continue
        except (OSError, ValueError):
            continue
        controller = re.fullmatch(r'(nvme\d+)n\d+', name)
        sensor_id = controller.group(1) if controller else name
        attached = []
        for volume in volumes:
            if volume.get('fileSystem') == 'btrfs':
                continue  # The mount device can be just one member of a pool.
            device = os.path.basename(os.path.realpath(volume['id']))
            # Delimit partitions explicitly: sda must not match sdaa; n1 not n10.
            suffix = r'p\d+' if name[-1:].isdigit() else r'\d+'
            if device == name or re.fullmatch(re.escape(name) + suffix, device):
                attached.append(volume)
        result.append({'id': name, 'model': linux_disk_model(sensor_id, sys_root),
                       'totalGB': size / 1024**3,
                       'availableGB': sum(v['availableGB'] for v in attached) if attached else None,
                       'temperature': temperatures.get(sensor_id), 'volumes': []})
    return result


def mac_physical_disks(groups):
    def diskutil(*args):
        try:
            data = subprocess.check_output(['diskutil', *args], stderr=subprocess.DEVNULL, timeout=2)
            value = plistlib.loads(data)
            return value if isinstance(value, dict) else {}
        except (OSError, subprocess.SubprocessError, ValueError, plistlib.InvalidFileException):
            return {}

    listing = diskutil('list', '-plist', 'physical').get('AllDisksAndPartitions', [])
    if not listing:
        return []
    containers = diskutil('apfs', 'list', '-plist').get('Containers', [])
    volumes = [v for group in groups for v in group['volumes']]
    result = []
    for disk in listing:
        disk_id, size = disk.get('DeviceIdentifier', ''), disk.get('Size', 0)
        if not re.fullmatch(r'disk\d+', disk_id) or size <= 0:
            continue
        info = diskutil('info', '-plist', disk_id)
        available = []
        shared = False
        for container in containers:
            stores = container.get('PhysicalStores', [])
            if any(re.fullmatch(re.escape(disk_id) + r's\d+', s.get('DeviceIdentifier', '')) for s in stores):
                if len(stores) == 1 and 'CapacityFree' in container:
                    available.append(max(0, container['CapacityFree']) / 1024**3)
                else:
                    shared = True
        # Non-APFS volumes refer directly to physical partitions.
        available.extend(v['availableGB'] for v in volumes
                         if re.fullmatch('/dev/' + re.escape(disk_id) + r'(s\d+)?', v['id']))
        result.append({'id': disk_id, 'model': info.get('MediaName') or info.get('DeviceModel') or disk_id,
                       'totalGB': size / 1024**3,
                       'availableGB': sum(available) if available and not shared else None,
                       'temperature': None, 'volumes': []})
    return result


def get_unix_disks(sys_root='/sys', proc_root='/proc'):
    metrics = {'usagePercent': 0.0, 'totalGB': 0.0, 'usedGB': 0.0, 'disks': [],
               'platform': sys.platform}
    is_mac = sys.platform == 'darwin'
    mount_types = {} if is_mac else linux_mount_types(proc_root)
    virtual_types = {'proc', 'sysfs', 'tmpfs', 'devtmpfs', 'devpts', 'ramfs',
                     'cgroup', 'cgroup2', 'securityfs', 'pstore', 'debugfs',
                     'tracefs', 'configfs', 'hugetlbfs', 'mqueue', 'fusectl',
                     'bpf', 'autofs', 'overlay', 'nsfs', 'efivarfs'}
    disk_temps = {} if is_mac else linux_disk_temperatures(sys_root)
    # Separate physical sensors from filesystem/LVM grouping. A disk can back
    # several volumes or no mounted volume and must appear here only once.
    metrics['temperatures'] = [
        {'id': device, 'model': linux_disk_model(device, sys_root), 'temperature': value}
        for device, value in sorted(disk_temps.items())]
    root_usage = None
    if is_mac:
        try:
            # APFS shares free space with Data/Preboot/etc. Show the container's
            # actual occupied space once, not just the read-only system volume.
            root_usage = shutil.disk_usage('/')
            metrics.update(totalGB=root_usage.total / 1024**3,
                           usedGB=root_usage.used / 1024**3,
                           usagePercent=100.0 * root_usage.used / root_usage.total)
        except (OSError, ZeroDivisionError):
            pass
    disks = {}
    seen_devices = set()
    total_used = total_available = 0.0
    try:
        # POSIX columns also work on macOS; local-only avoids stale SMB mounts.
        output = subprocess.check_output(['df', '-P', '-k', '-l'],
                                         stderr=subprocess.DEVNULL, timeout=3).decode('utf-8', 'replace')
    except (OSError, subprocess.SubprocessError):
        metrics['physicalDisks'] = (mac_physical_disks([]) if is_mac
                                    else linux_physical_disks([], disk_temps, sys_root))
        return metrics
    for line in output.splitlines()[1:]:
        parts = line.split(maxsplit=5)
        if len(parts) != 6:
            continue
        device, mount = parts[0], parts[5]
        filesystem = mount_types.get(mount)
        if not device.startswith('/dev/'):
            # ZFS datasets (tank/data), for example, are real local storage
            # without /dev paths. df -l excludes network filesystems; mountinfo
            # distinguishes persistent local storage from memory/pseudo mounts.
            if is_mac or not filesystem or filesystem in virtual_types:
                continue
        if device.startswith(('/dev/loop', '/dev/ram')):
            continue
        try:
            total, used, available = (int(parts[i]) * 1024 for i in (1, 2, 3))
            if total <= 0:
                continue
            name = os.path.basename(mount) if mount != '/' else 'Root'
            if is_mac:
                if (mount.startswith('/System/Volumes/') or mount == '/Volumes/Recovery'
                        or 'cryptexd' in mount or 'CoreSimulator' in mount):
                    continue
                if mount == '/':
                    name = 'Macintosh HD'
                    if root_usage:
                        total, used, available = root_usage.total, root_usage.used, root_usage.free
                match = re.match(r'/dev/(disk\d+)', device)
                disk_id, model = (match.group(1) if match else device), 'Apple SSD'
            else:
                # Deduplicate bind mounts / device aliases, not distinct LVs.
                identity = os.path.realpath(device) if device.startswith('/dev/') else device
                if identity in seen_devices:
                    continue
                if device.startswith('/dev/'):
                    disk_id, model = linux_disk_identity(device, sys_root)
                elif filesystem == 'zfs':
                    pool = device.split('/')[0]
                    disk_id, model = 'zfs:' + pool, 'ZFS pool ' + pool
                else:
                    disk_id, model = device, filesystem.upper() + ' · ' + device
                try:
                    stat = os.statvfs(mount)
                    total = stat.f_blocks * stat.f_frsize
                    used = (stat.f_blocks - stat.f_bfree) * stat.f_frsize
                    available = stat.f_bavail * stat.f_frsize
                except OSError:
                    pass  # df already provided usable figures.
                seen_devices.add(identity)
            disk = disks.setdefault(disk_id, {'id': disk_id, 'model': model, 'volumes': [],
                                              'temperature': disk_temperature(disk_id, disk_temps, sys_root)})
            disk['volumes'].append({'id': device, 'name': name, 'mountPoint': mount,
                                    'totalGB': total / 1024**3, 'usedGB': used / 1024**3,
                                    'availableGB': max(0, available) / 1024**3,
                                    'fileSystem': filesystem,
                                    'isCriticalMount': not is_mac or mount == '/'})
            total_used += used
            total_available += max(0, available)
        except (ValueError, OSError):
            continue
    metrics['disks'] = list(disks.values())
    metrics['physicalDisks'] = (mac_physical_disks(metrics['disks']) if is_mac
                                else linux_physical_disks(metrics['disks'], disk_temps, sys_root))
    if not is_mac:
        metrics['totalGB'] = sum(v['totalGB'] for d in metrics['disks'] for v in d['volumes'])
        metrics['usedGB'] = sum(v['usedGB'] for d in metrics['disks'] for v in d['volumes'])
        usable = total_used + total_available
        metrics['usagePercent'] = total_used / usable * 100.0 if usable > 0 else 0.0
    return metrics


_mac_gpu_identity = None


def get_mac_gpu():
    global _mac_gpu_identity
    gpu = {'usagePercent': 0.0, 'modelName': '', 'cores': 0,
           'temperature': 0.0, 'memoryUsed': 0.0, 'memoryTotal': 0.0,
           'utilizationAvailable': False}
    try:
        output = subprocess.check_output(['ioreg', '-a', '-r', '-c', 'IOAccelerator', '-d', '1'],
                                         stderr=subprocess.DEVNULL, timeout=2)
        devices = plistlib.loads(output)
        for device in devices:
            stats = device.get('PerformanceStatistics', {})
            if not stats:
                continue
            gpu['modelName'] = str(device.get('model', ''))
            gpu['cores'] = int(device.get('gpu-core-count', 0))
            gpu['usagePercent'] = min(100.0, max(0.0, float(stats.get('Device Utilization %', 0))))
            gpu['utilizationAvailable'] = 'Device Utilization %' in stats
            gpu['memoryUsed'] = float(stats.get('In use system memory', 0)) / 1024**2
            # Apple Silicon uses unified memory, not a dedicated VRAM capacity.
            break
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, plistlib.InvalidFileException):
        pass
    if not gpu['modelName']:
        # Some Intel drivers expose no IOAccelerator statistics. Identity is
        # independent of utilization and only needs the slower profiler once.
        if _mac_gpu_identity is None:
            _mac_gpu_identity = ('', 0)
            try:
                output = subprocess.check_output(['system_profiler', 'SPDisplaysDataType', '-json'],
                                                 stderr=subprocess.DEVNULL, timeout=2)
                display = json.loads(output)['SPDisplaysDataType'][0]
                _mac_gpu_identity = (display.get('sppci_model', ''), int(display.get('sppci_cores', 0)))
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError):
                pass
        gpu['modelName'], gpu['cores'] = _mac_gpu_identity
    return gpu


def mac_cpu_ticks():
    """Read Mach's per-processor counters without sudo or third-party packages."""
    if sys.platform != 'darwin':
        return []
    import ctypes as c
    try:
        lib = c.CDLL('/usr/lib/libSystem.B.dylib')
        uint = c.c_uint
        pointer = c.POINTER(uint)
        lib.mach_host_self.restype = uint
        lib.host_processor_info.argtypes = [uint, c.c_int, c.POINTER(uint), c.POINTER(pointer), c.POINTER(uint)]
        lib.host_processor_info.restype = c.c_int
        lib.vm_deallocate.argtypes = [uint, c.c_void_p, c.c_size_t]
        lib.mach_port_deallocate.argtypes = [uint, uint]
        task = uint.in_dll(lib, 'mach_task_self_').value
        host = lib.mach_host_self()
        count, length, data = uint(), uint(), pointer()
        try:
            # PROCESSOR_CPU_LOAD_INFO = 2; USER, SYSTEM, IDLE, NICE = 0...3.
            status = lib.host_processor_info(host, 2, c.byref(count), c.byref(data), c.byref(length))
            if status != 0:
                return []
            try:
                if length.value < count.value * 4:
                    return []
                return [tuple(data[i * 4 + j] for j in range(4)) for i in range(count.value)]
            finally:
                lib.vm_deallocate(task, c.cast(data, c.c_void_p), length.value * c.sizeof(uint))
        finally:
            lib.mach_port_deallocate(task, host)
    except (OSError, AttributeError, ValueError):
        return []


def mac_cpu_activity():
    global _mac_cpu_previous
    current = mac_cpu_ticks()
    previous, _mac_cpu_previous = _mac_cpu_previous, current
    if not previous or len(previous) != len(current):
        return None, []
    values = []
    tot_user = tot_sys = tot_idle = tot_nice = 0
    for before, after in zip(previous, current):
        delta = [b - a for a, b in zip(before, after)]
        if any(v < 0 for v in delta):
            return None, []
        s = sum(delta)
        if s <= 0:
            values.append(0.0)
        else:
            values.append(100.0 * (s - delta[2]) / s)
            tot_user += delta[0]
            tot_sys += delta[1]
            tot_idle += delta[2]
            tot_nice += delta[3]
    total = tot_user + tot_sys + tot_idle + tot_nice
    if total <= 0:
        return None, values
    agg = {
        'utilization': 100.0 * (total - tot_idle) / total,
        'userUsage': 100.0 * (tot_user + tot_nice) / total,
        'systemUsage': 100.0 * tot_sys / total,
        'idleUsage': 100.0 * tot_idle / total,
    }
    return agg, values


def mac_core_usage():
    _, per_core = mac_cpu_activity()
    return per_core


def mac_network_counters(output):
    lines = output.splitlines()
    if not lines:
        return {}
    headers = lines[0].split()
    try:
        rx, tx, network = (headers.index(name) for name in ('Ibytes', 'Obytes', 'Network'))
    except ValueError:
        return {}
    counters = {}
    for line in lines[1:]:
        fields = line.split()
        try:
            name = fields[0].rstrip('*')
            if re.fullmatch(r'en\d+', name) and fields[network].startswith('<Link#'):
                counters[name] = (int(fields[rx]), int(fields[tx]))
        except (IndexError, ValueError):
            continue
    return counters


def get_mac_metrics():
    core_count = os.cpu_count() or 0
    metrics = {
        "cpu": {
            "temperature": 0.0,
            "utilization": 0.0,
            "systemUsage": 0.0,
            "userUsage": 0.0,
            "idleUsage": 0.0,
            "efficiencyCoreUsage": 0.0,
            "performanceCoreUsage": 0.0,
            "uptime": "",
            "freqAllCores": 0,
            "freqEfficiency": 0,
            "freqPerformance": 0,
            "history": [],
            "topProcesses": [],
            "coreCount": core_count,
            "loadAverage1m": 0.0,
            "loadAverage5m": 0.0,
            "loadAverage15m": 0.0,
            "loadPerCore": 0.0 if core_count else None
        },
        "memory": {
            "usagePercent": 0.0,
            "total": 0.0,
            "used": 0.0,
            "app": 0.0,
            "wired": 0.0,
            "compressed": 0.0,
            "free": 0.0,
            "swap": 0.0,
            "topProcesses": []
        },
        "disk": get_unix_disks(),
        "gpu": {
            "usagePercent": 0.0,
            "modelName": "",
            "cores": 0,
            "temperature": 0.0,
            "memoryUsed": 0.0,
            "memoryTotal": 0.0
        },
        "network": {
            "downloadSpeed": 0.0,
            "uploadSpeed": 0.0,
            "downloadString": format_bytes(0),
            "uploadString": format_bytes(0)
        }
    }
    
    try:
        load1, load5, load15 = os.getloadavg()
        metrics["cpu"]["loadAverage1m"] = load1
        metrics["cpu"]["loadAverage5m"] = load5
        metrics["cpu"]["loadAverage15m"] = load15
        metrics["cpu"]["loadPerCore"] = load1 / core_count if core_count else None
        
        # Try to read SMC temperatures via powermetrics for Intel Macs (requires passwordless sudo)
        try:
            pm_out = subprocess.check_output(['sudo', '-n', 'powermetrics', '--samplers', 'smc', '-n', '1', '-i', '100'], stderr=subprocess.DEVNULL, timeout=1).decode('utf-8')
            for line in pm_out.split('\n'):
                if 'CPU die temperature' in line or 'CPU thermal level' in line:
                    # Format: "CPU die temperature: 45.32 C"
                    parts = line.split(':')
                    if len(parts) > 1:
                        val = parts[1].strip().split(' ')[0]
                        metrics["cpu"]["temperature"] = float(val)
                        break
        except Exception:
            # Fallback for Apple Silicon where SMC sampler isn't supported and raw temp requires compiled IOKit C
            pass
            
    except Exception:
        pass

    metrics["gpu"] = get_mac_gpu()

    try:
        page_size = int(subprocess.check_output(['sysctl', '-n', 'hw.pagesize']).decode('utf-8').strip())
        vm = subprocess.check_output(['vm_stat']).decode('utf-8')
        vm_dict = {}
        for line in vm.split('\n'):
            if ':' in line:
                parts = line.split(':')
                key = parts[0].strip()
                try:
                    val = int(parts[1].strip().replace('.', ''))
                    vm_dict[key] = val
                except ValueError:
                    pass
        
        app_memory = vm_dict.get('Anonymous pages', 0) * page_size
        wired_memory = vm_dict.get('Pages wired down', 0) * page_size
        compressed_memory = vm_dict.get('Pages occupied by compressor', 0) * page_size
        used_memory = app_memory + wired_memory + compressed_memory
        total_ram = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize']).decode('utf-8').strip())
        
        if total_ram > 0:
            metrics["memory"]["usagePercent"] = (used_memory / total_ram) * 100.0
            metrics["memory"]["total"] = total_ram / (1024**3)
            metrics["memory"]["used"] = used_memory / (1024**3)
            metrics["memory"]["app"] = app_memory / (1024**3)
            metrics["memory"]["wired"] = wired_memory / (1024**3)
            metrics["memory"]["compressed"] = compressed_memory / (1024**3)
            metrics["memory"]["free"] = (total_ram - used_memory) / (1024**3)
            
        sys_swap = subprocess.check_output(['sysctl', '-n', 'vm.swapusage']).decode('utf-8').strip()
        # vm.swapusage: total = 2048.00M  used = 1024.00M  free = 1024.00M  (encrypted)
        if "used =" in sys_swap:
            used_str = sys_swap.split("used =")[1].split("M")[0].strip()
            metrics["memory"]["swap"] = float(used_str) / 1024.0
    except Exception:
        pass

    try:
        # RSS is KiB on both macOS ps and Linux /proc/status. Keep memory
        # ranking independent of CPU usage and never expose command arguments.
        output = subprocess.check_output(['ps', '-axo', 'pid=,rss=,comm='],
                                         stderr=subprocess.DEVNULL, timeout=2).decode('utf-8', 'replace')
        processes = []
        for line in output.splitlines():
            try:
                pid, rss, name = line.strip().split(maxsplit=2)
                pid, rss = int(pid), int(rss)
                if rss > 0:
                    processes.append({'id': str(pid), 'pid': pid,
                                      'name': os.path.basename(name), 'rssBytes': rss * 1024})
            except (ValueError, IndexError):
                continue
        metrics['memory']['topProcesses'] = sorted(
            processes, key=lambda p: (-p['rssBytes'], p['pid']))[:10]
    except (OSError, subprocess.SubprocessError):
        pass

    try:
        # Top processes
        ps_out = subprocess.check_output(['ps', '-rc', '-o', 'comm,pcpu', '-e']).decode('utf-8')
        lines = ps_out.strip().split('\n')[1:6]
        top_procs = []
        for line in lines:
            parts = line.rsplit(maxsplit=1)
            if len(parts) == 2:
                top_procs.append({
                    "id": parts[0].strip(),
                    "name": parts[0].strip(),
                    "usage": float(parts[1].strip())
                })
        metrics["cpu"]["topProcesses"] = top_procs
    except Exception:
        pass

    agg, per_core = mac_cpu_activity()
    metrics['cpu']['perCoreUsage'] = per_core
    if agg is not None:
        metrics['cpu'].update(agg)
    else:
        try:
            # CPU Usage via top fallback when Mach ticks delta is not available (e.g. first sample or tests)
            top_out = subprocess.check_output(['top', '-l', '1', '-n', '0']).decode('utf-8')
            for line in top_out.split('\n'):
                if line.startswith('CPU usage:'):
                    parts = line.split(',')
                    user = float(parts[0].split(':')[1].replace('% user', '').strip())
                    sys_ = float(parts[1].replace('% sys', '').strip())
                    idle = float(parts[2].replace('% idle', '').strip())
                    metrics["cpu"]["userUsage"] = user
                    metrics["cpu"]["systemUsage"] = sys_
                    metrics["cpu"]["idleUsage"] = idle
                    metrics["cpu"]["utilization"] = user + sys_
        except Exception:
            pass
        
    try:
        uptime_out = subprocess.check_output(['uptime']).decode('utf-8')
        # 14:48  up 9 days, 5:32, 2 users, load averages: 2.31 2.59 2.50
        up_idx = uptime_out.find('up ')
        user_idx = uptime_out.find(',', uptime_out.find(',', up_idx)+1)
        if up_idx != -1 and user_idx != -1:
            metrics["cpu"]["uptime"] = uptime_out[up_idx+3:user_idx].strip()
    except Exception:
        pass

    global _mac_network_previous
    try:
        output = subprocess.check_output(['netstat', '-ibn'], stderr=subprocess.DEVNULL, timeout=2).decode('utf-8')
        counters, now = mac_network_counters(output), time.monotonic()
        if _mac_network_previous is not None:
            previous, then = _mac_network_previous
            elapsed = now - then
            received = sent = 0.0
            if elapsed > 0:
                for name, (rx, tx) in counters.items():
                    if name in previous:
                        received += max(0, rx - previous[name][0]) / elapsed
                        sent += max(0, tx - previous[name][1]) / elapsed
                metrics['network'] = {'downloadSpeed': received, 'uploadSpeed': sent,
                                      'downloadString': format_bytes(received), 'uploadString': format_bytes(sent)}
        _mac_network_previous = counters, now
    except (OSError, subprocess.SubprocessError):
        pass

    return metrics

def cpu_defaults():
    return {'temperature': 0.0, 'utilization': 0.0, 'systemUsage': 0.0,
            'userUsage': 0.0, 'idleUsage': 0.0, 'efficiencyCoreUsage': 0.0,
            'performanceCoreUsage': 0.0, 'uptime': '', 'freqAllCores': 0,
            'freqEfficiency': 0, 'freqPerformance': 0, 'history': [],
            'topProcesses': [], 'loadAverage1m': 0.0, 'loadAverage5m': 0.0,
            'loadAverage15m': 0.0, 'coreCount': 0, 'loadPerCore': 0.0,
            'perCoreUsage': []}


def logical_cpu_ids():
    count = os.cpu_count() or 1
    try:
        affinity = sorted(os.sched_getaffinity(0))
        if affinity:
            return affinity
    except (AttributeError, OSError):
        pass
    return list(range(count))


def cpu_delta(before, after):
    if before is None or after is None:
        return None
    delta = [b - a for a, b in zip(before, after)]
    # iowait can decrease on Linux. Other decreases imply a reset/hotplug.
    if any(value < 0 for i, value in enumerate(delta) if i != 4):
        return None
    return [max(0, value) for value in delta]


def cpu_percent(before, after, previous):
    delta = cpu_delta(before, after)
    if delta is None:
        return previous.copy()
    total = sum(delta)
    if total <= 0:
        return previous.copy()
    user = (delta[0] + delta[1]) * 100.0 / total
    system = (delta[2] + delta[5] + delta[6]) * 100.0 / total
    idle = (delta[3] + delta[4]) * 100.0 / total
    return {'utilization': user + system, 'userUsage': user,
            'systemUsage': system, 'idleUsage': idle}


class LinuxSampler:
    """CPU, process and physical-NIC rates share one monotonic sample window."""
    def __init__(self, proc_root='/proc', sys_root='/sys', cpu_ids=None,
                 clock=time.monotonic, sleep=time.sleep):
        self.proc = Path(proc_root)
        self.sys = Path(sys_root)
        self.cpu_ids = logical_cpu_ids() if cpu_ids is None else cpu_ids
        self.clock, self.sleep = clock, sleep
        self.ticks = os.sysconf('SC_CLK_TCK')
        self.previous = None
        self.cpu = {'utilization': 0.0, 'userUsage': 0.0, 'systemUsage': 0.0, 'idleUsage': 0.0}
        self.per_core = [self.cpu.copy() for _ in self.cpu_ids]

    def process_stat(self, pid):
        text = (self.proc / str(pid) / 'stat').read_text()
        # comm may contain spaces and ')'; remaining fields start at field 3.
        fields = text[text.rfind(')') + 2:].split()
        return int(fields[1]), int(fields[11]) + int(fields[12]), int(fields[19])

    def snapshot(self):
        cpus, processes, network = {}, {}, {}
        try:
            for line in (self.proc / 'stat').read_text().splitlines():
                parts = line.split()
                if parts and parts[0].startswith('cpu'):
                    values = [int(v) for v in parts[1:9]]
                    cpus[parts[0]] = tuple((values + [0] * 8)[:8])
        except (OSError, ValueError):
            pass
        try:
            for entry in self.proc.iterdir():
                if not entry.name.isdigit():
                    continue
                try:
                    processes[int(entry.name)] = self.process_stat(entry.name)
                except (OSError, ValueError, IndexError):
                    continue
        except OSError:
            pass
        try:
            for line in (self.proc / 'net/dev').read_text().splitlines()[2:]:
                interface, counters = line.split(':', 1)
                interface = interface.strip()
                if interface == 'lo' or interface.startswith(('veth', 'br-', 'docker', 'virbr')):
                    continue
                path = self.sys / 'class/net' / interface
                if not (path / 'device').exists():
                    continue
                try:
                    if (path / 'operstate').read_text().strip() == 'down':
                        continue
                except OSError:
                    pass
                fields = counters.split()
                network[interface] = (int(fields[0]), int(fields[8]))
        except (OSError, ValueError, IndexError):
            pass
        return {'time': self.clock(), 'cpus': cpus, 'processes': processes, 'network': network}

    def process_name(self, pid):
        path = self.proc / str(pid)
        try:
            args = [v.decode('utf-8', 'replace') for v in (path / 'cmdline').read_bytes().split(b'\0') if v]
            if args:
                name = os.path.basename(args[0])
                if re.fullmatch(r'python[\d.]*|node|nodejs|MainThread', name):
                    for i, arg in enumerate(args[1:], 1):
                        if arg == '-m' and i + 1 < len(args):
                            return name + ' ' + args[i + 1]
                        if arg in ('-c', '-e', '--eval'):
                            return name + ' ' + arg  # never expose inline code / credentials
                        if arg in ('-W', '-X'):
                            continue
                        if i > 1 and args[i - 1] in ('-W', '-X'):
                            continue
                        if not arg.startswith('-'):
                            return name + ' ' + os.path.basename(arg)
                return name
        except OSError:
            pass
        try:
            return (path / 'comm').read_text().strip()
        except OSError:
            return str(pid)

    def sample(self):
        if self.previous is None:
            self.previous = self.snapshot()
            self.sleep(0.5)
        current = self.snapshot()
        previous = self.previous
        elapsed = current['time'] - previous['time']
        # Sum usable per-core deltas, not percentages or cumulative counters.
        # This weights each logical CPU by its elapsed ticks and prevents a
        # reset on one CPU being hidden by growth on another. Guest counters
        # are already included in user/nice, so snapshot reads only fields 1–8.
        aggregate = [0] * 8
        for i, core in enumerate(self.cpu_ids):
            key = 'cpu' + str(core)
            before, after = previous['cpus'].get(key), current['cpus'].get(key)
            delta = cpu_delta(before, after)
            if delta is not None:
                aggregate = [a + b for a, b in zip(aggregate, delta)]
            self.per_core[i] = cpu_percent(before, after, self.per_core[i])
        self.cpu = cpu_percent((0,) * 8, aggregate, self.cpu)
        excluded = {os.getpid()}
        # Include descendants present in either sample, including just-exited parents.
        family = dict(previous['processes'])
        family.update(current['processes'])
        while True:
            children = {pid for pid, stat in family.items() if stat[0] in excluded}
            if children <= excluded:
                break
            excluded.update(children)
        top = []
        if elapsed > 0:
            for pid, stat in current['processes'].items():
                old = previous['processes'].get(pid)
                if pid in excluded or old is None or old[2] != stat[2] or stat[1] <= old[1]:
                    continue
                top.append((100.0 * (stat[1] - old[1]) / (self.ticks * elapsed), pid, stat[2]))
        processes = []
        for usage, pid, start in sorted(top, reverse=True):
            try:
                name = self.process_name(pid)
                if self.process_stat(pid)[2] != start:
                    continue
            except (OSError, ValueError, IndexError):
                continue
            processes.append({'id': str(pid) + ':' + str(start), 'name': name, 'usage': usage})
            if len(processes) == 5:
                break
        received = sent = 0.0
        if elapsed > 0:
            for interface, counters in current['network'].items():
                old = previous['network'].get(interface)
                if old is not None:
                    received += max(0, counters[0] - old[0]) / elapsed
                    sent += max(0, counters[1] - old[1]) / elapsed
        self.previous = current
        cpu = dict(self.cpu, coreCount=len(self.cpu_ids),
                   perCoreUsage=[core['utilization'] for core in self.per_core], topProcesses=processes)
        network = {'downloadSpeed': received, 'uploadSpeed': sent,
                   'downloadString': format_bytes(received), 'uploadString': format_bytes(sent)}
        return cpu, network


def linux_temperature(sys_root='/sys'):
    root = Path(sys_root)
    values = []
    def read_temp(path):
        try:
            value = float(path.read_text().strip()) / 1000.0
            return value if math.isfinite(value) and 0 < value < 150 else None
        except (OSError, ValueError):
            return None
    for zone in root.glob('class/thermal/thermal_zone*'):
        try:
            if (zone / 'type').read_text().strip() != 'x86_pkg_temp':
                continue
            value = read_temp(zone / 'temp')
            if value is not None:
                values.append(value)
        except OSError:
            continue
    for monitor in root.glob('class/hwmon/hwmon*'):
        try:
            if (monitor / 'name').read_text().strip() not in ('coretemp', 'k10temp'):
                continue
            for sensor in monitor.glob('temp*_input'):
                value = read_temp(sensor)
                if value is not None:
                    values.append(value)
        except OSError:
            continue
    return max(values) if values else 0.0


def linux_memory_processes(proc_root='/proc', limit=10):
    sampler = LinuxSampler(proc_root=proc_root, cpu_ids=[])
    ranked = []
    try:
        for entry in sampler.proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                pid = int(entry.name)
                start = sampler.process_stat(pid)[2]
                for line in (entry / 'status').read_text().splitlines():
                    if line.startswith('VmRSS:'):
                        rss = int(line.split()[1]) * 1024
                        if rss > 0:
                            ranked.append((rss, pid, start))
                        break
            except (OSError, ValueError, IndexError):
                continue
    except OSError:
        pass
    processes = []
    for rss, pid, start in sorted(ranked, key=lambda p: (-p[0], p[1])):
        try:
            name = sampler.process_name(pid)
            if sampler.process_stat(pid)[2] != start:
                continue  # Exited/reused PID; never attach another process's name.
        except (OSError, ValueError, IndexError):
            continue
        processes.append({'id': f'{pid}:{start}', 'pid': pid, 'name': name, 'rssBytes': rss})
        if len(processes) == limit:
            break
    return processes


def linux_memory(proc_root='/proc'):
    memory = dict.fromkeys(('usagePercent', 'total', 'used', 'app', 'wired',
                            'compressed', 'free', 'swap', 'available', 'cache'), 0.0)
    memory['topProcesses'] = linux_memory_processes(proc_root)
    try:
        info = {line.split(':')[0]: int(line.split()[1])
                for line in (Path(proc_root) / 'meminfo').read_text().splitlines()}
        total = info.get('MemTotal', 0)
        available = info.get('MemAvailable', info.get('MemFree', 0))
        if total > 0:
            memory.update(total=total / 1024**2, used=(total - available) / 1024**2,
                          usagePercent=(total - available) * 100.0 / total,
                          free=info.get('MemFree', 0) / 1024**2, available=available / 1024**2,
                          app=info.get('AnonPages', 0) / 1024**2,
                          cache=(info.get('Cached', 0) + info.get('Buffers', 0)) / 1024**2,
                          swap=(info.get('SwapTotal', 0) - info.get('SwapFree', 0)) / 1024**2)
    except (OSError, ValueError, IndexError):
        pass
    return memory


_linux_sampler = None


def get_linux_metrics():
    global _linux_sampler
    if _linux_sampler is None:
        _linux_sampler = LinuxSampler()
    cpu, network = _linux_sampler.sample()
    metrics = {'cpu': dict(cpu_defaults(), **cpu), 'memory': linux_memory(),
               'disk': get_unix_disks(), 'network': network,
               'gpu': {'usagePercent': 0.0, 'modelName': '', 'cores': 0,
                       'temperature': 0.0, 'memoryUsed': 0.0, 'memoryTotal': 0.0,
                       'utilizationAvailable': False}}
    try:
        load1, load5, load15 = os.getloadavg()
        metrics['cpu'].update(loadAverage1m=load1, loadAverage5m=load5, loadAverage15m=load15,
                              loadPerCore=load1 / cpu['coreCount'] if cpu['coreCount'] else 0.0)
    except OSError:
        pass
    metrics['cpu']['temperature'] = linux_temperature()
    try:
        seconds = float(Path('/proc/uptime').read_text().split()[0])
        metrics['cpu']['uptime'] = f'{int(seconds // 86400)} days, {int(seconds % 86400 // 3600)} hours'
    except (OSError, ValueError, IndexError):
        pass
    try:
        output = subprocess.check_output([
            'nvidia-smi', '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,name',
            '--format=csv,noheader,nounits'], stderr=subprocess.DEVNULL, timeout=1).decode('utf-8')
        parts = output.splitlines()[0].split(',', 4)
        metrics['gpu'].update(usagePercent=float(parts[0]), temperature=float(parts[1]),
                              memoryUsed=float(parts[2]), memoryTotal=float(parts[3]), modelName=parts[4].strip(),
                              utilizationAvailable=True)
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        pass
    return metrics


def main():
    # If run with --loop, print metrics every 2 seconds
    loop = len(sys.argv) > 1 and sys.argv[1] == "--loop"
    
    while True:
        if sys.platform == "darwin":
            data = get_mac_metrics()
        elif sys.platform == "win32":
            # For Windows, we might need a separate function, but for now we'll just mock CPU/RAM
            data = {
                "cpu": cpu_defaults(),
                "memory": {"usagePercent": 0.0},
                "gpu": {"usagePercent": 0.0, "modelName": "", "cores": 0, "temperature": 0.0, "memoryUsed": 0.0, "memoryTotal": 0.0},
                "disk": get_windows_disks()
            }
        else:
            data = get_linux_metrics()
            
        print(json.dumps(data), flush=True)
        
        if not loop:
            break
        time.sleep(2)

if __name__ == "__main__":
    main()
