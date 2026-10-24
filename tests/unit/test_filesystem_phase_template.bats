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

teardown() {
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
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
    acfs_asset_dir() { :; }
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
    local fn
    for fn in acfs_write_file_as_target install_asset; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done

    SOURCE_ROOT="$BATS_TEST_TMPDIR/source"
    mkdir -p "$SOURCE_ROOT/acfs"
    printf 'template\n' > "$SOURCE_ROOT/acfs/AGENTS.md"
    chmod 0644 "$SOURCE_ROOT/acfs/AGENTS.md"
    ACFS_TRUSTED_INTERNAL_SOURCE_ROOT="$SOURCE_ROOT"
    ACFS_BOOTSTRAP_DIR="$SOURCE_ROOT"
    TARGET_USER=ubuntu
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    ACFS_HOME="$TARGET_HOME/.acfs"
    # An allowed destination outside the target's home, as /usr/local/bin is.
    ACFS_BIN_DIR="$BATS_TEST_TMPDIR/system-bin"
    mkdir -p "$ACFS_HOME" "$ACFS_BIN_DIR"

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
    grep -qF " _ $dest 644 " "$CALLS"
    [[ -z "$(grep '^caller cp' "$CALLS" || true)" ]]
}

@test "install_asset writes as the target user by default under the target's home (acfs-wiip)" {
    load_install_asset
    local dest="$ACFS_HOME/scripts/lib/thing.sh"

    install_asset "acfs/AGENTS.md" "$dest"

    [[ "$(cat "$dest")" == "template" ]]
    grep -qF " _ $dest 644 " "$CALLS"
    [[ -z "$(grep '^caller cp' "$CALLS" || true)" ]]
}

@test "install_asset copies as the caller outside the target's home, and for a root target" {
    load_install_asset

    install_asset "acfs/AGENTS.md" "$ACFS_BIN_DIR/tool"
    [[ "$(cat "$ACFS_BIN_DIR/tool")" == "template" ]]
    grep -q '^caller cp ' "$CALLS"
    [[ -z "$(grep '^as target' "$CALLS" || true)" ]]

    : > "$CALLS"
    TARGET_USER=root
    mkdir -p "$ACFS_HOME/docs"
    install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/AGENTS.workspace.md"
    grep -q '^caller cp ' "$CALLS"
    [[ -z "$(grep '^as target' "$CALLS" || true)" ]]
}

@test "install_asset gives the user's copy the source's mode as cp would: 0775 lands at 0755, 0664 at 0644" {
    load_install_asset
    printf '#!/bin/bash\n' > "$SOURCE_ROOT/acfs/run.sh"
    chmod 0775 "$SOURCE_ROOT/acfs/run.sh"
    chmod 0664 "$SOURCE_ROOT/acfs/AGENTS.md"

    install_asset "acfs/run.sh" "$ACFS_HOME/bin/run.sh"
    install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/AGENTS.workspace.md"

    [[ "$(stat -c %a "$ACFS_HOME/bin/run.sh")" == "755" ]]
    [[ "$(stat -c %a "$ACFS_HOME/docs/AGENTS.workspace.md")" == "644" ]]
    # The user's write set those modes, not a cp of the caller's.
    [[ -z "$(grep '^caller cp' "$CALLS" || true)" ]]
}

@test "install_asset replaces a read-only file root left at the name, and a link there, without writing through it" {
    load_install_asset
    mkdir -p "$ACFS_HOME/docs"
    printf 'old\n' > "$ACFS_HOME/docs/left.md"
    chmod 0444 "$ACFS_HOME/docs/left.md"
    printf 'not yours\n' > "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ACFS_HOME/docs/linked.md"

    install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/left.md"
    install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/linked.md"

    [[ "$(cat "$ACFS_HOME/docs/left.md")" == "template" ]]
    [[ -f "$ACFS_HOME/docs/linked.md" && ! -L "$ACFS_HOME/docs/linked.md" ]]
    [[ "$(cat "$ACFS_HOME/docs/linked.md")" == "template" ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/elsewhere")" == "not yours" ]]
    [[ -z "$(find "$ACFS_HOME/docs" -name '.acfs-asset.*')" ]]
}

@test "install_asset's user write checks the verified sha before its rename, and renames nothing that differs" {
    load_install_asset
    mkdir -p "$ACFS_HOME/docs"
    printf 'old\n' > "$ACFS_HOME/docs/AGENTS.workspace.md"
    _acfs_internal_asset_expected_sha256() { printf '%064d\n' 0; }
    acfs_calculate_file_sha256() { printf '%064d\n' 0; }

    run install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/AGENTS.workspace.md"

    [[ "$status" -ne 0 ]]
    [[ "$(cat "$ACFS_HOME/docs/AGENTS.workspace.md")" == "old" ]]
    [[ -z "$(find "$ACFS_HOME/docs" -name '.acfs-asset.*')" ]]
    grep -qF "error: install_asset: Failed to write verified source asset as ubuntu: acfs/AGENTS.md" "$CALLS"
}

