#!/usr/bin/env python3
"""On-demand software provisioning and verified plugin setup for an SSH user.

No daemon restart is needed. Install recipes are owned by MSAM; repository
metadata can name dependencies but cannot supply package-manager commands.
"""
import argparse
import base64
import hashlib
import io
import importlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HOME_DIR = Path.home()
STATE = HOME_DIR / '.local/libexec/msam-host-software'
SYSTEM = {'Darwin': 'macos', 'Windows': 'windows', 'Linux': 'linux'}.get(platform.system(), 'unknown')
AGENTS = {
    'codex': ('codex', 'https://chatgpt.com/codex/install'),
    'claude': ('claude', 'https://claude.ai/install'),
    'antigravity': ('agy', 'https://antigravity.google/cli/install'),
}


def environment():
    env = os.environ.copy()
    paths = [HOME_DIR / '.local/bin', HOME_DIR / '.cargo/bin', HOME_DIR / '.herdr/bin',
             HOME_DIR / '.bun/bin', HOME_DIR / '.local/share/pnpm',
             Path('/opt/homebrew/bin'), Path('/usr/local/bin')]
    if SYSTEM == 'windows':
        paths += [HOME_DIR / 'AppData/Local/agy/bin', HOME_DIR / 'AppData/Roaming/npm',
                  Path('C:/Program Files/nodejs'), Path('C:/Program Files/Go/bin'),
                  Path('C:/Program Files/Git/cmd')]
    env['PATH'] = os.pathsep.join(map(str, paths)) + os.pathsep + env.get('PATH', '')
    env['GIT_TERMINAL_PROMPT'] = '0'
    env['GCM_INTERACTIVE'] = 'Never'
    return env


def executable(name):
    return shutil.which(name, path=environment()['PATH'])


def run(args, timeout=120, check=True):
    # cmd wrappers (npm, pnpm) need cmd.exe on Windows; all arguments are
    # app-owned tool/package names or validated repository identifiers.
    if SYSTEM == 'windows' and str(args[0]).lower().endswith(('.cmd', '.bat')):
        quoted = ' '.join("'" + str(value).replace("'", "''") + "'" for value in args)
        script = "$ErrorActionPreference='Stop'; & " + quoted + '; exit $LASTEXITCODE'
        args = ['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand',
                base64.b64encode(script.encode('utf-16le')).decode('ascii')]
    result = subprocess.run(args, env=environment(), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors='replace', timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(result.stdout[-4000:] or '{} exited {}'.format(args[0], result.returncode))
    return result


def download(url, limit=32 * 1024 * 1024):
    request = urllib.request.Request(url, headers={'User-Agent': 'MSAM-Host-Software/1.0'})
    with urllib.request.urlopen(request, timeout=45) as response:
        if urllib.parse.urlparse(response.url).scheme != 'https':
            raise RuntimeError('Refusing an insecure download redirect')
        data = response.read(limit + 1)
    if len(data) > limit:
        raise RuntimeError('Download exceeded its size limit')
    return data


def toml_module():
    try:
        import tomllib
        return tomllib
    except ImportError:
        pass
    deps = STATE / 'tomli-2.2.1'
    sys.path.insert(0, str(deps))
    try:
        import tomli
        return tomli
    except ImportError:
        # Apple Python 3.9 has no tomllib/pip. Bootstrap the small pure-Python
        # parser from its pinned PyPI wheel, checking the published SHA-256.
        info = json.loads(download('https://pypi.org/pypi/tomli/2.2.1/json'))
        wheel = next(x for x in info['urls'] if x['filename'].endswith('py3-none-any.whl'))
        if urllib.parse.urlparse(wheel['url']).hostname != 'files.pythonhosted.org':
            raise RuntimeError('Unexpected TOML parser download host')
        data = download(wheel['url'])
        if hashlib.sha256(data).hexdigest() != wheel['digests']['sha256']:
            raise RuntimeError('TOML parser checksum mismatch')
        STATE.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=str(STATE)) as tmp:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for name in archive.namelist():
                    if name.startswith('/') or '..' in Path(name).parts:
                        raise RuntimeError('Invalid TOML parser archive')
                archive.extractall(tmp)
            try:
                Path(tmp).rename(deps)
            except FileExistsError:
                pass
        importlib.invalidate_caches()
        import tomli
        return tomli


def read_toml(path):
    return toml_module().loads(path.read_text(encoding='utf-8')) if path.exists() else {}


