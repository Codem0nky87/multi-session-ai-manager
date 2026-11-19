#!/usr/bin/env python3
"""One per-user host agent: shared metrics, Herdr inventory, durable updates."""
import argparse
import contextlib
import errno
import http.server
import importlib.util
import json
import ntpath
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

VERSION = '1.2.1'
ROOT = Path(__file__).resolve().parent
HOME = Path(os.environ.get('MSAM_HOST_HOME', str(Path.home())))
STATE = HOME / '.local/state/msam-host-agent'
UPDATER_STATE = HOME / '.local/state/msam-agent-updater'
STOP = threading.Event()
WINDOWS_NETWORK = None

# Seconds between polls of every Herdr session's agents. The app shows a pill on
# a host's tab when an agent there is blocked or has finished, and that should
# follow within a few seconds, not a quarter of a minute.
INVENTORY_INTERVAL = 3
# The list of Herdr sessions changes rarely and is re-read less often.
SESSION_REFRESH_INTERVAL = 15
# An inventory older than this says nothing about now: the poller is stuck.
ATTENTION_MAX_AGE = 30
ATTENTION_PREFIX = 'MSAM_ATTENTION='
ATTENTION_LIMIT = 20
# An unchanged summary is repeated this often, so a reader can tell a quiet
# host from a dead stream.
ATTENTION_HEARTBEAT = 15
# Windows refuses to replace a file another program has open, and to open one
# that is being replaced. Both pass within a moment.
REPLACE_TRIES, REPLACE_PAUSE = 40, 0.05
READ_TRIES, READ_PAUSE = 5, 0.02
# How long a metrics stream waits out a service that looks stopped or a reading
# that failed, before it gives up and says so.
STREAM_PATIENCE = 20
# How long the Windows service waits before it starts its work again.
SERVICE_RETRY = 5

# Per-component versions for the service status. Scripts that declare one
# report it verbatim; the rest report a short content digest so the app can
# still tell two builds apart. Read once at startup: the service is replaced
# (and restarted) when files change, never hot-swapped.
COMPONENT_VERSION_SOURCES = {
    'metrics': ('msam-metrics.ps1', r'^\$MetricsVersion\s*=\s*[\'"]([^\'"]+)[\'"]') if os.name == 'nt'
               else ('msam-metrics.py', r"^METRICS_VERSION = ['\"]([^'\"]+)['\"]"),
    'updater': ('msam-agent-updater.sh', r'^PROTOCOL_VERSION=(\S+)'),
}
COMPONENT_DIGEST_FILES = ['msam-host-software.py', 'msam-metrics-manage.py',
                          'msam-host-service-windows.py', 'msam-agent-updater-windows.py',
                          'msam-host-agent-install.py', 'msam-provider-pulse.py',
                          'msam-hardware-db.json']


def component_versions():
    import hashlib
    import re
    versions = {'service': VERSION}
    sources = dict(COMPONENT_VERSION_SOURCES)
    sources['metrics'] = (
        ('msam-metrics.ps1', r'^\$MetricsVersion\s*=\s*[\'"]([^\'"]+)[\'"]')
        if os.name == 'nt'
        else ('msam-metrics.py', r"^METRICS_VERSION = ['\"]([^'\"]+)['\"]")
    )
    for name, (filename, pattern) in sources.items():
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
    for attempt in range(REPLACE_TRIES):
        try:
            os.replace(temp, path)
            return
        except PermissionError:
            # A reader has the file open (Windows). It lets go within a moment.
            if attempt == REPLACE_TRIES - 1:
                with contextlib.suppress(OSError):
                    temp.unlink()
                raise
            time.sleep(REPLACE_PAUSE)


def read_json(path, fallback=None):
    for attempt in range(READ_TRIES):
        try:
            return json.loads(path.read_text())
        except PermissionError:
            # The file is being replaced at this instant (Windows).
            if attempt < READ_TRIES - 1:
                time.sleep(READ_PAUSE)
        except (OSError, ValueError):
            break
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


