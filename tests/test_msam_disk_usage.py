import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Resources/msam-disk-usage.py'
spec = importlib.util.spec_from_file_location('disk_usage', SOURCE)
disk_usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(disk_usage)

MIB = 1024 * 1024


def write(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'wb') as stream:
        stream.write(b'x' * size)
        stream.flush()
        os.fsync(stream.fileno())


class RealTreeTests(unittest.TestCase):
    """Runs against real files, so sizes and links are whatever the filesystem says."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def scan(self, **options):
        return disk_usage.largest_files(str(self.root), **options)

    def test_largest_files_come_first_with_their_full_paths(self):
        write(self.root / 'small.bin', 64 * 1024)
        write(self.root / 'deep/er/big.bin', 3 * MIB)
        write(self.root / 'deep/middle.bin', 1 * MIB)
        report = self.scan()
        self.assertEqual([entry['path'] for entry in report['files']],
                         [str(self.root / 'deep/er/big.bin'), str(self.root / 'deep/middle.bin'),
                          str(self.root / 'small.bin')])
        self.assertGreaterEqual(report['files'][0]['bytes'], 3 * MIB)
        self.assertEqual(report['scannedFiles'], 3)
        self.assertTrue(report['complete'])
        self.assertEqual(report['mountPoint'], str(self.root))

    def test_only_the_requested_number_of_files_is_listed(self):
        for index in range(6):
            write(self.root / f'file{index}.bin', (index + 1) * 128 * 1024)
        report = self.scan(limit=2)
        self.assertEqual([Path(entry['path']).name for entry in report['files']], ['file5.bin', 'file4.bin'])
        self.assertEqual(report['scannedFiles'], 6)

    def test_a_sparse_file_counts_for_the_space_it_occupies_not_its_length(self):
        write(self.root / 'real.bin', 2 * MIB)
        with open(self.root / 'sparse.img', 'wb') as stream:
            stream.truncate(500 * MIB)
        if os.lstat(self.root / 'sparse.img').st_blocks * 512 >= 2 * MIB:
            self.skipTest('this filesystem does not keep sparse files sparse')
        report = self.scan()
        self.assertEqual(Path(report['files'][0]['path']).name, 'real.bin')
        self.assertLess(report['files'][1]['bytes'], 2 * MIB)

    def test_symlinks_are_neither_followed_nor_listed(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        write(Path(outside.name) / 'elsewhere.bin', 2 * MIB)
        write(self.root / 'here.bin', 256 * 1024)
        os.symlink(outside.name, self.root / 'link-to-folder')
        os.symlink(Path(outside.name) / 'elsewhere.bin', self.root / 'link-to-file')
        report = self.scan()
        self.assertEqual([Path(entry['path']).name for entry in report['files']], ['here.bin'])

    def test_a_hard_linked_file_is_listed_once(self):
        write(self.root / 'a/original.bin', 1 * MIB)
        os.link(self.root / 'a/original.bin', self.root / 'second-name.bin')
        report = self.scan()
        self.assertEqual(len(report['files']), 1)

    def test_the_command_prints_one_report_line(self):
        write(self.root / 'only.bin', 512 * 1024)
        result = subprocess.run([sys.executable, str(SOURCE), 'largest-files', str(self.root), '--limit', '5'],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [line for line in result.stdout.splitlines() if line.startswith('MSAM_DISK_USAGE=')]
        self.assertEqual(len(lines), 1)
        report = json.loads(lines[0][len('MSAM_DISK_USAGE='):])
        self.assertEqual([Path(entry['path']).name for entry in report['files']], ['only.bin'])

    def test_the_command_reports_a_volume_that_is_not_there(self):
        result = subprocess.run([sys.executable, str(SOURCE), 'largest-files', str(self.root / 'missing')],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        report = json.loads(result.stdout.strip().split('MSAM_DISK_USAGE=')[-1])
        self.assertIn('missing', report['error'])

    def test_the_command_refuses_a_relative_path(self):
        result = subprocess.run([sys.executable, str(SOURCE), 'largest-files', 'relative/folder'],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('error', json.loads(result.stdout.strip().split('MSAM_DISK_USAGE=')[-1]))


class FakeTree:
    """A directory tree described in memory, for cases a test machine cannot stage:
    other devices, cloud placeholders, unreadable folders, Windows links."""

    def __init__(self):
        self.entries = {}
        self.stats = {}
        self.listed = []
        self.unreadable = set()
        self.inode = 100

    def add(self, path, kind='file', size=0, dev=1, flags=0, attributes=0, ino=None, links=1):
        """`size` is in KiB, so every size is a whole number of disk blocks."""
        self.inode += 1
        mode = {'file': stat.S_IFREG, 'dir': stat.S_IFDIR, 'link': stat.S_IFLNK}[kind]
        self.stats[path] = SimpleNamespace(st_mode=mode | 0o644, st_dev=dev, st_ino=ino or self.inode,
                                           st_size=size * 1024, st_blocks=size * 2, st_flags=flags,
                                           st_file_attributes=attributes, st_nlink=links)
        parent = path.rsplit('/', 1)[0] or '/'
        if path != '/':
            self.entries.setdefault(parent, []).append(path)
        if kind == 'dir':
            self.entries.setdefault(path, [])
        return self

    def lstat(self, path):
        return self.stats[path]

    def scandir(self, path):
        self.listed.append(path)
        if path in self.unreadable:
            raise PermissionError(13, 'Permission denied', path)
        tree = self

        class Listing:
            def __enter__(self):
                return iter([SimpleNamespace(path=child, name=child.rsplit('/', 1)[1],
                                             stat=lambda follow_symlinks=True, child=child: tree.stats[child])
                             for child in tree.entries[path]])

            def __exit__(self, *_):
                return False

        return Listing()

    def scan(self, root='/', **options):
        return disk_usage.largest_files(root, scandir=self.scandir, lstat=self.lstat, **options)


def names(report):
    return [entry['path'] for entry in report['files']]


class RulesTests(unittest.TestCase):
    def test_other_filesystems_mounted_inside_the_volume_are_left_alone(self):
        tree = FakeTree().add('/', 'dir').add('/mine.bin', size=10)
        tree.add('/mnt', 'dir', dev=2).add('/mnt/theirs.bin', size=999, dev=2)
        report = tree.scan()
        self.assertEqual(names(report), ['/mine.bin'])
        self.assertNotIn('/mnt', tree.listed)

    def test_an_unreadable_folder_is_counted_and_the_scan_carries_on(self):
        tree = FakeTree().add('/', 'dir').add('/locked', 'dir').add('/open', 'dir').add('/open/a.bin', size=5)
        tree.unreadable.add('/locked')
        report = tree.scan()
        self.assertEqual(names(report), ['/open/a.bin'])
        self.assertEqual(report['unreadable'], 1)
        self.assertTrue(report['complete'])

    def test_cloud_only_items_are_counted_but_never_opened_or_listed(self):
        dataless = disk_usage.SF_DATALESS
        tree = FakeTree().add('/', 'dir').add('/local.bin', size=7)
        tree.add('/icloud', 'dir', flags=dataless).add('/icloud/inside.bin', size=900)
        tree.add('/placeholder.mov', size=800, flags=dataless)
        report = tree.scan()
        self.assertEqual(names(report), ['/local.bin'])
        self.assertEqual(report['cloudOnly'], 2)
        self.assertNotIn('/icloud', tree.listed)

    def test_a_scan_that_runs_out_of_time_keeps_what_it_found_and_says_so(self):
        tree = FakeTree().add('/', 'dir').add('/first.bin', size=50)
        for index in range(5):
            tree.add(f'/d{index}', 'dir').add(f'/d{index}/later.bin', size=10 + index)
        ticks = iter(range(0, 1000, 4))
        report = tree.scan(seconds=10, clock=lambda: next(ticks))
        self.assertFalse(report['complete'])
        self.assertIn('/first.bin', names(report))
        self.assertLess(report['scannedFiles'], 6)

    def test_the_time_limit_is_noticed_inside_one_enormous_folder(self):
        tree = FakeTree().add('/', 'dir')
        for index in range(5000):
            tree.add(f'/f{index}', size=index + 1)
        ticks = iter(range(0, 100000))
        report = tree.scan(seconds=3, clock=lambda: next(ticks))
        self.assertFalse(report['complete'])
        self.assertLess(report['scannedFiles'], 5000)

    def test_one_file_reachable_by_two_paths_is_listed_once(self):
        # macOS shows the data volume's folders both at / and under /System/Volumes/Data.
        tree = FakeTree().add('/', 'dir').add('/Users', 'dir').add('/Users/movie.mov', size=500, ino=7)
        tree.add('/Data', 'dir').add('/Data/movie.mov', size=500, ino=7)
        self.assertEqual(len(tree.scan()['files']), 1)

    def test_on_a_mac_the_startup_volume_scan_skips_the_duplicate_volume_folder(self):
        tree = FakeTree().add('/', 'dir').add('/Users', 'dir').add('/Users/a.bin', size=5)
        tree.add('/System', 'dir').add('/System/Volumes', 'dir').add('/System/Volumes/Data', 'dir')
        tree.add('/System/Volumes/Data/b.bin', size=9)
        tree.add('/System/Library', 'dir').add('/System/Library/c.bin', size=3)
        report = tree.scan(platform='darwin')
        self.assertEqual(names(report), ['/Users/a.bin', '/System/Library/c.bin'])
        self.assertNotIn('/System/Volumes', tree.listed)
        other = FakeTree().add('/', 'dir').add('/System', 'dir').add('/System/Volumes', 'dir')
        other.add('/System/Volumes/x.bin', size=4)
        self.assertEqual(names(other.scan(platform='linux')), ['/System/Volumes/x.bin'])

    def test_windows_links_to_other_folders_are_not_followed(self):
        reparse = disk_usage.FILE_ATTRIBUTE_REPARSE_POINT
        tree = FakeTree().add('/', 'dir', dev=0).add('/real.bin', size=6, dev=0)
        tree.add('/Junction', 'dir', dev=0, attributes=reparse).add('/Junction/loop.bin', size=600, dev=0)
        report = tree.scan(platform='win32')
        self.assertEqual(names(report), ['/real.bin'])
        self.assertNotIn('/Junction', tree.listed)

    def test_windows_files_without_file_numbers_are_all_listed(self):
        # A Windows folder listing reports 0 for every file's device and file number.
        tree = FakeTree().add('/', 'dir', dev=7)
        tree.add('/one.bin', size=5, dev=0).add('/two.bin', size=6, dev=0)
        for path in ('/one.bin', '/two.bin'):
            tree.stats[path].st_ino = 0
        self.assertEqual(names(tree.scan(platform='win32')), ['/two.bin', '/one.bin'])

    def test_windows_cloud_placeholders_are_counted_not_listed(self):
        tree = FakeTree().add('/', 'dir', dev=0).add('/local.bin', size=6, dev=0)
        tree.add('/onedrive.mp4', size=900, dev=0, attributes=disk_usage.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)
        report = tree.scan(platform='win32')
        self.assertEqual(names(report), ['/local.bin'])
        self.assertEqual(report['cloudOnly'], 1)

    def test_a_bare_windows_drive_letter_means_the_root_of_that_drive(self):
        self.assertEqual(disk_usage.volume_root('C:', platform='win32'), 'C:\\')
        self.assertEqual(disk_usage.volume_root('D:/', platform='win32'), 'D:/')
        self.assertEqual(disk_usage.volume_root('/data', platform='linux'), '/data')

    def test_files_without_a_block_count_fall_back_to_their_length(self):
        tree = FakeTree().add('/', 'dir', dev=0).add('/win.bin', size=4, dev=0)
        del tree.stats['/win.bin'].st_blocks
        self.assertEqual(tree.scan(platform='win32')['files'][0]['bytes'], 4096)

    def test_a_name_that_is_not_valid_text_still_produces_valid_json(self):
        tree = FakeTree().add('/', 'dir').add('/bad-\udcff-name.bin', size=5)
        encoded = json.dumps(tree.scan())
        encoded.encode('utf-8')
        self.assertIn('bad-', json.loads(encoded)['files'][0]['path'])

    def test_equal_sizes_are_ordered_by_path_so_the_list_is_stable(self):
        tree = FakeTree().add('/', 'dir').add('/b.bin', size=5).add('/a.bin', size=5)
        self.assertEqual(names(tree.scan()), ['/a.bin', '/b.bin'])


if __name__ == '__main__':
    unittest.main()
