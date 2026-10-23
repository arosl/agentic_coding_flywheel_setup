#!/usr/bin/env python3
"""Bounded, read-only readiness (--wait) through the CLI and deterministic
clocks: upstream's a15ff24a, on herdr's observations (acfs-g85y). One
observation is one round of herdr reads; it starts with the workspace list."""
import importlib.util
import json
import shlex
import time
import unittest
from unittest import mock

import test_swarm_launch_recovery as fixtures

SPEC = importlib.util.spec_from_file_location("recovery_wait_subject", fixtures.SCRIPT)
recovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recovery)

# agents[0] is OnyxField (codex, w9:p7), agents[1] AmberFox (claude, w9:p3).
# A starting agent's pane still runs its shell.
TRANSIENT_FIXTURE = r'''
if mode == "warming" and rounds == 1 or mode == "flapping" and rounds == 2:
    state["agents"][0]["foreground"] = "bash"
if mode == "missing-first" and rounds == 1:
    state["agents"] = state["agents"][1:]
if mode == "empty-first" and rounds == 1:
    state["agents"] = []
if mode.startswith("warming-"):
    state["agents"][0]["foreground"] = "bash"
if mode == "warming-malformed":
    state["agents"][1]["terminal_id"] = "not a terminal"
if mode == "warming-other-process":
    state["agents"][1]["foreground"] = "python3"
if mode == "warming-duplicate":
    state["agents"][1]["terminal_id"] = state["agents"][0]["terminal_id"]
if mode == "warming-wrong-type":
    state["agents"][1]["agent"] = "codex"
'''


class WaitingCliTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.RecoveryTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        anchor = "def ok(result):"
        assert anchor in fixtures.FIXTURE
        (self.fixture.bin / "herdr").write_text(fixtures.FIXTURE.replace(anchor, TRANSIENT_FIXTURE + anchor))
        self.targets = ["--target", "1:w9:p7", "--target", "2:w9:p3", "--target", "3:w9:p2"]

    def observations(self):
        return sum(1 for c in self.fixture.calls() if c[:2] == ["workspace", "list"])

    def test_waiting_preview_is_read_only_then_copyable_command_adopts(self):
        f = self.fixture
        before = f.intent.read_bytes()
        report = f.invoke("--wait", "6", mode="warming")
        self.assertEqual(report["status"], "preview")
        self.assertEqual(report["readiness_observations"], 3)
        self.assertEqual(self.observations(), 3)
        self.assertFalse(f.result.exists())
        self.assertEqual(list(f.receipts.iterdir()), [f.intent])
        self.assertEqual(f.intent.read_bytes(), before)
        command = shlex.split(report["adopt_command"])
        self.assertNotIn("--wait", command)
        self.assertEqual(f.invoke(*command[4:])["status"], "ready")

    def test_explicit_bindings_wait_for_missing_agent_with_helper_present(self):
        f = self.fixture
        helper = f.agent(20, "opencode", "HelperPane")
        helper["cwd"] = str(f.root)
        f.agents.append(helper)
        f.save_state()
        report = f.invoke(*self.targets, "--wait", "6", mode="missing-first")
        self.assertEqual(report["readiness_observations"], 3)
        self.assertEqual([t["pane_id"] for t in report["targets"]], ["w9:p7", "w9:p3", "w9:p2"])
        self.assertFalse(f.result.exists())

    def test_empty_initial_observation_can_become_ready(self):
        report = self.fixture.invoke("--wait", "6", mode="empty-first")
        self.assertEqual(report["readiness_observations"], 3)

    def test_intermittent_native_observation_does_not_count_as_stable(self):
        report = self.fixture.invoke("--wait", "6", mode="flapping")
        self.assertEqual(report["readiness_observations"], 4)

    def test_wait_does_not_change_approval_for_same_observed_identities(self):
        ordinary = self.fixture.invoke()
        waited = self.fixture.invoke("--wait", "6")
        self.assertEqual(ordinary["readiness_observations"], 1)
        self.assertEqual(waited["readiness_observations"], 2)
        self.assertEqual(ordinary["review_sha256"], waited["review_sha256"])

    def test_default_and_zero_wait_remain_single_observation(self):
        for args in ([], ["--wait", "0"]):
            with self.subTest(args=args):
                report = self.fixture.invoke(*args, mode="warming", code=2)
                self.assertIn("still starting", report["error"])
                self.assertEqual(self.observations(), 1)
                self.assertFalse(self.fixture.result.exists())

    def test_wait_is_never_allowed_during_adoption(self):
        report = self.fixture.invoke("--adopt", "--wait", "6", "--expect-sha256", "0" * 64, code=2)
        self.assertIn("preview-only", report["error"])
        self.assertEqual(self.fixture.calls(), [])
        self.assertFalse(self.fixture.result.exists())

    def test_incomplete_startup_does_not_hide_fatal_observations(self):
        for mode in ("warming-malformed", "warming-other-process", "warming-duplicate", "warming-wrong-type"):
            with self.subTest(mode=mode):
                self.fixture.invoke(*self.targets, "--wait", "6", mode=mode, code=2)
                self.assertEqual(self.observations(), 1)
                self.assertFalse(self.fixture.result.exists())

    def test_swapped_bindings_are_refused_while_another_agent_starts(self):
        # The right mix of types, the wrong type for slots 1 and 2: never a retry.
        swapped = ["--target", "1:w9:p3", "--target", "2:w9:p7", "--target", "3:w9:p2"]
        report = self.fixture.invoke(*swapped, "--wait", "6", mode="warming", code=2)
        self.assertIn("saved slot's agent type", report["error"])
        self.assertEqual(self.observations(), 1)

    def test_failed_observation_is_not_retried_or_leaked(self):
        report = self.fixture.invoke("--wait", "6", mode="error", code=2)
        self.assertEqual(self.observations(), 1)
        self.assertNotIn("DO_NOT_LEAK", json.dumps(report))

    def test_waiting_preview_rechecks_retained_intent_and_result(self):
        for mode in ("replace-intent", "rewrite-intent", "result-race"):
            with self.subTest(mode=mode):
                self.fixture.invoke("--wait", "6", mode=mode, code=2)
                self.assertEqual(self.observations(), 2)
        self.assertEqual(self.fixture.result.read_text(), "retained competitor result")

    def test_overall_wait_caps_a_hung_observation(self):
        started = time.monotonic()
        self.fixture.invoke("--wait", "1", "--timeout", "30", mode="timeout", code=2)
        self.assertLess(time.monotonic() - started, 6)
        self.assertEqual(self.observations(), 1)
        self.assertFalse(self.fixture.result.exists())


