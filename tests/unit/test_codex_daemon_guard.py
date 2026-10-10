"""The guard that fails a test leaving a Codex app-server daemon behind (acfs-cj07)."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from codex_daemon_guard import codex_daemons_under, guard_codex_daemons  # noqa: E402


class GuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="acfs-daemon-guard-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(os.path.realpath(tmp.name))

    def fake_proc(self, entries):
        proc = self.root / "proc"
        for pid, cmdline, environ in entries:
            (proc / pid).mkdir(parents=True)
            (proc / pid / "cmdline").write_bytes(cmdline)
            (proc / pid / "environ").write_bytes(environ)
        (proc / "self").mkdir()
        return proc

    def test_finds_only_app_servers_whose_environment_names_the_root(self):
        home = os.fsencode(str(self.root / "home"))
        proc = self.fake_proc([
            ("11", b"codex\0app-server\0--listen\0", b"HOME=" + home + b"\0"),
            ("12", b"codex\0app-server\0daemon\0", b"HOME=/home/someone\0"),
            ("13", b"bash\0", b"HOME=" + home + b"\0"),
        ])
        self.assertEqual(codex_daemons_under(self.root, proc), [11])

    def test_stops_and_reports_a_daemon_the_test_left_running(self):
        # A stand-in daemon: argv names app-server, its env names the test root.
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "app-server"],
                                 env=dict(os.environ, HOME=str(self.root)))
        self.addCleanup(child.kill)
        for _ in range(50):
            if codex_daemons_under(self.root):
                break
            time.sleep(0.05)

        class Leaky(unittest.TestCase):
            def runTest(inner):
                guard_codex_daemons(inner, self.root)

        result = unittest.TestResult()
        Leaky().run(result)
        self.assertEqual(len(result.failures), 1, result.failures)
        self.assertIn("real Codex app-server daemon", result.failures[0][1])
        self.assertIsNotNone(child.wait(timeout=5))
        self.assertEqual(codex_daemons_under(self.root), [])

    def test_passes_when_nothing_was_left(self):
        class Clean(unittest.TestCase):
            def runTest(inner):
                guard_codex_daemons(inner, self.root)

        result = unittest.TestResult()
        Clean().run(result)
        self.assertTrue(result.wasSuccessful(), result.failures)


if __name__ == "__main__":
    unittest.main()
