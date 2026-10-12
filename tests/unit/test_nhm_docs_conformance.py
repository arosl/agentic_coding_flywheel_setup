"""The docs-conformance test (acfs-9hkh.56): each nhm form in
tests/fixtures/nhm/doc_forms.txt parses against nhm's real command tree.

Syntax only. nhm runs with an empty HOME and a herdr socket that does not
exist, so a form that parses stops at "not enrolled" or "herdr did not
answer", and nothing is spawned or sent. A form that does not parse shows
nhm's own parse errors: an unknown command, an undefined flag (native
verbs print their usage; robot flags answer error_code INVALID_FLAG).

nhm is $NHM_BIN, else nhm on PATH. Without one the test is skipped, and
says so. It never installs anything.

Usage: python3 -m unittest tests/unit/test_nhm_docs_conformance.py
"""

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

FORMS = Path(__file__).resolve().parents[1] / "fixtures" / "nhm" / "doc_forms.txt"
PARSE_ERRORS = ("unknown command", "flag provided but not defined", "INVALID_FLAG", "Usage: nhm")


def nhm_binary():
    return os.environ.get("NHM_BIN") or shutil.which("nhm")


def read_forms():
    """(kind, argv, line) for each line: kind is run, deferred or replaced."""
    out = []
    for line in FORMS.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("deferred "):
            _, bead, form = line.split(" ", 2)
            out.append(("deferred", shlex.split(form), bead))
        elif line.startswith("replaced "):
            ntm_form, nhm_form = line[len("replaced "):].split(" => ")
            out.append(("run", shlex.split(nhm_form), "replaces " + ntm_form))
        else:
            out.append(("run", shlex.split(line), line))
    return out


@unittest.skipUnless(nhm_binary(), "nhm is not installed (set NHM_BIN to a built nhm)")
class Conformance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nhm = nhm_binary()
        cls.home = tempfile.mkdtemp(prefix="acfs-nhm-conformance.")
        cls.env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": cls.home,
                   "XDG_STATE_HOME": cls.home + "/state", "XDG_CONFIG_HOME": cls.home + "/config",
                   "XDG_DATA_HOME": cls.home + "/data", "HERDR_SOCKET_PATH": cls.home + "/no-herdr.sock",
                   "LANG": "C.UTF-8"}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.home, ignore_errors=True)

    def parse(self, argv):
        """nhm's output for a form, and whether nhm parsed it."""
        self.assertEqual(argv[0], "nhm", argv)
        proc = subprocess.run([self.nhm, *argv[1:]], env=self.env, cwd=self.home, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=15)
        out = proc.stdout + proc.stderr
        if argv[-1] == "--help":
            # nhm --help prints "Usage:" on a line of its own; a verb's
            # --help prints "Usage: nhm <verb>".
            return out, "Usage:" in out and "unknown command" not in out and "not defined" not in out
        return out, not any(e in out for e in PARSE_ERRORS)

    def test_the_check_tells_parse_errors(self):
        for bad in (["nhm", "nosuchverb"], ["nhm", "spawn", "demo", "--bogus"],
                    ["nhm", "send", "demo", "--no-such-kind"], ["nhm", "--robot-spawn=demo", "--spawn-bogus=1"]):
            out, ok = self.parse(bad)
            self.assertFalse(ok, f"{shlex.join(bad)} parsed:\n{out}")

    def test_forms_parse(self):
        deferred = []
        for kind, argv, note in read_forms():
            if kind == "deferred":
                deferred.append(f"{shlex.join(argv)} ({note})")
                continue
            with self.subTest(form=shlex.join(argv)):
                out, ok = self.parse(argv)
                self.assertTrue(ok, f"{shlex.join(argv)} [{note}] does not parse:\n{out}")
        if deferred:
            print("\ndeferred (not run): " + "; ".join(deferred))

    def test_deferred_forms_are_still_missing(self):
        # A deferred form that parses now means its bead landed: run it.
        for kind, argv, bead in read_forms():
            if kind != "deferred":
                continue
            with self.subTest(form=shlex.join(argv)):
                out, ok = self.parse(argv)
                self.assertFalse(ok, f"{shlex.join(argv)} parses now ({bead} landed): move it to the run forms")


class FormsFile(unittest.TestCase):
    def test_every_form_is_nhm(self):
        forms = read_forms()
        self.assertGreater(len(forms), 10)
        for kind, argv, note in forms:
            self.assertEqual(argv[0], "nhm", note)
            if kind == "deferred":
                self.assertRegex(note, r"^acfs-[0-9a-z.]+$")


if __name__ == "__main__":
    unittest.main()
