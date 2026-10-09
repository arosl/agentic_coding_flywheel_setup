#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus.sh against real Incus (opt-in VM tier)
#
# Creates a real VM with the launcher, then checks it the way a user would
# reach it: only through the ssh_config entry and known_hosts line the
# launcher printed. It needs Incus with a KVM-capable host and network
# access to images: and GitHub, and it runs the full ACFS install (~10 min).
#
# Usage: tests/vm/test_incus_provider.sh <instance-name>
#
# The instance must not exist yet. The test stops it at the end and never
# deletes it; it prints the delete command instead. It runs from the Incus
# host itself, so it passes no --jump.
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$ROOT/scripts/providers/incus.sh"
NAME="${1:-}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '[SKIP] %s\n' "$1"; exit 0; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
not() { ! "$@"; }

[[ -n "$NAME" ]] || { echo "Usage: $0 <instance-name>" >&2; exit 2; }

command -v incus >/dev/null 2>&1 || skip "incus is not installed"
incus info </dev/null >/dev/null 2>&1 || skip "this user can't reach the Incus daemon (not in incus-admin?)"
[[ -e /dev/kvm ]] || skip "/dev/kvm is missing, so Incus can't run VMs here"
incus image info images:ubuntu/26.04/cloud </dev/null >/dev/null 2>&1 || skip "the images: remote isn't reachable"
if incus info "$NAME" </dev/null >/dev/null 2>&1; then
    echo "instance $NAME already exists; pass a fresh name" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-vm.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ssh-keygen -q -t ed25519 -N '' -C acfs-incus-vm-test -f "$WORK/key"

echo "== create $NAME (full install; ~10 min)"
set +e
"$LAUNCHER" "$NAME" --ssh-key "$WORK/key.pub" >"$WORK/block" 2>"$WORK/create.log"
create_rc=$?
set -e
echo "  launcher exit: $create_rc; its last stderr lines:"
tail -n 15 "$WORK/create.log" | sed 's/^/  | /'
check "create exits 0" test "$create_rc" -eq 0

# Split the printed block into the two files the user would write.
sed -n '/^Host /,/^#/p' "$WORK/block" | grep -v '^#' >"$WORK/ssh_config"
grep -A1 -x '# Add to ~/.ssh/known_hosts on that machine:' "$WORK/block" | tail -n 1 >"$WORK/known_hosts"
check "the block has an ssh_config entry" grep -qx "Host $NAME" "$WORK/ssh_config"
check "the block has a known_hosts line" grep -q "^$NAME ssh-ed25519 " "$WORK/known_hosts"

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

echo "== network ACL"
gateway="$(vm_ssh "ip -4 route show default | awk '{print \$3; exit}'" 2>/dev/null || true)"
check "DNS resolves in the VM" vm_ssh getent hosts github.com
check "the VM reaches the internet over HTTPS" vm_ssh curl -fsS -o /dev/null --max-time 15 https://github.com
nic="$(vm_ssh "ip -4 route show default | awk '{print \$5; exit}'" 2>/dev/null || true)"
check "a DHCP renew keeps the VM's address" \
    vm_ssh "sudo networkctl renew $nic && sleep 5 && ip -4 -o addr show dev $nic scope global | grep -q inet"
# Each blocked address is only tested where the host itself accepts on :22
# there, so a refusal from the VM is the ACL and not a closed port.
blocked=("$gateway")
while read -r address; do
    blocked+=("$address")
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

echo "== re-run"
if [[ "$create_rc" -eq 0 ]]; then
    before="$(vm_ssh 'stat -c %Y ~/.acfs/state.json' 2>/dev/null || true)"
    set +e
    "$LAUNCHER" "$NAME" >"$WORK/block2" 2>"$WORK/rerun.log"
    rerun_rc=$?
    set -e
    check "a re-run exits 0" test "$rerun_rc" -eq 0
    check "a re-run says it's already installed" grep -q 'Already installed' "$WORK/rerun.log"
    check "a re-run doesn't touch the install" test "$before" = "$(vm_ssh 'stat -c %Y ~/.acfs/state.json' 2>/dev/null || true)"
    check "a re-run prints the same block" diff -q "$WORK/block" "$WORK/block2"
else
    echo "  (not tested: the install didn't complete, so a re-run resumes it by design)"
fi

echo "== Ctrl-C reaches a process started with incus exec"
# The launcher runs the installer as `incus exec ... </dev/null` in the
# foreground; a terminal's Ctrl-C sends SIGINT to that whole process group.
setsid bash -c "exec incus exec '$NAME' -- sleep 900 </dev/null" &
probe=$!
sleep 5
kill -INT -- "-$probe" 2>/dev/null || true
wait "$probe" 2>/dev/null || true
sleep 2
check "SIGINT to the client ends the process in the VM" \
    bash -c '! incus exec "$1" -- pgrep -x -f "sleep 900" </dev/null >/dev/null' _ "$NAME"

incus stop "$NAME" </dev/null
echo
echo "Stopped $NAME. It is not deleted; to delete it: incus delete $NAME"
echo "incus provider (real Incus VM): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
