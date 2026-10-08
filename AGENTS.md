# Agentic Coding Flywheel Setup (ACFS): agent instructions

This repository is a fork of upstream ACFS ([Dicklesworthstone/agentic_coding_flywheel_setup](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)). ACFS takes a beginner from "I have a laptop" to an Ubuntu VPS set up for agentic coding. It has three parts, all driven by one manifest, `acfs.manifest.yaml`: a wizard website (`apps/web/`), a one-line, idempotent Bash installer (`install.sh` and `scripts/`), and an onboarding TUI (`packages/onboard/`). The fork changes the toolset: herdr instead of tmux, ntm and wezterm_automata, and no Docker (Incus is planned). `README.md`, "About this fork", says what else differs.

This file is also `CLAUDE.md` (a symlink), so every agent reads the same instructions. It is the fork's own file, not upstream's: see "Upstream sync" under "Project rules".

How agents work together here currently follows agentharness: the block below and the "Coordination" section. That is the way of working for now, not a dependency. Nothing the installer, the scripts or the tests run needs it, and a better system, possibly one built in this project, replaces those two places in one edit.

<!-- agentharness:begin -->
## Shared practices: agentharness

This repo follows **agentharness**, the home of the shared practices for the repos on this host. If the agentharness skill is installed, load it. Otherwise read the pages below in the agentharness repository.

- **The rules every change and every brief here is held to:** `agentharness/docs/code-rules.md`, on how to change code, review it and test it. They apply here in full. Read the page in full before your first change, review or brief, and never write a brief that asks for anything it forbids.

The rest is reference. Read it when your task needs it.

- **How the docs are laid out and kept current:** `agentharness/docs/doc-structure.md`. Those rules apply here in full too.
- **How agents work together here:** `agentharness/docs/README.md`. It starts with what agentharness asks of a repo, in priority order, then covers br, Agent Mail, herdr, roles, briefs, routing and hazards.
- **What this repo must contain, and how to keep it current:** `agentharness/docs/client.md`, `agentharness/docs/adopt.md` and `agentharness/docs/CHANGELOG.md`.

The sections after this block are this project's own rules. Where they're stricter than agentharness, they win. The marker below records the last agentharness practice this repo has adopted; `adopt.md` says how to bring it up to date.

<!-- agentharness:adopted 2026-10-06.6 -->
<!-- agentharness:end -->

## Project rules

1. **The repo is public.** No host-specific content goes into a committed file or a commit message: no home-directory paths, hostnames, email addresses, Agent Mail content or credentials. Commits use the GitHub noreply author that the clone already has set. The bead queue stays local for the same reason ("Coordination", "Beads").
2. **Dates and times.** ISO 8601 everywhere. Instants are stored in UTC and shown in `UTC`. A date-only value stays date-only.
3. **Upstream sync.** Upstream's own instruction file is read with `git show upstream/main:AGENTS.md`, and never kept in the tree. When an upstream merge conflicts in `AGENTS.md`, keep ours (`git checkout --ours AGENTS.md`). Then read `git diff <merge-base> upstream/main -- AGENTS.md`, and port each new project fact into the section of the same name below, by hand. Never use a `merge=ours` driver: it drops upstream's facts without anyone seeing them. Rules taken from upstream keep upstream's section names, so that a hunk maps to one section.
4. **`main` only.** Work, branches and merges target `main`. Never reference `master` in code or docs.
5. **What ACFS installs is `acfs.manifest.yaml`,** the single source of truth. Never keep a second list of tools in a doc or in this file.
6. **Bun for everything JS/TS** in the project's scripts and docs, never npm, yarn or pnpm. `bun.lock` is the only lockfile. `bun install -g <pkg>` is valid syntax (an alias for `bun add -g`), so don't "fix" it.
7. **Bash for the installer and scripts,** checked with shellcheck (`.shellcheckrc` lists the disabled checks). The installer targets Ubuntu LTS and Arch-family. It keeps a supported 22.04 or 24.04 host on its release, and upgrades only on `--target-ubuntu=26.04`, which `--skip-ubuntu-upgrade` suppresses. It is idempotent and checkpointed: safe to re-run, and its phases resume after a failure. The upgrade path is in `docs/operations/ubuntu-upgrade.md`.
8. **Installer output goes through `scripts/lib/logging.sh`,** to stderr, so stdout stays clean for piping. `--quiet` suppresses progress, never errors.
9. **Revise files in place.** Never add variations such as `install_v2.sh` or `install_improved.sh`. A new file is only for functionality that fits in no existing file.
10. **No backwards-compatibility shims.** There are no users to keep compatible, so fix the code directly, and don't wrap a deprecated API.
11. **No script-based code changes.** Never run a script or a regex over code files to change them; brittle mass rewrites cost more than they save. Make each change by hand, and split many simple edits across agents. This is stricter than agentharness.
12. **A third-party library you aren't sure of:** read its current documentation online before using it.

### Components

