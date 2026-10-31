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
# The commands can't use the host's sudo either (acfs-2fhq): they run
# with no_new_privs, so no setuid program gains root, and a sudo first
# on PATH refuses each call by name. ACFS_GATE_ALLOW_SUDO=1 turns that off.
#
# Steps, in order (each one runs even when an earlier one failed):
#   manifest    generate:validate, generate --diff, bun test
#   policy      policy_lint.sh, lint_rch_offload_policy.sh
#   lint (step "shellcheck"): ShellCheck over every tracked *.sh, and
#               every tracked *.bats as unit-bats.yml does, then CI's
#               installer.yml jobs (the scripts its ShellCheck job runs)
#   ci          run_ci_workflows_locally.sh (--since REF when given)
#
# The fork deploys no website, so the gate runs no apps/web checks.
#
# rch offloads Rust builds, not bun's. So where a systemd user manager
# runs, the manifest step runs each bun command in a user scope with a
# memory cap (--bun-memory-max); one that reaches it is killed and named
# (acfs-dpvr). Without a user manager, it runs without a cap.
#
# Run it in the gate worktree at the commit you push, after
# 'bun install --frozen-lockfile': the CI steps write into the tree.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALL_STEPS=(manifest policy shellcheck ci)

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
                          policy, shellcheck, ci
  --tmp-parent DIR        Where the temp root goes (default: /tmp, as
                          in CI; it must be traversable by other users)
  --bun-memory-max SIZE   The memory cap of each bun command of the
                          manifest step, in systemd's units (default:
                          4G), or none
  --keep                  Keep the temp root, for debugging a failure
  -h, --help              Show this help

Environment:
  ACFS_GATE_ALLOW_SUDO    1 lets the commands use this host's sudo, for a
                          test that needs root. Otherwise they run with
                          no_new_privs, and a sudo first on PATH refuses
                          each call; the gate lists them at the end

Exit status: 0 when every step passed, 1 when one failed, 2 on bad usage.
USAGE
}

