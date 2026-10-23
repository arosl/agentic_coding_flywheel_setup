#!/usr/bin/env bash
# ============================================================
# scripts/lib/machine.sh (acfs machine up|verify) against STUBS
#
# A stub incus, a stub launcher and stub tool CLIs (claude, codex, gh, am,
# tailscale, herdr, br, cm, curl, sudo, ssh, ssh-keygen) on PATH, and a
# throwaway HOME with login files. Proves what `up` passes to the launcher,
# the order and the resumability of --replace, and what `verify` reports
# for each tool state, without a real Incus, a real login or a paid
# request. On "macOS" (stub colima, sw_vers and route), it proves how `up`
# starts Colima, sets up its Incus and attaches. The `acfs machine` route
# in doctor.sh is checked too.
#
# Usage: bash tests/unit/test_machine.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACHINE="$ROOT/scripts/lib/machine.sh"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-machine.XXXXXX")"
# KEEP_WORK=1 keeps the cases' out/err files for a look after a failure.
trap '[[ -n "${KEEP_WORK:-}" ]] && echo "kept: $WORK" || rm -rf "$WORK"' EXIT

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
# Stubs. Each logs "<argv>" to $STUB_DIR/calls-<name> and answers from
# files under $STUB_DIR or from STUB_* variables.
# ------------------------------------------------------------
mkdir -p "$WORK/bin"

cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_DIR/calls-incus"
# An instance exists when $STUB_DIR/inst-<name>.json does; remotes are stripped.
case "$1" in
    list)
        # list [remote:] ^name$ -f json
        pat="$2"; [[ "$pat" == ^* ]] || pat="$3"
        name="${pat#^}"; name="${name%\$}"
        if [[ -f "$STUB_DIR/inst-$name.json" ]]; then printf '[%s]\n' "$(cat "$STUB_DIR/inst-$name.json")"; else echo '[]'; fi
        ;;
    query)
        name="${2##*/}"
        cat "$STUB_DIR/devices-$name.json"
        ;;
    stop)
        name="${2#*:}"
        jq '.status = "Stopped"' "$STUB_DIR/inst-$name.json" >"$STUB_DIR/inst-$name.json.new" && mv "$STUB_DIR/inst-$name.json.new" "$STUB_DIR/inst-$name.json"
        ;;
    rename)
        old="${2#*:}"; new="${3#*:}"
        jq --arg n "$new" '.name = $n' "$STUB_DIR/inst-$old.json" >"$STUB_DIR/inst-$new.json"
        rm -f "$STUB_DIR/inst-$old.json"
        [[ ! -f "$STUB_DIR/devices-$old.json" ]] || mv "$STUB_DIR/devices-$old.json" "$STUB_DIR/devices-$new.json"
        [[ ! -f "$STUB_DIR/lease-$old" ]] || mv "$STUB_DIR/lease-$old" "$STUB_DIR/lease-$new"
        ;;
    config)
        case "$2" in
            device)
                # config device remove <inst> <device>
                name="${4#*:}"
                jq --arg d "$5" 'del(.devices[$d])' "$STUB_DIR/devices-$name.json" >"$STUB_DIR/devices-$name.json.new" && mv "$STUB_DIR/devices-$name.json.new" "$STUB_DIR/devices-$name.json"
                ;;
            get)
                name="${3#*:}"
                [[ -f "$STUB_DIR/lease-$name" ]] && cat "$STUB_DIR/lease-$name" || echo
                ;;
            unset)
                # config unset <inst> user.acfs.lease
                name="${3#*:}"
                [[ -z "${STUB_UNSET_EXIT:-}" ]] || exit "$STUB_UNSET_EXIT"
                [[ "$4" != user.acfs.lease ]] || rm -f "$STUB_DIR/lease-$name"
                ;;
        esac
        ;;
    storage)
        # storage volume snapshot show|create <pool> <volume> <snapshot>
        snap="$STUB_DIR/snap-${5#*:}-$6-$7"
        case "$4" in
            show) [[ -f "$snap" ]] ;;
            create)
                [[ -z "${STUB_SNAPSHOT_EXIT:-}" ]] || exit "$STUB_SNAPSHOT_EXIT"
                touch "$snap"
                ;;
        esac
        ;;
    export)
        # export <inst> <file> --instance-only
        [[ -z "${STUB_EXPORT_EXIT:-}" ]] || exit "$STUB_EXPORT_EXIT"
        echo "root of ${2#*:}" >"$3"
        ;;
    exec)
        # exec <inst> [--env X] -- <command...>
        shift
        while [[ "$1" != "--" ]]; do shift; done
        shift
        case "$1" in
            # runuser -u ubuntu -- bash -s -- verify ...: the script arrives on
            # stdin; its first line is kept as proof.
            runuser)
                head -n 1 >"$STUB_DIR/streamed-script"
                cat "$STUB_DIR/guest-report.json"
                exit "${STUB_GUEST_EXIT:-0}"
                ;;
        esac
        ;;
    remote)
        case "$2" in
            get-default) cat "$STUB_DIR/remote-default" 2>/dev/null || echo local ;;
            switch) printf '%s\n' "$3" >"$STUB_DIR/remote-default" ;;
        esac
        ;;
    info) exit "${STUB_INCUS_INFO_EXIT:-0}" ;;
esac
STUB

# colima: `list` answers from $STUB_DIR/colima-list.json (absent: no such
# profile); `start` leaves the profile running. `ssh` runs its command as
# if in Colima's VM: a bare environment with $STUB_DIR/vm-bin as PATH and
# $STUB_DIR/vm-home as HOME.
cat >"$WORK/bin/colima" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# One line per call: a script's newlines are logged as \n.
call="$*"
printf '%s\n' "${call//$'\n'/\\n}" >>"$STUB_DIR/calls-colima"
case "$1" in
    version)
        printf 'colima version %s\ngit commit: 0000000\n' "${STUB_COLIMA_VERSION:-0.10.3}"
        ;;
    list)
        [[ ! -f "$STUB_DIR/colima-list.json" ]] || cat "$STUB_DIR/colima-list.json"
        ;;
    start)
        [[ -z "${STUB_COLIMA_START_EXIT:-}" ]] || exit "$STUB_COLIMA_START_EXIT"
        printf '{"name":"acfs","status":"Running","arch":"aarch64","runtime":"incus","address":"192.168.64.2"}\n' >"$STUB_DIR/colima-list.json"
        # A Colima that ignored --activate=false would switch the remote.
        [[ -z "${STUB_COLIMA_SWITCHES:-}" ]] || echo colima-acfs >"$STUB_DIR/remote-default"
        ;;
    ssh)
        while [[ "$1" != -- ]]; do shift; done
        shift
        mkdir -p "$STUB_DIR/vm-home" "$STUB_DIR/vm-tmp"
        exec env -i HOME="$STUB_DIR/vm-home" PATH="$STUB_DIR/vm-bin" TMPDIR="$STUB_DIR/vm-tmp" \
            STUB_DIR="$STUB_DIR" STUB_HOST_SETUP_EXIT="${STUB_HOST_SETUP_EXIT:-}" "$@"
        ;;
esac
STUB
cat >"$WORK/bin/sw_vers" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_MACOS:-15.1}"
STUB
# route -n get <address>: the route goes through STUB_ROUTE_VIA, by default
# the Colima VM's address in the colima stub.
cat >"$WORK/bin/route" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-route"
printf '   route to: %s\n    gateway: %s\n  interface: bridge100\n' "$3" "${STUB_ROUTE_VIA:-192.168.64.2}"
STUB

# The launcher: records its arguments; on success it "creates" the
# instance as installed and running, with a lease.
cat >"$WORK/bin/launcher" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_DIR/calls-launcher"
printf '%s\n' "$@" >"$STUB_DIR/launcher.args"
[[ -z "${STUB_LAUNCH_EXIT:-}" ]] || exit "$STUB_LAUNCH_EXIT"
name="${1#*:}"
printf '{"name":"%s","status":"Running","type":"container","config":{"user.acfs.installed":"abc","user.acfs.lease":"ffffffffffffffffffffffffffffffff"}}\n' "$name" >"$STUB_DIR/inst-$name.json"
printf 'ffffffffffffffffffffffffffffffff\n' >"$STUB_DIR/lease-$name"
echo "launcher stdout: the attach block"
STUB

