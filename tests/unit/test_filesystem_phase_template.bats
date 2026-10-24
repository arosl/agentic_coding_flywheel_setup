#!/usr/bin/env bats
#
# install.sh's own filesystem phase is the default (filesystem is not a
# migrated category), and since upstream's #474 install.sh runs
# base.filesystem's verify after it. That verify requires the ACFS-owned
# copy of the workspace AGENTS.md template, so the phase must write every
# file the verify tests for. acfs-qe94: it wrote /data/projects/AGENTS.md
# only, and every fresh install failed phase 2. acfs-zp8w: it overwrote
# /data/projects/AGENTS.md on every run; it now seeds it only when absent.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# Runs install.sh's setup_filesystem with stubs, and prints, in order, each
# install_asset destination and each workspace AGENTS.md seed it asks for.
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
    install_asset() { printf 'asset=%s%s\n' "$2" "${3:+ $3}" >> "$ASSETS"; }
    acfs_seed_workspace_agents_md() { printf 'seed=%s <- %s\n' "$2" "$1" >> "$ASSETS"; }

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
    cat "$ASSETS"
}

# Loads install.sh's acfs_seed_workspace_agents_md, with a run_as_target
# that logs the command and runs it as is.
load_seed_helper() {
    eval "$(sed -n '/^acfs_seed_workspace_agents_md() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_seed_workspace_agents_md)" == "function" ]]

    RUN_AS_TARGET_LOG="$BATS_TEST_TMPDIR/run_as_target"
    : > "$RUN_AS_TARGET_LOG"
    run_as_target() { printf '%s\n' "$*" >> "$RUN_AS_TARGET_LOG"; "$@"; }

    TEMPLATE="$BATS_TEST_TMPDIR/AGENTS.workspace.md"
    WORKSPACE="$BATS_TEST_TMPDIR/projects"
    printf 'template\n' > "$TEMPLATE"
    mkdir -p "$WORKSPACE"
}

# Loads install.sh's install_asset over a verified source tree in the test
# dir. run_as_target logs and runs the command as is, and the cp it resolves
# logs that the caller copied. Not root here, so the link checks don't run.
load_install_asset() {
    eval "$(sed -n '/^install_asset() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t install_asset)" == "function" ]]

    SOURCE_ROOT="$BATS_TEST_TMPDIR/source"
    mkdir -p "$SOURCE_ROOT/acfs"
    printf 'template\n' > "$SOURCE_ROOT/acfs/AGENTS.md"
    ACFS_TRUSTED_INTERNAL_SOURCE_ROOT="$SOURCE_ROOT"
    ACFS_BOOTSTRAP_DIR="$SOURCE_ROOT"
    TARGET_USER=ubuntu
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    ACFS_HOME="$TARGET_HOME/.acfs"
    mkdir -p "$ACFS_HOME"

    CALLS="$BATS_TEST_TMPDIR/calls"
    : > "$CALLS"
    FAKE_CP="$BATS_TEST_TMPDIR/cp"
    printf '#!/bin/bash\necho "caller cp $*" >> "%s"\nexec %s "$@"\n' "$CALLS" "$(command -v cp)" > "$FAKE_CP"
    chmod 0755 "$FAKE_CP"
    acfs_early_system_binary_path() { if [[ "$1" == cp ]]; then printf '%s\n' "$FAKE_CP"; else command -v "$1"; fi; }
    acfs_early_sudo_binary_path() { return 1; }
    _acfs_internal_asset_is_rendered_data() { return 1; }
    _acfs_internal_asset_expected_sha256() { sha256sum "$SOURCE_ROOT/$1" | cut -d' ' -f1; }
    acfs_calculate_file_sha256() { sha256sum "$1" | cut -d' ' -f1; }
    log_error() { printf 'error: %s\n' "$*" >> "$CALLS"; }
    run_as_target() { printf 'as target: %s\n' "$*" >> "$CALLS"; "$@"; }
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

@test "install.sh's filesystem phase seeds /data/projects/AGENTS.md from the ~/.acfs/docs copy, never installing over it" {
    local template="$BATS_TEST_TMPDIR/home/.acfs/docs/AGENTS.workspace.md"
    run run_filesystem_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"asset=$template"*"seed=/data/projects/AGENTS.md <- $template"* ]]
    [[ "$output" != *"asset=/data/projects/AGENTS.md"* ]]
}

@test "install.sh's filesystem phase writes the ~/.acfs/docs template as the target user (acfs-69gx)" {
    run run_filesystem_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"asset=$BATS_TEST_TMPDIR/home/.acfs/docs/AGENTS.workspace.md --as-target"* ]]
}

