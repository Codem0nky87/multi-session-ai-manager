#!/usr/bin/env python3
"""Run the iOS folder browser tests against disposable SSH with SFTP disabled.

Usage: scripts/test-workdir-browser.py 'platform=iOS Simulator,id=...'
Only the temporary fixture's public-key file is changed. No user SSH config,
saved hosts, or production credentials are used.
"""
import getpass
import json
import os
import re
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time


def main():
    app = Path(__file__).resolve().parents[1] / "app/MultiSessionAIManager"
    destination = sys.argv[1] if len(sys.argv) > 1 else "platform=iOS Simulator,name=iPad Pro 13-inch (M5)"
    # Near the start of /tmp so UI navigation remains deterministic even on a
    # development machine with thousands of unrelated temporary directories.
    with tempfile.TemporaryDirectory(prefix="000-msam-ssh-", dir="/tmp") as directory:
        root = Path(directory)
        folders = root / "folders"
        (folders / "Projects/nested folder").mkdir(parents=True)
        (folders / ".hidden").mkdir()
        (folders / "quote's $dollar\nline").mkdir()
        (folders / "README.txt").write_text("fixture\n")
        (folders / "linked projects").symlink_to("Projects", target_is_directory=True)
        (folders / "linked file").symlink_to("README.txt")
        (folders / "broken link").symlink_to("missing")
        locked = folders / "locked"
        locked.mkdir(mode=0o000)
        for name in ("host_key", "client_key"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        config = root / "sshd_config"
        config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host_key
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/client_key.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding no
X11Forwarding no
LogLevel ERROR
""")  # Deliberately no Subsystem sftp configuration.
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-f", str(config), "-E", str(root / "sshd.log")], start_new_session=True)
        try:
            options = ["-i", str(root / "client_key"), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                       "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={root}/known_hosts"]
            for _ in range(50):
                result = subprocess.run(["ssh", *options, "-p", str(port), "127.0.0.1", "true"], capture_output=True)
                if result.returncode == 0:
                    break
                if server.poll() is not None:
                    raise RuntimeError("Fixture SSH server did not start")
                time.sleep(0.1)
            else:
                raise RuntimeError("Fixture SSH connection failed")
            sftp = subprocess.run(["sftp", *options, "-P", str(port), "-b", "-", "127.0.0.1"], input=b"pwd\n", capture_output=True)
            if sftp.returncode == 0 or b"subsystem request failed" not in sftp.stderr:
                raise RuntimeError("Fixture must explicitly reject the SFTP subsystem")
            print("Fixture verified: SSH works; SFTP is disabled.", flush=True)
            manifest = root / "fixture.json"
            manifest.write_text(json.dumps(dict(root=str(root), port=port, username=getpass.getuser())))
            env = dict(os.environ, TEST_RUNNER_MSAM_SSH_IT="1", TEST_RUNNER_MSAM_SSH_FIXTURE=str(manifest))
            subprocess.run(["xcodegen", "generate"], cwd=app, check=True)
            model_tests = re.findall(r"@Test func (\w+)\(", (app / "Tests/FileBrowserModelTests.swift").read_text())
            selections = ["SSHDirectoryBrowserTests", "WorkdirBrowserLiveTests", "AddHostProvisioningModelTests"]
            selections += [name + "()" for name in model_tests]
            result = subprocess.run([
                "xcodebuild", "-project", "MultiSessionAIManager.xcodeproj", "-scheme", "MultiSessionAIManager",
                "-destination", destination, "-derivedDataPath", "build/DerivedData", "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never",
                *["-only-testing:MultiSessionAIManagerTests/" + name for name in selections],
                "-only-testing:MultiSessionAIManagerUITests/AddHostWizardUITests", "test"
            ], cwd=app, env=env)
            return result.returncode
        finally:
            locked.chmod(0o700)
            try:
                os.killpg(server.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            server.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
