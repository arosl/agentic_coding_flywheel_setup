#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus_rch_worker.sh (incus.sh rch-worker) against a STUB incus
#
# Proves the worker's decisions: what it is created with (the pins, its
# hard limits, its fixed address on the bridge, its ACL), that cloud-init
# runs rustup's installer only after checking the sha256 checksums.yaml
# pins, that the dispatcher's key is authorized and the block printed for
# it, which addresses --ipv4 refuses, that a missing lease, cloud-init
# error or toolchain stops the run, and that a re-run reuses its own worker
# and refuses any other instance. The stub keeps the objects as files;
# nothing here touches real Incus, rch or the host.
#
# Usage: bash tests/unit/test_incus_rch_worker.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$ROOT/scripts/providers/incus_rch_worker.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-rch-worker.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
RUSTUP_SHA="$(sed -n '/^  rust:$/,/^$/s/^    sha256: "\(.*\)"$/\1/p' "$ROOT/checksums.yaml")"
HOST_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKeyOfTheWorker0000000000000000000000"
# Paths printed for the dispatcher, never expanded here.
# shellcheck disable=SC2088
DEFAULT_IDENTITY='~/.ssh/id_ed25519'
# shellcheck disable=SC2088
OTHER_IDENTITY='~/.ssh/rch_ed25519'

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

ssh-keygen -q -t ed25519 -N '' -C dispatcher -f "$WORK/dispatcher"
printf 'not a key\n' >"$WORK/not-a-key.pub"

# ------------------------------------------------------------
# The stub. incus logs "<stdin>\t<argv>" per call ("null" when stdin is
# /dev/null), drops a "r:" remote prefix from every argument, and keeps
# each API object as $STUB_DIR/api/<path>.json with "/" as "_". `init`
# keeps its -c keys as config and its -d keys as devices, and writes the
# user-data to $STUB_DIR/user-data. A running instance's state has its
# NIC's fixed address (or $STUB_LEASE_ADDR) once polled more than
# $STUB_LEASE_AFTER times. `exec` plays the worker: cloud-init answers
# $STUB_CLOUD_INIT; $STUB_NO_RSYNC and $STUB_NO_RUST take those away.
# sleep only counts, in $STUB_DIR/sleeps.
# ------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/sleeps"
STUB
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

