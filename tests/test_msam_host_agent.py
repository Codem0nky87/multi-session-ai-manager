import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources'


def module(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), RESOURCES / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class HostAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.agent = module('msam-host-agent.py')
        self.installer = module('msam-host-agent-install.py')
        self.manager = module('msam-metrics-manage.py')
        for mod in (self.agent, self.installer):
            mod.HOME = self.home
            mod.STATE = self.home / '.local/state/msam-host-agent'
        self.agent.UPDATER_STATE = self.home / '.local/state/msam-agent-updater'
        self.installer.BASE = self.home / '.local/libexec/msam-host-agent'

    def stage(self):
        stage = self.home / 'stage'; stage.mkdir()
        manifest = {}
        for name in self.installer.FILES:
            shutil.copyfile(RESOURCES / name, stage / name)
            manifest[name] = hashlib.sha256((stage / name).read_bytes()).hexdigest()
        (stage / 'manifest.json').write_text(json.dumps(manifest))
        return stage

    def test_status_reports_component_versions(self):
        import re
        components = self.agent.COMPONENT_VERSIONS
        self.assertEqual(components['service'], self.agent.VERSION)
        # Real declared versions are read from the bundled scripts.
        metrics = (RESOURCES / 'msam-metrics.py').read_text()
        self.assertEqual(components['metrics'],
                         re.search(r"^METRICS_VERSION = ['\"]([^'\"]+)['\"]", metrics, re.MULTILINE).group(1))
        self.assertEqual(components['metrics'], '2.5.0')
        self.assertNotIn('metrics_windows', components, "metrics_windows must be unified under metrics")
        self.assertRegex(components['updater'], r'^\d+$')
        # Digest-only components are short hex strings.
        self.assertRegex(components['msam-host-software.py'], r'^[0-9a-f]{12}$')
        self.assertRegex(components['msam-hardware-db.json'], r'^[0-9a-f]{12}$')

        # Windows platform resolves metrics version from msam-metrics.ps1
        metrics_ps1 = (RESOURCES / 'msam-metrics.ps1').read_text()
        ps1_version = re.search(r'^\$MetricsVersion\s*=\s*[\'"]([^\'"]+)[\'"]', metrics_ps1, re.MULTILINE).group(1)
        self.assertEqual(ps1_version, '2.5.0', "Windows metrics collector version must match POSIX (2.5.0)")
        with patch('os.name', 'nt'):
            win_components = self.agent.component_versions()
            self.assertEqual(win_components['metrics'], '2.5.0')
            self.assertNotIn('metrics_windows', win_components)

    def test_status_command_output_carries_components(self):
        output = subprocess.run([sys.executable, str(RESOURCES / 'msam-host-agent.py'), 'status'],
                                capture_output=True, text=True,
                                env=dict(os.environ, MSAM_HOST_HOME=str(self.home / 'unused')), timeout=30)
        self.assertEqual(output.returncode, 0, output.stderr)
        payload = json.loads(output.stdout.strip().split('MSAM_HOST_STATUS=', 1)[1])
        self.assertEqual(payload['components']['metrics'], self.agent.COMPONENT_VERSIONS['metrics'])

    def test_invalid_bundle_keeps_old_service_and_collectors(self):
        stage = self.stage()
        (stage / 'msam-metrics.py').write_text('broken')
        with patch.object(self.installer, 'control') as control:
            with self.assertRaisesRegex(ValueError, 'checksum'):
                self.installer.install(stage)
        control.assert_not_called()

    def test_active_update_refuses_migration(self):
        directory = self.home / '.local/state/msam-agent-updater'
        directory.mkdir(parents=True)
        batch = '12345678-1234-1234-1234-123456789012'
        (directory / 'current').write_text(batch)
        (directory / 'batches' / batch).mkdir(parents=True)
        (directory / 'batches' / batch / 'phase').write_text('rolling')
        with self.assertRaisesRegex(RuntimeError, 'rolling agent update'):
            self.installer.require_idle()
        (directory / 'batches' / batch / 'phase').write_text('complete')
        self.installer.require_idle()

    def test_management_lock_excludes_workers_and_parallel_installers(self):
        lock = self.home / '.local/state/msam-agent-updater/lock'
        with self.installer.maintenance():
            self.assertEqual((lock / 'pid').read_text(), str(os.getpid()))
            self.installer.require_idle()
            with self.assertRaises(BlockingIOError):
                with self.installer.maintenance():
                    self.fail('Concurrent management was allowed')
        self.assertFalse(lock.exists())

    def held_updater_lock(self, pid=None):
        lock = self.home / '.local/state/msam-agent-updater/lock'
        lock.mkdir(parents=True)
        if pid is not None:
            (lock / 'pid').write_text(str(pid))
        return lock

    def test_service_change_waits_out_the_workers_passing_lock(self):
        """The running service takes the updater lock for a few milliseconds every
        two seconds to look at its queue. Meeting it there used to fail Install,
        Restart, Stop and Remove with "An agent update is in progress"."""
        lock = self.held_updater_lock(pid=os.getpid())
        waits = []

        def worker_finishes_on_the_third_look(seconds):
            waits.append(seconds)
            if len(waits) == 3:
                (lock / 'pid').unlink()
                lock.rmdir()

        self.installer.take_updater_lock(lock, patience=10, sleep=worker_finishes_on_the_third_look)
        self.assertEqual(len(waits), 3)
        self.assertTrue(lock.is_dir(), 'the installer now holds the lock')
        self.assertFalse((lock / 'pid').exists())

    def test_service_change_through_maintenance_survives_a_passing_lock(self):
        lock = self.held_updater_lock(pid=os.getpid())

        def release():
            (lock / 'pid').unlink()
            lock.rmdir()

        timer = threading.Timer(0.2, release)
        timer.start()
        self.addCleanup(timer.cancel)
        with self.installer.maintenance():
            self.assertEqual((lock / 'pid').read_text(), str(os.getpid()))
        self.assertFalse(lock.exists())

    def test_an_update_that_keeps_the_lock_still_refuses_the_service_change(self):
        lock = self.held_updater_lock(pid=os.getpid())
        ticks = iter(range(100))
        with self.assertRaisesRegex(RuntimeError, 'An agent update is in progress'):
            self.installer.take_updater_lock(lock, patience=5, clock=lambda: next(ticks), sleep=lambda _: None)
        self.assertEqual((lock / 'pid').read_text(), str(os.getpid()), 'the holder keeps its lock')

    def test_lock_left_by_a_dead_worker_is_cleared(self):
        finished = subprocess.Popen([sys.executable, '-c', 'pass'])
        finished.wait()
        lock = self.held_updater_lock(pid=finished.pid)
        self.installer.take_updater_lock(lock, patience=5, sleep=lambda _: None)
        self.assertTrue(lock.is_dir())
        self.assertFalse((lock / 'pid').exists())

    def test_lock_without_an_owner_is_reported_once_it_outlasts_the_wait(self):
        lock = self.held_updater_lock()
        ticks = iter(range(100))
        with self.assertRaisesRegex(RuntimeError, 'updater lock needs attention'):
            self.installer.take_updater_lock(lock, patience=5, clock=lambda: next(ticks), sleep=lambda _: None)
        self.assertTrue(lock.is_dir())

    def test_failed_first_install_leaves_no_enabled_service_or_launcher(self):
        stage = self.stage()
        result = subprocess.CompletedProcess([], 0, 'yes\n', '')
        with patch.object(self.installer, 'run', return_value=result), patch.object(self.installer, 'build_mac_launcher'), patch.object(self.installer, 'control'), patch.object(self.installer, 'wait_healthy', side_effect=RuntimeError('unhealthy')):
            with self.assertRaisesRegex(RuntimeError, 'unhealthy'):
                self.installer.install(stage)
        self.assertFalse((self.installer.BASE / 'current').exists())
        self.assertFalse(self.installer.service_path().exists())
        self.assertFalse((self.home / '.local/bin/msam-host-agent').exists())
        self.assertFalse(self.installer.get_status()['installed'])

    def test_native_windows_batch_blocks_service_replacement(self):
        path = self.home / '.local/state/msam-agent-updater/current.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'phase': 'updating'}))
        with self.assertRaises(RuntimeError):
            self.installer.require_idle()

    def test_removal_marker_prevents_reconnect_reinstall(self):
        current = self.installer.BASE / 'current'; current.mkdir(parents=True)
        (current / 'msam-host-agent.py').write_text('installed')
        self.installer.STATE.mkdir(parents=True)
        (self.installer.STATE / 'disabled').touch()
        self.assertFalse(self.installer.get_status()['installed'])
        self.assertTrue(self.installer.get_status()['disabled'])

    def test_windows_network_rates_ignore_new_interfaces_and_counter_resets(self):
        metrics = module('msam-metrics.py')
        payloads = [
            {'nic': {'received': 100, 'sent': 40}},
            {'nic': {'received': 300, 'sent': 100}, 'new': {'received': 9000, 'sent': 500}},
            {'nic': {'received': 10, 'sent': 5}, 'new': {'received': 9040, 'sent': 520}},
        ]
        results = [subprocess.CompletedProcess([], 0, json.dumps({'networkCounters': p}).encode()) for p in payloads]
        with patch.object(self.agent.os, 'name', 'nt'), patch.object(self.agent.sys, 'platform', 'win32'), \
                patch.object(self.agent, 'environment', return_value={}), \
                patch.object(self.agent.subprocess, 'run', side_effect=results), \
                patch.object(self.agent.time, 'monotonic', side_effect=[10, 12, 14]):
            first, second, third = [self.agent.sample_metrics(metrics) for _ in results]
        self.assertEqual(first['network']['downloadSpeed'], 0)
        self.assertEqual(second['network']['downloadSpeed'], 100)
        self.assertEqual(second['network']['uploadSpeed'], 30)
        self.assertEqual(third['network']['downloadSpeed'], 20)
        self.assertEqual(third['network']['uploadSpeed'], 10)
        self.assertNotIn('networkCounters', third)

    def test_windows_metrics_script_power_telemetry_structure(self):
        metrics_ps1 = (RESOURCES / 'msam-metrics.ps1').read_text()
        # Verify nvidia-smi query includes power.draw
        self.assertIn('power.draw', metrics_ps1, "msam-metrics.ps1 must query nvidia-smi power.draw")
        # Verify battery discharge rate query via CIM BatteryStatus
        self.assertIn('BatteryStatus', metrics_ps1, "msam-metrics.ps1 must query WMI BatteryStatus")
        self.assertIn('DischargeRate', metrics_ps1, "msam-metrics.ps1 must query DischargeRate")
        # Verify power fields in cpu, gpu, and top-level power object
        import re
        self.assertRegex(metrics_ps1, r'cpu\s*=\s*@\{[\s\S]*?powerWatts', "msam-metrics.ps1 must define powerWatts in cpu")
        self.assertRegex(metrics_ps1, r'gpu\s*=\s*@\{[\s\S]*?powerWatts', "msam-metrics.ps1 must define powerWatts in gpu")
        self.assertRegex(metrics_ps1, r'power\s*=\s*@\{[\s\S]*?totalWatts[\s\S]*?cpuWatts[\s\S]*?gpuWatts[\s\S]*?source',
                         "msam-metrics.ps1 must define top-level power hashtable with totalWatts, cpuWatts, gpuWatts, source")

    def test_windows_metrics_payload_power_fields_parsing(self):
        metrics = module('msam-metrics.py')
        sample_payload = {
            'cpu': {
                'temperature': 45.0,
                'utilization': 22.5,
                'powerWatts': None,
            },
            'gpu': {
                'usagePercent': 35.0,
                'modelName': 'NVIDIA GeForce RTX 4070',
                'temperature': 52.0,
                'powerWatts': 85.5,
            },
            'power': {
                'totalWatts': 85.5,
                'cpuWatts': None,
                'gpuWatts': 85.5,
                'source': 'nvml',
            },
            'memory': {'used': 8.0, 'total': 32.0, 'usagePercent': 25.0},
            'networkCounters': {'eth0': {'received': 2048, 'sent': 1024}},
        }
        proc = subprocess.CompletedProcess([], 0, json.dumps(sample_payload).encode('utf-8-sig'))
        self.agent.WINDOWS_NETWORK = None
        with patch.object(self.agent.os, 'name', 'nt'), patch.object(self.agent.sys, 'platform', 'win32'), \
                patch.object(self.agent, 'environment', return_value={}), \
                patch.object(self.agent.subprocess, 'run', return_value=proc), \
                patch.object(self.agent.time, 'monotonic', return_value=100.0):
            res = self.agent.sample_metrics(metrics)

        self.assertIn('power', res)
        self.assertEqual(res['power']['totalWatts'], 85.5)
        self.assertIsNone(res['power']['cpuWatts'])
        self.assertEqual(res['power']['gpuWatts'], 85.5)
        self.assertEqual(res['power']['source'], 'nvml')
        self.assertIsNone(res['cpu']['powerWatts'])
        self.assertEqual(res['gpu']['powerWatts'], 85.5)

        # Verify integration with MetricsHistoryDB recording
        db_path = self.home / '.local/state/msam/metrics-history.db'
        db = metrics.MetricsHistoryDB(db_path=db_path)
        db.record_sample_from_metrics(res, timestamp=1700000000.0)
        cur = db.conn.cursor()
        cur.execute("SELECT cpu_watts, gpu_watts, system_watts, power_source FROM metrics_samples WHERE timestamp = 1700000000.0")
        row = cur.fetchone()
        self.assertEqual(row, (None, 85.5, 85.5, 'nvml'))
        db.close()

    def test_windows_metrics_battery_and_fallback_power_sources(self):
        metrics = module('msam-metrics.py')
        battery_payload = {
            'cpu': {'utilization': 10.0, 'powerWatts': None},
            'gpu': {'usagePercent': 0.0, 'powerWatts': None},
            'power': {'totalWatts': 24.3, 'cpuWatts': None, 'gpuWatts': None, 'source': 'battery'},
            'networkCounters': {},
        }
        none_payload = {
            'cpu': {'utilization': 5.0, 'powerWatts': None},
            'gpu': {'usagePercent': 0.0, 'powerWatts': None},
            'power': {'totalWatts': None, 'cpuWatts': None, 'gpuWatts': None, 'source': 'none'},
            'networkCounters': {},
        }
        for payload, expected_source, expected_watts in [
            (battery_payload, 'battery', 24.3),
            (none_payload, 'none', None),
        ]:
            proc = subprocess.CompletedProcess([], 0, json.dumps(payload).encode('utf-8-sig'))
            self.agent.WINDOWS_NETWORK = None
            with patch.object(self.agent.os, 'name', 'nt'), patch.object(self.agent.sys, 'platform', 'win32'), \
                    patch.object(self.agent, 'environment', return_value={}), \
                    patch.object(self.agent.subprocess, 'run', return_value=proc):
                res = self.agent.sample_metrics(metrics)
            self.assertEqual(res['power']['source'], expected_source)
            self.assertEqual(res['power']['totalWatts'], expected_watts)

    def test_mac_and_linux_definitions_run_one_unified_daemon(self):
        with patch.object(self.installer.sys, 'platform', 'linux'):
            self.installer.write_service()
            content = self.installer.service_path().read_text()
            self.assertIn('msam-host-agent.py" "serve"', content)
            self.assertNotIn('msam-agent-updater.sh', content)
            self.assertNotIn('NoNewPrivileges=true', content)
        with patch.object(self.installer.sys, 'platform', 'darwin'):
            self.installer.write_service()
            import plistlib
            plist = plistlib.loads(self.installer.service_path().read_bytes())
            self.assertEqual(plist['ProgramArguments'][-1], 'serve')
            self.assertEqual(plist['EnvironmentVariables']['MSAM_HOST_HOME'], str(self.home))

    def fake_launchctl(self, desktop_session, user_session=True):
        """A stand-in for `run` that answers launchctl the way macOS does.

        `gui/<uid>` only exists while that user is logged in at the screen;
        printing it otherwise fails with launchd's error 125.
        """
        calls, loaded = [], set()

        def run(args, check=True, timeout=30, **kwargs):
            args = [str(arg) for arg in args]
            calls.append(args)
            code = 0
            if args[0] == 'launchctl':
                verb, target = args[1], args[2] if args[1] != 'kickstart' else args[3]
                domain = '/'.join(target.split('/')[:2])
                available = desktop_session if domain.startswith('gui/') else user_session
                if not available:
                    code = 125
                elif verb == 'print' and target.count('/') == 2:
                    code = 0 if target in loaded else 113
                elif verb == 'bootstrap':
                    import plistlib
                    definition = plistlib.loads(Path(args[3]).read_bytes())
                    background = definition.get('LimitLoadToSessionType') == 'Background'
                    # launchd refuses a definition whose session type does not match.
                    if background != domain.startswith('user/'):
                        code = 5
                    else:
                        loaded.add(domain + '/' + definition['Label'])
                elif verb == 'bootout':
                    code = 0 if target in loaded else 3
                    loaded.discard(target)
            if check and code:
                raise subprocess.CalledProcessError(
                    code, args, '', 'Could not print domain: 125: Domain does not support specified action')
            return subprocess.CompletedProcess(args, code, '', '')
        return run, calls, loaded

    def test_mac_service_runs_in_the_background_session_without_a_desktop_login(self):
        import plistlib
        label = self.installer.LABEL
        for desktop_session, domain in ((False, 'user/501'), (True, 'gui/501')):
            run, calls, loaded = self.fake_launchctl(desktop_session)
            with patch.object(self.installer.sys, 'platform', 'darwin'), \
                    patch.object(self.installer.os, 'getuid', return_value=501), \
                    patch.object(self.installer, 'run', side_effect=run):
                self.assertEqual(self.installer.mac_domain(), domain)
                self.installer.write_service()
                definition = plistlib.loads(self.installer.service_path().read_bytes())
                # Only a background-session definition may load outside the desktop session.
                self.assertEqual(definition.get('LimitLoadToSessionType'),
                                 None if desktop_session else 'Background')
                self.installer.control('start')
            self.assertEqual(loaded, {domain + '/' + label})
            self.assertIn(['launchctl', 'kickstart', '-k', domain + '/' + label], calls)

    def test_mac_start_rewrites_a_definition_left_by_the_other_session(self):
        import plistlib
        label = self.installer.LABEL
        with patch.object(self.installer.sys, 'platform', 'darwin'), \
                patch.object(self.installer.os, 'getuid', return_value=501):
            # Installed while logged in at the screen...
            run, _, _ = self.fake_launchctl(desktop_session=True)
            with patch.object(self.installer, 'run', side_effect=run):
                self.installer.write_service()
            # ...then started again after that desktop session has ended.
            run, _, loaded = self.fake_launchctl(desktop_session=False)
            with patch.object(self.installer, 'run', side_effect=run):
                self.installer.control('start')
            self.assertEqual(loaded, {'user/501/' + label})
            definition = plistlib.loads(self.installer.service_path().read_bytes())
            self.assertEqual(definition['LimitLoadToSessionType'], 'Background')
            self.assertEqual(definition['ProgramArguments'][-1], 'serve')
            # And back again once the desktop session returns.
            run, _, loaded = self.fake_launchctl(desktop_session=True)
            with patch.object(self.installer, 'run', side_effect=run):
                self.installer.control('start')
            self.assertEqual(loaded, {'gui/501/' + label})
            self.assertNotIn('LimitLoadToSessionType', plistlib.loads(self.installer.service_path().read_bytes()))

    def test_mac_stop_clears_the_service_from_both_sessions(self):
        label = self.installer.LABEL
        for desktop_session in (False, True):
            run, calls, _ = self.fake_launchctl(desktop_session)
            with patch.object(self.installer.sys, 'platform', 'darwin'), \
                    patch.object(self.installer.os, 'getuid', return_value=501), \
                    patch.object(self.installer, 'run', side_effect=run):
                self.installer.control('stop')
            for domain in ('gui/501', 'user/501'):
                self.assertIn(['launchctl', 'bootout', domain + '/' + label], calls)

    def test_mac_install_does_not_need_a_desktop_login(self):
        stage = self.stage()
        run, _, _ = self.fake_launchctl(desktop_session=False)
        with patch.object(self.installer.sys, 'platform', 'darwin'), \
                patch.object(self.installer.os, 'getuid', return_value=501), \
                patch.object(self.installer, 'run', side_effect=run), \
                patch.object(self.installer, 'build_mac_launcher', side_effect=RuntimeError('past the session check')), \
                patch.object(self.installer, 'control'):
            with self.assertRaisesRegex(RuntimeError, 'past the session check'):
                self.installer.install(stage)

        # With no launchd session at all, say so in words rather than launchd's.
        run, _, _ = self.fake_launchctl(desktop_session=False, user_session=False)
        with patch.object(self.installer.sys, 'platform', 'darwin'), \
                patch.object(self.installer.os, 'getuid', return_value=501), \
                patch.object(self.installer, 'run', side_effect=run), \
                patch.object(self.installer, 'control'):
            with self.assertRaisesRegex(RuntimeError, 'launchd session'):
                self.installer.install(stage)

    def test_native_launcher_preflight_failure_keeps_current_service(self):
        stage = self.stage()
        previous = self.installer.BASE / 'releases/old'
        previous.mkdir(parents=True)
        (self.installer.BASE / 'current').symlink_to(previous)
        result = subprocess.CompletedProcess([], 0, 'yes\n', '')
        with patch.object(self.installer, 'run', return_value=result), \
                patch.object(self.installer, 'build_mac_launcher', side_effect=RuntimeError('compiler failed')), \
                patch.object(self.installer, 'control') as control:
            with self.assertRaisesRegex(RuntimeError, 'compiler failed'):
                self.installer.install(stage)
        control.assert_not_called()
        self.assertEqual((self.installer.BASE / 'current').resolve(), previous.resolve())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS native process naming')
    def test_mac_native_launcher_preserves_python_and_identifies_process(self):
        stage = self.stage()
        self.installer.build_mac_launcher(stage)
        self.installer.BASE.mkdir(parents=True)
        (self.installer.BASE / 'current').symlink_to(stage)
        command = self.installer.command('serve')
        self.assertEqual(Path(command[0]).name, 'msam-host-agent')
        self.installer.write_service()
        import plistlib
        definition = plistlib.loads(self.installer.service_path().read_bytes())
        self.assertEqual(definition['ProgramArguments'], command)
        process = subprocess.Popen(command[:3] + ['-c',
            'import sys,time; print(sys.executable, flush=True); time.sleep(30)'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), sys.executable)
            name = subprocess.check_output(['ps', '-c', '-p', str(process.pid), '-o', 'comm='], text=True).strip()
            self.assertEqual(name, 'msam-host-agent')
        finally:
            process.terminate()
            process.communicate(timeout=5)
        self.assertEqual(process.returncode, -15)
        failure = subprocess.run(command[:3] + ['-c', 'raise SystemExit(7)'], capture_output=True)
        self.assertEqual(failure.returncode, 7)

    def test_failed_replacement_restores_previous_release(self):
        stage = self.stage()
        previous = self.installer.BASE / 'releases/old'; previous.mkdir(parents=True)
        (previous / 'msam-host-agent.py').write_text('old')
        (self.installer.BASE / 'current').symlink_to(previous)
        result = subprocess.CompletedProcess([], 0, 'yes\n', '')
        with patch.object(self.installer, 'run', return_value=result), patch.object(self.installer, 'build_mac_launcher'), patch.object(self.installer, 'control') as control, patch.object(self.installer, 'wait_healthy', side_effect=RuntimeError('unhealthy')), patch.object(self.installer, 'migrate_collectors') as retire:
            with self.assertRaisesRegex(RuntimeError, 'unhealthy'):
                self.installer.install(stage)
        self.assertEqual((self.installer.BASE / 'current').resolve(), previous.resolve())
        self.assertEqual(control.call_args.args, ('start',))
        retire.assert_not_called()

    def test_metrics_retirement_targets_only_exact_owned_collectors(self):
        target = self.home / '.local/bin/msam-metrics'
        own = ('1', [sys.executable, str(target), '--loop'])
        self.assertTrue(self.manager.is_collector(own, target))
        for args in ([sys.executable, '-c', str(target), '--loop'], ['herdr', str(target), '--loop'], [sys.executable, str(target) + '.other', '--loop']):
            self.assertFalse(self.manager.is_collector(('1', args), target))
        self.assertTrue(self.manager.is_collector(('now', '/usr/bin/python3 ' + str(target) + ' --loop'), target))

    def test_real_daemon_has_one_collector_and_survives_reader_disconnect(self):
        (self.home / '.local/bin').mkdir(parents=True)
        fake = self.home / '.local/bin/herdr'
        fake.write_text('#!/bin/sh\nprintf \'{"sessions":[]}\\n\'\n'); fake.chmod(0o700)
        env = dict(os.environ, MSAM_HOST_HOME=str(self.home), PYTHONDONTWRITEBYTECODE='1')
        daemon = subprocess.Popen([sys.executable, '-B', str(RESOURCES / 'msam-host-agent.py'), 'serve'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            path = self.agent.STATE / 'status.json'
            for _ in range(100):
                data = self.agent.read_json(path, {})
                if data.get('metrics'):
                    break
                time.sleep(.05)
            self.assertTrue(data.get('metrics'), daemon.stderr.read().decode() if daemon.poll() is not None else 'no metrics')
            args = [sys.executable, '-B', str(RESOURCES / 'msam-host-agent.py'), 'metrics']
            first = json.loads(subprocess.check_output(args, env=env, timeout=5))
            self.assertIn('cpu', first)
            reader = subprocess.Popen(args + ['--loop'], env=env, stdout=subprocess.DEVNULL)
            time.sleep(.1); reader.terminate(); reader.wait(timeout=5)
            self.assertIsNone(daemon.poll())
            second = json.loads(subprocess.check_output(args, env=env, timeout=5))
            self.assertIn('disk', second)
            duplicate = subprocess.run([sys.executable, '-B', str(RESOURCES / 'msam-host-agent.py'), 'serve'], env=env, capture_output=True, timeout=5)
            self.assertNotEqual(duplicate.returncode, 0)
        finally:
            daemon.terminate(); daemon.wait(timeout=10)
            daemon.stderr.close()
        self.assertFalse(self.agent.status()['running'])

    def test_sample_metrics_includes_providers_and_terminal_agents(self):
        mock_metrics_mod = unittest.mock.MagicMock()
        mock_payload = {
            'cpu': {'utilization': 15.0},
            'memory': {'usagePercent': 45.0},
            'disk': {'volumes': []},
            'gpu': {'usagePercent': 0.0},
        }
        mock_metrics_mod.get_linux_metrics.return_value = dict(mock_payload)
        mock_metrics_mod.get_mac_metrics.return_value = dict(mock_payload)
        self.agent.atomic_json(self.agent.STATE / 'providers.json', {
            'providers': {'claude_code': {'state': 'HEALTHY', 'used_percent': 10.0}, 'codex': {'state': 'HEALTHY', 'used_percent': 5.0}},
            'terminal_agents': []
        })
        sample = self.agent.sample_metrics(mock_metrics_mod)
        self.assertIn('providers', sample)
        self.assertIn('terminal_agents', sample)
        self.assertIn('claude_code', sample['providers'])
        self.assertIn('codex', sample['providers'])

    def test_analyze_task_command(self):
        transcript = self.home / "task.jsonl"
        transcript.write_text(json.dumps({"type": "user", "message": "refactor compiler and fix fatal error"}))
        rec = self.agent.analyze_task(str(transcript), "codex")
        self.assertEqual(rec["model"], "gpt-6.1-sol")
        self.assertEqual(rec["effort"], "high")

    def test_service_definition_includes_path_and_network_target(self):
        with patch.object(self.installer.sys, 'platform', 'linux'):
            self.installer.write_service()
            content = self.installer.service_path().read_text()
            self.assertIn('After=network.target', content)
            self.assertIn('Environment="PATH=', content)
            self.assertIn('.local/bin', content)
        with patch.object(self.installer.sys, 'platform', 'darwin'):
            self.installer.write_service()
            import plistlib
            plist = plistlib.loads(self.installer.service_path().read_bytes())
            self.assertIn('PATH', plist['EnvironmentVariables'])
            self.assertIn('.local/bin', plist['EnvironmentVariables']['PATH'])

    def test_background_provider_pulse_retries_and_preserves_providers_on_error(self):
        state_dir = self.home / '.local/state/msam-host-agent'
        state_dir.mkdir(parents=True, exist_ok=True)
        providers_file = state_dir / 'providers.json'
        error_file = state_dir / 'providers-error.json'

        # Seed valid existing providers
        initial_telemetry = {'providers': {'codex': {'state': 'HEALTHY', 'used_percent': 25.0}}, 'terminal_agents': []}
        self.agent.atomic_json(providers_file, initial_telemetry)

        mock_pulse = unittest.mock.MagicMock()
        mock_pulse.collect_provider_telemetry.side_effect = RuntimeError("network unreachable at boot")

        with patch.object(self.agent, 'load_pulse', return_value=mock_pulse), \
             patch.object(self.agent.STOP, 'is_set', side_effect=[False, True]), \
             patch.object(self.agent.STOP, 'wait'):
            self.agent.background_provider_pulse()

        # Existing providers.json must NOT be overwritten with empty providers
        cached = json.loads(providers_file.read_text())
        self.assertEqual(cached['providers']['codex']['used_percent'], 25.0)
        # providers-error.json must record the error
        self.assertTrue(error_file.exists())
        err_data = json.loads(error_file.read_text())
        self.assertIn("network unreachable at boot", err_data['error'])

    def test_http_metrics_report_endpoint(self):
        import http.server
        import urllib.request
        import urllib.error

        # Create temporary metrics DB with sample data
        metrics_mod = module('msam-metrics.py')
        db_path = self.home / '.local/state/msam/metrics-history.db'
        db = metrics_mod.MetricsHistoryDB(db_path=db_path)
        now = time.time()
        db.record_sample(
            timestamp=now - 100,
            cpu_util=25.0, cpu_temp=45.0, cpu_watts=30.0,
            mem_used_gb=8.0, mem_total_gb=16.0,
            gpu_util=15.0, gpu_temp=50.0, gpu_watts=20.0,
            net_down_kbps=100.0, net_up_kbps=20.0,
            system_watts=50.0, power_source='rapl+nvml'
        )
        db.record_sample(
            timestamp=now,
            cpu_util=35.0, cpu_temp=55.0, cpu_watts=40.0,
            mem_used_gb=10.0, mem_total_gb=16.0,
            gpu_util=25.0, gpu_temp=60.0, gpu_watts=30.0,
            net_down_kbps=200.0, net_up_kbps=40.0,
            system_watts=70.0, power_source='rapl+nvml'
        )
        db.close()

        handler_class = self.agent.RequestHandler
        server = http.server.HTTPServer(('127.0.0.1', 0), handler_class)
        server.db_path = db_path
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        port = server.server_port
        base_url = f"http://127.0.0.1:{port}"

        try:
            # 1. Successful GET /api/metrics/report?period=24h
            url = f"{base_url}/api/metrics/report?period=24h"
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=5) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get_content_type(), 'application/json')
                data = json.loads(resp.read().decode('utf-8'))
                self.assertIn('period', data)
                self.assertIn('power', data)
                self.assertEqual(data['period']['sample_count'], 2)

            # 2. GET /api/metrics/report with cost_per_kwh and period=1h
            url = f"{base_url}/api/metrics/report?period=1h&cost_per_kwh=0.20"
            with urllib.request.urlopen(url, timeout=5) as resp:
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode('utf-8'))
                self.assertIsNotNone(data['power']['cost'])

            # 3. Invalid period parameter handling -> 400 Bad Request
            url_invalid = f"{base_url}/api/metrics/report?period=invalid_period_xyz"
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(url_invalid, timeout=5)
            self.assertEqual(ctx.exception.code, 400)
            err_body = json.loads(ctx.exception.read().decode('utf-8'))
            ctx.exception.close()
            self.assertIn('error', err_body)

            # 4. Unknown route -> 404 Not Found
            url_404 = f"{base_url}/api/unknown"
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(url_404, timeout=5)
            self.assertEqual(ctx.exception.code, 404)
            ctx.exception.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_host_agent_report_cli(self):
        import io
        metrics_mod = module('msam-metrics.py')
        db_path = self.home / '.local/state/msam/metrics-history-cli.db'
        db = metrics_mod.MetricsHistoryDB(db_path=db_path)
        now = time.time()
        db.record_sample(
            timestamp=now - 60,
            cpu_util=15.0, cpu_temp=45.0, cpu_watts=30.0,
            mem_used_gb=8.0, mem_total_gb=32.0,
            gpu_util=20.0, gpu_temp=50.0, gpu_watts=40.0,
            net_down_kbps=1024.0, net_up_kbps=512.0,
            system_watts=70.0, power_source='rapl+nvml'
        )
        db.close()

        with patch.object(sys, 'argv', ['msam-host-agent.py', '--home', str(self.home), 'report', '--format', 'json', '--db', str(db_path)]):
            with patch('sys.stdout', new_callable=io.StringIO) as mock_stdout:
                self.agent.main()
                output = mock_stdout.getvalue()
                data = json.loads(output)
                self.assertIn('period', data)
                self.assertIn('cpu', data)
                self.assertIn('power', data)
                self.assertEqual(data['power']['max_watts'], 70.0)

    def test_host_agent_monitor_cli_dispatches(self):
        metrics_mod = module('msam-metrics.py')
        with patch.object(self.agent, 'load_module', return_value=metrics_mod):
            with patch.object(metrics_mod, 'run_monitor_cli', return_value=0) as mock_monitor:
                with patch.object(sys, 'argv', ['msam-host-agent.py', '--home', str(self.home), 'monitor', '--oneshot']):
                    self.agent.main()
                    mock_monitor.assert_called_once_with(['--oneshot'])


