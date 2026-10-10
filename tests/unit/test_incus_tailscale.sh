#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus_tailscale.sh (incus.sh tailscale) against a STUB incus
#
# Proves the sidecar's decisions: what it is created with, that it joins
# the machine's bridge behind acfs-vm-egress, that tailscaled runs in
# userspace mode, that the auth key never reaches argv or output and is
# removed in the sidecar, which forwards it serves, and that a re-run
# reuses what exists and refuses what it would have to change. The stub
# keeps the objects and the sidecar's Tailscale state as files; nothing
# here touches real Incus, Tailscale or the host.
#
# Usage: bash tests/unit/test_incus_tailscale.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIDECAR="$ROOT/scripts/providers/incus_tailscale.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-tailscale.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
KEY="tskey-auth-kSECRET0CNTRL-0123456789abcdef"

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
# The stub. incus logs "<stdin>\t<argv>" per call ("null" when stdin is
# /dev/null), drops a "r:" remote prefix from every argument, and keeps
# each API object as $STUB_DIR/api/<path>.json with "/" as "_". `exec`
# plays the sidecar: cloud-init answers $STUB_CLOUD_INIT, getent resolves
# only $STUB_RESOLVES, and Tailscale's state is $STUB_DIR/ts.json (status)
# and $STUB_DIR/serve.json (serve status).
# ------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
stdin=other
[[ "$(readlink /proc/self/fd/0)" == /dev/null ]] && stdin=null
args="$*"
printf '%s\t%s\n' "$stdin" "${args//$'\n'/\\n}" >>"$STUB_DIR/calls"
argv=()
for a in "$@"; do argv+=("${a#r:}"); done
set -- "${argv[@]}"

obj() { local p="${1//\//_}"; printf '%s/api/%s.json\n' "$STUB_DIR" "$p"; }
edit() { local file; file="$(obj "$1")"; jq "${@:2}" "$file" >"$file.new"; mv "$file.new" "$file"; }
ts() { local file="$STUB_DIR/$1"; jq "${@:2}" "$file" >"$file.new"; mv "$file.new" "$file"; }

case "$1 ${2:-}" in
    "query "*)
        [[ -f "$(obj "$2")" ]] || { echo "Error: Not Found" >&2; exit 1; }
        cat "$(obj "$2")"
        ;;
    "network acl")
        # network acl show <name>
        [[ -f "$(obj "/1.0/network-acls/$4")" ]] || { echo "Error: Not Found" >&2; exit 1; }
        ;;
    "storage volume")
        # storage volume create <pool> <volume> size=<size>
        jq -n --arg s "${6#size=}" '{config: {size: $s}}' >"$(obj "/1.0/storage-pools/$4/volumes/custom/$5")"
        ;;
    "init "*)
        # init <image> <name> <args>...
        printf '%s\n' "${@:4}" >"$STUB_DIR/init.args"
        owner=""
        for a in "${@:4}"; do [[ "$a" != user.acfs.tailscale-for=* ]] || owner="${a#*=}"; done
        jq -n --arg o "$owner" '{status: "Stopped", config: {"user.acfs.tailscale-for": $o}, devices: {}}' >"$(obj "/1.0/instances/$3")"
        ;;
    "config device")
        # config device add <instance> <device> disk <key=value>...
        json='{type: "disk"}'
        for kv in "${@:7}"; do json="$json + {\"${kv%%=*}\": \"${kv#*=}\"}"; done
        edit "/1.0/instances/$4" --arg d "$5" ".devices[\$d] = ($json)"
        ;;
    "start "*)
        edit "/1.0/instances/$2" '.status = "Running"'
        ;;
    "exec "*)
        shift 3
        case "$1 ${2:-}" in
            "true ") ;;
            "cloud-init status") printf 'status: %s\n' "${STUB_CLOUD_INIT:-done}" ;;
            "tailscale version") [[ -z "${STUB_NO_TAILSCALE:-}" ]] || exit 127 ;;
            "getent hosts")
                [[ "$3" == "${STUB_RESOLVES:-dev.incus}" ]] || exit 2
                printf '10.0.0.7  %s\n' "$3"
                ;;
            "tailscale status") cat "$STUB_DIR/ts.json" ;;
            "tailscale up")
                ts ts.json '.BackendState = "Running"'
                ;;
            "tailscale serve")
                if [[ "$3" == status ]]; then
                    cat "$STUB_DIR/serve.json"
                else
                    # serve --bg --tcp=<port> tcp://<target>
                    ts serve.json --arg p "${4#--tcp=}" --arg t "${5#tcp://}" '.TCP[$p] = {TCPForward: $t}'
                fi
                ;;
            "sh -c")
                if [[ "$3" == "umask 077 && cat > "* ]]; then
                    cat >"$STUB_DIR/sidecar-key"
                    cp "$STUB_DIR/sidecar-key" "$STUB_DIR/key-received"
                else
                    # The login: sh -c '<script>' sh <key path> <hostname>
                    printf '%s\n' "${@:5}" >"$STUB_DIR/up.args"
                    rm -f "$STUB_DIR/sidecar-key"
                    [[ -z "${STUB_UP_FAILS:-}" ]] || exit 1
                    ts ts.json '.BackendState = "Running"'
                fi
                ;;
            *) echo "stub incus exec: unexpected: $*" >&2; exit 99 ;;
        esac
        ;;
    *) echo "stub incus: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/incus"

