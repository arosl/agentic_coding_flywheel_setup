#!/usr/bin/env python3
"""A root-started update hands the log it made in the user's ~/.acfs to that user.

update.sh is sourced (not run) as root inside an unprivileged user namespace
(`unshare -r`), and its init_logging writes a real log. chown is a recording
stub, so no ownership on the host changes and no update step runs.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "scripts/lib/update.sh"
HARNESS = r'''
source "$1"
update_target_home() { printf '%s\n' "$FIXTURE_HOME"; }
chown() { printf '%s\n' "$*" >> "$FIXTURE_CALLS"; }
UPDATE_LOG_DIR="$FIXTURE_HOME/.acfs/logs/updates"
init_logging
printf '%s\n' "$UPDATE_LOG_FILE"
'''


class UpdateLogOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("unshare"):
            raise unittest.SkipTest("requires util-linux unshare")
        probe = subprocess.run(["unshare", "-r", "bash", "-c", 'printf %s "$EUID"'],
                               capture_output=True, text=True, timeout=30)
        if probe.returncode != 0 or probe.stdout != "0":
            raise unittest.SkipTest("unprivileged user namespaces are unavailable")

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="acfs-update-log-owner-"))
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.home = self.base / "home"
        self.home.mkdir()
        self.calls = self.base / "chown-calls"

    def run_update(self, as_root=True, target_user="alice"):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "FIXTURE_HOME": str(self.home),
               "FIXTURE_CALLS": str(self.calls)}
        if target_user:
            env["TARGET_USER"] = target_user
        argv = ["bash", "-c", HARNESS, "_", str(SOURCE)]
        if as_root:
            argv = ["unshare", "-r"] + argv
        result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        log = Path(result.stdout.strip().splitlines()[-1])
        self.assertTrue(log.is_file())
        return log, self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_root_run_for_a_user_hands_over_the_log_and_the_dirs_it_made(self):
        log, calls = self.run_update()
        acfs = self.home / ".acfs"
        self.assertEqual(calls, [f"-h alice:alice -- {p}" for p in
                                 (log, acfs / "logs/updates", acfs / "logs", acfs)])

    def test_a_link_below_the_home_stops_the_handover(self):
        elsewhere = self.base / "elsewhere"
        elsewhere.mkdir()
        (self.home / ".acfs").mkdir()
        os.symlink(elsewhere, self.home / ".acfs/logs")
        log, calls = self.run_update()
        self.assertTrue((elsewhere / "updates" / log.name).is_file())
        self.assertEqual(calls, [])

    def test_root_updating_itself_changes_no_owner(self):
        _, calls = self.run_update(target_user="")
        self.assertEqual(calls, [])

    def test_user_run_changes_no_owner(self):
        _, calls = self.run_update(as_root=False, target_user="")
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
