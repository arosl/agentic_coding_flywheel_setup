# Start native agents with admission and a durable launch intent

The explicit launcher fills the gap between the read-only swarm planner and
packet preparation, which needs existing stable agent panes. It supports 1–32
native Claude/Codex agents. It does not use nhm's automatic work assignment.

Preview first (the standalone entrypoint is also useful from a checkout):

```bash
bash scripts/lib/swarm_launch.sh --repo "$PWD" --session implementation \
  --agent RedFox:claude --agent BlueLake:codex \
  --receipt "$HOME/implementation-launch.json"
```

The installed command is `acfs swarm launch` once the runtime has been installed
or refreshed. Preview runs the existing live ACFS planner in the selected
repository and nhm's native spawn dry-run. It does not create a receipt or start
agents, although upstream tools can write their ordinary telemetry. Use the
returned `launch_command` to perform the separate hash-bound `--launch` operation.
Launching starts the agents in a new herdr workspace labelled
`swarm-<session>-<first 12 hex of the review hash>`, through `nhm
--robot-spawn=<label> --spawn-cc=N --spawn-cod=N --spawn-safety --spawn-wait`.
herdr has no session-creation time, so the label is what tells this launch's
workspace from any other with the same session name; recovery finds it by the
label. nhm gives each agent a new Agent Mail identity, registered in the
repository's Agent Mail project; its herdr name is that name lowercased.
Launching can start paid provider processes; nhm's configured commands, models
and normal permission policy remain in effect. No prompts, trust-dialog
responses, Beads claims, reservations, interrupts, existing-workspace reuse or
destructive cleanup are requested.

Both ACFS and nhm must admit the requested agent count. Unknown or malformed
admission fails closed. When nhm's admission check refuses, nothing is started,
and the error gives nhm's reasons and hint, such as a red capacity and its way
out (`--ignore-capacity`, which `acfs swarm launch` never passes). A launch
refused this way never relaunches from its receipt; launch again with a new
`--receipt`. `wait`, `scale_down`, `fail`, or a count above the
recommended/safe limits always blocks launch. `--accept-warnings` is explicit
permission for warning-level decisions that still recommend proceeding; it
never overrides pressure or hard blockers. `--profile` and `--workload` select
the existing planner policies, not provider/model overrides. No saved admission
snapshots are accepted as authority to start agents.

Every requested name is bound to its original slot, even when the request
interleaves Claude and Codex. After nhm reports ready agents, ACFS finds each
returned agent by the herdr pane ID nhm reports, and verifies the live native
process in the pane, the project directory, and its herdr identity: workspace,
tab, pane, terminal ID and shell PID. The workspace must carry the launch's
label, where upstream requires each pane's tmux session to be the launch's. A
stale title on a shell is not sufficient. An agent nhm does not report ready, such as one stopped at a
first-run trust dialog, leaves the launch unconfirmed: answer the dialog in its
pane, then use receipt-only reconciliation or recovery below. The result
includes `preparation_targets`, such as:

```text
1:GreenCastle:claude:w9:p2
2:AmberFox:codex:w9:p3
```

The second field is the slot's Agent Mail name, which nhm registered; the last
is its herdr pane ID. Pass those values as repeated `--target` options to
`acfs swarm packet --prepare-batch`, then review the generated packets before
dispatch. Process readiness does not establish authentication or successful
model execution.

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

Use that returned command only after reviewing the packet Markdown and the
slot-to-pane mapping. Each new submission rechecks the original native target,
then uses the existing single-packet sender's live ready-queue check, nhm dry run,
private durable intent, exact payload hash and stdin transport
([packet delivery](swarm-packet-delivery.md)). It does not create workspaces,
register identities, claim Beads or acquire reservations.

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
never authorizes resending. `submitted` means matching nhm submission evidence,
not task execution or completion. `submission_may_have_occurred` flags uncertain
child execution even when no valid result was returned.

The native identity check and nhm send are separate operations, not an atomic
compare-and-send. Do not restart agents or replace panes during dispatch. This
path detects identity changes at its checks but cannot eliminate that final race.
The launch receipt directory lock excludes concurrent launch-aware dispatchers
using the same directory, not unrelated nhm callers or all users on the machine.

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
other users or nhm callers can still launch work independently.

The intent is fsynced **before** the real nhm spawn. Full verified success writes
a separate private `<receipt>.result.json` (schema `acfs.swarm-launch.v2`, whose
targets are herdr identities). Both files are immutable to this command.
Repeating the same request with an existing intent only verifies the saved
agents; it never invokes spawn or re-runs admission as authority to spawn.
Identity is the pane, not the agent's name: a new terminal or shell in a
recorded pane, a missing agent, a shell, a different repository, or a workspace
that no longer carries the launch's label returns `unconfirmed`.

A lost response, timeout, signal, partial startup or failed confirmation can
leave a working or partial workspace and an intent without a result. It remains
`unconfirmed`, and ACFS deliberately does not adopt arbitrary agents based only
on the workspace label. Inspect that workspace manually; Agent Mail identities
may already be registered for agents that started. Preserve receipts; changing
the receipt path or deleting an intent is a new launch request, not recovery.
No workspace or agent is automatically closed, restarted or cleaned up after
failure.

Exit codes: `0` for an admitted preview or fully verified ready agents, `1` for
an uncertain launch/reconciliation, `2` for validation, admission or preflight
failure. Preserve any intent even after an exit-2 interruption.

## Verification

```bash
bash -n scripts/lib/swarm_launch.sh
python3 -B tests/unit/test_swarm_launch.py
python3 -B tests/unit/test_swarm_launch_handoff.py
```

The regression suites execute the actual Bash/Python launcher against executable
planner/nhm/herdr contract fixtures. They cover both admissions, exact agent mix,
original-slot mapping, private receipts, directory exclusion, unready/native
process failures, replaced terminals, response loss and no-relaunch recovery.
Handoff and dispatch tests also exercise the actual allocator, preparer and
packet sender from a complete checkout, including receipt-only recovery after
native agents exit. They do not exercise installed providers, live
authentication or a production VPS.

## Lost startup confirmation and receipt-only reconciliation

Use `acfs swarm launch --reconcile --receipt /absolute/path/launch.json` to
verify an existing launch without retyping its original arguments. This command
only inspects saved evidence and live herdr state; it never launches agents or
sends work.

When the original durable intent exists but its result is missing, use
`acfs swarm launch --recover --receipt /absolute/path/launch.json` to preview
explicit adoption of the agents in the launch's workspace. Adoption needs a
separate recovery digest and `--adopt`. It never retries spawn or replaces an
existing result. See [launch recovery](swarm-launch-recovery.md) for the identity
checks, provenance limitations, and return path to scoped work-packet preparation.
