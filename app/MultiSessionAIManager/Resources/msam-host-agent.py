#!/usr/bin/env python3
"""One per-user host agent: shared metrics, Herdr inventory, durable updates."""
import argparse
import contextlib
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

VERSION = '1.1.0'
ROOT = Path(__file__).resolve().parent
HOME = Path(os.environ.get('MSAM_HOST_HOME', str(Path.home())))
STATE = HOME / '.local/state/msam-host-agent'
UPDATER_STATE = HOME / '.local/state/msam-agent-updater'
STOP = threading.Event()
WINDOWS_NETWORK = None

# Per-component versions for the service status. Scripts that declare one
# report it verbatim; the rest report a short content digest so the app can
# still tell two builds apart. Read once at startup: the service is replaced
# (and restarted) when files change, never hot-swapped.
COMPONENT_VERSION_SOURCES = {
    'metrics': ('msam-metrics.py', r"^METRICS_VERSION = ['\"]([^'\"]+)['\"]"),
    'metrics_windows': ('msam-metrics.ps1', r'^\$MetricsVersion\s*=\s*[\'"]([^\'"]+)[\'"]'),
    'updater': ('msam-agent-updater.sh', r'^PROTOCOL_VERSION=(\S+)'),
}
COMPONENT_DIGEST_FILES = ['msam-host-software.py', 'msam-metrics-manage.py',
                          'msam-host-service-windows.py', 'msam-agent-updater-windows.py',
                          'msam-host-agent-install.py']


def component_versions():
    import hashlib
    import re
    versions = {'service': VERSION}
    for name, (filename, pattern) in COMPONENT_VERSION_SOURCES.items():
        try:
            match = re.search(pattern, (ROOT / filename).read_text(encoding='utf-8'), re.MULTILINE)
        except OSError:
            match = None
        versions[name] = match.group(1) if match else 'unknown'
    for filename in COMPONENT_DIGEST_FILES:
        try:
            digest = hashlib.sha256((ROOT / filename).read_bytes()).hexdigest()[:12]
        except OSError:
            digest = 'missing'
        versions[filename] = digest
    return versions


COMPONENT_VERSIONS = component_versions()


def atomic_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temp.write_text(json.dumps(value, allow_nan=False) + '\n')
    temp.chmod(0o600)
    os.replace(temp, path)


def read_json(path, fallback=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def updater_command(*args):
    if os.name == 'nt':
        # The native service uses the same durable request protocol, with a
        # platform-specific backend rather than executing a POSIX shell.
        return [sys.executable, str(ROOT / 'msam-agent-updater-windows.py'), *args]
    return ['/bin/sh', str(ROOT / 'msam-agent-updater.sh'), *args]


def environment():
    env = dict(os.environ, HOME=str(HOME), MSAM_AGENT_UPDATER_STATE_DIR=str(UPDATER_STATE))
    extra = [HOME / '.local/bin', HOME / '.gemini/antigravity-cli/bin']
    if os.name == 'nt':
        extra += [HOME / 'AppData/Roaming/npm', HOME / '.herdr/bin', HOME / '.herdr/current']
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
                user_path = winreg.QueryValueEx(key, 'Path')[0]
                env['PATH'] = os.path.expandvars(user_path) + os.pathsep + env.get('PATH', '')
        except OSError:
            pass
    else:
        extra += [Path('/opt/homebrew/bin'), Path('/usr/local/bin'), Path('/usr/bin'), Path('/bin')]
    env['PATH'] = os.pathsep.join(map(str, extra)) + os.pathsep + env.get('PATH', '')
    return env


def status():
    value = read_json(STATE / 'status.json', {})
    value['running'] = bool(value.get('heartbeat', 0) > time.time() - 15)
    value.setdefault('version', VERSION)
    # The status command runs from the installed files, so component versions
    # are accurate even when the daemon last wrote an older status.json.
    value['components'] = COMPONENT_VERSIONS
    return value


def sample_metrics(module):
    global WINDOWS_NETWORK
    if sys.platform == 'darwin':
        return module.get_mac_metrics()
    if os.name == 'nt':
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                 '-File', str(ROOT / 'msam-metrics.ps1')],
                                capture_output=True, timeout=15, check=True, env=environment())
        value = json.loads(result.stdout.decode('utf-8-sig'))
        counters, now = value.pop('networkCounters', {}), time.monotonic()
        received = sent = 0.0
        if WINDOWS_NETWORK:
            previous, then = WINDOWS_NETWORK
            elapsed = max(now - then, .001)
            for interface, current in counters.items():
                old = previous.get(interface)
                if old and current['received'] >= old['received'] and current['sent'] >= old['sent']:
                    received += (current['received'] - old['received']) / elapsed
                    sent += (current['sent'] - old['sent']) / elapsed
        WINDOWS_NETWORK = (counters, now)
        value['network'] = {'downloadSpeed': received, 'uploadSpeed': sent,
                            'downloadString': module.format_bytes(received), 'uploadString': module.format_bytes(sent)}
        return value
    return module.get_linux_metrics()


