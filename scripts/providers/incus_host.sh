#!/usr/bin/env bash
# ============================================================
# ACFS swarm setup on the hypervisor (incus.sh host-setup)
#
# Prepares the hypervisor (the physical machine that runs Incus) once, as an
# Incus admin there: the storage pool at the location you give, the
# policy-only profile acfs-swarm for ACFS containers, the restricted project
# acfs-tests on its own bridge acfstest0, the egress ACLs acfs-swarm-egress
# and acfs-vm-egress, and optionally a client certificate restricted to
# acfs-tests. It records the result in
# ${XDG_CONFIG_HOME:-~/.config}/acfs/incus.env, which incus.sh reads.
#
# The storage location is required and has no default: it is prompted for
# on a terminal and refused when missing otherwise. It is an existing Incus
# pool or a directory; ACFS formats no disks and adds no swap, because the
# hypervisor's disks and swap are a hosting decision.
#
# Re-running it is safe: what is absent is created, and what exists is
# checked against what these options would create and never changed; a
# difference stops the run and names the object. It never deletes anything.
#
# Progress goes to stderr; stdout stays empty.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

SWARM_PROFILE="acfs-swarm"
TEST_PROJECT="acfs-tests"
TEST_BRIDGE="acfstest0"
SWARM_ACL="acfs-swarm-egress"
VM_ACL="acfs-vm-egress"
# The same ranges, rule and description as incus.sh's acfs-vm-egress, so that
# the launcher finds this ACL as its own.
VM_ACL_DESCRIPTION="ACFS instances: no egress to private, CGNAT or link-local ranges"
SWARM_ACL_DESCRIPTION="ACFS containers: the hypervisor's Incus API, SSH to the test instances and the rch workers; no other private ranges"
PRIVATE_V4=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16)
PRIVATE_V6=(fc00::/7 fe80::/10)
SWARM_API_PORT=8443

# Plan 3.1's pins and the operator's CPU ruling (2026-10-10): an ACFS
# container sees every hypervisor thread (no limits.cpu) and yields under
# contention. Incus writes cpu.weight = allowance% - (10 - priority), here
# 30 - 10 = 20, against the default 100 of the hypervisor's own services.
SWARM_PROFILE_CONFIG=(
    security.privileged=false
    security.nesting=false
    security.idmap.isolated=true
    security.syscalls.intercept.sysinfo=true
    limits.cpu.priority=0
    limits.cpu.allowance=30%
    limits.processes=30000
    limits.kernel.nofile=1048576
    boot.autostart=true
    boot.host_shutdown_timeout=120
)
TEST_PROJECT_CONFIG=(
    features.images=true
    features.profiles=true
    features.storage.volumes=true
    features.networks=false
    restricted=true
    restricted.containers.nesting=block
    restricted.containers.privilege=isolated
    restricted.containers.interception=block
    restricted.devices.unix-char=block
    restricted.devices.gpu=block
    restricted.devices.disk=managed
    restricted.devices.nic=managed
    "restricted.networks.access=$TEST_BRIDGE"
    restricted.images.servers=images.linuxcontainers.org
    restricted.snapshots=block
    restricted.backups=block
)
# Its limits are set at creation and when unset; values the operator changed
# later are left as they are.
TEST_PROJECT_LIMITS=(
    limits.instances=6
    limits.cpu=16
    limits.memory=32GiB
    limits.disk=200GiB
)
# A project with limits.cpu, limits.memory and limits.disk refuses instances
# that don't set them, so its default profile sets incus.sh's sizes.
TEST_PROFILE_CONFIG=(limits.cpu=4 limits.memory=8GiB)
TEST_ROOT_SIZE="40GiB"
REQUIRED_API_EXTENSIONS=(projects_networks_restricted_access container_syscall_intercept_sysinfo)

