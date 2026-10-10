#!/usr/bin/env bash
# ============================================================
# scripts/lib/state_layer.sh (acfs state) against a fixture machine
#
# Every outside command the layer runs is a stub: age (a reversible
# header instead of encryption), systemctl, pgrep, runuser, chown,
# curl (the guest API), mountpoint, systemd-detect-virt, sshd and
# incus. No Incus, no systemd and no root are touched.
#
# Proves: the manifest's rows; export refuses without a recipient,
# while a writer runs, and over an existing file, and restarts what it
# stopped; the archive is 0600, ends with manifest.json, leaves cache
# out unless --with-cache and leaves out a symlink that leaves its row;
# import restores files, links, modes and root rows, writes the lease,
# refuses a held login without --replace, refuses a tampered archive
# and an unfenced move, and resumes after an interruption; a --move
# export fences the lease; lease check's four cases; repair; doctor's
# JSON; setup-guest's unit, drop-ins and HostKey drop-in.
#
# Usage: bash tests/unit/test_state_layer.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE="$ROOT/scripts/lib/state_layer.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-state-layer-test.XXXXXX")"
cleanup() {
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

OUT="$WORK/out"
ERR="$WORK/err"
LOG="$WORK/calls.log"
BIN="$WORK/bin"
mkdir -p "$BIN"

# --- Stubs -------------------------------------------------------------

# age: "encrypts" by prefixing a header, so the archive is checkable.
cat >"$BIN/age" <<'STUB'
#!/usr/bin/env bash
echo "age $*" >>"$STUB_LOG"
decrypt=false out="" in=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) decrypt=true; shift ;;
        -o) out="$2"; shift 2 ;;
        -r|-R|-i) shift 2 ;;
        -p) shift ;;
        *) in="$1"; shift ;;
    esac
done
[[ -n "${AGE_FAIL:-}" ]] && exit 1
if [[ "$decrypt" == "true" ]]; then
    exec 3<"${in:-/dev/stdin}"
    IFS= read -r header <&3
    [[ "$header" == "AGESTUB" ]] || { echo "age: not an age file" >&2; exit 1; }
    cat <&3
else
    { echo AGESTUB; cat; } >"${out:-/dev/stdout}"
fi
STUB

cat >"$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case "$1" in
    is-active)
        unit="${*: -1}"
        [[ " ${ACTIVE_UNITS:-} " == *" $unit "* ]] ;;
    show)
        case "$*" in
            *LoadState*) echo "${LEASE_LOAD:-loaded}" ;;
            *ActiveState*) echo "${LEASE_ACTIVE:-active}" ;;
            *Result*) echo "${LEASE_RESULT:-success}" ;;
        esac ;;
    *) exit 0 ;;
esac
STUB

cat >"$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -f "* ]]; then
    [[ -n "${RUNNING_INTERP:-}" ]] && { echo 4343; exit 0; }
    exit 1
fi
name="${*: -1}"
[[ " ${RUNNING_WRITERS:-} " == *" $name "* ]] && { echo 4242; exit 0; }
exit 1
STUB

cat >"$BIN/runuser" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
exec "$@"
STUB

# chown: the tests don't run as root; record what would be chowned.
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
echo "chown $*" >>"$STUB_LOG"
STUB

# curl: the guest API, answering with the body and then the status line
# that -w '\n%{http_code}' adds; GUEST_DOWN makes it unreachable.
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
[[ -n "${GUEST_DOWN:-}" ]] && exit 7
if [[ -n "${INSTANCE_LEASE:-}" ]]; then
    printf '%s\n200' "$INSTANCE_LEASE"
else
    printf 'not found\n404'
fi
STUB

cat >"$BIN/mountpoint" <<'STUB'
#!/usr/bin/env bash
[[ "${MOUNTED:-yes}" == "yes" ]]
STUB

cat >"$BIN/systemd-detect-virt" <<'STUB'
#!/usr/bin/env bash
echo "${VIRT:-lxc}"
[[ "${VIRT:-lxc}" != "none" ]]
STUB

cat >"$BIN/sshd" <<'STUB'
#!/usr/bin/env bash
echo "sshd $*" >>"$STUB_LOG"
[[ -z "${SSHD_FAIL:-}" ]]
STUB

cat >"$BIN/incus" <<'STUB'
#!/usr/bin/env bash
echo "incus $*" >>"$STUB_LOG"
STUB

cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "${CLAUDE_VERSION:-2.0.0 (Claude Code)}"
STUB
chmod +x "$BIN"/*

# --- Fixture machines ---------------------------------------------------

# make_machine DIR: a home with logins, cache, an unknown dot-directory,
# links, and root rows.
make_machine() {
    local m="$1"
    mkdir -p "$m/home/.claude/hooks" "$m/home/.codex" "$m/home/.config/gh" \
        "$m/home/.config/systemd/user" "$m/home/.local/share/coding-agent-search" \
        "$m/home/.weirdtool" "$m/home/.acfs" "$m/meta" "$m/ssh" "$m/ts" \
        "$m/etcssh/sshd_config.d" "$m/systemd"
    echo '{"token":"claude-secret"}' >"$m/home/.claude/.credentials.json"
    echo '{"projects":{}}' >"$m/home/.claude.json"
    echo '#!/bin/sh' >"$m/home/.claude/hooks/h.sh"
    chmod 0755 "$m/home/.claude/hooks/h.sh"
    ln -s ../.claude.json "$m/home/.claude/link-in"
    ln -s /etc/passwd "$m/home/.claude/link-out"
    echo shared >"$m/home/.claude/hard-a"
    ln "$m/home/.claude/hard-a" "$m/home/.claude/hard-b"
    ln -s "$m/home/.claude.json" "$m/home/.claude/link-abs"
    mkdir -p "$m/home/.ssh"
    echo "ssh-ed25519 key-$(basename "$m")" >"$m/home/.ssh/authorized_keys"
    echo '{"auth":"codex-secret"}' >"$m/home/.codex/auth.json"
    echo 'github.com: {}' >"$m/home/.config/gh/hosts.yml"
    echo '[Unit]' >"$m/home/.config/systemd/user/x.service"
    echo cachedata >"$m/home/.local/share/coding-agent-search/db"
    echo state >"$m/home/.weirdtool/s"
    echo 0.10.0 >"$m/home/.acfs/VERSION"
    echo ed25519-private >"$m/ssh/ssh_host_ed25519_key"
    echo ed25519-public >"$m/ssh/ssh_host_ed25519_key.pub"
    echo node >"$m/ts/tailscaled.state"
    echo etc-private >"$m/etcssh/ssh_host_ed25519_key"
    echo etc-public >"$m/etcssh/ssh_host_ed25519_key.pub"
    chmod 0600 "$m/home/.claude/.credentials.json" "$m/home/.codex/auth.json"
    chmod 0700 "$m/home/.claude" "$m/home/.codex" "$m/meta" "$m/ssh" "$m/ts"
}

SOCK="$WORK/s.sock"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCK"

# A cgroup outside the user manager, and an SSH client off Tailscale, so
# the quiesce preflight passes unless a test says otherwise (this test
# itself may well run in a herdr pane).
echo "0::/system.slice/ssh.service" >"$WORK/cgroup-outside"
echo "0::/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/herdr.service" >"$WORK/cgroup-herdr"

# st MACHINE ARGS...: run acfs state against fixture machine MACHINE.
st() {
    local m="$1"
    shift
    env PATH="$BIN:$PATH" STUB_LOG="$LOG" ACFS_STATE_ALLOW_NONROOT=1 \
        ACFS_STATE_GUEST_RETRIES=2 ACFS_STATE_GUEST_DELAY=0 \
        ACFS_STATE_PROC_SELF_CGROUP="${CGROUP_FILE:-$WORK/cgroup-outside}" \
        SSH_CONNECTION="${SSH_FROM:-192.0.2.1} 50000 192.0.2.2 22" \
        INSTANCE_LEASE="${INSTANCE_LEASE-lease-default}" \
        ACFS_STATE_USER="$(id -un)" ACFS_STATE_HOME="$m/home" ACFS_STATE_META="$m/meta" \
        ACFS_STATE_SSH_DIR="$m/ssh" ACFS_STATE_TS_DIR="$m/ts" ACFS_STATE_ETC_SSH="$m/etcssh" \
        ACFS_STATE_SSHD_DROPIN="$m/etcssh/sshd_config.d/10-acfs-host-keys.conf" \
        ACFS_STATE_GUEST_SOCK="${GUEST_SOCK-$SOCK}" ACFS_STATE_SYSTEMD_DIR="$m/systemd" \
        ACFS_STATE_LIBEXEC="$m/libexec/state_layer.sh" ACFS_STATE_OUT_DIR="$m/home/acfs-state" \
        bash "$STATE" "$@" >"$OUT" 2>"$ERR"
}

# Run st and remember its exit status in RC (st's own failure is data).
RC=0
run() { RC=0; st "$@" || RC=$?; }

# Decrypt an archive (the stub's format) and list its members in order.
members() { tail -n +2 "$1" | python3 -I -c 'import sys, tarfile; [print(m.name) for m in tarfile.open(fileobj=sys.stdin.buffer, mode="r|")]'; }
mode_of() { stat -c %a "$1"; }

A="$WORK/a"
B="$WORK/b"
make_machine "$A"
make_machine "$B"
# B is a fresh machine: no logins, its own host keys.
rm -rf "$B/home/.claude" "$B/home/.claude.json" "$B/home/.codex" "$B/home/.config/gh"
echo b-private >"$B/ssh/ssh_host_ed25519_key"
UID_NOW="$(id -u)"

echo "manifest"
run "$A" manifest
check "manifest lists login, cache and root rows" \
    bash -c 'grep -q "^claude .*login" "$1" && grep -q "^cass .*cache" "$1" && grep -q "^ssh-host .*root" "$1"' _ "$OUT"
run "$A" manifest --json
check "manifest --json is valid and has a private claude row" \
    bash -c 'jq -e ".[] | select(.id == \"claude\" and .policy == \"private\")" "$1" >/dev/null' _ "$OUT"

echo "export: refusals"
run "$A" export devbox
check "export without a recipient refuses (exit 2)" bash -c '[[ "$1" -eq 2 ]] && grep -q "needs --recipient" "$2"' _ "$RC" "$ERR"
run "$A" export "bad/name" --recipient age1x
check "export refuses a machine name with a slash" bash -c '[[ "$1" -eq 2 ]]' _ "$RC"

: >"$LOG"
ACTIVE_UNITS="user@$UID_NOW.service tailscaled.service" RUNNING_WRITERS="claude" run "$A" export devbox --recipient age1x
check "export refuses while a writer still runs, and names it" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "claude (pid 4242)" "$2" && grep -q "there is no --force" "$2"' _ "$RC" "$ERR"
check "after refusing, export restarts the units it stopped" \
    bash -c 'grep -q "systemctl stop user@$2.service" "$1" && grep -q "systemctl start user@$2.service" "$1" && grep -q "systemctl start tailscaled.service" "$1"' _ "$LOG" "$UID_NOW"
check "no archive is left after a refusal" bash -c '! compgen -G "$1/home/acfs-state/*" >/dev/null' _ "$A"

: >"$LOG"
ACTIVE_UNITS="user@$UID_NOW.service" RUNNING_INTERP=1 run "$A" export devbox --recipient age1x
check "export refuses a writer running under node or bun" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "under an interpreter (pid 4343)" "$2"' _ "$RC" "$ERR"
: >"$LOG"
ACTIVE_UNITS="user@$UID_NOW.service" CGROUP_FILE="$WORK/cgroup-herdr" run "$A" export devbox --recipient age1x
check "export refuses inside the user manager (a herdr pane), before stopping anything" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "runs inside .* user manager" "$2" && grep -q "incus exec" "$2" && ! grep -q "systemctl stop" "$3"' _ "$RC" "$ERR" "$LOG"
: >"$LOG"
ACTIVE_UNITS="user@$UID_NOW.service tailscaled.service" SSH_FROM=100.101.2.3 run "$A" export devbox --recipient age1x
check "export refuses an SSH session over Tailscale while tailscaled runs" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "comes over Tailscale" "$2" && ! grep -q "systemctl stop" "$3"' _ "$RC" "$ERR" "$LOG"
ACTIVE_UNITS="user@$UID_NOW.service" SSH_FROM=100.101.2.3 run "$A" export devbox "$WORK/ts-off.tar.age" --recipient age1x
check "the same session is fine when tailscaled doesn't run" bash -c '[[ "$1" -eq 0 ]]' _ "$RC"

echo "export: dry run"
run "$A" export devbox --dry-run
check "dry run lists rows and marks absent ones" \
    bash -c 'grep -q "claude .*login" "$1" && grep -q "pi .*(absent)" "$1"' _ "$OUT"
check "dry run reports the unknown dot-directory" bash -c 'grep -q "^  .weirdtool$" "$1"' _ "$OUT"

echo "export"
: >"$LOG"
ACTIVE_UNITS="user@$UID_NOW.service" run "$A" export devbox "$WORK/a.tar.age" --recipient age1example
check "export succeeds" bash -c '[[ "$1" -eq 0 ]]' _ "$RC"
check "the archive is 0600" bash -c '[[ "$(stat -c %a "$1")" == 600 ]]' _ "$WORK/a.tar.age"
check "export prints the archive's sha256" bash -c 'grep -q "^sha256: $(sha256sum "$2" | cut -d" " -f1)$" "$1"' _ "$OUT" "$WORK/a.tar.age"
check "export stopped and restarted the user manager" \
    bash -c 'grep -q "systemctl stop user@$2.service" "$1" && grep -q "systemctl start user@$2.service" "$1"' _ "$LOG" "$UID_NOW"
check "age got the recipient" bash -c 'grep -q "age -r age1example -o" "$1"' _ "$LOG"
members "$WORK/a.tar.age" >"$WORK/a.members"
check "manifest.json is the last member" bash -c '[[ "$(tail -1 "$1")" == manifest.json ]]' _ "$WORK/a.members"
check "logins and root rows are in, cache is out" \
    bash -c 'grep -qx home/.claude/.credentials.json "$1" && grep -qx home/.codex/auth.json "$1" && grep -qx root/ssh-host/ssh_host_ed25519_key "$1" && grep -qx root/tailscale/tailscaled.state "$1" && ! grep -q coding-agent-search "$1"' _ "$WORK/a.members"
check "the unknown dot-directory is not exported" bash -c '! grep -q weirdtool "$1"' _ "$WORK/a.members"
check "a symlink that leaves its row is left out and reported" \
    bash -c '! grep -qx home/.claude/link-out "$1" && grep -q "home/.claude/link-out: symlink leaves its row" "$2" && grep -qx home/.claude/link-in "$1"' _ "$WORK/a.members" "$ERR"
check "the archive never holds a secret in the clear outside its members" \
    bash -c '! grep -q claude-secret "$1" && ! grep -q claude-secret "$2"' _ "$OUT" "$ERR"

run "$A" export devbox "$WORK/a.tar.age" --recipient age1example
check "export refuses to overwrite an existing file" bash -c '[[ "$1" -ne 0 ]] && grep -q "refusing to overwrite" "$2"' _ "$RC" "$ERR"

run "$A" export devbox --with-cache --recipient age1example
DEFAULT_ARCHIVE="$(compgen -G "$A/home/acfs-state/devbox-*.tar.age" | head -1)"
check "the default output is ~/acfs-state/<name>-<UTC>.tar.age, in a 0700 dir" \
    bash -c '[[ -f "$1" && "$(stat -c %a "$(dirname "$1")")" == 700 ]]' _ "$DEFAULT_ARCHIVE"
members "$DEFAULT_ARCHIVE" >"$WORK/cache.members"
check "--with-cache carries the cache row" \
    grep -qx home/.local/share/coding-agent-search/db "$WORK/cache.members"

: >"$LOG"
run "$A" export devbox "$WORK/snap.tar.age" --recipient age1example --snapshot-pool fast
check "--snapshot-pool snapshots acfs-state-<name> through the host remote" \
    bash -c 'grep -q "incus storage volume snapshot create host:fast acfs-state-devbox acfs-export-" "$1"' _ "$LOG"

echo "import"
INSTANCE_LEASE="lease-b" run "$B" import devbox "$WORK/a.tar.age"
check "import into a fresh machine succeeds" bash -c '[[ "$1" -eq 0 ]]' _ "$RC"
check "logins arrive with their contents" \
    bash -c 'grep -q claude-secret "$1/home/.claude/.credentials.json" && grep -q codex-secret "$1/home/.codex/auth.json"' _ "$B"
check "the hook keeps its execute bit, with no group or other access" \
    bash -c '[[ "$(stat -c %a "$1/home/.claude/hooks/h.sh")" == 700 ]]' _ "$B"
check "the relative symlink and the hardlink survive" \
    bash -c '[[ "$(readlink "$1/home/.claude/link-in")" == ../.claude.json && "$(stat -c %i "$1/home/.claude/hard-a")" == "$(stat -c %i "$1/home/.claude/hard-b")" ]]' _ "$B"
check "an absolute symlink into the source's home points into this home" \
    bash -c '[[ "$(readlink "$1/home/.claude/link-abs")" == "$1/home/.claude.json" ]]' _ "$B"
check "authorized_keys keeps this machine's key first and adds the source's" \
    bash -c '[[ "$(sed -n 1p "$1/home/.ssh/authorized_keys")" == "ssh-ed25519 key-b" && "$(sed -n 2p "$1/home/.ssh/authorized_keys")" == "ssh-ed25519 key-a" && "$(stat -c %a "$1/home/.ssh/authorized_keys")" == 600 ]]' _ "$B"
check "the import points sshd at the imported host keys" \
    bash -c 'grep -qx "HostKey $1/ssh/ssh_host_ed25519_key" "$1/etcssh/sshd_config.d/10-acfs-host-keys.conf"' _ "$B"
check "root rows are replaced by the archive's, the old ones kept" \
    bash -c 'grep -q ed25519-private "$1/ssh/ssh_host_ed25519_key" && grep -q b-private "$1"/ssh/.acfs-import-*/old/ssh_host_ed25519_key' _ "$B"