# ------------------------------------------------------------
# A world: the machine "dev" on incusbr0, which is the default profile's
# NIC network, the ACL, incus.env, and a sidecar not yet logged in.
# ------------------------------------------------------------
new_case() {
    CASE="$WORK/$1"
    mkdir -p "$CASE/stub/api" "$CASE/home/.config/acfs"
    : >"$CASE/stub/calls"
    printf 'ACFS_INCUS_POOL=acfs\n' >"$CASE/home/.config/acfs/incus.env"
    api /1.0/instances/dev '{status: "Running", config: {}, expanded_devices: {eth0: {type: "nic", network: "incusbr0", name: "eth0"}, root: {type: "disk", path: "/"}}}'
    api /1.0/profiles/default '{devices: {eth0: {type: "nic", network: "incusbr0", name: "eth0"}, root: {type: "disk", path: "/", pool: "acfs"}}}'
    api /1.0/networks/incusbr0 '{managed: true, type: "bridge", config: {"ipv4.address": "10.0.0.1/24"}}'
    api /1.0/network-acls/acfs-vm-egress '{}'
    jq -n '{BackendState: "NeedsLogin", Self: {DNSName: "dev.tail1234.ts.net."}}' >"$CASE/stub/ts.json"
    printf '{}\n' >"$CASE/stub/serve.json"
    printf '%s\n' "$KEY" >"$CASE/key"
    chmod 600 "$CASE/key"
}
api() { local p="${1//\//_}"; jq -n "$2" >"$CASE/stub/api/$p.json"; }
api_of() { local p="${1//\//_}"; cat "$CASE/stub/api/$p.json"; }

