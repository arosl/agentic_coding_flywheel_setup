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
# acfs-ltqj: every other hand-written call must pass the runner, env and
# arguments of the module's generated installer. cass's TMPDIR, dcg's and
# rch's --easy-mode, and s2p's --skip-cass and env were missing.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# "<module>|<tool>|<runner>|<env>|<args>" for each generated installer's
# verified-installer call, with quotes removed. A call that doesn't run the
# staged file prints "?" as its runner.
generated_calls() {
    awk '
        /^acfs_generated_install_[a-z0-9_]+\(\) \{$/ { module = ""; tool = ""; next }
        /^    local module_id="/ { module = $0; sub(/^[^"]*"/, "", module); sub(/".*/, "", module) }
        /^ *local tool="/ { tool = $0; sub(/^[^"]*"/, "", tool); sub(/".*/, "", tool) }
        /^ *elif run_as_target_runner .*; then$/ {
            call = $0
            sub(/^ *elif run_as_target_runner /, "", call)
            sub(/; then$/, "", call)
            gsub(/["\047]/, "", call)
            n = split(call, word, " ")
            env = ""
            i = 1
            if (word[1] == "env") {
                for (i = 2; i <= n && word[i] ~ /=/; i++) env = env (env == "" ? "" : " ") word[i]
            }
            runner = word[i]
            if (word[i + 1] != "$verified_installer_file") runner = "?"
            args = ""
            for (i += 2; i <= n; i++) args = args (args == "" ? "" : " ") word[i]
            print module "|" tool "|" runner "|" env "|" args
        }
    ' "$PROJECT_ROOT"/scripts/generated/install_*.sh
}

# "<line>|<tool>|<runner>|<env>|<args>" for each call of install.sh's
# hand-written verified-installer runner, with quotes removed.
hand_written_calls() {
    grep -noE 'acfs_run_verified_upstream_script_as_target(_with_env)? "[^"]+" "[a-z]+"[^|;]*' \
        "$PROJECT_ROOT/install.sh" | awk '{
            line = $0
            number = line
            sub(/:.*/, "", number)
            sub(/^[0-9]+:/, "", line)
            gsub(/["\047]/, "", line)
            n = split(line, word, " ")
            env = ""
            i = 4
            if (word[1] ~ /_with_env$/) { env = word[4]; i = 5 }
            args = ""
            for (; i <= n; i++) args = args (args == "" ? "" : " ") word[i]
            print number "|" word[2] "|" word[3] "|" env "|" args
        }'
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

# Two calls differ on purpose. rano's TMPDIR comes from the hand-written
# runner itself, which stages rano on real disk (acfs-i5s0). fsfs's
# arguments are built at run time, and install.sh runs fsfs through
# _stack_run_fsfs_installer when stack.sh has it.
@test "each hand-written verified-installer call passes its generated installer's runner, env and arguments" {
    local -A gen_runner=() gen_env=() gen_args=()
    local module tool runner env args number failures="" count=0
    while IFS='|' read -r module tool runner env args; do
        gen_runner[$tool]="$runner"
        gen_env[$tool]="$env"
        gen_args[$tool]="$args"
    done < <(generated_calls)
    (( ${#gen_runner[@]} >= 40 ))
    grep -qF '[[ "$tool" == rano ]]' "$PROJECT_ROOT/install.sh"

    while IFS='|' read -r number tool runner env args; do
        count=$((count + 1))
        if [[ -z "${gen_runner[$tool]+set}" ]]; then
            failures+="install.sh:$number: $tool has no generated installer call"$'\n'
            continue
        fi
        [[ "$tool" != fsfs ]] || continue
        local want_env="${gen_env[$tool]}"
        [[ "$tool" != rano ]] || want_env="${want_env#'TMPDIR=$verified_installer_tmpdir'}"
        if [[ "$runner" != "${gen_runner[$tool]}" || "$env" != "$want_env" \
            || "$args" != "${gen_args[$tool]}" ]]; then
            failures+="install.sh:$number: $tool runs '$runner' env '$env' args '$args'; generated: '${gen_runner[$tool]}' env '$want_env' args '${gen_args[$tool]}'"$'\n'
        fi
    done < <(hand_written_calls)
    (( count >= 40 )) || failures+="only $count hand-written calls found"$'\n'
    printf '%s' "$failures"
    [[ -z "$failures" ]]
}

# Runs install.sh's install_stack_phase with every hand-written tool
# installed, Agent Mail deselected and fake generated installers that record
# their module. INSTALLED names the modules whose installed_check passes,
# MISSING the binaries that binary_installed doesn't find, FAILING the
# generated installers that fail, UNSELECTED the modules the plan lacks.
# Link steps are recorded as "link=<command>".
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
    should_run_module() { [[ " ${UNSELECTED:-} " != *" $1 "* ]]; }
    acfs_module_supports_family() { return 0; }
    binary_installed() { [[ " ${MISSING:-} " != *" $1 "* ]]; }
    install_asset() { return 1; }
    run_as_target() { return 0; }
    try_step() { shift; "$@"; }
    acfs_try_module_step() { shift 2; "$@"; }
    acfs_link_primary_bin_command() { printf 'link=%s\n' "$2" >> "$MODULES"; }
    acfs_run_verified_upstream_script_as_target() { return 0; }
    acfs_run_verified_upstream_script_as_target_with_env() { return 0; }
    acfs_should_skip_module() { [[ " ${INSTALLED:-} " == *" $1 "* ]]; }

    declare -gA ACFS_MODULE_FUNC=()
    local module func
    for module in tools.herdr stack.nhm stack.caam stack.ru utils.mdwb stack.cass utils.s2p \
        utils.rust_proxy utils.aadc utils.caut; do
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
    [[ "$body" == *"'PATH='\"\$TARGET_HOME\"'/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin'"* ]]
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

# acfs-ltqj: cass's generated installer stages downloads in its own TMPDIR,
# and s2p's passes --skip-cass and RU_NON_INTERACTIVE=1.
@test "install.sh runs cass's and s2p's installers only through their generated installers" {
    run grep -nE 'acfs_run_verified_upstream_script_as_target(_with_env)? "(cass|s2p)"' "$PROJECT_ROOT/install.sh"
    [[ "$status" -eq 1 ]]
    grep -q 'acfs_legacy_run_manifest_module "stack.cass"' "$PROJECT_ROOT/install.sh"
    grep -q 'acfs_legacy_run_manifest_module "utils.s2p"' "$PROJECT_ROOT/install.sh"
}

@test "install_stack_phase installs cass and a missing s2p through their generated installers" {
    MISSING="s2p"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"module=stack.cass"* ]]
    [[ "$output" == *"module=utils.s2p"* ]]
}

@test "install_stack_phase skips cass when its installed_check passes, and s2p when its binary is there" {
    INSTALLED="stack.cass"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" != *"module=stack.cass"* ]]
    [[ "$output" != *"module=utils.s2p"* ]]
}

@test "a failed cass install fails the stack phase and names stack.cass with its reason" {
    FAILING="stack.cass"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"failure=stack.cass (checksum)"* ]]
}

# acfs-fae9: modules with no legacy steps run through their generated
# installer when the plan has them, so --only on the legacy path (Arch, or
# ACFS_USE_GENERATED=0) installs them and the phase verify judges that.
@test "install_stack_phase installs rust_proxy, aadc and caut through their generated installers when selected" {
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"module=utils.rust_proxy"* ]]
    [[ "$output" == *"module=utils.aadc"* ]]
    [[ "$output" == *"module=utils.caut"* ]]
}