# Tool CLIs: exit STUB_<TOOL>_EXIT (default 0) after printing STUB_<TOOL>_OUT.
for tool in claude codex agy gemini pi gh am cm br; do
    upper="$(tr '[:lower:]' '[:upper:]' <<<"$tool")"
    cat >"$WORK/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$STUB_DIR/calls-$tool"
[[ -z "\${STUB_${upper}_SLEEP:-}" ]] || sleep "\$STUB_${upper}_SLEEP"
printf '%s\n' "\${STUB_${upper}_OUT:-ok}"
exit "\${STUB_${upper}_EXIT:-0}"
STUB
done
cat >"$WORK/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-tailscale"
[[ -z "${STUB_TAILSCALE_DOWN:-}" ]] || exit 1
printf '{"Self":{"HostName":"%s"}}\n' "${STUB_TAILSCALE_HOST:-devbox}"
STUB
cat >"$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-herdr"
[[ -z "${STUB_HERDR_DOWN:-}" ]] || exit 1
echo '{"result":{"workspaces":[{"id":"w1"},{"id":"w2"}]}}'
STUB
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-curl"
[[ -z "${STUB_CURL_EXIT:-}" ]] || exit "$STUB_CURL_EXIT"
echo '{"status":"ok"}'
STUB
cat >"$WORK/bin/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-ssh-keygen"
printf '256 %s host (ED25519)\n' "${STUB_HOST_FP:-SHA256:hostfingerprint}"
STUB
cat >"$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-ssh"
exit "${STUB_SSH_EXIT:-0}"
STUB
# sudo -n <command>: `true` passes unless STUB_NO_SUDO; `find` runs as is
# (the search root is $STUB_ROOTFS); `acfs state lease status` prints a
# fixture.
cat >"$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-sudo"
[[ "$1" == -n ]] && shift
[[ -z "${STUB_NO_SUDO:-}" ]] || exit 1
case "$1" in
    true) exit 0 ;;
    find) exec "$@" ;;
    acfs) printf 'volume lease:   set\ninstance lease: set\nmatch: %s\n' "${STUB_LEASE_MATCH:-yes}" ;;