run() {
    local status=0
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$CASE/home" STUB_DIR="$CASE/stub" \
        ${STUB_CLOUD_INIT:+STUB_CLOUD_INIT="$STUB_CLOUD_INIT"} \
        ${STUB_RESOLVES:+STUB_RESOLVES="$STUB_RESOLVES"} \
        ${STUB_UP_FAILS:+STUB_UP_FAILS=1} ${STUB_NO_TAILSCALE:+STUB_NO_TAILSCALE=1} \
        bash "$SIDECAR" "$@" >"$CASE/out" 2>"$CASE/err" || status=$?
    printf '%s\n' "$status" >"$CASE/status"
}
status_is() { [[ "$(cat "$CASE/status")" == "$1" ]]; }
out_is() { [[ "$(cat "$CASE/out")" == "$1" ]]; }
err_has() { grep -qF -- "$1" "$CASE/err"; }
called() { grep -qF -- "$1" "$CASE/stub/calls"; }
not_called() { ! called "$1"; }
no_calls() { [[ ! -s "$CASE/stub/calls" ]]; }
created_nothing() { ! grep -qP '\t(init |storage volume create |config device add )' "$CASE/stub/calls"; }
json_true() { jq -e "$1" "$2" >/dev/null; }
# Every incus call but the key's hand-over runs with stdin on /dev/null.
stdin_only_for_key() {
    local others
    others="$(grep -v '^null' "$CASE/stub/calls" || true)"
    [[ "$(grep -c . <<<"$others")" == 1 && "$others" == *"umask 077 && cat > /run/acfs-tailscale-authkey"* ]]
}
key_nowhere() { ! grep -rqF -- "$KEY" "$CASE/stub/calls" "$CASE/out" "$CASE/err" "$CASE/stub/init.args" 2>/dev/null; }
init_has() { grep -qxF -- "$1" "$CASE/stub/init.args"; }
forward_is() { [[ "$(jq -r --arg p "$1" '.TCP[$p].TCPForward // ""' "$CASE/stub/serve.json")" == "$2" ]]; }
sidecar_is() { api_of /1.0/instances/acfs-ts-dev | jq -e "$1" >/dev/null; }

echo "== a fresh sidecar"
new_case fresh
run dev --auth-key-file "$CASE/key"
check "exits 0" status_is 0
check "stdout is the tailnet name alone" out_is dev.tail1234.ts.net
check "creates the state volume on the recorded pool" \
    json_true '.config.size == "1GiB"' "$CASE/stub/api/_1.0_storage-pools_acfs_volumes_custom_acfs-ts-dev-state.json"
check "creates acfs-ts-dev from Ubuntu 26.04" called "init images:ubuntu/26.04/cloud acfs-ts-dev"
check "pins it unprivileged" init_has security.privileged=false
check "with no nesting" init_has security.nesting=false
check "with its own uid/gid range" init_has security.idmap.isolated=true
check "with a hard memory limit" init_has limits.memory.enforce=hard
check "marks whose sidecar it is" init_has user.acfs.tailscale-for=dev
check "puts its root on the pool" init_has root,pool=acfs
check "its NIC carries acfs-vm-egress" init_has eth0,security.acls=acfs-vm-egress
check "adds no host device" bash -c "! grep -qE 'unix-char|/dev/net/tun|nesting=true' '$CASE/stub/init.args'"
check "user-data runs tailscaled in userspace mode" grep -qF -- '--tun=userspace-networking' "$CASE/stub/init.args"
check "user-data installs tailscale from Tailscale's repository" grep -qF 'pkgs.tailscale.com/stable/ubuntu/$codename' "$CASE/stub/init.args"
check "mounts the state volume at /var/lib/tailscale" \
    sidecar_is '.devices.state == {type: "disk", pool: "acfs", source: "acfs-ts-dev-state", path: "/var/lib/tailscale"}'
check "starts it" sidecar_is '.status == "Running"'
check "the sidecar received exactly the key file" cmp -s "$CASE/key" "$CASE/stub/key-received"
check "passes the key file's path and the hostname, not the key" \
    bash -c "[[ \"\$(cat '$CASE/stub/up.args')\" == \$'/run/acfs-tailscale-authkey\ndev' ]]"
check "the key file in the sidecar is gone after login" bash -c "[[ ! -e '$CASE/stub/sidecar-key' ]]"
check "the key is in no argv, output or error" key_nowhere
check "only the key's hand-over has a stdin" stdin_only_for_key
check "forwards tailnet 22 to the machine's name on the bridge" forward_is 22 dev.incus:22
check "never changes the machine" bash -c "! grep -P '\t(config|start|stop|delete|exec) (r:)?dev( |$)' '$CASE/stub/calls'"

echo "== a re-run"
new_case rerun
run dev --auth-key-file "$CASE/key"
: >"$CASE/stub/calls"
run dev
check "exits 0 without a key" status_is 0
check "prints the same name" out_is dev.tail1234.ts.net
check "creates nothing" created_nothing
check "doesn't start a running sidecar" not_called "start acfs-ts-dev"
check "doesn't log in again" bash -c "! grep -qE 'tailscale up|sh -c' '$CASE/stub/calls'"
check "doesn't serve again" bash -c "! grep -q 'serve --bg' '$CASE/stub/calls'"

