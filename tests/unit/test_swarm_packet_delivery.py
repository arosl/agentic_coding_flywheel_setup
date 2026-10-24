"""Real Bash/Python delivery entry point with executable nhm/herdr/br fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/swarm_packet.sh"
PANE = "w9:p3"

FIXTURE = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
mode = os.environ.get("FIXTURE_MODE", "ok")
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([name, args]) + "\n")
if name == "br":
    assert args == ["ready", "--json"], args
    print(json.dumps([] if mode == "closed" else [{"id": "bd-work", "status": "open"}]))
    sys.exit(0)
if name == "herdr":
    # herdr's CLI answers as its socket API does, inside {"result": ...}.
    if args == ["agent", "list"]:
        checks = sum(1 for line in (root / "calls.jsonl").read_text().splitlines()
                     if json.loads(line) == ["herdr", ["agent", "list"]])
        row = {"pane_id": "w9:p3", "workspace_id": "w8" if mode == "other-workspace" else "w9", "tab_id": "w9:t3",
               "agent": "codex" if mode == "wrong-agent" else "claude", "name": None,
               "agent_status": "blocked" if mode == "dialog" else "idle",
               "cwd": str(root) if mode == "wrong-repo" else str(root / "repo"),
               # Another agent started in the pane between the two checks.
               "terminal_id": "term_65d6a6" + ("x" if mode == "replaced-terminal" and checks > 1 else "")}
        print(json.dumps({"result": {"agents": [] if mode == "not-an-agent" else [row]}}))
        sys.exit(0)
    assert args == ["pane", "process-info", "--pane", "w9:p3"], args
    command = "bash" if mode == "stale-title" else "claude"
    print(json.dumps({"result": {"process_info": {"pane_id": "w9:p3", "shell_pid": 4200,
        "foreground_processes": [{"name": command, "argv": [command], "pid": 4242}]}}}))
    sys.exit(0)
assert name == "nhm"
if args[0].startswith("--robot-send-receipt="):
    assert args == ["--robot-send-receipt=work-one", "--robot-format=json"], args
    store = root / "nhm-operation.json"
    if not store.exists():
        print(json.dumps({"success": False, "error_code": "NOT_FOUND"}))
        sys.exit(1)
    recorded = json.loads(store.read_text())
    print(json.dumps({"success": True, "session": "w9", "operation": recorded["operation"], "outcome": recorded}))
    sys.exit(0)
# nhm's session is the herdr workspace; --panes takes the agent's herdr pane ID,
# and nhm names its target by the agent's slot.
assert "--robot-send=w9" in args, args
assert "--panes=w9:p3" in args and "--type=claude" in args and "--msg-file=-" in args, args
assert "--robot-format=json" in args and "--no-cass" in args and "--with-memory=false" in args, args
payload = sys.stdin.buffer.read()
assert payload == (root / "expected-prompt").read_bytes()
if "--dry-run" in args:
    assert not any(a.startswith("--op-id=") for a in args)
    if mode == "unsupported":
        print("Unknown option", file=sys.stderr)
        sys.exit(2)
    preview = {"success": True, "session": "w9", "dry_run": True, "blocked": False,
               "successful": [], "failed": [], "would_send_to": ["1.1"]}
    if mode == "shell": preview["would_send_to"] = []
    if mode == "broad": preview["would_send_to"] = ["1.1", "1.2"]
    if mode == "injection": preview["cm_injection"] = {"enabled": True, "tokens_added": 10}
    print(json.dumps(preview))
    sys.exit(0)
assert "--op-id=work-one" in args and "--dry-run" not in args
response = {"success": True, "session": "w9", "targets": ["1.1"], "successful": ["1.1"], "failed": [],
            "operation": {"operation_id": "work-one", "status": "completed",
                          "payload_sha256": hashlib.sha256(payload).hexdigest(), "payload_bytes": len(payload),
                          "admissions": [{"target": "1.1", "state": "submitted"}]}}
if mode == "digest-mismatch": response["operation"]["payload_sha256"] = "0" * 64
if mode == "failed": response["successful"] = []
if mode == "no-operation": del response["operation"]
if mode != "missing-receipt": (root / "nhm-operation.json").write_text(json.dumps(response))
if mode in ("lost-response", "missing-receipt"):
    print("secret-raw-output", file=sys.stderr)
    sys.exit(1)
print(json.dumps(response))
'''


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="acfs-delivery-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Prefer the target platform's standard-library interpreter over any
        # developer virtualenv startup hooks; the production path still resolves python3.
        if Path("/usr/bin/python3").is_file():
            (self.bin / "python3").symlink_to("/usr/bin/python3")
        for name in ("nhm", "herdr", "br"):
            path = self.bin / name
            path.write_text(FIXTURE)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], FIXTURE_ROOT=str(self.root))
        self.packet = self.root / "packet.json"
        self.receipt = self.root / "receipt.json"
        self.prompt = "# ACFS Swarm Startup Packet\n\nImplement bd-work; literal $(touch should-not-exist).\n\tIndented.\n"
        self.report = {"schema_version": 1, "status": "pass", "repository": {"path": str(self.repo)},
                       "bead": {"id": "bd-work", "status": "open"},
                       "output": {"truncated": False}, "packet_markdown": self.prompt}
        self.write_packet()

    def write_packet(self):
        self.packet.write_text(json.dumps(self.report), encoding="utf-8")
        (self.root / "expected-prompt").write_bytes(self.report["packet_markdown"].encode())
        self.hash = hashlib.sha256(self.packet.read_bytes()).hexdigest()

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def send_count(self):
        return sum(name == "nhm" and "--robot-send=w9" in args and "--dry-run" not in args
                   for name, args in self.calls())

    def invoke(self, send=False, mode="ok", extra=(), workspace="w9", pane=PANE):
        env = dict(self.env, FIXTURE_MODE=mode)
        args = ["bash", str(SCRIPT), "--deliver", str(self.packet), "--repo", str(self.repo),
                "--workspace", workspace, "--pane-id", pane, "--agent-type", "claude",
                "--operation-id", "work-one", "--receipt", str(self.receipt)]
        if send:
            args += ["--expect-sha256", self.hash, "--send"]
        result = subprocess.run(args + list(extra), env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_preview_has_no_tool_calls_or_writes(self):
        code, report = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "preview")
        self.assertEqual(report["request"]["packet_sha256"], self.hash)
        self.assertEqual(report["nhm_argv"], ["nhm", "--robot-send=w9", "--panes=" + PANE, "--type=claude",
            "--msg-file=-", "--op-id=work-one", "--robot-format=json", "--no-cass", "--with-memory=false"])
        self.assertIn("--expect-sha256", shlex.split(report["send_command"]))
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.receipt.exists())
        self.assertFalse(report["sends_prompt"])

    def test_submit_exact_prompt_and_private_receipt(self):
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertTrue(report["sends_prompt"])
        self.assertFalse(report["agent_execution_verified"])
        self.assertEqual(self.send_count(), 1)
        self.assertEqual(stat.S_IMODE(self.receipt.stat().st_mode), 0o600)
        self.assertNotIn(self.prompt, self.receipt.read_text())
        intent = json.loads(self.receipt.read_text())
        self.assertEqual((set(intent), intent["target"]), ({"schema", "request", "target"}, "1.1"))
        self.assertFalse((self.repo / "should-not-exist").exists())
        self.assertEqual([name for name, _ in self.calls()], ["br", "herdr", "herdr", "nhm", "herdr", "herdr", "nhm"])

    def test_payload_never_reaches_argv(self):
        self.invoke(send=True)
        self.assertTrue(all(self.prompt not in json.dumps(args) for _, args in self.calls()))

    def test_completed_retry_queries_receipt_without_sending(self):
        self.invoke(send=True)
        saved = self.receipt.read_bytes()
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertTrue(report["reconciled_only"])
        self.assertFalse(report["sends_prompt"])
        self.assertEqual(self.send_count(), 1)
        self.assertEqual(self.receipt.read_bytes(), saved)

    def test_lost_response_reconciles_recorded_submission(self):
        code, report = self.invoke(send=True, mode="lost-response")
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))
        self.assertNotIn("secret-raw-output", json.dumps(report))
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertEqual(self.send_count(), 1)

    def test_missing_upstream_receipt_never_resends(self):
        self.invoke(send=True, mode="missing-receipt")
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))
        self.assertTrue(report["reconciled_only"])
        self.assertEqual(self.send_count(), 1)

    def test_live_closed_bead_blocks_before_receipt(self):
        code, report = self.invoke(send=True, mode="closed")
        self.assertEqual(code, 2)
        self.assertIn("ready queue", report["error"])
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.send_count(), 0)

    def test_wrong_repository_blocks_before_dry_run(self):
        code, _ = self.invoke(send=True, mode="wrong-repo")
        self.assertEqual(code, 2)
        self.assertFalse(self.receipt.exists())
        self.assertFalse(any(name == "nhm" for name, _ in self.calls()))

    def test_other_workspace_agent_or_dialog_blocks_before_dry_run(self):
        for mode in ("other-workspace", "wrong-agent", "dialog", "not-an-agent"):
            with self.subTest(mode=mode):
                code, report = self.invoke(send=True, mode=mode)
                self.assertEqual(code, 2, report)
                self.assertFalse(self.receipt.exists())
                self.assertFalse(any(name == "nhm" for name, _ in self.calls()))

    def test_shell_with_stale_agent_title_is_not_a_delivery_target(self):
        code, _ = self.invoke(send=True, mode="stale-title")
        self.assertEqual(code, 2)
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.receipt.exists())

    def test_agent_replaced_between_checks_blocks_before_receipt(self):
        code, report = self.invoke(send=True, mode="replaced-terminal")
        self.assertEqual(code, 2, report)
        self.assertIn("changed", report["error"])
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.receipt.exists())

    def test_shell_broad_unsupported_and_context_injection_block(self):
        for mode in ("shell", "broad", "unsupported", "injection"):
            with self.subTest(mode=mode):
                code, _ = self.invoke(send=True, mode=mode)
                self.assertEqual(code, 2)
                self.assertFalse(self.receipt.exists())
                self.assertEqual(self.send_count(), 0)

    def test_ambiguous_outcome_does_not_claim_success(self):
        code, report = self.invoke(send=True, mode="digest-mismatch")
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))
        self.assertTrue(self.receipt.exists())

    def test_absent_durable_operation_is_not_success(self):
        code, report = self.invoke(send=True, mode="no-operation")
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))

    def test_failed_admission_is_not_success(self):
        code, report = self.invoke(send=True, mode="failed")
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))

    def test_pane_outside_workspace_and_bad_ids_rejected_before_tools(self):
        for workspace, pane in (("w8", PANE), ("w9", "%42"), ("w9", "w9:t3")):
            with self.subTest(pane=pane):
                code, _ = self.invoke(send=True, workspace=workspace, pane=pane)
                self.assertEqual(code, 2)
        self.assertEqual(self.calls(), [])

    def test_preview_hash_required_and_changed_packet_rejected(self):
        code, _ = self.invoke(extra=("--send",))
        self.assertEqual(code, 2)
        code, _ = self.invoke(send=True, extra=("--expect-sha256", "0" * 64))
        self.assertEqual(code, 2)
        self.assertEqual(self.calls(), [])

    def test_different_request_cannot_reuse_receipt(self):
        self.invoke(send=True)
        before = len(self.calls())
        code, _ = self.invoke(send=True, extra=("--operation-id", "different"))
        self.assertEqual(code, 2)
        self.assertEqual(len(self.calls()), before)
        self.assertEqual(self.send_count(), 1)

    def test_truncated_packet_not_delivered(self):
        self.report["output"]["truncated"] = True
        self.write_packet()
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.calls(), [])

    def test_duplicate_keys_rejected_before_tools(self):
        self.packet.write_text('{"schema_version":0,' + json.dumps(self.report)[1:])
        code, _ = self.invoke()
        self.assertEqual(code, 2)
        self.assertEqual(self.calls(), [])

    def test_existing_user_file_not_overwritten(self):
        self.receipt.write_text("user work")
        self.receipt.chmod(0o600)
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.receipt.read_text(), "user work")
        self.assertEqual(self.calls(), [])

    def test_receipt_symlink_is_not_followed(self):
        target = self.root / "keep"
        target.write_text("untouched")
        self.receipt.symlink_to(target)
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(target.read_text(), "untouched")
        self.assertEqual(self.calls(), [])

    def test_receipt_directory_others_can_write_is_refused(self):
        shared = self.root / "shared"
        shared.mkdir()
        self.receipt = shared / "delivery.json"
        for mode in (0o775, 0o757, 0o1777):
            with self.subTest(mode=oct(mode)):
                shared.chmod(mode)
                code, report = self.invoke(send=True)
                self.assertEqual(code, 2, report)
                self.assertIn("Receipt directory", report["error"])
                self.assertEqual(list(shared.iterdir()), [])
        self.assertEqual(self.calls(), [])

    def test_real_generator_output_can_be_delivered(self):
        (self.repo / "AGENTS.md").write_text("Use current project policy.\n")
        (self.repo / "README.md").write_text("Demo project\n")
        bead = self.root / "bead.json"
        bead.write_text(json.dumps({"id": "bd-work", "title": "Implement core", "status": "open", "priority": 1}))
        generated = subprocess.run(["bash", str(SCRIPT), "--json", "--repo", str(self.repo),
            "--bead-file", str(bead), "--no-live-context"], capture_output=True, text=True, timeout=30)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.report = json.loads(generated.stdout)
        self.write_packet()
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)


if __name__ == "__main__":
    unittest.main()
