#!/usr/bin/env bats
#
# Every verified installer that the generated category libraries run goes
# through run_as_target_runner, whose clean-runner validator refuses an env
# assignment it doesn't know. A manifest module's env must therefore be on
# _acfs_clean_runner_env_allowed in both copies (install.sh, and
# scripts/lib/install_helpers.sh for the generated path). acfs-tqh9: once the
# legacy stack phase ran stack.ru through its generated installer, the
# validator refused RU_VERSION, and every fresh install failed stack.ru.
#
# These tests run each generated runner call, as written, through the real
# validator of each copy. They prove that no call is refused; the installers
# themselves don't run.

load test_helper

setup() {
    common_setup
    HOME_UNDER_TEST="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME_UNDER_TEST/.cache/acfs/installer-tmp/cass.ABC123"
    VERIFIED_FILE="$BATS_TEST_TMPDIR/verified-installer.sh"
    printf 'exit 0\n' > "$VERIFIED_FILE"
}

teardown() {
    common_teardown
}

# Each generated runner call, one per line, as "<file>:<line>:<call>".
generated_runner_calls() {
    grep -n -E '^ *elif run_as_target_runner .*; then$' "$PROJECT_ROOT"/scripts/generated/install_*.sh \
        | sed -E 's/^([^:]+):([0-9]+): *elif (run_as_target_runner .*); then$/\1:\2:\3/'
}

# Runs every generated call through the validator loaded in this shell.
check_generated_calls() {
    local failures="" location call count=0
    local TARGET_HOME="$HOME_UNDER_TEST"
    local verified_installer_file="$VERIFIED_FILE"
    local verified_installer_tmpdir="$HOME_UNDER_TEST/.cache/acfs/installer-tmp/cass.ABC123"
    local -a verified_installer_checksum_args=(--archive-sha256 "linux-amd64=$(printf '%064d' 1)")
    run_as_target_runner() { _acfs_validate_clean_runner_command "$TARGET_HOME" "$@"; }
    while IFS= read -r line; do
        location="${line%:run_as_target_runner *}"
        call="${line#"$location":}"
        count=$((count + 1))
        if ! eval "$call" 2>"$BATS_TEST_TMPDIR/refusal"; then
            failures+="$location: $(cat "$BATS_TEST_TMPDIR/refusal")"$'\n'
        fi
    done < <(generated_runner_calls)
    [[ "$count" -ge 40 ]] || failures+="only $count generated runner calls found"$'\n'
    printf '%s' "$failures"
    [[ -z "$failures" ]]
}

load_install_sh_validator() {
    log_error() { printf '%s\n' "$*" >&2; }
    eval "$(sed -n '/^_acfs_clean_runner_env_allowed() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    eval "$(sed -n '/^_acfs_validate_clean_runner_command() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t _acfs_clean_runner_env_allowed)" == "function" ]]
    [[ "$(type -t _acfs_validate_clean_runner_command)" == "function" ]]
}

load_install_helpers_validator() {
    source_lib "logging"
    source_lib "install_helpers"
    [[ "$(type -t _acfs_validate_clean_runner_command)" == "function" ]]
}

@test "install.sh's clean runner accepts every generated installer's env and arguments" {
    load_install_sh_validator
    run check_generated_calls
    [[ "$status" -eq 0 ]] || { printf '%s\n' "$output"; false; }
}

@test "install_helpers.sh's clean runner accepts every generated installer's env and arguments" {
    load_install_helpers_validator
    run check_generated_calls
    [[ "$status" -eq 0 ]] || { printf '%s\n' "$output"; false; }
}

@test "the generated stack.ru call carries its pin and self-refresh opt-out" {
    run generated_runner_calls
    [[ "$output" == *"'RU_VERSION=1.5.0-nhm.2' 'RU_INSTALLER_NO_SELF_REFRESH=1'"* ]]
}

@test "RU_VERSION takes a release name only, and RU_INSTALLER_NO_SELF_REFRESH only 1" {
    local loader value
    for loader in load_install_sh_validator load_install_helpers_validator; do
        "$loader"
        _acfs_clean_runner_env_allowed "$HOME_UNDER_TEST" "RU_VERSION=1.5.0-nhm.2"
        _acfs_clean_runner_env_allowed "$HOME_UNDER_TEST" "RU_VERSION=1.5.0"
        _acfs_clean_runner_env_allowed "$HOME_UNDER_TEST" "RU_INSTALLER_NO_SELF_REFRESH=1"
        for value in "RU_VERSION=" "RU_VERSION=latest" "RU_VERSION=../1.5.0" "RU_VERSION=1.5.0;id" \
                     "RU_VERSION=1.5.0 x" "RU_VERSION=v1.5.0" "RU_VERSION=1.5.0-" "RU_INSTALLER_NO_SELF_REFRESH=0"; do
            if _acfs_clean_runner_env_allowed "$HOME_UNDER_TEST" "$value"; then
                printf '%s accepted %s\n' "$loader" "$value"
                false
            fi
        done
    done
}
