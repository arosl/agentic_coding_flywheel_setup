"""Real Bash/Python delivery entry point against a herdr socket stub and a br fixture."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from herdr_socket_stub import HerdrStub, agent_row  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/swarm_packet.sh"
SCHEMA_FIXTURE = ROOT / "tests/fixtures/herdr/agent_prompt_schema.json"

BR = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([pathlib.Path(sys.argv[0]).name, sys.argv[1:]]) + "\n")
assert sys.argv[1:] == ["ready", "--json"], sys.argv
closed = (root / "closed").exists()
print(json.dumps([] if closed else [{"id": "bd-work", "status": "open"}]))
'''

PANE = "w9:p3"


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
        (self.bin / "br").write_text(BR)
        (self.bin / "br").chmod(0o755)
        self.herdr = HerdrStub([agent_row(PANE, self.repo)])
        self.addCleanup(self.herdr.close)
        self.env = self.herdr.env(dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                       FIXTURE_ROOT=str(self.root)))
        self.packet = self.root / "packet.json"
        self.receipt = self.root / "receipt.json"
        self.result = self.root / "receipt.json.result.json"
        self.prompt = "# ACFS Swarm Startup Packet\n\nImplement bd-work; literal $(touch should-not-exist).\n\tIndented.\n"
        self.report = {"schema_version": 1, "status": "pass", "repository": {"path": str(self.repo)},
                       "bead": {"id": "bd-work", "status": "open"},
                       "output": {"truncated": False}, "packet_markdown": self.prompt}
        self.write_packet()

    def write_packet(self):
        self.packet.write_text(json.dumps(self.report), encoding="utf-8")
        self.hash = hashlib.sha256(self.packet.read_bytes()).hexdigest()

    def br_calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def send_count(self):
        return len(self.herdr.prompts())

    def invoke(self, send=False, mode="ok", extra=(), workspace="w9", pane=PANE, agent_type="claude", env=None):
        self.herdr.mode = mode
        args = ["bash", str(SCRIPT), "--deliver", str(self.packet), "--repo", str(self.repo),
                "--workspace", workspace, "--pane-id", pane, "--agent-type", agent_type,
                "--operation-id", "work-one", "--receipt", str(self.receipt)]
        if send:
            args += ["--expect-sha256", self.hash, "--send"]
        result = subprocess.run(args + list(extra), env=env or self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_preview_has_no_tool_calls_or_writes(self):
        code, report = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "preview")
        self.assertEqual(report["request"]["packet_sha256"], self.hash)
        self.assertEqual(report["herdr_request"], {"method": "agent.prompt", "target": PANE})
        self.assertIn("--expect-sha256", shlex.split(report["send_command"]))
        self.assertEqual(self.br_calls(), [])
        self.assertEqual(self.herdr.calls, [])
        self.assertFalse(self.receipt.exists())
        self.assertFalse(report["sends_prompt"])

    def test_submit_exact_prompt_over_the_socket_with_private_receipts(self):
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertTrue(report["sends_prompt"])
        self.assertFalse(report["agent_execution_verified"])
        self.assertEqual(self.herdr.prompts(), [{"target": PANE, "text": self.prompt}])
        self.assertEqual([method for method, _ in self.herdr.calls],
                         ["agent.list", "pane.process_info", "agent.list", "pane.process_info", "agent.prompt"])
        self.assertEqual([name for name, _ in self.br_calls()], ["br"])
        for path in (self.receipt, self.result):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertNotIn("should-not-exist", path.read_text())
        result = json.loads(self.result.read_text())
        self.assertEqual((result["status"], result["target"]), ("submitted", "term_w9_p3"))
        self.assertFalse((self.repo / "should-not-exist").exists())

    def test_payload_never_reaches_argv(self):
        self.invoke(send=True)
        self.assertTrue(all(self.prompt not in json.dumps(args) for _, args in self.br_calls()))

    def test_completed_retry_reads_result_without_sending(self):
        self.invoke(send=True)
        saved = self.receipt.read_bytes(), self.result.read_bytes()
        calls = len(self.herdr.calls)
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertTrue(report["reconciled_only"])
        self.assertFalse(report["sends_prompt"])
        self.assertEqual(len(self.herdr.calls), calls)
        self.assertEqual((self.receipt.read_bytes(), self.result.read_bytes()), saved)

    def test_uncertain_answers_are_unconfirmed_and_never_resent(self):
        for mode in ("disconnect", "garbage", "wrong_id", "wrong_pane", "unknown_error", "oversize"):
            with self.subTest(mode=mode):
                for path in (self.receipt, self.result):
                    if path.exists():
                        path.unlink()
                before = self.send_count()
                code, report = self.invoke(send=True, mode=mode)
                self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
                self.assertTrue(report["sends_prompt"])
                self.assertTrue(self.receipt.exists())
                self.assertFalse(self.result.exists())
                self.assertIn("herdr agent read " + PANE, report["recovery"])
                code, report = self.invoke(send=True)
                self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
                self.assertTrue(report["reconciled_only"])
                self.assertEqual(self.send_count(), before + 1)

    def test_refusal_before_typing_is_recorded_and_never_retried(self):
        for mode, error_code in (("blocked", "agent_blocked"), ("not_found", "agent_not_found")):
            with self.subTest(mode=mode):
                for path in (self.receipt, self.result):
                    if path.exists():
                        path.unlink()
                code, report = self.invoke(send=True, mode=mode)
                self.assertEqual((code, report["status"]), (1, "refused"), report)
                self.assertFalse(report["sends_prompt"])
                self.assertEqual(report["evidence"], {"error_code": error_code})
                self.assertEqual(json.loads(self.result.read_text())["status"], "refused")
                before = self.send_count()
                code, report = self.invoke(send=True)
                self.assertEqual((code, report["status"]), (1, "refused"), report)
                self.assertEqual(self.send_count(), before)

    def test_orphan_result_file_blocks_before_any_send(self):
        self.result.write_text("someone else's result")
        self.result.chmod(0o600)
        code, report = self.invoke(send=True)
        self.assertEqual(code, 2, report)
        self.assertIn("result file already exists", report["error"])
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.result.read_text(), "someone else's result")

    def test_packet_cannot_be_the_result_file(self):
        self.receipt = self.root / "packet"
        self.packet.rename(self.root / "packet.result.json")
        self.packet = self.root / "packet.result.json"
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.herdr.calls, [])

    def test_agent_session_is_bound_through_the_send(self):
        self.herdr.agents[PANE] = agent_row(PANE, self.repo, session="session-one")
        code, report = self.invoke(send=True, mode="session_changed")
        self.assertEqual((code, report["status"]), (1, "unconfirmed"), report)
        self.assertEqual(json.loads(self.receipt.read_text())["agent_session"], "session-one")
        self.assertFalse(self.result.exists())
        self.receipt.unlink()
        code, report = self.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertEqual(report["evidence"]["agent_session"], "session-one")

    def test_live_closed_bead_blocks_before_receipt(self):
        (self.root / "closed").write_text("")
        code, report = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertIn("ready queue", report["error"])
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.herdr.calls, [])

    def test_target_mismatches_block_before_receipt(self):
        cases = {
            "wrong repository": dict(cwd=str(self.root)),
            "wrong agent": dict(agent="codex"),
            "dialog": dict(agent_status="blocked"),
            "other workspace": dict(workspace_id="w8"),
        }
        for label, change in cases.items():
            with self.subTest(label):
                self.herdr.agents[PANE] = dict(agent_row(PANE, self.repo), **change)
                code, report = self.invoke(send=True)
                self.assertEqual(code, 2, report)
                self.assertFalse(self.receipt.exists())
                self.assertEqual(self.send_count(), 0)

    def test_shell_pane_is_not_a_delivery_target(self):
        self.herdr.processes[PANE] = [{"name": "zsh", "argv": ["/usr/bin/zsh"], "pid": 1}]
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.send_count(), 0)
        self.assertFalse(self.receipt.exists())
        del self.herdr.agents[PANE]
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.send_count(), 0)

    def test_agy_is_recognized_by_its_argv0(self):
        self.herdr.agents[PANE] = agent_row(PANE, self.repo, agent="agy")
        self.herdr.processes[PANE] = [{"name": "python3", "argv": ["python3", "agy-locked"], "pid": 1},
                                      {"name": "agy-real", "argv": ["agy", "--model", "x"], "pid": 2}]
        code, report = self.invoke(send=True, agent_type="agy")
        self.assertEqual((code, report["status"]), (0, "submitted"), report)

    def test_pane_outside_workspace_and_bad_ids_rejected_before_tools(self):
        for workspace, pane in (("w8", PANE), ("w9", "%42"), ("w9", "w9:t3")):
            with self.subTest(pane=pane):
                code, _ = self.invoke(send=True, workspace=workspace, pane=pane)
                self.assertEqual(code, 2)
        self.assertEqual(self.herdr.calls, [])
        self.assertEqual(self.br_calls(), [])

    def test_socket_must_be_this_users_socket(self):
        fake = self.root / "not-a-socket"
        fake.write_text("")
        code, report = self.invoke(send=True, env=dict(self.env, HERDR_SOCKET_PATH=str(fake)))
        self.assertEqual(code, 2)
        self.assertIn("socket", report["error"])
        self.assertFalse(self.receipt.exists())

    def test_preview_hash_required_and_changed_packet_rejected(self):
        code, _ = self.invoke(extra=("--send",))
        self.assertEqual(code, 2)
        code, _ = self.invoke(send=True, extra=("--expect-sha256", "0" * 64))
        self.assertEqual(code, 2)
        self.assertEqual(self.herdr.calls, [])

    def test_different_request_cannot_reuse_receipt(self):
        self.invoke(send=True)
        before = len(self.herdr.calls)
        code, _ = self.invoke(send=True, extra=("--operation-id", "different"))
        self.assertEqual(code, 2)
        self.assertEqual(len(self.herdr.calls), before)
        self.assertEqual(self.send_count(), 1)

    def test_foreign_result_file_is_not_trusted(self):
        self.invoke(send=True, mode="disconnect")
        self.result.write_text(json.dumps({"schema": "acfs.packet-delivery.v2", "status": "submitted"}))
        self.result.chmod(0o600)
        code, report = self.invoke(send=True)
        self.assertEqual(code, 2, report)
        self.assertEqual(self.send_count(), 1)

    def test_truncated_packet_not_delivered(self):
        self.report["output"]["truncated"] = True
        self.write_packet()
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.herdr.calls, [])

    def test_duplicate_keys_rejected_before_tools(self):
        self.packet.write_text('{"schema_version":0,' + json.dumps(self.report)[1:])
        code, _ = self.invoke()
        self.assertEqual(code, 2)
        self.assertEqual(self.herdr.calls, [])

    def test_existing_user_file_not_overwritten(self):
        self.receipt.write_text("user work")
        self.receipt.chmod(0o600)
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.receipt.read_text(), "user work")
        self.assertEqual(self.herdr.calls, [])

    def test_receipt_symlink_is_not_followed(self):
        target = self.root / "keep"
        target.write_text("untouched")
        self.receipt.symlink_to(target)
        code, _ = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertEqual(target.read_text(), "untouched")
        self.assertEqual(self.herdr.calls, [])

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
        self.assertEqual(self.herdr.calls, [])

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
        self.assertEqual(self.herdr.prompts()[0]["text"], self.report["packet_markdown"])


class HerdrSchemaContractTests(unittest.TestCase):
    """Delivery's socket requests match herdr's published API schema."""

    def setUp(self):
        self.fixture = json.loads(SCHEMA_FIXTURE.read_text())

    def check_request(self, method, params):
        self.assertIn(method, self.fixture["methods"])
        schema = self.fixture["params"][self.fixture["methods"][method]]
        properties = schema.get("properties", {})
        self.assertLessEqual(set(params), set(properties), (method, params))
        self.assertLessEqual(set(schema.get("required", [])), set(params), (method, params))
        for key, value in params.items():
            allowed = properties[key].get("type")
            allowed = allowed if isinstance(allowed, list) else [allowed]
            self.assertIn("string", allowed, (method, key))
            self.assertIsInstance(value, str)

    def test_every_request_a_delivery_sends_fits_the_schema(self):
        case = DeliveryTests("test_submit_exact_prompt_over_the_socket_with_private_receipts")
        case.setUp()
        self.addCleanup(case.doCleanups)
        code, report = case.invoke(send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertEqual({method for method, _ in case.herdr.calls}, set(self.fixture["methods"]))
        for method, params in case.herdr.calls:
            self.check_request(method, params)

    def test_fixture_matches_the_installed_herdr(self):
        herdr = shutil.which("herdr")
        if herdr is None:
            self.skipTest("herdr is not installed; the committed fixture is the contract")
        live = json.loads(subprocess.run([herdr, "api", "schema", "--json"], capture_output=True,
                                         text=True, timeout=30, check=True).stdout)
        requests = {item["properties"]["method"]["const"]: item["properties"]["params"]["$ref"].rsplit("/", 1)[1]
                    for item in live["schemas"]["request"]["oneOf"]}
        self.assertEqual(live["protocol"], self.fixture["protocol"],
                         "herdr's protocol changed; re-check delivery and refresh the fixture")
        for method, name in self.fixture["methods"].items():
            self.assertEqual(requests.get(method), name, method)
        for name, schema in self.fixture["params"].items():
            self.assertEqual(live["schemas"]["request"]["$defs"][name], schema, name)
        self.assertEqual(live["schemas"]["error_response"]["$defs"]["ErrorBody"], self.fixture["error_body"])


if __name__ == "__main__":
    unittest.main()