esac
STUB
# findmnt -rn -o TARGET: the root and $STUB_DIR/mounts, never this host's.
cat >"$WORK/bin/findmnt" <<'STUB'
#!/usr/bin/env bash
echo /
[[ ! -f "$STUB_DIR/mounts" ]] || cat "$STUB_DIR/mounts"
STUB
chmod +x "$WORK"/bin/*

# A checkout for the Colima cases: up takes host-setup from its HEAD. Its
# host-setup records its arguments and, like the real one, writes incus.env
# last.
REPO="$WORK/repo"
mkdir -p "$REPO/scripts/lib" "$REPO/scripts/providers"
echo '# logging.sh' >"$REPO/scripts/lib/logging.sh"
cat >"$REPO/scripts/providers/incus_host.sh" <<'STUB'
printf '%s\n' "$*" >>"$STUB_DIR/calls-host-setup"
[[ -z "$STUB_HOST_SETUP_EXIT" ]] || exit "$STUB_HOST_SETUP_EXIT"
[[ -f "$(dirname "$0")/../lib/logging.sh" ]] || exit 9
mkdir -p "$HOME/.config/acfs"
printf '# Written by scripts/providers/incus.sh host-setup; read by incus.sh.\nACFS_INCUS_POOL=default\n' >"$HOME/.config/acfs/incus.env"
STUB
cp "$WORK/bin/launcher" "$REPO/scripts/providers/incus.sh"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid -c core.hooksPath=/dev/null commit -q -m fixture

CASE=""
RC=0

# new_case <name>: a fresh stub state, HOME and state dir.
new_case() {
    CASE="$WORK/case-$1"
    mkdir -p "$CASE/home/.ssh" "$CASE/state" "$CASE/rootfs"
    : >"$CASE/calls-incus"
}

# A login file with a mode, under the case's HOME.
login_file() {
    mkdir -p "$(dirname "$CASE/home/$1")"
    printf 'SECRET-%s\n' "$1" >"$CASE/home/$1"
    chmod "${2:-0600}" "$CASE/home/$1"
}

# run_machine [--no-tools] <args...>: runs machine.sh with the stubs first on
# PATH (or, with --no-tools, with only incus and the launcher), HOME in
# the case, and the launcher pointed at the stub.
run_machine() {
    # PATH_PREFIX puts a case's own wrappers ahead of the stubs.
    local path="${PATH_PREFIX:+$PATH_PREFIX:}$WORK/bin:$PATH"
    if [[ "${1:-}" == --no-tools ]]; then
        # Only what machine.sh itself needs, so a real gh, ssh or tailscale
        # on this host isn't found either.
        shift
        mkdir -p "$CASE/bin-min"
        ln -sf "$WORK/bin/incus" "$CASE/bin-min/incus"
        ln -sf "$WORK/bin/ssh-keygen" "$CASE/bin-min/ssh-keygen"
        local b
        for b in bash sh jq timeout stat sed awk grep cat tr wc mkdir chmod rm mktemp head tail cut sort uname readlink dirname date ls env; do
            command -v "$b" >/dev/null 2>&1 && ln -sf "$(command -v "$b")" "$CASE/bin-min/$b"
        done
        path="$CASE/bin-min"
    elif [[ -n "${NO_TIMEOUT:-}" ]]; then
        # Every stub and what machine.sh uses, but no timeout(1), as on macOS.
        mkdir -p "$CASE/bin-nt"
        ln -sf "$WORK"/bin/* "$CASE/bin-nt/"
        local t
        for t in bash sh jq stat sed awk grep cat tr wc mkdir chmod rm mktemp head tail cut sort uname readlink dirname date ls env git; do
            command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$CASE/bin-nt/$t"
        done
        path="$CASE/bin-nt"
    fi
    set +e
    PATH="$path" STUB_DIR="$CASE" STUB_ROOTFS="$CASE/rootfs" HOME="$CASE/home" \
        XDG_STATE_HOME="$CASE/home/.local/state" XDG_CONFIG_HOME="$CASE/home/.config" \
        ACFS_MACHINE_STATE_DIR="$CASE/state" \
        ACFS_MACHINE_UNAME="${UNAME:-Linux}" ACFS_MACHINE_ARCH="${ARCH:-arm64}" \
        ACFS_MACHINE_LAUNCHER="${LAUNCHER_OVERRIDE:-$WORK/bin/launcher}" \
        ACFS_VERIFY_HOST_KEYS="$CASE/host_key.pub" ACFS_MACHINE_GUEST_SOCK="$CASE/guest.sock" \
        ACFS_VERIFY_PROJECT="$CASE/project" ACFS_VERIFY_SEARCH_ROOT="$CASE/rootfs" \
        bash "$MACHINE" "$@" >"$CASE/out" 2>"$CASE/err"
    RC=$?
    set -e
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
err_has() { grep -q -- "$1" "$CASE/err"; }
err_lacks() { ! grep -q -- "$1" "$CASE/err"; }
out_has() { grep -q -- "$1" "$CASE/out"; }
incus_called() { grep -q -- "$1" "$CASE/calls-incus"; }
incus_not_called() { ! grep -q -- "$1" "$CASE/calls-incus"; }
only_lists() { [[ "$(cut -d' ' -f1 "$CASE/calls-incus" | sort -u)" == list ]]; }
launcher_args_are() { [[ "$(tr '\n' ' ' <"$CASE/launcher.args")" == "$1 " ]]; }
no_launch() { [[ ! -e "$CASE/calls-launcher" ]]; }
# The report line for a check: "<check> <status> <detail>" on stderr.
status_of() { awk -v c="$1" '$1 == c {print $2; exit}' "$CASE/err"; }
status_is() { [[ "$(status_of "$1")" == "$2" ]]; }
both_ok() { status_is "$1" ok && status_is "$2" ok; }
detail_has() { grep -E -- "^$1 +[a-z-]+ +.*$2" "$CASE/err" >/dev/null; }
tool_called() { [[ -s "$CASE/calls-$1" ]]; }
tool_not_called() { [[ ! -s "$CASE/calls-$1" ]]; }
call_line() { grep -n -- "$1" "$CASE/calls-incus" | head -n 1 | cut -d: -f1; }
called_before() { [[ -n "$(call_line "$1")" && -n "$(call_line "$2")" && "$(call_line "$1")" -lt "$(call_line "$2")" ]]; }
replace_order() {
    called_before '^stop dev$' '^storage volume snapshot create' \
        && called_before '^storage volume snapshot create' '^export dev ' \
        && called_before '^export dev ' '^config device remove' \
        && called_before '^config device remove' '^rename dev dev-old$'
}
# The lease leaves dev-old after the launch and before the verify.
lease_moved_in_order() {
    local unset_line exec_line
    unset_line="$(call_line '^config unset dev-old user.acfs.lease$')"
    exec_line="$(call_line '^exec dev ')"
    [[ -n "$unset_line" && -n "$exec_line" && "$unset_line" -lt "$exec_line" && -s "$CASE/calls-launcher" ]]
}
# The launcher stub runs after incus rename when the rename is logged and the launcher was called at all.
launched_after_rename() { [[ -n "$(call_line '^rename dev dev-old$')" && -s "$CASE/calls-launcher" ]]; }
# No credential text may appear in either stream.
no_secret_printed() { ! grep -q 'SECRET-' "$CASE/out" "$CASE/err"; }

instance_json() { # <name> <status> <type> <installed: 1|"">
    local installed='"user.acfs.installed":"abc",'
    [[ -n "$4" ]] || installed=""
    printf '{"name":"%s","status":"%s","type":"%s","config":{%s"user.acfs.provider":"incus"}}' "$1" "$2" "$3" "$installed"
}

# An installed, running container with the launcher's devices and a lease.
installed_machine() {
    instance_json dev Running container 1 >"$CASE/inst-dev.json"
    echo '{"devices":{"root":{"type":"disk"},"eth0":{"type":"nic"},"state-home":{"type":"disk","pool":"acfs","source":"acfs-state-dev/home"},"state-ssh-host":{"type":"disk"},"state-tailscale":{"type":"disk"},"state-acfs":{"type":"disk"},"data":{"type":"disk","pool":"acfs","source":"dev-data"}}}' >"$CASE/devices-dev.json"
    printf '0123456789abcdef0123456789abcdef\n' >"$CASE/lease-dev"
    echo '[{"check":"claude","status":"ok","detail":"login stored, mode 0600; claude -p answered"},{"check":"lease","status":"ok","detail":"this instance holds its state volume"}]' >"$CASE/guest-report.json"
}

echo "== up: the launcher gets the name and every option machine.sh doesn't own"
new_case up
run_machine up dev --ssh-key "$WORK/k.pub" --jump box --root-size 100GiB
check "exits 0" rc_is 0
check "the launcher runs with the name first and the options as given" launcher_args_are "dev --ssh-key $WORK/k.pub --jump box --root-size 100GiB"
check "the launcher's stdout is the command's stdout" out_has 'launcher stdout: the attach block'
check "no incus call of its own" bash -c '[[ ! -s "$1" ]]' _ "$CASE/calls-incus"
new_case up-remote
run_machine up far:dev --ssh-key k --vm
check "a remote-qualified name reaches the launcher as given" launcher_args_are "far:dev --ssh-key k --vm"
new_case up-dashdash
run_machine up dev -- --ssh-key k
check "arguments after -- go to the launcher" launcher_args_are "dev --ssh-key k"

echo "== up: refusals"
new_case up-vps
run_machine up --target vps dev
check "--target vps: exits 2" rc_is 2
check "--target vps: points at the one-liner and the provider guides" err_has 'scripts/providers/hetzner.md'
check "--target vps: points at verify afterwards" err_has 'acfs machine verify'
check "--target vps: launches nothing" no_launch
new_case up-target-bogus
run_machine up --target bogus dev
check "--target bogus: exits 2" rc_is 2
new_case up-noname
run_machine up --vm
check "no name: exits 2" rc_is 2
check "no name: says so" err_has 'up needs the machine'
new_case up-badname
run_machine up 1dev
check "a name starting with a digit: exits 2" rc_is 2
new_case up-no-launcher
LAUNCHER_OVERRIDE="$CASE/nowhere/incus.sh" run_machine up dev --ssh-key k
check "no launcher beside the script: exits 2" rc_is 2
check "no launcher beside the script: says to run from a checkout" err_has 'runs from a checkout of the repository'
new_case usage
run_machine
check "no subcommand: exits 2" rc_is 2
run_machine --help
check "--help: exits 0" rc_is 0
check "--help: prints the usage" out_has 'acfs machine up'
run_machine bogus
check "unknown subcommand: exits 2" rc_is 2

# colima_case <name>: a fresh case on "macOS", where Colima's Incus answers
# with its default profile on the bridge incusbr0 (192.168.100.1/24). The
# VM's PATH has what the setup script uses, jq unless VM_NO_JQ, and a sudo
# that only records.
colima_case() {
    new_case "$1"
    mkdir -p "$CASE/vm-bin"
    local b
    for b in sh bash tar mktemp rm rmdir cat mkdir dirname; do
        ln -sf "$(command -v "$b")" "$CASE/vm-bin/$b"
    done
    [[ -n "${VM_NO_JQ:-}" ]] || ln -sf "$(command -v jq)" "$CASE/vm-bin/jq"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$STUB_DIR/calls-vm-sudo"\n' >"$CASE/vm-bin/sudo"
    chmod +x "$CASE/vm-bin/sudo"
    # The incus stub's query answers from devices-<last path element>.json.
    echo '{"devices":{"eth0":{"type":"nic","network":"incusbr0"},"root":{"type":"disk"}}}' >"$CASE/devices-default.json"
    echo '{"config":{"ipv4.address":"192.168.100.1/24"}}' >"$CASE/devices-incusbr0.json"
}
# A setup that finished in the VM earlier, and its pool on the Mac.
colima_set_up() {
    mkdir -p "$CASE/vm-home/.config/acfs" "$CASE/home/.config/acfs"
    printf 'ACFS_INCUS_POOL=default\n' >"$CASE/vm-home/.config/acfs/incus.env"
    printf 'ACFS_INCUS_POOL=default\n' >"$CASE/home/.config/acfs/incus.env"
}
run_colima() { UNAME=Darwin LAUNCHER_OVERRIDE="$REPO/scripts/providers/incus.sh" run_machine "$@"; }
colima_called() { grep -q -- "$1" "$CASE/calls-colima"; }
colima_not_called() { ! grep -q -- "$1" "$CASE/calls-colima" 2>/dev/null; }
colima_start_is() { [[ "$(grep '^start ' "$CASE/calls-colima")" == "start $1" ]]; }
every_colima_call_names_the_profile() { ! grep -v -- '--profile acfs' "$CASE/calls-colima"; }
mac_env_has() { grep -qx -- "$1" "$CASE/home/.config/acfs/incus.env"; }
vm_tmp_empty() { [[ -z "$(ls -A "$CASE/vm-tmp")" ]]; }

echo "== up on macOS: a new Colima profile, set up once, then the launcher on colima-acfs"
colima_case colima-new
run_colima up dev --ssh-key k
check "exits 0" rc_is 0
check "creates the profile acfs with Incus, VZ, virtiofs, the arch, the sizes, the route and no share" \
    colima_start_is "--profile acfs --activate=false --runtime incus --vm-type vz --mount-type virtiofs --arch aarch64 --memory 8 --disk 160 --cpus 4 --network-address --mount none"
check "every colima call names the profile acfs, never the default one" every_colima_call_names_the_profile
check "waits for Colima's Incus" incus_called '^info colima-acfs:$'
check "keeps the current Incus remote: nothing switches it" incus_not_called '^remote switch'
check "runs host-setup in the VM on Colima's pool" bash -c '[[ "$(cat "$1")" == "--storage default" ]]' _ "$CASE/calls-host-setup"
check "the VM has jq, so nothing is installed there" bash -c '[[ ! -e "$1" ]]' _ "$CASE/calls-vm-sudo"
check "the setup leaves no temp files in the VM" vm_tmp_empty
check "records Colima's pool on the Mac" mac_env_has 'ACFS_INCUS_POOL=default'
check "the Mac's incus.env says where it came from" bash -c 'head -n 1 "$1" | grep -q "Copied from Colima"' _ "$CASE/home/.config/acfs/incus.env"
check "the Mac's incus.env is mode 0644" bash -c '[[ "$(stat -c %a "$1")" == 644 ]]' _ "$CASE/home/.config/acfs/incus.env"
check "checks the route to the bridge's gateway" bash -c 'grep -qx -- "-n get 192.168.100.1" "$1"' _ "$CASE/calls-route"
check "the route goes through the VM, so the launcher gets no jump" launcher_args_are "colima-acfs:dev --ssh-key k"
check "says the SSH entry goes into this Mac's ~/.ssh/config" err_has "into this Mac's ~/.ssh/config"

echo "== up on macOS: a re-run finds the profile running and set up"
colima_case colima-running
colima_set_up
echo '{"name":"acfs","status":"Running","runtime":"incus","address":"192.168.64.2"}' >"$CASE/colima-list.json"
run_colima up dev --colima-cpus 8
check "exits 0" rc_is 0
check "starts nothing" colima_not_called '^start'
check "runs no host-setup" bash -c '[[ ! -e "$1" ]]' _ "$CASE/calls-host-setup"
check "says the sizes are ignored for an existing profile" err_has 'ignored: the profile acfs exists'
check "the launcher gets the remote-qualified name" launcher_args_are "colima-acfs:dev"

echo "== up on macOS: a stopped profile is started as it is"
colima_case colima-stopped
colima_set_up
echo '{"name":"acfs","status":"Stopped","runtime":"incus"}' >"$CASE/colima-list.json"
run_colima up dev
check "exits 0" rc_is 0
check "starts it with no creation flags" colima_start_is "--profile acfs --activate=false"

echo "== up on macOS: Colima before 0.10.0 has no route and no --mount none"
colima_case colima-old
export STUB_COLIMA_VERSION=0.8.4
run_colima up dev --ssh-key k --colima-memory 12
unset STUB_COLIMA_VERSION
check "exits 0" rc_is 0
check "creates the profile with --cpu, the given memory and an empty share" \
    colima_start_is "--profile acfs --activate=false --runtime incus --vm-type vz --mount-type virtiofs --arch aarch64 --memory 12 --disk 160 --cpu 4 --mount $CASE/state/colima-empty"
check "the shared directory is empty and owner only" bash -c '[[ -z "$(ls -A "$1")" && "$(stat -c %a "$1")" == 700 ]]' _ "$CASE/state/colima-empty"
check "checks no route" bash -c '[[ ! -e "$1" ]]' _ "$CASE/calls-route"
check "the SSH entry jumps through Colima's VM" launcher_args_are "colima-acfs:dev --ssh-key k --jump colima-acfs"

echo "== up on macOS: a route that misses the VM means a jump; a --jump given is kept"
colima_case colima-no-route
export STUB_ROUTE_VIA=10.0.0.1
run_colima up dev
check "exits 0" rc_is 0
check "jumps through Colima's VM" launcher_args_are "colima-acfs:dev --jump colima-acfs"
check "says why" err_has "doesn't go through its VM"
colima_case colima-own-jump
run_colima up dev --jump box
unset STUB_ROUTE_VIA
check "a --jump of the user's own is the only one" launcher_args_are "colima-acfs:dev --jump box"

echo "== up on macOS: an Intel Mac, a VM without jq, and a Colima that switches the remote anyway"
VM_NO_JQ=1 colima_case colima-intel
echo myremote >"$CASE/remote-default"
export STUB_COLIMA_SWITCHES=1
ARCH=x86_64 run_colima up dev
unset STUB_COLIMA_SWITCHES
check "exits 0" rc_is 0
check "an Intel Mac gets --arch x86_64" colima_called '--arch x86_64 '
check "installs jq in the VM before host-setup" bash -c 'grep -q "apt-get install -y -qq jq" "$1"' _ "$CASE/calls-vm-sudo"
check "switches the default remote back to the user's" incus_called '^remote switch myremote$'
check "the default remote is the user's again" bash -c '[[ "$(cat "$1")" == myremote ]]' _ "$CASE/remote-default"

echo "== up on macOS: refusals"
colima_case colima-too-old
export STUB_COLIMA_VERSION=0.6.9
run_colima up dev
unset STUB_COLIMA_VERSION
check "Colima 0.6.9: exits 2" rc_is 2
check "Colima 0.6.9: says 0.7.0 is needed" err_has 'needs 0.7.0 or newer'
check "Colima 0.6.9: starts nothing" colima_not_called '^start'
colima_case colima-macos-12
export STUB_MACOS=12.7.4
run_colima up dev
unset STUB_MACOS
check "macOS 12: exits 2, naming VZ" bash -c '[[ "$1" -eq 2 ]] && grep -q "VZ virtual machine needs macOS 13" "$2"' _ "$RC" "$CASE/err"
colima_case colima-docker
echo '{"name":"acfs","status":"Running","runtime":"docker"}' >"$CASE/colima-list.json"
run_colima up dev
check "a profile acfs with the docker runtime: exits 2" rc_is 2
check "a profile acfs with the docker runtime: is left alone" colima_not_called '^start'
check "a profile acfs with the docker runtime: launches nothing" no_launch
colima_case colima-broken
echo '{"name":"acfs","status":"Broken","runtime":"incus"}' >"$CASE/colima-list.json"
run_colima up dev
check "a broken profile: exits 1, naming its status" bash -c '[[ "$1" -eq 1 ]] && grep -q "profile acfs is Broken" "$2"' _ "$RC" "$CASE/err"
colima_case colima-vm
run_colima up dev --vm
check "--vm: exits 2" rc_is 2
check "--vm: starts no Colima" bash -c '[[ ! -e "$1" ]]' _ "$CASE/calls-colima"
colima_case colima-start-fails
export STUB_COLIMA_START_EXIT=1
run_colima up dev
unset STUB_COLIMA_START_EXIT
check "a failed colima start: exits 1 and launches nothing" bash -c '[[ "$1" -eq 1 ]] && [[ ! -e "$2" ]]' _ "$RC" "$CASE/calls-launcher"
colima_case colima-no-answer
export STUB_INCUS_INFO_EXIT=1 ACFS_COLIMA_TIMEOUT=0
run_colima up dev
unset STUB_INCUS_INFO_EXIT ACFS_COLIMA_TIMEOUT
check "Incus doesn't answer: exits 1, naming incus info" bash -c '[[ "$1" -eq 1 ]] && grep -q "didn.t answer .incus info colima-acfs:." "$2"' _ "$RC" "$CASE/err"
colima_case colima-setup-fails
export STUB_HOST_SETUP_EXIT=1
run_colima up dev
unset STUB_HOST_SETUP_EXIT
check "a failed host-setup: exits 1 and launches nothing" bash -c '[[ "$1" -eq 1 ]] && [[ ! -e "$2" ]]' _ "$RC" "$CASE/calls-launcher"
check "a failed host-setup: the message doesn't end in the exit code" err_lacks 're-run) 1$'
check "a failed host-setup: writes no incus.env on the Mac" bash -c '[[ ! -e "$1" ]]' _ "$CASE/home/.config/acfs/incus.env"
check "a failed host-setup: leaves no temp files in the VM" vm_tmp_empty
colima_case colima-env-conflict
mkdir -p "$CASE/home/.config/acfs"
printf 'ACFS_INCUS_POOL=acfs\n' >"$CASE/home/.config/acfs/incus.env"
run_colima up dev
check "another pool in the Mac's incus.env: exits 2" rc_is 2
check "another pool in the Mac's incus.env: names both" err_has "records the pool 'acfs', but Colima's Incus uses 'default'"
check "another pool in the Mac's incus.env: is kept as it is" mac_env_has 'ACFS_INCUS_POOL=acfs'
check "another pool in the Mac's incus.env: launches nothing" no_launch

echo "== up --replace on macOS: the rebuild runs on colima-acfs"
colima_case colima-replace
colima_set_up
echo '{"name":"acfs","status":"Running","runtime":"incus","address":"192.168.64.2"}' >"$CASE/colima-list.json"
installed_machine
run_colima up --replace dev --ssh-key k
check "exits 0" rc_is 0
check "stops the instance on colima-acfs" incus_called '^stop colima-acfs:dev$'
check "renames it there" incus_called '^rename colima-acfs:dev colima-acfs:dev-old$'
check "launches colima-acfs:dev with the lease" launcher_args_are "colima-acfs:dev --lease-from dev-old --ssh-key k"

echo "== up on macOS with another remote, and the Colima sizes off macOS"
colima_case colima-other-remote
run_colima up far:dev --ssh-key k
check "a named remote: exits 0 without Colima" bash -c '[[ "$1" -eq 0 && ! -e "$2" ]]' _ "$RC" "$CASE/calls-colima"
check "a named remote: reaches the launcher as given" launcher_args_are "far:dev --ssh-key k"
new_case colima-linux-sizes
run_machine up dev --colima-disk 200
check "on Linux: --colima-disk is ignored, with a note" bash -c '[[ "$1" -eq 0 ]] && grep -q "ignored: only on macOS" "$2"' _ "$RC" "$CASE/err"
check "on Linux: the launcher doesn't get it" launcher_args_are "dev"
new_case colima-bad-size
run_machine up dev --colima-memory 8GiB
check "--colima-memory 8GiB: exits 2 (whole GiB only)" rc_is 2

echo "== up --replace: stop, snapshot, export, detach the launcher's devices, rename, launch with the lease, move the lease, verify"
new_case replace
installed_machine
run_machine up --replace dev --ssh-key k
check "exits 0" rc_is 0
check "stops the old instance" incus_called '^stop dev$'
check "snapshots the state volume on the device's pool" incus_called '^storage volume snapshot create acfs acfs-state-dev acfs-replace-[0-9]\{8\}-[0-9]\{6\}$'
check "snapshots the data volume" incus_called '^storage volume snapshot create acfs dev-data acfs-replace-[0-9]\{8\}-[0-9]\{6\}$'
check "both snapshots carry the same stamp" bash -c '[[ "$(grep "^storage volume snapshot create" "$1" | awk "{print \$NF}" | sort -u | wc -l)" -eq 1 ]]' _ "$CASE/calls-incus"
check "exports the old root alone, through a .part file" incus_called "^export dev $CASE/state/exports/dev-[0-9]\{8\}-[0-9]\{6\}\.tar\.gz\.part --instance-only$"
check "the export is published, owner only, in an owner-only directory" \
    bash -c 'f="$(ls "$1"/exports/dev-*.tar.gz)" && [[ "$(stat -c %a "$f")" == 600 && "$(stat -c %a "$1/exports")" == 700 ]] && ! ls "$1"/exports/*.part >/dev/null 2>&1' _ "$CASE/state"
check "stop, snapshot, export, detach and rename run in that order" replace_order
check "takes the lease from dev-old after the launch, before the verify" lease_moved_in_order
check "dev-old holds no lease afterwards" bash -c '[[ ! -e "$1/lease-dev-old" ]]' _ "$CASE"
check "the done note names the snapshots and the export it keeps" \
    bash -c 'grep -q "the volume snapshots acfs-replace-[0-9]\{8\}-[0-9]\{6\}; the root.s export $1/exports/dev-" "$2"' _ "$CASE/state" "$CASE/err"
check "removes the state-home device" incus_called '^config device remove dev state-home$'
check "removes the data device" incus_called '^config device remove dev data$'
check "removes the other state devices" bash -c 'grep -c "^config device remove dev state-" "$1" | grep -qx 4' _ "$CASE/calls-incus"
check "leaves root and the NIC alone" incus_not_called 'device remove dev root\|device remove dev eth0'
check "renames the old instance to dev-old" incus_called '^rename dev dev-old$'
check "stops before detaching, detaches before renaming" replace_order
check "launches dev with the lease copied from dev-old and the user's options" launcher_args_are "dev --lease-from dev-old --ssh-key k"
check "launches after the rename" launched_after_rename
check "verifies the new instance inside" incus_called '^exec dev --env HOME=/home/ubuntu -- runuser -u ubuntu -- bash -s -- verify --json --timeout 90$'
check "reports the guest checks" both_ok claude lease
check "reports the new instance's lease key" status_is instance-lease ok
check "keeps the old instance as the rollback and says so" err_has 'Kept as the rollback: dev-old, stopped and without the lease'
check "removes the journal when done" bash -c '[[ ! -e "$1/dev.replace" ]]' _ "$CASE/state"
check "the old instance still exists, stopped" bash -c 'jq -e ".status == \"Stopped\"" "$1/inst-dev-old.json" >/dev/null' _ "$CASE"
check "prints no secret" no_secret_printed

echo "== up --replace: a failed launch leaves a journal, and a re-run continues after the rename"
new_case replace-resume
installed_machine
export STUB_LAUNCH_EXIT=3
run_machine up --replace dev --ssh-key k
unset STUB_LAUNCH_EXIT
check "exits 1" rc_is 1
check "says to re-run to continue" err_has "re-run 'acfs machine up --replace dev' to continue"
check "the journal records stop, detach and rename" bash -c 'grep -qx stopped=1 "$1" && grep -qx detached=1 "$1" && grep -qx renamed=1 "$1" && ! grep -q launched "$1"' _ "$CASE/state/dev.replace"
: >"$CASE/calls-incus"
rm -f "$CASE/calls-launcher"
run_machine up --replace dev --ssh-key k
check "the re-run exits 0" rc_is 0
check "the re-run stops nothing and renames nothing" incus_not_called '^stop \|^rename '
check "the re-run launches again with the lease" launcher_args_are "dev --lease-from dev-old --ssh-key k"
check "the re-run removes the journal" bash -c '[[ ! -e "$1/dev.replace" ]]' _ "$CASE/state"

echo "== up --replace: a failed export resumes with the same stamp, and no second snapshot"
new_case replace-export-fails
installed_machine
export STUB_EXPORT_EXIT=1
run_machine up --replace dev --ssh-key k
unset STUB_EXPORT_EXIT
check "exits 1, saying to re-run" bash -c '[[ "$1" -eq 1 ]] && grep -q "incus export failed; re-run" "$2"' _ "$RC" "$CASE/err"
check "the journal has the stamp, stopped and snapshotted, not exported" \
    bash -c 'grep -qx "stamp=[0-9]\{8\}-[0-9]\{6\}" "$1" && grep -qx stopped=1 "$1" && grep -qx snapshotted=1 "$1" && ! grep -q exported "$1"' _ "$CASE/state/dev.replace"
check "nothing was detached or renamed yet" incus_not_called '^config device remove\|^rename '
stamp_before="$(sed -n 's/^stamp=//p' "$CASE/state/dev.replace")"
: >"$CASE/calls-incus"
run_machine up --replace dev --ssh-key k
check "the re-run exits 0" rc_is 0
check "the re-run makes no snapshot again" incus_not_called '^storage volume snapshot create'
check "the re-run exports under the same stamp" incus_called "^export dev $CASE/state/exports/dev-$stamp_before\.tar\.gz\.part --instance-only$"

echo "== up --replace: a snapshot that exists already is kept"
new_case replace-snapshot-exists
installed_machine
printf 'stamp=20261010-120000\n' >"$CASE/state/dev.replace"
touch "$CASE/snap-acfs-acfs-state-dev-acfs-replace-20261010-120000"
run_machine up --replace dev --ssh-key k
check "exits 0" rc_is 0
check "only the missing data snapshot is made" \
    bash -c '[[ "$(grep -c "^storage volume snapshot create" "$1")" -eq 1 ]] && grep -q "^storage volume snapshot create acfs dev-data acfs-replace-20261010-120000$" "$1"' _ "$CASE/calls-incus"

echo "== up --replace: an instance without the launcher's volume devices isn't snapshotted blindly"
new_case replace-no-pool
installed_machine
echo '{"devices":{"root":{"type":"disk"},"eth0":{"type":"nic"}}}' >"$CASE/devices-dev.json"
run_machine up --replace dev --ssh-key k
check "exits 2, naming the devices it needs" bash -c '[[ "$1" -eq 2 ]] && grep -q "no state-home and data devices with a pool and a source" "$2"' _ "$RC" "$CASE/err"
check "makes no snapshot, export or rename" incus_not_called '^storage volume snapshot create\|^export \|^rename '

echo "== up --replace: a failed lease move resumes"
new_case replace-unset-fails
installed_machine
export STUB_UNSET_EXIT=1
run_machine up --replace dev --ssh-key k
unset STUB_UNSET_EXIT
check "exits 1 after the launch" bash -c '[[ "$1" -eq 1 ]] && grep -qx launched=1 "$2" && ! grep -q lease-moved "$2"' _ "$RC" "$CASE/state/dev.replace"
rm -f "$CASE/calls-launcher"
run_machine up --replace dev --ssh-key k
check "the re-run moves the lease without launching again" bash -c '[[ "$1" -eq 0 && ! -e "$2/calls-launcher" && ! -e "$2/lease-dev-old" ]]' _ "$RC" "$CASE"

echo "== up --replace: a journal that no longer matches the instances is refused, not resumed"
new_case replace-stale-launched
# A rollback by hand after a failed verify: dev-old renamed back to dev,
# the journal left behind at launched=1.
installed_machine
printf 'stopped=1\ndetached=1\nrenamed=1\nlaunched=1\n' >"$CASE/state/dev.replace"
run_machine up --replace dev --ssh-key k
check "exits 2" rc_is 2
check "says the journal is stale and how to start over" err_has 'says dev was renamed to dev-old, but no such instance exists'
check "names the journal to remove" err_has "$CASE/state/dev.replace"
check "touches nothing: only lists" only_lists
check "launches nothing" no_launch
check "doesn't report a replace as done" err_lacks 'replace: done'
check "keeps the journal for the user to remove" test -f "$CASE/state/dev.replace"
new_case replace-stale-renamed
# The journal says renamed, but neither dev nor dev-old exists.
printf 'stopped=1\ndetached=1\nrenamed=1\n' >"$CASE/state/dev.replace"
run_machine up --replace dev --ssh-key k
check "no dev-old after renamed: exits 2" rc_is 2
check "no dev-old after renamed: launches nothing with --lease-from a missing instance" no_launch
new_case replace-stale-launched-only-old
# The journal says launched, dev-old exists, dev doesn't (the new instance was deleted).
instance_json dev-old Stopped container 1 >"$CASE/inst-dev-old.json"
printf 'stopped=1\ndetached=1\nrenamed=1\nlaunched=1\n' >"$CASE/state/dev.replace"
run_machine up --replace dev --ssh-key k
check "launched but dev missing: exits 2" rc_is 2
check "launched but dev missing: says so" err_has 'says dev was launched, but no such instance exists'
new_case replace-journal-valid
# A journal that matches the instances resumes: renamed, dev-old present, dev absent.
instance_json dev-old Stopped container 1 >"$CASE/inst-dev-old.json"
printf '0123456789abcdef0123456789abcdef\n' >"$CASE/lease-dev-old"
echo '[]' >"$CASE/guest-report.json"
printf 'stamp=20261010-120000\nstopped=1\nsnapshotted=1\nexported=1\ndetached=1\nrenamed=1\n' >"$CASE/state/dev.replace"
run_machine up --replace dev --ssh-key k
check "a matching journal resumes: exits 0" rc_is 0
check "a matching journal resumes: says it continues from the journal" err_has 'continuing from the journal'
check "a matching journal resumes: launches with the lease" launcher_args_are "dev --lease-from dev-old --ssh-key k"

echo "== up --replace: a failed verify keeps the journal and names the rollback"
new_case replace-verify-fails
installed_machine
echo '[{"check":"claude","status":"fail","detail":"login stored, mode 0600; claude -p: the login is invalid or expired (exit 1)"}]' >"$CASE/guest-report.json"
run_machine up --replace dev --ssh-key k
check "exits 1" rc_is 1
check "names the old instance as the rollback" err_has 'the old instance is still dev-old, stopped'
check "the rollback text names the journal to remove" err_has "rm $CASE/state/dev.replace"
check "the rollback text gives the lease back to the old root" err_has 'incus config set dev-old user.acfs.lease "$(incus config get dev user.acfs.lease)"'
check "the rollback text names the snapshots and the export it keeps" bash -c 'grep -q "The snapshots acfs-replace-[0-9]\{8\}-[0-9]\{6\} and the export .*/exports/dev-.*\.tar\.gz are kept" "$1"' _ "$CASE/err"
check "the journal keeps launched, not verified" bash -c 'grep -qx launched=1 "$1" && ! grep -q verified "$1"' _ "$CASE/state/dev.replace"