@test "install_asset --as-target makes the directory and writes the file as the target user, with no cp of its own (acfs-69gx)" {
    load_install_asset
    local dest="$ACFS_HOME/docs/AGENTS.workspace.md"

    install_asset "acfs/AGENTS.md" "$dest" --as-target

    [[ "$(cat "$dest")" == "template" ]]
    grep -qxF "as target: $(command -v mkdir) -p $ACFS_HOME/docs" "$CALLS"
    grep -qxF "as target: tee $dest" "$CALLS"
    [[ -z "$(grep '^caller cp' "$CALLS" || true)" ]]
}

@test "install_asset without --as-target still copies as the caller" {
    load_install_asset
    local dest="$ACFS_HOME/docs/AGENTS.workspace.md"
    mkdir -p "$ACFS_HOME/docs"

    install_asset "acfs/AGENTS.md" "$dest"

    [[ "$(cat "$dest")" == "template" ]]
    grep -q '^caller cp ' "$CALLS"
    [[ -z "$(grep '^as target' "$CALLS" || true)" ]]
}

@test "install_asset --as-target fails when the target user's write fails" {
    load_install_asset
    run_as_target() { printf 'as target: %s\n' "$*" >> "$CALLS"; return 1; }
    mkdir -p "$ACFS_HOME/docs"

    run install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/AGENTS.workspace.md" --as-target

    [[ "$status" -ne 0 ]]
    grep -qF "error: install_asset: Failed to write verified source asset as ubuntu: acfs/AGENTS.md" "$CALLS"
}

@test "the seed writes an absent workspace AGENTS.md, as the target user" {
    load_seed_helper
    run acfs_seed_workspace_agents_md "$TEMPLATE" "$WORKSPACE/AGENTS.md"
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$WORKSPACE/AGENTS.md")" == "template" ]]
    [[ "$(cat "$RUN_AS_TARGET_LOG")" == "cp $TEMPLATE $WORKSPACE/AGENTS.md" ]]
}

@test "the seed keeps an existing workspace AGENTS.md" {
    load_seed_helper
    printf 'my rules\n' > "$WORKSPACE/AGENTS.md"
    run acfs_seed_workspace_agents_md "$TEMPLATE" "$WORKSPACE/AGENTS.md"
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$WORKSPACE/AGENTS.md")" == "my rules" ]]
    [[ ! -s "$RUN_AS_TARGET_LOG" ]]
}

@test "the seed never writes through a link at the workspace AGENTS.md" {
    load_seed_helper
    printf 'not yours\n' > "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$WORKSPACE/AGENTS.md"
    run acfs_seed_workspace_agents_md "$TEMPLATE" "$WORKSPACE/AGENTS.md"
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/elsewhere")" == "not yours" ]]
    [[ ! -s "$RUN_AS_TARGET_LOG" ]]
}

@test "the seed never writes through a dangling link at the workspace AGENTS.md" {
    load_seed_helper
    ln -s "$BATS_TEST_TMPDIR/missing" "$WORKSPACE/AGENTS.md"
    run acfs_seed_workspace_agents_md "$TEMPLATE" "$WORKSPACE/AGENTS.md"
    [[ "$status" -eq 0 ]]
    [[ ! -e "$BATS_TEST_TMPDIR/missing" ]]
    [[ ! -s "$RUN_AS_TARGET_LOG" ]]
}

# The generated path (a migrated filesystem category) runs base.filesystem's
# install as root. It can't run here: it writes /data/projects, and runuser
# needs root. So the generated installer is read instead.
@test "base.filesystem writes the template and the workspace seed as the target user, and root chowns neither (acfs-idnq)" {
    local body writes as_root chowns
    # The module's shell snippets, which carry helper functions of their own.
    body="$(sed -n "/<<'INSTALL_BASE_FILESYSTEM'\$/,/^INSTALL_BASE_FILESYSTEM\$/p" "$PROJECT_ROOT/scripts/generated/install_filesystem.sh")"
    [[ -n "$body" ]]
    [[ "$body" == *'as_target=("$runuser_bin" -u "${TARGET_USER:-ubuntu}" --)'* ]]

    # Each command that writes ~/.acfs/docs or /data/projects/AGENTS.md.
    writes="$(grep -E '^[^#]*\b(mkdir|curl|cp)\b.*(\.acfs/docs|/data/projects/AGENTS\.md)' <<< "$body" || true)"
    [[ "$(grep -c . <<< "$writes")" -eq 3 ]]
    as_root="$(grep -vE '^[[:space:]]*"\$\{as_target\[@\]\}" ' <<< "$writes" || true)"
    printf 'written as root: %s\n' "$as_root"
    [[ -z "$as_root" ]]

    chowns="$(grep -E '^[^#]*\bchown\b.*(\.acfs/docs|/data/projects/AGENTS\.md)' <<< "$body" || true)"
    printf 'root chowns: %s\n' "$chowns"
    [[ -z "$chowns" ]]
}
