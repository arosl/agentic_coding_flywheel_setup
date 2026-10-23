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
# "/" as "_" and "?" as "@". findmnt answers from $STUB_FS, swapon from
# $STUB_SWAP.
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
        # network acl create|edit <name>, the ACL as JSON on stdin. Read
        # whole before the file is opened: in "query | jq | edit" the query
        # still reads it, as Incus reads the ACL before the edit's PUT.
        acl="$(jq .)"
        printf '%s\n' "$acl" >"$(obj "/1.0/network-acls/$4")"
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
# swapon --show=NAME --noheadings: the hypervisor's swap, one line per area.
cat >"$WORK/bin/swapon" <<'STUB'
#!/usr/bin/env bash
[[ -z "${STUB_SWAP:-}" ]] || printf '%s\n' "$STUB_SWAP"
STUB
chmod +x "$WORK/bin/incus" "$WORK/bin/findmnt" "$WORK/bin/swapon"

GATEWAY_NET='{"managed": true, "type": "bridge", "config": {"ipv4.address": "10.20.30.1/24"}}'
DEFAULT_PROFILE='{"config": {}, "devices": {"eth0": {"type": "nic", "network": "incusbr0"}, "root": {"type": "disk", "path": "/", "pool": "default"}}}'
SERVER='{"auth": "trusted",
  "api_extensions": ["projects_networks_restricted_access", "container_syscall_intercept_sysinfo", "disk_volume_subpath",
    "projects_restricted_image_servers"],
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
env_lacks() { ! grep -q -- "$1" "$(env_file)"; }
# env_is <pool> <source> [<test project> <test bridge>]: empty when not given.
env_is() {
    local ACFS_INCUS_POOL="" ACFS_INCUS_STORAGE_SOURCE="" ACFS_INCUS_PROJECT="" ACFS_INCUS_BRIDGE_TESTS=""
    # shellcheck disable=SC1090
    source "$(env_file)"
    [[ "$ACFS_INCUS_POOL" == "$1" && "$ACFS_INCUS_STORAGE_SOURCE" == "$2" \
        && "$ACFS_INCUS_PROJECT" == "${3:-}" && "$ACFS_INCUS_BRIDGE_TESTS" == "${4:-}" ]]
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

echo "== a fresh host without --test-project: no test project, bridge or test-net rules"
new_case notest
run_setup --storage "$STORAGE_DIR"
check "exits 0" rc_is 0
check "stdout stays empty" stdout_empty
check "creates the profile" config_is /1.0/profiles/acfs-swarm security.privileged false
check "creates no project" not_called 'project create'
check "creates no bridge" not_called 'network create'
check "creates the vm ACL (the launcher uses it)" \
    jq_is /1.0/network-acls/acfs-vm-egress '[.egress[] | .action]' '["reject"]'
check "swarm ACL: allows the host API on the gateway" acl_allows acfs-swarm-egress 10.20.30.1 tcp 8443
check "swarm ACL: rejects SSH into 10/8 (no test bridge to allow)" acl_rejects acfs-swarm-egress 10.99.0.50 tcp 22
check "swarm ACL: rejects ICMP into 10/8" acl_rejects acfs-swarm-egress 10.99.0.50 icmp4
check "swarm ACL: allows the internet" acl_allows acfs-swarm-egress 1.1.1.1 tcp 443
check "creates the sidecar ACL" called 'network acl create --quiet acfs-sidecar-egress'
check "sidecar ACL: its description" \
    jq_is /1.0/network-acls/acfs-sidecar-egress .description \
    '"ACFS Tailscale sidecars: DNS and DHCP on the bridge'"'"'s gateway and TCP to the instances on the bridge; no other private ranges"'
check "sidecar ACL: allows DNS over UDP on the gateway" acl_allows acfs-sidecar-egress 10.20.30.1 udp 53
check "sidecar ACL: allows DNS over TCP on the gateway" acl_allows acfs-sidecar-egress 10.20.30.1 tcp 53
check "sidecar ACL: allows a unicast DHCP renewal to the gateway" acl_allows acfs-sidecar-egress 10.20.30.1 udp 67
check "sidecar ACL: rejects other UDP to the gateway" acl_rejects acfs-sidecar-egress 10.20.30.1 udp 123
check "sidecar ACL: rejects UDP 68 to the gateway (a client port)" acl_rejects acfs-sidecar-egress 10.20.30.1 udp 68
check "sidecar ACL: rejects SSH to the gateway" acl_rejects acfs-sidecar-egress 10.20.30.1 tcp 22
check "sidecar ACL: rejects the host API on the gateway" acl_rejects acfs-sidecar-egress 10.20.30.1 tcp 8443
check "sidecar ACL: allows SSH to the machine on the bridge" acl_allows acfs-sidecar-egress 10.20.30.7 tcp 22
check "sidecar ACL: allows another forwarded port on the bridge" acl_allows acfs-sidecar-egress 10.20.30.254 tcp 8080
check "sidecar ACL: rejects UDP to the bridge's instances" acl_rejects acfs-sidecar-egress 10.20.30.7 udp 53
check "sidecar ACL: rejects the next subnet in 10/8" acl_rejects acfs-sidecar-egress 10.20.31.1 tcp 22
check "sidecar ACL: rejects the rest of 10/8" acl_rejects acfs-sidecar-egress 10.99.0.50 tcp 22
check "sidecar ACL: rejects the LAN" acl_rejects acfs-sidecar-egress 192.168.1.1 tcp 443
check "sidecar ACL: rejects the tailnet's range" acl_rejects acfs-sidecar-egress 100.100.1.1 tcp 443
check "sidecar ACL: rejects link-local (cloud metadata)" acl_rejects acfs-sidecar-egress 169.254.169.254 tcp 80
check "sidecar ACL: rejects IPv6 ULA" acl_rejects acfs-sidecar-egress fd00::1 tcp 443
check "sidecar ACL: rejects IPv6 link-local" acl_rejects acfs-sidecar-egress fe80::1 udp 53
check "sidecar ACL: leaves DHCPv6 to multicast alone" acl_allows acfs-sidecar-egress ff02::1:2 udp 547
check "sidecar ACL: allows the internet (coordination, DERP)" acl_allows acfs-sidecar-egress 1.1.1.1 tcp 443
check "sidecar ACL: allows STUN" acl_allows acfs-sidecar-egress 1.1.1.1 udp 3478
check "creates no certificate" not_called 'config trust'
check "incus.env records the pool, and no test project or bridge" env_is acfs "$STORAGE_DIR"
check "incus.env has no test lines" env_lacks 'ACFS_INCUS_PROJECT\|ACFS_INCUS_BRIDGE_TESTS'
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR"
check "re-run: exits 0" rc_is 0
check "re-run: creates and changes nothing" no_creates
run_setup --storage "$STORAGE_DIR" --client-cert "$WORK/no-such.crt" --client-name devbox
check "--client-cert without --test-project: exits 2" rc_is 2
check "--client-cert without --test-project: names it" err_has 'needs --test-project'

echo "== a fresh host with --test-project, a directory on ext4 without project quotas"
new_case fresh
run_setup --storage "$STORAGE_DIR" --test-project
check "exits 0" rc_is 0
check "stdout stays empty" stdout_empty
check "creates a dir pool acfs on the directory" pool_is acfs "[\"dir\",\"$STORAGE_DIR\"]"
check "warns that sizes aren't enforced" err_has 'not enforced'
check "profile: unprivileged" config_is /1.0/profiles/acfs-swarm security.privileged false
check "profile: no nesting" config_is /1.0/profiles/acfs-swarm security.nesting false
check "profile: isolated idmap" config_is /1.0/profiles/acfs-swarm security.idmap.isolated true
check "profile: sysinfo intercept" config_is /1.0/profiles/acfs-swarm security.syscalls.intercept.sysinfo true
check "profile: every thread, no CPU count" config_is /1.0/profiles/acfs-swarm limits.cpu '<unset>'
check "profile: lowest CPU priority" config_is /1.0/profiles/acfs-swarm limits.cpu.priority 0
check "profile: a CPU share, not a time cap" config_is /1.0/profiles/acfs-swarm limits.cpu.allowance 30%
check "profile: no memory limit without --memory" config_is /1.0/profiles/acfs-swarm limits.memory '<unset>'
check "profile: no memory enforcement without --memory" config_is /1.0/profiles/acfs-swarm limits.memory.enforce '<unset>'
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
check "swarm ACL: rejects the tailnet" acl_rejects acfs-swarm-egress 100.100.1.1 tcp 443
check "swarm ACL: rejects IPv6 ULA" acl_rejects acfs-swarm-egress fd00::1 tcp 443
check "swarm ACL: allows the internet" acl_allows acfs-swarm-egress 1.1.1.1 tcp 443
check "creates no certificate without --client-cert" not_called 'config trust'
check "incus.env records the pool, its source, the project and the bridge" env_is acfs "$STORAGE_DIR" acfs-tests acfstest0
check "every incus call but the ACL creates has stdin /dev/null" only_null_stdin_except_acl_create
check "every incus call is local" all_local

echo "== re-run on the set-up host"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --test-project
check "exits 0" rc_is 0
check "creates and changes nothing" no_creates
check "incus.env is unchanged" env_is acfs "$STORAGE_DIR" acfs-tests acfstest0

echo "== re-run without --test-project on a host that has the test project"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR"
check "exits 1" rc_is 1
check "names the project and --test-project" err_has 'test project acfs-tests from an earlier host setup; pass --test-project'
check "creates and changes nothing" no_creates
check "incus.env is unchanged" env_is acfs "$STORAGE_DIR" acfs-tests acfstest0

echo "== re-run with an rch worker: the swarm ACL would differ"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --test-project --rch-worker 192.168.5.20
check "exits 1" rc_is 1
check "names the ACL" err_has 'acfs-swarm-egress exists with other egress rules'
check "changes nothing" no_creates
check "lists the worker's SSH allow as added" err_has '+ {"action":"allow","destination":"192.168.5.20/32"'
check "lists the old private-range reject as dropped" err_has '- {"action":"reject","destination":"10.0.0.0/'
check "prints the command that takes the rules" err_has 'incus network acl edit --force-local acfs-swarm-egress$'
# The printed command, run as the operator would, against the stub.
TAKE="$(sed -n 's/^ *\(incus query --force-local .*\)$/\1/p' "$CASE/err")"
set +e
PATH="$WORK/bin:$PATH" STUB_DIR="$CASE" bash -c "$TAKE" 2>"$CASE/take.err"
TAKE_RC=$?
set -e
check "the printed command runs" bash -c '[[ "$1" -eq 0 ]]' _ "$TAKE_RC"
check "it keeps the ACL's description" \
    jq_is /1.0/network-acls/acfs-swarm-egress '.description | startswith("ACFS containers")' true
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --test-project --rch-worker 192.168.5.20
check "the re-run after it: exits 0" rc_is 0
check "the re-run after it: changes nothing" no_creates
check "the worker is reachable over SSH" acl_allows acfs-swarm-egress 192.168.5.20 tcp 22

echo "== re-run on a host set up before the sidecar's ACL"
new_case nosidecaracl
run_setup --storage "$STORAGE_DIR"
rm "$CASE/api/_1.0_network-acls_acfs-sidecar-egress.json"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR"
check "exits 0" rc_is 0
check "creates the sidecar ACL" called 'network acl create --quiet acfs-sidecar-egress'
check "creates no other ACL" bash -c "[[ \$(grep -c 'network acl create' '$CASE/calls') == 1 ]]"
check "the new ACL lets the sidecar reach the machine" acl_allows acfs-sidecar-egress 10.20.30.7 tcp 22
: >"$CASE/calls"
seed /1.0/network-acls/acfs-sidecar-egress "$(api /1.0/network-acls/acfs-sidecar-egress | jq '.egress |= map(select(.action != "allow")) + [{action: "allow", destination: "10.20.30.0/24", protocol: "udp", state: "enabled"}]')"
run_setup --storage "$STORAGE_DIR"
check "a sidecar ACL with other rules: exits 1" rc_is 1
check "a sidecar ACL with other rules: names it" err_has 'acfs-sidecar-egress exists with other egress rules'
check "a sidecar ACL with other rules: changes nothing" no_creates

echo "== without --test-project, after a run that made the test bridge and stopped at the project"
new_case bridgeonly
seed /1.0/networks/acfstest0 '{"managed": true, "type": "bridge", "config": {"ipv4.address": "10.99.0.1/24"}}'
run_setup --storage "$STORAGE_DIR"
check "exits 1" rc_is 1
check "names the bridge" err_has 'test bridge acfstest0'
check "creates nothing" no_creates
check "writes no incus.env" no_env_file

echo "== rch workers on a fresh hypervisor"
new_case rch
run_setup --storage "$STORAGE_DIR" --rch-worker 192.168.5.20 --rch-worker 10.20.30.40
check "exits 0" rc_is 0
check "allows SSH to a worker on the LAN" acl_allows acfs-swarm-egress 192.168.5.20 tcp 22
check "allows SSH to a worker on the containers' bridge" acl_allows acfs-swarm-egress 10.20.30.40 tcp 22
check "rejects other ports on a worker" acl_rejects acfs-swarm-egress 192.168.5.20 tcp 5432
check "rejects UDP to a worker" acl_rejects acfs-swarm-egress 192.168.5.20 udp 53
check "still rejects the worker's neighbour" acl_rejects acfs-swarm-egress 192.168.5.21 tcp 22
check "still rejects the tailnet" acl_rejects acfs-swarm-egress 100.100.1.1 tcp 443

echo "== a bad --rch-worker"
new_case badworker
run_setup --storage "$STORAGE_DIR" --rch-worker 10.20.30.400
check "exits 2" rc_is 2
check "makes no incus call" no_calls

echo "== --memory: soft with the hypervisor's swap, hard without"
new_case swap
STUB_SWAP=/swapfile run_setup --storage "$STORAGE_DIR" --memory 96GiB
check "exits 0" rc_is 0
check "limits.memory" config_is /1.0/profiles/acfs-swarm limits.memory 96GiB
check "with swap: soft" config_is /1.0/profiles/acfs-swarm limits.memory.enforce soft
check "with swap: the container may swap" config_is /1.0/profiles/acfs-swarm limits.memory.swap true
STUB_SWAP=/swapfile run_setup --storage "$STORAGE_DIR" --memory 64GiB
check "a different --memory later is refused" rc_is 1
check "naming the key" err_has 'limits.memory is 96GiB, not 64GiB'
new_case noswap
run_setup --storage "$STORAGE_DIR" --memory 96GiB
check "without swap: exits 0" rc_is 0
check "without swap: hard" config_is /1.0/profiles/acfs-swarm limits.memory.enforce hard
check "without swap: no swap" config_is /1.0/profiles/acfs-swarm limits.memory.swap false
new_case override
run_setup --storage "$STORAGE_DIR" --memory 96GiB --memory-enforce soft
check "--memory-enforce overrides: exits 0" rc_is 0
check "--memory-enforce overrides: soft" config_is /1.0/profiles/acfs-swarm limits.memory.enforce soft
check "--memory-enforce soft without swap warns" err_has 'stalls'
new_case badmemory
run_setup --storage "$STORAGE_DIR" --memory 96G
check "a size without a unit is refused" rc_is 2
run_setup --storage "$STORAGE_DIR" --memory-enforce soft
check "--memory-enforce without --memory is refused" rc_is 2
run_setup --storage "$STORAGE_DIR" --cpus 24
check "--cpus is gone (no CPU count)" rc_is 2
check "makes no incus call" no_calls

echo "== btrfs, XFS with quotas, a ZFS mountpoint, not a directory"
new_case btrfs
STUB_FS="btrfs rw,relatime" run_setup --storage "$STORAGE_DIR"
check "btrfs: exits 0" rc_is 0
check "btrfs: a btrfs pool on the directory" pool_is acfs "[\"btrfs\",\"$STORAGE_DIR\"]"
check "btrfs: no quota warning" err_lacks 'not enforced'
new_case xfsquota
STUB_FS="xfs rw,relatime,prjquota" run_setup --storage "$STORAGE_DIR"
check "xfs with prjquota: no quota warning" err_lacks 'not enforced'
new_case zfsdir
STUB_FS="zfs rw" run_setup --storage "$STORAGE_DIR"
check "zfs mountpoint: exits 0" rc_is 0
check "zfs mountpoint: a dir pool" pool_is acfs "[\"dir\",\"$STORAGE_DIR\"]"
check "zfs mountpoint: warns" err_has 'not enforced'
new_case relative
run_setup --storage tank/incus
check "a relative path: exits 2" rc_is 2
check "a relative path: creates nothing" no_creates
new_case missing
run_setup --storage "$WORK/no-such-dir"
check "a missing directory: exits 2" rc_is 2
check "a missing directory: creates nothing" no_creates

echo "== an existing pool by name"
new_case existing
run_setup --storage default --test-project
check "exits 0" rc_is 0
check "creates no pool" not_called 'storage create'
check "the test project's root is on it" \
    jq_is '/1.0/profiles/default?project=acfs-tests' .devices.root.pool '"default"'
check "incus.env records it and its source" env_is default /var/lib/incus/storage-pools/default acfs-tests acfstest0
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
check "missing extension: claims no 6.0.6 floor" err_lacks '6.0.6'
check "missing extension: creates nothing" no_creates

echo "== --test-project on an Incus without restricted.images.servers (6.0.5)"
new_case noimageservers
seed /1.0 "$(jq -c '.api_extensions -= ["projects_restricted_image_servers"]' <<<"$SERVER")"
run_setup --storage "$STORAGE_DIR" --test-project
check "exits 0" rc_is 0
check "warns, naming the extension" err_has 'lacks the API extension projects_restricted_image_servers'
check "the key is left out" config_is /1.0/projects/acfs-tests restricted.images.servers '<unset>'
check "the project is restricted otherwise" config_is /1.0/projects/acfs-tests restricted true
check "and keeps its network restriction" config_is /1.0/projects/acfs-tests restricted.networks.access acfstest0
check "the key is never sent" not_called 'restricted.images.servers'
seed /1.0 "$SERVER"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --test-project
check "after an upgrade: exits 0" rc_is 0
check "after an upgrade: the key is set" config_is /1.0/projects/acfs-tests restricted.images.servers images.linuxcontainers.org
check "after an upgrade: no warning" err_lacks 'projects_restricted_image_servers'
new_case noimageservers-default
seed /1.0 "$(jq -c '.api_extensions -= ["projects_restricted_image_servers"]' <<<"$SERVER")"
run_setup --storage "$STORAGE_DIR"
check "without --test-project: exits 0" rc_is 0
check "without --test-project: no warning" err_lacks 'projects_restricted_image_servers'

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
run_setup --storage "$STORAGE_DIR" --test-project
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
run_setup --storage "$STORAGE_DIR" --test-project
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
run_setup --storage "$STORAGE_DIR" --test-project --client-cert "$CASE/client.crt"
check "--client-cert without --client-name: exits 2" rc_is 2
run_setup --storage "$STORAGE_DIR" --client-cert "$CASE/client.crt" --client-name devbox
check "--client-cert without --test-project: exits 2" rc_is 2
check "--client-cert without --test-project: makes no incus call" no_calls
run_setup --storage "$STORAGE_DIR" --test-project --client-cert "$CASE/client.crt" --client-name devbox
check "exits 0" rc_is 0
check "trusted restricted to acfs-tests under its name" \
    args_are trust.args "$CASE/client.crt --restricted --projects acfs-tests --name devbox"
seed '/1.0/certificates?recursion=1' "[{\"fingerprint\": \"$FP\", \"name\": \"devbox\", \"restricted\": true, \"projects\": [\"acfs-tests\"]}]"
: >"$CASE/calls"
run_setup --storage "$STORAGE_DIR" --test-project --client-cert "$CASE/client.crt" --client-name devbox
check "already trusted that way: exits 0" rc_is 0
check "already trusted that way: not added again" not_called 'config trust'
seed '/1.0/certificates?recursion=1' "[{\"fingerprint\": \"$FP\", \"name\": \"devbox\", \"restricted\": false, \"projects\": []}]"
run_setup --storage "$STORAGE_DIR" --test-project --client-cert "$CASE/client.crt" --client-name devbox
check "trusted unrestricted: exits 1" rc_is 1
check "trusted unrestricted: says so" err_has 'not restricted to acfs-tests'

echo "== a block device: ACFS formats no disks"
DEVICE="$(find /dev -maxdepth 1 -type b -print -quit 2>/dev/null || true)"
if [[ -z "$DEVICE" ]]; then
    echo "  skip (no block device under /dev)"
else
    new_case device
    run_setup --storage "$DEVICE"
    check "exits 2" rc_is 2
    check "says it formats no disks" err_has 'formats no disks'
    check "creates nothing" no_creates
    run_setup --storage "$DEVICE" --format-device
    check "--format-device is gone" rc_is 2
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
