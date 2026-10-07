#!/usr/bin/env python3
"""Native Windows SCM adapter; runs under the account owning the LLM agents."""
import ctypes
import getpass
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from ctypes import wintypes

NAME = 'MSAMHostAgent'


def api():
    if os.name != 'nt':
        raise RuntimeError('Windows Services are only available on Windows.')
    return ctypes.WinDLL('advapi32', use_last_error=True)


def run(serve, stop):
    advapi = api()
    class Status(ctypes.Structure):
        _fields_ = [(key, wintypes.DWORD) for key in ('type', 'state', 'accepted', 'exitCode', 'specificExitCode', 'checkpoint', 'waitHint')]
    handler_type = ctypes.WINFUNCTYPE(wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p, ctypes.c_void_p)
    main_type = ctypes.WINFUNCTYPE(None, wintypes.DWORD, ctypes.POINTER(wintypes.LPWSTR))
    class Entry(ctypes.Structure):
        _fields_ = [('name', wintypes.LPWSTR), ('main', main_type)]
    advapi.RegisterServiceCtrlHandlerExW.argtypes = [wintypes.LPCWSTR, handler_type, ctypes.c_void_p]
    advapi.RegisterServiceCtrlHandlerExW.restype = wintypes.HANDLE
    advapi.SetServiceStatus.argtypes = [wintypes.HANDLE, ctypes.POINTER(Status)]
    advapi.SetServiceStatus.restype = wintypes.BOOL
    advapi.StartServiceCtrlDispatcherW.argtypes = [ctypes.POINTER(Entry)]
    advapi.StartServiceCtrlDispatcherW.restype = wintypes.BOOL
    handle = None
    def report(state, error=0):
        accepted = 5 if state == 4 else 0  # STOP | SHUTDOWN while running.
        value = Status(16, state, accepted, error, 0, 0, 20000 if state == 3 else 0)
        if not advapi.SetServiceStatus(handle, ctypes.byref(value)):
            raise ctypes.WinError(ctypes.get_last_error())
    @handler_type
    def control(code, _event, _data, _context):
        if code in (1, 5):
            report(3)
            stop.set()
        return 0
    @main_type
    def main(_count, _argv):
        nonlocal handle
        handle = advapi.RegisterServiceCtrlHandlerExW(NAME, control, None)
        if not handle:
            return
        try:
            report(2)
            report(4)
            serve()
            report(1)
        except Exception:
            report(1, 1)
    table = (Entry * 2)(Entry(NAME, main), Entry(None, main_type()))
    if not advapi.StartServiceCtrlDispatcherW(table):
        raise ctypes.WinError(ctypes.get_last_error())


def binary_path(home):
    return subprocess.list2cmdline([sys.executable, str(Path(__file__).resolve().parent / 'msam-host-agent.py'), '--home', home, 'windows-service'])


def configure(home):
    api()
    query = "$s = Get-CimInstance Win32_Service -Filter \"Name='MSAMHostAgent'\"; if ($s) { $s | Select-Object StartName | ConvertTo-Json -Compress }"
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', query], capture_output=True, text=True, check=True)
    if not result.stdout.strip():
        root = Path(__file__).resolve().parent
        manifest = json.loads((root / 'manifest.json').read_text())
        release = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()[:20]
        # A failed first install rolls back `current`; the immutable release
        # remains available for this one-time registration command.
        script = str(Path(home) / '.local/libexec/msam-host-agent/releases' / release / Path(__file__).name)
        raise RuntimeError('Create the Windows service once from an elevated terminal under the agent account: python "' + script + '" register "' + home + '" "DOMAIN\\USER". The password is prompted securely; it is not stored by MSAM.')
    account = json.loads(result.stdout)['StartName'].lower()
    owner = subprocess.check_output(['whoami'], text=True).strip().lower()
    account = account.replace('.\\', os.environ.get('COMPUTERNAME', '').lower() + '\\', 1)
    if account != owner:
        raise RuntimeError('MSAMHostAgent must run as ' + owner + ', the account that owns the LLM agents.')
    subprocess.run(['sc.exe', 'config', NAME, 'binPath=', binary_path(home), 'start=', 'auto'], check=True, capture_output=True)
    subprocess.run(['sc.exe', 'failure', NAME, 'reset=', '86400', 'actions=', 'restart/5000/restart/15000/restart/60000'], check=True, capture_output=True)


def register(home, account):
    advapi = api()
    advapi.OpenSCManagerW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD]
    advapi.OpenSCManagerW.restype = wintypes.HANDLE
    advapi.CreateServiceW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
        wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR,
        ctypes.POINTER(wintypes.DWORD), wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR]
    advapi.CreateServiceW.restype = wintypes.HANDLE
    advapi.CloseServiceHandle.argtypes = [wintypes.HANDLE]
    manager = advapi.OpenSCManagerW(None, None, 2)
    if not manager:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        password = getpass.getpass('Service account password: ')
        service = advapi.CreateServiceW(manager, NAME, 'MSAM Host Agent', 0xF01FF, 16, 2, 1,
            binary_path(home), None, None, None, account, password)
        password = None
        if not service:
            raise ctypes.WinError(ctypes.get_last_error())
        advapi.CloseServiceHandle(service)
    finally:
        advapi.CloseServiceHandle(manager)
    print('Registered MSAMHostAgent. Grant this account Log on as a service, then install from Manage Hosts.')


if __name__ == '__main__':
    if sys.argv[1] == 'configure':
        configure(sys.argv[2])
    elif sys.argv[1] == 'register':
        register(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit('Expected configure HOME or register HOME ACCOUNT.')
