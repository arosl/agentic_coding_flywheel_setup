# herdr: Your Agent Cockpit

**Goal:** Master herdr's agent commands for orchestrating agents.

---

## What Is herdr?

herdr is your **command center** for managing multiple coding agents.

It creates organized workspaces with dedicated panes for each agent.

---

## The herdr Help

herdr's agent commands document themselves. List them now:

```bash
herdr agent
```

Each command takes `--help` for its options.

---

## Essential herdr Commands

Run these from a herdr pane in your project directory.

### Check The Server

```bash
herdr status
```

Shows whether herdr's server is running, and its version.

### Start a Project's Agents

```bash
for spec in cc1:claude cc2:claude cod1:codex agy1:agy; do
  pane=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus |
    jq -r '.result.pane.pane_id')
  herdr agent start "myproject-${spec%%:*}" --kind "${spec#*:}" --pane "$pane"
done
```

This creates, in your current workspace:
- 2 Claude Code panes
- 1 Codex pane
- 1 Gemini pane

Agent names must be unique across herdr, so prefix them with the project.
herdr takes only lowercase names: a lowercase letter first, then lowercase
letters, digits, `-` or `_`, 32 characters at most. An agent that also has
an Agent Mail name (CamelCase, such as `IcyKnoll`) uses it lowercased in
herdr (`icyknoll`), so other agents can find it in both.

### When an Agent Isn't Ready

`herdr agent start` returns once herdr sees the agent ready for input. Two
things can still stand in the way:

- **A first-run dialog.** Codex asks "Trust this folder?" on its first run in
  a directory, and then "Hooks need review" for the hooks that dcg and herdr
  install. While a dialog is up, the agent is `blocked`: `agent start` fails
  with `agent_not_ready`, and `agent prompt` with `agent_blocked`, without
  typing anything. Look at the dialog, then answer it deliberately:

  ```bash
  herdr agent read myproject-cod1 --source visible   # what's on screen now
  herdr agent send-keys myproject-cod1 enter         # accept the highlighted choice
  ```

  Other key names include `esc`, `up`, `down` and `ctrl+c`.
- **A login screen.** A Claude or Codex that isn't logged in yet can look
  `idle`. It has started a real session only once herdr reports one:

  ```bash
  herdr agent get myproject-cc1 | jq '.result.agent.agent_session'   # null until then
  ```

### List Agents

```bash
herdr agent list
```

### Attach to a Workspace

```bash
herdr
```

Then press `Ctrl+b` then `w` and pick the workspace.

### Send a Command to All Agents

herdr sends to one agent at a time, so loop over the agents in your workspace:

```bash
# The agents in this workspace, optionally only one kind
agents() {
  herdr agent list | jq -r --arg ws "$HERDR_WORKSPACE_ID" --arg kind "${1:-}" \
    '.result.agents[] | select(.workspace_id == $ws and ($kind == "" or .agent == $kind)) | .pane_id'
}

for a in $(agents); do
  herdr agent prompt "$a" "Analyze this codebase and summarize what it does"
done
```

This sends the same prompt to **all** agents in the workspace!

### Send to Specific Agent Type

```bash
for a in $(agents claude); do herdr agent prompt "$a" "Focus on the API layer"; done
for a in $(agents codex); do herdr agent prompt "$a" "Focus on the frontend"; done
```

### Watch an Agent

```bash
# Read what an agent printed
herdr agent read myproject-cc1 --source recent-unwrapped --lines 50

# Wait until it is idle, done or waiting for you (10 minutes at most)
herdr agent wait myproject-cc1 --timeout 600000
```

`herdr agent list` shows each agent's state: `working`, `idle`, `done`,
`blocked` (waiting for your approval or answer) or `unknown`. A finished turn
is `done`, not `idle`, until you look at that agent, so wait without
`--until idle`: plain `herdr agent wait` matches idle, done and blocked.

---

## The Power of herdr

Imagine this workflow:

1. Spawn a session with multiple agents
2. Send a high-level task to all of them
3. Each agent works in parallel
4. Compare their solutions
5. Take the best parts from each

That's the power of multi-agent development!

---

## Quick Session Template

For a typical project, start the agents with the loop above:

```bash
for spec in cc1:claude cc2:claude cod1:codex agy1:agy; do
  pane=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus |
    jq -r '.result.pane.pane_id')
  herdr agent start "myproject-${spec%%:*}" --kind "${spec#*:}" --pane "$pane"
done
```

Why this ratio?
- **2 Claude** - Great for architecture and complex reasoning
- **1 Codex** - Fast iteration and testing
- **1 Gemini** - Different perspective, good for docs

---

## Workspace Navigation

Once inside a herdr workspace:

| Keys | Action |
|------|--------|
| `Ctrl+b` then `n` | Next tab |
| `Ctrl+b` then `p` | Previous tab |
| `Ctrl+b` then `h/j/k/l` | Move between panes |
| `Ctrl+b` then `z` | Zoom current pane |

---

## Try It Now

```bash
# Optional but recommended: build the CASS index once, so cass can
# search your past agent sessions. On a fresh install with no index,
# that search finds nothing.
#
# `cass index --full` has no bound/limit/since/timeout flag, so on a
# real, long-lived session history it can run for a very long time.
# Never run it inline here — it will block the rest of this
# walkthrough. Kick it off detached instead:
mkdir -p ~/.cache
nohup cass index --full --json > ~/.cache/cass-index-full.log 2>&1 &
disown
echo "cass index --full is running in the background."
echo "Check progress any time with: cass health --json   (see index.status)"
echo "Or: tail -f ~/.cache/cass-index-full.log"

# Start a test agent in a new pane
pane=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus |
  jq -r '.result.pane.pane_id')
herdr agent start test-cc --kind claude --pane "$pane"

# List agents
herdr agent list

# Send a simple task and wait for the answer (2 minutes at most)
herdr agent prompt test-cc "Say hello and confirm you're working" --wait --timeout 120000

# Read the result
herdr agent read test-cc --source recent-unwrapped --lines 40
```

> **CASS first run:** `cass --version` works the moment cass is
> installed, but the search-backed code paths need an initial index.
> `cass index --full` builds it —
> but the command has no bound/limit/timeout flag, so always run it
> backgrounded (see above) rather than waiting on it in the
> foreground. Poll `cass health --json` for `index.status: "fresh"`
> instead of waiting for the command to return.

---

## Next

The real power is in the command palette:

```bash
onboard 6
```