def account():
    """The Windows account whose agents this is for, as setup wrote it down."""
    return read_json(STATE / 'account.json', {}) or {}


def adopt_account():
    """Makes this process, and all it starts, work in the account's profile.

    The Windows service runs as SYSTEM, whose profile is not the account's:
    npm would install the agents' tools where nobody finds them, and Herdr
    would look for SYSTEM's sessions. Windows locates a profile through these
    variables, so they are set to the account's.
    """
    home = str(HOME)
    drive, tail = ntpath.splitdrive(home)
    profile = {'APPDATA': ntpath.join(home, 'AppData', 'Roaming'),
               'LOCALAPPDATA': ntpath.join(home, 'AppData', 'Local')}
    # Where setup found them, which need not be under the home.
    recorded = account().get('environment') or {}
    profile.update({name: recorded[name] for name in ('APPDATA', 'LOCALAPPDATA', 'USERNAME', 'USERDOMAIN')
                    if isinstance(recorded.get(name), str) and recorded[name]})
    profile.update(USERPROFILE=home, HOMEDRIVE=drive, HOMEPATH=tail or '\\')
    os.environ.update(profile)
    temp = ntpath.join(profile['LOCALAPPDATA'], 'Temp')
    if os.path.isdir(temp):
        os.environ['TEMP'] = os.environ['TMP'] = temp


def registry_path(sid):
    """The PATH an account keeps in its registry; this process's own without a SID.

    Another account's registry is only loaded while that account is logged on.
    """
    import winreg
    root, key = (winreg.HKEY_USERS, sid + '\\Environment') if sid else (winreg.HKEY_CURRENT_USER, 'Environment')
    try:
        with winreg.OpenKey(root, key) as handle:
            return winreg.QueryValueEx(handle, 'Path')[0]
    except OSError:
        return None


def account_path():
    """The account's own PATH: as it is now, or else as it was at setup."""
    known = account()
    return registry_path(known.get('sid')) or known.get('path') or ''


def environment():
    env = dict(os.environ, HOME=str(HOME), MSAM_AGENT_UPDATER_STATE_DIR=str(UPDATER_STATE))
    extra = [HOME / '.local/bin', HOME / '.gemini/antigravity-cli/bin']
    if os.name == 'nt':
        extra += [HOME / 'AppData/Roaming/npm', HOME / '.herdr/bin', HOME / '.herdr/current']
        env['PATH'] = os.path.expandvars(account_path()) + os.pathsep + env.get('PATH', '')
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


def load_pulse():
    pulse_file = ROOT / 'msam-provider-pulse.py'
    if pulse_file.exists():
        try:
            return load_module('pulse', 'msam-provider-pulse.py')
        except Exception:
            return None
    return None


def analyze_task(transcript_path, target_provider='codex'):
    pulse = load_pulse()
    if pulse:
        return pulse.analyze_session_task(transcript_path, target_provider, home_dir=HOME, env=environment())
    return {'model': 'gpt-6.1-sol', 'effort': 'medium', 'summary': 'Default recommendation'}


def sample_metrics(module):
    global WINDOWS_NETWORK
    if sys.platform == 'darwin':
        value = module.get_mac_metrics()
    elif os.name == 'nt':
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
    else:
        value = module.get_linux_metrics()

    cached_pulse = read_json(STATE / 'providers.json', None)
    if cached_pulse is not None:
        value.update(cached_pulse)
    else:
        value['providers'] = {}
        value['terminal_agents'] = []

    if hasattr(module, 'MetricsHistoryDB'):
        try:
            if not hasattr(sample_metrics, '_db') or sample_metrics._db is None:
                sample_metrics._db = module.MetricsHistoryDB()
                sample_metrics._last_prune = time.time()
                sample_metrics._db.prune_older_than(days=30)
            sample_metrics._db.record_sample_from_metrics(value)
            now = time.time()
            if now - getattr(sample_metrics, '_last_prune', 0) >= 3600:
                sample_metrics._last_prune = now
                sample_metrics._db.prune_older_than(days=30)
        except Exception:
            pass

    return value


