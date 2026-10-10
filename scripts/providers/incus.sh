#!/usr/bin/env bash
# ============================================================
# ACFS in an Incus system container or VM
#
# Creates an unprivileged Ubuntu system container (or, with --vm, a VM) with
# Incus, runs the ACFS installer inside it from this checkout, and prints
# the ssh_config entry and the `herdr machine add` command for attaching to
# it. The guide is scripts/providers/incus.md.
#
# A container is a swarm machine: it gets the policy profile acfs-swarm
# (pins, limits, sysinfo intercept) that `host-setup` created, the egress
# ACL acfs-swarm-egress, and two volumes of its own on the pool host-setup
# recorded: acfs-state-<name>, which holds the home and the host identities
# so logins survive a rebuild, and <name>-data for /data. Both are attached
# before the first boot, so cloud-init and the installer land on the final
# layout. A VM keeps the launcher's earlier shape, until --vm goes.
#
# Re-running it is safe: an absent instance is created, an instance where it
# started an install that never completed resumes it, an instance that is
# installed is never changed (the block is printed again), and any other
# instance is refused untouched. An existing volume is reused as it is. It
# never deletes an instance, volume, image, profile or ACL.
#
# Progress goes to stderr; stdout carries only the attach block.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

IMAGE="images:ubuntu/26.04/cloud"
# The VM's shape: its limits are its own, since the swarm profile is for
# containers. A container pins the security keys a profile could loosen:
# unprivileged, no nesting, and its own uid/gid range, so root in one ACFS
# container is no uid of another. Its limits come from the profile.
VM_LAUNCH_ARGS=(--vm -c limits.cpu=4 -c limits.memory=8GiB)
CONTAINER_LAUNCH_ARGS=(-p default -p acfs-swarm
    -c security.privileged=false -c security.nesting=false -c security.idmap.isolated=true)
SWARM_PROFILE="acfs-swarm"
# Defaults for what is per machine, not policy; --root-size, --state-size
# and --data-size change them at creation.
ROOT_SIZE="40GiB"
STATE_SIZE="20GiB"
DATA_SIZE="60GiB"
# The container target needs the state layer's sub-path mounts, the sysinfo
# intercept and the restricted test project; the two optional extensions
# only add knobs the profile may use. The server is judged by the API
# extensions it reports, never by its version string (the operator,
# 2026-10-10: Ubuntu 26.04's 6.0.5 has what phase 1 needs).
REQUIRED_API_EXTENSIONS=(disk_volume_subpath container_syscall_intercept_sysinfo projects_networks_restricted_access)
OPTIONAL_API_EXTENSIONS=(instance_limits_oom container_disk_tmpfs)
# Written by `host-setup`; every run reads it.
INCUS_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/acfs/incus.env"

REPO_OWNER="arosl"
REPO_NAME="agentic_coding_flywheel_setup"
TARGET_USER="ubuntu"
TARGET_UID=1000
TARGET_GID=1000
# The ACLs: host-setup creates both; the launcher creates only the VM's,
# which needs no address of the host.
VM_ACL_NAME="acfs-vm-egress"
SWARM_ACL_NAME="acfs-swarm-egress"
# Private, CGNAT (tailnet) and link-local ranges: the host's LAN and tailnet,
# and the host and other instances over the bridge's IPv6 link-local.
ACL_REJECT_DESTINATIONS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,fc00::/7,fe80::/10"
AGENT_TIMEOUT_SECONDS=300
CLOUD_INIT_TIMEOUT_SECONDS=600
# Runs "$@" in the instance so that Ctrl-C stops it. A non-interactive incus exec
# passes SIGINT to the remote pid alone, and a bash waiting on a child
# doesn't pass it on, so the installer would carry on. This gives "$@" its
# own process group and signals that whole group; the client then exits 130.
# tests/vm/test_incus_provider.sh reads this line.
REMOTE_GROUP_WRAPPER='set -m; "$@" & p=$!; trap "kill -INT -- -$p" INT TERM HUP; wait "$p"; s=$?; wait "$p" 2>/dev/null; exit "$s"'

