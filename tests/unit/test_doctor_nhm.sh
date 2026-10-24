#!/usr/bin/env bash
# ============================================================
# doctor's stack.nhm.setup check against fixture homes
#
# The check reports whether a herdr server is enrolled with nhm and
# whether nhm's hook lines are registered for each installed agent CLI.
# It changes nothing. doctor.sh ends in `main "$@"`, so its functions are
# loaded with that line stripped, as the bats tests do.
#
# Usage: bash tests/unit/test_doctor_nhm.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-nhm.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check_case() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

# A `codex` whose app-server is the fake (tests/unit/fake_codex_app_server.py),
# for the check's Codex trust question.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$ROOT/tests/unit/fake_codex_app_server.py" >"$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"

# run_check <agents: claude|codex|both|none> [nhm present: true|false]
# prints "id|status|details|fix".
run_check() {
    local agents="$1" nhm_present="${2:-true}"
    PATH="$FAKEBIN:$PATH" STUB_HOME="$WORK/home" STUB_AGENTS="$agents" STUB_NHM="$nhm_present" XDG_STATE_HOME="" XDG_CONFIG_HOME="" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$STUB_HOME"; }
        doctor_binary_exists() {
            case "$1" in
                nhm) [[ "$STUB_NHM" == true ]] ;;
                claude) [[ "$STUB_AGENTS" == claude || "$STUB_AGENTS" == both ]] ;;
                codex) [[ "$STUB_AGENTS" == codex || "$STUB_AGENTS" == both ]] ;;
                *) return 1 ;;
            esac
        }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_nhm
    ' _ "$DOCTOR"
}

# fixture <enrolled: yes|no> <register: claude|codex|both|none>
fixture() {
    rm -rf "${WORK:?}/home"
    mkdir -p "$WORK/home/.acfs/scripts/lib" "$WORK/home/.claude" "$WORK/home/.codex"
    cp "$ROOT/scripts/lib/nhm_hooks.sh" "$WORK/home/.acfs/scripts/lib/nhm_hooks.sh"
    if [[ "$1" == yes ]]; then
        mkdir -p "$WORK/home/.local/state/nhm/inst-0123456789ab"
        printf 'id = "inst-0123456789ab"\n' >"$WORK/home/.local/state/nhm/inst-0123456789ab/instance.toml"
    fi
    case "$2" in
        claude|both) HOME="$WORK/home" bash "$ROOT/scripts/lib/nhm_hooks.sh" register claude 2>/dev/null ;;
    esac
    case "$2" in
        codex|both) HOME="$WORK/home" bash "$ROOT/scripts/lib/nhm_hooks.sh" register codex 2>/dev/null ;;
    esac
    # nhm's learning profile, as install sets it (acfs-9hkh.88); NO_LEARNING
    # leaves it out. CAPACITY sets the capacity provider, which only a user
    # does (acfs-hd37).
    [[ -n "${NO_LEARNING:-}" ]] || HOME="$WORK/home" XDG_CONFIG_HOME="" \
        bash "$ROOT/scripts/lib/nhm_hooks.sh" learning-profile set 2>/dev/null
    [[ -z "${CAPACITY:-}" ]] || HOME="$WORK/home" XDG_CONFIG_HOME="" \
        bash "$ROOT/scripts/lib/nhm_hooks.sh" capacity-provider set 2>/dev/null
}

echo "stack.nhm.setup"

fixture yes both
out="$(run_check both)"
check_case "lines Codex does not trust yet warn with the trust command" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"Codex does not trust 3 ACFS hook line(s) yet"*\|*"nhm_hooks.sh trust codex" ]]' _ "$out"
check_case "the check asked Codex without recording trust" test ! -e "$WORK/home/.codex/fake-trust.json"

PATH="$FAKEBIN:$PATH" HOME="$WORK/home" CODEX_HOME="$WORK/home/.codex" \
    bash "$ROOT/scripts/lib/nhm_hooks.sh" trust codex "$WORK/home/.codex/hooks.json" 2>/dev/null