check "the private key on the ssh row is 0600 and its .pub 0644" \
    bash -c '[[ "$(stat -c %a "$1/ssh/ssh_host_ed25519_key")" == 600 && "$(stat -c %a "$1/ssh/ssh_host_ed25519_key.pub")" == 644 ]]' _ "$B"
check "the import writes this instance's lease into the volume" bash -c '[[ "$(cat "$1/meta/lease")" == lease-b ]]' _ "$B"
check "the journal ends with done" bash -c 'tail -1 "$1/meta/journal" | grep -q " done$"' _ "$B"
check "home rows are chowned to the user, root rows to root" \
    bash -c 'grep -q "chown -R -h $2:$3 $1/home/.acfs-import-" "$4" && grep -q "chown -R -h 0:0 $1/ssh/.acfs-import-" "$4"' _ "$B" "$UID_NOW" "$(id -g)" "$LOG"

INSTANCE_LEASE="lease-b" run "$B" import devbox "$WORK/a.tar.age"
check "a second import refuses the login this machine now holds" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "already holds a login" "$2" && grep -q ".claude/.credentials.json" "$2"' _ "$RC" "$ERR"
echo changed >"$B/home/.codex/auth.json"
INSTANCE_LEASE="lease-b" run "$B" import devbox "$WORK/a.tar.age" --replace
check "--replace replaces it and keeps the old copy" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q codex-secret "$2/home/.codex/auth.json" && grep -qr changed "$2"/home/.acfs-import-*/old/.codex/auth.json' _ "$RC" "$B"

