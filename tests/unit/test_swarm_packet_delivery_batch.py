"""Multi-agent dispatch and cross-process recovery through the real entrypoint."""
import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from herdr_socket_stub import HerdrStub, agent_row  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/swarm_packet.sh"

BR = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["BATCH_FIXTURE_ROOT"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([pathlib.Path(sys.argv[0]).name, sys.argv[1:]]) + "\n")
assert sys.argv[1:] == ["ready", "--json"], sys.argv
not_ready = (root / "not-ready").exists()
print(json.dumps([{"id": "bd-" + str(i), "status": "open"} for i in (1, 2, 3) if not (not_ready and i == 2)]))
'''


def pane(i):
    return "w9:p" + str(i)


class BatchDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="acfs-batch-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        if Path("/usr/bin/python3").exists():
            (self.bin / "python3").symlink_to("/usr/bin/python3")
        (self.bin / "br").write_text(BR)
        (self.bin / "br").chmod(0o755)
        self.herdr = HerdrStub([agent_row(pane(i), self.repo, agent="codex" if i == 2 else "claude")
                                for i in (1, 2, 3)])
        self.addCleanup(self.herdr.close)
        self.env = self.herdr.env(dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                       BATCH_FIXTURE_ROOT=str(self.root)))
        self.batch = self.root / "batch.json"
        self.spec = {"schema": "acfs.packet-delivery-batch.v2", "deliveries": []}
        self.prompts = {}
        for i in (1, 2, 3):
            prompt = "# ACFS Swarm Startup Packet\n\nTask bd-" + str(i) + "; private code context.\n"
            self.prompts[pane(i)] = prompt
            packet = {"schema_version": 1, "status": "pass", "repository": {"path": str(self.repo)},
                      "bead": {"id": "bd-" + str(i), "status": "open"},
                      "output": {"truncated": False}, "packet_markdown": prompt}
            (self.root / ("packet-" + str(i) + ".json")).write_text(json.dumps(packet))
            self.spec["deliveries"].append({"packet": "packet-" + str(i) + ".json", "repo": "repo",
                "workspace": "w9", "pane_id": pane(i), "agent_type": "codex" if i == 2 else "claude",
                "operation_id": "batch-op-" + str(i), "receipt": "receipt-" + str(i) + ".json"})
        self.save()

    def save(self):
        self.batch.write_text(json.dumps(self.spec))

    def invoke(self, review_hash=None, send=False):
        args = ["bash", str(SCRIPT), "--deliver-batch", str(self.batch)]
        if review_hash is not None:
            args += ["--expect-sha256", review_hash]
        if send:
            args.append("--send")
        result = subprocess.run(args, cwd="/", env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.stderr, "", result.stderr)
        report = json.loads(result.stdout)
        self.assertNotIn("private code context", result.stdout)
        return result.returncode, report

    def preview_hash(self):
        code, report = self.invoke()
        self.assertEqual(code, 0, report)
        return report["review_sha256"]

    def tool_calls(self):
        path = self.root / "calls.jsonl"
        br = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return br + self.herdr.calls

    def sends(self):
        return [params["target"] for params in self.herdr.prompts()]

    def test_preview_binds_every_payload_and_does_not_probe_or_write(self):
        code, report = self.invoke()
        self.assertEqual((code, report["status"]), (0, "preview"))
        self.assertEqual(report["delivery_count"], 3)
        self.assertEqual(self.tool_calls(), [])
        self.assertEqual(list(self.root.glob("receipt*")), [])
        self.assertIn("--send", shlex.split(report["send_command"]))
        self.assertFalse(report["agent_execution_verified"])
        for item in report["deliveries"]:
            self.assertIn(str(self.root), item["receipt"])
            self.assertEqual(item["request"]["repo"], str(self.repo))

    def test_three_agents_receive_distinct_packets(self):
        code, report = self.invoke(self.preview_hash(), send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertEqual(report["summary"]["submitted"], 3)
        self.assertEqual(report["summary"]["not_attempted"], 0)
        self.assertEqual(self.sends(), [pane(1), pane(2), pane(3)])
        self.assertEqual([p["text"] for p in self.herdr.prompts()], [self.prompts[pane(i)] for i in (1, 2, 3)])
        self.assertEqual(len(list(self.root.glob("receipt-?.json"))), 3)
        self.assertEqual(len(list(self.root.glob("receipt-?.json.result.json"))), 3)

    def test_retry_reads_all_results_without_resubmitting(self):
        review = self.preview_hash()
        self.invoke(review, send=True)
        code, report = self.invoke(review, send=True)
        self.assertEqual((code, report["status"]), (0, "submitted"), report)
        self.assertEqual(report["summary"]["reconciled"], 3)
        self.assertFalse(report["sends_prompt"])
        self.assertEqual(len(self.sends()), 3)

    def test_lost_middle_answer_stops_and_is_never_resent(self):
        review = self.preview_hash()
        self.herdr.pane_modes[pane(2)] = "disconnect"
        code, report = self.invoke(review, send=True)
        self.assertEqual((code, report["status"]), (1, "stopped"), report)
        self.assertEqual([item["status"] for item in report["deliveries"]],
                         ["submitted", "unconfirmed", "not_attempted"])
        self.assertFalse((self.root / "receipt-3.json").exists())
        # herdr keeps no record, so a rerun cannot learn that the middle prompt
        # arrived: it stays unconfirmed, and the later agent is never reached.
        self.herdr.pane_modes.clear()
        for _ in range(2):
            code, report = self.invoke(review, send=True)
            self.assertEqual((code, report["status"]), (1, "stopped"), report)
            self.assertEqual([item["status"] for item in report["deliveries"]],
                             ["submitted", "unconfirmed", "not_attempted"])
        self.assertEqual(self.sends(), [pane(1), pane(2)])

    def test_refused_middle_agent_stops_the_batch(self):
        review = self.preview_hash()
        self.herdr.pane_modes[pane(2)] = "blocked"
        code, report = self.invoke(review, send=True)
        self.assertEqual((code, report["status"]), (1, "stopped"), report)
        self.assertEqual([item["status"] for item in report["deliveries"]],
                         ["submitted", "refused", "not_attempted"])
        self.assertEqual(report["summary"]["refused"], 1)
        self.assertFalse(report["deliveries"][1]["sends_prompt"])

    def test_invalid_later_packet_blocks_entire_batch_before_tools(self):
        path = self.root / "packet-3.json"
        packet = json.loads(path.read_text())
        packet["output"]["truncated"] = True
        path.write_text(json.dumps(packet))
        code, _ = self.invoke(send=True, review_hash="0" * 64)
        self.assertEqual(code, 2)
        self.assertEqual(self.tool_calls(), [])

    def test_changed_later_packet_requires_new_review(self):
        review = self.preview_hash()
        path = self.root / "packet-3.json"
        packet = json.loads(path.read_text())
        packet["packet_markdown"] += "New instruction.\n"
        path.write_text(json.dumps(packet))
        code, report = self.invoke(review, send=True)
        self.assertEqual(code, 2)
        self.assertIn("changed since review", report["error"])
        self.assertEqual(self.tool_calls(), [])

    def test_changed_batch_requires_new_review(self):
        review = self.preview_hash()
        self.spec["deliveries"][2]["operation_id"] = "different-operation"
        self.save()
        code, _ = self.invoke(review, send=True)
        self.assertEqual(code, 2)
        self.assertEqual(self.tool_calls(), [])

    def test_send_requires_combined_review_hash(self):
        code, report = self.invoke(send=True)
        self.assertEqual(code, 2)
        self.assertIn("Preview the batch", report["error"])
        self.assertEqual(self.tool_calls(), [])

    def test_duplicate_targets_operations_and_receipts_are_rejected(self):
        original = copy.deepcopy(self.spec)
        for key in ("pane_id", "operation_id", "receipt"):
            with self.subTest(key=key):
                self.spec = copy.deepcopy(original)
                self.spec["deliveries"][1][key] = self.spec["deliveries"][0][key]
                self.save()
                code, _ = self.invoke()
                self.assertEqual(code, 2)
                self.assertEqual(self.tool_calls(), [])

    def test_same_bead_cannot_be_dispatched_twice(self):
        path = self.root / "packet-2.json"
        packet = json.loads(path.read_text())
        packet["bead"]["id"] = "bd-1"
        path.write_text(json.dumps(packet))
        code, report = self.invoke()
        self.assertEqual(code, 2)
        self.assertIn("same repository Bead", report["error"])

    def test_receipt_cannot_alias_a_later_packet_or_batch(self):
        original = copy.deepcopy(self.spec)
        for target in ("packet-3.json", "batch.json"):
            with self.subTest(target=target):
                self.spec = copy.deepcopy(original)
                self.spec["deliveries"][0]["receipt"] = target
                self.save()
                code, _ = self.invoke()
                self.assertEqual(code, 2)
                self.assertEqual(self.tool_calls(), [])

    def test_orphan_later_result_file_prevents_any_new_sends(self):
        path = self.root / "receipt-3.json.result.json"
        path.write_text("not ours")
        path.chmod(0o600)
        code, report = self.invoke()
        self.assertEqual(code, 2, report)
        self.assertEqual(path.read_text(), "not ours")
        self.assertEqual(self.tool_calls(), [])

    def test_receipt_cannot_be_another_deliverys_result_file(self):
        self.spec["deliveries"][1]["receipt"] = "receipt-1.json.result.json"
        self.save()
        code, _ = self.invoke()
        self.assertEqual(code, 2)
        self.assertEqual(self.tool_calls(), [])

    def test_conflicting_later_receipt_prevents_any_new_sends(self):
        path = self.root / "receipt-3.json"
        path.write_text('{"schema":"unrelated"}')
        path.chmod(0o600)
        code, _ = self.invoke(send=True, review_hash="0" * 64)
        self.assertEqual(code, 2)
        self.assertEqual(path.read_text(), '{"schema":"unrelated"}')
        self.assertEqual(self.tool_calls(), [])

    def test_live_middle_preflight_failure_preserves_first_submission(self):
        review = self.preview_hash()
        (self.root / "not-ready").write_text("")
        code, report = self.invoke(review, send=True)
        self.assertEqual((code, report["status"]), (2, "stopped"), report)
        self.assertEqual([item["status"] for item in report["deliveries"]],
                         ["submitted", "error", "not_attempted"])
        self.assertEqual(len(self.sends()), 1)
        (self.root / "not-ready").unlink()
        code, report = self.invoke(review, send=True)
        self.assertEqual(code, 0, report)
        self.assertEqual(report["summary"]["reconciled"], 1)
        self.assertEqual(len(self.sends()), 3)

    def test_v1_manifest_and_tmux_panes_are_refused(self):
        original = copy.deepcopy(self.spec)
        legacy = dict(original, schema="acfs.packet-delivery-batch.v1")
        tmux = copy.deepcopy(original)
        tmux["deliveries"][0]["pane_id"] = "%41"
        for spec in (legacy, tmux):
            with self.subTest(spec=str(spec)[:60]):
                self.batch.write_text(json.dumps(spec))
                code, _ = self.invoke()
                self.assertEqual(code, 2)
        self.assertEqual(self.tool_calls(), [])

    def test_invalid_manifest_shapes_and_entry_types_are_rejected(self):
        original = copy.deepcopy(self.spec)
        bad_specs = [[], {}, {"schema": "other", "deliveries": []},
                     dict(original, deliveries=[]), dict(original, extra=True),
                     dict(original, deliveries=[None]), dict(original, deliveries=[{}]),
                     dict(original, deliveries=original["deliveries"] * 11)]
        for key in ("pane_id", "packet", "agent_type"):
            spec = copy.deepcopy(original)
            spec["deliveries"][1][key] = True
            bad_specs.append(spec)
        for spec in bad_specs:
            with self.subTest(spec=str(spec)[:90]):
                self.batch.write_text(json.dumps(spec))
                code, _ = self.invoke()
                self.assertEqual(code, 2)
        self.assertEqual(self.tool_calls(), [])

    def test_duplicate_manifest_keys_are_rejected(self):
        self.batch.write_text('{"schema":"ignored",' + json.dumps(self.spec)[1:])
        code, _ = self.invoke()
        self.assertEqual(code, 2)
        self.assertEqual(self.tool_calls(), [])


if __name__ == "__main__":
    unittest.main()
