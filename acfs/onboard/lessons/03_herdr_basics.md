# herdr Basics

**Goal:** Never lose work when SSH drops, and see every agent at a glance.

---

## What Is herdr?

herdr is a **terminal workspace manager for coding agents**. It lets you:

1. Keep agents running after you disconnect
2. Split your terminal into panes, tabs and workspaces
3. See each agent's state (working, idle, done, blocked) in the sidebar

---

## Essential Commands

### Start or Reattach

```bash
herdr
```

The first run starts herdr's server and opens it. Every later run reattaches
to the same session, with everything still running.

### Detach (Leave Everything Running)

Press: `Ctrl+b` then `q`

Your agents keep working in the background.

---

## The Prefix Key

herdr's prefix key is `Ctrl+b`. Press it, let go, then press the action key.

Press `Ctrl+b` then `?` to see every key binding.

---

## Panes

| Keys | Action |
|------|--------|
| `Ctrl+b` then `v` | Split vertically |
| `Ctrl+b` then `-` | Split horizontally |
| `Ctrl+b` then `h/j/k/l` | Move between panes |
| `Ctrl+b` then `z` | Zoom the current pane |
| `Ctrl+b` then `x` | Close current pane |

---

## Tabs and Workspaces

| Keys | Action |
|------|--------|
| `Ctrl+b` then `c` | New tab |
| `Ctrl+b` then `n` | Next tab |
| `Ctrl+b` then `p` | Previous tab |
| `Ctrl+b` then `1-9` | Go to tab number |
| `Ctrl+b` then `w` | Pick a workspace |
| `Ctrl+b` then `Shift+n` | New workspace |

A workspace usually holds one project. Its tabs and panes hold your agents and
your own shell.

---

## Copy Mode (Scrolling)

| Keys | Action |
|------|--------|
| `Ctrl+b` then `[` | Enter copy mode |
| Use `PageUp/PageDown` or `j/k` | Scroll |
| `q` | Exit copy mode |
| `v` | Start selection |
| `y` | Copy selection |

---

## Try It Now

```bash
# Open herdr
herdr

# Split the screen
# Press Ctrl+b, then v

# Move to the new pane
# Press Ctrl+b, then l

# Run something
ls -la

# Detach
# Press Ctrl+b, then q

# Reattach: everything is still there
herdr
```

---

## Why This Matters for Agents

Your coding agents (Claude, Codex, Antigravity) run in herdr panes. herdr
detects each agent and shows in the sidebar whether it is working, waiting for
you, or done. ACFS also installs herdr's integration for each agent it
supports, which adds session restore or more exact state, depending on the
agent.

If SSH drops, they keep running. When you reconnect and run `herdr`, they're
still there!

---

## Prompting Agents From the Shell

`acfs agents send --name <agent> "<prompt>"` types a prompt into an agent and
checks that the agent took it. It exits non-zero and says why when it didn't:
no agent has that name, the agent is waiting at a question, or the prompt
stalled (nothing started working). On a stall it reads the agent's screen and
tells you whether a dialog is open or your text is still in the input box. It
never presses Enter for you.

In an idle Claude Code pane you may see a dim line such as
`❯ Check your Agent Mail inbox.` in the input box. That is Claude Code's
suggestion, made from your recent prompts, not a prompt waiting to be sent.
Pressing Enter on it does nothing. Only text in normal brightness was typed.

### From Outside herdr (cron, systemd units)

herdr's commands also work from a script that runs outside any pane:

- Plain `herdr agent list` reaches the default session, the one `herdr`
  opens.
- `herdr --session <name> agent list` reaches a named session. `--session`
  wins over a `HERDR_SOCKET_PATH` the script inherited.
- `herdr agent prompt` refuses an agent that is waiting at a question.
  Read its screen first (`herdr agent read <agent> --lines 60`), then answer
  with `herdr agent send-keys <agent> <keys>`.
- A finished turn is `done`, not `idle`. To wait for one, use
  `herdr agent prompt <agent> "<prompt>" --wait`.

---

## Next

Now let's meet your coding agents:

```bash
onboard 4
```
