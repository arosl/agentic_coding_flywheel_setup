# Start native agents with admission and a durable launch intent

The explicit launcher fills the gap between the read-only swarm planner and
packet preparation, which needs existing stable agent panes. It supports 1–32
native Claude/Codex agents, each in its own tab of a new herdr workspace. It
sends the agents no work.

Preview first (the standalone entrypoint is also useful from a checkout):

```bash
bash scripts/lib/swarm_launch.sh --repo "$PWD" --session implementation \
  --agent RedFox:claude --agent BlueLake:codex \
  --receipt "$HOME/implementation-launch.json"
```

The installed command is `acfs swarm launch` once the runtime has been installed
or refreshed. Preview runs the existing live ACFS planner in the selected
repository and checks that herdr can take the launch: herdr, `am` and `jq` are
installed, `acfs agents` (`herdr_agents.sh`) is beside the launcher, the herdr
server is running, and no workspace already carries this launch's label. It
reports the exact herdr commands it would run (`herdr_plan`). It does not create
a receipt or start agents. Use the returned `launch_command` to perform the
separate hash-bound `--launch` operation.

Launching creates a new herdr workspace labelled
`swarm-<session>-<first 12 hex of the review hash>`, then starts the agents one at
a time, in slot order, through `acfs agents spawn --kind <type> --count 1
--no-prompt`. Each agent gets a new Agent Mail identity, registered in the
repository's Agent Mail project, and its own tab labelled with that name; its
herdr name is that name lowercased. Launching can start paid provider processes.
No prompts, trust-dialog answers, Beads claims, reservations, interrupts,
existing-workspace reuse or destructive cleanup are requested.

An agent that stops at a first-run dialog, such as Claude Code's or Codex's
"trust this folder?", counts as launched (`launched_state: "blocked"`): answer it
in its tab. The launcher never answers it, because trusting the repository is
the operator's decision.

The ACFS planner is the only admission gate. Unknown or malformed admission
fails closed. `wait`, `scale_down`, `fail`, or a count above the
recommended/safe limits always blocks launch. `--accept-warnings` is explicit
permission for warning-level decisions that still recommend proceeding; it
never overrides pressure or hard blockers. `--profile` and `--workload` select
the existing planner policies, not provider/model overrides. No saved admission
snapshots are accepted as authority to start agents.

Every requested name is bound to its original slot, even when the request
interleaves Claude and Codex. After each agent starts, ACFS verifies it through
herdr: its pane, tab, terminal ID and shell PID, the live native process in the
pane, and its working directory. The result includes `preparation_targets`, such
as:

```text
1:GreenCastle:claude:w9:p2
2:AmberFox:codex:w9:p3
```

The second field is the slot's Agent Mail name, the last is its herdr pane ID.
Process readiness does not establish authentication or successful model
execution.

## Prepare work directly from a verified launch

Supply the original launch intent; each launched slot's Agent Mail identity
defaults to the one launch registered:

```bash
acfs swarm launch --prepare-batch ./handoff \
  --receipt "$HOME/implementation-launch.json" \
  --scopes-file scopes.json --roles implementation,documentation
```

`--identity SLOT:NAME` overrides the mapping; give one for every launched slot,
including slots that may be idle. `launch.agent_mail_registration_verified` is
true only when every name is the one launch registered.

This reads the private launch intent and result, rechecks each recorded agent
through herdr (pane, tab, terminal, shell PID, native process and repository
working directory), then delegates to the installed scope-aware packet preparer.
Repository, workspace, pane and provider choices come only from the saved launch;
there is no handoff override that can retarget another workspace.

**Until acfs-qzc (K5) lands,** the installed packet preparer still expects tmux
pane IDs (`%N`) and refuses herdr pane IDs, so this handoff stops at the
preparer.

Only selected work produces packets. Use `--assignments assignments.json` instead
of `--scopes-file` to prepare saved assignments, including reports with idle-slot
holes. `--ready-file`, `--triage-file`, `--beads-file`, `--no-live-context` and the
role/profile options have the same meanings as in
[packet preparation](swarm-packet-preparation.md). Relative inputs resolve from
the invocation directory and their bytes are pinned before preparation.

The handoff does not spawn, send prompts, claim Beads or acquire reservations.
It rechecks the launch again after preparation. A changed agent causes failure
without advertising a usable handoff; any already-written bundle is retained for
inspection. Missing or unconfirmed launch receipts never trigger a replacement
launch or adoption of arbitrary agents. Existing output is not replaced.
Review every generated packet and then use the returned `preview_command` for
the separate receipt-checked dispatch workflow below.

Handoff exit codes are `0` for prepared work, `1` for no independent ready work
(no bundle is created), and `2` for unusable launch evidence or preparation errors.
The result's `launch` object records the identity mapping and makes explicit that
no agents were started and no work was dispatched.

## Dispatch reviewed work to the original launched agents

Preparation from a launch returns this preview command:

```bash
acfs swarm launch --dispatch-batch ./handoff/batch.json \
  --receipt "$HOME/implementation-launch.json"
```