echo "== up --replace: preflight refusals touch nothing"
new_case replace-absent
run_machine up --replace dev --ssh-key k
check "no instance: exits 2" rc_is 2
check "no instance: says up creates one" err_has "'acfs machine up dev' creates one"
check "no instance: only lists" only_lists
new_case replace-uninstalled
instance_json dev Running container "" >"$CASE/inst-dev.json"
run_machine up --replace dev --ssh-key k
check "no finished install: exits 2" rc_is 2
check "no finished install: says so" err_has 'carries no user.acfs.installed'
check "no finished install: only lists" only_lists
new_case replace-vm
instance_json dev Running virtual-machine 1 >"$CASE/inst-dev.json"
run_machine up --replace dev --ssh-key k
check "a VM: exits 2" rc_is 2
check "a VM: says it has no state volume" err_has 'is a VM: a VM has no state volume'
new_case replace-old-exists
installed_machine
instance_json dev-old Stopped container 1 >"$CASE/inst-dev-old.json"
run_machine up --replace dev --ssh-key k
check "dev-old exists: exits 2" rc_is 2
check "dev-old exists: says to delete the earlier rollback" err_has "dev-old exists already: an earlier replace's rollback"
check "dev-old exists: only lists" only_lists
check "dev-old exists: launches nothing" no_launch

