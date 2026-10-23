#!/usr/bin/env bash
# ============================================================
# install.sh records the install's outcome in state.json (acfs-8j1)
#
# Runs the real install.sh (sourced without its trailing `main "$@"`, so
# its real cleanup() EXIT trap is registered) with the real state.sh in a
# subprocess per scenario:
#   1. A run this process opened (state_init, a phase start) that exits 1
#      without a result ends with install_status failed.
#   2. A process that never opened the run (an earlier install's complete
#      state) exits 1: install_status stays complete.
#   3. A run that main closed as complete and that exits 0 stays complete.
#   4. acfs_summary_emit's failure object names every failed phase.
#   5. main records install_status before any success output or summary.
#   6. A failed Ubuntu-upgrade preparation, which opened its own state file
#      and pointed ACFS_STATE_FILE back at the install's, exits 1: the
#      install's complete status stays complete (acfs-vd2j).
#   7. The same preparation succeeding exits 0 for its reboot: its state
#      stays in_progress.
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/acfs-install-state-status.XXXXXX")"
cleanup_tmproot() { rm -rf "$TMPROOT"; }
trap cleanup_tmproot EXIT

FAIL=0
assert() {
    local desc="$1" cond="$2"
    if [[ "$cond" == "true" ]]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        FAIL=1
    fi
}

INSTALL_SH="$REPO_ROOT/install.sh"
SOURCEABLE="$TMPROOT/install_sourceable.sh"
if [[ "$(tail -n 1 "$INSTALL_SH")" != 'main "$@"' ]]; then
    echo "FATAL: install.sh's last line is not \`main \"\$@\"\`; update this test." >&2
    exit 2
fi
head -n "$(($(wc -l < "$INSTALL_SH") - 1))" "$INSTALL_SH" > "$SOURCEABLE"
bash -n "$SOURCEABLE" || { echo "FATAL: sourceable copy of install.sh fails bash -n"; exit 2; }

# Writes a scenario script: it sources install.sh and state.sh with a state
# file under $1, then runs the scenario body that follows on stdin.
write_scenario() {
    local out="$1" state_dir="$2"
    {
        cat <<EOF
set -uo pipefail
TARGET_USER="$(whoami)"
TARGET_HOME="$state_dir/home"
MODE="vibe"
HAS_GUM=false
# shellcheck disable=SC1090
source "$SOURCEABLE"
# shellcheck disable=SC1090
source "$REPO_ROOT/scripts/lib/state.sh"
ACFS_HOME="$state_dir/home/.acfs"
ACFS_STATE_FILE="\$ACFS_HOME/state.json"
export ACFS_HOME ACFS_STATE_FILE
mkdir -p "\$ACFS_HOME"
EOF
        cat
    } > "$out"
}

run_scenario() {
    local name="$1"
    local state_dir="$TMPROOT/$name"
    mkdir -p "$state_dir/home"
    write_scenario "$state_dir/scenario.sh" "$state_dir"
    bash "$state_dir/scenario.sh" > "$state_dir/out.log" 2>&1
    echo "$?"
}

state_value() {
    jq -r "$2" "$TMPROOT/$1/home/.acfs/state.json" 2>/dev/null
}

# 1. Opened by this process, then an exit main did not handle.
rc="$(run_scenario opened_exit <<'EOF'
state_init
state_phase_start "cli_tools"
exit 1
EOF
)"
assert "1a. the opened run exits 1" "$([[ "$rc" == "1" ]] && echo true || echo false)"
assert "1b. the EXIT trap records install_status failed" \
    "$([[ "$(state_value opened_exit '.install_status')" == "failed" ]] && echo true || echo false)"

# 2. Never opened by this process (no state_init, no phase start).
rc="$(run_scenario foreign_exit <<'EOF'
printf '%s\n' '{"schema_version":3,"version":"0.7.0","mode":"vibe","completed_phases":["user_setup","filesystem","shell_setup","cli_tools","languages","agents","cloud_db","stack","finalize"],"install_status":"complete"}' > "$ACFS_STATE_FILE"
exit 1
EOF
)"
assert "2a. the process that never opened the run exits 1" "$([[ "$rc" == "1" ]] && echo true || echo false)"
assert "2b. an earlier install's complete status is left alone" \
    "$([[ "$(state_value foreign_exit '.install_status')" == "complete" ]] && echo true || echo false)"

# 3. Closed as complete by main's end-of-run step, then a clean exit.
rc="$(run_scenario closed_complete <<'EOF'
state_init
for phase in "${ACFS_PHASE_IDS[@]}"; do
    state_phase_start "$phase"
    state_phase_complete "$phase"