echo "== another port on a re-run"
new_case port
run dev --auth-key-file "$CASE/key"
run dev --port 8080 --port 22 --port 8080
check "exits 0" status_is 0
check "adds the forward for 8080" forward_is 8080 dev.incus:8080
check "keeps 22's" forward_is 22 dev.incus:22
check "serves 8080 once" bash -c "[[ \$(grep -c 'tcp=8080' '$CASE/stub/calls') == 1 ]]"

echo "== a port that serves something else"
new_case conflict
jq -n '{TCP: {"22": {TCPForward: "other.incus:22"}}}' >"$CASE/stub/serve.json"
run dev --auth-key-file "$CASE/key"
check "exits 1" status_is 1
check "names the port" err_has "tailnet port 22 already serves something else (other.incus:22)"
check "leaves it" forward_is 22 other.incus:22
check "serves nothing" not_called "serve --bg"

echo "== a port that serves the web"
new_case web
jq -n '{TCP: {"22": {HTTPS: true}}}' >"$CASE/stub/serve.json"
run dev --auth-key-file "$CASE/key"
check "exits 1" status_is 1
check "says it isn't a TCP forward" err_has "(not a TCP forward)"

echo "== not logged in, no key"
new_case nokey
run dev
check "exits 2" status_is 2
check "asks for --auth-key-file" err_has "pass --auth-key-file"
check "serves nothing" not_called "serve --bg"

echo "== logged in but down"
new_case stopped
jq '.BackendState = "Stopped"' "$CASE/stub/ts.json" >"$CASE/ts" && mv "$CASE/ts" "$CASE/stub/ts.json"
run dev
check "exits 0 without a key" status_is 0
check "brings it up with the hostname" called "tailscale up --hostname=dev --accept-dns=false"

echo "== waiting for approval"
new_case approval
jq '.BackendState = "NeedsMachineAuth"' "$CASE/stub/ts.json" >"$CASE/ts" && mv "$CASE/ts" "$CASE/stub/ts.json"
run dev --auth-key-file "$CASE/key"
check "exits 1" status_is 1
check "says to approve it" err_has "waits for approval in the tailnet's admin console"
check "doesn't hand over the key" not_called "umask 077"

echo "== --hostname"
new_case hostname
run dev --auth-key-file "$CASE/key" --hostname devbox
check "logs in under that name" bash -c "[[ \"\$(sed -n 2p '$CASE/stub/up.args')\" == devbox ]]"

echo "== a failed login"
new_case upfails
STUB_UP_FAILS=1 run dev --auth-key-file "$CASE/key"
check "exits 1" status_is 1
check "says the key file was removed" err_has "the key file there was removed"
check "the key file in the sidecar is gone" bash -c "[[ ! -e '$CASE/stub/sidecar-key' ]]"
check "the key is in no argv, output or error" key_nowhere

echo "== a half-made sidecar"
new_case half
api /1.0/instances/acfs-ts-dev '{status: "Stopped", config: {"user.acfs.tailscale-for": "dev"}, devices: {}}'
api /1.0/storage-pools/acfs/volumes/custom/acfs-ts-dev-state '{config: {size: "1GiB"}}'
run dev --auth-key-file "$CASE/key"
check "exits 0" status_is 0
check "doesn't create it again" bash -c "! grep -qP '\tinit ' '$CASE/stub/calls'"
check "adds the missing state device" sidecar_is '.devices.state.source == "acfs-ts-dev-state"'
check "starts it" called "start acfs-ts-dev"

echo "== an instance by that name that isn't the sidecar"
new_case foreign
api /1.0/instances/acfs-ts-dev '{status: "Running", config: {}, devices: {}}'
run dev --auth-key-file "$CASE/key"
check "exits 1" status_is 1
check "says so" err_has "isn't this machine's sidecar"
check "changes nothing" bash -c "! grep -qP '\t(init |config device add |start |exec )' '$CASE/stub/calls'"