# ------------------------------------------------------------
# verify, locally (no name): the checklist against the stubs
# ------------------------------------------------------------
all_logins() {
    login_file .claude/.credentials.json
    login_file .codex/auth.json
    login_file .gemini/antigravity-cli/antigravity-oauth-token
    login_file .gemini/oauth_creds.json
    login_file .pi/agent/auth.json
    login_file .config/gh/hosts.yml
    login_file .config/mcp-agent-mail/config.env
    printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
    mkdir -p "$CASE/project/.beads"
}

echo "== verify: every tool configured and answering"
new_case verify-all
all_logins
run_machine verify
check "exits 0" rc_is 0
for tool in claude codex agy gemini pi gh agent-mail tailscale ssh-host-key herdr beads cm; do
    check "$tool: ok" status_is "$tool" ok
done
check "claude is asked with -p and the text format, saving no session" grep -qx -- '-p reply with ok --output-format text --no-session-persistence' "$CASE/calls-claude"
check "codex: login status, then one exec, saving no session" bash -c 'grep -qx "login status" "$1" && grep -q "^exec --skip-git-repo-check --ephemeral reply with ok$" "$1"' _ "$CASE/calls-codex"
check "sessions: not-configured without a saved one" bash -c '[[ "$(awk "\$1 == \"claude.session\" {print \$2}" "$1")" == not-configured && "$(awk "\$1 == \"codex.session\" {print \$2}" "$1")" == not-configured ]]' _ "$CASE/err"
check "agy: one print-mode request with a time limit" grep -q -- '^-p reply with ok --output-format text --print-timeout 90s$' "$CASE/calls-agy"
check "pi: no request without ACFS_VERIFY_PI_CMD" bash -c '[[ ! -s "$1" ]]' _ "$CASE/calls-pi"
check "pi: says why" detail_has pi 'no request made'
check "gh: auth status" grep -qx 'auth status' "$CASE/calls-gh"
check "agent-mail: health first, then an authenticated list" bash -c 'grep -q "8765/health" "$1" && grep -qx "agents list --json" "$2"' _ "$CASE/calls-curl" "$CASE/calls-am"
check "tailscale: the node name is recorded on the first run" detail_has tailscale 'node name recorded'
check "ssh-host-key: the fingerprint is recorded on the first run" detail_has ssh-host-key 'fingerprint recorded'
check "herdr: counts the workspaces" detail_has herdr '2 workspace'
check "beads: br ready in the project" detail_has beads 'br ready answers'
check "lease: skipped without the guest API" status_is lease skip
check "credentials-outside: none under /root" status_is credentials-outside ok
check "says nothing failed" err_has 'verify: nothing failed'
check "prints no secret" no_secret_printed

