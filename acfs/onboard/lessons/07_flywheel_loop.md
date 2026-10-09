# The Flywheel Loop

**Goal:** Understand how all the tools work together.

---

## The ACFS Flywheel

This isn't just a collection of tools. It's a **compounding loop**:

```
Plan (Beads) --> Coordinate (Agent Mail) --> Execute (herdr + Agents)
      ^                                              |
      |                                              v
      +---- Remember (CASS Memory) <---- Scan (UBS) +
```

Each cycle makes the next one better.

---

## The Nine Tools (And When To Use Them)

### 1. herdr - Your Cockpit
**Command:** `herdr`

Use it to:
- Spawn agent sessions
- Send prompts to multiple agents
- Orchestrate parallel work

### 2. MCP Agent Mail - Coordination
**Command:** `am` (starts server)

Use it when:
- Multiple agents need to share context
- You want agents to "talk" to each other
- Coordinating complex multi-agent workflows

### 3. UBS - Quality Guardrails
**Command:** `ubs`

Use it to:
- Scan code for bugs before committing
- Run comprehensive static analysis
- Catch issues early

```bash
ubs .  # Scan current directory
```

### 4. CASS - Session Search
**Command:** `cass`

Use it to:
- Search across all agent session history
- Find previous solutions
- Review what agents have done

```bash
cass  # Opens TUI
```

### 5. CASS Memory (CM) - Procedural Memory
**Command:** `cm`

Use it to:
- Build persistent agent memory
- Distill learnings from sessions
- Give agents context from past work

```bash
cm context "Building an API"  # Get relevant memories
cm reflect                     # Update procedural memory
```

### 6. Beads Viewer - Task Management
**Command:** `bv`

Use it to:
- Track tasks and issues
- Kanban view of work
- Keep agents focused on goals

```bash
bv  # Opens TUI
```

### 7. CAAM - Account Switching
**Command:** `caam`

Use it when:
- You hit rate limits
- You want to switch between accounts
- Testing with different credentials

```bash
caam status         # See current accounts
caam activate claude backup-account
```

### 8. DCG - Destructive Command Guard
**Command:** `dcg`

Use it to:
- Block dangerous commands before they execute
- Test risky commands with explanations
- Add a safety net for agents in vibe mode

```bash
dcg test "git reset --hard" --explain
```

### 9. SLB - Safety Guardrails
**Command:** `slb`

Use it for:
- Dangerous commands (when you want them reviewed)
- Two-person rule for destructive operations
- Optional safety layer

---

## A Complete Workflow

Here's how a real session might look:

```bash
# 1. Plan your work
bv --robot-triage               # Check tasks
br ready --json                 # See what's ready to work on

# 2. Start your agents (the loop and `agents` helper from lesson 5)
for spec in cc1:claude cc2:claude cod1:codex; do
  pane=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus |
    jq -r '.result.pane.pane_id')
  herdr agent start "myproject-${spec%%:*}" --kind "${spec#*:}" --pane "$pane"
done

# 3. Set context
cm context "Implementing user authentication" --json

# 4. Send initial prompt
for a in $(agents); do
  herdr agent prompt "$a" "Let's implement user authentication.
Here's the context: [paste cm output]"
done

# 5. Monitor and guide
herdr agent list                # Which agents are working, idle or done

# 6. Scan before committing
ubs .                           # Check for bugs

# 7. Update memory
cm reflect                      # Distill learnings

# 8. Close the task
br close <task-id>
```

---

## The Flywheel Effect

With each cycle:
- **CASS** remembers what worked
- **CM** distills reusable patterns
- **UBS** catches more issues
- **Agent Mail** improves coordination
- **herdr** sessions become more effective

This is why it's called a **flywheel** - it gets better the more you use it.

---

## Your First Real Task

You're ready! Here's how to start your first project:

```bash
# 1. Create project with ACFS (recommended!)
acfs newproj my-first-project --interactive

# This creates:
# - /data/projects/my-first-project
# - Git repository initialized
# - Beads (br) for task tracking
# - AGENTS.md with project guidance
# - Claude settings

# 2. Spawn your agents (from a herdr pane in the project)
cd /data/projects/my-first-project
for spec in cc1:claude cc2:claude cod1:codex agy1:agy; do
  pane=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus |
    jq -r '.result.pane.pane_id')
  herdr agent start "my-first-project-${spec%%:*}" --kind "${spec#*:}" --pane "$pane"
done

# 3. Start building!
for a in $(agents); do
  herdr agent prompt "$a" "Let's build something awesome.
What kind of project should we create?"
done
```

**Why `acfs newproj`?** It sets up everything agents need to work effectively,
including AGENTS.md which tells them about your project conventions.

For more details, run:

```bash
onboard 20
```

---

## Getting Help

- **`acfs doctor`** - Check everything is working
- **`herdr --help`** - herdr help
- **`onboard`** - Re-run this tutorial anytime

---

## Next

One final lesson: keeping everything updated.

```bash
onboard 8
```

Also recommended: learn how git works with multiple agents in `onboard 21`.

---

*The Agentic Coding Flywheel Setup - https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup*
