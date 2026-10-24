"""Execute the real launch CLI against native-process contract fixtures.

nhm, herdr and the planner are fixtures; the launcher runs unchanged between them.
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

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/lib/swarm_launch.sh"

FIXTURE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["LAUNCH_TEST_ROOT"])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
mode = os.environ.get("LAUNCH_TEST_MODE", "ok")
assert pathlib.Path.cwd() == root / "repo"
with (root / "calls").open("a") as f:
    f.write(json.dumps([name, args]) + "\n")
state_path = root / "herdr-state.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {"agents": [], "next": 2}
def flag(prefix):
    return next(a[len(prefix):] for a in args if a.startswith(prefix))
def opt(key):
    return args[args.index(key) + 1]
def ok(result):
    print(json.dumps({"result": result})); sys.exit(0)
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
if name == "nhm":
    # nhm's --robot-spawn, in the shape of tests/fixtures/nhm/robot_spawn*.json:
    # one agent per tab of a new herdr workspace labelled with the launch's
    # label, each with its Agent Mail name.
    assert "--spawn-safety" in args and "--spawn-no-user" in args and "--spawn-wait" in args
    assert "--timeout=60s" in args and "--robot-format=json" in args
    assert not any("assign-work" in a or "robot-send" in a or "spawn-prompt" in a for a in args)
    assert flag("--spawn-dir=") == str(root / "repo")
    session = flag("--robot-spawn=")
    assert session == os.environ["LAUNCH_TEST_LABEL"]
    types = ["claude"] * int(flag("--spawn-cc=")) + ["codex"] * int(flag("--spawn-cod="))
    dry = "--dry-run" in args
    response = {"success": True, "session": session, "working_dir": str(root / "repo"),
        "effective_project_key": str(root / "repo"), "assignments": [],
        "admission": {"decision": "admit"}, "agents": []}
    if dry:
        if mode == "existing-session": print('{"success":false}'); sys.exit(1)
        agents = [{"pane": "1." + str(i), "type": kind, "ready": False} for i, kind in enumerate(types, 1)]
        response.update(dry_run=True, would_create=agents)
        if mode == "unsupported": print('unknown flag --spawn-safety', file=sys.stderr); sys.exit(2)
        if mode == "nhm-defer": response["admission"]["decision"] = "defer"
        if mode == "no-nhm-admission": del response["admission"]
        if mode == "extra-agent": response["would_create"].append({"pane": "1.9", "type": "codex"})
        if mode == "wrong-project": response["working_dir"] = str(root)
        if mode == "different-project-key": response["effective_project_key"] = str(root)
        if mode == "bad-mix": agents[-1]["type"] = "claude"
        if mode == "dup-pane": agents[-1]["pane"] = agents[0]["pane"]
    else:
        # The caller must have published a durable private intent before spawning.
        intent = root / "intent.json"
        assert intent.exists() and (intent.stat().st_mode & 0o077) == 0
        names = ["GreenCastle", "AmberFox", "CopperHill"]
        agents = []
        # As nhm's robot spawn does: one tab holds a launch's agents, a pane
        # each, in slots 1.1, 1.2, ... (acfs-q51a).
        tab = "w9:t%d" % state["next"]
        for i, kind in enumerate(types):
            n = state["next"]
            state["next"] += 1
            state["agents"].append({"workspace_id": "w9", "tab_id": tab, "pane_id": "w9:p%d" % n,
                "name": names[i].lower(), "agent": kind, "agent_status": "idle", "cwd": str(root / "repo"),
                "terminal_id": "term_%d" % n})
            agents.append({"pane": "1.%d" % (i + 1), "pane_id": "w9:p%d" % n, "agent_mail_name": names[i],
                "name": names[i].lower(), "type": kind, "ready": True})
        state["workspaces"] = [{"workspace_id": "w9", "label": session}]
        state_path.write_text(json.dumps(state))
        response["agents"] = agents
        if mode == "lost-response": print('private-provider-message', file=sys.stderr); sys.exit(1)
        if mode == "not-ready": agents[0]["ready"] = False
        if mode == "failed-spawn": response["success"] = False
        if mode == "malformed-spawn": print('unparseable-private-output'); sys.exit(0)
    print(json.dumps(response)); sys.exit(0)
assert name == "herdr"
# herdr is only asked about agents that nhm started.
assert state_path.exists()
if args[:2] == ["workspace", "list"]:
    workspaces = [dict(w) for w in state["workspaces"]]
    # Another workspace has the launch's agents: tmux's pane in another session.
    if mode == "relabelled-workspace": workspaces[0]["label"] = "project"
    ok({"workspaces": workspaces})
if args[:2] == ["agent", "list"]:
    agents = [dict(a) for a in state["agents"]]
    for a in agents:
        if mode == "replaced-terminal": a["terminal_id"] += "x"
        if mode == "pane-wrong-repo": a["cwd"] = str(root)
        # Two panes that show one terminal.
        if mode == "aliased-panes": a["terminal_id"] = state["agents"][0]["terminal_id"]
    ok({"agents": agents})
if args[:2] == ["pane", "process-info"]:
    pane = opt("--pane")
    agent = next(a for a in state["agents"] if a["pane_id"] == pane)
    n = int(pane.rsplit(":p", 1)[1])
    kind = "bash" if mode == "shell-pane" else agent["agent"]
    ok({"process_info": {"pane_id": pane, "shell_pid": 1000 + n,
        "foreground_processes": [{"name": kind, "pid": 2000 + n, "argv": [kind]}]}})
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
        # The planner is a Bash entrypoint like production; a native fixture
        # implements its contract while all launcher code is copied unchanged.
        for path in (self.bin / "nhm", self.bin / "herdr", self.bin / "swarm_plan.sh"):
            path.write_text(FIXTURE)
            path.chmod(0o755)
        (self.lib / "swarm_plan.sh").write_text('#!/usr/bin/env bash\nexec "' + str(self.bin / "swarm_plan.sh") + '" "$@"\n')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], LAUNCH_TEST_ROOT=str(self.root))
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

    def label(self, extra=()):
        # The launch's herdr workspace label: the session and its request's hash.
        return "swarm-project-" + self.review_hash(extra)[:12]

    def calls(self):
        path = self.root / "calls"
        return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []

    def count_spawns(self):
        return sum(name == "nhm" and "--dry-run" not in argv for name, argv in self.calls())

    def invoke(self, mode="ok", extra=(), launch=False):
        args = [*self.args]
        if launch:
            args.extend(("--launch", "--expect-sha256", self.review_hash(extra)))
        result = subprocess.run([*args, *extra], env=dict(self.env, LAUNCH_TEST_MODE=mode, LAUNCH_TEST_LABEL=self.label(extra)),
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_preview_checks_admission_but_does_not_start_or_write_receipt(self):
        code, report = self.invoke()
        self.assertEqual((code, report["status"]), (0, "preview"), report)
        self.assertFalse(report["starts_agents"])
        self.assertEqual([n for n, _ in self.calls()], ["swarm_plan.sh", "nhm"])
        self.assertEqual(self.count_spawns(), 0)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(report["nhm_argv"], ["nhm", "--robot-spawn=" + self.label(), "--spawn-dir=" + str(self.repo),
            "--spawn-cc=1", "--spawn-cod=1", "--spawn-no-user", "--spawn-safety", "--spawn-wait", "--timeout=60s",
            "--robot-format=json"])
        self.assertIn("--expect-sha256", shlex.split(report["launch_command"]))

    def test_launch_verifies_native_agents_and_maps_original_slots(self):
        code, report = self.invoke(launch=True)
        self.assertEqual((code, report["status"]), (0, "ready"), report)
        # nhm starts claude before codex; each slot takes the next agent of its kind.
        self.assertEqual(report["preparation_targets"], ["1:AmberFox:codex:w9:p3", "2:GreenCastle:claude:w9:p2"])
        self.assertTrue(report["starts_agents"])
        self.assertTrue(report["agent_mail_registered"])
        self.assertFalse(report["work_dispatched"])
        self.assertFalse(report["authentication_verified"])
        self.assertEqual(self.count_spawns(), 1)
        # nhm starts the agents; herdr is only read.
        self.assertEqual({tuple(a[:2]) for n, a in self.calls() if n == "herdr"},
                         {("agent", "list"), ("pane", "process-info"), ("workspace", "list")})
        targets = json.loads((self.root / "intent.json.result.json").read_text())["targets"]
        self.assertEqual(report["targets"], targets)
        self.assertEqual(targets, [
            {"slot": 1, "agent_name": "BlueLake", "agent_type": "codex", "agent_mail_name": "AmberFox",
             "herdr_name": "amberfox", "workspace_id": "w9", "workspace_label": self.label(), "tab_id": "w9:t2",
             "pane_id": "w9:p3", "terminal_id": "term_3", "shell_pid": 1003, "launched_state": "ready"},
            {"slot": 2, "agent_name": "RedFox", "agent_type": "claude", "agent_mail_name": "GreenCastle",
             "herdr_name": "greencastle", "workspace_id": "w9", "workspace_label": self.label(), "tab_id": "w9:t2",
             "pane_id": "w9:p2", "terminal_id": "term_2", "shell_pid": 1002, "launched_state": "ready"}])
        for name in ("intent.json", "intent.json.result.json"):
            self.assertEqual(stat.S_IMODE((self.root / name).stat().st_mode), 0o600)

    def test_repeat_only_verifies_recorded_stable_panes(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        intent, result = self.receipt.read_bytes(), (self.root / "intent.json.result.json").read_bytes()
        before = len(self.calls())
        code, report = self.invoke(launch=True)
        self.assertEqual((code, report["status"]), (0, "ready"), report)
        self.assertTrue(report["reconciled_only"])
        self.assertFalse(report["starts_agents"])
        self.assertEqual([a[:2] for _, a in self.calls()[before:]],
                         [["workspace", "list"], ["agent", "list"], ["pane", "process-info"], ["pane", "process-info"]])
        self.assertEqual(self.count_spawns(), 1)
        self.assertEqual(self.receipt.read_bytes(), intent)
        self.assertEqual((self.root / "intent.json.result.json").read_bytes(), result)

    def test_lost_response_never_relaunches_or_adopts_unknown_session(self):
        code, report = self.invoke(launch=True, mode="lost-response")
        self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
        self.assertNotIn("private-provider", json.dumps(report))
        before = len(self.calls())
        code, report = self.invoke(launch=True)
        self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
        self.assertEqual(len(self.calls()), before)
        self.assertEqual(self.count_spawns(), 1)

    def test_replaced_terminal_is_not_trusted_or_relaunched(self):
        self.assertEqual(self.invoke(launch=True)[0], 0)
        for mode in ("replaced-terminal", "shell-pane", "pane-wrong-repo", "relabelled-workspace"):
            with self.subTest(mode=mode):
                code, report = self.invoke(launch=True, mode=mode)
                self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
        self.assertEqual(self.count_spawns(), 1)

    def test_unready_or_invalid_launch_retains_intent(self):
        for mode in ("not-ready", "failed-spawn", "malformed-spawn", "shell-pane", "pane-wrong-repo", "aliased-panes",
                     "relabelled-workspace"):
            with self.subTest(mode=mode):
                # Fresh isolated receipt for each simulated first launch.
                with LaunchTests("test_preview_checks_admission_but_does_not_start_or_write_receipt") as case:
                    code, report = case.invoke(launch=True, mode=mode)
                    self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
                    if mode in ("not-ready", "relabelled-workspace"):
                        # The label is not the session the user typed, so the error names it.
                        self.assertIn(case.label(), report["error"])
                    self.assertTrue(case.receipt.exists())
                    self.assertEqual(case.count_spawns(), 1)
                    self.assertEqual(case.invoke(launch=True)[1]["status"], "unconfirmed")
                    self.assertEqual(case.count_spawns(), 1)

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

    def test_pressure_and_malformed_plans_fail_before_nhm_or_receipt(self):
        for mode in ("blocked", "wait", "scale", "over-capacity", "wrong-count", "invalid-checks", "mismatched-code", "bad-plan"):
            with self.subTest(mode=mode):
                code, report = self.invoke(mode=mode, launch=True, extra=("--accept-warnings",))
                self.assertEqual(code, 2, report)
                self.assertFalse(self.receipt.exists())
                self.assertNotIn("sensitive-probe", json.dumps(report))
        self.assertTrue(all(name == "swarm_plan.sh" for name, _ in self.calls()))

    def test_nhm_dry_run_failure_prevents_intent_and_spawn(self):
        for mode in ("existing-session", "unsupported", "nhm-defer", "no-nhm-admission", "extra-agent", "wrong-project",
                     "different-project-key", "bad-mix", "dup-pane"):
            with self.subTest(mode=mode):
                code, report = self.invoke(mode=mode, launch=True)
                self.assertEqual(code, 2, report)
                self.assertFalse(self.receipt.exists())
                self.assertEqual(self.count_spawns(), 0)

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
        self.assertEqual(self.count_spawns(), 1)

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
        self.assertEqual(self.count_spawns(), 1)

    def test_invalid_names_types_counts_and_session_never_probe(self):
        for extra in (("--agent", "RedFox:bash"), ("--agent", "redfox:codex"), ("--session", "bad--label"),
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
