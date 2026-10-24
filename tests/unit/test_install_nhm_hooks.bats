#!/usr/bin/env bats
#
# acfs-9hkh.46: install.sh's acfs_install_nhm_hook_lines registers the
# nhm-hook lines when nhm-hook is in ${NHM_BIN_DIR:-~/.local/bin} of the
# target user, removes the lines ACFS wrote when it is not, and changes
# nothing when the check cannot run as the target user. The function runs
# with the installer's helpers stubbed and the real nhm_hooks.sh.

load 'test_helper'

setup() {
    common_setup
    FIX="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FIX/.acfs/scripts/lib" "$FIX/.claude" "$FIX/.local/bin"
    cp "$PROJECT_ROOT/scripts/lib/nhm_hooks.sh" "$FIX/.acfs/scripts/lib/"
    printf '{"model": "opus"}\n' > "$FIX/.claude/settings.json"
    FN="$BATS_TEST_TMPDIR/fn.sh"
    awk '
        /^acfs_install_nhm_hook_lines\(\) \{/ { capture=1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$PROJECT_ROOT/install.sh" > "$FN"
    [[ -s "$FN" ]] || fail "acfs_install_nhm_hook_lines not found in install.sh"
}

teardown() {
    common_teardown
}

install_hook_bin() {
    printf '#!/bin/sh\nexit 0\n' > "$FIX/.local/bin/nhm-hook"
    chmod 0755 "$FIX/.local/bin/nhm-hook"
}

# Run the function. Env knobs: SELECTED (stack.nhm selected, default 1),
# RUN_AS_FAILS (run_as_target fails as a refused sudo does).
run_fn() {
    run env -i PATH="/usr/bin:/bin" HOME="$FIX" FIX="$FIX" FN="$FN" \
        SELECTED="${SELECTED:-1}" RUN_AS_FAILS="${RUN_AS_FAILS:-}" bash -c '
        ACFS_HOME="$FIX/.acfs" TARGET_HOME="$FIX" TARGET_USER=ubuntu
        run_as_target() { [[ -z "$RUN_AS_FAILS" ]] || return 1; "$@"; }
        acfs_legacy_module_selected() { [[ "$1" == stack.nhm && "$SELECTED" == 1 ]]; }
        binary_installed() { [[ "$1" == claude ]]; }
        try_step() { shift; "$@"; }
        try_step_optional() { shift; "$@"; }
        log_warn() { printf "WARN %s\n" "$1"; }
        log_detail() { printf "DETAIL %s\n" "$1"; }
        # shellcheck source=/dev/null
        source "$FN"
        acfs_install_nhm_hook_lines
    '
}

registered() {
    HOME="$FIX" bash "$FIX/.acfs/scripts/lib/nhm_hooks.sh" registered claude "$FIX/.claude/settings.json"
}

@test "nhm-hook present: the lines are registered" {
    install_hook_bin
    run_fn
    assert_success
    registered || fail "the nhm hook lines were not registered"
    grep -q '"model": "opus"' "$FIX/.claude/settings.json" || fail "other settings were lost"
}

@test "nhm-hook under NHM_BIN_DIR counts as present" {
    mkdir -p "$FIX/alt"
    printf '#!/bin/sh\nexit 0\n' > "$FIX/alt/nhm-hook"
    chmod 0755 "$FIX/alt/nhm-hook"
    run env -i PATH="/usr/bin:/bin" HOME="$FIX" FIX="$FIX" FN="$FN" NHM_BIN_DIR="$FIX/alt" bash -c '
        ACFS_HOME="$FIX/.acfs" TARGET_HOME="$FIX" TARGET_USER=ubuntu
        run_as_target() { "$@"; }
        acfs_legacy_module_selected() { true; }
        binary_installed() { [[ "$1" == claude ]]; }
        try_step() { shift; "$@"; }
        try_step_optional() { shift; "$@"; }
        log_warn() { printf "WARN %s\n" "$1"; }
        log_detail() { :; }
        source "$FN"
        acfs_install_nhm_hook_lines
    '
    assert_success
    refute_output --partial "WARN"
    grep -q "$FIX/alt/nhm-hook sessionstart" "$FIX/.claude/settings.json" \
        || fail "the lines do not run NHM_BIN_DIR's nhm-hook"
}

@test "nhm-hook missing: the lines an earlier run added are removed" {
    install_hook_bin
    run_fn
    registered || fail "setup: the lines were not registered"
    rm -f "$FIX/.local/bin/nhm-hook"
    run_fn
    assert_success
    assert_output --partial "WARN nhm-hook is not installed"
    ! registered || fail "the lines are still there"
    grep -q 'nhm-hook' "$FIX/.claude/settings.json" && fail "an nhm-hook line is left"
    grep -q '"model": "opus"' "$FIX/.claude/settings.json" || fail "other settings were lost"
}

@test "nhm-hook missing and stack.nhm not selected: lines removed, no warning" {
    install_hook_bin
    run_fn
    rm -f "$FIX/.local/bin/nhm-hook"
    SELECTED=0 run_fn
    assert_success
    refute_output --partial "WARN"
    grep -q 'nhm-hook' "$FIX/.claude/settings.json" && fail "an nhm-hook line is left"
    true
}

@test "the check cannot run as the target user: says so and changes nothing" {
    install_hook_bin
    run_fn
    cp "$FIX/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
    rm -f "$FIX/.local/bin/nhm-hook"
    RUN_AS_FAILS=1 run_fn
    assert_success
    assert_output --partial "WARN could not check for nhm-hook as ubuntu"
    refute_output --partial "not installed"
    cmp -s "$FIX/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json" || fail "the settings changed"
}

# acfs-5917: Claude Code's statusLine runs nhm quota record-claude.
statusline_command() {
    jq -r '.statusLine.command // empty' "$FIX/.claude/settings.json"
}

@test "nhm-hook present: Claude Code's statusLine runs nhm quota record-claude" {
    install_hook_bin
    run_fn
    assert_success
    assert_output --partial "DETAIL Claude Code's statusLine records Claude's windows for nhm"
    [[ "$(statusline_command)" == "$FIX/.local/bin/nhm quota record-claude" ]] \
        || fail "statusLine is '$(statusline_command)'"
    grep -q '"model": "opus"' "$FIX/.claude/settings.json" || fail "other settings were lost"
}

@test "ACFS's older agent_quota.sh statusLine is replaced by nhm's" {
    printf '{"statusLine": {"type": "command", "command": "bash %s/.acfs/scripts/lib/agent_quota.sh record-claude"}}\n' "$FIX" \
        > "$FIX/.claude/settings.json"
    install_hook_bin
    run_fn
    assert_success
    [[ "$(statusline_command)" == "$FIX/.local/bin/nhm quota record-claude" ]] \
        || fail "statusLine is '$(statusline_command)'"
}

@test "a statusLine of the user's stays, and the install says so" {
    printf '{"statusLine": {"type": "command", "command": "~/bin/my-status"}}\n' > "$FIX/.claude/settings.json"
    install_hook_bin
    run_fn
    assert_success
    assert_output --partial "DETAIL Claude Code's statusLine is your own"
    refute_output --partial "WARN"
    # shellcheck disable=SC2088  # the user's literal ~ in settings.json
    [[ "$(statusline_command)" == "~/bin/my-status" ]] || fail "the user's statusLine changed"
}

@test "nhm-hook missing: nhm's statusLine an earlier run set is removed" {
    install_hook_bin
    run_fn
    [[ -n "$(statusline_command)" ]] || fail "setup: no statusLine"
    rm -f "$FIX/.local/bin/nhm-hook"
    run_fn
    assert_success
    jq -e 'has("statusLine") | not' "$FIX/.claude/settings.json" >/dev/null || fail "nhm's statusLine is left"
}

@test "stack.nhm not selected: nothing is registered" {
    install_hook_bin
    SELECTED=0 run_fn
    assert_success
    ! registered || fail "lines were registered for a module not selected"
}

# acfs-9hkh.60: nhm's verified installer runs in a clean environment, so it
# never sees the caller's NHM_BIN_DIR and installs to ~/.local/bin. Every
# other stack.nhm step (verify, enroll, the hook check) must read the same
# directory, so run_as_target passes NHM_BIN_DIR in neither mode, in
# neither copy. The library copy runs for real here, with a spy sudo;
# install.sh's copy is checked by its source.

@test "run_as_target passes no NHM_BIN_DIR to the target user, in either mode" {
    source_lib "logging"
    source_lib "install_helpers"
    export TARGET_USER="testuser" TARGET_HOME="/home/testuser" NHM_BIN_DIR="/opt/nhm/bin"
    _acfs_getent_passwd_entry() {
        [[ "${1:-}" == "testuser" ]] || return 1
        printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'
    }
    spy_command "sudo"
    export ACFS_TEST_SUDO_BIN="$STUB_DIR/sudo"
    _acfs_system_binary_path() {
        local name="${1:-}" candidate=""
        if [[ "$name" == "sudo" ]]; then printf '%s\n' "$ACFS_TEST_SUDO_BIN"; return 0; fi
        for candidate in "/usr/bin/$name" "/bin/$name"; do
            [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
        done
        return 1
    }
    run run_as_target bash -c true
    assert_success
    [[ "$(cat "$STUB_DIR/sudo.log")" != *"NHM_BIN_DIR="* ]] \
        || fail "NHM_BIN_DIR reached the target user's steps: $(cat "$STUB_DIR/sudo.log")"
    : > "$STUB_DIR/sudo.log"
    local script="$BATS_TEST_TMPDIR/verified-installer.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$script"
    run run_as_target --acfs-clean-environment bash "$script"
    assert_success
    [[ "$(cat "$STUB_DIR/sudo.log")" != *"NHM_BIN_DIR="* ]] \
        || fail "NHM_BIN_DIR reached a clean environment: $(cat "$STUB_DIR/sudo.log")"
}

@test "install.sh's run_as_target passes no NHM_BIN_DIR either" {
    local body
    body="$(awk '
        /^run_as_target\(\) \{/ { capture=1 }
        capture { print }
        capture && /^    command_argv=\("\$@"\)/ { exit }
    ' "$PROJECT_ROOT/install.sh")"
    [[ -n "$body" ]] || fail "run_as_target not found in install.sh"
    ! grep -q 'NHM_BIN_DIR' <<< "$body" \
        || fail "install.sh's run_as_target passes NHM_BIN_DIR; nhm's clean installer would not see it"
}

# acfs-hd37: install and acfs update leave nhm's capacity provider unset.
# With it set, a red guard refuses every spawn that doesn't pass
# --ignore-capacity, so turning it on is the user's choice.
@test "install and acfs update never set nhm's capacity provider" {
    ! grep -n 'capacity-provider set' "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/scripts/lib/update.sh" \
        || fail "install.sh or update.sh sets nhm's capacity provider"
}
