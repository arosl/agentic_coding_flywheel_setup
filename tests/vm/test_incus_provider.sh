#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus.sh against real Incus (opt-in VM tier)
#
# Creates a real VM with the launcher, then checks it the way a user would
# reach it: only through the ssh_config entry and known_hosts line the
# launcher printed. It needs Incus (on a KVM-capable host, for a VM) and
# network access to images: and GitHub, and it runs the full ACFS install.
#
# Usage: tests/vm/test_incus_provider.sh [--vm] [<remote>:]<instance-name>
#
# Without --vm and without a remote it creates the launcher's default, an
# unprivileged system container (a swarm machine), which needs no KVM but
# does need the host-setup of scripts/providers/incus.md (the profile, the
# ACLs and the pool in ~/.config/acfs/incus.env).
#
# With --vm, or with a remote, the harness makes the instance itself, with
# incus launch in the restricted project acfs-tests (ACFS_TEST_PROJECT),
# and installs committed HEAD the way the launcher does. So the VM tier
# doesn't need the launcher's --vm. Through a remote (from inside a
# machine, with the client certificate host setup trusted for acfs-tests
# alone), KVM is probed on the remote server, by its qemu driver, and the
# certificate's refusals are tested: no default project, no host path, no
# raw.* key, no unix-char device, no nesting or privilege, and no instance
# beyond the project's limits. The checks that need the host's own view
# (its addresses, its bridge, the Ctrl-C probe) run only without a remote.
#
# Every run ends by measuring the instance: disk and memory once installed,
# and a cold start from stopped to an SSH login. Run it in each mode to
# compare them. The last line is "RESULT: pass", "RESULT: fail" or
# "RESULT: skip (<why>)"; a skip exits 77, so it never reads as a pass.
#
# The instance must not exist yet. The test stops it at the end and never
# deletes it; it prints the delete command instead. The launcher path runs
# from the Incus host itself, so it passes no --jump.
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$ROOT/scripts/providers/incus.sh"
MODE_ARGS=()
if [[ "${1:-}" == "--vm" ]]; then
    MODE_ARGS=(--vm)
    shift