echo "== verify: the second run compares against the recorded baseline"
run_machine verify
check "tailscale unchanged" detail_has tailscale 'unchanged since first recorded'
check "ssh-host-key unchanged" detail_has ssh-host-key 'unchanged since first recorded'
export STUB_TAILSCALE_HOST=other STUB_HOST_FP=SHA256:changed
run_machine verify
unset STUB_TAILSCALE_HOST STUB_HOST_FP
check "a changed node name fails" status_is tailscale fail
check "a changed host key fails" status_is ssh-host-key fail
check "and names the baseline file to edit" detail_has ssh-host-key 'remove the ssh.host_key line'
check "exits 1" rc_is 1

echo "== verify: not configured is a distinct result, never a forced login"
new_case verify-none
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
run_machine verify
check "exits 0 (nothing failed)" rc_is 0
for tool in claude codex agy gemini pi gh agent-mail; do
    check "$tool: not-configured without its login file" status_is "$tool" not-configured
done
check "no tool is asked anything" bash -c '! ls "$1"/calls-claude "$1"/calls-codex "$1"/calls-agy "$1"/calls-gemini "$1"/calls-am >/dev/null 2>&1' _ "$CASE"
check "beads: skip without a .beads" status_is beads skip
new_case verify-no-tools
all_logins
run_machine --no-tools verify
check "without the CLIs installed: exits 0" rc_is 0
check "claude: not-configured when the CLI is missing" detail_has claude "isn't installed"
check "tailscale: not-configured when the CLI is missing" detail_has tailscale "isn't installed"