def herdr(args, env=None):
    result = subprocess.run(['herdr'] + args, env=env or environment(), capture_output=True, timeout=10, check=True)
    return json.loads(result.stdout)


def running_sessions():
    sessions = herdr(['session', 'list', '--json']).get('sessions', [])
    return [session for session in sessions[:32] if session.get('running') and session.get('socket_path')]


def session_agents(sessions):
    result = []
    for session in sessions:
        env = dict(environment(), HERDR_SOCKET_PATH=session['socket_path'])
        try:
            agents = herdr(['agent', 'list'], env).get('result', {}).get('agents', [])
        except (OSError, ValueError, subprocess.SubprocessError):
            # The session ended since it was listed. One that is gone must not
            # blind the inventory to the others.
            continue
        result.append({'session': session['name'], 'socketPath': session['socket_path'], 'agents': agents[:256]})
    return result


def inventory():
    return session_agents(running_sessions())


def attention():
    """What on this host is waiting for its user.

    Herdr has no feed of the notifications it pops up, but it reports the agent
    state behind them: `blocked` is an agent waiting for an answer or a
    permission, and `done` is one that finished while nobody was looking, which
    Herdr clears itself once its pane is viewed. A provider that is rate limited
    is listed too. Read from the files the daemon already keeps, so asking costs
    no Herdr call.
    """
    providers = (read_json(STATE / 'providers.json', {}) or {}).get('providers') or {}
    summary = {
        'available': False, 'blocked': [], 'done': [], 'blocked_count': 0, 'done_count': 0,
        'rate_limited': sorted(name for name, value in providers.items()
                               if isinstance(value, dict) and value.get('state') == 'RATE_LIMITED')[:ATTENTION_LIMIT],
    }
    state = read_json(STATE / 'agents.json', None)
    if not isinstance(state, dict) or state.get('error') or time.time() - state.get('at', 0) > ATTENTION_MAX_AGE:
        return summary
    summary['available'] = True
    for session in state.get('sessions', []):
        for agent in session.get('agents', []):
            status = agent.get('agent_status')
            if status not in ('blocked', 'done'):
                continue
            pane = str(agent.get('pane_id') or '')
            name = agent.get('name') or agent.get('terminal_title_stripped') or agent.get('agent') or pane
            summary[status].append({'session': str(session.get('session') or ''), 'pane_id': pane,
                                    'name': str(name)[:80], 'agent': agent.get('agent')})
    for status in ('blocked', 'done'):
        summary[status + '_count'] = len(summary[status])
        summary[status] = summary[status][:ATTENTION_LIMIT]
    return summary


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
    sessions, refreshed = [], None
    while not STOP.is_set():
        try:
            now = time.monotonic()
            if refreshed is None or now - refreshed >= SESSION_REFRESH_INTERVAL:
                sessions, refreshed = running_sessions(), now
            found = session_agents(sessions)
            if len(found) != len(sessions):
                refreshed = None  # a session went away: list them again next time
            atomic_json(STATE / 'agents.json', {'at': time.time(), 'sessions': found})
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            refreshed = None
            atomic_json(STATE / 'agents.json', {'at': time.time(), 'sessions': [], 'error': str(error)})
        STOP.wait(INVENTORY_INTERVAL)