done
state_install_finish false
exit 0
EOF
)"
assert "3a. the closed run exits 0" "$([[ "$rc" == "0" ]] && echo true || echo false)"
assert "3b. install_status stays complete" \
    "$([[ "$(state_value closed_complete '.install_status')" == "complete" ]] && echo true || echo false)"

# 4. The install summary's failure object names every failed phase.
rc="$(run_scenario summary_failure <<'EOF'
state_init
state_phase_start "languages"
state_phase_fail "languages" "Execution failed" "exit 1"
state_phase_start "stack"
state_phase_fail "stack" "Installing dcg" "exit 1"
state_install_finish true
acfs_summary_emit "failure" 0 || exit 3
cp "$ACFS_SUMMARY_FILE" "$ACFS_HOME/summary.json"
exit 0
EOF
)"
summary_failure="$(jq -c '.failure | [.phase, .failed_phases, .step]' "$TMPROOT/summary_failure/home/.acfs/summary.json" 2>/dev/null)"
assert "4a. acfs_summary_emit wrote a summary (rc=$rc)" "$([[ "$rc" == "0" ]] && echo true || echo false)"
assert "4b. the failure names the last phase and lists both: $summary_failure" \
    "$([[ "$summary_failure" == '["stack",["languages","stack"],"Installing dcg"]' ]] && echo true || echo false)"
assert "4c. state.json says failed" \
    "$([[ "$(state_value summary_failure '.install_status')" == "failed" ]] && echo true || echo false)"

# 5. main records install_status after the smoke test and before the first
#    success side effect (acfs_report_success_if_clean) and print_summary.
main_body="$(awk '/^main\(\) \{/,/^}/' "$INSTALL_SH")"
line_of() { grep -n -m1 -F -- "$1" <<< "$main_body" | cut -d: -f1; }
finish_line="$(line_of 'state_install_finish "$run_failed"')"
smoke_line="$(line_of 'run_smoke_test')"
report_line="$(line_of 'acfs_report_success_if_clean "$total_seconds"')"
# The first print_summary after the success report (the dry-run branch has one earlier).
summary_line="$(awk -v after="${report_line:-0}" 'NR > after && /print_summary/ { print NR; exit }' <<< "$main_body")"
assert "5. main: smoke test < state_install_finish < success report < summary ($smoke_line < $finish_line < $report_line < $summary_line)" \
    "$([[ -n "$finish_line" && -n "$smoke_line" && -n "$report_line" && -n "$summary_line" ]] \
        && (( smoke_line < finish_line && finish_line < report_line && report_line < summary_line )) && echo true || echo false)"

# 6. run_ubuntu_upgrade_phase's failure path: it opens its own state file
#    (state_init), then restore_previous_acfs_state_file points
#    ACFS_STATE_FILE back at the install's, and main exits 1.
rc="$(run_scenario upgrade_restore <<'EOF'
printf '%s\n' '{"schema_version":3,"version":"0.7.0","mode":"safe","completed_phases":["user_setup","filesystem","shell_setup","cli_tools","languages","agents","cloud_db","stack","finalize"],"install_status":"complete"}' > "$ACFS_STATE_FILE"
previous_state_file="$ACFS_STATE_FILE"
export ACFS_STATE_FILE="$ACFS_HOME/upgrade-state.json"
state_init || exit 3
restore_previous_acfs_state_file true "$previous_state_file"
exit 1
EOF
)"
assert "6a. the failed preparation exits 1" "$([[ "$rc" == "1" ]] && echo true || echo false)"
assert "6b. the install's complete status is left alone" \
    "$([[ "$(state_value upgrade_restore '.install_status')" == "complete" ]] && echo true || echo false)"
assert "6c. the upgrade's own state file was opened (state_init ran)" \
    "$([[ -f "$TMPROOT/upgrade_restore/home/.acfs/upgrade-state.json" ]] && echo true || echo false)"

# 7. The same preparation succeeding: it exits 0 for its reboot, and the
#    run it opened stays in_progress for the install that follows.
rc="$(run_scenario upgrade_reboot <<'EOF'
export ACFS_STATE_FILE="$ACFS_HOME/upgrade-state.json"
state_init || exit 3
exit 0
EOF
)"
assert "7a. the preparation exits 0 for its reboot" "$([[ "$rc" == "0" ]] && echo true || echo false)"
assert "7b. its state stays in_progress" \
    "$([[ "$(jq -r '.install_status' "$TMPROOT/upgrade_reboot/home/.acfs/upgrade-state.json" 2>/dev/null)" == "in_progress" ]] && echo true || echo false)"

if [[ "$FAIL" -ne 0 ]]; then
    for log in "$TMPROOT"/*/out.log; do
        echo "--- $log"
        tail -n 20 "$log"
    done
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
