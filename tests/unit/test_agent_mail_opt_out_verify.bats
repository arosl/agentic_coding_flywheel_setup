#!/usr/bin/env bats
#
# stack.mcp_agent_mail's verdict after a local opt-out (acfs-v1lt). The
# install respects an Agent Mail opt-out (issue #327: ACFS_SKIP_AGENT_MAIL=1,
# a persistent mask, a disabled and stopped unit) and leaves the service
# down. But upstream's #474 verify, new in the 2d7f95a9 sync, checks
# stack.mcp_agent_mail after phase 9 with the manifest's verify, which
# requires the service active and healthy. Every opted-out install then ended
# with failures. install.sh's authored verifier now needs only Agent Mail's
# CLI while stack.sh's stack_agent_mail_opted_out holds; otherwise the
# manifest's verify decides. test_stack_agent_mail_mask.sh checks that
# predicate against the configure step's rc 75.
#
# The tests run the real acfs_verify_module (install_helpers.sh), the real
# acfs_verify_authored_module (from install.sh) and the generated manifest
# index; only the target user's commands are stubs, in a temp home.

load test_helper

setup() {
    common_setup
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FAKE_HOME/mcp_agent_mail" "$FAKE_HOME/.acfs/scripts/lib"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_HOME/mcp_agent_mail/am"
    chmod +x "$FAKE_HOME/mcp_agent_mail/am"
    export FAKE_HOME

    source_lib "logging"
    source_lib "install_helpers"
    # shellcheck source=../../scripts/generated/manifest_index.sh
    source "$PROJECT_ROOT/scripts/generated/manifest_index.sh"
    eval "$(sed -n '/^acfs_verify_authored_module() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t acfs_verify_authored_module)" == "function" ]]
    # The target user's commands run in the temp home.
    run_as_target() { HOME="$FAKE_HOME" "$@"; }
    # stack.sh isn't sourced yet, as on a resume that verifies phase 9 first.
    ACFS_LIB_DIR="$BATS_TEST_TMPDIR/no-lib"
}

teardown() {
    common_teardown
}

# stack.sh's resolver, as the temp home has it.
stub_cli_path() {
    _stack_agent_mail_cli_path() {
        [[ -x "$FAKE_HOME/mcp_agent_mail/am" ]] || return 1
        printf '%s\n' "$FAKE_HOME/mcp_agent_mail/am"
    }
}

@test "opted out: stack.mcp_agent_mail is ready with Agent Mail's CLI and no service" {
    stack_agent_mail_opted_out() { return 0; }
    stub_cli_path
    run acfs_verify_module "stack.mcp_agent_mail"
    [[ "$status" -eq 0 ]]
}

@test "opted out: stack.mcp_agent_mail is not ready without Agent Mail's CLI" {
    stack_agent_mail_opted_out() { return 0; }
    stub_cli_path
    rm "$FAKE_HOME/mcp_agent_mail/am"
    run acfs_verify_module "stack.mcp_agent_mail"
    [[ "$status" -ne 0 ]]
}

@test "opted out: stack.mcp_agent_mail is not ready when its CLI fails to run" {
    stack_agent_mail_opted_out() { return 0; }
    stub_cli_path
    printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_HOME/mcp_agent_mail/am"
    run acfs_verify_module "stack.mcp_agent_mail"
    [[ "$status" -ne 0 ]]
}

@test "not opted out: the manifest's verify decides" {
    stack_agent_mail_opted_out() { return 1; }
    stub_cli_path
    run acfs_verify_authored_module "stack.mcp_agent_mail"
    [[ "$status" -eq 2 ]]
}

@test "without stack.sh, the manifest's verify decides" {
    run acfs_verify_authored_module "stack.mcp_agent_mail"
    [[ "$status" -eq 2 ]]
}

@test "the verifier sources stack.sh when it isn't loaded, and uses its opt-out and resolver" {
    ACFS_LIB_DIR="$PROJECT_ROOT/scripts/lib"
    ACFS_SKIP_AGENT_MAIL=1
    TARGET_USER="$(id -un)"
    TARGET_HOME="$FAKE_HOME"
    ACFS_STACK_TRUST_TARGET_HOME=true
    [[ "$(type -t stack_agent_mail_opted_out)" != "function" ]]
    run acfs_verify_authored_module "stack.mcp_agent_mail"
    [[ "$status" -eq 0 ]]
    # A system am on PATH is not Agent Mail's CLI.
    rm "$FAKE_HOME/mcp_agent_mail/am"
    mkdir -p "$BATS_TEST_TMPDIR/sysbin"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/sysbin/am"
    chmod +x "$BATS_TEST_TMPDIR/sysbin/am"
    PATH="$BATS_TEST_TMPDIR/sysbin:$PATH" run acfs_verify_authored_module "stack.mcp_agent_mail"
    [[ "$status" -ne 0 ]]
}
