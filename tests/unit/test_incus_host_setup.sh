#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus_host.sh (incus.sh host-setup) against a STUB incus
#
# Proves host setup's decisions: the storage location is required, how a
# location becomes a pool, what the profile, project, bridge, ACLs and
# certificate are created with, that existing objects are checked and never
# changed, and what incus.env records. The stub keeps the objects as JSON
# files; nothing here touches real Incus or the host.
#
# Usage: bash tests/unit/test_incus_host_setup.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/scripts/providers/incus_host.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-host.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
# A failure shows the end of the run's stderr.
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
    [[ ! -s "${CASE:-}/err" ]] || tail -n 3 "$CASE/err" | sed 's/^/       | /'
}
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# ------------------------------------------------------------
# The stubs. incus logs "<stdin>\t<argv>" per call ("null" when stdin is
# /dev/null) and keeps each API object as $STUB_DIR/api/<path>.json, with
# "/" as "_" and "?" as "@". findmnt answers from $STUB_FS, lsblk from
# $STUB_MOUNTED.
# ------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
stdin=other
[[ "$(readlink /proc/self/fd/0)" == /dev/null ]] && stdin=null
args="$*"
printf '%s\t%s\n' "$stdin" "${args//$'\n'/\\n}" >>"$STUB_DIR/calls"

# Drops the global flag, and takes --project P out of the arguments.
argv=() project=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-local|--quiet) shift ;;
        --project) project="$2"; shift 2 ;;
        *) argv+=("$1"); shift ;;
    esac
done
set -- "${argv[@]}"

obj() { local p="${1//\//_}"; printf '%s/api/%s.json\n' "$STUB_DIR" "${p//\?/@}"; }
put() { jq -n "$2" >"$(obj "$1")"; }
# set_config <path> <key=value>...
set_config() {
    local file kv
    file="$(obj "$1")"
    shift
    for kv in "$@"; do
        jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.config[$k] = $v' "$file" >"$file.new"
        mv "$file.new" "$file"
    done
}
profile_path() { printf '/1.0/profiles/%s%s\n' "$1" "${project:+?project=$project}"; }

case "$1 ${2:-}" in
    "query "*)
        [[ -f "$(obj "$2")" ]] || { echo "Error: Not Found" >&2; exit 1; }
        cat "$(obj "$2")"
        ;;
    "storage create")
        put "/1.0/storage-pools/$3" "{driver: \"$4\", config: {source: \"${5#source=}\"}}"
        ;;
    "profile create")
        put "$(profile_path "$3")" '{config: {}, devices: {}}'
        ;;
    "profile set")
        p="$(profile_path "$3")"
        shift 3
        set_config "$p" "$@"
        ;;
    "profile device")
        # profile device add <profile> <device> <type> <key=value>...
        file="$(obj "$(profile_path "$4")")"
        dev="$5" type="$6"
        shift 6
        json="$(jq -n --arg t "$type" '{type: $t}')"
        for kv in "$@"; do json="$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$json")"; done
        jq --arg d "$dev" --argjson j "$json" '.devices[$d] = $j' "$file" >"$file.new"
        mv "$file.new" "$file"
        ;;
    "network create")
        put "/1.0/networks/$3" '{managed: true, type: "bridge", config: {"ipv4.address": "10.99.0.1/24"}}'
        printf '%s\n' "${@:4}" >"$STUB_DIR/network-create.args"
        ;;
    "network acl")
        # network acl create <name>, the ACL as JSON on stdin
        jq . >"$(obj "/1.0/network-acls/$4")"
        ;;
    "project create")
        put "/1.0/projects/$3" '{config: {}}'
        name="$3"
        shift 3
        kvs=()
        while [[ $# -gt 0 ]]; do [[ "$1" == -c ]] && kvs+=("$2"); shift 2; done
        set_config "/1.0/projects/$name" "${kvs[@]}"
        put "/1.0/profiles/default?project=$name" '{config: {}, devices: {}}'
        ;;
    "project set")
        name="$3"
        shift 3
        set_config "/1.0/projects/$name" "$@"
        ;;
    "config trust")
        # config trust add-certificate <file> --restricted --projects P --name N
        printf '%s\n' "${@:4}" >"$STUB_DIR/trust.args"
        ;;
    *) echo "stub incus: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