out="$(run_check both)"
check_case "enrolled, registered for both and trusted by Codex passes" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|enrolled*"Claude Code"*"Codex (trusted)"*"learning profile on; capacity provider off: "*"turns it off again"\| ]]' _ "$out"

# dcg's Bash guard (acfs-9hkh.81) counts among ACFS's lines: untrusted, it
# warns with the same count and fix; trusted, the check passes.
fixture yes codex
mkdir -p "$WORK/home/.local/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/home/.local/bin/dcg"
chmod +x "$WORK/home/.local/bin/dcg"
HOME="$WORK/home" bash "$ROOT/scripts/lib/nhm_hooks.sh" codex-dcg register "$WORK/home/.codex/hooks.json" 2>/dev/null
out="$(run_check codex)"
check_case "an untrusted dcg guard counts as a fourth ACFS line" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"Codex does not trust 4 ACFS hook line(s) yet"* ]]' _ "$out"
PATH="$FAKEBIN:$PATH" HOME="$WORK/home" CODEX_HOME="$WORK/home/.codex" \
    bash "$ROOT/scripts/lib/nhm_hooks.sh" trust codex "$WORK/home/.codex/hooks.json" 2>/dev/null
out="$(run_check codex)"
check_case "with dcg's guard trusted too, the check passes" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|*"Codex (trusted)"* ]]' _ "$out"

fixture yes claude
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/elsewhere/nhm-hook sessionstart"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"/elsewhere/nhm-hook posttooluse"}]}],"PostCompact":[{"hooks":[{"type":"command","command":"/elsewhere/nhm-hook sessionstart"}]}]}}' \
    >"$WORK/home/.codex/hooks.json"
out="$(run_check codex)"
check_case "nhm-hook at a path ACFS never wrote is the user's: ACFS's lines count as missing" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"hook lines missing for Codex"* ]]' _ "$out"

# Older ACFS lines: ACFS's own path, an older timeout, in pure groups.
fixture yes claude
jq -n --arg p "$WORK/home/.local/bin/nhm-hook posttooluse" --arg s "$WORK/home/.local/bin/nhm-hook sessionstart" \
    --arg m '^mcp__.+__(register_agent|create_agent_identity|macro_start_session)$' \
    '{hooks: {PostToolUse: [{matcher: $m, hooks: [{type: "command", command: $p, timeout: 10}]}],
              SessionStart: [{hooks: [{type: "command", command: $s, timeout: 10}]}],
              PostCompact: [{hooks: [{type: "command", command: $s}]}]}}' >"$WORK/home/.codex/hooks.json"
out="$(run_check codex)"
check_case "older-path lines warn: upgrade with register, then trust" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"older nhm hook lines for Codex need an upgrade"*\|*"register codex (or acfs update)"*"trust codex" ]]' _ "$out"
HOME="$WORK/home" bash "$ROOT/scripts/lib/nhm_hooks.sh" register codex 2>/dev/null
PATH="$FAKEBIN:$PATH" HOME="$WORK/home" CODEX_HOME="$WORK/home/.codex" \
    bash "$ROOT/scripts/lib/nhm_hooks.sh" trust codex "$WORK/home/.codex/hooks.json" 2>/dev/null
out="$(run_check codex)"
check_case "after register and trust, register, trust and the doctor agree: trusted" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|*"Codex (trusted)"* ]]' _ "$out"

# acfs-9hkh.53: ACFS's handler inside the user's own group stays there;
# the doctor names the event, the group and the file.
fixture yes claude
jq --arg s "$WORK/home/.local/bin/nhm-hook sessionstart" \
    '.hooks.SessionStart = [{matcher: "startup", hooks: [{type: "command", command: "user-a"}, {type: "command", command: $s}]}] + .hooks.SessionStart' \
    "$WORK/home/.claude/settings.json" >"$WORK/settings.tmp"
