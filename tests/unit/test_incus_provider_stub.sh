#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus.sh against a STUB incus
#
# Proves the launcher's decisions and output: which incus calls it makes in
# each state, with which arguments and stdin, and what it prints. The stub
# replays `incus list`/`incus query` JSON captured from real Incus 6.0.5
# (tests/unit/fixtures/incus/README.md), plus a hand-written `/1.0` for a
# 6.0.5 server with the required extensions and without the optional ones.
# Nothing here touches real Incus or an instance; that is
# tests/vm/test_incus_provider.sh.
#
# Usage: bash tests/unit/test_incus_provider_stub.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/tests/unit/fixtures/incus"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-stub.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# ------------------------------------------------------------
# A throwaway checkout holding the launcher, so the archive and the
# dirty-tree warning are tested without touching this repo.
# ------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/scripts/providers" "$REPO/scripts/lib"
cp "$ROOT/scripts/providers/incus.sh" "$REPO/scripts/providers/incus.sh"
cp "$ROOT/scripts/lib/logging.sh" "$REPO/scripts/lib/logging.sh"
printf '#!/usr/bin/env bash\necho committed installer\n' >"$REPO/install.sh"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"

# Synthetic keys: the attaching machine's public key and the instance's host key.
ssh-keygen -q -t ed25519 -N '' -C laptop -f "$WORK/laptop"
ssh-keygen -q -t ed25519 -N '' -C host -f "$WORK/hostkey"
printf 'not a key\n' >"$WORK/not-a-key.pub"

# ------------------------------------------------------------
# The stub. It logs "<stdin>\t<argv>" per call, where <stdin> is "null"
# when stdin is /dev/null, and answers from the fixtures and $STUB_DIR:
# the server's /1.0 is server.json; a profile exists when profile-<name>
# does; an ACL when acl-<name>.yaml does; a volume when volume-<pool>-<name>
# does. Remote prefixes are stripped from the names it looks up.
# ------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
stdin=other
[[ "$(readlink /proc/self/fd/0)" == /dev/null ]] && stdin=null
args="$*"
printf '%s\t%s\n' "$stdin" "${args//$'\n'/\\n}" >>"$STUB_DIR/calls"
case "$1" in
    list) cat "$STUB_DIR/list.json" ;;
    query)
        case "$2" in
            */1.0) cat "$STUB_DIR/server.json" ;;
            */1.0/profiles/default) cat "$STUB_FIXTURES/profile-default.json" ;;
            */1.0/networks/*) cat "$STUB_DIR/network.json" ;;
        esac
        ;;
    profile)
        [[ "$2" == show && -f "$STUB_DIR/profile-${3#*:}" ]] || { echo 'Error: Profile not found' >&2; exit 1; }
        ;;
    network)
        case "$3" in
            show) [[ -f "$STUB_DIR/acl-${4#*:}.yaml" ]] || { echo 'Error: Network ACL not found' >&2; exit 1; } ;;
            # Like the real client, it reports the creation on stdout unless --quiet.
            create)
                if [[ "$4" == --quiet ]]; then
                    cat >"$STUB_DIR/acl-${5#*:}.yaml"
                else
                    cat >"$STUB_DIR/acl-${4#*:}.yaml"
                    echo "Network ACL ${4#*:} created"
                fi
                ;;
        esac
        ;;
    storage)
        case "$3" in
            show) [[ -f "$STUB_DIR/volume-${4#*:}-$5" ]] || { echo 'Error: Storage pool volume not found' >&2; exit 1; } ;;
            create)
                printf '%s\n' "${*:4}" >>"$STUB_DIR/volume-create"
                : >"$STUB_DIR/volume-${4#*:}-$5"
                echo "Storage volume $5 created"
                ;;
        esac
        ;;
    init)
        shift
        printf '%s\n' "$@" >"$STUB_DIR/init.args"
        cp "$STUB_FIXTURES/list-stopped-marked.json" "$STUB_DIR/list.json"
        ;;
    start) cp "$STUB_FIXTURES/list-running-started.json" "$STUB_DIR/list.json" ;;
    # Real `incus file push` writes its progress to stdout unless --quiet.
    file)
        shift 2
        if [[ "$1" == --quiet ]]; then shift; else printf '\rPushing %s: 100%%\n' "$1"; fi
        cp "$1" "$STUB_DIR/pushed-${2##*/}"
        ;;
    config)
        case "$2" in
            set) printf '%s\n' "$4" >>"$STUB_DIR/config-set" ;;
            device) printf '%s\n' "${*:5}" >>"$STUB_DIR/device-add" ;;
        esac
        ;;
    exec)
        shift 2
        while [[ "$1" != "--" ]]; do
            [[ "$1" == "--env" ]] && { printf '%s\n' "$2" >>"$STUB_DIR/exec-env"; shift; }
            shift
        done
        shift
        case "$1" in
            # Real `cloud-init status` exits 0 (done or running), 1 (error)
            # or 2 (done with recoverable errors).
            cloud-init)
                printf 'status: %s\n' "${STUB_CLOUD_INIT:-done}"
                exit "${STUB_CLOUD_INIT_EXIT:-0}"
                ;;
            cat) cat "$STUB_HOST_KEY" ;;
            runuser) echo 'herdr 0.9.3' ;;
            ssh-keygen) echo '256 SHA256:stubfingerprint laptop (ED25519)' ;;
            bash) echo 'INSTALLER OUTPUT'; exit "${STUB_INSTALL_EXIT:-0}" ;;
        esac
        ;;
