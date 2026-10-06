#!/usr/bin/env python3
"""Exercise production SSH file-transfer shell templates on Linux without SFTP.

This verifies the shell protocol, not Swift compilation. Swift live integration
coverage is in ServiceSetupLiveTests, driven by test-workdir-browser.py on macOS.
"""
import base64
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / 'app/MultiSessionAIManager/Core/SSHFileTransfer.swift'
MARKER = b'\nMSAM_FILE_OK\n'


def main():
    source = SOURCE.read_text()
    templates = re.findall(r'(?:execute)\("""\n(.*?)\n\s*""", using:', source, re.S)
    assert len(templates) == 5
    templates = [re.sub(r'\\\\', lambda _: '\\', template) for template in templates]

    def run(template, values):
        script = template
        for name, value in values.items():
            script = script.replace('\\(' + name + ')', str(value))
        assert '\\(' not in script, script
        result = subprocess.run(['/bin/sh', '-c', 'set -eu\nPATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH\n' + script], capture_output=True)
        if result.returncode or not result.stdout.endswith(MARKER):
            raise RuntimeError(result.stderr.decode())
        return result.stdout[:-len(MARKER)]

    with tempfile.TemporaryDirectory(prefix='msam-transfer-shell-') as root:
        target = Path(root) / "quote's $literal\nfile"
        staging = Path(str(target) + '.msam-test')
        values = dict(destination=shlex.quote(str(target)), staging=shlex.quote(str(staging)), quoted=shlex.quote(str(target)))
        chunk_size = 48 * 1024
        for payload in [b'', bytes(range(256)) * 577, os.urandom(1024 * 1024 + 17)]:
            run(templates[0], values)
            for offset in range(0, len(payload), chunk_size):
                end = min(offset + chunk_size, len(payload))
                run(templates[1], values | {'offset': offset, 'end': end, 'encoded': base64.b64encode(payload[offset:end]).decode()})
            run(templates[2], values | {'data.count': len(payload)})
            assert target.read_bytes() == payload
            size = int(run(templates[3], values))
            assert size == len(payload)
            downloaded = b''
            for offset in range(0, size, chunk_size):
                encoded = run(templates[4], values | {'count': size, 'chunkSize': chunk_size, 'offset / chunkSize': offset // chunk_size})
                downloaded += base64.b64decode(encoded)
            assert downloaded == payload
            assert not staging.exists()
        # A corrupt or interrupted chunk must not publish over an existing file.
        original = target.read_bytes()
        run(templates[0], values)
        try:
            run(templates[1], values | {'offset': 0, 'end': 3, 'encoded': 'AA=='})
        except RuntimeError:
            pass
        else:
            raise AssertionError('Truncated chunk was accepted')
        assert target.read_bytes() == original
        staging.unlink()
        directory = Path(root) / 'directory'
        directory.mkdir()
        try:
            run(templates[0], values | {'destination': shlex.quote(str(directory))})
        except RuntimeError:
            pass
        else:
            raise AssertionError('Directory destination was accepted')
        assert list(directory.iterdir()) == []
    print('PASS: production shell templates preserve binary bytes across multiple chunks, empty files, quoted paths, and failed uploads')


if __name__ == '__main__':
    main()