cat >"$WORK/bin/findmnt" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_FS:-ext4 rw,relatime}"
STUB
# lsblk -nr -o MOUNTPOINT <device>: one line per partition, empty when unmounted.
cat >"$WORK/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
printf '\n%s\n' "${STUB_MOUNTED:+/mnt}"
STUB
chmod +x "$WORK/bin/incus" "$WORK/bin/findmnt" "$WORK/bin/lsblk"

GATEWAY_NET='{"managed": true, "type": "bridge", "config": {"ipv4.address": "10.20.30.1/24"}}'
DEFAULT_PROFILE='{"config": {}, "devices": {"eth0": {"type": "nic", "network": "incusbr0"}, "root": {"type": "disk", "path": "/", "pool": "default"}}}'
SERVER='{"auth": "trusted",
  "api_extensions": ["projects_networks_restricted_access", "container_syscall_intercept_sysinfo", "disk_volume_subpath"],
  "environment": {"storage_supported_drivers": [{"Name": "dir"}, {"Name": "btrfs"}, {"Name": "zfs"}]}}'

CASE=""
RC=0
STORAGE_DIR="$WORK/storage"
mkdir -p "$STORAGE_DIR"

# new_case <name>: a fresh host with only the default profile, incusbr0 and
# the "default" pool, and a fresh HOME.
new_case() {
    CASE="$WORK/case-$1"
    mkdir -p "$CASE/api" "$CASE/home"
    : >"$CASE/calls"
    seed /1.0 "$SERVER"
    seed /1.0/profiles/default "$DEFAULT_PROFILE"
    seed /1.0/networks/incusbr0 "$GATEWAY_NET"
    seed /1.0/storage-pools/default '{"driver": "dir", "config": {"source": "/var/lib/incus/storage-pools/default"}}'
    seed '/1.0/certificates?recursion=1' '[]'
}
seed() { local p="${1//\//_}"; printf '%s\n' "$2" >"$CASE/api/${p//\?/@}.json"; }
api() { local p="${1//\//_}"; cat "$CASE/api/${p//\?/@}.json"; }

run_setup() {
    set +e
    echo 'stdin that incus must not read' | \
        PATH="$WORK/bin:$PATH" STUB_DIR="$CASE" HOME="$CASE/home" XDG_CONFIG_HOME="" NO_COLOR=1 \
        "$SETUP" "$@" >"$CASE/out" 2>"$CASE/err"
    RC=$?
    set -e
}