def sudo_prefix():
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        return []
    if executable('sudo') and run(['sudo', '-n', 'true'], check=False).returncode == 0:
        return ['sudo', '-n']
    raise RuntimeError('Installing system dependencies needs administrator access on this host. '
                       'Run the displayed package command in a host terminal, then retry.')


PACKAGES = {
    'apt-get': {'cc': 'build-essential', 'pkg-config': 'pkg-config', 'openssl-dev': 'libssl-dev',
                'node': 'nodejs', 'npm': 'npm', 'go': 'golang-go', 'python3': 'python3'},
    'dnf': {'cc': 'gcc gcc-c++ make', 'pkg-config': 'pkgconf-pkg-config', 'openssl-dev': 'openssl-devel',
            'node': 'nodejs', 'npm': 'npm', 'go': 'golang', 'python3': 'python3'},
    'apk': {'cc': 'build-base', 'pkg-config': 'pkgconf', 'openssl-dev': 'openssl-dev',
            'node': 'nodejs', 'npm': 'npm', 'go': 'go', 'python3': 'python3'},
    'pacman': {'cc': 'base-devel', 'pkg-config': 'pkgconf', 'openssl-dev': 'openssl',
               'node': 'nodejs', 'npm': 'npm', 'go': 'go', 'python3': 'python'},
    'brew': {'cc': 'llvm', 'pkg-config': 'pkgconf', 'openssl-dev': 'openssl@3', 'npm': 'node'},
}
TOOLS = {'git', 'curl', 'bash', 'unzip', 'tar', 'cargo', 'rustc', 'cc', 'pkg-config',
         'openssl-dev', 'node', 'npm', 'go', 'make', 'cmake', 'pnpm', 'yarn', 'bun', 'zig', 'python3'}


def package_install(tool):
    if SYSTEM == 'windows':
        packages = {'git': 'Git.Git', 'node': 'OpenJS.NodeJS.LTS', 'npm': 'OpenJS.NodeJS.LTS',
                    'go': 'GoLang.Go', 'cmake': 'Kitware.CMake', 'cargo': 'Rustlang.Rustup',
                    'rustc': 'Rustlang.Rustup', 'cc': 'Microsoft.VisualStudio.2022.BuildTools'}
        package = packages.get(tool)
        if not package or not executable('winget'):
            raise RuntimeError('Install {} on this Windows host, then retry; no supported package installer is available.'.format(tool))
        args = ['winget', 'install', '--id', package, '--exact', '--silent',
                '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity']
        if tool == 'cc':
            args += ['--override', '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended']
        run(args, timeout=2400)
        return
    manager = 'brew' if SYSTEM == 'macos' else next((x for x in ['apt-get', 'dnf', 'apk', 'pacman'] if executable(x)), None)
    if not manager or not executable(manager):
        raise RuntimeError('Install {} using the host package manager, then retry.'.format(tool))
    packages = PACKAGES[manager].get(tool, tool).split()
    if manager == 'brew':
        run([executable('brew'), 'install'] + packages, timeout=1800)
    else:
        try:
            prefix = sudo_prefix()
        except RuntimeError as error:
            raise RuntimeError('{} Required packages: {}.'.format(error, ' '.join(packages)))
        if manager == 'apt-get':
            run(prefix + ['apt-get', 'update'], timeout=300)
            run(prefix + ['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y'] + packages, timeout=1200)
        else:
            flags = {'dnf': ['install', '-y'], 'apk': ['add'], 'pacman': ['-S', '--needed', '--noconfirm']}[manager]
            run(prefix + [manager] + flags + packages, timeout=1200)


def has_tool(tool):
    if tool == 'openssl-dev':
        return bool(executable('pkg-config') and run([executable('pkg-config'), '--exists', 'openssl'], check=False).returncode == 0)
    if tool == 'cc' and SYSTEM == 'windows':
        vswhere = Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        return vswhere.exists() and bool(run([str(vswhere), '-latest', '-products', '*', '-requires',
            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], check=False).stdout.strip())
    path = executable(tool)
    if not path:
        return False
    try:
        return run([path, 'version' if tool == 'go' else '--version'], timeout=20, check=False).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def installer_script(url, shell, args=()):
    data = download(url)
    if data.lstrip().lower().startswith((b'<!doctype html', b'<html')):
        raise RuntimeError('The download returned an HTML page instead of an installer')
    with tempfile.TemporaryDirectory(prefix='msam-install-') as tmp:
        target = Path(tmp) / ('install.ps1' if SYSTEM == 'windows' else 'install.sh')
        target.write_bytes(data)
        run(list(shell) + [str(target)] + list(args), timeout=1800)


