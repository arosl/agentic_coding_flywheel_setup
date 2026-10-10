---
name: premortem-plan
description: Run a premortem on a plan: assume it failed six months out, find why, and revise the plan. Use when writing or revising a plan, or reviewing one in a plan-review round, before it is turned into beads.
---

# Premortem

jfp's `premortem-planner` prompt. jfp ships with ACFS; the prompt is read from it, not copied here.

1. Read the prompt: `jfp show premortem-planner --json | jq -r .content`.
2. Apply it to the plan you are working on, and write the failure modes and the revisions into the plan itself.
3. If jfp is missing, say so and stop; don't improvise the prompt.
