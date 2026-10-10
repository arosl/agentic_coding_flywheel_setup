---
name: de-slopify
description: Revise prose by hand to remove AI-slop tells (em dashes, "it's not X, it's Y", "here's why"). Use before committing a doc, README section, bead or mail text meant for people.
---

# De-slopify

jfp's `de-slopify` prompt. jfp ships with ACFS; the prompt is read from it, not copied here.

1. Read the prompt: `jfp show de-slopify --json | jq -r .content`.
2. Apply it line by line, by hand, to the text you wrote. Never with a script or a regex (project rule 11).
3. If jfp is missing, say so and stop; don't improvise the prompt.