# run_tty <input> <args...>: runs it on a pseudo-terminal, typing <input>.
run_tty() {
    local input="$1" cmd
    shift
    cmd="$(printf '%q ' env PATH="$WORK/bin:$PATH" STUB_DIR="$CASE" HOME="$CASE/home" XDG_CONFIG_HOME= NO_COLOR=1 "$SETUP" "$@")"
    set +e
    { sleep 1; printf '%s\n' "$input"; } | script -qec "$cmd 2>$(printf '%q' "$CASE/err")" /dev/null >"$CASE/out"
    RC=$?
    set -e
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
called() { grep -q -- "$1" "$CASE/calls"; }
not_called() { ! grep -q -- "$1" "$CASE/calls"; }
err_has() { grep -q -- "$1" "$CASE/err"; }
err_lacks() { ! err_has "$1"; }
no_calls() { [[ ! -s "$CASE/calls" ]]; }
all_local() { ! cut -f2 "$CASE/calls" | grep -v -- '--force-local' | grep -q .; }
# jq_is <api path> <jq filter> <expected compact JSON>
jq_is() { [[ "$(api "$1" | jq -c "$2")" == "$3" ]]; }
# args_are <file under the case> <expected, one line>
args_are() { [[ "$(paste -sd' ' "$CASE/$1")" == "$2" ]]; }
stdout_empty() { [[ ! -s "$CASE/out" ]]; }
no_creates() { ! cut -f2 "$CASE/calls" | grep -qE '^(storage|profile|network|project|config) '; }
only_null_stdin_except_acl_create() {
    ! grep -v $'^null\t' "$CASE/calls" | grep -v $'^other\tnetwork acl create ' | grep -q .
}
env_file() { printf '%s/.config/acfs/incus.env\n' "$CASE/home"; }
no_env_file() { [[ ! -e "$(env_file)" ]]; }
env_is() {
    local ACFS_INCUS_POOL="" ACFS_INCUS_STORAGE_SOURCE="" ACFS_INCUS_PROJECT="" ACFS_INCUS_BRIDGE_TESTS=""
    # shellcheck disable=SC1090
    source "$(env_file)"
    [[ "$ACFS_INCUS_POOL" == "$1" && "$ACFS_INCUS_STORAGE_SOURCE" == "$2" \
        && "$ACFS_INCUS_PROJECT" == acfs-tests && "$ACFS_INCUS_BRIDGE_TESTS" == acfstest0 ]]
}
config_is() { [[ "$(api "$1" | jq -r --arg k "$2" '.config[$k] // "<unset>"')" == "$3" ]]; }
pool_is() { [[ "$(api "/1.0/storage-pools/$1" | jq -c '[.driver, .config.source]')" == "$2" ]]; }

# acl_rejects <acl> <ip> [protocol] [port]: does a reject rule of the
# created ACL match a packet to <ip>? An independent oracle: Python's ipaddress.
acl_rejects() {
    api "/1.0/network-acls/$1" | python3 -I -c '
import ipaddress, json, sys
ip, proto, port = sys.argv[1], sys.argv[2], sys.argv[3]
def port_in(spec):
    if not spec: return True
    if not port: return False
    for part in spec.split(","):
        lo, _, hi = part.partition("-")
        if int(lo) <= int(port) <= int(hi or lo): return True
    return False
for r in json.load(sys.stdin)["egress"]:
    if r["action"] != "reject": continue
    if r.get("protocol") and r["protocol"] != proto: continue
    if not port_in(r.get("destination_port", "")): continue
    if any(ipaddress.ip_address(ip) in ipaddress.ip_network(d) for d in r["destination"].split(",")):
        sys.exit(0)
sys.exit(1)
' "$2" "${3:-}" "${4:-}"
}
acl_allows() { ! acl_rejects "$@"; }

# ------------------------------------------------------------
echo "== the storage location is required, with no default"
new_case nostorage
run_setup
check "exits 2" rc_is 2
check "names --storage" err_has 'storage is required'
check "makes no incus call" no_calls
check "writes no incus.env" no_env_file

echo "== a fresh host, a directory on ext4 without project quotas"
new_case fresh
run_setup --storage "$STORAGE_DIR"
check "exits 0" rc_is 0
check "stdout stays empty" stdout_empty
check "creates a dir pool acfs on the directory" pool_is acfs "[\"dir\",\"$STORAGE_DIR\"]"
check "warns that quotas are advisory" err_has 'advisory'
check "profile: unprivileged" config_is /1.0/profiles/acfs-swarm security.privileged false
check "profile: no nesting" config_is /1.0/profiles/acfs-swarm security.nesting false
check "profile: isolated idmap" config_is /1.0/profiles/acfs-swarm security.idmap.isolated true
check "profile: sysinfo intercept" config_is /1.0/profiles/acfs-swarm security.syscalls.intercept.sysinfo true
check "profile: soft memory limit" config_is /1.0/profiles/acfs-swarm limits.memory.enforce soft
check "profile: no host-specific memory size" config_is /1.0/profiles/acfs-swarm limits.memory '<unset>'
check "profile: no devices" jq_is /1.0/profiles/acfs-swarm .devices '{}'
for kv in features.images=true features.profiles=true features.storage.volumes=true features.networks=false \
    restricted=true restricted.containers.nesting=block restricted.containers.privilege=isolated \
    restricted.containers.interception=block restricted.devices.unix-char=block restricted.devices.gpu=block \
    restricted.devices.disk=managed restricted.devices.nic=managed restricted.networks.access=acfstest0 \
    restricted.images.servers=images.linuxcontainers.org restricted.snapshots=block restricted.backups=block \
    limits.instances=6 limits.cpu=16 limits.memory=32GiB limits.disk=200GiB; do
    check "project: $kv" config_is /1.0/projects/acfs-tests "${kv%%=*}" "${kv#*=}"
done
check "test profile: root on the pool, 40GiB" \
    jq_is '/1.0/profiles/default?project=acfs-tests' '.devices.root | [.pool, .size]' '["acfs","40GiB"]'
check "test profile: NIC on acfstest0 behind acfs-vm-egress" \
    jq_is '/1.0/profiles/default?project=acfs-tests' '.devices.eth0 | [.network, .["security.acls"]]' '["acfstest0","acfs-vm-egress"]'
check "test profile: limits the project requires" config_is "/1.0/profiles/default?project=acfs-tests" limits.cpu 4
check "bridge acfstest0: IPv4 with NAT, no IPv6" \
    args_are network-create.args '--type=bridge ipv4.address=auto ipv4.nat=true ipv6.address=none'
check "vm ACL: the launcher's one reject rule" \
    jq_is /1.0/network-acls/acfs-vm-egress '[.egress[] | [.action, .destination]]' \
    '[["reject","10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,fc00::/7,fe80::/10"]]'
check "vm ACL: the launcher's description" \
    jq_is /1.0/network-acls/acfs-vm-egress .description '"ACFS instances: no egress to private, CGNAT or link-local ranges"'
check "swarm ACL: allows the host API on the gateway" acl_allows acfs-swarm-egress 10.20.30.1 tcp 8443
check "swarm ACL: rejects SSH to the gateway" acl_rejects acfs-swarm-egress 10.20.30.1 tcp 22
check "swarm ACL: rejects UDP to the gateway" acl_rejects acfs-swarm-egress 10.20.30.1 udp 123
check "swarm ACL: allows SSH to a test instance" acl_allows acfs-swarm-egress 10.99.0.50 tcp 22
check "swarm ACL: allows ICMP to a test instance" acl_allows acfs-swarm-egress 10.99.0.50 icmp4
check "swarm ACL: rejects other ports on a test instance" acl_rejects acfs-swarm-egress 10.99.0.50 tcp 80
check "swarm ACL: rejects acfstest0's gateway (the host)" acl_rejects acfs-swarm-egress 10.99.0.1 tcp 22
check "swarm ACL: rejects another instance on the swarm bridge" acl_rejects acfs-swarm-egress 10.20.30.2 tcp 22
check "swarm ACL: rejects the rest of 10/8" acl_rejects acfs-swarm-egress 10.98.255.255 tcp 22
check "swarm ACL: rejects the LAN" acl_rejects acfs-swarm-egress 192.168.1.1 tcp 443
check "swarm ACL: rejects the tailnet without --tailscale" acl_rejects acfs-swarm-egress 100.100.1.1 tcp 443
check "swarm ACL: rejects IPv6 ULA" acl_rejects acfs-swarm-egress fd00::1 tcp 443
check "swarm ACL: allows the internet" acl_allows acfs-swarm-egress 1.1.1.1 tcp 443
check "creates no certificate without --client-cert" not_called 'config trust'
check "incus.env records the pool and its source" env_is acfs "$STORAGE_DIR"
check "every incus call but the ACL creates has stdin /dev/null" only_null_stdin_except_acl_create
check "every incus call is local" all_local

echo "== re-run on the set-up host"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR"
check "exits 0" rc_is 0
check "creates and changes nothing" no_creates
check "incus.env is unchanged" env_is acfs "$STORAGE_DIR"

echo "== re-run with --tailscale: the swarm ACL would differ"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --tailscale
check "exits 1" rc_is 1
check "names the ACL" err_has 'acfs-swarm-egress exists with other egress rules'
check "changes nothing" no_creates

echo "== --tailscale and --sibling on a fresh host"
new_case tailnet
run_setup --storage "$STORAGE_DIR" --tailscale --sibling 10.20.30.40
check "exits 0" rc_is 0
check "allows the tailnet" acl_allows acfs-swarm-egress 100.100.1.1 tcp 443
check "allows the sibling on any port" acl_allows acfs-swarm-egress 10.20.30.40 tcp 5432
check "still rejects its neighbour" acl_rejects acfs-swarm-egress 10.20.30.41 tcp 5432

echo "== a bad --sibling"
new_case badsibling
run_setup --storage "$STORAGE_DIR" --sibling 10.20.30.400
check "exits 2" rc_is 2
check "makes no incus call" no_calls

echo "== --memory and --cpus go into the profile"
new_case sized
run_setup --storage "$STORAGE_DIR" --memory 96GiB --cpus 24
check "exits 0" rc_is 0
check "limits.memory" config_is /1.0/profiles/acfs-swarm limits.memory 96GiB
check "limits.cpu" config_is /1.0/profiles/acfs-swarm limits.cpu 24
run_setup --storage "$STORAGE_DIR" --memory 64GiB
check "a different --memory later is refused" rc_is 1
check "naming the key" err_has 'limits.memory is 96GiB, not 64GiB'
run_setup --storage "$STORAGE_DIR" --memory 96G
check "a size without a unit is refused" rc_is 2

echo "== btrfs, a ZFS dataset, a ZFS mountpoint"
new_case btrfs
STUB_FS="btrfs rw,relatime" run_setup --storage "$STORAGE_DIR"
check "btrfs: exits 0" rc_is 0
check "btrfs: a btrfs pool on the directory" pool_is acfs "[\"btrfs\",\"$STORAGE_DIR\"]"
check "btrfs: no quota warning" err_lacks advisory
new_case xfsquota
STUB_FS="xfs rw,relatime,prjquota" run_setup --storage "$STORAGE_DIR"
check "xfs with prjquota: no quota warning" err_lacks advisory
new_case dataset
run_setup --storage tank/incus --pool-name swarm
check "dataset: exits 0" rc_is 0
check "dataset: a zfs pool named by --pool-name" pool_is swarm '["zfs","tank/incus"]'
check "dataset: incus.env records it" env_is swarm tank/incus
new_case zfsdir
STUB_FS="zfs rw" run_setup --storage "$STORAGE_DIR"
check "zfs mountpoint: refused" rc_is 2
check "zfs mountpoint: asks for the dataset" err_has 'give the dataset'
check "zfs mountpoint: creates nothing" no_creates

echo "== an existing pool by name"
new_case existing
run_setup --storage default
check "exits 0" rc_is 0
check "creates no pool" not_called 'storage create'
check "the test project's root is on it" \
    jq_is '/1.0/profiles/default?project=acfs-tests' .devices.root.pool '"default"'
check "incus.env records it and its source" env_is default /var/lib/incus/storage-pools/default
new_case nopool
run_setup --storage nosuchpool
check "an unknown pool name: exits 2" rc_is 2
check "an unknown pool name: creates nothing" no_creates

echo "== pool acfs exists on another source"
new_case clash
seed /1.0/storage-pools/acfs '{"driver": "dir", "config": {"source": "/elsewhere"}}'
run_setup --storage "$STORAGE_DIR"
check "exits 1" rc_is 1
check "names the pool's source" err_has "source '/elsewhere'"
check "creates nothing" no_creates

echo "== incus.env records another pool"
new_case setup
mkdir -p "$CASE/home/.config/acfs"
printf 'ACFS_INCUS_POOL=other\n' >"$CASE/home/.config/acfs/incus.env"
run_setup --storage "$STORAGE_DIR"
check "exits 1" rc_is 1
check "creates nothing" no_creates
check "leaves incus.env alone" grep -qx ACFS_INCUS_POOL=other "$CASE/home/.config/acfs/incus.env"

echo "== an Incus that isn't ready"
new_case untrusted
seed /1.0 '{"auth": "untrusted", "api_extensions": []}'
run_setup --storage "$STORAGE_DIR"
check "not an admin: exits 1" rc_is 1
check "not an admin: says so" err_has 'incus-admin'
new_case old
seed /1.0 "$(jq -c '.api_extensions = ["container_syscall_intercept_sysinfo"]' <<<"$SERVER")"
run_setup --storage "$STORAGE_DIR"
check "missing extension: exits 1" rc_is 1
check "missing extension: names it" err_has 'projects_networks_restricted_access'
check "missing extension: creates nothing" no_creates

echo "== existing objects are checked, not changed"
new_case loose
seed /1.0/profiles/acfs-swarm '{"config": {"security.nesting": "true"}, "devices": {}}'
run_setup --storage "$STORAGE_DIR"
check "a loosened profile: exits 1" rc_is 1
check "a loosened profile: names the key" err_has 'security.nesting is true, not false'
check "a loosened profile: never set" not_called 'profile set acfs-swarm'
new_case halfdone
seed /1.0/profiles/acfs-swarm '{"config": {}, "devices": {}}'
run_setup --storage "$STORAGE_DIR"
check "an empty profile (interrupted run): exits 0" rc_is 0
check "an empty profile: its keys are set" config_is /1.0/profiles/acfs-swarm security.idmap.isolated true
new_case withdev
seed /1.0/profiles/acfs-swarm '{"config": {}, "devices": {"data": {"type": "disk"}}}'
run_setup --storage "$STORAGE_DIR"
check "a profile with devices: exits 1" rc_is 1
new_case looseproject
seed /1.0/projects/acfs-tests '{"config": {"restricted.containers.nesting": "allow"}}'
run_setup --storage "$STORAGE_DIR"
check "a loosened project: exits 1" rc_is 1
check "a loosened project: never set" not_called 'project set'
new_case tunedproject
seed /1.0/projects/acfs-tests "$(jq -n '{config: ($ARGS.positional | map(split("=") | {(.[0]): .[1]}) | add)}' --args \
    features.images=true features.profiles=true features.storage.volumes=true features.networks=false \
    restricted=true restricted.containers.nesting=block restricted.containers.privilege=isolated \
    restricted.containers.interception=block restricted.devices.unix-char=block restricted.devices.gpu=block \
    restricted.devices.disk=managed restricted.devices.nic=managed restricted.networks.access=acfstest0 \
    restricted.images.servers=images.linuxcontainers.org restricted.snapshots=block restricted.backups=block \
    limits.instances=10)"
seed '/1.0/profiles/default?project=acfs-tests' '{"config": {}, "devices": {}}'
run_setup --storage "$STORAGE_DIR"
check "a project with the operator's own limit: exits 0" rc_is 0
check "keeps the operator's limit" config_is /1.0/projects/acfs-tests limits.instances 10
check "sets the limits it lacked" config_is /1.0/projects/acfs-tests limits.memory 32GiB
new_case launcheracl
# acfs-vm-egress as incus.sh creates it, as Incus returns it.
seed /1.0/network-acls/acfs-vm-egress '{"name": "acfs-vm-egress", "description": "x", "ingress": [],
  "egress": [{"action": "reject", "source": "", "destination": "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,fc00::/7,fe80::/10",
  "protocol": "", "source_port": "", "destination_port": "", "icmp_type": "", "icmp_code": "", "description": "", "state": "enabled"}]}'