| Component | Location |
|---|---|
| Wizard website (Next.js App Router, Tailwind, shadcn/ui; state in URL params and localStorage, no backend; step content in `lib/wizardSteps.ts`) | `apps/web/` |
| Installer | `install.sh`, `scripts/lib/` |
| Onboarding TUI | `packages/onboard/` |
| Module manifest | `acfs.manifest.yaml` |
| Manifest parser and generators | `packages/manifest/` |
| Files installed to `~/.acfs/` on the VPS. `acfs/AGENTS.md` among them is the template ACFS installs for projects on the VPS: product, not this repo's instructions | `acfs/` |
| Tests: `tests/vm/` (installer in a container), `tests/e2e/`, `tests/unit/`, `tests/smoke/`, `scripts/tests/` (script-level checks), `apps/web/e2e/` (Playwright) | `tests/`, `scripts/tests/`, `apps/web/e2e/` |

The architecture, the manifest system, the installer's phases and modes, and the `acfs` CLI are described in `README.md`.

### Generated Files — NEVER Edit Manually

Everything in `scripts/generated/` is generated from the manifest: the category installers, `install_all.sh`, `doctor_checks.sh`, `internal_checksums.sh` and `manifest_index.sh`. An edit there is overwritten on the next regeneration. Change the generator (`packages/manifest/src/generate.ts`) or the manifest instead, regenerate with `bun run generate` in `packages/manifest`, then shellcheck the output.

### Verified Installer Checksum Discipline

`checksums.yaml` is a security boundary for every manifest module that installs through `verified_installer`.

- **Whenever a tool installed through `verified_installer` changes or releases,** run the canonical refresh and review the diff, even when you expect the installer script's hash to stay the same. A version bump isn't done while its checksum is stale. Never hand-edit a checksum:

  ```bash
  candidate="/tmp/acfs-checksums.$$.candidate.yaml"
  ./scripts/lib/security.sh --update-checksums > "$candidate"
  diff -u checksums.yaml "$candidate" || [[ $? -eq 1 ]]
  ```

  Never redirect the updater straight onto `checksums.yaml`: the redirect truncates it first, and one failed fetch leaves it empty.
- **Unrelated entries changed too:** stop and investigate before replacing `checksums.yaml`, even if the target entry changed as well.
- **Only the timestamp header and the target entry changed:** replace `checksums.yaml` with the candidate.
- **Only the timestamp header changed:** leave `checksums.yaml` as it is.
- `./scripts/lib/security.sh --checksum <installer-url>` prints one installer's current hash.

## Scope

The fork tracks upstream ACFS and changes its toolset: herdr instead of tmux, ntm and wezterm_automata, and no Docker.

- **Deploys as:** nothing from this repo. Users run `install.sh` on their own VPS, through the one-liner that fetches it from GitHub, and the fork has no deployment of its own; upstream deploys the wizard website (`apps/web/`) to Vercel.
- **Deferred** (don't build, don't scaffold): Incus in place of the removed Docker modules and of the Docker-based `tests/vm/`.
- **Rejected** (2026-10-08; not to be built or reopened): Docker and lazydocker; tmux, ntm and wezterm_automata, which herdr replaces. The reasons: `README.md`, "About this fork".

## Commands and gates

- **Tests (own area, from a worktree):** in `packages/manifest`, `(umask 022; npm exec --yes bun -- test)`. For shell code, run the `tests/unit/` or `scripts/tests/` script that covers what you changed, with a throwaway home: `HOME="$(mktemp -d)" bash tests/unit/test_policy_lint.sh`. <!-- acfs-policy-lint: allow toolchain.bun_only (npm only fetches bun) -->
- **Full gate (the integrator runs it on the merged tree):** each of these, from the repo root:
  - `cd packages/manifest && npm exec --yes bun -- run generate:validate && npm exec --yes bun -- run generate --diff && (umask 022; npm exec --yes bun -- test)`; <!-- acfs-policy-lint: allow toolchain.bun_only (npm only fetches bun) -->
  - `bash scripts/lib/policy_lint.sh` and `bash scripts/tests/lint_rch_offload_policy.sh`;
  - CI's shellcheck job (`.github/workflows/installer.yml`): `git ls-files -z '*.sh' | xargs -0 shellcheck`, then each script it runs after that, with `HOME="$(mktemp -d)"`. On `main` at `16a201ec`, before any fork change, shellcheck 0.9.0 warns in `tests/unit/test_offline_artifact_pack_builder.sh` and `tests/unit/test_ubuntu_lts_runtime.sh`, and `scripts/tests/lint_declare_scoping.sh`, `tests/unit/test_release_doctor.sh` and `scripts/tests/ubuntu_upgrade_test.sh` fail. A branch must not add to that list;
  - `apps/web`: `bun run type-check`, `bun run lint`, `bun run build` and `bun run test`, from `apps/web`. Not run on this host yet, because `apps/web` has no `node_modules` here.
