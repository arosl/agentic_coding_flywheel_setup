#!/usr/bin/env bats
#
# install.sh runs as root and hands files to the target user in directories
# that user already owns (~/.acfs, ~, ~/.local/bin, /data/projects). A plain
# chown follows a symlink, so a user who swaps the file for one between the
# write and the chown gets root to chown the link's target, say /etc/shadow.
# acfs-573x: every such chown passes -h, which changes the link itself.
#
# setup_shell writes ~/.zshrc, ~/.profile and ~/.zprofile. As root, a write
# through a link the user planted there, or swapped in mid-run, would create
# or change any file, say /etc/profile.d/x.sh. acfs-k9a9: those writes run
# as the target user, so a link reaches only what the user could write.
#
# chmod follows a link too, so root's chmod of a path in the user's home had
# root change any file's mode: /etc/shadow to 0755, or /etc to 0700.
# acfs-1twj: those chmods run as the target user (acfs_chmod_as_target).
#
# chown -h doesn't help with a hard link, which is the file itself: where
# fs.protected_hardlinks is 0, a hard link the user put in the home would
# have a handover give that file away. acfs-wmgr: main checks the sysctl
# before the first handover (acfs_check_protected_hardlinks).
#
# A script in ~/.acfs is the user's: install_asset writes it as the user, who
# can change it before root runs it. acfs-uhbz: root runs only the verified
# source tree's copy (acfs_verified_source_path), never one in the home.
#
# acfs_chown_tree resolved a link at its path, so a link the user put at
# ~/.acfs/scripts had root chown -hR /root. acfs-y57c: below the home it
# refuses a link anywhere in the path, and chowns from inside the checked
# directory, so a link swapped in later can't send it elsewhere.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    # Stands in for a root-owned directory such as /etc: the user can't
    # write it, and nor can this test once it's locked.
    ROOT_DIR="$BATS_TEST_TMPDIR/etc"
    mkdir -p "$TARGET_HOME" "$ROOT_DIR"
}

