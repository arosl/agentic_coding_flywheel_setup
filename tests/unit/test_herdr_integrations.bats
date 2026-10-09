#!/usr/bin/env bats
#
# tools.herdr installs herdr's integration for each agent CLI ACFS put on
# PATH. These tests run the shipped install step, extracted from the
# generated installer, under the same `set -euo pipefail` run_as_target_shell
# uses. herdr and the agent CLIs are fakes: this proves which integrations
# the step asks for and that a refused integration doesn't fail the module.
# It does not prove that real herdr accepts them.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    STEP="$BATS_TEST_TMPDIR/herdr_integrations.sh"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    CALLS="$BATS_TEST_TMPDIR/herdr_calls"
    mkdir -p "$FAKE_BIN"

    # The heredoc body that follows the step's acfs-summary line.
    sed -n '/^# acfs-summary: install herdr integrations/,/^INSTALL_TOOLS_HERDR$/p' \
        "$PROJECT_ROOT/scripts/generated/install_tools.sh" | sed '$d' > "$STEP"
    [[ -s "$STEP" ]]

    # Fake herdr: records each call, and refuses the targets in
    # HERDR_REFUSE the way real herdr refuses an agent with no config dir.
    cat > "$FAKE_BIN/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case " \${HERDR_REFUSE:-} " in
    *" \$3 "*) echo "\$3 config directory not found" >&2; exit 1 ;;
esac
EOF
    chmod +x "$FAKE_BIN/herdr"
}

fake_agent() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$1"
    chmod +x "$FAKE_BIN/$1"
}

run_step() {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$FAKE_BIN:/usr/bin:/bin" \
        HERDR_REFUSE="${HERDR_REFUSE:-}" bash -c 'set -euo pipefail; source "$1"' _ "$STEP"
}

@test "installs an integration only for the agent CLIs on PATH" {
    fake_agent claude
    fake_agent agy

    run_step
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == $'integration install claude\nintegration install antigravity-cli' ]]
}

@test "a refused integration warns and the step still succeeds" {
    fake_agent claude
    fake_agent codex
    HERDR_REFUSE="codex"

    run_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"herdr: no codex integration yet; start codex once, and acfs update installs it"* ]]
    run cat "$CALLS"
    [[ "$output" == $'integration install claude\nintegration install codex' ]]
}

@test "a refused integration is recorded once for acfs update to retry" {
    fake_agent claude
    fake_agent codex
    HERDR_REFUSE="codex"

    run_step
    [[ "$status" -eq 0 ]]
    run_step
    [[ "$status" -eq 0 ]]
    run cat "$BATS_TEST_TMPDIR/.acfs/herdr-integrations-pending"
    [[ "$output" == "codex" ]]
}

@test "an accepted integration is not recorded as pending" {
    fake_agent claude

    run_step
    [[ "$status" -eq 0 ]]
    [[ ! -e "$BATS_TEST_TMPDIR/.acfs/herdr-integrations-pending" ]]
}

@test "no agent CLIs on PATH means no herdr calls" {
    run_step
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
}