@test "install_asset under set -u with TARGET_HOME unset gives its own error, not an unbound variable" {
    load_install_asset
    # shellcheck disable=SC2016 # expanded by the child shell
    run env -u TARGET_HOME TARGET_USER=ubuntu bash -uc "$(declare -f install_asset)"'
        log_error() { printf "error: %s\n" "$*"; }
        install_asset acfs/AGENTS.md /x'

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"error: install_asset: ACFS_HOME/TARGET_HOME not set"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "install_asset --as-target fails when the target user's write fails" {
    load_install_asset
    run_as_target() { printf 'as target: %s\n' "$*" >> "$CALLS"; return 1; }
    mkdir -p "$ACFS_HOME/docs"

    run install_asset "acfs/AGENTS.md" "$ACFS_HOME/docs/AGENTS.workspace.md" --as-target

    [[ "$status" -ne 0 ]]
    grep -qF "error: install_asset: Failed to write verified source asset as ubuntu: acfs/AGENTS.md" "$CALLS"
}

# Adds install.sh's acfs_asset_dir to load_install_asset. A test can't make
# root's directories, so left_by_root makes them mode 0555, which stops this
# test's user as root's ownership stops the target, and the stat that
# acfs_asset_dir resolves reports uid 0 for the paths in ROOT_OWNED.
# acfs_chown_tree logs the handover and gives the tree back. $SUDO logs a
# root mkdir.
load_asset_dir() {
    load_install_asset
    eval "$(sed -n '/^acfs_asset_dir() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_asset_dir)" == "function" ]]

    ROOT_OWNED="$BATS_TEST_TMPDIR/root-owned"
    : > "$ROOT_OWNED"
    FAKE_STAT="$BATS_TEST_TMPDIR/stat"
    printf '#!/bin/bash\nif grep -qxF -- "${!#}" "%s"; then echo 0; else exec %s "$@"; fi\n' \
        "$ROOT_OWNED" "$(command -v stat)" > "$FAKE_STAT"
    chmod 0755 "$FAKE_STAT"
    acfs_early_system_binary_path() {
        case "$1" in
            cp) printf '%s\n' "$FAKE_CP" ;;
            stat) printf '%s\n' "$FAKE_STAT" ;;
            *) command -v "$1" ;;
        esac
    }
    acfs_chown_tree() {
        printf 'handover %s %s\n' "$1" "$2" >> "$CALLS"
        chmod -R u+w -- "$2"
        : > "$ROOT_OWNED"
    }
    root_mkdir() { printf 'root %s\n' "$*" >> "$CALLS"; "$@"; }
    SUDO=root_mkdir
}

# Makes each DIR as an earlier run's root mkdir left it.
left_by_root() {
    local dir
    for dir in "$@"; do
        mkdir -p "$dir"
        printf '%s\n' "$dir" >> "$ROOT_OWNED"
    done
    chmod 0555 -- "$@"
}

@test "acfs_asset_dir makes a directory under the target's home as the target user, and root makes none (acfs-svzn)" {
    load_asset_dir

    acfs_asset_dir "$ACFS_HOME/onboard/lessons" "$ACFS_HOME/scripts/generated"

    [[ -d "$ACFS_HOME/onboard/lessons" && -d "$ACFS_HOME/scripts/generated" ]]
    grep -qxF "as target: $(command -v mkdir) -p -- $ACFS_HOME/onboard/lessons" "$CALLS"
    grep -qxF "as target: $(command -v mkdir) -p -- $ACFS_HOME/scripts/generated" "$CALLS"
    [[ -z "$(grep -E '^(root|handover) ' "$CALLS" || true)" ]]
}

@test "a directory an earlier root run left is handed to the user first, so install_asset's user write gets in" {
    load_asset_dir
    left_by_root "$ACFS_HOME/onboard" "$ACFS_HOME/onboard/lessons"
    # As finalize's was since acfs-wiip: the user can't write there.
    run install_asset "acfs/AGENTS.md" "$ACFS_HOME/onboard/lessons/00_welcome.md"
    [[ "$status" -ne 0 ]]
    : > "$CALLS"

    acfs_asset_dir "$ACFS_HOME/onboard/lessons"
    install_asset "acfs/AGENTS.md" "$ACFS_HOME/onboard/lessons/00_welcome.md"

    [[ "$(head -n 1 "$CALLS")" == "handover ubuntu:ubuntu $ACFS_HOME/onboard" ]]
    [[ "$(cat "$ACFS_HOME/onboard/lessons/00_welcome.md")" == "template" ]]
}

