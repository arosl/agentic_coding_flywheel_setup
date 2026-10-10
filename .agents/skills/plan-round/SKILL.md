---
name: plan-round
description: Run one plan-review round through apr: render the round's prompt for the reviewers, add apr's ChatGPT Pro review only when an Oracle host answers, collect the reviews and integrate them. Use when you plan or revise a plan (/data/tmp/acfs-plans/<plan>) and its next review round starts.
---

# Plan round

apr's revision prompt, `apr run <N> --render`; apr ships with ACFS. `plan_round.sh`, beside this file, runs the steps around it. A plan keeps its apr workflow beside it, in `/data/tmp/acfs-plans/<plan>/.apr`, whose `spec` is the plan's current version (`apr setup` there makes one).

1. Start the round: `.agents/skills/plan-round/plan_round.sh -C <plan-dir> start <N>`. It writes `.apr/round_<N>.bundle.md`, the prompt with the brief and the plan inlined. When `oracle` says the host in `$ORACLE_REMOTE_HOST` answers, it also starts apr's ChatGPT Pro review in the background; when not, it says why and skips it. Never wait for that review.
2. Give the bundle to the round's reviewers: heterogeneous ones, at least one Codex plan reviewer (the coordinator spawns it) and one fresh Claude agent. Each writes its whole review to `.apr/rounds/<workflow>/round_<N>.<reviewer>.md`.
3. When they're done: `plan_round.sh -C <plan-dir> collect <N>` writes `round_<N>.md` from the reviews there.
4. Integrate: `apr robot integrate <N>` (run in the plan directory) gives the integration prompt. Apply it, and write the result as the plan's next version, never over the old one; point the workflow's `spec` at it. Its prompt calls every review "APR reviewer model"; whose each one was is in `round_<N>.md`.
5. Before the next round, `apr robot stats` says whether the rounds converge, from round 2 on.
