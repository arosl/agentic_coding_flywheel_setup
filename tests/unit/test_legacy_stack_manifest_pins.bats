#!/usr/bin/env bats
#
# install.sh's legacy stack phase is the default (stack is not a migrated
# category). Some generated installers pass what its hand-written runner
# can't: archive pins from checksums.yaml, or more than one env assignment.
# install.sh must run those modules through their generated installer
# (acfs_legacy_run_manifest_module), never through the hand-written runner.
# acfs-tqh9: the hand-written caam call had no --version and no pins, so a
# fresh Ubuntu 24.04 install failed stack.caam without cosign; the ru call
# had no RU_INSTALLER_NO_SELF_REFRESH=1, so ru's installer fetched main's
# install.sh, unverified, and ran it.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# "<module> <tool>" for each generated installer that passes archive pins
# or two or more env assignments.
pinned_modules() {
    awk '
        /^acfs_generated_install_[a-z0-9_]+\(\) \{$/ { module = ""; tool = ""; pinned = 0; next }
        /^    local module_id="/ { module = $0; sub(/^[^"]*"/, "", module); sub(/".*/, "", module) }
        /^ *local tool="/ { tool = $0; sub(/^[^"]*"/, "", tool); sub(/".*/, "", tool) }
        /verified_installer_checksum_args\+=/ { pinned = 1 }
        /run_as_target_runner .env. .[A-Za-z_][A-Za-z0-9_]*=[^ ]* .[A-Za-z_][A-Za-z0-9_]*=/ { pinned = 1 }
        /^}$/ { if (pinned && module != "" && tool != "") print module, tool; module = "" }
    ' "$PROJECT_ROOT"/scripts/generated/install_*.sh
}

@test "the generated installers of caam, ru and nhm pass pins or several env assignments" {
    run pinned_modules
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stack.caam caam"* ]]
    [[ "$output" == *"stack.ru ru"* ]]
    [[ "$output" == *"stack.nhm nhm"* ]]
}

@test "install.sh runs no such module's verified installer by hand" {
    local module tool calls failures=""
    while read -r module tool; do
        calls="$(grep -nE "acfs_run_verified_upstream_script_as_target(_with_env)? \"$tool\"" \
            "$PROJECT_ROOT/install.sh" || true)"
        if [[ -n "$calls" ]]; then
            failures+="$module: install.sh runs its installer by hand, without its pins:"$'\n'"$calls"$'\n'
        fi
    done < <(pinned_modules)
    printf '%s' "$failures"
    [[ -z "$failures" ]]
}

# Runs install.sh's install_stack_phase with every hand-written tool
# installed, Agent Mail deselected and fake generated installers that record
# their module. INSTALLED names the modules whose installed_check passes,
# FAILING the generated installers that fail.
run_stack_phase() {
    eval "$(sed -n '/^install_stack_phase() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    eval "$(sed -n '/^acfs_legacy_run_manifest_module() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t install_stack_phase)" == "function" ]]
    [[ "$(type -t acfs_legacy_run_manifest_module)" == "function" ]]

    MODULES="$BATS_TEST_TMPDIR/generated_modules"
    : > "$MODULES"
    set_phase() { :; }
    log_step() { :; }
    log_detail() { :; }
    log_info() { :; }
    log_error() { :; }
    log_warn() { :; }
    log_success() { :; }
    acfs_use_generated_category() { return 1; }
    acfs_legacy_module_selected() { [[ "$1" != "stack.mcp_agent_mail" ]]; }
    should_run_module() { return 0; }
    acfs_module_supports_family() { return 0; }
    binary_installed() { return 0; }
    install_asset() { return 1; }
    run_as_target() { return 0; }
    try_step() { shift; "$@"; }
    acfs_run_verified_upstream_script_as_target() { return 0; }
    acfs_run_verified_upstream_script_as_target_with_env() { return 0; }
    acfs_should_skip_module() { [[ " ${INSTALLED:-} " == *" $1 "* ]]; }

    declare -gA ACFS_MODULE_FUNC=()
    local module func
    for module in tools.herdr stack.nhm stack.caam stack.ru utils.mdwb; do
        func="acfs_generated_install_${module//./_}"
        ACFS_MODULE_FUNC[$module]="$func"
        eval "$func() {
            printf '%s\n' '$module' >> \"\$MODULES\"
            if [[ \" \${FAILING:-} \" == *' $module '* ]]; then
                ACFS_LAST_MODULE_FAILURE_REASON=checksum
                return 1
            fi
        }"
    done
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    ACFS_HOME="$TARGET_HOME/.acfs"
    ACFS_BIN_DIR="$TARGET_HOME/.local/bin"
    ACFS_LIB_DIR=""
    ACFS_MODULE_FAILURES=()

    local rc=0
    local -a ran=()
    install_stack_phase || rc=$?
    mapfile -t ran < "$MODULES"
    printf 'rc=%s\n' "$rc"
    printf 'failure=%s\n' "${ACFS_MODULE_FAILURES[@]}"
    printf 'module=%s\n' "${ran[@]}"
    printf 'reason=%s\n' "${ACFS_LAST_MODULE_FAILURE_REASON:-}"
}

@test "install_stack_phase installs caam and ru through their generated installers" {
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"module=stack.caam"* ]]
    [[ "$output" == *"module=stack.ru"* ]]
    [[ "$output" != *"failure=stack."* ]]
}

