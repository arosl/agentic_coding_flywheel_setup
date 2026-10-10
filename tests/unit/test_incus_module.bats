#!/usr/bin/env bats
#
# tools.incus is the fork's default container runtime. These tests resolve the
# real selection from the generated manifest index, run the shipped Incus
# block extracted from install.sh's legacy (Arch-family) CLI phase with
# package installs, systemctl and usermod stubbed out, and run the doctor's
# Incus check against a fake incus and /dev/kvm.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CALLS="$BATS_TEST_TMPDIR/incus_calls"
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

# Runs the Incus block from install.sh on the given distro family. With
# "skip" as the second argument, tools.incus is skipped; otherwise the
# selection is a default install. ROOT_SUBUID=yes (ROOT_SUBGID=yes) makes
# root already own a subordinate uid (gid) range.
run_incus_block() {
    local family="$1" skip="${2:-}"
    run bash -c '
        set -uo pipefail
        root="$1"; calls="$2"; family="$3"; skip="$4"
        log_detail() { :; }
        log_warn() { :; }
        log_info() { :; }
        log_error() { :; }
        source "$root/scripts/generated/manifest_index.sh"
        ACFS_MANIFEST_INDEX_LOADED=true
        source "$root/scripts/lib/install_helpers.sh"
        ONLY_MODULES=()
        ONLY_PHASES=()
        SKIP_MODULES=()
        [[ "$skip" == skip ]] && SKIP_MODULES=(tools.incus)
        NO_DEPS=false
        acfs_resolve_selection >/dev/null 2>&1 || { echo "selection failed"; exit 3; }

        ACFS_DISTRO_FAMILY="$family"
        TARGET_USER=alice
        SUDO=""
        try_step() { shift; "$@"; }
        command_exists() { [[ "$1" == systemctl ]]; }
        getent() { [[ "$1 $2" == "group incus-admin" ]]; }
        # Called with 2>/dev/null, which is not part of "$*".
        grep() {
            case "$*" in
                "-q ^root: /etc/subuid") [[ "${ROOT_SUBUID:-no}" == yes ]] ;;
                "-q ^root: /etc/subgid") [[ "${ROOT_SUBGID:-no}" == yes ]] ;;
                *) command grep "$@" ;;
            esac
        }
        acfs_arch_pkg_install() { printf "pacman %s\n" "$*" >> "$calls"; }
        systemctl() { printf "systemctl %s\n" "$*" >> "$calls"; }
        usermod() { printf "usermod %s\n" "$*" >> "$calls"; }
        acfs_legacy_run_manifest_module() { printf "manifest %s\n" "$1" >> "$calls"; }
        record_skipped_tool() { printf "skipped %s\n" "$1" >> "$calls"; }

        eval "incus_block() {
$(sed -n "/^    # Incus (tools.incus) is the default/,/^    fi$/p" "$root/install.sh")
}"
        # The block only enables the socket when systemd is running.
        if [[ -d /run/systemd/system ]]; then systemd=yes; else systemd=no; fi
        incus_block
        echo "systemd=$systemd"
    ' _ "$PROJECT_ROOT" "$CALLS" "$family" "$skip"
}

# Runs doctor.sh's check_incus with a fake incus (or none) and a fake KVM
# device path, and prints each check() call. db_groups is the user's entry in
# the group database (id -nG USER); proc_groups, this process's groups (id
# -nG), defaults to the same. The fake daemon answers `incus info` with
# FAKE_INFO_RC (default 0) and `incus storage list` with FAKE_STORAGE
# (default one pool) and `incus query /1.0` with FAKE_SERVER (default a 6.0.5
# server with the required API extensions and neither optional one);
# FAKE_CONTAINER=yes makes systemd-detect-virt report a container.
SERVER_605='{"api_extensions":["network_acl","disk_volume_subpath","container_syscall_intercept_sysinfo","projects_networks_restricted_access"],"environment":{"server_version":"6.0.5"}}'
run_check_incus() {
    local have_incus="$1" kvm="$2" db_groups="$3" proc_groups="${4:-$3}"
    local bin="$BATS_TEST_TMPDIR/bin"
    export FAKE_SERVER="${FAKE_SERVER-$SERVER_605}"
    mkdir -p "$bin"
    if [[ "$have_incus" == yes ]]; then
        cat > "$bin/incus" <<'FAKE'
#!/bin/sh
case "$1" in
    --version) echo 6.0.5 ;;
    info) exit "${FAKE_INFO_RC:-0}" ;;
    storage) printf '%s' "${FAKE_STORAGE-default,dir,,,CREATED}" ;;
    query) [ "$2" = /1.0 ] && printf '%s' "$FAKE_SERVER" ;;
