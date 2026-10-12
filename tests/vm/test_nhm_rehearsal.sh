#!/usr/bin/env bash
# ============================================================
# The nhm method rehearsal (plan-v8 section 7; METHOD-MATRIX.md section E)
#
# Runs a release's steps of E00-E21 in a bwrap sandbox on this machine
# (tests/vm/lib/nhm_sandbox.sh): / read-only, its own HOME, TMPDIR and
# network namespace, its own herdr server, nhm from a verified release
# archive or a local build. The operator's ruling of 2026-10-12: the
# rehearsal is sandbox only; no Incus, no container, no install.sh, never
# the live herdr server or Agent Mail. Each step runs as one script in
# the sandbox and reports PASS or FAIL per pass condition; its output is
# the step's evidence.
#
# Usage: tests/vm/test_nhm_rehearsal.sh --authorised RUN-ID
#            (--nhm-version X.Y.Z | --nhm-build DIR)
#            [--release 0.1|0.2|0.3|0.4] [--steps E00,E01,...] [--root DIR]
#
# --authorised is required, and names the run: sandbox runs are
# authorised under F.12 (SageOak, 2026-10-12), and each run's id goes into
# its evidence. Nothing is made without it.
#
# --release picks the steps the release implements (default 0.1):
#   0.1  E00 E01 E14 E16
#   0.2  adds E02 E04 E08 E09 E10 E11 E12 E17 E18
#   0.3  adds E03 E05 E06 E07 E13 E15 E21
#   0.4  adds E19 E20
# --steps runs only the named steps. A step the harness does not automate
# yet counts as FAIL, never as a pass. Parts only the operator can do from
# the Mac are MANUAL; a run with them open does not pass.
#
# The matrix's install parts (install.sh, the checksum pin, acfs machine
# verify) are out of the sandbox's scope (accepted by the operator). Some
# pass conditions name forms nhm does not have (`nhm doctor --mode
# active`): the harness checks nhm's nearest form and names it.
#
# --root is the sandbox root (default $NHM_SANDBOX_PARENT/$USER/
# nhm-rehearsal/RUN-ID, NHM_SANDBOX_PARENT defaulting to /data/tmp). It
# must not exist yet and is never in this checkout. The evidence is in
# ROOT/evidence; the harness removes nothing.
#
# The last line is "RESULT: pass", "RESULT: fail" or "RESULT: skip
# (<why>)"; a skip exits 77, so it never reads as a pass.
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT_DIR/tests/vm/lib/nhm_sandbox.sh"

usage() {
    sed -n 's/^# Usage: //p; s/^#            /    /p' "${BASH_SOURCE[0]}" | head -n 3 >&2
    exit 2
}

