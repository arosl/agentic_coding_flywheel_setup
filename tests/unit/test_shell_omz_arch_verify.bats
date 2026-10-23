#!/usr/bin/env bats
#
# shell.omz's verdict on Arch-family systems (acfs-yz54). setup_shell keeps
# an Arch system's own prompt and installs no Oh My Zsh, Powerlevel10k or
# ~/.p10k.zsh there, but upstream's #474 verify, new in the 2d7f95a9 sync,
# checks shell.omz after phase 4 with the manifest's verify, which requires
# both. Every Arch install then failed phase 4. install.sh's authored
# verifier now decides shell.omz on Arch: ACFS's zshrc and the zsh login
# shell. Elsewhere the manifest's verify still decides.
#
# The tests run the real acfs_verify_module (install_helpers.sh), the real
# acfs_verify_authored_module (from install.sh) and the generated manifest
# index; only the target user's shell is a stub, in a temp home.

load test_helper

setup() {
    common_setup
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    FAKE_LIB="$BATS_TEST_TMPDIR/lib"
    mkdir -p "$FAKE_HOME/.acfs/zsh" "$FAKE_LIB"
    : >"$FAKE_HOME/.acfs/zsh/acfs.zshrc"
    # The login-shell check, as the target user sees it: configured while
    # the marker file exists.
    printf '%s\n' 'user_login_shell_configured() { [[ -f "$HOME/.login-shell-ok" ]]; }' >"$FAKE_LIB/user.sh"
    : >"$FAKE_HOME/.login-shell-ok"
    export FAKE_HOME FAKE_LIB

    source_lib "logging"
    source_lib "install_helpers"
    # shellcheck source=../../scripts/generated/manifest_index.sh
    source "$PROJECT_ROOT/scripts/generated/manifest_index.sh"
    eval "$(sed -n '/^acfs_verify_authored_module() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_verify_authored_module)" == "function" ]]
    # The target user's shell: the command runs in the temp home.
    run_as_target_shell() { HOME="$FAKE_HOME" ACFS_LIB_DIR="$FAKE_LIB" bash -c "$1"; }
}

teardown() {
    common_teardown
}

@test "Arch: shell.omz is ready with ACFS's zshrc and the login shell, without Oh My Zsh or p10k" {
    ACFS_DISTRO_FAMILY=arch
    [[ ! -e "$FAKE_HOME/.oh-my-zsh" && ! -e "$FAKE_HOME/.p10k.zsh" ]]
    run acfs_verify_module "shell.omz"
    [[ "$status" -eq 0 ]]
}

@test "Arch: shell.omz is not ready without ACFS's zshrc" {
    ACFS_DISTRO_FAMILY=arch
    rm "$FAKE_HOME/.acfs/zsh/acfs.zshrc"
    run acfs_verify_module "shell.omz"
    [[ "$status" -ne 0 ]]
}

@test "Arch: shell.omz is not ready while the login shell isn't zsh" {
    ACFS_DISTRO_FAMILY=arch
    rm "$FAKE_HOME/.login-shell-ok"
    run acfs_verify_module "shell.omz"
    [[ "$status" -ne 0 ]]
}

@test "Ubuntu: the manifest's verify still decides, so a home without Oh My Zsh fails" {
    ACFS_DISTRO_FAMILY=ubuntu
    run acfs_verify_authored_module "shell.omz"
    [[ "$status" -eq 2 ]]
    run acfs_verify_module "shell.omz"
    [[ "$status" -ne 0 ]]
}

@test "Ubuntu: with Oh My Zsh and ~/.p10k.zsh in place, the manifest's verify passes" {
    ACFS_DISTRO_FAMILY=ubuntu
    mkdir -p "$FAKE_HOME/.oh-my-zsh"
    : >"$FAKE_HOME/.p10k.zsh"
    run acfs_verify_module "shell.omz"
    [[ "$status" -eq 0 ]]
}
