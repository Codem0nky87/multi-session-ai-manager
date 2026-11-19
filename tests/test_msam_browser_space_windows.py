"""The Windows browser space's placeholder, started the way AI Manager starts
it: its line typed into the shell of a real pseudo-console, the kind of console
Herdr gives a pane on Windows.

Needs Windows, pywinpty and pyte (`python -m pip install pywinpty pyte`), and is
skipped anywhere else. CI runs it on a Windows machine.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

try:
    import pyte
    from winpty import PtyProcess
except ImportError:
    # On the CI's Windows machine a missing package is a failure, not a skip.
    if os.name == 'nt' and os.environ.get('GITHUB_ACTIONS'):
        raise
    pyte = PtyProcess = None

SCRIPT = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-browser-space.ps1'
FILL = '░'
WAIT = float(os.environ.get('MSAM_TEST_WAIT', '40'))


def typed_line(script, ident):
    """`BrowserSpaceCommands.windowsPlaceholderLine`, word for word."""
    path = str(script).replace('\\', '/')
    plain = all(c.isalnum() or c in '/:._-' for c in path)
    return 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File %s %s' % (
        path if plain else '"%s"' % path, ident)


class Pane:
    """A pseudo-console the size of a Herdr pane running `shell`, and the
    screen a terminal attached to it shows."""

    def __init__(self, shell, rows, cols, ident='7f3a2c'):
        self.ident = ident
        self.lock = threading.Lock()
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.Stream(self.screen)
        self.process = PtyProcess.spawn([shell], dimensions=(rows, cols))
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                text = self.process.read(4096)
            except Exception:
                return
            with self.lock:
                self.stream.feed(text)

    def open_browser_space(self, script=SCRIPT):
        """What `herdr pane run` does with the app's line: types it, then Enter.
        Nothing waits for the shell's prompt first, as nothing does there."""
        self.type(typed_line(script, self.ident) + '\r')

    def resize(self, rows, cols):
        with self.lock:
            self.screen.resize(rows, cols)
        self.process.setwinsize(rows, cols)

    def type(self, text):
        self.process.write(text)

    def rows(self):
        with self.lock:
            return list(self.screen.display)

    def marked(self, rows, cols):
        """What the app's locator asks for: the mark at the top left, and every
        other cell of the rectangle it claims the fill."""
        mark = '[[AIM-BROWSER %s %dx%d]]' % (self.ident, cols, rows)
        shown = self.rows()
        return (len(shown) >= rows and shown[0][:cols] == mark + FILL * (cols - len(mark))
                and all(row[:cols] == FILL * cols for row in shown[1:rows]))

    def filled(self, rows, cols):
        shown = self.rows()
        return len(shown) >= rows and all(row[:cols] == FILL * cols for row in shown[:rows])

    def end_placeholder(self):
        """Ends the placeholder alone, leaving the pane and its shell."""
        found = subprocess.run(
            ['powershell.exe', '-NoProfile', '-Command',
             "(Get-CimInstance Win32_Process -Filter 'ParentProcessId=%d').ProcessId" % self.process.pid],
            capture_output=True, text=True).stdout.split()
        for pid in found:
            subprocess.run(['taskkill', '/F', '/PID', pid], capture_output=True)
        return found

    def close(self):
        for end in (lambda: self.process.close(force=True), lambda: self.process.terminate(force=True)):
            try:
                end()
            except Exception:
                pass


