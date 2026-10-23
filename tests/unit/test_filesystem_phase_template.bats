#!/usr/bin/env bats
#
# install.sh's own filesystem phase is the default (filesystem is not a
# migrated category), and since upstream's #474 install.sh runs
# base.filesystem's verify after it. That verify requires the ACFS-owned
# copy of the workspace AGENTS.md template, so the phase must write every
# file the verify tests for. acfs-qe94: it wrote /data/projects/AGENTS.md
# only, and every fresh install failed phase 2.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# Runs install.sh's setup_filesystem with stubs, and prints each
# install_asset destination it asks for.
run_filesystem_phase() {
    eval "$(sed -n '/^setup_filesystem() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t setup_filesystem)" == "function" ]]

    ASSETS="$BATS_TEST_TMPDIR/assets"
    : > "$ASSETS"
    set_phase() { :; }
    log_step() { :; }
    log_detail() { :; }
    log_error() { :; }
    log_success() { :; }
    acfs_use_generated_category() { return 1; }
    try_step() { shift; "$@"; }
    try_step_optional() { shift; "$@"; }
    fake_sudo() { :; }
    run_as_target() { :; }
    acfs_chown_target_home() { :; }
    acfs_chown_tree() { :; }
    acfs_ensure_primary_bin_dir() { :; }
    user_container_tmp_policy() { :; }
    install_asset() { printf '%s\n' "$2" >> "$ASSETS"; }

    SUDO=fake_sudo
    TARGET_USER=ubuntu
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    ACFS_HOME="$TARGET_HOME/.acfs"
    ACFS_LOG_DIR="$ACFS_HOME/logs"
    ACFS_BIN_DIR="$TARGET_HOME/.local/bin"
    mkdir -p "$TARGET_HOME/Development" "$TARGET_HOME/Projects" "$TARGET_HOME/dotfiles"

    local rc=0
    setup_filesystem || rc=$?
    printf 'rc=%s\n' "$rc"
    sed 's/^/asset=/' "$ASSETS"
}

# Each "$target_home/..." file that base.filesystem's verify tests with
# test -f, as a path under TARGET_HOME.
verified_files() {
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/scripts/generated/manifest_index.sh"
    local count="${ACFS_MODULE_VERIFY_COUNT[base.filesystem]:-0}" i
    (( count > 0 )) || return 1
    for ((i = 0; i < count; i++)); do
        grep -oE 'test -f "\$target_home/[^"]+"' <<< "${ACFS_MODULE_VERIFY_COMMAND[base.filesystem.$i]}" || true
    done | sed -E 's|^test -f "\$target_home/(.*)"$|\1|'
}

@test "base.filesystem's verify tests for the ACFS-owned AGENTS.md template" {
    run verified_files
    [[ "$status" -eq 0 ]]
    [[ "$output" == *".acfs/docs/AGENTS.workspace.md"* ]]
}

@test "install.sh's filesystem phase installs every file base.filesystem's verify tests for" {
    local files phase file missing=""
    files="$(verified_files)"
    [[ -n "$files" ]]
    phase="$(run_filesystem_phase)"
    [[ "$phase" == *"rc=0"* ]]
    while IFS= read -r file; do
        [[ "$phase" == *"asset=$BATS_TEST_TMPDIR/home/$file"* ]] || missing+="$file "
    done <<< "$files"
    printf 'missing: %s\n' "$missing"
    [[ -z "$missing" ]]
}

@test "install.sh's filesystem phase still installs /data/projects/AGENTS.md" {
    run run_filesystem_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"asset=/data/projects/AGENTS.md"* ]]
}