class AttentionTests(unittest.TestCase):
    """What on a host is waiting for its user, for the app's pill on the host tab."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.agent = module('msam-host-agent.py')
        self.agent.HOME = self.home
        self.agent.STATE = self.home / '.local/state/msam-host-agent'
        self.agent.STATE.mkdir(parents=True)

    def pane(self, status, pane='w1:p1', name='build fixer', kind='claude', **extra):
        return dict({'agent': kind, 'agent_status': status, 'pane_id': pane, 'name': name}, **extra)

    def record(self, sessions, age=0, providers=None, error=None):
        state = {'at': time.time() - age, 'sessions': sessions}
        if error:
            state['error'] = error
        self.agent.atomic_json(self.agent.STATE / 'agents.json', state)
        if providers is not None:
            self.agent.atomic_json(self.agent.STATE / 'providers.json', {'providers': providers})

    def test_a_blocked_agent_and_a_finished_one_are_reported_apart(self):
        self.record([{'session': 'default', 'agents': [
            self.pane('blocked', 'w1:p1', 'needs an answer'), self.pane('done', 'w1:p2', 'finished', 'codex'),
            self.pane('working', 'w1:p3'), self.pane('idle', 'w1:p4'), self.pane('unknown', 'w1:p5')]}])
        summary = self.agent.attention()
        self.assertEqual(summary['blocked'], [
            {'session': 'default', 'pane_id': 'w1:p1', 'name': 'needs an answer', 'agent': 'claude'}])
        self.assertEqual(summary['done'], [
            {'session': 'default', 'pane_id': 'w1:p2', 'name': 'finished', 'agent': 'codex'}])
        self.assertEqual(summary['rate_limited'], [])
        self.assertTrue(summary['available'])

    def test_every_herdr_session_on_the_host_counts(self):
        self.record([{'session': 'default', 'agents': [self.pane('blocked', 'a:p1')]},
                     {'session': 'desktop', 'agents': [self.pane('blocked', 'b:p1'), self.pane('done', 'b:p2')]}])
        summary = self.agent.attention()
        self.assertEqual([(item['session'], item['pane_id']) for item in summary['blocked']],
                         [('default', 'a:p1'), ('desktop', 'b:p1')])
        self.assertEqual([item['session'] for item in summary['done']], ['desktop'])

    def test_a_rate_limited_provider_is_named(self):
        self.record([], providers={'codex': {'state': 'RATE_LIMITED'}, 'claude_code': {'state': 'HEALTHY'},
                                   'antigravity': {'state': 'RATE_LIMITED'}, 'broken': 'not a mapping'})
        self.assertEqual(self.agent.attention()['rate_limited'], ['antigravity', 'codex'])

    def test_an_agent_without_a_name_is_called_by_its_title_then_its_kind(self):
        self.record([{'session': 'default', 'agents': [
            self.pane('blocked', 'w:p1', name='', terminal_title_stripped='Refactor the parser'),
            self.pane('blocked', 'w:p2', name=None, kind='codex'),
            self.pane('blocked', 'w:p3', name=None, kind=None)]}])
        self.assertEqual([item['name'] for item in self.agent.attention()['blocked']],
                         ['Refactor the parser', 'codex', 'w:p3'])

    def test_long_names_and_long_lists_are_cut_but_still_counted(self):
        self.record([{'session': 'default', 'agents': [
            self.pane('blocked', 'w:p%d' % index, name='x' * 300) for index in range(60)]}])
        summary = self.agent.attention()
        self.assertEqual(len(summary['blocked']), self.agent.ATTENTION_LIMIT)
        self.assertEqual(summary['blocked_count'], 60)
        self.assertLessEqual(len(summary['blocked'][0]['name']), 80)

    def test_nothing_is_claimed_when_the_inventory_is_old_missing_or_failed(self):
        blocked = [{'session': 'default', 'agents': [self.pane('blocked')]}]
        for label, setup in [
            ('missing', lambda: None),
            ('old', lambda: self.record(blocked, age=120)),
            ('failed', lambda: self.record(blocked, error='herdr is not installed')),
        ]:
            with self.subTest(label):
                (self.agent.STATE / 'agents.json').unlink(missing_ok=True)
                setup()
                summary = self.agent.attention()
                self.assertFalse(summary['available'])
                self.assertEqual(summary['blocked'], [])
                self.assertEqual(summary['blocked_count'], 0)

    def test_the_inventory_polls_agents_often_and_sessions_less_often(self):
        calls = []

        def run(args, **kwargs):
            calls.append(args[1:3])
            if args[1:3] == ['session', 'list']:
                payload = {'sessions': [{'name': 'default', 'running': True, 'socket_path': '/tmp/one.sock'},
                                        {'name': 'stopped', 'running': False, 'socket_path': '/tmp/two.sock'}]}
            else:
                payload = {'result': {'agents': [self.pane('blocked')]}}
            return subprocess.CompletedProcess(args, 0, stdout=json.dumps(payload).encode())

        waits = []

        def wait(seconds):
            waits.append(seconds)
            if len(waits) >= 3:
                self.agent.STOP.set()

        self.addCleanup(self.agent.STOP.clear)
        with patch.object(self.agent.subprocess, 'run', side_effect=run), \
             patch.object(self.agent.STOP, 'wait', side_effect=wait):
            self.agent.background_inventory()

        self.assertEqual(waits, [self.agent.INVENTORY_INTERVAL] * 3)
        self.assertLessEqual(self.agent.INVENTORY_INTERVAL, 5, 'A blocked agent should show within seconds')
        self.assertEqual(calls.count(['session', 'list']), 1, 'The session list is not re-read on every poll')
        self.assertEqual(calls.count(['agent', 'list']), 3)
        saved = self.agent.read_json(self.agent.STATE / 'agents.json')
        self.assertEqual([session['session'] for session in saved['sessions']], ['default'])
        self.assertEqual(self.agent.attention()['blocked_count'], 1)

    def test_a_session_that_went_away_does_not_blind_the_others(self):
        def run(args, env=None, **kwargs):
            if args[1:3] == ['session', 'list']:
                payload = {'sessions': [{'name': 'gone', 'running': True, 'socket_path': '/tmp/gone.sock'},
                                        {'name': 'default', 'running': True, 'socket_path': '/tmp/ok.sock'}]}
                return subprocess.CompletedProcess(args, 0, stdout=json.dumps(payload).encode())
            if env['HERDR_SOCKET_PATH'] == '/tmp/gone.sock':
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, stdout=json.dumps(
                {'result': {'agents': [self.pane('done')]}}).encode())

        with patch.object(self.agent.subprocess, 'run', side_effect=run):
            sessions = self.agent.session_agents(self.agent.running_sessions())
        self.assertEqual([session['session'] for session in sessions], ['default'])

    def test_the_notification_stream_prints_a_line_only_when_something_changes(self):
        self.agent.atomic_json(self.agent.STATE / 'status.json', {'heartbeat': time.time()})
        self.record([{'session': 'default', 'agents': [self.pane('working')]}])
        steps = [
            lambda: None,                                                            # nothing new
            lambda: self.record([{'session': 'default', 'agents': [self.pane('blocked')]}]),
            lambda: None,
        ]
        printed = []

        def sleep(_):
            if not steps:
                raise KeyboardInterrupt
            steps.pop(0)()

        with patch.object(self.agent.time, 'sleep', side_effect=sleep), \
             patch('builtins.print', side_effect=lambda *args, **kwargs: printed.append(args[0])):
            with self.assertRaises(KeyboardInterrupt):
                self.agent.stream_attention(loop=True)

        self.assertEqual(len(printed), 2, printed)
        self.assertTrue(all(line.startswith('MSAM_ATTENTION=') for line in printed))
        first, second = (json.loads(line.split('=', 1)[1]) for line in printed)
        self.assertEqual(first['blocked_count'], 0)
        self.assertEqual(second['blocked_count'], 1)

    def test_the_notification_stream_repeats_itself_as_a_heartbeat(self):
        self.record([])
        clock = [1000.0]
        printed = []

        def sleep(seconds):
            clock[0] += 6
            self.record([])                       # keep the inventory fresh on the fake clock
            if clock[0] > 1000 + 40:
                raise KeyboardInterrupt

        with patch.object(self.agent.time, 'sleep', side_effect=sleep), \
             patch.object(self.agent.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch('builtins.print', side_effect=lambda *args, **kwargs: printed.append(args[0])):
            with self.assertRaises(KeyboardInterrupt):
                self.agent.stream_attention(loop=True)
        self.assertGreaterEqual(len(printed), 3, 'An unchanged summary is still repeated so the app knows the stream is alive')

    def test_one_reading_is_available_without_a_stream(self):
        self.record([{'session': 'default', 'agents': [self.pane('done')]}])
        printed = []
        with patch('builtins.print', side_effect=lambda *args, **kwargs: printed.append(args[0])):
            self.agent.stream_attention(loop=False)
        self.assertEqual(json.loads(printed[0].split('=', 1)[1])['done_count'], 1)
        self.assertEqual(len(printed), 1)


class WindowsUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.worker = module('msam-agent-updater-windows.py')
        self.batch = '12345678-1234-1234-1234-123456789012'
        self.text = 'MSAM_AGENT_UPDATE_REQUEST\t1\nBATCH\t' + self.batch + '\nPOLICY\tmanualApproval\nTARGET\tsession\tC:/Users/test/pipe\t%1\t42\tcodex\tconversation\nEND\n'

    def test_windows_request_and_unknown_tools(self):
        batch = self.worker.request(self.text, self.batch)
        self.assertEqual(batch['targets'][0]['conversation'], 'conversation')
        with self.assertRaises(ValueError):
            self.worker.request(self.text.replace('\tcodex\t', '\tunknown\t'), self.batch)

    def test_working_or_identity_changed_agent_is_never_exited(self):
        batch = self.worker.request(self.text, self.batch)
        target = batch['targets'][0]
        agent = {'agent_status': 'working', 'agent_session': {'agent': 'codex', 'value': 'conversation'}}
        with patch.object(self.worker, 'snapshot', return_value=(agent, '42')), patch.object(self.worker, 'command') as command:
            self.worker.roll(target, batch)
            command.assert_not_called()
        agent['agent_status'] = 'idle'; agent['agent_session']['value'] = 'different'
        with patch.object(self.worker, 'snapshot', return_value=(agent, '42')), patch.object(self.worker, 'command') as command:
            self.worker.roll(target, batch)
            command.assert_not_called()
        self.assertEqual(target['phase'], 'failed')

    def test_unknown_agent_state_does_not_trigger_a_restore(self):
        target = self.worker.request(self.text, self.batch)['targets'][0]
        with patch.object(self.worker, 'command', side_effect=subprocess.TimeoutExpired('herdr', 30)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.worker.snapshot(target)

    def test_successful_empty_inventory_allows_restore_after_agent_exit(self):
        target = self.worker.request(self.text, self.batch)['targets'][0]
        replies = ['{"result":{"agents":[]}}', '{"result":{"process_info":{"shell_pid":88}}}']
        with patch.object(self.worker, 'command', side_effect=replies) as command:
            self.assertEqual(self.worker.snapshot(target), (None, '88'))
            self.assertEqual(command.call_count, 2)
        for invalid in ('{}', '{"result":{"agents":{}}}'):
            with patch.object(self.worker, 'command', return_value=invalid):
                with self.assertRaises((ValueError, KeyError)):
                    self.worker.snapshot(target)

    def test_same_or_older_version_never_updates(self):
        before = {'method': 'npm', 'installed': '1.2.3', 'latest': '1.2.3'}
        with patch.object(self.worker, 'probe', return_value=before), patch.object(self.worker, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'No newer'):
                self.worker.update_tool('codex')
            command.assert_not_called()

    def test_restore_uses_a_valid_lowercase_herdr_agent_name(self):
        batch = self.worker.request(self.text, self.batch)
        batch['id'] = 'ABCDEFAB-1234-1234-1234-123456789012'
        target = batch['targets'][0]
        target['phase'] = 'exited'
        restored = {'agent_session': {'agent': 'codex', 'value': 'conversation'}}
        with patch.object(self.worker, 'snapshot', side_effect=[(None, '88'), (restored, '99')]), \
                patch.object(self.worker, 'save'), patch.object(self.worker, 'command') as command:
            self.worker.roll(target, batch)
        self.assertEqual(command.call_args.args[0][3], 'msam_abcdefab_0')
        self.assertEqual(target['phase'], 'restored')

    def test_codex_foreground_restore_supports_old_and_new_versions(self):
        with patch.object(self.worker, 'command', return_value='Options: --no-daemon'):
            self.assertEqual(self.worker.resume_arguments('codex', 'id'), ['--no-daemon', 'resume', 'id'])
        with patch.object(self.worker, 'command', return_value='Older CLI help'):
            self.assertEqual(self.worker.resume_arguments('codex', 'id'), ['resume', 'id'])

    def test_restored_process_waiting_for_sign_in_is_not_restarted(self):
        batch = self.worker.request(self.text, self.batch)
        target = batch['targets'][0]
        target.update(phase='exited', attempts=1, restoreStartedAt=time.time())
        agent = {'agent': 'codex', 'launch_pending': True}
        with patch.object(self.worker, 'snapshot', return_value=(agent, '99')), patch.object(self.worker, 'command') as command:
            self.worker.roll(target, batch)
            self.assertEqual(target['message'], 'attention_waiting_for_native_session')
            target['restoreStartedAt'] -= 340
            self.worker.roll(target, batch)
            self.assertEqual(target['phase'], 'failed')
            self.assertIn('sign_in', target['message'])
            command.assert_not_called()


class FakeWindows:
    """Answers `sc.exe`, `whoami` and the service query the way Windows does."""

    def __init__(self, service_account=None):
        self.service_account = service_account
        self.calls = []

    def __call__(self, args, **kwargs):
        args = [str(arg) for arg in args]
        self.calls.append(args)
        code, out, err = 0, '', ''
        tool = Path(args[0]).name.lower()
        if tool == 'sc.exe':
            verb = args[1].lower()
            if verb == 'create':
                self.service_account = args[args.index('obj=') + 1]
            elif self.service_account is None:
                code, out = 1060, '[SC] OpenService FAILED 1060'
            elif verb == 'delete':
                self.service_account = None
        elif tool == 'powershell.exe':
            if self.service_account is not None:
                out = json.dumps({'StartName': self.service_account})
        elif tool == 'whoami':
            out = '"host\\alice","S-1-5-21-1-2-3-1001"\n' if '/user' in args else 'host\\alice\n'
        if kwargs.get('check') and code:
            raise subprocess.CalledProcessError(code, args, out, err)
        return subprocess.CompletedProcess(args, code, out, err)

    def ran(self, *prefix):
        return [call for call in self.calls if [part.lower() for part in call[:len(prefix)]] == [part.lower() for part in prefix]]

    @staticmethod
    def setting(call, name):
        return call[call.index(name) + 1]


class WindowsServiceTests(unittest.TestCase):
    """The host agent on Windows is a service that runs as SYSTEM. Windows asks
    for no password for that account, so the app can set the service up itself."""

    HOME = 'C:\\Users\\alice'
    ACCOUNT = {'USERPROFILE': 'C:\\Users\\alice', 'APPDATA': 'D:\\Roaming\\alice',
               'LOCALAPPDATA': 'C:\\Users\\alice\\AppData\\Local', 'HOMEDRIVE': 'C:', 'HOMEPATH': '\\Users\\alice',
               'USERNAME': 'alice', 'USERDOMAIN': 'HOST'}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = module('msam-host-service-windows.py')
        self.bridge.api = lambda: None
        self.bridge.is_administrator = lambda: True
        self.bridge.user_path = lambda: '%USERPROFILE%\\.cargo\\bin;C:\\Users\\alice\\tools'
        self.bridge.state_directory = lambda home: Path(self.temp.name)

    def configure(self, windows):
        with patch.object(self.bridge.subprocess, 'run', side_effect=windows), \
                patch.object(self.bridge.subprocess, 'check_output', side_effect=lambda args, **kw: windows(args, **kw).stdout), \
                patch.dict(self.bridge.os.environ, self.ACCOUNT), \
                patch.object(self.bridge.getpass, 'getpass', side_effect=AssertionError('no password may be asked for')):
            self.bridge.configure(self.HOME)

    def test_a_host_without_the_service_gets_one_that_runs_as_system_and_is_asked_for_nothing(self):
        windows = FakeWindows()
        self.configure(windows)
        create = windows.ran('sc.exe', 'create')[0]
        self.assertEqual(create[2], 'MSAMHostAgent')
        self.assertEqual(windows.setting(create, 'obj='), 'LocalSystem')
        self.assertEqual(windows.setting(create, 'start='), 'auto')
        command = windows.setting(create, 'binPath=')
        self.assertIn('msam-host-agent.py', command)
        self.assertTrue(command.endswith('--home C:\\Users\\alice windows-service'), command)
        self.assertNotIn('password=', [part.lower() for part in create])

    def test_the_service_comes_back_after_a_crash(self):
        windows = FakeWindows()
        self.configure(windows)
        failure = windows.ran('sc.exe', 'failure')[0]
        self.assertIn('restart', windows.setting(failure, 'actions='))

    def test_a_host_that_has_the_service_is_pointed_at_the_new_files(self):
        windows = FakeWindows(service_account='LocalSystem')
        self.configure(windows)
        self.assertFalse(windows.ran('sc.exe', 'create'))
        config = windows.ran('sc.exe', 'config')[0]
        self.assertTrue(windows.setting(config, 'binPath=').endswith('windows-service'))

    def test_a_service_an_earlier_build_put_under_the_account_stays_under_it(self):
        # Changing its account would throw away a password only its owner can give again.
        windows = FakeWindows(service_account='HOST\\alice')
        self.configure(windows)
        self.assertFalse(windows.ran('sc.exe', 'create'))
        config = windows.ran('sc.exe', 'config')[0]
        self.assertNotIn('obj=', config)

    def test_a_service_under_someone_elses_account_is_refused(self):
        windows = FakeWindows(service_account='HOST\\bob')
        with self.assertRaisesRegex(RuntimeError, 'host\\\\bob'):
            self.configure(windows)
        self.assertFalse(windows.ran('sc.exe', 'config'))

    def test_an_account_that_is_not_an_administrator_is_told_so_before_anything_is_tried(self):
        self.bridge.is_administrator = lambda: False
        windows = FakeWindows()
        with self.assertRaisesRegex(RuntimeError, '[Aa]dministrator'):
            self.configure(windows)
        self.assertFalse(windows.ran('sc.exe'))

    def test_the_account_is_written_down_for_the_service_to_work_in(self):
        self.configure(FakeWindows())
        account = json.loads((Path(self.temp.name) / 'account.json').read_text())
        self.assertEqual(account['sid'], 'S-1-5-21-1-2-3-1001')
        self.assertEqual(account['environment']['APPDATA'], 'D:\\Roaming\\alice')
        self.assertEqual(account['environment']['USERNAME'], 'alice')
        self.assertEqual(account['path'], '%USERPROFILE%\\.cargo\\bin;C:\\Users\\alice\\tools')

    def test_a_failure_is_reported_as_a_sentence_not_as_a_traceback(self):
        result = subprocess.run([sys.executable, str(RESOURCES / 'msam-host-service-windows.py'), 'configure', self.HOME],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('Traceback', result.stderr)
        self.assertIn('only available on Windows', result.stderr)


class SystemAccountTests(unittest.TestCase):
    """As SYSTEM the service has a profile of its own. Everything it does is for
    the account that owns the agents, so it works in that account's instead."""

    SYSTEM = {'USERPROFILE': 'C:\\WINDOWS\\system32\\config\\systemprofile',
              'APPDATA': 'C:\\WINDOWS\\system32\\config\\systemprofile\\AppData\\Roaming',
              'LOCALAPPDATA': 'C:\\WINDOWS\\system32\\config\\systemprofile\\AppData\\Local',
              'USERNAME': 'HOST$', 'TEMP': 'C:\\WINDOWS\\TEMP'}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.agent = module('msam-host-agent.py')
        self.agent.HOME = 'C:\\Users\\alice'
        self.agent.STATE = Path(self.temp.name)

    def record(self, **account):
        (self.agent.STATE / 'account.json').write_text(json.dumps(account))

    def test_the_service_takes_on_the_accounts_profile(self):
        self.record(sid='S-1-5-21-1-2-3-1001', environment={
            'USERPROFILE': 'C:\\Users\\alice', 'APPDATA': 'D:\\Roaming\\alice',
            'LOCALAPPDATA': 'C:\\Users\\alice\\AppData\\Local', 'HOMEDRIVE': 'C:', 'HOMEPATH': '\\Users\\alice',
            'USERNAME': 'alice', 'USERDOMAIN': 'HOST'})
        with patch.dict(self.agent.os.environ, self.SYSTEM):
            self.agent.adopt_account()
            adopted = dict(self.agent.os.environ)
        self.assertEqual(adopted['USERPROFILE'], 'C:\\Users\\alice')
        # npm installs the agents' tools under APPDATA: in SYSTEM's they would be nobody's.
        self.assertEqual(adopted['APPDATA'], 'D:\\Roaming\\alice')
        self.assertEqual(adopted['LOCALAPPDATA'], 'C:\\Users\\alice\\AppData\\Local')
        self.assertEqual(adopted['USERNAME'], 'alice')
        self.assertEqual((adopted['HOMEDRIVE'], adopted['HOMEPATH']), ('C:', '\\Users\\alice'))

    def test_without_a_record_the_profile_is_worked_out_from_the_home(self):
        with patch.dict(self.agent.os.environ, self.SYSTEM):
            self.agent.adopt_account()
            adopted = dict(self.agent.os.environ)
        self.assertEqual(adopted['USERPROFILE'], 'C:\\Users\\alice')
        self.assertEqual(adopted['APPDATA'], 'C:\\Users\\alice\\AppData\\Roaming')
        self.assertEqual(adopted['LOCALAPPDATA'], 'C:\\Users\\alice\\AppData\\Local')
        self.assertEqual((adopted['HOMEDRIVE'], adopted['HOMEPATH']), ('C:', '\\Users\\alice'))

    def test_the_accounts_own_path_is_read_from_its_registry_when_that_is_loaded(self):
        self.record(sid='S-1-5-21-1-2-3-1001', path='C:\\old')
        with patch.object(self.agent, 'registry_path', side_effect=lambda sid: 'C:\\now' if sid == 'S-1-5-21-1-2-3-1001' else None):
            self.assertEqual(self.agent.account_path(), 'C:\\now')

    def test_the_path_written_down_at_setup_stands_in_while_the_account_is_logged_off(self):
        # An account's registry is only loaded while it is logged on.
        self.record(sid='S-1-5-21-1-2-3-1001', path='C:\\Users\\alice\\tools')
        with patch.object(self.agent, 'registry_path', return_value=None):
            self.assertEqual(self.agent.account_path(), 'C:\\Users\\alice\\tools')


