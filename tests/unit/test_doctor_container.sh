#!/usr/bin/env bash
# ============================================================
# doctor's container section and Incus-in-a-container check (acfs-ioo3.6)
# against stubs
#
# In an Incus system container (systemd-detect-virt -c says lxc) doctor
# checks /tmp on disk, linger, the state layer's own report, and that incus
# has a remote. It has no memory check: spawn admission is nhm's (acfs-0oc2).
# systemd-detect-virt, stat, loginctl, systemctl and incus are stubs on PATH;
# no real Incus or systemd is asked anything. doctor.sh ends in
# `main "$@"`, so its functions are loaded with that line stripped.
#
# Usage: bash tests/unit/test_doctor_container.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-container.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check_case() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
has_line() { grep -q -- "$1" <<<"$2"; }
lacks_line() { ! grep -q -- "$1" <<<"$2"; }

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Stubs. Each reads its answer from FAKE_* variables and logs its arguments.
mkdir -p "$WORK/bin" "$WORK/lib"
cat >"$WORK/bin/systemd-detect-virt" <<'STUB'
#!/usr/bin/env bash
echo "${FAKE_VIRT:-none}"
[[ "${FAKE_VIRT:-none}" != none ]]
STUB
cat >"$WORK/bin/stat" <<'STUB'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "-f -c %T" ]] || exit 2
case "${!#}" in
    /tmp) echo "${FAKE_TMP_FSTYPE:-ext2/ext3}" ;;
    *) echo "${FAKE_TMPDIR_FSTYPE:-ext2/ext3}" ;;
esac
STUB
cat >"$WORK/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >>"$FAKE_CALLS"
[[ -n "${FAKE_LINGER:-}" ]] || exit 1
echo "$FAKE_LINGER"
STUB
# The section asks systemd nothing; a call would show in the log.
cat >"$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAKE_CALLS"
exit 1
STUB
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
printf 'incus %s\n' "$*" >>"$FAKE_CALLS"
case "$*" in
    "--version") echo "6.0.6" ;;
    "remote list --format json") printf '%s\n' "${FAKE_REMOTES:-}" ;;
    *) echo "unexpected incus call: $*" >&2; exit 9 ;;
esac
STUB
cat >"$WORK/lib/state_layer.sh" <<'STUB'
#!/usr/bin/env bash
printf 'state_layer %s\n' "$*" >>"$FAKE_CALLS"
printf '%s\n' "${FAKE_STATE_REPORT:-}"
STUB
chmod +x "$WORK/bin/"* "$WORK/lib/state_layer.sh"

# Runs one doctor function with the stubs first on PATH; prints one
# "id|status|details|fix" line per check.
run_doctor() {
    local fn="$1"
    : >"$WORK/calls"
    FAKE_CALLS="$WORK/calls" STUB_LIB_DIR="$WORK/lib" PATH="$WORK/bin:$PATH" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        TARGET_USER=swarm
        doctor_runtime_home() { printf "%s\n" "$FAKE_HOME"; }
        _acfs_doctor_find_lib_script() { [[ -e "$STUB_LIB_DIR/$1" ]] && printf "%s\n" "$STUB_LIB_DIR/$1"; }
        _acfs_doctor_exec_bash_script() { local s="$1"; shift; bash "$s" "$@"; }
        doctor_binary_path() { [[ "$1" == incus && -n "${HAS_INCUS:-}" ]] && printf "%s\n" "$STUB_BIN/incus"; }
        get_version_line() { echo "6.0.6"; }
        section() { :; }
        blank_line() { :; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        "$2"
    ' _ "$DOCTOR" "$fn"
}
export STUB_BIN="$WORK/bin" FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

# A healthy container: linger on, /tmp on disk, a remote, and the state
# layer's own checks.
healthy() {
    export FAKE_VIRT=lxc FAKE_LINGER=yes FAKE_TMP_FSTYPE=ext2/ext3 TMPDIR=/data/tmp
    export FAKE_STATE_REPORT='[{"id":"state.layer","label":"State layer","status":"pass","details":"acfs-state-devbox","fix":""},
                               {"id":"state.lease","label":"Lease","status":"warn","details":"","fix":"acfs state lease --repair"}]'
}

echo "container section"

out="$(FAKE_VIRT=none run_doctor check_container)"
check_case "outside a container the section prints nothing" test -z "$out"

out="$(healthy; run_doctor check_container)"
check_case "a healthy container passes every check, in order" \
    test "$(cut -d'|' -f1,2 <<<"$out")" = "container.virt|pass
container.tmp|pass
container.tmpdir|pass
container.linger|pass
state.layer|pass
state.lease|warn"
check_case "nothing asks systemd about slices, MemoryLow or oomd (service protection is dropped)" \
    lacks_line "^systemctl" "$(cat "$WORK/calls")"
check_case "the state layer's empty details keep their place (the fix stays the fix)" \
    has_line "^state.lease|warn||acfs state lease --repair$" "$out"
check_case "the state layer is asked for its doctor report as JSON" \
    has_line "^state_layer doctor --json$" "$(cat "$WORK/calls")"
check_case "linger is read for the target user" \
    has_line "^loginctl show-user swarm --property=Linger --value$" "$(cat "$WORK/calls")"