@test "install_stack_phase skips caam and ru when their installed_check passes" {
    INSTALLED="stack.caam stack.ru"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" != *"module=stack.caam"* ]]
    [[ "$output" != *"module=stack.ru"* ]]
    [[ "$output" == *"module=stack.nhm"* ]]
}

# acfs-2qhv: mdwb's generated installer skips aarch64 (its pre_install_check)
# and runs with ~/.local/bin first on PATH, so it keeps lang.uv's uv. The
# hand-written runner has neither, so install.sh must use the generated one.
@test "the generated mdwb installer skips aarch64 and puts ~/.local/bin first on PATH" {
    local body
    body="$(awk '/^acfs_generated_install_utils_mdwb\(\) \{$/,/^}$/' "$PROJECT_ROOT/scripts/generated/install_tools.sh")"
    [[ -n "$body" ]]
    [[ "$body" == *'[ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]'* ]]
    [[ "$body" == *"Chrome for Testing has no linux-arm64 build"* ]]
    [[ "$body" == *"'PATH='\"\$TARGET_HOME\"'/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin'"* ]]
}

@test "install.sh runs mdwb's installer only through its generated installer" {
    run grep -nE 'acfs_run_verified_upstream_script_as_target(_with_env)? "mdwb"' "$PROJECT_ROOT/install.sh"
    [[ "$status" -eq 1 ]]
    grep -q 'acfs_legacy_run_manifest_module "utils.mdwb"' "$PROJECT_ROOT/install.sh"
}

@test "acfs update skips mdwb on aarch64 and arm64, with the reason, and runs it elsewhere" {
    local block arch
    block="$(awk '/^    # MDWB \(Markdown Web Browser\)/,/^    esac$/' "$PROJECT_ROOT/scripts/lib/update.sh")"
    [[ -n "$block" ]]
    for arch in aarch64 arm64; do
        run env ARCH="$arch" bash -c 'uname() { printf "%s\n" "$ARCH"; }
            log_item() { printf "%s|%s|%s\n" "$@"; }
            run_cmd() { printf "run %s\n" "$*"; }
            eval "$1"' _ "$block"
        [[ "$status" -eq 0 ]]
        [[ "$output" == "skip|MDWB|Chrome for Testing has no linux-arm64 build"* ]]
        [[ "$output" != *"run "* ]]
    done
    run env ARCH=x86_64 bash -c 'uname() { printf "%s\n" "$ARCH"; }
        log_item() { printf "%s|%s|%s\n" "$@"; }
        run_cmd() { printf "run %s\n" "$*"; }
        eval "$1"' _ "$block"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "run MDWB update_run_verified_installer mdwb --yes" ]]
}

@test "install_stack_phase installs mdwb through its generated installer, and skips it when installed" {
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"module=utils.mdwb"* ]]
    INSTALLED="utils.mdwb"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"module=utils.mdwb"* ]]
}

@test "a failed caam install fails the stack phase and names stack.caam with its reason" {
    FAILING="stack.caam"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"failure=stack.caam (checksum)"* ]]
    [[ "$output" == *"module=stack.ru"* ]]
    # The reason is consumed, so no later failure is reported with it.
    [[ "$output" == *$'\nreason=' ]]
}