esac
STUB
chmod +x "$WORK/bin/incus"

CASE=""
RC=0

# new_case <name> <list fixture state>: a fresh stub state for one run, on
# a host where host-setup has run: the swarm profile and ACL exist, the
# server is 6.0.5 with the required extensions, the env file names the pool
# "acfs", and no volume exists.
new_case() {
    CASE="$WORK/case-$1"
    mkdir -p "$CASE/home/.config/acfs"
    cp "$FIXTURES/list-$2.json" "$CASE/list.json"
    cp "$FIXTURES/network-incusbr0.json" "$CASE/network.json"
    cp "$FIXTURES/server-1.0.json" "$CASE/server.json"
    : >"$CASE/profile-acfs-swarm"
    printf 'existing\n' >"$CASE/acl-acfs-swarm-egress.yaml"
    printf 'ACFS_INCUS_POOL=acfs\nACFS_INCUS_STORAGE_SOURCE=/scratch/incus\nACFS_INCUS_PROJECT=acfs-tests\nACFS_INCUS_BRIDGE_TESTS=acfstest0\n' \
        >"$CASE/home/.config/acfs/incus.env"
    : >"$CASE/calls"
}

# Runs the launcher with a non-empty pipe on stdin, so any incus call that
# inherited it shows up as stdin=other.
run_launcher() {
    set +e
    echo 'stdin that incus must not read' | \
        PATH="$WORK/bin:$PATH" STUB_DIR="$CASE" STUB_FIXTURES="$FIXTURES" \
        STUB_HOST_KEY="$WORK/hostkey.pub" NO_COLOR=1 \
        HOME="$CASE/home" XDG_CONFIG_HOME="$CASE/home/.config" \
        "$REPO/scripts/providers/incus.sh" "$@" >"$CASE/out" 2>"$CASE/err"
    RC=$?
    set -e
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
called() { grep -q -- "$1" "$CASE/calls"; }
not_called() { ! grep -q -- "$1" "$CASE/calls"; }
no_init() { not_called $'\tinit '; }
no_calls() { [[ ! -s "$CASE/calls" ]]; }
err_has() { grep -q -- "$1" "$CASE/err"; }
err_lacks() { ! grep -q -- "$1" "$CASE/err"; }
init_has() { grep -qx -- "$1" "$CASE/init.args"; }
init_lacks() { ! grep -q -- "$1" "$CASE/init.args"; }
device_added() { grep -qx -- "$1" "$CASE/device-add"; }
volume_created() { grep -qx -- "$1" "$CASE/volume-create"; }
no_volume_calls() { not_called $'\tstorage volume '; }
# The line number of the first call matching $1, for ordering checks.
call_line() { grep -n -- "$1" "$CASE/calls" | head -n 1 | cut -d: -f1; }
called_before() { [[ -n "$(call_line "$1")" && -n "$(call_line "$2")" && "$(call_line "$1")" -lt "$(call_line "$2")" ]]; }
called_in_order() { called_before "$1" "$2" && called_before "$2" "$3"; }
both_called() { called "$1" && called "$2"; }
lease_set() { grep -q -E '^user\.acfs\.lease=[0-9a-f]{32}$' "$CASE/config-set"; }
no_lease_set() { [[ ! -e "$CASE/config-set" ]] || ! grep -q '^user\.acfs\.lease=' "$CASE/config-set"; }
no_volumes_at_all() { no_volume_calls && [[ ! -e "$CASE/device-add" ]]; }
only_the_lookup() { [[ "$(cut -f2 "$CASE/calls" | cut -d' ' -f1 | sort -u)" == list ]]; }
two_quiet_pushes() {
    [[ "$(grep -c $'\tfile push --quiet ' "$CASE/calls")" -eq 2 \
        && "$(grep -c $'\tfile push ' "$CASE/calls")" -eq 2 ]]
}
# The only -d values allowed at init: the root disk's pool and size (one key
# per -d: the client takes everything after the first "=" as the value) and
# the NIC's ACL keys. The volumes come after, through `config device add`.
only_expected_devices() {
    local size="$1" previous="" arg
    while IFS= read -r arg; do
        if [[ "$previous" == "-d" && "$arg" != "root,pool=acfs" && "$arg" != "root,size=$size" && "$arg" != eth0,security.acls* ]]; then
            return 1
        fi
        previous="$arg"
    done <"$CASE/init.args"
}
root_on_pool_sized() { init_has 'root,pool=acfs' && init_has "root,size=$1"; }
only_null_stdin_except_acl_create() {
    ! grep -v $'^null\t' "$CASE/calls" | grep -v $'^other\tnetwork acl create ' | grep -q .
}

# expected_block <jump> [failed]
expected_block() {
    local jump="$1" failed="${2:-}"
    if [[ -n "$jump" ]]; then
        echo '# Add to ~/.ssh/config on the machine you attach from, ABOVE any "Host *" block:'
    else
        echo '# Add to ~/.ssh/config on the Incus host, ABOVE any "Host *" block:'
    fi
    echo 'Host dev'
    echo '    HostName 192.0.2.20'
    echo '    User ubuntu'
    [[ -z "$jump" ]] || echo "    ProxyJump $jump"
    echo '    HostKeyAlias dev'
    echo '    StrictHostKeyChecking yes'
    echo '    ForwardAgent no'
    echo '# Add to ~/.ssh/known_hosts on that machine:'
    echo "dev $(awk '{print $1, $2}' "$WORK/hostkey.pub")"
    if [[ -z "$failed" ]]; then
        echo '# Then run there (dev runs herdr 0.9.3):'
        echo 'herdr machine add dev'
    else
        echo '# The install failed: re-run this command; it prints the herdr machine add line once ACFS is installed.'
    fi
}
stdout_is_block() { diff -u <(expected_block "$@") "$CASE/out" >&2; }

echo "== absent instance: an unprivileged container by default: check, create, attach, install, print (with --jump)"
new_case create absent
run_launcher dev --ssh-key "$WORK/laptop.pub" --jump box
check "exits 0" rc_is 0
check "queries the server's API extensions" called $'\tquery /1.0$'
check "says the server has what a container needs" err_has 'Incus 6.0.5 has what a container needs'
check "notes the optional oom_priority extension is missing" err_has 'Incus 6.0.5 lacks the optional API extension instance_limits_oom'
check "notes the optional tmpfs disk extension is missing" err_has 'Incus 6.0.5 lacks the optional API extension container_disk_tmpfs'
check "checks that the swarm profile exists" called $'\tprofile show acfs-swarm$'
check "uses the existing swarm ACL unchecked" err_has 'Using the existing network ACL acfs-swarm-egress'
check "creates the state volume on the pool from incus.env, 20 GiB" volume_created 'acfs acfs-state-dev size=20GiB'
check "creates the data volume on the pool, 60 GiB" volume_created 'acfs dev-data size=60GiB'
check "inits the cloud image" init_has 'images:ubuntu/26.04/cloud'
check "doesn't pass --vm" init_lacks '^--vm$'
check "applies the default profile and the swarm profile, in that order" \
    bash -c '[[ "$(grep -A1 -x -- -p "$1" | grep -v -x -e -p -e -- | tr "\n" " ")" == "default acfs-swarm " ]]' _ "$CASE/init.args"
check "passes no limits (the swarm profile's)" init_lacks '^limits\.'
check "pins it unprivileged" init_has 'security.privileged=false'
check "pins nesting off" init_has 'security.nesting=false'
check "gives it its own uid/gid range" init_has 'security.idmap.isolated=true'
check "marks the instance as the launcher's" init_has 'user.acfs.provider=incus'
check "doesn't mark the install started at init (that comes after the volumes)" init_lacks 'user.acfs.install-started'
check "root disk 40 GiB on the pool from incus.env (one key per -d)" root_on_pool_sized 40GiB
check "attaches the swarm ACL to the profile's NIC" init_has 'eth0,security.acls=acfs-swarm-egress'
check "unmatched egress passes the ACL" init_has 'eth0,security.acls.default.egress.action=allow'
check "unmatched ingress passes the ACL" init_has 'eth0,security.acls.default.ingress.action=allow'
check "no device at init beyond root and the NIC's ACL keys" only_expected_devices 40GiB
check "user-data authorizes exactly the given key" \
    bash -c 'grep -A1 -x -- -c "$1" | grep "^cloud-init.user-data=" >/dev/null && [[ "$(grep -c "^  - \"ssh-ed25519 " "$1")" -eq 1 ]] && grep -qF "$(cut -d" " -f2 "$2")" "$1"' _ "$CASE/init.args" "$WORK/laptop.pub"
check "user-data installs openssh-server" grep -q 'packages: \[openssh-server, curl, git, jq, ca-certificates, unzip\]' "$CASE/init.args"
check "user-data leaves ssh_pwauth unset (sshd keeps the packaged config)" bash -c '! grep -q ssh_pwauth "$1"' _ "$CASE/init.args"
check "mounts the state volume's home/ at the user's home, 1000:1000 0700" \
    device_added 'state-home disk pool=acfs source=acfs-state-dev/home path=/home/ubuntu initial.uid=1000 initial.gid=1000 initial.mode=0700'
check "mounts root/ssh-host/ for the SSH host keys, root 0700" \
    device_added 'state-ssh-host disk pool=acfs source=acfs-state-dev/root/ssh-host path=/etc/ssh/acfs-host-keys initial.uid=0 initial.gid=0 initial.mode=0700'
check "mounts root/tailscale/ at /var/lib/tailscale, root 0700" \
    device_added 'state-tailscale disk pool=acfs source=acfs-state-dev/root/tailscale path=/var/lib/tailscale initial.uid=0 initial.gid=0 initial.mode=0700'
check "mounts .acfs/ (lease, lock, journal) at /etc/acfs/state, root 0700" \
    device_added 'state-acfs disk pool=acfs source=acfs-state-dev/.acfs path=/etc/acfs/state initial.uid=0 initial.gid=0 initial.mode=0700'
check "mounts the data volume at /data" \
    device_added 'data disk pool=acfs source=dev-data path=/data initial.uid=1000 initial.gid=1000 initial.mode=0755'
check "exactly five devices are added" bash -c '[[ "$(wc -l <"$1")" -eq 5 ]]' _ "$CASE/device-add"
check "sets a fresh 32-hex-digit lease on the instance" lease_set
check "never prints the lease token" \
    bash -c '! grep -q "$(sed -n "s/^user.acfs.lease=//p" "$1")" "$2" "$3"' _ "$CASE/config-set" "$CASE/out" "$CASE/err"
check "checks the server before creating anything" called_before $'\tquery /1.0$' $'\tstorage volume create '
check "creates the volumes before the instance" called_before $'\tstorage volume create ' $'\tinit '
check "attaches the volumes after init and before the start" called_in_order $'\tinit ' $'\tconfig device add ' $'\tstart dev$'
check "sets the lease after the volumes, before the start" called_in_order $'\tconfig device add ' $'\tconfig set dev user.acfs.lease=' $'\tstart dev$'
check "marks the install started after the volumes, before the start" \
    called_in_order $'\tconfig device add ' "config set dev user.acfs.install-started=$SHA" $'\tstart dev$'
check "starts the container" called $'\tstart dev$'
check "every incus call gets /dev/null on stdin" only_null_stdin_except_acl_create
check "pushes HEAD as a bootstrap archive with GitHub's prefix" \
    bash -c 'tar -tzf "$1" | grep -qx "agentic_coding_flywheel_setup-$2/install.sh"' _ "$CASE/pushed-acfs.tar.gz" "$SHA"
check "pushes HEAD's install.sh" grep -qx 'echo committed installer' "$CASE/pushed-install.sh"
check "both pushes are quiet (no progress lines on stderr)" two_quiet_pushes
check "runs the installer for ubuntu" grep -qx 'TARGET_USER=ubuntu' "$CASE/exec-env"
check "passes the fork as the repo owner" grep -qx 'ACFS_REPO_OWNER=arosl' "$CASE/exec-env"
check "runs the installer with --bootstrap-archive" called '--bootstrap-archive /root/acfs.tar.gz < /root/install.sh'
check "runs it in its own process group, so Ctrl-C stops it" \
    called $'\texec dev --env TARGET_USER=ubuntu --env ACFS_REPO_OWNER=arosl -- bash -c set -m; "$@" & p=$!; trap "kill -INT -- -$p" INT TERM HUP; wait "$p"; s=$?; wait "$p" 2>/dev/null; exit "$s" acfs-install bash -c bash -s -- '
check "records the installed sha" grep -qx "user.acfs.installed=$SHA" "$CASE/config-set"
check "stdout is exactly the attach block (installer output stays on stderr)" stdout_is_block box
check "installer output went to stderr" err_has 'INSTALLER OUTPUT'
check "says it creates an unprivileged container with the profile" err_has 'Creating unprivileged container dev from images:ubuntu/26.04/cloud with profile acfs-swarm'
check "says the disk size holds only where the pool enforces it" err_has 'where the pool enforces it'
check "says what it attaches" err_has 'Attaching acfs-state-dev (home, SSH host keys, Tailscale, lease) and dev-data (/data)'
check "waits for the container" err_has 'Waiting for the container to accept incus exec'
check "stderr names the keys ubuntu accepts" err_has 'ubuntu accepts: 256 SHA256:stubfingerprint'
check "stderr names the given key's fingerprint before the init" \
    bash -c 'f="$(ssh-keygen -l -f "$2" | cut -d" " -f2)"; n="$(grep -n "Authorizing for ubuntu: .*$f" "$1" | head -1 | cut -d: -f1)"; c="$(grep -n "Creating unprivileged container" "$1" | head -1 | cut -d: -f1)"; [[ -n "$n" && -n "$c" && "$n" -lt "$c" ]]' _ "$CASE/err" "$WORK/laptop.pub"

echo "== absent container, no --jump"
new_case nojump absent
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 0" rc_is 0
check "stdout is the block without ProxyJump" stdout_is_block ''

echo "== sizes and --acl apply at creation"
new_case sizes absent
printf 'existing\n' >"$CASE/acl-my-egress.yaml"
run_launcher dev --ssh-key "$WORK/laptop.pub" --root-size 100GiB --state-size 60GiB --data-size 400GiB --acl my-egress
check "exits 0" rc_is 0
check "root disk 100 GiB" root_on_pool_sized 100GiB
check "state volume 60 GiB" volume_created 'acfs acfs-state-dev size=60GiB'
check "data volume 400 GiB" volume_created 'acfs dev-data size=400GiB'
check "the named ACL is on the NIC" init_has 'eth0,security.acls=my-egress'
check "the named ACL is used as it is" err_has 'Using the existing network ACL my-egress'

echo "== existing volumes are reused (a rebuild keeps the state)"
new_case volumes-exist absent
: >"$CASE/volume-acfs-acfs-state-dev"
: >"$CASE/volume-acfs-dev-data"
run_launcher dev --ssh-key "$WORK/laptop.pub" --state-size 60GiB
check "exits 0" rc_is 0
check "creates no volume" not_called 'storage volume create'
check "says the state volume is reused, unresized" err_has 'Using the existing volume acfs-state-dev on pool acfs as it is'
check "says the data volume is reused" err_has 'Using the existing volume dev-data on pool acfs as it is'
check "attaches them all the same" device_added 'state-home disk pool=acfs source=acfs-state-dev/home path=/home/ubuntu initial.uid=1000 initial.gid=1000 initial.mode=0700'

echo "== --vm: a VM with the launcher's own limits, no profile, no volumes"
new_case vm absent
run_launcher dev --ssh-key "$WORK/laptop.pub" --vm --jump box
check "exits 0" rc_is 0
check "inits the same cloud image" init_has 'images:ubuntu/26.04/cloud'
check "passes --vm" init_has '--vm'
check "limits: 4 vCPU" init_has 'limits.cpu=4'
check "limits: 8 GiB" init_has 'limits.memory=8GiB'
check "root disk 40 GiB on the pool" root_on_pool_sized 40GiB
check "no profile beyond the default" init_lacks '^-p$'
check "a VM gets none of the container's security keys" init_lacks '^security\.'
check "marks the instance as the launcher's" init_has 'user.acfs.provider=incus'
check "attaches the VM ACL to the profile's NIC" init_has 'eth0,security.acls=acfs-vm-egress'
check "creates the VM ACL, rejecting private, CGNAT and link-local egress" \
    grep -q 'destination: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,fc00::/7,fe80::/10' "$CASE/acl-acfs-vm-egress.yaml"
check "every incus call but the ACL's YAML gets /dev/null on stdin" only_null_stdin_except_acl_create
check "no device at init beyond root and the NIC's ACL keys" only_expected_devices 40GiB
check "doesn't query the server" not_called $'\tquery /1.0$'
check "doesn't look for the swarm profile" not_called 'profile show'
check "creates and attaches no volume" no_volumes_at_all
check "sets no lease" no_lease_set
check "marks the install started before the start" called_before "config set dev user.acfs.install-started=$SHA" $'\tstart dev$'
check "says it creates a VM" err_has 'Creating VM dev from images:ubuntu/26.04/cloud (4 vCPU, 8 GiB RAM, 40GiB disk on pool acfs)'
check "waits for the VM agent" err_has 'Waiting for the VM to accept incus exec'
check "runs the installer the same way" called '--bootstrap-archive /root/acfs.tar.gz < /root/install.sh'
check "records the installed sha" grep -qx "user.acfs.installed=$SHA" "$CASE/config-set"
check "stdout is exactly the attach block" stdout_is_block box

echo "== --vm with an existing VM ACL: left as it is"
new_case vm-acl-exists absent
printf 'existing\n' >"$CASE/acl-acfs-vm-egress.yaml"
run_launcher dev --ssh-key "$WORK/laptop.pub" --vm
check "exits 0" rc_is 0
check "does not create the ACL again" not_called 'network acl create'
check "does not change the ACL" grep -qx existing "$CASE/acl-acfs-vm-egress.yaml"
check "says it uses the existing ACL unchecked" err_has 'Using the existing network ACL acfs-vm-egress'

echo "== refusals before anything is created (container)"
new_case no-env absent
rm -f "$CASE/home/.config/acfs/incus.env"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "no incus.env: exits 2" rc_is 2
check "no incus.env: names the file and host-setup" err_has "acfs/incus.env is missing: run 'scripts/providers/incus.sh host-setup --storage <path|pool>'"
check "no incus.env: makes no incus call" no_calls
new_case env-no-pool absent
printf 'ACFS_INCUS_PROJECT=acfs-tests\n' >"$CASE/home/.config/acfs/incus.env"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "incus.env without a pool: exits 2" rc_is 2
check "incus.env without a pool: says so" err_has 'sets no usable ACFS_INCUS_POOL'
check "incus.env without a pool: makes no incus call" no_calls
new_case env-quoted absent
printf 'ACFS_INCUS_POOL="acfs"\n' >"$CASE/home/.config/acfs/incus.env"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "a quoted pool value is read without the quotes" init_has 'root,pool=acfs'
new_case no-profile absent
rm -f "$CASE/profile-acfs-swarm"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "no swarm profile: exits 1" rc_is 1
check "no swarm profile: names it and host-setup" err_has "profile acfs-swarm doesn't exist: run 'scripts/providers/incus.sh host-setup'"
check "no swarm profile: creates no volume" no_volume_calls
check "no swarm profile: inits nothing" no_init
new_case no-swarm-acl absent
rm -f "$CASE/acl-acfs-swarm-egress.yaml"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "no swarm ACL: exits 1" rc_is 1
check "no swarm ACL: says host-setup creates it" err_has "network ACL acfs-swarm-egress doesn't exist; host-setup creates acfs-swarm-egress and acfs-vm-egress"
check "no swarm ACL: doesn't create it" not_called 'network acl create'
check "no swarm ACL: creates no volume" no_volume_calls
check "no swarm ACL: inits nothing" no_init
new_case acl-missing absent
run_launcher dev --ssh-key "$WORK/laptop.pub" --acl nosuch
check "--acl of an absent ACL: exits 1" rc_is 1
check "--acl of an absent ACL: names it" err_has "network ACL nosuch doesn't exist"
check "--acl of an absent ACL: inits nothing" no_init
new_case no-extension absent
jq '.api_extensions -= ["disk_volume_subpath"]' "$FIXTURES/server-1.0.json" >"$CASE/server.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "a required extension missing: exits 1" rc_is 1
check "a required extension missing: names it" err_has 'Incus 6.0.5 lacks the API extension disk_volume_subpath, which a container needs'
check "a required extension missing: creates no volume" no_volume_calls
check "a required extension missing: inits nothing" no_init
# The version string decides nothing: an old-looking server with the
# extensions passes, a new-looking one without them is refused.
new_case old-version-with-extensions absent
jq '.environment.server_version = "5.21.0"' "$FIXTURES/server-1.0.json" >"$CASE/server.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "an old version string with the extensions: exits 0" rc_is 0
check "an old version string with the extensions: is named in the note" err_has 'Incus 5.21.0 has what a container needs'
new_case new-version-without-extension absent
jq '.environment.server_version = "6.20" | .api_extensions -= ["container_syscall_intercept_sysinfo"]' "$FIXTURES/server-1.0.json" >"$CASE/server.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "a new version string without an extension: exits 1" rc_is 1
check "a new version string without an extension: names it" err_has 'Incus 6.20 lacks the API extension container_syscall_intercept_sysinfo'
new_case optional-extensions-present absent
jq '.api_extensions += ["instance_limits_oom", "container_disk_tmpfs"]' "$FIXTURES/server-1.0.json" >"$CASE/server.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "both optional extensions present: exits 0" rc_is 0
check "both optional extensions present: nothing is noted as lacking" err_lacks 'lacks the optional API extension'
new_case no-extensions-field absent
jq 'del(.api_extensions)' "$FIXTURES/server-1.0.json" >"$CASE/server.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "no api_extensions in /1.0: exits 1" rc_is 1
check "no api_extensions in /1.0: says so" err_has 'reports no api_extensions'
check "no api_extensions in /1.0: inits nothing" no_init

echo "== --vm needs no server check"
new_case vm-no-extension absent
jq '.api_extensions -= ["disk_volume_subpath"]' "$FIXTURES/server-1.0.json" >"$CASE/server.json"
run_launcher dev --ssh-key "$WORK/laptop.pub" --vm
check "a VM on a server without the container's extensions: exits 0" rc_is 0

# Synthetic: the captured fixtures are VMs, so these set .type the way
# `incus list -f json` reports a container.
echo "== existing container whose install never completed: resumed as a container"
new_case container-resume running-started
jq '.[0].type = "container"' "$FIXTURES/list-running-started.json" >"$CASE/list.json"
export STUB_INSTALL_EXIT=7
run_launcher dev
unset STUB_INSTALL_EXIT
check "exits 1 (the installer failed)" rc_is 1
check "inits nothing" no_init
check "creates no volume" no_volume_calls
check "sets no new lease on an existing instance" no_lease_set
check "runs the installer" called 'bootstrap-archive'
check "calls it a container" err_has 'the container is kept'
check "doesn't warn about creation options" err_lacks 'are ignored'

echo "== --vm on an existing container: the container keeps its type"
new_case vm-on-container running-installed
jq '.[0].type = "container"' "$FIXTURES/list-running-installed.json" >"$CASE/list.json"
run_launcher dev --vm
check "exits 0" rc_is 0
check "warns that --vm is ignored" err_has -- '--vm, --acl and the sizes are ignored: dev exists as a container'
check "inits nothing" no_init
check "runs no installer" not_called 'bootstrap-archive'
check "calls it a container" err_has 'Update inside the container with: acfs update'
check "stdout is the attach block" stdout_is_block ''

echo "== sizes on an existing VM: ignored with a warning"
new_case sizes-on-existing running-installed
run_launcher dev --root-size 100GiB
check "exits 0" rc_is 0
check "warns that the sizes are ignored" err_has 'are ignored: dev exists as a VM'
check "calls it a VM" err_has 'Update inside the VM with: acfs update'

echo "== key refusals (absent instance)"
new_case no-key absent
run_launcher dev
check "no --ssh-key: exits 2" rc_is 2
check "no --ssh-key: says whose key to pass" err_has "public key of the machine you'll attach from"
check "no --ssh-key: inits nothing" no_init
check "no --ssh-key: creates no volume" no_volume_calls
new_case private-key absent
run_launcher dev --ssh-key "$WORK/laptop"
check "private key: exits 2" rc_is 2
check "private key: refused as private" err_has 'is a private key'
check "private key: inits nothing" no_init
new_case non-key absent
run_launcher dev --ssh-key "$WORK/not-a-key.pub"
check "non-key file: exits 2" rc_is 2
check "non-key file: inits nothing" no_init

echo "== network that isn't a managed bridge"
new_case unmanaged absent
# Synthetic variant of the captured network: the same bridge, unmanaged.
jq '.managed = false' "$FIXTURES/network-incusbr0.json" >"$CASE/network.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 1" rc_is 1
check "names the network" err_has "network 'incusbr0' isn't a managed bridge"
check "creates no volume" no_volume_calls
check "inits nothing" no_init

echo "== existing instance the launcher didn't create"
new_case unmarked running-unmarked
run_launcher dev
check "exits 2" rc_is 2
check "says it refuses" err_has "refusing to touch it"
check "names the key that marks an install as done" err_has 'incus config set dev user.acfs.installed=<commit>'
check "makes no call but the lookup" only_the_lookup

# The provider mark is a label: an instance marked by hand carries it without
# the launcher ever having started an install there (devbox, 2026-10-09). It
# is also what a creation that stopped between init and the start leaves.
echo "== running instance with only the provider mark: refused, untouched"
new_case marked-only running-marked
run_launcher dev
check "exits 2" rc_is 2
check "says it refuses" err_has "refusing to touch it"
check "makes no call but the lookup (no push, no exec, no installer)" only_the_lookup

echo "== stopped instance with only the provider mark: refused, not started"
new_case marked-only-stopped stopped-marked
run_launcher dev
check "exits 2" rc_is 2
check "says a half-created instance is deleted and re-run, keeping its volumes" err_has 'delete it and re-run; its volumes are kept and reused'
check "makes no call but the lookup (no start)" only_the_lookup

echo "== installed VM: re-run prints and changes nothing"
new_case installed running-installed
run_launcher dev --jump box
check "exits 0" rc_is 0
check "pushes no files" not_called $'\tfile push'
check "runs no installer" not_called 'bootstrap-archive'
check "sets no config" bash -c '[[ ! -e "$1" ]]' _ "$CASE/config-set"
check "creates no volume" no_volume_calls
check "points at acfs update" err_has 'Update inside the VM with: acfs update'
check "stdout is the attach block" stdout_is_block box

echo "== VM installed by hand and marked user.acfs.installed: prints only"
new_case handmarked running-handmarked
# An install made by hand may be on an image without cloud-init: the block
# needs only the agent, so cloud-init's state mustn't matter.
export STUB_CLOUD_INIT=disabled
run_launcher dev
unset STUB_CLOUD_INIT
check "exits 0" rc_is 0
check "doesn't wait for cloud-init" not_called 'cloud-init'
check "pushes no files" not_called $'\tfile push'
check "runs no installer" not_called 'bootstrap-archive'
check "sets no config" bash -c '[[ ! -e "$1" ]]' _ "$CASE/config-set"
check "stdout is the attach block" stdout_is_block ''

echo "== stopped VM whose install never completed: start and resume"
new_case resume stopped-started
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 0" rc_is 0
check "starts the VM" called $'\tstart dev'
check "re-marks the install as started at HEAD" grep -qx "user.acfs.install-started=$SHA" "$CASE/config-set"
check "warns that --ssh-key is ignored" err_has '--ssh-key is ignored for an existing VM'
check "inits nothing" no_init
check "runs the installer" called 'bootstrap-archive'
check "records the installed sha" grep -qx "user.acfs.installed=$SHA" "$CASE/config-set"

echo "== installer fails"
new_case install-fails running-started
export STUB_INSTALL_EXIT=7
run_launcher dev
unset STUB_INSTALL_EXIT
check "exits 1" rc_is 1
check "records no installed sha" bash -c '! grep -q "^user.acfs.installed=" "$1"' _ "$CASE/config-set"
check "keeps the install marked as started, so a re-run resumes" grep -qx "user.acfs.install-started=$SHA" "$CASE/config-set"
check "says re-run resumes, not the installer's hint" err_has 're-run this command to resume'
check "prints the SSH entry but no machine add line" stdout_is_block '' failed

# Ctrl-C: the wrapper stops the installer's process group, and the client
# exits 130. (If the launcher's own bash dies of the signal instead, nothing
# prints; tests/vm/test_incus_provider.sh checks the instance side.)
echo "== install interrupted with Ctrl-C (the client exits 130)"
new_case install-interrupted running-started
export STUB_INSTALL_EXIT=130
run_launcher dev
unset STUB_INSTALL_EXIT
check "exits 1" rc_is 1
check "names the installer's exit" err_has 'Install failed (exit 130)'
check "records no installed sha" bash -c '! grep -q "^user.acfs.installed=" "$1"' _ "$CASE/config-set"
check "says re-run resumes" err_has 're-run this command to resume'
check "prints the SSH entry but no machine add line" stdout_is_block '' failed

echo "== cloud-init ends in error"
new_case cloud-init-error absent
export STUB_CLOUD_INIT=error STUB_CLOUD_INIT_EXIT=1
run_launcher dev --ssh-key "$WORK/laptop.pub"
unset STUB_CLOUD_INIT STUB_CLOUD_INIT_EXIT
check "exits 1" rc_is 1
check "names cloud-init's status" err_has 'status: error'
check "doesn't install" not_called 'bootstrap-archive'

echo "== cloud-init done with recoverable errors"
new_case cloud-init-degraded absent
export STUB_CLOUD_INIT_EXIT=2
run_launcher dev --ssh-key "$WORK/laptop.pub"
unset STUB_CLOUD_INIT_EXIT
check "exits 0" rc_is 0
check "warns and points at cloud-init status --long" err_has 'cloud-init finished with recoverable errors'
check "installs" called 'bootstrap-archive'

echo "== uncommitted changes are not installed"
new_case dirty running-started
printf '#!/usr/bin/env bash\necho uncommitted\n' >"$REPO/install.sh"
run_launcher dev
git -C "$REPO" checkout -q -- install.sh
check "exits 0" rc_is 0
check "warns about uncommitted changes" err_has 'uncommitted changes'
check "pushes the committed install.sh" grep -qx 'echo committed installer' "$CASE/pushed-install.sh"
check "the archive holds the committed install.sh" \
    bash -c 'tar -xzOf "$1" "agentic_coding_flywheel_setup-$2/install.sh" | grep -qx "echo committed installer"' _ "$CASE/pushed-acfs.tar.gz" "$SHA"

echo "== remote prefix reaches every call"
new_case remote absent
run_launcher far:dev --ssh-key "$WORK/laptop.pub" --jump farhost
check "exits 0" rc_is 0
check "lists on the remote" called $'\tlist far: ^dev\\$ -f json'
check "queries the remote's server" called $'\tquery far:/1.0$'
check "queries the remote's profile" called 'query far:/1.0/profiles/default'
check "queries the remote's network" called 'query far:/1.0/networks/incusbr0'
check "looks for the swarm profile on the remote" called $'\tprofile show far:acfs-swarm$'
check "looks for the ACL on the remote" called $'\tnetwork acl show far:acfs-swarm-egress$'
check "looks for and creates the volumes on the remote's pool" \
    both_called $'\tstorage volume show far:acfs acfs-state-dev$' $'\tstorage volume create far:acfs dev-data size=60GiB$'
check "inits on the remote" grep -qx 'far:dev' "$CASE/init.args"
check "every exec, push, config, device and start names the remote" \
    bash -c '! cut -f2 "$1" | grep -E "^(exec|file|config|start)" | grep -v -E "^(exec far:dev|file push --quiet [^ ]+ far:dev/|config set far:dev |config device add far:dev |start far:dev$)" | grep -q .' _ "$CASE/calls"
check "the block names the instance without the remote" grep -qx 'Host dev' "$CASE/out"

echo "== host-setup is dispatched to incus_host.sh"
new_case host-setup-missing absent
run_launcher host-setup --storage /scratch/incus
check "without incus_host.sh: exits 2" rc_is 2
check "without incus_host.sh: says so" err_has "host-setup isn't in this checkout yet"
check "without incus_host.sh: makes no incus call" no_calls
new_case host-setup absent
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' >"$REPO/scripts/providers/incus_host.sh"
chmod +x "$REPO/scripts/providers/incus_host.sh"
run_launcher host-setup --storage /scratch/incus
rm -f "$REPO/scripts/providers/incus_host.sh"
check "with incus_host.sh: exits 0" rc_is 0
check "with incus_host.sh: passes the rest of the arguments through" bash -c '[[ "$(cat "$1")" == $'"'"'--storage\n/scratch/incus'"'"' ]]' _ "$CASE/out"
check "with incus_host.sh: needs no incus.env itself" no_calls

echo "== tailscale is dispatched to incus_tailscale.sh"
new_case tailscale-missing absent
run_launcher tailscale dev --port 8080
check "without incus_tailscale.sh: exits 2" rc_is 2
check "without incus_tailscale.sh: says so" err_has "tailscale isn't in this checkout yet"
check "without incus_tailscale.sh: makes no incus call" no_calls
new_case tailscale absent
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' >"$REPO/scripts/providers/incus_tailscale.sh"
chmod +x "$REPO/scripts/providers/incus_tailscale.sh"
run_launcher tailscale far:dev --port 8080
rm -f "$REPO/scripts/providers/incus_tailscale.sh"
check "with incus_tailscale.sh: exits 0" rc_is 0
check "with incus_tailscale.sh: passes the rest of the arguments through" bash -c '[[ "$(cat "$1")" == $'"'"'far:dev\n--port\n8080'"'"' ]]' _ "$CASE/out"
check "with incus_tailscale.sh: needs no incus.env itself" no_calls

echo "== usage errors"
new_case usage absent
run_launcher
check "no name: exits 2" rc_is 2
run_launcher 1dev --ssh-key "$WORK/laptop.pub"
check "name starting with a digit: exits 2" rc_is 2
run_launcher dev- --ssh-key "$WORK/laptop.pub"
check "name ending with a dash: exits 2" rc_is 2
run_launcher dev --bogus
check "unknown option: exits 2" rc_is 2
run_launcher dev --container
check "--container (gone: a container is the default): exits 2" rc_is 2
run_launcher dev other
check "two names: exits 2" rc_is 2
run_launcher dev --root-size 100
check "a size without a unit: exits 2" rc_is 2
run_launcher dev --acl
check "--acl without a name: exits 2" rc_is 2
check "usage errors make no incus call" no_calls

echo
echo "incus provider (stub incus): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
