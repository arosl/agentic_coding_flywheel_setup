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
#            [--release 0.1|0.2|0.3|0.4] [--steps E00,E01,...] [--root DIR] [--takeover | --owner]
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
# --takeover adds the takeover scenario (plan-v8 section 5 step 6) between
# release 0.1's steps and the later ones: an agent outside git imported,
# an unbound Bash token refusing both modes, and --exclude letting the
# takeover pass. Without it, a later release's first step takes the
# server over itself, as on the plan's disposable instance.
#
# --owner runs ACFS's own takeover (tests/vm/rehearsal/OWNER.sh;
# acfs-9hkh.93) alone, on a fresh sandbox, instead of a release's steps:
# the step install.sh and acfs update run, on a fresh install and on an
# upgrade whose Bash keeps an agent. It takes no --steps or --takeover.
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
TAKEOVER=0
OWNER=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --authorised) [[ $# -ge 2 ]] || usage; AUTHORISED="$2"; shift 2 ;;
        --release) [[ $# -ge 2 ]] || usage; RELEASE="$2"; shift 2 ;;
        --steps) [[ $# -ge 2 ]] || usage; STEPS="$2"; shift 2 ;;
        --root) [[ $# -ge 2 ]] || usage; ROOT="$2"; shift 2 ;;
        --nhm-version) [[ $# -ge 2 ]] || usage; NHM_VERSION="$2"; shift 2 ;;
        --nhm-build) [[ $# -ge 2 ]] || usage; NHM_BUILD="$2"; shift 2 ;;
        --takeover) TAKEOVER=1; shift ;;
        --owner) OWNER=1; shift ;;
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
# The takeover runs where the migration has it: after release 0.1's steps
# (the Bash owns the server) and before the later releases' (nhm owns it).
if [[ "$TAKEOVER" == 1 ]]; then
    before="" after=""
    for s in $RUN_STEPS; do
        if [[ " $(release_steps 0.1) " == *" $s "* ]]; then before+=" $s"; else after+=" $s"; fi
    done
    RUN_STEPS="${before# } TAKEOVER$after"
    RUN_STEPS="${RUN_STEPS# }"
fi
if [[ "$OWNER" == 1 ]]; then
    if [[ -n "$STEPS" || "$TAKEOVER" == 1 ]]; then
        echo "--owner runs alone: drop --steps and --takeover" >&2
        exit 2
    fi
    RUN_STEPS="OWNER"
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
for tool in dcg rch am br claude codex cm cass; do
    if command -v "$tool" >/dev/null 2>&1; then
        sandbox_bin "$tool"
    fi
done
if [[ -n "$NHM_VERSION" ]]; then
    sandbox_nhm_release "$NHM_VERSION" || { echo "RESULT: fail (nhm $NHM_VERSION could not be fetched and verified)"; exit 1; }
else
    sandbox_nhm_build "$NHM_BUILD" || { echo "RESULT: fail (no nhm build in $NHM_BUILD)"; exit 1; }
fi
# E21 runs the brenner fork at the tag ACFS pins (KNOWN_INSTALLERS in
# scripts/lib/security.sh). Without it E21 fails; it never runs the host's.
BRENNER_TAG=""
if [[ " $RUN_STEPS " == *" E21 "* ]]; then
    BRENNER_TAG="$(sed -nE 's#^ *\[brenner_bot\]="https://raw\.githubusercontent\.com/arosl/brenner_bot/(v[^/"]+)/install\.sh"$#\1#p' \
        "$ROOT_DIR/scripts/lib/security.sh")"
    sandbox_brenner_release "$BRENNER_TAG" || echo "  (E21 will fail: brenner ${BRENNER_TAG:-<no pinned tag>} could not be fetched and verified)"
fi
{
    printf 'run: %s\nrelease: %s\nsteps: %s\nacfs: %s\nnhm: %s\nbrenner: %s\nstarted: %s\n' "$AUTHORISED" "$RELEASE" "$RUN_STEPS" \
        "$(git -C "$ROOT_DIR" rev-parse HEAD)" "${NHM_VERSION:-build $NHM_BUILD}" "${BRENNER_TAG:-not used}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    # The guards as ACFS's install sets them, here in the sandbox HOME:
    # Claude's through claude_guards; Codex's dcg line and its trust through
    # nhm_hooks.sh's codex-dcg register and trust codex (acfs-9hkh.81),
    # which the step file's e01_codex_dcg runs. Without that file, Codex's
    # check fails: the harness writes no hook of its own.
    claude_guards
    # Codex's dcg line and its trust, as ACFS's install records them
    # (tests/vm/rehearsal/E01_codex.sh, TealHorizon).
    if declare -F e01_codex_dcg >/dev/null; then
        e01_codex_dcg
    fi
    doc="$(nhm doctor --json --no-mail 2>/dev/null || true)"
    echo "### the guard checks of nhm doctor --json"
    jq -c '.result.checks[]? | select(.name | startswith("guard "))' <<<"$doc"
    for kind in claude codex; do
        check "E01: dcg is active for $kind" \
            jq -e --arg k "$kind" '.result.checks[]? | select(.name == ("guard " + $k + " dcg"))
                | select(.detail | startswith("configured") or startswith("verified_for_launch"))' <<<"$doc"
    done
    for kind in agy pi; do
        check "E01: the doctor reports $kind's guard state" \
            jq -e --arg k "$kind" '.result.checks[]? | select(.name | startswith("guard " + $k + " "))' <<<"$doc"
    done
}

# bash_agent: Agent Mail and the mock API in the step, one Claude that the
# Bash spawns in a git project (nhm_takeover_steps.sh), read into nhm's
# bindings. Prints the agent's herdr name.
bash_agent() {
    # As ACFS's install does: herdr's Claude integration, the hook that
    # reports the agent's state and session to herdr.
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 ||
        { echo "FAIL herdr integration install claude"; return 1; }
    # shellcheck source=tests/vm/lib/nhm_takeover_steps.sh
    source "$(dirname "$SANDBOX_LIB")/nhm_takeover_steps.sh"
    local name
    name="$(takeover_bash_agent "$HOME/project")" || { echo "FAIL the Bash spawn (bash-spawn.out)"; return 1; }
    nhm admin recover reconcile --import-only --json >"$SANDBOX_EVIDENCE/import.json" 2>&1 || true
    printf '%s\n' "$name"
}

# E14 The sweep, release 0.1's part (status): one view and one JSON with,
# per agent, state, observed_since, bead, unread, acks, limit, guards and
# generation; --robot-status non-empty. nhm's row says observed_at for
# observed_since, and has a limit only when one was seen. The interrupt
# and recycle parts come with 0.2 and 0.3.
step_E14() {
    local name st row
    name="$(bash_agent)" || { echo "$name"; return; }
    echo "agent: $name"
    st="$(nhm status --json 2>&1 || true)"
    echo "### nhm status --json"
    echo "$st"
    row="$(jq -c --arg n "$name" '[.. | objects | select(.herdr_name? == $n)][0] // empty' <<<"$st" 2>/dev/null)"
    check "E14: status has a row for $name" test -n "$row"
    check "E14: the row has a state" jq -e '.state | type == "string"' <<<"${row:-null}"
    check "E14: the row has when it was observed (observed_at)" jq -e '.observed_at | type == "string"' <<<"${row:-null}"
    check "E14: the row has the binding's generation" jq -e '.binding.generation | type == "number"' <<<"${row:-null}"
    check "E14: the row has unread mail and acks" jq -e '.mail | has("unread") and has("pending_acks")' <<<"${row:-null}"
    check "E14: the row has the guards" jq -e '.guards | type == "object"' <<<"${row:-null}"
    check "E14: the row has the agent's bead" jq -e 'has("bead")' <<<"${row:-null}"
    check "E14: nhm status (the view) answers" show "nhm status" nhm status
    check "E14: --robot-status is not empty" bash -c 'nhm --robot-status | jq -e "(.sessions // []) | length > 0"'
    nhm --robot-status >"$SANDBOX_EVIDENCE/robot-status.json" 2>&1 || true
}

# E16 Server restart, release 0.1's part (inspect): stop and start the
# herdr server with the Bash's agent bound. herdr 0.9.3 restores its
# session itself and resumes the agents (same native session), so the
# matrix's "nothing launched" is nhm's part: inspect knows the binding,
# every agent herdr lists after the restart is a binding inspect calls
# live (herdr and the registry agree), no session twice, no nhm operation
# left open, and recover resume --dry-run previews the session. The
# matrix's "one send pending" needs a send the Bash leaves unconfirmed,
# which the step cannot stage yet.
step_E16() {
    local name bid inspect agents preview
    name="$(bash_agent)" || { echo "$name"; return; }
    echo "agent: $name"
    bid="$(nhm resolve "$name" --json 2>/dev/null | jq -r '[.. | objects | .binding_id? // empty][0] // empty')"
    check "E16: the agent is bound before the restart" test -n "$bid"
    show "herdr server stop" sandbox_herdr_stop
    show "herdr server start" sandbox_herdr_start || { echo "FAIL E16: the server did not come back"; return; }
    inspect="$(nhm admin recover inspect --json 2>&1 || true)"
    echo "### nhm admin recover inspect --json"
    echo "$inspect"
    check "E16: inspect knows the binding (live, displaced or orphan)" \
        jq -e --arg b "$bid" '.result | [(.live // [])[], (.displaced // [])[], (.orphans // [])[]] | map(.binding_id) | index($b) != null' <<<"$inspect"
    check "E16: inspect lists no session twice" jq -e '(.result.duplicate_sessions // {}) | length == 0' <<<"$inspect"
    check "E16: no nhm operation was left open" jq -e '(.result.pending_operations // []) | length == 0' <<<"$inspect"
    agents="$(herdr agent list 2>/dev/null || true)"
    echo "### herdr agent list"
    echo "$agents"
    check "E16: every agent herdr lists is a binding inspect calls live" \
        jq -e -n --argjson a "${agents:-null}" --argjson i "$inspect" '
            ([$i.result.live[]?.pane_id]) as $live
            | [$a.result.agents[]?.pane_id] | all(. as $p | $live | index($p) != null)'
    preview="$(nhm admin recover resume "$bid" --dry-run --json 2>&1 || true)"
    echo "### nhm admin recover resume --dry-run"
    echo "$preview"
    check "E16: resume --dry-run previews the session's argv" jq -e '.result.argv | index("--resume") != null' <<<"$preview"
    manual "E16: one send pending through the restart stays unconfirmed (needs a send the Bash leaves pending)"
}

# claude_guards: Claude's three guards, as ACFS's install sets them (here
# in the sandbox HOME): dcg install, rch hook install, and the Agent Mail
# Stop hook (agent_mail_hook.sh register claude).
claude_guards() {
    local hook
    hook="$(dirname "$SANDBOX_LIB")/../../../scripts/lib/agent_mail_hook.sh"
    command -v dcg >/dev/null 2>&1 && dcg install --quiet >"$SANDBOX_EVIDENCE/guard-dcg.out" 2>&1
    command -v rch >/dev/null 2>&1 && rch hook install >"$SANDBOX_EVIDENCE/guard-rch.out" 2>&1
    bash "$hook" register claude >"$SANDBOX_EVIDENCE/guard-agent-mail.out" 2>&1
    return 0
}

# nhm_owner: release 0.2's steps run with nhm as the owner, as on the
# disposable instance the plan rehearses them on: take the server over
# when the Bash still owns it (the earlier steps' agents are imported).
nhm_owner() {
    local out rc=0
    out="$(nhm admin takeover --yes --json 2>&1)" || rc=$?
    if ((rc != 0)) && ! grep -q 'already nhm' <<<"$out"; then
        echo "### takeover (exit $rc)"
        echo "$out"
        return 1
    fi
}

# state PANE: herdr's state of the agent in PANE.
state() { herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }

# until_state PANE REGEX SECONDS
until_state() {
    local end=$((SECONDS + $3))
    while ((SECONDS < end)); do
        [[ "$(state "$1")" =~ $2 ]] && return 0
        sleep 0.5
    done
    return 1
}

# E09 Wake: mail to an idle agent and to a working one. The idle agent is
# nudged by the pass; the working one is left alone until its turn ends,
# then nudged; each message nudges once (a later pass nudges nobody).
# nhm's wake keeps pending message ids, not a cursor: "the cursor
# survives a restart" is checked as "a new pass does not nudge again".
step_E09() {
    local dir out a b pa pb w1 w2 w3
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    dir="$HOME/e09"
    mkdir -p "$dir" && git -C "$dir" init -q && sandbox_claude_prepare "$dir" >/dev/null
    claude_guards
    nhm_owner || { echo "FAIL E09: nhm could not take the server over"; return; }
    out="$(cd "$dir" && nhm spawn e09 --cc=2 --prompt "say hi" --json 2>&1)"
    echo "### nhm spawn e09 --cc=2"
    echo "$out"
    a="$(jq -r '.result.agents[0].mail_name // empty' <<<"$out")"
    b="$(jq -r '.result.agents[1].mail_name // empty' <<<"$out")"
    pa="$(jq -r '.result.agents[0].pane_id // empty' <<<"$out")"
    pb="$(jq -r '.result.agents[1].pane_id // empty' <<<"$out")"
    check "E09: nhm spawned two agents" test -n "$a" -a -n "$b"
    until_state "$pa" '^(idle|done)$' 60 && until_state "$pb" '^(idle|done)$' 60
    am agents register --project "$dir" --program rehearsal --model none --name GrayHeron --json \
        >"$SANDBOX_EVIDENCE/e09-sender.json" 2>&1 || true
    # A works (a slow reply), B is idle; the mail reaches both.
    herdr agent prompt "$pa" "say hi slow" >/dev/null 2>&1 || true
    until_state "$pa" '^working$' 10
    show "mail to both" am mail send --project "$dir" --from GrayHeron --to "$a,$b" -s "e09" -b "wake test" --json >/dev/null
    w1="$(nhm wake --once --json 2>&1 || true)"
    echo "### wake, A working"
    echo "$w1"
    check "E09: the idle agent is nudged" \
        jq -e --arg m "$b" '.result.decisions[]? | select(.mail_name == $m and .action == "nudged")' <<<"$w1"
    check "E09: the working agent is left alone" \
        jq -e --arg m "$a" '[.result.decisions[]? | select(.mail_name == $m and .action == "nudged")] | length == 0' <<<"$w1"
    until_state "$pa" '^(idle|done)$' 60
    w2="$(nhm wake --once --json 2>&1 || true)"
    echo "### wake, A done"
    echo "$w2"
    check "E09: the agent is nudged once its turn is done" \
        jq -e --arg m "$a" '.result.decisions[]? | select(.mail_name == $m and .action == "nudged")' <<<"$w2"
    w3="$(nhm wake --once --json 2>&1 || true)"
    echo "### a later wake"
    echo "$w3"
    check "E09: a later pass nudges nobody again" \
        jq -e '[.result.decisions[]? | select(.action == "nudged")] | length == 0' <<<"$w3"
}

# settle PANE: wait until the agent has been idle or done for 3 seconds
# (after a kickoff, Claude may start another turn on its own).
settle() {
    local end=$((SECONDS + 60)) since=""
    while ((SECONDS < end)); do
        if [[ "$(state "$1")" =~ ^(idle|done)$ ]]; then
            since="${since:-$SECONDS}"
            ((SECONDS - since >= 3)) && return 0
        else
            since=""
        fi
        sleep 0.5
    done
    return 1
}

# e11_agent: one Claude that nhm spawns in session e11; prints its pane.
e11_agent() {
    local dir out pane
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    dir="$HOME/e11"
    mkdir -p "$dir" && git -C "$dir" init -q && sandbox_claude_prepare "$dir" >/dev/null
    claude_guards
    nhm_owner || return 1
    out="$(cd "$dir" && nhm spawn e11 --cc=1 --prompt "say hi" --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e11-spawn.json"
    pane="$(jq -r '.result.agents[0].pane_id // empty' <<<"$out")"
    [[ -n "$pane" ]] || return 1
    until_state "$pane" '^(idle|done)$' 60
    printf '%s\n' "$pane"
}

# robot ARGS...: one robot call; prints its JSON and saves it, labelled.
robot() {
    local label="$1" out rc=0
    shift
    out="$(nhm "$@" 2>&1)" || rc=$?
    echo "### $label (exit $rc): nhm $*"
    echo "$out"
    printf '%s' "$out" >"$SANDBOX_EVIDENCE/e11-$label.json"
    return 0
}

# E11 The robot-driven turn: resolve, send once, read and wait, through a
# fast finish, a busy agent and a replaced occupant; a repeated --op-id
# returns the stored receipt and dispatches nothing again. The matrix's
# names map to nhm's (plan-v8 section 7): submitted_observed is
# submitted, generation_changed is replaced. A timeout that leaves the
# submission unconfirmed and a blocked input (a dialog) cannot be staged
# against the mock yet: MANUAL. The mock takes about 1.5 s per turn, so
# herdr sees a turn start; "slow" makes it about 8 s, and "fast" answers
# at once, the fast finish.
step_E11() {
    local pane before after
    pane="$(e11_agent)" || { echo "FAIL E11: no agent"; return; }
    robot status --robot-status
    check "E11: --robot-status lists the session" jq -e '[.. | objects | select(has("name") or has("session"))] | length > 0' \
        "$SANDBOX_EVIDENCE/e11-status.json"
    # A turn, its ack and its receipt.
    settle "$pane"
    robot send-a --robot-send=e11 --all --msg="hello robot slow" --op-id=e11-a
    check "E11: a send to a ready agent is submitted" jq -e '.success and (.successful | length == 1)' "$SANDBOX_EVIDENCE/e11-send-a.json"
    robot ack-a --robot-ack=e11 --op-id=e11-a --timeout=60s
    check "E11: its ack confirms the turn" jq -e '.success and (.confirmations | length == 1) and (.timed_out | not)' \
        "$SANDBOX_EVIDENCE/e11-ack-a.json"
    robot receipt-a --robot-send-receipt=e11-a
    check "E11: --robot-send-receipt returns the stored receipt" jq -e '.success and (.. | objects | select(has("successful")) | .successful | length == 1)' \
        "$SANDBOX_EVIDENCE/e11-receipt-a.json"
    # The same --op-id again: the stored receipt, no second prompt.
    until_state "$pane" '^(idle|done)$' 60
    # grep -c prints 0 itself (and exits 1) when nothing matches.
    before="$(grep -c 'hello robot slow' "$SANDBOX_EVIDENCE/mock-requests.jsonl" 2>/dev/null)"
    robot send-a-again --robot-send=e11 --all --msg="hello robot slow" --op-id=e11-a
    sleep 3
    after="$(grep -c 'hello robot slow' "$SANDBOX_EVIDENCE/mock-requests.jsonl" 2>/dev/null)"
    before="${before:-0}" after="${after:-0}"
    echo "mock requests with the text: $before before, $after after"
    check "E11: a repeated --op-id answers with the receipt" jq -e '.success and (.successful | length == 1)' \
        "$SANDBOX_EVIDENCE/e11-send-a-again.json"
    check "E11: a repeated --op-id dispatches nothing again" test "$before" -eq "$after"
    # A busy agent. nhm send --when ready refuses it at the gate.
    # --robot-send types into it, as ntm's send does (nhm-r0v, the
    # operator, 2026-10-13): its receipt names the busy gate it passed, and
    # Claude Code takes the text once its turn ends.
    herdr agent prompt "$pane" "work slow" >/dev/null 2>&1 || true
    until_state "$pane" '^working$' 10
    robot send-busy-ready send e11 --all --when ready "refused while busy" --json
    check "E11: nhm send --when ready refuses a working agent (busy)" \
        jq -e '.result.targets[0] | .submission == "refused" and .result.gate == "busy" and .error_code == "gate_busy"' \
        "$SANDBOX_EVIDENCE/e11-send-busy-ready.json"
    robot send-busy --robot-send=e11 --all --msg="while busy" --op-id=e11-b
    check "E11: --robot-send types into a working agent, as ntm (submitted, gate busy)" \
        jq -e '(._nhm // .nhm) as $n | .success and ($n.targets[0].submission == "submitted") and ($n.targets[0].gate == "busy")' \
        "$SANDBOX_EVIDENCE/e11-send-busy.json"
    until_state "$pane" '^(idle|done)$' 60
    check "E11: and the model gets it after the turn" grep -qF 'while busy' "$SANDBOX_EVIDENCE/mock-requests.jsonl"
    check "E11: the refused text never reached it" bash -c '! grep -qF "refused while busy" "$1"' _ "$SANDBOX_EVIDENCE/mock-requests.jsonl"
    # A fast finish: the turn ends before herdr sees it start, so nhm
    # cannot confirm the submission and says possibly_submitted, never
    # submitted.
    settle "$pane"
    robot send-fast --robot-send=e11 --all --msg="hello robot fast" --op-id=e11-f
    check "E11: a fast finish reads possibly_submitted (OPERATION_OUTCOME_UNKNOWN)" \
        jq -e '(._nhm // .nhm) as $n | (.success | not) and .error_code == "OPERATION_OUTCOME_UNKNOWN"
            and ($n.targets[0].submission == "possibly_submitted")' "$SANDBOX_EVIDENCE/e11-send-fast.json"
    check "E11: and the prompt reached the model" grep -qF 'hello robot fast' "$SANDBOX_EVIDENCE/mock-requests.jsonl"
    settle "$pane"
    # A replaced occupant: recycle, then the earlier operation's ack.
    robot recycle recycle "$(jq -r '.result.agents[0].mail_name' "$SANDBOX_EVIDENCE/e11-spawn.json")" --prompt "go on" --json
    robot ack-after-recycle --robot-ack=e11 --op-id=e11-a --timeout=5s
    check "E11: after a recycle the earlier send reads replaced" \
        jq -e '(.success | not) and (.failed[0].reason | startswith("replaced"))' "$SANDBOX_EVIDENCE/e11-ack-after-recycle.json"
    manual "E11: a timeout that leaves a submission unconfirmed (possibly_submitted) and a blocked input (refused at a dialog)"
}

# TAKEOVER (--takeover; plan-v8 section 5 step 6, run last): the Bash
# spawns a Claude in a folder outside git; then
#   1. the dry run passes, imports the agent and keeps its token;
#   2. a token the Bash kept for an identity no agent holds refuses both
#      the dry run and --yes with exit 2, and the Bash stays the owner;
#   3. --exclude names that identity: the takeover passes, lists it as
#      excluded, and nhm owns the server.
step_TAKEOVER() {
    local dir ws mail out rc ghostdir mode
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    dir="$HOME/plainwork"
    mkdir -p "$dir" && sandbox_claude_prepare "$dir" >/dev/null
    ws="$(herdr workspace create --cwd "$dir" --label plainwork --no-focus 2>/dev/null | jq -r '.result.workspace.workspace_id // empty')"
    acfs agents spawn --claude 1 --workspace "$ws" --cwd "$dir" --no-prompt --trust-folder --force \
        >"$SANDBOX_EVIDENCE/plain-spawn.out" 2>&1 || true
    mail="$(sed -n 's/^started: \([A-Za-z]*\) (.*/\1/p' "$SANDBOX_EVIDENCE/plain-spawn.out" | head -1)"
    check "TAKEOVER: the Bash spawned a Claude outside git" test -n "$mail"
    nhm admin recover reconcile --import-only --json >"$SANDBOX_EVIDENCE/takeover-import.json" 2>&1 || true

    rc=0
    out="$(nhm admin takeover --dry-run --json 2>&1)" || rc=$?
    echo "### takeover --dry-run (exit $rc)"
    echo "$out"
    check "TAKEOVER 1: the dry run passes" test "$rc" -eq 0
    check "TAKEOVER 1: it keeps the outside-git agent's token" \
        jq -e --arg m "$mail" '.result.tokens[]? | select(.mail_name == $m) | select(.action != "acfs_only")' <<<"$out"

    # A token the Bash kept for an identity no agent holds.
    ghostdir="${ACFS_HOME:-$HOME/.acfs}/state/tokens/$(printf '%s' "$dir" | sha256sum | cut -c1-16)"
    mkdir -p "$ghostdir" && printf '%s\n' "$dir" >"$ghostdir/.project" && printf 'tok-ghost\n' >"$ghostdir/GhostOwl"
    for mode in --dry-run --yes; do
        rc=0
        out="$(nhm admin takeover "$mode" --json 2>&1)" || rc=$?
        echo "### takeover $mode with GhostOwl's token (exit $rc)"
        echo "$out"
        check "TAKEOVER 2: $mode refuses (exit 2) over an unbound token" test "$rc" -eq 2
        check "TAKEOVER 2: after $mode the Bash still owns the server" \
            bash -c '[[ "$(acfs agents owner 2>/dev/null)" == acfs-bash* ]]'
    done
    rc=0
    out="$(nhm admin takeover --yes --exclude GhostOwl --json 2>&1)" || rc=$?
    echo "### takeover --yes --exclude GhostOwl (exit $rc)"
    echo "$out"
    check "TAKEOVER 3: --exclude passes" test "$rc" -eq 0
    check "TAKEOVER 3: the report lists GhostOwl as excluded" jq -e '.result.excluded | index("GhostOwl") != null' <<<"$out"
    check "TAKEOVER 3: nhm owns the server" jq -e '.result.owner.owner == "nhm"' <<<"$out"
}

# --- Steps in their own files ----------------------------------------------
# tests/vm/rehearsal/<STEP>.sh defines step_<STEP> and helpers prefixed
# <step>_ (lower case), and may use the helpers above. Sourced after this
# file's own steps, so a step file wins over an inline step of that name.
for step_file in "$ROOT_DIR/tests/vm/rehearsal/"*.sh; do
    [[ -e "$step_file" ]] || continue
    # shellcheck source=/dev/null
    source "$step_file"
done

# --- Outside: run each step as one script in the sandbox ------------------

PASS=0
FAIL=0
MANUAL=0
run_step() {
    local step="$1" script="$ROOT/steps/$1.sh" out="$EVIDENCE/$1.txt"
    mkdir -p "$ROOT/steps"
    {
        printf '#!/usr/bin/env bash\nset -uo pipefail\nsource "$SANDBOX_LIB"\n'
        declare -f check show manual bash_agent claude_guards nhm_owner state until_state settle e11_agent robot "step_$step"
        # A step file's own helpers: <step>_* (and e01_* for E01's).
        local helper
        for helper in $(declare -F | awk '{print $3}' | grep -i "^${step,,}_"); do
            declare -f "$helper"
        done
        # Agent Mail and the mock come first: the herdr server's panes take
        # their URLs from its environment.
        printf 'sandbox_mail_start >/dev/null || echo "FAIL %s: the step'"'"'s Agent Mail"\n' "$step"
        printf 'sandbox_mock_start >/dev/null || echo "FAIL %s: the mock API"\n' "$step"
        printf 'sandbox_herdr_start || { echo "FAIL %s: the sandbox herdr server"; exit 1; }\n' "$step"
        printf 'show "enroll" nhm admin instance enroll --json || echo "FAIL %s: enroll"\n' "$step"
        printf 'step_%s\nsandbox_herdr_stop\necho STEP-COMPLETE\n' "$step"
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
    # A step that dies partway (a shell error ends its script) must not
    # read as a pass on the checks it reached.
    if ! grep -qx 'STEP-COMPLETE' "$out"; then
        echo "  FAIL $step: the step's script did not finish (see the end of $out)"
        f=$((f + 1))
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
