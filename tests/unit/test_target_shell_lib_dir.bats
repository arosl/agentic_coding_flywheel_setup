#!/usr/bin/env bats
#
# run_as_target_shell and an ACFS_LIB_DIR the target user can't read
# (acfs-pkqz). For a local-checkout run, ACFS_LIB_DIR is the checkout's
# scripts/lib, root's view. Under a 0700 directory such as /root/acfs the
# target user can't read it, so shell.login's and shell.omz's verify
# ('source "${ACFS_LIB_DIR:-$HOME/.acfs/scripts/lib}/user.sh" && ...')
# failed, and with upstream's #474 phase verify, phase 4 failed with it.
# run_as_target_shell now drops an ACFS_LIB_DIR the target can't read and
# traverse, so the deployed copy under ~/.acfs answers.
#
# run_as_target is a stub that runs the command as the current user; the
# checkout's lib dir is made unreadable with chmod 000, which binds only a
# non-root user.

load test_helper

setup() {
    common_setup
    [[ "$EUID" -ne 0 ]] || skip "permission bits don't bind root"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    CHECKOUT_LIB="$BATS_TEST_TMPDIR/checkout/scripts/lib"
    mkdir -p "$FAKE_HOME/.acfs/scripts/lib" "$CHECKOUT_LIB"
    printf '%s\n' 'which_user_sh() { echo deployed; }' >"$FAKE_HOME/.acfs/scripts/lib/user.sh"
    printf '%s\n' 'which_user_sh() { echo checkout; }' >"$CHECKOUT_LIB/user.sh"

    source_lib "logging"
    source_lib "install_helpers"
    run_as_target() { HOME="$FAKE_HOME" "$@"; }
    export ACFS_LIB_DIR="$CHECKOUT_LIB"
    SOURCE_USER_SH='source "${ACFS_LIB_DIR:-$HOME/.acfs/scripts/lib}/user.sh" && which_user_sh'
}

teardown() {
    chmod 755 "$BATS_TEST_TMPDIR/checkout" 2>/dev/null || true
    [[ -d "$CHECKOUT_LIB" ]] && chmod 755 "$CHECKOUT_LIB"
    common_teardown
}

@test "a readable ACFS_LIB_DIR is used, as before" {
    run run_as_target_shell "$SOURCE_USER_SH"
    [[ "$status" -eq 0 && "$output" == "checkout" ]]
}

@test "an ACFS_LIB_DIR the target can't read falls back to the deployed copy" {
    chmod 000 "$CHECKOUT_LIB"
    run run_as_target_shell "$SOURCE_USER_SH"
    [[ "$status" -eq 0 && "$output" == "deployed" ]]
}

@test "a readable lib dir under a parent the target can't traverse falls back too" {
    # The real layout: /root is 0700, its checkout's scripts/lib is 0755.
    chmod 000 "$BATS_TEST_TMPDIR/checkout"
    run run_as_target_shell "$SOURCE_USER_SH"
    [[ "$status" -eq 0 && "$output" == "deployed" ]]
}

@test "the same fallback holds in stdin mode" {
    chmod 000 "$CHECKOUT_LIB"
    pipe_to_target_shell() { printf '%s\n' "$1" | run_as_target_shell; }
    run pipe_to_target_shell "$SOURCE_USER_SH"
    [[ "$status" -eq 0 && "$output" == "deployed" ]]
}

@test "an ACFS_LIB_DIR that doesn't exist falls back too" {
    ACFS_LIB_DIR="$BATS_TEST_TMPDIR/no-such-dir"
    run run_as_target_shell "$SOURCE_USER_SH"
    [[ "$status" -eq 0 && "$output" == "deployed" ]]
}

@test "the caller's own ACFS_LIB_DIR is unchanged" {
    chmod 000 "$CHECKOUT_LIB"
    run_as_target_shell "$SOURCE_USER_SH" >/dev/null
    [[ "$ACFS_LIB_DIR" == "$CHECKOUT_LIB" ]]
}
