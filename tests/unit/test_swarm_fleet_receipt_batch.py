#!/usr/bin/env python3
"""Two-phase receipt verification: real private readers, processes and journals.

Upstream's 61c803dc test, on the fork's herdr evidence: the batch reads every
saved native intent in one remote operation, and each intent that holds then
reads its delivery's own result file (read-result), where upstream queried
NTM's operation (query-receipt). herdr keeps no record of a prompt, so that
result file is the only submission evidence (acfs-qzc).
"""
import base64
import copy
from contextlib import redirect_stdout
import fcntl
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_swarm_fleet_dispatch as fixtures

dispatch, fleet = fixtures.dispatch, fixtures.fleet


def native(delivery):
    return {"schema": dispatch.PACKET_SCHEMA, "request": copy.deepcopy(delivery["request"]),
            "target": "recorded:" + delivery["request"]["operation_id"], "agent_session": None}


def result(delivery):
    target = native(delivery)["target"]
    return {"schema": dispatch.PACKET_SCHEMA, "request": copy.deepcopy(delivery["request"]), "target": target,
            "status": "submitted", "evidence": {"pane_id": delivery["request"]["pane_id"], "terminal_id": target}}


def deliveries(count=2):
    return [{"slot": i, "receipt": f"/home/ubuntu/receipts/op-{i}.json", "request": {
        "repo": "/data/projects/app", "workspace": "w1", "pane_id": f"w1:p{i}",
        "agent_type": "claude", "operation_id": f"op-{i}", "bead_id": f"bd-{i}",
        "packet_sha256": "a" * 64, "payload_sha256": "b" * 64, "payload_bytes": 120}}
        for i in range(1, count + 1)]


