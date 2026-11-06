#!/usr/bin/env python3
from __future__ import annotations
import os
import sys
import json
import sqlite3
import subprocess
import time
import math
import plistlib
import re
import shutil
import platform
from pathlib import Path

METRICS_VERSION = "2.5.0"

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


def mac_physical_disks(groups, disk_temperature_c=None):
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
        temp = disk_temperature_c if (disk_id == 'disk0' or not result) else None
        result.append({'id': disk_id, 'model': info.get('MediaName') or info.get('DeviceModel') or disk_id,
                       'totalGB': size / 1024**3,
                       'availableGB': sum(available) if available and not shared else None,
                       'temperature': temp, 'volumes': []})
    return result


def get_unix_disks(sys_root='/sys', proc_root='/proc', disk_temperature_c=None):
    metrics = {'usagePercent': 0.0, 'totalGB': 0.0, 'usedGB': 0.0, 'disks': [],
               'platform': sys.platform}
    is_mac = sys.platform == 'darwin'
    mount_types = {} if is_mac else linux_mount_types(proc_root)
    virtual_types = {'proc', 'sysfs', 'tmpfs', 'devtmpfs', 'devpts', 'ramfs',
                     'cgroup', 'cgroup2', 'securityfs', 'pstore', 'debugfs',
                     'tracefs', 'configfs', 'hugetlbfs', 'mqueue', 'fusectl',
                     'bpf', 'autofs', 'overlay', 'nsfs', 'efivarfs'}
    disk_temps = {} if is_mac else linux_disk_temperatures(sys_root)
    if is_mac and disk_temperature_c is not None:
        disk_temps = {'disk0': disk_temperature_c}
    # Separate physical sensors from filesystem/LVM grouping. A disk can back
    # several volumes or no mounted volume and must appear here only once.
    metrics['temperatures'] = [
        {'id': device, 'model': 'Apple NVMe SSD' if is_mac else linux_disk_model(device, sys_root), 'temperature': value}
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
        metrics['physicalDisks'] = (mac_physical_disks([], disk_temperature_c) if is_mac
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
            parent_temp = disk_temperature_c if is_mac else disk_temperature(disk_id, disk_temps, sys_root)
            disk = disks.setdefault(disk_id, {'id': disk_id, 'model': model, 'volumes': [],
                                              'temperature': parent_temp})
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
    metrics['physicalDisks'] = (mac_physical_disks(metrics['disks'], disk_temperature_c) if is_mac
                                else linux_physical_disks(metrics['disks'], disk_temps, sys_root))
    if not is_mac:
        metrics['totalGB'] = sum(v['totalGB'] for d in metrics['disks'] for v in d['volumes'])
        metrics['usedGB'] = sum(v['usedGB'] for d in metrics['disks'] for v in d['volumes'])
        usable = total_used + total_available
        metrics['usagePercent'] = total_used / usable * 100.0 if usable > 0 else 0.0
    return metrics


def mac_temperatures():
    """Read Apple Silicon (and Intel fallback) CPU, GPU, and Disk temperatures.
    Uses native IOKit IOHIDEventSystemClient via ctypes - no root or unbundled packages needed.
    """
    temps = {'cpu': None, 'gpu': None, 'disk': None}
    if sys.platform != 'darwin':
        return temps
    try:
        import ctypes
        iokit = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit')
        cf = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

        cf.CFArrayGetCount.restype = ctypes.c_long
        cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]

        cf.CFStringGetCString.restype = ctypes.c_bool
        cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFRelease.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]

        iokit.IOHIDEventSystemClientCreate.restype = ctypes.c_void_p
        iokit.IOHIDEventSystemClientCreate.argtypes = [ctypes.c_void_p]
        iokit.IOHIDEventSystemClientCopyServices.restype = ctypes.c_void_p
        iokit.IOHIDEventSystemClientCopyServices.argtypes = [ctypes.c_void_p]

        iokit.IOHIDServiceClientCopyProperty.restype = ctypes.c_void_p
        iokit.IOHIDServiceClientCopyProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

        iokit.IOHIDServiceClientCopyEvent.restype = ctypes.c_void_p
        iokit.IOHIDServiceClientCopyEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]

        iokit.IOHIDEventGetFloatValue.restype = ctypes.c_double
        iokit.IOHIDEventGetFloatValue.argtypes = [ctypes.c_void_p, ctypes.c_uint32]

        kCFStringEncodingUTF8 = 0x08000100
        client = iokit.IOHIDEventSystemClientCreate(None)
        if client:
            services = iokit.IOHIDEventSystemClientCopyServices(client)
            count = cf.CFArrayGetCount(services) if services else 0
            prop_product = cf.CFStringCreateWithCString(None, b"Product", kCFStringEncodingUTF8)

            cpu_vals = []
            gpu_vals = []
            disk_vals = []

            buf = ctypes.create_string_buffer(128)
            for i in range(count):
                srv = cf.CFArrayGetValueAtIndex(services, i)
                name_ref = iokit.IOHIDServiceClientCopyProperty(srv, prop_product)
                if not name_ref:
                    continue
                name = ""
                if cf.CFStringGetCString(name_ref, buf, 128, kCFStringEncodingUTF8):
                    name = buf.value.decode('utf-8', errors='ignore')
                cf.CFRelease(name_ref)

                event = iokit.IOHIDServiceClientCopyEvent(srv, 15, 0, 0)
                if event:
                    val = iokit.IOHIDEventGetFloatValue(event, 15 << 16)
                    cf.CFRelease(event)
                    if 0 < val < 150:
                        if "PMU tdie" in name or "PMU tcal" in name:
                            cpu_vals.append(val)
                        elif "PMU2 tdie" in name or "PMU2 tcal" in name:
                            gpu_vals.append(val)
                        elif "NAND" in name:
                            disk_vals.append(val)

            if prop_product:
                cf.CFRelease(prop_product)
            if services:
                cf.CFRelease(services)
            cf.CFRelease(client)

            if cpu_vals:
                temps['cpu'] = round(sum(cpu_vals) / len(cpu_vals), 1)
            if gpu_vals:
                temps['gpu'] = round(sum(gpu_vals) / len(gpu_vals), 1)
            if disk_vals:
                temps['disk'] = round(sum(disk_vals) / len(disk_vals), 1)
    except Exception:
        pass

    # Intel Mac fallback for CPU via powermetrics if IOHID didn't find PMU
    if temps['cpu'] is None:
        try:
            pm_out = subprocess.check_output(
                ['sudo', '-n', 'powermetrics', '--samplers', 'smc', '-n', '1', '-i', '100'],
                stderr=subprocess.DEVNULL, timeout=1
            ).decode('utf-8', errors='ignore')
            for line in pm_out.splitlines():
                if 'CPU die temperature' in line or 'CPU thermal level' in line:
                    parts = line.split(':')
                    if len(parts) > 1:
                        val = parts[1].strip().split(' ')[0]
                        temps['cpu'] = float(val)
                        break
        except Exception:
            pass

    return temps


