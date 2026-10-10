# Documentation log

Related: [index](index.md)

Append-only record of changes to durable knowledge. Each entry is a heading `## [YYYY-MM-DD] title`, so `grep '^## \[' docs/log.md` lists them. A new entry goes at the end: the order is the order entries were appended, which isn't strictly by date, and `grep '^## \[' docs/log.md | sort` lists them by date. A page that is added, moved, split or restructured gets an entry; a routine edit doesn't.

## [2026-10-09] A catalog and a log for docs/

The docs now have a catalog (`docs/index.md`) and this log. The catalog lists every page under `docs/`, one line each, and says that history is in git. The pages themselves are upstream ACFS's and are unchanged: they get no `Related:` line or scope paragraph, and nothing moved out of `README.md`, because each such edit would conflict at every upstream sync.

## [2026-10-10] The fork's divergence list moves out of AGENTS.md

`AGENTS.md` listed the known non-herdr divergences, the fork-only changes to upstream files, in its "Scope" section, and every agent read the list at startup. It is now `docs/operations/fork-divergences.md`, the first page under `docs/`, besides this log and the catalog, that is the fork's own, and "Scope" links to it (acfs-5f9).

## [2026-10-10] A runbook for moving a dev machine into an Incus swarm machine

`docs/operations/incus-swarm.md` is new and the fork's own. It says how to move a running ACFS dev machine, a VM or a VPS, into a container made by `scripts/providers/incus.sh`: host setup, a fresh install as the product test, a live copy and then a delta copy of `/data`, the logins moved with `acfs state export --move` and `import`, the restart, and the rollback. It holds no host-specific values. The guide, `scripts/providers/incus.md`, now also covers host setup, the swarm machine, the state layer, the Tailscale sidecar, the restricted test project and coexistence with podman (acfs-ioo3.12).

## [2026-10-10] ntm becomes herdr in the methodology, planning, audit and reference pages

The operator's ruling that all ntm becomes herdr reverses the earlier rule that upstream's pages under `docs/` stay unchanged, for these pages (acfs-6bv). Guidance and reference now name the fork's tools: herdr and `acfs agents spawn`, `send` and `list` in `methodology/THE_FLYWHEEL_APPROACH_TO_PLANNING_AND_BEADS_CREATION.md` and `THE_FLYWHEEL_CORE_LOOP.md`, `tools.herdr` in `reference/MANIFEST_SCHEMA_VNEXT.md` and `audits/manifest-gap-analysis.md`, and herdr in the two user-experience audits' recommendations. Records and quotations stay as written and carry a note saying what the fork uses instead: the X posts, the AGY cutover report and the three plans under `planning/`. A remaining ntm name there is upstream's history, or the command palette's path, `~/.acfs/onboard/docs/ntm/`. The swarm and fleet operations pages move with acfs-kch.
