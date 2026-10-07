import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-host-software.py'
spec = importlib.util.spec_from_file_location('software', SOURCE)
software = importlib.util.module_from_spec(spec)
spec.loader.exec_module(software)


class SoftwareTests(unittest.TestCase):
    def test_rust_plugin_prerequisites_are_checked_before_build(self):
        manifest = {'build': [{'command': ['cargo', 'build', '--release']}]}
        required = software.plugin_dependencies(manifest, {'Cargo.toml': '', 'Cargo.lock': 'openssl-sys'})
        for tool in ['git', 'cargo', 'rustc', 'cc', 'pkg-config', 'openssl-dev']:
            self.assertIn(tool, required)

    def test_platform_builds_do_not_install_foreign_tools(self):
        manifest = {'build': [{'platforms': ['windows'], 'command': ['windows-only-builder']},
                              {'platforms': ['linux'], 'command': ['npm', 'run', 'build']}]}
        with patch.object(software, 'SYSTEM', 'linux'):
            self.assertEqual(software.plugin_dependencies(manifest, {}), ['git', 'npm'])

    def test_missing_dependencies_installed_once_and_rechecked(self):
        with patch.object(software, 'has_tool', side_effect=[True, False, True]) as probe, \
             patch.object(software, 'package_install') as install:
            result = software.ensure_tools(['git', 'make', 'make'])
        install.assert_called_once_with('make')
        self.assertEqual(probe.call_count, 3)
        self.assertEqual(result[-1]['status'], 'installed')

    def test_dependency_install_without_a_working_tool_fails(self):
        with patch.object(software, 'has_tool', return_value=False), patch.object(software, 'package_install'):
            with self.assertRaisesRegex(RuntimeError, 'did not verify'):
                software.ensure_tools(['make'])

    def test_unknown_dependency_blocks_before_any_install(self):
        with patch.object(software, 'plugin_metadata', return_value=({'id': 'p', 'build': [{'command': ['unknown-tool']}]}, {}, 'a'*40)), \
             patch.object(software, 'ensure_tools') as install:
            with self.assertRaisesRegex(RuntimeError, 'unknown-tool'):
                software.prepare_plugin('owner/plugin')
            install.assert_not_called()

    def test_preflight_returns_exact_revision_and_plugin_identity(self):
        with patch.object(software, 'plugin_metadata', return_value=({'id': 'ferry'}, {}, 'a'*40)), \
             patch.object(software, 'ensure_tools', return_value=[{'tool': 'git', 'status': 'present'}]):
            result = software.prepare_plugin('owner/ferry', 'release')
        self.assertEqual(result['ref'], 'a'*40)
        self.assertEqual(result['pluginID'], 'ferry')

    def test_invalid_sources_and_refs_cannot_escape_repository(self):
        for source, ref in [('a/../b', None), ('a/b', '--upload-pack=evil'), ('a/b', '../secret'), ('a/$(id)', None)]:
            with self.assertRaises(ValueError):
                software.valid_source(source, ref)

    def test_healthy_cli_install_is_idempotent(self):
        status = {'id': 'codex', 'installed': True, 'version': '1.0', 'path': '/bin/codex'}
        with patch.object(software, 'agent_status', return_value=status), patch.object(software, 'installer_script') as install:
            self.assertEqual(software.install_agent('codex'), status)
            install.assert_not_called()

    def test_failed_version_probe_is_not_marked_installed(self):
        result = subprocess.CompletedProcess([], 1, stdout='broken 1.0.0')
        with patch.object(software, 'executable', return_value='/bin/codex'), patch.object(software, 'run', return_value=result):
            self.assertFalse(software.agent_status('codex')['installed'])

    def test_successful_installer_still_requires_version_verification(self):
        status = {'installed': False, 'path': None, 'error': None}
        with patch.object(software, 'agent_status', return_value=status), patch.object(software, 'ensure_tools'), \
             patch.object(software, 'installer_script'), patch.object(software, 'SYSTEM', 'linux'):
            with self.assertRaisesRegex(RuntimeError, 'did not verify'):
                software.install_agent('claude')

    def ferry(self, config):
        return software.keybinding_state(config, 'shadowfax.ferry', {'id': 'install-keybindings'})['state']

    def test_ferry_becomes_ready_only_after_correct_binding_exists(self):
        self.assertEqual(self.ferry({}), 'missing')
        binding = {'key': 'prefix+m', 'type': 'plugin_action', 'command': 'shadowfax.ferry.open'}
        config = {'keys': {'command': [binding]}}
        self.assertEqual(self.ferry(config), 'ready')
        config['keys']['command'] = []
        self.assertEqual(self.ferry(config), 'missing')

    def test_wrong_type_and_custom_or_builtin_key_conflicts_are_detected(self):
        for binding in [{'key': 'prefix+m', 'type': 'shell', 'command': 'shadowfax.ferry.open'},
                        {'key': 'prefix+m', 'type': 'plugin_action', 'command': 'another.plugin'}]:
            self.assertEqual(self.ferry({'keys': {'command': [binding]}}), 'conflict')
        self.assertEqual(self.ferry({'keys': {'new_tab': ['prefix+m']}}), 'conflict')

    def test_unknown_actions_are_unverified_not_actionable(self):
        result = software.keybinding_state({}, 'plugin', {'id': 'setup'})
        self.assertEqual(result['state'], 'unverified')

    def test_declared_checks_are_dynamic_for_other_plugins(self):
        action = {'id': 'setup', 'checks': [{'key': 'prefix+a', 'command': 'example.open'}]}
        config = {'keys': {'command': [{'key': 'prefix+a', 'type': 'plugin_action', 'command': 'example.open'}]}}
        self.assertEqual(software.keybinding_state({}, 'example', action)['state'], 'missing')
        self.assertEqual(software.keybinding_state(config, 'example', action)['state'], 'ready')

    def test_all_binding_conflicts_are_checked_before_offering_setup(self):
        action = {'id': 'setup', 'checks': [{'key': 'prefix+a', 'command': 'example.a'},
                                          {'key': 'prefix+b', 'command': 'example.b'}]}
        config = {'keys': {'command': [{'key': 'prefix+b', 'type': 'plugin_action', 'command': 'other'}]}}
        self.assertEqual(software.keybinding_state(config, 'example', action)['state'], 'conflict')

    def test_duplicate_bindings_are_not_marked_ready(self):
        binding = {'key': 'prefix+m', 'type': 'plugin_action', 'command': 'shadowfax.ferry.open'}
        self.assertEqual(self.ferry({'keys': {'command': [binding, binding]}}), 'conflict')

    def test_config_parse_does_not_treat_comments_as_installed_bindings(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.toml'
            path.write_text('# command = "shadowfax.ferry.open"\n# key = "prefix+m"\n')
            self.assertEqual(self.ferry(software.read_toml(path)), 'missing')
            path.write_text('keys = [invalid')
            with self.assertRaises(ValueError):
                software.read_toml(path)

    def test_configured_binding_with_missing_plugin_binary_is_unverified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / 'config.toml'
            config.write_text('[[keys.command]]\nkey="prefix+m"\ntype="plugin_action"\ncommand="shadowfax.ferry.open"\n')
            (root / 'herdr-plugin.toml').write_text('[[actions]]\nid="open"\ncommand=["./missing-ferry", "open"]\n')
            plugin = {'plugin_id': 'shadowfax.ferry', 'plugin_root': str(root), 'enabled': True,
                      'actions': [{'id': 'install-keybindings', 'title': 'Install Ferry keybinding'}]}
            with patch.dict(os.environ, {'HERDR_CONFIG_PATH': str(config)}), \
                 patch.object(software, 'herdr_json', return_value={'plugins': [plugin]}):
                status = software.plugin_setup_status()['plugins'][0]['actions'][0]
                self.assertEqual(status['state'], 'unverified')
                self.assertIn('executable', status['detail'])


if __name__ == '__main__':
    unittest.main()