esac
FAKE
        chmod 0755 "$bin/incus"
    fi
    run bash -c '
        set -uo pipefail
        # Named apart from check_incus locals, which would shadow them.
        root="$1"; bin="$2"; kvm="$3"; stub_db_groups="$4"; stub_proc_groups="$5"
        eval "$(sed -n "/^check_incus() {/,/^}/p" "$root/scripts/lib/doctor.sh")"
        eval "$(sed -n "/^ACFS_DOCTOR_INCUS_[A-Z]*_EXTENSIONS=/p; /^_acfs_doctor_incus_extensions() {/,/^}/p" "$root/scripts/lib/doctor.sh")"
        check() { printf "check %s|%s|%s|%s|%s\n" "$1" "$2" "$3" "${4:-}" "${5:-}"; }
        doctor_binary_path() { [[ -x "$bin/$1" ]] && printf "%s\n" "$bin/$1"; }
        get_version_line() { "$1" --version; }
        id() {
            if [[ "$*" == "-nG" ]]; then printf "%s\n" "$stub_proc_groups"; else printf "%s\n" "$stub_db_groups"; fi
        }
        systemd-detect-virt() { [[ "${FAKE_CONTAINER:-no}" == yes ]]; }
        export FAKE_INFO_RC FAKE_STORAGE FAKE_SERVER
        ACFS_DOCTOR_KVM_DEVICE="$kvm"
        check_incus
    ' _ "$PROJECT_ROOT" "$bin" "$kvm" "$db_groups" "$proc_groups"
}

@test "a default install selects tools.incus" {
    resolve_selection
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"run tools.incus"* ]]
    [[ "$output" != *"run tools.docker"* ]]
}

@test "tools.incus can be skipped" {
    resolve_selection --skip tools.incus
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"run tools.incus"* ]]
}

@test "a default Arch install installs Incus, enables its socket and adds the group" {
    run_incus_block arch
    [[ "$status" -eq 0 ]]
    local systemd="${output##*systemd=}"
    run cat "$CALLS"
    [[ "${lines[0]}" == "pacman incus" ]]
    [[ "$output" == *"usermod --add-subuids 1000000-1000999999 --add-subgids 1000000-1000999999 root"* ]]
    if [[ "$systemd" == yes ]]; then
        [[ "$output" == *"systemctl enable --now incus.socket"* ]]
    fi
    [[ "$output" == *"usermod -aG incus-admin alice"* ]]
}

@test "Arch leaves existing root subordinate id ranges alone" {
    ROOT_SUBUID=yes ROOT_SUBGID=yes run_incus_block arch
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" != *"--add-sub"* ]]
    [[ "$output" == *"usermod -aG incus-admin alice"* ]]
}

@test "Arch adds only the subordinate range root lacks" {
    ROOT_SUBUID=yes run_incus_block arch
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == *"usermod --add-subgids 1000000-1000999999 root"* ]]
    [[ "$output" != *"--add-subuids"* ]]
}

@test "a default Ubuntu legacy install runs the manifest module" {
    run_incus_block debian
    [[ "$status" -eq 0 ]]
    run cat "$CALLS"
    [[ "$output" == "manifest tools.incus" ]]
}

@test "skipping tools.incus performs no Incus action" {
    run_incus_block arch skip
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
    run_incus_block debian skip
    [[ "$status" -eq 0 ]]
    [[ ! -e "$CALLS" ]]
}

@test "the generated tools.incus installer installs incus and adds the group" {
    run grep -c 'install -y incus' "$PROJECT_ROOT/scripts/generated/install_tools.sh"
    [[ "$output" -ge 1 ]]
    run grep -c 'usermod -aG incus-admin' "$PROJECT_ROOT/scripts/generated/install_tools.sh"
    [[ "$output" -ge 1 ]]
}

@test "doctor: an initialised Incus with /dev/kvm passes for containers and VMs" {
    touch "$BATS_TEST_TMPDIR/kvm"
    run_check_incus yes "$BATS_TEST_TMPDIR/kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus|Incus (6.0.5)|pass|containers and VMs|"* ]]
    [[ "$output" == *"check tools.incus.daemon|Incus daemon|pass|reachable and initialised|"* ]]
}

@test "doctor: Incus without /dev/kvm passes as containers only" {
    run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus|Incus (6.0.5)|pass|containers only (no /dev/kvm, so no VMs)|"* ]]
}

@test "doctor: an installed but uninitialised Incus warns with incus admin init" {
    FAKE_STORAGE="" run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.daemon|Incus daemon|warn|reachable, but not initialised (no storage pool)|incus admin init --minimal"* ]]
}