out="$(healthy; FAKE_TMP_FSTYPE=tmpfs run_doctor _acfs_doctor_container_tmp)"
check_case "a tmpfs /tmp warns, with the mask as the fix" \
    has_line "^container.tmp|warn|/tmp is a tmpfs: .*|sudo systemctl mask tmp.mount, then restart the container (an Incus tmpfs disk" "$out"

out="$(healthy; FAKE_TMPDIR_FSTYPE=tmpfs run_doctor _acfs_doctor_container_tmp)"
check_case "a TMPDIR on a tmpfs warns too" \
    has_line "^container.tmpdir|warn|TMPDIR=/data/tmp is on a tmpfs" "$out"
out="$(healthy; run_doctor _acfs_doctor_container_tmp)"
check_case "a TMPDIR on disk passes" \
    has_line "^container.tmpdir|pass|/data/tmp|$" "$out"
for unset_tmpdir in "" /tmp /tmp/; do
    out="$(healthy; TMPDIR="$unset_tmpdir" run_doctor _acfs_doctor_container_tmp)"
    expected="${unset_tmpdir%/}"
    check_case "TMPDIR '${unset_tmpdir}' warns, with the installer's file as the fix" \
        has_line "^container.tmpdir|warn|TMPDIR is ${expected:-unset}: agents' temp files land on the root volume|Re-run the ACFS installer, or put TMPDIR=/data/tmp in ~/.config/environment.d/60-acfs-tmpdir.conf" "$out"
done
out="$(FAKE_VIRT=none run_doctor check_container)"
check_case "outside a container no TMPDIR advice either" lacks_line "tmpdir" "$out"

# The installer's environment.d file wins over doctor's own environment,
# which under sudo or a unit may lack TMPDIR.
mkdir -p "$FAKE_HOME/.config/environment.d"
printf '# ACFS\nTMPDIR="/data/tmp"\n' > "$FAKE_HOME/.config/environment.d/60-acfs-tmpdir.conf"
out="$(healthy; TMPDIR="" run_doctor _acfs_doctor_container_tmp)"
check_case "TMPDIR from ~/.config/environment.d passes when doctor's own is unset" \
    has_line "^container.tmpdir|pass|/data/tmp|$" "$out"
mv "$FAKE_HOME/.config/environment.d/60-acfs-tmpdir.conf" "$WORK/60-acfs-tmpdir.conf.off"

out="$(healthy; FAKE_LINGER=no run_doctor _acfs_doctor_container_linger)"
check_case "linger off warns, with enable-linger as the fix" \
    has_line "^container.linger|warn|off for swarm: .*|sudo loginctl enable-linger swarm$" "$out"

echo "state layer"

out="$(healthy; rm -f "$WORK/lib/state_layer.sh.off"; mv "$WORK/lib/state_layer.sh" "$WORK/lib/state_layer.sh.off"
       run_doctor _acfs_doctor_container_state; mv "$WORK/lib/state_layer.sh.off" "$WORK/lib/state_layer.sh")"
check_case "no state_layer.sh is one skip" \
    test "$out" = "state.layer|skip|state_layer.sh is not installed|"

out="$(healthy; FAKE_STATE_REPORT='{"oops":1}' run_doctor _acfs_doctor_container_state)"
check_case "a report that isn't an array skips" \
    test "$out" = "state.layer|skip|state_layer.sh doctor --json gave no report|"

out="$(healthy; FAKE_STATE_REPORT='[{"id":"state.modes","status":"fail","details":"~/.ssh is 0755"},{"id":"host.swap","status":"pass"},{"id":"state.x","status":"maybe"},"junk"]' \
    run_doctor _acfs_doctor_container_state)"
check_case "valid items pass through, and the rest are counted, not trusted" \
    test "$out" = "state.modes|fail|~/.ssh is 0755|
state.layer.report|warn|3 item(s) from state_layer.sh doctor --json are not checks doctor can read|"

echo "incus in a container"

remotes='{"images":{"Addr":"https://images.linuxcontainers.org","Protocol":"simplestreams","Public":true},
          "local":{"Addr":"unix://","Protocol":"","Public":false},
          "oci-docker":{"Addr":"https://docker.io","Protocol":"oci","Public":true},
          "host":{"Addr":"https://10.0.0.1:8443","Protocol":"incus","Public":false}}'
out="$(healthy; HAS_INCUS=1 FAKE_REMOTES="$remotes" run_doctor check_incus)"
check_case "a remote to the host's Incus passes, and no daemon or group check runs" \
    test "$out" = "tools.incus|pass|client; instances live on a remote|
tools.incus.remote|pass|host|"
check_case "only the client's remote list is read" \
    test "$(grep '^incus' "$WORK/calls")" = "incus remote list --format json"

out="$(healthy; HAS_INCUS=1 FAKE_REMOTES='{"images":{"Addr":"https://images.linuxcontainers.org","Protocol":"simplestreams","Public":true},"local":{"Addr":"unix://","Protocol":"incus","Public":false}}' \
    run_doctor check_incus)"
check_case "only local and images warns that incus has no remote" \
    has_line "^tools.incus.remote|warn|none: test instances can't be made from inside the container|" "$out"

out="$(healthy; HAS_INCUS=1 FAKE_REMOTES='' run_doctor check_incus)"
check_case "an unreadable remote list skips" \
    has_line "^tools.incus.remote|skip|" "$out"

out="$(healthy; run_doctor check_incus)"
check_case "no incus client in the container is the usual optional skip" \
    test "$out" = "tools.incus|skip|not installed (optional)|"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
