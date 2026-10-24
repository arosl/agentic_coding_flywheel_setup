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
shell PID. By default, slots are assigned to the same native-agent types
(Claude or Codex, as launch takes) in the order the agents started: nhm's slot
`N.M`. A pane runs its agent when a foreground process has the agent type as
its name.

Only nhm launches, so recovery reads each agent's Agent Mail name and slot from
nhm's binding of its pane, never from a tab label (acfs-aahj, acfs-f2mc.5). nhm
puts up to six agents in one tab and names a shared tab after the project's
directory. Recovery asks nhm (`nhm resolve <pane> --json`, on the socket
`herdr status server` reports) and refuses:

- a pane without a binding, and a missing nhm;
- a binding that isn't active and verified, or doesn't match its pane, tab,
  workspace and repository;
- an nhm that can't answer.

A herdr name that was dropped (for example after a Codex context compaction)
is restored from the binding. A herdr name that differs from the agent's Agent
Mail name is refused, and each name must also be registered in Agent Mail under
the repository's project key (`am agents list`). The preview writes no files and
runs only read-only queries: herdr's `workspace list`, `agent list`,
`status server` and `pane process-info`, `nhm resolve` for each pane, and
`am agents list`. It never runs model commands, pane capture, renames or prompt
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

## Recover reordered agents, or a workspace with other agents

When the start order no longer gives the intended assignments, bind **every
saved launch slot** to its exact herdr pane. Other agents may then stay in the
launch's workspace, for example a helper started there by hand, and recovery
doesn't adopt them:

```bash
acfs swarm launch --recover --receipt /absolute/path/launch.json \
  --target 1:w2:p7 --target 2:w2:p3 --target 3:w2:p2
```

Slots are the positions in the intent's `request.agents`, starting at 1. Each
slot appears exactly once, with a distinct pane. The selected pane must run the
native agent type saved for that slot, in the saved repository; the right count
of each type is not enough. A partial mapping, an id that isn't a herdr pane id
(such as a tab id `w2:t3` or a tmux `%7`), a missing pane, a pane that runs
another process, and a duplicate or malformed identity are refused.

Review the returned `targets` and run its `adopt_command`, which keeps every
binding and the approval digest. Changing a binding, or switching between
`selection: "explicit"` and `selection: "layout"`, needs a new preview, even
when both give the same targets today. The order of the flags doesn't change
the digest, and neither does the order of herdr's agent list.

Only the selected agents are adopted and rechecked. The other agents get no
command or work, may be outside the repository, and may change their processes
without moving a saved slot. Every agent in the workspace is still checked for
a valid, distinct pane and terminal: a selection never hides a duplicate or
malformed identity. nhm's bindings are read for the selected panes only.
Without `--target`, recovery keeps its strict rule: the workspace holds exactly
the launch's agents.

## Wait for agents that are still starting

An agent may still be starting after the launcher's response was lost. Preview
with a bounded, read-only wait rather than running recovery again by hand:

```bash
acfs swarm launch --recover --receipt /absolute/path/launch.json --wait 60
```

`--wait` takes 0 to 300 seconds; 0, the default, is a single observation. A
positive value needs **two consecutive identical observations** of the agents'
identities. As in approval, an agent's state, such as an open dialog, isn't
part of them. An agent that herdr doesn't list yet, and a pane whose foreground
is still a startup shell (`bash`, `zsh`, `sh`, `dash`, `fish`), are retried.
Every selected pane must run its native agent before a preview is returned. The
preview reports `readiness_observations`. A running agent process doesn't prove
that the agent is logged in, that its model answers, or that its name is
registered.

One deadline covers every herdr, nhm and Agent Mail query and every pause.
`--timeout` still bounds each query, shortened to what is left of the wait.
These fail at once, never as a startup delay: more agents than the launch saved,
an agent of the wrong type or outside the repository, another process in a pane,
a duplicate or malformed identity, an unavailable herdr or nhm, a failed command
and invalid output. Every agent is checked before an incomplete workspace counts
as still starting. An intent changed during the wait, or a result published
meanwhile, voids the preview; no retained file is overwritten.

Waiting never writes a result or starts an agent. Review the final preview and
run its `adopt_command`, which **leaves out `--wait`**. `--adopt` with a positive
wait is refused before any query: approval applies to the exact identities
reviewed, not to later ones. A timeout is not permission to launch again or to
delete the original receipt.

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
separately.

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

Without `--target`, missing, extra, shell-only, wrong-repository or duplicate
agents, and duplicate terminals or shells, prevent recovery. With `--target`,
the agent, process and repository checks apply to the selected agents, and the
identity checks to every agent in the workspace. Unsafe receipt paths and non-private,
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
approval, lost and renamed names, nhm's bindings, concurrent-directory locks,
changing intents and agents, create-only result races, partial-result
preservation, explicit slot bindings, other agents in the workspace, startup
waits, stable observations, invalid inputs, output limits and shared deadlines.
Deterministic-clock tests cover each query's shrinking budget and a success that
arrives after the deadline. They do not start paid agents or certify a live
provider session.

Integration tests additionally reproduce a lost startup response through the
actual launcher, recover its saved workspace, and reconcile using only the
receipt, without a second spawn or any prompt send.
