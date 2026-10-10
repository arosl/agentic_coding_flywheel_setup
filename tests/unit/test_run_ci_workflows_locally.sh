#!/usr/bin/env bash
# ============================================================
# scripts/tests/run_ci_workflows_locally.sh against fixture workflows
#
# Proves which workflows, jobs and steps the local CI runner runs or
# skips, that it runs a step the way a runner would (working-directory,
# env, GITHUB_ENV, a fresh HOME), that a failing step fails the run and
# skips the rest of its job, and that the steps it must never run on a
# development host (sudo, install.sh, acfs update, containers, tool
# installs) don't run: each of those writes a marker if it ever does.
#
# Usage: bash tests/unit/test_run_ci_workflows_locally.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/scripts/tests/run_ci_workflows_locally.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-ci-local-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

OUT="" RC=0
run_runner() {
    RC=0
    OUT="$(TMPDIR="$WORK" bash "$RUNNER" --root "$REPO" "$@" 2>&1)" || RC=$?
}
rc_is() { [[ "$RC" -eq "$1" ]]; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
no_marker() { [[ ! -e "$REPO/ran-$1" ]]; }

# ------------------------------------------------------------
# A throwaway repository with fixture workflows.
# ------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/.github/workflows" "$REPO/sub" "$REPO/only" "$REPO/other"
printf '#!/usr/bin/env bash\ntouch "$(dirname "$0")/ran-install"\n' >"$REPO/install.sh"
printf 'one\n' >"$REPO/only/a.txt"
printf 'one\n' >"$REPO/other/b.txt"

cat >"$REPO/.github/workflows/good.yml" <<'YAML'
name: good
on:
  push:
    branches: [main]
env:
  WF_VAR: from-workflow
jobs:
  first:
    runs-on: ubuntu-latest
    env:
      JOB_VAR: from-job
    steps:
      - uses: actions/checkout@v4
      - name: Runs in the step's working-directory with the merged env
        working-directory: sub
        env:
          STEP_VAR: from-step
        run: |
          [[ "$PWD" == */repo/sub ]]
          [[ "$WF_VAR/$JOB_VAR/$STEP_VAR" == from-workflow/from-job/from-step ]]
          [[ "$CI" == true && -n "$RUNNER_TEMP" && -d "$RUNNER_TEMP" ]]
          [[ "$HOME" != "$CALLER_HOME" && -d "$HOME" ]]
          echo "FROM_ENV_FILE=carried" >>"$GITHUB_ENV"
          echo "$PWD/bin" >>"$GITHUB_PATH"
      - name: Sees what an earlier step wrote to GITHUB_ENV
        run: '[[ "$FROM_ENV_FILE" == carried ]]'
      - name: Sees what an earlier step added to GITHUB_PATH
        run: '[[ ":$PATH:" == *"/repo/sub/bin:"* ]]'
      - name: Keeps a multi-line env value whole
        env:
          MULTI: |
            line one
            line two
        run: '[[ "$MULTI" == "line one"$''\n''"line two"* ]]'
      - name: Reads install.sh without running it
        run: |
          bash -n install.sh
          grep -q ran-install install.sh
      - name: Fills the expressions it knows
        run: '[[ "${{ github.workspace }}" == "$GITHUB_WORKSPACE" && "${{ github.event_name }}" == push ]]'
YAML

cat >"$REPO/.github/workflows/bad.yml" <<'YAML'
name: bad
on:
  push:
    branches: [main]
jobs:
  broken:
    runs-on: ubuntu-latest
    steps:
      - name: Fails
        run: |
          echo "the reason it failed"
          exit 3
      - name: Never runs after a failure
        run: touch ran-after-failure
      - name: Runs anyway
        if: always()
        run: touch ran-always
YAML

cat >"$REPO/.github/workflows/danger.yml" <<'YAML'
name: danger
on:
  push:
    branches: [main]
jobs:
  host:
    runs-on: ubuntu-latest
    steps:
      - name: Needs root
        run: sudo -n true; touch ran-sudo
      - name: Runs the installer
        run: ACFS_CI=true bash install.sh --yes
      - name: Runs the installer directly
        run: cd . && ./install.sh
      - name: Updates the host
        run: acfs update --yes; touch ran-update
      - name: Uses a container engine
        run: docker ps; touch ran-docker
      - name: Needs a secret
        run: echo "${{ secrets.TOKEN }}"; touch ran-secret
      - name: Conditional
        if: github.event_name == 'workflow_dispatch'
        run: touch ran-conditional
  tools:
    runs-on: ubuntu-latest
    steps:
      - name: Installs a tool
        run: cargo install --git https://example.invalid/tool; touch ran-cargo
      - name: Uses the tool
        run: touch ran-tool-user
  boxed:
    runs-on: ubuntu-latest
    container:
      image: ubuntu:24.04
    steps:
      - run: touch ran-container
  gated:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - run: touch ran-gated
YAML

cat >"$REPO/.github/workflows/scheduled.yml" <<'YAML'
name: scheduled
on:
  schedule:
    - cron: '0 0 * * *'
  push:
    branches: [release]
jobs:
  nightly:
    runs-on: ubuntu-latest
    steps:
      - run: touch ran-scheduled
YAML

cat >"$REPO/.github/workflows/narrow.yml" <<'YAML'
name: narrow
on:
  push:
    branches: [main]
    paths:
      - 'only/**'
jobs:
  narrow:
    runs-on: ubuntu-latest
    steps:
      - name: Narrow step
        run: touch ran-narrow
YAML

cat >"$REPO/.github/workflows/production-smoke.yml" <<'YAML'
name: production smoke
on:
  push:
    branches: [main]
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - run: touch ran-production
YAML

git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
printf 'two\n' >"$REPO/other/b.txt"
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -q -am "touch other"

export CALLER_HOME="$HOME"

echo "list"
run_runner --list
check "--list exits 0" rc_is 0
check "--list runs nothing" no_marker always
check "--list plans good.yml's steps" out_has "RUN   good.yml › first › Sees what an earlier step wrote to GITHUB_ENV"
check "a uses: step is skipped" out_has "SKIP  good.yml › first › actions/checkout@v4: uses: actions/checkout@v4"
check "a workflow that never runs on a push to main is left out" out_lacks "scheduled.yml"
check "production smoke is skipped with its reason" out_has "SKIP  production-smoke.yml: tests the deployed site"

echo "danger"
run_runner --workflow danger.yml
check "danger.yml has nothing to run, so it passes" rc_is 0
check "sudo is skipped" out_has "Needs root: needs root or a package manager"
check "bash install.sh is skipped" out_has "Runs the installer: runs install.sh on this host"
check "./install.sh is skipped" out_has "Runs the installer directly: runs install.sh on this host"
check "acfs update is skipped" out_has "Updates the host: runs acfs update on this host"
check "docker is skipped" out_has "Uses a container engine: needs a container engine"
check "an unknown expression is skipped" out_has 'Needs a secret: needs ${{ secrets.TOKEN }}'
check "a step if: is skipped" out_has "Conditional: if: github.event_name == 'workflow_dispatch'"
check "a tool install is skipped" out_has "Installs a tool: installs a tool on this host"
check "the steps after a tool install are skipped" out_has "Uses the tool: step 1 installs a tool the job then uses"
check "a container job is skipped" out_has "SKIP  danger.yml › boxed: runs in a container"
check "a job if: is skipped" out_has "SKIP  danger.yml › gated: job if:"
for marker in sudo install update docker secret conditional cargo tool-user container gated; do
    check "never ran: $marker" no_marker "$marker"
done

echo "run"
run_runner --workflow good.yml --workflow bad.yml
check "a failing step fails the run" rc_is 1
check "good.yml's steps pass" out_has "PASS  good.yml › first › Runs in the step's working-directory with the merged env"
check "GITHUB_ENV carries to the next step" out_has "PASS  good.yml › first › Sees what an earlier step wrote to GITHUB_ENV"
check "GITHUB_PATH carries to the next step" out_has "PASS  good.yml › first › Sees what an earlier step added to GITHUB_PATH"
check "a multi-line env value stays whole" out_has "PASS  good.yml › first › Keeps a multi-line env value whole"
check "bash -n install.sh runs" out_has "PASS  good.yml › first › Reads install.sh without running it"
check "known expressions are filled" out_has "PASS  good.yml › first › Fills the expressions it knows"
check "the failure is reported with its exit code" out_has "FAIL  bad.yml › broken › Fails (exit 3"
check "the failing step's output is shown" out_has "| the reason it failed"
check "the rest of the job is skipped" out_has "Never runs after a failure: an earlier step in the job failed"
check "the step after a failure never ran" no_marker after-failure
check "an if: always() step still runs" out_has "PASS  bad.yml › broken › Runs anyway"
check "the summary names the failure" out_has "failed: bad.yml › broken › Fails"
FAIL_LOG="$(sed -n 's/^FAIL  bad.yml › broken › Fails (.*; log \(.*\))$/\1/p' <<<"$OUT")"
check "the failing step's log is kept" grep -qF "the reason it failed" "$FAIL_LOG"
check "install.sh never ran" no_marker install
rm -f -- "$REPO"/ran-*

echo "since"
run_runner --since HEAD~1 --workflow narrow.yml
check "--since: an unmatched paths filter skips the workflow" out_has "SKIP  narrow.yml: no changed file matches its paths"
check "--since: the narrow step never ran" no_marker narrow
printf 'two\n' >"$REPO/only/a.txt"
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -q -am "touch only"
run_runner --since HEAD~1 --workflow narrow.yml
check "--since: a matching file runs the workflow" out_has "PASS  narrow.yml › narrow › Narrow step"

echo "usage"
run_runner --bogus
check "an unknown option exits 2" rc_is 2

echo
echo "run_ci_workflows_locally: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