echo "import: tampered archives"
# tamper NAME PYTHON: write an age-stub archive built by PYTHON (which
# gets a tarfile 't' and the helper add(name, data)).
tamper() {
    local name="$1" body="$2"
    python3 -I -c "
import io, sys, tarfile, json, hashlib
buf = io.BytesIO()
t = tarfile.open(fileobj=buf, mode='w', format=tarfile.PAX_FORMAT)
def add(name, data, kind=None, link=''):
    ti = tarfile.TarInfo(name); ti.mode = 0o600
    if kind == 'sym':
        ti.type = tarfile.SYMTYPE; ti.linkname = link; t.addfile(ti); return
    ti.size = len(data); t.addfile(ti, io.BytesIO(data))
def manifest(files, **kw):
    m = {'schema': 1, 'id': 'x', 'kind': 'backup', 'fenced': False, 'tools': {},
         'rows': [{'id': 'codex', 'class': 'login', 'base': 'home', 'path': '.codex', 'policy': 'private', 'markers': [], 'present': True}],
         'files': files}
    m.update(kw)
    add('manifest.json', json.dumps(m).encode())
$body
t.close()
sys.stdout.buffer.write(b'AGESTUB\n' + buf.getvalue())
" >"$WORK/$name.tar.age"
}
C="$WORK/c"
make_machine "$C"
rm -rf "$C/home/.claude" "$C/home/.claude.json" "$C/home/.codex" "$C/home/.config/gh"
# What the machine holds outside its lock and import records.
snapshot() { find "$1/home" "$1/ssh" "$1/ts" -printf '%p %s %m\n' | sort | sha256sum; }
before="$(snapshot "$C")"

