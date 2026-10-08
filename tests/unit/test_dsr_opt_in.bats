#!/usr/bin/env bats
#
# stack.doodlestein_self_releaser (dsr) needs Docker, which ACFS doesn't
# install, so the manifest has it off by default. A default install takes
# install.sh's hand-written stack path, so that path must honor the resolved
# selection. These tests resolve the real selection from the generated
# manifest index, then run the shipped dsr block extracted from install.sh,
# with the installer itself stubbed out.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CALLS="$BATS_TEST_TMPDIR/dsr_calls"
}

# Runs the dsr block after resolving the selection with the given --only
# modules (none: a default install).
run_dsr_block() {
    run bash -c '
        set -uo pipefail
        root="$1"; calls="$2"; shift 2
        log_detail() { :; }
        log_warn() { :; }
        log_info() { :; }
        log_error() { :; }
        source "$root/scripts/generated/manifest_index.sh"
        ACFS_MANIFEST_INDEX_LOADED=true
        source "$root/scripts/lib/install_helpers.sh"
        ONLY_MODULES=("$@")
        ONLY_PHASES=()
        SKIP_MODULES=()
        NO_DEPS=true
        acfs_resolve_selection >/dev/null 2>&1 || { echo "selection failed"; exit 3; }

        binary_installed() { return 1; }
        try_step() { shift; "$@"; }
        acfs_run_verified_upstream_script_as_target() { printf "%s\n" "$1" >> "$calls"; }
        acfs_optional_module_install_failed() { :; }

        eval "dsr_block() {
$(sed -n "/^    # Doodlestein Self-Releaser (dsr)/,/^    fi$/p" "$root/install.sh")
}"
        dsr_block
    ' _ "$PROJECT_ROOT" "$CALLS" "$@"
}

@test "a default install does not install dsr" {
    run_dsr_block
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
}

@test "selecting stack.doodlestein_self_releaser installs dsr" {
    run_dsr_block "stack.doodlestein_self_releaser"
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == "dsr" ]]
}