@test "install_stack_phase leaves rust_proxy, aadc and caut alone when the plan lacks them" {
    UNSELECTED="utils.rust_proxy utils.aadc utils.caut"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" != *"module=utils.rust_proxy"* ]]
    [[ "$output" != *"module=utils.aadc"* ]]
    [[ "$output" != *"module=utils.caut"* ]]
}

@test "a selected aadc whose generated installer fails fails the stack phase and names it" {
    FAILING="utils.aadc"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"failure=utils.aadc (checksum)"* ]]
}

@test "grok and opencode found outside ACFS's bin dir are linked even when already installed" {
    mkdir -p "$BATS_TEST_TMPDIR/home/.grok/bin" "$BATS_TEST_TMPDIR/home/.opencode/bin"
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/home/.grok/bin/grok"
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/home/.opencode/bin/opencode"
    chmod +x "$BATS_TEST_TMPDIR/home/.grok/bin/grok" "$BATS_TEST_TMPDIR/home/.opencode/bin/opencode"
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"module=link=grok"* ]]
    [[ "$output" == *"module=link=opencode"* ]]
}

@test "grok and opencode already in ACFS's bin dir are not linked again" {
    mkdir -p "$BATS_TEST_TMPDIR/home/.grok/bin" "$BATS_TEST_TMPDIR/home/.opencode/bin" "$BATS_TEST_TMPDIR/home/.local/bin"
    local f
    for f in .grok/bin/grok .opencode/bin/opencode .local/bin/grok .local/bin/opencode; do
        printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/home/$f"
        chmod +x "$BATS_TEST_TMPDIR/home/$f"
    done
    run run_stack_phase
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"module=link="* ]]
}

@test "the legacy agents phase runs gemini through its generated installer when the plan has it" {
    local body
    body="$(sed -n '/^install_agents_phase() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    grep -q 'if should_run_module "agents.gemini"; then' <<<"$body"
    grep -q 'acfs_legacy_run_manifest_module "agents.gemini"' <<<"$body"
}

@test "the legacy CLI phase runs ssh_keepalive's generated installer whenever it is selected (acfs-htdm)" {
    local body
    body="$(sed -n '/^install_cli_tools() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    grep -q 'acfs_legacy_module_selected "network.ssh_keepalive"' <<<"$body"
    grep -q 'acfs_should_skip_module "network.ssh_keepalive"' <<<"$body"
    grep -q 'acfs_legacy_run_manifest_module "network.ssh_keepalive"' <<<"$body"
    ! grep -q 'acfs_module_explicitly_selected "network.ssh_keepalive"' <<<"$body" \
        || fail "keepalive still waits to be named"
}