tamper dotdot "add('home/.codex/../../../escape', b'x'); manifest([{'path': 'home/.codex/../../../escape', 'sha256': hashlib.sha256(b'x').hexdigest()}])"
run "$C" import devbox "$WORK/dotdot.tar.age"
check "a member with .. is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "not normalized" "$2"' _ "$RC" "$ERR"
tamper absolute "add('/etc/evil', b'x'); manifest([])"
run "$C" import devbox "$WORK/absolute.tar.age"
check "an absolute member is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "refused" "$2"' _ "$RC" "$ERR"
tamper symout "add('home/.codex/l', b'', kind='sym', link='/etc'); manifest([], source={'bases': {'home': '/home/ubuntu'}})"
run "$C" import devbox "$WORK/symout.tar.age"
check "an absolute symlink out of its row is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "symlink leaves its row" "$2"' _ "$RC" "$ERR"
tamper symrel "add('home/.codex/l', b'', kind='sym', link='../../../etc'); manifest([])"
run "$C" import devbox "$WORK/symrel.tar.age"
check "a relative symlink out of its row is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "symlink leaves its row" "$2"' _ "$RC" "$ERR"
tamper symthrough "add('home/.codex/l', b'', kind='sym', link='sub'); add('home/.codex/l/passwd', b'x'); manifest([])"
run "$C" import devbox "$WORK/symthrough.tar.age"
check "a member under a symlink member is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "under a symlink member" "$2"' _ "$RC" "$ERR"
tamper badhash "add('home/.codex/auth.json', b'evil'); manifest([{'path': 'home/.codex/auth.json', 'sha256': '00'}])"
run "$C" import devbox "$WORK/badhash.tar.age"
check "a file whose sha256 differs from manifest.json is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "do not match manifest.json" "$2"' _ "$RC" "$ERR"
tamper norow "add('home/.bashrc-evil', b'x'); manifest([{'path': 'home/.bashrc-evil', 'sha256': hashlib.sha256(b'x').hexdigest()}])"
run "$C" import devbox "$WORK/norow.tar.age"
check "a member under no manifest row is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "not under a manifest row" "$2"' _ "$RC" "$ERR"
X="$WORK/x"
make_machine "$X"
rm -rf "$X/home/.claude" "$X/home/.claude.json" "$X/home/.codex" "$X/home/.config/gh"
tamper chain "add('home/.claude/d/l', b'', kind='sym', link='../..'); add('home/.ssh', b'', kind='sym', link='.claude/d/l/../../../root/.ssh'); manifest([], rows=[
    {'id': 'claude', 'class': 'login', 'base': 'home', 'path': '.claude', 'policy': 'private', 'markers': [], 'present': True},
    {'id': 'ssh-user', 'class': 'login', 'base': 'home', 'path': '.ssh', 'policy': 'private', 'markers': [], 'present': True}])"