echo "== the machine's network"
new_case nomachine
rm "$CASE/stub/api/_1.0_instances_dev.json"
run dev --auth-key-file "$CASE/key"
check "a missing machine exits 1" status_is 1
check "and says to create it" err_has "doesn't exist; create it with scripts/providers/incus.sh first"
new_case othernet
api /1.0/instances/dev '{status: "Running", config: {}, expanded_devices: {eth0: {type: "nic", network: "acfstest0"}}}'
run dev --auth-key-file "$CASE/key"
check "a machine off the default profile's network exits 1" status_is 1
check "and names both networks" err_has "the machine is on network 'acfstest0', the default profile's NIC on 'incusbr0'"
check "and creates nothing" created_nothing
new_case nodns
api /1.0/networks/incusbr0 '{managed: true, type: "bridge", config: {"dns.mode": "none"}}'
run dev --auth-key-file "$CASE/key"
check "dns.mode=none exits 1" status_is 1
new_case domain
api /1.0/networks/incusbr0 '{managed: true, type: "bridge", config: {"dns.domain": "lan.example"}}'
STUB_RESOLVES=dev.lan.example run dev --auth-key-file "$CASE/key"
check "a bridge's dns.domain names the target" forward_is 22 dev.lan.example:22
new_case unresolved
STUB_RESOLVES=nothing run dev --auth-key-file "$CASE/key"
check "a name the sidecar can't resolve exits 1" status_is 1
check "before login" bash -c "! grep -q 'sh -c' '$CASE/stub/calls'"

echo "== what host-setup provides"
new_case noacl
rm "$CASE/stub/api/_1.0_network-acls_acfs-vm-egress.json"
run dev --auth-key-file "$CASE/key"
check "a missing ACL exits 1" status_is 1
check "and creates nothing" created_nothing
new_case noenv
rm "$CASE/home/.config/acfs/incus.env"
run dev --auth-key-file "$CASE/key"
check "a missing incus.env exits 2" status_is 2
check "and calls no incus" no_calls

echo "== cloud-init"
new_case cloudinit
STUB_CLOUD_INIT=error run dev --auth-key-file "$CASE/key"
check "an error exits 1" status_is 1
check "before login" bash -c "! grep -q 'sh -c' '$CASE/stub/calls'"
new_case notailscale
STUB_NO_TAILSCALE=1 run dev --auth-key-file "$CASE/key"
check "no tailscale after cloud-init exits 1" status_is 1

echo "== a remote"
new_case remote
run r:dev --auth-key-file "$CASE/key"
check "exits 0" status_is 0
check "creates the sidecar on the remote" called "init images:ubuntu/26.04/cloud r:acfs-ts-dev"
check "queries the remote" called "query r:/1.0/instances/dev"
check "creates the volume on the remote's pool" called "storage volume create r:acfs acfs-ts-dev-state size=1GiB"

echo "== arguments"
new_case args
for bad in "--port 0" "--port 65536" "--port x" "--hostname -bad" "--auth-key-file $CASE/missing" "--frobnicate" "1dev" "dev other"; do
    : >"$CASE/stub/calls"
    # shellcheck disable=SC2086 # each case is several words on purpose
    run $bad
    check "'$bad' exits 2 and calls no incus" bash -c "[[ \$(cat '$CASE/status') == 2 && ! -s '$CASE/stub/calls' ]]"
done
run abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghi
check "a machine name too long for the sidecar's exits 2" status_is 2
printf 'not-a-key\n' >"$CASE/badkey"
run dev --auth-key-file "$CASE/badkey"
check "a file that isn't a key exits 2" status_is 2
check "without printing it" bash -c "! grep -q not-a-key '$CASE/err'"
chmod 644 "$CASE/key"
run dev --auth-key-file "$CASE/key"
check "a key others can read is warned about" err_has "can be read by other users"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