def inventory():
    def run(args, env=None):
        result = subprocess.run(args, env=env or environment(), capture_output=True, timeout=10, check=True)
        return json.loads(result.stdout)
    sessions = run(['herdr', 'session', 'list', '--json']).get('sessions', [])
    result = []
    for session in sessions[:32]:
        if not session.get('running') or not session.get('socket_path'):
            continue
        env = dict(environment(), HERDR_SOCKET_PATH=session['socket_path'])
        agents = run(['herdr', 'agent', 'list'], env).get('result', {}).get('agents', [])
        result.append({'session': session['name'], 'socketPath': session['socket_path'], 'agents': agents[:256]})
    return result


def background_updates():
    while not STOP.is_set():
        try:
            # Keep the proven request/restore state machine and its exclusive
            # lock. A worker continues independently if the daemon is stopped.
            result = subprocess.run(updater_command('run-once'), env=environment(),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if result.returncode not in (0, 75):
                atomic_json(STATE / 'updater-error.json', {'message': result.stderr.decode('utf-8', 'replace')[-2048:], 'at': time.time()})
            elif result.returncode == 0:
                (STATE / 'updater-error.json').unlink(missing_ok=True)
        except OSError as error:
            atomic_json(STATE / 'updater-error.json', {'message': str(error), 'at': time.time()})
        STOP.wait(2)


def background_inventory():
    while not STOP.is_set():
        try:
            atomic_json(STATE / 'agents.json', {'at': time.time(), 'sessions': inventory()})
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            atomic_json(STATE / 'agents.json', {'at': time.time(), 'sessions': [], 'error': str(error)})
        STOP.wait(15)


@contextlib.contextmanager
def singleton(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open('a+b') as lock:
        if os.name == 'nt':
            import msvcrt
            lock.seek(0)
            if not lock.read(1):
                lock.write(b'0'); lock.flush()
            lock.seek(0)
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                    raise BlockingIOError('The host worker is already running.') from error
                raise
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            if os.name == 'nt':
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def serve():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    module = load_module('metrics', 'msam-metrics.py')
    with singleton(STATE / 'daemon.lock'):
        threading.Thread(target=background_updates, daemon=True).start()
        threading.Thread(target=background_inventory, daemon=True).start()
        try:
            while not STOP.is_set():
                started = time.monotonic()
                detail = {'version': VERSION, 'components': COMPONENT_VERSIONS,
                          'pid': os.getpid(), 'heartbeat': time.time(),
                          'metrics': False, 'updates': not (STATE / 'updater-error.json').exists(),
                          'agents': not read_json(STATE / 'agents.json', {}).get('error')}
                try:
                    atomic_json(STATE / 'metrics.json', sample_metrics(module))
                    detail['metrics'] = True
                except Exception as error:
                    detail['error'] = str(error)
                atomic_json(STATE / 'status.json', detail)
                STOP.wait(max(0.1, 2 - (time.monotonic() - started)))
        finally:
            atomic_json(STATE / 'status.json', {'version': VERSION, 'components': COMPONENT_VERSIONS,
                                                'heartbeat': 0, 'pid': os.getpid(), 'metrics': False})


def stream_metrics(loop):
    last = None
    while True:
        current = status()
        if not current['running']:
            raise RuntimeError('The MSAM host service is stopped. Start it from Manage Hosts.')
        if not current.get('metrics'):
            raise RuntimeError(current.get('error', 'The host service has no current metrics.'))
        path = STATE / 'metrics.json'
        stamp = path.stat().st_mtime_ns
        if stamp != last:
            print(path.read_text().strip(), flush=True)
            last = stamp
        if not loop:
            return
        time.sleep(0.5)


def main():
    global HOME, STATE, UPDATER_STATE
    parser = argparse.ArgumentParser()
    parser.add_argument('--home')
    parser.add_argument('command', choices=['serve', 'windows-service', 'status', 'metrics', 'agents', 'updates', 'self-test'])
    parser.add_argument('args', nargs='*')
    parser.add_argument('--loop', action='store_true')
    options = parser.parse_args()
    if options.home:
        HOME = Path(options.home)
        STATE = HOME / '.local/state/msam-host-agent'
        UPDATER_STATE = HOME / '.local/state/msam-agent-updater'
    if options.command == 'serve':
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: STOP.set())
        serve()
    elif options.command == 'windows-service':
        load_module('windows_service', 'msam-host-service-windows.py').run(serve, STOP)
    elif options.command == 'status':
        print('MSAM_HOST_STATUS=' + json.dumps(status()))
    elif options.command == 'metrics':
        stream_metrics(options.loop)
    elif options.command == 'agents':
        print(json.dumps(read_json(STATE / 'agents.json', {'sessions': []})))
    elif options.command == 'updates':
        if not options.args or options.args[0] not in ('protocol', 'verify-service', 'submit', 'status', 'version'):
            raise ValueError('Unsupported update operation.')
        raise SystemExit(subprocess.call(updater_command(*options.args), env=environment()))
    elif options.command == 'self-test':
        module = load_module('metrics', 'msam-metrics.py')
        sample = sample_metrics(module)
        if not all(isinstance(sample.get(k), dict) for k in ('cpu', 'memory', 'disk', 'gpu')):
            raise ValueError('Invalid metrics payload.')
        subprocess.run(updater_command('verify-service'), env=environment(), check=True, timeout=10, stdout=subprocess.DEVNULL)
        print(json.dumps(sample))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
