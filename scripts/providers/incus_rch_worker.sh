#!/usr/bin/env bash
# ============================================================
# An rch build worker container (incus.sh rch-worker)
#
# Creates the unprivileged container <name> as a build worker for rch
# (remote_compilation_helper): hard CPU and memory limits, sshd, rsync, a
# C toolchain and Rust from rustup, and /data/projects and /data/tmp for
# the user, where rch mirrors the projects it builds. The dispatcher, the
# machine whose builds rch offloads, deploys rch's own worker binary and
# the projects' toolchains later with `rch workers setup`. This prints that
# machine's workers.toml block and known_hosts line. Run it on the machine
# you run incus.sh from.
#
# The worker gets the policy profile acfs-swarm (the pins, the low CPU
# priority, the sysinfo intercept, so cargo sees the worker's own CPUs)
# and its own hard limits. Its NIC carries acfs-swarm-egress (--acl changes
# it): the internet, for crates and toolchains, and no other private range
# but what that ACL allows. It has a fixed IPv4 address on the bridge,
# because an ACFS container's egress ACL lets it reach a worker only by
# address: `host-setup --rch-worker ADDR`.
#
# rustup's installer is checked in the container against the sha256 that
# checksums.yaml pins for it, before it runs.
#
# Re-running is safe: an existing worker must be one this made (its
# user.acfs.rch-worker) and is reused as it is. It is started if stopped,
# and its block is printed again; the options that apply only at creation
# are ignored then, with a warning. Nothing is ever changed on another
# instance, and nothing is deleted.
#
# Progress goes to stderr; stdout carries only the block.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

IMAGE="images:ubuntu/26.04/cloud"
SWARM_PROFILE="acfs-swarm"
# The pins a profile could loosen, as the launcher sets them, and a hard
# memory limit without swap: a build that outgrows the worker is killed
# there rather than slowing the host.
WORKER_LAUNCH_ARGS=(-p default -p "$SWARM_PROFILE"
    -c security.privileged=false -c security.nesting=false -c security.idmap.isolated=true
    -c limits.memory.enforce=hard -c limits.memory.swap=false)
# Per worker, set at creation: --cpus, --memory, --root-size.
CPUS=8
MEMORY="16GiB"
ROOT_SIZE="100GiB"
ACL_NAME="acfs-swarm-egress"
TARGET_USER="ubuntu"
# The private key's path on the dispatcher, for the printed block only.
# shellcheck disable=SC2088 # a path for the dispatcher's config, not this shell
IDENTITY_FILE="~/.ssh/id_ed25519"
AGENT_TIMEOUT_SECONDS=300
# Polls, 3 s apart, for the worker's address.
LEASE_POLLS=20
# The packages and a Rust toolchain take a few minutes.
CLOUD_INIT_TIMEOUT_SECONDS=1200
CHECKSUMS_YAML="$REPO_ROOT/checksums.yaml"
INCUS_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/acfs/incus.env"