mv "$WORK/settings.tmp" "$WORK/home/.claude/settings.json"
out="$(run_check claude)"
check_case "a stray nhm-hook line in the user's group warns: remove it by hand" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"older nhm-hook line inside your own hook group (SessionStart, group 1) in $2/.claude/settings.json: remove it by hand; it fires twice"*\|*"by hand"* ]]' \
    _ "$out" "$WORK/home"

# acfs-9hkh.60: a second copy of ACFS's exact line warns too; groups count
# from 1.
fixture yes claude
jq '.hooks.SessionStart += [.hooks.SessionStart[-1]]' "$WORK/home/.claude/settings.json" >"$WORK/settings.tmp"
mv "$WORK/settings.tmp" "$WORK/home/.claude/settings.json"
out="$(run_check claude)"
check_case "a duplicate ACFS line warns: a second copy, it fires twice" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"a second copy of ACFS'"'"'s nhm-hook line (SessionStart, group 2) in $2/.claude/settings.json: remove it by hand; it fires twice"* ]]' \
    _ "$out" "$WORK/home"

fixture yes both
out="$(FAKE_CODEX_FAIL=1 run_check codex)"
check_case "an app-server that fails warns that trust is unknown" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"trust of the nhm hook lines is unknown"*\|*"trust codex" ]]' _ "$out"

fixture no both
out="$(run_check both)"
check_case "no enrolled server warns with the enroll command" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"no enrolled herdr server"*\|*"nhm admin instance enroll"* ]]' _ "$out"

fixture yes claude
out="$(run_check both)"
check_case "lines missing for Codex warn with the codex register command" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*Codex*\|*"nhm_hooks.sh register codex"* && "$1" != *"register claude"* ]]' _ "$out"

fixture yes claude
out="$(run_check claude)"
check_case "Claude Code only, registered: passes without asking about Codex" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|* && "$1" != *Codex* ]]' _ "$out"

fixture yes none
out="$(run_check none)"
check_case "enrolled, no agent CLI: passes" bash -c '[[ "$1" == stack.nhm.setup\|pass\|"enrolled; learning profile on; capacity provider off: "*"turns it off again"\| ]]' _ "$out"

# nhm's learning profile (acfs-9hkh.88): not set warns with the fix; the
# user's own value is noted and passes.
NO_LEARNING=1 fixture yes none
out="$(run_check none)"
check_case "no learning profile warns with the set command" \
    bash -c '[[ "$1" == stack.nhm.setup\|warn\|*"learning profile is not set"*\|*"learning-profile set (or acfs update)" ]]' _ "$out"
mkdir -p "$WORK/home/.config/nhm"
printf '[learning]\nimplicit_outcome = "off"\n' >"$WORK/home/.config/nhm/config.toml"
out="$(run_check none)"
check_case "the user's own learning value passes, noted as theirs" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|*"learning profile set by your nhm config"* ]]' _ "$out"

# nhm's capacity provider (acfs-hd37) is the user's choice: unset, the
# check still passes and notes the set command and the spawn-sized line
# (acfs-w1f0); set, it notes how to turn it off; the user's own value is
# noted as theirs.
fixture yes none
out="$(run_check none)"
check_case "no capacity provider passes, noting the set command and the spawn-sized line" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|*"capacity provider off: "*"capacity-provider set"*"acfs capacity --guard --for-spawn"*"one more agent doesn"*"t fit"*"1536 MiB by default"*"[providers] capacity = [] in nhm"*"s config turns it off again"\| ]]' _ "$out"
CAPACITY=1 fixture yes none
out="$(run_check none)"
check_case "the capacity provider set passes, noting nhm's per-spawn override and how to turn it off" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|*"capacity provider on (--ignore-capacity on nhm spawn or add admits that spawn while the guard is red; [providers] capacity = [] in nhm"*"s config turns it off)"* ]]' _ "$out"
fixture yes none
printf '\n[providers]\ncapacity = []\n' >>"$WORK/home/.config/nhm/config.toml"
out="$(run_check none)"
check_case "the user's own capacity value passes, noted as theirs" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|*"capacity provider set by your nhm config"* ]]' _ "$out"

