import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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