usage() {
    cat <<'EOF'
Usage: scripts/providers/incus.sh rch-worker [<remote>:]<name> --ipv4 ADDR --ssh-key FILE [--ssh-key FILE]...
                                             [--identity-file PATH] [--cpus N] [--memory SIZE]
                                             [--root-size SIZE] [--acl NAME]

Creates the unprivileged container <name> as an rch build worker, and
prints the workers.toml block and known_hosts line for the dispatcher (the
machine whose builds rch offloads), plus the commands to run there.

  --ipv4 ADDR           The worker's fixed address on the default profile's
                        bridge. Needed when the worker doesn't exist yet.
                        Pass the same address to host-setup --rch-worker, so
                        ACFS containers may reach the worker over SSH.
  --ssh-key FILE        The dispatcher's public key, which rch logs in with
                        (repeatable). Needed when the worker doesn't exist yet.
  --identity-file PATH  The matching private key's path on the dispatcher,
                        printed into the block (default: ~/.ssh/id_ed25519).
  --cpus N              CPUs the worker may use (default 8); the block's
                        total_slots starts there.
  --memory SIZE         Its hard memory limit, without swap (default 16GiB).
  --root-size SIZE      Its root disk on the pool (default 100GiB): the
                        projects and their build caches.
  --acl NAME            The egress ACL on its NIC (default acfs-swarm-egress).

The address, keys, limits, size and ACL apply only when the worker is
created; an existing one keeps them. Every run needs the file host-setup
writes (~/.config/acfs/incus.env). See scripts/providers/incus.md.
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
name=""
ipv4=""
identity_file="$IDENTITY_FILE"
acl_name="$ACL_NAME"
ssh_key_files=()
# Set when the caller gave an option that applies only at creation.
creation_options=""

parse_args() {
    local target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ipv4)
                ipv4_to_int "${2:-}" >/dev/null || die "--ipv4 needs an IPv4 address" 2
                ipv4="$2"
                creation_options=1
                shift 2
                ;;
            --ssh-key)
                [[ -n "${2:-}" ]] || die "--ssh-key needs a file" 2
                ssh_key_files+=("$2")
                creation_options=1
                shift 2
                ;;
            --identity-file)
                # It is printed between TOML quotes.
                [[ "${2:-}" =~ ^[^\"\\[:space:]]+$ ]] || die "--identity-file needs a path without quotes, backslashes or spaces" 2
                identity_file="$2"
                shift 2
                ;;
            --cpus)
                [[ "${2:-}" =~ ^[1-9][0-9]{0,3}$ ]] || die "--cpus needs a whole number of CPUs" 2
                CPUS="$2"
                creation_options=1
                shift 2
                ;;
            --memory)
                [[ "${2:-}" =~ ^[1-9][0-9]*(MiB|GiB|TiB)$ ]] || die "--memory needs a size such as 16GiB" 2
                MEMORY="$2"
                creation_options=1
                shift 2
                ;;
            --root-size)
                [[ "${2:-}" =~ ^[1-9][0-9]*(MiB|GiB|TiB)$ ]] || die "--root-size needs a size such as 100GiB" 2
                ROOT_SIZE="$2"
                creation_options=1
                shift 2
                ;;
            --acl)
                [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--acl needs an ACL name" 2
                acl_name="$2"
                creation_options=1
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
                [[ -z "$target" ]] || die "one worker name only (got '$target' and '$1')" 2
                target="$1"
                shift
                ;;
        esac
    done

    [[ -n "$target" ]] || { usage >&2; die "missing worker name" 2; }
    if [[ "$target" == *:* ]]; then
        remote="${target%%:*}"
        name="${target#*:}"
        [[ -n "$remote" ]] || die "empty remote in '$target'" 2
    else
        name="$target"
    fi
    [[ "$name" =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || die "invalid worker name '$name': letters, digits and dashes, starting with a letter and not ending with a dash" 2
}

# The remote-qualified name of an Incus object, e.g. "r:rch-w1" or "rch-w1".
qualified() {
    printf '%s%s\n' "${remote:+$remote:}" "$1"
}

ipv4_to_int() {
    local a b c d
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
    ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255)) || return 1
    printf '%d\n' $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

require_commands() {
    local cmd
    for cmd in incus jq ssh-keygen; do
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

# Validates each --ssh-key file, logs its fingerprints and prints its keys
# as a JSON array.
read_public_keys() {
    local file fingerprints line
    for file in "${ssh_key_files[@]}"; do
        [[ -f "$file" && -r "$file" ]] || die "--ssh-key $file: not a readable file" 2
        ! grep -q 'PRIVATE KEY' "$file" || die "--ssh-key $file is a private key; pass the .pub file" 2
        fingerprints="$(ssh-keygen -l -f "$file" 2>/dev/null)" \
            || die "--ssh-key $file: not an OpenSSH public key" 2
        while IFS= read -r line; do
            log_info "Authorizing for $TARGET_USER: $line ($file)"
        done <<<"$fingerprints"
        grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$file"
    done | jq -R . | jq -sc .
}

# The URL and sha256 checksums.yaml pins for rustup's installer (its
# "rust" entry), as "<url> <sha256>".
rustup_pin() {
    local url sha
    [[ -r "$CHECKSUMS_YAML" ]] || die "$CHECKSUMS_YAML is missing; it pins rustup's installer" 1
    url="$(sed -n '/^  rust:$/,/^$/s/^    url: "\(.*\)"$/\1/p' "$CHECKSUMS_YAML" | head -n 1)"
    sha="$(sed -n '/^  rust:$/,/^$/s/^    sha256: "\(.*\)"$/\1/p' "$CHECKSUMS_YAML" | head -n 1)"
    [[ "$url" =~ ^https://[A-Za-z0-9./_-]+$ && "$sha" =~ ^[0-9a-f]{64}$ ]] \
        || die "$CHECKSUMS_YAML has no usable 'rust' entry (url and sha256) for rustup's installer" 1
    printf '%s %s\n' "$url" "$sha"
}

check_swarm_profile() {
    incus_run profile show "$(qualified "$SWARM_PROFILE")" >/dev/null 2>&1 \
        || die "profile $SWARM_PROFILE doesn't exist: run 'scripts/providers/incus.sh host-setup' on the Incus host first" 1
}

check_acl() {
    incus_run network acl show "$(qualified "$acl_name")" >/dev/null 2>&1 \
        || die "network ACL $acl_name doesn't exist; run 'scripts/providers/incus.sh host-setup' on the Incus host first" 1
}

# The default profile's NIC must be on a managed bridge, and --ipv4 a host
# address in its subnet other than the gateway's. Prints the NIC's name.
check_bridge_address() {
    local profile_nic nic network network_json address gw n prefix mask base want
    profile_nic="$(api_get /1.0/profiles/default \
        | jq -r '.devices | to_entries[] | select(.value.type == "nic") | "\(.key) \(.value.network // "")"' | head -n 1)"
    [[ -n "$profile_nic" ]] || die "the default profile has no NIC" 1
    nic="${profile_nic%% *}"
    network="${profile_nic#* }"
    [[ -n "$network" ]] || die "the default profile's NIC '$nic' isn't on an Incus network; a fixed address needs a managed bridge" 1
    network_json="$(api_get "/1.0/networks/$network")" || die "could not read network $network" 1
    jq -e '.managed == true and .type == "bridge"' <<<"$network_json" >/dev/null \
        || die "network '$network' isn't a managed bridge; a fixed address needs one" 1
    address="$(jq -r '.config["ipv4.address"] // ""' <<<"$network_json")"
    [[ "$address" =~ ^([0-9.]+)/([0-9]{1,2})$ ]] && gw="$(ipv4_to_int "${BASH_REMATCH[1]}")" \
        && prefix="${BASH_REMATCH[2]}" && ((prefix >= 8 && prefix <= 30)) \
        || die "network '$network' has no usable IPv4 subnet (ipv4.address='$address')" 1
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    base=$((gw & mask))
    n="$(ipv4_to_int "$ipv4")"
    want="--ipv4 $ipv4 must be a host address in $network's subnet $address"
    ((((n & mask) == base) && n != base && n != (base | (~mask & 0xFFFFFFFF)))) || die "$want" 2
    ((n != gw)) || die "$want, not the gateway's" 2
    printf '%s\n' "$nic"
}

user_data() {
    local keys_json="$1" rustup_url="$2" rustup_sha="$3"
    printf '#cloud-config\n'
    printf 'package_update: true\n'
    printf 'packages: [openssh-server, rsync, zstd, build-essential, pkg-config, libssl-dev, cmake, git, curl, ca-certificates]\n'
    printf 'ssh_authorized_keys:\n'
    jq -r '.[] | "  - " + (. | tojson)' <<<"$keys_json"
    # rustup's installer runs only when its sha256 is the pinned one, as the
    # user, so ~/.cargo and ~/.rustup are the user's.
    cat <<EOF
runcmd:
  - - sh
    - -ec
    - |
      install -d -m 0755 /data
      install -d -o $TARGET_USER -g $TARGET_USER -m 0755 /data/projects /data/tmp
      curl -fsSL --proto =https --tlsv1.2 "$rustup_url" -o /root/rustup-init.sh
      echo "$rustup_sha  /root/rustup-init.sh" | sha256sum -c -
      install -o $TARGET_USER -g $TARGET_USER -m 0755 /root/rustup-init.sh /home/$TARGET_USER/.rustup-init.sh
      runuser -u $TARGET_USER -- env HOME=/home/$TARGET_USER sh /home/$TARGET_USER/.rustup-init.sh -y --profile minimal --default-toolchain stable -c clippy -c rustfmt
      rm -f /root/rustup-init.sh /home/$TARGET_USER/.rustup-init.sh
EOF
}

# Creates the worker stopped with its limits, disk, address and ACL, marks
# it as this script's, and starts it.
create_worker() {
    local nic="$1" keys_json="$2" rustup_url="$3" rustup_sha="$4"
    log_step "Creating the rch worker $(qualified "$name") from $IMAGE ($CPUS CPUs, $MEMORY hard, $ROOT_SIZE root on pool $ACFS_INCUS_POOL, $ipv4 behind $acl_name)"
    incus_run init "$IMAGE" "$(qualified "$name")" "${WORKER_LAUNCH_ARGS[@]}" \
        -c "limits.cpu=$CPUS" \
        -c "limits.memory=$MEMORY" \
        -c "user.acfs.rch-worker=true" \
        -c "cloud-init.user-data=$(user_data "$keys_json" "$rustup_url" "$rustup_sha")" \
        -d "root,pool=$ACFS_INCUS_POOL" \
        -d "root,size=$ROOT_SIZE" \
        -d "$nic,ipv4.address=$ipv4" \
        -d "$nic,security.acls=$acl_name" \
        -d "$nic,security.acls.default.egress.action=allow" \
        -d "$nic,security.acls.default.ingress.action=allow" \
        >/dev/null || die "incus init failed" 1
    log_step "Starting $(qualified "$name")"
    incus_run start "$(qualified "$name")" || die "incus start failed" 1
}

# An existing worker must be this script's; its address is read from its
# NIC. It is started if stopped.
reuse_worker() {
    local json="$1"
    jq -e '.config["user.acfs.rch-worker"] == "true"' <<<"$json" >/dev/null \
        || die "an instance $(qualified "$name") exists that isn't an rch worker made by this script (no user.acfs.rch-worker); left untouched" 1
    log_info "Using the existing rch worker $(qualified "$name") as it is"
    [[ -z "$creation_options" ]] \
        || log_warn "--ipv4, --ssh-key, --cpus, --memory, --root-size and --acl apply only when the worker is created; $(qualified "$name") keeps what it has"
    ipv4="$(jq -r '[.expanded_devices // {} | .[] | select(.type == "nic") | .["ipv4.address"] // empty][0] // ""' <<<"$json")"
    ipv4_to_int "$ipv4" >/dev/null || die "the worker's NIC has no fixed IPv4 address (ipv4.address)" 1
    # A count gives the block's total_slots; a CPU set (0-7) gives none,
    # and rch uses its default.
    CPUS="$(jq -r '.config["limits.cpu"] // ""' <<<"$json")"
    [[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || CPUS=""
    if [[ "$(jq -r '.status // ""' <<<"$json")" != Running ]]; then
        log_step "Starting $(qualified "$name")"
        incus_run start "$(qualified "$name")" || die "incus start failed" 1
    fi
}

worker_exec() {
    incus_run exec "$(qualified "$name")" -- "$@"
}

wait_ready() {
    local deadline=$((SECONDS + AGENT_TIMEOUT_SECONDS)) poll output state exit_code
    log_step "Waiting for the worker to accept incus exec"
    until worker_exec true >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "the worker didn't accept incus exec within ${AGENT_TIMEOUT_SECONDS}s" 1
        sleep 3
    done

    # Its fixed address comes by DHCP too; without it cloud-init can't fetch
    # anything, so this stops here rather than at cloud-init's timeout.
    log_step "Waiting for the worker's address $ipv4"
    for ((poll = 1; ; poll++)); do
        api_get "/1.0/instances/$name/state" \
            | jq -e --arg ip "$ipv4" '[.network // {} | .[] | .addresses[]? | select(.family == "inet" and .address == $ip)] | length > 0' \
                >/dev/null 2>&1 && break
        ((poll < LEASE_POLLS)) \
            || die "the worker doesn't have its address $ipv4 about $((LEASE_POLLS * 3))s after its start: no DHCP lease. Check the ACL on its NIC ($acl_name) and the bridge: incus config device show $(qualified "$name")" 1
        sleep 3
    done

    deadline=$((SECONDS + CLOUD_INIT_TIMEOUT_SECONDS))
    log_step "Waiting for cloud-init (packages, rustup)"
    # As in incus.sh: `cloud-init status` exits 0 while running or done, 1 on
    # an error and 2 when done with recoverable errors.
    while :; do
        exit_code=0
        output="$(worker_exec cloud-init status 2>/dev/null)" || exit_code=$?
        state="$(sed -n 's/^status: //p' <<<"$output")"
        case "$state" in
            done)
                ((exit_code != 2)) || log_warn "cloud-init finished with recoverable errors; see: incus exec $(qualified "$name") -- cloud-init status --long"
                break
                ;;
            error|disabled)
                die "cloud-init didn't finish cleanly (status: $state); see: incus exec $(qualified "$name") -- cloud-init status --long" 1
                ;;
        esac
        ((SECONDS < deadline)) || die "cloud-init didn't finish within ${CLOUD_INIT_TIMEOUT_SECONDS}s; see: incus exec $(qualified "$name") -- cloud-init status --long" 1
        sleep 3
    done
}

# What rch needs before `rch workers setup`: rsync, and a Rust toolchain
# that `rustup run` finds.
check_worker() {
    local rustc
    worker_exec rsync --version >/dev/null 2>&1 \
        || die "rsync isn't installed in the worker; see: incus exec $(qualified "$name") -- cloud-init status --long" 1
    rustc="$(worker_exec runuser -u "$TARGET_USER" -- env "HOME=/home/$TARGET_USER" \
        "/home/$TARGET_USER/.cargo/bin/rustup" run stable rustc --version 2>/dev/null)" \
        || die "the worker has no Rust toolchain for $TARGET_USER; see: incus exec $(qualified "$name") -- cloud-init status --long" 1
    log_info "The worker has rsync and $rustc"
}

print_block() {
    local host_key
    host_key="$(worker_exec cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1, $2}')"
    [[ "$host_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+$ ]] || die "could not read the worker's SSH host key" 1
    log_success "$(qualified "$name") is ready as an rch worker at $ipv4"
    log_info "ACFS containers reach it once their ACL allows it: host-setup --rch-worker $ipv4 (see scripts/providers/incus.md for a host already set up)"
    printf '# Add to ~/.config/rch/workers.toml on the dispatcher (the machine whose builds rch offloads):\n'
    printf '[[workers]]\n'
    printf 'id = "%s"\n' "$name"
    printf 'host = "%s"\n' "$ipv4"
    printf 'user = "%s"\n' "$TARGET_USER"
    printf 'identity_file = "%s"\n' "$identity_file"
    [[ -z "$CPUS" ]] || printf 'total_slots = %s\n' "$CPUS"
    printf '# Add to ~/.ssh/known_hosts on the dispatcher:\n'
    printf '%s %s\n' "$ipv4" "$host_key"
    printf '# Then run there (rch-wkr and the toolchains), and set total_slots and priority from the benchmark:\n'
    printf 'rch workers setup %s\n' "$name"
    printf 'rch workers benchmark %s\n' "$name"
}

main() {
    parse_args "$@"
    require_commands
    read_incus_env
    local json nic keys_json pin
    if json="$(api_get "/1.0/instances/$name")"; then
        reuse_worker "$json"
    else
        [[ -n "$ipv4" ]] || die "--ipv4 is needed to create the worker $(qualified "$name")" 2
        ((${#ssh_key_files[@]} > 0)) || die "--ssh-key is needed to create the worker $(qualified "$name")" 2
        keys_json="$(read_public_keys)"
        pin="$(rustup_pin)"
        check_swarm_profile
        check_acl
        nic="$(check_bridge_address)"
        create_worker "$nic" "$keys_json" "${pin%% *}" "${pin#* }"
    fi
    wait_ready
    check_worker
    print_block
}

main "$@"