class PollBudgetTests(unittest.TestCase):
    def setUp(self):
        self.now = 0.0
        self.sleeps = []
        self.request = {"identity": "unused-by-probe-fixture"}
        self.chosen = {1: "w9:p7"}
        self.targets = [{"pane_id": "w9:p7", "shell_pid": 1007, "launched_state": "ready"}]
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(recovery.time, "monotonic", side_effect=lambda: self.now).start()
        mock.patch.object(recovery.time, "sleep", side_effect=self.sleep).start()

    def sleep(self, delay):
        self.sleeps.append(delay)
        self.now += delay

    def test_sleep_and_all_observations_share_one_deadline(self):
        timeouts = []
        def probe(request, timeout, chosen):
            self.assertEqual(request, self.request)
            self.assertEqual(chosen, self.chosen)
            timeouts.append(timeout)
            self.now += 0.1
            raise recovery.PaneNotReady("still starting")
        with mock.patch.object(recovery, "observe", side_effect=probe):
            with self.assertRaisesRegex(recovery.RecoveryError, "deadline expired"):
                recovery.preview_observation(self.request, 30, self.chosen, 1)
        self.assertEqual(len(timeouts), 3)
        self.assertAlmostEqual(timeouts[0], 1.0)
        self.assertAlmostEqual(timeouts[1], 0.65)
        self.assertAlmostEqual(timeouts[2], 0.3)
        self.assertAlmostEqual(self.now, 1.0)

    def test_late_success_cannot_escape_overall_deadline(self):
        def probe(*args):
            self.now += 0.4
            return self.targets
        with mock.patch.object(recovery, "observe", side_effect=probe) as observe:
            with self.assertRaisesRegex(recovery.RecoveryError, "deadline expired"):
                recovery.preview_observation(self.request, 30, None, 1)
        self.assertEqual(observe.call_count, 2)

    def test_only_consecutive_matching_identities_stabilize(self):
        other = [{"pane_id": "w9:p7", "shell_pid": 9999, "launched_state": "ready"}]
        states = [self.targets, other, recovery.PaneNotReady("starting"), other, other]
        with mock.patch.object(recovery, "observe", side_effect=states) as observe:
            targets, count = recovery.preview_observation(self.request, 1, None, 6)
        self.assertEqual((targets, count), (other, 5))
        self.assertEqual(observe.call_count, 5)
        self.assertTrue(all(call.args[1] <= 1 for call in observe.call_args_list))

    def test_launch_state_change_still_counts_as_stable(self):
        # As in approval, a dialog opening or closing is not an identity change.
        blocked = [{**self.targets[0], "launched_state": "blocked"}]
        with mock.patch.object(recovery, "observe", side_effect=[self.targets, blocked]):
            targets, count = recovery.preview_observation(self.request, 1, None, 6)
        self.assertEqual((targets, count), (blocked, 2))

    def test_nonreadiness_errors_are_immediate(self):
        for error in (recovery.RecoveryError("malformed"), OSError("unavailable"), UnicodeError("invalid")):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(recovery, "observe", side_effect=error) as observe:
                    with self.assertRaises(type(error)):
                        recovery.preview_observation(self.request, 1, None, 6)
                self.assertEqual(observe.call_count, 1)
        self.assertEqual(self.sleeps, [])

    def test_zero_wait_preserves_single_observation(self):
        with mock.patch.object(recovery, "observe", return_value=self.targets) as observe:
            self.assertEqual(recovery.preview_observation(self.request, 10, self.chosen, 0), (self.targets, 1))
        observe.assert_called_once_with(self.request, 10, self.chosen)
        self.assertEqual(self.sleeps, [])


if __name__ == "__main__":
    unittest.main()
