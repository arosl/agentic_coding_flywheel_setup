#!/usr/bin/env bash
# ============================================================
# A Tailscale sidecar for an ACFS swarm machine (incus.sh tailscale)
#
# Puts the machine on the tailnet without Tailscale in it. A small sibling
# container, acfs-ts-<machine>, runs tailscaled and forwards tailnet TCP
# ports to the machine over the Incus bridge with `tailscale serve`:
# `ssh ubuntu@<machine>` from any tailnet device reaches the machine's own
# sshd. Run it on the machine you run incus.sh from.
#
# Why a sidecar rather than tailscaled in the machine: the node key stays
# out of the container the agents (with sudo) work in, the machine keeps
# its egress ACL closed to the tailnet's 100.64.0.0/10, and the machine
# can be rebuilt or replaced while the tailnet name and node stay.
# tailscaled runs with --tun=userspace-networking, so neither container
# needs /dev/net/tun or any other host device: serve dials the machine
# through the sidecar's own network stack.
#
# The sidecar keeps its node state on its own volume,
# acfs-ts-<machine>-state, so rebuilding the sidecar keeps its login. Its
# NIC carries acfs-vm-egress: it reaches the internet (the coordination
# server, DERP) and no private range; bridge ACLs don't filter traffic
# between instances on one bridge, so it still reaches the machine.
#
# Re-running is safe: an existing sidecar must be this machine's (its
# user.acfs.tailscale-for) and is reused as it is, a login is kept, a
# forward already in place is kept, and a different forward on a port is
# refused, never changed. The machine itself is never changed. The auth key reaches the
# sidecar on stdin into a file only root can read, and is removed when
# `tailscale up` returns; it is never in argv or in the output.
#
# Progress goes to stderr; stdout carries only the tailnet name.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

IMAGE="images:ubuntu/26.04/cloud"
SIDECAR_PREFIX="acfs-ts-"
# The sidecar's shape: unprivileged with its own uid/gid range, like the
# machine, and small. tailscaled in userspace mode needs well under this;
# the headroom is for apt during cloud-init.
SIDECAR_LAUNCH_ARGS=(-p default
    -c security.privileged=false -c security.nesting=false -c security.idmap.isolated=true
    -c limits.memory=512MiB -c limits.memory.enforce=hard -c limits.processes=1000
    -c boot.autostart=true)
ROOT_SIZE="4GiB"
STATE_SIZE="1GiB"
# Only the internet: the launcher and host-setup create it.
ACL_NAME="acfs-vm-egress"
TARGET_USER="ubuntu"
AUTH_KEY_PATH="/run/acfs-tailscale-authkey"
AGENT_TIMEOUT_SECONDS=300
CLOUD_INIT_TIMEOUT_SECONDS=600
INCUS_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/acfs/incus.env"