class SetupDiagnosisTests(unittest.TestCase):
    """Setup runs on a host nobody is looking at. What went wrong has to reach
    the app in the one message it shows."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.installer = module('msam-host-agent-install.py')
        self.agent = module('msam-host-agent.py')
        for mod in (self.installer, self.agent):
            mod.HOME = self.home
            mod.STATE = self.home / '.local/state/msam-host-agent'
        self.installer.STATE.mkdir(parents=True)

    def test_a_refused_command_is_reported_with_what_it_said(self):
        # sc.exe explains itself on its standard output, not its error output.
        refused = subprocess.CalledProcessError(1053, ['sc.exe', 'start', 'MSAMHostAgent'],
                                                '[SC] StartService FAILED 1053:\n\nThe service did not respond in time.\n', '')
        said = self.installer.describe(refused)
        self.assertIn('FAILED 1053', said)
        self.assertIn('did not respond in time', said)

    def test_a_refused_command_that_said_nothing_is_still_named(self):
        said = self.installer.describe(subprocess.CalledProcessError(5, ['sc.exe', 'start', 'MSAMHostAgent'], '', ''))
        self.assertIn('sc.exe', said)
        self.assertIn('5', said)

    def test_an_agent_that_runs_without_metrics_says_why(self):
        status = {'running': True, 'metrics': False, 'error': 'powershell.exe was not found'}
        with patch.object(self.installer, 'get_status', return_value=status), patch.object(self.installer.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'did not become healthy.*powershell.exe was not found'):
                self.installer.wait_healthy()

    def test_an_agent_that_stopped_says_what_stopped_it(self):
        (self.installer.STATE / 'service-error.json').write_text(json.dumps({'message': 'No module named winreg'}))
        with patch.object(self.installer, 'get_status', return_value={'running': False}), patch.object(self.installer.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'did not become healthy.*No module named winreg'):
                self.installer.wait_healthy()

    def test_a_service_that_stops_leaves_a_note_of_why(self):
        # A Windows service has nowhere to print.
        self.agent.STOP = FakeStop(rounds=1)
        with patch.object(self.agent, 'serve', side_effect=RuntimeError('The host worker is already running.')):
            self.agent.serve_as_service()
        note = json.loads((self.agent.STATE / 'service-error.json').read_text())
        self.assertEqual(note['message'], 'The host worker is already running.')

    def test_a_status_caught_while_it_is_being_replaced_is_not_taken_for_a_stopped_service(self):
        # The app reinstalls a service it finds stopped. On Windows a status
        # read at the instant it is replaced is refused, which must not read
        # as "stopped".
        self.installer.BASE = self.home / '.local/libexec/msam-host-agent'
        current = self.installer.BASE / 'current'
        current.mkdir(parents=True)
        (current / 'msam-host-agent.py').write_text('')
        (self.installer.STATE / 'status.json').write_text(json.dumps({'heartbeat': time.time(), 'metrics': True}))
        real, refusals = Path.read_text, [REFUSED]

        def read(path, *args, **kwargs):
            if path.name == 'status.json' and refusals:
                raise refusals.pop()
            return real(path, *args, **kwargs)

        with patch.object(Path, 'read_text', read), patch.object(self.installer.time, 'sleep'):
            status = self.installer.get_status()
        self.assertTrue(status['running'])
        self.assertTrue(status['metrics'])

    def test_a_service_that_starts_takes_back_the_note_of_its_last_failure(self):
        (self.agent.STATE / 'service-error.json').write_text(json.dumps({'message': 'earlier'}))
        with patch.object(self.agent, 'serve'):
            self.agent.serve_as_service()
        self.assertFalse((self.agent.STATE / 'service-error.json').exists())


class FakeStop:
    """The service's stop signal, for a loop that should run a set number of
    rounds and never really wait."""

    def __init__(self, rounds):
        self.rounds, self.waits = rounds, 0

    def is_set(self):
        return self.waits >= self.rounds

    def wait(self, _timeout=None):
        self.waits += 1
        return self.is_set()

    def set(self):
        self.waits = self.rounds


REFUSED = PermissionError(13, 'Access is denied')


class SharedFileTests(unittest.TestCase):
    """The service and the app's streams meet in a handful of small files. On
    Windows a file cannot be replaced while another program has it open, and
    cannot always be opened while it is being replaced: each side has to give
    the other a moment."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.agent = module('msam-host-agent.py')
        self.path = Path(self.temp.name) / 'status.json'

    def test_a_file_a_reader_has_open_is_replaced_once_the_reader_lets_go(self):
        real, refusals = os.replace, [REFUSED] * 3

        def replace(source, target):
            if refusals:
                raise refusals.pop()
            real(source, target)

        with patch.object(self.agent.os, 'replace', side_effect=replace), patch.object(self.agent.time, 'sleep'):
            self.agent.atomic_json(self.path, {'heartbeat': 1})
        self.assertEqual(json.loads(self.path.read_text()), {'heartbeat': 1})
        self.assertEqual(refusals, [])

    def test_a_file_that_is_never_let_go_is_reported_and_leaves_nothing_behind(self):
        self.path.write_text('{"heartbeat": 1}')
        with patch.object(self.agent.os, 'replace', side_effect=REFUSED), patch.object(self.agent.time, 'sleep'):
            with self.assertRaises(PermissionError):
                self.agent.atomic_json(self.path, {'heartbeat': 2})
        self.assertEqual([entry.name for entry in self.path.parent.iterdir()], ['status.json'])
        self.assertEqual(json.loads(self.path.read_text()), {'heartbeat': 1})

    def test_a_file_caught_while_it_is_being_replaced_is_read_on_the_next_try(self):
        self.path.write_text('{"heartbeat": 7}')
        real, tries = Path.read_text, []

        def read(path, *args, **kwargs):
            tries.append(path)
            if len(tries) == 1:
                raise REFUSED
            return real(path, *args, **kwargs)

        with patch.object(Path, 'read_text', read), patch.object(self.agent.time, 'sleep'):
            self.assertEqual(self.agent.read_json(self.path, {}), {'heartbeat': 7})

    def test_a_file_that_is_not_there_is_not_waited_for(self):
        with patch.object(self.agent.time, 'sleep') as sleep:
            self.assertEqual(self.agent.read_json(self.path, {'none': True}), {'none': True})
        sleep.assert_not_called()


