#!/usr/bin/env bash
# ============================================================
# acfs update registers the Agent Mail Stop hook on existing installs
# (acfs-pf26): update_agent_mail_stop_hook in scripts/lib/update.sh.
#
# Sources update.sh (its guard keeps main from running), stubs the helpers
# that look at the host (update_binary_exists, update_target_user, ...),
# and runs the real agent_mail_hook.sh against a fixture home. Nothing here
# touches the caller's ~/.claude or ~/.codex.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_update_agent_mail_hook.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}
check() { # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name" "${OUT:-}"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
lacks() { [[ "$OUT" != *"$1"* ]]; }

ROOT="$(mktemp -d)"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# run_hook <installed binaries...>: a fresh fixture home with ACFS's copy of
# agent_mail_hook.sh, then update_agent_mail_stop_hook with the given
# binaries "installed". Env knobs: SAME_USER (default 1), READ_ONLY,
# NO_HELPER, KEEP_HOME (reuse the previous home).
run_hook() {
    if [[ -z "${KEEP_HOME:-}" ]]; then
        FIX_HOME="$(mktemp -d -p "$ROOT")"
        mkdir -p "$FIX_HOME/.acfs/scripts/lib" "$FIX_HOME/.claude" "$FIX_HOME/.codex"
        [[ -n "${NO_HELPER:-}" ]] || cp "$REPO_ROOT/scripts/lib/agent_mail_hook.sh" "$FIX_HOME/.acfs/scripts/lib/"
        printf '{\n  "model": "opus",\n  "hooks": {}\n}\n' > "$FIX_HOME/.claude/settings.json"
    fi
    OUT="$(
        export HOME="$FIX_HOME" TARGET_HOME="$FIX_HOME" UPDATE_LOG_FILE="$ROOT/update.log"
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/update.sh" >/dev/null 2>&1
        INSTALLED=" $* "
        update_binary_exists() { [[ "$INSTALLED" == *" $1 "* ]]; }
        update_runtime_acfs_home() { printf '%s\n' "$FIX_HOME/.acfs"; }
        update_target_user() { printf 'ubuntu\n'; }
        update_target_home() { printf '%s\n' "$FIX_HOME"; }
        log_detail() { printf 'DETAIL %s\n' "$1"; }
        UPDATE_STACK="${STACK:-true}"
        update_current_user() { if [[ "${SAME_USER:-1}" == 1 ]]; then printf 'ubuntu\n'; else printf 'root\n'; fi; }
        update_is_read_only_mode() { [[ -n "${READ_ONLY:-}" ]]; }
        log_item() { printf 'ITEM %s|%s|%s\n' "$1" "$2" "${3:-}"; }
        update_agent_mail_stop_hook
        printf 'RC %s\n' "$?"
    )"
}
registered_in() { bash "$REPO_ROOT/scripts/lib/agent_mail_hook.sh" registered "$1"; }

# ------------------------------------------------------------
run_hook am claude
check "update: the function exists and returns 0" has "RC 0"
check "update: Claude Code gets the hook" registered_in "$FIX_HOME/.claude/settings.json"
check "update: reports what it registered" has "ITEM ok|Agent Mail Stop hook|registered for claude"
OUT="$(cat "$FIX_HOME/.claude/settings.json")"
check "update: the rest of settings.json is kept" has '"model": "opus"'
check "update: Codex isn't installed, so its file is left alone" test ! -e "$FIX_HOME/.codex/hooks.json"

before="$(cat "$FIX_HOME/.claude/settings.json")"
KEEP_HOME=1 run_hook am claude
check "update: a second run changes nothing" test "$(cat "$FIX_HOME/.claude/settings.json")" == "$before"
check "update: ... and still reports ok" has "ITEM ok|Agent Mail Stop hook|registered for claude"

run_hook am claude codex
check "update: Codex gets the hook too" registered_in "$FIX_HOME/.codex/hooks.json"
check "update: both are named" has "registered for claude, codex"
check "update: a new Codex hook comes with the /hooks trust note" has "DETAIL Codex asks to trust the Agent Mail Stop hook once"
KEEP_HOME=1 run_hook am claude codex
check "update: ... but not again once it is registered" lacks "DETAIL Codex asks"

STACK=false run_hook am claude codex
check "update: a partial mode (--agents-only) does nothing" test "$OUT" == "RC 0"
OUT="$(cat "$FIX_HOME/.claude/settings.json")"
check "update: ... settings.json untouched" lacks "agent_mail_hook"
check "update: ... and no Codex hooks.json written" test ! -e "$FIX_HOME/.codex/hooks.json"

run_hook claude codex
check "update: without Agent Mail it skips" has "ITEM skip|Agent Mail Stop hook|Agent Mail is not installed"
check "update: ... and writes nothing" lacks "registered for"
OUT="$(cat "$FIX_HOME/.claude/settings.json")"
check "update: ... settings.json untouched" lacks "agent_mail_hook"

NO_HELPER=1 run_hook am claude
check "update: without ACFS's copy of the hook it skips" has "agent_mail_hook.sh is not installed"

READ_ONLY=1 run_hook am claude
check "update: a dry run skips" has "ITEM skip|Agent Mail Stop hook|dry-run"
OUT="$(cat "$FIX_HOME/.claude/settings.json")"
check "update: ... and writes nothing" lacks "agent_mail_hook"

SAME_USER=0 run_hook am claude
check "update: run as another user it warns with the command" has "ITEM warn|Agent Mail Stop hook|run as ubuntu: bash $FIX_HOME/.acfs/scripts/lib/agent_mail_hook.sh register claude"
OUT="$(cat "$FIX_HOME/.claude/settings.json")"
check "update: ... and writes nothing (never another user's files)" lacks "agent_mail_hook"

run_hook am
check "update: no agent installed skips" has "ITEM skip|Agent Mail Stop hook|neither Claude Code nor Codex is installed"

OUT="$(sed -n '/^main() {$/,/^}$/p' "$REPO_ROOT/scripts/lib/update.sh")"
check "update: main runs it right after the stack" has $'    update_stack\n    update_agent_mail_stop_hook'

# ------------------------------------------------------------
printf '\nTests passed: %s\nTests failed: %s\n' "$TESTS_PASSED" "$TESTS_FAILED"
(( TESTS_FAILED == 0 ))
