#!/usr/bin/env bash
# ============================================================
# finalize() runs acfs.workspace on a default install
#
# The default install keeps the acfs category on finalize's hand-written
# path, which used to deploy every acfs module except acfs.workspace: no
# starter project, no ~/.acfs/workspace-instructions.txt and no `agents`
# alias, although the onboarding promises the alias.
#
# Each scenario sources the real install.sh (minus its trailing `main "$@"`)
# with the real generated installers, and calls the real finalize() with
# DRY_RUN=true. Only try_step (every asset copy, chmod and link) and
# set_phase are stubbed, so nothing is written outside the scratch directory.
# The real acfs.workspace installer prints its dry-run steps, and the test
# counts them. It proves the dispatch, not the steps on a real machine.
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/acfs-finalize-workspace.XXXXXX")"
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

SOURCEABLE="$TMPROOT/install_sourceable.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
total_lines="$(wc -l < "$INSTALL_SH")"
last_line="$(tail -n 1 "$INSTALL_SH")"
if [[ "$last_line" != 'main "$@"' ]]; then
    echo "FATAL: install.sh's last line is not \`main \"\$@\"\` (got: $last_line); update this test." >&2
    exit 2
fi
head -n "$((total_lines - 1))" "$INSTALL_SH" > "$SOURCEABLE"

# detect_environment resolves scripts/ and acfs/ next to the sourced copy, and
# checks these files against the internal checksum ledger byte for byte.
ln -sfn "$REPO_ROOT/scripts" "$TMPROOT/scripts"
ln -sfn "$REPO_ROOT/acfs" "$TMPROOT/acfs"
mkdir -p "$TMPROOT/packages/onboard"
for ledger_file in install.sh VERSION checksums.yaml acfs.manifest.yaml packages/onboard/onboard.sh; do
    cp -p "$REPO_ROOT/$ledger_file" "$TMPROOT/$ledger_file"
done

# run_finalize <name> <bash lines run before selection is resolved>
# Writes finalize's output to $TMPROOT/<name>.log and its exit code to
# $TMPROOT/<name>.rc.
run_finalize() {
    local name="$1" setup="$2"
    local workdir="$TMPROOT/$name"
    mkdir -p "$workdir/home"
    cat > "$workdir/scenario.sh" <<EOF
set -uo pipefail
TARGET_USER="$(id -un)"
TARGET_HOME="$workdir/home"
MODE="safe"
# shellcheck disable=SC1090
source "$SOURCEABLE"
detect_environment
source_generated_installers
ACFS_HOME="$workdir/home/.acfs"
ACFS_BIN_DIR="$workdir/home/.local/bin"
ACFS_STATE_FILE="\$ACFS_HOME/state.json"
export ACFS_HOME ACFS_STATE_FILE
state_init
SUDO=""
export ACFS_FORCE_REINSTALL=true
DRY_RUN=true
$setup
acfs_generated_ensure_selection || { echo "FATAL: selection failed"; exit 2; }
try_step() { return 0; }
set_phase() { :; }
finalize_rc=0
finalize || finalize_rc=\$?
printf 'MODULE FAILURE: %s\n' "\${ACFS_MODULE_FAILURES[@]}"
exit "\$finalize_rc"
EOF
    local rc=0
    bash "$workdir/scenario.sh" > "$TMPROOT/$name.log" 2>&1 || rc=$?
    echo "$rc" > "$TMPROOT/$name.rc"
}

# How many times the acfs.workspace installer ran its first step.
workspace_runs() {
    grep -c "dry-run: install: mkdir -p /data/projects/my_first_project" "$TMPROOT/$1.log" || true
}

run_finalize default ""
assert "1a. default install: finalize runs acfs.workspace once (ran $(workspace_runs default))" \
    "$([[ "$(workspace_runs default)" == "1" ]] && echo true || echo false)"
assert "1b. default install: finalize succeeds (rc $(cat "$TMPROOT/default.rc"))" \
    "$([[ "$(cat "$TMPROOT/default.rc")" == "0" ]] && echo true || echo false)"

# On Ubuntu a selection filter routes every category through generated
# dispatch, so --skip never reaches the hand-written branch there.
run_finalize skipped "SKIP_MODULES=(acfs.workspace)"
assert "2a. --skip acfs.workspace: finalize does not run it (ran $(workspace_runs skipped))" \
    "$([[ "$(workspace_runs skipped)" == "0" ]] && echo true || echo false)"

# On Arch, detect_environment routes every category through the hand-written
# paths, filters or not; this is the same override.
run_finalize arch_skipped "SKIP_MODULES=(acfs.workspace)
acfs_use_generated_for_category() { return 1; }
acfs_use_generated_category() { return 1; }"
assert "2b. Arch route, --skip acfs.workspace: finalize does not run it (ran $(workspace_runs arch_skipped))" \
    "$([[ "$(workspace_runs arch_skipped)" == "0" ]] && echo true || echo false)"
assert "2c. Arch route, --skip acfs.workspace: the hand-written branch reached the installer, which skipped it" \
    "$(grep -q "Skipping acfs.workspace (not selected)" "$TMPROOT/arch_skipped.log" && echo true || echo false)"

run_finalize generated "export ACFS_USE_GENERATED_ACFS=1"
assert "3. generated acfs category: acfs.workspace runs once, not twice (ran $(workspace_runs generated))" \
    "$([[ "$(workspace_runs generated)" == "1" ]] && echo true || echo false)"

# acfs.workspace is optional: a missing installer is recorded, the rest of
# finalize still deploys, and the phase fails so a resume retries it.
run_finalize unavailable "acfs_generated_ensure_selection
unset 'ACFS_MODULE_FUNC[acfs.workspace]'"
assert "4a. installer unavailable: the failure is recorded" \
    "$(grep -q "MODULE FAILURE: acfs.workspace (installer unavailable)" "$TMPROOT/unavailable.log" && echo true || echo false)"
assert "4b. installer unavailable: finalize still runs its later steps" \
    "$(grep -q "Configuring Claude Code session retention" "$TMPROOT/unavailable.log" && echo true || echo false)"
assert "4c. installer unavailable: finalize fails without claiming completion (rc $(cat "$TMPROOT/unavailable.rc"))" \
    "$([[ "$(cat "$TMPROOT/unavailable.rc")" == "1" ]] && ! grep -q "Finalization complete" "$TMPROOT/unavailable.log" && echo true || echo false)"

if [[ "$FAIL" -ne 0 ]]; then
    for log in "$TMPROOT"/*.log; do
        echo "----- $(basename "$log") (last 20 lines)"
        tail -n 20 "$log"
    done
fi
exit "$FAIL"