usage() {
    cat <<'EOF'
Usage: scripts/providers/incus.sh tailscale [<remote>:]<machine> [--auth-key-file FILE]
                                            [--port PORT]... [--hostname NAME]

Creates the sidecar container acfs-ts-<machine> next to the swarm machine
<machine>, logs it into your tailnet and forwards tailnet TCP port 22 (and
each --port) to the same port on the machine.

  --auth-key-file FILE  A file holding a Tailscale auth key (tskey-...).
                        Needed until the sidecar is logged in; its node
                        state then survives a rebuild of the sidecar.
  --port PORT           Another TCP port to forward (repeatable); 22 always is.
  --hostname NAME       The sidecar's name on the tailnet (default: <machine>).

Prints the sidecar's tailnet name. See scripts/providers/incus.md.
EOF
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# Every incus call goes through here: incus reads YAML from a non-TTY stdin
# and would otherwise block on an inherited pipe.
incus_run() {
    incus "$@" </dev/null
}

remote=""
machine=""
sidecar=""
hostname=""
auth_key_file=""
ports=(22)

parse_args() {
    local target="" port
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auth-key-file)
                [[ -n "${2:-}" ]] || die "--auth-key-file needs a file" 2
                auth_key_file="$2"
                shift 2
                ;;
            --port)
                port="${2:-}"
                [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) \
                    || die "--port needs a TCP port from 1 to 65535" 2
                [[ " ${ports[*]} " == *" $port "* ]] || ports+=("$port")
                shift 2
                ;;
            --hostname)
                [[ "${2:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
                    || die "--hostname needs a DNS label: letters, digits and dashes" 2
                hostname="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                die "unknown option: $1" 2
                ;;
            *)
                [[ -z "$target" ]] || die "one machine name only (got '$target' and '$1')" 2
                target="$1"
                shift
                ;;
        esac
    done

    [[ -n "$target" ]] || { usage >&2; die "missing machine name" 2; }
    if [[ "$target" == *:* ]]; then
        remote="${target%%:*}"
        machine="${target#*:}"
        [[ -n "$remote" ]] || die "empty remote in '$target'" 2
    else
        machine="$target"
    fi
    [[ "$machine" =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || die "invalid machine name '$machine': letters, digits and dashes, starting with a letter and not ending with a dash" 2
    sidecar="$SIDECAR_PREFIX$machine"
    ((${#sidecar} <= 63)) || die "the sidecar's name $sidecar is longer than Incus's 63 characters; the machine name must be at most $((63 - ${#SIDECAR_PREFIX}))" 2
    [[ -n "$hostname" ]] || hostname="$machine"
    if [[ -n "$auth_key_file" ]]; then
        check_auth_key_file
    fi
}

# Checks the key's shape without ever printing it.
check_auth_key_file() {
    local first mode
    [[ -f "$auth_key_file" && -r "$auth_key_file" ]] || die "--auth-key-file $auth_key_file: not a readable file" 2
    first="$(head -n 1 "$auth_key_file")"
    [[ "$first" =~ ^tskey-[A-Za-z0-9-]+$ ]] \
        || die "--auth-key-file $auth_key_file: its first line isn't a Tailscale auth key (tskey-...)" 2
    mode="$(stat -c %a "$auth_key_file" 2>/dev/null || stat -f %Lp "$auth_key_file")"
    [[ "$mode" =~ [0-7]00$ ]] || log_warn "$auth_key_file can be read by other users (mode $mode); chmod 600 it"
}

# The remote-qualified name of an Incus object, e.g. "r:dev" or "dev".
qualified() {
    printf '%s%s\n' "${remote:+$remote:}" "$1"
}

require_commands() {
    local cmd
    for cmd in incus jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required on this host" 2
    done
}

# One KEY=value line of host-setup's file, without the quotes host-setup
# may have put around the value. The file is never sourced.
incus_env_value() {
    sed -n "s/^$1=//p" "$INCUS_ENV_FILE" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

read_incus_env() {
    [[ -f "$INCUS_ENV_FILE" ]] \
        || die "$INCUS_ENV_FILE is missing: run 'scripts/providers/incus.sh host-setup --storage <path|pool>' on the Incus host first" 2
    ACFS_INCUS_POOL="$(incus_env_value ACFS_INCUS_POOL)"
    [[ "$ACFS_INCUS_POOL" =~ ^[A-Za-z0-9_.-]+$ ]] \
        || die "$INCUS_ENV_FILE sets no usable ACFS_INCUS_POOL; re-run 'scripts/providers/incus.sh host-setup --storage <path|pool>'" 2
}

# Prints the API object at $1, or nothing (status 1) when it doesn't exist.
api_get() {
    incus_run query "$(qualified "$1")" 2>/dev/null
}

# The machine's NIC must be on the default profile's managed bridge, which
# the sidecar joins; prints "<nic device> <network> <dns domain>".
machine_network() {
    local machine_json machine_network profile_nic nic network network_json domain
    machine_json="$(api_get "/1.0/instances/$machine")" \
        || die "the machine $(qualified "$machine") doesn't exist; create it with scripts/providers/incus.sh first" 1
    machine_network="$(jq -r '[.expanded_devices // {} | to_entries[] | select(.value.type == "nic") | .value.network // ""] | first // ""' <<<"$machine_json")"
    [[ -n "$machine_network" ]] || die "the machine $machine has no NIC on an Incus network" 1
    profile_nic="$(api_get /1.0/profiles/default \
        | jq -r '.devices | to_entries[] | select(.value.type == "nic") | "\(.key) \(.value.network // "")"' | head -n 1)"
    [[ -n "$profile_nic" ]] || die "the default profile has no NIC" 1
    nic="${profile_nic%% *}"
    network="${profile_nic#* }"
    [[ "$network" == "$machine_network" ]] \
        || die "the machine is on network '$machine_network', the default profile's NIC on '${network:-none}'; the sidecar joins the default profile's, so it couldn't reach the machine" 1
    network_json="$(api_get "/1.0/networks/$network")" || die "could not read network $network" 1
    jq -e '.managed == true and .type == "bridge"' <<<"$network_json" >/dev/null \
        || die "network '$network' isn't a managed bridge" 1
    [[ "$(jq -r '.config["dns.mode"] // "managed"' <<<"$network_json")" != none ]] \
        || die "network '$network' has dns.mode=none; the sidecar reaches the machine by its name on the bridge" 1
    domain="$(jq -r '.config["dns.domain"] // "incus"' <<<"$network_json")"
    printf '%s %s %s\n' "$nic" "$network" "$domain"
}

check_acl() {
    incus_run network acl show "$(qualified "$ACL_NAME")" >/dev/null 2>&1 \
        || die "network ACL $ACL_NAME doesn't exist; run 'scripts/providers/incus.sh host-setup' (or create the machine) first" 1
}

user_data() {
    # The drop-in comes first, so tailscaled's first start is already in
    # userspace mode; ExecStart is the package's, plus --tun.
    cat <<'EOF'
#cloud-config
package_update: true
packages: [ca-certificates, curl]
write_files:
  - path: /etc/systemd/system/tailscaled.service.d/acfs-userspace.conf
    content: |
      [Service]
      ExecStart=
      ExecStart=/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${PORT} --tun=userspace-networking $FLAGS
runcmd:
  - - sh
    - -ec
    - |
      codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
      curl -fsSL --proto =https "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
      curl -fsSL --proto =https "https://pkgs.tailscale.com/stable/ubuntu/$codename.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
      systemctl enable --now tailscaled
EOF
}

# The state volume is reused when it exists: it holds the node's login.
ensure_state_volume() {
    local volume="$sidecar-state"
    if api_get "/1.0/storage-pools/$ACFS_INCUS_POOL/volumes/custom/$volume" >/dev/null; then
        log_info "Using the existing volume $volume (the sidecar's node state) as it is"
        return 0
    fi
    log_info "Creating volume $volume on pool $ACFS_INCUS_POOL (size=$STATE_SIZE)"
    incus_run storage volume create "$(qualified "$ACFS_INCUS_POOL")" "$volume" "size=$STATE_SIZE" >/dev/null \
        || die "could not create volume $volume on pool $ACFS_INCUS_POOL" 1
}

# Creates the sidecar stopped, attaches its state and starts it. An existing
# sidecar must be this machine's; it is started if stopped, and its state
# device added if an earlier run stopped before that.
ensure_sidecar() {
    local nic="$1" sidecar_json owner
    if sidecar_json="$(api_get "/1.0/instances/$sidecar")"; then
        owner="$(jq -r '.config["user.acfs.tailscale-for"] // ""' <<<"$sidecar_json")"
        [[ "$owner" == "$machine" ]] \
            || die "an instance $sidecar exists that isn't this machine's sidecar (user.acfs.tailscale-for='$owner'); left untouched" 1
        log_info "Using the existing sidecar $(qualified "$sidecar")"
    else
        log_step "Creating the sidecar $(qualified "$sidecar") from $IMAGE (512 MiB, $ROOT_SIZE root on pool $ACFS_INCUS_POOL)"
        incus_run init "$IMAGE" "$(qualified "$sidecar")" "${SIDECAR_LAUNCH_ARGS[@]}" \
            -c "user.acfs.tailscale-for=$machine" \
            -c "cloud-init.user-data=$(user_data)" \
            -d "root,pool=$ACFS_INCUS_POOL" \
            -d "root,size=$ROOT_SIZE" \
            -d "$nic,security.acls=$ACL_NAME" \
            -d "$nic,security.acls.default.egress.action=allow" \
            -d "$nic,security.acls.default.ingress.action=allow" \
            >/dev/null || die "incus init failed" 1
        sidecar_json="$(api_get "/1.0/instances/$sidecar")" || die "the sidecar $sidecar vanished after incus init" 1
    fi
    if ! jq -e '.devices.state' <<<"$sidecar_json" >/dev/null; then
        incus_run config device add "$(qualified "$sidecar")" state disk \
            "pool=$ACFS_INCUS_POOL" "source=$sidecar-state" path=/var/lib/tailscale >/dev/null \
            || die "could not attach $sidecar-state at /var/lib/tailscale" 1
    fi
    if [[ "$(jq -r '.status // ""' <<<"$sidecar_json")" != Running ]]; then
        log_step "Starting $(qualified "$sidecar")"
        incus_run start "$(qualified "$sidecar")" || die "incus start failed" 1
    fi
}

sidecar_exec() {
    incus_run exec "$(qualified "$sidecar")" -- "$@"
}

wait_ready() {
    local deadline=$((SECONDS + AGENT_TIMEOUT_SECONDS)) output state exit_code
    log_step "Waiting for the sidecar to accept incus exec"
    until sidecar_exec true >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "the sidecar didn't accept incus exec within ${AGENT_TIMEOUT_SECONDS}s" 1
        sleep 3
    done
    deadline=$((SECONDS + CLOUD_INIT_TIMEOUT_SECONDS))
    log_step "Waiting for cloud-init (installs tailscale)"
    # As in incus.sh: `cloud-init status` exits 0 while running or done, 1 on
    # an error and 2 when done with recoverable errors.
    while :; do
        exit_code=0
        output="$(sidecar_exec cloud-init status 2>/dev/null)" || exit_code=$?
        state="$(sed -n 's/^status: //p' <<<"$output")"
        case "$state" in
            done)
                ((exit_code != 2)) || log_warn "cloud-init finished with recoverable errors; see: incus exec $(qualified "$sidecar") -- cloud-init status --long"
                break
                ;;
            error|disabled)
                die "cloud-init didn't finish cleanly (status: $state); see: incus exec $(qualified "$sidecar") -- cloud-init status --long" 1
                ;;
        esac
        ((SECONDS < deadline)) || die "cloud-init didn't finish within ${CLOUD_INIT_TIMEOUT_SECONDS}s; see: incus exec $(qualified "$sidecar") -- cloud-init status --long" 1
        sleep 3
    done
    sidecar_exec tailscale version >/dev/null 2>&1 \
        || die "tailscale isn't installed in the sidecar; see: incus exec $(qualified "$sidecar") -- cloud-init status --long" 1
}

# The sidecar must resolve the machine on the bridge, or serve can't dial it.
check_target() {
    local target="$1"
    sidecar_exec getent hosts "$target" >/dev/null 2>&1 \
        || die "the sidecar can't resolve $target; is the machine running?" 1
}

tailscale_status() {
    sidecar_exec tailscale status --json 2>/dev/null || true
}

# Logs in once. A sidecar that is logged in is left as it is; one that is
# logged in but down is brought up without a key.
ensure_login() {
    local backend
    backend="$(tailscale_status | jq -r '.BackendState // ""' 2>/dev/null || true)"
    case "$backend" in
        Running)
            log_info "The sidecar is already on the tailnet"
            return 0
            ;;
        Stopped)
            log_step "Bringing the sidecar up"
            sidecar_exec tailscale up "--hostname=$hostname" --accept-dns=false >&2 \
                || die "tailscale up failed in the sidecar" 1
            return 0
            ;;
        NeedsMachineAuth)
            die "the sidecar is logged in but waits for approval in the tailnet's admin console; approve $hostname there and re-run" 1
            ;;
    esac
    [[ -n "$auth_key_file" ]] \
        || die "the sidecar isn't logged in (state: ${backend:-unknown}); pass --auth-key-file with a Tailscale auth key" 2
    log_step "Logging the sidecar in as $hostname"
    # The key goes over stdin into a root-only file, which the same shell
    # removes whether or not `tailscale up` succeeds.
    incus exec "$(qualified "$sidecar")" -- sh -c "umask 077 && cat > $AUTH_KEY_PATH" <"$auth_key_file" \
        || die "could not pass the auth key to the sidecar" 1
    # shellcheck disable=SC2016 # $1 and $2 expand in the sidecar's shell
    sidecar_exec sh -c 'tailscale up --auth-key="file:$1" --hostname="$2" --accept-dns=false; s=$?; rm -f "$1"; exit "$s"' \
        sh "$AUTH_KEY_PATH" "$hostname" >&2 \
        || die "tailscale up failed in the sidecar (the key file there was removed)" 1
}

# Each port forwards to the same port on the machine. A forward already in
# place is kept; a different one on that port is refused, never replaced.
ensure_forwards() {
    local target="$1" serve_json port want have
    serve_json="$(sidecar_exec tailscale serve status --json 2>/dev/null || true)"
    [[ -n "$serve_json" ]] || serve_json='{}'
    for port in "${ports[@]}"; do
        want="$target:$port"
        have="$(jq -r --arg p "$port" '.TCP[$p].TCPForward // ""' <<<"$serve_json")"
        if [[ "$have" == "$want" ]]; then
            log_info "Tailnet port $port already forwards to $want"
            continue
        fi
        [[ -z "$have" ]] && ! jq -e --arg p "$port" '.TCP[$p]' <<<"$serve_json" >/dev/null \
            || die "tailnet port $port already serves something else (${have:-not a TCP forward}); left as it is" 1
        log_info "Forwarding tailnet port $port to $want"
        sidecar_exec tailscale serve --bg "--tcp=$port" "tcp://$want" >/dev/null \
            || die "tailscale serve failed for port $port" 1
    done
}

main() {
    parse_args "$@"
    require_commands
    read_incus_env
    local network_info nic domain target dns_name
    network_info="$(machine_network)"
    read -r nic _ domain <<<"$network_info"
    target="$machine.$domain"
    check_acl
    ensure_state_volume
    ensure_sidecar "$nic"
    wait_ready
    check_target "$target"
    ensure_login
    ensure_forwards "$target"
    dns_name="$(tailscale_status | jq -r '.Self.DNSName // ""' 2>/dev/null || true)"
    dns_name="${dns_name%.}"
    [[ -n "$dns_name" ]] || die "the sidecar reports no tailnet name" 1
    log_success "$(qualified "$machine") is on the tailnet as $dns_name: ssh $TARGET_USER@$dns_name"
    printf '%s\n' "$dns_name"
}

main "$@"