def ensure_tools(tools):
    results = []
    for tool in dict.fromkeys(tools):
        if tool not in TOOLS:
            if executable(tool):
                results.append({'tool': tool, 'status': 'present'})
                continue
            raise RuntimeError('No supported automatic installer for dependency: ' + tool)
        present = has_tool(tool)
        if not present:
            print('Installing dependency: ' + tool, flush=True)
            if tool in ('cargo', 'rustc') and SYSTEM != 'windows':
                ensure_tools(['curl', 'cc'])
                installer_script('https://sh.rustup.rs', ['sh'], ['-y', '--profile', 'minimal', '--no-modify-path'])
            elif tool in ('pnpm', 'yarn'):
                ensure_tools(['node', 'npm'])
                run([executable('npm'), 'install', '--global', '--prefix', str(HOME_DIR / '.local'), tool], timeout=600)
            elif tool == 'bun' and SYSTEM != 'windows':
                ensure_tools(['bash', 'curl', 'unzip'])
                installer_script('https://bun.sh/install', ['bash'])
            else:
                package_install(tool)
            if not has_tool(tool):
                raise RuntimeError('{} was installed but its executable did not verify. Check the host PATH and retry.'.format(tool))
        results.append({'tool': tool, 'status': 'present' if present else 'installed'})
    return results


def agent_status(tool):
    name = AGENTS[tool][0]
    path = executable(name)
    if not path:
        return {'id': tool, 'installed': False, 'version': None, 'path': None, 'error': None}
    try:
        result = run([path, '--version'], timeout=30, check=False)
        version = re.search(r'\b\d+\.\d+(?:\.\d+)?(?:[-+][\w.-]+)?', result.stdout)
        if result.returncode == 0 and version:
            return {'id': tool, 'installed': True, 'version': version.group(), 'path': path, 'error': None}
        reason = result.stdout[-600:] or 'Version check failed'
    except (OSError, subprocess.TimeoutExpired) as error:
        reason = str(error)
    return {'id': tool, 'installed': False, 'version': None, 'path': path, 'error': reason}


def install_agent(tool):
    before = agent_status(tool)
    if before['installed']:
        return before
    if before['path']:
        raise RuntimeError('An existing {} installation failed verification at {}. Repair it before installing another copy. {}'.format(tool, before['path'], before['error']))
    if SYSTEM not in ('macos', 'linux', 'windows'):
        raise RuntimeError('Unsupported host platform: ' + SYSTEM)
    base = AGENTS[tool][1]
    if SYSTEM == 'windows':
        installer_script(base + '.ps1', ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File'])
    else:
        ensure_tools(['curl', 'bash', 'tar'])
        installer_script(base + '.sh', ['sh' if tool == 'codex' else 'bash'],
                         ['--skip-aliases'] if tool == 'antigravity' else [])
    after = agent_status(tool)
    if not after['installed']:
        raise RuntimeError('Installer finished but {} --version did not verify. {}'.format(AGENTS[tool][0], after['error'] or 'Executable not found.'))
    return after


def valid_source(source, ref):
    parts = source.split('/')
    if len(parts) not in (2, 3) or any(not re.fullmatch(r'[A-Za-z0-9_.-]+', p) or p in ('.', '..') for p in parts):
        raise ValueError('Invalid plugin repository')
    if ref and (not re.fullmatch(r'[A-Za-z0-9_./-]{1,100}', ref) or ref.startswith('-') or '..' in ref.split('/')):
        raise ValueError('Invalid plugin ref')


def github_metadata(source, ref=None):
    valid_source(source, ref)
    parts = source.split('/')
    repository = '/'.join(parts[:2])
    api = 'https://api.github.com/repos/' + repository
    if not ref:
        ref = json.loads(download(api))['default_branch']
    commit = json.loads(download(api + '/commits/' + urllib.parse.quote(ref, safe='')))['sha']
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise RuntimeError('GitHub returned an invalid commit')
    base = 'https://raw.githubusercontent.com/' + repository + '/' + commit + '/' + (parts[2] + '/' if len(parts) == 3 else '')
    manifest = toml_module().loads(download(base + 'herdr-plugin.toml').decode('utf-8'))
    if SYSTEM not in manifest.get('platforms', ['linux', 'macos', 'windows']):
        raise RuntimeError('{} does not support {}.'.format(manifest.get('name', source), SYSTEM))
    files = {}
    for name in ['Cargo.toml', 'Cargo.lock', 'package.json', 'go.mod']:
        try:
            files[name] = download(base + name).decode('utf-8')
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    return manifest, files, commit


def plugin_metadata(source, ref=None):
    valid_source(source, ref)
    try:
        return github_metadata(source, ref)
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403, 404, 429):
            raise
    # Reuse host Git credentials for private repositories and API rate limits.
    # A bare checkout reads metadata without running repository build scripts.
    ensure_tools(['git'])
    parts = source.split('/')
    url = 'https://github.com/' + '/'.join(parts[:2]) + '.git'
    prefix = parts[2] + '/' if len(parts) == 3 else ''
    with tempfile.TemporaryDirectory(prefix='msam-plugin-check-') as tmp:
        git = [executable('git'), '-C', tmp]
        run(git + ['init', '--bare', '--quiet'])
        run(git + ['-c', 'core.hooksPath=', 'fetch', '--depth=1', '--quiet', url, ref or 'HEAD'], timeout=300)
        commit = run(git + ['rev-parse', 'FETCH_HEAD']).stdout.strip()
        manifest = toml_module().loads(run(git + ['show', commit + ':' + prefix + 'herdr-plugin.toml']).stdout)
        if SYSTEM not in manifest.get('platforms', ['linux', 'macos', 'windows']):
            raise RuntimeError('{} does not support {}.'.format(manifest.get('name', source), SYSTEM))
        files = {}
        for name in ['Cargo.toml', 'Cargo.lock', 'package.json', 'go.mod']:
            result = run(git + ['show', commit + ':' + prefix + name], check=False)
            if result.returncode == 0:
                files[name] = result.stdout
        return manifest, files, commit