case "$1 ${2:-}" in
    "query "*/state)
        instance="$(obj "${2%/state}")"
        [[ -f "$instance" ]] || { echo "Error: Not Found" >&2; exit 1; }
        polls=$(($(cat "$STUB_DIR/state-polls" 2>/dev/null || echo 0) + 1))
        printf '%s\n' "$polls" >"$STUB_DIR/state-polls"
        address=""
        if [[ "$(jq -r .status "$instance")" == Running ]] && ((polls > ${STUB_LEASE_AFTER:-0})); then
            address="${STUB_LEASE_ADDR:-$(jq -r '[.expanded_devices[] | select(.type == "nic") | .["ipv4.address"]][0]' "$instance")}"
        fi
        jq -n --arg a "$address" '{network: {
            lo: {addresses: [{family: "inet", address: "127.0.0.1", scope: "local"}]},
            eth0: {addresses: ([{family: "inet6", address: "fe80::216:3eff:fe00:2", scope: "link"}]
                + if $a == "" then [] else [{family: "inet", address: $a, scope: "global"}] end)}}}'
        ;;
    "query "*)
        [[ -f "$(obj "$2")" ]] || { echo "Error: Not Found" >&2; exit 1; }
        cat "$(obj "$2")"
        ;;
    "profile show")
        [[ -f "$(obj "/1.0/profiles/$3")" ]] || { echo "Error: Not Found" >&2; exit 1; }
        ;;
    "network acl")
        # network acl show <name>
        [[ -f "$(obj "/1.0/network-acls/$4")" ]] || { echo "Error: Not Found" >&2; exit 1; }
        ;;
    "init "*)
        # init <image> <name> <args>...
        printf '%s\n' "${@:4}" >"$STUB_DIR/init.args"
        config='{}'
        devices='{}'
        prev=""
        for a in "${@:4}"; do
            case "$prev" in
                -c)
                    if [[ "$a" == cloud-init.user-data=* ]]; then
                        printf '%s\n' "${a#*=}" >"$STUB_DIR/user-data"
                    else
                        config="$(jq -c --arg k "${a%%=*}" --arg v "${a#*=}" '.[$k] = $v' <<<"$config")"
                    fi
                    ;;
                -d)
                    kv="${a#*,}"
                    devices="$(jq -c --arg d "${a%%,*}" --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$d][$k] = $v' <<<"$devices")"
                    ;;
            esac
            prev="$a"
        done
        # The NIC comes from the default profile; the -d keys override it.
        jq -n --argjson c "$config" --argjson d "$devices" \
            '{status: "Stopped", config: $c, devices: $d,
              expanded_devices: ({eth0: {type: "nic", network: "incusbr0", name: "eth0"}} * $d)}' >"$(obj "/1.0/instances/$3")"
        ;;
    "start "*)
        edit "/1.0/instances/$2" '.status = "Running"'
        ;;
    "exec "*)
        shift 3
        case "$1 ${2:-}" in
            "true ") ;;
            "cloud-init status") printf 'status: %s\n' "${STUB_CLOUD_INIT:-done}" ;;
            "rsync --version")
                [[ -z "${STUB_NO_RSYNC:-}" ]] || exit 127
                echo "rsync  version 3.4.1  protocol version 32"
                ;;
            "runuser -u")
                # runuser -u ubuntu -- env HOME=/home/ubuntu <rustup> run stable rustc --version
                printf '%s\n' "$*" >"$STUB_DIR/toolchain-check"
                [[ -z "${STUB_NO_RUST:-}" ]] || exit 1
                echo "rustc 1.95.0 (0123456789 2026-10-01)"
                ;;
            "cat /etc/ssh/ssh_host_ed25519_key.pub") printf '%s root@worker\n' "$STUB_HOST_KEY" ;;
            *) echo "stub incus exec: unexpected: $*" >&2; exit 99 ;;
        esac
        ;;
    *) echo "stub incus: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/incus" "$WORK/bin/sleep"

# ------------------------------------------------------------
# A world: incusbr0 (10.20.30.1/24) as the default profile's NIC network,
# the swarm profile and ACL host-setup made, and incus.env.
# ------------------------------------------------------------
new_case() {
    CASE="$WORK/$1"
    mkdir -p "$CASE/stub/api" "$CASE/home/.config/acfs"
    : >"$CASE/stub/calls"
    printf 'ACFS_INCUS_POOL=acfs\n' >"$CASE/home/.config/acfs/incus.env"
    api /1.0/profiles/default '{devices: {eth0: {type: "nic", network: "incusbr0", name: "eth0"}, root: {type: "disk", path: "/", pool: "acfs"}}}'
    api /1.0/profiles/acfs-swarm '{config: {}, devices: {}}'
    api /1.0/networks/incusbr0 '{managed: true, type: "bridge", config: {"ipv4.address": "10.20.30.1/24"}}'
    api /1.0/network-acls/acfs-swarm-egress '{}'
}
api() { local p="${1//\//_}"; jq -n "$2" >"$CASE/stub/api/$p.json"; }
api_of() { local p="${1//\//_}"; cat "$CASE/stub/api/$p.json"; }

