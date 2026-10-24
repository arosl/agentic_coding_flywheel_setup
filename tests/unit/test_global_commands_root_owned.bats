#!/usr/bin/env bats
#
# acfs-evgn: no command in root's PATH is a link to a file the target user
# owns, since an admin's sudo would run that file as root. install.sh makes
# /usr/local/bin/acfs-update and /usr/local/bin/flywheel-update-agents-md
# root's own copies (acfs_install_global_command), staged and renamed over
# the name, so a link ACFS made there before is replaced, never written
# through. onboard leaves root's PATH: acfs_remove_global_home_link removes
# ACFS's old link into the home and leaves anything else. update.sh's side
# is in tests/unit/lib/test_update.bats ("global commands: ...").
#
# The function cases run install.sh's helpers with /usr/local/bin replaced
# by a temp dir, since a test can't write root's, and with the installer's
# root and tool helpers stubbed.

load 'test_helper'

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GB="$BATS_TEST_TMPDIR/usr-local-bin"
    HOMEDIR="$BATS_TEST_TMPDIR/home/u"
    mkdir -p "$GB" "$HOMEDIR/.acfs/bin" "$HOMEDIR/.acfs/onboard" "$BATS_TEST_TMPDIR/src/scripts"
    printf '#!/bin/sh\necho users-acfs-update\n' > "$HOMEDIR/.acfs/bin/acfs-update"
    printf '#!/bin/sh\necho onboard\n' > "$HOMEDIR/.acfs/onboard/onboard.sh"
    printf '#!/bin/sh\necho verified-acfs-update\n' > "$BATS_TEST_TMPDIR/src/scripts/acfs-update"
}

# load_helpers: install.sh's two helpers, with /usr/local/bin at $GB.
load_helpers() {
    local fn body
    for fn in acfs_install_global_command acfs_remove_global_home_link; do
        body="$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ -n "$body" ]] || fail "$fn not found in install.sh"
        eval "${body//\/usr\/local\/bin/$GB}"
    done
    TARGET_HOME="$HOMEDIR"
    ACFS_HOME="$HOMEDIR/.acfs"
    ACFS_BIN_DIR="$HOMEDIR/.local/bin"
    INSTALL_ASSET_FAILS=""
    _acfs_primary_bin_tool_path() { PATH=/usr/bin:/bin command -v "$1"; }
    _acfs_run_root_bin_command() { "$@"; }
    log_detail() { printf 'DETAIL %s\n' "$1"; }
    # install_asset's root copy of a verified source: here a plain cp.
    install_asset() {
        [[ -z "$INSTALL_ASSET_FAILS" ]] || return 1
        cp "$BATS_TEST_TMPDIR/src/$1" "$2"
    }
}

@test "acfs_install_global_command replaces ACFS's old link with root's copy, and the user's file stays as it was" {
    load_helpers
    ln -s "$HOMEDIR/.acfs/bin/acfs-update" "$GB/acfs-update"
    cp "$HOMEDIR/.acfs/bin/acfs-update" "$BATS_TEST_TMPDIR/before"

    acfs_install_global_command "scripts/acfs-update" "acfs-update"
    [[ -f "$GB/acfs-update" && ! -L "$GB/acfs-update" ]] || fail "acfs-update is not a regular file"
    cmp -s "$GB/acfs-update" "$BATS_TEST_TMPDIR/src/scripts/acfs-update" || fail "not the verified source"
    [[ "$(stat -c %a "$GB/acfs-update")" == 755 ]] || fail "not 0755"
    [[ ! -e "$GB/.acfs-update.acfs-new" ]] || fail "the staged copy was left"
    cmp -s "$HOMEDIR/.acfs/bin/acfs-update" "$BATS_TEST_TMPDIR/before" \
        || fail "the user's file was written through the link"
}

@test "acfs_install_global_command: a copy that fails leaves the name as it was" {
    load_helpers
    ln -s "$HOMEDIR/.acfs/bin/acfs-update" "$GB/acfs-update"
    INSTALL_ASSET_FAILS=1
    run acfs_install_global_command "scripts/acfs-update" "acfs-update"
    [[ "$status" -ne 0 ]]
    [[ -L "$GB/acfs-update" ]] || fail "the name changed"
}

@test "acfs_remove_global_home_link removes a link into the home, and leaves a regular file and a link elsewhere" {
    load_helpers
    ln -s "$HOMEDIR/.acfs/onboard/onboard.sh" "$GB/onboard"
    acfs_remove_global_home_link onboard
    [[ ! -e "$GB/onboard" && ! -L "$GB/onboard" ]] || fail "the link into the home stayed"
    [[ -f "$HOMEDIR/.acfs/onboard/onboard.sh" ]] || fail "the user's onboard.sh went"

    ln -s /usr/share/doc "$GB/onboard"
    run acfs_remove_global_home_link onboard
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Leaving $GB/onboard as it is: a link to /usr/share/doc"* ]]
    [[ -L "$GB/onboard" ]] || fail "a link elsewhere was removed"

    rm -f "$GB/onboard"
    printf '#!/bin/sh\n' > "$GB/onboard"
    acfs_remove_global_home_link onboard
    [[ -f "$GB/onboard" ]] || fail "a regular file was removed"

    rm -f "$GB/onboard"
    acfs_remove_global_home_link onboard
}

@test "acfs_remove_global_home_link leaves the link when ACFS_BIN_DIR is the global bin dir: it is the user's primary command (#211, acfs-g1p1)" {
    load_helpers
    ACFS_BIN_DIR="$GB"
    ln -s "$HOMEDIR/.acfs/onboard/onboard.sh" "$GB/onboard"
    acfs_remove_global_home_link onboard
    [[ -L "$GB/onboard" ]] || fail "the user's primary onboard link was removed"
}

@test "finalize installs root's copies of acfs-update and flywheel-update-agents-md and removes the onboard link" {
    local install_sh="$PROJECT_ROOT/install.sh"
    grep -qF 'acfs_install_global_command "scripts/acfs-update" "acfs-update"' "$install_sh"
    grep -qF 'acfs_install_global_command "scripts/generate-root-agents-md.sh" "flywheel-update-agents-md"' "$install_sh"
    grep -qF 'acfs_remove_global_home_link "onboard"' "$install_sh"
    run grep -n 'acfs_link_global_bin_command' "$install_sh"
    [[ "$status" -ne 0 ]] || fail "acfs_link_global_bin_command is still in install.sh: $output"
}

@test "no installer or update step links a file into /usr/local/bin" {
    local -a files=("$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/scripts/lib/update.sh"
        "$PROJECT_ROOT/acfs.manifest.yaml" "$PROJECT_ROOT/scripts/lib/install_helpers.sh")
    local f
    for f in "$PROJECT_ROOT"/scripts/generated/*.sh; do files+=("$f"); done
    # An ln that makes a link (-s, -sf, -sfn ...) and names /usr/local/bin,
    # or update.sh's global bin dir.
    run grep -n -E '(^|[^[:alnum:]_])ln(_bin"?)?[[:space:]]+(-[[:alpha:]]*s[[:alpha:]]*[[:space:]]).*(/usr/local/bin|global_bin_dir)' "${files[@]}"
    [[ "$status" -ne 0 ]] || fail "a link into the global bin dir: $output"
}
