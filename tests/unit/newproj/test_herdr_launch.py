#!/usr/bin/env python3
"""Exercise the real Bash success screen with fixture herdr/am/provider executables.

The screen's [n] and [w] options start agents through the real
scripts/lib/herdr_agents.sh (`acfs agents spawn`); only herdr, am, br and the
agent CLIs are fixtures. No agents, herdr server, network, or login flows are
started. Fixtures are retained in a named temporary directory to make failures
inspectable. Ported from upstream's test_ntm_launch.py.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SCREEN = REPO / "scripts/lib/newproj_screens/screen_success.sh"
BASH = shutil.which("bash")
JQ = shutil.which("jq")
# What the screen and herdr_agents.sh run besides the fixtures.
SYSTEM_TOOLS = ("bash", "mktemp", "cat", "rm", "awk", "sed", "grep", "dirname")

HERDR = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps({"argv": args, "cwd": os.getcwd()}) + "\n")
mode = os.environ.get("FAKE_HERDR_MODE", "ok")
def fail(code, message):
    print(json.dumps({"error": {"code": code, "message": message}}), file=sys.stderr)
    sys.exit(1)
def counter():
    path = Path(os.environ["CALLS"] + ".panes")
    n = int(path.read_text()) + 1 if path.exists() else 2
    path.write_text(str(n))
    return n
if not args:
    print("ATTACHED")
    sys.exit(0)
if args[:2] == ["status", "server"]:
    print("server:\n  status: " + ("not running" if mode == "server_down" else "running"))
    sys.exit(0)
if args[:2] == ["workspace", "create"]:
    if mode == "ws_exit": fail("server_error", "workspace create failed")
    workspace = {"workspace_id": "w9"}
    if mode == "ws_invalid": workspace = {}
    if mode == "ws_unsafe": workspace = {"workspace_id": "w9; touch injected"}
    print(json.dumps({"result": {"workspace": workspace, "tab": {"tab_id": "w9:t1"}, "root_pane": {"pane_id": "w9:p1"}}}))
    sys.exit(0)
if args[:2] == ["tab", "create"]:
    n = counter()
    print(json.dumps({"result": {"tab": {"tab_id": "w9:t%d" % n}, "root_pane": {"pane_id": "w9:p%d" % n}}}))
    sys.exit(0)
kinds = Path(os.environ["CALLS"] + ".kinds")
if args[:2] == ["agent", "start"]:
    known = json.loads(kinds.read_text()) if kinds.exists() else {}
    known[args[2]] = args[args.index("--kind") + 1]
    kinds.write_text(json.dumps(known))
    if mode in ("start_blocked", "trust_dialog"): fail("agent_not_ready", "agent is blocked")
    print(json.dumps({"result": {"agent": {"name": args[2]}}}))
    sys.exit(0)
if args[:2] == ["agent", "read"]:
    kind = json.loads(kinds.read_text()).get(args[2]) if kinds.exists() else None
    if mode == "trust_dialog" and kind == "claude":
        print(" Quick safety check\n Is this a project you created or one you trust?\n\n ❯ No, exit\n   Yes, I trust this folder")
    elif mode == "trust_dialog" and kind == "codex":
        print("  Trust this folder?\n\n› 1. Trust and continue\n  2. Quit")
    else:
        print("Trust this folder?")
    sys.exit(0)
if args[:2] in (["agent", "send-keys"], ["agent", "wait"]):
    print(json.dumps({"result": {}}))
    sys.exit(0)
if args[:2] == ["agent", "prompt"]:
    if mode == "prompt_fail": fail("agent_blocked", "agent is blocked")
    print(json.dumps({"result": {}}))
    sys.exit(0)
if args[:2] == ["workspace", "focus"]:
    print(json.dumps({"result": {}}))
    sys.exit(0)
sys.exit(95)
'''

AM = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["AM_CALLS"], "a") as log:
    log.write(json.dumps({"argv": args}) + "\n")
if os.environ.get("FAKE_AM_MODE") == "fail":
    sys.exit(1)
names = ["BlueLake", "GreenCastle", "RedStone", "AmberFox", "CopperHill", "IvoryPeak", "JadeRiver", "OnyxField"]
path = Path(os.environ["AM_CALLS"] + ".n")
n = int(path.read_text()) if path.exists() else 0
path.write_text(str(n + 1))
print(json.dumps({"name": names[n]}))
'''

BR = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["BR_CALLS"], "a") as log:
    log.write(json.dumps({"argv": args, "cwd": os.getcwd()}) + "\n")
if os.environ.get("SCOPE_LOG"):
    with open(os.environ["SCOPE_LOG"], "a") as log:
        log.write(json.dumps({key: os.environ.get(key) for key in ("BEADS_DIR", "BEADS_DB", "BD_DB", "BD_DATABASE", "BEADS_JSONL")}) + "\n")
queue = Path(os.environ["BR_QUEUE"])
mode = os.environ.get("BR_MODE", "ok")
if args == ["ready", "--json"]:
    if mode == "read_error": sys.exit(2)
    print(queue.read_text())
elif args and args[0] == "create":
    if mode == "create_error": sys.exit(2)
    title = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--title="))
    queue.write_text(json.dumps([{"id": "bd-first", "title": title}]))
    print("invalid id" if mode == "create_invalid" else "bd-first")
else:
    sys.exit(95)
'''

PRELUDE = r'''
set -euo pipefail
source "$SCREEN"
state_get() {
    case "$1" in
        project_name) printf '%s\n' "$PROJECT_NAME" ;;
        project_dir) printf '%s\n' "$PROJECT" ;;
        *) printf 'false\n' ;;
    esac
}
tui_cleanup() { printf 'cleanup\n' >> "$EVENTS"; }
finalize_logging() { printf 'finalize\n' >> "$EVENTS"; }
log_input() { :; }
render_success_screen() { :; }
'''

@unittest.skipUnless(BASH and JQ, "Bash and jq are required")
class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="acfs-herdr-launch-"))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.project = self.root / "project spaces ' $(literal); [brackets]"
        self.project.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.am_calls = self.root / "am-calls.jsonl"
        self.events = self.root / "events"
        self.executable("herdr", "#!" + sys.executable + "\n" + HERDR)
        self.executable("am", "#!" + sys.executable + "\n" + AM)
        self.bin.joinpath("jq").symlink_to(JQ)
        for tool in SYSTEM_TOOLS:
            self.bin.joinpath(tool).symlink_to(shutil.which(tool))
        for agent in ("claude", "codex", "agy"):
            self.executable(agent, "#!" + BASH + "\nprintf 'UNEXPECTED PROVIDER EXECUTION' >&2\nexit 91\n")
        env = {key: value for key, value in os.environ.items() if key != "HERDR_WORKSPACE_ID"}
        self.env = {
            **env, "PATH": str(self.bin), "SCREEN": str(SCREEN),
            "PROJECT": str(self.project), "PROJECT_NAME": "my-app",
            "CALLS": str(self.calls), "AM_CALLS": str(self.am_calls),
            "EVENTS": str(self.events), "FAKE_HERDR_MODE": "ok", "LC_ALL": "C",
            # The repo's command palette, never an installed copy.
            "ACFS_HOME": str(self.root / "no-acfs-home"),
        }

    def enable_work(self, ready=None):
        self.project.joinpath(".beads").mkdir()
        self.queue = self.root / "queue.json"
        self.queue.write_text(json.dumps(ready if ready is not None else [{"id": "bd-ready", "title": "Implement the feature"}]))
        self.br_calls = self.root / "br-calls.jsonl"
        self.env.update(BR_CALLS=str(self.br_calls), BR_QUEUE=str(self.queue), BR_MODE="ok")
        self.executable("br", "#!" + sys.executable + "\n" + BR)
        self.executable("bv", "#!" + BASH + "\nexit 0\n")

    def bead_invocations(self):
        return [json.loads(line) for line in self.br_calls.read_text().splitlines()] if self.br_calls.exists() else []

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_bash(self, body, data="", **env):
        return subprocess.run(
            [BASH, "-c", PRELUDE + body], input=data, text=True,
            capture_output=True, env={**self.env, **env}, cwd=self.root,
            timeout=20, check=False,
        )

    def invocations(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def mutating(self):
        """herdr calls that change anything: all but status, read and wait."""
        return [call["argv"] for call in self.invocations()
                if call["argv"][:2] not in (["status", "server"], ["agent", "read"], ["agent", "wait"])]

    def keys(self):
        return [argv[2:] for argv in self.mutating() if argv[:2] == ["agent", "send-keys"]]

    def starts(self):
        return [argv for argv in self.mutating() if argv[:2] == ["agent", "start"]]

    def prompts(self):
        return [argv for argv in self.mutating() if argv[:2] == ["agent", "prompt"]]

    def start(self, **env):
        return self.run_bash('newproj_start_herdr "$PROJECT" acfs-my-app 1 1 1', **env)

    def test_exact_workspace_and_explicit_counts(self):
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "w9\n")
        project = str(self.project)
        self.assertEqual(self.mutating(), [
            ["workspace", "create", "--cwd", project, "--label", "acfs-my-app", "--no-focus"],
            ["tab", "create", "--workspace", "w9", "--cwd", project, "--label", "BlueLake", "--no-focus"],
            ["agent", "start", "bluelake", "--kind", "claude", "--pane", "w9:p2"],
            ["tab", "create", "--workspace", "w9", "--cwd", project, "--label", "GreenCastle", "--no-focus"],
            ["agent", "start", "greencastle", "--kind", "codex", "--pane", "w9:p3"],
            ["tab", "create", "--workspace", "w9", "--cwd", project, "--label", "RedStone", "--no-focus"],
            ["agent", "start", "redstone", "--kind", "agy", "--pane", "w9:p4"],
        ])
        self.assertEqual(self.prompts(), [])
        self.assertFalse(self.events.exists())

    def test_failure_preserves_diagnostic_and_never_retries(self):
        result = self.start(FAKE_HERDR_MODE="start_blocked")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not start (agent_not_ready)", result.stderr)
        self.assertIn("Trust this folder?", result.stderr)
        self.assertIn("No automatic retry or cleanup", result.stderr)
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(sum(argv[:2] == ["workspace", "create"] for argv in self.mutating()), 1)
        self.assertFalse(self.events.exists())

    def test_unconfirmed_workspace_or_agents_never_authorize_attach(self):
        for mode in ("ws_exit", "ws_invalid", "ws_unsafe", "start_blocked"):
            with self.subTest(mode=mode):
                result = self.run_bash('open_in_herdr', "\n\n\n\nyes\n", FAKE_HERDR_MODE=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("ATTACHED", result.stdout)
                self.assertFalse(self.events.exists())
        self.assertFalse((self.root / "injected").exists())
        self.assertNotIn([], [call["argv"] for call in self.invocations()])

    def test_new_folder_trust_dialogs_are_answered_with_consent(self):
        # A folder newproj just created: Claude Code and Codex each ask
        # whether to trust it. The consent text says ACFS answers "trust".
        self.bin.joinpath("agy").rename(self.bin / "agy.disabled")
        result = self.run_bash('open_in_herdr', "\n\n\nyes\n", FAKE_HERDR_MODE="trust_dialog")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("trust this new project folder", result.stdout)
        self.assertEqual(self.keys(), [["bluelake", "down", "enter"], ["greencastle", "enter"]])
        self.assertIn("ATTACHED", result.stdout)

    def test_other_dialogs_still_stop_spawn(self):
        # Antigravity's dialog isn't a folder-trust dialog spawn knows.
        for agent in ("claude", "codex"):
            self.bin.joinpath(agent).rename(self.bin / (agent + ".disabled"))
        result = self.run_bash('open_in_herdr', "\n\nyes\n", FAKE_HERDR_MODE="trust_dialog")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("ATTACHED", result.stdout)
        self.assertEqual(self.keys(), [])
        self.assertEqual(len(self.starts()), 1)

    def test_default_label_is_sanitized(self):
        result = self.run_bash('open_in_herdr', "\n\n\n\nyes\n", PROJECT_NAME="my.app v2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutating()[0][4:6], ["--label", "acfs-my-app-v2"])

    def test_ws_failure_starts_no_agent(self):
        for mode in ("ws_exit", "ws_invalid", "ws_unsafe"):
            with self.subTest(mode=mode):
                result = self.start(FAKE_HERDR_MODE=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("did not confirm a new workspace", result.stderr)
        self.assertEqual(self.starts(), [])
        self.assertFalse(self.am_calls.exists())

    def test_agent_mail_failure_starts_no_agent(self):
        result = self.start(FAKE_AM_MODE="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("am agents create failed", result.stderr)
        self.assertEqual(self.starts(), [])

    def test_invalid_mix_never_executes_herdr(self):
        for mix in ("0 0 0", "4 4 4", "5 0 0", "-1 1 0", "08 1 0", "x 1 0", "1 1.0 0"):
            with self.subTest(mix=mix):
                result = self.run_bash('newproj_start_herdr "$PROJECT" acfs-my-app ' + mix)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.invocations(), [])

    def test_arithmetic_injection_is_data(self):
        result = self.run_bash('newproj_start_herdr "$PROJECT" acfs-my-app "$BAD_COUNT" 1 0', BAD_COUNT='1+$(touch injected)')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.invocations(), [])
        self.assertFalse((self.root / "injected").exists())

    def test_label_validation_precedes_execution(self):
        for name in ("", "-option", "bad.name", "bad:name", "a" * 65, "a\nline", "$(touch injected)"):
            with self.subTest(name=name):
                result = self.run_bash('newproj_start_herdr "$PROJECT" "$NAME" 1 1 0', NAME=name)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.invocations(), [])

    def test_missing_provider_refuses_before_spawn(self):
        self.bin.joinpath("codex").rename(self.bin / "codex.disabled")
        result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutating(), [])

    def test_each_infrastructure_dependency_is_required(self):
        for tool in ("herdr", "jq", "am"):
            with self.subTest(tool=tool):
                path = self.bin / tool
                saved = self.bin / (tool + ".saved")
                path.rename(saved)
                try:
                    result = self.start()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Missing " + tool, result.stderr)
                finally:
                    saved.rename(path)
        self.assertEqual(self.invocations(), [])

    def test_stopped_server_refuses_before_any_change(self):
        result = self.start(FAKE_HERDR_MODE="server_down")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("herdr server isn't running", result.stderr)
        self.assertEqual(self.mutating(), [])

    def test_missing_helper_refuses(self):
        result = self.run_bash('NEWPROJ_HERDR_AGENTS="$PROJECT/missing.sh"; newproj_start_herdr "$PROJECT" acfs-my-app 1 1 0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("acfs update", result.stderr)
        self.assertEqual(self.invocations(), [])

    def test_missing_or_unsafe_project_refuses(self):
        for project in ("/", "relative", str(self.root / "missing"), str(self.project) + "\n"):
            with self.subTest(project=project):
                result = self.start(PROJECT=project)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.invocations(), [])

    def test_canonical_project_ignores_cdpath(self):
        alias = self.root / "alias"
        alias.symlink_to(self.project, target_is_directory=True)
        result = self.run_bash('newproj_herdr_project', PROJECT=str(alias), CDPATH=str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.project) + "\n")

    def test_spawn_leaves_caller_directory_and_streams_intact(self):
        result = self.run_bash('newproj_start_herdr "$PROJECT" acfs-my-app 1 1 0; pwd; echo diagnostic >&2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith(str(self.root) + "\n"))
        self.assertIn("diagnostic", result.stderr)

    def test_default_mix_needs_explicit_yes(self):
        for answer in ("", "y", "no"):
            with self.subTest(answer=answer):
                result = self.run_bash('open_in_herdr', "\n\n\n\n" + answer + "\n")
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutating(), [])

    def test_eof_during_each_prompt_never_launches(self):
        for input_data in ("", "\n", "\n\n", "\n\n\n", "\n\n\n\n"):
            with self.subTest(input_data=input_data):
                result = self.run_bash('open_in_herdr', input_data)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutating(), [])

    def test_confirmed_workspace_focuses_and_attaches_after_cleanup(self):
        result = self.run_bash('open_in_herdr', "\n\n\n\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ATTACHED", result.stdout)
        self.assertEqual(self.events.read_text(), "cleanup\nfinalize\n")
        calls = self.invocations()
        self.assertEqual(calls[-2]["argv"], ["workspace", "focus", "w9"])
        self.assertEqual(calls[-1], {"argv": [], "cwd": str(self.project)})

    def test_inside_herdr_focuses_without_attaching(self):
        result = self.run_bash('open_in_herdr', "\n\n\n\nyes\n", HERDR_WORKSPACE_ID="w1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ATTACHED", result.stdout)
        self.assertIn("started and focused", result.stdout)
        self.assertEqual(self.invocations()[-1]["argv"], ["workspace", "focus", "w9"])
        # The caller's run_success_screen cleans up once; nothing here does.
        self.assertFalse(self.events.exists())
        self.assertNotIn("w1", [argv[3] for argv in self.mutating() if argv[:2] == ["tab", "create"]])

    def test_single_provider_defaults_to_two_agents(self):
        for agent in ("codex", "agy"):
            self.bin.joinpath(agent).rename(self.bin / (agent + ".disabled"))
        result = self.run_bash('open_in_herdr', "\n\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([argv[4] for argv in self.starts()], ["claude", "claude"])

    def test_operator_can_choose_counts_and_label(self):
        result = self.run_bash('open_in_herdr', "review-team\n2\n0\n1\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutating()[0][4:6], ["--label", "review-team"])
        self.assertEqual([argv[4] for argv in self.starts()], ["claude", "claude", "agy"])

    def test_no_agents_gives_actionable_failure(self):
        for agent in ("claude", "codex", "agy"):
            self.bin.joinpath(agent).rename(self.bin / (agent + ".disabled"))
        result = self.run_bash('open_in_herdr')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Install Claude Code", result.stderr)
        self.assertEqual(self.invocations(), [])

    def test_success_screen_eof_does_not_open_shell(self):
        result = self.run_bash('open_in_shell() { echo UNEXPECTED; }; handle_success_input')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("UNEXPECTED", result.stdout)
        self.assertEqual(self.invocations(), [])

    def test_menu_routes_herdr_and_preserves_cancel(self):
        result = self.run_bash('handle_success_input', "n\n\n\n\nno\nxq")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cancelled", result.stdout)
        self.assertEqual(self.mutating(), [])

    def test_plain_workspace_sends_no_prompt(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr', "\n\n\n\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bead_invocations(), [])
        self.assertEqual(self.prompts(), [])
        self.assertEqual(len(self.starts()), 3)

    def test_work_handoff_prompts_each_agent_with_the_palette_kickoff(self):
        self.enable_work()
        result = self.run_bash('open_in_herdr true', "\n\n\n\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        prompts = self.prompts()
        self.assertEqual([argv[2] for argv in prompts], ["bluelake", "greencastle", "redstone"])
        for argv in prompts:
            self.assertIn("Your Agent Mail identity is already registered", argv[3])
            self.assertIn("project key " + str(self.project), argv[3])
            self.assertIn("beads", argv[3].lower())
            self.assertNotIn("--wait", argv)
        self.assertIn("Prompted 3 agent(s)", result.stderr)
        self.assertIn("Implement the feature", result.stdout)
        self.assertTrue(all(call["argv"] == ["ready", "--json"] for call in self.bead_invocations()))
        self.assertTrue(all(call["cwd"] == str(self.project) for call in self.bead_invocations()))

    def test_failed_kickoff_is_not_reported_as_work_started(self):
        self.enable_work()
        result = self.run_bash('open_in_herdr true', "\n\n\n\nyes\n", FAKE_HERDR_MODE="prompt_fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("ATTACHED", result.stdout)
        self.assertNotIn("Prompted", result.stderr)
        self.assertIn("No automatic retry or cleanup", result.stderr)
        # One start per agent; nothing re-dispatched.
        self.assertEqual(len(self.starts()), 3)
        self.assertEqual(len(self.prompts()), 3)

    def test_empty_queue_creates_first_task_only_after_consent(self):
        self.enable_work([])
        title = 'Implement "search"; $(do-not-execute)'
        result = self.run_bash('open_in_herdr true', "\n\n\n\n" + title + "\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        creates = [call for call in self.bead_invocations() if call["argv"][0] == "create"]
        self.assertEqual(creates, [{"cwd": str(self.project), "argv": ["create", "--title=" + title, "--type=task", "--priority=2", "--silent"]}])
        self.assertEqual(json.loads(self.queue.read_text())[0]["title"], title)
        self.assertIn("Created task bd-first", result.stdout)
        self.assertEqual(len(self.prompts()), 3)

    def test_declined_first_task_is_not_created(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst feature\nno\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.queue.read_text()), [])
        self.assertEqual(self.mutating(), [])
        self.assertTrue(all(call["argv"][0] == "ready" for call in self.bead_invocations()))

    def test_work_mode_eof_never_creates_or_launches(self):
        self.enable_work([])
        for data in ("\n\n\n\n", "\n\n\n\nFirst feature\n"):
            with self.subTest(data=data):
                result = self.run_bash('open_in_herdr true', data)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.queue.read_text()), [])
        self.assertEqual(self.mutating(), [])

    def test_invalid_goal_never_creates_a_task(self):
        self.enable_work([])
        for title in ("", "   ", "x" * 513, "escape\x1bsequence", "tab\tvalue"):
            with self.subTest(title=title):
                result = self.run_bash('open_in_herdr true', "\n\n\n\n" + title + "\nyes\n")
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.queue.read_text()), [])
        self.assertEqual(self.mutating(), [])

    def test_invalid_mix_prevents_even_task_creation(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr true', "\n9\n1\n1\nFirst feature\nyes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.bead_invocations(), [])
        self.assertEqual(self.mutating(), [])

    def test_missing_beads_project_does_not_assign_work(self):
        self.enable_work()
        self.project.joinpath(".beads").rename(self.project / ".beads.saved")
        result = self.run_bash('open_in_herdr true', "\n\n\n\nyes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("br init", result.stderr)
        self.assertEqual(self.bead_invocations(), [])
        self.assertEqual(self.mutating(), [])

    def test_symlinked_beads_project_is_not_used(self):
        self.enable_work()
        original = self.project / ".beads"
        original.rename(self.project / ".beads.saved")
        original.symlink_to(self.project / ".beads.saved", target_is_directory=True)
        result = self.run_bash('open_in_herdr true', "\n\n\n\nyes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.bead_invocations(), [])

    def test_missing_beads_tools_prevents_launch(self):
        self.enable_work()
        for tool in ("br", "bv"):
            path = self.bin / tool
            saved = self.bin / (tool + ".saved")
            path.rename(saved)
            try:
                result = self.run_bash('open_in_herdr true', "\n\n\n\nyes\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.mutating(), [])
            finally:
                saved.rename(path)

    def test_malformed_ready_queue_is_not_permission_to_create(self):
        self.enable_work()
        for ready in ('{}', 'null', 'bad JSON', '[{}]', '[]\n[]', '[{"id":"bad id","title":"x"}]'):
            with self.subTest(ready=ready):
                self.queue.write_text(ready)
                result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst task\nyes\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.queue.read_text(), ready)
        self.assertEqual(self.mutating(), [])
        self.assertTrue(all(call["argv"][0] == "ready" for call in self.bead_invocations()))

    def test_task_read_failure_is_not_an_empty_queue(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst task\nyes\n", BR_MODE="read_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not read", result.stderr)
        self.assertEqual(self.mutating(), [])

    def test_creation_failure_never_launches(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst task\nyes\n", BR_MODE="create_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutating(), [])

    def test_ambiguous_creation_preserves_task_without_retry(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst task\nyes\n", BR_MODE="create_invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(json.loads(self.queue.read_text())), 1)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(sum(call["argv"][0] == "create" for call in self.bead_invocations()), 1)

    def test_spawn_failure_preserves_created_task(self):
        self.enable_work([])
        result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst task\nyes\n", FAKE_HERDR_MODE="start_blocked")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.queue.read_text())[0]["id"], "bd-first")
        self.assertEqual(len(self.starts()), 1)

    def test_inherited_database_overrides_cannot_redirect_task_handoff(self):
        self.enable_work([])
        scope_log = self.root / "scope.jsonl"
        overrides = {key: "/another-project/" + key for key in ("BEADS_DIR", "BEADS_DB", "BD_DB", "BD_DATABASE", "BEADS_JSONL")}
        result = self.run_bash('open_in_herdr true', "\n\n\n\nFirst task\nyes\n", SCOPE_LOG=str(scope_log), **overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        scopes = [json.loads(line) for line in scope_log.read_text().splitlines()]
        self.assertEqual(len(scopes), 3)  # ready, create, ready
        for scope in scopes:
            self.assertEqual(scope.pop("BEADS_DIR"), str(self.project / ".beads"))
            self.assertTrue(all(value is None for value in scope.values()))

    def test_project_scope_preserves_callers_environment(self):
        self.enable_work()
        overrides = {key: "/another-project/" + key for key in ("BEADS_DIR", "BEADS_DB", "BD_DB", "BD_DATABASE", "BEADS_JSONL")}
        body = r'''
        newproj_herdr_ready_work "$PROJECT" >/dev/null
        for key in BEADS_DIR BEADS_DB BD_DB BD_DATABASE BEADS_JSONL; do
            [[ "${!key}" == "/another-project/$key" ]] || exit 92
        done
        pwd
        '''
        result = self.run_bash(body, **overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.root) + "\n")

    def test_work_mode_must_be_explicit_boolean(self):
        result = self.run_bash('newproj_start_herdr "$PROJECT" acfs-my-app 1 1 0 maybe')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutating(), [])

    def test_work_menu_routes_to_explicit_handoff(self):
        self.enable_work()
        result = self.run_bash('handle_success_input', "w\n\n\n\nyes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.prompts()), 3)

if __name__ == "__main__":
    unittest.main(verbosity=2)
