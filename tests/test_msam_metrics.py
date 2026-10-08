"""Collector regression tests: python3 -m unittest discover -s tests -v."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
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
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 55.0)
        self.write('sys/class/hwmon/hwmon2/name', 'k10temp')
        self.write('sys/class/hwmon/hwmon2/temp1_input', '42000')
        self.assertEqual(m.linux_temperature(str(self.root / 'sys')), 42.0)

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
        def identity(device):
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
        self.assertEqual(command.call_args.args[0], ['df', '-P', '-k', '-l'])
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
                patch.object(m.subprocess, 'check_output', side_effect=output):
            cpu = m.get_mac_metrics()['cpu']
        self.assertEqual(cpu['coreCount'], 8)
        self.assertEqual(cpu['loadPerCore'], 0.25)
        self.assertEqual(cpu['utilization'], 12.5)
        # Preserve the collector protocol; the app normalizes process usage.
        self.assertEqual(cpu['topProcesses'][0]['usage'], 100.0)

    def test_disks_timeout_returns_safe_shape(self):
        with patch.object(m.subprocess, 'check_output', side_effect=subprocess.TimeoutExpired('df', 3)):
            result = m.get_unix_disks()
        self.assertEqual(set(result), {'usagePercent', 'totalGB', 'usedGB', 'disks'})
        self.assertEqual(result['disks'], [])


if __name__ == '__main__':
    unittest.main()
