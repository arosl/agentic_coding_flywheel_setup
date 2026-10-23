#!/usr/bin/env python3
"""Explicit recovery bindings (--target SLOT:PANE) through the real CLI, with
no live agents: upstream's f8d863df, on herdr's pane ids (acfs-g85y)."""
import json
import shlex
import unittest

import test_swarm_launch_recovery as fixtures


class ExplicitTargetTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.RecoveryTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        # Layout order would give slot 1 w9:p2 (tab t2); these bindings differ.
        self.targets = ["--target", "1:w9:p7", "--target", "2:w9:p3", "--target", "3:w9:p2"]

    def preview(self, targets=None):
        return self.fixture.invoke(*(self.targets if targets is None else targets))

    def adopt(self, preview, *, targets=None, **kwargs):
        return self.fixture.invoke(*(self.targets if targets is None else targets),
            "--adopt", "--expect-sha256", preview["review_sha256"], **kwargs)

    def helper(self, kind="opencode"):
        # Another agent in the launch workspace, started outside the repository.
        agent = self.fixture.agent(20, kind, "HelperPane")
        agent["cwd"] = str(self.fixture.root)
        return agent

    def test_explicit_slots_override_same_provider_layout_order(self):
        f = self.fixture
        before = f.intent.read_bytes()
        report = self.preview()
        self.assertEqual(report["selection"], "explicit")
        self.assertEqual([(t["slot"], t["agent_name"], t["pane_id"]) for t in report["targets"]],
            [(1, "Reviewer", "w9:p7"), (2, "Builder", "w9:p3"), (3, "Tester", "w9:p2")])
        self.assertEqual(self.adopt(report)["status"], "ready")
        saved = json.loads(f.result.read_text())
        self.assertEqual(saved["request"], f.request)
        self.assertEqual(saved["targets"], report["targets"])
        self.assertEqual(saved["recovery"]["selection"], "explicit")
        self.assertFalse(saved["recovery"]["original_launch_verified"])
        self.assertEqual(f.intent.read_bytes(), before)
        self.assertEqual(f.result.stat().st_mode & 0o777, 0o600)

    def test_layout_selection_is_recorded(self):
        report = self.fixture.invoke()
        self.assertEqual(report["selection"], "layout")
        self.fixture.invoke("--adopt", "--expect-sha256", report["review_sha256"])
        self.assertEqual(json.loads(self.fixture.result.read_text())["recovery"]["selection"], "layout")

    def test_helper_agent_outside_repo_can_remain_unselected(self):
        f = self.fixture
        f.agents.append(self.helper())
        f.save_state()
        f.invoke(code=2)  # Layout mode stays strict: no implicit filtering.
        report = self.preview()
        self.assertEqual(len(report["targets"]), 3)
        self.assertEqual(self.adopt(report)["status"], "ready")

    def test_unselected_native_agent_is_not_adopted(self):
        f = self.fixture
        f.agents.append(self.helper("codex"))
        f.save_state()
        report = self.preview()
        self.assertNotIn("w9:p20", [t["pane_id"] for t in report["targets"]])
        self.adopt(report)

    def test_bad_bindings_fail_before_observation(self):
        cases = [[""], ["1:w9:p7"], ["1:w9:p7", "2:w9:p3", "2:w9:p2"],
            ["1:w9:p7", "2:w9:p3", "3:w9:p7"], ["1:w9:p7", "2:w9:p3", "4:w9:p2"],
            ["0:w9:p7", "2:w9:p3", "3:w9:p2"], ["01:w9:p7", "2:w9:p3", "3:w9:p2"],
            ["1:%7", "2:w9:p3", "3:w9:p2"], ["1:w9:t7", "2:w9:p3", "3:w9:p2"],
            ["1:w9:pa", "2:w9:p3", "3:w9:p2"], ["1:w9:p7;true", "2:w9:p3", "3:w9:p2"],
            ["1:w9:p7", "2:w9:p3", "3:w9:p2", "4:w9:p9"]]
        for values in cases:
            with self.subTest(values=values):
                args = [part for value in values for part in ("--target", value)]
                self.fixture.invoke(*args, code=2)
                self.assertEqual(self.fixture.calls(), [])
                self.assertFalse(self.fixture.result.exists())

    def test_each_slot_requires_its_own_agent_type_not_just_the_right_mix(self):
        self.fixture.invoke("--target", "1:w9:p3", "--target", "2:w9:p7", "--target", "3:w9:p2", code=2)
        self.assertFalse(self.fixture.result.exists())

    def test_missing_selected_pane_is_not_replaced_by_another_agent(self):
        self.fixture.invoke("--target", "1:w9:p99", "--target", "2:w9:p3", "--target", "3:w9:p2", code=2)
        self.assertFalse(self.fixture.result.exists())

    def test_selected_wrong_process_kind_or_repo_is_refused(self):
        f = self.fixture
        for key, value in (("foreground", "python3"), ("foreground", "bash"), ("agent", "opencode"),
                           ("cwd", str(f.root))):
            with self.subTest(key=key, value=value):
                original = f.agents[0][key]
                f.agents[0][key] = value
                f.save_state()
                f.invoke(*self.targets, code=2)
                self.assertFalse(f.result.exists())
                f.agents[0][key] = original
        f.save_state()

    def test_ignored_rows_cannot_hide_a_duplicate_or_malformed_identity(self):
        f = self.fixture
        for key, value in (("pane_id", "w9:p7"), ("terminal_id", "term_7"), ("terminal_id", "not a terminal")):
            with self.subTest(key=key, value=value):
                helper = self.helper()
                helper[key] = value
                f.agents.append(helper)
                f.save_state()
                f.invoke(*self.targets, code=2)
                self.assertFalse(f.result.exists())
                f.agents.pop()
        f.save_state()

    def test_mapping_changes_invalidate_review(self):
        report = self.preview()
        other = ["--target", "1:w9:p2", "--target", "2:w9:p3", "--target", "3:w9:p7"]
        self.assertNotEqual(report["review_sha256"], self.preview(other)["review_sha256"])
        self.adopt(report, targets=other, code=2)
        self.assertFalse(self.fixture.result.exists())

    def test_approval_cannot_switch_between_explicit_and_layout_selection(self):
        f = self.fixture
        normal = f.invoke()
        same = ["--target", "1:w9:p2", "--target", "2:w9:p3", "--target", "3:w9:p7"]
        explicit = self.preview(same)
        self.assertEqual(normal["targets"], explicit["targets"])
        self.assertNotEqual(normal["review_sha256"], explicit["review_sha256"])
        self.adopt(normal, targets=same, code=2)
        f.invoke("--adopt", "--expect-sha256", explicit["review_sha256"], code=2)
        self.assertFalse(f.result.exists())

    def test_argument_order_is_canonical_and_copyable_command_retains_bindings(self):
        report = self.preview()
        reordered = self.targets[4:6] + self.targets[0:2] + self.targets[2:4]
        self.assertEqual(report["review_sha256"], self.preview(reordered)["review_sha256"])
        command = shlex.split(report["adopt_command"])
        self.assertEqual(command[:4], ["acfs", "swarm", "launch", "--recover"])
        self.assertEqual(command.count("--target"), 3)
        self.assertEqual(self.fixture.invoke(*command[4:])["status"], "ready")

    def test_explicit_approval_survives_agent_list_order(self):
        report = self.preview()
        f = self.fixture
        f.agents.reverse()
        f.save_state()
        self.assertEqual(report["review_sha256"], self.preview()["review_sha256"])
        self.adopt(report)

    def test_selected_process_drift_prevents_publication(self):
        self.adopt(self.preview(), mode="drift", code=2)
        self.assertFalse(self.fixture.result.exists())

    def test_unselected_helper_process_drift_does_not_rebind_slots(self):
        f = self.fixture
        f.agents.insert(0, self.helper())
        f.save_state()
        self.assertEqual(self.adopt(self.preview(), mode="drift")["status"], "ready")

    def test_explicit_targets_in_an_nhm_shared_tab_ignore_an_unbound_helper(self):
        # Only the selected panes need nhm's bindings (acfs-aahj).
        f = self.fixture
        f.nhm_launch(["5.3", "5.2", "5.1"])
        f.agents.append(self.helper())
        f.save_state()
        report = self.preview()
        self.assertEqual([(t["pane_id"], t["agent_mail_name"], t["tab_id"]) for t in report["targets"]],
                         [("w9:p7", "OnyxField", "w9:t5"), ("w9:p3", "AmberFox", "w9:t5"), ("w9:p2", "BlueLake", "w9:t5")])
        self.assertNotIn(["resolve", "w9:p20"], [c[:2] for c in f.calls()])
        self.adopt(report)


if __name__ == "__main__":
    unittest.main()