@test "doctor: an unreachable daemon warns" {
    FAKE_INFO_RC=1 run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.daemon|Incus daemon|warn|daemon not reachable|"*"incus.socket"* ]]
}

@test "doctor: an unreachable daemon inside a container names security.nesting" {
    FAKE_INFO_RC=1 FAKE_CONTAINER=yes run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"daemon not reachable (inside a container, Incus needs security.nesting=true)"* ]]
}

@test "doctor: a user outside incus-admin gets a warning with the fix, and no daemon check" {
    run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice sudo"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.group|Incus access|warn|"*"not in incus-admin"*"usermod -aG incus-admin"* ]]
    [[ "$output" != *"tools.incus.daemon"* ]]
}

@test "doctor: a membership that needs a new login says so" {
    run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin" "alice sudo"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.group|Incus access|warn|"*"predates it|Log out and in again"* ]]
    [[ "$output" != *"tools.incus.daemon"* ]]
}

@test "doctor: root is never warned about incus-admin and gets the daemon check" {
    USER=root run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "root"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"tools.incus.group"* ]]
    [[ "$output" == *"check tools.incus.daemon|Incus daemon|pass|"* ]]
}

@test "doctor: no incus is a skip, not a failure" {
    run_check_incus no "$BATS_TEST_TMPDIR/kvm" "alice"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus|Incus|skip|not installed (optional)|"* ]]
}

@test "doctor: a server with the required API extensions passes and names the missing optional ones" {
    run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.extensions|Incus API extensions|pass|server 6.0.5 has what a swarm container needs; lacks the optional instance_limits_oom, container_disk_tmpfs|"* ]]
}

@test "doctor: a server with every API extension passes without a note" {
    FAKE_SERVER='{"api_extensions":["disk_volume_subpath","container_syscall_intercept_sysinfo","projects_networks_restricted_access","instance_limits_oom","container_disk_tmpfs"],"environment":{"server_version":"6.0.6"}}' \
        run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.extensions|Incus API extensions|pass|server 6.0.6 has what a swarm container needs|"* ]]
}

@test "doctor: a server without a required API extension warns by name, whatever its version" {
    FAKE_SERVER='{"api_extensions":["container_syscall_intercept_sysinfo"],"environment":{"server_version":"6.0.9"}}' \
        run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check tools.incus.extensions|Incus API extensions|warn|server 6.0.9 lacks disk_volume_subpath, projects_networks_restricted_access, which a swarm container needs|"*"zabbly"*"4EFC 5906 96CB 15B8 7C73 A3AD 82CC 8797 C838 DCFD"* ]]
    # The daemon check still runs after it.
    [[ "$output" == *"check tools.incus.daemon|Incus daemon|pass|"* ]]
}

@test "doctor: a server that reports no api_extensions is a skip" {
    for server in '' 'not json' '{"environment":{"server_version":"6.0.5"}}' '{"api_extensions":"x"}'; do
        FAKE_SERVER="$server" run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
        [[ "$status" -eq 0 ]]
        [[ "$output" == *"check tools.incus.extensions|Incus API extensions|skip|incus query /1.0 gave no api_extensions|"* ]]
    done
}

@test "doctor: an unreachable daemon gets no extension check" {
    FAKE_INFO_RC=1 run_check_incus yes "$BATS_TEST_TMPDIR/no-kvm" "alice incus-admin"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"tools.incus.extensions"* ]]
}

# The doctor, the installer and the launcher judge one server the same way.
@test "the doctor's and the installer's API extension lists are the launcher's" {
    local launcher_req launcher_opt
    launcher_req="$(sed -n 's/^REQUIRED_API_EXTENSIONS=(\(.*\))$/\1/p' "$PROJECT_ROOT/scripts/providers/incus.sh")"
    launcher_opt="$(sed -n 's/^OPTIONAL_API_EXTENSIONS=(\(.*\))$/\1/p' "$PROJECT_ROOT/scripts/providers/incus.sh")"
    [[ -n "$launcher_req" && -n "$launcher_opt" ]]
    run sed -n 's/^ACFS_DOCTOR_INCUS_REQUIRED_EXTENSIONS=(\(.*\))$/\1/p' "$PROJECT_ROOT/scripts/lib/doctor.sh"
    [[ "$output" == "$launcher_req" ]]
    run sed -n 's/^ACFS_DOCTOR_INCUS_OPTIONAL_EXTENSIONS=(\(.*\))$/\1/p' "$PROJECT_ROOT/scripts/lib/doctor.sh"
    [[ "$output" == "$launcher_opt" ]]
}