@test "a link below the target's home is the user's: no handover, and the user's mkdir follows it" {
    load_asset_dir
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ACFS_HOME/onboard"
    printf '%s\n' "$ACFS_HOME/onboard" >> "$ROOT_OWNED"

    acfs_asset_dir "$ACFS_HOME/onboard/lessons"

    [[ -z "$(grep '^handover' "$CALLS" || true)" ]]
    grep -qxF "as target: $(command -v mkdir) -p -- $ACFS_HOME/onboard/lessons" "$CALLS"
}

@test "outside the target's home, or for a root target, root makes the directory as before" {
    load_asset_dir

    acfs_asset_dir "$ACFS_BIN_DIR/sub"
    TARGET_USER=root
    acfs_asset_dir "$ACFS_HOME/onboard/lessons"

    grep -qxF "root $(command -v mkdir) -p -- $ACFS_BIN_DIR/sub" "$CALLS"
    grep -qxF "root $(command -v mkdir) -p -- $ACFS_HOME/onboard/lessons" "$CALLS"
    [[ -z "$(grep -E '^(as target|handover) ' "$CALLS" || true)" ]]
}

@test "acfs_asset_dir fails when the user's mkdir fails, and makes nothing when the handover fails" {
    load_asset_dir
    run_as_target() { printf 'as target: %s\n' "$*" >> "$CALLS"; return 1; }
    run acfs_asset_dir "$ACFS_HOME/onboard/lessons"
    [[ "$status" -ne 0 ]]

    load_asset_dir
    left_by_root "$ACFS_HOME/onboard"
    acfs_chown_tree() { return 1; }
    run acfs_asset_dir "$ACFS_HOME/onboard/lessons"
    [[ "$status" -ne 0 ]]
    [[ -z "$(grep '^as target' "$CALLS" || true)" ]]
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

# Adds install.sh's install_checksums_yaml and acfs_asset_dir to
# load_install_asset, with a dedicated checksums ref (ACFS_CHECKSUMS_REF other
# than the install's ref), so it takes the branch that writes the fetched
# content itself. The fetch returns fixed text, and validation passes.
load_checksums_yaml() {
    load_install_asset
    local fn
    for fn in install_checksums_yaml acfs_asset_dir; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done
    ACFS_CHECKSUMS_REF=main
    ACFS_REF_INPUT=older-install-ref
    acfs_fetch_fresh_checksums_via_api() { printf 'installers:\n  tool:\n    url: "https://example.com/install.sh"\n'; }
    acfs_parse_checksums_content() { :; }
    acfs_validate_upstream_checksums() { :; }
}

@test "install_checksums_yaml from a dedicated ref is written by the user, and a link at the name is replaced, its target untouched (acfs-hmf1)" {
    load_checksums_yaml
    local victim="$BATS_TEST_TMPDIR/passwd"
    printf 'root:x:0:0\n' > "$victim"
    ln -s "$victim" "$ACFS_HOME/checksums.yaml"

    install_checksums_yaml "$ACFS_HOME/checksums.yaml"

    [[ "$(cat "$victim")" == "root:x:0:0" ]]
    [[ -f "$ACFS_HOME/checksums.yaml" && ! -L "$ACFS_HOME/checksums.yaml" ]]
    grep -qF 'url: "https://example.com/install.sh"' "$ACFS_HOME/checksums.yaml"
    [[ "$(stat -c %a "$ACFS_HOME/checksums.yaml")" == 644 ]]
    grep -q '^as target: ' "$CALLS"
}

@test "install_checksums_yaml hashes the fetched text with install.sh's own acfs_calculate_file_sha256 on /dev/stdin, and the user's sha-checked write takes it" {
    load_checksums_yaml
    # The real function, in place of load_install_asset's stub: it reads
    # /dev/stdin through env -i and the system sha256sum.
    eval "$(sed -n '/^acfs_calculate_file_sha256() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_calculate_file_sha256)" == "function" ]]

    install_checksums_yaml "$ACFS_HOME/checksums.yaml"

    [[ "$(cat "$ACFS_HOME/checksums.yaml")" == "$(acfs_fetch_fresh_checksums_via_api)" ]]
    grep -q '^as target: ' "$CALLS"
}

@test "install_checksums_yaml from a dedicated ref, outside the target's home, writes as before" {
    load_checksums_yaml

    install_checksums_yaml "$ACFS_BIN_DIR/checksums.yaml"

    grep -qF 'url: "https://example.com/install.sh"' "$ACFS_BIN_DIR/checksums.yaml"
    [[ -z "$(grep '^as target' "$CALLS" || true)" ]]
}
