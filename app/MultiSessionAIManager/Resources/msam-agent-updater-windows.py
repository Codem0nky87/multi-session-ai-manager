#!/usr/bin/env python3
"""Windows implementation of the durable MSAM updater protocol."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location('host_agent', Path(__file__).with_name('msam-host-agent.py'))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
STATE = Path(os.environ.get('MSAM_AGENT_UPDATER_STATE_DIR', str(host.UPDATER_STATE)))
TOOLS = {'claude': ('claude', '@anthropic-ai/claude-code'), 'codex': ('codex', '@openai/codex'), 'antigravity': ('agy', None)}


def command(args, timeout=30, env=None):
    # .cmd shims are launched by Windows itself; every argument is generated
    # from an allowlisted tool or passed through a quoted PowerShell array.
    executable = shutil.which(args[0]) or args[0]
    if str(executable).lower().endswith(('.cmd', '.bat')):
        quote = lambda v: "'" + str(v).replace("'", "''") + "'"
        script = '& ' + ' '.join(quote(v) for v in [executable, *args[1:]]) + '; exit $LASTEXITCODE'
        args = ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script]
    return subprocess.run(args, env=env or os.environ, capture_output=True, text=True, timeout=timeout, check=True).stdout


def version(text):
    match = re.search(r'\b(\d+(?:\.\d+){1,3})(?:-[\w.-]+)?', text)
    return match.group(0) if match else None


def probe(tool):
    executable, package = TOOLS[tool]
    path = shutil.which(executable)
    value = {'tool': tool, 'installed': None, 'latest': None, 'channel': None,
             'method': 'unknown', 'executablePath': path, 'error': None}
    if not path:
        value['error'] = 'not installed'
        return value
    value['installed'] = version(command([path, '--version']))
    owners = []
    if package:
        for manager in ('npm', 'pnpm'):
            if not shutil.which(manager):
                continue
            try:
                command([manager, 'list', '-g', '--depth=0', package])
                prefix = command([manager, 'prefix', '-g'] if manager == 'npm' else [manager, 'bin', '-g']).strip()
                # Match the actual executable, not another global installation.
                if Path(path).parent.resolve() == Path(prefix).resolve():
                    owners.append(manager)
            except subprocess.SubprocessError:
                pass
    if len(owners) > 1:
        value.update(method='ambiguous', error='Multiple package managers own this installation.')
    elif owners:
        value['method'] = owners[0]
        value['latest'] = version(command([owners[0], 'view', package, 'version']))
        value['channel'] = 'latest'
    else:
        value['error'] = 'This installation does not expose a verified update method. Update it with its original installer.'
    return value


def update_tool(tool):
    before = probe(tool)
    if before['method'] not in ('npm', 'pnpm') or not before['installed'] or not before['latest']:
        raise RuntimeError(before['error'] or 'Update method unavailable.')
    parts = lambda v: tuple(int(p) for p in v.split('-')[0].split('.'))
    if parts(before['latest']) <= parts(before['installed']):
        raise RuntimeError('No newer verified version is available.')
    package = TOOLS[tool][1]
    command([before['method'], 'install' if before['method'] == 'npm' else 'add', '-g', package + '@latest'], timeout=600)
    after = probe(tool)
    if after['executablePath'] != before['executablePath'] or after['installed'] != before['latest']:
        raise RuntimeError('The updated executable did not match the expected version and installation.')


def request(text, batch):
    if len(text.encode()) > 1048576 or '\0' in text:
        raise ValueError('Invalid request size.')
    lines = text.splitlines()
    if len(lines) < 5 or lines[0] != 'MSAM_AGENT_UPDATE_REQUEST\t1' or lines[1] != 'BATCH\t' + batch or lines[-1] != 'END':
        raise ValueError('Invalid update request.')
    if lines[2] not in ('POLICY\tmanualApproval', 'POLICY\tverifiedVendorArtifacts'):
        raise ValueError('Invalid update policy.')
    tools, targets, seen = [], [], set()
    for line in lines[3:-1]:
        fields = line.split('\t')
        if fields[0] == 'UPDATE' and len(fields) == 2 and fields[1] in TOOLS and fields[1] not in tools and not targets:
            tools.append(fields[1])
        elif fields[0] == 'TARGET' and len(fields) == 7 and fields[5] in TOOLS:
            _, session, socket, pane, pid, tool, conversation = fields
            for value, maximum in ((session, 128), (socket, 1024), (pane, 128), (conversation, 2048)):
                if not value or len(value.encode()) > maximum or any(ord(c) < 32 or ord(c) == 127 for c in value):
                    raise ValueError('Invalid target field.')
            if not (socket.startswith(('/', '\\\\')) or re.match(r'^[A-Za-z]:[\\/]', socket)):
                raise ValueError('Socket path must be absolute.')
            if not re.fullmatch(r'%?[A-Za-z0-9][A-Za-z0-9._:%@+-]*', pane) or (socket, pane) in seen:
                raise ValueError('Invalid or duplicate pane.')
            if pid != '-' and (not pid.isdigit() or int(pid) <= 0):
                raise ValueError('Invalid process identity.')
            seen.add((socket, pane))
            targets.append(dict(session=session, socket=socket, pane=pane, pid=pid, tool=tool,
                                conversation=conversation, phase='pending', attempts=0, exitAttempts=0, message='queued'))
        else:
            raise ValueError('Invalid request record.')
    if not tools and not targets:
        raise ValueError('Empty request.')
    return dict(id=batch, tools=tools, targets=targets, phase='updating', updated=[])


def current():
    return host.read_json(STATE / 'current.json')


def save(batch):
    host.atomic_json(STATE / 'current.json', batch)
    host.atomic_json(STATE / 'batches' / batch['id'] / 'state.json', batch)


def snapshot(target):
    env = dict(os.environ, HERDR_SOCKET_PATH=target['socket'])
    # A transport/parse failure is unknown, not evidence that an agent exited.
    # `agent get` exits 1 at a shell prompt. A successful, well-formed list
    # distinguishes that expected absence from an unreachable Herdr server.
    listing = json.loads(command(['herdr', 'agent', 'list'], env=env))['result']['agents']
    if not isinstance(listing, list) or any(not isinstance(item, dict) for item in listing):
        raise ValueError('Invalid Herdr agent inventory.')
    matches = [item for item in listing if item.get('pane_id') == target['pane']]
    if len(matches) > 1:
        raise ValueError('Duplicate Herdr pane identity.')
    agent = json.loads(command(['herdr', 'agent', 'get', target['pane']], env=env))['result']['agent'] if matches else None
    info = json.loads(command(['herdr', 'pane', 'process-info', '--pane', target['pane']], env=env)).get('result', {}).get('process_info', {})
    processes = info.get('foreground_processes', [])
    pid = processes[0].get('pid') if processes else info.get('foreground_pid', info.get('shell_pid'))
    return agent, str(pid) if pid else None


def expected(agent, target):
    native = agent.get('agent_session') or {}
    kind = native.get('agent', agent.get('kind', agent.get('agent')))
    aliases = ('agy', 'antigravity', 'antigravity-cli') if target['tool'] == 'antigravity' else (target['tool'],)
    return kind in aliases and native.get('value') == target['conversation']


def resume_arguments(tool, conversation):
    resume = 'resume' if tool == 'codex' else '--conversation' if tool == 'antigravity' else '--resume'
    args = [resume, conversation]
    # New Codex builds reject their shared Windows daemon in an elevated
    # terminal. Herdr already owns this terminal; use the supported foreground
    # mode when available, retaining compatibility with older CLI versions.
    if tool == 'codex' and '--no-daemon' in command([TOOLS[tool][0], '--help']):
        args.insert(0, '--no-daemon')
    return args


def roll(target, batch):
    if target['phase'] in ('restored', 'failed'):
        return
    agent, pid = snapshot(target)
    if target['phase'] == 'pending':
        state = agent.get('agent_status', agent.get('status', agent.get('state'))) if agent else 'unknown'
        if state not in ('idle', 'done'):
            target['message'] = 'working' if state == 'working' else 'attention_' + str(state)
            return
        if not expected(agent, target) or not pid or pid != target['pid']:
            target.update(phase='failed', message='identity_changed')
            return
        target.update(phase='exiting', message='exit_requested')
        save(batch)
    env = dict(os.environ, HERDR_SOCKET_PATH=target['socket'])
    if target['phase'] == 'exiting':
        if agent and not expected(agent, target):
            target.update(phase='failed', message='identity_changed'); return
        if agent and pid and pid != target['pid']:
            target.update(phase='restored', message='restored'); return
        if agent:
            if not pid:
                target.update(phase='failed', message='process_unavailable'); return
            if target['exitAttempts'] >= 3:
                target.update(phase='failed', message='exit_attempts_exhausted'); return
            target['exitAttempts'] += 1
            save(batch)
            command(['herdr', 'agent', 'prompt', target['pane'], '/exit'], env=env)
            target['message'] = 'waiting_for_exit'
            return
        if not pid or pid == target['pid']:
            target['message'] = 'waiting_for_exit'; return
        target['phase'] = 'exited'
        save(batch)
    if target['phase'] == 'exited':
        if agent:
            if expected(agent, target) and pid and pid != target['pid']:
                target.update(phase='restored', message='restored')
            elif not (agent.get('agent_session') or {}).get('value') and target.get('restoreStartedAt'):
                # A new process may be at sign-in or still publishing its native
                # ID. Never send another exit/start into that terminal.
                if time.time() - target['restoreStartedAt'] < 330:
                    target['message'] = 'attention_waiting_for_native_session'
                else:
                    target.update(phase='failed', message='restore_identity_unavailable_check_agent_sign_in')
            else:
                target.update(phase='failed', message='identity_changed')
            return
        if target['attempts'] >= 3:
            target.update(phase='failed', message='restore_attempts_exhausted'); return
        target['attempts'] += 1
        target['restoreStartedAt'] = time.time()
        save(batch)
        tool = target['tool']
        kind = 'agy' if tool == 'antigravity' else tool
        command(['herdr', 'agent', 'start', 'msam_' + batch['id'][:8].lower() + '_' + str(batch['targets'].index(target)),
                 '--kind', kind, '--pane', target['pane'], '--timeout', '300000', '--', *resume_arguments(tool, target['conversation'])], timeout=330, env=env)
        fresh, new_pid = snapshot(target)
        if fresh and expected(fresh, target) and new_pid and new_pid != target['pid']:
            target.update(phase='restored', message='restored')


def run_once():
    batch = current()
    if not batch or batch['phase'] in ('complete', 'completed_with_failures', 'failed_update'):
        queued = sorted((STATE / 'queue').glob('*.request'))
        if not queued:
            return
        path = queued[0]
        batch = request(path.read_text(), path.stem)
        save(batch)
        path.unlink()
    if batch['phase'] == 'updating':
        for tool in batch['tools']:
            if tool in batch['updated']:
                continue
            try:
                update_tool(tool)
            except Exception as error:
                batch.update(phase='failed_update', error=str(error))
                save(batch); return
            batch['updated'].append(tool); save(batch)
        batch['phase'] = 'rolling'; save(batch)
    for target in batch['targets']:
        try:
            roll(target, batch)
        except Exception as error:
            target['message'] = 'attention_' + str(error).replace('\n', ' ')[:200]
        save(batch)
    if all(t['phase'] in ('restored', 'failed') for t in batch['targets']):
        batch['phase'] = 'completed_with_failures' if any(t['phase'] == 'failed' for t in batch['targets']) else 'complete'
        save(batch)


def status_output():
    batch = current()
    print('MSAM_AGENT_UPDATE_STATUS\t1')
    if not batch:
        print('BATCH\t-\tidle\nCOUNTS\t0\t0\t0\t0\t0\t0\nEND'); return
    print('BATCH\t' + batch['id'] + '\t' + batch['phase'])
    counts = [len(batch['targets']), 0, 0, 0, 0, 0]
    for i, target in enumerate(batch['targets'], 1):
        phase, message = target['phase'], target['message'].replace('\t', ' ').replace('\n', ' ')
        counts[1 if phase == 'restored' else 5 if phase == 'failed' else 4 if phase in ('exited', 'exiting') else 2 if message == 'working' else 3] += 1
        print(f'TARGET\t{i}\t{phase}\t{target["attempts"]}\t{message}')
    print('COUNTS\t' + '\t'.join(map(str, counts)) + '\nEND')


def main():
    for name in ('incoming', 'queue'):
        (STATE / name).mkdir(parents=True, exist_ok=True)
    action = sys.argv[1]
    if action == 'protocol':
        print(1)
    elif action == 'verify-service':
        print('MSAM_AGENT_UPDATER_VERIFY\t1\tready')
    elif action == 'status':
        status_output()
    elif action == 'version':
        print(json.dumps(probe(sys.argv[2])))
    else:
        with host.singleton(STATE / 'worker.lock'):
            if action == 'submit':
                batch = str(uuid.UUID(sys.argv[2])).upper()
                path = STATE / 'incoming' / (batch + '.request')
                request(path.read_text(), batch)
                destination = STATE / 'queue' / path.name
                if not destination.exists() and (not current() or current()['id'] != batch):
                    os.replace(path, destination)
                print('MSAM_AGENT_UPDATE_ACCEPTED\t1\t' + batch + '\tqueued')
            elif action == 'run-once':
                run_once()
            else:
                raise ValueError('Unknown updater operation.')


if __name__ == '__main__':
    try:
        main()
    except BlockingIOError:
        sys.exit(75)
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
