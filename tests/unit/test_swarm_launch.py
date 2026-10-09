"""Execute the real launch CLI against native-process contract fixtures.

herdr, am and the planner are fixtures; the launcher and the real
herdr_agents.sh (acfs agents spawn) run unchanged between them.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[2] / "scripts/lib"
SCRIPT = LIB / "swarm_launch.sh"
HELPER = LIB / "herdr_agents.sh"

FIXTURE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["LAUNCH_TEST_ROOT"])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
mode = os.environ.get("LAUNCH_TEST_MODE", "ok")
assert pathlib.Path.cwd() == root / "repo"
with (root / "calls").open("a") as f:
    f.write(json.dumps([name, args]) + "\n")
state_path = root / "herdr-state.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {"workspaces": [], "agents": [], "next": 2}
def save():
    state_path.write_text(json.dumps(state))
def ok(result):
    print(json.dumps({"result": result})); sys.exit(0)
def fail(code):
    print(json.dumps({"error": {"code": code, "message": code}}), file=sys.stderr); sys.exit(1)
def opt(flag):
    return args[args.index(flag) + 1]
if name == "swarm_plan.sh":
    count = int(args[args.index("--agents") + 1])
    workload = args[args.index("--workload") + 1]
    status = "warn" if mode in ("warn", "wait", "scale") else "fail" if mode == "blocked" else "pass"
    code = {"pass": 0, "warn": 1, "fail": 2}[status]
    response = {"schema_version": 1, "status": status, "exit_code": code, "requested_agents": count,
        "workload": workload, "recommendation": "block" if status == "fail" else "launch_with_review" if status == "warn" else "launch",
        "safe_agents": 32, "recommended_agents": 24,
        "quiesce_advisory": {"recommendation": "wait" if mode == "wait" else "scale_down" if mode == "scale" else "proceed"},
        "checks": [{"id": "host_capacity", "status": status}]}
    if mode == "over-capacity": response["recommended_agents"] = 1
    if mode == "wrong-count": response["requested_agents"] += 1
    if mode == "invalid-checks": response["checks"] = []
    if mode == "mismatched-code": code = 1
    if mode == "bad-plan":
        print('sensitive-probe-output'); sys.exit(0)
    print(json.dumps(response)); sys.exit(code)
if name == "am":
    assert args[:2] == ["agents", "create"] and opt("--project") == str(root / "repo")
    names = ["GreenCastle", "AmberFox", "CopperHill"]
    if mode == "am-fail" and state["next"] > 2: sys.exit(1)
    print(json.dumps({"name": names[state["next"] - 2]})); sys.exit(0)
assert name == "herdr"
if args[:2] == ["status", "server"]:
    print("server:\n  status: " + ("stopped" if mode == "server-down" else "running")); sys.exit(0)
if args[:2] == ["workspace", "list"]:
    workspaces = list(state["workspaces"])
    if mode == "existing-workspace":
        workspaces.append({"workspace_id": "w3", "label": os.environ["LAUNCH_TEST_LABEL"]})
    ok({"workspaces": workspaces})
if args[:2] == ["workspace", "create"]:
    # The caller must have published a durable private intent before creating anything.
    intent = root / "intent.json"
    assert intent.exists() and (intent.stat().st_mode & 0o077) == 0
    assert opt("--cwd") == str(root / "repo") and "--no-focus" in args
    state["workspaces"].append({"workspace_id": "w9", "label": opt("--label")})
    save()
    ok({"workspace": {"workspace_id": "w9"}, "tab": {"tab_id": "w9:t1"}, "root_pane": {"pane_id": "w9:p1"}})
if args[:2] == ["tab", "create"]:
    assert opt("--workspace") == "w9" and opt("--cwd") == str(root / "repo")
    n = state["next"]
    state["next"] += 1
    state.setdefault("labels", {})["w9:t%d" % n] = opt("--label")
    save()
    ok({"tab": {"tab_id": "w9:t%d" % n}, "root_pane": {"pane_id": "w9:p%d" % n}})
if args[:2] == ["agent", "start"]:
    kind, pane = opt("--kind"), opt("--pane")
    if mode == "start-fail": fail("server_error")
    blocked = mode == "blocked-codex" and kind == "codex"
    n = int(pane.rsplit(":p", 1)[1])
    state["agents"].append({"workspace_id": "w9", "tab_id": "w9:t%d" % n, "pane_id": pane, "name": args[2],
        "agent": kind, "agent_status": "blocked" if blocked else "idle", "cwd": str(root / "repo"),
        "terminal_id": "term_%d" % n})
    save()
    if blocked: fail("agent_not_ready")
    ok({"agent": {"name": args[2]}})
if args[:2] == ["agent", "read"]:
    print("Trust this folder?"); sys.exit(0)
if args[:2] == ["agent", "list"]:
    agents = [dict(a) for a in state["agents"]]
    for a in agents:
        if mode == "replaced-terminal": a["terminal_id"] += "x"
        if mode == "name-lost" and a["agent"] == "codex": a["name"] = None
        if mode == "pane-wrong-repo": a["cwd"] = str(root)
    ok({"agents": agents})
if args[:2] == ["pane", "process-info"]:
    pane = opt("--pane")
    agent = next(a for a in state["agents"] if a["pane_id"] == pane)
    n = int(pane.rsplit(":p", 1)[1])
    shown = "bash" if mode == "shell-pane" else agent["agent"]
    ok({"process_info": {"pane_id": pane, "shell_pid": 1000 + n,
        "foreground_processes": [{"name": shown, "pid": 2000 + n, "argv": [shown]}]}})
sys.exit(95)
'''


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="acfs-launch-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(os.path.realpath(self.tmp.name))
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.lib = self.root / "lib"
        self.lib.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        if Path("/usr/bin/python3").is_file():
            (self.bin / "python3").symlink_to("/usr/bin/python3")
        self.script = self.lib / "swarm_launch.sh"
        shutil.copyfile(SCRIPT, self.script)
        shutil.copyfile(HELPER, self.lib / "herdr_agents.sh")
        # The planner is a Bash entrypoint like production; a native fixture
        # implements its contract while all launcher code is copied unchanged.
        for path in (self.bin / "herdr", self.bin / "am", self.bin / "swarm_plan.sh"):
            path.write_text(FIXTURE)
            path.chmod(0o755)
        (self.lib / "swarm_plan.sh").write_text('#!/usr/bin/env bash\nexec "' + str(self.bin / "swarm_plan.sh") + '" "$@"\n')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], LAUNCH_TEST_ROOT=str(self.root),
                        ACFS_HOME=str(self.root / "no-acfs-home"))
        self.env.pop("HERDR_WORKSPACE_ID", None)
        self.receipt = self.root / "intent.json"
        self.args = ["bash", str(self.script), "--repo", str(self.repo), "--session", "project",
            "--agent", "BlueLake:codex", "--agent", "RedFox:claude", "--receipt", str(self.receipt)]

    def request(self, extra=()):
        return {"repo": str(self.repo), "session": "project", "agents": [
            {"agent_name": "BlueLake", "agent_type": "codex"}, {"agent_name": "RedFox", "agent_type": "claude"}],
            "receipt": str(self.receipt), "profile": "balanced", "workload": "standard",
            "accept_warnings": "--accept-warnings" in extra}

    def review_hash(self, extra=()):
        encoded = (json.dumps({"schema": "acfs.swarm-launch.v2", "request": self.request(extra)}, sort_keys=True,
            ensure_ascii=True, indent=2) + "\n").encode()
        return hashlib.sha256(encoded).hexdigest()

    def label(self):
        return "swarm-project-" + self.review_hash()[:12]

    def calls(self):
        path = self.root / "calls"
        return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []

    def herdr_calls(self, *prefix):
        return [argv for name, argv in self.calls() if name == "herdr" and argv[:len(prefix)] == list(prefix)]

    def count_creates(self):
        return len(self.herdr_calls("workspace", "create"))

    def invoke(self, mode="ok", extra=(), launch=False):
        args = [*self.args]
        if launch:
            args.extend(("--launch", "--expect-sha256", self.review_hash(extra)))
        result = subprocess.run([*args, *extra], env=dict(self.env, LAUNCH_TEST_MODE=mode, LAUNCH_TEST_LABEL=self.label()),
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_preview_checks_admission_and_herdr_but_does_not_start_or_write_receipt(self):
        code, report = self.invoke()
        self.assertEqual((code, report["status"]), (0, "preview"), report)
        self.assertFalse(report["starts_agents"])
        self.assertEqual([(n, a[:2]) for n, a in self.calls()],
                         [("swarm_plan.sh", ["--json", "--agents"]), ("herdr", ["status", "server"]),
                          ("herdr", ["workspace", "list"])])
        self.assertFalse(self.receipt.exists())
        self.assertEqual(report["herdr_plan"]["workspace_label"], self.label())
        self.assertEqual([argv[-6:] for argv in report["herdr_plan"]["spawn"]],
                         [["--kind", "codex", "--count", "1", "--no-prompt", "--json"],
                          ["--kind", "claude", "--count", "1", "--no-prompt", "--json"]])
        self.assertIn("--expect-sha256", shlex.split(report["launch_command"]))

    def test_launch_starts_each_slot_in_its_own_tab_of_one_new_workspace(self):
        code, report = self.invoke(launch=True)
        self.assertEqual((code, report["status"]), (0, "ready"), report)
        self.assertEqual(report["preparation_targets"], ["1:GreenCastle:codex:w9:p2", "2:AmberFox:claude:w9:p3"])
        self.assertTrue(report["starts_agents"])
        self.assertTrue(report["agent_mail_registered"])
        self.assertFalse(report["work_dispatched"])
        self.assertFalse(report["authentication_verified"])
        self.assertEqual(self.count_creates(), 1)
        self.assertEqual(self.herdr_calls("workspace", "create")[0][5], self.label())
        # Slot order, one agent per tab; never a prompt, a key or a trust answer.
        self.assertEqual([a[2:5] for a in self.herdr_calls("agent", "start")],
                         [["greencastle", "--kind", "codex"], ["amberfox", "--kind", "claude"]])
        self.assertEqual(self.herdr_calls("agent", "prompt") + self.herdr_calls("agent", "send-keys"), [])
        targets = json.loads((self.root / "intent.json.result.json").read_text())["targets"]
        self.assertEqual([(t["slot"], t["agent_name"], t["herdr_name"], t["pane_id"], t["terminal_id"], t["shell_pid"],
                           t["launched_state"]) for t in targets],
                         [(1, "BlueLake", "greencastle", "w9:p2", "term_2", 1002, "ready"),
                          (2, "RedFox", "amberfox", "w9:p3", "term_3", 1003, "ready")])
        for name in ("intent.json", "intent.json.result.json"):
            self.assertEqual(stat.S_IMODE((self.root / name).stat().st_mode), 0o600)

    def test_agent_waiting_at_a_dialog_counts_as_launched(self):
        code, report = self.invoke(launch=True, mode="blocked-codex")
        self.assertEqual((code, report["status"]), (0, "ready"), report)
        self.assertEqual([t["launched_state"] for t in report["targets"]], ["blocked", "ready"])
        # The launch went on to the next slot and answered nothing.
        self.assertEqual(len(self.herdr_calls("agent", "start")), 2)
        self.assertEqual(self.herdr_calls("agent", "send-keys"), [])

    def test_repeat_only_verifies_recorded_panes(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        intent, result = self.receipt.read_bytes(), (self.root / "intent.json.result.json").read_bytes()
        before = len(self.calls())
        code, report = self.invoke(launch=True)
        self.assertEqual((code, report["status"]), (0, "ready"), report)
        self.assertTrue(report["reconciled_only"])
        self.assertFalse(report["starts_agents"])
        self.assertEqual([a[:2] for _, a in self.calls()[before:]],
                         [["agent", "list"], ["pane", "process-info"], ["pane", "process-info"]])
        self.assertEqual([t["live"] for t in report["targets"]],
                         [{"state": "ready", "name_lost": False}, {"state": "ready", "name_lost": False}])
        self.assertEqual(self.count_creates(), 1)
        self.assertEqual(self.receipt.read_bytes(), intent)
        self.assertEqual((self.root / "intent.json.result.json").read_bytes(), result)

    def test_lost_name_is_reported_with_its_rename_not_failed(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        code, report = self.invoke(launch=True, mode="name-lost")
        self.assertEqual((code, report["status"]), (0, "ready"), report)
        live = report["targets"][0]["live"]
        self.assertTrue(live["name_lost"])
        self.assertEqual(live["rename_command"], "herdr agent rename w9:p2 greencastle")
        # Reconcile reports the rename; it never runs it.
        self.assertEqual(self.herdr_calls("agent", "rename"), [])

    def test_replaced_terminal_is_not_trusted_or_relaunched(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        for mode in ("replaced-terminal", "shell-pane", "pane-wrong-repo"):
            with self.subTest(mode=mode):
                code, report = self.invoke(launch=True, mode=mode)
                self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
        self.assertEqual(self.count_creates(), 1)

    def test_failed_or_unverifiable_launch_retains_intent_and_never_relaunches(self):
        for mode in ("start-fail", "am-fail", "shell-pane", "pane-wrong-repo"):
            with self.subTest(mode=mode):
                # Fresh isolated receipt for each simulated first launch.
                with LaunchTests("test_preview_checks_admission_and_herdr_but_does_not_start_or_write_receipt") as case:
                    code, report = case.invoke(launch=True, mode=mode)
                    self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
                    self.assertIn(case.label(), report["error"])
                    self.assertTrue(case.receipt.exists())
                    self.assertEqual(case.count_creates(), 1)
                    self.assertEqual(case.invoke(launch=True)[1]["status"], "unconfirmed")
                    self.assertEqual(case.count_creates(), 1)

    def __enter__(self):
        self.setUp()
        return self

    def __exit__(self, *args):
        self.doCleanups()

    def test_warnings_require_explicit_hash_bound_option(self):
        code, _ = self.invoke(mode="warn", launch=True)
        self.assertEqual(code, 2)
        self.assertFalse(self.receipt.exists())
        code, report = self.invoke(mode="warn", launch=True, extra=("--accept-warnings",))
        self.assertEqual((code, report["status"]), (0, "ready"), report)

    def test_pressure_and_malformed_plans_fail_before_herdr_or_receipt(self):
        for mode in ("blocked", "wait", "scale", "over-capacity", "wrong-count", "invalid-checks", "mismatched-code", "bad-plan"):
            with self.subTest(mode=mode):
                code, report = self.invoke(mode=mode, launch=True, extra=("--accept-warnings",))
                self.assertEqual(code, 2, report)
                self.assertFalse(self.receipt.exists())
                self.assertNotIn("sensitive-probe", json.dumps(report))
        self.assertTrue(all(name == "swarm_plan.sh" for name, _ in self.calls()))

    def test_preflight_failure_prevents_intent_and_workspace(self):
        for mode in ("server-down", "existing-workspace"):
            with self.subTest(mode=mode):
                code, report = self.invoke(mode=mode, launch=True)
                self.assertEqual(code, 2, report)
                self.assertFalse(self.receipt.exists())
                self.assertEqual(self.count_creates(), 0)

    def test_missing_helper_or_am_prevents_intent(self):
        (self.lib / "herdr_agents.sh").unlink()
        code, report = self.invoke(launch=True)
        self.assertEqual(code, 2, report)
        self.assertIn("herdr_agents.sh", report["error"])
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.count_creates(), 0)

    def test_hash_required_and_request_changes_refused_before_probes(self):
        self.assertEqual(self.invoke(extra=("--launch",))[0], 2)
        self.assertEqual(self.invoke(launch=True, extra=("--session", "changed"))[0], 2)
        self.assertEqual(self.invoke(launch=True, extra=("--expect-sha256", "0" * 64))[0], 2)
        self.assertEqual(self.calls(), [])

    def test_mismatched_existing_receipt_is_preserved(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        original = self.receipt.read_bytes()
        # A newly reviewed different request still cannot take over an old intent.
        code, _ = self.invoke(extra=("--workload", "heavy"))
        self.assertEqual(code, 2)
        self.assertEqual(self.receipt.read_bytes(), original)
        self.assertEqual(self.count_creates(), 1)

    def test_existing_user_file_and_result_are_not_overwritten(self):
        self.receipt.write_text("important file")
        self.receipt.chmod(0o600)
        self.assertEqual(self.invoke(launch=True)[0], 2)
        self.assertEqual(self.receipt.read_text(), "important file")
        self.assertEqual(self.calls(), [])

    def test_symlink_receipt_refused(self):
        keep = self.root / "keep"
        keep.write_text("important")
        self.receipt.symlink_to(keep)
        self.assertEqual(self.invoke(launch=True)[0], 2)
        self.assertEqual(keep.read_text(), "important")
        self.assertEqual(self.calls(), [])

    def test_private_result_is_required_on_reconciliation(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        (self.root / "intent.json.result.json").chmod(0o644)
        code, report = self.invoke(launch=True)
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))
        self.assertEqual(self.count_creates(), 1)

    def test_invalid_names_types_counts_and_session_never_probe(self):
        for extra in (("--agent", "RedFox:bash"), ("--agent", "redfox:codex"), ("--session", "bad.label"),
                      ("--agent", "$(touch pwned):claude"), ("--session", "name:0")):
            with self.subTest(extra=extra):
                self.assertEqual(self.invoke(extra=extra)[0], 2)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.repo / "pwned").exists())

    def test_busy_receipt_directory_fails_without_probes(self):
        import fcntl
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, report = self.invoke(launch=True)
            self.assertEqual(code, 2, report)
            self.assertIn("Another launch", report["error"])
            self.assertEqual(self.calls(), [])
        finally:
            os.close(fd)

    def test_duplicate_json_receipt_is_rejected(self):
        self.receipt.write_text('{"schema":"one","schema":"two"}')
        self.receipt.chmod(0o600)
        self.assertEqual(self.invoke()[0], 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
