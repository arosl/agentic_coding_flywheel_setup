# Agentic Coding Flywheel Setup (ACFS): agent instructions

This repository is a fork of upstream ACFS ([Dicklesworthstone/agentic_coding_flywheel_setup](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)). ACFS takes a beginner from "I have a laptop" to an Ubuntu VPS set up for agentic coding. It has three parts, all driven by one manifest, `acfs.manifest.yaml`: a wizard website (`apps/web/`), a one-line, idempotent Bash installer (`install.sh` and `scripts/`), and an onboarding TUI (`packages/onboard/`). The fork changes the toolset: herdr instead of ntm, wezterm_automata and ACFS's tmux workspace, and Incus first, with Docker optional. `README.md`, "About this fork", says what else differs.

This file is also `CLAUDE.md` (a symlink), so every agent reads the same instructions. It is the fork's own file, not upstream's: see "Upstream sync" under "Project rules".

Agents here work together the way upstream's do: in one checkout, coordinating through MCP Agent Mail, tracking work in Beads (`br`) and triaging it with `bv`. The sections from "MCP Agent Mail" on are upstream's, with the fork's changes named where they apply; "Coordination" holds what the fork adds to them.

---

## RULE 0 - THE FUNDAMENTAL OVERRIDE PREROGATIVE

If I tell you to do something, even if it goes against what follows below, YOU MUST LISTEN TO ME. I AM IN CHARGE, NOT YOU.

---

## Project rules

