#!/usr/bin/env python3
"""Transactional management of the per-user metrics collector over SSH."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

PREFIX = 'MSAM_METRICS_STATUS='


def ps_identity(text):
    parts = text.split(None, 6)
    if len(parts) != 7 or int(parts[0]) != os.getuid():
        return None
    return ' '.join(parts[1:6]), parts[6]


def process_identity(pid):
    try:
        if sys.platform.startswith('linux'):
            root = Path('/proc') / str(pid)
            if root.stat().st_uid != os.getuid():
                return None
            stat = (root / 'stat').read_text()
            fields = stat[stat.rfind(')') + 2:].split()
            if fields[0] == 'Z':
                return None
            args = [v.decode('utf-8', 'replace') for v in (root / 'cmdline').read_bytes().split(b'\0') if v]
            return fields[19], args
        text = subprocess.check_output(['ps', '-p', str(pid), '-o', 'uid=,lstart=,command='],
                                       stderr=subprocess.DEVNULL, timeout=2).decode().strip()
        return ps_identity(text)
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def is_collector(identity, target):
    if identity is None:
        return False
    args = identity[1]
    if isinstance(args, str):
        # ps on macOS flattens argv without quoting paths containing spaces.
        suffix = str(target) + ' --loop'
        if not args.endswith(suffix):
            return False
        prefix = args[:-len(suffix)].strip()
        return not prefix or bool(re.fullmatch(r'(?:.*/)?[Pp]ython[\d.]*(?: -u)?', prefix))
    if args == [str(target), '--loop']:
        return True
    if not args or not re.fullmatch(r'[Pp]ython[\d.]*', os.path.basename(args[0])):
        return False
    return args[1:] in ([str(target), '--loop'], ['-u', str(target), '--loop'])


def collectors(target):
    result = {}
    if sys.platform.startswith('linux'):
        pids = [int(p.name) for p in Path('/proc').iterdir() if p.name.isdigit()]
    else:
        text = subprocess.check_output(['ps', '-axo', 'pid=,uid=,lstart=,command='], timeout=3).decode()
        for line in text.splitlines():
            pid, row = line.strip().split(None, 1)
            identity = ps_identity(row)
            if int(pid) != os.getpid() and is_collector(identity, target):
                result[int(pid)] = identity
        return result
    for pid in pids:
        if pid == os.getpid():
            continue
        identity = process_identity(pid)
        if is_collector(identity, target):
            result[pid] = identity
    return result


def stop_collectors(target):
    original = collectors(target)
    for sig, wait in ((signal.SIGTERM, 2.0), (signal.SIGKILL, 1.0)):
        for pid, identity in original.items():
            if process_identity(pid) == identity:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, sig)
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            if all(process_identity(pid) != identity for pid, identity in original.items()):
                return
            time.sleep(0.05)
    if any(process_identity(pid) == identity for pid, identity in original.items()):
        raise RuntimeError('An old metrics process could not be stopped.')


def state_directory(target):
    return target.parent.parent / 'state/msam-metrics'


def status(target):
    data = target.read_bytes() if target.is_file() else b''
    version = re.search(rb'^METRICS_VERSION = [\'"]([^\'"\n]+)[\'"]', data, re.MULTILINE)
    return {'installed': bool(data), 'disabled': (state_directory(target) / 'disabled').exists(),
            'version': version.group(1).decode() if version else ('Legacy' if data else ''),
            'digest': hashlib.sha256(data).hexdigest() if data else ''}


def candidate_data(candidate, target, digest):
    if candidate.parent != target.parent or not candidate.name.startswith('.msam-metrics-'):
        raise ValueError('Invalid staging path.')
    data = candidate.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('The uploaded collector did not match the app bundle.')
    compile(data, str(candidate), 'exec')
    return data


def manage(action, target, candidate=None, digest='', replace=False):
    target = Path(target)
    state = state_directory(target)
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (state / 'management.lock').open('a') as lock:
        # No stale lock directory if the SSH connection is interrupted.
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Metrics are being managed by another connection. Try again shortly.')
        if action == 'status':
            return status(target)
        if action == 'activate':
            candidate = Path(candidate)
            try:
                candidate_data(candidate, target, digest)
                if not replace and (target.exists() or (state / 'disabled').exists()):
                    return status(target)
                # Validation has already succeeded. Keep an inactive recovery copy,
                # then atomically replace the executable at its existing path.
                if target.is_file() and not target.with_suffix('.bak').exists():
                    shutil.copy2(target, target.with_suffix('.bak'))
                candidate.chmod(0o755)
                os.replace(candidate, target)
                (state / 'disabled').unlink(missing_ok=True)
                stop_collectors(target)
            finally:
                candidate.unlink(missing_ok=True)
        elif action == 'remove':
            # A reconnect must not silently reinstall something the user removed.
            (state / 'disabled').touch(mode=0o600)
            stop_collectors(target)
            target.unlink(missing_ok=True)
        else:
            raise ValueError('Unknown metrics management action.')
        return status(target)


def main():
    action, target = sys.argv[1:3]
    if action == 'validate':
        candidate, digest = sys.argv[3:5]
        candidate_data(Path(candidate), Path(target), digest)
        result = subprocess.run([sys.executable, candidate], capture_output=True, timeout=15, check=True)
        payload = json.loads(result.stdout)
        if not all(isinstance(payload.get(key), dict) for key in ('cpu', 'memory', 'gpu', 'disk')):
            raise ValueError('The new collector did not return a complete metrics payload.')
        print(json.dumps(payload))
        return
    result = manage(action, target, *(sys.argv[3:5] if action == 'activate' else []),
                    replace=action == 'activate' and sys.argv[5] == 'replace')
    print(PREFIX + json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