def plugin_dependencies(manifest, files):
    required = ['git']
    aliases = {'python': 'python3', '/bin/sh': None, 'sh': None, 'powershell': None,
               'powershell.exe': None, 'pwsh': None, 'cmd': None, 'cmd.exe': None}
    for item in manifest.get('build', []) + manifest.get('startup', []) + manifest.get('actions', []):
        if SYSTEM not in item.get('platforms', [SYSTEM]):
            continue
        command = item.get('command', [])
        if command:
            name = command[0]
            if name.startswith(('./', '.\\')):
                continue
            tool = aliases.get(name, Path(name).name)
            if tool:
                required.append(tool)
    if 'Cargo.toml' in files:
        required += ['cc', 'cargo', 'rustc']
        if 'openssl-sys' in files.get('Cargo.lock', ''):
            required += ['pkg-config', 'openssl-dev']
    if 'package.json' in files:
        package = json.loads(files['package.json'])
        required += ['node', 'npm']
        manager = package.get('packageManager', '').split('@')[0]
        if manager in ('pnpm', 'yarn', 'bun'):
            required.append(manager)
    if 'go.mod' in files:
        required.append('go')
    return list(dict.fromkeys(required))


def prepare_plugin(source, ref=None):
    manifest, files, commit = plugin_metadata(source, ref)
    dependencies = plugin_dependencies(manifest, files)
    unsupported = [x for x in dependencies if x not in TOOLS and not executable(x)]
    if unsupported:
        raise RuntimeError('Install these plugin dependencies on the host before retrying: ' + ', '.join(unsupported))
    results = ensure_tools(dependencies)
    return {'source': source, 'ref': commit, 'pluginID': manifest['id'], 'dependencies': results}


def herdr_json(args):
    binary = executable('herdr')
    if not binary:
        raise RuntimeError('Herdr is not installed on this host')
    text = run([binary] + args).stdout
    return json.loads(text[text.index('{'):])['result']


def keybinding_state(config, plugin, action):
    """Verify postconditions, never a saved 'button was clicked' flag.

    Plugins may declare metadata.msam.actions.<id>.keybindings. Legacy Ferry
    uses its published binding contract. Unknown actions stay unverified.
    """
    checks = action.get('checks', [])
    if not checks and plugin == 'shadowfax.ferry' and action['id'] == 'install-keybindings':
        checks = [{'key': 'prefix+m', 'command': 'shadowfax.ferry.open'}]
    if not checks:
        return {'state': 'unverified', 'detail': 'This plugin does not declare a setup check.'}
    keys = config.get('keys', {})
    commands = keys.get('command', [])
    missing = []
    for check in checks:
        key, command = check['key'], check['command']
        occupied = [x for x in commands if x.get('key') == key]
        builtin = any(v == key or isinstance(v, list) and key in v for k, v in keys.items() if k not in ('command', 'prefix'))
        if builtin or len(occupied) > 1 or any(x.get('command') != command or x.get('type') != 'plugin_action' for x in occupied):
            return {'state': 'conflict', 'detail': key + ' is assigned to another command.'}
        if not occupied:
            missing.append(key)
    if missing:
        return {'state': 'missing', 'detail': ', '.join(missing) + ' is not configured.'}
    return {'state': 'ready', 'detail': 'Key bindings verified on this host.'}