run_setup --storage "$STORAGE_DIR"
check "the launcher's acfs-vm-egress is accepted as it is" rc_is 0
check "and not created again" not_called 'network acl create acfs-vm-egress'

echo "== the restricted client certificate"
new_case cert
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=devbox \
    -keyout "$CASE/client.key" -out "$CASE/client.crt" 2>/dev/null
FP="$(openssl x509 -in "$CASE/client.crt" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
run_setup --storage "$STORAGE_DIR" --client-cert "$CASE/client.crt"
check "--client-cert without --client-name: exits 2" rc_is 2
run_setup --storage "$STORAGE_DIR" --client-cert "$CASE/client.crt" --client-name devbox
check "exits 0" rc_is 0
check "trusted restricted to acfs-tests under its name" \
    args_are trust.args "$CASE/client.crt --restricted --projects acfs-tests --name devbox"
seed '/1.0/certificates?recursion=1' "[{\"fingerprint\": \"$FP\", \"name\": \"devbox\", \"restricted\": true, \"projects\": [\"acfs-tests\"]}]"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --client-cert "$CASE/client.crt" --client-name devbox
check "already trusted that way: exits 0" rc_is 0
check "already trusted that way: not added again" not_called 'config trust'
seed '/1.0/certificates?recursion=1' "[{\"fingerprint\": \"$FP\", \"name\": \"devbox\", \"restricted\": false, \"projects\": []}]"
run_setup --storage "$STORAGE_DIR" --client-cert "$CASE/client.crt" --client-name devbox
check "trusted unrestricted: exits 1" rc_is 1
check "trusted unrestricted: says so" err_has 'not restricted to acfs-tests'