usage() {
    cat <<'EOF'
Usage: scripts/providers/incus.sh [<remote>:]<name> --ssh-key FILE [--ssh-key FILE]... [--jump SSH_HOST]
                                  [--vm] [--acl NAME] [--root-size SIZE] [--state-size SIZE] [--data-size SIZE]
       scripts/providers/incus.sh host-setup --storage <path|pool> [...]

Creates the unprivileged Incus system container <name>, installs ACFS in it
from this checkout's committed HEAD, and prints the ssh_config entry and
`herdr machine add` command for the machine you attach from.

  --ssh-key FILE     Public key of the machine you'll attach from (repeatable).
                     Required when the instance doesn't exist yet.
  --jump SSH_HOST    How that machine reaches the Incus host over SSH. Without
                     it, the entry works only on the Incus host itself.
  --vm               Create a VM instead: its own kernel behind KVM, with the
                     launcher's fixed limits and no state or data volume.
  --acl NAME         The egress ACL on the instance's NIC. Default:
                     acfs-swarm-egress for a container, acfs-vm-egress for a VM.
  --root-size SIZE   Root disk size (default 40GiB).
  --state-size SIZE  Size of the volume acfs-state-<name> (default 20GiB):
                     the home, the SSH host keys and Tailscale's state.
  --data-size SIZE   Size of the volume <name>-data, mounted at /data (default 60GiB).

The type, the ACL and the sizes apply only when the instance is created; an
existing one keeps them. Every run needs the file host-setup writes
(~/.config/acfs/incus.env), which names the storage pool.

Re-running is safe: an unfinished install resumes, and an installed instance
is left as it is. See scripts/providers/incus.md.
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
jump=""
vm=""
acl_name=""
ssh_key_files=()
# Set when the caller gave an option that applies only at creation.
creation_options=""
# What the messages call the instance: "VM" or "container".
kind="container"

parse_args() {
    local target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh-key)
                [[ -n "${2:-}" ]] || die "--ssh-key needs a file" 2
                ssh_key_files+=("$2")
                shift 2
                ;;
            --jump)
                [[ -n "${2:-}" ]] || die "--jump needs an SSH host" 2
                jump="$2"
                shift 2
                ;;
            --vm)
                vm=1
                creation_options=1
                shift
                ;;
            --acl)
                [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--acl needs an ACL name" 2
                acl_name="$2"
                creation_options=1
                shift 2
                ;;
            --root-size|--state-size|--data-size)
                [[ "${2:-}" =~ ^[0-9]+[KMGT]i?B$ ]] || die "$1 needs a size such as 100GiB" 2
                case "$1" in
                    --root-size) ROOT_SIZE="$2" ;;
                    --state-size) STATE_SIZE="$2" ;;
                    --data-size) DATA_SIZE="$2" ;;
                esac
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
                [[ -z "$target" ]] || die "one instance name only (got '$target' and '$1')" 2
                target="$1"
                shift
                ;;
        esac
    done

    [[ -n "$target" ]] || { usage >&2; die "missing instance name" 2; }
    if [[ "$target" == *:* ]]; then
        remote="${target%%:*}"
        name="${target#*:}"
        [[ -n "$remote" ]] || die "empty remote in '$target'" 2
    else
        name="$target"
    fi
    [[ "$name" =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || die "invalid instance name '$name': letters, digits and dashes, starting with a letter and not ending with a dash" 2
    [[ "$jump" =~ ^[^[:space:]]*$ ]] || die "--jump must not contain whitespace" 2
    if [[ -z "$acl_name" ]]; then
        if [[ -n "$vm" ]]; then acl_name="$VM_ACL_NAME"; else acl_name="$SWARM_ACL_NAME"; fi
    fi
}

# The remote-qualified name of an Incus object, e.g. "r:dev" or "dev".
qualified() {
    printf '%s%s\n' "${remote:+$remote:}" "$1"
}

require_commands() {
    local cmd
    for cmd in incus git jq ssh-keygen; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required on this host" 2
    done
}

# One KEY=value line of host-setup's file, without the quotes host-setup
# may have put around the value. The file is never sourced.
incus_env_value() {
    sed -n "s/^$1=//p" "$INCUS_ENV_FILE" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# The storage pool every instance and volume goes on. host-setup chose it
# with the operator, so a run without the file has nowhere to put them.
read_incus_env() {
    [[ -f "$INCUS_ENV_FILE" ]] \
        || die "$INCUS_ENV_FILE is missing: run 'scripts/providers/incus.sh host-setup --storage <path|pool>' on the Incus host first; it records the storage pool every instance uses" 2
    ACFS_INCUS_POOL="$(incus_env_value ACFS_INCUS_POOL)"
    [[ "$ACFS_INCUS_POOL" =~ ^[A-Za-z0-9_.-]+$ ]] \
        || die "$INCUS_ENV_FILE sets no usable ACFS_INCUS_POOL; re-run 'scripts/providers/incus.sh host-setup --storage <path|pool>'" 2
}

# Prints the instance's `incus list` JSON object, or nothing when it doesn't exist.
instance_json() {
    local list_args=(list)
    [[ -z "$remote" ]] || list_args+=("$remote:")
    list_args+=("^${name}\$" -f json)
    incus_run "${list_args[@]}" | jq -c --arg name "$name" '.[] | select(.name == $name)'
}

# Validates each --ssh-key file, logs its fingerprints and prints its keys,
# one per line.
read_public_keys() {
    local file fingerprints line
    for file in "${ssh_key_files[@]}"; do
        [[ -f "$file" && -r "$file" ]] || die "--ssh-key $file: not a readable file" 2
        if grep -q 'PRIVATE KEY' "$file"; then
            die "--ssh-key $file is a private key; pass the .pub file" 2
        fi
        fingerprints="$(ssh-keygen -l -f "$file" 2>/dev/null)" \
            || die "--ssh-key $file: not an OpenSSH public key" 2
        while IFS= read -r line; do
            log_info "Authorizing for $TARGET_USER: $line ($file)"
        done <<<"$fingerprints"
        grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$file"
    done
}

user_data() {
    local keys_json="$1"
    # No ssh_pwauth: cloud-init would write it into a fresh sshd_config before
    # openssh-server is installed, and the package then keeps that one-line
    # file (no UsePAM, no Include). The packaged config is what ACFS expects.
    printf '#cloud-config\n'
    printf 'package_update: true\n'
    printf 'packages: [openssh-server, curl, git, jq, ca-certificates, unzip]\n'
    printf 'ssh_authorized_keys:\n'
    jq -r '.[] | "  - " + (. | tojson)' <<<"$keys_json"
}

# A container needs what the state layer and the swarm profile use; a
# server that lacks an extension is refused by its name, before anything
# is created. The version is only named in the messages.
check_server() {
    local server_json version ext
    server_json="$(incus_run query "$(qualified /1.0)")" || die "could not query the Incus server" 1
    version="$(jq -r '.environment.server_version // "unknown"' <<<"$server_json")"
    jq -e '.api_extensions | type == "array"' <<<"$server_json" >/dev/null \
        || die "the Incus server reports no api_extensions (incus query /1.0)" 1
    for ext in "${REQUIRED_API_EXTENSIONS[@]}"; do
        jq -e --arg ext "$ext" '.api_extensions | index($ext) != null' <<<"$server_json" >/dev/null \
            || die "Incus $version lacks the API extension $ext, which a container needs; see scripts/providers/incus.md" 1
    done
    for ext in "${OPTIONAL_API_EXTENSIONS[@]}"; do
        jq -e --arg ext "$ext" '.api_extensions | index($ext) != null' <<<"$server_json" >/dev/null \
            || log_info "Incus $version lacks the optional API extension $ext; the profile keys that need it stay unset"
    done
    log_info "Incus $version has what a container needs"
}

check_swarm_profile() {
    incus_run profile show "$(qualified "$SWARM_PROFILE")" >/dev/null 2>&1 \
        || die "profile $SWARM_PROFILE doesn't exist: run 'scripts/providers/incus.sh host-setup' on the Incus host; it creates the policy profile every container gets" 1
}

# The ACL needs a managed bridge; a NIC on anything else can't carry it.
check_managed_bridge() {
    local profile_nic network network_json
    profile_nic="$(incus_run query "$(qualified /1.0/profiles/default)" \
        | jq -r '.devices | to_entries[] | select(.value.type == "nic") | "\(.key) \(.value.network // "")"' | head -n 1)"
    [[ -n "$profile_nic" ]] || die "the default profile has no NIC" 1
    network="${profile_nic#* }"
    [[ -n "$network" ]] || die "the default profile's NIC '${profile_nic%% *}' isn't on an Incus network; the egress ACL needs a managed bridge" 1
    network_json="$(incus_run query "$(qualified "/1.0/networks/$network")")"
    jq -e '.managed == true and .type == "bridge"' <<<"$network_json" >/dev/null \
        || die "network '$network' isn't a managed bridge; the egress ACL needs one" 1
    printf '%s\n' "${profile_nic%% *}"
}

# An existing ACL is never changed. The VM's ACL is created when absent;
# any other must exist already: the swarm ACL allows the host's API and
# the test bridge by address, which host-setup knows and this doesn't.
ensure_acl() {
    if incus_run network acl show "$(qualified "$acl_name")" >/dev/null 2>&1; then
        log_info "Using the existing network ACL $acl_name as it is (its rules aren't checked)"
        return 0
    fi
    [[ "$acl_name" == "$VM_ACL_NAME" ]] \
        || die "network ACL $acl_name doesn't exist; host-setup creates $SWARM_ACL_NAME and $VM_ACL_NAME, and this launcher creates only $VM_ACL_NAME" 1
    log_info "Creating network ACL $acl_name (rejects egress to $ACL_REJECT_DESTINATIONS)"
    # The one incus call whose stdin is meant: the ACL's YAML.
    # --quiet: the client reports the creation on stdout, which is the block's.
    incus network acl create --quiet "$(qualified "$acl_name")" <<EOF || die "could not create network ACL $acl_name" 1
description: "ACFS instances: no egress to private, CGNAT or link-local ranges"
egress:
  - action: reject
    destination: $ACL_REJECT_DESTINATIONS
    state: enabled
EOF
}

# Creates the custom volume $1 of size $2 on the pool, unless it exists: a
# volume left by an earlier instance of this name is the state a rebuild
# is meant to keep, so it is reused, and its size is never changed.
ensure_volume() {
    local volume="$1" size="$2"
    if incus_run storage volume show "$(qualified "$ACFS_INCUS_POOL")" "$volume" >/dev/null 2>&1; then
        log_info "Using the existing volume $volume on pool $ACFS_INCUS_POOL as it is (its size isn't changed)"
        return 0
    fi
    log_info "Creating volume $volume on pool $ACFS_INCUS_POOL (size=$size)"
    incus_run storage volume create "$(qualified "$ACFS_INCUS_POOL")" "$volume" "size=$size" >/dev/null \
        || die "could not create volume $volume on pool $ACFS_INCUS_POOL" 1
}

# Adds the disk device $1 mounting $2 (a volume, or volume/sub-path) at $3,
# owned by $4:$5 with mode $6 when Incus first creates the sub-path.
add_volume_device() {
    local device="$1" source="$2" path="$3" uid="$4" gid="$5" mode="$6"
    incus_run config device add "$(qualified "$name")" "$device" disk \
        "pool=$ACFS_INCUS_POOL" "source=$source" "path=$path" \
        "initial.uid=$uid" "initial.gid=$gid" "initial.mode=$mode" >/dev/null \
        || die "could not add the disk device $device ($source at $path)" 1
}

# The state layer and /data, on before the first boot so cloud-init makes
# the user's home on the volume and the installer lands on the final layout.
# .acfs/ holds the volume's lease, lock and journal for the guest's
# `acfs state` and its boot-time lease check.
attach_volumes() {
    local state="acfs-state-$name" data="$name-data"
    log_step "Attaching $state (home, SSH host keys, Tailscale, lease) and $data (/data)"
    add_volume_device state-home "$state/home" "/home/$TARGET_USER" "$TARGET_UID" "$TARGET_GID" 0700
    add_volume_device state-ssh-host "$state/root/ssh-host" /etc/ssh/acfs-host-keys 0 0 0700
    add_volume_device state-tailscale "$state/root/tailscale" /var/lib/tailscale 0 0 0700
    add_volume_device state-acfs "$state/.acfs" /etc/acfs/state 0 0 0700
    add_volume_device data "$data" /data "$TARGET_UID" "$TARGET_GID" 0755
}

# The lease that binds the state volume to this one instance: the guest
# claims it into the volume on first boot and refuses to start the user
# manager when the volume holds another instance's. The launcher only sets
# the key; it never writes into the volume, and it never prints the token.
set_lease() {
    local token
    token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || die "could not make a lease token" 1
    incus_run config set "$(qualified "$name")" "user.acfs.lease=$token" \
        || die "could not record user.acfs.lease" 1
}

# Creates the instance stopped, attaches what is per machine, marks it and
# starts it. The install-started mark comes last, so an instance this
# stopped halfway through is refused on a re-run rather than booted
# without its volumes.
create_instance() {
    local keys_json="$1" sha="$2" nic launch_args
    nic="$(check_managed_bridge)"
    ensure_acl
    if [[ -n "$vm" ]]; then
        launch_args=("${VM_LAUNCH_ARGS[@]}")
        log_step "Creating VM $(qualified "$name") from $IMAGE (4 vCPU, 8 GiB RAM, $ROOT_SIZE disk on pool $ACFS_INCUS_POOL)"
    else
        check_server
        check_swarm_profile
        ensure_volume "acfs-state-$name" "$STATE_SIZE"
        ensure_volume "$name-data" "$DATA_SIZE"
        launch_args=("${CONTAINER_LAUNCH_ARGS[@]}")
        log_step "Creating unprivileged container $(qualified "$name") from $IMAGE with profile $SWARM_PROFILE ($ROOT_SIZE root on pool $ACFS_INCUS_POOL, where the pool enforces it)"
    fi
    incus_run init "$IMAGE" "$(qualified "$name")" "${launch_args[@]}" \
        -c user.acfs.provider=incus \
        -c "cloud-init.user-data=$(user_data "$keys_json")" \
        -d "root,pool=$ACFS_INCUS_POOL" \
        -d "root,size=$ROOT_SIZE" \
        -d "$nic,security.acls=$acl_name" \
        -d "$nic,security.acls.default.egress.action=allow" \
        -d "$nic,security.acls.default.ingress.action=allow" \
        >/dev/null || die "incus init failed" 1
    if [[ -z "$vm" ]]; then
        attach_volumes
        set_lease
    fi
    incus_run config set "$(qualified "$name")" "user.acfs.install-started=$sha" \
        || die "could not record user.acfs.install-started" 1
    log_step "Starting $(qualified "$name")"
    incus_run start "$(qualified "$name")" || die "incus start failed" 1
}

wait_agent() {
    local deadline=$((SECONDS + AGENT_TIMEOUT_SECONDS))
    log_step "Waiting for the $kind to accept incus exec"
    until incus_run exec "$(qualified "$name")" -- true >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "the $kind didn't accept incus exec within ${AGENT_TIMEOUT_SECONDS}s" 1
        sleep 3
    done
}

# Only before an install: an installed instance may have been installed by hand,
# on an image without cloud-init.
wait_cloud_init() {
    local deadline=$((SECONDS + CLOUD_INIT_TIMEOUT_SECONDS)) output state exit_code
    log_step "Waiting for cloud-init (sshd, base packages)"
    # Polled rather than `cloud-init status --wait` under timeout(1), which
    # macOS doesn't ship. `cloud-init status` exits 0 while running or done,
    # 1 on an error and 2 when done with recoverable errors, so the status
    # line decides, and exit 2 only adds a warning.
    while :; do
        exit_code=0
        output="$(incus_run exec "$(qualified "$name")" -- cloud-init status 2>/dev/null)" || exit_code=$?
        state="$(sed -n 's/^status: //p' <<<"$output")"
        case "$state" in
            done)
                ((exit_code != 2)) || log_warn "cloud-init finished with recoverable errors; see: incus exec $(qualified "$name") -- cloud-init status --long"
                return 0
                ;;
            error|disabled) break ;;
        esac
        ((SECONDS < deadline)) || break
        sleep 3
    done
    die "cloud-init didn't finish cleanly (status: ${state:-unknown}); see: incus exec $(qualified "$name") -- cloud-init status --long" 1
}

# Installs committed HEAD through the installer's own --bootstrap-archive path.
# Returns the installer's exit code. (Called under `||`, so set -e is off here:
# every step checks its own status.)
install_acfs() {
    local sha="$1" work status=0
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
        log_warn "The checkout has uncommitted changes; installing committed HEAD ${sha:0:12} without them"
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus.XXXXXX")" || die "mktemp failed" 1
    git -C "$REPO_ROOT" archive --format=tar.gz --prefix="$REPO_NAME-$sha/" "$sha" >"$work/acfs.tar.gz" \
        && git -C "$REPO_ROOT" show "$sha:install.sh" >"$work/install.sh" \
        && incus_run file push --quiet "$work/acfs.tar.gz" "$(qualified "$name")/root/acfs.tar.gz" \
        && incus_run file push --quiet "$work/install.sh" "$(qualified "$name")/root/install.sh" \
        || status=$?
    rm -f -- "$work/acfs.tar.gz" "$work/install.sh"
    rmdir -- "$work"
    ((status == 0)) || die "could not archive HEAD and copy it into the $kind" 1

    log_step "Installing ACFS $REPO_OWNER/$REPO_NAME@$sha (--yes --mode vibe)"
    incus_run exec "$(qualified "$name")" \
        --env "TARGET_USER=$TARGET_USER" --env "ACFS_REPO_OWNER=$REPO_OWNER" -- \
        bash -c "$REMOTE_GROUP_WRAPPER" acfs-install \
        bash -c 'bash -s -- --yes --mode vibe --bootstrap-archive /root/acfs.tar.gz < /root/install.sh' >&2 \
        || status=$?
    return "$status"
}

vm_exec() {
    incus_run exec "$(qualified "$name")" -- "$@"
}

# Prints the attach block. After a failed install ($1 != 0) it leaves out the
# `herdr machine add` line: herdr may not be installed yet.
print_block() {
    local install_status="$1" ip host_key herdr_version
    ip="$(instance_json | jq -r '[.state.network // {} | to_entries[] | select(.key != "lo")
        | .value.addresses[] | select(.family == "inet" and .scope == "global") | .address][0] // empty')"
    [[ -n "$ip" ]] || die "the $kind has no IPv4 address yet; re-run once it has one" 1
    host_key="$(vm_exec cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1, $2}')"
    [[ -n "$host_key" ]] || die "could not read the $kind's SSH host key" 1
    herdr_version="$(vm_exec runuser -u "$TARGET_USER" -- "/home/$TARGET_USER/.local/bin/herdr" --version 2>/dev/null || true)"

    if [[ -n "$jump" ]]; then
        printf '# Add to ~/.ssh/config on the machine you attach from, ABOVE any "Host *" block:\n'
    else
        printf '# Add to ~/.ssh/config on the Incus host, ABOVE any "Host *" block:\n'
    fi
    printf 'Host %s\n' "$name"
    printf '    HostName %s\n' "$ip"
    printf '    User %s\n' "$TARGET_USER"
    [[ -z "$jump" ]] || printf '    ProxyJump %s\n' "$jump"
    printf '    HostKeyAlias %s\n' "$name"
    printf '    StrictHostKeyChecking yes\n'
    printf '    ForwardAgent no\n'
    printf '# Add to ~/.ssh/known_hosts on that machine:\n'
    printf '%s %s\n' "$name" "$host_key"
    if ((install_status == 0)); then
        printf '# Then run there (%s runs %s):\n' "$name" "${herdr_version:-no herdr found}"
        printf 'herdr machine add %s\n' "$name"
    else
        printf '# The install failed: re-run this command; it prints the herdr machine add line once ACFS is installed.\n'
    fi
}

