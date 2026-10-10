# Known non-herdr divergences

Related: [index](../index.md), `AGENTS.md` ("Scope", "Upstream sync")

Fork-only changes to upstream files, other than the herdr port, Incus first with Docker optional, and the supported platforms, which are why the fork exists ("Scope" in `AGENTS.md`). At each upstream sync, resolve each entry knowingly, and drop it once upstream fixes it. Each entry names its bead.

- acfs-gxd: test fixes that make the gate pass: tests assert the upgrade paths upstream retired, and `test_release_doctor.sh` fakes the version check unless a test clears it (release-doctor's missing-`install.sh` fix and its test are upstream's since the 2026-10-10 sync).
- acfs-bnz: CI pins shellcheck 0.9.0 and bun, which upstream's CI leaves unpinned.
- acfs-0pj: the plugin-pack tests set their fixtures' file modes, because upstream's tests fail under umask 0002.
- acfs-rst: `test_swarm_fleet_probe.py` also sets its library fixtures' modes in the test that upstream's leaves to the umask, for the same reason, and its unsafe-runtime case uses world write (0666), because acfs-pkh accepts the owner's private-group write.
- acfs-fep: `test_fleet_runtime.py`, `test_fleet_runtime_git_snapshot.py` and `test_ubuntu_eol_repositories.py` set their fixtures' modes, for the same reason.
- acfs-pkh: the fleet tools (`acfs-fleet.py`, `swarm-fleet-*.py`, `swarm_fleet_probe.sh`) accept group write when the group is the user's own private group, so repositories made under Ubuntu's umask 0002 aren't refused; upstream refuses any group write (operator ruling, 2026-10-09). Upstream's `swarm-fleet-provision.py`, new in the 2026-10-10 sync, still refuses it: acfs-r39.
- acfs-a04: `ACFS_REPO_OWNER` defaults to the fork's owner, so the one-liner installs the fork, not upstream.
- acfs-m3l: the support inventory fixture in `test_support_resource_profile.sh` probes at the current time, not upstream's 2099, which `swarm_inventory.sh` excludes as a future probe.
- acfs-xe3: `test_install_fetch_composition.sh`'s A6 resolves against the default owner, not upstream's.
- acfs-b0u: `security.sh` adds `--compressed` to upstream's identity request, because some hosts gzip anyway (antigravity, 2026-10-10).
- acfs-d91: the installer refuses Ubuntu 22.04 unless `--target-ubuntu=24.04|26.04` upgrades it first, and 22.04 is no longer an upgrade target (`install.sh`, `ubuntu_upgrade.sh`, `upgrade_resume.sh`, `preflight.sh`, their tests and CI's 22.04 job); upstream still installs on 22.04. Existing 22.04 installs keep running `acfs update`. The manifest's 22.04 branches (PostgreSQL's jammy PGDG) and the wizard's 22.04 image option, whose command upgrades it, stay as upstream's.
- acfs-yca: Docker is the opt-in module `tools.docker`, not part of `cli.modern`, which upstream installs by default. It takes Ubuntu's `docker-compose-v2` where apt offers it, because `docker-compose-plugin` exists only in Docker's own repository. dsr depends on the module.
- acfs-patg: `ubuntu-entrypoint.yml` runs `test_ubuntu_upgrade_main.py` as root in an `ubuntu:24.04` container, because its `PrivilegedCheckpointReadTests` refuses the runner, and upstream's job fails on every run.
- acfs-5f9: `AGENTS.md` drops upstream's "Morph Warp Grep" section: Warp Grep is a hosted service that needs a Morph account and API key, and neither ACFS nor upstream installs it (the operator, 2026-10-10).
- acfs-9ij4: three Installer CI fixes, because upstream's job fails on every run.
  - Every UBS install (manifest, `install.sh`, `acfs update`, the doctor's fix) passes `--skip-ast-grep`. Otherwise UBS's installer can install ast-grep's `sg` launcher as `~/.local/bin/ast-grep`, which runs itself until the system refuses. The doctor's fix also passes `--skip-hooks`, as the others already did.
  - The workflow YAML lint warns on line length instead of failing.
  - `test_fresh_root_bootstrap_regression.sh` reads the checkout from `$REPO_ROOT`, not `/repo`.