run() {
    local status=0
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$CASE/home" STUB_DIR="$CASE/stub" STUB_HOST_KEY="$HOST_KEY" \
        ${STUB_CLOUD_INIT:+STUB_CLOUD_INIT="$STUB_CLOUD_INIT"} \
        ${STUB_LEASE_AFTER:+STUB_LEASE_AFTER="$STUB_LEASE_AFTER"} \
        ${STUB_LEASE_ADDR:+STUB_LEASE_ADDR="$STUB_LEASE_ADDR"} \
        ${STUB_NO_RSYNC:+STUB_NO_RSYNC=1} ${STUB_NO_RUST:+STUB_NO_RUST=1} \
        bash "$WORKER" "$@" >"$CASE/out" 2>"$CASE/err" || status=$?
    printf '%s\n' "$status" >"$CASE/status"
}
status_is() { [[ "$(cat "$CASE/status")" == "$1" ]]; }
err_has() { grep -qF -- "$1" "$CASE/err"; }
called() { grep -qF -- "$1" "$CASE/stub/calls"; }
not_called() { ! called "$1"; }
no_calls() { [[ ! -s "$CASE/stub/calls" ]]; }
created_nothing() { ! grep -qP '\t(init |start )' "$CASE/stub/calls"; }
init_has() { grep -qxF -- "$1" "$CASE/stub/init.args"; }
userdata_has() { grep -qF -- "$1" "$CASE/stub/user-data"; }
worker_is() { api_of /1.0/instances/rch-w1 | jq -e "$1" >/dev/null; }
only_null_stdin() { ! grep -qv $'^null\t' "$CASE/stub/calls"; }
# expected_block <ip> <identity file> [<slots>]: what stdout must be.
expected_block() {
    printf '# Add to ~/.config/rch/workers.toml on the dispatcher (the machine whose builds rch offloads):\n'
    printf '[[workers]]\nid = "rch-w1"\nhost = "%s"\nuser = "ubuntu"\nidentity_file = "%s"\n' "$1" "$2"
    [[ -z "${3:-}" ]] || printf 'total_slots = %s\n' "$3"
    printf '# Add to ~/.ssh/known_hosts on the dispatcher:\n%s %s\n' "$1" "$HOST_KEY"
    printf '# Then run there (rch-wkr and the toolchains), and set total_slots and priority from the benchmark:\n'
    printf 'rch workers setup rch-w1\nrch workers benchmark rch-w1\n'
}
out_is_block() { [[ "$(cat "$CASE/out")" == "$(expected_block "$@")" ]]; }

echo "== a fresh worker"
new_case fresh
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "exits 0" status_is 0
check "stdout is the block alone" out_is_block 10.20.30.21 "$DEFAULT_IDENTITY" 8
check "creates rch-w1 from Ubuntu 26.04" called "init images:ubuntu/26.04/cloud rch-w1"
check "with the default and swarm profiles" bash -c "grep -A1 -x -- -p '$CASE/stub/init.args' | grep -c -x -e default -e acfs-swarm | grep -qx 2"
check "pins it unprivileged" init_has security.privileged=false
check "with no nesting" init_has security.nesting=false
check "with its own uid/gid range" init_has security.idmap.isolated=true
check "with 8 CPUs" init_has limits.cpu=8
check "with a 16GiB memory limit" init_has limits.memory=16GiB
check "enforced hard" init_has limits.memory.enforce=hard
check "without swap" init_has limits.memory.swap=false
check "marks it as an rch worker" worker_is '.config["user.acfs.rch-worker"] == "true"'
check "puts a 100GiB root on the pool" bash -c "grep -qx root,pool=acfs '$CASE/stub/init.args' && grep -qx root,size=100GiB '$CASE/stub/init.args'"
check "fixes its address on the bridge" init_has eth0,ipv4.address=10.20.30.21
check "its NIC carries acfs-swarm-egress" init_has eth0,security.acls=acfs-swarm-egress
check "which lets traffic the ACL doesn't name through" init_has eth0,security.acls.default.egress.action=allow
check "adds no host device" bash -c "! grep -qE 'unix-char|/dev/|nesting=true|privileged=true' '$CASE/stub/init.args'"
check "user-data authorizes the dispatcher's key" userdata_has "$(cut -d' ' -f1,2 "$WORK/dispatcher.pub")"
check "user-data installs sshd, rsync and a C toolchain" \
    userdata_has 'packages: [openssh-server, rsync, zstd, build-essential, pkg-config, libssl-dev, cmake, git, curl, ca-certificates]'
check "user-data makes /data/projects and /data/tmp the user's" \
    userdata_has 'install -d -o ubuntu -g ubuntu -m 0755 /data/projects /data/tmp'
