#!/usr/bin/env bash
# ============================================================
# ACFS - Unit Tests for the installer's smoke test and the
# module selection
#
# install.sh runs run_smoke_test at the end of a full install.
# A module the user skipped (--skip, a legacy --skip-* flag, or
# the interactive selector) is not installed, so its critical
# check must not fail the install. A selected module that is
# missing still must.
#
# The test resolves a real selection from the manifest, extracts
# run_smoke_test and its helpers from install.sh, and stubs only
# the probes that would touch the target user or the host.
#
# Run with: bash tests/unit/test_install_smoke_selection.sh
# ============================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts/lib"
INSTALLER="$REPO_ROOT/install.sh"

# shellcheck source=scripts/lib/logging.sh
source "$SCRIPT_DIR/logging.sh"
# shellcheck source=scripts/lib/install_helpers.sh
source "$SCRIPT_DIR/install_helpers.sh"

# The smoke test and the helpers it calls, taken from install.sh. A helper
# that doesn't exist in this install.sh extracts as nothing.
for smoke_fn in _smoke_module_selected _smoke_join acfs_smoke_install_fix_command run_smoke_test; do
    eval "$(sed -n "/^${smoke_fn}() {/,/^}$/p" "$INSTALLER")"
done
unset smoke_fn

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "FAIL: $1"
    echo "  Reason: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# --- Stubs for the probes that would touch the target user or the host ---
acfs_early_system_binary_path() { printf '%s\n' /bin/true; }
# SMOKE_EXTERNAL_ACCOUNT=true: an externally managed account whose login
# shell is bash, with no zsh handoff.
SMOKE_EXTERNAL_ACCOUNT=false
acfs_early_getent_passwd_entry() {
    local shell="/usr/bin/zsh"
    [[ "$SMOKE_EXTERNAL_ACCOUNT" == "true" ]] && shell="/bin/bash"
    printf '%s:x:1000:1000::%s:%s\n' "$1" "$TARGET_HOME" "$shell"
}
acfs_is_externally_managed_user() { [[ "$SMOKE_EXTERNAL_ACCOUNT" == "true" ]]; }
acfs_external_shell_handoff_configured() { return 1; }
# sudo, /data/projects and the stack tools pass; herdr works when its fake
# binary is there.
_smoke_run_as_target() {
    case "$1" in
        *herdr*) [[ -x "$ACFS_BIN_DIR/herdr" ]] ;;
        *) return 0 ;;
    esac
}
binary_installed() { [[ -x "$ACFS_BIN_DIR/$1" ]]; }
command_exists() { return 1; }
run_as_target() { return 1; }

SMOKE_ROOT="$(mktemp -d)"

# A fresh target home with every binary the critical checks look for,
# except the ones named as arguments.
make_target() {
    local without=" $* "
    TARGET_HOME="$(mktemp -d "$SMOKE_ROOT/home.XXXXXX")"
    ACFS_BIN_DIR="$TARGET_HOME/.local/bin"
    mkdir -p "$ACFS_BIN_DIR" "$TARGET_HOME/.bun/bin" "$TARGET_HOME/.cargo/bin"
    local path=""
    for path in .bun/bin/bun .local/bin/uv .cargo/bin/cargo .local/bin/go \
        .local/bin/claude .bun/bin/codex .local/bin/agy .local/bin/agy-locked .local/bin/agy-real \
        .local/bin/herdr .local/bin/onboard; do
        [[ "$without" == *" ${path##*/} "* ]] && continue
        printf '#!/bin/sh\n' > "$TARGET_HOME/$path"
        chmod +x "$TARGET_HOME/$path"
    done
    TARGET_USER="tester"
    MODE="vibe"
    SKIP_POSTGRES=false
    SKIP_VAULT=false
    SKIP_CLOUD=false
    ACFS_REPO_OWNER="arosl"
    ACFS_REPO_NAME="agentic_coding_flywheel_setup"
    ACFS_REF_INPUT="main"
    unset ACFS_COMMIT_SHA_FULL
}