echo "== a block device"
DEVICE="$(find /dev -maxdepth 1 -type b -print -quit 2>/dev/null || true)"
if [[ -z "$DEVICE" ]] || ! command -v script >/dev/null 2>&1; then
    echo "  skip (no block device under /dev, or no script(1))"
else
    new_case device
    run_setup --storage "$DEVICE"
    check "without --format-device: exits 2" rc_is 2
    check "without --format-device: says it destroys" err_has 'formatting destroys'
    check "without --format-device: creates nothing" no_creates
    run_setup --storage "$DEVICE" --format-device
    check "not on a terminal: exits 2" rc_is 2
    check "not on a terminal: creates nothing" no_creates
    run_tty "wrong" --storage "$DEVICE" --format-device
    check "a wrong confirmation: exits 2" rc_is 2
    check "a wrong confirmation: creates nothing" no_creates
    STUB_MOUNTED=1 run_tty "$DEVICE" --storage "$DEVICE" --format-device
    check "a mounted device: exits 2" rc_is 2
    check "a mounted device: creates nothing" no_creates
    run_tty "$DEVICE" --storage "$DEVICE" --format-device
    check "the typed path: exits 0" rc_is 0
    check "the typed path: a zfs pool on the device" pool_is acfs "[\"zfs\",\"$DEVICE\"]"
    seed /1.0/storage-pools/acfs '{"driver": "zfs", "config": {"source": "acfs"}}'
    : >"$CASE/calls"
    run_setup --storage "$DEVICE" --format-device
    check "re-run: the device's pool is found, no confirmation asked" rc_is 0
    check "re-run: creates nothing" no_creates
fi

echo "== the storage location prompted for on a terminal"
if ! command -v script >/dev/null 2>&1; then
    echo "  skip (no script(1))"
else
    new_case prompt
    run_tty "$STORAGE_DIR"
    check "exits 0" rc_is 0
    check "uses the typed location" pool_is acfs "[\"dir\",\"$STORAGE_DIR\"]"
fi

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
((FAIL == 0))