check "user-data fetches rustup's installer from checksums.yaml's URL" userdata_has 'curl -fsSL --proto =https --tlsv1.2 "https://sh.rustup.rs" -o /root/rustup-init.sh'
check "and checks the sha256 checksums.yaml pins" userdata_has "echo \"$RUSTUP_SHA  /root/rustup-init.sh\" | sha256sum -c -"
check "before it runs it, as the user" bash -c "c=\$(grep -n 'sha256sum -c' '$CASE/stub/user-data' | cut -d: -f1); r=\$(grep -n 'runuser -u ubuntu -- env HOME=/home/ubuntu sh ' '$CASE/stub/user-data' | cut -d: -f1); [[ -n \$c && -n \$r && \$c -lt \$r ]]"
check "with clippy and rustfmt" userdata_has '--profile minimal --default-toolchain stable -c clippy -c rustfmt'
check "starts it" worker_is '.status == "Running"'
check "checks the toolchain as the user" \
    grep -qxF 'runuser -u ubuntu -- env HOME=/home/ubuntu /home/ubuntu/.cargo/bin/rustup run stable rustc --version' "$CASE/stub/toolchain-check"
check "names the toolchain" err_has "The worker has rsync and rustc 1.95.0"
check "says host-setup must allow it" err_has "host-setup --rch-worker 10.20.30.21"
check "every incus call has stdin /dev/null" only_null_stdin

echo "== the per-worker options"
new_case options
run rch-w1 --ipv4 10.20.30.22 --ssh-key "$WORK/dispatcher.pub" --cpus 4 --memory 8GiB --root-size 60GiB \
    --acl other-egress --identity-file "$OTHER_IDENTITY"
check "a missing --acl exits 1" status_is 1
check "and names host-setup" err_has "network ACL other-egress doesn't exist; run 'scripts/providers/incus.sh host-setup'"
check "and creates nothing" created_nothing
api /1.0/network-acls/other-egress '{}'
run rch-w1 --ipv4 10.20.30.22 --ssh-key "$WORK/dispatcher.pub" --cpus 4 --memory 8GiB --root-size 60GiB \
    --acl other-egress --identity-file "$OTHER_IDENTITY"
check "exits 0" status_is 0
check "with 4 CPUs" init_has limits.cpu=4
check "with 8GiB" init_has limits.memory=8GiB
check "with a 60GiB root" init_has root,size=60GiB
check "behind --acl's ACL" init_has eth0,security.acls=other-egress
check "prints --identity-file and 4 slots" out_is_block 10.20.30.22 "$OTHER_IDENTITY" 4

echo "== a re-run"
new_case rerun
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
: >"$CASE/stub/calls"
run rch-w1
check "exits 0 without --ipv4 or --ssh-key" status_is 0
check "creates and starts nothing" created_nothing
check "prints the same block, the address read from its NIC" out_is_block 10.20.30.21 "$DEFAULT_IDENTITY" 8
run rch-w1 --ipv4 10.20.30.99 --cpus 2
check "creation options on a re-run: exits 0" status_is 0
check "are warned about" err_has "apply only when the worker is created; rch-w1 keeps what it has"
check "and change nothing" out_is_block 10.20.30.21 "$DEFAULT_IDENTITY" 8
edit_worker() { local f="$CASE/stub/api/_1.0_instances_rch-w1.json"; jq "$1" "$f" >"$f.new"; mv "$f.new" "$f"; }
edit_worker '.status = "Stopped"'
: >"$CASE/stub/calls"
run rch-w1
check "a stopped worker is started" called "start rch-w1"
check "and its block printed" status_is 0
edit_worker '.config["limits.cpu"] = "0-3"'
run rch-w1
check "a worker limited to a CPU set gets no total_slots" out_is_block 10.20.30.21 "$DEFAULT_IDENTITY"

echo "== an instance by that name that isn't a worker"
new_case foreign
api /1.0/instances/rch-w1 '{status: "Running", config: {}, devices: {}, expanded_devices: {}}'
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "exits 1" status_is 1
check "says so" err_has "isn't an rch worker made by this script"
check "changes nothing" bash -c "! grep -qP '\t(init |start |exec |config )' '$CASE/stub/calls'"

echo "== --ipv4 must be a host address in the bridge's subnet"
# The gateway comes last: the check after the loop reads its error.
for bad in 10.20.31.5 10.20.30.0 10.20.30.255 192.168.1.5 10.20.30.1; do
    new_case "ip-$bad"
    run rch-w1 --ipv4 "$bad" --ssh-key "$WORK/dispatcher.pub"
    check "$bad exits 2" status_is 2
    check "$bad creates nothing" created_nothing