AUTHORISED=""
RELEASE="0.1"
STEPS=""
ROOT=""
NHM_VERSION=""
NHM_BUILD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --authorised) [[ $# -ge 2 ]] || usage; AUTHORISED="$2"; shift 2 ;;
        --release) [[ $# -ge 2 ]] || usage; RELEASE="$2"; shift 2 ;;
        --steps) [[ $# -ge 2 ]] || usage; STEPS="$2"; shift 2 ;;
        --root) [[ $# -ge 2 ]] || usage; ROOT="$2"; shift 2 ;;
        --nhm-version) [[ $# -ge 2 ]] || usage; NHM_VERSION="$2"; shift 2 ;;
        --nhm-build) [[ $# -ge 2 ]] || usage; NHM_BUILD="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -z "$AUTHORISED" ]]; then
    echo "refused: name the run with --authorised RUN-ID" >&2
    exit 2
fi
[[ "$AUTHORISED" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
    || { echo "--authorised takes a run id of letters, digits, '.', '_' and '-'" >&2; exit 2; }
if [[ -n "$NHM_VERSION" && -n "$NHM_BUILD" || -z "$NHM_VERSION$NHM_BUILD" ]]; then
    echo "give one of --nhm-version X.Y.Z or --nhm-build DIR" >&2
    exit 2
fi
[[ -z "$NHM_VERSION" || "$NHM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "--nhm-version takes X.Y.Z" >&2; exit 2; }

# The steps of each release (cumulative).
release_steps() {
    case "$1" in
        0.1) echo "E00 E01 E14 E16" ;;
        0.2) echo "$(release_steps 0.1) E02 E04 E08 E09 E10 E11 E12 E17 E18" ;;
        0.3) echo "$(release_steps 0.2) E03 E05 E06 E07 E13 E15 E21" ;;
        0.4) echo "$(release_steps 0.3) E19 E20" ;;
        *) return 1 ;;
    esac
}
ALL_STEPS="$(release_steps "$RELEASE")" || { echo "unknown release: $RELEASE (0.1, 0.2, 0.3 or 0.4)" >&2; exit 2; }
if [[ -n "$STEPS" ]]; then
    RUN_STEPS="${STEPS//,/ }"
    for s in $RUN_STEPS; do
        [[ " $ALL_STEPS " == *" $s "* ]] || { echo "step $s is not one of release $RELEASE's: $ALL_STEPS" >&2; exit 2; }
    done
else
    RUN_STEPS="$ALL_STEPS"
fi
ROOT="${ROOT:-${NHM_SANDBOX_PARENT:-/data/tmp}/${USER:-rehearsal}/nhm-rehearsal/$AUTHORISED}"
if [[ -e "$ROOT" ]]; then
    echo "the sandbox root $ROOT exists; pass a new run id or --root" >&2
    exit 2
fi

skip() { printf '[SKIP] %s\n' "$1"; printf 'RESULT: skip (%s)\n' "$1"; exit 77; }
[[ -r "$LIB" ]] || skip "tests/vm/lib/nhm_sandbox.sh is missing"
command -v bwrap >/dev/null 2>&1 || skip "bwrap is not installed"
command -v herdr >/dev/null 2>&1 || skip "herdr is not on PATH (the sandbox runs its own server from it)"

# shellcheck source=tests/vm/lib/nhm_sandbox.sh
source "$LIB"
sandbox_init "$ROOT" || exit 2
EVIDENCE="$SANDBOX_EVIDENCE"
sandbox_bin herdr
for tool in dcg jq git; do
    if command -v "$tool" >/dev/null 2>&1; then
        sandbox_bin "$tool"
    fi
done
if [[ -n "$NHM_VERSION" ]]; then
    sandbox_nhm_release "$NHM_VERSION" || { echo "RESULT: fail (nhm $NHM_VERSION could not be fetched and verified)"; exit 1; }
else
    sandbox_nhm_build "$NHM_BUILD" || { echo "RESULT: fail (no nhm build in $NHM_BUILD)"; exit 1; }
fi
{
    printf 'run: %s\nrelease: %s\nsteps: %s\nacfs: %s\nnhm: %s\nstarted: %s\n' "$AUTHORISED" "$RELEASE" "$RUN_STEPS" \
        "$(git -C "$ROOT_DIR" rev-parse HEAD)" "${NHM_VERSION:-build $NHM_BUILD}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$EVIDENCE/run.txt"

# --- Inside the sandbox ----------------------------------------------------
# These functions run in the step script, not here: each step is one
# sandbox_exec, so its herdr server lives and ends with the step.

# check LABEL CMD...: PASS or FAIL for one pass condition.
check() {
    local label="$1"
    shift
    if "$@"; then echo "PASS $label"; else echo "FAIL $label"; fi
}
# show LABEL CMD...: runs CMD, prints it and its output and exit code.
show() {
    local label="$1" rc=0
    shift
    echo "### $label"
    echo "\$ $*"
    "$@" || rc=$?
    echo "(exit $rc)"
    return "$rc"
}
manual() { echo "MANUAL $1"; }

# E00 Install and verify. In the sandbox: the release archive verified
# against its SHA256SUMS (sandbox_nhm_release), nhm version, and `nhm
# doctor --json` with no failing check and herdr on nhm's protocol (nhm's
# doctor has no --mode active). The install.sh, pin and machine-verify
# parts are out of scope.
step_E00() {
    local doc
    check "E00: nhm version --json answers" show "nhm version" nhm version --json
    doc="$(nhm doctor --json --no-mail 2>/dev/null || true)"
    echo "### nhm doctor --json --no-mail"
    echo "$doc"
    check "E00: no doctor check fails" jq -e '[.result.checks[]? | select(.result == "fail")] | length == 0' <<<"$doc"
    check "E00: herdr answers on nhm's protocol" jq -e '.result.checks[]? | select(.name == "herdr" and .result == "ok")' <<<"$doc"
    check "E00: this herdr server is enrolled" jq -e '.result.checks[]? | select(.name == "enrollment" and .result == "ok")' <<<"$doc"
    manual "E00: attach from the Mac client and run nhm bind --print-client"
}

# E01 Foundation and readiness: quota with UTC resets, --robot-spawn's
# dry run with admission.decision, the guard states per kind.
step_E01() {
    local quota spawn doc kind reset
    # A fresh sandbox has no quota observation: feed one Claude statusLine
    # payload, as Claude Code's statusLine does through record-claude.
    reset=$(($(date +%s) + 3600))
    printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%d}}}' "$reset" |
        show "nhm quota record-claude" nhm quota record-claude
    quota="$(nhm quota --json 2>&1 || true)"
    echo "### nhm quota --json"
    echo "$quota"
    check "E01: nhm quota --json answers" jq -e '.result' <<<"$quota"
    check "E01: quota resets are UTC" grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' <<<"$quota"
    mkdir -p "$HOME/fixture" && git -C "$HOME/fixture" init -q 2>/dev/null || true
    spawn="$(cd "$HOME/fixture" && nhm --robot-spawn=fixture --spawn-dir="$HOME/fixture" --spawn-cc=1 --spawn-cod=1 --dry-run 2>&1 || true)"
    echo "### nhm --robot-spawn=fixture ... --dry-run"
    echo "$spawn"
    check "E01: --robot-spawn --dry-run returns admission.decision" \
        jq -e '.. | objects | select(has("admission")) | .admission.decision' <<<"$spawn"
    doc="$(nhm doctor --json --no-mail 2>/dev/null || true)"
    for kind in claude codex agy pi; do
        check "E01: the doctor reports $kind's guard state" \
            jq -e --arg k "$kind" '.result.checks[]? | select(.name | startswith("guard " + $k + " "))' <<<"$doc"
    done
}

# --- Outside: run each step as one script in the sandbox ------------------

PASS=0
FAIL=0
MANUAL=0
run_step() {
    local step="$1" script="$ROOT/steps/$1.sh" out="$EVIDENCE/$1.txt"
    mkdir -p "$ROOT/steps"
    {
        printf '#!/usr/bin/env bash\nset -uo pipefail\nsource "$SANDBOX_LIB"\n'
        declare -f check show manual "step_$step"
        printf 'sandbox_herdr_start || { echo "FAIL %s: the sandbox herdr server"; exit 1; }\n' "$step"
        printf 'show "enroll" nhm admin instance enroll --json || echo "FAIL %s: enroll"\n' "$step"
        printf 'step_%s\nsandbox_herdr_stop\n' "$step"
    } >"$script"
    sandbox_exec bash "$script" >"$out" 2>&1 || true
    local p f m
    p="$(grep -c '^PASS ' "$out" || true)"
    f="$(grep -c '^FAIL ' "$out" || true)"
    m="$(grep -c '^MANUAL ' "$out" || true)"
    grep -E '^(PASS|FAIL|MANUAL) ' "$out" | sed 's/^/  /' || true
    if [[ "$p$f" == "00" ]]; then
        echo "  FAIL $step: the step reported nothing (see $out)"
        f=1
    fi
    PASS=$((PASS + p))
    FAIL=$((FAIL + f))
    MANUAL=$((MANUAL + m))
}

for step in $RUN_STEPS; do
    echo "== $step"
    if declare -F "step_$step" >/dev/null; then
        run_step "$step"
    else
        echo "  FAIL $step: not automated yet (acfs-9hkh.31)"
        printf 'not automated yet\n' >"$EVIDENCE/$step.txt"
        FAIL=$((FAIL + 1))
    fi
done

printf 'finished: %s\npassed: %d\nfailed: %d\nmanual: %d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PASS" "$FAIL" "$MANUAL" >>"$EVIDENCE/run.txt"
echo "evidence: $EVIDENCE"
if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: fail"
    exit 1
fi
if [[ "$MANUAL" -gt 0 ]]; then
    echo "RESULT: fail (the MANUAL parts are the operator's; a run with them open does not pass)"
    exit 1
fi
echo "RESULT: pass"
