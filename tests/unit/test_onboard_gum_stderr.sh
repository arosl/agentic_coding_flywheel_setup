#!/usr/bin/env bash
# ============================================================
# Interactive gum never has its stderr discarded.
#
# gum v2 draws its UI and sends its terminal queries on stderr
# (stdout carries only the answer), so `gum choose ... 2>/dev/null`
# leaves the user at a blank screen: acfs-268, onboard's lesson
# menu. This scans every tracked shell script outside tests/ for
# an interactive gum command whose statement (with its backslash
# continuations) sends stderr to /dev/null.
#
# Run with: bash tests/unit/test_onboard_gum_stderr.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
ONBOARD_SH="$REPO_ROOT/packages/onboard/onboard.sh"

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
}

# Print "file:line" for each interactive gum statement in the given
# files that redirects stderr (2> or &>) to /dev/null.
gum_stderr_discards() {
    awk '
        FNR == 1 { file = FILENAME }
        /^[[:space:]]*#/ { next }
        /gum (choose|confirm|input|filter|write|file|spin|table|pager)/ {
            stmt = $0
            start = FNR
            while (stmt ~ /\\$/ && (getline line) > 0) stmt = stmt "\n" line
            if (stmt ~ /(2|&)>[[:space:]]*\/dev\/null/) print file ":" start
        }
    ' "$@"
}

# ------------------------------------------------------------
# The scanner catches the pattern acfs-268 removed
# ------------------------------------------------------------
fixture="$(mktemp)"
# The trailing backslash is fixture text: a line continuation.
# shellcheck disable=SC1003
printf '%s\n' \
    'choice=$(printf "%s\n" a b | gum choose \' \
    '    --header "Pick:" 2>/dev/null) || true' \
    'gum confirm "Sure?" &>/dev/null || true' \
    'gum style "not interactive" 2>/dev/null' >"$fixture"
found="$(gum_stderr_discards "$fixture" | wc -l)"
rm -f "$fixture"
if [[ "$found" -eq 2 ]]; then
    pass "the scanner flags a multi-line gum choose and a gum confirm that discard stderr"
else
    fail "the scanner flags a multi-line gum choose and a gum confirm that discard stderr" "$found hits"
fi

# ------------------------------------------------------------
# onboard still drives its menus through gum choose
# ------------------------------------------------------------
choose_count="$(grep -c 'gum choose' "$ONBOARD_SH")"
if [[ "$choose_count" -ge 3 ]]; then
    pass "onboard.sh draws its menus with gum choose ($choose_count calls)"
else
    fail "onboard.sh draws its menus with gum choose" "$choose_count calls"
fi

# ------------------------------------------------------------
# No tracked script discards an interactive gum command's stderr
# ------------------------------------------------------------
mapfile -t scripts < <(git -C "$REPO_ROOT" ls-files '*.sh' ':!tests/' | sed "s|^|$REPO_ROOT/|")
offenders="$(gum_stderr_discards "${scripts[@]}" | sed "s|^$REPO_ROOT/||")"
if [[ -z "$offenders" ]]; then
    pass "no interactive gum call in ${#scripts[@]} tracked scripts discards stderr"
else
    fail "no interactive gum call discards stderr" "${offenders//$'\n'/ }"
fi

printf '\nTests passed: %d\nTests failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