# Resolve the selection a full install would, with these modules skipped.
select_with_skips() {
    ONLY_MODULES=()
    ONLY_PHASES=()
    SKIP_MODULES=("$@")
    SKIP_TAGS=()
    SKIP_CATEGORIES=()
    NO_DEPS=false
    ACFS_SELECTED_PROFILE=""
    ACFS_CLI_PROFILE=""
    ACFS_INTERACTIVE=false
    ACFS_EXPLICIT_TARGETED_SELECTION=false
    acfs_resolve_selection >/dev/null 2>&1
}

SMOKE_OUTPUT=""
SMOKE_STATUS=0
run_smoke() {
    SMOKE_STATUS=0
    SMOKE_OUTPUT="$(run_smoke_test 2>&1)" || SMOKE_STATUS=$?
}

# The Fix lines the smoke test printed.
fix_lines() {
    grep -F 'Fix:' <<< "$SMOKE_OUTPUT" || true
}

test_default_selection_passes_all_eight() {
    make_target
    select_with_skips || { fail "default_selection_passes_all_eight" "default selection failed"; return 1; }
    run_smoke
    [[ "$SMOKE_STATUS" -eq 0 && "$SMOKE_OUTPUT" == *"Smoke test: 8/8 critical passed"* ]] \
        || { fail "default_selection_passes_all_eight" "status $SMOKE_STATUS, output: $SMOKE_OUTPUT"; return 1; }
    [[ "$SMOKE_OUTPUT" == *"✅ Agents: claude, codex, agy"* && "$SMOKE_OUTPUT" == *"✅ Languages: bun, uv, cargo, go available"* ]] \
        || { fail "default_selection_passes_all_eight" "pass lines changed: $SMOKE_OUTPUT"; return 1; }
    [[ "$SMOKE_OUTPUT" != *"not selected"* ]] \
        || { fail "default_selection_passes_all_eight" "a default install reported a skip: $SMOKE_OUTPUT"; return 1; }
    pass "default_selection_passes_all_eight"
}

test_skipped_codex_is_not_a_failure() {
    make_target codex
    select_with_skips agents.codex || { fail "skipped_codex_is_not_a_failure" "--skip agents.codex failed selection"; return 1; }
    run_smoke
    [[ "$SMOKE_STATUS" -eq 0 && "$SMOKE_OUTPUT" == *"Smoke test: 8/8 critical passed"* ]] \
        || { fail "skipped_codex_is_not_a_failure" "status $SMOKE_STATUS, output: $SMOKE_OUTPUT"; return 1; }
    [[ "$SMOKE_OUTPUT" == *"⚠️ Agents: codex skipped (not selected)"* && "$SMOKE_OUTPUT" == *"✅ Agents: claude, agy"* ]] \
        || { fail "skipped_codex_is_not_a_failure" "no skipped line for codex: $SMOKE_OUTPUT"; return 1; }
    [[ "$(fix_lines)" != *"agents.codex"* ]] \
        || { fail "skipped_codex_is_not_a_failure" "a Fix line reinstalls the skipped codex: $(fix_lines)"; return 1; }
    pass "skipped_codex_is_not_a_failure"
}

test_skipped_onboard_drops_out_of_the_count() {
    make_target codex onboard
    select_with_skips agents.codex acfs.onboard \
        || { fail "skipped_onboard_drops_out_of_the_count" "--skip agents.codex --skip acfs.onboard failed selection"; return 1; }
    run_smoke
    [[ "$SMOKE_STATUS" -eq 0 && "$SMOKE_OUTPUT" == *"Smoke test: 7/7 critical passed"* ]] \
        || { fail "skipped_onboard_drops_out_of_the_count" "status $SMOKE_STATUS, output: $SMOKE_OUTPUT"; return 1; }
    [[ "$SMOKE_OUTPUT" == *"⚠️ Onboard: skipped (not selected)"* ]] \
        || { fail "skipped_onboard_drops_out_of_the_count" "no skipped line for onboard: $SMOKE_OUTPUT"; return 1; }
    pass "skipped_onboard_drops_out_of_the_count"
}

