"""Fail a test that leaves a real Codex app-server daemon running.

`acfs agents spawn` starts Codex's app-server daemon when none runs
(acfs-gen.3). A test that reaches it with the real codex on PATH starts one
that outlives the test, reparented to init, for as long as the host is up
(acfs-cj07). Tests fake the daemon and stub codex; this guard catches a test
that stops doing so. A process is the test's when its environment names the
test's temporary root, which every fixture env carries (HOME, CODEX_HOME or
the fixture's own *_ROOT).
"""
import os
from pathlib import Path
import signal


def codex_daemons_under(root, proc_root="/proc"):
    """Pids of codex app-server processes whose environment names root."""
    marker = os.fsencode(str(root))
    pids = []
    for proc in Path(proc_root).iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if b"app-server" in (proc / "cmdline").read_bytes() and marker in (proc / "environ").read_bytes():
                pids.append(int(proc.name))
        except OSError:
            continue  # gone, or another user's
    return pids


def guard_codex_daemons(test, root):
    """Register a cleanup on test that stops and reports any daemon under root."""
    def check():
        leaked = codex_daemons_under(root)
        for pid in leaked:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        test.assertEqual(leaked, [], "the test started a real Codex app-server daemon (stopped it)")
    test.addCleanup(check)
