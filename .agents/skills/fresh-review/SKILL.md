---
name: fresh-review
description: Re-read your own new or changed code with fresh eyes and fix what you find. Use after finishing a change and before committing it (the loop's Check step). Not for reviewing another agent's work; that is check-other-agents-work.
---

# Fresh review

The palette's `fresh_review` prompt, applied to your own change.

1. List what you changed: `git diff --stat -- <your files>`, plus any new files.
2. Read the prompt and follow it, over every changed file:

   ```bash
   sed -n '/^### fresh_review /,/^### /p' acfs/onboard/docs/ntm/command_palette.md
   ```

3. Run `ubs <changed files>` and fix what it reports.
4. Re-run the test that covers the change.