teardown() {
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Each code line whose chown gives a path to an owner held in a variable
# ($TARGET_USER, $target_user, $(state_uid), ...), in install.sh, the scripts
# and libraries it runs as root, and the manifest's install snippets.
# acfs-4qz1 widened it from install.sh alone.
variable_owner_chowns() {
    grep -nHE '(^|[^[:alnum:]_-])(chown|"\$chown_bin")( +-[[:alpha:]]+)* +"\$' \
        "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT"/scripts/*.sh "$PROJECT_ROOT"/scripts/lib/*.sh \
        "$PROJECT_ROOT/acfs.manifest.yaml" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

@test "install.sh and the scripts it runs give a user its files only with chown -h" {
    local chowns missing
    chowns="$(variable_owner_chowns)"
    # The pattern still finds the call sites, so the check can't pass empty.
    (( $(wc -l <<<"$chowns") >= 40 ))
    # -R passes too: GNU and uutils chown -R lchown a link given on the command line.
    missing="$(grep -vE '(chown|"\$chown_bin")( +-[[:alpha:]]+)* +-[[:alpha:]]*[hR][[:alpha:]]* ' <<<"$chowns" || true)"
    printf '%s\n' "$missing"
    [[ -z "$missing" ]]
}

# Each code line of install.sh that changes a mode on a path in the user's
# home ($ACFS_HOME, $ACFS_BIN_DIR, $TARGET_HOME, ~/.ssh with it): a chmod by
# any name, or a find that runs chmod.
home_chmods() {
    grep -nE '(acfs_(find_)?chmod_as_target|(^|[^[:alnum:]_-])chmod|"\$chmod_bin")( +-[[:alpha:]]+)* +[^[:space:]]+ +"\$\{?(ACFS_HOME|ACFS_BIN_DIR|TARGET_HOME)|find +"\$\{?(ACFS_HOME|ACFS_BIN_DIR|TARGET_HOME)[^|]*-exec +chmod' \
        "$PROJECT_ROOT/install.sh" | grep -vE '^[0-9]+:[[:space:]]*#'
}

@test "install.sh changes modes in the user's home only as the target user (acfs-1twj)" {
    local chmods as_root
    chmods="$(home_chmods)"
    # The pattern still finds the call sites, so the check can't pass empty.
    (( $(wc -l <<<"$chmods") >= 13 ))
    as_root="$(grep -vE 'acfs_(find_)?chmod_as_target|run_as_target' <<<"$chmods" || true)"
    printf 'as root: %s\n' "$as_root"
    [[ -z "$as_root" ]]
}

# Each code line of install.sh that makes a directory on a path in the
# user's home ($ACFS_HOME, $ACFS_BIN_DIR, $TARGET_HOME).
home_mkdirs() {
    grep -nE '((^|[^[:alnum:]_-])mkdir|"\$mkdir_bin"|acfs_asset_dir)( +-[[:alpha:]-]+)* +"\$\{?(ACFS_HOME|ACFS_BIN_DIR|TARGET_HOME)' \
        "$PROJECT_ROOT/install.sh" | grep -vE '^[0-9]+:[[:space:]]*#'
}

@test "install.sh makes directories in the user's home only as the target user (acfs-svzn)" {
    local mkdirs as_root
    mkdirs="$(home_mkdirs)"
    # The pattern still finds the call sites, so the check can't pass empty.
    (( $(wc -l <<<"$mkdirs") >= 10 ))
    # install_asset writes there as the user (acfs-wiip), and the user can't
    # create a file in a directory root made. Two stay root's: a primary bin
    # directory root owns (_acfs_run_root_bin_command), and normalize_user's
    # ~/.ssh, which root fills and hands over before the user writes there.
    as_root="$(grep -vE 'acfs_asset_dir|run_as_target|_acfs_run_root_bin_command|"\$TARGET_HOME/\.ssh"' <<<"$mkdirs" || true)"
    printf 'as root: %s\n' "$as_root"
    [[ -z "$as_root" ]]
}

# Each code line of install.sh that runs a script in the user's home
# ($ACFS_HOME, $TARGET_HOME), named literally or through a variable install.sh
# sets to one: through bash, sh, source, . or exec, or as the command itself,
# on its own line or after env or $SUDO.
# A pass is not proof that root runs nothing of the user's. The pattern can't
# see a file without .sh or .py (~/.acfs/bin/acfs, $ACFS_BIN_DIR/*, the user's
# ~/.local/bin, ~/.bun/bin or ~/.cargo/bin), "${ACFS_HOME:-…}/x.sh" or
# "$ACFS_HOME"/x.sh, a variable with an uppercase name or one set from another
# variable or a command substitution, or another runner (timeout, nohup,
# xargs, or a path after try_step's description). The reviews of 6b7be77f
# found none of those in install.sh: each such run goes through run_as_target.
home_script_runs() {
    local install_sh="$PROJECT_ROOT/install.sh" names="" ref=""
    names="$(grep -oE '[a-z_]+="\$\{?(ACFS_HOME|TARGET_HOME)\}?/[^"]*\.(sh|py)"' "$install_sh" \
        | cut -d= -f1 | sort -u | paste -sd '|' -)"
    ref='"\$\{?((ACFS_HOME|TARGET_HOME)\}?/[^"]*\.(sh|py)'"${names:+|($names)\\\}?}"')"'
    grep -nE "(^|[[:space:];&|(])(bash|sh|source|exec|\\.)( +-[[:alpha:]-]+)* +${ref}|^[[:space:]]*${ref}( |\$)|(env|\\\$SUDO)( +\"[A-Z_]+=[^\"]*\")* +${ref}" \
        "$install_sh" | grep -vE '^[0-9]+:[[:space:]]*#'
}

@test "install.sh runs a script in the user's home only as the target user (acfs-uhbz)" {
    local runs as_root
    runs="$(home_script_runs)"
    # The pattern still finds the call sites, so the check can't pass empty:
    # nhm's hooks and timer, and Agent Mail's hook, which the user runs.
    (( $(wc -l <<<"$runs") >= 15 ))
    as_root="$(grep -v 'run_as_target' <<<"$runs" || true)"
    printf 'as root: %s\n' "$as_root"
    [[ -z "$as_root" ]]
}

@test "finalize's root runs of services-setup.sh and state_layer.sh take the verified tree's copy (acfs-uhbz)" {
    local body
    body="$(sed -n '/^finalize() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    # shellcheck disable=SC2016  # The literal lines finalize holds.
    grep -qF 'state_layer_script="$(acfs_verified_source_path "scripts/lib/state_layer.sh")" || return 1' <<<"$body"
    # shellcheck disable=SC2016
    grep -qF 'bash "$state_layer_script" setup-guest' <<<"$body"
    # shellcheck disable=SC2016
    grep -qF 'if services_setup_script="$(acfs_verified_source_path "scripts/services-setup.sh")"; then' <<<"$body"
    # shellcheck disable=SC2016
    grep -qF 'bash "$services_setup_script" --install-claude-guard --yes' <<<"$body"
    # Each variable is set only there.
    [[ "$(grep -cE '(state_layer|services_setup)_script=' <<<"$body")" -eq 4 ]]
}

# Loads install.sh's acfs_verified_source_path over a verified tree the test
# makes, whose ledger holds each file's sha256 as it was when made.
load_verified_source() {
    eval "$(sed -n '/^acfs_verified_source_path() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_verified_source_path)" == "function" ]]
    SOURCE_ROOT="$BATS_TEST_TMPDIR/source"
    mkdir -p "$SOURCE_ROOT/scripts/lib"
    printf '#!/bin/bash\necho verified\n' > "$SOURCE_ROOT/scripts/services-setup.sh"
    printf '#!/bin/bash\necho verified\n' > "$SOURCE_ROOT/scripts/lib/state_layer.sh"
    ACFS_TRUSTED_INTERNAL_SOURCE_ROOT="$SOURCE_ROOT"
    ACFS_BOOTSTRAP_DIR="$SOURCE_ROOT"
    declare -gA LEDGER=()
    local rel
    for rel in scripts/services-setup.sh scripts/lib/state_layer.sh; do
        LEDGER[$rel]="$(sha256sum "$SOURCE_ROOT/$rel" | cut -d' ' -f1)"
    done
    _acfs_internal_asset_expected_sha256() { [[ -n "${LEDGER[$1]:-}" ]] && printf '%s\n' "${LEDGER[$1]}"; }
    acfs_calculate_file_sha256() { sha256sum "$1" | cut -d' ' -f1; }
    log_error() { printf 'error: %s\n' "$*"; }
}

@test "acfs_verified_source_path prints the verified tree's copy when it is the ledger's" {
    load_verified_source
    run acfs_verified_source_path "scripts/services-setup.sh"
    [[ "$status" -eq 0 && "$output" == "$SOURCE_ROOT/scripts/services-setup.sh" ]]
    run acfs_verified_source_path "scripts/lib/state_layer.sh"
    [[ "$status" -eq 0 && "$output" == "$SOURCE_ROOT/scripts/lib/state_layer.sh" ]]
}

@test "acfs_verified_source_path refuses a changed file, a link, a file outside the ledger, a bad path and an unverified tree" {
    load_verified_source
    printf 'echo changed\n' >> "$SOURCE_ROOT/scripts/services-setup.sh"
    run acfs_verified_source_path "scripts/services-setup.sh"
    [[ "$status" -ne 0 && "$output" == *"Not the ledger's copy"* ]]

    rm -f "$SOURCE_ROOT/scripts/lib/state_layer.sh"
    ln -s "$TARGET_HOME/state_layer.sh" "$SOURCE_ROOT/scripts/lib/state_layer.sh"
    run acfs_verified_source_path "scripts/lib/state_layer.sh"
    [[ "$status" -ne 0 && "$output" == *"Missing or unsafe"* ]]

    printf 'x\n' > "$SOURCE_ROOT/scripts/other.sh"
    run acfs_verified_source_path "scripts/other.sh"
    [[ "$status" -ne 0 && "$output" == *"Not the ledger's copy"* ]]

    run acfs_verified_source_path "../scripts/services-setup.sh"
    [[ "$status" -ne 0 && "$output" == *"Invalid path"* ]]
    run acfs_verified_source_path "$SOURCE_ROOT/scripts/services-setup.sh"
    [[ "$status" -ne 0 && "$output" == *"Invalid path"* ]]

    rm -f "$SOURCE_ROOT/scripts/lib/state_layer.sh"
    load_verified_source
    ACFS_BOOTSTRAP_DIR="$TARGET_HOME"
    run acfs_verified_source_path "scripts/services-setup.sh"
    [[ "$status" -ne 0 && "$output" == *"not the verified ACFS tree"* ]]
}

# Loads install.sh's acfs_chown_tree. A test can't chown to another user, so
# $SUDO records where root's chown ran (its physical working directory) and
# with what, and changes nothing. VICTIM stands in for /root, OTHER_HOME for
# another user's home.
load_chown_tree() {
    eval "$(sed -n '/^acfs_chown_tree() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_chown_tree)" == "function" ]]
    command_exists() { command -v "$1" >/dev/null 2>&1; }
    log_error() { printf 'error: %s\n' "$*"; }
    log_detail() { :; }
    CHOWNS="$BATS_TEST_TMPDIR/chowns"
    : > "$CHOWNS"
    # The kernel's working directory: bash's pwd -P resolves $PWD's string
    # again, which a swap after the cd changes.
    record_chown() { printf 'in %s: %s\n' "$(readlink /proc/self/cwd)" "$*" >> "$CHOWNS"; }
    SUDO=record_chown
    ACFS_HOME="$TARGET_HOME/.acfs"
    VICTIM="$BATS_TEST_TMPDIR/root-home"
    OTHER_HOME="$BATS_TEST_TMPDIR/other-home"
    mkdir -p "$ACFS_HOME" "$VICTIM" "$OTHER_HOME"
}

@test "acfs_chown_tree hands over a directory or a file below the home from inside its directory (acfs-y57c)" {
    load_chown_tree
    mkdir -p "$ACFS_HOME/scripts/lib"
    : > "$ACFS_HOME/VERSION"

    acfs_chown_tree "tester:tester" "$ACFS_HOME/scripts"
    acfs_chown_tree "tester:tester" "$ACFS_HOME/VERSION"

    [[ "$(sed -n 1p "$CHOWNS")" == "in $(cd -P "$ACFS_HOME/scripts" && pwd -P): chown -hR tester:tester ." ]]
    [[ "$(sed -n 2p "$CHOWNS")" == "in $(cd -P "$ACFS_HOME" && pwd -P): chown -hR tester:tester ./VERSION" ]]
}

@test "a link at the path or above it below the home, to /root or another home, gets no handover (acfs-y57c)" {
    load_chown_tree
    ln -s "$VICTIM" "$ACFS_HOME/scripts"
    run acfs_chown_tree "tester:tester" "$ACFS_HOME/scripts"
    [[ "$status" -ne 0 && "$output" == *"through a link below $TARGET_HOME: $ACFS_HOME/scripts"* ]]

    rm -f "$ACFS_HOME/scripts"
    ln -s /root "$ACFS_HOME/scripts"
    run acfs_chown_tree "tester:tester" "$ACFS_HOME/scripts"
    [[ "$status" -ne 0 ]]

    ln -s "$OTHER_HOME" "$ACFS_HOME/onboard"
    mkdir -p "$OTHER_HOME/lessons"
    run acfs_chown_tree "tester:tester" "$ACFS_HOME/onboard/lessons"
    [[ "$status" -ne 0 && "$output" == *"through a link below $TARGET_HOME: $ACFS_HOME/onboard"* ]]

    run acfs_chown_tree "tester:tester" "$TARGET_HOME/../root-home"
    [[ "$status" -ne 0 && "$output" == *"with '..'"* ]]

    [[ ! -s "$CHOWNS" ]]
}

@test "a link swapped in after the checks and before the chown gets no handover (acfs-y57c)" {
    load_chown_tree
    mkdir -p "$ACFS_HOME/scripts"
    # The swap lands between the walk's checks and root's cd into the
    # directory: the user renames the directory and puts a link in its place.
    cd() {
        if [[ "${3:-}" == "$ACFS_HOME/scripts" && ! -e "$BATS_TEST_TMPDIR/swapped" ]]; then
            mv "$ACFS_HOME/scripts" "$ACFS_HOME/scripts.moved"
            ln -s "$VICTIM" "$ACFS_HOME/scripts"
            : > "$BATS_TEST_TMPDIR/swapped"
        fi
        builtin cd "$@"
    }

    run acfs_chown_tree "tester:tester" "$ACFS_HOME/scripts"

    [[ -e "$BATS_TEST_TMPDIR/swapped" ]]
    [[ "$status" -ne 0 ]]
    [[ ! -s "$CHOWNS" ]]
}

@test "a link swapped in once root is inside the directory leaves the chown where it was checked (acfs-y57c)" {
    load_chown_tree
    mkdir -p "$ACFS_HOME/scripts"
    record_chown() {
        mv "$ACFS_HOME/scripts" "$ACFS_HOME/scripts.moved"
        ln -s "$VICTIM" "$ACFS_HOME/scripts"
        printf 'in %s: %s\n' "$(readlink /proc/self/cwd)" "$*" >> "$CHOWNS"
    }

    acfs_chown_tree "tester:tester" "$ACFS_HOME/scripts"

    [[ -L "$ACFS_HOME/scripts" ]]
    [[ "$(cat "$CHOWNS")" == "in $(cd -P "$ACFS_HOME/scripts.moved" && pwd -P): chown -hR tester:tester ." ]]
}

@test "the home itself, and a link outside the home, keep acfs_chown_tree's old handling (acfs-y57c)" {
    load_chown_tree
    mkdir -p "$BATS_TEST_TMPDIR/real-data"
    ln -s "$BATS_TEST_TMPDIR/real-data" "$BATS_TEST_TMPDIR/data"

    acfs_chown_tree "tester:tester" "$TARGET_HOME"
    acfs_chown_tree "tester:tester" "$BATS_TEST_TMPDIR/data"

    grep -qE "^in .*: chown -hR tester:tester $TARGET_HOME\$" "$CHOWNS"
    grep -qE "^in .*: chown -hR tester:tester $(cd -P "$BATS_TEST_TMPDIR/real-data" && pwd -P)\$" "$CHOWNS"
}

@test "acfs_asset_dir's handover of a directory swapped for a link after its check is refused (acfs-y57c)" {
    load_chown_tree
    eval "$(sed -n '/^acfs_asset_dir() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_asset_dir)" == "function" ]]
    TARGET_USER=tester
    mkdir -p "$ACFS_HOME/onboard"
    # acfs_asset_dir checks for a link, then asks stat who owns the
    # directory: the fake stat swaps it for a link first, and says root.
    FAKE_STAT="$BATS_TEST_TMPDIR/stat"
    printf '#!/bin/bash\n[[ "${!#}" == "%s" ]] || { echo 1000; exit 0; }\nif [[ ! -e "%s" ]]; then mv "%s" "%s.moved"; ln -s "%s" "%s"; : > "%s"; fi\necho 0\n' \
        "$ACFS_HOME/onboard" "$BATS_TEST_TMPDIR/swapped" "$ACFS_HOME/onboard" "$ACFS_HOME/onboard" \
        "$VICTIM" "$ACFS_HOME/onboard" "$BATS_TEST_TMPDIR/swapped" > "$FAKE_STAT"
    chmod 0755 "$FAKE_STAT"
    acfs_early_system_binary_path() { if [[ "$1" == stat ]]; then printf '%s\n' "$FAKE_STAT"; else command -v "$1"; fi; }
    run_as_target() { printf 'as target: %s\n' "$*" >> "$CHOWNS"; }

    run acfs_asset_dir "$ACFS_HOME/onboard/lessons"

    [[ -e "$BATS_TEST_TMPDIR/swapped" ]]
    [[ "$status" -ne 0 && "$output" == *"through a link below $TARGET_HOME: $ACFS_HOME/onboard"* ]]
    [[ ! -s "$CHOWNS" ]]
}

# Loads install.sh's acfs_chmod_as_target, acfs_find_chmod_as_target and
# acfs_dotfile_own_for_target. The system chmod is a fake that logs who ran
# it, root or the target user (run_as_target sets the runner), then runs the
# real one; $SUDO logs each chown.
load_chmod_helpers() {
    local fn
    for fn in acfs_dotfile_own_for_target acfs_chmod_as_target acfs_find_chmod_as_target; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done
    CALLS="$BATS_TEST_TMPDIR/calls"
    : > "$CALLS"
    FAKE_CHMOD="$BATS_TEST_TMPDIR/chmod"
    printf '#!/bin/bash\necho "${ACFS_TEST_RUNNER:-root} chmod $*" >> "%s"\nexec %s "$@"\n' \
        "$CALLS" "$(command -v chmod)" > "$FAKE_CHMOD"
    command chmod 0755 "$FAKE_CHMOD"
    acfs_early_system_binary_path() { if [[ "$1" == chmod ]]; then printf '%s\n' "$FAKE_CHMOD"; else command -v "$1"; fi; }
    fake_sudo() { printf 'sudo %s\n' "$*" >> "$CALLS"; }
    log_error() { printf 'error: %s\n' "$*" >> "$CALLS"; }
    run_as_target() { ACFS_TEST_RUNNER=target "$@"; }
    SUDO=fake_sudo
    TARGET_USER=tester
}

@test "acfs_chmod_as_target hands a lone file to the user first, then the user changes its mode" {
    load_chmod_helpers
    printf 'x\n' > "$TARGET_HOME/tool"
    command chmod 0644 "$TARGET_HOME/tool"

    acfs_chmod_as_target 755 "$TARGET_HOME/tool"

    [[ "$(cat "$CALLS")" == "sudo chown -h tester:tester $TARGET_HOME/tool"$'\n'"target chmod 755 $TARGET_HOME/tool" ]]
    [[ "$(stat -c %a "$TARGET_HOME/tool")" == 755 ]]
}

@test "acfs_chmod_as_target never chowns a link or a file with a second hard link, and root runs no chmod" {
    load_chmod_helpers
    printf 'root file\n' > "$ROOT_DIR/shadow"
    ln -s "$ROOT_DIR/shadow" "$TARGET_HOME/tool"
    printf 'x\n' > "$TARGET_HOME/linked"
    ln "$TARGET_HOME/linked" "$BATS_TEST_TMPDIR/second-name"

    acfs_chmod_as_target 755 "$TARGET_HOME/tool" "$TARGET_HOME/linked"

    [[ -z "$(grep '^sudo ' "$CALLS" || true)" ]]
    [[ -z "$(grep '^root chmod' "$CALLS" || true)" ]]
    grep -qxF "target chmod 755 $TARGET_HOME/tool $TARGET_HOME/linked" "$CALLS"
}

@test "acfs_chmod_as_target fails when the user's chmod fails" {
    load_chmod_helpers
    run_as_target() { return 1; }
    printf 'x\n' > "$TARGET_HOME/tool"

    run acfs_chmod_as_target 755 "$TARGET_HOME/tool"
    [[ "$status" -ne 0 ]]
}

@test "acfs_find_chmod_as_target passes only the regular files root's find lists" {
    load_chmod_helpers
    local dir="$TARGET_HOME/generated"
    mkdir -p "$dir/sub.sh" "$dir/deeper"
    printf 'x\n' > "$dir/a.sh"
    printf 'x\n' > "$dir/c.txt"
    printf 'x\n' > "$dir/deeper/d.sh"
    printf 'root file\n' > "$ROOT_DIR/shadow"
    ln -s "$ROOT_DIR/shadow" "$dir/b.sh"

    acfs_find_chmod_as_target 755 "$dir" -maxdepth 1 -name '*.sh'

    [[ "$(grep 'chmod' "$CALLS")" == "target chmod 755 $dir/a.sh" ]]
}

@test "acfs_find_chmod_as_target runs no chmod when nothing matches, and fails on a missing directory" {
    load_chmod_helpers
    local dir="$TARGET_HOME/generated"
    mkdir -p "$dir"
    printf 'x\n' > "$dir/c.txt"

    acfs_find_chmod_as_target 755 "$dir" -maxdepth 1 -name '*.sh'
    [[ ! -s "$CALLS" ]]

    run acfs_find_chmod_as_target 755 "$TARGET_HOME/missing" -maxdepth 1 -name '*.sh'
    [[ "$status" -ne 0 ]]
    grep -qxF "error: Unable to list $TARGET_HOME/missing for a target-user chmod" "$CALLS"
    [[ -z "$(grep 'chmod ' "$CALLS" | grep -v '^error' || true)" ]]
}

@test "setup_shell itself never writes the user's dotfiles; run_as_target does" {
    local body
    body="$(sed -n '/^setup_shell() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ -n "$body" ]]
    # No redirect into a dotfile from install.sh's own shell. (A negated
    # `! grep` can't fail a bats test: set -e ignores it.)
    local redirects
    redirects="$(grep -nE '>>? *"\$user_(zshrc|profile|zprofile)"' <<<"$body" || true)"
    printf '%s\n' "$redirects"
    [[ -z "$redirects" ]]
    # Every sed -i, mv or cp of a dotfile runs as the target user.
    local edits unwrapped
    edits="$(grep -nE '(sed [^|]*-i|mv -T| cp ).*"\$user_(zshrc|profile|zprofile)"' <<<"$body")"
    [[ -n "$edits" ]]
    unwrapped="$(grep -v 'run_as_target' <<<"$edits" || true)"
    printf '%s\n' "$unwrapped"
    [[ -z "$unwrapped" ]]
}

# Makes the home read-only to this shell, as root's view would be if root
# never wrote there: only a command through run_as_target may write it.
lock_home() {
    find "$TARGET_HOME" \( -type d -o -type f \) -exec chmod a-w {} +
}
unlock_home() {
    find "$TARGET_HOME" \( -type d -o -type f \) -exec chmod u+w {} +
}

# Runs install.sh's setup_shell with stubs for ACFS_DISTRO_FAMILY (ubuntu
# unless set), the home locked and ROOT_DIR unwritable. Prints its warnings,
# its errors and its rc.
run_setup_shell() {
    local fn
    for fn in profile_path_has_fragment profile_path_sed_literal \
        acfs_zshrc_is_managed_loader acfs_dotfile_write_as_target \
        acfs_file_matches_as_target acfs_backup_file_as_target \
        acfs_dotfile_own_for_target acfs_dotfile_warn_unwritten setup_shell; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done

    set_phase() { :; }
    log_step() { :; }
    log_detail() { :; }
    log_info() { :; }
    log_error() { printf 'ERROR: %s\n' "$*"; }
    log_success() { :; }
    log_warn() { printf 'WARN: %s\n' "$*"; }
    acfs_use_generated_category() { return 1; }
    binary_installed() { return 0; }
    try_step() { shift; "$@"; }
    try_step_optional() { shift; "$@"; }
    install_asset() { return 0; }
    acfs_chown_tree() { :; }
    # The target user's rights: the home is writable while the command runs.
    run_as_target() {
        local rc=0
        unlock_home
        "$@" || rc=$?
        lock_home
        return "$rc"
    }
    acfs_run_verified_upstream_script_as_target() { :; }
    acfs_early_system_binary_path() { command -v "$1"; }
    set_default_shell() { return 0; }
    chown() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/chown.log"; }

    SUDO=""
    TARGET_USER="tester"
    ACFS_HOME="$TARGET_HOME/.acfs"
    ACFS_BOOTSTRAP_DIR="$BATS_TEST_TMPDIR/bootstrap"
    ACFS_DISTRO_FAMILY="${ACFS_DISTRO_FAMILY:-ubuntu}"
    ACFS_CI=true
    # Ubuntu's oh-my-zsh, theme and plugins count as installed.
    mkdir -p "$TARGET_HOME/.oh-my-zsh/custom/themes/powerlevel10k" \
        "$TARGET_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" \
        "$TARGET_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
    chmod -R a-w "$ROOT_DIR"
    lock_home

    local rc=0
    setup_shell || rc=$?
    unlock_home
    printf 'rc=%s\n' "$rc"
}

@test "a fresh home gets ~/.zshrc, ~/.profile and ~/.zprofile, all written as the user" {
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" != *"WARN:"* && "$output" != *"ERROR:"* ]]
    [[ "$(cat "$TARGET_HOME/.zshrc")" == '# ACFS loader'$'\n''source "$HOME/.acfs/zsh/acfs.zshrc"' ]]
    grep -Fq 'export PATH="$HOME/.local/bin:' "$TARGET_HOME/.profile"
    grep -Fq 'export PATH="$HOME/.local/bin:' "$TARGET_HOME/.zprofile"
}

@test "a dangling ~/.profile or ~/.zprofile link into a root directory gets no file created" {
    mkdir -p "$ROOT_DIR/profile.d"
    ln -s "$ROOT_DIR/profile.d/x.sh" "$TARGET_HOME/.profile"
    ln -s "$ROOT_DIR/zprofile" "$TARGET_HOME/.zprofile"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ ! -e "$ROOT_DIR/profile.d/x.sh" ]]
    [[ ! -e "$ROOT_DIR/zprofile" ]]
    [[ -L "$TARGET_HOME/.profile" && -L "$TARGET_HOME/.zprofile" ]]
    [[ "$output" == *"WARN: Couldn't write $TARGET_HOME/.profile as tester. Add this line to it:"* ]]
    [[ "$output" == *"WARN: Couldn't write $TARGET_HOME/.zprofile as tester. Add this line to it:"* ]]
    [[ "$output" == *'WARN: export PATH="$HOME/.local/bin:'* ]]
}

@test "a ~/.profile or ~/.zprofile link to a root file leaves that file as it was" {
    printf 'root content\n' > "$ROOT_DIR/bash.bashrc"
    ln -s "$ROOT_DIR/bash.bashrc" "$TARGET_HOME/.profile"
    ln -s "$ROOT_DIR/bash.bashrc" "$TARGET_HOME/.zprofile"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$(cat "$ROOT_DIR/bash.bashrc")" == "root content" ]]
    [[ "$output" == *"WARN: Couldn't write $TARGET_HOME/.profile as tester"* ]]
}

@test "on Ubuntu, a ~/.zshrc link is moved aside, and a regular loader takes its place" {
    printf 'root content\n' > "$ROOT_DIR/zshrc"
    ln -s "$ROOT_DIR/zshrc" "$TARGET_HOME/.zshrc"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$(cat "$ROOT_DIR/zshrc")" == "root content" ]]
    [[ -f "$TARGET_HOME/.zshrc" && ! -L "$TARGET_HOME/.zshrc" ]]
    [[ "$(cat "$TARGET_HOME/.zshrc")" == '# ACFS loader'$'\n''source "$HOME/.acfs/zsh/acfs.zshrc"' ]]
    local backups=("$TARGET_HOME"/.zshrc.pre-acfs.*)
    [[ ${#backups[@]} -eq 1 && -L "${backups[0]}" ]]
    [[ "$(readlink "${backups[0]}")" == "$ROOT_DIR/zshrc" ]]
    [[ "$output" == *"WARN: $TARGET_HOME/.zshrc is a symlink; moving the link aside"* ]]
}

@test "on Ubuntu, a dangling ~/.zshrc link gets no file created through it" {
    ln -s "$ROOT_DIR/zshrc" "$TARGET_HOME/.zshrc"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ ! -e "$ROOT_DIR/zshrc" ]]
    [[ -f "$TARGET_HOME/.zshrc" && ! -L "$TARGET_HOME/.zshrc" ]]
}

@test "on Ubuntu, an existing ~/.zshrc is backed up as a copy the user made" {
    printf '# my zshrc\n' > "$TARGET_HOME/.zshrc"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    local backups=("$TARGET_HOME"/.zshrc.pre-acfs.*)
    [[ ${#backups[@]} -eq 1 && -f "${backups[0]}" && ! -L "${backups[0]}" ]]
    [[ "$(cat "${backups[0]}")" == "# my zshrc" ]]
    [[ "$(head -n 1 "$TARGET_HOME/.zshrc")" == "# ACFS loader" ]]
}

@test "on Arch, a ~/.zshrc link to a root file is left alone, with the loader line to add" {
    printf 'root content\n' > "$ROOT_DIR/zshrc"
    ln -s "$ROOT_DIR/zshrc" "$TARGET_HOME/.zshrc"
    ACFS_DISTRO_FAMILY=arch run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$(cat "$ROOT_DIR/zshrc")" == "root content" ]]
    [[ -L "$TARGET_HOME/.zshrc" ]]
    [[ "$output" == *"WARN: Couldn't write $TARGET_HOME/.zshrc as tester. Add this line to it:"* ]]
    [[ "$output" == *'WARN: [[ -f "$HOME/.acfs/zsh/acfs.zshrc" ]] && source "$HOME/.acfs/zsh/acfs.zshrc"'* ]]
}

@test "a dotfiles link the user owns is written through, and stays a link" {
    mkdir -p "$TARGET_HOME/dotfiles"
    printf '# my profile\n' > "$TARGET_HOME/dotfiles/profile"
    printf '# my zshrc\n' > "$TARGET_HOME/dotfiles/zshrc"
    ln -s "$TARGET_HOME/dotfiles/profile" "$TARGET_HOME/.profile"
    ln -s "$TARGET_HOME/dotfiles/zshrc" "$TARGET_HOME/.zshrc"
    ACFS_DISTRO_FAMILY=arch run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" != *"WARN:"* ]]
    [[ -L "$TARGET_HOME/.profile" && -L "$TARGET_HOME/.zshrc" ]]
    grep -Fq 'export PATH="$HOME/.local/bin:' "$TARGET_HOME/dotfiles/profile"
    grep -Fq '.acfs/zsh/acfs.zshrc' "$TARGET_HOME/dotfiles/zshrc"
}

@test "a dotfiles link holding the legacy PATH line stays a link, and its file gets the new line" {
    mkdir -p "$TARGET_HOME/dotfiles"
    # shellcheck disable=SC2016  # The literal line ~/.profile holds.
    printf '%s\n' 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"' \
        > "$TARGET_HOME/dotfiles/profile"
    ln -s "$TARGET_HOME/dotfiles/profile" "$TARGET_HOME/.profile"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ -L "$TARGET_HOME/.profile" ]]
    grep -Fq '$HOME/.atuin/bin:$PATH"' "$TARGET_HOME/dotfiles/profile"
}

@test "a ~/.profile with a second hard link is not chowned; a lone one is, with -h" {
    printf '# my profile\n' > "$TARGET_HOME/.profile"
    printf '# my zprofile\n' > "$TARGET_HOME/.zprofile"
    mkdir -p "$BATS_TEST_TMPDIR/other"
    ln "$TARGET_HOME/.profile" "$BATS_TEST_TMPDIR/other/profile"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ -z "$(grep -F "$TARGET_HOME/.profile" "$BATS_TEST_TMPDIR/chown.log" || true)" ]]
    [[ "$(grep -F "$TARGET_HOME/.zprofile" "$BATS_TEST_TMPDIR/chown.log")" == "-h tester:tester $TARGET_HOME/.zprofile" ]]
}

@test "a differing ~/.p10k.zsh is backed up by the user; a link planted at the backup name is replaced, its target untouched (acfs-qz1k)" {
    mkdir -p "$BATS_TEST_TMPDIR/bootstrap/acfs/zsh"
    printf 'acfs p10k\n' > "$BATS_TEST_TMPDIR/bootstrap/acfs/zsh/p10k.zsh"
    printf 'my p10k\n' > "$TARGET_HOME/.p10k.zsh"
    printf 'root file\n' > "$ROOT_DIR/victim"
    ln -s "$ROOT_DIR/victim" "$TARGET_HOME/.p10k.zsh.pre-acfs.20261024000000"
    # The backup name is predictable to the second; pin that second.
    date() { printf '20261024000000\n'; }
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$(cat "$ROOT_DIR/victim")" == "root file" ]]
    [[ -f "$TARGET_HOME/.p10k.zsh.pre-acfs.20261024000000" && ! -L "$TARGET_HOME/.p10k.zsh.pre-acfs.20261024000000" ]]
    [[ "$(cat "$TARGET_HOME/.p10k.zsh.pre-acfs.20261024000000")" == "my p10k" ]]
    [[ -z "$(find "$TARGET_HOME" -maxdepth 1 -name '.acfs-backup.*')" ]]
}

@test "an unchanged ~/.p10k.zsh gets no backup" {
    mkdir -p "$BATS_TEST_TMPDIR/bootstrap/acfs/zsh"
    printf 'acfs p10k\n' > "$BATS_TEST_TMPDIR/bootstrap/acfs/zsh/p10k.zsh"
    printf 'acfs p10k\n' > "$TARGET_HOME/.p10k.zsh"
    run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ -z "$(find "$TARGET_HOME" -maxdepth 1 -name '.p10k.zsh.pre-acfs.*')" ]]
}

# Loads install.sh's acfs_check_protected_hardlinks, with a sysctl file the
# test writes in place of /proc/sys/fs/protected_hardlinks.
load_hardlinks_guard() {
    eval "$(sed -n '/^acfs_check_protected_hardlinks() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_check_protected_hardlinks)" == "function" ]]
    log_warn() { printf 'WARN: %s\n' "$*"; }
    log_error() { printf 'ERROR: %s\n' "$*"; }
    TARGET_USER=tester
    ACFS_PROTECTED_HARDLINKS_FILE="$BATS_TEST_TMPDIR/protected_hardlinks"
}

@test "main checks fs.protected_hardlinks before the first handover, when the installer isn't the target user (acfs-wmgr)" {
    local body guard first
    body="$(sed -n '/^main() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    guard="$(grep -n 'acfs_check_protected_hardlinks || exit 1' <<<"$body" | cut -d: -f1)"
    [[ -n "$guard" ]]
    # shellcheck disable=SC2016  # The literal condition main holds.
    grep -qF '[[ "$(acfs_early_resolve_current_user 2>/dev/null || true)" != "$TARGET_USER" ]]' <<<"$body"
    # It follows init_target_paths and comes before anything that hands files over.
    (( guard > $(grep -n '^\s*init_target_paths$' <<<"$body" | cut -d: -f1) ))
    first="$(grep -nE 'acfs_log_init|state_init|acfs_chown_tree|acfs_dotfile_own_for_target|chown ' <<<"$body" | head -1 | cut -d: -f1)"
    [[ -n "$first" ]]
    (( guard < first ))
}

@test "fs.protected_hardlinks on: the install goes on, silently" {
    load_hardlinks_guard
    printf '1\n' > "$ACFS_PROTECTED_HARDLINKS_FILE"
    MODE=safe run acfs_check_protected_hardlinks
    [[ "$status" -eq 0 && -z "$output" ]]
}

@test "fs.protected_hardlinks off: --mode safe stops, naming the sysctl and the fix" {
    load_hardlinks_guard
    printf '0\n' > "$ACFS_PROTECTED_HARDLINKS_FILE"
    MODE=safe run acfs_check_protected_hardlinks
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ERROR: fs.protected_hardlinks is 0"* ]]
    [[ "$output" == *"sudo sysctl -w fs.protected_hardlinks=1"* ]]
}

@test "fs.protected_hardlinks off: vibe mode warns and goes on" {
    load_hardlinks_guard
    printf '0\n' > "$ACFS_PROTECTED_HARDLINKS_FILE"
    MODE=vibe run acfs_check_protected_hardlinks
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARN: fs.protected_hardlinks is 0"* && "$output" != *"ERROR:"* ]]
}

@test "fs.protected_hardlinks unreadable or not a number: a warning, and the install goes on, in either mode" {
    load_hardlinks_guard
    MODE=safe run acfs_check_protected_hardlinks
    [[ "$status" -eq 0 && "$output" == *"WARN: Unable to read fs.protected_hardlinks"* ]]
    printf 'x\n' > "$ACFS_PROTECTED_HARDLINKS_FILE"
    MODE=safe run acfs_check_protected_hardlinks
    [[ "$status" -eq 0 && "$output" == *"WARN: Unable to read fs.protected_hardlinks"* ]]
}