run "$X" import devbox "$WORK/chain.tar.age"
check "a chain of relative links is written normalized and stays in the home" \
    bash -c '[[ "$1" -eq 0 && "$(readlink "$2/home/.ssh")" == root/.ssh && "$(readlink "$2/home/.claude/d/l")" == ../.. && ! -e "$2/root" ]]' _ "$RC" "$X"

tamper rowpath "manifest([], rows=[{'id': 'codex', 'class': 'login', 'base': 'home', 'path': '../../etc', 'policy': 'asis', 'markers': [], 'present': True}])"
run "$C" import devbox "$WORK/rowpath.tar.age"
check "a row whose path differs from this machine's is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "names a different path" "$2"' _ "$RC" "$ERR"
tamper rowid "manifest([], rows=[{'id': 'everything', 'class': 'login', 'base': 'home', 'path': '', 'policy': 'asis', 'markers': [], 'present': True}])"
run "$C" import devbox "$WORK/rowid.tar.age"
check "a row this machine doesn't know is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "not in this machine.s manifest" "$2"' _ "$RC" "$ERR"
tamper unfenced "add('home/.codex/auth.json', b'x'); manifest([{'path': 'home/.codex/auth.json', 'sha256': hashlib.sha256(b'x').hexdigest()}], kind='move', fenced=False)"
run "$C" import devbox "$WORK/unfenced.tar.age"
check "a move archive whose source is not fenced is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "not fenced" "$2"' _ "$RC" "$ERR"
INSTANCE_LEASE="" run "$C" import devbox "$WORK/a.tar.age"
check "an import in a container whose instance has no lease is refused up front" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "has no user.acfs.lease" "$2"' _ "$RC" "$ERR"
AGE_FAIL=1 run "$C" import devbox "$WORK/a.tar.age"
check "an archive age can't decrypt is refused" bash -c '[[ "$1" -ne 0 ]] && grep -q "could not decrypt" "$2"' _ "$RC" "$ERR"
check "no refused archive changed the machine's home or root rows" bash -c '[[ "$1" == "$2" ]]' _ "$before" "$(snapshot "$C")"

run "$C" import devbox "$WORK/a.tar.age" --dry-run
check "import --dry-run validates and changes nothing" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "The archive is valid: backup" "$2" && [[ ! -e "$3/home/.codex" ]]' _ "$RC" "$OUT" "$C"

echo "import: resume after an interruption"
D="$WORK/d"
make_machine "$D"
rm -rf "$D/home/.claude" "$D/home/.claude.json" "$D/home/.codex" "$D/home/.config/gh"
chmod 0500 "$D/home/.config"
INSTANCE_LEASE="lease-d" run "$D" import devbox "$WORK/a.tar.age"
check "an import that fails mid-swap exits non-zero" bash -c '[[ "$1" -ne 0 ]]' _ "$RC"
check "rows before the failure are in place" bash -c 'grep -q codex-secret "$1/home/.codex/auth.json"' _ "$D"
run "$D" import devbox "$WORK/a.tar.age"
check "a new import refuses while one is interrupted" bash -c '[[ "$1" -ne 0 ]] && grep -q "was interrupted" "$2"' _ "$RC" "$ERR"
chmod 0700 "$D/home/.config"
INSTANCE_LEASE="lease-d" run "$D" import devbox --resume
check "--resume finishes the import" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "github.com" "$2/home/.config/gh/hosts.yml" && tail -1 "$2/meta/journal" | grep -q " done$"' _ "$RC" "$D"

echo "export --move"
E="$WORK/e"
make_machine "$E"
: >"$LOG"
ACTIVE_UNITS="user@$UID_NOW.service" run "$E" export devbox "$WORK/move.tar.age" --recipient age1x --move
check "a move export succeeds and fences the volume's lease" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "^fenced:devbox-" "$2/meta/lease"' _ "$RC" "$E"
check "a move export leaves the user manager stopped" \
    bash -c 'grep -q "systemctl stop user@" "$1" && ! grep -q "systemctl start" "$1"' _ "$LOG"
F="$WORK/f"
make_machine "$F"
rm -rf "$F/home/.claude" "$F/home/.claude.json" "$F/home/.codex" "$F/home/.config/gh"
INSTANCE_LEASE="lease-f" run "$F" import devbox "$WORK/move.tar.age"
check "the fenced move archive imports" bash -c '[[ "$1" -eq 0 ]]' _ "$RC"