_mac_gpu_identity = None


def get_mac_gpu(temperature_c=None):
    global _mac_gpu_identity
    gpu = {'usagePercent': 0.0, 'modelName': '', 'cores': 0,
           'temperature': float(temperature_c) if temperature_c is not None else 0.0,
           'memoryUsed': 0.0, 'memoryTotal': 0.0,
           'utilizationAvailable': False, 'powerWatts': None}
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
    temps = mac_temperatures()
    metrics = {
        "cpu": {
            "temperature": temps.get('cpu') or 0.0,
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
        "disk": get_unix_disks(disk_temperature_c=temps.get('disk')),
        "gpu": get_mac_gpu(temperature_c=temps.get('gpu')),
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
    except Exception:
        pass

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

    global _power_sampler
    if _power_sampler is None:
        _power_sampler = PowerSampler()
    metrics['power'] = _power_sampler.sample(time.monotonic(), metrics.get('cpu'), metrics.get('gpu'))

    return metrics

def cpu_defaults():
    return {'temperature': 0.0, 'utilization': 0.0, 'systemUsage': 0.0,
            'userUsage': 0.0, 'idleUsage': 0.0, 'efficiencyCoreUsage': 0.0,
            'performanceCoreUsage': 0.0, 'uptime': '', 'freqAllCores': 0,
            'freqEfficiency': 0, 'freqPerformance': 0, 'history': [],
            'topProcesses': [], 'loadAverage1m': 0.0, 'loadAverage5m': 0.0,
            'loadAverage15m': 0.0, 'coreCount': 0, 'loadPerCore': 0.0,
            'perCoreUsage': [], 'powerWatts': None}


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
    primary_values = []
    fallback_values = []
    def read_temp(path):
        try:
            value = float(path.read_text().strip()) / 1000.0
            return value if math.isfinite(value) and 0 < value < 150 else None
        except (OSError, ValueError):
            return None

    primary_zone_types = {'x86_pkg_temp', 'cpu-thermal', 'cpu_thermal', 'soc-thermal', 'soc_thermal', 'cpu_temp'}
    primary_hwmon_names = {'coretemp', 'k10temp', 'zenpower', 'cpu_thermal', 'soc_thermal'}

    for zone in root.glob('class/thermal/thermal_zone*'):
        try:
            z_type = (zone / 'type').read_text().strip().lower()
            val = read_temp(zone / 'temp')
            if val is not None:
                if z_type in primary_zone_types:
                    primary_values.append(val)
                elif z_type == 'acpitz':
                    fallback_values.append(val)
        except OSError:
            continue

    for monitor in root.glob('class/hwmon/hwmon*'):
        try:
            m_name = (monitor / 'name').read_text().strip().lower()
            for sensor in monitor.glob('temp*_input'):
                val = read_temp(sensor)
                if val is not None:
                    if m_name in primary_hwmon_names:
                        primary_values.append(val)
                    elif m_name == 'acpitz':
                        fallback_values.append(val)
        except OSError:
            continue

    if primary_values:
        return max(primary_values)
    if fallback_values:
        return max(fallback_values)
    return 0.0


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


def get_linux_gpu():
    gpu = {'usagePercent': 0.0, 'modelName': '', 'cores': 0,
           'temperature': 0.0, 'memoryUsed': 0.0, 'memoryTotal': 0.0,
           'utilizationAvailable': False, 'powerWatts': None}
    try:
        output = subprocess.check_output([
            'nvidia-smi', '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,name',
            '--format=csv,noheader,nounits'], stderr=subprocess.DEVNULL, timeout=1).decode('utf-8')
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        if not lines:
            return gpu
        parts = [p.strip() for p in lines[0].split(',', 4)]
        if len(parts) < 5:
            return gpu

        def safe_float(v, default=0.0):
            if v in ('[N/A]', 'N/A', '[Not Supported]', 'Not Supported', ''):
                return default
            try:
                return float(v)
            except ValueError:
                return default

        util_str = parts[0]
        temp_str = parts[1]
        mem_used_str = parts[2]
        mem_total_str = parts[3]
        model_name = parts[4]

        gpu['modelName'] = model_name
        if util_str not in ('[N/A]', 'N/A', '[Not Supported]', 'Not Supported', ''):
            gpu['usagePercent'] = safe_float(util_str)
            gpu['utilizationAvailable'] = True

        gpu['temperature'] = safe_float(temp_str)
        gpu['memoryUsed'] = safe_float(mem_used_str)
        gpu['memoryTotal'] = safe_float(mem_total_str)

        # On unified memory systems (e.g. Grace Blackwell GB10), memory.used is [N/A].
        # Sum allocated compute memory from running processes if memoryUsed is 0.
        if gpu['memoryUsed'] == 0.0:
            try:
                app_out = subprocess.check_output([
                    'nvidia-smi', '--query-compute-apps=used_gpu_memory',
                    '--format=csv,noheader,nounits'], stderr=subprocess.DEVNULL, timeout=1).decode('utf-8')
                total_app_mem = sum(safe_float(line.strip()) for line in app_out.splitlines() if line.strip())
                if total_app_mem > 0:
                    gpu['memoryUsed'] = total_app_mem
            except (OSError, subprocess.SubprocessError):
                pass
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        pass
    return gpu


def rapl_energy_delta(current_uj, prev_uj, max_range_uj=None):
    """Calculates RAPL energy delta in microjoules, handling counter rollover."""
    if current_uj is None or prev_uj is None:
        return None
    if current_uj >= prev_uj:
        return current_uj - prev_uj
    if max_range_uj is not None and max_range_uj > prev_uj:
        return (max_range_uj - prev_uj) + current_uj
    return None


def read_linux_rapl_energy(sys_root='/sys'):
    """Reads RAPL energy_uj and max_energy_range_uj from sysfs (or sudo fallback)."""
    rapl_dir = Path(sys_root) / 'class/powercap/intel-rapl:0'
    energy_path = rapl_dir / 'energy_uj'
    range_path = rapl_dir / 'max_energy_range_uj'

    energy_uj = None
    try:
        energy_uj = int(energy_path.read_text().strip())
    except (OSError, ValueError):
        try:
            out = subprocess.check_output(
                ['sudo', '-n', 'cat', str(energy_path)],
                stderr=subprocess.DEVNULL, timeout=1
            ).decode('utf-8').strip()
            energy_uj = int(out)
        except (subprocess.SubprocessError, OSError, ValueError):
            return None

    max_range_uj = None
    try:
        max_range_uj = int(range_path.read_text().strip())
    except (OSError, ValueError):
        try:
            out = subprocess.check_output(
                ['sudo', '-n', 'cat', str(range_path)],
                stderr=subprocess.DEVNULL, timeout=1
            ).decode('utf-8').strip()
            max_range_uj = int(out)
        except (subprocess.SubprocessError, OSError, ValueError):
            max_range_uj = None

    return (energy_uj, max_range_uj)


def read_linux_battery_power(sys_root='/sys'):
    """Reads total battery discharge power in Watts from /sys/class/power_supply."""
    ps_root = Path(sys_root) / 'class/power_supply'
    if not ps_root.exists():
        return None

    total_watts = 0.0
    found = False
    try:
        for entry in sorted(ps_root.iterdir()):
            b_type = ""
            type_file = entry / 'type'
            if type_file.exists():
                try:
                    b_type = type_file.read_text().strip().lower()
                except OSError:
                    pass
            if 'battery' not in b_type and not entry.name.startswith('BAT'):
                continue

            status = ""
            status_file = entry / 'status'
            if status_file.exists():
                try:
                    status = status_file.read_text().strip().lower()
                except OSError:
                    pass
            if status and status != 'discharging':
                continue

            # 1. Try power_now (in microWatts)
            power_file = entry / 'power_now'
            if power_file.exists():
                try:
                    p_val = float(power_file.read_text().strip())
                    if p_val > 0:
                        total_watts += p_val / 1_000_000.0
                        found = True
                        continue
                except (OSError, ValueError):
                    pass

            # 2. Try current_now * voltage_now (in microAmps * microVolts -> Watts)
            curr_file = entry / 'current_now'
            volt_file = entry / 'voltage_now'
            if curr_file.exists() and volt_file.exists():
                try:
                    c_val = float(curr_file.read_text().strip())
                    v_val = float(volt_file.read_text().strip())
                    w_val = (c_val * v_val) / 1_000_000_000_000.0
                    if w_val > 0:
                        total_watts += w_val
                        found = True
                except (OSError, ValueError):
                    pass
    except OSError:
        pass

    return round(total_watts, 2) if found else None


def get_gpu_power(sys_root='/sys'):
    """Queries GPU power draw in Watts via nvidia-smi or AMD hwmon fallback."""
    # 1. NVIDIA NVML via nvidia-smi
    try:
        out = subprocess.check_output(
            ['nvidia-smi', '--query-gpu=power.draw', '--format=csv,nounits,noheader'],
            stderr=subprocess.DEVNULL, timeout=1
        ).decode('utf-8')
        total_watts = 0.0
        found = False
        for line in out.splitlines():
            line = line.strip()
            if not line or line in ('[N/A]', 'N/A', '[Not Supported]', 'Not Supported'):
                continue
            try:
                total_watts += float(line)
                found = True
            except ValueError:
                pass
        if found:
            return round(total_watts, 2)
    except (subprocess.SubprocessError, OSError, ValueError):
        pass

    # 2. AMD hwmon fallback
    try:
        root = Path(sys_root)
        amd_watts = 0.0
        found_amd = False
        for hwmon in sorted(root.glob('class/drm/card*/device/hwmon/hwmon*')):
            for p_file in ('power1_average', 'power1_input'):
                p_path = hwmon / p_file
                if p_path.exists():
                    try:
                        val = float(p_path.read_text().strip())
                        amd_watts += val / 1_000_000.0
                        found_amd = True
                        break
                    except (OSError, ValueError):
                        continue
        if found_amd:
            return round(amd_watts, 2)
    except OSError:
        pass

    return None


def parse_macos_powermetrics(text):
    """Parses powermetrics cpu_power sampler text output into Watts."""
    res = {'cpuWatts': None, 'gpuWatts': None, 'combinedWatts': None}
    m_cpu = re.search(r'CPU Power:\s*([0-9.]+)\s*mW', text)
    if m_cpu:
        res['cpuWatts'] = round(float(m_cpu.group(1)) / 1000.0, 2)
    m_gpu = re.search(r'GPU Power:\s*([0-9.]+)\s*mW', text)
    if m_gpu:
        res['gpuWatts'] = round(float(m_gpu.group(1)) / 1000.0, 2)
    m_combined = re.search(r'Combined Power.*?:\s*([0-9.]+)\s*mW', text)
    if m_combined:
        res['combinedWatts'] = round(float(m_combined.group(1)) / 1000.0, 2)
    return res


def read_macos_powermetrics():
    """Reads Apple Silicon CPU/GPU/Combined power using powermetrics."""
    try:
        out = subprocess.check_output(
            ['sudo', '-n', 'powermetrics', '-n', '1', '-i', '100', '--samplers', 'cpu_power'],
            stderr=subprocess.DEVNULL, timeout=2
        ).decode('utf-8', 'replace')
        return parse_macos_powermetrics(out)
    except (subprocess.SubprocessError, OSError):
        return {'cpuWatts': None, 'gpuWatts': None, 'combinedWatts': None}


STANDARD_PSU_TIERS = [150, 250, 350, 450, 500, 550, 600, 650, 700, 750, 850, 1000, 1200, 1300, 1500, 1600, 2000]


def calculate_recommended_psu(cpu_tdp: float | None, gpu_tdp: float | None) -> float | None:
    """Calculates recommended PSU wattage ceiling from CPU and GPU TDP.

    Formula: Recommended PSU = (CPU TDP + GPU TDP + 80W) * 1.4 rounded up to
    the smallest standard PSU tier >= raw, or next 100W above 2000W.
    """
    if cpu_tdp is None and gpu_tdp is None:
        return None
    raw = round(((cpu_tdp or 0.0) + (gpu_tdp or 0.0) + 80.0) * 1.4, 2)
    for tier in STANDARD_PSU_TIERS:
        if tier >= raw:
            return float(tier)
    return float(math.ceil(raw / 100.0) * 100.0)


def match_cpu_tdp_model(model_name: str, arch: str | None = None) -> float | None:
    """Table lookup and substring matching for CPU TDP estimates in Watts."""
    if not model_name:
        return None
    name = model_name.upper()

    # Apple Silicon
    if "APPLE" in name:
        if "ULTRA" in name:
            return 120.0
        if "MAX" in name:
            return 75.0
        if "PRO" in name:
            return 45.0
        return 30.0

    # AMD Ryzen specific models
    if "9950X" in name:
        return 170.0
    if "7950X" in name or "7900X" in name:
        return 170.0
    if "9900X" in name:
        return 120.0
    if "7800X3D" in name or "9800X3D" in name:
        return 120.0
    if any(m in name for m in ("7700X", "5800X", "5900X", "5950X")):
        return 105.0

    # Intel Core specific models
    if any(m in name for m in (
        "14900", "13900", "12900",
        "14700", "13700", "12700",
        "14600", "13600", "12600"
    )):
        return 125.0

    # Architecture fallbacks
    machine = (arch or platform.machine()).lower()
    if any(arm in machine or arm in name.lower() for arm in ("arm", "aarch64", "cortex")):
        return 30.0
    if any(x86 in machine or x86 in name.lower() for x86 in ("x86_64", "amd64", "i386", "x86", "intel", "amd")):
        return 65.0

    return 65.0


def get_cpu_tdp(sys_root="/sys", proc_root=None) -> float | None:
    """Estimates CPU TDP in Watts from RAPL powercap constraints or CPU model heuristics."""
    # 1. RAPL constraint_0_power_limit_uw (PL1 in microwatts)
    try:
        powercap_dir = Path(sys_root) / 'class/powercap'
        if powercap_dir.exists():
            candidates = sorted(
                powercap_dir.glob('intel-rapl*/constraint_0_power_limit_uw'),
                key=lambda p: (len(str(p)), str(p))
            )
            for cap_path in candidates:
                try:
                    val = float(cap_path.read_text().strip())
                except (OSError, ValueError):
                    try:
                        out = subprocess.check_output(
                            ['sudo', '-n', 'cat', str(cap_path)],
                            stderr=subprocess.DEVNULL, timeout=1
                        ).decode('utf-8').strip()
                        val = float(out)
                    except Exception:
                        continue
                if 0 < val < 1_000_000_000:
                    return round(val / 1_000_000.0, 2)
    except Exception:
        pass

    # 2. macOS CPU model brand string lookup
    if sys.platform == "darwin":
        try:
            brand = subprocess.check_output(
                ['sysctl', '-n', 'machdep.cpu.brand_string'],
                stderr=subprocess.DEVNULL, timeout=1
            ).decode('utf-8').strip()
            if brand:
                matched = match_cpu_tdp_model(brand)
                if matched is not None:
                    return matched
        except (subprocess.SubprocessError, OSError):
            pass

    # 3. Linux /proc/cpuinfo lookup
    if proc_root is None:
        if sys_root != '/sys':
            proc_candidate = Path(sys_root).parent / 'proc'
            if proc_candidate.exists():
                proc_root = str(proc_candidate)
        if proc_root is None and sys_root == '/sys':
            proc_root = '/proc'

    if proc_root is not None:
        cpuinfo_file = Path(proc_root) / 'cpuinfo'
        if cpuinfo_file.exists():
            try:
                text = cpuinfo_file.read_text()
                model_name = None
                is_arm = False
                core_count = 0
                for line in text.splitlines():
                    if ':' in line:
                        k, v = line.split(':', 1)
                        k = k.strip().lower()
                        if k == 'processor':
                            core_count += 1
                        if k in ('model name', 'model', 'hardware', 'cpu model'):
                            v = v.strip()
                            if v and not v.isdigit():
                                model_name = v
                        if k in ('cpu implementer', 'cpu architecture', 'cpu part'):
                            is_arm = True
                if model_name:
                    matched = match_cpu_tdp_model(model_name)
                    if matched is not None:
                        return matched
                if is_arm:
                    return 65.0 if core_count >= 16 else 30.0
            except OSError:
                pass

    machine = platform.machine().lower()
    if any(arm in machine for arm in ("arm", "aarch64")):
        return 45.0

    return None


GPU_TDP_MODELS = [
    ("5090", 600.0),
    ("5080", 400.0),
    ("5070 TI", 300.0),
    ("5070TI", 300.0),
    ("5070", 250.0),
    ("4090", 450.0),
    ("4080", 320.0),
    ("4070 TI", 285.0),
    ("4070TI", 285.0),
    ("4070", 200.0),
    ("4060", 115.0),
    ("3090", 350.0),
    ("3080", 320.0),
    ("3070", 220.0),
    ("3060", 170.0),
    ("GB10", 70.0),
    ("GB200", 1000.0),
    ("GH200", 900.0),
    ("H100", 700.0),
    ("A100", 400.0),
]


def match_gpu_tdp_model(model_name: str) -> float | None:
    """Table lookup for GPU TDP fallback estimates in Watts."""
    if not model_name:
        return None
    name = model_name.upper()
    for needle, tdp in GPU_TDP_MODELS:
        if needle in name:
            return tdp
    return None


def get_gpu_tdp(sys_root="/sys", gpu_name=None) -> float | None:
    """Estimates GPU TDP in Watts via nvidia-smi power limits, DRM hwmon, or model heuristics."""
    # 1. NVIDIA NVML via nvidia-smi query power limits
    try:
        out = subprocess.check_output(
            ['nvidia-smi', '--query-gpu=power.limit,power.default_limit', '--format=csv,nounits,noheader'],
            stderr=subprocess.DEVNULL, timeout=1
        ).decode('utf-8')
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            for part in line.split(','):
                part = part.strip()
                if not part or part in ('[N/A]', 'N/A', '[Not Supported]', 'Not Supported'):
                    continue
                try:
                    val = float(part)
                    if val > 0 and math.isfinite(val):
                        return round(val, 2)
                except ValueError:
                    pass
    except (subprocess.SubprocessError, OSError, ValueError):
        pass

    # 2. DRM hwmon fallback: /sys/class/drm/card*/device/hwmon/hwmon*/power1_cap
    try:
        root = Path(sys_root)
        for cap_path in sorted(root.glob('class/drm/card*/device/hwmon/hwmon*/power1_cap')):
            try:
                val = float(cap_path.read_text().strip())
            except (OSError, ValueError):
                try:
                    out = subprocess.check_output(
                        ['sudo', '-n', 'cat', str(cap_path)],
                        stderr=subprocess.DEVNULL, timeout=1
                    ).decode('utf-8').strip()
                    val = float(out)
                except Exception:
                    continue
            if val > 0 and math.isfinite(val):
                return round(val / 1_000_000.0, 2)
    except OSError:
        pass

    # 3. Model name fallback
    if gpu_name is not None:
        matched = match_gpu_tdp_model(gpu_name)
        if matched is not None:
            return matched

    try:
        out = subprocess.check_output(
            ['nvidia-smi', '--query-gpu=name', '--format=csv,noheader'],
            stderr=subprocess.DEVNULL, timeout=1
        ).decode('utf-8')
        for line in out.splitlines():
            line = line.strip()
            if line and line not in ('[N/A]', 'N/A', '[Not Supported]', 'Not Supported'):
                matched = match_gpu_tdp_model(line)
                if matched is not None:
                    return matched
    except (subprocess.SubprocessError, OSError):
        pass

    try:
        lspci_out = subprocess.check_output(
            ['lspci'], stderr=subprocess.DEVNULL, timeout=1
        ).decode('utf-8')
        for line in lspci_out.splitlines():
            if any(term in line.lower() for term in ('vga', '3d', 'display')):
                matched = match_gpu_tdp_model(line)
                if matched is not None:
                    return matched
    except (subprocess.SubprocessError, OSError):
        pass

    return None


class PowerSampler:
    """Multi-platform power telemetry sampler for Linux (RAPL/NVML/battery) and macOS (powermetrics)."""
    def __init__(self, sys_root='/sys', clock=time.monotonic, sleep=time.sleep):
        self.sys_root = sys_root
        self.clock = clock
        self.sleep = sleep
        self.prev_rapl = None  # (energy_uj, max_range_uj, timestamp)
        self.cpu_tdp = get_cpu_tdp(self.sys_root)
        self.gpu_tdp = get_gpu_tdp(self.sys_root)
        self.psu_ceiling = calculate_recommended_psu(self.cpu_tdp, self.gpu_tdp)

    def prime(self):
        """Optionally capture an initial RAPL baseline for single-shot invocations."""
        rapl = read_linux_rapl_energy(self.sys_root)
        if rapl is not None:
            self.prev_rapl = (rapl[0], rapl[1], self.clock())

    def sample(self, now=None, cpu_info=None, gpu_info=None):
        if now is None:
            now = self.clock()

        cpu_watts = None
        gpu_watts = None
        total_watts = None
        source = "none"

        if sys.platform == "darwin":
            pm = read_macos_powermetrics()
            cpu_watts = pm.get('cpuWatts')
            gpu_watts = pm.get('gpuWatts')
            total_watts = pm.get('combinedWatts')
            if total_watts is None and (cpu_watts is not None or gpu_watts is not None):
                total_watts = round((cpu_watts or 0.0) + (gpu_watts or 0.0), 2)
            if total_watts is not None or cpu_watts is not None or gpu_watts is not None:
                source = "powermetrics"
        elif sys.platform == "win32":
            gpu_watts = get_gpu_power(self.sys_root)
            if gpu_watts is not None:
                total_watts = gpu_watts
                source = "nvml"
        else:
            # Linux: check battery first
            battery_watts = read_linux_battery_power(self.sys_root)
            rapl = read_linux_rapl_energy(self.sys_root)
            if rapl is not None:
                curr_energy, max_range = rapl
                if self.prev_rapl is not None:
                    prev_energy, _, prev_time = self.prev_rapl
                    elapsed = now - prev_time
                    if elapsed > 0:
                        delta_uj = rapl_energy_delta(curr_energy, prev_energy, max_range)
                        if delta_uj is not None:
                            cpu_watts = round((delta_uj / 1_000_000.0) / elapsed, 2)
                self.prev_rapl = (curr_energy, max_range, now)

            gpu_watts = get_gpu_power(self.sys_root)

            if battery_watts is not None:
                total_watts = battery_watts
                source = "battery"
            else:
                if cpu_watts is not None and gpu_watts is not None:
                    total_watts = round(cpu_watts + gpu_watts, 2)
                    source = "rapl+nvml"
                elif cpu_watts is not None:
                    total_watts = cpu_watts
                    source = "rapl"
                elif gpu_watts is not None:
                    total_watts = gpu_watts
                    source = "nvml"
                else:
                    total_watts = None
                    source = "none"

                if cpu_watts is None:
                    if self.cpu_tdp is not None and isinstance(cpu_info, dict) and cpu_info.get('utilization') is not None:
                        try:
                            util = max(0.0, min(100.0, float(cpu_info['utilization'])))
                            est_cpu = round(max(3.0, (self.cpu_tdp * 0.10) + (self.cpu_tdp * 0.90) * (util / 100.0)), 2)
                            cpu_watts = est_cpu
                            if gpu_watts is not None:
                                total_watts = round(cpu_watts + gpu_watts, 2)
                                source = "nvml+est"
                            else:
                                total_watts = cpu_watts
                                source = "est"
                        except (ValueError, TypeError):
                            pass

        if isinstance(cpu_info, dict):
            cpu_info['powerWatts'] = cpu_watts
        if isinstance(gpu_info, dict):
            gpu_info['powerWatts'] = gpu_watts

        return {
            'totalWatts': total_watts,
            'cpuWatts': cpu_watts,
            'gpuWatts': gpu_watts,
            'source': source,
            'cpuTdpWatts': self.cpu_tdp,
            'gpuTdpWatts': self.gpu_tdp,
            'psuCeilingWatts': self.psu_ceiling
        }


_power_sampler = None


def get_linux_metrics(sampler=None, power_sampler=None):
    global _linux_sampler, _power_sampler
    active_sampler = sampler if sampler is not None else (_linux_sampler or LinuxSampler())
    if sampler is None and _linux_sampler is None:
        _linux_sampler = active_sampler

    active_power = power_sampler if power_sampler is not None else (_power_sampler or PowerSampler())
    if power_sampler is None and _power_sampler is None:
        _power_sampler = active_power

    if active_power.prev_rapl is None:
        active_power.prime()

    cpu, network = active_sampler.sample()
    metrics = {'cpu': dict(cpu_defaults(), **cpu), 'memory': linux_memory(),
               'disk': get_unix_disks(), 'network': network,
               'gpu': get_linux_gpu()}
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
    now = time.monotonic()
    metrics['power'] = active_power.sample(now, metrics['cpu'], metrics['gpu'])
    return metrics


def get_metrics():
    if sys.platform == "darwin":
        return get_mac_metrics()
    elif sys.platform == "win32":
        global _power_sampler
        if _power_sampler is None:
            _power_sampler = PowerSampler()
        cpu = cpu_defaults()
        gpu = {
            "usagePercent": 0.0, "modelName": "", "cores": 0,
            "temperature": 0.0, "memoryUsed": 0.0, "memoryTotal": 0.0,
            "utilizationAvailable": False, "powerWatts": None
        }
        now = time.monotonic()
        power = _power_sampler.sample(now, cpu, gpu)
        return {
            "cpu": cpu,
            "memory": {"usagePercent": 0.0},
            "gpu": gpu,
            "disk": get_windows_disks(),
            "power": power
        }
    else:
        return get_linux_metrics()


def default_metrics_db_path():
    """Returns the default SQLite metrics history database path for the current OS."""
    if sys.platform == "win32":
        local_app_data = os.environ.get("LOCALAPPDATA")
        base = Path(local_app_data) if local_app_data else Path.home() / "AppData" / "Local"
        return base / "msam" / "metrics-history.db"
    else:
        return Path.home() / ".local" / "state" / "msam" / "metrics-history.db"


class MetricsHistoryDB:
    """SQLite time-series storage with rolling 30-day retention for system metrics and power telemetry."""

    def __init__(self, db_path=None):
        if db_path is None:
            self.db_path = default_metrics_db_path()
        elif isinstance(db_path, Path):
            self.db_path = db_path
        else:
            self.db_path = Path(db_path) if db_path != ":memory:" else ":memory:"

        if isinstance(self.db_path, Path):
            self.db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            db_target = str(self.db_path)
        else:
            db_target = self.db_path

        self.conn = sqlite3.connect(db_target, timeout=10.0)
        self._init_db()

    def _init_db(self):
        cur = self.conn.cursor()
        cur.execute("PRAGMA journal_mode = WAL;")
        cur.execute("PRAGMA synchronous = NORMAL;")
        cur.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        cur.execute("""
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
        """)
        cur.execute("CREATE INDEX IF NOT EXISTS idx_metrics_samples_timestamp ON metrics_samples(timestamp);")
        self.conn.commit()
        cur.close()

    def record_sample(self, timestamp, cpu_util, cpu_temp, cpu_watts,
                      mem_used_gb, mem_total_gb, gpu_util, gpu_temp,
                      gpu_watts, net_down_kbps, net_up_kbps, system_watts,
                      power_source):
        """Insert or replace a metric snapshot."""
        with self.conn:
            self.conn.execute("""
                INSERT OR REPLACE INTO metrics_samples (
                    timestamp, cpu_util, cpu_temp, cpu_watts,
                    mem_used_gb, mem_total_gb, gpu_util, gpu_temp,
                    gpu_watts, net_down_kbps, net_up_kbps, system_watts,
                    power_source
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (timestamp, cpu_util, cpu_temp, cpu_watts,
                  mem_used_gb, mem_total_gb, gpu_util, gpu_temp,
                  gpu_watts, net_down_kbps, net_up_kbps, system_watts,
                  power_source))

    def record_sample_from_metrics(self, metrics, timestamp=None):
        """Extract fields from a standard get_metrics() dictionary and record the sample."""
        if timestamp is None:
            timestamp = time.time()
        cpu = metrics.get('cpu') or {}
        mem = metrics.get('memory') or {}
        gpu = metrics.get('gpu') or {}
        net = metrics.get('network') or {}
        power = metrics.get('power') or {}

        cpu_util = cpu.get('utilization')
        cpu_temp = cpu.get('temperature')
        cpu_watts = cpu.get('powerWatts')

        mem_used = mem.get('used')
        mem_total = mem.get('total')

        gpu_util = gpu.get('usagePercent')
        gpu_temp = gpu.get('temperature')
        gpu_watts = gpu.get('powerWatts')

        down_speed = net.get('downloadSpeed')
        net_down = (float(down_speed) / 1024.0) if down_speed is not None else None

        up_speed = net.get('uploadSpeed')
        net_up = (float(up_speed) / 1024.0) if up_speed is not None else None

        system_watts = power.get('totalWatts')
        power_source = power.get('source')

        self.record_sample(
            timestamp=timestamp,
            cpu_util=cpu_util,
            cpu_temp=cpu_temp,
            cpu_watts=cpu_watts,
            mem_used_gb=mem_used,
            mem_total_gb=mem_total,
            gpu_util=gpu_util,
            gpu_temp=gpu_temp,
            gpu_watts=gpu_watts,
            net_down_kbps=net_down,
            net_up_kbps=net_up,
            system_watts=system_watts,
            power_source=power_source,
        )

    def prune_older_than(self, days=30, now=None):
        """Prunes metrics samples older than given days. Returns number of rows deleted."""
        if now is None:
            now = time.time()
        cutoff = now - (float(days) * 86400.0)
        with self.conn:
            cur = self.conn.execute("DELETE FROM metrics_samples WHERE timestamp < ?", (cutoff,))
            pruned_count = cur.rowcount
            self.conn.execute("PRAGMA incremental_vacuum;")
        return pruned_count

    def get_report_data(self, start_time, end_time, cost_per_kwh=None):
        """Fetches aggregated statistics and sample integration (energy kWh and network volume) between start_time and end_time."""
        cur = self.conn.cursor()

        # Summary aggregations
        cur.execute("""
            SELECT
                COUNT(*),
                AVG(cpu_util), MAX(cpu_util), MIN(cpu_util),
                AVG(cpu_temp), MAX(cpu_temp),
                AVG(cpu_watts), MAX(cpu_watts),
                AVG(mem_used_gb), MAX(mem_used_gb), MAX(mem_total_gb),
                AVG(gpu_util), MAX(gpu_util), MIN(gpu_util),
                AVG(gpu_temp), MAX(gpu_temp),
                AVG(gpu_watts), MAX(gpu_watts),
                AVG(net_down_kbps), MAX(net_down_kbps),
                AVG(net_up_kbps), MAX(net_up_kbps),
                AVG(system_watts), MAX(system_watts), MIN(system_watts)
            FROM metrics_samples
            WHERE timestamp >= ? AND timestamp <= ?
        """, (start_time, end_time))
        row = cur.fetchone()

        (sample_count,
         avg_cpu_util, max_cpu_util, min_cpu_util,
         avg_cpu_temp, max_cpu_temp,
         avg_cpu_watts, max_cpu_watts,
         avg_mem_used, max_mem_used, max_mem_total,
         avg_gpu_util, max_gpu_util, min_gpu_util,
         avg_gpu_temp, max_gpu_temp,
         avg_gpu_watts, max_gpu_watts,
         avg_net_down, max_net_down,
         avg_net_up, max_net_up,
         avg_sys_watts, max_sys_watts, min_sys_watts) = row

        # Time series integration for kWh and Network Volume
        cur.execute("""
            SELECT timestamp, system_watts, net_down_kbps, net_up_kbps
            FROM metrics_samples
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC
        """, (start_time, end_time))
        ts_rows = cur.fetchall()
        cur.close()

        total_kwh = 0.0
        total_down_kb = 0.0
        total_up_kb = 0.0

        if len(ts_rows) >= 2:
            for i in range(1, len(ts_rows)):
                t_prev, w_prev, down_prev, up_prev = ts_rows[i - 1]
                t_curr, w_curr, down_curr, up_curr = ts_rows[i]
                dt = t_curr - t_prev
                if dt > 0:
                    dt_hours = dt / 3600.0

                    # Trapezoidal watts integration
                    if w_curr is not None and w_prev is not None:
                        w_avg = (w_curr + w_prev) / 2.0
                    elif w_curr is not None:
                        w_avg = w_curr
                    elif w_prev is not None:
                        w_avg = w_prev
                    else:
                        w_avg = 0.0
                    total_kwh += (w_avg * dt_hours) / 1000.0

                    # Network volume integration
                    if down_curr is not None and down_prev is not None:
                        down_avg = (down_curr + down_prev) / 2.0
                    elif down_curr is not None:
                        down_avg = down_curr
                    elif down_prev is not None:
                        down_avg = down_prev
                    else:
                        down_avg = 0.0
                    total_down_kb += down_avg * dt

                    if up_curr is not None and up_prev is not None:
                        up_avg = (up_curr + up_prev) / 2.0
                    elif up_curr is not None:
                        up_avg = up_curr
                    elif up_prev is not None:
                        up_avg = up_prev
                    else:
                        up_avg = 0.0
                    total_up_kb += up_avg * dt

        total_down_mb = total_down_kb / 1024.0
        total_up_mb = total_up_kb / 1024.0

        cost = None
        if cost_per_kwh is not None:
            cost = round(total_kwh * float(cost_per_kwh), 4)

        return {
            "period": {
                "start_time": start_time,
                "end_time": end_time,
                "sample_count": sample_count or 0,
            },
            "cpu": {
                "avg_util": round(avg_cpu_util, 2) if avg_cpu_util is not None else None,
                "max_util": round(max_cpu_util, 2) if max_cpu_util is not None else None,
                "min_util": round(min_cpu_util, 2) if min_cpu_util is not None else None,
                "avg_utilization": round(avg_cpu_util, 2) if avg_cpu_util is not None else None,
                "max_utilization": round(max_cpu_util, 2) if max_cpu_util is not None else None,
                "min_utilization": round(min_cpu_util, 2) if min_cpu_util is not None else None,
                "avg_temp": round(avg_cpu_temp, 1) if avg_cpu_temp is not None else None,
                "max_temp": round(max_cpu_temp, 1) if max_cpu_temp is not None else None,
                "avg_watts": round(avg_cpu_watts, 2) if avg_cpu_watts is not None else None,
                "max_watts": round(max_cpu_watts, 2) if max_cpu_watts is not None else None,
                "peak_watts": round(max_cpu_watts, 2) if max_cpu_watts is not None else None,
            },
            "memory": {
                "avg_used_gb": round(avg_mem_used, 2) if avg_mem_used is not None else None,
                "max_used_gb": round(max_mem_used, 2) if max_mem_used is not None else None,
                "peak_used_gb": round(max_mem_used, 2) if max_mem_used is not None else None,
                "total_gb": round(max_mem_total, 2) if max_mem_total is not None else None,
            },
            "gpu": {
                "avg_util": round(avg_gpu_util, 2) if avg_gpu_util is not None else None,
                "max_util": round(max_gpu_util, 2) if max_gpu_util is not None else None,
                "min_util": round(min_gpu_util, 2) if min_gpu_util is not None else None,
                "avg_utilization": round(avg_gpu_util, 2) if avg_gpu_util is not None else None,
                "max_utilization": round(max_gpu_util, 2) if max_gpu_util is not None else None,
                "min_utilization": round(min_gpu_util, 2) if min_gpu_util is not None else None,
                "avg_temp": round(avg_gpu_temp, 1) if avg_gpu_temp is not None else None,
                "max_temp": round(max_gpu_temp, 1) if max_gpu_temp is not None else None,
                "avg_watts": round(avg_gpu_watts, 2) if avg_gpu_watts is not None else None,
                "max_watts": round(max_gpu_watts, 2) if max_gpu_watts is not None else None,
                "peak_watts": round(max_gpu_watts, 2) if max_gpu_watts is not None else None,
            },
            "network": {
                "total_download_mb": round(total_down_mb, 2),
                "total_upload_mb": round(total_up_mb, 2),
                "total_down_mb": round(total_down_mb, 2),
                "total_up_mb": round(total_up_mb, 2),
                "peak_down_kbps": round(max_net_down, 2) if max_net_down is not None else None,
                "peak_up_kbps": round(max_net_up, 2) if max_net_up is not None else None,
                "peak_download_kbps": round(max_net_down, 2) if max_net_down is not None else None,
                "peak_upload_kbps": round(max_net_up, 2) if max_net_up is not None else None,
                "avg_down_kbps": round(avg_net_down, 2) if avg_net_down is not None else None,
                "avg_up_kbps": round(avg_net_up, 2) if avg_net_up is not None else None,
                "avg_download_kbps": round(avg_net_down, 2) if avg_net_down is not None else None,
                "avg_upload_kbps": round(avg_net_up, 2) if avg_net_up is not None else None,
            },
            "power": {
                "avg_watts": round(avg_sys_watts, 2) if avg_sys_watts is not None else None,
                "max_watts": round(max_sys_watts, 2) if max_sys_watts is not None else None,
                "min_watts": round(min_sys_watts, 2) if min_sys_watts is not None else None,
                "peak_watts": round(max_sys_watts, 2) if max_sys_watts is not None else None,
                "total_kwh": round(total_kwh, 4),
                "cost": cost,
                "cost_per_kwh": cost_per_kwh,
            }
        }

    def close(self):
        """Closes the database connection."""
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


def _sample_loop(interval=2.0, db=None, max_iterations=None, stop_event=None,
                 on_sample=None, now_func=time.time, sleep_func=time.sleep):
    """Continuous or bounded metrics sampling loop with SQLite historical recording and hourly pruning."""
    history_db = db
    if history_db is None:
        try:
            history_db = MetricsHistoryDB()
        except Exception:
            history_db = None

    # Run initial retention pruning on startup
    if history_db is not None:
        try:
            history_db.prune_older_than(days=30, now=now_func())
        except Exception:
            pass

    last_prune = now_func()
    iterations = 0

    while True:
        if stop_event is not None and stop_event.is_set():
            break
        if max_iterations is not None and iterations >= max_iterations:
            break

        data = get_metrics()
        now = now_func()

        if history_db is not None:
            try:
                history_db.record_sample_from_metrics(data, timestamp=now)
            except Exception:
                pass

            if now - last_prune >= 3600:
                try:
                    history_db.prune_older_than(days=30, now=now)
                except Exception:
                    pass
                last_prune = now

        if on_sample is not None:
            try:
                on_sample(data)
            except Exception:
                pass
        else:
            print(json.dumps(data), flush=True)

        iterations += 1
        if max_iterations is not None and iterations >= max_iterations:
            break
        if interval is None:
            break

        if sleep_func is not None:
            sleep_func(interval)


def parse_period(period_str, now=None):
    """
    Parses a period string (e.g., '1h', '24h', '7d', '30d') and returns (start_time, end_time) in epoch seconds.
    """
    if now is None:
        now = time.time()
    if not isinstance(period_str, str) or not period_str:
        raise ValueError(f"Invalid period: {period_str}. Use e.g. 1h, 24h, 7d, 30d")

    match = re.fullmatch(r'(\d+)([smhdw])', period_str.strip())
    if not match:
        raise ValueError(f"Invalid period format: {period_str}. Use e.g. 1h, 24h, 7d, 30d")

    val, unit = int(match.group(1)), match.group(2)
    multipliers = {
        's': 1.0,
        'm': 60.0,
        'h': 3600.0,
        'd': 86400.0,
        'w': 7 * 86400.0,
    }
    duration = val * multipliers[unit]
    return now - duration, now


def parse_iso_timestamp(val):
    """Parses an ISO 8601 string or numeric timestamp into an epoch timestamp (float)."""
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    val = str(val).strip()
    try:
        return float(val)
    except ValueError:
        pass
    from datetime import datetime
    try:
        clean = val.replace('Z', '+00:00')
        dt = datetime.fromisoformat(clean)
        return dt.timestamp()
    except Exception as e:
        raise ValueError(f"Invalid timestamp format: {val}. Use ISO 8601 format.") from e


def generate_metrics_report(db, start_time=None, end_time=None, format="table", cost_per_kwh=None):
    """
    Generates a historical metrics report in table, json, or csv format.
    db may be a MetricsHistoryDB instance, a Path, a path string, or None.
    """
    close_db = False
    if db is None:
        db = MetricsHistoryDB()
        close_db = True
    elif isinstance(db, (str, Path)):
        db = MetricsHistoryDB(db_path=db)
        close_db = True

    try:
        if start_time is None and end_time is None:
            end_time = time.time()
            start_time = end_time - 86400.0
        elif start_time is None:
            start_time = end_time - 86400.0
        elif end_time is None:
            end_time = time.time()

        if isinstance(start_time, str):
            start_time = parse_iso_timestamp(start_time)
        if isinstance(end_time, str):
            end_time = parse_iso_timestamp(end_time)

        data = db.get_report_data(start_time=start_time, end_time=end_time, cost_per_kwh=cost_per_kwh)

        fmt = (format or "table").lower()
        if fmt == "json":
            return data
        elif fmt == "csv":
            lines = ["category,metric,value"]
            p = data["period"]
            from datetime import datetime, timezone
            start_iso = datetime.fromtimestamp(p["start_time"], tz=timezone.utc).isoformat() if p.get("start_time") else ""
            end_iso = datetime.fromtimestamp(p["end_time"], tz=timezone.utc).isoformat() if p.get("end_time") else ""
            lines.append(f"period,start_time,{start_iso}")
            lines.append(f"period,end_time,{end_iso}")
            lines.append(f"period,sample_count,{p['sample_count']}")

            for cat, metrics in [("cpu", data["cpu"]), ("memory", data["memory"]),
                                 ("gpu", data["gpu"]), ("network", data["network"]),
                                 ("power", data["power"])]:
                for k, v in metrics.items():
                    val_str = "" if v is None else str(v)
                    lines.append(f"{cat},{k},{val_str}")
            return "\n".join(lines) + "\n"
        else:
            # table format
            from datetime import datetime, timezone
            p = data["period"]
            start_str = datetime.fromtimestamp(p["start_time"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ") if p.get("start_time") else "N/A"
            end_str = datetime.fromtimestamp(p["end_time"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ") if p.get("end_time") else "N/A"
            count = p["sample_count"]

            def fmt_val(val, unit="", ndigits=2, fallback="N/A"):
                if val is None:
                    return fallback
                return f"{val:.{ndigits}f}{unit}"

            c = data["cpu"]
            m = data["memory"]
            g = data["gpu"]
            n = data["network"]
            pw = data["power"]

            lines = [
                "=" * 60,
                "                    MSAM METRICS REPORT",
                "=" * 60,
                f"Period: {start_str} to {end_str} ({count} samples)",
                "-" * 60,
                "CPU:",
                f"  Utilization:  Avg: {fmt_val(c['avg_util'], '%')} | Max: {fmt_val(c['max_util'], '%')} | Min: {fmt_val(c['min_util'], '%')}",
                f"  Temperature:  Avg: {fmt_val(c['avg_temp'], '°C', 1)} | Max: {fmt_val(c['max_temp'], '°C', 1)}",
                f"  Power:        Avg: {fmt_val(c['avg_watts'], ' W')} | Peak: {fmt_val(c['max_watts'], ' W')}",
                "-" * 60,
                "Memory:",
                f"  Used:         Avg: {fmt_val(m['avg_used_gb'], ' GB')} | Peak: {fmt_val(m['max_used_gb'], ' GB')}",
                f"  Total:        {fmt_val(m['total_gb'], ' GB')}",
                "-" * 60,
                "GPU:",
                f"  Utilization:  Avg: {fmt_val(g['avg_util'], '%')} | Max: {fmt_val(g['max_util'], '%')} | Min: {fmt_val(g['min_util'], '%')}",
                f"  Temperature:  Avg: {fmt_val(g['avg_temp'], '°C', 1)} | Max: {fmt_val(g['max_temp'], '°C', 1)}",
                f"  Power:        Avg: {fmt_val(g['avg_watts'], ' W')} | Peak: {fmt_val(g['max_watts'], ' W')}",
                "-" * 60,
                "Network:",
                f"  Total Volume: Down: {fmt_val(n['total_download_mb'], ' MB')} | Up: {fmt_val(n['total_upload_mb'], ' MB')}",
                f"  Peak Speed:   Down: {fmt_val(n['peak_down_kbps'], ' KB/s')} | Up: {fmt_val(n['peak_up_kbps'], ' KB/s')}",
                f"  Avg Speed:    Down: {fmt_val(n['avg_down_kbps'], ' KB/s')} | Up: {fmt_val(n['avg_up_kbps'], ' KB/s')}",
                "-" * 60,
                "Power & Energy:",
                f"  System Power: Avg: {fmt_val(pw['avg_watts'], ' W')} | Max: {fmt_val(pw['max_watts'], ' W')} | Min: {fmt_val(pw['min_watts'], ' W')}",
                f"  Total Energy: {pw['total_kwh']:.4f} kWh",
            ]
            if pw['cost'] is not None and pw['cost_per_kwh'] is not None:
                lines.append(f"  Est. Cost:    ${pw['cost']:.4f} (@ ${pw['cost_per_kwh']:.4f}/kWh)")
            lines.append("=" * 60)
            return "\n".join(lines)
    finally:
        if close_db:
            db.close()


def run_report_cli(argv):
    import argparse
    parser = argparse.ArgumentParser(prog="msam-metrics report", description="Historical usage and power reporting")
    parser.add_argument("--period", help="Time period, e.g. 1h, 24h, 7d, 30d (default: 24h)")
    parser.add_argument("--from", dest="from_time", help="Start time in ISO format or unix timestamp")
    parser.add_argument("--to", dest="to_time", help="End time in ISO format or unix timestamp")
    parser.add_argument("--format", choices=["table", "json", "csv"], default="table", help="Output format")
    parser.add_argument("--cost-per-kwh", type=float, help="Electricity cost rate per kWh")
    parser.add_argument("--db", help="Path to SQLite metrics database")
    args = parser.parse_args(argv)

    start_time = None
    end_time = None

    if args.period:
        start_time, end_time = parse_period(args.period)
    if args.from_time:
        start_time = parse_iso_timestamp(args.from_time)
    if args.to_time:
        end_time = parse_iso_timestamp(args.to_time)

    db_path = args.db if args.db else default_metrics_db_path()
    db = MetricsHistoryDB(db_path=db_path)
    try:
        report = generate_metrics_report(
            db=db,
            start_time=start_time,
            end_time=end_time,
            format=args.format,
            cost_per_kwh=args.cost_per_kwh
        )
        if isinstance(report, dict):
            print(json.dumps(report, indent=2))
        else:
            print(report)
    finally:
        db.close()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "report":
        run_report_cli(sys.argv[2:])
        return
    # If run with --loop, print metrics every 2 seconds
    loop = len(sys.argv) > 1 and sys.argv[1] == "--loop"
    _sample_loop(interval=2.0 if loop else None, max_iterations=None if loop else 1)

if __name__ == "__main__":
    main()