class PlaceholderInAPane:
    """The tests, for one shell a Herdr pane may be running."""
    SHELL = None

    def start(self, rows, cols):
        pane = Pane(self.SHELL, rows, cols)
        self.addCleanup(pane.close)
        return pane

    def shown(self, pane):
        return '\n'.join(repr(row) for row in pane.rows())

    def wait(self, pane, condition):
        end = time.time() + WAIT
        while time.time() < end:
            if condition():
                return
            time.sleep(0.1)
        self.fail('never shown; alive=%s, the screen was:\n%s' % (pane.process.isalive(), self.shown(pane)))

    def test_it_marks_its_pane_with_its_id_and_size_and_fills_every_cell(self):
        pane = self.start(12, 40)
        pane.open_browser_space()
        self.wait(pane, lambda: pane.marked(12, 40))

    def test_it_repaints_with_the_new_size_after_a_resize(self):
        pane = self.start(12, 40)
        pane.open_browser_space()
        self.wait(pane, lambda: pane.marked(12, 40))
        for rows, cols in [(10, 30), (16, 60), (12, 40)]:
            pane.resize(rows, cols)
            self.wait(pane, lambda: pane.marked(rows, cols))

    def test_a_pane_too_narrow_for_the_mark_shows_only_the_fill(self):
        pane = self.start(5, 20)
        pane.open_browser_space()
        self.wait(pane, lambda: pane.filled(5, 20))

    def test_a_profile_with_a_space_in_its_name_is_found(self):
        folder = Path(tempfile.mkdtemp()) / 'Jane Smith'
        folder.mkdir()
        self.addCleanup(shutil.rmtree, folder.parent, True)
        script = folder / 'browser-space.ps1'
        # With the line ends the app sends: git may have checked this out with
        # Windows' own.
        script.write_bytes(SCRIPT.read_bytes().replace(b'\r\n', b'\n'))
        pane = self.start(12, 40)
        pane.open_browser_space(script)
        self.wait(pane, lambda: pane.marked(12, 40))

    def test_ctrl_c_does_not_close_the_space(self):
        pane = self.start(12, 40)
        pane.open_browser_space()
        self.wait(pane, lambda: pane.marked(12, 40))
        pane.type('\x03')
        time.sleep(1.5)
        self.assertTrue(pane.marked(12, 40), self.shown(pane))
        # Only a placeholder that is still running draws the new size.
        pane.resize(10, 30)
        self.wait(pane, lambda: pane.marked(10, 30))

    def test_what_was_typed_at_the_space_is_not_run_by_the_shell_underneath(self):
        pane = self.start(12, 40)
        pane.open_browser_space()
        self.wait(pane, lambda: pane.marked(12, 40))
        pane.type('echo L-E-A-K\r')
        time.sleep(1.5)
        self.assertTrue(pane.marked(12, 40), self.shown(pane))
        self.assertTrue(pane.end_placeholder(), 'the placeholder runs under the pane\'s shell')
        # The shell is back and draws its prompt over the fill.
        self.wait(pane, lambda: not pane.marked(12, 40))
        time.sleep(1.5)
        self.assertNotIn('L-E-A-K', self.shown(pane))


@unittest.skipUnless(os.name == 'nt', 'needs Windows PowerShell')
class TheLineReachesHerdrWholeTests(unittest.TestCase):
    """`BrowserSpaceCommands.runWindowsPlaceholder` hands Herdr the line as one
    argument of a command run by Windows PowerShell 5.1, which does not escape
    a double quote inside an argument by itself. The commands are the ones
    `BrowserSpaceOnWindowsTests` pins, with a program that prints its
    arguments standing in for `herdr`."""

    def arguments(self, command):
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder, True)
        printer = folder / 'arguments.py'
        printer.write_text('import json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        self.assertTrue(command.startswith('herdr '))
        script = "& '%s' '%s' %s; exit $LASTEXITCODE" % (sys.executable, printer, command[len('herdr '):])
        # As `WindowsShell.command` sends a script.
        encoded = base64.b64encode(script.encode('utf-16-le')).decode()
        ran = subprocess.run(
            ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
             '-EncodedCommand', encoded], capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        return json.loads(ran.stdout)

    def test_a_plain_profile(self):
        line = ('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass '
                '-File C:/Users/alice/.local/share/msam/browser-space.ps1 7f3a2c')
        self.assertEqual(
            self.arguments("herdr --session 'work' pane run 'w2:p1' '%s'" % line),
            ['--session', 'work', 'pane', 'run', 'w2:p1', line])

    def test_a_profile_with_a_space_in_its_name_keeps_its_quotes(self):
        command = ("herdr pane run 'w2:p1' 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
                   "-File \\\"C:/Users/Jane Smith/.local/share/msam/browser-space.ps1\\\" 7f3a2c'")
        self.assertEqual(
            self.arguments(command),
            ['pane', 'run', 'w2:p1',
             'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass '
             '-File "C:/Users/Jane Smith/.local/share/msam/browser-space.ps1" 7f3a2c'])

    def test_a_session_whose_name_has_a_quote_in_it(self):
        self.assertEqual(
            self.arguments("herdr --session 'rufus''s' workspace create --label 'Browser' --focus"),
            ['--session', "rufus's", 'workspace', 'create', '--label', 'Browser', '--focus'])


WINDOWS = os.name == 'nt' and PtyProcess is not None


@unittest.skipUnless(WINDOWS, 'needs Windows with pywinpty and pyte')
class InWindowsPowerShellTests(PlaceholderInAPane, unittest.TestCase):
    """Herdr's shell where PowerShell 7 is not installed."""
    SHELL = 'powershell.exe'


@unittest.skipUnless(WINDOWS and shutil.which('pwsh.exe'), 'needs Windows with PowerShell 7, pywinpty and pyte')
class InPowerShell7Tests(PlaceholderInAPane, unittest.TestCase):
    """Herdr's shell where PowerShell 7 is installed."""
    SHELL = 'pwsh.exe'


@unittest.skipUnless(WINDOWS, 'needs Windows with pywinpty and pyte')
class InCmdTests(PlaceholderInAPane, unittest.TestCase):
    """A Herdr configured with `default_shell = "cmd.exe"`."""
    SHELL = 'cmd.exe'


if __name__ == '__main__':
    unittest.main()
