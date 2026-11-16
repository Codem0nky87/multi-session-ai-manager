#!/usr/bin/env python3
"""Lists the files that occupy the most space on one volume, for the MSAM app.

The app runs this on demand when a volume is expanded in the storage detail;
it is not part of the installed host service and nothing here runs on a timer.

    msam-disk-usage.py largest-files <mount point> [--limit 20] [--seconds 180]

prints one line, `MSAM_DISK_USAGE=<json>`.

What the walk will not do:
  * leave the volume: folders on another device are other volumes;
  * follow links (symlinks, Windows junctions), so nothing is counted twice
    and a link cannot lead the walk in a circle;
  * open cloud-only items. On macOS merely listing an iCloud "dataless" folder
    asks iCloud to download it and blocks until that finishes. Such items use
    no local space, so they are counted and skipped;
  * use sudo. Folders the login cannot read are counted, not listed.
"""

import argparse
import heapq
import json
import os
import stat
import sys
import threading
import time

PREFIX = 'MSAM_DISK_USAGE='
# macOS st_flags: the item's content lives in the cloud, not on this disk.
SF_DATALESS = 0x40000000
# Windows st_file_attributes.
FILE_ATTRIBUTE_REPARSE_POINT = 0x400
FILE_ATTRIBUTE_OFFLINE = 0x1000
FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000
WINDOWS_CLOUD_ONLY = FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
# Entries read inside one folder between looks at the clock.
CLOCK_CHECK_INTERVAL = 512
# How long after the time limit the process force-stops a walk that is stuck
# inside a single system call (a dead network mount, a hung FUSE filesystem).
HARD_STOP_GRACE = 10.0


def text(path):
    """A path as valid UTF-8, whatever bytes the filesystem holds."""
    try:
        return path.encode('utf-8', 'surrogateescape').decode('utf-8', 'replace')
    except UnicodeEncodeError:
        return path.encode('utf-8', 'replace').decode('utf-8')


def volume_root(volume, platform=sys.platform):
    # "C:" alone means "the current folder on C:", not the drive's root.
    if platform == 'win32' and len(volume) == 2 and volume[1] == ':' and volume[0].isalpha():
        return volume + '\\'
    return volume


class Scan:
    def __init__(self, root, limit=20, seconds=180.0, clock=time.monotonic,
                 scandir=os.scandir, lstat=os.lstat, platform=sys.platform):
        self.root = root
        self.limit = max(1, min(int(limit), 200))
        self.seconds = seconds
        self.clock = clock
        self.scandir = scandir
        self.lstat = lstat
        self.platform = platform
        self.largest = []       # heap of (bytes, -arrival, path, identity); smallest on top
        self.identities = set()  # identities currently in the heap
        self.arrivals = 0
        self.scanned = 0
        self.unreadable = 0
        self.cloud_only = 0
        self.complete = False
        self.started = clock()

    def out_of_time(self):
        return self.clock() - self.started > self.seconds

    def run(self):
        device = self.lstat(self.root).st_dev
        # The Mac's startup volume shows the data volume's folders at /Users,
        # /Applications and so on, and the whole data volume again under
        # /System/Volumes. Walking both would double the time for no new file.
        skipped = {'/System/Volumes'} if self.platform == 'darwin' and self.root == '/' else set()
        pending = [self.root]
        while pending:
            if self.out_of_time():
                return self
            folder = pending.pop()
            try:
                with self.scandir(folder) as listing:
                    for count, entry in enumerate(listing, 1):
                        if count % CLOCK_CHECK_INTERVAL == 0 and self.out_of_time():
                            return self
                        try:
                            info = entry.stat(follow_symlinks=False)
                        except OSError:
                            self.unreadable += 1
                            continue
                        if getattr(info, 'st_flags', 0) & SF_DATALESS:
                            self.cloud_only += 1
                            continue
                        # A Windows folder listing reports device 0 for everything;
                        # there other volumes are reparse points, handled below.
                        if device and info.st_dev and info.st_dev != device:
                            continue
                        attributes = getattr(info, 'st_file_attributes', 0)
                        if stat.S_ISDIR(info.st_mode):
                            if attributes & FILE_ATTRIBUTE_REPARSE_POINT or entry.path in skipped:
                                continue
                            pending.append(entry.path)
                        elif stat.S_ISREG(info.st_mode):
                            if attributes & WINDOWS_CLOUD_ONLY:
                                self.cloud_only += 1
                                continue
                            self.scanned += 1
                            self.offer(entry.path, info)
            except OSError:
                self.unreadable += 1
        self.complete = True
        return self

    def offer(self, path, info):
        # Space occupied, not length: a sparse disk image or a compressed file
        # can be far smaller on disk than it claims to be.
        size = info.st_blocks * 512 if hasattr(info, 'st_blocks') else info.st_size
        inode = getattr(info, 'st_ino', 0)
        identity = (info.st_dev, inode) if inode else None
        if identity is not None and identity in self.identities:
            return  # a second name for a file already listed (hard link, macOS firmlink)
        self.arrivals += 1
        item = (size, -self.arrivals, path, identity)
        if len(self.largest) < self.limit:
            heapq.heappush(self.largest, item)
        elif size > self.largest[0][0]:
            self.identities.discard(heapq.heapreplace(self.largest, item)[3])
        else:
            return
        if identity is not None:
            self.identities.add(identity)

    def report(self):
        files = sorted(list(self.largest), key=lambda item: (-item[0], item[2]))
        return {
            'mountPoint': text(self.root),
            'files': [{'path': text(path), 'bytes': size} for size, _, path, _ in files],
            'scannedFiles': self.scanned,
            'unreadable': self.unreadable,
            'cloudOnly': self.cloud_only,
            'complete': self.complete,
            'seconds': round(self.clock() - self.started, 1),
        }


def largest_files(root, **options):
    return Scan(root, **options).run().report()


def be_gentle():
    """The host is busy with other work; this is a background question."""
    try:
        os.nice(19)
    except (AttributeError, OSError):
        pass
    if sys.platform == 'darwin':
        try:
            import ctypes
            # setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
            # IOPOL_MATERIALIZE_DATALESS_FILES_OFF): this process must never make iCloud
            # download anything, even if a placeholder slips past the flag check.
            ctypes.CDLL(None).setiopolicy_np(3, 0, 1)
        except Exception:
            pass


def emit(value):
    sys.stdout.write(PREFIX + json.dumps(value) + '\n')
    sys.stdout.flush()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['largest-files'])
    parser.add_argument('volume')
    parser.add_argument('--limit', type=int, default=20)
    parser.add_argument('--seconds', type=float, default=180.0)
    args = parser.parse_args(argv)
    try:
        root = volume_root(args.volume)
        if not os.path.isabs(root):
            raise ValueError('The volume must be given as an absolute path.')
        if not os.path.isdir(root):
            raise ValueError('The volume ' + text(root) + ' is missing or is not a folder.')
        be_gentle()
        scan = Scan(root, limit=args.limit, seconds=args.seconds)
        writing = threading.Lock()
        finished = []

        def hard_stop():
            time.sleep(args.seconds + HARD_STOP_GRACE)
            with writing:
                if not finished:
                    emit(scan.report())
                    os._exit(0)

        threading.Thread(target=hard_stop, daemon=True).start()
        scan.run()
        with writing:
            finished.append(True)
            emit(scan.report())
    except Exception as error:
        emit({'error': str(error) or error.__class__.__name__})
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