class ServiceLoopTests(unittest.TestCase):
    """What the service writes while it runs, and what it takes to stop it."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.agent = module('msam-host-agent.py')
        self.agent.HOME = Path(self.temp.name)
        self.agent.STATE = self.agent.HOME / '.local/state/msam-host-agent'
        self.agent.UPDATER_STATE = self.agent.HOME / '.local/state/msam-agent-updater'
        for name in ('background_updates', 'background_inventory', 'background_provider_pulse'):
            patcher = patch.object(self.agent, name, lambda: None)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(self.agent, 'load_module', return_value=object())
        patcher.start()
        self.addCleanup(patcher.stop)

    def serve(self, rounds, sample):
        self.agent.STOP = FakeStop(rounds)
        with patch.dict(os.environ), patch.object(self.agent, 'sample_metrics', side_effect=sample):
            self.agent.serve()

    def test_the_service_keeps_running_when_a_status_could_not_be_written(self):
        # The app's stream reads status.json twice a second. On Windows the
        # write that meets a read is refused; that used to end the service,
        # and Windows does not restart a service that stops by itself.
        real, refused, readings = self.agent.atomic_json, [], []

        def write(path, value):
            if path.name == 'status.json' and not refused:
                refused.append(path)
                raise REFUSED
            real(path, value)

        def sample(_module):
            readings.append(1)
            return {'cpu': {}}

        with patch.object(self.agent, 'atomic_json', side_effect=write):
            try:
                self.serve(rounds=3, sample=sample)
            except PermissionError as error:
                self.fail('The service stopped: ' + str(error))
        self.assertEqual(len(refused), 1)
        self.assertEqual(len(readings), 3)

    def test_a_slow_reading_does_not_make_the_service_look_stopped(self):
        # On Windows every reading starts a PowerShell, which takes seconds.
        # A status is "running" while its heartbeat is under 15 seconds old.
        clock, seen = [1_000.0], []

        def sample(_module):
            clock[0] += 9
            seen.append(self.agent.status()['running'])
            return {'cpu': {}}

        with patch.object(self.agent.time, 'time', side_effect=lambda: clock[0]):
            self.serve(rounds=3, sample=sample)
        self.assertEqual(seen, [True, True, True])

    def test_the_status_says_how_long_a_reading_takes(self):
        clock, statuses, real = [50.0], [], self.agent.atomic_json

        def sample(_module):
            clock[0] += 9
            return {'cpu': {}}

        def write(path, value):
            if path.name == 'status.json':
                statuses.append(dict(value))
            real(path, value)

        with patch.object(self.agent.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(self.agent, 'atomic_json', side_effect=write):
            self.serve(rounds=2, sample=sample)
        self.assertIn(9.0, [status.get('sampleSeconds') for status in statuses])

    def test_a_reading_that_failed_is_still_said_while_the_next_one_is_taken(self):
        statuses, real, outcomes = [], self.agent.atomic_json, [RuntimeError('powershell.exe timed out'), {'cpu': {}}]

        def sample(_module):
            outcome = outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        def write(path, value):
            if path.name == 'status.json':
                statuses.append(dict(value))
            real(path, value)

        with patch.object(self.agent, 'atomic_json', side_effect=write):
            self.serve(rounds=2, sample=sample)
        # after the failed reading, and again before the second one is back
        failed = [status for status in statuses if status.get('error') == 'powershell.exe timed out']
        self.assertGreaterEqual(len(failed), 2, statuses)
        self.assertTrue(all(status['metrics'] is False for status in failed))
        self.assertTrue(any(status['metrics'] is True and 'error' not in status for status in statuses))

    def test_a_service_that_falls_over_notes_why_and_starts_again(self):
        self.agent.STATE.mkdir(parents=True)
        self.agent.STOP = FakeStop(rounds=10)
        with patch.object(self.agent, 'serve', side_effect=[RuntimeError('the disk is full'), None]) as serve:
            self.agent.serve_as_service()
        self.assertEqual(serve.call_count, 2)
        note = json.loads((self.agent.STATE / 'service-error.json').read_text())
        self.assertEqual(note['message'], 'the disk is full')

    def test_a_service_told_to_stop_does_not_start_again(self):
        self.agent.STATE.mkdir(parents=True)
        self.agent.STOP = FakeStop(rounds=1)
        with patch.object(self.agent, 'serve', side_effect=RuntimeError('the disk is full')) as serve:
            self.agent.serve_as_service()
        self.assertEqual(serve.call_count, 1)


class MetricsStreamTests(unittest.TestCase):
    """The app shows the last reading it was sent and nothing else, so a stream
    that ends is a display that has stopped. It must not end over a moment."""

    HEALTHY = {'running': True, 'metrics': True}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.agent = module('msam-host-agent.py')
        self.agent.STATE = Path(self.temp.name)
        self.readings = 0
        self.reading()

    def reading(self):
        self.readings += 1
        path = self.agent.STATE / 'metrics.json'
        path.write_text(json.dumps({'reading': self.readings}) + '\n')
        os.utime(path, ns=(self.readings * 10**9, self.readings * 10**9))

    def stream(self, answers, loop=True):
        """Runs the stream against one status per look; a fresh reading lands
        between looks. Returns what was printed and what ended the stream."""
        answers, clock, printed = list(answers), [0.0], []

        def status():
            if not answers:
                raise KeyboardInterrupt
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return dict(answer)

        def sleep(seconds):
            clock[0] += seconds
            self.reading()

        with patch.object(self.agent, 'status', side_effect=status), \
             patch.object(self.agent.time, 'sleep', side_effect=sleep), \
             patch.object(self.agent.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch('builtins.print', side_effect=lambda *args, **kwargs: printed.append(json.loads(args[0]))):
            try:
                self.agent.stream_metrics(loop)
            except (KeyboardInterrupt, RuntimeError) as error:
                return printed, error
        return printed, None

    def test_each_new_reading_is_printed_once(self):
        printed, ended = self.stream([self.HEALTHY] * 3)
        self.assertEqual(printed, [{'reading': 1}, {'reading': 2}, {'reading': 3}])
        self.assertIsInstance(ended, KeyboardInterrupt)

    def test_the_stream_rides_out_a_moment_when_the_service_looks_stopped(self):
        # The app replacing the service, or a status read while being written.
        printed, ended = self.stream([self.HEALTHY, {'running': False}, {'running': False}, self.HEALTHY])
        self.assertIsInstance(ended, KeyboardInterrupt, ended)
        self.assertEqual(printed[0], {'reading': 1})
        self.assertEqual(printed[-1], {'reading': 4})

    def test_the_stream_rides_out_a_reading_that_failed(self):
        failed = {'running': True, 'metrics': False, 'error': 'powershell.exe timed out'}
        printed, ended = self.stream([self.HEALTHY, failed, self.HEALTHY])
        self.assertIsInstance(ended, KeyboardInterrupt, ended)
        self.assertEqual(printed[-1], {'reading': 3})

    def test_the_stream_ends_when_the_service_stays_stopped(self):
        looks = int(self.agent.STREAM_PATIENCE / 0.5) + 5
        printed, ended = self.stream([self.HEALTHY] + [{'running': False}] * looks)
        self.assertIsInstance(ended, RuntimeError)
        self.assertIn('stopped', str(ended))
        self.assertEqual(printed, [{'reading': 1}])

    def test_the_stream_ends_with_the_reason_when_readings_keep_failing(self):
        failed = {'running': True, 'metrics': False, 'error': 'powershell.exe timed out'}
        looks = int(self.agent.STREAM_PATIENCE / 0.5) + 5
        _printed, ended = self.stream([failed] * looks)
        self.assertIsInstance(ended, RuntimeError)
        self.assertEqual(str(ended), 'powershell.exe timed out')

    def test_one_reading_without_a_stream_is_refused_at_once_when_the_service_is_stopped(self):
        printed, ended = self.stream([{'running': False}], loop=False)
        self.assertIsInstance(ended, RuntimeError)
        self.assertEqual(printed, [])

    def test_a_reading_that_cannot_be_opened_just_now_is_printed_on_the_next_look(self):
        real, refusals = Path.read_text, [REFUSED]

        def read(path, *args, **kwargs):
            if path.name == 'metrics.json' and refusals:
                raise refusals.pop()
            return real(path, *args, **kwargs)

        with patch.object(Path, 'read_text', read):
            printed, ended = self.stream([self.HEALTHY] * 3)
        self.assertIsInstance(ended, KeyboardInterrupt, ended)
        self.assertEqual(printed[-1], {'reading': 3})


if __name__ == '__main__':
    unittest.main()
