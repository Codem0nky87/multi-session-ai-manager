#!/usr/bin/env python3
"""The host agent as a Windows service.

It runs as SYSTEM, the one account Windows starts a service under without
being given a password, so the app can set it up by itself. What it does is
for the account owning the LLM agents, so it works in that account's profile:
`configure` writes the account down and the agent takes it on when it starts.
"""
import csv
import ctypes
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
from ctypes import wintypes

NAME = 'MSAMHostAgent'
# What of the account's environment the service has to take on to work in its profile.
ACCOUNT_VARIABLES = ('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'HOMEDRIVE', 'HOMEPATH', 'USERNAME', 'USERDOMAIN')


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


def is_administrator():
    return bool(ctypes.windll.shell32.IsUserAnAdmin())


def state_directory(home):
    return Path(home) / '.local/state/msam-host-agent'


def user_path():
    """The account's own PATH, as its registry has it."""
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
            return winreg.QueryValueEx(key, 'Path')[0]
    except OSError:
        return ''


def record_account(home):
    """Writes down whose agents the service looks after.

    This runs as that account. The service does not: as SYSTEM it has a profile
    and a registry of its own, where it would find none of the account's
    sessions, tools or sign-ins.
    """
    row = subprocess.check_output(['whoami', '/user', '/fo', 'csv', '/nh'], text=True).strip()
    account = {'sid': next(csv.reader([row]))[-1],
               'environment': {name: os.environ[name] for name in ACCOUNT_VARIABLES if os.environ.get(name)},
               'path': user_path()}
    directory = state_directory(home)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'account.json').write_text(json.dumps(account, indent=1) + '\n')


def service_account():
    """The account the service is registered to run as; None when there is no service."""
    query = "$s = Get-CimInstance Win32_Service -Filter \"Name='MSAMHostAgent'\"; if ($s) { $s | Select-Object StartName | ConvertTo-Json -Compress }"
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', query], capture_output=True, text=True, check=True)
    if not result.stdout.strip():
        return None
    return json.loads(result.stdout)['StartName'].lower()


def sc(*arguments):
    result = subprocess.run(['sc.exe', *arguments], capture_output=True, text=True, errors='replace')
    if result.returncode != 0:
        # sc.exe explains itself on its standard output.
        said = ' '.join((result.stdout + ' ' + result.stderr).split())
        raise RuntimeError('Windows refused to ' + arguments[0] + ' the ' + NAME + ' service: ' + said)


def configure(home):
    """Creates the service, or points the one that is there at these files."""
    api()
    if not is_administrator():
        raise RuntimeError('The host service runs as the SYSTEM account, and setting it up takes an administrator. '
                           'Connect as an account that is in the Administrators group of this host.')
    record_account(home)
    account = service_account()
    if account is None:
        sc('create', NAME, 'binPath=', binary_path(home), 'start=', 'auto', 'obj=', 'LocalSystem',
           'DisplayName=', 'MSAM Host Agent')
        sc('description', NAME, 'AI Manager host agent: agents, updates and metrics for one account.')
    else:
        # A build before this one had the service created by hand under the
        # account itself, with its password. That one is left under it.
        owner = subprocess.check_output(['whoami'], text=True).strip().lower()
        account = account.replace('.\\', os.environ.get('COMPUTERNAME', '').lower() + '\\', 1)
        if account not in ('localsystem', owner):
            raise RuntimeError(NAME + ' is registered to run as ' + account + '. It has to run as SYSTEM. Remove it from '
                               'an elevated terminal on the host with "sc delete ' + NAME + '", then set the host up again.')
        sc('config', NAME, 'binPath=', binary_path(home), 'start=', 'auto')
    sc('failure', NAME, 'reset=', '86400', 'actions=', 'restart/5000/restart/15000/restart/60000')


def register(home, account):
    """Creates the service under an account of its own instead of SYSTEM.

    Not needed for setup, and not used by it. Run from an elevated terminal:
    the service manager wants the account's password, which is asked for here
    and not kept.
    """
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
    try:
        if sys.argv[1] == 'configure':
            configure(sys.argv[2])
        elif sys.argv[1] == 'register':
            register(sys.argv[2], sys.argv[3])
        else:
            raise SystemExit('Expected configure HOME or register HOME ACCOUNT.')
    except Exception as error:
        # The app shows this to the user as it is.
        print(str(error), file=sys.stderr)
        sys.exit(1)