class ProtocolPeer:
    def __init__(self):
        self.calls, self.probes = [], []
        self.change_intent = self.change_result = self.change_batch = None

    def __call__(self, entry, mode):
        self.calls.append(mode)
        if mode == "read-receipt":
            item = entry["delivery"]
            value = native(item)
            if self.change_intent:
                self.change_intent(value)
            self.probes.append((item["request"]["operation_id"], "read"))
            return 0, fleet.encoded(value)
        if mode == "read-result":
            item = entry["delivery"]
            value = result(item)
            if self.change_result:
                self.change_result(value)
            self.probes.append((item["request"]["operation_id"], "result"))
            return 0, fleet.encoded(value)
        assert mode == "batch-read-receipts", mode
        request = entry["receipt_batch"]
        by_id = {d["request"]["operation_id"]: d for d in entry["deliveries"]}
        rows = []
        for requested in request["items"]:
            item = by_id[requested["operation_id"]]
            value = native(item)
            if self.change_intent:
                self.change_intent(value)
            self.probes.append((requested["operation_id"], "read"))
            rows.append({"operation_id": requested["operation_id"], "status": "captured",
                         "stdout_base64": base64.b64encode(fleet.encoded(value)).decode()})
        value = {"schema": dispatch.BATCH_RECEIPT_SCHEMA,
                 "request_sha256": fleet.digest(fleet.encoded(request)), "rows": rows}
        if self.change_batch:
            self.change_batch(value)
        return 0, fleet.encoded(value)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.entry = {"deliveries": deliveries()}
        self.peer = ProtocolPeer()

    def test_thirty_two_deliveries_cut_receipt_read_connections_in_half(self):
        self.entry["deliveries"] = deliveries(32)
        individual = ProtocolPeer()
        for item in self.entry["deliveries"]:
            dispatch.query_submission(self.entry, item, individual)
        outcome = dispatch.query_submissions_batched_reads(self.entry, self.peer)
        self.assertEqual(outcome, [None] * 32)
        self.assertEqual(len(individual.calls), 64)
        self.assertEqual(self.peer.calls[0], "batch-read-receipts")
        self.assertEqual(self.peer.calls[1:], ["read-result"] * 32)
        self.assertEqual(len(self.peer.calls), 33)

    def test_wrong_native_intent_never_enters_result_read(self):
        def wrong(value):
            if value["request"]["operation_id"] == "op-1":
                value["request"]["repo"] = "/wrong"
        self.peer.change_intent = wrong
        self.assertEqual(dispatch.query_submissions_batched_reads(self.entry, self.peer),
                         ["native_receipt_mismatch", None])
        self.assertNotIn(("op-1", "result"), self.peer.probes)
        self.assertIn(("op-2", "result"), self.peer.probes)

    def test_no_valid_intents_means_no_result_reads(self):
        self.peer.change_intent = lambda v: v.update(schema="wrong")
        self.assertEqual(dispatch.query_submissions_batched_reads(self.entry, self.peer),
                         ["native_receipt_mismatch"] * 2)
        self.assertEqual(self.peer.calls, ["batch-read-receipts"])

    def test_existing_result_identity_checks_remain_required(self):
        changes = [(lambda v: v.update(status="refused"), "delivery_refused"),
                   (lambda v: v.update(status="pending"), "delivery_result_mismatch"),
                   (lambda v: v.update(schema="acfs.packet-delivery.v1"), "delivery_result_mismatch"),
                   (lambda v: v.update(target="other"), "delivery_result_mismatch"),
                   (lambda v: v["request"].update(payload_sha256="0" * 64), "delivery_result_mismatch"),
                   (lambda v: v.update(evidence=[]), "delivery_result_mismatch"),
                   (lambda v: v.update(extra=True), "delivery_result_mismatch")]
        for change, code in changes:
            with self.subTest(code=code, change=change):
                self.peer = ProtocolPeer()
                self.peer.change_result = change
                self.assertEqual(dispatch.query_submissions_batched_reads(self.entry, self.peer), [code] * 2)

    def test_batched_and_single_reads_give_the_same_verdicts(self):
        for change in (None, lambda v: v.update(status="refused"), lambda v: v.update(target="other")):
            with self.subTest(change=change):
                single, batched = ProtocolPeer(), ProtocolPeer()
                single.change_result = batched.change_result = change
                expected = []
                for item in self.entry["deliveries"]:
                    try:
                        dispatch.query_submission(self.entry, item, single)
                        expected.append(None)
                    except fleet.Refused as exc:
                        expected.append(str(exc))
                self.assertEqual(dispatch.query_submissions_batched_reads(self.entry, batched), expected)

    def test_reordered_or_mismatched_batch_envelope_is_refused(self):
        for change in (lambda v: v["rows"].reverse(),
                       lambda v: v.update(request_sha256="0" * 64),
                       lambda v: v.update(schema="wrong")):
            with self.subTest(change=change):
                self.peer = ProtocolPeer()
                self.peer.change_batch = change
                with self.assertRaises(fleet.Refused):
                    dispatch.query_submissions_batched_reads(self.entry, self.peer)
                self.assertEqual(self.peer.calls, ["batch-read-receipts"])

    def test_one_unavailable_receipt_does_not_hide_healthy_peer(self):
        def unavailable(value):
            value["rows"][0] = {"operation_id": "op-1", "status": "unavailable",
                                "code": "native_receipt_unavailable"}
        self.peer.change_batch = unavailable
        self.assertEqual(dispatch.query_submissions_batched_reads(self.entry, self.peer),
                         ["native_receipt_unavailable", None])
        self.assertEqual(self.peer.calls, ["batch-read-receipts", "read-result"])

    def test_malformed_item_is_local_and_not_read_further(self):
        def malformed(value):
            value["rows"][0]["stdout_base64"] = base64.b64encode(b"not-json").decode()
        self.peer.change_batch = malformed
        self.assertEqual(dispatch.query_submissions_batched_reads(self.entry, self.peer),
                         ["invalid_json", None])
        self.assertEqual(self.peer.calls, ["batch-read-receipts", "read-result"])

    def test_batch_reader_is_strictly_read_only(self):
        for word in ("subprocess", "robot-send", "herdr", "ntm", "--send"):
            self.assertNotIn(word, dispatch.READ_RECEIPT_BATCH)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(os.umask, os.umask(0o022))
        self.fx = fixtures.DispatchTests()
        self.fx.setUp()
        self.approval = self.fx.approved()
        def lost(_entry, mode, _value):
            if mode == "send":
                raise fleet.Refused("ssh_timeout")
        self.fx.peer.mutate = lost
        self.assertEqual(self.fx.run_dispatch("send", self.approval)[1], 1)
        self.fx.peer.mutate = None
        self.peer, self.calls = ProtocolPeer(), []

    def invoke(self, entry, mode):
        self.calls.append((entry["host"]["id"], mode))
        for directory in (self.fx.launch_dir, self.fx.state):
            with fleet.directory_fd(directory, private=True) as fd:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if mode.startswith("batch-") or mode == "read-result":
            return self.peer(entry, mode)
        return self.fx.peer(entry, mode)

    def execute(self, mode="reconcile", approval=None):
        return dispatch.execute(self.fx.launch_dir, self.fx.batches, self.fx.known, self.fx.identity,
                                self.fx.state, 360, mode, approval, self.invoke, batch_receipts=True)

    def snapshot(self):
        return {str(p): (p.read_bytes(), p.stat().st_mode, p.stat().st_mtime_ns)
                for parent in (self.fx.launch_dir, self.fx.state) for p in parent.iterdir()}

    def test_partial_reconcile_reads_attempted_host_without_writes_or_launch_checks(self):
        before = self.snapshot()
        report, code = self.execute()
        self.assertEqual((code, report["status"]), (1, "partial"))
        self.assertEqual(self.calls, [("worker-0", "batch-read-receipts"),
                                      ("worker-0", "read-result"), ("worker-0", "read-result")])
        self.assertEqual(before, self.snapshot())
        self.assertFalse(report["send_attempted"])

    def test_resume_recovers_lost_result_and_only_sends_untouched_host(self):
        before = self.fx.snapshot()
        report, code = self.execute("resume", self.approval)
        self.assertEqual((code, report["status"]), (0, "submitted"))
        self.assertEqual([c for c in self.calls if c[1] == "send"], [("worker-1", "send")])
        self.assertEqual(before, self.fx.snapshot())
        self.assertTrue((self.fx.state / "worker-0.result.json").is_file())
        self.assertTrue((self.fx.state / "worker-1.result.json").is_file())

    def test_unconfirmed_submission_blocks_every_pending_send_without_result_repair(self):
        self.peer.change_result = lambda v: v.update(status="refused")
        before = self.snapshot()
        report, code = self.execute("resume", self.approval)
        self.assertEqual((code, report["status"]), (1, "unconfirmed"))
        self.assertEqual({d.get("code") for d in report["hosts"][0]["deliveries"]}, {"delivery_refused"})
        self.assertEqual(before, self.snapshot())
        self.assertFalse(any(mode == "send" for _, mode in self.calls))

    def test_wrong_approval_is_rejected_before_any_batch_calls(self):
        with self.assertRaisesRegex(fleet.Refused, "approval_mismatch"):
            self.execute("resume", "0" * 64)
        self.assertEqual(self.calls, [])

    def test_journal_mutation_during_batch_stops_before_next_phase_or_resume(self):
        def change(_value):
            path = self.fx.state / "worker-0.attempt.json"
            path.write_bytes(path.read_bytes() + b" ")
        self.peer.change_batch = change
        with self.assertRaisesRegex(fleet.Refused, "state_changed"):
            self.execute("resume", self.approval)
        self.assertEqual(self.calls, [("worker-0", "batch-read-receipts")])

    def test_batch_flag_cannot_be_used_to_send_without_recovery(self):
        with self.assertRaisesRegex(fleet.Refused, "requires_reconciliation_or_resume"):
            self.execute("send", self.approval)
        self.assertEqual(self.calls, [])
        with patch.object(fleet, "read_input") as read, self.assertRaises(fleet.Refused):
            dispatch.main(["--launch-state", "/x", "--batches", "/x", "--known-hosts", "/x",
                           "--identity-file", "/x", "--state-dir", "/x", "--batch-receipts"])
        read.assert_not_called()

    def test_cli_reconcile_uses_batched_path(self):
        paths = []
        for name, raw in (("batches.json", fleet.encoded(self.fx.batches)), ("known", self.fx.known), ("key", self.fx.identity)):
            path = self.fx.root / name
            path.write_bytes(raw)
            path.chmod(0o600)
            paths.append(str(path))
        with patch.object(dispatch, "transport", return_value=self.invoke), redirect_stdout(io.StringIO()) as out:
            code = dispatch.main(["--launch-state", str(self.fx.launch_dir), "--batches", paths[0],
                "--known-hosts", paths[1], "--identity-file", paths[2], "--state-dir", str(self.fx.state),
                "--reconcile", "--batch-receipts"])
        self.assertEqual((code, json.loads(out.getvalue())["status"]), (1, "partial"))
        self.assertEqual(len(self.calls), 3)


