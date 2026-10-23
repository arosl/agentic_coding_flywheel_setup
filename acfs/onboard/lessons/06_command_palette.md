# The Command Palette

**Goal:** Discover the pre-built prompts that supercharge your agents.

---

## What Is The Command Palette?

ACFS ships with a **command palette** - a collection of battle-tested prompts
for common development tasks.

These aren't just prompts. They're carefully crafted instructions that get
the best results from coding agents.

---

## View The Palette

In herdr, press **Ctrl-b**, then **a**. Anywhere else:

```bash
nhm palette
```

This opens an interactive browser of all available prompts: type to filter,
and the preview shows the whole prompt. Pinned and recent prompts come
first.

---

## Palette Categories

The prompts are organized into categories:

### Architecture & Design
- System design analysis
- Architecture review
- API design patterns

### Code Quality
- Code review prompts
- Refactoring suggestions
- Bug hunting strategies

### Testing
- Test generation
- Coverage analysis
- Edge case discovery

### Documentation
- README generation
- API documentation
- Inline comment review

### Debugging
- Error analysis
- Performance profiling
- Memory leak detection

---

## Using Palette Prompts

### Option 1: Pick and Send

1. Open the palette: **Ctrl-b a** in herdr, or `nhm palette`
2. Select a prompt and press Enter (`ctrl-n` writes a new message instead)
3. Pick who gets it: `1` every agent in this workspace, a digit for one
   kind (`2` claude, `3` codex; the palette shows the others), or `6` to
   pick single agents (Space marks one, Enter sends). `e` edits the prompt
   first
4. Read the result: one line per agent, sent or refused

`ctrl-p` pins a prompt to the top, `ctrl-f` marks it a favorite, Esc goes
back a step, and `f1` shows every key.

### Option 2: Send Without The Menu (Power Move)

The non-interactive sender is `nhm send`, and `-t` takes a palette prompt by
its key:

```bash
# Send a one-off prompt to every agent in the session
nhm send myproject "Review the changes in src/ for edge cases"

# Send a palette prompt (keys: nhm palette --list)
nhm send myproject --cc -t fresh_review
```

Same battle-tested prompts, no menu: `nhm send` targets every agent of the
session but you by default, or use `--cc`, `--cod`, `--agy` or
`--name <agent>` to pick recipients. Agents blocked at a question are refused,
never answered.

---

## Example Prompts

Here are a few examples from the palette:

### Code Review
```
Review this code with an emphasis on:
1. Security vulnerabilities
2. Performance issues
3. Code readability
4. Edge cases not handled

For each issue, provide:
- The specific problem
- Why it matters
- A suggested fix
```

### Architecture Analysis
```
Analyze the architecture of this codebase:
1. Identify the main components
2. Map the data flow
3. Note any anti-patterns
4. Suggest improvements

Create a simple diagram if helpful.
```

---

## Customizing The Palette

You can add your own prompts. The palette reads, first key wins:

```bash
# In your project directory (or at its git root)
./command_palette.md

# Your own, for every project
~/.config/nhm/command_palette.md

# The one ACFS installs
~/.acfs/onboard/docs/ntm/command_palette.md
```

Use the installed file's format (`## Category`, then `### key | Label` and
the prompt text), and your prompts show up in the menu.

---

## The Palette, Board And Menu Keys

nhm binds three keys in herdr:

| Keys | Opens |
|------|-------|
| Ctrl-b a | The command palette, in a popup |
| Ctrl-b d | The agent board: this workspace's agents and their states, in a tab of its own |
| Ctrl-b m | The nhm menu: spawn, wake, retire and nhm's other commands, in a popup |

From a shell, `nhm palette`, `nhm board <session>` and `nhm menu` open the
same three.

The keys are set in `~/.config/nhm/config.toml`:

```toml
[keys]
palette = "prefix+a"   # the defaults
board   = "prefix+d"
menu    = "prefix+m"
```

Change one and run `nhm bind` to move it. `nhm bind --show` prints the
keys. `nhm bind --unbind` removes them, and `acfs update` then leaves them
removed until you run `nhm bind --force`.

The keys live in the herdr config on your VPS. If you attach from your
laptop with `herdr --remote`, herdr uses your laptop's keys. To get the
VPS's keys, attach with `--remote-keybindings server`:

```bash
herdr --remote <your-vps> --remote-keybindings server
```

Or run `nhm bind --print-client` on the VPS, and add the block it prints
to the herdr config on your laptop.

---

## Pro Tips

1. **Start broad, then narrow** - Use high-level prompts first
2. **Combine agents** - Send different prompts to different agents
3. **Build on responses** - Use agent output in follow-up prompts
4. **Save good prompts** - Add working prompts to your custom palette

---

## Try It Now

```bash
# Open the palette (or press Ctrl-b a in herdr)
nhm palette

# Browse the categories
# Select something interesting
# Send it to your test agent
```

---

## Next

Now let's put it all together - the complete flywheel workflow:

```bash
onboard 7
```
