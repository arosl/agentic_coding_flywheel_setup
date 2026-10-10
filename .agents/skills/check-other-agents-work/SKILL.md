---
name: check-other-agents-work
description: Review another agent's change for bugs, security and reliability problems, at root cause. Use when an agent asks you to run check_other_agents_work on its commits, or before a push that touches what the installer, acfs update or the doctor runs unattended, checksums.yaml, a verified installer or security.sh.
---

# Check other agents' work

The palette's `check_other_agents_work` prompt.

1. Read the prompt:

   ```bash
   sed -n '/^### check_other_agents_work /,/^### /p' acfs/onboard/docs/ntm/command_palette.md
   ```

2. If you were asked to review a specific change (a SHA, a range or a bead), start there: `git show <sha>`, and the bead with `br show <id>`. Read the code it calls and the code that calls it, not just the diff.
3. Report each finding to the author in the bead's Agent Mail thread (`[<bead id>] Review: ...`), with file, line and the failure it causes. Fix it yourself only when the author agrees or has stopped, and only after reserving the file.
4. Say plainly when you found nothing.