fi
NAME="${1:-}"
IMAGE="images:ubuntu/26.04/cloud"
TEST_PROJECT="${ACFS_TEST_PROJECT:-acfs-tests}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
# A skip is not a pass: its own result line and exit code 77.
skip() { printf '[SKIP] %s\n' "$1"; printf 'RESULT: skip (%s)\n' "$1"; exit 77; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
not() { ! "$@"; }

[[ -n "$NAME" ]] || { echo "Usage: $0 [--vm] [<remote>:]<instance-name>" >&2; exit 2; }

# <remote>:<name> reaches the instance through that remote; the harness then
# makes it itself, in the test project, as it does every VM.
REMOTE=""
INAME="$NAME"
if [[ "$NAME" == *:* ]]; then
    REMOTE="${NAME%%:*}"
    INAME="${NAME#*:}"
fi
# At most 50 characters, so <name>-over-limit stays a valid instance name.
[[ "$INAME" =~ ^[a-z]([a-z0-9-]{0,48}[a-z0-9])?$ ]] \
    || { echo "the instance name must be at most 50 lowercase letters, digits and hyphens: $INAME" >&2; exit 2; }
OWN=false
[[ -z "$REMOTE" && ${#MODE_ARGS[@]} -eq 0 ]] || OWN=true
SERVER="${REMOTE:+$REMOTE:}"
# incus for this instance: in the test project when the harness makes it.
inc() {
    if [[ "$OWN" == true ]]; then
        incus --project "$TEST_PROJECT" "$@" </dev/null
    else
        incus "$@" </dev/null
    fi
}

command -v incus >/dev/null 2>&1 || skip "incus is not installed"
if [[ -n "$REMOTE" ]]; then
    incus info "$SERVER" </dev/null >/dev/null 2>&1 || skip "the remote $REMOTE doesn't answer (incus remote list; is its API reachable from here?)"
else
    incus info </dev/null >/dev/null 2>&1 || skip "this user can't reach the Incus daemon (not in incus-admin?)"
fi
# KVM is the server's, not this machine's: its driver list names qemu.
if [[ ${#MODE_ARGS[@]} -gt 0 ]]; then
    drivers="$(incus query "${SERVER}/1.0" </dev/null 2>/dev/null | jq -r '.environment.driver // ""' 2>/dev/null || true)"
    [[ "$drivers" == *qemu* ]] || skip "the Incus server ${REMOTE:-here} has no qemu driver (${drivers:-none}), so it can't run VMs (no KVM there)"
fi
if [[ "$OWN" == true ]]; then
    inc list "$SERVER" -f csv -c n >/dev/null 2>&1 \
        || skip "the project $TEST_PROJECT isn't usable on ${REMOTE:-this server} (host setup makes it; a remote needs the client certificate it trusted)"
fi
incus image info "$IMAGE" </dev/null >/dev/null 2>&1 || skip "the images: remote isn't reachable"
if inc info "$NAME" >/dev/null 2>&1; then
    echo "instance $NAME already exists; pass a fresh name" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-vm.XXXXXX")"
# The directory is flat: remove its files, then the directory, nothing else.
trap 'rm -f -- "$WORK"/*; rmdir -- "$WORK"' EXIT
ssh-keygen -q -t ed25519 -N '' -C acfs-incus-vm-test -f "$WORK/key"

# --- The restricted certificate's refusals (through a remote only) ---------
# Each refused request changes nothing. One that Incus accepts is a finding:
# it fails, and what it added to the test's own instance is taken back.
refused() {
    local what="$1"
    shift
    if inc "$@" >/dev/null 2>&1; then
        fail "the restricted certificate was allowed to $what"
        return 1
    fi
    pass "the restricted certificate may not $what"
}
if [[ -n "$REMOTE" ]]; then
    echo "== what the restricted certificate may not do (before anything exists)"
    if incus list "$SERVER" --project default -f csv -c n </dev/null >/dev/null 2>&1; then
        fail "the restricted certificate was allowed to list the default project"
    else
        pass "the restricted certificate may not list the default project"
    fi
    projects="$(incus project list "$SERVER" -f csv -c n </dev/null 2>/dev/null | sed 's/ (current)$//' | sort | tr '\n' ' ')"
    check "it sees only $TEST_PROJECT among the projects (${projects:-none})" test "$projects" = "$TEST_PROJECT "
    # --empty: if Incus wrongly accepts it, what exists is an empty, stopped
    # instance with no image, named for the test.
    refused "create an instance beyond the project's memory limit" \
        init --empty "$SERVER$INAME-over-limit" -c limits.memory=1TiB
fi

echo "== create $NAME (full install)"
create_started=$SECONDS
create_rc=0
if [[ "$OWN" == false ]]; then
    set +e
    "$LAUNCHER" "$NAME" --ssh-key "$WORK/key.pub" >"$WORK/block" 2>"$WORK/create.log"
    create_rc=$?
    set -e
    echo "  launcher exit: $create_rc after $((SECONDS - create_started)) s; its last stderr lines:"
    tail -n 15 "$WORK/create.log" | sed 's/^/  | /'
    check "create exits 0" test "$create_rc" -eq 0
    check "stdout carries only the block (no progress lines, no carriage returns)" \
        bash -c 'head -n 1 "$1" | grep -q "^# Add to ~/.ssh/config " && ! grep -q $'"'"'\r'"'"' "$1"' _ "$WORK/block"
    # Split the printed block into the two files the user would write.
    sed -n '/^Host /,/^#/p' "$WORK/block" | grep -v '^#' >"$WORK/ssh_config"
    grep -A1 -x '# Add to ~/.ssh/known_hosts on that machine:' "$WORK/block" | tail -n 1 >"$WORK/known_hosts"
    check "the block has an ssh_config entry" grep -qx "Host $NAME" "$WORK/ssh_config"
    check "the block has a known_hosts line" grep -q "^$NAME ssh-ed25519 " "$WORK/known_hosts"
else
    # The harness's own instance: the project's default profile gives it
    # its limits and a NIC on acfstest0 behind acfs-vm-egress. Then the
    # launcher's install of committed HEAD, by the same command.
    own_install() {
        local sha owner wrapper deadline state
        sha="$(git -C "$ROOT" rev-parse HEAD)"
        owner="$(sed -n 's/^REPO_OWNER="\(.*\)"$/\1/p' "$LAUNCHER")"
        wrapper="$(sed -n "s/^REMOTE_GROUP_WRAPPER='\(.*\)'\$/\1/p" "$LAUNCHER")"
        [[ -n "$owner" && -n "$wrapper" ]] || { echo "  can't read REPO_OWNER and REMOTE_GROUP_WRAPPER from the launcher"; return 1; }
        {
            printf '#cloud-config\npackage_update: true\n'
            printf 'packages: [openssh-server, curl, git, jq, ca-certificates, unzip]\n'
            printf 'ssh_authorized_keys:\n  - %s\n' "$(jq -Rn --arg k "$(cat "$WORK/key.pub")" '$k')"
        } >"$WORK/user-data"
        inc launch "$IMAGE" "$NAME" "${MODE_ARGS[@]}" -c "cloud-init.user-data=$(cat "$WORK/user-data")" \
            >"$WORK/create.log" 2>&1 || return 1
        deadline=$((SECONDS + 600))
        until inc exec "$NAME" -- true >/dev/null 2>&1; do
            ((SECONDS < deadline)) || { echo "  no incus exec within 600 s"; return 1; }
            sleep 3
        done
        until state="$(inc exec "$NAME" -- cloud-init status 2>/dev/null | sed -n 's/^status: //p')"; [[ "$state" == "done" || "$state" == "error" ]]; do
            ((SECONDS < deadline)) || { echo "  cloud-init still ${state:-unknown} after 600 s"; return 1; }
            sleep 3
        done
        [[ "$state" == "done" ]] || { echo "  cloud-init: $state"; return 1; }
        git -C "$ROOT" archive --format=tar.gz --prefix="agentic_coding_flywheel_setup-$sha/" "$sha" >"$WORK/acfs.tar.gz" \
            && git -C "$ROOT" show "$sha:install.sh" >"$WORK/install.sh" \
            && inc file push --quiet "$WORK/acfs.tar.gz" "$NAME/root/acfs.tar.gz" \
            && inc file push --quiet "$WORK/install.sh" "$NAME/root/install.sh" || return 1
        inc exec "$NAME" --env TARGET_USER=ubuntu --env "ACFS_REPO_OWNER=$owner" -- \
            bash -c "$wrapper" acfs-install \
            bash -c 'bash -s -- --yes --mode vibe --bootstrap-archive /root/acfs.tar.gz < /root/install.sh' >>"$WORK/create.log" 2>&1
    }
    own_install || create_rc=$?
    echo "  own create and install exit: $create_rc after $((SECONDS - create_started)) s; the last log lines:"
    tail -n 15 "$WORK/create.log" | sed 's/^/  | /'
    check "create and install exit 0" test "$create_rc" -eq 0
    # The entry and known_hosts line the launcher would print, from the
    # instance's own address and host key.
    address="$(inc query "${SERVER}/1.0/instances/$INAME/state" 2>/dev/null | jq -r '[.network // {} | to_entries[]
        | select(.key != "lo") | .value.addresses[] | select(.family == "inet" and .scope == "global") | .address][0] // empty' || true)"
    host_key="$(inc exec "$NAME" -- cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $1, $2}' || true)"
    printf 'Host %s\n    HostName %s\n    User ubuntu\n    HostKeyAlias %s\n    StrictHostKeyChecking yes\n    ForwardAgent no\n' \
        "$INAME" "$address" "$INAME" >"$WORK/ssh_config"
    printf '%s %s\n' "$INAME" "$host_key" >"$WORK/known_hosts"
    check "the instance has an IPv4 address on the test bridge (${address:-none})" test -n "$address"
    check "its ed25519 host key is readable" bash -c '[[ "$1" == "ssh-ed25519 "* ]]' _ "$host_key"
fi

if [[ -n "$REMOTE" ]] && inc info "$NAME" >/dev/null 2>&1; then
    echo "== what the restricted certificate may not do to its own instance"
    refused "mount a host path" config device add "$NAME" acfs-neg-host disk source=/etc path=/mnt/acfs-neg-host \
        || inc config device remove "$NAME" acfs-neg-host >/dev/null 2>&1 || true
    refused "add a unix-char device" config device add "$NAME" acfs-neg-kvm unix-char path=/dev/kvm \
        || inc config device remove "$NAME" acfs-neg-kvm >/dev/null 2>&1 || true
    if [[ ${#MODE_ARGS[@]} -eq 0 ]]; then
        refused "set raw.lxc" config set "$NAME" raw.lxc=lxc.apparmor.profile=unconfined \
            || inc config unset "$NAME" raw.lxc >/dev/null 2>&1 || true
        refused "turn on nesting" config set "$NAME" security.nesting=true \
            || inc config unset "$NAME" security.nesting >/dev/null 2>&1 || true
        refused "make the container privileged" config set "$NAME" security.privileged=true \
            || inc config unset "$NAME" security.privileged >/dev/null 2>&1 || true
    else
        refused "set raw.qemu" config set "$NAME" raw.qemu=-no-reboot \
            || inc config unset "$NAME" raw.qemu >/dev/null 2>&1 || true
    fi
fi

echo "== instance type"
instance_type="$(inc query "${SERVER}/1.0/instances/$INAME" | jq -r '.type' || true)"
if [[ ${#MODE_ARGS[@]} -eq 0 ]]; then
    check "the instance is a container" test "$instance_type" = container
    # The launcher pins these; the test project enforces its own instead.
    if [[ "$OWN" == false ]]; then
        for setting in security.privileged=false security.nesting=false security.idmap.isolated=true; do
            check "it carries $setting" test "$(inc config get "$NAME" "${setting%%=*}")" = "${setting#*=}"
        done
    fi
    # /proc/self/uid_map: <uid inside> <uid on the host> <count>.
    root_host_uid="$(inc exec "$NAME" -- awk '$1 == 0 {print $2; exit}' /proc/self/uid_map || true)"
    check "root in the container is an unprivileged uid on the host (${root_host_uid:-none})" \
        bash -c '[[ "$1" =~ ^[1-9][0-9]*$ ]]' _ "$root_host_uid"
else
    check "the instance is a VM" test "$instance_type" = virtual-machine
fi

vm_ssh() {
    ssh -F "$WORK/ssh_config" -i "$WORK/key" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o ConnectTimeout=10 -o "UserKnownHostsFile=$WORK/known_hosts" "$NAME" "$@" </dev/null
}

echo "== SSH and sshd"
check "key login as ubuntu through the printed entry" vm_ssh true
sshd_usepam="$(vm_ssh sudo sshd -T 2>/dev/null | grep -i '^usepam ' || true)"
check "sshd -T: usepam yes" test "$sshd_usepam" = "usepam yes"
check "ubuntu has no usable password, so password login can't succeed" \
    bash -c '[[ "$1" == "ubuntu L "* ]]' _ "$(vm_ssh sudo passwd -S ubuntu 2>/dev/null)"
check "root has no usable password" \
    bash -c '[[ "$1" == "root L "* ]]' _ "$(vm_ssh sudo passwd -S root 2>/dev/null)"
check "a password-only login is refused" \
    bash -c '! ssh -F "$1/ssh_config" -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o ConnectTimeout=10 -o "UserKnownHostsFile=$1/known_hosts" "$2" true </dev/null 2>/dev/null' _ "$WORK" "$NAME"

echo "== ACFS"
# Remote paths are relative to ubuntu's home, where ssh starts; ~/.local/bin
# isn't on the non-interactive PATH.
herdr_version="$(vm_ssh .local/bin/herdr --version 2>/dev/null || true)"
check "herdr runs from ~/.local/bin" bash -c '[[ "$1" == herdr\ * ]]' _ "$herdr_version"
check "the block names the VM's herdr version" grep -qF "($NAME runs $herdr_version)" "$WORK/block"
doctor_json="$(vm_ssh .acfs/bin/acfs doctor --json 2>/dev/null || true)"
doctor_failures="$(jq -r '.summary.fail // "no summary"' <<<"$doctor_json" 2>/dev/null || echo "no JSON")"
echo "  acfs doctor failures: $doctor_failures"
jq -r '.checks[]? | select(.status == "fail") | "  | fail: \(.id // .name // "?"): \(.message // .label // "")"' \
    <<<"$doctor_json" 2>/dev/null || true
check "acfs doctor --json reports no failures" test "$doctor_failures" = "0"

# The ACL, IPv6 and Ctrl-C sections compare the instance with the host's own
# addresses, bridge and processes, so they need to run on the host.
if [[ -n "$REMOTE" ]]; then
    echo "== network ACL, IPv6 and the re-run: not tested through a remote (they need the host's own view)"
else
echo "== network ACL"
# The field after "via": an IPv6 route puts "nhid <n>" before it.
route_via='{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}'
gateway="$(vm_ssh "ip -4 route show default | awk '$route_via'" 2>/dev/null || true)"
check "DNS resolves in the VM" vm_ssh getent hosts github.com
check "the VM reaches the internet over HTTPS" vm_ssh curl -fsS -o /dev/null --max-time 15 https://github.com
nic="$(vm_ssh "ip -4 route show default | awk '{print \$5; exit}'" 2>/dev/null || true)"
vm_address() { vm_ssh "ip -4 -o addr show dev $nic scope global | awk '{print \$4; exit}'" 2>/dev/null || true; }
address_before="$(vm_address)"
vm_ssh "sudo networkctl renew $nic && sleep 5" || true
check "a DHCP renew keeps the VM's address ($address_before)" \
    bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "$address_before" "$(vm_address)"
# Each blocked address is only tested where the host itself accepts on :22
# there, so a refusal from the VM is the ACL and not a closed port.
blocked=("$gateway")
while read -r address; do
    [[ "$address" == "$gateway" ]] || blocked+=("$address")
done < <(ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1]}' \
    | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' || true)
for address in "${blocked[@]}"; do
    [[ -n "$address" ]] || continue
    if timeout 5 bash -c "</dev/tcp/$address/22" 2>/dev/null; then
        check "the VM can't open $address:22 (the host accepts there)" \
            not vm_ssh "timeout 5 bash -c '</dev/tcp/$address/22'"
    else
        echo "  (not tested: the host itself doesn't accept on $address:22)"
    fi
done

echo "== IPv6 under the ACL"
# fe80::/10 and fc00::/7 are rejected, so check that the bridge's IPv6 still
# works. Router advertisements come in, which the egress ACL doesn't filter:
# a global address and a default route show them. The VM's neighbour
# advertisements go out, as unicast replies to whichever address solicited
# them, so each range gets a solicitation from the host's address in it. The
# ping's echo reply may or may not pass, and Linux doesn't count it as
# neighbour confirmation either way, so only an advertisement makes the entry
# REACHABLE: an existing one goes DELAY, then PROBE (about 5 s, then up to 3
# probes 1 s apart) and ends REACHABLE, or FAILED without one.
vm_global6="$(vm_ssh "ip -6 -o addr show dev $nic scope global | awk '{split(\$4, a, \"/\"); print a[1]; exit}'" 2>/dev/null || true)"
vm_link6="$(vm_ssh "ip -6 -o addr show dev $nic scope link | awk '{split(\$4, a, \"/\"); print a[1]; exit}'" 2>/dev/null || true)"
gateway6="$(vm_ssh "ip -6 route show default | awk '$route_via'" 2>/dev/null || true)"
bridge_dev="$(ip -6 -o addr show scope link | awk -v a="$gateway6" '{split($4, x, "/"); if (x[1] == a) {print $2; exit}}')"
check "the VM has a global IPv6 address (SLAAC)" test -n "$vm_global6"
check "the VM has an IPv6 default route" test -n "$gateway6"
# neighbour_confirmed <address> <ping target>
neighbour_confirmed() {
    ping -6 -c 1 -W 2 "$2" >/dev/null 2>&1 || true
    sleep 10
    ip -6 neigh show "$1" dev "$bridge_dev" | grep -q -w REACHABLE
}
if [[ -n "$bridge_dev" && -n "$vm_global6" ]]; then
    check "the VM answers neighbour solicitation from the host's global address (fc00::/7)" \
        neighbour_confirmed "$vm_global6" "$vm_global6"
fi
if [[ -n "$bridge_dev" && -n "$vm_link6" ]]; then
    check "the VM answers neighbour solicitation from the host's link-local address (fe80::/10)" \
        neighbour_confirmed "$vm_link6" "$vm_link6%$bridge_dev"
else
    fail "the VM's link-local address and the host's bridge device are known"
fi
if [[ -n "$gateway6" && -n "$bridge_dev" ]] && timeout 5 bash -c "</dev/tcp/$gateway6%$bridge_dev/22" 2>/dev/null; then
    check "the VM can't open the gateway's link-local :22 (the host accepts there)" \
        not vm_ssh "timeout 5 bash -c '</dev/tcp/$gateway6%$nic/22'"
else
    echo "  (not tested: the host itself doesn't accept on the gateway's link-local :22)"
fi

fi

echo "== re-run"
if [[ "$OWN" == true ]]; then
    echo "  (not tested: the harness made this instance itself; the launcher's re-run is the container path's)"
elif [[ "$create_rc" -eq 0 ]]; then
    before="$(vm_ssh 'stat -c %Y ~/.acfs/state.json' 2>/dev/null || true)"
    set +e
    "$LAUNCHER" "$NAME" >"$WORK/block2" 2>"$WORK/rerun.log"
    rerun_rc=$?
    set -e
    check "a re-run exits 0" test "$rerun_rc" -eq 0
    check "a re-run says it's already installed" grep -q 'Already installed' "$WORK/rerun.log"
    check "a re-run doesn't touch the install" test "$before" = "$(vm_ssh 'stat -c %Y ~/.acfs/state.json' 2>/dev/null || true)"
    check "a re-run prints the same block" diff -q "$WORK/block" "$WORK/block2"
    diff -u "$WORK/block" "$WORK/block2" | cat -A | head -n 40 | sed 's/^/  | /' || true
else
    echo "  (not tested: the install didn't complete, so a re-run resumes it by design)"
fi

echo "== lifting the ACL on the running VM (the guide's command)"
if [[ "$OWN" == true ]]; then
    echo "  (not tested: the instance's NIC is the test project's profile's, which the guide's command leaves alone)"
else
vm_nic="$(incus query "/1.0/instances/$NAME" </dev/null \
    | jq -r '.devices | to_entries[] | select(.value.type == "nic") | .key' | head -n 1)"
check "the VM has its own NIC device" test -n "$vm_nic"
if [[ -n "$vm_nic" ]] && incus config device unset "$NAME" "$vm_nic" security.acls </dev/null; then
    pass "incus config device unset $NAME $vm_nic security.acls"
    if [[ -n "$gateway" ]] && timeout 5 bash -c "</dev/tcp/$gateway/22" 2>/dev/null; then
        check "without a restart, the VM now opens $gateway:22" \
            vm_ssh "timeout 5 bash -c '</dev/tcp/$gateway/22'"
    else
        echo "  (not tested: the host itself doesn't accept on the gateway's :22)"
    fi
else
    fail "incus config device unset $NAME ${vm_nic:-<no NIC>} security.acls"
fi
fi

echo "== Ctrl-C stops a command run the way the launcher runs the installer"
# The launcher runs the installer as `incus exec ... </dev/null` in the
# foreground. The probe has the installer's shape: the launcher's wrapper
# around a bash that waits on a child, which a bare SIGINT to the remote pid
# doesn't stop. The ^C is typed into a real pty with script(1), as in a
# terminal; a signal to a background job wouldn't do, since a
# non-interactive shell's & starts it with SIGINT ignored.
wrapper="$(sed -n "s/^REMOTE_GROUP_WRAPPER='\(.*\)'\$/\1/p" "$LAUNCHER")"
check "the launcher's REMOTE_GROUP_WRAPPER line is readable" test -n "$wrapper"
project_flag=""
[[ "$OWN" == false ]] || printf -v project_flag -- '--project %q ' "$TEST_PROJECT"
printf -v probe_command 'incus %sexec %q -- bash -c %q probe bash -c %q </dev/null' \
    "$project_flag" "$NAME" "$wrapper" 'sleep 900; true'
probe_rc=0
{ sleep 5; printf '\003'; sleep 20; } \
    | timeout 60 script -q -e -c "$probe_command" /dev/null >/dev/null 2>&1 || probe_rc=$?
sleep 2
check "the client exits 130 on SIGINT (exit $probe_rc)" test "$probe_rc" -eq 130
check "SIGINT to the client ends the bash and its child in the VM" \
    not inc exec "$NAME" -- pgrep -f "sleep 900"

# Printed for comparing a VM with a container, not checked. The host's view
# is what the instance costs the host; a VM's disk usage may be missing
# there, depending on the storage driver.
echo "== measurements ($instance_type, installed, idle)"
instance_state="$(inc query "${SERVER}/1.0/instances/$INAME/state" || true)"
echo "  host's view: memory $(jq -r '.memory.usage // "?"' <<<"$instance_state" 2>/dev/null) B, root disk $(jq -r '.disk.root.usage // "?"' <<<"$instance_state" 2>/dev/null) B"
echo "  inside: / has $(vm_ssh "df -B1 --output=used / | tail -n 1" 2>/dev/null || echo '?') B used, memory used $(vm_ssh "free -b | awk '/^Mem:/ {print \$3}'" 2>/dev/null || echo '?') B"

inc stop "$NAME"

echo "== cold start (stopped to an SSH login through the printed entry)"
start_ms="$(date +%s%3N)"
inc start "$NAME" || fail "incus start $NAME"
deadline=$((SECONDS + 300))
until inc exec "$NAME" -- true >/dev/null 2>&1 || ((SECONDS >= deadline)); do sleep 0.2; done
exec_ms="$(date +%s%3N)"
until vm_ssh true 2>/dev/null || ((SECONDS >= deadline)); do sleep 0.5; done
ssh_ms="$(date +%s%3N)"
echo "  incus exec answered after $((exec_ms - start_ms)) ms, SSH login after $((ssh_ms - start_ms)) ms"
check "an SSH login works after a cold start" vm_ssh true

inc stop "$NAME"
echo
echo "Stopped $NAME. It is not deleted; to delete it: incus ${project_flag}delete $NAME"
echo "incus provider (real Incus $instance_type${REMOTE:+, through $REMOTE}): $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then
    echo "RESULT: pass"
else
    echo "RESULT: fail"
    exit 1
fi
