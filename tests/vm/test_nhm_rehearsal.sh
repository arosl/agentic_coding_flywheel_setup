#!/usr/bin/env bash
# ============================================================
# The nhm method rehearsal (plan-v8 section 7; METHOD-MATRIX.md section E)
#
# Runs a release's steps of E00-E21 on a fresh, disposable Incus container
# that scripts/providers/incus.sh makes: ACFS from the committed HEAD, nhm
# from the manifest's stack.nhm. Each step writes its evidence to
# <evidence>/<step>.txt and reports ok or FAIL per pass condition.
#
# Usage: tests/vm/test_nhm_rehearsal.sh --authorised RUN-ID
#            [--release 0.1|0.2|0.3|0.4] [--steps E00,E01,...]
#            [--evidence DIR] <instance-name>
#
# --authorised is required: each run is the operator's call (plan-v8
# section 7, "authorised per run"); RUN-ID names that authorisation and
# goes into the evidence. Nothing is created without it.
#
# --release picks the steps the release implements (default 0.1):
#   0.1  E00 E01 E14 E16
#   0.2  adds E02 E04 E08 E09 E10 E11 E12 E17 E18
#   0.3  adds E03 E05 E06 E07 E13 E15 E21
#   0.4  adds E19 E20
# --steps runs only the named steps. A step the harness does not automate
# yet counts as FAIL, never as a pass, so a run passes only when every
# step it was asked for passed. Steps that need the operator's Mac (E00's
# attach, E18) report that part as manual; it does not pass on its own.
#
# The matrix's pass conditions name some forms nhm does not have (for
# example `nhm doctor --mode active`). The harness checks nhm's nearest
# form and names it, so the gap shows in the evidence.
#
# Evidence goes to evidence/rehearsal/<release>/<RUN-ID>/ in this checkout
# unless --evidence names another directory. It holds command output from
# the container: review it before you commit any of it (AGENTS.md rule 1).
#
# Needs: Incus after `scripts/providers/incus.sh host-setup`, network
# access to images: and GitHub. Never on the development machine itself:
# everything installs inside the container. The instance must not exist
# yet; the harness stops it at the end and never deletes it.
#
# The last line is "RESULT: pass", "RESULT: fail" or "RESULT: skip
# (<why>)"; a skip exits 77, so it never reads as a pass.
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$ROOT/scripts/providers/incus.sh"

usage() {
    sed -n 's/^# Usage: //p; s/^#            /    /p' "${BASH_SOURCE[0]}" | head -n 3 >&2
    exit 2
}