echo "== verify: failures are classified without printing output"
new_case verify-classify
all_logins
export STUB_CLAUDE_EXIT=1 STUB_CLAUDE_OUT='Error: rate limit reached, try again later'
export STUB_CODEX_EXIT=1 STUB_CODEX_OUT='Not logged in. Run codex login.'
export STUB_AGY_EXIT=1 STUB_AGY_OUT='getaddrinfo ENOTFOUND api.example'
export STUB_GEMINI_EXIT=7 STUB_GEMINI_OUT='something else went wrong'
export STUB_GH_EXIT=1 STUB_GH_OUT='You are not logged into any GitHub hosts'
run_machine verify
unset STUB_CLAUDE_EXIT STUB_CLAUDE_OUT STUB_CODEX_EXIT STUB_CODEX_OUT STUB_AGY_EXIT STUB_AGY_OUT STUB_GEMINI_EXIT STUB_GEMINI_OUT STUB_GH_EXIT STUB_GH_OUT
check "exits 1" rc_is 1
check "claude: quota" detail_has claude 'quota or rate limit exhausted'
check "codex: login status failing is an invalid login" detail_has codex 'not logged in'
check "agy: network" detail_has agy 'network failure'
check "gemini: an unclassified failure names the exit and hides the output" detail_has gemini 'exit 7 \(1 lines of output, not shown\)'
check "gh: invalid login" detail_has gh 'invalid or expired'
check "each failure's class is its status" bash -c '
    for pair in claude=quota codex=invalid-login agy=network gemini=fail gh=invalid-login; do
        [[ "$(awk -v c="${pair%%=*}" "\$1 == c {print \$2; exit}" "$1")" == "${pair#*=}" ]] || { echo "$pair"; exit 1; }
    done' _ "$CASE/err"
new_case verify-chatter
all_logins
# A working run whose output holds a session id and a token count with
# 401 and 429 in them: still ok.
export STUB_CLAUDE_OUT='session 7f401-a429; tokens used 1,429; ok'
export STUB_GEMINI_EXIT=1 STUB_GEMINI_OUT='error id 4291 at step 4013'
run_machine verify
unset STUB_CLAUDE_OUT STUB_GEMINI_EXIT STUB_GEMINI_OUT
check "a success whose output holds 401 and 429 is ok" status_is claude ok
check "numbers holding 401 or 429 aren't status codes" status_is gemini fail
check "the tools' output never reaches the report" bash -c '! grep -q "rate limit reached\|something else went wrong\|ENOTFOUND api" "$1" "$2"' _ "$CASE/out" "$CASE/err"
check "prints no secret" no_secret_printed

echo "== verify: a request that hangs is cut off by the timeout"
new_case verify-timeout
login_file .claude/.credentials.json
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
export STUB_CLAUDE_SLEEP=5
run_machine verify --timeout 1
unset STUB_CLAUDE_SLEEP
check "exits 1" rc_is 1
check "claude: no answer within 1s" detail_has claude 'no answer within 1s'
check "claude: a timeout is network" status_is claude network

echo "== verify: one session per kind, resumed as an unsaved fork in its own cwd"
new_case verify-sessions
all_logins
mkdir -p "$CASE/home/.claude/projects/-work" "$CASE/work" "$CASE/home/.codex/sessions/2026/10/10" "$CASE/repo"
printf '{"type":"summary"}\n{"cwd":"%s","sessionId":"x"}\n' "$CASE/work" >"$CASE/home/.claude/projects/-work/1111-2222.jsonl"
printf '{"type":"summary"}\n' >"$CASE/home/.claude/projects/-work/0000-old.jsonl"
touch -d '2026-01-01' "$CASE/home/.claude/projects/-work/0000-old.jsonl"
printf '{"type":"session_meta","payload":{"id":"0199-aaaa","cwd":"%s"}}\n' "$CASE/repo" \
    >"$CASE/home/.codex/sessions/2026/10/10/rollout-2026-10-10T10-00-00-0199-aaaa.jsonl"
# The stubs record where they ran.
for t in claude codex; do
    cat >"$CASE/$t-pwd" <<STUB
#!/usr/bin/env bash
printf '%s @ %s\n' "\$*" "\$PWD" >>"$CASE/calls-$t-pwd"
exec "$WORK/bin/$t" "\$@"
STUB
    chmod +x "$CASE/$t-pwd"
done
mkdir -p "$CASE/bin-pwd"
ln -sf "$CASE/claude-pwd" "$CASE/bin-pwd/claude"
ln -sf "$CASE/codex-pwd" "$CASE/bin-pwd/codex"
PATH_PREFIX="$CASE/bin-pwd" run_machine verify
check "claude.session: ok" status_is claude.session ok
check "codex.session: ok" status_is codex.session ok
check "the newest claude session is forked, unsaved, in its own cwd" \
    grep -qxF -- "-p reply with ok --resume 1111-2222 --fork-session --no-session-persistence --output-format text @ $CASE/work" "$CASE/calls-claude-pwd"
check "the newest codex session is forked, unsaved, in its own cwd" \
    grep -qxF -- "exec fork --skip-git-repo-check --ephemeral 0199-aaaa reply with ok @ $CASE/repo" "$CASE/calls-codex-pwd"
rm -rf "$CASE/repo"
run_machine verify
check "a session whose cwd is gone fails, naming it" bash -c '[[ "$(awk "\$1 == \"codex.session\" {print \$2}" "$1")" == fail ]] && grep -q "0199-aaaa.s working directory .* doesn.t exist here" "$1"' _ "$CASE/err"
run_machine verify --read-only
check "--read-only skips the resumes (they are requests)" status_is claude.session skip

echo "== verify: a login file others can read fails before any request"
new_case verify-mode
login_file .claude/.credentials.json 0644
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
run_machine verify
check "exits 1" rc_is 1
check "claude: names the mode and acfs state repair" detail_has claude 'mode 0644 allows group or other access; run: acfs state repair'
check "claude is not asked" tool_not_called claude