def plugin_setup_status():
    plugins = herdr_json(['plugin', 'list', '--json']).get('plugins', [])
    config_path = Path(os.environ.get('HERDR_CONFIG_PATH') or
                       str(Path(os.environ.get('XDG_CONFIG_HOME', str(HOME_DIR / '.config'))) / 'herdr/config.toml'))
    config = read_toml(config_path)
    results = []
    for plugin in plugins:
        plugin_id = plugin['plugin_id']
        declarations = {}
        root = plugin.get('plugin_root')
        manifest = {}
        if root:
            manifest = read_toml(Path(root) / 'herdr-plugin.toml')
            declarations = manifest.get('metadata', {}).get('msam', {}).get('actions', {})
        actions = []
        for action in plugin.get('actions', []):
            if action.get('contexts'):
                continue
            declaration = declarations.get(action['id'], {})
            if 'keybind' not in (action['id'] + ' ' + action.get('title', '')).lower() and not declaration:
                continue
            check = dict(action, checks=declaration.get('keybindings', []))
            state = keybinding_state(config, plugin_id, check)
            if state['state'] == 'ready' and root:
                bindings = check.get('checks', [])
                if not bindings and plugin_id == 'shadowfax.ferry':
                    bindings = [{'command': 'shadowfax.ferry.open'}]
                for binding in bindings:
                    target_id = binding['command'][len(plugin_id) + 1:]
                    target = next((x for x in manifest.get('actions', []) if x.get('id') == target_id), {})
                    command = target.get('command', [])
                    if not command:
                        state = {'state': 'unverified', 'detail': 'The configured action is missing from the installed plugin.'}
                        break
                    binary = Path(root) / command[0] if command and command[0].startswith('./') else None
                    if (binary is not None and (not binary.is_file() or SYSTEM != 'windows' and not os.access(str(binary), os.X_OK))) or (binary is None and not executable(command[0])):
                        state = {'state': 'unverified', 'detail': 'The plugin executable is missing or cannot run. Reinstall the plugin.'}
                        break
            if not plugin.get('enabled', True):
                state = {'state': 'disabled', 'detail': 'Enable the plugin before configuring it.'}
            actions.append(dict(state, id=action['id']))
        if plugin_id == 'herdr-file-viewer':
            if SYSTEM == 'windows':
                transfer = {'state': 'unverified', 'detail': 'File transfer setup is not supported on Windows yet.'}
            else:
                transfer = keybinding_state(config, plugin_id, {'id': 'msam-file-transfer', 'checks': [
                    {'key': 'prefix+f', 'command': 'herdr-file-viewer.open-file-viewer'},
                    {'key': 'prefix+shift+f', 'command': 'herdr-file-viewer.open-file-viewer-tab'}]})
                if transfer['state'] == 'ready':
                    directory = run([executable('herdr'), 'plugin', 'config-dir', plugin_id]).stdout.strip()
                    viewer = read_toml(Path(directory) / 'config.toml')
                    opened = viewer.get('open')
                    if opened not in (None, 'msam-send'):
                        transfer = {'state': 'conflict', 'detail': 'The file viewer has another open command configured.'}
                    elif opened != 'msam-send' or not executable('msam-send'):
                        transfer = {'state': 'missing', 'detail': 'File transfer command is not configured.'}
            if not plugin.get('enabled', True):
                transfer = {'state': 'disabled', 'detail': 'Enable the plugin before configuring file transfer.'}
            actions.append(dict(transfer, id='msam-file-transfer'))
        results.append({'pluginID': plugin_id, 'actions': actions})
    return {'plugins': results}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['agents', 'install-agent', 'prepare-plugin', 'plugin-status'])
    parser.add_argument('target', nargs='?')
    parser.add_argument('--ref')
    args = parser.parse_args()
    try:
        if args.operation == 'agents':
            result = {'agents': [agent_status(tool) for tool in AGENTS]}
        elif args.operation == 'install-agent':
            if args.target not in AGENTS:
                raise ValueError('Unknown AI agent')
            result = {'agents': [install_agent(args.target)]}
        elif args.operation == 'prepare-plugin':
            result = prepare_plugin(args.target, args.ref)
        else:
            result = plugin_setup_status()
        print('MSAM_SOFTWARE=' + json.dumps(result), flush=True)
    except Exception as error:
        print('MSAM_SOFTWARE=' + json.dumps({'error': str(error)}), flush=True)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
