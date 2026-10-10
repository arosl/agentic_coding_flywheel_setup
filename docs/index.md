# Documentation index

Related: [log](log.md)

The catalog of every documentation page, one line each, saying which questions the page answers. The pages describe the current state only; history is in git. Every page under `docs/` is upstream ACFS's, except this catalog, its log, `operations/fork-divergences.md` and `operations/incus-swarm.md`: where one names ntm, tmux or Docker, `README.md`, "About this fork", says what the fork installs instead.

## How to navigate

Start here, pick the one page whose line matches your question, and open only that page. `grep -n '^## ' <page>` lists a page's sections, and `rg -n -i -- '<term>' docs/` finds the page that holds a term. Where a page and the code disagree, the code decides, and the page is corrected. The pages are upstream's, so they don't open with a `Related:` line; adding one to each would conflict at every upstream sync.

## Entry points outside docs/

- `README.md`: what ACFS is, how to install it, what it installs, and how the fork differs ("About this fork"). Search it; never read it whole.
- `AGENTS.md` (with `CLAUDE.md`): the binding rules for anyone, human or agent, changing this repo.
- `acfs.manifest.yaml`: what ACFS installs, the single source of truth.
- [`operations/fork-divergences.md`](operations/fork-divergences.md) (the fork's own page): which upstream files the fork changes beyond the herdr port, Incus first and the supported platforms, and the bead behind each change.
- `.beads/`: the task queue, kept local and out of git, read and changed with `br`.

## Antigravity CLI (agy)

- [`AGY_MIGRATION_REFERENCE.md`](AGY_MIGRATION_REFERENCE.md): how `agy` maps onto the retired Gemini CLI: config schema, command mapping, and the model-pin contract.
- [`AGY_ROLLOUT_CUTOVER.md`](AGY_ROLLOUT_CUTOVER.md): how the switch from Gemini CLI to `agy` rolls out, and how `gmi` is retired.

## Operations: installer, upgrade and updater

- [`operations/ubuntu-upgrade.md`](operations/ubuntu-upgrade.md): how the opt-in Ubuntu upgrade works inside, and how to debug it.
- [`operations/ubuntu-entrypoint-migration.md`](operations/ubuntu-entrypoint-migration.md): which Ubuntu targets the upgrade entrypoint supports, and which checkpoints it preserves.
- [`operations/pinned-ref-installs.md`](operations/pinned-ref-installs.md): how to install ACFS reproducibly from a pinned ref.
- [`operations/offline-artifact-pack.md`](operations/offline-artifact-pack.md): what the verified installer entrypoint cache holds, and its contract.
- [`operations/architecture-audit.md`](operations/architecture-audit.md): how module binaries are checked for the host's architecture before they run.
- [`operations/installer-transcript.md`](operations/installer-transcript.md): how to explain a failed installer transcript locally.
- [`operations/updater-locking.md`](operations/updater-locking.md): how `acfs update` keeps to one instance per target home.
- [`operations/incus-swarm.md`](operations/incus-swarm.md) (the fork's own page): how to move a running dev machine, VM or VPS, into an Incus swarm machine with its data and logins, and how to roll back.
- [`operations/updater-pin-recovery.md`](operations/updater-pin-recovery.md): what to do when a downloaded installer doesn't match its pin.
- [`operations/config-restore.md`](operations/config-restore.md): how to restore an exported module selection on a new machine.
- [`operations/postgresql.md`](operations/postgresql.md): how the PostgreSQL 18 module installs and runs on supported Ubuntu LTS hosts.
- [`operations/process-storm-watchdog.md`](operations/process-storm-watchdog.md): how the installer's process-storm watchdog decides to stop a run.
- [`operations/capacity-process-limits.md`](operations/capacity-process-limits.md): how `acfs capacity` sizes against the current process's resource limits.
- [`operations/UPGRADE_LOG.md`](operations/UPGRADE_LOG.md): which JS dependencies the 2026-01-24 upgrade moved.

## Operations: wizard, first project and team profiles

- [`operations/guided-first-project.md`](operations/guided-first-project.md): how a beginner creates a first project with the terminal guide.
- [`operations/project-bootstrap.md`](operations/project-bootstrap.md): how the reviewed first-project bootstrap works after installation.
- [`operations/doctor-report-review.md`](operations/doctor-report-review.md): how the wizard diagnoses a doctor JSON report locally.
- [`operations/team-profile-import.md`](operations/team-profile-import.md): how the wizard reviews a shared team profile.
- [`operations/team-profile-schema.md`](operations/team-profile-schema.md): the schema of a redacted, portable team profile.
- [`operations/agent-profile-rehearsal.md`](operations/agent-profile-rehearsal.md): how to rehearse isolated agent profiles before a multi-account workspace.
- [`operations/provider-provisioning-packet.md`](operations/provider-provisioning-packet.md): the provider-agnostic VPS provisioning packet contract.
- [`operations/GUIDE_TO_REDUCING_VERCEL_USAGE.md`](operations/GUIDE_TO_REDUCING_VERCEL_USAGE.md): how upstream cut Vercel credit use for the wizard site.

## Operations: plugins

- [`operations/plugin-manifest-contract.md`](operations/plugin-manifest-contract.md): the v1 plugin package schema and trust policy.
- [`operations/plugin-authoring.md`](operations/plugin-authoring.md): how to build a reproducible ACFS plugin package.
- [`operations/plugin-review-workflow.md`](operations/plugin-review-workflow.md): how a plugin is verified and installed for a target user.
- [`operations/plugin-health.md`](operations/plugin-health.md): how to check installed plugins without reinstalling them.

## Operations: swarm planning and launch

- [`operations/swarm-launch-admission.md`](operations/swarm-launch-admission.md): how the queue-aware planner admits or refuses a swarm launch.
- [`operations/swarm-plan-snapshot-replay.md`](operations/swarm-plan-snapshot-replay.md): how to replay swarm admission from saved evidence.
- [`operations/swarm-assignment-scopes.md`](operations/swarm-assignment-scopes.md): how swarm assignments account for file contention.
- [`operations/swarm-resource-isolation.md`](operations/swarm-resource-isolation.md): the research and decision on optional resource isolation for large hosts.
- [`operations/swarm-capacity-inventory.md`](operations/swarm-capacity-inventory.md): the design of the local multi-host capacity inventory.
- [`operations/swarm-launch.md`](operations/swarm-launch.md): how to start native agents with admission and a durable launch intent.
- [`operations/swarm-launch-recovery.md`](operations/swarm-launch-recovery.md): how to recover an unconfirmed agent launch without starting it again.
- [`operations/swarm-packet-preparation.md`](operations/swarm-packet-preparation.md): how to prepare a scoped handoff of per-agent work packets.
- [`operations/swarm-packet-delivery.md`](operations/swarm-packet-delivery.md): how to deliver a reviewed work packet to an existing agent.

## Operations: swarm fleets

- [`operations/fleet-runtime.md`](operations/fleet-runtime.md): how to install the fleet controllers without keeping a checkout.
- [`operations/swarm-fleet-placement.md`](operations/swarm-fleet-placement.md): how to place a target swarm across recorded host capacity.
- [`operations/swarm-fleet-probe.md`](operations/swarm-fleet-probe.md): how to refresh a fleet's capacity before placement.
- [`operations/swarm-fleet-launch.md`](operations/swarm-fleet-launch.md): how to run a reviewed multi-host agent launch.
- [`operations/swarm-fleet-preparation.md`](operations/swarm-fleet-preparation.md): how to prepare a fleet's work from one controller.
- [`operations/swarm-fleet-preparation-recovery.md`](operations/swarm-fleet-preparation-recovery.md): how fleet preparation admits dependencies and recovers.
- [`operations/swarm-fleet-dispatch.md`](operations/swarm-fleet-dispatch.md): how to send reviewed work to an existing fleet.
- [`operations/swarm-fleet-status.md`](operations/swarm-fleet-status.md): how to observe a launched fleet without sending more work.
- [`operations/swarm-fleet-collection.md`](operations/swarm-fleet-collection.md): how to bring committed fleet work back for review.
- [`operations/swarm-fleet-integration.md`](operations/swarm-fleet-integration.md): how to combine collected histories without changing your checkout.
- [`operations/swarm-fleet-resolutions.md`](operations/swarm-fleet-resolutions.md): how to resolve conflicting fleet contributions.
- [`operations/swarm-fleet-testing.md`](operations/swarm-fleet-testing.md): how to test the exact combined fleet result.
- [`operations/swarm-fleet-promotion.md`](operations/swarm-fleet-promotion.md): how to promote an exactly tested fleet candidate.
- [`operations/swarm-fleet-publication.md`](operations/swarm-fleet-publication.md): how to publish the tested candidate to an explicit Git destination.

## Reference

- [`reference/MAINTAINER_GUIDE.md`](reference/MAINTAINER_GUIDE.md): how to maintain the installer and the manifest.
- [`reference/MANIFEST_SCHEMA_VNEXT.md`](reference/MANIFEST_SCHEMA_VNEXT.md): the fields of `acfs.manifest.yaml`, their validation rules, and the maintainer workflows.

## Tools

- [`tools/README.md`](tools/README.md): which tools have pages in `docs/tools/`.
- [`tools/beads_rust.md`](tools/beads_rust.md): how to use `br`, the issue tracker.
- [`tools/brenner_bot.md`](tools/brenner_bot.md): how to use `brenner`, the research session manager.
- [`tools/meta_skill.md`](tools/meta_skill.md): how to use `ms`, the local knowledge base with semantic search.
- [`tools/rch.md`](tools/rch.md): how to use `rch`, the remote compilation helper.
- [`tools/utilities.md`](tools/utilities.md): the optional utility tools ACFS installs.

## Tests

- [`tests/coverage_matrix.md`](tests/coverage_matrix.md): which real-data coverage the tests aim for, with no mocks.
- [`tests/fixtures_catalog.md`](tests/fixtures_catalog.md): which existing files the tests use as real fixtures.

## Methodology (long; search, never read whole)

- [`methodology/THE_FLYWHEEL_CORE_LOOP.md`](methodology/THE_FLYWHEEL_CORE_LOOP.md): the beginner's version of the flywheel method, built on its three main tools.
- [`methodology/THE_FLYWHEEL_APPROACH_TO_PLANNING_AND_BEADS_CREATION.md`](methodology/THE_FLYWHEEL_APPROACH_TO_PLANNING_AND_BEADS_CREATION.md): the full method: markdown planning, beads, and coordinated agent swarms.
- [`methodology/COMPLETE_X_POSTS_ABOUT_PLANNING_AND_BEADS.md`](methodology/COMPLETE_X_POSTS_ABOUT_PLANNING_AND_BEADS.md): the source posts the method was written from.

## Planning (historical plans)

- [`planning/PLAN_TO_CREATE_ACFS.md`](planning/PLAN_TO_CREATE_ACFS.md): the original plan for ACFS.
- [`planning/PLAN_TO_HAVE_SINGLE_SOURCE_OF_TRUTH_MANIFEST.md`](planning/PLAN_TO_HAVE_SINGLE_SOURCE_OF_TRUTH_MANIFEST.md): the superseded plan for the manifest-driven architecture.
- [`planning/ROADMAP_INSTALLER_RELIABILITY.md`](planning/ROADMAP_INSTALLER_RELIABILITY.md): the installer reliability and UX roadmap.
- [`planning/ROOT_AGENTS_MD_PLAN.md`](planning/ROOT_AGENTS_MD_PLAN.md): the planned outline of a root `/AGENTS.md` on the VPS.
- [`planning/TODO_GUIDE_REDESIGN.md`](planning/TODO_GUIDE_REDESIGN.md): the to-do list for the wizard guide redesign.
- [`planning/tui-wizard-design.md`](planning/tui-wizard-design.md): the flow and screens of the `newproj` TUI wizard.

## Research

- [`research/cass-session-format-research.md`](research/cass-session-format-research.md): which agent session formats CASS reads, and how.
- [`research/codex-auth-research.md`](research/codex-auth-research.md): how the Codex CLI authenticates.
- [`research/tui-research.md`](research/tui-research.md): which patterns the onboarding TUI was built on.

## Audits

- [`audits/STEP_BY_STEP_AUDIT_OF_USER_EXPERIENCE.md`](audits/STEP_BY_STEP_AUDIT_OF_USER_EXPERIENCE.md): the first beginner walk-through audit of the install experience.
- [`audits/STEP_BY_STEP_AUDIT_OF_USER_EXPERIENCE__ROUND_2.md`](audits/STEP_BY_STEP_AUDIT_OF_USER_EXPERIENCE__ROUND_2.md): the second round of that audit.
- [`audits/manifest-gap-analysis.md`](audits/manifest-gap-analysis.md): how `install.sh` maps onto `acfs.manifest.yaml`, and where they differ.