def background_provider_pulse():
    while not STOP.is_set():
        try:
            pulse = load_pulse()
            if pulse:
                telemetry = pulse.collect_provider_telemetry(home_dir=HOME, env=environment())
                atomic_json(STATE / 'providers.json', telemetry)
                (STATE / 'providers-error.json').unlink(missing_ok=True)
            else:
                atomic_json(STATE / 'providers-error.json', {
                    'error': 'msam-provider-pulse module unavailable',
                    'at': time.time(),
                })
        except Exception as error:
            atomic_json(STATE / 'providers-error.json', {'error': str(error), 'at': time.time()})
            if not (STATE / 'providers.json').exists():
                atomic_json(STATE / 'providers.json', {'error': str(error), 'providers': {}, 'terminal_agents': []})
        STOP.wait(30)


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
    os.environ.update(environment())
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    module = load_module('metrics', 'msam-metrics.py')

    def report(reading):
        detail = {'version': VERSION, 'components': COMPONENT_VERSIONS,
                  'pid': os.getpid(), 'heartbeat': time.time(),
                  'updates': not (STATE / 'updater-error.json').exists(),
                  'agents': not read_json(STATE / 'agents.json', {}).get('error'), **reading}
        # A status that cannot be written now is written on the next round.
        # The service must not stop over it: nothing would start it again.
        with contextlib.suppress(OSError):
            atomic_json(STATE / 'status.json', detail)

    with singleton(STATE / 'daemon.lock'):
        threading.Thread(target=background_updates, daemon=True).start()
        threading.Thread(target=background_inventory, daemon=True).start()
        threading.Thread(target=background_provider_pulse, daemon=True).start()
        reading = {'metrics': False}
        try:
            while not STOP.is_set():
                started = time.monotonic()
                # Said before a reading as well as after it. A reading can take
                # many seconds (on Windows each one starts a PowerShell), and
                # the service counts as running only while its heartbeat is
                # recent: stamped once a round, a slow reading made a running
                # service look stopped.
                report(reading)
                try:
                    atomic_json(STATE / 'metrics.json', sample_metrics(module))
                    reading = {'metrics': True}
                except Exception as error:
                    reading = {'metrics': False, 'error': str(error)}
                reading['sampleSeconds'] = round(time.monotonic() - started, 1)
                report(reading)
                STOP.wait(max(0.1, 2 - (time.monotonic() - started)))
        finally:
            with contextlib.suppress(OSError):
                atomic_json(STATE / 'status.json', {'version': VERSION, 'components': COMPONENT_VERSIONS,
                                                    'heartbeat': 0, 'pid': os.getpid(), 'metrics': False})


def serve_as_service():
    """`serve` for the Windows service, which has nowhere to print.

    What stopped the work is left where the installer looks when the service
    does not come up, and the work is started again: Windows restarts a
    service that crashes, not one that stops by itself.
    """
    note = STATE / 'service-error.json'
    note.unlink(missing_ok=True)
    while True:
        try:
            return serve()
        except Exception as error:
            with contextlib.suppress(OSError):
                atomic_json(note, {'message': str(error), 'at': time.time()})
        if STOP.wait(SERVICE_RETRY):
            return


def stream_metrics(loop):
    """Prints each new reading. The app shows the last one it was sent and
    nothing else, so a stream that ends is a display that has stopped: it rides
    out a service that is being replaced, a reading that failed and a file it
    could not open just then, and ends only when that lasts."""
    last = troubled = None
    while True:
        text = None
        try:
            current = status()
            if not current['running']:
                raise RuntimeError('The MSAM host service is stopped. Start it from Manage Hosts.')
            if not current.get('metrics'):
                raise RuntimeError(current.get('error', 'The host service has no current metrics.'))
            path = STATE / 'metrics.json'
            stamp = path.stat().st_mtime_ns
            if stamp != last:
                text = path.read_text().strip()
            troubled = None
        except (RuntimeError, OSError):
            now = time.monotonic()
            troubled = now if troubled is None else troubled
            if not loop or now - troubled >= STREAM_PATIENCE:
                raise
        if text is not None:
            print(text, flush=True)
            last = stamp
        if not loop:
            return
        time.sleep(0.5)


def stream_attention(loop):
    """The notification feed for the app's background connection: one small line
    when what needs attention changes, and nothing else. It carries no metrics
    and attaches to no Herdr session, so watching a host this way costs it
    almost nothing and does not disturb the layout of anyone's terminal."""
    last = printed_at = None
    while True:
        current, now = attention(), time.monotonic()
        if current != last or printed_at is None or now - printed_at >= ATTENTION_HEARTBEAT:
            print(ATTENTION_PREFIX + json.dumps(current), flush=True)
            last, printed_at = current, now
        if not loop:
            return
        time.sleep(1)


class RequestHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for MSAM host agent API endpoints."""

    def log_message(self, format, *args):
        if os.environ.get('MSAM_DEBUG'):
            super().log_message(format, *args)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == '/api/metrics/report':
            period = query.get('period', [None])[0]
            from_time = query.get('from', [None])[0]
            to_time = query.get('to', [None])[0]
            fmt = query.get('format', ['json'])[0]
            cost_str = query.get('cost_per_kwh', [None])[0]

            metrics_mod = load_module('metrics', 'msam-metrics.py')

            start_time = None
            end_time = None
            try:
                cost_per_kwh = float(cost_str) if cost_str is not None else None
                if period:
                    start_time, end_time = metrics_mod.parse_period(period)
                if from_time:
                    start_time = metrics_mod.parse_iso_timestamp(from_time)
                if to_time:
                    end_time = metrics_mod.parse_iso_timestamp(to_time)
            except ValueError as e:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode('utf-8'))
                return

            db_target = getattr(self.server, 'db_path', None) or getattr(self.server, 'db', None)
            if db_target is None:
                db_target = metrics_mod.default_metrics_db_path()

            if isinstance(db_target, metrics_mod.MetricsHistoryDB):
                db = db_target
                close_db = False
            else:
                db = metrics_mod.MetricsHistoryDB(db_path=db_target)
                close_db = True

            try:
                report = metrics_mod.generate_metrics_report(
                    db=db,
                    start_time=start_time,
                    end_time=end_time,
                    format=fmt,
                    cost_per_kwh=cost_per_kwh
                )
            finally:
                if close_db:
                    db.close()

            self.send_response(200)
            if fmt == 'json' or isinstance(report, dict):
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                body = json.dumps(report) if isinstance(report, dict) else report
                self.wfile.write(body.encode('utf-8'))
            elif fmt == 'csv':
                self.send_header('Content-Type', 'text/csv')
                self.end_headers()
                self.wfile.write(report.encode('utf-8'))
            else:
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write(report.encode('utf-8'))
        else:
            self.send_response(404)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Not found'}).encode('utf-8'))


def main():
    global HOME, STATE, UPDATER_STATE
    parser = argparse.ArgumentParser()
    parser.add_argument('--home')
    parser.add_argument('command', choices=['serve', 'windows-service', 'status', 'metrics', 'agents', 'attention', 'updates', 'self-test',
                                            'analyze-task', 'report', 'monitor'])
    parser.add_argument('args', nargs='*')
    parser.add_argument('--loop', action='store_true')
    options, remaining = parser.parse_known_args()
    if options.home:
        HOME = Path(options.home)
        STATE = HOME / '.local/state/msam-host-agent'
        UPDATER_STATE = HOME / '.local/state/msam-agent-updater'
    if options.command == 'windows-service':
        adopt_account()
    os.environ.update(environment())
    if options.command == 'serve':
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: STOP.set())
        serve()
    elif options.command == 'windows-service':
        load_module('windows_service', 'msam-host-service-windows.py').run(serve_as_service, STOP)
    elif options.command == 'status':
        print('MSAM_HOST_STATUS=' + json.dumps(status()))
    elif options.command == 'metrics':
        stream_metrics(options.loop)
    elif options.command == 'agents':
        print(json.dumps(read_json(STATE / 'agents.json', {'sessions': []})))
    elif options.command == 'attention':
        stream_attention(options.loop)
    elif options.command == 'analyze-task':
        transcript_path = options.args[0] if options.args else ""
        target_provider = options.args[1] if len(options.args) > 1 else "codex"
        print(json.dumps(analyze_task(transcript_path, target_provider)))
    elif options.command == 'report':
        cmd_idx = sys.argv.index('report')
        load_module('metrics', 'msam-metrics.py').run_report_cli(sys.argv[cmd_idx + 1:])
    elif options.command == 'monitor':
        cmd_idx = sys.argv.index('monitor')
        load_module('metrics', 'msam-metrics.py').run_monitor_cli(sys.argv[cmd_idx + 1:])
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
