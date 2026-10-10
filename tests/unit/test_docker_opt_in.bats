#!/usr/bin/env bats
#
# tools.docker is opt-in: the fork runs containers in Incus, and upstream's
# Docker in cli.modern is gone. These tests resolve the real selection from
# the generated manifest index, then run the shipped Docker block extracted
# from install.sh's legacy (Arch-family) CLI phase, with package installs,
# systemctl and usermod stubbed out.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CALLS="$BATS_TEST_TMPDIR/docker_calls"
}

# Resolves the selection with the given --only modules (none: a default
# install), with dependencies, and prints the modules that would run.
resolve_selection() {
    run bash -c '
        set -uo pipefail
        root="$1"; shift
        log_detail() { :; }
        log_warn() { :; }
        log_info() { :; }
        log_error() { printf "%s\n" "$*" >&2; }
        source "$root/scripts/generated/manifest_index.sh"
        ACFS_MANIFEST_INDEX_LOADED=true
        source "$root/scripts/lib/install_helpers.sh"
        ONLY_MODULES=()
        SKIP_MODULES=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --skip) SKIP_MODULES+=("$2"); shift 2 ;;
                *) ONLY_MODULES+=("$1"); shift ;;
            esac
        done
        ONLY_PHASES=()
        NO_DEPS=false
        acfs_resolve_selection >/dev/null || { echo "selection failed"; exit 3; }
        for m in "${ACFS_MODULES_IN_ORDER[@]}"; do
            should_run_module "$m" && printf "run %s\n" "$m"
        done
        exit 0
    ' _ "$PROJECT_ROOT" "$@"
}

# Runs the Docker block from install.sh on the given distro family after
# resolving the selection with the given --only modules.
run_docker_block() {
    local family="$1"
    shift
    run bash -c '
        set -uo pipefail
        root="$1"; calls="$2"; family="$3"; shift 3
        log_detail() { :; }
        log_warn() { :; }
        log_info() { :; }
        log_error() { :; }
        source "$root/scripts/generated/manifest_index.sh"
        ACFS_MANIFEST_INDEX_LOADED=true
        source "$root/scripts/lib/install_helpers.sh"
        ONLY_MODULES=("$@")
        ONLY_PHASES=()
        SKIP_MODULES=()
        NO_DEPS=true
        acfs_resolve_selection >/dev/null 2>&1 || { echo "selection failed"; exit 3; }

        ACFS_DISTRO_FAMILY="$family"
        TARGET_USER=alice
        SUDO=""
        try_step() { shift; "$@"; }
        command_exists() { [[ "$1" == systemctl ]]; }
        getent() { [[ "$1 $2" == "group docker" ]]; }
        acfs_arch_pkg_install() { printf "pacman %s\n" "$*" >> "$calls"; }
        systemctl() { printf "systemctl %s\n" "$*" >> "$calls"; }
        usermod() { printf "usermod %s\n" "$*" >> "$calls"; }
        acfs_legacy_run_manifest_module() { printf "manifest %s\n" "$1" >> "$calls"; }
        record_skipped_tool() { printf "skipped %s\n" "$1" >> "$calls"; }

        eval "docker_block() {
$(sed -n "/^    # Docker (tools.docker) is opt-in/,/^    fi$/p" "$root/install.sh")
}"
        # The block only enables the service when systemd is running.
        if [[ -d /run/systemd/system ]]; then systemd=yes; else systemd=no; fi
        docker_block
        echo "systemd=$systemd"
    ' _ "$PROJECT_ROOT" "$CALLS" "$family" "$@"
}

@test "a default install does not select tools.docker" {
    resolve_selection
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"run tools.docker"* ]]
    [[ "$output" == *"run cli.modern"* ]]
}

@test "selecting tools.docker selects it" {
    resolve_selection tools.docker
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"run tools.docker"* ]]
}

@test "selecting dsr brings tools.docker along" {
    resolve_selection stack.doodlestein_self_releaser
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"run tools.docker"* ]]
    [[ "$output" == *"run stack.doodlestein_self_releaser"* ]]
}

@test "selecting dsr while skipping tools.docker is an explicit error" {
    resolve_selection stack.doodlestein_self_releaser --skip tools.docker
    [[ "$status" -eq 3 ]]
    [[ "$output" == *"depends on skipped tools.docker"* ]]
}

@test "a default Arch install performs no Docker action" {
    run_docker_block arch
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
}

@test "a default Ubuntu legacy install performs no Docker action" {
    run_docker_block debian
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
}

@test "Arch with tools.docker selected installs, enables and adds the group" {
    run_docker_block arch tools.docker
    [[ "$status" -eq 0 ]]
    local systemd="${output##*systemd=}"
    run cat "$CALLS"
    [[ "${lines[0]}" == "pacman docker docker-compose" ]]
    if [[ "$systemd" == yes ]]; then
        [[ "$output" == *"systemctl enable --now docker.service"* ]]
    fi
    [[ "$output" == *"usermod -aG docker alice"* ]]
}

@test "Ubuntu legacy path with tools.docker selected runs the manifest module" {
    run_docker_block debian tools.docker
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == "manifest tools.docker" ]]
}

@test "the generated tools.docker installer installs Compose and adds the group" {
    run grep -c 'docker.io' "$PROJECT_ROOT/scripts/generated/install_tools.sh"
    [[ "$output" -ge 1 ]]
    run grep -c 'usermod -aG docker' "$PROJECT_ROOT/scripts/generated/install_tools.sh"
    [[ "$output" -ge 1 ]]
}
