"""Collector regression tests: python3 -m unittest discover -s tests -v."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-metrics.py'
spec = importlib.util.spec_from_file_location('metrics', PATH)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        return target

    def stat(self, pid, ticks, start=10, ppid=1):
        fields = ['S', str(ppid)] + ['0'] * 18
        fields[11], fields[12], fields[19] = str(ticks), '0', str(start)
        self.write(f'proc/{pid}/stat', f'{pid} (a weird ) process) ' + ' '.join(fields))

    def sampler(self, count=24):
        return m.LinuxSampler(str(self.root / 'proc'), str(self.root / 'sys'), list(range(count)))

    def test_cpu_real_deltas_steal_guest_zero_and_reset(self):
        old = (100, 100, 100, 100, 100, 100, 100, 100)
        new = (110, 105, 110, 150, 105, 105, 105, 110)
        previous = dict(utilization=0.0, userUsage=0.0, systemUsage=0.0, idleUsage=0.0)
        actual = m.cpu_percent(old, new, previous)
        self.assertEqual(actual, dict(utilization=35.0, userUsage=15.0, systemUsage=20.0, idleUsage=55.0))
        self.assertEqual(m.cpu_percent(new, new, actual), actual)
        self.assertEqual(m.cpu_percent(new, old, actual), actual)
        # iowait decreasing must not discard the other usable counters.
        changed = m.cpu_percent(old, (110, 100, 100, 190, 99, 100, 100, 100), actual)
        self.assertEqual(changed['utilization'], 10.0)
        self.write('proc/stat', 'cpu 10 20 30 40 50 60 70 80 999 999\n')
        self.assertEqual(self.sampler().snapshot()['cpus']['cpu'], (10, 20, 30, 40, 50, 60, 70, 80))

    def test_affinity_uses_actual_noncontiguous_ids(self):
        with patch.object(m.os, 'cpu_count', return_value=32), patch.object(m.os, 'sched_getaffinity', return_value={3, 7, 11}, create=True):
            self.assertEqual(m.logical_cpu_ids(), [3, 7, 11])

    def test_shared_first_sample_24_cores_and_persistent_zero_delta(self):
        sampler = self.sampler()
        before = {'time': 10.0, 'cpus': {f'cpu{i}': (0,) * 8 for i in range(24)}, 'processes': {}, 'network': {'eth0': (1000, 2000)}}
        before['cpus']['cpu'] = (0,) * 8
        after = {'time': 10.5, 'cpus': {f'cpu{i}': (10, 0, 5, 85, 0, 0, 0, 0) for i in range(24)}, 'processes': {}, 'network': {'eth0': (1500, 3000)}}
        after['cpus']['cpu'] = (240, 0, 120, 2040, 0, 0, 0, 0)
        with patch.object(sampler, 'snapshot', side_effect=[before, after, dict(after, time=11)]), patch.object(sampler, 'sleep') as sleep:
            cpu, net = sampler.sample()
            self.assertEqual(cpu['coreCount'], 24)
            self.assertEqual(cpu['perCoreUsage'], [15.0] * 24)
            self.assertEqual(cpu['utilization'], 15.0)
            self.assertEqual(net['downloadSpeed'], 1000.0)
            self.assertEqual(net['uploadSpeed'], 2000.0)
            cpu2, net2 = sampler.sample()
            self.assertEqual(cpu2['utilization'], 15.0)
            self.assertEqual(net2['downloadSpeed'], 0.0)
            sleep.assert_called_once_with(0.5)

    def test_process_current_usage_reuse_exit_names_and_descendants(self):
        sampler = self.sampler()
        sampler.ticks = 100
        me = os.getpid()
        old = {10: (1, 10000, 1), 11: (1, 100, 2), 12: (1, 100, 3),
               13: (me, 0, 4), 14: (13, 0, 5), me: (1, 0, 6)}
        new = {10: (1, 10250, 1), 11: (1, 10000, 9), 13: (me, 1000, 4),
               14: (13, 1000, 5), me: (1, 1000, 6)}
        self.stat(10, 10250, start=1)
        self.write('proc/10/cmdline', '/usr/bin/python3\0-m\0uvicorn\0api.main:app\0')
        self.assertEqual(sampler.process_stat(10), (1, 10250, 1))
        sampler.previous = {'time': 1, 'cpus': {}, 'processes': old, 'network': {}}
        with patch.object(sampler, 'snapshot', return_value={'time': 2, 'cpus': {}, 'processes': new, 'network': {}}):
            cpu, _ = sampler.sample()
        self.assertEqual(cpu['topProcesses'], [{'id': '10:1', 'name': 'python3 uvicorn', 'usage': 250.0}])
        self.write('proc/10/cmdline', '/usr/bin/node\0/srv/web/server.js\0--secret\0')
        self.assertEqual(sampler.process_name(10), 'node server.js')

    def test_one_busy_core_is_a_share_of_total_capacity(self):
        for count in (8, 32):
            with self.subTest(logical_cores=count):
                sampler = self.sampler(count=count)
                cpus = {f'cpu{i}': (0,) * 8 for i in range(count)}
                sampler.previous = {'time': 1, 'cpus': dict(cpus, cpu=(0,) * 8),
                                    'processes': {}, 'network': {}}
                cpus = {f'cpu{i}': (0, 0, 0, 100, 0, 0, 0, 0) for i in range(count)}
                cpus['cpu0'] = (100, 0, 0, 0, 0, 0, 0, 0)
                cpus['cpu'] = (100, 0, 0, (count - 1) * 100, 0, 0, 0, 0)
                with patch.object(sampler, 'snapshot', return_value={
                        'time': 2, 'cpus': cpus, 'processes': {}, 'network': {}}):
                    cpu, _ = sampler.sample()
                self.assertEqual(cpu['coreCount'], count)
                self.assertEqual(cpu['utilization'], 100.0 / count)
                self.assertEqual(cpu['utilization'], sum(cpu['perCoreUsage']) / count)

    def test_restricted_affinity_keeps_aggregate_and_per_core_consistent(self):
        sampler = self.sampler(count=1)
        sampler.previous = {'time': 1, 'processes': {}, 'network': {},
                            'cpus': {'cpu': (0,) * 8, 'cpu0': (0,) * 8, 'cpu1': (0,) * 8}}
        current = {'time': 2, 'processes': {}, 'network': {},
                   'cpus': {'cpu': (100, 0, 0, 100, 0, 0, 0, 0),
                            'cpu0': (10, 0, 0, 90, 0, 0, 0, 0),
                            'cpu1': (90, 0, 0, 10, 0, 0, 0, 0)}}
        with patch.object(sampler, 'snapshot', return_value=current):
            cpu, _ = sampler.sample()
        self.assertEqual(cpu['utilization'], 10.0)
        self.assertEqual(cpu['perCoreUsage'], [10.0])

    def test_aggregate_weights_each_core_by_its_actual_tick_delta(self):
        sampler = self.sampler(count=2)
        # A 100% busy CPU with 100 ticks and an idle CPU with 300 ticks.
        # Deliberately inconsistent kernel aggregate: use the per-core windows.
        sampler.previous = {'time': 1, 'processes': {}, 'network': {},
                            'cpus': {key: (0,) * 8 for key in ('cpu', 'cpu0', 'cpu1')}}
        with patch.object(sampler, 'snapshot', return_value={
                'time': 2, 'processes': {}, 'network': {}, 'cpus': {
                    'cpu': (200, 0, 0, 200, 0, 0, 0, 0),
                    'cpu0': (100, 0, 0, 0, 0, 0, 0, 0),
                    'cpu1': (0, 0, 0, 300, 0, 0, 0, 0)}}):
            cpu, _ = sampler.sample()
        self.assertEqual(cpu['perCoreUsage'], [100.0, 0.0])
        self.assertEqual(cpu['utilization'], 25.0)

    def test_core_reset_cannot_be_hidden_by_another_cores_growth(self):
        sampler = self.sampler(count=2)
        sampler.previous = {'time': 1, 'processes': {}, 'network': {}, 'cpus': {
            'cpu0': (100, 0, 0, 100, 0, 0, 0, 0),
            'cpu1': (100, 0, 0, 100, 0, 0, 0, 0),
            'cpu': (200, 0, 0, 200, 0, 0, 0, 0)}}
        with patch.object(sampler, 'snapshot', return_value={
                'time': 2, 'processes': {}, 'network': {}, 'cpus': {
                    'cpu0': (0,) * 8,
                    'cpu1': (200, 0, 0, 400, 0, 0, 0, 0),
                    'cpu': (200, 0, 0, 400, 0, 0, 0, 0)}}):
            cpu, _ = sampler.sample()
        self.assertEqual(cpu['utilization'], 25.0)

    def test_network_physical_only_down_resets_and_new_interfaces(self):
        names = ['enp2s0f0', 'wlan0', 'lo', 'veth0', 'br-123', 'docker0', 'virbr0', 'tun0']
        lines = ['header', 'header']
        for name in names:
            lines.append(name + ': 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0')
            self.write(f'sys/class/net/{name}/operstate', 'down' if name == 'wlan0' else 'up')
            if name != 'tun0':
                self.write(f'sys/class/net/{name}/device/uevent', '')
        self.write('proc/net/dev', '\n'.join(lines))
        sampler = self.sampler()
        self.assertEqual(sampler.snapshot()['network'], {'enp2s0f0': (1000, 2000)})
        sampler.previous = {'time': 1, 'cpus': {}, 'processes': {}, 'network': {'enp2s0f0': (2000, 1000), 'gone': (99, 99)}}
        with patch.object(sampler, 'snapshot', return_value={'time': 2, 'cpus': {}, 'processes': {}, 'network': {'enp2s0f0': (1000, 2000), 'new': (9999, 9999)}}):
            _, network = sampler.sample()
        self.assertEqual(network['downloadSpeed'], 0.0)
        self.assertEqual(network['uploadSpeed'], 1000.0)

    def test_temperature_prefers_hottest_cpu_not_chipset(self):
        for i, kind, temp in [(0, 'pch_wellsburg', 55000), (1, 'x86_pkg_temp', 33000), (2, 'x86_pkg_temp', 35000)]:
            self.write(f'sys/class/thermal/thermal_zone{i}/type', kind)
            self.write(f'sys/class/thermal/thermal_zone{i}/temp', str(temp))
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 35.0)
        for i in (1, 2):
            self.write(f'sys/class/thermal/thermal_zone{i}/temp', 'unavailable')
        # A chipset reading is not a CPU temperature.
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 0.0)
        self.write('sys/class/hwmon/hwmon2/name', 'k10temp')
        self.write('sys/class/hwmon/hwmon2/temp1_input', '42000')
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 42.0)
        self.write('sys/class/thermal/thermal_zone1/temp', '33000')
        self.write('sys/class/hwmon/hwmon2/temp2_input', '49000')
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 49.0)

    def test_temperature_supports_arm_and_acpitz_fallback(self):
        # On ARM / DGX Spark systems without x86_pkg_temp or k10temp, acpitz is the SoC thermal zone.
        for i, temp in [(0, 42800), (1, 40000), (2, 43600)]:
            self.write(f'sys/class/thermal/thermal_zone{i}/type', 'acpitz')
            self.write(f'sys/class/thermal/thermal_zone{i}/temp', str(temp))
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 43.6)

        # Primary sensors (e.g. cpu_thermal or coretemp) take precedence when available.
        self.write('sys/class/thermal/thermal_zone3/type', 'cpu-thermal')
        self.write('sys/class/thermal/thermal_zone3/temp', '52000')
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 52.0)

    def test_linux_gpu_discrete_parsing(self):
        output = b"45, 62, 8192, 16384, NVIDIA GeForce RTX 4090\n"
        with patch.object(m.subprocess, 'check_output', return_value=output):
            gpu = m.get_linux_gpu()
        self.assertEqual(gpu['modelName'], 'NVIDIA GeForce RTX 4090')
        self.assertEqual(gpu['usagePercent'], 45.0)
        self.assertEqual(gpu['temperature'], 62.0)
        self.assertEqual(gpu['memoryUsed'], 8192.0)
        self.assertEqual(gpu['memoryTotal'], 16384.0)
        self.assertTrue(gpu['utilizationAvailable'])

    def test_linux_gpu_unified_memory_and_compute_apps(self):
        # NVIDIA GB10 / Blackwell / Grace unified memory returns [N/A] for device VRAM.
        smi_gpu = b"96, 70, [N/A], [N/A], NVIDIA GB10\n"
        smi_apps = b"4196\n936\n1290\n31066\n"
        def mock_smi(args, **kwargs):
            if any('query-gpu' in a for a in args):
                return smi_gpu
            if any('query-compute-apps' in a for a in args):
                return smi_apps
            raise subprocess.CalledProcessError(1, args)
        with patch.object(m.subprocess, 'check_output', side_effect=mock_smi):
            gpu = m.get_linux_gpu()
        self.assertEqual(gpu['modelName'], 'NVIDIA GB10')
        self.assertEqual(gpu['usagePercent'], 96.0)
        self.assertEqual(gpu['temperature'], 70.0)
        self.assertEqual(gpu['memoryUsed'], 37488.0)
        self.assertEqual(gpu['memoryTotal'], 0.0)
        self.assertTrue(gpu['utilizationAvailable'])

    def test_linux_gpu_handles_failure_and_missing_tool(self):
        with patch.object(m.subprocess, 'check_output', side_effect=FileNotFoundError):
            gpu = m.get_linux_gpu()
        self.assertEqual(gpu['modelName'], '')
        self.assertFalse(gpu['utilizationAvailable'])
        self.assertEqual(gpu['usagePercent'], 0.0)

    def test_memory_top_processes_rank_rss_not_cpu_with_pid_and_safe_name(self):
        for pid, rss, ticks in [(11, 1024, 9000), (12, 8192, 0), (13, 4096, 100)]:
            self.stat(pid, ticks)
            self.write(f'proc/{pid}/status', f'Name:\tworker\nVmRSS:\t{rss} kB\n')
            self.write(f'proc/{pid}/cmdline', '/usr/bin/python3\0-m\0worker\0--secret\0hidden\0')
        # Disappearing, malformed and kernel processes do not hide valid rows.
        self.write('proc/14/status', 'VmRSS: garbage kB')
        self.write('proc/15/status', 'Name: kernel\n')
        memory = m.linux_memory(str(self.root / 'proc'))
        self.assertEqual([p['pid'] for p in memory.get('topProcesses', [])], [12, 13, 11])
        self.assertEqual(memory['topProcesses'][0], {
            'id': '12:10', 'pid': 12, 'name': 'python3 worker', 'rssBytes': 8192 * 1024})
        self.assertNotIn('hidden', json.dumps(memory['topProcesses']))

    def test_memory_process_limit_and_reused_pid(self):
        for pid in range(10, 22):
            self.stat(pid, 0)
            self.write(f'proc/{pid}/status', f'VmRSS: {pid * 1024} kB\n')
        original = m.LinuxSampler.process_stat
        calls = {}
        def changing_stat(sampler, pid):
            value = original(sampler, pid)
            calls[pid] = calls.get(pid, 0) + 1
            if pid == 21 and calls[pid] > 1:
                return value[0], value[1], value[2] + 1
            return value
        with patch.object(m.LinuxSampler, 'process_stat', changing_stat):
            processes = m.linux_memory(str(self.root / 'proc')).get('topProcesses', [])
        self.assertEqual([p['pid'] for p in processes], list(range(20, 10, -1)))

    def test_mac_memory_processes_use_same_rss_shape(self):
        def output(command, **kwargs):
            if command[0] == 'ps' and 'pid=,rss=,comm=' in command:
                return b' 41 1024 /usr/bin/small\n 42 8192 /Applications/Large App\n'
            raise OSError('Unavailable in fixture')
        with patch.object(m, 'get_unix_disks', return_value={}), \
                patch.object(m, 'get_mac_gpu', return_value={}), \
                patch.object(m.subprocess, 'check_output', side_effect=output):
            processes = m.get_mac_metrics()['memory'].get('topProcesses', [])
        self.assertEqual(processes, [
            {'id': '42', 'pid': 42, 'name': 'Large App', 'rssBytes': 8192 * 1024},
            {'id': '41', 'pid': 41, 'name': 'small', 'rssBytes': 1024 * 1024}])

    def test_memory_free_available_anon_and_cache(self):
        self.write('proc/meminfo', '\n'.join(f'{key}: {value * 1024**2} kB' for key, value in dict(MemTotal=256, MemFree=54, MemAvailable=217, AnonPages=25, Cached=150, Buffers=2, SwapTotal=8, SwapFree=7).items()))
        memory = m.linux_memory(str(self.root / 'proc'))
        self.assertEqual((memory['total'], memory['used'], memory['free'], memory['available']), (256.0, 39.0, 54.0, 217.0))
        self.assertEqual((memory['app'], memory['cache'], memory['swap']), (25.0, 152.0, 1.0))
        self.assertEqual(memory['usagePercent'], 39 / 256 * 100)

    def test_disks_sum_data_full_mapper_names_reserved_blocks_and_bind(self):
        output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/mapper/ubuntu--vg-ubuntu--lv 1000 340 610 36% /
/dev/mapper/vg_data-lv_data 2000 1700 280 86% /data
/dev/mapper/vg_data-lv_data 2000 1700 280 86% /data bind
/dev/loop0 1000 1000 0 100% /snap/x
/dev/bad broken 1 1 1% /bad
'''
        def statvfs(path):
            total, used, available = (1000, 340, 610) if path == '/' else (2000, 1700, 280)
            return SimpleNamespace(f_blocks=total, f_bfree=total-used, f_bavail=available, f_frsize=1024)
        with patch.object(m.sys, 'platform', 'linux'), patch.object(m.subprocess, 'check_output', return_value=output), patch.object(m.os, 'statvfs', side_effect=statvfs):
            disk = m.get_unix_disks()
        self.assertEqual([d['id'] for d in disk['disks']], ['mapper/ubuntu--vg-ubuntu--lv', 'mapper/vg_data-lv_data'])
        self.assertEqual(disk['disks'][1]['volumes'][0]['mountPoint'], '/data')
        self.assertEqual(disk['totalGB'], 3000 / 1024**2)
        self.assertEqual(disk['usedGB'], 2040 / 1024**2)
        self.assertAlmostEqual(disk['usagePercent'], 2040 / (2040 + 890) * 100)
        self.assertEqual(disk['disks'][1]['volumes'][0]['availableGB'], 280 / 1024**2)

    def test_linux_data_mount_pressure_is_preserved_despite_healthy_aggregate(self):
        output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 100000 1000 99000 1% /
/dev/sdb1 1000 820 180 82% /data
'''
        with patch.object(m.sys, 'platform', 'linux'), \
                patch.object(m.subprocess, 'check_output', return_value=output), \
                patch.object(m.os, 'statvfs', side_effect=OSError):
            disk = m.get_unix_disks(sys_root=str(self.root / 'sys'))
        data = disk['disks'][1]['volumes'][0]
        self.assertLess(disk['usagePercent'], 2)
        self.assertEqual(disk['platform'], 'linux')
        self.assertTrue(data['isCriticalMount'])
        self.assertEqual(data['availableGB'] / (data['availableGB'] + data['usedGB']), 0.18)

    def test_zfs_data_mount_is_reported_but_memory_filesystems_are_excluded(self):
        self.write('proc/self/mountinfo', '''10 1 8:1 / / rw - ext4 /dev/sda1 rw
11 1 0:50 / /data rw - zfs tank/data rw
12 1 0:51 / /run rw - tmpfs tmpfs rw
13 1 0:52 / /scratch rw - overlay overlay rw
''')
        output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 100000 1000 99000 1% /
tank/data 1000 820 180 82% /data
tmpfs 1000 950 50 95% /run
overlay 1000 950 50 95% /scratch
'''
        with patch.object(m.sys, 'platform', 'linux'), \
                patch.object(m.subprocess, 'check_output', return_value=output), \
                patch.object(m.os, 'statvfs', side_effect=OSError):
            disk = m.get_unix_disks(sys_root=str(self.root / 'sys'), proc_root=str(self.root / 'proc'))
        volumes = [v for d in disk['disks'] for v in d['volumes']]
        self.assertEqual([v['mountPoint'] for v in volumes], ['/', '/data'])
        self.assertTrue(volumes[1]['isCriticalMount'])
        self.assertEqual(volumes[1]['availableGB'], 180 / 1024**2)

    def test_nvme_temperature_dedup_uses_controller_and_model_not_sensor_label(self):
        for number, controller, values in [(1, 'nvme0', (39000, 41000)),
                                            (2, 'nvme0', (38000,)),
                                            (3, 'nvme1', (47000,))]:
            monitor = self.root / f'sys/class/hwmon/hwmon{number}'
            self.write(f'sys/class/hwmon/hwmon{number}/name', 'nvme')
            controller_path = self.root / f'sys/class/nvme/{controller}'
            controller_path.mkdir(parents=True, exist_ok=True)
            (monitor / 'device').symlink_to(controller_path, target_is_directory=True)
            for i, value in enumerate(values, 1):
                self.write(f'sys/class/hwmon/hwmon{number}/temp{i}_input', str(value))
        # Identical models are still two separate physical drives.
        for controller in ('nvme0', 'nvme1'):
            self.write(f'sys/class/nvme/{controller}/model', 'Samsung SSD 990 PRO\n')
        sys_root = str(self.root / 'sys')
        self.assertEqual(m.linux_disk_temperatures(sys_root), {'nvme0': 41.0, 'nvme1': 47.0})
        with patch.object(m.sys, 'platform', 'linux'), \
                patch.object(m.subprocess, 'check_output', side_effect=subprocess.TimeoutExpired('df', 3)):
            disk = m.get_unix_disks(sys_root=sys_root)
        self.assertEqual(disk['temperatures'], [
            {'id': 'nvme0', 'model': 'Samsung SSD 990 PRO', 'temperature': 41.0},
            {'id': 'nvme1', 'model': 'Samsung SSD 990 PRO', 'temperature': 47.0}])
        self.assertEqual(m.linux_disk_identity('/dev/nvme0n1p2', sys_root),
                         ('nvme0', 'Samsung SSD 990 PRO'))
        self.assertEqual(m.linux_disk_identity('/dev/nvme0n2', sys_root),
                         ('nvme0', 'Samsung SSD 990 PRO'))
        with patch.object(m.os.path, 'realpath', return_value='/dev/nvme0n1p2'):
            self.assertEqual(m.linux_disk_identity('/dev/disk/by-uuid/volume', sys_root),
                             ('nvme0', 'Samsung SSD 990 PRO'))

    def test_drivetemp_scsi_device_resolves_physical_block_model(self):
        self.write('sys/class/hwmon/hwmon0/name', 'drivetemp')
        self.write('sys/class/hwmon/hwmon0/temp1_input', '43000')
        device = self.root / 'sys/devices/pci/host0/target0/0:0:0:0'
        (device / 'block/sda').mkdir(parents=True)
        (self.root / 'sys/class/hwmon/hwmon0/device').symlink_to(device, target_is_directory=True)
        self.write('sys/class/block/sda/device/model', 'WDC WD40EFRX\n')
        sys_root = str(self.root / 'sys')
        self.assertEqual(m.linux_disk_temperatures(sys_root), {'sda': 43.0})
        self.assertEqual(m.linux_disk_model('sda', sys_root), 'WDC WD40EFRX')

    def test_windows_marks_system_drive_and_retains_each_volume_capacity(self):
        output = json.dumps([
            {'id': 'C:', 'name': 'System', 'mountPoint': 'C:\\', 'totalGB': 100, 'usedGB': 82},
            {'id': 'D:', 'name': 'Data', 'mountPoint': 'D:\\', 'totalGB': 100, 'usedGB': 99}
        ]).encode()
        with patch.object(m.subprocess, 'check_output', return_value=output) as command:
            disk = m.get_windows_disks()
        self.assertEqual(disk['platform'], 'win32')
        volumes = disk['disks'][0]['volumes']
        self.assertEqual([v['isCriticalMount'] for v in volumes], [True, False])
        self.assertEqual([v['availableGB'] for v in volumes], [18, 1])
        # The Python string must preserve the PowerShell backslash.
        self.assertIn("$vol.DriveLetter + ':\\'", command.call_args.args[0][-1])

    def test_linux_disk_temperatures_from_nvme_and_drivetemp_hwmon(self):
        # NVMe drive: hwmon named "nvme" whose device symlink ends in nvme0.
        self.write('sys/class/hwmon/hwmon3/name', 'nvme')
        self.write('sys/class/hwmon/hwmon3/temp1_input', '39000')
        self.write('sys/class/hwmon/hwmon3/temp2_input', 'garbage')
        # SATA drive via drivetemp: device symlink ends in sda.
        self.write('sys/class/hwmon/hwmon4/name', 'drivetemp')
        self.write('sys/class/hwmon/hwmon4/temp1_input', '52000')
        # CPU monitor must not be mistaken for a disk.
        self.write('sys/class/hwmon/hwmon0/name', 'k10temp')
        self.write('sys/class/hwmon/hwmon0/temp1_input', '42000')
        sys_root = str(self.root / 'sys')
        real = {'hwmon3': sys_root + '/class/nvme/nvme0',
                'hwmon4': sys_root + '/class/block/sda',
                'hwmon0': sys_root + '/devices/platform/coretemp.0'}
        with patch.object(m.os.path, 'realpath',
                          side_effect=lambda path: real[os.path.basename(os.path.dirname(path))]):
            temps = m.linux_disk_temperatures(sys_root)
        self.assertEqual(temps, {'nvme0': 39.0, 'sda': 52.0})
        self.assertEqual(m.disk_temperature('nvme0', temps, sys_root), 39.0)
        # Block devices carry the namespace (nvme0n1); map to the controller sensor.
        self.assertEqual(m.disk_temperature('nvme0n1', temps, sys_root), 39.0)
        self.assertEqual(m.disk_temperature('sda', temps, sys_root), 52.0)
        self.assertIsNone(m.disk_temperature('sdb', temps, sys_root))

    def test_mapper_disk_temperature_uses_hottest_slave(self):
        temps = {'sda': 41.0, 'sdb': 55.0}
        self.write('sys/class/block/dm-0/slaves/sda/x', '')
        self.write('sys/class/block/dm-0/slaves/sdb/x', '')
        sys_root = str(self.root / 'sys')
        with patch.object(m.os.path, 'realpath', return_value='/dev/dm-0'):
            self.assertEqual(m.disk_temperature('mapper/vg-lv', temps, sys_root), 55.0)

    def test_disks_attach_temperature_per_physical_disk(self):
        output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/nvme0n1p1 1000 340 610 36% /
/dev/sda1 2000 1700 280 86% /data
'''
        def statvfs(path):
            total, used, available = (1000, 340, 610) if path == '/' else (2000, 1700, 280)
            return SimpleNamespace(f_blocks=total, f_bfree=total-used, f_bavail=available, f_frsize=1024)
        def identity(device, sys_root='/sys'):
            base = device[5:]
            return (base[:5], 'NVMe SSD') if base.startswith('nvme') else (base[:3], 'SATA Disk')
        with patch.object(m.sys, 'platform', 'linux'), \
                patch.object(m.subprocess, 'check_output', return_value=output), \
                patch.object(m.os, 'statvfs', side_effect=statvfs), \
                patch.object(m, 'linux_disk_identity', side_effect=identity), \
                patch.object(m, 'linux_disk_temperatures', return_value={'nvme0': 38.0, 'sda': 51.0}):
            disk = m.get_unix_disks()
        self.assertEqual([d['temperature'] for d in disk['disks']], [38.0, 51.0])

    def test_mac_disks_have_no_temperature_field_value(self):
        output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s3s1 1000 100 500 17% /
'''
        with patch.object(m.sys, 'platform', 'darwin'), \
                patch.object(m.shutil, 'disk_usage', return_value=SimpleNamespace(total=1024000, used=512000, free=512000)), \
                patch.object(m.subprocess, 'check_output', return_value=output):
            disk = m.get_unix_disks()
        self.assertIsNone(disk['disks'][0]['temperature'])

    def test_mac_apfs_summary_and_gpu_do_not_need_sudo(self):
        output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s3s1 1000 100 500 17% /
/dev/disk3s1 1000 300 500 38% /System/Volumes/Data
/dev/disk5s1 100 100 0 100% /private/cryptexd/metal
'''
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.shutil, 'disk_usage', return_value=SimpleNamespace(total=1024000, used=512000, free=512000)), patch.object(m.subprocess, 'check_output', return_value=output) as command:
            disk = m.get_unix_disks()
        self.assertEqual(disk['usagePercent'], 50.0)
        self.assertEqual(len(disk['disks']), 1)
        self.assertEqual(disk['disks'][0]['volumes'][0]['usedGB'], 512000 / 1024**3)
        self.assertEqual(disk['platform'], 'darwin')
        self.assertTrue(disk['disks'][0]['volumes'][0]['isCriticalMount'])
        self.assertIn(['df', '-P', '-k', '-l'], [call.args[0] for call in command.call_args_list])
        gpu_data = plistlib.dumps([{'model': 'Apple M3', 'gpu-core-count': 10, 'PerformanceStatistics': {'Device Utilization %': 27, 'In use system memory': 128 * 1024**2}}])
        with patch.object(m.subprocess, 'check_output', return_value=gpu_data) as command:
            gpu = m.get_mac_gpu()
        self.assertEqual(gpu['modelName'], 'Apple M3')
        self.assertEqual(gpu['cores'], 10)
        self.assertEqual(gpu['usagePercent'], 27.0)
        self.assertEqual(gpu['memoryTotal'], 0.0)
        self.assertNotIn('sudo', command.call_args.args[0])

    def test_mac_reports_core_count_and_already_normalized_total_usage(self):
        def output(command, **kwargs):
            if command[0] == 'top':
                return b'CPU usage: 10.0% user, 2.5% sys, 87.5% idle\n'
            if command[0] == 'ps':
                return b'COMM %CPU\nworker 100.0\n'
            raise OSError('Other metrics unavailable in fixture')
        with patch.object(m.os, 'cpu_count', return_value=8), \
                patch.object(m.os, 'getloadavg', return_value=(2.0, 1.0, 0.5)), \
                patch.object(m, 'get_unix_disks', return_value={}), \
                patch.object(m, 'get_mac_gpu', return_value={}), \
                patch.object(m, 'mac_cpu_activity', return_value=(None, [])), \
                patch.object(m.subprocess, 'check_output', side_effect=output):
            cpu = m.get_mac_metrics()['cpu']
        self.assertEqual(cpu['coreCount'], 8)
        self.assertEqual(cpu['loadPerCore'], 0.25)
        self.assertEqual(cpu['utilization'], 12.5)
        # Preserve the collector protocol; the app normalizes process usage.
        self.assertEqual(cpu['topProcesses'][0]['usage'], 100.0)

    def test_mac_temperatures_populates_cpu_gpu_and_disk(self):
        sample_temps = {'cpu': 48.5, 'gpu': 45.2, 'disk': 37.0}
        df_output = b'''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s3s1 1000 100 500 17% /
'''
        with patch.object(m, 'mac_temperatures', return_value=sample_temps), \
                patch.object(m.sys, 'platform', 'darwin'), \
                patch.object(m.shutil, 'disk_usage', return_value=SimpleNamespace(total=1024000, used=512000, free=512000)), \
                patch.object(m.subprocess, 'check_output', return_value=df_output), \
                patch.object(m, 'mac_cpu_activity', return_value=(None, [])):
            metrics = m.get_mac_metrics()
        self.assertEqual(metrics['cpu']['temperature'], 48.5)
        self.assertEqual(metrics['gpu']['temperature'], 45.2)
        self.assertEqual(metrics['disk']['disks'][0]['temperature'], 37.0)
        self.assertEqual(metrics['disk']['temperatures'][0]['temperature'], 37.0)
        self.assertEqual(metrics['disk']['temperatures'][0]['model'], 'Apple NVMe SSD')

    def test_mac_temperatures_safe_on_non_darwin(self):
        with patch.object(m.sys, 'platform', 'linux'):
            temps = m.mac_temperatures()
            self.assertEqual(temps, {'cpu': None, 'gpu': None, 'disk': None})

    def test_disks_timeout_returns_safe_shape(self):
        with patch.object(m.subprocess, 'check_output', side_effect=subprocess.TimeoutExpired('df', 3)):
            result = m.get_unix_disks()
        self.assertTrue({'usagePercent', 'totalGB', 'usedGB', 'disks'} <= set(result))
        self.assertEqual(result['disks'], [])

    def test_linux_rapl_energy_delta_and_rollover(self):
        # 1. Delta calculation without rollover
        delta = m.rapl_energy_delta(30_000_000, 10_000_000, 65_532_610_987)
        self.assertEqual(delta, 20_000_000)

        # 2. Counter rollover handling using max_energy_range_uj
        # max_range: 65,532,610,987; prev: 65,530,000,000; curr: 17,389,013
        # Delta = (65,532,610,987 - 65,530,000,000) + 17,389,013 = 2,610,987 + 17,389,013 = 20,000,000
        delta_rollover = m.rapl_energy_delta(17_389_013, 65_530_000_000, 65_532_610_987)
        self.assertEqual(delta_rollover, 20_000_000)

        # Without max_range, rollover should return None
        self.assertIsNone(m.rapl_energy_delta(100, 200, None))

        # 3. Reading sysfs directly
        self.write('sys/class/powercap/intel-rapl:0/energy_uj', '12345678\n')
        self.write('sys/class/powercap/intel-rapl:0/max_energy_range_uj', '65532610987\n')
        rapl = m.read_linux_rapl_energy(str(self.root / 'sys'))
        self.assertEqual(rapl, (12345678, 65532610987))

        # 4. Fallback to sudo -n cat if permission denied
        rapl_path = self.root / 'sys/class/powercap/intel-rapl:0/energy_uj'
        def mock_read_text(self_path):
            if 'energy_uj' in str(self_path):
                raise PermissionError('Permission denied')
            return '65532610987\n'
        with patch.object(Path, 'read_text', mock_read_text), \
             patch.object(m.subprocess, 'check_output', return_value=b'98765432\n'):
            rapl_sudo = m.read_linux_rapl_energy(str(self.root / 'sys'))
            self.assertEqual(rapl_sudo, (98765432, 65532610987))

    def test_nvidia_nvml_power_parsing_and_amd_fallback(self):
        # 1. Single GPU
        with patch.object(m.subprocess, 'check_output', return_value=b'16.36\n'):
            gpu_watts = m.get_gpu_power()
            self.assertEqual(gpu_watts, 16.36)

        # 2. Multi-GPU
        with patch.object(m.subprocess, 'check_output', return_value=b'25.50\n30.25\n'):
            gpu_watts = m.get_gpu_power()
            self.assertEqual(gpu_watts, 55.75)

        # 3. [N/A] output
        with patch.object(m.subprocess, 'check_output', return_value=b'[N/A]\n'):
            gpu_watts = m.get_gpu_power(str(self.root / 'sys'))
            self.assertIsNone(gpu_watts)

        # 4. AMD hwmon fallback when nvidia-smi fails
        self.write('sys/class/drm/card0/device/hwmon/hwmon1/power1_average', '45000000\n')
        with patch.object(m.subprocess, 'check_output', side_effect=FileNotFoundError):
            gpu_watts = m.get_gpu_power(str(self.root / 'sys'))
            self.assertEqual(gpu_watts, 45.0)

    def test_apple_silicon_powermetrics_parsing(self):
        sample_output = """
