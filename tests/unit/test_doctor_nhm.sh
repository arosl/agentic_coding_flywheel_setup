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

# run_check <agents: claude|codex|both|none> [nhm present: true|false]
# prints "id|status|details|fix".
run_check() {
    local agents="$1" nhm_present="${2:-true}"
    STUB_HOME="$WORK/home" STUB_AGENTS="$agents" STUB_NHM="$nhm_present" XDG_STATE_HOME="" \
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
}

echo "stack.nhm.setup"

fixture yes both
out="$(run_check both)"
check_case "enrolled and registered for both passes" \
    bash -c '[[ "$1" == stack.nhm.setup\|pass\|enrolled*"Claude Code"*Codex*\| ]]' _ "$out"
check_case "the Codex pass reminds that /hooks must trust them" bash -c '[[ "$1" == *"/hooks"* ]]' _ "$out"

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
check_case "enrolled, no agent CLI: passes" bash -c '[[ "$1" == stack.nhm.setup\|pass\|enrolled\| ]]' _ "$out"

fixture no none
out="$(run_check both false)"
check_case "no nhm: skips" bash -c '[[ "$1" == stack.nhm.setup\|skip\|* ]]' _ "$out"

fixture no none
before="$(find "$WORK/home" -type f | sort)"
run_check both >/dev/null
check_case "the check writes nothing" test "$(find "$WORK/home" -type f | sort)" = "$before"

echo
echo "doctor nhm: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
