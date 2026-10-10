#!/usr/bin/env python3
"""Host-safe recovery tests using the real CLI and a bounded herdr fixture."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/swarm_launch_recovery.py"
FIXTURE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ["RECOVERY_FIXTURE"])
log = root / "commands.jsonl"
args = sys.argv[1:]
with log.open("a") as stream:
    stream.write(json.dumps(args) + "\n")
# One observation is one round of reads; it starts with the workspace list.
rounds = sum(1 for line in log.read_text().splitlines() if json.loads(line)[:2] == ["workspace", "list"])
mode = os.environ.get("RECOVERY_MODE", "")
state = json.loads((root / "herdr.json").read_text())
if mode == "error":
    print("DO_NOT_LEAK_SECRET_STDERR", file=sys.stderr)
    sys.exit(17)
if mode == "large":
    print("x" * (1024 * 1024 + 1))
    sys.exit(0)
if mode == "invalid-utf8":
    sys.stdout.buffer.write(b"\xff\n")
    sys.exit(0)
if mode == "timeout":
    time.sleep(30)
if mode == "drift" and rounds == 2 or mode == "post-drift" and rounds == 3:
    state["agents"][0]["shell_pid"] = 9876
if mode == "replace-intent" and rounds == 2 and args[:2] == ["workspace", "list"]:
    intent = pathlib.Path(os.environ["RECOVERY_INTENT"])
    replacement = intent.with_name("replacement")
    replacement.write_bytes(intent.read_bytes())
    replacement.chmod(0o600)
    replacement.replace(intent)
if mode == "rewrite-intent" and rounds == 2 and args[:2] == ["workspace", "list"]:
    intent = pathlib.Path(os.environ["RECOVERY_INTENT"])
    intent.write_bytes(intent.read_bytes() + b" ")
if mode == "result-race" and rounds == 2 and args[:2] == ["workspace", "list"]:
    result = pathlib.Path(os.environ["RECOVERY_INTENT"] + ".result.json")
    result.write_text("retained competitor result")
    result.chmod(0o600)
def ok(result):
    print(json.dumps({"result": result}))
    sys.exit(0)
if args[:2] == ["agents", "list"]:
    # The same fixture serves as am; it registers every tab's name unless told otherwise.
    names = state.get("registered", [a["label"] for a in state["agents"]])
    print(json.dumps([{"name": n, "program": "fixture"} for n in names]))
    sys.exit(0)
if args[:2] == ["workspace", "list"]:
    ok({"workspaces": state["workspaces"]})
if args[:2] == ["tab", "list"]:
    ws = args[args.index("--workspace") + 1]
    ok({"tabs": [{"tab_id": a["tab_id"], "label": a["label"], "workspace_id": ws}
                 for a in state["agents"] if a["workspace_id"] == ws]})
if args[:2] == ["agent", "list"]:
    ok({"agents": [{k: a[k] for k in ("workspace_id", "tab_id", "pane_id", "terminal_id", "agent", "cwd", "name",
                                      "agent_status")} for a in state["agents"]]})
if args[:2] == ["pane", "process-info"]:
    pane = args[args.index("--pane") + 1]
    a = next(a for a in state["agents"] if a["pane_id"] == pane)
    ok({"process_info": {"pane_id": pane, "shell_pid": a["shell_pid"],
        "foreground_processes": [{"name": a["foreground"], "pid": a["shell_pid"] + 1,
                                  "argv": [a.get("argv0", a["foreground"])]}]}})
sys.exit(95)
'''
READ_ONLY = (["workspace", "list"], ["tab", "list"], ["agent", "list"], ["pane", "process-info"],
             ["agents", "list"])


def encode(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=True, indent=2, allow_nan=False) + "\n").encode()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="acfs-recovery-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(os.path.realpath(self.temp.name))
        self.repo = self.root / "repository with spaces"
        self.repo.mkdir()
        self.receipts = self.root / "receipts"
        self.receipts.mkdir(mode=0o700)
        self.intent = self.receipts / "launch.json"
        self.result = Path(str(self.intent) + ".result.json")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("herdr", "am"):
            (self.bin / name).write_text(FIXTURE)
            (self.bin / name).chmod(0o755)
        self.request = {"repo": str(self.repo), "session": "swarm-demo", "receipt": str(self.intent),
            "agents": [{"agent_name": "Reviewer", "agent_type": "codex"},
                       {"agent_name": "Builder", "agent_type": "claude"},
                       {"agent_name": "Tester", "agent_type": "codex"}],
            "profile": "balanced", "workload": "standard", "accept_warnings": False}
        self.save_intent()
        # Deliberately unsorted: slot mapping follows tab creation order.
        self.agents = [self.agent(7, "codex", "OnyxField"), self.agent(3, "claude", "AmberFox"),
                       self.agent(2, "codex", "BlueLake")]
        self.workspaces = [{"workspace_id": "w1", "label": "someone-elses"},
                           {"workspace_id": "w9", "label": self.label()}]
        self.save_state()
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            "RECOVERY_FIXTURE": str(self.root), "RECOVERY_INTENT": str(self.intent)}

    def label(self):
        review = hashlib.sha256(encode({"schema": "acfs.swarm-launch.v2", "request": self.request})).hexdigest()
        return "swarm-swarm-demo-" + review[:12]

    def agent(self, n, kind, mail_name):
        n = str(n)
        return {"workspace_id": "w9", "tab_id": "w9:t" + n, "pane_id": "w9:p" + n, "terminal_id": "term_" + n,
                "agent": kind, "cwd": str(self.repo), "name": mail_name.lower(), "agent_status": "idle",
                "label": mail_name, "shell_pid": 1000 + int(n, 36), "foreground": kind}

    def save_intent(self):
        self.intent.write_text(json.dumps({"schema": "acfs.swarm-launch.v2", "request": self.request}))
        self.intent.chmod(0o600)

    def save_state(self):
        state = {"workspaces": self.workspaces, "agents": self.agents}
        if getattr(self, "registered", None) is not None:
            state["registered"] = self.registered
        (self.root / "herdr.json").write_text(json.dumps(state))

    def invoke(self, *args, code=0, mode=""):
        (self.root / "commands.jsonl").write_text("")
        process = subprocess.run([sys.executable, "-B", str(SCRIPT), "--receipt", str(self.intent), *args],
            env={**self.env, "RECOVERY_MODE": mode}, text=True, capture_output=True, timeout=8)
        self.assertEqual(process.returncode, code, process.stdout + process.stderr)
        self.assertNotIn("Traceback", process.stderr)
        report = json.loads(process.stdout)
        self.assertFalse(report["starts_agents"])
        self.assertFalse(report["work_dispatched"])
        for call in self.calls():
            self.assertIn(call[:2], READ_ONLY)
        return report

    def calls(self):
        return [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]

    def preview(self):
        report = self.invoke()
        self.assertEqual(report["status"], "preview")
        self.assertFalse(report["result_created"])
        self.assertFalse(report["original_launch_verified"])
        self.assertFalse(self.result.exists())
        return report["review_sha256"]

    def adopt(self, review=None, **kwargs):
        if review is None:
            review = self.preview()
        return self.invoke("--adopt", "--expect-sha256", review, **kwargs)

    def test_preview_is_read_only_and_deterministic(self):
        before = self.intent.read_bytes()
        self.assertEqual(self.preview(), self.preview())
        self.assertEqual(self.intent.read_bytes(), before)
        self.assertEqual(list(self.receipts.iterdir()), [self.intent])

    def test_adoption_creates_private_compatible_result_and_preserves_intent(self):
        before = self.intent.read_bytes()
        report = self.adopt()
        self.assertEqual(report["status"], "ready")
        self.assertTrue(report["result_created"])
        self.assertEqual(self.intent.read_bytes(), before)
        self.assertEqual(self.result.stat().st_mode & 0o777, 0o600)
        saved = json.loads(self.result.read_text())
        self.assertEqual(saved["schema"], "acfs.swarm-launch.v2")
        self.assertEqual(saved["request"], self.request)
        self.assertEqual([(t["slot"], t["agent_name"], t["pane_id"], t["agent_mail_name"], t["herdr_name"])
                          for t in saved["targets"]],
                         [(1, "Reviewer", "w9:p2", "BlueLake", "bluelake"), (2, "Builder", "w9:p3", "AmberFox", "amberfox"),
                          (3, "Tester", "w9:p7", "OnyxField", "onyxfield")])
        self.assertEqual({t["workspace_label"] for t in saved["targets"]}, {self.label()})
        self.assertFalse(saved["recovery"]["original_launch_verified"])
        self.assertEqual(saved["recovery"]["schema"], "acfs.swarm-launch-recovery.v2")
        self.assertEqual(saved["recovery"]["review_sha256"], report["review_sha256"])

    def test_agent_output_order_does_not_change_approval(self):
        review = self.preview()
        self.agents.reverse()
        self.save_state()
        self.assertEqual(review, self.preview())
        self.adopt(review)

    def test_agy_slot_is_recovered_by_its_argv0(self):
        self.request["agents"][1]["agent_type"] = "agy"
        self.save_intent()
        self.workspaces[1]["label"] = self.label()
        # agy-locked runs agy-real with argv[0] agy (acfs-zg0); herdr reports the agent as agy.
        self.agents[1] = {**self.agent(3, "agy", "AmberFox"), "foreground": "agy-real", "argv0": "agy"}
        self.save_state()
        self.assertTrue(self.adopt()["result_created"])
        saved = json.loads(self.result.read_text())
        self.assertEqual([(t["slot"], t["agent_type"], t["pane_id"]) for t in saved["targets"]],
                         [(1, "codex", "w9:p2"), (2, "agy", "w9:p3"), (3, "codex", "w9:p7")])

    def test_agy_pane_running_something_else_is_refused(self):
        self.request["agents"][1]["agent_type"] = "agy"
        self.save_intent()
        self.workspaces[1]["label"] = self.label()
        self.agents[1] = {**self.agent(3, "agy", "AmberFox"), "foreground": "agy-real", "argv0": "bash"}
        self.save_state()
        self.invoke(code=2)
        self.assertFalse(self.result.exists())

    def test_tabs_past_nine_keep_creation_order(self):
        # herdr names the tab after t9 "tA", and a decimal parse would refuse it.
        self.agents = [self.agent("A", "codex", "OnyxField"), self.agent(9, "claude", "AmberFox"),
                       self.agent(8, "codex", "BlueLake")]
        self.save_state()
        self.adopt()
        saved = json.loads(self.result.read_text())
        self.assertEqual([(t["slot"], t["tab_id"]) for t in saved["targets"]],
                         [(1, "w9:t8"), (2, "w9:t9"), (3, "w9:tA")])

    def test_lowercase_tab_ids_are_refused(self):
        # Base 36 ignores case, so "ta" would sort as "tA"; herdr's order past tZ is unknown.
        self.agents[0]["tab_id"] = "w9:ta"
        self.save_state()
        self.invoke(code=2)
        self.assertFalse(self.result.exists())

    def test_tab_label_must_be_a_registered_agent_mail_name(self):
        # A lost herdr name leaves only the editable tab label; Agent Mail must know it.
        self.registered = [a["label"] for a in self.agents]
        self.agents[0]["name"] = None
        self.agents[0]["label"] = "RenamedTab"
        self.save_state()
        report = self.invoke(code=2)
        self.assertIn("Agent Mail identity", report["error"])
        self.assertIn(["agents", "list", "--project", str(self.repo), "--json"], self.calls())
        self.assertFalse(self.result.exists())

    def test_launch_state_is_not_part_of_approval(self):
        # A dialog answered between preview and adoption doesn't void the review.
        self.agents[0]["agent_status"] = "blocked"
        self.save_state()
        review = self.preview()
        self.agents[0]["agent_status"] = "idle"
        self.save_state()
        self.adopt(review)

    def test_lost_herdr_name_is_recovered_from_the_tab_label(self):
        for lost in (None, "-"):
            with self.subTest(lost=lost):
                self.agents[0]["name"] = lost
                self.save_state()
                self.preview()
        report = self.adopt()
        self.assertEqual(report["status"], "ready")
        saved = json.loads(self.result.read_text())
        self.assertEqual(saved["targets"][2]["herdr_name"], "onyxfield")

    def test_renamed_tab_or_agent_is_refused_not_guessed(self):
        for key, value in (("label", "Renamed"), ("name", "someoneelse"), ("label", "not a name")):
            with self.subTest(key=key, value=value):
                original = self.agents[0][key]
                self.agents[0][key] = value
                self.save_state()
                self.invoke(code=2)
                self.agents[0][key] = original
        self.save_state()
        self.assertFalse(self.result.exists())

    def test_requires_distinct_recovery_approval_before_observation(self):
        self.invoke("--adopt", code=2)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.result.exists())

    def test_wrong_digest_does_not_publish(self):
        self.adopt("0" * 64, code=2)
        self.assertFalse(self.result.exists())

    def test_approval_binds_pane_terminal_shell_and_workspace_identities(self):
        review = self.preview()
        for key, value in (("pane_id", "w9:p80"), ("terminal_id", "term_80"), ("shell_pid", 1080), ("tab_id", "w9:t80")):
            with self.subTest(key=key):
                original = self.agents[0][key]
                self.agents[0][key] = value
                if key == "tab_id":
                    self.agents[0]["label"] = "OnyxField"
                self.save_state()
                self.adopt(review, code=2)
                self.assertFalse(self.result.exists())
                self.agents[0][key] = original
                self.save_state()

    def test_approval_binds_original_intent_bytes(self):
        review = self.preview()
        self.intent.write_bytes(self.intent.read_bytes() + b" ")
        self.adopt(review, code=2)
        self.assertFalse(self.result.exists())

    def test_recheck_detects_topology_change_before_publish(self):
        self.adopt(mode="drift", code=2)
        self.assertFalse(self.result.exists())

    def test_intent_replacement_is_not_accepted(self):
        self.adopt(mode="replace-intent", code=2)
        self.assertFalse(self.result.exists())

    def test_intent_edit_during_recovery_is_not_accepted(self):
        self.adopt(mode="rewrite-intent", code=2)
        self.assertFalse(self.result.exists())

    def test_racing_result_is_preserved(self):
        self.adopt(mode="result-race", code=2)
        self.assertEqual(self.result.read_text(), "retained competitor result")

    def test_post_publication_drift_retains_result_and_returns_unconfirmed(self):
        report = self.adopt(mode="post-drift", code=1)
        self.assertEqual(report["status"], "unconfirmed")
        self.assertTrue(report["result_created"])
        self.assertTrue(self.result.is_file())
        before = self.result.read_bytes()
        self.invoke(code=2)
        self.assertEqual(self.result.read_bytes(), before)

    def test_existing_result_is_never_replaced(self):
        self.result.write_text("incomplete result to inspect")
        self.invoke(code=2)
        self.assertEqual(self.result.read_text(), "incomplete result to inspect")
        self.assertEqual(self.calls(), [])

    def test_existing_dangling_result_symlink_is_preserved(self):
        self.result.symlink_to(self.root / "missing")
        self.invoke(code=2)
        self.assertTrue(self.result.is_symlink())
        self.assertFalse((self.root / "missing").exists())

    def test_busy_launch_directory_is_refused(self):
        fd = os.open(self.receipts, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.invoke(code=2)
        self.assertFalse(self.result.exists())

    def test_unknown_or_extra_request_fields_are_rejected(self):
        self.request["force"] = True
        self.save_intent()
        self.invoke(code=2)

    def test_v1_ntm_intent_is_refused(self):
        self.intent.write_text(json.dumps({"schema": "acfs.swarm-launch.v1", "request": self.request}))
        self.intent.chmod(0o600)
        self.invoke(code=2)
        self.assertEqual(self.calls(), [])

    def test_wrong_receipt_path_is_rejected(self):
        self.request["receipt"] = str(self.receipts / "other.json")
        self.save_intent()
        self.invoke(code=2)

    def test_duplicate_keys_and_nonfinite_json_are_rejected(self):
        for raw in ('{"schema":1,"schema":2}', '{"schema":NaN}', '{"schema":"\\ud800"}'):
            with self.subTest(raw=raw):
                self.intent.write_text(raw)
                self.invoke(code=2)

    def test_huge_intent_is_rejected_without_observation(self):
        self.intent.write_bytes(b" " * (1024 * 1024 + 1))
        self.invoke(code=2)
        self.assertEqual(self.calls(), [])

    def test_unprivate_intent_is_rejected(self):
        self.intent.chmod(0o644)
        self.invoke(code=2)

    def test_hardlinked_intent_is_rejected(self):
        os.link(self.intent, self.receipts / "intent-link")
        self.invoke(code=2)

    def test_symlinked_intent_is_rejected(self):
        real = self.receipts / "real-intent"
        self.intent.rename(real)
        self.intent.symlink_to(real)
        self.invoke(code=2)

    def test_nonregular_intent_does_not_block(self):
        self.intent.unlink()
        os.mkfifo(self.intent, 0o600)
        self.invoke(code=2)

    def test_writable_receipt_directory_is_rejected(self):
        self.receipts.chmod(0o777)
        self.invoke(code=2)

    def test_missing_or_ambiguous_workspace_is_rejected(self):
        for workspaces in ([self.workspaces[0]], self.workspaces + [{"workspace_id": "w8", "label": self.label()}]):
            with self.subTest(workspaces=workspaces):
                self.workspaces_saved = self.workspaces
                self.workspaces = workspaces
                self.save_state()
                self.invoke(code=2)
                self.workspaces = self.workspaces_saved
        self.assertFalse(self.result.exists())

    def test_missing_extra_or_shell_agents_are_rejected(self):
        original = [dict(a) for a in self.agents]
        cases = [original[:-1], original + [self.agent(20, "codex", "CopperHill")]]
        for key, value in (("foreground", "bash"), ("agent", "bash"), ("shell_pid", 0)):
            changed = [dict(a) for a in original]
            changed[0][key] = value
            cases.append(changed)
        for agents in cases:
            with self.subTest(agents=agents):
                self.agents = agents
                self.save_state()
                self.invoke(code=2)
                self.assertFalse(self.result.exists())

    def test_duplicate_terminal_shell_or_tab_is_rejected(self):
        for key in ("terminal_id", "shell_pid"):
            with self.subTest(key=key):
                original = self.agents[0][key]
                self.agents[0][key] = self.agents[1][key]
                self.save_state()
                self.invoke(code=2)
                self.agents[0][key] = original
                self.save_state()

    def test_native_agent_mix_must_match(self):
        self.agents[1]["agent"] = "codex"
        self.agents[1]["foreground"] = "codex"
        self.save_state()
        self.invoke(code=2)

    def test_outside_repo_agent_is_rejected(self):
        self.agents[0]["cwd"] = str(self.root)
        self.save_state()
        self.invoke(code=2)

    def test_subdirectory_agent_is_accepted(self):
        child = self.repo / "src"
        child.mkdir()
        self.agents[0]["cwd"] = str(child)
        self.save_state()
        self.adopt()

    def test_command_failure_is_redacted(self):
        report = self.invoke(mode="error", code=2)
        self.assertNotIn("DO_NOT_LEAK", json.dumps(report))

    def test_oversized_and_invalid_observations_are_rejected(self):
        self.invoke(mode="large", code=2)
        self.invoke(mode="invalid-utf8", code=2)
        self.assertFalse(self.result.exists())

    def test_observation_deadline_is_enforced(self):
        self.invoke("--timeout", "1", mode="timeout", code=2)
        self.assertFalse(self.result.exists())


if __name__ == "__main__":
    unittest.main()
