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
        with patch.object(self.installer.sys, 'platform', 'darwin'):
            self.installer.write_service()
            import plistlib
            plist = plistlib.loads(self.installer.service_path().read_bytes())
            self.assertEqual(plist['ProgramArguments'][-1], 'serve')
            self.assertEqual(plist['EnvironmentVariables']['MSAM_HOST_HOME'], str(self.home))

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


if __name__ == '__main__':
    unittest.main()