*** Sampled system activity (Thu Nov  5 09:54:22 2026 +0200) (104.10ms elapsed) ***

CPU Power: 4300 mW
GPU Power: 40 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 4340 mW
"""
        parsed = m.parse_macos_powermetrics(sample_output)
        self.assertEqual(parsed['cpuWatts'], 4.3)
        self.assertEqual(parsed['gpuWatts'], 0.04)
        self.assertEqual(parsed['combinedWatts'], 4.34)

        # Missing or unparseable output
        empty = m.parse_macos_powermetrics("")
        self.assertIsNone(empty['cpuWatts'])
        self.assertIsNone(empty['gpuWatts'])
        self.assertIsNone(empty['combinedWatts'])

        # read_macos_powermetrics running subprocess
        with patch.object(m.subprocess, 'check_output', return_value=sample_output.encode()):
            res = m.read_macos_powermetrics()
            self.assertEqual(res['combinedWatts'], 4.34)

    def test_linux_battery_discharge_parsing(self):
        # 1. power_now (uW -> W)
        self.write('sys/class/power_supply/BAT0/type', 'Battery\n')
        self.write('sys/class/power_supply/BAT0/status', 'Discharging\n')
        self.write('sys/class/power_supply/BAT0/power_now', '15000000\n')
        watts = m.read_linux_battery_power(str(self.root / 'sys'))
        self.assertEqual(watts, 15.0)

        # 2. current_now * voltage_now fallback (uA * uV -> W)
        self.write('sys/class/power_supply/BAT1/type', 'Battery\n')
        self.write('sys/class/power_supply/BAT1/status', 'Discharging\n')
        self.write('sys/class/power_supply/BAT1/current_now', '2000000\n')
        self.write('sys/class/power_supply/BAT1/voltage_now', '11000000\n')
        # Remove BAT0 so BAT1 is evaluated alone
        (self.root / 'sys/class/power_supply/BAT0/power_now').unlink()
        (self.root / 'sys/class/power_supply/BAT0/status').write_text('Not charging\n')
        watts = m.read_linux_battery_power(str(self.root / 'sys'))
        self.assertEqual(watts, 22.0)

        # 3. Charging status returns None
        (self.root / 'sys/class/power_supply/BAT1/status').write_text('Charging\n')
        watts = m.read_linux_battery_power(str(self.root / 'sys'))
        self.assertIsNone(watts)

    def test_power_sampler_sample_and_get_metrics(self):
        # Test PowerSampler directly
        sampler = m.PowerSampler(sys_root=str(self.root / 'sys'))
        cpu = {'utilization': 15.0}
        gpu = {'usagePercent': 20.0}

        # Mock RAPL and GPU power
        with patch.object(m, 'read_linux_rapl_energy', side_effect=[(10_000_000, 65_532_610_987), (30_000_000, 65_532_610_987)]), \
             patch.object(m, 'get_gpu_power', return_value=16.2), \
             patch.object(m, 'read_linux_battery_power', return_value=None):
            # First sample initializes baseline
            first = sampler.sample(now=10.0, cpu_info=cpu, gpu_info=gpu)
            # Second sample 1 second later computes delta
            second = sampler.sample(now=11.0, cpu_info=cpu, gpu_info=gpu)

            self.assertEqual(second['cpuWatts'], 20.0)
            self.assertEqual(second['gpuWatts'], 16.2)
            self.assertEqual(second['totalWatts'], 36.2)
            self.assertEqual(second['source'], 'rapl+nvml')
            self.assertEqual(cpu.get('powerWatts'), 20.0)
            self.assertEqual(gpu.get('powerWatts'), 16.2)

        # Test get_metrics includes power structure
        with patch.object(m, 'get_linux_metrics') as mock_linux:
            mock_linux.return_value = {
                'cpu': {'utilization': 10.0, 'powerWatts': 25.0},
                'gpu': {'usagePercent': 5.0, 'powerWatts': 15.0},
                'power': {'totalWatts': 40.0, 'cpuWatts': 25.0, 'gpuWatts': 15.0, 'source': 'rapl+nvml'}
            }
            metrics = m.get_metrics()
            self.assertIn('power', metrics)
            self.assertEqual(metrics['power']['totalWatts'], 40.0)
            self.assertEqual(metrics['cpu']['powerWatts'], 25.0)
            self.assertEqual(metrics['gpu']['powerWatts'], 15.0)

    def test_metrics_history_db_initialization_and_schema(self):
        db_path = self.root / 'nested' / 'metrics-history.db'
        self.assertFalse(db_path.parent.exists())

        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            # Check parent directory was created
            self.assertTrue(db_path.parent.exists())

            # Check WAL mode pragma
            cur = db.conn.cursor()
            cur.execute("PRAGMA journal_mode;")
            journal_mode = cur.fetchone()[0]
            self.assertEqual(journal_mode.lower(), 'wal')

            # Check table creation
            cur.execute("SELECT name FROM sqlite_master WHERE type='table';")
            tables = [row[0] for row in cur.fetchall()]
            self.assertIn('metrics_samples', tables)

            # Check timestamp index creation
            cur.execute("SELECT name FROM sqlite_master WHERE type='index';")
            indices = [row[0] for row in cur.fetchall()]
            self.assertIn('idx_metrics_samples_timestamp', indices)

            # Check columns
            cur.execute("PRAGMA table_info(metrics_samples);")
            columns = {row[1]: row[2].upper() for row in cur.fetchall()}
            expected_columns = {
                'timestamp': 'REAL',
                'cpu_util': 'REAL',
                'cpu_temp': 'REAL',
                'cpu_watts': 'REAL',
                'mem_used_gb': 'REAL',
                'mem_total_gb': 'REAL',
                'gpu_util': 'REAL',
                'gpu_temp': 'REAL',
                'gpu_watts': 'REAL',
                'net_down_kbps': 'REAL',
                'net_up_kbps': 'REAL',
                'system_watts': 'REAL',
                'power_source': 'TEXT',
            }
            for col, col_type in expected_columns.items():
                self.assertIn(col, columns)
                self.assertEqual(columns[col], col_type)
        finally:
            db.close()

        # Check default db path resolution
        with patch.object(m.sys, 'platform', 'linux'), patch.object(Path, 'home', return_value=self.root / 'fakehome'):
            path = m.default_metrics_db_path()
            self.assertEqual(path, self.root / 'fakehome' / '.local/state/msam/metrics-history.db')

        with patch.object(m.sys, 'platform', 'win32'), patch.dict(os.environ, {'LOCALAPPDATA': str(self.root / 'fakeappdata')}):
            path = m.default_metrics_db_path()
            self.assertEqual(path, self.root / 'fakeappdata' / 'msam/metrics-history.db')

    def test_metrics_history_db_record_sample(self):
        db_path = self.root / 'test_record.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            ts = 1762330000.5
            db.record_sample(
                timestamp=ts,
                cpu_util=14.5,
                cpu_temp=48.0,
                cpu_watts=42.5,
                mem_used_gb=15.2,
                mem_total_gb=32.0,
                gpu_util=18.0,
                gpu_temp=52.0,
                gpu_watts=16.2,
                net_down_kbps=145.5,
                net_up_kbps=25.0,
                system_watts=58.7,
                power_source='rapl+nvml'
            )

            cur = db.conn.cursor()
            cur.execute("SELECT * FROM metrics_samples WHERE timestamp = ?", (ts,))
            row = cur.fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row[0], ts)
            self.assertEqual(row[1], 14.5)
            self.assertEqual(row[2], 48.0)
            self.assertEqual(row[3], 42.5)
            self.assertEqual(row[4], 15.2)
            self.assertEqual(row[5], 32.0)
            self.assertEqual(row[6], 18.0)
            self.assertEqual(row[7], 52.0)
            self.assertEqual(row[8], 16.2)
            self.assertEqual(row[9], 145.5)
            self.assertEqual(row[10], 25.0)
            self.assertEqual(row[11], 58.7)
            self.assertEqual(row[12], 'rapl+nvml')

            # Test record_sample_from_metrics
            metrics_payload = {
                'cpu': {'utilization': 25.0, 'temperature': 55.0, 'powerWatts': 30.0},
                'memory': {'used': 10.5, 'total': 16.0},
                'gpu': {'usagePercent': 40.0, 'temperature': 60.0, 'powerWatts': 50.0},
                'network': {'downloadSpeed': 204800.0, 'uploadSpeed': 51200.0},  # Bytes/s -> KB/s (/1024)
                'power': {'totalWatts': 80.0, 'source': 'powermetrics'}
            }
            ts2 = ts + 5.0
            db.record_sample_from_metrics(metrics_payload, timestamp=ts2)
            cur.execute("SELECT net_down_kbps, net_up_kbps, system_watts, power_source FROM metrics_samples WHERE timestamp = ?", (ts2,))
            r2 = cur.fetchone()
            self.assertEqual(r2[0], 200.0)  # 204800 / 1024
            self.assertEqual(r2[1], 50.0)   # 51200 / 1024
            self.assertEqual(r2[2], 80.0)
            self.assertEqual(r2[3], 'powermetrics')

            # Test NULL values handling
            ts3 = ts + 10.0
            db.record_sample(
                timestamp=ts3,
                cpu_util=None,
                cpu_temp=None,
                cpu_watts=None,
                mem_used_gb=None,
                mem_total_gb=None,
                gpu_util=None,
                gpu_temp=None,
                gpu_watts=None,
                net_down_kbps=None,
                net_up_kbps=None,
                system_watts=None,
                power_source=None
            )
            cur.execute("SELECT cpu_util, power_source FROM metrics_samples WHERE timestamp = ?", (ts3,))
            r3 = cur.fetchone()
            self.assertIsNone(r3[0])
            self.assertIsNone(r3[1])
        finally:
            db.close()

    def test_metrics_history_db_prune_older_than(self):
        db_path = self.root / 'test_prune.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            now = 1762330000.0
            day = 86400.0
            timestamps = [
                now - (40 * day),  # > 30 days old: prune
                now - (31 * day),  # > 30 days old: prune
                now - (30 * day) - 10,  # > 30 days old: prune
                now - (29 * day),  # < 30 days old: keep
                now - (5 * day),   # keep
                now,               # keep
            ]
            for t in timestamps:
                db.record_sample(
                    timestamp=t,
                    cpu_util=10.0, cpu_temp=40.0, cpu_watts=20.0,
                    mem_used_gb=8.0, mem_total_gb=16.0,
                    gpu_util=5.0, gpu_temp=35.0, gpu_watts=10.0,
                    net_down_kbps=100.0, net_up_kbps=10.0,
                    system_watts=30.0, power_source='rapl'
                )

            pruned = db.prune_older_than(days=30, now=now)
            self.assertEqual(pruned, 3)

            cur = db.conn.cursor()
            cur.execute("SELECT timestamp FROM metrics_samples ORDER BY timestamp ASC")
            remaining = [r[0] for r in cur.fetchall()]
            self.assertEqual(len(remaining), 3)
            self.assertEqual(remaining, [now - (29 * day), now - (5 * day), now])
        finally:
            db.close()

    def test_sample_loop_integration_and_periodic_pruning(self):
        db_path = self.root / 'test_loop.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))

        samples_collected = []
        now_val = [1000.0]

        def fake_now():
            return now_val[0]

        def fake_sleep(sec):
            now_val[0] += sec

        # Plant an old sample to verify startup pruning runs
        db.record_sample(
            timestamp=1000.0 - (35 * 86400),
            cpu_util=5.0, cpu_temp=30.0, cpu_watts=10.0,
            mem_used_gb=4.0, mem_total_gb=16.0,
            gpu_util=0.0, gpu_temp=30.0, gpu_watts=0.0,
            net_down_kbps=0.0, net_up_kbps=0.0,
            system_watts=10.0, power_source='battery'
        )

        sample_metric_payload = {
            'cpu': {'utilization': 15.0, 'temperature': 45.0, 'powerWatts': 25.0},
            'memory': {'used': 8.0, 'total': 16.0},
            'gpu': {'usagePercent': 10.0, 'temperature': 40.0, 'powerWatts': 15.0},
            'network': {'downloadSpeed': 10240.0, 'uploadSpeed': 5120.0},
            'power': {'totalWatts': 40.0, 'source': 'rapl+nvml'}
        }

        with patch.object(m, 'get_metrics', return_value=sample_metric_payload):
            # Run 3 iterations
            m._sample_loop(
                interval=2,
                db=db,
                max_iterations=3,
                on_sample=lambda s: samples_collected.append(s),
                now_func=fake_now,
                sleep_func=fake_sleep
            )

        self.assertEqual(len(samples_collected), 3)

        # Check that the 35-day-old sample was pruned on startup
        cur = db.conn.cursor()
        cur.execute("SELECT timestamp FROM metrics_samples ORDER BY timestamp ASC")
        rows = [r[0] for r in cur.fetchall()]
        self.assertEqual(len(rows), 3)

        # Test periodic pruning when 1 hour elapses
        with patch.object(db, 'prune_older_than', wraps=db.prune_older_than) as mock_prune, \
             patch.object(m, 'get_metrics', return_value=sample_metric_payload):
            # Startup prune occurs once
            # Advance time by 3700 seconds (> 1 hour)
            now_val[0] = 5000.0
            m._sample_loop(
                interval=2,
                db=db,
                max_iterations=1,
                on_sample=lambda s: None,
                now_func=fake_now,
                sleep_func=fake_sleep
            )
            # prune_older_than should have been called on startup and hourly
            self.assertTrue(mock_prune.called)

        # Clean exception handling: if DB write fails, loop continues without crashing
        with patch.object(db, 'record_sample_from_metrics', side_effect=Exception("Disk full")):
            samples_collected.clear()
            with patch.object(m, 'get_metrics', return_value=sample_metric_payload):
                m._sample_loop(
                    interval=1,
                    db=db,
                    max_iterations=2,
                    on_sample=lambda s: samples_collected.append(s),
                    now_func=fake_now,
                    sleep_func=fake_sleep
                )
            self.assertEqual(len(samples_collected), 2)

        db.close()

    def test_parse_period(self):
        now = 1762330000.0
        # 1 hour = 3600s
        start, end = m.parse_period("1h", now=now)
        self.assertEqual(end, now)
        self.assertEqual(start, now - 3600.0)

        # 24 hours = 86400s
        start, end = m.parse_period("24h", now=now)
        self.assertEqual(end, now)
        self.assertEqual(start, now - 86400.0)

        # 7 days = 7 * 86400s
        start, end = m.parse_period("7d", now=now)
        self.assertEqual(end, now)
        self.assertEqual(start, now - (7 * 86400.0))

        # 30 days = 30 * 86400s
        start, end = m.parse_period("30d", now=now)
        self.assertEqual(end, now)
        self.assertEqual(start, now - (30 * 86400.0))

        # Invalid formats
        for invalid in ["", "xyz", "24x", "-1h", "100"]:
            with self.assertRaises(ValueError):
                m.parse_period(invalid, now=now)

    def test_metrics_history_db_get_report_data_aggregations(self):
        db_path = self.root / 'test_report_agg.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            t0 = 10000.0
            # 3 samples over 1 hour (3600s): t=0, t=1800, t=3600
            db.record_sample(
                timestamp=t0,
                cpu_util=20.0, cpu_temp=40.0, cpu_watts=30.0,
                mem_used_gb=8.0, mem_total_gb=16.0,
                gpu_util=10.0, gpu_temp=50.0, gpu_watts=20.0,
                net_down_kbps=100.0, net_up_kbps=20.0,
                system_watts=50.0, power_source='rapl+nvml'
            )
            db.record_sample(
                timestamp=t0 + 1800.0,
                cpu_util=40.0, cpu_temp=50.0, cpu_watts=50.0,
                mem_used_gb=10.0, mem_total_gb=16.0,
                gpu_util=30.0, gpu_temp=60.0, gpu_watts=40.0,
                net_down_kbps=300.0, net_up_kbps=60.0,
                system_watts=90.0, power_source='rapl+nvml'
            )
            db.record_sample(
                timestamp=t0 + 3600.0,
                cpu_util=60.0, cpu_temp=60.0, cpu_watts=70.0,
                mem_used_gb=12.0, mem_total_gb=16.0,
                gpu_util=50.0, gpu_temp=70.0, gpu_watts=60.0,
                net_down_kbps=500.0, net_up_kbps=100.0,
                system_watts=130.0, power_source='rapl+nvml'
            )

            data = db.get_report_data(t0, t0 + 3600.0, cost_per_kwh=0.20)

            # Period
            self.assertEqual(data['period']['sample_count'], 3)
            self.assertEqual(data['period']['start_time'], t0)
            self.assertEqual(data['period']['end_time'], t0 + 3600.0)

            # CPU: avg 40, min 20, max 60, avg_temp 50, avg_watts 50, max_watts 70
            self.assertAlmostEqual(data['cpu']['avg_util'], 40.0, places=1)
            self.assertAlmostEqual(data['cpu']['min_util'], 20.0, places=1)
            self.assertAlmostEqual(data['cpu']['max_util'], 60.0, places=1)
            self.assertAlmostEqual(data['cpu']['avg_temp'], 50.0, places=1)
            self.assertAlmostEqual(data['cpu']['max_temp'], 60.0, places=1)
            self.assertAlmostEqual(data['cpu']['avg_watts'], 50.0, places=1)
            self.assertAlmostEqual(data['cpu']['max_watts'], 70.0, places=1)

            # Memory: avg 10.0, max 12.0, total 16.0
            self.assertAlmostEqual(data['memory']['avg_used_gb'], 10.0, places=1)
            self.assertAlmostEqual(data['memory']['max_used_gb'], 12.0, places=1)
            self.assertAlmostEqual(data['memory']['total_gb'], 16.0, places=1)

            # GPU: avg 30, min 10, max 50, avg_temp 60, avg_watts 40, max_watts 60
            self.assertAlmostEqual(data['gpu']['avg_util'], 30.0, places=1)
            self.assertAlmostEqual(data['gpu']['min_util'], 10.0, places=1)
            self.assertAlmostEqual(data['gpu']['max_util'], 50.0, places=1)
            self.assertAlmostEqual(data['gpu']['avg_temp'], 60.0, places=1)
            self.assertAlmostEqual(data['gpu']['avg_watts'], 40.0, places=1)
            self.assertAlmostEqual(data['gpu']['max_watts'], 60.0, places=1)

            # Network: peak_down 500, peak_up 100, avg_down 300, avg_up 60
            self.assertAlmostEqual(data['network']['peak_down_kbps'], 500.0, places=1)
            self.assertAlmostEqual(data['network']['peak_up_kbps'], 100.0, places=1)
            self.assertAlmostEqual(data['network']['avg_down_kbps'], 300.0, places=1)
            self.assertAlmostEqual(data['network']['avg_up_kbps'], 60.0, places=1)
            # Volume:
            # interval 1: (100+300)/2 * 1800 = 360000 KB
            # interval 2: (300+500)/2 * 1800 = 720000 KB -> total 1080000 KB = 1054.69 MB
            self.assertAlmostEqual(data['network']['total_download_mb'], 1080000.0 / 1024.0, places=1)
            # up: (20+60)/2 * 1800 + (60+100)/2 * 1800 = 72000 + 144000 = 216000 KB = 210.94 MB
            self.assertAlmostEqual(data['network']['total_upload_mb'], 216000.0 / 1024.0, places=1)

            # Power: avg 90.0, min 50.0, max 130.0
            self.assertAlmostEqual(data['power']['avg_watts'], 90.0, places=1)
            self.assertAlmostEqual(data['power']['min_watts'], 50.0, places=1)
            self.assertAlmostEqual(data['power']['max_watts'], 130.0, places=1)

            # Energy kWh:
            # interval 1: (50 + 90)/2 * 0.5h / 1000 = 0.035 kWh
            # interval 2: (90 + 130)/2 * 0.5h / 1000 = 0.055 kWh
            # Total = 0.090 kWh
            self.assertAlmostEqual(data['power']['total_kwh'], 0.09, places=4)
            # Cost: 0.09 kWh * $0.20/kWh = $0.018
            self.assertAlmostEqual(data['power']['cost'], 0.018, places=4)
            self.assertEqual(data['power']['cost_per_kwh'], 0.20)
        finally:
            db.close()

    def test_generate_metrics_report_formats(self):
        db_path = self.root / 'test_report_formats.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            t0 = 1000.0
            db.record_sample(
                timestamp=t0,
                cpu_util=25.0, cpu_temp=45.0, cpu_watts=35.0,
                mem_used_gb=8.0, mem_total_gb=16.0,
                gpu_util=15.0, gpu_temp=55.0, gpu_watts=25.0,
                net_down_kbps=150.0, net_up_kbps=50.0,
                system_watts=60.0, power_source='rapl+nvml'
            )
            db.record_sample(
                timestamp=t0 + 3600.0,
                cpu_util=35.0, cpu_temp=55.0, cpu_watts=45.0,
                mem_used_gb=10.0, mem_total_gb=16.0,
                gpu_util=25.0, gpu_temp=65.0, gpu_watts=35.0,
                net_down_kbps=250.0, net_up_kbps=70.0,
                system_watts=80.0, power_source='rapl+nvml'
            )

            # JSON format returns dict
            json_report = m.generate_metrics_report(db, start_time=t0, end_time=t0 + 3600.0, format="json", cost_per_kwh=0.15)
            self.assertIsInstance(json_report, dict)
            self.assertIn('cpu', json_report)
            self.assertIn('power', json_report)
            self.assertEqual(json_report['period']['sample_count'], 2)
            self.assertAlmostEqual(json_report['power']['total_kwh'], 0.07, places=3)
            self.assertAlmostEqual(json_report['power']['cost'], 0.07 * 0.15, places=4)

            # Table format returns ASCII string
            table_report = m.generate_metrics_report(db, start_time=t0, end_time=t0 + 3600.0, format="table", cost_per_kwh=0.15)
            self.assertIsInstance(table_report, str)
            self.assertIn("MSAM METRICS REPORT", table_report)
            self.assertIn("CPU:", table_report)
            self.assertIn("Power & Energy:", table_report)
            self.assertIn("0.0700 kWh", table_report)

            # CSV format returns CSV string
            csv_report = m.generate_metrics_report(db, start_time=t0, end_time=t0 + 3600.0, format="csv", cost_per_kwh=0.15)
            self.assertIsInstance(csv_report, str)
            self.assertIn("category,metric,value", csv_report)
            self.assertIn("power,total_kwh,0.07", csv_report)
            self.assertIn("cpu,avg_util", csv_report)
        finally:
            db.close()

    def test_generate_metrics_report_empty_db(self):
        db_path = self.root / 'test_report_empty.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            # Query time range with no samples
            json_report = m.generate_metrics_report(db, start_time=100.0, end_time=200.0, format="json", cost_per_kwh=0.15)
            self.assertIsInstance(json_report, dict)
            self.assertEqual(json_report['period']['sample_count'], 0)
            self.assertEqual(json_report['power']['total_kwh'], 0.0)
            self.assertEqual(json_report['power']['cost'], 0.0)
            self.assertIsNone(json_report['cpu']['avg_util'])

            table_report = m.generate_metrics_report(db, start_time=100.0, end_time=200.0, format="table")
            self.assertIn("(0 samples)", table_report)

            csv_report = m.generate_metrics_report(db, start_time=100.0, end_time=200.0, format="csv")
            self.assertIn("category,metric,value", csv_report)
            self.assertIn("period,sample_count,0", csv_report)
        finally:
            db.close()

    def test_report_cli_parsing_and_execution(self):
        db_path = self.root / 'test_report_cli.db'
        db = m.MetricsHistoryDB(db_path=str(db_path))
        try:
            now = time.time()
            db.record_sample(
                timestamp=now - 60,
                cpu_util=20.0, cpu_temp=40.0, cpu_watts=30.0,
                mem_used_gb=8.0, mem_total_gb=16.0,
                gpu_util=10.0, gpu_temp=50.0, gpu_watts=20.0,
                net_down_kbps=100.0, net_up_kbps=20.0,
                system_watts=50.0, power_source='rapl+nvml'
            )
            db.record_sample(
                timestamp=now,
                cpu_util=40.0, cpu_temp=50.0, cpu_watts=50.0,
                mem_used_gb=10.0, mem_total_gb=16.0,
                gpu_util=30.0, gpu_temp=60.0, gpu_watts=40.0,
                net_down_kbps=300.0, net_up_kbps=60.0,
                system_watts=90.0, power_source='rapl+nvml'
            )
        finally:
            db.close()

        # Run CLI report with --format json
        cmd = [sys.executable, str(PATH), "report", "--db", str(db_path), "--period", "1h", "--format", "json", "--cost-per-kwh", "0.20"]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        out = json.loads(res.stdout)
        self.assertEqual(out['period']['sample_count'], 2)
        self.assertAlmostEqual(out['power']['cost_per_kwh'], 0.20)

        # Run CLI report with --format table
        cmd_table = [sys.executable, str(PATH), "report", "--db", str(db_path), "--period", "1h", "--format", "table"]
        res_table = subprocess.run(cmd_table, capture_output=True, text=True, check=True)
        self.assertIn("MSAM METRICS REPORT", res_table.stdout)

        # Run CLI report with --format csv
        cmd_csv = [sys.executable, str(PATH), "report", "--db", str(db_path), "--period", "1h", "--format", "csv"]
        res_csv = subprocess.run(cmd_csv, capture_output=True, text=True, check=True)
        self.assertIn("category,metric,value", res_csv.stdout)


if __name__ == '__main__':
    unittest.main()
