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
acfs palette
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

1. Open the palette: **Ctrl-b a** in herdr, or `acfs palette`
2. Select a prompt and press Enter (`ctrl-e` edits it first, `ctrl-n`
   writes a new message)
3. Pick who gets it: `1` every agent in this workspace, `2` and up one
   kind (claude, codex, ...), or `tab` to mark single agents. Each agent
   shows its herdr status (working, blocked, done) and a preview of its
   screen
4. Press Enter to send

`ctrl-p` pins a prompt to the top, `ctrl-f` marks it a favorite, and Esc
goes back a step.

### Option 2: Send Without The Menu (Power Move)

The non-interactive sender is `nhm send`, and `-t` takes a palette prompt by
its key:

```bash
# Send a one-off prompt to every agent in the session
nhm send myproject "Review the changes in src/ for edge cases"

# Send a palette prompt (keys: acfs palette --list)
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
~/.config/acfs/command_palette.md

# The one ACFS installs
~/.acfs/onboard/docs/ntm/command_palette.md
```

Use the installed file's format (`## Category`, then `### key | Label` and
the prompt text), and your prompts show up in the menu.

Ctrl-b a (`prefix+a` in herdr's config) is the default key.
`acfs palette bind --key prefix+space` picks another, and
`acfs palette unbind` removes it.

The key lives in the herdr config on your VPS. If you attach from your
laptop with `herdr --remote`, herdr uses your laptop's keys, so add
`--remote-keybindings server` to get Ctrl-b a:

```bash
herdr --remote <your-vps> --remote-keybindings server
```

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
acfs palette

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
