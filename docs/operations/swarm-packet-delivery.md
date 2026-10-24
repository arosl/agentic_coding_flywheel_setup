# Deliver a reviewed work packet to an existing agent

The packet generator can now hand its prompt to one explicitly selected nhm
agent. Ordinary `acfs swarm packet --bead …` generation remains read-only.
Delivery is a separate `--deliver` mode, previews by default, and requires
`--send` plus the previewed packet hash to submit anything.

This starts work in an **existing native Claude or Codex agent**. It does not
spawn agents, authenticate accounts, clear input, interrupt a session, change
trust settings, claim Beads, or reserve files. Submission can trigger paid model
calls and project edits by the receiving agent. Review the prompt first.

## Generate, review, then deliver

Run in the target repository. Protect saved context and avoid overwriting an
existing packet:

```bash
umask 077
set -o noclobber
acfs swarm packet --bead bd-example --repo "$PWD" \
  --agent-name YOUR_AGENT_NAME --max-chars 16000 --json > work-packet.json
jq -r .packet_markdown work-packet.json
```

Use an already registered Agent Mail identity where the packet names one. The
receiving agent must still inspect its inbox, current Beads, and reservations.
A packet is not a work claim or evidence that its instructions are current.

Find the agent's herdr workspace and pane IDs, not a tab or layout number:

```bash
herdr agent list
```

Preview the handoff (no tools are called and no receipt is written):

```bash
acfs swarm packet --deliver work-packet.json --repo "$PWD" \
  --workspace w9 --pane-id w9:p3 --agent-type claude \
  --operation-id myproject-bd-example-1 --receipt work-packet.receipt.json
```

The JSON output includes `send_command`, a copyable invocation with `--send` and
`--expect-sha256` already filled in. Execute that command only after reviewing
the prompt, pane, repository, and potential model costs.

Before sending, ACFS checks the live `br ready --json` queue and verifies the
pane through herdr: it must be listed by `herdr agent list` with the requested
agent type, in the named workspace, with its working directory inside the
repository, not waiting at a dialog (`blocked`), and with the agent among the
pane's foreground processes. ACFS then asks nhm for a dry run, and checks the
pane again. nhm must select exactly one agent. A shell with an old agent title
is not accepted. Other provider types are not yet supported here.

Requires an nhm version supporting `--robot-send`, `--msg-file=-`, `--panes`,
`--type`, `--dry-run`, `--op-id`, and `--robot-send-receipt`. nhm's session is
the herdr workspace, and `--panes` takes the agent's herdr pane ID. The prompt
is sent through stdin, never shell-evaluated or placed in process arguments.
nhm context injection is refused when reported enabled: this packet already
contains its reviewed context. ACFS does not edit the nhm configuration to turn
it off.

## Interruptions and uncertain outcomes

Immediately before submission, ACFS writes a create-only, mode-0600 intent
receipt. It records the packet hash, target, and operation ID, not the prompt.
**Keep both the packet and receipt.** The receipt's directory must be yours and
writable by nobody else (no group or world write): whoever can write it could
remove an intent and turn the next run into a resend. ACFS refuses any other
directory before it contacts herdr or nhm.

Repeat the identical delivery command after a dropped connection or uncertain
result. When the receipt exists, ACFS only queries nhm's durable receipt. It does
not resend, even when the upstream receipt is missing or still in progress.
This intentionally avoids nhm's stale-operation takeover becoming a blind retry.
It also means an intent written just before a crash may require manual inspection
when no send actually reached nhm. Do not remove receipts merely to retry.

`submitted` means a matching nhm durable operation reports one successful pane
submission with the expected payload digest and byte count. It does **not**
prove model comprehension, task execution, or task completion. Changed or
transformed payloads, missing operations, and incomplete admissions remain
`unconfirmed`. Review nhm and the actual pane (`herdr agent read PANE_ID`)
before deliberately creating a new operation/receipt for another attempt.

Exit codes: `0` for a preview or confirmed submission, `1` for an unconfirmed
outcome, and `2` for invalid inputs, failed preflight, or interruption. Never
interpret a nonzero exit as proof that nothing was typed; retain the receipt.
No raw nhm output, model prompt, or service error body is echoed in delivery
reports. Saved packet JSON can contain private project context; do not publish it.

## Tests

```bash
python3 -B tests/unit/test_swarm_packet_delivery.py
python3 -B tests/unit/test_swarm_packet_delivery_batch.py
```

The suites drive the real Bash/Python command, real packet generation, and
executable nhm/herdr/Beads contract fixtures. Live provider/nhm acceptance must be
run separately on a configured VPS; these tests make no model calls.

## Deliver different work to several agents

`--deliver-batch` connects a set of reviewed packets to up to 32 existing agents.
It does not spawn or provision a swarm. First generate a separate, complete
packet for each distinct Bead, review each prompt, and identify the exact panes.
Keep the batch manifest next to the saved packets:

```json
{
  "schema": "acfs.packet-delivery-batch.v2",
  "deliveries": [
    {
      "packet": "implementation.json",
      "repo": "/data/projects/myproject",
      "workspace": "w9",
      "pane_id": "w9:p3",
      "agent_type": "claude",
      "operation_id": "myproject-implementation-1",
      "receipt": "implementation.receipt.json"
    },
    {
      "packet": "tests.json",
      "repo": "/data/projects/myproject",
      "workspace": "w9",
      "pane_id": "w9:p4",
      "agent_type": "codex",
      "operation_id": "myproject-tests-1",
      "receipt": "tests.receipt.json"
    }
  ]
}
```

Relative packet, repository and receipt paths resolve from the manifest's
parent directory, not the invocation directory. Every entry must supply exactly
the fields shown. Panes, operation IDs and receipt paths must be distinct. The
same Bead in the same repository cannot be dispatched twice within one batch.
Receipt paths cannot replace the batch manifest or any packet input.

Preview the entire handoff:

```bash
acfs swarm packet --deliver-batch batch.json
```

This validates **all** saved packets and existing local receipts before any tool
calls. The returned `review_sha256` binds the manifest bytes, all packet file
hashes, target identities and resolved receipt paths. The returned `send_command`
includes that combined hash and `--send`. It is not just a hash of the manifest:
editing a referenced packet also invalidates the reviewed batch.

Authorized dispatch is sequential. Each target still receives the single-agent
live ready-queue, herdr pane, nhm dry-run and durable-intent checks described
above. The reviewed packet bytes are retained in memory for the run. Agents may
begin working as soon as their packet is submitted; this is **not** a transaction,
a reservation, or evidence that their editing scopes are independent. Use the
scope-aware assignment planner and Agent Mail coordination when preparing work.

A failed preflight or uncertain outcome stops dispatch immediately. The JSON
report keeps the earlier results and labels later entries `not_attempted`.
Completed submissions are not rolled back. Preserve the unchanged batch,
packets and receipts, then repeat the same authorized command: earlier intents
are queried, not resent, and remaining agents are dispatched only after those
outcomes are confirmed. A missing or ambiguous upstream receipt continues to
block later entries rather than triggering a blind resend.

The batch report exposes per-entry `submitted`, `unconfirmed`, `error`, and
`not_attempted` states plus summary counts and a reconciled count. Its exit code
is `0` after preview or all submissions, `1` when an outcome is unconfirmed, or
`2` for validation/preflight/interruption errors. It never claims task completion.
