#!/usr/bin/env bash
# ============================================================
# Run the full gate under one temp root (acfs-6nqh)
#
# The gate used to be a list of commands in AGENTS.md, each run
# with HOME="$(mktemp -d)", and nothing removed those homes or what
# the tests left in TMPDIR: tens of GB a day on a busy host. This
# runs every gate step with TMPDIR and HOME inside a single root,
# and removes the root on exit, on success or failure.
#
# Steps, in order (each one runs even when an earlier one failed):
#   manifest    generate:validate, generate --diff, bun test
#   policy      policy_lint.sh, lint_rch_offload_policy.sh
#   lint (step "shellcheck"): ShellCheck over every tracked *.sh,
#               then CI's installer.yml jobs (the scripts its
#               ShellCheck job runs)
#   ci          run_ci_workflows_locally.sh (--since REF when given)
#   web         apps/web type-check, lint, build, then Playwright
#               under the host-wide browser lock
#
# Run it in the gate worktree at the commit you push, after
# 'bun install --frozen-lockfile': the CI steps write into the tree.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALL_STEPS=(manifest policy shellcheck ci web)

usage() {
    cat <<'USAGE'
Usage: bash scripts/tests/run_gate.sh [options]
       bash scripts/tests/run_gate.sh [--keep] [--tmp-parent DIR] -- COMMAND...

Runs the full gate with TMPDIR and HOME under one temp root, which it
removes on exit. With -- COMMAND, it runs that one command instead (a
single test, say), from the current directory, the same way.

Options:
  --root DIR              Checkout to gate (default: this one)
  --since REF             Pass --since REF to the CI workflow step
  --step NAME             Run only this step (repeatable): manifest,
                          policy, shellcheck, ci, web
  --browser-project NAME  Playwright project to run (repeatable;
                          default: every project in the config)
  --tmp-parent DIR        Where the temp root goes (default: /tmp, as
                          in CI; it must be traversable by other users)
  --keep                  Keep the temp root, for debugging a failure
  -h, --help              Show this help

Environment:
  ACFS_BROWSER_GATE_LOCK  The host-wide Playwright lock file (default:
                          /data/tmp/acfs-browser-gate.lock when /data/tmp
                          exists, else /tmp/acfs-browser-gate.lock)

Exit status: 0 when every step passed, 1 when one failed, 2 on bad usage.
USAGE
}