usage() {
    cat <<'EOF'
Usage: scripts/providers/incus.sh host-setup --storage <pool|directory> [options]

Prepares the hypervisor (the machine running Incus) for ACFS containers, as
an Incus admin there, and records the result in
${XDG_CONFIG_HOME:-~/.config}/acfs/incus.env.

  --storage WHERE        Required, no default. An existing Incus storage pool's
                         name, or a directory: on btrfs it becomes a btrfs pool,
                         elsewhere a dir pool, whose size limits are enforced
                         only on ext4 or XFS with project quotas on. Every
                         container's root, data and state volumes go there.
                         ACFS formats no disks.
  --pool-name NAME       The pool made from a directory (default: acfs).
  --memory SIZE          The containers' memory limit (e.g. 96GiB); none without
                         it. Soft (the container is throttled, nothing is killed)
                         when the hypervisor has swap, hard (killed inside the
                         container at the limit) when it has none.
  --memory-enforce soft|hard
                         Overrides that choice.
  --rch-worker ADDR      An IPv4 address of an rch build worker that the
                         containers may reach over SSH (repeatable).
  --client-cert FILE     Trust this client certificate, restricted to acfs-tests.
  --client-name NAME     The name it is trusted under (required with --client-cert).

ACFS containers reach the internet, and of private addresses only the
hypervisor's Incus API (8443 on their bridge's gateway), SSH and ping to the
test instances on acfstest0, and SSH to the rch workers.

Re-running is safe: absent objects are created, and existing ones are checked
and never changed. See scripts/providers/incus.md.
EOF
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# Every incus call goes through here: the local daemon only, whatever the
# default remote, and never the caller's stdin.
incus_run() {
    incus "$@" --force-local </dev/null
}

# The one form whose stdin is meant: an object's YAML.
incus_stdin() {
    incus "$@" --force-local
}

# Succeeds when the API path exists and prints its JSON.
incus_get() {
    incus_run query "$1" 2>/dev/null
}

storage=""
pool_name="acfs"
memory=""
memory_enforce=""
rch_workers=()
client_cert=""
client_name=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --storage|--pool-name|--memory|--memory-enforce|--rch-worker|--client-cert|--client-name)
                [[ -n "${2:-}" ]] || die "$1 needs a value" 2
                case "$1" in
                    --storage) storage="$2" ;;
                    --pool-name) pool_name="$2" ;;
                    --memory) memory="$2" ;;
                    --memory-enforce) memory_enforce="$2" ;;
                    --rch-worker) rch_workers+=("$2") ;;
                    --client-cert) client_cert="$2" ;;
                    --client-name) client_name="$2" ;;
                esac
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" 2 ;;
        esac
    done

    [[ "$pool_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid --pool-name '$pool_name'" 2
    [[ -z "$memory" || "$memory" =~ ^[1-9][0-9]*(MiB|GiB|TiB)$ ]] || die "--memory is a size such as 96GiB, not '$memory'" 2
    [[ -z "$memory_enforce" || "$memory_enforce" == soft || "$memory_enforce" == hard ]] \
        || die "--memory-enforce is soft or hard, not '$memory_enforce'" 2
    [[ -z "$memory_enforce" || -n "$memory" ]] || die "--memory-enforce needs --memory" 2
    local addr
    for addr in "${rch_workers[@]}"; do
        ipv4_to_int "$addr" >/dev/null || die "--rch-worker $addr: not an IPv4 address" 2
    done
    if [[ -n "$client_cert" || -n "$client_name" ]]; then
        [[ -n "$client_cert" && -n "$client_name" ]] || die "--client-cert and --client-name go together" 2
        [[ -f "$client_cert" && -r "$client_cert" ]] || die "--client-cert $client_cert: not a readable file" 2
        [[ "$client_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid --client-name '$client_name'" 2
    fi
}

# The storage location: required, prompted for on a terminal only.
require_storage() {
    [[ -z "$storage" ]] || return 0
    [[ -t 0 ]] || die "--storage is required: the storage location has no default (an Incus pool or a directory)" 2
    printf 'Storage location for ACFS containers (an Incus pool or a directory): ' >&2
    IFS= read -r storage || true
    [[ -n "$storage" ]] || die "no storage location given" 2
}

require_commands() {
    local cmd
    for cmd in incus jq findmnt; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required on the hypervisor" 2
    done
    [[ -z "$memory" ]] || command -v swapon >/dev/null 2>&1 || die "swapon is required for --memory" 2
    [[ -z "$client_cert" ]] || command -v openssl >/dev/null 2>&1 || die "openssl is required for --client-cert" 2
}

server_json=""

check_server() {
    server_json="$(incus_get /1.0)" || die "cannot reach the local Incus daemon; run this on the hypervisor as a member of incus-admin" 1
    jq -e '.auth == "trusted"' <<<"$server_json" >/dev/null \
        || die "the local Incus daemon doesn't trust this user; host setup needs an Incus admin (the incus-admin group)" 1
    local ext
    for ext in "${REQUIRED_API_EXTENSIONS[@]}"; do
        jq -e --arg ext "$ext" '.api_extensions | index($ext) != null' <<<"$server_json" >/dev/null \
            || die "this Incus lacks the API extension $ext; ACFS containers need Incus 6.0.6 or later" 1
    done
}

driver_supported() {
    jq -e --arg d "$1" '[.environment.storage_supported_drivers[]?.Name] | index($d) != null' <<<"$server_json" >/dev/null
}

# The memory keys for --memory. Without swap on the hypervisor a soft limit
# stalls a container that overruns it with nothing to reclaim, so the limit
# is hard there unless --memory-enforce says otherwise.
add_memory_config() {
    [[ -n "$memory" ]] || return 0
    local swap="false" enforce
    [[ -z "$(swapon --show=NAME --noheadings 2>/dev/null)" ]] || swap="true"
    if [[ -n "$memory_enforce" ]]; then
        enforce="$memory_enforce"
    elif [[ "$swap" == true ]]; then
        enforce=soft
    else
        enforce=hard
    fi
    if [[ "$enforce" == soft && "$swap" == false ]]; then
        log_warn "The hypervisor has no swap: a container over its soft limit stalls instead of reclaiming"
    fi
    log_info "Memory: $memory, $enforce (the hypervisor has $([[ "$swap" == true ]] && echo swap || echo "no swap"))"
    SWARM_PROFILE_CONFIG+=("limits.memory=$memory" "limits.memory.enforce=$enforce" "limits.memory.swap=$swap")
}

# ------------------------------------------------------------
# IPv4 arithmetic, for the ACL's reject ranges.
# ------------------------------------------------------------

ipv4_to_int() {
    local a b c d
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
    ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255)) || return 1
    printf '%d\n' $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

int_to_ipv4() {
    printf '%d.%d.%d.%d\n' $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255))
}