report_authorized_keys() {
    local line
    while IFS= read -r line; do
        log_info "$TARGET_USER accepts: $line"
    done < <(vm_exec ssh-keygen -l -f "/home/$TARGET_USER/.ssh/authorized_keys" | sort -u)
}

main() {
    if [[ "${1:-}" == host-setup ]]; then
        [[ -x "$SCRIPT_DIR/incus_host.sh" ]] || die "host-setup isn't in this checkout yet" 2
        exec "$SCRIPT_DIR/incus_host.sh" "${@:2}"
    fi
    parse_args "$@"
    require_commands
    read_incus_env

    local json sha keys_json installed="" status=0
    sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    json="$(instance_json)"

    if [[ -z "$json" ]]; then
        [[ -z "$vm" ]] || kind="VM"
        ((${#ssh_key_files[@]} > 0)) \
            || die "--ssh-key is required: pass the public key of the machine you'll attach from" 2
        keys_json="$(read_public_keys | jq -R . | jq -s -c .)"
        create_instance "$keys_json" "$sha"
    else
        # Decided before anything touches the instance, and only by the install
        # keys: user.acfs.provider is a label, which an instance marked by hand can
        # carry without this launcher having started an install there.
        installed="$(jq -r '.config["user.acfs.installed"] // empty' <<<"$json")"
        if [[ -z "$installed" ]] && ! jq -e '.config["user.acfs.install-started"] != null' <<<"$json" >/dev/null; then
            log_error "instance $(qualified "$name") exists, and this launcher didn't start an install in it; refusing to touch it."
            log_error "If ACFS is already installed there and you only want the attach block, mark it installed:"
            log_error "  incus config set $(qualified "$name") user.acfs.installed=<commit>"
            log_error "The launcher then never touches that instance's install, so set it only for an install you made."
            die "If this launcher created it and stopped before starting it, delete it and re-run; its volumes are kept and reused." 2
        fi
        [[ "$(jq -r '.type' <<<"$json")" != "virtual-machine" ]] || kind="VM"
        [[ -z "$creation_options" ]] \
            || log_warn "--vm, --acl and the sizes are ignored: $(qualified "$name") exists as a $kind, and an instance keeps the type, ACL and sizes it was created with"
        ((${#ssh_key_files[@]} == 0)) \
            || log_warn "--ssh-key is ignored for an existing $kind; add keys with ssh-copy-id from a machine that can already log in, or here with: incus exec $(qualified "$name") -- bash -c 'cat >> /home/$TARGET_USER/.ssh/authorized_keys' < KEY.pub"
        if [[ "$(jq -r '.status' <<<"$json")" != "Running" ]]; then
            log_step "Starting $(qualified "$name")"
            incus_run start "$(qualified "$name")" || die "incus start failed" 1
        fi
    fi
    wait_agent
    [[ -n "$installed" ]] || wait_cloud_init

    if [[ -n "$installed" ]]; then
        log_info "Already installed at ${installed:0:12}; the checkout is at ${sha:0:12}. Update inside the $kind with: acfs update"
    else
        incus_run config set "$(qualified "$name")" "user.acfs.install-started=$sha" \
            || die "could not record user.acfs.install-started" 1
        install_acfs "$sha" || status=$?
        if ((status == 0)); then
            incus_run config set "$(qualified "$name")" "user.acfs.installed=$sha" \
                || die "ACFS installed, but recording user.acfs.installed failed; a re-run will run the installer again" 1
            log_success "ACFS installed in $(qualified "$name") at ${sha:0:12}"
            report_authorized_keys
            log_info "Ignore the installer's note about copying an SSH key: the keys above came through cloud-init."
        fi
    fi

    print_block "$status"
    if ((status != 0)); then
        log_error "Install failed (exit $status); the $kind is kept."
        log_error "Ignore the installer's resume hint: re-run this command to resume."
        log_error "Installer log: incus exec $(qualified "$name") -- ls -t /home/$TARGET_USER/.acfs/logs/"
        exit 1
    fi
}

main "$@"
