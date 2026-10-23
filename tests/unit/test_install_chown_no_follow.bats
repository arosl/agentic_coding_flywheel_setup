#!/usr/bin/env bats
#
# install.sh runs as root and hands files to the target user in directories
# that user already owns (~/.acfs, ~, ~/.local/bin, /data/projects). A plain
# chown follows a symlink, so a user who swaps the file for one between the
# write and the chown gets root to chown the link's target, say /etc/shadow.
# acfs-573x: every such chown passes -h, which changes the link itself.
#
# setup_shell writes ~/.zshrc, ~/.profile and ~/.zprofile with shell
# redirects, which follow a link too. A dangling ~/.profile pointing at
# /etc/profile.d/x.sh would have root create that file; a link to an
# existing file would have root append to it. So as root it never writes
# through a link there.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    # Stands in for a root-owned directory such as /etc/profile.d.
    ROOT_DIR="$BATS_TEST_TMPDIR/etc"
    mkdir -p "$TARGET_HOME" "$ROOT_DIR"
}

# Each code line of install.sh whose chown gives a path to $TARGET_USER.
target_user_chowns() {
    grep -nE '(^|[^[:alnum:]_-])chown( +-[[:alpha:]]+)* +"\$(\{TARGET_USER\}|TARGET_USER)[:"]' \
        "$PROJECT_ROOT/install.sh" | grep -vE '^[0-9]+:[[:space:]]*#'
}

@test "install.sh gives the target user its files only with chown -h" {
    local chowns missing
    chowns="$(target_user_chowns)"
    # The pattern still finds the call sites, so the check can't pass empty.
    (( $(wc -l <<<"$chowns") >= 20 ))
    missing="$(grep -vE 'chown +-[[:alpha:]]*h[[:alpha:]]* ' <<<"$chowns" || true)"
    printf '%s\n' "$missing"
    [[ -z "$missing" ]]
}

# Runs install.sh's setup_shell with stubs, as uid FAKE_UID, for
# ACFS_DISTRO_FAMILY (ubuntu unless set). Prints its warnings and its rc.
run_setup_shell() {
    local fn
    for fn in profile_path_has_fragment profile_path_sed_literal \
        acfs_zshrc_is_managed_loader acfs_dotfile_link_unsafe_for_root setup_shell; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done

    id() { if [[ "${1:-}" == "-u" ]]; then printf '%s\n' "$FAKE_UID"; else command id "$@"; fi; }
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
    run_as_target() { :; }
    acfs_run_verified_upstream_script_as_target() { :; }
    set_default_shell() { return 0; }
    chown() { :; }

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

    local rc=0
    setup_shell || rc=$?
    printf 'rc=%s\n' "$rc"
}

@test "as root, a dangling ~/.profile or ~/.zprofile link gets no file created through it" {
    mkdir -p "$ROOT_DIR/profile.d"
    ln -s "$ROOT_DIR/profile.d/x.sh" "$TARGET_HOME/.profile"
    ln -s "$ROOT_DIR/zprofile" "$TARGET_HOME/.zprofile"
    FAKE_UID=0 run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ ! -e "$ROOT_DIR/profile.d/x.sh" ]]
    [[ ! -e "$ROOT_DIR/zprofile" ]]
    [[ -L "$TARGET_HOME/.profile" && -L "$TARGET_HOME/.zprofile" ]]
    [[ "$output" == *"WARN: $TARGET_HOME/.profile is a symlink"* ]]
    [[ "$output" == *"WARN: $TARGET_HOME/.zprofile is a symlink"* ]]
    [[ "$output" == *'WARN: export PATH="$HOME/.local/bin:'* ]]
}

@test "as root, a ~/.profile or ~/.zprofile link to an existing file leaves that file as it was" {
    printf 'root content\n' > "$ROOT_DIR/bash.bashrc"
    ln -s "$ROOT_DIR/bash.bashrc" "$TARGET_HOME/.profile"
    ln -s "$ROOT_DIR/bash.bashrc" "$TARGET_HOME/.zprofile"
    FAKE_UID=0 run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$(cat "$ROOT_DIR/bash.bashrc")" == "root content" ]]
}

@test "as root on Ubuntu, a ~/.zshrc link is moved aside, and a regular loader takes its place" {
    printf 'root content\n' > "$ROOT_DIR/zshrc"
    ln -s "$ROOT_DIR/zshrc" "$TARGET_HOME/.zshrc"
    FAKE_UID=0 run run_setup_shell
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

@test "as root on Ubuntu, a dangling ~/.zshrc link gets no file created through it" {
    ln -s "$ROOT_DIR/zshrc" "$TARGET_HOME/.zshrc"
    FAKE_UID=0 run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ ! -e "$ROOT_DIR/zshrc" ]]
    [[ -f "$TARGET_HOME/.zshrc" && ! -L "$TARGET_HOME/.zshrc" ]]
}

@test "as root on Arch, a ~/.zshrc link is left alone, with the loader line to add" {
    ln -s "$ROOT_DIR/zshrc" "$TARGET_HOME/.zshrc"
    ACFS_DISTRO_FAMILY=arch FAKE_UID=0 run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ ! -e "$ROOT_DIR/zshrc" ]]
    [[ -L "$TARGET_HOME/.zshrc" ]]
    [[ "$output" == *"WARN: $TARGET_HOME/.zshrc is a symlink, so ACFS doesn't write through it as root"* ]]
    [[ "$output" == *'WARN: [[ -f "$HOME/.acfs/zsh/acfs.zshrc" ]] && source "$HOME/.acfs/zsh/acfs.zshrc"'* ]]
}

@test "run as the target user, setup_shell still writes through a dotfiles link" {
    mkdir -p "$TARGET_HOME/dotfiles"
    printf '# my profile\n' > "$TARGET_HOME/dotfiles/profile"
    ln -s "$TARGET_HOME/dotfiles/profile" "$TARGET_HOME/.profile"
    FAKE_UID=1000 run run_setup_shell
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" != *"is a symlink"* ]]
    [[ -L "$TARGET_HOME/.profile" ]]
    grep -Fq 'export PATH="$HOME/.local/bin:' "$TARGET_HOME/dotfiles/profile"
}
