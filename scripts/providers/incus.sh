#!/usr/bin/env bash
# ============================================================
# ACFS on an Incus VM
#
# Creates an Ubuntu VM with Incus, runs the ACFS installer inside it from
# this checkout, and prints the ssh_config entry and the `herdr machine add`
# command for attaching to it. The guide is scripts/providers/incus.md.
#
# Re-running it is safe: an absent VM is created, a VM where it started an
# install that never completed resumes it, a VM that is installed is never
# changed (the block is printed again), and any other instance is refused
# untouched. It never deletes an instance, image or ACL.
#
# Progress goes to stderr; stdout carries only the attach block.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

# The one place the instance type and size are decided.
IMAGE="images:ubuntu/26.04/cloud"
LAUNCH_ARGS=(--vm -c limits.cpu=4 -c limits.memory=8GiB -d "root,size=40GiB")

REPO_OWNER="arosl"
REPO_NAME="agentic_coding_flywheel_setup"
TARGET_USER="ubuntu"
ACL_NAME="acfs-vm-egress"
# Private, CGNAT (tailnet) and link-local ranges: the host's LAN and tailnet,
# and the host and other instances over the bridge's IPv6 link-local.
ACL_REJECT_DESTINATIONS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,fc00::/7,fe80::/10"
AGENT_TIMEOUT_SECONDS=300
CLOUD_INIT_TIMEOUT_SECONDS=600

usage() {
    cat <<'EOF'
Usage: scripts/providers/incus.sh [<remote>:]<name> --ssh-key FILE [--ssh-key FILE]... [--jump SSH_HOST]

Creates the Incus VM <name>, installs ACFS in it from this checkout's
committed HEAD, and prints the ssh_config entry and `herdr machine add`
command for the machine you attach from.

  --ssh-key FILE   Public key of the machine you'll attach from (repeatable).
                   Required when the VM doesn't exist yet.
  --jump SSH_HOST  How that machine reaches the Incus host over SSH. Without
                   it, the entry works only on the Incus host itself.

Re-running is safe: an unfinished install resumes, and an installed VM is
left as it is. See scripts/providers/incus.md.
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
ssh_key_files=()

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

# Creates the ACL when it's absent. An existing ACL is never changed.
ensure_acl() {
    if incus_run network acl show "$(qualified "$ACL_NAME")" >/dev/null 2>&1; then
        log_info "Using the existing network ACL $ACL_NAME as it is (its rules aren't checked)"
        return 0
    fi
    log_info "Creating network ACL $ACL_NAME (rejects egress to $ACL_REJECT_DESTINATIONS)"
    # The one incus call whose stdin is meant: the ACL's YAML.
    # --quiet: the client reports the creation on stdout, which is the block's.
    incus network acl create --quiet "$(qualified "$ACL_NAME")" <<EOF || die "could not create network ACL $ACL_NAME" 1
description: "ACFS VMs: no egress to private, CGNAT or link-local ranges"
egress:
  - action: reject
    destination: $ACL_REJECT_DESTINATIONS
    state: enabled
EOF
}

launch() {
    local keys_json="$1" sha="$2" nic
    nic="$(check_managed_bridge)"
    ensure_acl
    log_step "Creating VM $(qualified "$name") from $IMAGE (4 vCPU, 8 GiB RAM, 40 GiB disk)"
    incus_run launch "$IMAGE" "$(qualified "$name")" "${LAUNCH_ARGS[@]}" \
        -c user.acfs.provider=incus \
        -c "user.acfs.install-started=$sha" \
        -c "cloud-init.user-data=$(user_data "$keys_json")" \
        -d "$nic,security.acls=$ACL_NAME" \
        -d "$nic,security.acls.default.egress.action=allow" \
        -d "$nic,security.acls.default.ingress.action=allow" \
        >/dev/null || die "incus launch failed" 1
}

wait_agent() {
    local deadline=$((SECONDS + AGENT_TIMEOUT_SECONDS))
    log_step "Waiting for the VM agent"
    until incus_run exec "$(qualified "$name")" -- true >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "the VM agent didn't answer within ${AGENT_TIMEOUT_SECONDS}s" 1
        sleep 3
    done
}

# Only before an install: an installed VM may have been installed by hand,
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
    ((status == 0)) || die "could not archive HEAD and copy it into the VM" 1

    log_step "Installing ACFS $REPO_OWNER/$REPO_NAME@$sha (--yes --mode vibe)"
    incus_run exec "$(qualified "$name")" \
        --env "TARGET_USER=$TARGET_USER" --env "ACFS_REPO_OWNER=$REPO_OWNER" -- \
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
    [[ -n "$ip" ]] || die "the VM has no IPv4 address yet; re-run once it has one" 1
    host_key="$(vm_exec cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1, $2}')"
    [[ -n "$host_key" ]] || die "could not read the VM's SSH host key" 1
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
    parse_args "$@"
    require_commands

    local json sha keys_json installed="" status=0
    sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    json="$(instance_json)"

    if [[ -z "$json" ]]; then
        ((${#ssh_key_files[@]} > 0)) \
            || die "--ssh-key is required: pass the public key of the machine you'll attach from" 2
        keys_json="$(read_public_keys | jq -R . | jq -s -c .)"
        launch "$keys_json" "$sha"
    else
        # Decided before anything touches the VM, and only by the install
        # keys: user.acfs.provider is a label, which a VM marked by hand can
        # carry without this launcher having started an install there.
        installed="$(jq -r '.config["user.acfs.installed"] // empty' <<<"$json")"
        if [[ -z "$installed" ]] && ! jq -e '.config["user.acfs.install-started"] != null' <<<"$json" >/dev/null; then
            log_error "instance $(qualified "$name") exists, and this launcher didn't start an install in it; refusing to touch it."
            log_error "If ACFS is already installed there and you only want the attach block, mark it installed:"
            log_error "  incus config set $(qualified "$name") user.acfs.installed=<commit>"
            die "The launcher then never touches that VM's install, so set it only for an install you made." 2
        fi
        ((${#ssh_key_files[@]} == 0)) \
            || log_warn "--ssh-key is ignored for an existing VM; add keys with ssh-copy-id"
        if [[ "$(jq -r '.status' <<<"$json")" != "Running" ]]; then
            log_step "Starting $(qualified "$name")"
            incus_run start "$(qualified "$name")" || die "incus start failed" 1
        fi
    fi
    wait_agent
    [[ -n "$installed" ]] || wait_cloud_init

    if [[ -n "$installed" ]]; then
        log_info "Already installed at ${installed:0:12}; the checkout is at ${sha:0:12}. Update inside the VM with: acfs update"
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
        log_error "Install failed (exit $status); the VM is kept."
        log_error "Ignore the installer's resume hint: re-run this command to resume."
        log_error "Installer log: incus exec $(qualified "$name") -- ls -t /home/$TARGET_USER/.acfs/logs/"
        exit 1
    fi
}

main "$@"
