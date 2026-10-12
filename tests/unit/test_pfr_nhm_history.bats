#!/usr/bin/env bats
#
# acfs-9hkh.30: pfr leaves out the sessions that ntm drove, by the prompts
# in ntm's send history. nhm writes that history in ntm's format, so
# acfs.zshrc points pfr at nhm's file through PFR_NTM_HISTORY. These tests
# run the pfr block of acfs.zshrc in zsh (and bash) with a stub pfr.

load 'test_helper'

setup() {
    common_setup
    ZSHRC="$PROJECT_ROOT/acfs/zsh/acfs.zshrc"
    PFR_BLOCK="$BATS_TEST_TMPDIR/pfr_block.sh"
    awk '
        /^# Power Failure Resumer/ { capture=1 }
        capture { print }
        capture && /^fi$/ { exit }
    ' "$ZSHRC" > "$PFR_BLOCK"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/pfr"
    chmod +x "$STUB_BIN/pfr"
}

teardown() {
    common_teardown
}

# Run the pfr block in the shell $1 and print PFR_NTM_HISTORY ("<unset>" if
# the block left it unset). Extra env assignments come after the shell.
pfr_history_in() {
    local shell="$1"
    shift
    env -i HOME="$BATS_TEST_TMPDIR/home" "$@" "$shell" -c \
        '. "$1"; printf "%s\n" "${PFR_NTM_HISTORY-<unset>}"' _ "$PFR_BLOCK"
}

@test "the pfr block exists in acfs.zshrc and sets PFR_NTM_HISTORY" {
    grep -q 'PFR_NTM_HISTORY' "$PFR_BLOCK" \
        || fail "the pfr block of acfs.zshrc no longer sets PFR_NTM_HISTORY"
}

@test "PFR_NTM_HISTORY defaults to nhm's history under ~/.local/share" {
    local shell
    for shell in zsh bash; do
        command -v "$shell" >/dev/null || continue
        run pfr_history_in "$shell" PATH="$STUB_BIN:/usr/bin:/bin"
        assert_success
        assert_output "$BATS_TEST_TMPDIR/home/.local/share/nhm/history.jsonl"
    done
}

@test "PFR_NTM_HISTORY follows XDG_DATA_HOME, as nhm does" {
    local shell
    for shell in zsh bash; do
        command -v "$shell" >/dev/null || continue
        run pfr_history_in "$shell" PATH="$STUB_BIN:/usr/bin:/bin" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
        assert_success
        assert_output "$BATS_TEST_TMPDIR/data/nhm/history.jsonl"
    done
}

@test "a PFR_NTM_HISTORY the user set is kept" {
    local shell
    for shell in zsh bash; do
        command -v "$shell" >/dev/null || continue
        run pfr_history_in "$shell" PATH="$STUB_BIN:/usr/bin:/bin" PFR_NTM_HISTORY=/custom/history.jsonl
        assert_success
        assert_output "/custom/history.jsonl"
    done
}

@test "without pfr the block sets nothing" {
    local shell
    for shell in zsh bash; do
        command -v "$shell" >/dev/null || continue
        run pfr_history_in "$shell" PATH="/usr/bin:/bin"
        assert_success
        assert_output "<unset>"
    done
}