done
check "the gateway's is named as such" err_has "not the gateway's"
new_case ip-nobridge
api /1.0/networks/incusbr0 '{managed: false, type: "bridge", config: {}}'
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "an unmanaged bridge exits 1" status_is 1
check "and creates nothing" created_nothing

echo "== what creation needs"
new_case noip
run rch-w1 --ssh-key "$WORK/dispatcher.pub"
check "no --ipv4: exits 2" status_is 2
check "no --ipv4: names it" err_has "--ipv4 is needed to create the worker rch-w1"
new_case nokey
run rch-w1 --ipv4 10.20.30.21
check "no --ssh-key: exits 2" status_is 2
check "no --ssh-key: creates nothing" created_nothing
new_case privkey
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher"
check "a private key: exits 2" status_is 2
check "a private key: says to pass the .pub" err_has "is a private key; pass the .pub file"
check "a private key: creates nothing" created_nothing
new_case notakey
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/not-a-key.pub"
check "not a key: exits 2" status_is 2
new_case noprofile
rm "$CASE/stub/api/_1.0_profiles_acfs-swarm.json"
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "no swarm profile: exits 1, naming host-setup" bash -c "[[ \$(cat '$CASE/status') == 1 ]] && grep -qF 'profile acfs-swarm doesn'\''t exist' '$CASE/err'"
check "no swarm profile: creates nothing" created_nothing
new_case noenv
rm "$CASE/home/.config/acfs/incus.env"
run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "no incus.env: exits 2" status_is 2
check "no incus.env: calls no incus" no_calls

echo "== no lease"
new_case nolease
STUB_LEASE_AFTER=1000 run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "exits 1" status_is 1
check "says there is no lease and names the ACL" err_has "doesn't have its address 10.20.30.21 about 60s after its start: no DHCP lease. Check the ACL on its NIC (acfs-swarm-egress)"
check "after 20 polls, 3 s apart" bash -c "[[ \$(cat '$CASE/stub/state-polls') == 20 && \$(grep -cx 3 '$CASE/stub/sleeps') == 19 ]]"
check "before cloud-init's wait" not_called "cloud-init status"
new_case otherlease
STUB_LEASE_AFTER=1000 STUB_LEASE_ADDR=10.20.30.77 run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "another address isn't its address" status_is 1
new_case latelease
STUB_LEASE_AFTER=2 run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "a lease on the third poll is waited for" status_is 0

echo "== cloud-init and the toolchain"
new_case cloudinit
STUB_CLOUD_INIT=error run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "a cloud-init error exits 1" status_is 1
check "and prints no block" bash -c "[[ ! -s '$CASE/out' ]]"
new_case norust
STUB_NO_RUST=1 run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "no toolchain exits 1" status_is 1
check "and says so" err_has "the worker has no Rust toolchain for ubuntu"
new_case norsync
STUB_NO_RSYNC=1 run rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "no rsync exits 1" status_is 1

echo "== a remote"
new_case remote
run r:rch-w1 --ipv4 10.20.30.21 --ssh-key "$WORK/dispatcher.pub"
check "exits 0" status_is 0
check "creates the worker on the remote" called "init images:ubuntu/26.04/cloud r:rch-w1"
check "queries the remote" called "query r:/1.0/instances/rch-w1"
check "checks the remote's ACL" called "network acl show r:acfs-swarm-egress"

echo "== arguments"
new_case args
for bad in "--ipv4 10.20.30" "--ipv4 300.1.1.1" "--cpus 0" "--cpus x" "--memory 16G" "--root-size big" \
    "--acl a/b" "--frobnicate" "1worker" "rch-w1 other"; do
    : >"$CASE/stub/calls"
    # shellcheck disable=SC2086 # each case is several words on purpose
    run $bad
    check "'$bad' exits 2 and calls no incus" bash -c "[[ \$(cat '$CASE/status') == 2 && ! -s '$CASE/stub/calls' ]]"
done
run rch-w1 --identity-file 'a"b'
check "an --identity-file with a quote exits 2 (it is printed between TOML quotes)" status_is 2
run --help
check "--help exits 0" status_is 0
check "incus.sh rch-worker dispatches here" \
    bash -c "bash '$ROOT/scripts/providers/incus.sh' rch-worker --help 2>/dev/null | grep -qF 'Creates the unprivileged container <name> as an rch build worker'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
