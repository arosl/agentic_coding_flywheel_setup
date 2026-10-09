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

# install.sh's call that installs each agent CLI the step integrates: its
# verified-installer call, or for codex its try_step label.
install_call_for() {
    case "$1" in
        claude) echo 'acfs_run_verified_upstream_script_as_target "claude"' ;;
        codex) echo 'try_step "Installing Codex CLI"' ;;
        agy) echo 'acfs_run_verified_upstream_script_as_target "antigravity"' ;;
        opencode) echo 'acfs_run_verified_upstream_script_as_target "opencode"' ;;
        omp) echo 'acfs_run_verified_upstream_script_as_target "omp"' ;;
        grok) echo 'acfs_run_verified_upstream_script_as_target_with_env "grok"' ;;
    esac
}

@test "install.sh installs every agent CLI the step integrates before it runs tools.herdr" {
    local install_sh="$PROJECT_ROOT/install.sh"
    local herdr_call='acfs_legacy_run_manifest_module "tools.herdr"'

    # The phase functions main runs, in order.
    local -a phases
    mapfile -t phases < <(awk '/^main\(\) \{$/{m=1} m && /^}$/{exit} m' "$install_sh" \
        | sed -nE 's/^ *_run_phase_with_report "[^"]*" "[^"]*" ([A-Za-z0-9_]+).*/\1/p')
    local stack_index=-1 i
    for i in "${!phases[@]}"; do
        if [[ "${phases[$i]}" == "install_stack_phase" ]]; then stack_index=$i; fi
    done
    [[ "$stack_index" -gt 0 ]]

    # Each match of a fixed string as "<line> <enclosing top-level function>".
    calls_of() {
        awk -v needle="$1" '
            /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn = $0; sub(/\(.*/, "", fn) }
            index($0, needle) { print NR, fn }
        ' "$install_sh"
    }

    local herdr_line herdr_fn
    [[ "$(calls_of "$herdr_call" | wc -l)" -eq 1 ]]
    read -r herdr_line herdr_fn < <(calls_of "$herdr_call")
    [[ "$herdr_fn" == "install_stack_phase" ]]

    local -a clis
    read -r -a clis < <(sed -n 's/^for pair in \(.*\); do$/\1/p' "$STEP")
    [[ "${#clis[@]}" -gt 0 ]]

    local pair cli needle line fn phase_index failures=""
    for pair in "${clis[@]}"; do
        cli="${pair%%:*}"
        needle="$(install_call_for "$cli")"
        if [[ -z "$needle" ]] || ! read -r line fn < <(calls_of "$needle"); then
            failures+="$cli: no install call found in install.sh"$'\n'
            continue
        fi
        phase_index=-1
        for i in "${!phases[@]}"; do
            if [[ "${phases[$i]}" == "$fn" ]]; then phase_index=$i; fi
        done
        if [[ "$fn" == "install_stack_phase" ]]; then
            if [[ "$line" -gt "$herdr_line" ]]; then
                failures+="$cli: installed at line $line, after the tools.herdr call at line $herdr_line"$'\n'
            fi
        elif [[ "$phase_index" -lt 0 || "$phase_index" -gt "$stack_index" ]]; then
            failures+="$cli: installed at line $line in $fn, not in a phase main runs before install_stack_phase"$'\n'
        fi
    done
    printf '%s' "$failures"
    [[ -z "$failures" ]]
}
