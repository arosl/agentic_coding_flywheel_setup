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

```bash
less ~/.acfs/onboard/docs/ntm/command_palette.md
```

This opens the file with all available prompts.

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

### Option 1: Copy and Send

1. Open the palette: `less ~/.acfs/onboard/docs/ntm/command_palette.md`
2. Select a prompt
3. Copy it
4. Use `herdr agent prompt` or paste directly

### Option 2: Send From The Shell (Power Move)

herdr has no palette menu. The non-interactive sender is `herdr agent prompt`:

```bash
# Send a one-off prompt to one agent
herdr agent prompt myproject-cc1 "Review the changes in src/ for edge cases"

# Send it to every agent in the workspace (the `agents` helper from lesson 5)
for a in $(agents); do
  herdr agent prompt "$a" "Review the changes in src/ for edge cases"
done
```

Same battle-tested prompts, no menu: `herdr agent prompt` targets one agent by
name or pane ID, and `agents claude`, `agents codex` or `agents agy` picks
recipients by kind.

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

You can add your own prompts. Keep them in your own copy of the palette:

```bash
# Primary location
cp ~/.acfs/onboard/docs/ntm/command_palette.md ~/command_palette.md

# Or in your project directory
./command_palette.md
```

Add your prompts to that markdown file, and send them the same way.

---

## Pro Tips

1. **Start broad, then narrow** - Use high-level prompts first
2. **Combine agents** - Send different prompts to different agents
3. **Build on responses** - Use agent output in follow-up prompts
4. **Save good prompts** - Add working prompts to your custom palette

---

## Try It Now

```bash
# Open the palette
less ~/.acfs/onboard/docs/ntm/command_palette.md

# Browse the categories
# Select something interesting
# Try sending it to your test agent
herdr agent prompt test-cc "<the prompt>"
```

---

## Next

Now let's put it all together - the complete flywheel workflow:

```bash
onboard 7
```