echo "lease"
L="$WORK/l"
mkdir -p "$L/meta" "$L/home"
INSTANCE_LEASE="" run "$L" lease check
check "no lease anywhere: pass" bash -c '[[ "$1" -eq 0 ]] && grep -q "none on the volume" "$2"' _ "$RC" "$OUT"
INSTANCE_LEASE="tok1" run "$L" lease check
check "volume empty, instance set: first claim writes the volume" bash -c '[[ "$1" -eq 0 && "$(cat "$2/meta/lease")" == tok1 ]]' _ "$RC" "$L"
INSTANCE_LEASE="tok1" run "$L" lease check
check "matching leases: pass" bash -c '[[ "$1" -eq 0 ]] && grep -q "holds the state volume" "$2"' _ "$RC" "$OUT"
INSTANCE_LEASE="tok2" run "$L" lease check
check "a different instance's lease: refuse" bash -c '[[ "$1" -ne 0 ]] && grep -q "another instance holds" "$2"' _ "$RC" "$ERR"
INSTANCE_LEASE="" run "$L" lease check
check "volume set, instance without a lease: refuse" bash -c '[[ "$1" -ne 0 ]]' _ "$RC"
INSTANCE_LEASE="tok1" GUEST_DOWN=1 run "$L" lease check
check "a guest API that doesn't answer: refuse, after retrying" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "did not answer" "$2" && [[ "$(grep -c "^curl " "$3")" -ge 2 ]]' _ "$RC" "$ERR" "$LOG"
run "$E" lease check
check "a fenced volume: refuse, naming reclaim through incus exec" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "incus exec <name> -- sudo acfs state lease reclaim" "$2"' _ "$RC" "$ERR"
INSTANCE_LEASE="" run "$E" lease reclaim
check "reclaim refuses in a container whose instance has no lease" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "^fenced:" "$2/meta/lease"' _ "$RC" "$E"
INSTANCE_LEASE="tok-e" run "$E" lease reclaim
check "reclaim takes the lease back" bash -c '[[ "$1" -eq 0 && "$(cat "$2/meta/lease")" == tok-e ]]' _ "$RC" "$E"
check "the lease file is 0600" bash -c '[[ "$(stat -c %a "$1/meta/lease")" == 600 ]]' _ "$E"
run "$L" lease new
check "lease new prints 32 hex chars" bash -c 'grep -qxE "[0-9a-f]{32}" "$1"' _ "$OUT"
INSTANCE_LEASE="tok1" run "$L" lease status
check "lease status never prints the token" bash -c '! grep -q tok1 "$1" && grep -q "match: yes" "$1"' _ "$OUT"

echo "repair"
chmod 0644 "$A/home/.codex/auth.json" "$A/ssh/ssh_host_ed25519_key"
chmod 0755 "$A/home/.codex"
chmod 0664 "$A/home/.config/systemd/user/x.service"
run "$A" repair --dry-run
check "repair --dry-run names the rows and changes nothing" \
    bash -c 'grep -q "^codex: no group or other access" "$1" && [[ "$(stat -c %a "$2/home/.codex/auth.json")" == 644 ]]' _ "$OUT" "$A"
run "$A" repair
check "repair makes secret files 0600, dirs 0700, keeps .pub 0644" \
    bash -c '[[ "$(stat -c %a "$1/home/.codex/auth.json")" == 600 && "$(stat -c %a "$1/home/.codex")" == 700 && "$(stat -c %a "$1/ssh/ssh_host_ed25519_key")" == 600 && "$(stat -c %a "$1/ssh/ssh_host_ed25519_key.pub")" == 644 ]]' _ "$A"
check "repair leaves asis rows alone" \
    bash -c '[[ "$(stat -c %a "$1/home/.config/systemd/user/x.service")" == 664 ]]' _ "$A"

echo "doctor"
chmod 0644 "$A/home/.codex/auth.json"
run "$A" doctor --json
check "doctor --json is an array of {id,label,status,details,fix}" \
    bash -c 'jq -e "type == \"array\" and all(.[]; has(\"id\") and has(\"label\") and has(\"status\") and has(\"details\") and has(\"fix\"))" "$1" >/dev/null' _ "$OUT"
check "doctor passes the layer when every path is a mount" \
    bash -c 'jq -e ".[] | select(.id == \"state.layer\" and .status == \"pass\")" "$1" >/dev/null' _ "$OUT"
check "doctor warns on a group-readable login and names repair" \
    bash -c 'jq -e ".[] | select(.id == \"state.modes\" and .status == \"warn\" and (.details | contains(\"codex\")) and .fix == \"sudo acfs state repair\")" "$1" >/dev/null' _ "$OUT"
check "doctor reports the unknown dot-directory" \
    bash -c 'jq -e ".[] | select(.id == \"state.unknown\" and .status == \"warn\" and (.details | contains(\".weirdtool\")))" "$1" >/dev/null' _ "$OUT"
check "doctor's lease check passes on an active, successful unit" \
    bash -c 'jq -e ".[] | select(.id == \"state.lease\" and .status == \"pass\")" "$1" >/dev/null' _ "$OUT"
check "doctor never prints a secret" bash -c '! grep -q secret "$1"' _ "$OUT"
LEASE_ACTIVE=failed LEASE_RESULT=exit-code run "$A" doctor --json
check "doctor fails the lease when its unit failed" \
    bash -c 'jq -e ".[] | select(.id == \"state.lease\" and .status == \"fail\")" "$1" >/dev/null' _ "$OUT"
