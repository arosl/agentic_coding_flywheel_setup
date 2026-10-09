#!/usr/bin/env bash
# ============================================================
# scripts/providers/incus.sh against a STUB incus
#
# Proves the launcher's decisions and output: which incus calls it makes in
# each state, with which arguments and stdin, and what it prints. The stub
# replays `incus list`/`incus query` JSON captured from real Incus 6.0.5
# (tests/unit/fixtures/incus/README.md). Nothing here touches real Incus or
# a VM; that is tests/vm/test_incus_provider.sh.
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

# Synthetic keys: the attaching machine's public key and the VM's host key.
ssh-keygen -q -t ed25519 -N '' -C laptop -f "$WORK/laptop"
ssh-keygen -q -t ed25519 -N '' -C host -f "$WORK/hostkey"
printf 'not a key\n' >"$WORK/not-a-key.pub"

# ------------------------------------------------------------
# The stub. It logs "<stdin>\t<argv>" per call, where <stdin> is "null"
# when stdin is /dev/null, and answers from the fixtures and $STUB_DIR.
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
            */1.0/profiles/default) cat "$STUB_FIXTURES/profile-default.json" ;;
            */1.0/networks/*) cat "$STUB_DIR/network.json" ;;
        esac
        ;;
    network)
        case "$3" in
            show) [[ -f "$STUB_DIR/acl.yaml" ]] || { echo 'Error: Network ACL not found' >&2; exit 1; } ;;
            create) cat >"$STUB_DIR/acl.yaml" ;;
        esac
        ;;
    launch)
        shift
        printf '%s\n' "$@" >"$STUB_DIR/launch.args"
        cp "$STUB_FIXTURES/list-running-marked.json" "$STUB_DIR/list.json"
        ;;
    start) cp "$STUB_FIXTURES/list-running-marked.json" "$STUB_DIR/list.json" ;;
    file) cp "$3" "$STUB_DIR/pushed-${4##*/}" ;;
    config) printf '%s\n' "$4" >>"$STUB_DIR/config-set" ;;
    exec)
        shift 2
        while [[ "$1" != "--" ]]; do
            [[ "$1" == "--env" ]] && { printf '%s\n' "$2" >>"$STUB_DIR/exec-env"; shift; }
            shift
        done
        shift
        case "$1" in
            cloud-init) printf 'status: %s\n' "${STUB_CLOUD_INIT:-done}" ;;
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

# new_case <name> <list fixture state>: a fresh stub state for one run.
new_case() {
    CASE="$WORK/case-$1"
    mkdir -p "$CASE"
    cp "$FIXTURES/list-$2.json" "$CASE/list.json"
    cp "$FIXTURES/network-incusbr0.json" "$CASE/network.json"
    : >"$CASE/calls"
}

