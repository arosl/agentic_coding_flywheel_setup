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

# tools.lazydocker (acfs-fgd): upstream's module, opt-in here because it
# needs tools.docker.

# Runs install.sh's lazydocker block, as run_docker_block runs Docker's.
run_lazydocker_block() {
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
        acfs_arch_pkg_install() { printf "pacman %s\n" "$*" >> "$calls"; }
        acfs_legacy_run_manifest_module() { printf "manifest %s\n" "$1" >> "$calls"; }
        record_skipped_tool() { printf "skipped %s\n" "$1" >> "$calls"; }

        block="$(sed -n "/^    # Lazydocker (tools.lazydocker) needs Docker/,/^    fi$/p" "$root/install.sh")"
        [[ -n "$block" ]] || { echo "no lazydocker block in install.sh"; exit 4; }
        eval "lazydocker_block() {
$block
}"
        lazydocker_block
    ' _ "$PROJECT_ROOT" "$CALLS" "$family" "$@"
}

# Runs the generated tools.lazydocker install script on a fake <arch> host,
# where curl records its URL and downloads junk.
run_generated_lazydocker() {
    local arch="$1" bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\necho %s\n' "$arch" > "$bin/uname"
    cat > "$bin/curl" <<'EOF'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in -o) out="$2"; shift 2 ;; http*) printf '%s\n' "$1" >> "$CALLS"; shift ;; *) shift ;; esac
done
printf 'not the release tarball\n' > "$out"
EOF
    printf '#!/bin/bash\nprintf "tar %%s\\n" "$*" >> "$CALLS"\n' > "$bin/tar"
    chmod +x "$bin/uname" "$bin/curl" "$bin/tar"
    local script
    script="$(awk "/<<'INSTALL_TOOLS_LAZYDOCKER'\$/ { on = 1; next } on && /^INSTALL_TOOLS_LAZYDOCKER\$/ { exit } on" \
        "$PROJECT_ROOT/scripts/generated/install_tools.sh")"
    [[ -n "$script" ]]
    run env PATH="$bin:$PATH" CALLS="$CALLS" TMPDIR="$BATS_TEST_TMPDIR" bash -c "$script"
}

@test "a default install does not select tools.lazydocker" {
    resolve_selection
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"run tools.lazydocker"* ]]
}

@test "selecting tools.lazydocker brings tools.docker along" {
    resolve_selection tools.lazydocker
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"run tools.docker"* ]]
    [[ "$output" == *"run tools.lazydocker"* ]]
}

@test "selecting tools.lazydocker while skipping tools.docker is an explicit error" {
    resolve_selection tools.lazydocker --skip tools.docker
    [[ "$status" -eq 3 ]]
    [[ "$output" == *"depends on skipped tools.docker"* ]]
}

@test "a default install performs no lazydocker action on Arch or Ubuntu" {
    run_lazydocker_block arch
    [[ "$status" -eq 0 ]]
    run_lazydocker_block debian
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
}

@test "Arch with tools.lazydocker selected installs its package" {
    run_lazydocker_block arch tools.lazydocker
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == "pacman lazydocker" ]]
}

@test "Ubuntu legacy path with tools.lazydocker selected runs the manifest module" {
    run_lazydocker_block debian tools.lazydocker
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == "manifest tools.lazydocker" ]]
}

@test "the generated lazydocker installer refuses a download whose hash doesn't match" {
    run_generated_lazydocker x86_64
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Checksum failed"* ]]
    run cat "$CALLS"
    [[ "$output" == *"/v0.23.3/lazydocker_0.23.3_Linux_x86_64.tar.gz"* ]]
    [[ "$output" != *"tar "* ]]
}

@test "the generated lazydocker installer fetches the arm64 asset on an aarch64 host" {
    run_generated_lazydocker aarch64
    [[ "$status" -ne 0 ]]
    run cat "$CALLS"
    [[ "$output" == *"/lazydocker_0.23.3_Linux_arm64.tar.gz"* ]]
    [[ "$output" != *"aarch64"* ]]
}