class AuditTests(unittest.TestCase):
    """Upstream's 3df1e56f: --audit validates the local journals and never opens SSH."""
    def setUp(self):
        self.addCleanup(os.umask, os.umask(0o022))
        self.fx = fixtures.DispatchTests()
        self.fx.setUp()
        self.approval = self.fx.approved()

    def audit(self):
        def no_remote(_entry, _mode):
            raise AssertionError("audit contacted a host")
        return dispatch.execute(self.fx.launch_dir, self.fx.batches, self.fx.known, self.fx.identity,
                                self.fx.state, 360, "audit", None, no_remote)

    def test_partial_history_is_reported_without_writes(self):
        def lost(_entry, mode, _value):
            if mode == "send":
                raise fleet.Refused("ssh_timeout")
        self.fx.peer.mutate = lost
        self.assertEqual(self.fx.run_dispatch("send", self.approval)[1], 1)
        before = self.fx.snapshot()
        report, code = self.audit()
        self.assertEqual((code, report["status"], report["operation"]), (1, "partial", "audit"))
        self.assertEqual([h["status"] for h in report["hosts"]], ["attempted_unconfirmed", "not_attempted"])
        self.assertTrue(report["local_history_only"])
        self.assertFalse(report["remote_submission_verified"] or report["send_attempted"])
        self.assertEqual(before, self.fx.snapshot())

    def test_complete_history_is_recorded(self):
        self.assertEqual(self.fx.run_dispatch("send", self.approval)[1], 0)
        report, code = self.audit()
        self.assertEqual((code, report["status"]), (0, "recorded"))
        self.assertEqual({h["status"] for h in report["hosts"]}, {"recorded_submitted"})

    def test_cli_audit_never_builds_a_transport(self):
        self.assertEqual(self.fx.run_dispatch("send", self.approval)[1], 0)
        paths = []
        for name, raw in (("batches.json", fleet.encoded(self.fx.batches)), ("known", self.fx.known), ("key", self.fx.identity)):
            path = self.fx.root / name
            path.write_bytes(raw)
            path.chmod(0o600)
            paths.append(str(path))
        with patch.object(dispatch, "transport") as transport, redirect_stdout(io.StringIO()) as out:
            code = dispatch.main(["--launch-state", str(self.fx.launch_dir), "--batches", paths[0],
                "--known-hosts", paths[1], "--identity-file", paths[2], "--state-dir", str(self.fx.state),
                "--audit"])
        transport.assert_not_called()
        self.assertEqual((code, json.loads(out.getvalue())["status"]), (0, "recorded"))