# Prints "<network int> <prefix>" for a CIDR, host bits cleared.
cidr_parse() {
    local ip prefix n
    ip="${1%/*}"
    prefix="${1#*/}"
    [[ "$1" == */* && "$prefix" =~ ^[0-9]{1,2}$ ]] && ((prefix <= 32)) || return 1
    n="$(ipv4_to_int "$ip")" || return 1
    printf '%d %d\n' $((n & (prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))) "$prefix"
}

# cidr_subtract <cidr> <exclude cidr>...: prints, one per line, the CIDRs that
# cover <cidr> without any of the excluded ones.
cidr_subtract() {
    local base="$1" n p ex en ep size half overlaps=""
    shift
    read -r n p < <(cidr_parse "$base")
    size=$((1 << (32 - p)))
    for ex in "$@"; do
        read -r en ep < <(cidr_parse "$ex")
        if ((ep <= p)); then
            # The excluded block is at least as large: it covers all or nothing.
            (((n >> (32 - ep)) != (en >> (32 - ep)))) || return 0
        elif ((en >= n && en < n + size)); then
            overlaps+=" $ex"
        fi
    done
    if [[ -z "$overlaps" ]]; then
        printf '%s/%d\n' "$(int_to_ipv4 "$n")" "$p"
        return 0
    fi
    half=$((size / 2))
    # shellcheck disable=SC2086 # $overlaps is a space-separated CIDR list
    cidr_subtract "$(int_to_ipv4 "$n")/$((p + 1))" $overlaps
    # shellcheck disable=SC2086
    cidr_subtract "$(int_to_ipv4 $((n + half)))/$((p + 1))" $overlaps
}

# "10.1.2.1/24" -> "10.1.2.0/24"
cidr_network() {
    local n p
    read -r n p < <(cidr_parse "$1") || return 1
    printf '%s/%d\n' "$(int_to_ipv4 "$n")" "$p"
}

join_by() {
    local IFS="$1"
    shift
    printf '%s\n' "$*"
}

# ------------------------------------------------------------
# The storage pool: an existing pool, or one made from a directory with the
# driver its filesystem supports (the operator, 2026-10-10).
# ------------------------------------------------------------

pool_source=""

existing_pool_source() {
    jq -r '.config.source // ""' <<<"$1"
}

ensure_pool() {
    local json fs fstype options driver

    # An existing pool named by --storage is used as it is.
    if [[ "$storage" != */* ]]; then
        json="$(incus_get "/1.0/storage-pools/$storage")" \
            || die "--storage $storage: no Incus storage pool by that name; give a pool or an absolute directory path" 2
        pool_name="$storage"
        pool_source="$(existing_pool_source "$json")"
        log_info "Using the existing storage pool $pool_name ($(jq -r '.driver' <<<"$json"))"
        return 0
    fi

    [[ "$storage" == /* ]] || die "--storage $storage: give a pool name or an absolute directory path" 2
    [[ ! -b "$storage" ]] || die "--storage $storage is a block device; ACFS formats no disks. Make a filesystem or an Incus pool on it yourself, and pass that" 2
    [[ -d "$storage" ]] || die "--storage $storage: not a directory" 2

    fs="$(findmnt -n -o FSTYPE,OPTIONS --target "$storage" 2>/dev/null | head -n 1)"
    fstype="${fs%% *}"
    options="${fs#* }"
    if [[ "$fstype" == btrfs ]]; then
        driver=btrfs
    else
        driver=dir
        if [[ ! ( "$fstype" == ext4 || "$fstype" == xfs ) \
                || ! ( ",$options," == *,prjquota,* || ",$options," == *,pquota,* ) ]]; then
            log_warn "$storage is on ${fstype:-an unknown filesystem} without project quotas: the containers' volume sizes there are not enforced (ext4: tune2fs -O project and prjquota; XFS: pquota)"
        fi
    fi

    if json="$(incus_get "/1.0/storage-pools/$pool_name")"; then
        [[ "$(jq -r '.driver' <<<"$json")" == "$driver" && "$(existing_pool_source "$json")" == "$storage" ]] \
            || die "storage pool $pool_name exists with driver $(jq -r '.driver' <<<"$json") and source '$(existing_pool_source "$json")', not $driver on $storage; pass that pool's name to --storage, or choose another --pool-name" 1
        log_info "Using the existing storage pool $pool_name ($driver on $storage)"
    else
        driver_supported "$driver" || die "this Incus has no $driver storage driver" 1
        log_step "Creating storage pool $pool_name ($driver, source=$storage)"
        incus_run storage create "$pool_name" "$driver" "source=$storage" >/dev/null \
            || die "could not create storage pool $pool_name" 1
    fi
    pool_source="$storage"
}

# ------------------------------------------------------------
# Profiles and the project: created when absent, checked when present.
# ------------------------------------------------------------

# unset_keys <json> <key=value>...: prints the pairs whose key is unset there.
unset_keys() {
    local json="$1" kv
    shift
    for kv in "$@"; do
        jq -e --arg k "${kv%%=*}" '(.config[$k] // "") != ""' <<<"$json" >/dev/null || printf '%s\n' "$kv"
    done
}

# set_unset <what> <json> <incus set command...> -- <key=value>...: sets the
# keys that are unset, which resumes an interrupted run. A key set to another
# value is never changed: the run stops and names it.
set_unset() {
    local what="$1" json="$2" command=() missing=() bad=() kv key want have
    shift 2
    while [[ "$1" != -- ]]; do command+=("$1"); shift; done
    shift
    for kv in "$@"; do
        key="${kv%%=*}"
        want="${kv#*=}"
        have="$(jq -r --arg k "$key" '.config[$k] // ""' <<<"$json")"
        if [[ -z "$have" ]]; then
            missing+=("$kv")
        elif [[ "$have" != "$want" ]]; then
            bad+=("$key is $have, not $want")
        fi
    done
    if ((${#bad[@]} > 0)); then
        for kv in "${bad[@]}"; do log_error "$what: $kv"; done
        die "$what exists with other settings; it is left as it is. Fix it with incus, then re-run" 1
    fi
    ((${#missing[@]} > 0)) || return 0
    log_step "$what: setting ${missing[*]}"
    incus_run "${command[@]}" "${missing[@]}" || die "could not configure $what" 1
}

ensure_swarm_profile() {
    local json
    if ! json="$(incus_get "/1.0/profiles/$SWARM_PROFILE")"; then
        log_step "Creating profile $SWARM_PROFILE (policy only: unprivileged, isolated idmap, no nesting, low CPU priority, sysinfo intercept)"
        incus_run profile create "$SWARM_PROFILE" >/dev/null || die "could not create profile $SWARM_PROFILE" 1
        json="$(incus_get "/1.0/profiles/$SWARM_PROFILE")" || die "could not read profile $SWARM_PROFILE" 1
    fi
    jq -e '(.devices // {}) == {}' <<<"$json" >/dev/null \
        || die "profile $SWARM_PROFILE has devices; it holds policy only, and each container's devices are its own" 1
    set_unset "profile $SWARM_PROFILE" "$json" profile set "$SWARM_PROFILE" -- "${SWARM_PROFILE_CONFIG[@]}"
    log_info "Profile $SWARM_PROFILE is in place"
}

ensure_test_bridge() {
    local json
    if json="$(incus_get "/1.0/networks/$TEST_BRIDGE")"; then
        jq -e '.managed == true and .type == "bridge"' <<<"$json" >/dev/null \
            || die "network $TEST_BRIDGE exists and isn't a managed bridge" 1
        log_info "Bridge $TEST_BRIDGE is in place"
    else
        log_step "Creating bridge $TEST_BRIDGE for the test instances (IPv4 with NAT, no IPv6)"
        incus_run network create "$TEST_BRIDGE" --type=bridge \
            ipv4.address=auto ipv4.nat=true ipv6.address=none >/dev/null \
            || die "could not create network $TEST_BRIDGE" 1
        json="$(incus_get "/1.0/networks/$TEST_BRIDGE")" || die "could not read network $TEST_BRIDGE" 1
    fi
    test_bridge_cidr="$(jq -r '.config["ipv4.address"] // ""' <<<"$json")"
    cidr_parse "$test_bridge_cidr" >/dev/null || die "network $TEST_BRIDGE has no IPv4 address (ipv4.address='$test_bridge_cidr')" 1
}

ensure_test_project() {
    local json q="?project=$TEST_PROJECT" profile
    if json="$(incus_get "/1.0/projects/$TEST_PROJECT")"; then
        set_unset "project $TEST_PROJECT" "$json" project set "$TEST_PROJECT" -- "${TEST_PROJECT_CONFIG[@]}"
        log_info "Project $TEST_PROJECT is in place"
    else
        log_step "Creating project $TEST_PROJECT (restricted; containers isolated, no nesting, only $TEST_BRIDGE)"
        local args=() kv
        for kv in "${TEST_PROJECT_CONFIG[@]}" "${TEST_PROJECT_LIMITS[@]}"; do args+=(-c "$kv"); done
        incus_run project create "$TEST_PROJECT" "${args[@]}" >/dev/null \
            || die "could not create project $TEST_PROJECT" 1
        json="$(incus_get "/1.0/projects/$TEST_PROJECT")" || die "could not read project $TEST_PROJECT" 1
    fi
    local limits=()
    mapfile -t limits < <(unset_keys "$json" "${TEST_PROJECT_LIMITS[@]}")
    if ((${#limits[@]} > 0)); then
        incus_run project set "$TEST_PROJECT" "${limits[@]}" || die "could not set limits on project $TEST_PROJECT" 1
    fi

    # Its default profile: root on the pool and a NIC on acfstest0 behind the
    # test ACL. Each piece is added when missing, so an interrupted run resumes.
    profile="$(incus_get "/1.0/profiles/default$q")" || die "could not read project $TEST_PROJECT's default profile" 1
    if ! jq -e '.devices.root' <<<"$profile" >/dev/null; then
        log_step "Project $TEST_PROJECT: root disk on pool $pool_name ($TEST_ROOT_SIZE)"
        incus_run profile device add default root disk path=/ "pool=$pool_name" "size=$TEST_ROOT_SIZE" \
            --project "$TEST_PROJECT" >/dev/null || die "could not add the root disk to $TEST_PROJECT's default profile" 1
    elif ! jq -e --arg p "$pool_name" '.devices.root.pool == $p' <<<"$profile" >/dev/null; then
        die "project $TEST_PROJECT's default profile has its root disk on pool $(jq -r '.devices.root.pool' <<<"$profile"), not $pool_name" 1
    fi
    if ! jq -e '.devices.eth0' <<<"$profile" >/dev/null; then
        log_step "Project $TEST_PROJECT: NIC on $TEST_BRIDGE with ACL $VM_ACL"
        incus_run profile device add default eth0 nic "network=$TEST_BRIDGE" "security.acls=$VM_ACL" \
            security.acls.default.egress.action=allow security.acls.default.ingress.action=allow \
            --project "$TEST_PROJECT" >/dev/null || die "could not add the NIC to $TEST_PROJECT's default profile" 1
    elif ! jq -e --arg n "$TEST_BRIDGE" --arg a "$VM_ACL" \
            '.devices.eth0.network == $n and .devices.eth0["security.acls"] == $a' <<<"$profile" >/dev/null; then
        die "project $TEST_PROJECT's default profile has a NIC that isn't on $TEST_BRIDGE behind $VM_ACL" 1
    fi
    # Limits the operator changed there are theirs: only unset ones are set.
    local missing=()
    mapfile -t missing < <(unset_keys "$profile" "${TEST_PROFILE_CONFIG[@]}")
    if ((${#missing[@]} > 0)); then
        incus_run profile set default "${missing[@]}" --project "$TEST_PROJECT" \
            || die "could not set limits on $TEST_PROJECT's default profile" 1
    fi
}

# ------------------------------------------------------------
# The egress ACLs. Incus applies every reject before any allow, so the swarm
# ACL's reject ranges leave out what the containers may reach, and the
# narrower rejects then close the ports they may not. The bridge's DHCP and
# DNS on the gateway still work: Incus puts those baseline rules before any
# ACL's.
# ------------------------------------------------------------

# The bridge the containers' NIC uses: the default profile's.
swarm_gateway() {
    local profile network json address
    profile="$(incus_get /1.0/profiles/default)" || die "could not read the default profile" 1
    network="$(jq -r '[.devices[] | select(.type == "nic") | .network // ""][0] // ""' <<<"$profile")"
    [[ -n "$network" ]] || die "the default profile has no NIC on an Incus network; the swarm ACL needs a managed bridge" 1
    json="$(incus_get "/1.0/networks/$network")" || die "could not read network $network" 1
    jq -e '.managed == true and .type == "bridge"' <<<"$json" >/dev/null \
        || die "network $network isn't a managed bridge; the swarm ACL needs one" 1
    address="$(jq -r '.config["ipv4.address"] // ""' <<<"$json")"
    cidr_parse "$address" >/dev/null || die "network $network has no IPv4 address (ipv4.address='$address')" 1
    printf '%s\n' "${address%/*}"
}

# rule <action> <destination> [protocol] [ports]: one rule as JSON.
rule() {
    jq -nc --arg a "$1" --arg d "$2" --arg p "${3:-}" --arg port "${4:-}" \
        '{action: $a, destination: $d, state: "enabled"}
         + (if $p == "" then {} else {protocol: $p} end)
         + (if $port == "" then {} else {destination_port: $port} end)'
}

swarm_acl_rules() {
    local gateway="$1" test_net test_gateway worker excluded=() reject=() workers=() cidr
    test_net="$(cidr_network "$test_bridge_cidr")"
    test_gateway="${test_bridge_cidr%/*}"
    excluded=("$gateway/32" "$test_net")
    for worker in "${rch_workers[@]}"; do
        excluded+=("$worker/32")
        workers+=("$worker/32")
    done
    for cidr in "${PRIVATE_V4[@]}"; do
        while IFS= read -r cidr; do reject+=("$cidr"); done < <(cidr_subtract "$cidr" "${excluded[@]}")
    done
    reject+=("${PRIVATE_V6[@]}")

    {
        rule reject "$(join_by , "${reject[@]}")"
        rule reject "$gateway/32" tcp "1-$((SWARM_API_PORT - 1)),$((SWARM_API_PORT + 1))-65535"
        rule reject "$gateway/32" udp
        rule reject "$test_gateway/32"
        rule reject "$test_net" tcp 1-21,23-65535
        rule reject "$test_net" udp
        rule allow "$gateway/32" tcp "$SWARM_API_PORT"
        rule allow "$test_net" tcp 22
        rule allow "$test_net" icmp4
        if ((${#workers[@]} > 0)); then
            rule reject "$(join_by , "${workers[@]}")" tcp 1-21,23-65535
            rule reject "$(join_by , "${workers[@]}")" udp
            rule allow "$(join_by , "${workers[@]}")" tcp 22
        fi
    } | jq -sc .
}

vm_acl_rules() {
    rule reject "$(join_by , "${PRIVATE_V4[@]}" "${PRIVATE_V6[@]}")" | jq -sc .
}

# The rules compared as sets, without the fields Incus fills in empty.
normalized_rules() {
    jq -c 'map(with_entries(select(.value != "" and .value != null and .key != "description")))
           | map(tojson) | sort' <<<"$1"
}

ensure_acl() {
    local name="$1" description="$2" rules="$3" json
    if json="$(incus_get "/1.0/network-acls/$name")"; then
        [[ "$(normalized_rules "$(jq -c '.egress // []' <<<"$json")")" == "$(normalized_rules "$rules")" ]] \
            || die "network ACL $name exists with other egress rules than these options give; it is left as it is. Compare with: incus network acl show $name" 1
        log_info "Network ACL $name is in place"
        return 0
    fi
    log_step "Creating network ACL $name"
    jq -n --arg d "$description" --argjson e "$rules" '{description: $d, egress: $e}' \
        | incus_stdin network acl create --quiet "$name" >/dev/null \
        || die "could not create network ACL $name" 1
}

# ------------------------------------------------------------
# The restricted client certificate.
# ------------------------------------------------------------

ensure_client_cert() {
    [[ -n "$client_cert" ]] || return 0
    local fingerprint certs entry
    fingerprint="$(openssl x509 -in "$client_cert" -noout -fingerprint -sha256 2>/dev/null)" \
        || die "--client-cert $client_cert: not a PEM certificate" 2
    fingerprint="${fingerprint#*=}"
    fingerprint="${fingerprint//:/}"
    fingerprint="${fingerprint,,}"
    certs="$(incus_get '/1.0/certificates?recursion=1')" || die "could not list the trusted certificates" 1
    entry="$(jq -c --arg f "$fingerprint" '[.[] | select(.fingerprint == $f)][0] // empty' <<<"$certs")"
    if [[ -n "$entry" ]]; then
        jq -e --arg p "$TEST_PROJECT" '.restricted == true and .projects == [$p]' <<<"$entry" >/dev/null \
            || die "certificate ${fingerprint:0:12} is already trusted as $(jq -r '.name' <<<"$entry"), and not restricted to $TEST_PROJECT alone; it is left as it is" 1
        log_info "Certificate ${fingerprint:0:12} is trusted, restricted to $TEST_PROJECT"
        return 0
    fi
    log_step "Trusting certificate ${fingerprint:0:12} as $client_name, restricted to project $TEST_PROJECT"
    incus_run config trust add-certificate "$client_cert" --restricted --projects "$TEST_PROJECT" \
        --name "$client_name" >/dev/null || die "could not trust $client_cert" 1
}

# ------------------------------------------------------------
# incus.env: written last, so it exists only for a finished setup.
# ------------------------------------------------------------

env_file() {
    printf '%s/acfs/incus.env\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

check_env_file() {
    local file recorded
    file="$(env_file)"
    [[ -f "$file" ]] || return 0
    recorded="$(sed -n 's/^ACFS_INCUS_POOL=//p' "$file")"
    [[ -z "$recorded" || "$recorded" == "$(printf '%q' "$pool_name")" ]] \
        || die "$file records pool $recorded, not $pool_name; this hypervisor is set up already. Move that file aside to set it up again" 1
}

write_env_file() {
    local file dir tmp
    file="$(env_file)"
    dir="$(dirname "$file")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.incus.env.XXXXXX")"
    {
        printf '# Written by scripts/providers/incus.sh host-setup; read by incus.sh.\n'
        printf 'ACFS_INCUS_POOL=%q\n' "$pool_name"
        printf 'ACFS_INCUS_STORAGE_SOURCE=%q\n' "$pool_source"
        printf 'ACFS_INCUS_PROJECT=%q\n' "$TEST_PROJECT"
        printf 'ACFS_INCUS_BRIDGE_TESTS=%q\n' "$TEST_BRIDGE"
    } >"$tmp"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$file"
    log_success "Host setup done; recorded in $file"
}

test_bridge_cidr=""

main() {
    parse_args "$@"
    require_storage
    require_commands
    check_server
    add_memory_config

    local gateway
    gateway="$(swarm_gateway)"
    # The pool is named before anything is created, so that a hypervisor
    # already set up with another pool is refused untouched.
    [[ "$storage" == */* ]] || pool_name="$storage"
    check_env_file
    ensure_pool
    ensure_swarm_profile
    ensure_test_bridge
    ensure_acl "$VM_ACL" "$VM_ACL_DESCRIPTION" "$(vm_acl_rules)"
    ensure_acl "$SWARM_ACL" "$SWARM_ACL_DESCRIPTION" "$(swarm_acl_rules "$gateway")"
    ensure_test_project
    ensure_client_cert
    write_env_file
}

main "$@"