fixture no none
out="$(run_check both false)"
check_case "no nhm: skips" bash -c '[[ "$1" == stack.nhm.setup\|skip\|* ]]' _ "$out"

fixture no none
before="$(find "$WORK/home" -type f | sort)"
run_check both >/dev/null
check_case "the check writes nothing" test "$(find "$WORK/home" -type f | sort)" = "$before"

# ------------------------------------------------------------
# agent.quota_statusline (acfs-5917): Claude Code's statusLine runs
# nhm quota record-claude
# ------------------------------------------------------------
# run_sl_check <claude: true|false> <nhm: true|false> prints "id|status|details|fix".
run_sl_check() {
    STUB_HOME="$SLHOME" STUB_CLAUDE="$1" STUB_NHM="$2" NHM_BIN_DIR="" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$STUB_HOME"; }
        doctor_binary_exists() {
            case "$1" in
                nhm) [[ "$STUB_NHM" == true ]] ;;
                claude) [[ "$STUB_CLAUDE" == true ]] ;;
                *) return 1 ;;
            esac
        }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_nhm_quota_statusline
    ' _ "$DOCTOR"
}
SLHOME="$WORK/slhome"
mkdir -p "$SLHOME/.acfs/scripts/lib" "$SLHOME/.claude"
cp "$ROOT/scripts/lib/nhm_hooks.sh" "$SLHOME/.acfs/scripts/lib/nhm_hooks.sh"
SLSET="$SLHOME/.claude/settings.json"

printf '{}\n' >"$SLSET"
out="$(run_sl_check true true)"
check_case "statusLine: none set warns and names the fix" \
    bash -c '[[ "$1" == "agent.quota_statusline|warn|"*"does not run nhm quota record-claude"*"|Run: bash "*"nhm_hooks.sh statusline claude set (or acfs update)" ]]' _ "$out"
printf '{"statusLine": {"type": "command", "command": "bash %s/.acfs/scripts/lib/agent_quota.sh record-claude"}}\n' "$SLHOME" >"$SLSET"
out="$(run_sl_check true true)"
check_case "statusLine: ACFS's old agent_quota.sh line warns with the same fix" \
    bash -c '[[ "$1" == "agent.quota_statusline|warn|"*"|Run: bash "*"statusline claude set"* ]]' _ "$out"
HOME="$SLHOME" bash "$ROOT/scripts/lib/nhm_hooks.sh" statusline claude set "$SLSET" 2>/dev/null
out="$(run_sl_check true true)"
check_case "statusLine: nhm's line passes" bash -c '[[ "$1" == "agent.quota_statusline|pass|"* ]]' _ "$out"
printf '{"statusLine": {"type": "command", "command": "~/bin/my-status"}}\n' >"$SLSET"
out="$(run_sl_check true true)"
check_case "statusLine: the user's own warns and shows how to chain nhm's" \
    bash -c '[[ "$1" == "agent.quota_statusline|warn|"*"is your own"*"|Feed both"*"/.local/bin/nhm quota record-claude"*"<your command>"* ]]' _ "$out"
printf '{"statusLine": ' >"$SLSET"
out="$(run_sl_check true true)"
check_case "statusLine: malformed settings warn" \
    bash -c '[[ "$1" == "agent.quota_statusline|warn|"*"is not a settings object|Check: jq ."* ]]' _ "$out"
out="$(run_sl_check false true)"
check_case "statusLine: no Claude Code: skips" bash -c '[[ "$1" == "agent.quota_statusline|skip|"* ]]' _ "$out"
out="$(run_sl_check true false)"
check_case "statusLine: no nhm: skips" bash -c '[[ "$1" == "agent.quota_statusline|skip|"* ]]' _ "$out"
printf '{}\n' >"$SLSET"
before="$(cat "$SLSET")"
run_sl_check true true >/dev/null
check_case "statusLine: the check writes nothing" test "$(cat "$SLSET")" = "$before"

echo
echo "doctor nhm: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