@unittest.skipIf(os.geteuid() == 0, "the remote readers refuse root")
class RemoteReadBatchTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="acfs-receipt-batch-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.root.chmod(0o700)

    def private(self, name, body, mode=0o600):
        path = self.root / name
        path.write_bytes(body)
        path.chmod(mode)
        return path

    def run_batch(self, paths):
        request = {"nonce": "0" * 32, "items": [{"operation_id": f"op-{i}", "receipt": str(p)}
                                                for i, p in enumerate(paths)]}
        raw = fleet.encoded(request).decode()
        done = subprocess.run([sys.executable, "-I", "-c", dispatch.READ_RECEIPT_BATCH, raw],
                              capture_output=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stderr)
        value = json.loads(done.stdout)
        self.assertEqual(value["request_sha256"], fleet.digest(raw.encode()))
        return value["rows"]

    def test_batch_reader_refuses_what_the_single_reader_refuses(self):
        good = self.private("good.receipt", b'{"schema":"fixture"}')
        link = self.root / "link"; link.symlink_to(good)
        fifo = self.root / "fifo"; os.mkfifo(fifo, 0o600)
        public = self.private("public", b"private", 0o644)
        large = self.private("large", b"x" * 32769)
        hard = self.private("hard-a", b"{}"); os.link(hard, self.root / "hard-b")
        alias = self.root / "alias"; alias.symlink_to(self.root)
        paths = [good, link, fifo, public, large, hard, alias / "good.receipt"]
        rows = self.run_batch(paths)
        self.assertEqual(rows[0], {"operation_id": "op-0", "status": "captured",
                                   "stdout_base64": base64.b64encode(good.read_bytes()).decode()})
        for row in rows[1:]:
            with self.subTest(row=row["operation_id"]):
                self.assertEqual(row["status"], "unavailable")
                self.assertEqual(row["code"], "native_receipt_unavailable")
        for refused in (link, fifo, public, hard, alias / "good.receipt"):
            single = subprocess.run([sys.executable, "-I", "-c", dispatch.READ_RECEIPT, str(refused)],
                                    capture_output=True, timeout=5)
            self.assertEqual(single.returncode, 2, refused)

    def test_controller_sends_a_fixed_command_with_the_request_quoted(self):
        seen = {}
        def invoke(entry, mode):
            seen["mode"], seen["command"] = mode, dispatch.remote_command(entry, mode)
            request = entry["receipt_batch"]
            return 0, fleet.encoded({"schema": dispatch.BATCH_RECEIPT_SCHEMA,
                                     "request_sha256": fleet.digest(fleet.encoded(request)),
                                     "rows": [{"operation_id": i["operation_id"], "status": "unavailable",
                                               "code": "native_receipt_unavailable"} for i in request["items"]]})
        items = deliveries(2)
        items[0]["receipt"] = "/home/ubuntu/a 'quote'; $(touch BAD).receipt"
        frames = dispatch.receipt_read_batch({"deliveries": items}, items, invoke)
        self.assertEqual(frames, [(None, "native_receipt_unavailable")] * 2)
        self.assertEqual(seen["mode"], "batch-read-receipts")
        words = shlex.split(seen["command"])
        self.assertEqual(words[:5], ["exec", "/usr/bin/python3", "-I", "-c", dispatch.READ_RECEIPT_BATCH])
        self.assertEqual(json.loads(words[5])["items"][0]["receipt"], items[0]["receipt"])
        with self.assertRaises(fleet.Refused):
            dispatch.remote_command({"receipt_batch_command": "exec /bin/sh -c id"}, "batch-read-receipts")

    def test_batch_mode_keeps_the_result_read(self):
        items = deliveries(2)
        peer = ProtocolPeer()
        failures = dispatch.query_submissions_batched_reads({"deliveries": items}, peer)
        self.assertEqual(failures, [None, None])
        self.assertEqual(peer.calls[0], "batch-read-receipts")
        self.assertEqual(peer.calls[1:], ["read-result", "read-result"])


if __name__ == "__main__":
    unittest.main()
