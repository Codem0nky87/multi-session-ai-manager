"""The browser space's placeholder, run under a real pty."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import termios
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-browser-space.sh'
FILL = '░'


class Placeholder:
    def __init__(self, rows, cols, ident='7f3a2c'):
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.execvp('sh', ['sh', str(SCRIPT), ident])
        self.resize(rows, cols)

    def resize(self, rows, cols):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def read(self, seconds=0.6):
        data = b''
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                try:
                    data += os.read(self.master, 65536)
                except OSError:
                    break
        return data.decode('utf-8', 'replace')

    def children(self):
        out = subprocess.run(['pgrep', '-P', str(self.pid)], capture_output=True, text=True).stdout.split()
        return [int(pid) for pid in out]

    def exited(self):
        try:
            return os.waitpid(self.pid, os.WNOHANG)[0] == self.pid
        except ChildProcessError:
            return True

    def close(self):
        try:
            os.close(self.master)
        except OSError:
            pass
        time.sleep(0.5)
        if not self.exited():
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)


class PlaceholderTests(unittest.TestCase):
    def start(self, rows, cols):
        placeholder = Placeholder(rows, cols)
        self.addCleanup(placeholder.close)
        time.sleep(0.2)
        return placeholder

    def test_it_marks_its_pane_with_its_id_and_size(self):
        shown = self.start(10, 40).read()
        self.assertIn('\x1b[1;1H[[AIM-BROWSER 7f3a2c 40x10]]', shown)

    def test_it_fills_every_cell(self):
        shown = self.start(10, 40).read()
        self.assertEqual(shown.count(FILL), 40 * 10)
        for row in range(1, 11):
            self.assertIn('\x1b[%d;1H%s' % (row, FILL * 40), shown)

    def test_it_repaints_with_the_new_size_after_a_resize(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        placeholder.resize(12, 50)
        shown = placeholder.read()
        self.assertIn('[[AIM-BROWSER 7f3a2c 50x12]]', shown)
        self.assertEqual(shown.count(FILL), 50 * 12)

    def test_a_pane_too_narrow_for_the_marker_shows_only_the_fill(self):
        shown = self.start(5, 12).read()
        self.assertNotIn('AIM-BROWSER', shown)
        self.assertEqual(shown.count(FILL), 12 * 5)

    def test_it_keeps_one_helper_process_however_often_it_is_resized(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        for rows, cols in [(12, 50), (8, 30), (20, 60)]:
            placeholder.resize(rows, cols)
            placeholder.read(0.4)
        self.assertEqual(len(placeholder.children()), 1)

    def test_ctrl_c_does_not_close_the_space(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        os.write(placeholder.master, b'\x03')
        time.sleep(0.3)
        self.assertFalse(placeholder.exited())

    def test_it_ends_with_its_helper_when_the_pane_is_closed(self):
        placeholder = self.start(10, 40)
        placeholder.read()
        children = placeholder.children()
        self.assertEqual(len(children), 1)
        self.assertFalse(placeholder.exited())
        os.close(placeholder.master)
        time.sleep(0.6)
        self.assertTrue(placeholder.exited())
        self.assertEqual([pid for pid in children if os.path.exists('/proc/%d' % pid)], [])


if __name__ == '__main__':
    unittest.main()