LEASE_LOAD=not-found LEASE_ACTIVE=inactive run "$A" doctor --json
check "doctor warns when the lease unit isn't installed" \
    bash -c 'jq -e ".[] | select(.id == \"state.lease\" and .status == \"warn\")" "$1" >/dev/null' _ "$OUT"
MOUNTED=no run "$A" doctor --json
check "doctor fails the layer when the home is not a mount" \
    bash -c 'jq -e ".[] | select(.id == \"state.layer\" and .status == \"fail\")" "$1" >/dev/null' _ "$OUT"
N="$WORK/n"
mkdir -p "$N/home"
VIRT=none run "$N" doctor --json
check "on a VPS without the layer, doctor skips" \
    bash -c 'jq -e ".[] | select(.id == \"state.layer\" and .status == \"skip\")" "$1" >/dev/null' _ "$OUT"
VIRT=lxc run "$N" doctor --json
check "in a container without the layer, doctor warns" \
    bash -c 'jq -e ".[] | select(.id == \"state.layer\" and .status == \"warn\")" "$1" >/dev/null' _ "$OUT"

echo "setup-guest"
G="$WORK/g"
make_machine "$G"
rm -f "$G/ssh"/ssh_host_*
: >"$LOG"
run "$G" setup-guest
check "setup-guest succeeds" bash -c '[[ "$1" -eq 0 ]]' _ "$RC"
check "the lease unit runs a root-owned copy before the user manager" \
    bash -c 'grep -q "^ExecStart=/bin/bash $1/libexec/state_layer.sh lease check$" "$1/systemd/acfs-state-lease.service" && grep -q "^Before=user@$2.service tailscaled.service$" "$1/systemd/acfs-state-lease.service" && cmp -s "$1/libexec/state_layer.sh" "$3"' _ "$G" "$UID_NOW" "$STATE"
check "user@ and tailscaled require the lease unit" \
    bash -c 'grep -q "^Requires=acfs-state-lease.service$" "$1/systemd/user@$2.service.d/10-acfs-lease.conf" && grep -q "^After=acfs-state-lease.service$" "$1/systemd/tailscaled.service.d/10-acfs-lease.conf"' _ "$G" "$UID_NOW"
check "setup-guest enables the unit and reloads systemd" \
    bash -c 'grep -q "systemctl daemon-reload" "$1" && grep -q "systemctl enable acfs-state-lease.service" "$1"' _ "$LOG"
check "host keys are seeded from /etc/ssh onto the volume" bash -c 'grep -q etc-private "$1/ssh/ssh_host_ed25519_key"' _ "$G"
check "the sshd drop-in names the volume's keys and sshd -t ran" \
    bash -c 'grep -qx "HostKey $1/ssh/ssh_host_ed25519_key" "$1/etcssh/sshd_config.d/10-acfs-host-keys.conf" && grep -q "sshd -t" "$2"' _ "$G" "$LOG"
: >"$LOG"
run "$G" setup-guest
check "a second setup-guest changes nothing and doesn't reload" \
    bash -c '[[ "$1" -eq 0 ]] && ! grep -q daemon-reload "$2" && ! grep -q "sshd -t" "$2"' _ "$RC" "$LOG"
rm -f "$G/etcssh/sshd_config.d/10-acfs-host-keys.conf"
SSHD_FAIL=1 run "$G" setup-guest
check "a drop-in sshd rejects is set aside with a warning, and the install goes on" \
    bash -c '[[ "$1" -eq 0 && ! -e "$2/etcssh/sshd_config.d/10-acfs-host-keys.conf" && -e "$2/etcssh/sshd_config.d/10-acfs-host-keys.conf.rejected" ]] && grep -q "sshd -t rejected" "$3"' _ "$RC" "$G" "$ERR"
rm -f "$G/etcssh/sshd_config.d/10-acfs-host-keys.conf.rejected"
run "$G" setup-guest
echo rsa-private >"$G/ssh/ssh_host_rsa_key"
SSHD_FAIL=1 run "$G" setup-guest
check "a rejected change puts back the drop-in sshd ran with" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx "HostKey $2/ssh/ssh_host_ed25519_key" "$2/etcssh/sshd_config.d/10-acfs-host-keys.conf" && ! grep -q rsa "$2/etcssh/sshd_config.d/10-acfs-host-keys.conf"' _ "$RC" "$G"
H="$WORK/h"
make_machine "$H"
: >"$LOG"
GUEST_SOCK="$WORK/no-such-sock" run "$H" setup-guest
check "without the guest API, no lease unit is installed" \
    bash -c '[[ "$1" -eq 0 && ! -e "$2/systemd/acfs-state-lease.service" ]] && grep -q "No guest API" "$3"' _ "$RC" "$H" "$OUT"
rm -rf "$H/meta"
run "$H" setup-guest
check "without a state volume, setup-guest does nothing" bash -c '[[ "$1" -eq 0 ]] && grep -q "nothing to set up" "$2"' _ "$RC" "$OUT"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
