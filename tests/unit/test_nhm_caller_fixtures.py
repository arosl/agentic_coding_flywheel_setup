"""tests/fixtures/nhm: nhm's robot output passes what upstream's swarm
scripts assert, and a fixture changed in a way the callers must refuse
fails (acfs-9hkh.56).

Usage: python3 -m unittest tests/unit/test_nhm_caller_fixtures.py
"""

import copy
import importlib.util
import json
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "nhm"
_spec = importlib.util.spec_from_file_location("upstream_checks", FIXTURES / "upstream_checks.py")
checks = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checks)


def load(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class SpawnFixtures(unittest.TestCase):
    def setUp(self):
        self.request = load("request.json")

    def test_spawn_passes(self):
        agents = checks.spawn_response(load("robot_spawn.json"), self.request, dry_run=False)
        self.assertEqual([a["pane"] for a in agents], ["1.1", "1.2"])

    def test_dry_run_passes(self):
        agents = checks.spawn_response(load("robot_spawn_dry_run.json"), self.request, dry_run=True)
        self.assertEqual(len(agents), 2)

    def test_refused_changes(self):
        def changed(edit, dry_run=False):
            out = load("robot_spawn_dry_run.json" if dry_run else "robot_spawn.json")
            edit(out)
            with self.assertRaises(checks.CheckError):
                checks.spawn_response(out, self.request, dry_run)
        # A herdr pane id is not ntm's N.M slot.
        changed(lambda o: o["agents"][0].update(pane="w1:p2"))
        changed(lambda o: o["agents"][1].update(ready=False))
        changed(lambda o: o["agents"][1].update(pane="1.1"))
        changed(lambda o: o["agents"][1].update(type="claude"))
        changed(lambda o: o["admission"].update(decision="refuse"))
        changed(lambda o: o.update(working_dir="/srv/projects/other"))
        changed(lambda o: o.update(assignments=[{"pane": "1.1"}]))
        changed(lambda o: o.update(dry_run=True))
        changed(lambda o: o.pop("would_create"), dry_run=True)


class SendFixtures(unittest.TestCase):
    def setUp(self):
        self.request = load("request.json")

    def test_preview_names_one_slot(self):
        self.assertEqual(checks.send_preview(load("robot_send_dry_run.json"), self.request), self.request["pane"])

    def test_preview_refuses_injection_and_blocking(self):
        for edit in (lambda o: o["memory_injection"].update(enabled=True),
                     lambda o: o.update(cm_injection={"enabled": True}),
                     lambda o: o.update(blocked=True),
                     lambda o: o.update(would_send_to=["1.1", "1.2"])):
            out = load("robot_send_dry_run.json")
            edit(out)
            with self.assertRaises(checks.CheckError):
                checks.send_preview(out, self.request)

    def test_send_and_receipt_are_submitted(self):
        target = self.request["pane"]
        self.assertEqual(checks.outcome(load("robot_send.json"), self.request, target), "submitted")
        self.assertEqual(checks.outcome(load("robot_send_receipt.json"), self.request, target, receipt_query=True),
                         "submitted")

    def test_possibly_submitted_is_unconfirmed(self):
        out = load("robot_send_receipt_unconfirmed.json")
        self.assertEqual(checks.outcome(out, self.request, self.request["pane"], receipt_query=True), "unconfirmed")

    def test_receipt_of_another_packet_refuses(self):
        for field, value in (("payload_sha256", "0" * 64), ("payload_bytes", 22), ("operation_id", "other")):
            out = load("robot_send_receipt.json")
            out["operation"][field] = value
            with self.assertRaises(checks.CheckError):
                checks.outcome(out, self.request, self.request["pane"], receipt_query=True)

    def test_other_admission_states_are_unconfirmed(self):
        base = load("robot_send.json")
        for state in ("possibly_submitted", "refused", "failed"):
            out = copy.deepcopy(base)
            out["operation"]["admissions"][0]["state"] = state
            self.assertEqual(checks.outcome(out, self.request, self.request["pane"]), "unconfirmed")


class StatusFixture(unittest.TestCase):
    def test_sessions_are_headers(self):
        sessions = checks.status_sessions(load("robot_status.json"))
        self.assertEqual([s["name"] for s in sessions], ["demo"])

    def test_a_session_map_refuses(self):
        out = load("robot_status.json")
        out["sessions"] = {"demo": out["sessions"][0]}
        with self.assertRaises(checks.CheckError):
            checks.status_sessions(out)


class Fixtures(unittest.TestCase):
    def test_every_fixture_is_strict_json_without_host_paths(self):
        # Upstream's parse refuses a duplicate field; so do the fixtures.
        def unique(pairs):
            keys = [k for k, _ in pairs]
            self.assertEqual(len(keys), len(set(keys)), f"duplicate field in {keys}")
            return dict(pairs)
        for path in sorted(FIXTURES.glob("*.json")):
            text = path.read_text(encoding="utf-8")
            json.loads(text, object_pairs_hook=unique)
            self.assertNotIn("/home/", text, path.name)


if __name__ == "__main__":
    unittest.main()
