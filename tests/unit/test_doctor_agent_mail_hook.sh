#!/usr/bin/env bash
# ============================================================
# doctor's agent.mail_stop_hook check (acfs-gen.4) against fixture
# settings files
#
# The check reports whether the Agent Mail Stop hook is registered for
# each installed agent (Claude Code's settings.json, Codex's hooks.json)
# and never registers it itself. doctor.sh ends in `main "$@"`, so its
# functions are loaded with that line stripped, as the bats tests do.
#
# Usage: bash tests/unit/test_doctor_agent_mail_hook.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-agent-mail-hook.XXXXXX")"
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

HOOK_ENTRY='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /home/u/.acfs/scripts/lib/agent_mail_hook.sh stop","timeout":10}]}]}}'
OTHER_ENTRY='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"claude-done-notifier"}]}]}}'

# Run the check in a subshell with doctor's functions loaded, the runtime
# home pointed at a fixture and the collector replaced; prints
# "id|status|details|fix". $1 is the agents present (claude, codex, both,
# none), $2 whether am is installed.
run_check() {
    local agents="$1" am_present="${2:-true}"
    STUB_HOME="$WORK/home" STUB_AGENTS="$agents" STUB_AM="$am_present" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$STUB_HOME"; }
        doctor_binary_exists() {
            case "$1" in
                am) [[ "$STUB_AM" == true ]] ;;
                claude) [[ "$STUB_AGENTS" == claude || "$STUB_AGENTS" == both ]] ;;
                codex) [[ "$STUB_AGENTS" == codex || "$STUB_AGENTS" == both ]] ;;
                *) return 1 ;;
            esac
        }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_agent_mail_stop_hook
    ' _ "$DOCTOR"
}

fixture() {
    # fixture <claude json or ""> <codex json or "">
    rm -rf "${WORK:?}/home"
    mkdir -p "$WORK/home/.claude" "$WORK/home/.codex"
    [[ -z "$1" ]] || printf '%s\n' "$1" >"$WORK/home/.claude/settings.json"
    [[ -z "$2" ]] || printf '%s\n' "$2" >"$WORK/home/.codex/hooks.json"
}

echo "agent.mail_stop_hook"

fixture "$HOOK_ENTRY" "$HOOK_ENTRY"
out="$(run_check both)"
check_case "registered for both agents passes" \
    bash -c '[[ "$1" == agent.mail_stop_hook\|pass\|*"Claude Code"*Codex*\| ]]' _ "$out"
check_case "the Codex pass reminds that /hooks must trust it" \
    bash -c '[[ "$1" == *"/hooks"* ]]' _ "$out"

fixture "$OTHER_ENTRY" "$HOOK_ENTRY"
out="$(run_check both)"
check_case "missing from Claude Code's settings warns with the register command" \
    bash -c '[[ "$1" == agent.mail_stop_hook\|warn\|*"Claude Code"*\|*"agent_mail_hook.sh register claude"* ]]' _ "$out"
check_case "the warning doesn't ask to register Codex again" \
    bash -c '[[ "$1" != *"register codex"* ]]' _ "$out"

fixture "$HOOK_ENTRY" ""
out="$(run_check both)"
check_case "no Codex hooks.json warns with the codex register command" \
    bash -c '[[ "$1" == agent.mail_stop_hook\|warn\|*Codex*\|*"agent_mail_hook.sh register codex"* ]]' _ "$out"

fixture "$HOOK_ENTRY" ""
out="$(run_check claude)"
check_case "Claude Code only, registered: passes without asking about Codex" \
    bash -c '[[ "$1" == agent.mail_stop_hook\|pass\|*"Claude Code"*\| && "$1" != *Codex* ]]' _ "$out"

fixture "" ""
out="$(run_check none)"
check_case "no Claude Code or Codex: skips" \
    bash -c '[[ "$1" == agent.mail_stop_hook\|skip\|* ]]' _ "$out"

fixture "" ""
out="$(run_check both false)"
check_case "no Agent Mail: skips" \
    bash -c '[[ "$1" == agent.mail_stop_hook\|skip\|* ]]' _ "$out"

fixture "" ""
before="$(find "$WORK/home" -type f | sort)"
run_check both >/dev/null
check_case "the check writes nothing" test "$(find "$WORK/home" -type f | sort)" = "$before"

echo
echo "doctor agent.mail_stop_hook: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
