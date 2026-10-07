#!/usr/bin/env python3
"""Install/update one MSAM host service; preserve update queues and rollback."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import sysconfig
import time

HOME = Path(os.environ.get('MSAM_HOST_HOME', str(Path.home())))
BASE = HOME / '.local/libexec/msam-host-agent'
STATE = HOME / '.local/state/msam-host-agent'
LABEL = 'com.codem0nky87.msam-host-agent'
UNIT = 'msam-host-agent.service'
LEGACY_LABEL = 'com.codem0nky87.msam-agent-updater'
LEGACY_UNIT = 'msam-agent-updater.service'
FILES = ('msam-host-agent.py', 'msam-metrics.py', 'msam-agent-updater.sh',
         'msam-agent-updater-windows.py', 'msam-metrics.ps1',
         'msam-host-service-windows.py', 'msam-metrics-manage.py', 'msam-host-agent-install.py',
         'msam-host-launcher.c.txt')


@contextlib.contextmanager
def maintenance():
    """Serialize service changes and prevent the old/new worker starting a job."""
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    updater = HOME / '.local/state/msam-agent-updater'
    updater.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'management.lock').open('a+b') as operation:
        if os.name == 'nt':
            import msvcrt
            operation.write(b'0'); operation.flush(); operation.seek(0)
            msvcrt.locking(operation.fileno(), msvcrt.LK_NBLCK, 1)
            with (updater / 'worker.lock').open('a+b') as worker:
                worker.write(b'0'); worker.flush(); worker.seek(0)
                msvcrt.locking(worker.fileno(), msvcrt.LK_NBLCK, 1)
                try:
                    yield
                finally:
                    worker.seek(0); msvcrt.locking(worker.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(operation, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock = updater / 'lock'
            if lock.exists():
                try:
                    pid = int((lock / 'pid').read_text())
                    os.kill(pid, 0)
                except ProcessLookupError:
                    (lock / 'pid').unlink(); lock.rmdir()
                except (OSError, ValueError):
                    raise RuntimeError('The updater lock needs attention; check AI Agent Updates before changing the service.')
                else:
                    raise RuntimeError('An agent update is in progress. Try again when it settles.')
            lock.mkdir()
            (lock / 'pid').write_text(str(os.getpid()))
            try:
                yield
            finally:
                (lock / 'pid').unlink(missing_ok=True)
                lock.rmdir()


def run(args, check=True, timeout=30, **kwargs):
    env = dict(os.environ, MSAM_HOST_HOME=str(HOME))
    if sys.platform.startswith('linux'):
        env.setdefault('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid()))
        env.setdefault('DBUS_SESSION_BUS_ADDRESS', 'unix:path=' + env['XDG_RUNTIME_DIR'] + '/bus')
    return subprocess.run(args, env=env, check=check, capture_output=True, text=True, timeout=timeout, **kwargs)


def command(*args):
    current = BASE / 'current'
    launcher = current / 'msam-host-agent'
    if sys.platform == 'darwin' and launcher.is_file():
        runtime = json.loads((current / 'mac-runtime.json').read_text())
        return [str(launcher), runtime['library'], runtime['executable'],
                str(current / 'msam-host-agent.py'), *args]
    # Older releases have no native launcher; retain their command for rollback.
    return [sys.executable, str(BASE / 'current/msam-host-agent.py'), *args]


def build_mac_launcher(release):
    if sys.platform != 'darwin':
        return
    library_name = sysconfig.get_config_var('LDLIBRARY')
    if not library_name:
        raise RuntimeError('MSAM could not locate the Python shared library.')
    candidates = [Path(prefix) / library_name for prefix in (
        sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX'), sysconfig.get_config_var('LIBDIR')) if prefix]
    library = next((path.resolve() for path in candidates if path.is_file()), None)
    if library is None:
        raise RuntimeError('MSAM requires a Python installation with a shared library on macOS.')
    runtime = {'library': str(library), 'executable': sys.executable}
    temporary = release / ('.msam-host-agent-' + str(os.getpid()))
    try:
        # Compile and smoke-test before stopping the current service. No Python
        # headers or downloaded packages are needed; only Apple's command-line tools.
        # The .txt suffix keeps Xcode from compiling this iOS bundle resource.
        run(['xcrun', 'clang', '-x', 'c', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
             str(release / 'msam-host-launcher.c.txt'), '-o', str(temporary)], timeout=60)
        run([str(temporary), runtime['library'], runtime['executable'], '-c',
             'import ctypes, json, ssl, threading; print("MSAM_RUNTIME_OK")'])
        temporary.chmod(0o700)
        os.replace(temporary, release / 'msam-host-agent')
        config = release / 'mac-runtime.json'
        config.write_text(json.dumps(runtime) + '\n')
        config.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def get_status():
    try:
        value = json.loads((STATE / 'status.json').read_text())
    except (OSError, ValueError):
        value = {}
    value['disabled'] = (STATE / 'disabled').exists()
    value['installed'] = (BASE / 'current/msam-host-agent.py').is_file() and not value['disabled']
    value['running'] = value['installed'] and value.get('heartbeat', 0) > time.time() - 15
    value.setdefault('version', '')
    try:
        value['manifest'] = json.loads((BASE / 'current/manifest.json').read_text())
    except (OSError, ValueError):
        value['manifest'] = None
    return value


def service_path(legacy=False):
    if sys.platform == 'darwin':
        return HOME / 'Library/LaunchAgents' / ((LEGACY_LABEL if legacy else LABEL) + '.plist')
    return HOME / '.config/systemd/user' / (LEGACY_UNIT if legacy else UNIT)


def write_service():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if sys.platform == 'darwin':
        definition = {'Label': LABEL, 'ProgramArguments': command('serve'),
                      'EnvironmentVariables': {'MSAM_HOST_HOME': str(HOME)},
                      'RunAtLoad': True, 'KeepAlive': True, 'ProcessType': 'Background',
                      'StandardOutPath': str(STATE / 'service.stdout.log'),
                      'StandardErrorPath': str(STATE / 'service.stderr.log')}
        service_path().parent.mkdir(parents=True, exist_ok=True)
        service_path().write_bytes(plistlib.dumps(definition))
        service_path().chmod(0o600)
    elif os.name == 'nt':
        # Registration must use the SSH user's account, never LocalSystem.
        # A one-time account credential is required by SCM for a new service.
        bridge = BASE / 'current/msam-host-service-windows.py'
        run([sys.executable, str(bridge), 'configure', str(HOME)], timeout=30)
    else:
        def quote(value):
            return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
        content = '[Unit]\nDescription=MSAM host agent (agents, updates, metrics)\n\n[Service]\nType=simple\n'
        content += 'ExecStart=' + ' '.join(quote(v) for v in command('serve')) + '\n'
        content += 'Environment=' + quote('MSAM_HOST_HOME=' + str(HOME)) + '\n'
        content += 'Restart=on-failure\nRestartSec=2\nKillMode=process\nTimeoutStopSec=20\nNoNewPrivileges=true\n\n[Install]\nWantedBy=default.target\n'
        service_path().parent.mkdir(parents=True, exist_ok=True)
        service_path().write_text(content)
        service_path().chmod(0o600)


def control(action, legacy=False):
    if sys.platform == 'darwin':
        label = LEGACY_LABEL if legacy else LABEL
        domain = 'gui/' + str(os.getuid())
        if action == 'stop':
            run(['launchctl', 'bootout', domain + '/' + label], check=False)
            for _ in range(40):
                if run(['launchctl', 'print', domain + '/' + label], check=False).returncode != 0:
                    break
                time.sleep(.25)
            else:
                raise RuntimeError('The previous launchd service could not be stopped.')
        else:
            run(['launchctl', 'bootstrap', domain, str(service_path(legacy))])
            run(['launchctl', 'enable', domain + '/' + label])
            run(['launchctl', 'kickstart', '-k', domain + '/' + label])
    elif os.name == 'nt':
        if not legacy:
            run(['sc.exe', action, 'MSAMHostAgent'], check=action != 'stop')
            if action == 'stop':
                for _ in range(40):
                    query = run(['sc.exe', 'query', 'MSAMHostAgent'], check=False)
                    if query.returncode == 1060 or re.search(r'STATE\s*:\s*1\b', query.stdout):
                        break
                    time.sleep(.25)
                else:
                    raise RuntimeError('The Windows host service could not be stopped.')
    else:
        unit = LEGACY_UNIT if legacy else UNIT
        if action == 'stop':
            result = run(['systemctl', '--user', 'disable', '--now', unit], check=False)
            if run(['systemctl', '--user', 'is-active', '--quiet', unit], check=False).returncode == 0:
                raise RuntimeError('The previous service could not be stopped: ' + result.stderr)
        else:
            run(['systemctl', '--user', 'daemon-reload'])
            run(['systemctl', '--user', 'enable', '--now', unit])


def require_idle():
    # Never terminate an update/install/restore subprocess during migration.
    state = HOME / '.local/state/msam-agent-updater'
    try:
        windows_batch = json.loads((state / 'current.json').read_text())
    except (OSError, ValueError):
        windows_batch = {}
    if windows_batch.get('phase') in ('updating', 'rolling'):
        raise RuntimeError('An agent update is active. Wait for it to finish before changing the service.')
    lock = state / 'lock/pid'
    if lock.exists():
        try:
            pid = int(lock.read_text().strip())
            if pid != os.getpid():
                os.kill(pid, 0)
            else:
                raise ProcessLookupError()
        except (OSError, ValueError):
            pass
        else:
            raise RuntimeError('An agent update is in progress. Wait for it to finish before changing the service.')
    current = state / 'current'
    if current.exists():
        batch = current.read_text().strip()
        if not re.fullmatch(r'[0-9a-fA-F-]{36}', batch):
            raise RuntimeError('The existing updater has an unresolved batch. Check AI Agent Updates first.')
        phase = state / 'batches' / batch / 'phase'
        if phase.exists() and phase.read_text().strip() in ('updating', 'rolling'):
            raise RuntimeError('A rolling agent update is active. Wait for it to settle before changing the service.')


def migrate_collectors():
    if os.name == 'nt':
        # The old Windows script runs in an app-owned PTY, which the app retires.
        for filename in ('msam-metrics.ps1',):
            (HOME / '.local/bin' / filename).unlink(missing_ok=True)
        return
    spec = importlib.util.spec_from_file_location('metrics_manage', BASE / 'current/msam-metrics-manage.py')
    manager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(manager)
    target = HOME / '.local/bin/msam-metrics'
    manager.stop_collectors(target)
    target.unlink(missing_ok=True)


def write_launchers():
    binary = HOME / '.local/bin'
    binary.mkdir(parents=True, exist_ok=True)
    if os.name == 'nt':
        (binary / 'msam-host-agent.cmd').write_bytes(('@echo off\r\n"' + sys.executable + '" "' + str(BASE / 'current/msam-host-agent.py') + '" %*\r\n').encode('utf-8'))
        return
    launcher = '#!/bin/sh\nexec ' + ' '.join(shlex.quote(v) for v in command()) + ' "$@"\n'
    (binary / 'msam-host-agent').write_text(launcher)
    (binary / 'msam-host-agent').chmod(0o700)
    # Compatibility command for the app's existing durable update protocol.
    # There is no separate updater daemon after migration.
    shim = HOME / '.local/libexec/msam-agent-updater'
    if shim.exists() and not shim.with_suffix('.bak').exists():
        shutil.copy2(shim, shim.with_suffix('.bak'))
    shim.write_text('#!/bin/sh\nexec ' + ' '.join(shlex.quote(v) for v in command('updates')) + ' "$@"\n')
    shim.chmod(0o700)


def wait_healthy():
    for _ in range(40):
        value = get_status()
        if value.get('running') and value.get('metrics'):
            return value
        time.sleep(.5)
    raise RuntimeError('The host agent did not become healthy. Check its service log.')


def install(stage):
    stage = Path(stage).resolve()
    manifest = json.loads((stage / 'manifest.json').read_text())
    if set(manifest) != set(FILES):
        raise ValueError('Incomplete host-agent bundle.')
    for name in FILES:
        data = (stage / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != manifest[name]:
            raise ValueError('Host-agent bundle checksum failed: ' + name)
        if name.endswith('.py'):
            compile(data, name, 'exec')
    run([sys.executable, str(stage / 'msam-host-agent.py'), 'self-test'], timeout=30)
    require_idle()
    if sys.platform == 'darwin':
        run(['launchctl', 'print', 'gui/' + str(os.getuid())])
    elif sys.platform.startswith('linux'):
        run(['systemctl', '--user', 'show-environment'])
        linger = run(['loginctl', 'show-user', str(os.getuid()), '-p', 'Linger', '--value']).stdout.strip()
        if linger != 'yes':
            raise RuntimeError('Enable background operation first: sudo loginctl enable-linger ' + os.environ.get('USER', str(os.getuid())))
    release = BASE / 'releases' / hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()[:20]
    release.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not release.exists():
        release.mkdir(mode=0o700)
        for name in (*FILES, 'manifest.json'):
            shutil.copy2(stage / name, release / name)
    build_mac_launcher(release)
    current = BASE / 'current'
    previous = current.resolve() if current.exists() else None
    was_disabled = (STATE / 'disabled').exists()
    windows_previous = BASE / '.previous'
    legacy = service_path(legacy=True).exists() if os.name != 'nt' else False
    control('stop', legacy=True)
    control('stop')
    try:
        if os.name == 'nt':
            if current.exists():
                if windows_previous.exists():
                    shutil.rmtree(windows_previous)
                os.replace(current, windows_previous)
            shutil.copytree(release, current)
        else:
            candidate = BASE / '.current-new'
            candidate.unlink(missing_ok=True)
            candidate.symlink_to(release)
            os.replace(candidate, current)
        (STATE / 'status.json').unlink(missing_ok=True)
        (STATE / 'disabled').unlink(missing_ok=True)
        write_service()
        write_launchers()
        control('start')
        value = wait_healthy()
        migrate_collectors()
        if os.name != 'nt':
            service_path(legacy=True).unlink(missing_ok=True)
            if sys.platform.startswith('linux'):
                run(['systemctl', '--user', 'daemon-reload'])
        return value
    except Exception:
        control('stop')
        if previous and os.name != 'nt':
            current.unlink(missing_ok=True)
            current.symlink_to(previous)
            write_service(); write_launchers(); control('start')
        elif os.name == 'nt' and windows_previous.exists():
            shutil.rmtree(current)
            os.replace(windows_previous, current)
            write_service(); write_launchers(); control('start')
        else:
            if os.name == 'nt':
                shutil.rmtree(current, ignore_errors=True)
            else:
                current.unlink(missing_ok=True)
                service_path().unlink(missing_ok=True)
            for name in ('msam-host-agent', 'msam-host-agent.cmd'):
                (HOME / '.local/bin' / name).unlink(missing_ok=True)
            shim = HOME / '.local/libexec/msam-agent-updater'
            if legacy:
                # The old unit/helper is only retired after the health check.
                if shim.with_suffix('.bak').exists():
                    shutil.copy2(shim.with_suffix('.bak'), shim)
                control('start', legacy=True)
            else:
                shim.unlink(missing_ok=True)
        if was_disabled:
            control('stop')
            (STATE / 'disabled').touch(mode=0o600)
        raise


def perform(args):
    if args.action == 'install':
        return install(args.stage)
    if args.action != 'start':
        require_idle()
    if args.action in ('stop', 'restart', 'remove'):
        control('stop')
        (STATE / 'status.json').unlink(missing_ok=True)
    if args.action == 'remove':
        STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
        (STATE / 'disabled').touch(mode=0o600)
        if os.name == 'nt':
            run(['sc.exe', 'delete', 'MSAMHostAgent'])
        else:
            service_path().unlink(missing_ok=True)
        for name in ('msam-host-agent', 'msam-host-agent.cmd', 'msam-metrics', 'msam-metrics.ps1'):
            (HOME / '.local/bin' / name).unlink(missing_ok=True)
        (HOME / '.local/libexec/msam-agent-updater').unlink(missing_ok=True)
        return dict(get_status(), installed=False)
    if args.action in ('start', 'restart'):
        if not get_status()['running']:
            control('start')
            wait_healthy()
    return get_status()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'status', 'start', 'stop', 'restart', 'remove'])
    parser.add_argument('stage', nargs='?')
    args = parser.parse_args()
    if args.action == 'status':
        result = get_status()
    else:
        with maintenance():
            result = perform(args)
    print('MSAM_HOST_STATUS=' + json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(detail, file=sys.stderr)
        sys.exit(1)