echo "== verify --read-only: stored logins only, no paid request"
new_case verify-read-only
all_logins
export STUB_CLAUDE_EXIT=1 STUB_CODEX_EXIT=1 STUB_AGY_EXIT=1 STUB_GEMINI_EXIT=1
run_machine verify --read-only
unset STUB_CLAUDE_EXIT STUB_CODEX_EXIT STUB_AGY_EXIT STUB_GEMINI_EXIT
check "exits 0 although the agents would fail" rc_is 0
check "claude: ok, request skipped" detail_has claude 'request skipped \(--read-only\)'
check "no agent CLI is asked" bash -c '! ls "$1"/calls-claude "$1"/calls-codex "$1"/calls-agy "$1"/calls-gemini >/dev/null 2>&1' _ "$CASE"
check "gh auth status still runs (a read)" tool_called gh

echo "== verify: the lease and the credential search need the guest API and sudo"
new_case verify-lease
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$CASE/guest.sock"
run_machine verify
check "lease: ok when sudo acfs state lease status matches" status_is lease ok
check "asks acfs state lease status through sudo -n" grep -qx -- '-n acfs state lease status' "$CASE/calls-sudo"
export STUB_LEASE_MATCH=no
run_machine verify
unset STUB_LEASE_MATCH
check "lease: fail when they don't match" status_is lease fail
mkdir -p "$CASE/rootfs/root/.codex"
printf 'SECRET-root\n' >"$CASE/rootfs/root/.codex/auth.json"
run_machine verify
check "credentials-outside: fail, naming the path only" detail_has credentials-outside '/root/.codex/auth.json \(a rebuild loses them\)'
check "prints no secret" no_secret_printed
# The volumes' paths and every other mount are left out of the search.
mkdir -p "$CASE/rootfs/home/ubuntu/.codex" "$CASE/rootfs/data/x" "$CASE/rootfs/mnt/vol" "$CASE/rootfs/etc/stray"
touch "$CASE/rootfs/home/ubuntu/.codex/auth.json" "$CASE/rootfs/data/x/.credentials.json" \
    "$CASE/rootfs/mnt/vol/hosts.yml" "$CASE/rootfs/etc/stray/oauth_creds.json"
printf '/mnt/vol\n' >"$CASE/mounts"
run_machine verify
check "the home, /data and another mount are left out; the root volume's files are found" \
    bash -c 'grep -E "^credentials-outside +fail +login files outside the state volume: /(root/.codex/auth.json /etc/stray/oauth_creds.json|etc/stray/oauth_creds.json /root/.codex/auth.json) \(a rebuild loses them\)$" "$1" >/dev/null' _ "$CASE/err"
export STUB_NO_SUDO=1
run_machine verify
unset STUB_NO_SUDO
check "lease: skip without passwordless sudo" status_is lease skip
check "credentials-outside: skip without passwordless sudo" status_is credentials-outside skip

echo "== verify --json"
new_case verify-json
login_file .claude/.credentials.json
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
run_machine verify --json
check "exits 0" rc_is 0
check "stdout is a JSON array of checks" bash -c 'jq -e "type == \"array\" and (map(select(.check == \"claude\" and .status == \"ok\")) | length) == 1" "$1" >/dev/null' _ "$CASE/out"
check "every row has check, status and detail" bash -c 'jq -e "all(has(\"check\") and has(\"status\") and has(\"detail\"))" "$1" >/dev/null' _ "$CASE/out"
check "no table on stderr" err_lacks 'login stored'

echo "== verify <name>: host-side checks, then the checklist inside the instance"
new_case verify-named
installed_machine
printf 'Host dev\n    HostName 192.0.2.20\n' >"$CASE/home/.ssh/config"
run_machine verify dev
check "exits 0" rc_is 0
check "instance-lease: ok" status_is instance-lease ok
check "ssh-entry: ok through the entry" status_is ssh-entry ok
check "ssh runs in batch mode against dev" grep -q -- '-o BatchMode=yes -o ConnectTimeout=10 dev true' "$CASE/calls-ssh"
check "runs the guest checklist as the target user with the timeout" incus_called '^exec dev --env HOME=/home/ubuntu -- runuser -u ubuntu -- bash -s -- verify --json --timeout 90$'
check "streams this very script in on stdin" grep -qx '#!/usr/bin/env bash' "$CASE/streamed-script"
check "merges the guest report" both_ok claude lease
run_machine verify dev --read-only --timeout 30
check "--read-only and --timeout reach the guest" incus_called 'bash -s -- verify --json --read-only --timeout 30$'
rm -f "$CASE/home/.ssh/config"
run_machine verify dev
check "ssh-entry: not-configured without a Host entry" status_is ssh-entry not-configured
new_case verify-named-stopped
installed_machine
jq '.status = "Stopped"' "$CASE/inst-dev.json" >"$CASE/x" && mv "$CASE/x" "$CASE/inst-dev.json"
run_machine verify dev
check "a stopped instance: exits 1" rc_is 1
check "a stopped instance: says so" err_has "dev isn't running"
new_case verify-named-absent
run_machine verify dev
check "no such instance: exits 2" rc_is 2
new_case verify-named-guest-fails
installed_machine
echo '[{"check":"codex","status":"fail","detail":"login stored, mode 0600; codex login status says not logged in"}]' >"$CASE/guest-report.json"
export STUB_GUEST_EXIT=1
run_machine verify dev
unset STUB_GUEST_EXIT
check "a failing guest check: exits 1" rc_is 1
check "a failing guest check: is reported as such" status_is codex fail

echo "== verify <name> without timeout(1), as on macOS, and a bare name on macOS"
new_case verify-named-no-timeout
installed_machine
printf 'Host dev\n    HostName 192.0.2.20\n' >"$CASE/home/.ssh/config"
NO_TIMEOUT=1 run_machine verify dev
check "no timeout(1): exits 0" rc_is 0
check "no timeout(1): the SSH entry is still checked" status_is ssh-entry ok
check "no timeout(1): ssh runs with keepalive limits, in batch mode" \
    grep -q -- '-o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o BatchMode=yes -o ConnectTimeout=10 dev true' "$CASE/calls-ssh"
NO_TIMEOUT=1 run_machine verify
check "no timeout(1): the local checklist exits 2, naming timeout" bash -c '[[ "$1" -eq 2 ]] && grep -q "timeout is required" "$2"' _ "$RC" "$CASE/err"
new_case verify-darwin
installed_machine
UNAME=Darwin run_machine verify dev
check "macOS: a bare name exits 0" rc_is 0
check "macOS: asks Colima's Incus first" incus_called '^info colima-acfs:$'
check "macOS: a bare name is the instance on colima-acfs" incus_called '^exec colima-acfs:dev --env HOME=/home/ubuntu -- runuser -u ubuntu -- bash -s -- verify --json --timeout 90$'
check "macOS: the lease is read there" status_is instance-lease ok
export STUB_INCUS_INFO_EXIT=1
UNAME=Darwin run_machine verify dev
unset STUB_INCUS_INFO_EXIT
check "macOS, Colima down: exits 1, saying how to start it" bash -c '[[ "$1" -eq 1 ]] && grep -q "colima start --profile acfs" "$2"' _ "$RC" "$CASE/err"
: >"$CASE/calls-incus"
UNAME=Darwin run_machine verify far:dev
check "macOS: a named remote is used as given" incus_called '^exec far:dev --env HOME=/home/ubuntu'
check "macOS: a named remote doesn't ask Colima" incus_not_called '^info '

echo "== acfs machine routes to machine.sh (doctor.sh's main)"
[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
mkdir -p "$WORK/route/lib"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$ROUTE_CALLS"\n' >"$WORK/route/lib/machine.sh"
: >"$WORK/route/calls"
ROUTE_CALLS="$WORK/route/calls" STUB_LIB_DIR="$WORK/route/lib" HOME="$WORK/route/home" \
bash -c '
    set +e
    # shellcheck disable=SC1090
    source <(sed "\$d" "$1") >/dev/null 2>&1
    shift
    _acfs_doctor_find_lib_script() { printf "%s\n" "$STUB_LIB_DIR/$1"; }
    _acfs_doctor_exec_bash_script() { local s="$1"; shift; bash "$s" "$@"; exit $?; }
    doctor_binary_path() { return 1; }
    main machine "$@"
' _ "$DOCTOR" verify dev --read-only >/dev/null 2>&1 || true
check "acfs machine verify dev --read-only reaches machine.sh unchanged" test "$(cat "$WORK/route/calls")" = "verify dev --read-only"

echo
echo "acfs machine (stubs): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