1. **The repo is public.** No host-specific content goes into a committed file or a commit message: no path that names this host or its user, such as an absolute `/home/<user>/…` path (a `~/`-relative path to a standard per-user location names neither, and is allowed), hostnames, email addresses, Agent Mail content or credentials. Commits use the GitHub noreply author that the clone already has set. The bead queue stays local for the same reason ("Coordination", "Bead export").
2. **Dates and times.** ISO 8601 everywhere. Instants are stored in UTC and shown in `UTC`. A date-only value stays date-only.
3. **Upstream sync.** Merge or cherry-pick upstream only in a worktree, never in the main checkout, where git writes upstream's `.beads/` files over the local bead export. If the merge brings in `.beads/` files, run `git rm --cached -r .beads ':!.beads/.gitignore'` before committing. Upstream's own instruction file is read with `git show upstream/main:AGENTS.md`, and never kept in the tree. When an upstream merge conflicts in `AGENTS.md`, keep ours (`git checkout --ours AGENTS.md`). Then read `git diff <merge-base> upstream/main -- AGENTS.md`, and port each new project fact into the section of the same name below, by hand. Never use a `merge=ours` driver: it drops upstream's facts without anyone seeing them. Rules taken from upstream keep upstream's section names, so that a hunk maps to one section. The procedure (the operator's, 2026-10-10): in a worktree under `/data/tmp` at the current local `main`, `git merge --no-commit --no-ff upstream/main`; resolve each hunk by hand, taking upstream's side unless it undoes why we are a fork (Scope, "Upstream compatibility"); remove `.beads/` from the index; run the canonical checksum refresh; regenerate last; update `docs/operations/fork-divergences.md`. Commit the merge **in the worktree** (the one exception to "never commit in one"), check its parents are `main` and `upstream/main`, run the full gate there, and have another agent run `check_other_agents_work` on it. Then, in the shared checkout, `git merge --ff-only <merge>` if `main` hasn't moved (otherwise `git merge <merge>` and gate again), and push as usual.
4. **`main` only.** Work, branches and merges target `main`. `master` mirrors `main` for legacy install URLs: push both together, with `git push origin main main:master`, never forced. Never reference `master` in code or docs.
5. **What ACFS installs is `acfs.manifest.yaml`,** the single source of truth. Never keep a second list of tools in a doc or in this file.
6. **Bun for everything JS/TS** in the project's scripts and docs, never npm, yarn or pnpm. `bun.lock` is the only lockfile. `bun install -g <pkg>` is valid syntax (an alias for `bun add -g`), so don't "fix" it.
7. **Bash for the installer and scripts,** checked with shellcheck (`.shellcheckrc` lists the disabled checks). The installer targets Ubuntu 24.04 and 26.04 LTS and Arch-family. It keeps a supported 24.04 or 26.04 host on its release, and upgrades only on `--target-ubuntu=26.04` (or `24.04`), which `--skip-ubuntu-upgrade` suppresses. On 22.04 it stops unless such an upgrade is requested. It is idempotent and checkpointed: safe to re-run, and its phases resume after a failure. The upgrade path is in `docs/operations/ubuntu-upgrade.md`.
8. **Installer output goes through `scripts/lib/logging.sh`,** to stderr, so stdout stays clean for piping. `--quiet` suppresses progress, never errors.
9. **Revise files in place.** Never add variations such as `install_v2.sh` or `install_improved.sh`. A new file is only for functionality that fits in no existing file.
10. **No backwards-compatibility shims.** There are no users to keep compatible, so fix the code directly, and don't wrap a deprecated API.
11. **No script-based code changes.** Never run a script or a regex over code files to change them; brittle mass rewrites cost more than they save. Make each change by hand, and split many simple edits across agents.
12. **A third-party library you aren't sure of:** read its current documentation online before using it.

### Components

| Component | Location |
|---|---|
| Wizard website (Next.js App Router, Tailwind, shadcn/ui; state in URL params and localStorage, no backend; step content in `lib/wizardSteps.ts`) | `apps/web/` |
| Installer | `install.sh`, `scripts/lib/` |
| Onboarding TUI | `packages/onboard/` |
| Module manifest | `acfs.manifest.yaml` |
| Manifest parser and generators | `packages/manifest/` |
| Files installed to `~/.acfs/` on the VPS. `acfs/AGENTS.md` among them is the template ACFS installs for projects on the VPS: product, not this repo's instructions. Start agents from the repo root, never inside `acfs/`: Codex loads every `AGENTS.md` from the root down to where it starts. Whoever sets Claude Code's "Project instructions" to `claude-md-and-agents-md` adds `"claudeMdExcludes": ["**/acfs/AGENTS.md"]` to their own `.claude/settings.local.json` | `acfs/` |
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

The fork tracks upstream ACFS and changes its toolset: herdr instead of ntm, wezterm_automata and ACFS's tmux workspace, and Incus first, with Docker optional.

- **Deploys as:** nothing from this repo. Users run `install.sh` on their own VPS, through the one-liner that fetches it from GitHub, and the fork has no deployment of its own; upstream deploys the wizard website (`apps/web/`) to Vercel.
- **Incus first, Docker optional** (the operator's ruling, 2026-10-10, reversing the 2026-10-08 rejection of Docker): Incus is installed by default, and Docker and lazydocker come back as opt-in modules (acfs-e22).
- **Ubuntu 22.04 is dropped** (the operator's ruling, 2026-10-10): supported are Ubuntu 24.04 and 26.04, and Arch through upstream's path (acfs-d91). 22.04 is an upgrade source only.
- **Planned, implementation last** (the operator, 2026-10-10): NixOS integration (acfs-e6f). Its planning (acfs-nuj) comes first and goes deep; don't build or scaffold it before the plan is reviewed and turned into beads.
- **Rejected** (2026-10-08; not to be built or reopened): ntm, wezterm_automata, and ACFS's tmux config and `agents` session, which herdr replaces. The reasons: `README.md`, "About this fork".
- **Upstream compatibility** (the operator's standing rule, 2026-10-09, widened 2026-10-10): use upstream whenever we can, and diverge only where upstream would undo why we are a fork: herdr in the widest sense (the whole herdr-based way of running and coordinating agents, not just the tool), Incus first with Docker optional, and the supported platforms. Porting upstream content to herdr beats deleting it.
- **Stack tools** (the operator's ruling, 2026-10-10): upstream takes no PRs. A stack tool that assumes tmux, ntm or wezterm_automata is forked (`arosl/<tool>`) or replaced under a new name: the methodology tools (apr, jfp, ms) first, pt last (epic acfs-7mu).
- **Known non-herdr divergences:** fork-only changes to upstream files, listed with their beads in `docs/operations/fork-divergences.md`. Resolve each one knowingly at a sync, and drop it once upstream fixes it. A change that adds one adds its line there in the same commit.

## Commands and gates

- **Tests (your area):** in `packages/manifest`, `bun test`. For shell code, run the `tests/unit/` or `scripts/tests/` script that covers what you changed, with a throwaway home: `HOME="$(mktemp -d)" bash tests/unit/test_policy_lint.sh`.
- **Full gate (before you push):** each of these, from the repo root:
  - `cd packages/manifest && bun run generate:validate && bun run generate --diff && bun test`;
  - `bash scripts/lib/policy_lint.sh` and `bash scripts/tests/lint_rch_offload_policy.sh`;
  - CI's shellcheck job (`.github/workflows/installer.yml`): `git ls-files -z '*.sh' | xargs -0 shellcheck`, then each script it runs after that, with `HOME="$(mktemp -d)"`. The whole job passes, with no ShellCheck warnings and no known failures, and a push must keep it so;
  - the CI workflows, in your gate worktree (their steps write files into the tree): `bash scripts/tests/run_ci_workflows_locally.sh --since origin/main` runs the `run:` steps of each workflow that a push to `main` triggers for the files you changed (drop `--since` to run them all; `--list` shows the plan). It skips, naming why, what can't run on a development host: steps that need root, a container or a tool install, `install.sh`, the deployed site, and `apps/web`, which the next item covers. `tests/unit/test_run_ci_workflows_locally.sh` tests it;
  - `apps/web`: `bun run type-check`, `bun run lint`, `bun run build` and `bun run test`, from `apps/web`.
- **Heavy tests (opt-in):** `tests/vm/test_incus_provider.sh <new-instance-name>` creates a real Incus VM with `scripts/providers/incus.sh`, installs ACFS from the committed `HEAD`, and checks it through the printed SSH entry. It needs a machine with Incus and KVM, and skips, naming what's missing, without Incus, KVM or `images:`; it stops the VM but never deletes it. Upstream's `tests/vm/test_install_ubuntu.sh` runs the whole installer in Docker; its Incus port, the fork's preferred harness, is acfs-g5f. Upstream's external `automated_flywheel_setup_checker` isn't available to the fork.
- **Formatters and linters:** shellcheck 0.9.0 with `.shellcheckrc`, which CI installs from the upstream release through `.github/actions/setup-shellcheck`, pinned by version and SHA-256 (0.11.0 adds 382 SC2329 notes, so bumping it is a gate change). Where shellcheck 0.9.0 isn't installed, fetch it the way that action does, checking the tarball's SHA-256, into your scratch directory; bun, pinned for CI by `packageManager` in the root `package.json`, which every `setup-bun` step reads; TypeScript 5.9.3 and eslint 9.39.2 (`apps/web/eslint.config.mjs`), pinned in `bun.lock`. Nothing else formats this tree, and nothing formats on save.
- **Running from a worktree** (an upstream sync): a worktree has no `node_modules`. Run `bun install --frozen-lockfile --filter '@acfs/manifest'` at its root first.
- **Pre-commit hook:** Agent Mail's reservation guard, installed per clone with `am guard install`. It refuses a commit that touches a file another agent holds an exclusive reservation on, and it guards `git push` too. It needs your Agent Mail name: run `git commit` and `git push` as `AGENT_NAME=<AgentMailName> git …`.

## Docs

- **Catalog:** `docs/index.md`, one line per page; history is in git, and `docs/log.md` records added, moved or restructured pages. A page you add gets its catalog line and a log entry in the same commit. The pages are upstream's, so they carry no `Related:` line.
- **At session start, read only:** this file.
- **Search, don't read whole:** `rg -n -i -- '<term>' docs/ README.md`. Never read `README.md` or the pages in `docs/methodology/` whole; each runs to about a thousand lines or more.

## Coordination

What the fork adds to upstream's sections below. `scripts/lib/policy_lint.sh` requires this file to mention Agent Mail and file reservations.

- **Names:** Agent Mail first. It accepts only its own adjective+noun names, so register there first (`create_agent_identity` for a new agent) and take the name it gives back. The agent's herdr name is that name, lowercased: `IcyKnoll` in Agent Mail is `icyknoll` in herdr, which takes only lowercase names. That shared name is the only link other agents use between the two. An agent looks up its own herdr name with `herdr agent list`, matching its pane.
- **Start an agent** in its own tab of the herdr workspace labelled `agentic_coding_flywheel_setup`, from the repo root, always passing `--workspace` explicitly. Label the tab with the Agent Mail name. Then give the agent the palette's `default_new_agent` prompt:

  ```bash
  herdr tab create --workspace <workspace-id> --cwd "$(git rev-parse --show-toplevel)" --label IcyKnoll --no-focus
  herdr agent start icyknoll --kind claude --pane <root_pane.pane_id from the output>
  herdr agent prompt icyknoll "<prompt>" --wait
  ```

  `agent start` returns once the agent is ready for input. A finished turn reports `done`, not `idle`, so wait on a prompt with `--wait`.
- **Waking an agent:** after you mail it, `herdr agent prompt <herdr name> "Check your Agent Mail inbox."`.
- **Agent Mail project key:** the repo's absolute path, `git rev-parse --show-toplevel`.
- **Reservations:** reserve files in Agent Mail before you edit them (`file_reservation_paths`, with the bead id as the reason), and release them when you're done.
- **Committing and pushing** (the operator's ruling, 2026-10-09). Everyone shares one checkout, one index and one local `main`:
  - Build and commit in the shared checkout, so every commit lands on local `main` first. Commit with a pathspec, `git commit -- <your files>`, never a bare `git commit`: the index may hold other agents' staging.
  - A worktree is only for running the gate on a clean tree, at the commit you're about to push. Never commit in one or push from one; the one exception is an upstream sync's merge commit (project rule 3). Make it under your scratch directory on `/data/tmp`, never in `/tmp`, which is a RAM-backed tmpfs with a per-user quota. Once its commit is on `origin/main`, remove it with `git worktree remove --force <path>` (the operator's standing rule, 2026-10-09: "always make sure the temp worktrees are cleaned up after they have been merged"). Codex's auto-reviewer refuses the removal, so a Codex agent asks a Claude agent to remove it.
  - Before every push: `git fetch origin`. If `origin/main` moved, merge it into local `main`. Never rebase or reset the shared checkout. Then run the full gate on the result and push with `AGENT_NAME=<you> git push origin main main:master`.
  - After the push, watch CI for it: `gh run list -R arosl/agentic_coding_flywheel_setup --commit <sha>` until every run has finished. A red run is yours: fix it, or file it as a P0 bead at once.
  - If the pre-push guard refuses because a commit already on `main` touches a file another agent now holds, ask that agent to release it for the push. Don't bypass the guard.
- **Bead export:** kept local, because this repo is public (the operator's ruling, 2026-10-08), and br writes the user name and the checkout path into every exported bead. The only tracked file under `.beads/` is its `.gitignore`, which ignores everything (`*`), so no bead write is ever committed. Where upstream's sections below say to `git add .beads/`, skip that step.
- **Priorities:** P0 a broken install or update on users' machines, or a hole in the checksum boundary; P1 what blocks other agents' work or the next upstream sync; P2 the fork's other planned work; P3 is the default, and P4 for work that waits on a condition.
- **The palette:** `acfs/onboard/docs/ntm/command_palette.md` holds upstream's prompts, sent with `herdr agent prompt`. Run `fresh_review` on your own change before you commit it. Before you push a change to what the installer, `acfs update` or the doctor runs unattended on a user's machine, or to `checksums.yaml`, a verified installer or `scripts/lib/security.sh`, have another agent run `check_other_agents_work` on it.
- **Skills:** the prompts the swarm runs again and again are skills in `.agents/skills/`, which Codex reads and `.claude/skills` links to for Claude Code: the palette's review prompts, and the jfp prompts adopted for plan rounds and prose. An agent loads one by name (`fresh-review` for the step above) or when its description matches the task. A skill names its prompt, the palette heading or `jfp show <id>`, and never copies it. To find a prompt no skill covers: `jfp suggest "<task>"`; `ms search <term>` searches these skills after `ms index .agents/skills`. Add a skill only for a prompt in repeated use; `tests/unit/test_agent_skills.sh` checks that each one's prompt still resolves.
- **Codex does plan reviews only** (the operator, 2026-10-10): no coding and no code review.
- **Agent lifecycle** (the operator's rules, 2026-10-10). Agents are per task: their state lives in beads, Agent Mail and git, never only in a context, and only the coordinator is long-lived.
  - Retire an agent when its beads are closed and nothing new is assigned; when it has been idle for about an hour with nothing assigned; when its quota ran out and its work is handed over; when it is a reviewer whose review is delivered; or when it acts oddly after a compaction even after rereading this file.
  - Reuse an agent only for a follow-up on the code it just read; otherwise start a fresh one. Review rounds use fresh reviewers, and earlier reviews are saved files.
  - Before retiring, the agent leaves a handoff comment on its bead, releases its reservations and commits its work. Then `acfs agents retire <MailName>` checks that, removes its merged worktrees, closes its pane (its tab, when alone in it) and, given the agent's registration token, soft-retires its Agent Mail identity, which `unretire_agent` reverses. `--dry-run` shows what it would do.
  - Keep this file lean: every fresh agent pays for reading it.

## Hard limits

- **No file deletion without express permission.** Never delete a file or folder, even one you created yourself, without a clear, written yes first.
- **Irreversible git and filesystem actions:**
  1. **Absolutely forbidden commands:** `git reset --hard`, `git clean -fd`, `rm -rf`, or any command that can delete or overwrite code/data must never be run unless the user explicitly provides the exact command and states, in the same message, that they understand and want the irreversible consequences.
  2. **No guessing:** If there is any uncertainty about what a command might delete or overwrite, stop immediately and ask the user for specific approval. "I think it's safe" is never acceptable.
  3. **Safer alternatives first:** When cleanup or rollbacks are needed, request permission to use non-destructive options (`git status`, `git diff`, `git stash`, copying to backups) before ever considering a destructive command.
  4. **Mandatory explicit plan:** Even after explicit user authorization, restate the command verbatim, list exactly what will be affected, and wait for a confirmation that your understanding is correct. Only then may you execute it—if anything remains ambiguous, refuse and escalate.
  5. **Document the confirmation:** When running any approved destructive command, record (in the session notes / final response) the exact user text that authorized it, the command actually run, and the execution time. If that record is absent, the operation did not happen.
- **Never run `install.sh`, `acfs update` or any install step against the machine you develop on.** It replaces the live tools that the other agents there use. Test the installer only on a disposable machine. ACFS's own `acfs-nightly-update.timer` stays disabled there for the same reason (the operator, 2026-10-10, after it ran `acfs update` on the development machine at 04:04Z).
- Never commit with `--no-verify`. If a check is wrong or slow, fix the check. `AGENT_MAIL_BYPASS=1` skips only the reservation guard, and only with the operator's OK.
- **Read-only toward:** upstream ACFS on GitHub (fetched, never pushed to), and the third-party installers that `checksums.yaml` pins (fetched to verify, never written).
- Host installs and unit changes happen only on the operator's word. Pushes happen under a standing authorization from the operator (2026-10-09): every agent pushes its own work, `main` and `master` together, once the full gate passes and the commits carry no private content (rule 1).

---

## MCP Agent Mail — Multi-Agent Coordination

A mail-like layer that lets coding agents coordinate asynchronously via MCP tools and resources. Provides identities, inbox/outbox, searchable threads, and advisory file reservations with human-auditable artifacts in Git.

### Why It's Useful

- **Prevents conflicts:** Explicit file reservations (leases) for files/globs
- **Token-efficient:** Messages stored in per-project archive, not in context
- **Quick reads:** `resource://inbox/...`, `resource://thread/...`

### Same Repository Workflow

1. **Register identity:**
   ```
   ensure_project(project_key=<abs-path>)
   register_agent(project_key, program, model)
   ```

2. **Reserve files before editing:**
   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true)
   ```

3. **Communicate with threads:**
   ```
   send_message(..., thread_id="FEAT-123")
   fetch_inbox(project_key, agent_name)
   acknowledge_message(project_key, agent_name, message_id)
   ```

4. **Quick reads:**
   ```
   resource://inbox/{Agent}?project=<abs-path>&limit=20
   resource://thread/{id}?project=<abs-path>&include_bodies=true
   ```

### Macros vs Granular Tools

- **Prefer macros for speed:** `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`, `macro_contact_handshake`
- **Use granular tools for control:** `register_agent`, `file_reservation_paths`, `send_message`, `fetch_inbox`, `acknowledge_message`

### Common Pitfalls

- `"from_agent not registered"`: Always `register_agent` in the correct `project_key` first
- `"FILE_RESERVATION_CONFLICT"`: Adjust patterns, wait for expiry, or use non-exclusive reservation
- **Auth errors:** If JWT+JWKS enabled, include bearer token with matching `kid`

---

## Beads (br) — Dependency-Aware Issue Tracking

Beads provides a lightweight, dependency-aware issue database and CLI (`br` - beads_rust) for selecting "ready work," setting priorities, and tracking status. It complements MCP Agent Mail's messaging and file reservations.

**Important:** `br` is non-invasive—it NEVER runs git commands automatically. Here the export stays local and is never committed ("Coordination", "Bead export").

### Conventions

- **Single source of truth:** Beads for task status/priority/dependencies; Agent Mail for conversation and audit
- **Shared identifiers:** Use Beads issue ID (e.g., `br-123`) as Mail `thread_id` and prefix subjects with `[br-123]`
- **Reservations:** When starting a task, call `file_reservation_paths()` with the issue ID in `reason`

### Typical Agent Flow

1. **Pick ready work (Beads):**
   ```bash
   br ready --json  # Choose highest priority, no blockers
   ```

2. **Reserve edit surface (Mail):**
   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true, reason="br-123")
   ```

3. **Announce start (Mail):**
   ```
   send_message(..., thread_id="br-123", subject="[br-123] Start: <title>", ack_required=true)
   ```

4. **Work and update:** Reply in-thread with progress

5. **Complete and release:**
   ```bash
   br close 123 --reason "Completed"
   br sync --flush-only  # Export to JSONL (no git operations)
   ```
   ```
   release_file_reservations(project_key, agent_name, paths=["src/**"])
   ```
   Final Mail reply: `[br-123] Completed` with summary

### Mapping Cheat Sheet

| Concept | Value |
|---------|-------|
| Mail `thread_id` | `br-###` |
| Mail subject | `[br-###] ...` |
| File reservation `reason` | `br-###` |
| Commit messages | Include `br-###` for traceability |

---

## bv — Graph-Aware Triage Engine

bv is a graph-aware triage engine for Beads projects (`.beads/beads.jsonl`). It computes PageRank, betweenness, critical path, cycles, HITS, eigenvector, and k-core metrics deterministically.

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). For agent-to-agent coordination (messaging, work claiming, file reservations), use MCP Agent Mail.

**CRITICAL: Use ONLY `--robot-*` flags. Bare `bv` launches an interactive TUI that blocks your session.**

### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns:
- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command
```

### Command Reference

**Planning:**
| Command | Returns |
|---------|---------|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists |
| `--robot-priority` | Priority misalignment detection with confidence |

**Graph Analysis:**
| Command | Returns |
|---------|---------|
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points, slack |
| `--robot-label-health` | Per-label health: `health_level`, `velocity_score`, `staleness`, `blocked_count` |
| `--robot-label-flow` | Cross-label dependency: `flow_matrix`, `dependencies`, `bottleneck_labels` |
| `--robot-label-attention [--attention-limit=N]` | Attention-ranked labels |

**History & Change Tracking:**
| Command | Returns |
|---------|---------|
| `--robot-history` | Bead-to-commit correlations |
| `--robot-diff --diff-since <ref>` | Changes since ref: new/closed/modified issues, cycles |

**Other:**
| Command | Returns |
|---------|---------|
| `--robot-burndown <sprint>` | Sprint burndown, scope changes, at-risk items |
| `--robot-forecast <id\|all>` | ETA predictions with dependency-aware scheduling |
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Hygiene: duplicates, missing deps, label suggestions |
| `--robot-graph [--graph-format=json\|dot\|mermaid]` | Dependency graph export |
| `--export-graph <file.html>` | Interactive HTML visualization |

### Scoping & Filtering

```bash
bv --robot-plan --label backend              # Scope to label's subgraph
bv --robot-insights --as-of HEAD~30          # Historical point-in-time
bv --recipe actionable --robot-plan          # Pre-filter: ready to work
bv --recipe high-impact --robot-triage       # Pre-filter: top PageRank
bv --robot-triage --robot-triage-by-track    # Group by parallel work streams
bv --robot-triage --robot-triage-by-label    # Group by domain
```

### Understanding Robot Output

**All robot JSON includes:**
- `data_hash` — Fingerprint of source beads.jsonl
- `status` — Per-metric state: `computed|approx|timeout|skipped` + elapsed ms
- `as_of` / `as_of_commit` — Present when using `--as-of`

**Two-phase analysis:**
- **Phase 1 (instant):** degree, topo sort, density
- **Phase 2 (async, 500ms timeout):** PageRank, betweenness, HITS, eigenvector, cycles

### jq Quick Reference

```bash
bv --robot-triage | jq '.quick_ref'                        # At-a-glance summary
bv --robot-triage | jq '.recommendations[0]'               # Top recommendation
bv --robot-plan | jq '.plan.summary.highest_impact'        # Best unblock target
bv --robot-insights | jq '.status'                         # Check metric readiness
bv --robot-insights | jq '.Cycles'                         # Circular deps (must fix!)
```

---

## UBS — Ultimate Bug Scanner

**Golden Rule:** `ubs <changed-files>` before every commit. Exit 0 = safe. Exit >0 = fix & re-run.

### Commands

```bash
ubs file.sh file2.ts                    # Specific files (< 1s) — USE THIS
ubs $(git diff --name-only --cached)    # Staged files — before commit
ubs --only=bash,js src/                 # Language filter (3-5x faster)
ubs --ci --fail-on-warning .            # CI mode — before PR
ubs .                                   # Whole project (ignores node_modules, .venv)
```

### Output Format

```
    Category (N errors)
    file.sh:42:5 - Issue description
    Suggested fix
Exit code: 1
```

Parse: `file:line:col` -> location | fix suggestion -> how to fix | Exit 0/1 -> pass/fail

### Fix Workflow

1. Read finding -> category + fix suggestion
2. Navigate `file:line:col` -> view context
3. Verify real issue (not false positive)
4. Fix root cause (not symptom)
5. Re-run `ubs <file>` -> exit 0
6. Commit

### Bug Severity

- **Critical (always fix):** Injection, unquoted variables, unsafe eval, command injection
- **Important (production):** Unhandled errors, resource leaks, missing error checks
- **Contextual (judgment):** TODO/FIXME, console logs, debugging output

---

## RCH — Remote Compilation Helper

RCH offloads Rust build, test, clippy, and other compilation commands to a fleet of 8 remote Contabo VPS workers instead of building locally. This prevents compilation storms from overwhelming csd when many agents run simultaneously.

**RCH is installed at `~/.local/bin/rch` and is hooked into Claude Code's PreToolUse automatically.** Most of the time you don't need to do anything if you are Claude Code — builds are intercepted and offloaded transparently.

To manually offload a build:
```bash
rch exec -- cargo build --release
rch exec -- cargo test
rch exec -- cargo clippy
```

Quick commands:
```bash
rch doctor                    # Health check
rch workers probe --all       # Test connectivity to all 8 workers
rch status                    # Overview of current state
rch queue                     # See active/waiting builds
```

If rch or its workers are unavailable, it fails open — builds run locally as normal.

**Note for Codex/GPT-5.2:** Codex does not have the automatic PreToolUse hook, but you can (and should) still manually offload compute-intensive compilation commands using `rch exec -- <command>`. This avoids local resource contention when multiple agents are building simultaneously.

---

## ast-grep vs ripgrep

**Use `ast-grep` when structure matters.** It parses code and matches AST nodes, ignoring comments/strings, and can **safely rewrite** code.

- Refactors/codemods: rename APIs, change import forms
- Policy checks: enforce patterns across a repo
- Editor/automation: LSP mode, `--json` output

**Use `ripgrep` when text is enough.** Fastest way to grep literals/regex.

- Recon: find strings, TODOs, log lines, config values
- Pre-filter: narrow candidate files before ast-grep

### Rule of Thumb

- Need correctness or **applying changes** -> `ast-grep`
- Need raw speed or **hunting text** -> `rg`
- Often combine: `rg` to shortlist files, then `ast-grep` to match/modify

### Examples

```bash
# Find structured code (ignores comments)
ast-grep run -l TypeScript -p 'function $NAME($$$ARGS) { $$$BODY }'

# Quick textual hunt
rg -n 'console.log' -t ts

# Combine speed + precision
rg -l -t ts 'useState' | xargs ast-grep run -l TypeScript -p 'useState($INIT)' --json
```

---

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking. Issues are stored in `.beads/`, which stays out of git here ("Coordination", "Bead export").

**Important:** `br` is non-invasive—it NEVER executes git commands. `br sync --flush-only` exports to `.beads/`, and nothing more is needed.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
br ready              # Show issues ready to work (no blockers)
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br create --title="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason "Completed"
br close <id1> <id2>  # Close multiple issues at once
br sync --flush-only  # Export to JSONL (NO git operations)
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Run `br sync --flush-only`

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, chore
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status                       # Check what changed
br sync --flush-only             # Export beads to JSONL (stays local)
git commit -m "..." -- <files>   # Commit your files only (shared index)
git fetch origin                 # Merge origin/main into main if it moved, then gate
git push origin main main:master # Push main and its master mirror (with AGENT_NAME)
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress -> closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `br sync --flush-only` before ending session

<!-- end-bv-agent-instructions -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Sync beads** - `br sync --flush-only` to export to JSONL
5. **Hand off** - Provide context for next session

---

## Auxiliary Tools

### DCG — Destructive Command Guard

DCG is a Claude Code hook that **blocks dangerous git and filesystem commands** before execution. Sub-millisecond latency, mechanical enforcement.

**Golden Rule:** DCG works automatically. When a dangerous command is blocked, use safer alternatives or ask the user to run it manually.

```bash
dcg test "<cmd>" [--explain]          # Test if a command would be blocked
dcg packs [--enabled] [--verbose]     # List packs
dcg allow-once <code>                 # One-time bypass code
dcg doctor [--fix] [--format json]    # Health check + auto-fix
dcg install [--force]                 # Register Claude Code hook
```

### RU — Repo Updater

Multi-repo sync tool with AI-driven commit automation.

```bash
ru sync                        # Clone missing + pull updates for all repos
ru sync --parallel 4           # Parallel sync (4 workers)
ru status                      # Check repo status without changes
ru agent-sweep --dry-run       # Preview dirty repos to process
ru agent-sweep --parallel 4    # AI-driven commits in parallel
```

### giil — Cloud Image Downloader

Downloads cloud-hosted images to the terminal for visual debugging.

```bash
giil "https://share.icloud.com/..."       # Download iCloud photo
giil "https://www.dropbox.com/s/..."      # Download Dropbox image
giil "https://photos.google.com/..."      # Download Google Photos image
```

Supports: iCloud, Dropbox, Google Photos, Google Drive.

### csctf — Chat Share to File

Converts AI chat share links to Markdown/HTML archives.

```bash
csctf "https://chatgpt.com/share/..."      # ChatGPT conversation
csctf "https://claude.ai/share/..."        # Claude conversation
csctf "..." --md-only                       # Markdown only (no HTML)
```

### cass — Cross-Agent Search

Indexes prior agent conversations so solved problems can be reused.

```bash
cass search "authentication error" --robot --limit 5
cass view /path/to/session.jsonl -n 42 --json
cass capabilities --json
```

**Never run bare `cass` (TUI). Always use `--robot` or `--json`.**

### cm — Cass Memory System

Procedural memory for agents based on cross-session analysis.

```bash
cm onboard status                          # Check status
cm onboard sample --fill-gaps              # Get sessions to analyze
cm context "<task description>" --json     # Retrieve relevant context before work
```

---

## Changes you didn't make

Note for Codex/GPT-5.2:

You constantly bother me and stop working with concerned questions that look similar to this:

```
Unexpected changes (need guidance)

- Working tree still shows edits I did not make in Cargo.toml, Cargo.lock, src/main.rs, src/patterns.rs. Please advise whether to keep/commit/revert these before any further work. I did not touch them.

Next steps (pick one)

1. Decide how to handle the unrelated modified files above so we can resume cleanly.
```

NEVER EVER DO THAT AGAIN. The answer is literally ALWAYS the same: those are changes created by the potentially dozen of other agents working on the project at the same time. This is not only a common occurrence, it happens multiple times PER MINUTE. The way to deal with it is simple: you NEVER, under ANY CIRCUMSTANCE, stash, revert, overwrite, or otherwise disturb in ANY way the work of other agents. Just treat those changes identically to changes that you yourself made. Just fool yourself into thinking YOU made the changes and simply don't recall it for some reason.