The preview validates every packet using the installed packet-delivery module,
checks that each target belongs to the recorded launch, and rechecks each
pending delivery's original agent through herdr. It does not send prompts or
create delivery receipts. Its `send_command` requires a hash binding **the
launch request and original targets plus the batch and every packet**. A hash
from the lower-level packet dispatcher does not authorize this command.

**Delivery still runs through NTM** (`ntm --robot-send` and its receipts) until
acfs-qzc (K5) moves it to herdr. Use the returned command only after reviewing the
packet Markdown and the slot-to-pane mapping. Each new submission rechecks the
original agent, then uses the existing single-packet sender's live ready-queue
check, private durable intent, exact payload hash and stdin transport. It does
not create workspaces, register identities, claim Beads or acquire reservations.

Dispatch is sequential, not transactional. An uncertain submission or failed
identity check stops the batch, retains earlier submissions, and marks later
entries `not_attempted`. Keep the unchanged batch, packets, launch receipt/result,
and per-delivery receipts. Repeating the same approved command queries known
intents first and continues pending entries only after earlier submissions are
confirmed. A known intent never enters a send-capable path again during that
invocation, even if its file is moved after validation. Do not remove receipts
between invocations: an absent receipt cannot prove a previous send did not occur.

Historical submission receipts can be queried after the original agents exit;
new work still requires the original live identities. A missing upstream receipt,
wrong operation/payload/target, or malformed response stays `unconfirmed` and
never authorizes resending. `submitted` means matching submission evidence,
not task execution or completion. `submission_may_have_occurred` flags uncertain
child execution even when no valid result was returned.

The identity check and the send are separate operations, not an atomic
compare-and-send. Do not restart agents or replace panes during dispatch. This
path detects identity changes at its checks but cannot eliminate that final race.
The launch receipt directory lock excludes concurrent launch-aware dispatchers
using the same directory, not unrelated callers or all users on the machine.

Dispatch exit codes are `0` for a valid preview or confirmed submissions, `1`
for an unconfirmed submission, and `2` for invalid evidence or a failed preflight.
After a stopped batch, inspect its per-delivery results before taking any action.
The lower-level `acfs swarm packet --deliver-batch` remains available for manually
managed agents; it does not add these original-launch identity checks.

## Recovery: never blindly repeat a spawn

The owned receipt parent must already exist and must not be writable by other
users. Receipts use create-only mode-0600 files; path components and existing
files cannot be symlinks. An exclusive kernel lock on the receipt directory
serializes launches using that directory. This is not a machine-wide quota:
other users or herdr callers can still start agents independently.

The intent is fsynced **before** the workspace is created. Full verified success
writes a separate private `<receipt>.result.json` (schema
`acfs.swarm-launch.v2`). Both files are immutable to this command. Repeating the
same request with an existing intent only verifies the saved agents; it never
spawns or re-runs admission as authority to spawn.

Identity is the pane, not the agent's name. herdr can drop an agent's name, for
example after a Codex context compaction or `codex resume`; a recorded agent whose
pane, tab, terminal, shell PID and kind still match stays `ready`, and its
`live` report says `name_lost: true` with the `rename_command`
(`herdr agent rename <pane> <name>`) to run. Reconciliation never runs it. A new
terminal or shell in a recorded pane, a missing agent, a shell, or a different
repository returns `unconfirmed`.

A lost response, timeout, signal, partial startup or failed confirmation can
leave a working or partial workspace and an intent without a result. It remains
`unconfirmed`, and the error names the workspace label to inspect. Agent Mail
identities may already be registered for agents that started. Preserve receipts;
changing the receipt path or deleting an intent is a new launch request, not
recovery. No workspace or agent is automatically closed, restarted or cleaned
up after failure.

Exit codes: `0` for an admitted preview or fully verified ready agents, `1` for
an uncertain launch/reconciliation, `2` for validation, admission or preflight
failure. Preserve any intent even after an exit-2 interruption.

## Verification

```bash
bash -n scripts/lib/swarm_launch.sh
python3 -B tests/unit/test_swarm_launch.py
python3 -B tests/unit/test_swarm_launch_handoff.py
```

The regression suites execute the actual Bash/Python launcher, and the real
`herdr_agents.sh` it calls, against executable planner/herdr/`am` contract
fixtures. They cover admission, preflight, exact agent mix, original-slot
mapping, an agent waiting at a dialog, a lost name, replaced terminals, private
receipts, directory exclusion, response loss and no-relaunch recovery. The
tests that run the real packet preparer are skipped until acfs-qzc (K5). They do
not exercise installed providers, live authentication or a production VPS.

## Lost startup confirmation and receipt-only reconciliation

Use `acfs swarm launch --reconcile --receipt /absolute/path/launch.json` to
verify an existing launch without retyping its original arguments. This command
only inspects saved evidence and live herdr state; it never launches agents,
renames them or sends work.

When the original durable intent exists but its result is missing, use
`acfs swarm launch --recover --receipt /absolute/path/launch.json` to preview
explicit adoption of the agents in the launch's workspace. Adoption needs a
separate recovery digest and `--adopt`. It never retries spawn or replaces an
existing result. See [launch recovery](swarm-launch-recovery.md) for the identity
checks, provenance limitations, and return path to scoped work-packet preparation.
