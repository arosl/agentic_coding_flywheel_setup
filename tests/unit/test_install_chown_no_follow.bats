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