# Runs the generated installer's Zabbly step, as install.sh's root shell
# would, against stubs: incus answers `query /1.0` with FAKE_SERVER, and
# with FAKE_SERVER_AFTER once the stub apt-get has installed incus; curl
# writes a key file; gpg lists FAKE_GPG as the key's colon records; apt-get
# and curl log to $CALLS. /etc is $BATS_TEST_TMPDIR/etc, whose os-release
# says FAKE_OS (default ubuntu noble).
PINNED_KEY='pub:-:3072:1:82CC8797C838DCFD:1692748800:1913846400::-:::scSC::::::23::0:
fpr:::::::::4EFC590696CB15B87C73A3AD82CC8797C838DCFD:
uid:-::::1692748800::0::Zabbly Kernel Builds <info@zabbly.com>::::::::::0:
sub:-:3072:1:AAAAAAAAAAAAAAAA:1692748800:1913846400:::::e::::::23:
fpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBAAAAAAAAAAAAAAAA:'
SERVER_600='{"api_extensions":["container_syscall_intercept_sysinfo","projects_networks_restricted_access"],"environment":{"server_version":"6.0.0"}}'
SERVER_606='{"api_extensions":["disk_volume_subpath","container_syscall_intercept_sysinfo","projects_networks_restricted_access","instance_limits_oom"],"environment":{"server_version":"6.0.6"}}'
run_zabbly_step() {
    local bin="$BATS_TEST_TMPDIR/zbin" etc="$BATS_TEST_TMPDIR/etc" step="$BATS_TEST_TMPDIR/zabbly_step.sh"
    mkdir -p "$bin" "$etc/apt/sources.list.d"
    printf '%s\n' "${FAKE_OS:-ID=ubuntu
VERSION_CODENAME=noble}" > "$etc/os-release"
    sed -n "/^# acfs-summary: install Zabbly's lts-6.0 Incus/,/^INSTALL_TOOLS_INCUS\$/p" \
        "$PROJECT_ROOT/scripts/generated/install_tools.sh" | sed '$d' > "$step"
    [[ -s "$step" ]] || { echo "no Zabbly step in install_tools.sh"; return 1; }
    cat > "$bin/incus" <<'FAKE'
#!/bin/bash
[[ "$1 $2" == "query /1.0" ]] || exit 2
if [[ -e "$STATE/installed" ]]; then server="${FAKE_SERVER_AFTER-$SERVER_606}"; else server="$FAKE_SERVER"; fi
[[ -n "$server" ]] || exit 1
printf '%s\n' "$server"
FAKE
    cat > "$bin/curl" <<'FAKE'
#!/bin/bash
echo "curl $*" >> "$CALLS"
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { echo "armored key" > "$2"; }; shift; done
FAKE
    cat > "$bin/gpg" <<'FAKE'
#!/bin/bash
[[ -n "${GNUPGHOME:-}" ]] || exit 3
printf '%s\n' "$FAKE_GPG"
FAKE
    cat > "$bin/dpkg" <<'FAKE'
#!/bin/bash
[[ "$1" == --print-architecture ]] && echo amd64
FAKE
    cat > "$bin/apt-get" <<'FAKE'