# Runs the launcher with a non-empty pipe on stdin, so any incus call that
# inherited it shows up as stdin=other.
run_launcher() {
    set +e
    echo 'stdin that incus must not read' | \
        PATH="$WORK/bin:$PATH" STUB_DIR="$CASE" STUB_FIXTURES="$FIXTURES" \
        STUB_HOST_KEY="$WORK/hostkey.pub" NO_COLOR=1 \
        "$REPO/scripts/providers/incus.sh" "$@" >"$CASE/out" 2>"$CASE/err"
    RC=$?
    set -e
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
called() { grep -q -- "$1" "$CASE/calls"; }
not_called() { ! grep -q -- "$1" "$CASE/calls"; }
no_launch() { not_called $'\tlaunch '; }
err_has() { grep -q -- "$1" "$CASE/err"; }
launch_has() { grep -qx -- "$1" "$CASE/launch.args"; }
# The only -d values allowed: the root disk size and the NIC's ACL keys.
only_expected_devices() {
    local previous="" arg
    while IFS= read -r arg; do
        if [[ "$previous" == "-d" && "$arg" != "root,size=40GiB" && "$arg" != eth0,security.acls* ]]; then
            return 1
        fi
        previous="$arg"
    done <"$CASE/launch.args"
}
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

echo "== absent VM: create, install, print (with --jump)"
new_case create absent
run_launcher dev --ssh-key "$WORK/laptop.pub" --jump box
check "exits 0" rc_is 0
check "launches the cloud image as a VM" launch_has 'images:ubuntu/26.04/cloud'
check "passes --vm" launch_has '--vm'
check "limits: 4 vCPU" launch_has 'limits.cpu=4'
check "limits: 8 GiB" launch_has 'limits.memory=8GiB'
check "root disk 40 GiB" launch_has 'root,size=40GiB'
check "marks the instance as the launcher's" launch_has 'user.acfs.provider=incus'
check "attaches the egress ACL to the profile's NIC" launch_has 'eth0,security.acls=acfs-vm-egress'
check "unmatched egress passes the ACL" launch_has 'eth0,security.acls.default.egress.action=allow'
check "unmatched ingress passes the ACL" launch_has 'eth0,security.acls.default.ingress.action=allow'
check "no device beyond root and the NIC's ACL keys" only_expected_devices
check "user-data authorizes exactly the given key" \
    bash -c 'grep -A1 -x -- -c "$1" | grep "^cloud-init.user-data=" >/dev/null && [[ "$(grep -c "^  - \"ssh-ed25519 " "$1")" -eq 1 ]] && grep -qF "$(cut -d" " -f2 "$2")" "$1"' _ "$CASE/launch.args" "$WORK/laptop.pub"
check "user-data installs openssh-server" grep -q 'packages: \[openssh-server, curl, git, jq, ca-certificates, unzip\]' "$CASE/launch.args"
check "user-data leaves ssh_pwauth unset (sshd keeps the packaged config)" bash -c '! grep -q ssh_pwauth "$1"' _ "$CASE/launch.args"
check "creates the ACL, rejecting private, CGNAT and link-local egress" \
    grep -q 'destination: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,fc00::/7' "$CASE/acl.yaml"
check "every incus call but the ACL's YAML gets /dev/null on stdin" only_null_stdin_except_acl_create
check "pushes HEAD as a bootstrap archive with GitHub's prefix" \
    bash -c 'tar -tzf "$1" | grep -qx "agentic_coding_flywheel_setup-$2/install.sh"' _ "$CASE/pushed-acfs.tar.gz" "$SHA"
check "pushes HEAD's install.sh" grep -qx 'echo committed installer' "$CASE/pushed-install.sh"
check "runs the installer for ubuntu" grep -qx 'TARGET_USER=ubuntu' "$CASE/exec-env"
check "passes the fork as the repo owner" grep -qx 'ACFS_REPO_OWNER=arosl' "$CASE/exec-env"
check "runs the installer with --bootstrap-archive" called '--bootstrap-archive /root/acfs.tar.gz < /root/install.sh'
check "records the installed sha" grep -qx "user.acfs.installed=$SHA" "$CASE/config-set"
check "stdout is exactly the attach block (installer output stays on stderr)" stdout_is_block box
check "installer output went to stderr" err_has 'INSTALLER OUTPUT'
check "stderr names the keys ubuntu accepts" err_has 'ubuntu accepts: 256 SHA256:stubfingerprint'
check "stderr names the given key's fingerprint before the launch" \
    bash -c 'f="$(ssh-keygen -l -f "$2" | cut -d" " -f2)"; n="$(grep -n "Authorizing for ubuntu: .*$f" "$1" | head -1 | cut -d: -f1)"; c="$(grep -n "Creating VM" "$1" | head -1 | cut -d: -f1)"; [[ -n "$n" && -n "$c" && "$n" -lt "$c" ]]' _ "$CASE/err" "$WORK/laptop.pub"

echo "== absent VM, no --jump"
new_case nojump absent
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 0" rc_is 0
check "stdout is the block without ProxyJump" stdout_is_block ''

echo "== existing ACL is left as it is"
new_case acl-exists absent
printf 'existing\n' >"$CASE/acl.yaml"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 0" rc_is 0
check "does not create the ACL again" not_called 'network acl create'
check "does not change the ACL" grep -qx existing "$CASE/acl.yaml"
check "says it uses the existing ACL unchecked" err_has 'Using the existing network ACL acfs-vm-egress'

echo "== key refusals (absent VM)"
new_case no-key absent
run_launcher dev
check "no --ssh-key: exits 2" rc_is 2
check "no --ssh-key: says whose key to pass" err_has "public key of the machine you'll attach from"
check "no --ssh-key: launches nothing" no_launch
new_case private-key absent
run_launcher dev --ssh-key "$WORK/laptop"
check "private key: exits 2" rc_is 2
check "private key: refused as private" err_has 'is a private key'
check "private key: launches nothing" no_launch
new_case non-key absent
run_launcher dev --ssh-key "$WORK/not-a-key.pub"
check "non-key file: exits 2" rc_is 2
check "non-key file: launches nothing" no_launch

echo "== network that isn't a managed bridge"
new_case unmanaged absent
# Synthetic variant of the captured network: the same bridge, unmanaged.
jq '.managed = false' "$FIXTURES/network-incusbr0.json" >"$CASE/network.json"
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 1" rc_is 1
check "names the network" err_has "network 'incusbr0' isn't a managed bridge"
check "launches nothing" no_launch

echo "== existing instance the launcher didn't create"
new_case unmarked running-unmarked
run_launcher dev
check "exits 2" rc_is 2
check "says it refuses" err_has "wasn't created by this launcher"
check "makes no call but the lookup" bash -c '[[ "$(cut -f2 "$1" | cut -d" " -f1 | sort -u)" == list ]]' _ "$CASE/calls"

echo "== installed VM: re-run prints and changes nothing"
new_case installed running-installed
run_launcher dev --jump box
check "exits 0" rc_is 0
check "pushes no files" not_called $'\tfile push'
check "runs no installer" not_called 'bootstrap-archive'
check "sets no config" bash -c '[[ ! -e "$1" ]]' _ "$CASE/config-set"
check "points at acfs update" err_has 'Update inside the VM with: acfs update'
check "stdout is the attach block" stdout_is_block box

echo "== stopped VM whose install never completed: start and resume"
new_case resume stopped-marked
run_launcher dev --ssh-key "$WORK/laptop.pub"
check "exits 0" rc_is 0
check "starts the VM" called $'\tstart dev'
check "warns that --ssh-key is ignored" err_has '--ssh-key is ignored for an existing VM'
check "launches nothing" no_launch
check "runs the installer" called 'bootstrap-archive'
check "records the installed sha" grep -qx "user.acfs.installed=$SHA" "$CASE/config-set"

echo "== installer fails"
new_case install-fails running-marked
export STUB_INSTALL_EXIT=7
run_launcher dev
unset STUB_INSTALL_EXIT
check "exits 1" rc_is 1
check "records no installed sha" bash -c '[[ ! -e "$1" ]]' _ "$CASE/config-set"
check "says re-run resumes, not the installer's hint" err_has 're-run this command to resume'
check "prints the SSH entry but no machine add line" stdout_is_block '' failed

echo "== cloud-init ends in error"
new_case cloud-init-error absent
export STUB_CLOUD_INIT=error
run_launcher dev --ssh-key "$WORK/laptop.pub"
unset STUB_CLOUD_INIT
check "exits 1" rc_is 1
check "names cloud-init's status" err_has 'status: error'
check "doesn't install" not_called 'bootstrap-archive'

echo "== uncommitted changes are not installed"
new_case dirty running-marked
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
check "queries the remote's profile" called 'query far:/1.0/profiles/default'
check "queries the remote's network" called 'query far:/1.0/networks/incusbr0'
check "creates the ACL on the remote" called 'network acl create far:acfs-vm-egress'
check "launches on the remote" grep -qx 'far:dev' "$CASE/launch.args"
check "every exec, push and config names the remote" \
    bash -c '! cut -f2 "$1" | grep -E "^(exec|file|config|start)" | grep -v -E "^(exec far:dev|file push [^ ]+ far:dev/|config set far:dev )" | grep -q .' _ "$CASE/calls"
check "the block names the instance without the remote" grep -qx 'Host dev' "$CASE/out"

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
run_launcher dev other
check "two names: exits 2" rc_is 2

echo
echo "incus provider (stub incus): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
