#!/usr/bin/env python3
"""A root-started update lets the target user make its log, and never writes there by path.

update.sh is sourced (not run) as root inside an unprivileged user namespace
(`unshare -r`, or bwrap where AppArmor keeps unshare from making one, as on
Ubuntu 24.04), and its init_logging writes a real log. Switching to the
target user is a recording stub that runs the command as the namespace's
root, `id -u alice` answers that root's uid, and chown is a recording stub,
so no ownership on the host changes and no update step runs (acfs-7v3,
acfs-930).
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
update_run_in_target_context() {
    shift
    printf 'as-user %s\n' "$*" >> "$FIXTURE_CALLS"
    if [[ -n "${FIXTURE_TOUCH_LINK:-}" && "$1" == touch ]]; then
        ln -s "$FIXTURE_TOUCH_LINK" "$3"
        return 0
    fi
    "$@"
}
id() { if [[ "$1" == -u && "${3:-$2}" == alice ]]; then echo "$EUID"; else command id "$@"; fi; }
chown() { printf 'chown %s\n' "$*" >> "$FIXTURE_CALLS"; }
UPDATE_LOG_DIR="$FIXTURE_HOME/.acfs/logs/updates"
init_logging
log_to_file "probe line"
printf 'file=%s\npath=%s\n' "$UPDATE_LOG_FILE" "${UPDATE_LOG_PATH:-}"
'''
DUMP_HARNESS = r'''
source "$1"
update_procwatch_scan /proc
if update_procwatch_dump /proc "$2" "test storm" 4; then echo wrote; else echo refused; fi
'''


AS_ROOT = (["unshare", "-r"],
           ["bwrap", "--unshare-user", "--uid", "0", "--gid", "0", "--dev-bind", "/", "/", "--"])


class UpdateLogOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for prefix in AS_ROOT:
            if not shutil.which(prefix[0]):
                continue
            probe = subprocess.run(prefix + ["bash", "-c", 'printf %s "$EUID"'],
                                   capture_output=True, text=True, timeout=30)
            if probe.returncode == 0 and probe.stdout == "0":
                cls.as_root = prefix
                return
        raise unittest.SkipTest("unprivileged user namespaces are unavailable (unshare -r, bwrap)")

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="acfs-update-log-owner-"))
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.home = self.base / "home"
        self.home.mkdir()
        self.calls = self.base / "calls"

    def run_update(self, as_root=True, target_user="alice", touch_link=None):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "FIXTURE_HOME": str(self.home),
               "FIXTURE_CALLS": str(self.calls)}
        if target_user:
            env["TARGET_USER"] = target_user
        if touch_link:
            env["FIXTURE_TOUCH_LINK"] = str(touch_link)
        argv = ["bash", "-c", HARNESS, "_", str(SOURCE)]
        if as_root:
            argv = self.as_root + argv
        result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        out = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return out, calls, result.stderr

    def the_log(self):
        logs = list((self.home / ".acfs/logs/updates").glob("*.log"))
        self.assertEqual(len(logs), 1, logs)
        return logs[0]

    def test_root_run_for_a_user_has_the_user_make_the_log_and_writes_through_its_fd(self):
        out, calls, _ = self.run_update()
        log = self.the_log()
        updates = self.home / ".acfs/logs/updates"
        self.assertEqual(calls, [f"as-user mkdir -p -- {updates}", f"as-user touch -- {log}"])
        self.assertTrue(out["file"].startswith("/proc/"), out)
        self.assertEqual(out["path"], str(log))
        text = log.read_text()
        self.assertIn("ACFS Update Log", text)
        self.assertIn("probe line", text)

    def test_a_link_below_the_home_means_no_log_and_no_root_write(self):
        elsewhere = self.base / "elsewhere"
        elsewhere.mkdir()
        (self.home / ".acfs").mkdir()
        os.symlink(elsewhere, self.home / ".acfs/logs")
        out, calls, err = self.run_update()
        self.assertEqual(out["file"], "")
        self.assertIn("not logging to", err)
        for made in (elsewhere / "updates").glob("*.log"):
            self.assertEqual(made.read_text(), "", "root wrote through the link")
        self.assertFalse(any(c.startswith("chown") for c in calls))

    def test_a_log_swapped_for_a_link_is_never_opened(self):
        victim = self.base / "victim"
        victim.write_text("untouched\n")
        out, _, err = self.run_update(touch_link=victim)
        self.assertEqual(out["file"], "")
        self.assertIn("not logging to", err)
        self.assertEqual(victim.read_text(), "untouched\n")

    def test_root_updating_itself_logs_by_path_as_before(self):
        out, calls, _ = self.run_update(target_user="")
        self.assertEqual(calls, [])
        self.assertEqual(out["file"], str(self.the_log()))
        self.assertIn("probe line", self.the_log().read_text())

    def test_user_run_logs_by_path_as_before(self):
        out, calls, _ = self.run_update(as_root=False, target_user="")
        self.assertEqual(calls, [])
        self.assertEqual(out["file"], str(self.the_log()))

    def run_dump(self, dumpfile):
        result = subprocess.run(["bash", "-c", DUMP_HARNESS, "_", str(SOURCE), str(dumpfile)],
                                capture_output=True, text=True, timeout=60,
                                env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip().splitlines()[-1]

    def test_a_storm_snapshot_is_a_new_file(self):
        dumpfile = self.base / "storm.txt"
        self.assertEqual(self.run_dump(dumpfile), "wrote")
        self.assertIn("ACFS process-storm snapshot", dumpfile.read_text())

    def test_a_storm_snapshot_never_follows_or_appends_to_a_planted_name(self):
        victim = self.base / "victim"
        victim.write_text("untouched\n")
        for planted in ("link", "file"):
            dumpfile = self.base / f"storm-{planted}.txt"
            if planted == "link":
                os.symlink(victim, dumpfile)
            else:
                dumpfile.write_text("old\n")
            self.assertEqual(self.run_dump(dumpfile), "refused")
        self.assertEqual(victim.read_text(), "untouched\n")
        self.assertEqual((self.base / "storm-file.txt").read_text(), "old\n")


if __name__ == "__main__":
    unittest.main()