test_missing_selected_agent_still_fails() {
    make_target codex
    select_with_skips || { fail "missing_selected_agent_still_fails" "default selection failed"; return 1; }
    run_smoke
    [[ "$SMOKE_STATUS" -ne 0 && "$SMOKE_OUTPUT" == *"✖ Agents: missing codex"* ]] \
        || { fail "missing_selected_agent_still_fails" "status $SMOKE_STATUS, output: $SMOKE_OUTPUT"; return 1; }
    local agents_fix=""
    agents_fix="$(grep -F -A1 '✖ Agents:' <<< "$SMOKE_OUTPUT" | grep -F 'Fix:')"
    [[ "$agents_fix" == *"--only agents.codex"* && "$agents_fix" != *"agents.claude"* && "$agents_fix" != *"agents.antigravity"* ]] \
        || { fail "missing_selected_agent_still_fails" "the Fix line should name only agents.codex: $agents_fix"; return 1; }
    pass "missing_selected_agent_still_fails"
}

# A critical check that ran but only warned still counts in the total, so
# the summary doesn't claim every critical check passed.
test_warned_critical_check_stays_in_the_total() {
    make_target
    select_with_skips || { fail "warned_critical_check_stays_in_the_total" "default selection failed"; return 1; }
    SMOKE_EXTERNAL_ACCOUNT=true
    run_smoke
    SMOKE_EXTERNAL_ACCOUNT=false
    [[ "$SMOKE_STATUS" -eq 0 && "$SMOKE_OUTPUT" == *"⚠ Shell: externally managed account reports /bin/bash"* \
        && "$SMOKE_OUTPUT" == *"Smoke test: 7/8 critical passed"* ]] \
        || { fail "warned_critical_check_stays_in_the_total" "status $SMOKE_STATUS, output: $SMOKE_OUTPUT"; return 1; }
    pass "warned_critical_check_stays_in_the_total"
}

test_unresolved_selection_checks_everything() {
    make_target codex onboard
    ACFS_GENERATED_SELECTION_READY=false
    ACFS_EFFECTIVE_RUN=()
    run_smoke
    [[ "$SMOKE_STATUS" -ne 0 && "$SMOKE_OUTPUT" == *"✖ Agents: missing codex"* && "$SMOKE_OUTPUT" == *"✖ Onboard: missing"* ]] \
        || { fail "unresolved_selection_checks_everything" "status $SMOKE_STATUS, output: $SMOKE_OUTPUT"; return 1; }
    pass "unresolved_selection_checks_everything"
}

# --only and --only-phase (and profiles, which set them) mark modules
# "filtered by phase" or leave them unselected while they may be installed
# from an earlier run. The smoke test must not run then, or it would skip
# checks for modules that are there. The guard lives at its only call site.
test_smoke_test_runs_only_without_only_selectors() {
    local calls="" guard=""
    calls="$(grep -c 'run_smoke_test;' "$INSTALLER")"
    guard="$(grep -B1 'if ! run_smoke_test; then' "$INSTALLER" | head -1)"
    [[ "$calls" -eq 1 && "$guard" == *'${#ONLY_MODULES[@]} -eq 0 ]] && [[ ${#ONLY_PHASES[@]} -eq 0 ]]'* ]] \
        || { fail "smoke_test_runs_only_without_only_selectors" "call sites: $calls, guard line: $guard"; return 1; }
    pass "smoke_test_runs_only_without_only_selectors"
}

run_all_tests() {
    source_manifest_index
    test_default_selection_passes_all_eight
    test_skipped_codex_is_not_a_failure
    test_skipped_onboard_drops_out_of_the_count
    test_missing_selected_agent_still_fails
    test_warned_critical_check_stays_in_the_total
    test_unresolved_selection_checks_everything
    test_smoke_test_runs_only_without_only_selectors

    echo ""
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        return 1
    fi
    return 0
}

run_all_tests
