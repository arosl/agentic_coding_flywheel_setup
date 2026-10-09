# Recover an unconfirmed native-agent launch without starting it again

A lost response or an interruption during startup can leave native agents
running while the ACFS launch intent has no `.result.json`. Retrying the normal
launch deliberately does not spawn again. Recovery provides an explicit way to
adopt the agents currently in the launch's herdr workspace and restore the
result needed for work packet preparation.

The installed entrypoint is:

```bash
acfs swarm launch --recover --receipt /absolute/path/launch.json
```

Recovery looks for **exactly one** herdr workspace whose label is the launch's
own, `swarm-<session>-<first 12 hex of the review hash>`. None or more than one
is refused.

Inspect every proposed slot, agent type, Agent Mail name, pane, terminal and
shell PID. Slots are assigned to the same native-agent types in tab creation
order, which the launcher's one-at-a-time start made the slot order. Each
agent's Agent Mail name is read from its tab label, where `acfs agents spawn` put
it. A herdr name that was dropped (for example after a Codex context compaction)
is restored from the tab label; a renamed tab, or a herdr name that differs from
its tab's label, is refused rather than guessed. The preview writes no files and
runs only read-only herdr queries (`workspace list`, `tab list`, `agent list`,
`pane process-info`), never model commands, pane capture, renames or prompt
delivery.

To adopt exactly those observed identities, repeat with the **recovery** digest:

```bash
acfs swarm launch --recover --receipt /absolute/path/launch.json \
  --adopt --expect-sha256 RECOVERY_PREVIEW_DIGEST
```

This digest is different from the original launch approval. It binds the
original intent bytes, saved request, observed agent identities and recovery
policy. An agent's state, such as a dialog answered between preview and
adoption, is not part of it. Changing a pane, tab, terminal, shell, workspace,
request, or policy requires a new preview. The topology is rechecked before
result publication and again afterward. The same receipt-directory lock used by
normal launch prevents cooperating launch/recovery operations from racing.

## Reconcile a saved launch using only its receipt

```bash
acfs swarm launch --reconcile --receipt /absolute/path/launch.json
```

This reads the original saved repository, session, agent identities and options,
then verifies the recorded agents through herdr. It does not need the original
launch arguments and never calls admission, spawn, rename or prompt delivery. An
adopted result retains its explicit recovery provenance in this report. A
missing result returns an unconfirmed status and a recovery preview command;
reconciliation does not adopt anything automatically. Changed or invalid results
remain preserved.

After a ready result, prepare work using the existing scoped handoff; each slot's
Agent Mail identity defaults to the recorded one:

```bash
acfs swarm launch --prepare-batch ./work-bundle \
  --receipt /absolute/path/launch.json --scopes-file ./scopes.json
```

Preparing packets does not send them; review the returned dispatch preview
separately. Until acfs-qzc (K5) lands, the installed packet preparer still expects
tmux pane IDs and refuses herdr ones.

Fresh installs and runtime updates distribute the recovery helper beside the
native launcher under the canonical internal-checksum contract. A missing or
symlinked helper fails closed; the launcher never searches PATH for a substitute.
For checkout use, invoke `bash scripts/lib/swarm_launch.sh --recover` or the
standalone `python3 -B scripts/lib/swarm_launch_recovery.py` with the same flags.

## What adoption does and does not prove

Adoption confirms that the reviewed live agents match the saved repository,
agent count, native-agent mix and the launch's workspace. **It does not prove
that the original spawn started those agents.** The operator explicitly approves
using them. Both the report and the saved recovery provenance retain
`original_launch_verified: false`.

A successful adoption creates only the missing private result, in the existing
`acfs.swarm-launch.v2` format, with recovery provenance
`acfs.swarm-launch-recovery.v2`. Normal launch reconciliation and packet handoff
can consume that result. Keep the original intent. No agents are started,
stopped, interrupted, renamed or given work; no Beads or Agent Mail state is
changed.

Existing results (including malformed files, directories and dangling symlinks)
are never overwritten. Interrupted publication may leave a partial result that
must be preserved for inspection. Recovery does not erase evidence to enable
another attempt. A result that already exists should go through ordinary launch
reconciliation, not adoption.

Missing, extra, shell-only, wrong-repository or duplicate agents, and duplicate
terminals or shells, prevent recovery. Unsafe receipt paths and non-private,
symlinked, hardlinked or special-file intents are rejected, and so is an
ntm-era `acfs.swarm-launch.v1` intent. Input and observation sizes are bounded
to 1 MiB. `--timeout` bounds each herdr query to 1-30 seconds (default 10); raw
herdr errors are not copied into reports.

Exit 0 means a valid preview or successful adoption. Exit 1 means a result was
created but the final live recheck could not confirm it; retain that result and
use normal reconciliation. Exit 2 means recovery was refused or unavailable.
An interruption returns 130 and never authorizes a duplicate launch.

## Tests

```bash
python3 -B -m unittest discover -s tests/unit -p 'test_swarm_launch_recovery*.py' -v
```

The tests execute the real recovery CLI against a local read-only herdr contract
fixture. They cover successful handoff-compatible results, identity-bound
approval, lost and renamed names, concurrent-directory locks, changing intents
and agents, create-only result races, partial-result preservation, invalid
inputs, output limits and deadlines. They do not start paid agents or certify a
live provider session.

Integration tests additionally reproduce a lost startup response through the
actual launcher, recover its saved workspace, and reconcile using only the
receipt, without a second spawn or any prompt send.