#!/bin/bash
# stdin must not be the step's own script.
if [[ -t 0 ]] || read -r -t 0.1 _line; then echo "apt-get read stdin" >> "$CALLS"; fi
echo "apt-get DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-} $*" >> "$CALLS"
[[ " $* " == *" install -y incus "* ]] && touch "$STATE/installed"
exit 0
FAKE
    chmod 0755 "$bin"/*
    mkdir -p "$BATS_TEST_TMPDIR/state"
    run env PATH="$bin:$PATH" STATE="$BATS_TEST_TMPDIR/state" CALLS="$CALLS" ACFS_INCUS_ETC="$etc" \
        FAKE_SERVER="${FAKE_SERVER-$SERVER_600}" SERVER_606="$SERVER_606" FAKE_GPG="${FAKE_GPG-$PINNED_KEY}" \
        ${FAKE_SERVER_AFTER+FAKE_SERVER_AFTER="$FAKE_SERVER_AFTER"} \
        bash -c 'set -euo pipefail; (printf "%s\n" "set -euo pipefail"; cat "$1") | bash -s' _ "$step"
}

@test "installer: an archive Incus with the required API extensions stays, with no Zabbly repository" {
    FAKE_SERVER="$SERVER_605" run_zabbly_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"the archive's Incus has the API extensions a swarm container needs"* ]]
    [[ ! -e "$CALLS" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources" ]]
}

@test "installer: an Incus daemon that doesn't answer changes nothing" {
    for server in '' '{"environment":{}}'; do
        FAKE_SERVER="$server" run_zabbly_step
        [[ "$status" -eq 0 ]]
        [[ "$output" == *"the Incus daemon didn't answer"* ]]
        [[ ! -e "$CALLS" ]]
    done
}

@test "installer: Ubuntu 24.04's 6.0.0 moves to Zabbly's lts-6.0 with the pinned key" {
    run_zabbly_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"lacks disk_volume_subpath; installing Zabbly's lts-6.0 packages"* ]]
    [[ "$output" == *"Zabbly's Incus has the API extensions a swarm container needs"* ]]
    local etc="$BATS_TEST_TMPDIR/etc"
    [[ "$(cat "$etc/apt/keyrings/zabbly.asc")" == "armored key" ]]
    [[ "$(stat -c %a "$etc/apt/keyrings/zabbly.asc")" == 644 ]]
    [[ "$(cat "$etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources")" == "Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-6.0
Suites: noble
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/zabbly.asc" ]]
    run cat "$CALLS"
    [[ "${lines[0]}" == "curl -q --proto =https --proto-redir =https -fsSL https://pkgs.zabbly.com/key.asc -o "* ]]
    [[ "${lines[1]}" == "apt-get DEBIAN_FRONTEND=noninteractive -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold update" ]]
    [[ "${lines[2]}" == "apt-get DEBIAN_FRONTEND=noninteractive -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y incus" ]]
    [[ "${#lines[@]}" -eq 3 ]]
}

@test "installer: Ubuntu 26.04 gets the resolute suite" {
    FAKE_OS='ID=ubuntu
VERSION_CODENAME=resolute' run_zabbly_step
    [[ "$status" -eq 0 ]]
    grep -qx 'Suites: resolute' "$BATS_TEST_TMPDIR/etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources"
}

@test "installer: a key without the pinned fingerprint is refused before any repository is added" {
    local wrong="${PINNED_KEY/4EFC590696CB15B87C73A3AD82CC8797C838DCFD/0000590696CB15B87C73A3AD82CC8797C838DCFD}"
    local extra="$PINNED_KEY
pub:-:3072:1:1111111111111111:1692748800:::-:::scSC::::::23::0:
fpr:::::::::2222222222222222222222221111111111111111:"
    local fake
    for fake in "$wrong" "$extra" ""; do
        rm -f "$CALLS"
        FAKE_GPG="$fake" run_zabbly_step
        [[ "$status" -ne 0 ]]
        [[ "$output" == *"is not the key with fingerprint 4EFC590696CB15B87C73A3AD82CC8797C838DCFD"* ]]
        [[ ! -e "$BATS_TEST_TMPDIR/etc/apt/keyrings/zabbly.asc" ]]
        [[ ! -e "$BATS_TEST_TMPDIR/etc/apt/sources.list.d/zabbly-incus-lts-6.0.sources" ]]
        run cat "$CALLS"
        [[ "$output" != *apt-get* ]]
    done
}

@test "installer: outside Ubuntu 24.04 and 26.04 the archive's Incus stays" {
    local os
    for os in 'ID=ubuntu
VERSION_CODENAME=jammy' 'ID=debian
VERSION_CODENAME=noble' 'ID=ubuntu'; do
        FAKE_OS="$os" run_zabbly_step
        [[ "$status" -eq 0 ]]
        [[ "$output" == *"Incus lacks disk_volume_subpath, and ACFS sets up Zabbly's packages only on Ubuntu 24.04 and 26.04"* ]]
        [[ ! -e "$CALLS" ]]
    done
}

@test "installer: Zabbly's Incus that still lacks an extension, or doesn't answer, is reported" {
    FAKE_SERVER_AFTER="$SERVER_600" run_zabbly_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Zabbly's Incus still lacks disk_volume_subpath; the launcher refuses a container on it"* ]]
    rm -f "$BATS_TEST_TMPDIR/state/installed"
    FAKE_SERVER_AFTER="" run_zabbly_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Zabbly's Incus is installed, but its daemon didn't answer"* ]]
}

@test "the installer's API extension list is the launcher's" {
    local launcher_req
    launcher_req="$(sed -n 's/^REQUIRED_API_EXTENSIONS=(\(.*\))$/\1/p' "$PROJECT_ROOT/scripts/providers/incus.sh")"
    run sed -n 's/^required=(\(.*\))$/\1/p' "$PROJECT_ROOT/scripts/generated/install_tools.sh"
    [[ -n "$launcher_req" && "$output" == "$launcher_req" ]]
}