AUTHORISED=""
RELEASE="0.1"
STEPS=""
EVIDENCE=""
NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --authorised) [[ $# -ge 2 ]] || usage; AUTHORISED="$2"; shift 2 ;;
        --release) [[ $# -ge 2 ]] || usage; RELEASE="$2"; shift 2 ;;
        --steps) [[ $# -ge 2 ]] || usage; STEPS="$2"; shift 2 ;;
        --evidence) [[ $# -ge 2 ]] || usage; EVIDENCE="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) [[ -z "$NAME" ]] || usage; NAME="$1"; shift ;;
    esac
done

[[ -n "$NAME" ]] || usage
[[ "$NAME" =~ ^[a-z]([a-z0-9-]{0,48}[a-z0-9])?$ ]] \
    || { echo "the instance name must be at most 50 lowercase letters, digits and hyphens: $NAME" >&2; exit 2; }
if [[ -z "$AUTHORISED" ]]; then
    echo "refused: a rehearsal run is the operator's call; pass --authorised RUN-ID naming their go-ahead" >&2
    exit 2
fi
[[ "$AUTHORISED" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
    || { echo "--authorised takes a run id of letters, digits, '.', '_' and '-'" >&2; exit 2; }

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
EVIDENCE="${EVIDENCE:-$ROOT/evidence/rehearsal/$RELEASE/$AUTHORISED}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '[SKIP] %s\n' "$1"; printf 'RESULT: skip (%s)\n' "$1"; exit 77; }
# A part only the operator can do from the Mac: noted, and not a pass.
manual() { printf '  MANUAL %s\n' "$1"; printf 'MANUAL %s\n' "$1" >>"$EVIDENCE/manual.txt"; }

command -v incus >/dev/null 2>&1 || skip "incus is not installed"
command -v jq >/dev/null 2>&1 || skip "jq is not installed"
incus info </dev/null >/dev/null 2>&1 || skip "this user can't reach the Incus daemon (not in incus-admin?)"
incus image info images:ubuntu/26.04/cloud </dev/null >/dev/null 2>&1 || skip "the images: remote isn't reachable"
if incus info "$NAME" </dev/null >/dev/null 2>&1; then
    echo "instance $NAME already exists; pass a fresh name" >&2
    exit 2
fi
if [[ -e "$EVIDENCE" ]]; then
    echo "the evidence directory $EVIDENCE exists; pass a new run id or --evidence" >&2
    exit 2
fi
mkdir -p "$EVIDENCE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-nhm-rehearsal.XXXXXX")"
# The directory is flat: remove its files, then the directory, nothing else.
trap 'rm -f -- "$WORK"/*; rmdir -- "$WORK"' EXIT
ssh-keygen -q -t ed25519 -N '' -C acfs-nhm-rehearsal -f "$WORK/key"

{
    printf 'run: %s\nrelease: %s\nsteps: %s\nacfs: %s\nstarted: %s\n' "$AUTHORISED" "$RELEASE" "$RUN_STEPS" \
        "$(git -C "$ROOT" rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$EVIDENCE/run.txt"

echo "== create $NAME (the launcher: ACFS from HEAD, nhm from the manifest)"
create_rc=0
"$LAUNCHER" "$NAME" --ssh-key "$WORK/key.pub" >"$WORK/block" 2>"$WORK/create.log" || create_rc=$?
tail -n 15 "$WORK/create.log" | sed 's/^/  | /'
cp "$WORK/create.log" "$EVIDENCE/create.log"
if [[ "$create_rc" -ne 0 ]]; then
    fail "create exits 0 (exit $create_rc)"
    echo "RESULT: fail"
    exit 1
fi
sed -n '/^Host /,/^#/p' "$WORK/block" | grep -v '^#' >"$WORK/ssh_config"
grep -A1 -x '# Add to ~/.ssh/known_hosts on that machine:' "$WORK/block" | tail -n 1 >"$WORK/known_hosts"

# A login shell on the instance as ubuntu, so ~/.local/bin is on PATH.
on() {
    ssh -F "$WORK/ssh_config" -i "$WORK/key" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o ConnectTimeout=10 -o "UserKnownHostsFile=$WORK/known_hosts" "$NAME" bash -lc "$(printf '%q' "$1")" </dev/null
}
# record STEP LABEL COMMAND: runs it on the instance, keeps its output and
# exit code in the step's evidence, and prints the output.
record() {
    local step="$1" label="$2" cmd="$3" out rc=0
    out="$(on "$cmd" 2>&1)" || rc=$?
    printf '### %s\n$ %s\n%s\n(exit %d)\n\n' "$label" "$cmd" "$out" "$rc" >>"$EVIDENCE/$step.txt"
    printf '%s' "$out"
    return "$rc"
}

# --- The steps -------------------------------------------------------------

# E00 Install and verify. Matrix: `nhm doctor --json --mode active` passes;
# `acfs machine verify` shows the nhm line; checksums.yaml unchanged by
# the install; attach from the Mac. nhm's doctor has no --mode: the
# harness runs `nhm doctor --json` and requires no failing check.
step_E00() {
    local doc verify
    if doc="$(record E00 "nhm doctor" "nhm doctor --json")"; then
        pass "E00: nhm doctor --json exits 0"
    else
        fail "E00: nhm doctor --json exits 0"
    fi
    if jq -e '[.result.checks[]? | select(.result == "fail")] | length == 0' <<<"$doc" >/dev/null 2>&1; then
        pass "E00: no doctor check fails"
    else
        fail "E00: no doctor check fails"
    fi
    if jq -e '.result.checks[]? | select(.name == "herdr" and .result == "ok")' <<<"$doc" >/dev/null 2>&1; then
        pass "E00: herdr answers with nhm's protocol"
    else
        fail "E00: herdr answers with nhm's protocol"
    fi
    verify="$(record E00 "acfs machine verify" "acfs machine verify --read-only" || true)"
    if grep -qi 'nhm' <<<"$verify"; then
        pass "E00: acfs machine verify shows the nhm line"
    else
        fail "E00: acfs machine verify shows the nhm line"
    fi
    # The install verified against HEAD's pins and changed none of them.
    local want got
    want="$(git -C "$ROOT" show HEAD:checksums.yaml | sha256sum | cut -d' ' -f1)"
    got="$(record E00 "installed checksums.yaml" "sha256sum ~/.acfs/checksums.yaml" | cut -d' ' -f1 || true)"
    if [[ "$got" == "$want" ]]; then
        pass "E00: checksums.yaml unchanged by the install"
    else
        fail "E00: checksums.yaml unchanged by the install (HEAD $want, installed ${got:-none})"
    fi
    if record E00 "nhm version" "nhm version --json" >/dev/null; then
        pass "E00: nhm version --json answers"
    else
        fail "E00: nhm version --json answers"
    fi
    manual "E00: attach from the Mac client (herdr --remote $NAME) and run nhm bind --print-client"
}

# E01 Foundation and readiness. Matrix: `nhm quota --json` shows windows
# and UTC resets; `nhm --robot-spawn=fixture … --dry-run` returns
# admission.decision; `nhm doctor --json` lists dcg active for claude and
# codex, and agy and pi honestly; no host install happened (the harness
# runs only inside the container).
step_E01() {
    local quota spawn doc
    quota="$(record E01 "nhm quota" "nhm quota --json" || true)"
    if jq -e '.result' <<<"$quota" >/dev/null 2>&1; then
        pass "E01: nhm quota --json answers"
    else
        fail "E01: nhm quota --json answers"
    fi
    if grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' <<<"$quota"; then
        pass "E01: quota windows carry UTC resets"
    else
        fail "E01: quota windows carry UTC resets"
    fi
    on "mkdir -p ~/rehearsal-fixture && cd ~/rehearsal-fixture && git init -q 2>/dev/null; true" >/dev/null 2>&1 || true
    spawn="$(record E01 "robot spawn dry run" "cd ~/rehearsal-fixture && nhm --robot-spawn=fixture --spawn-dir=\$PWD --spawn-cc=1 --spawn-cod=1 --dry-run" || true)"
    if jq -e '.. | objects | select(has("admission")) | .admission.decision' <<<"$spawn" >/dev/null 2>&1; then
        pass "E01: --robot-spawn --dry-run returns admission.decision"
    else
        fail "E01: --robot-spawn --dry-run returns admission.decision"
    fi
    doc="$(record E01 "nhm doctor (guards)" "nhm doctor --json" || true)"
    local kind
    for kind in claude codex; do
        if jq -e --arg k "$kind" '.result.checks[]? | select(.name == ("guard " + $k + " dcg")) | select(.detail == "active")' <<<"$doc" >/dev/null 2>&1; then
            pass "E01: dcg is active for $kind"
        else
            fail "E01: dcg is active for $kind"
        fi
    done
    for kind in agy pi; do
        if jq -e --arg k "$kind" '.result.checks[]? | select(.name | startswith("guard " + $k + " "))' <<<"$doc" >/dev/null 2>&1; then
            pass "E01: the doctor reports $kind's guard state"
        else
            fail "E01: the doctor reports $kind's guard state"
        fi
    done
}

for step in $RUN_STEPS; do
    echo "== $step"
    if declare -F "step_$step" >/dev/null; then
        "step_$step"
    else
        fail "$step: not automated yet (acfs-9hkh.31)"
        printf 'not automated yet\n' >>"$EVIDENCE/$step.txt"
    fi
done

echo "== stop $NAME (kept; delete it with: incus delete $NAME)"
incus stop "$NAME" </dev/null >/dev/null 2>&1 || echo "  could not stop $NAME"
printf 'finished: %s\npassed: %d\nfailed: %d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PASS" "$FAIL" >>"$EVIDENCE/run.txt"
echo "evidence: $EVIDENCE"
if [[ "$FAIL" -eq 0 && ! -s "$EVIDENCE/manual.txt" ]]; then
    echo "RESULT: pass"
    exit 0
fi
if [[ "$FAIL" -eq 0 ]]; then
    echo "RESULT: fail (the manual parts in $EVIDENCE/manual.txt are the operator's; a run with them open does not pass)"
    exit 1
fi
echo "RESULT: fail"
exit 1