- **Heavy tests (opt-in):** none that run in the fork. Upstream's `tests/vm/test_install_ubuntu.sh` runs the whole installer in Docker, which the fork drops, and its Incus replacement is deferred. Upstream's external `automated_flywheel_setup_checker` isn't available to the fork.
- **Formatters and linters:** shellcheck with `.shellcheckrc`, which CI installs from the runner's apt archive, unpinned (0.9.0 on Ubuntu 24.04, checked 2026-10-08; 0.11.0 adds 382 SC2329 notes, so bumping it is a gate change); TypeScript 5.9.3 and eslint 9.39.2 (`apps/web/eslint.config.mjs`), pinned in `bun.lock`. Nothing else formats this tree, and nothing formats on save.
- **Running from a worktree:** a worktree has no `node_modules`. Run `npm exec --yes bun -- install --frozen-lockfile --filter '@acfs/manifest'` at its root first. Where bun isn't installed, run it as `npm exec --yes bun -- …` (CI uses `bun-version: latest`, so bun is unpinned). Under a umask of `0002`, the plugin-pack tests in `packages/manifest` fail, because the packer refuses group-writable files, so run them with `umask 022`. <!-- acfs-policy-lint: allow toolchain.bun_only (npm only fetches bun) -->
- **Pre-commit hook:** agentharness's shared hook, enabled per clone through `core.hooksPath`. It runs the checks in `.agentharness-precommit` on the staged files, plus the Agent Mail reservation guard.

## Docs

- **Catalog:** none yet. `docs/` has no `index.md` or log; a bead tracks adding them.
- **At session start, read only:** this file.
- **Search, don't read whole:** `rg -n -i -- '<term>' docs/ README.md`. Never read `README.md` or the pages in `docs/methodology/` whole; each runs to about a thousand lines or more.

## Coordination

This is the current way of working: agentharness's wave method, with br, Agent Mail and herdr, as the block above describes. A successor replaces this section and that block. Nothing in the product reads either, with one coupling to keep or change: `scripts/lib/policy_lint.sh` requires this file to mention Agent Mail and file reservations.

- **Staffing:** a wave. `scarletfern` coordinates and never builds; implementation goes to workers it briefs (agentharness `docs/roles.md`)
- **Agent Mail project key:** the main checkout's absolute path, also from a worktree. Reserve files in Agent Mail before you edit them (`file_reservation_paths`, with the bead id as the reason), and release them when you're done.
- **Worktrees:** `<main checkout>-wt/<herdr name>`, one per agent
- **Worktree lifetime:** one bead at a time, each on a fresh branch from current `main`; reused only once the merged branch is deleted and nothing is uncommitted, and removed by the integrator after its agent's last bead
- **herdr workspace:** label `agentic_coding_flywheel_setup`; always pass `--workspace` explicitly
- **Waker:** `herdr-agent-waker@agentic_coding_flywheel_setup.service`, configured by `~/.config/agentharness/agentic_coding_flywheel_setup.env`
- **Beads:** change only from the main checkout, by the coordinator (claims) and the integrator (closes). The queue is local-only: `.beads/` is untracked, and its `.gitignore` is `*`. agentharness's `beads` part commits the export, but br writes the local user name and checkout path into every bead, and this repo is public (the operator's ruling, 2026-10-08). So no bead write is ever committed, and a worktree has no `.beads/`.
- **Priorities:** P0 a broken install or update on users' machines, or a hole in the checksum boundary; P1 what blocks the current wave or the next upstream sync; P2 the fork's other planned work; P3 is the default and P4 conditional, as everywhere (agentharness `docs/primitives.md`)
- **Review tiers:** PUSH, LIGHT or FULL per bead (agentharness `docs/tiers.md`); the brief states it with the FULL criterion it trips, or none. FULL only on a named criterion, never on doubt. FULL here also covers: a change to what the installer, `acfs update` or the doctor runs unattended on a user's machine; a change to `checksums.yaml`, a verified installer, or `scripts/lib/security.sh`

## Hard limits

- **No file deletion without express permission.** Never delete a file or folder, even one you created yourself, without a clear, written yes first. This is stricter than agentharness.
- **Irreversible git and filesystem commands are forbidden** (`git reset --hard`, `git clean -fd`, `rm -rf`, or anything else that can delete or overwrite code or data), unless the operator gives the exact command and says, in the same message, that they want its irreversible effect. Restate the command and what it affects, and wait for confirmation before you run it.
- **Never run `install.sh`, `acfs update` or any install step against the machine you develop on.** It replaces the live tools that the other agents there use. Test the installer only on a disposable machine.
- Never commit with `--no-verify`. If a check is wrong or slow, fix the check. `AGENT_MAIL_BYPASS=1` skips only the reservation guard, and only with the operator's OK.
- **Read-only toward:** upstream ACFS on GitHub (fetched, never pushed to), and the third-party installers that `checksums.yaml` pins (fetched to verify, never written).
- Host installs, unit changes and pushes happen only on the operator's word, or under a standing authorization the operator gave, named here with who may act, the scope and the date: the coordinator pushes `main` to `origin` after each merge, once it has checked the merge for private content (2026-10-08).
