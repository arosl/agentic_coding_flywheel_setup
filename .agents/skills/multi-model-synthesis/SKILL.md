---
name: multi-model-synthesis
description: Merge competing plans from several models into one revised plan, crediting what each did better. Use in a plan-review round when you hold your plan plus other agents' or models' plans or reviews of it.
---

# Multi-model synthesis

jfp's `multi-model-synthesis` prompt. jfp ships with ACFS; the prompt is read from it, not copied here.

1. Read the prompt: `jfp show multi-model-synthesis --json | jq -r .content`.
2. Gather the competing plans or reviews (files under the round's plan directory, or Agent Mail messages) and apply the prompt to them.
3. Write the revision as a new version of the plan file, never over the old one, and say which input each change came from.
4. If jfp is missing, say so and stop; don't improvise the prompt.