ROOT="$REPO_ROOT"
SINCE=""
STEPS=()
TMP_PARENT="/tmp"
KEEP=false
COMMAND=()
# Peak measured on 2026-10-23, each command alone in a scope (cgroup
# memory.peak): manifest bun test 0.3 GiB. The cap leaves room above it
# and stops a runaway.
BUN_MEMORY_MAX="4G"

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
        --tmp-parent) [[ $# -ge 2 ]] || { echo "run_gate: --tmp-parent needs a directory" >&2; exit 2; }; TMP_PARENT="$2"; shift 2 ;;
        --bun-memory-max)
            [[ $# -ge 2 && "$2" =~ ^([1-9][0-9]*[KMGT]|none)$ ]] \
                || { echo "run_gate: --bun-memory-max needs a size such as 4G, or none" >&2; exit 2; }
            BUN_MEMORY_MAX="$2"; shift 2 ;;
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

# Caches stay where the caller keeps them: the fresh HOMEs below would
# otherwise refetch every package.
REAL_HOME="$HOME"
export BUN_INSTALL_CACHE_DIR="${BUN_INSTALL_CACHE_DIR:-$REAL_HOME/.bun/install/cache}"
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
SUDO_LOG="$GATE_ROOT/logs/sudo-refused.log"

cleanup() {
    local status=$?
    if [[ -s "$SUDO_LOG" ]]; then
        echo "run_gate: refused these sudo calls (directory: call):" >&2
        sed 's/^/  /' "$SUDO_LOG" >&2 || true
    fi
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

# A test that misses one stub must not reach the host's sudo: on
# 2026-10-24 one ran `sudo -n rm` on the development host through its
# passwordless sudo (acfs-2fhq). The scripts take sudo from /usr/bin, not
# PATH, so the commands run with no_new_privs, under which no setuid
# program gains root by any path. The sudo first on PATH names the call.
NO_NEW_PRIVS=()
if [[ "${ACFS_GATE_ALLOW_SUDO:-}" == 1 ]]; then
    echo "run_gate: ACFS_GATE_ALLOW_SUDO=1: the commands may use this host's sudo" >&2
else
    mkdir -m 0755 "$GATE_ROOT/bin"
    sudo_log_q="$(printf '%q' "$SUDO_LOG")"
    cat >"$GATE_ROOT/bin/sudo" <<SHIM
#!/usr/bin/env bash
# run_gate's sudo (acfs-2fhq): a test must not use the host's sudo.
printf 'run_gate: refused: sudo %s (stub it, or set ACFS_GATE_ALLOW_SUDO=1 for a test that needs root)\n' "\$*" >&2
printf '%s: sudo %s\n' "\$PWD" "\$*" >>$sudo_log_q 2>/dev/null || true
exit 1
SHIM
    chmod 0755 "$GATE_ROOT/bin/sudo"
    export PATH="$GATE_ROOT/bin:$PATH"
    if command -v setpriv >/dev/null 2>&1; then
        NO_NEW_PRIVS=(setpriv --no-new-privs)
    else
        echo "run_gate: no setpriv: only the sudo on PATH guards the commands, not /usr/bin/sudo" >&2
    fi
fi

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
    run_cmd_shown "$label" "$dir" "$*" "$@"
}

# run_cmd_shown <label> <dir> <what the log says> <command...>: run_cmd,
# logging the command as given.
run_cmd_shown() {
    local label="$1" dir="$2" shown="$3"
    shift 3
    new_home
    echo "run_gate: [$label] $shown" >&2
    if (cd "$dir" && HOME="$STEP_HOME" "${NO_NEW_PRIVS[@]}" "$@"); then
        PASSED+=("$label")
        return 0
    fi
    FAILED+=("$label")
    return 1
}

# The bun steps' memory cap. BUN_SCOPE is what goes in front of a bun
# step: a systemd user scope capped at BUN_MEMORY_MAX, or nothing.
BUN_SCOPE=()
BUN_SCOPE_DECIDED=false
# Runs in the scope: the step, then, when the kernel killed a process in
# the scope at the cap while it ran, a note, and the end of the step's
# other processes (what OOMPolicy=stop did, without its race).
# shellcheck disable=SC2016 # expanded by the scope's bash
BUN_SCOPE_RUNNER='
cap="$1"
shift
events="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.events"
oom_kills() { sed -n "s/^oom_kill //p" "$events" 2>/dev/null || true; }
before="$(oom_kills)"
"$@"
rc=$?
if [[ "$(oom_kills)" != "$before" ]]; then
    echo "run_gate: the step reached the bun memory cap ($cap), and the kernel killed a process in it; --bun-memory-max raises the cap" >&2
    ((rc != 0)) || rc=1
    while read -r pid; do
        [[ "$pid" == "$$" ]] || kill "$pid" 2>/dev/null || true
    done <"${events%/memory.events}/cgroup.procs"
fi
exit "$rc"'

bun_scope_decide() {
    local state
    [[ "$BUN_SCOPE_DECIDED" == false ]] || return 0
    BUN_SCOPE_DECIDED=true
    if [[ "$BUN_MEMORY_MAX" == none ]]; then
        echo "run_gate: the bun commands run without a memory cap (--bun-memory-max none)" >&2
        return 0
    fi
    state="$(systemctl --user is-system-running 2>/dev/null)" || true
    if ! command -v systemd-run >/dev/null 2>&1 || [[ "$state" != running && "$state" != degraded ]]; then
        echo "run_gate: no systemd user manager (${state:-none}); the bun commands run without a memory cap" >&2
        return 0
    fi
    echo "run_gate: each bun command runs in a user scope capped at $BUN_MEMORY_MAX" >&2
    # --expand-environment=no: systemd-run would expand ${...} and $$ in
    # the runner itself. OOMPolicy=continue: a scope's default
    # (DefaultOOMPolicy=stop) has systemd terminate the whole scope after
    # an OOM kill, and that can kill the runner before it reports
    # (acfs-x6cj).
    BUN_SCOPE=(systemd-run --user --scope --quiet --expand-environment=no -p "MemoryMax=$BUN_MEMORY_MAX"
        -p MemorySwapMax=0 -p OOMPolicy=continue -- bash -c "$BUN_SCOPE_RUNNER" run_gate_bun "$BUN_MEMORY_MAX")
}

# run_bun <label> <dir> <command...>: run_cmd, under the bun memory cap.
run_bun() {
    local label="$1" dir="$2"
    shift 2
    bun_scope_decide
    run_cmd_shown "$label" "$dir" "$*${BUN_SCOPE[*]:+ (in a user scope, MemoryMax=$BUN_MEMORY_MAX)}" \
        "${BUN_SCOPE[@]}" "$@"
}

step_manifest() {
    local dir="$ROOT/packages/manifest"
    run_bun "manifest: generate:validate" "$dir" bun run generate:validate || true
    run_bun "manifest: generate --diff" "$dir" bun run generate --diff || true
    run_bun "manifest: bun test" "$dir" bun test || true
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
    run_cmd "shellcheck: tracked *.bats" "$ROOT" bash -c 'git ls-files -z "*.bats" | xargs -0 shellcheck' || true
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

echo "run_gate: temp root $GATE_ROOT (TMPDIR and every HOME)" >&2
if [[ ${#COMMAND[@]} -gt 0 ]]; then
    # One command: its own exit status, not the summary's.
    new_home
    rc=0
    HOME="$STEP_HOME" "${NO_NEW_PRIVS[@]}" "${COMMAND[@]}" || rc=$?
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