ROOT="$REPO_ROOT"
SINCE=""
STEPS=()
BROWSER_PROJECTS=()
TMP_PARENT="/tmp"
KEEP=false
COMMAND=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) [[ $# -ge 2 ]] || { echo "run_gate: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
        --since) [[ $# -ge 2 ]] || { echo "run_gate: --since needs a git ref" >&2; exit 2; }; SINCE="$2"; shift 2 ;;
        --step)
            [[ $# -ge 2 ]] || { echo "run_gate: --step needs a name" >&2; exit 2; }
            case " ${ALL_STEPS[*]} " in
                *" $2 "*) STEPS+=("$2") ;;
                *) echo "run_gate: unknown step: $2 (one of: ${ALL_STEPS[*]})" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --browser-project) [[ $# -ge 2 ]] || { echo "run_gate: --browser-project needs a name" >&2; exit 2; }; BROWSER_PROJECTS+=("$2"); shift 2 ;;
        --tmp-parent) [[ $# -ge 2 ]] || { echo "run_gate: --tmp-parent needs a directory" >&2; exit 2; }; TMP_PARENT="$2"; shift 2 ;;
        --keep) KEEP=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; COMMAND=("$@"); break ;;
        *) echo "run_gate: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ "${#COMMAND[@]}" -gt 0 && "${#STEPS[@]}" -gt 0 ]]; then
    echo "run_gate: --step and -- COMMAND don't mix" >&2
    exit 2
fi
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=("${ALL_STEPS[@]}")
ROOT="$(cd "$ROOT" && pwd)"
[[ -d "$TMP_PARENT" ]] || { echo "run_gate: --tmp-parent is not a directory: $TMP_PARENT" >&2; exit 2; }

if [[ -z "${ACFS_BROWSER_GATE_LOCK:-}" ]]; then
    if [[ -d /data/tmp ]]; then
        ACFS_BROWSER_GATE_LOCK=/data/tmp/acfs-browser-gate.lock
    else
        ACFS_BROWSER_GATE_LOCK=/tmp/acfs-browser-gate.lock
    fi
fi

# Caches and browsers stay where the caller keeps them: the fresh HOMEs
# below would otherwise refetch every package and find no browser.
REAL_HOME="$HOME"
export BUN_INSTALL_CACHE_DIR="${BUN_INSTALL_CACHE_DIR:-$REAL_HOME/.bun/install/cache}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${XDG_CACHE_HOME:-$REAL_HOME/.cache}/ms-playwright}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$REAL_HOME/.cache}/uv}"
unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME

# CI's umask. Group-writable temp dirs fail upstream's ownership checks.
umask 022

GATE_ROOT="$(mktemp -d "$TMP_PARENT/acfs-gate.XXXXXX")"
# 0755, as CI's checkout: tests that run a CLI as another user must
# traverse TMPDIR (a 0700 chain fails them), and the fleet and profile
# tools refuse a group- or world-writable dir that root doesn't own
# (unsafe_evidence_directory), so not 1777 either.
chmod 0755 "$GATE_ROOT"
mkdir -m 0755 "$GATE_ROOT/tmp"
mkdir "$GATE_ROOT/logs"

cleanup() {
    local status=$?
    if [[ "$KEEP" == true ]]; then
        echo "run_gate: kept the temp root: $GATE_ROOT" >&2
    else
        # Tests leave read-only dirs behind; make them removable first.
        chmod -R u+rwX -- "$GATE_ROOT" 2>/dev/null || true
        rm -rf -- "$GATE_ROOT"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export TMPDIR="$GATE_ROOT/tmp"
export TMP="$TMPDIR" TEMP="$TMPDIR"

STEP_HOME=""
new_home() {
    STEP_HOME="$(mktemp -d "$GATE_ROOT/home.XXXXXX")"
}

FAILED=()
PASSED=()

# run_cmd <label> <dir> <command...>: one command, its own fresh HOME.
run_cmd() {
    local label="$1" dir="$2"
    shift 2
    new_home
    echo "run_gate: [$label] $*" >&2
    if (cd "$dir" && HOME="$STEP_HOME" "$@"); then
        PASSED+=("$label")
        return 0
    fi
    FAILED+=("$label")
    return 1
}

step_manifest() {
    local dir="$ROOT/packages/manifest"
    run_cmd "manifest: generate:validate" "$dir" bun run generate:validate || true
    run_cmd "manifest: generate --diff" "$dir" bun run generate --diff || true
    run_cmd "manifest: bun test" "$dir" bun test || true
}

step_policy() {
    run_cmd "policy: policy_lint" "$ROOT" bash scripts/lib/policy_lint.sh || true
    run_cmd "policy: rch offload lint" "$ROOT" bash scripts/tests/lint_rch_offload_policy.sh || true
}

# True when the ci step will run installer.yml anyway.
ci_runs_installer_yml() {
    [[ " ${STEPS[*]} " == *" ci "* ]] || return 1
    [[ -n "$SINCE" ]] || return 0
    bash "$ROOT/scripts/tests/run_ci_workflows_locally.sh" --root "$ROOT" --list --since "$SINCE" 2>/dev/null \
        | grep -q '^RUN  *installer\.yml '
}

step_shellcheck() {
    local version
    version="$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')" || true
    if [[ "$version" != "0.9.0" ]]; then
        echo "run_gate: CI pins shellcheck 0.9.0, but the first on PATH is '${version:-none}'" >&2
        FAILED+=("shellcheck: version")
        return 0
    fi
    run_cmd "shellcheck: tracked *.sh" "$ROOT" bash -c 'git ls-files -z "*.sh" | xargs -0 shellcheck' || true
    if ci_runs_installer_yml; then
        echo "run_gate: [shellcheck] installer.yml's jobs run in the ci step" >&2
        return 0
    fi
    run_cmd "shellcheck: installer.yml jobs" "$ROOT" \
        bash scripts/tests/run_ci_workflows_locally.sh --workflow installer.yml --log-dir "$GATE_ROOT/logs/installer" || true
}

step_ci() {
    local args=(--log-dir "$GATE_ROOT/logs/ci")
    [[ -z "$SINCE" ]] || args+=(--since "$SINCE")
    run_cmd "ci: workflows${SINCE:+ since $SINCE}" "$ROOT" bash scripts/tests/run_ci_workflows_locally.sh "${args[@]}" || true
}

free_port() {
    python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

step_web() {
    local dir="$ROOT/apps/web" port project
    run_cmd "web: type-check" "$dir" bun run type-check || true
    run_cmd "web: lint" "$dir" bun run lint || true
    run_cmd "web: build" "$dir" bun run build || true
    local pw_args=()
    for project in "${BROWSER_PROJECTS[@]}"; do
        pw_args+=("--project=$project")
    done
    port="$(free_port)"
    # One Playwright run at a time on the host: concurrent runs time out.
    run_cmd "web: playwright" "$dir" env PW_PORT="$port" \
        flock "$ACFS_BROWSER_GATE_LOCK" bun run test -- "${pw_args[@]}" || true
}

echo "run_gate: temp root $GATE_ROOT (TMPDIR and every HOME)" >&2
if [[ ${#COMMAND[@]} -gt 0 ]]; then
    # One command: its own exit status, not the summary's.
    new_home
    rc=0
    HOME="$STEP_HOME" "${COMMAND[@]}" || rc=$?
    exit "$rc"
fi
for step in "${STEPS[@]}"; do
    "step_$step"
done

echo >&2
for label in "${PASSED[@]}"; do
    echo "PASS  $label" >&2
done
for label in "${FAILED[@]}"; do
    echo "FAIL  $label" >&2
done
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "run_gate: ${#FAILED[@]} failed; --keep keeps the step logs under the temp root" >&2
    exit 1
fi
echo "run_gate: all passed" >&2
