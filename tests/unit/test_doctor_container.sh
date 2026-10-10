#!/usr/bin/env bash
# ============================================================
# doctor's container section and Incus-in-a-container check (acfs-ioo3.6)
# against stubs
#
# In an Incus system container (systemd-detect-virt -c says lxc) doctor
# checks the working set against memory.high from the capacity guard, /tmp on
# disk, linger, the acfs slices with MemoryLow along the chain and the
# agents' OOM killer, the state layer's own report, and that incus has a
# remote. systemd-detect-virt, stat, loginctl, systemctl and incus are stubs
# on PATH; no real Incus or systemd is asked anything. doctor.sh ends in
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
cat >"$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAKE_CALLS"
case "$*" in
    "--user show --property=Id,FragmentPath,DropInPaths,MemoryLow,ManagedOOMMemoryPressure "*)
        [[ "${FAKE_USER_MANAGER:-up}" == up ]] || exit 1
        first=true
        for unit in acfs-services.slice acfs-background.slice acfs-agents.slice; do
            $first || echo
            first=false
            var="FAKE_${unit%%.slice}"; var="${var//-/_}"
            # FAKE_acfs_services="<file|dropin|none> <memorylow> <oom>"; systemd
            # says LoadState=loaded for any slice name, so the stub does too.
            read -r how low oom <<<"${!var:-none 0 auto}"
            fragment=""; dropins=""
            [[ "$how" == file ]] && fragment="/home/u/.config/systemd/user/$unit"
            [[ "$how" == dropin ]] && dropins="/home/u/.config/systemd/user/$unit.d/10-acfs.conf"
            printf 'Id=%s\nFragmentPath=%s\nDropInPaths=%s\nMemoryLow=%s\nManagedOOMMemoryPressure=%s\n' \
                "$unit" "$fragment" "$dropins" "$low" "$oom"
        done
        ;;
    "show --property=MemoryLow --value user.slice user-"*)
        printf '%s\n\n%s\n\n%s\n' "${FAKE_CHAIN_USER:-12884901888}" "${FAKE_CHAIN_SLICE:-12884901888}" "${FAKE_CHAIN_SERVICE:-12884901888}"
        ;;
    "--user show --property=MemoryLow --value acfs.slice")
        printf '%s\n' "${FAKE_CHAIN_ACFS:-11811160064}"
        ;;
    "is-active --quiet systemd-oomd.service") [[ "${FAKE_OOMD:-active}" == active ]] ;;
    "--user is-active --quiet acfs-agents-pressure.service") [[ "${FAKE_PRESSURE_UNIT:-inactive}" == active ]] ;;
    *) exit 1 ;;
esac
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

# A guard report as capacity.sh --guard --json gives it in a container:
# $1 working set MiB, $2 limit MiB ("" for none), $3 used percent,
# $4 reasons (a JSON array).
guard_json() {
    jq -n -c --arg current "$1" --arg limit "$2" --arg used "$3" --argjson reasons "${4:-[]}" '
        def num: if . == "" then null else tonumber end;
        {schema_version: 1, status: "green", reasons: $reasons,
         container: {virt: "lxc", memory_current_mib: (($current | num) + 5000) , memory_working_set_mib: ($current | num),
                     memory_limit_mib: ($limit | num),
                     memory_limit_file: (if $limit == "" then null else "memory.high" end),
                     memory_used_percent: ($used | num)},
         thresholds: {max_container_memory_percent: 80}}'
}

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
        _ACFS_DOCTOR_GUARD_JSON="${GUARD:-}"
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

# A healthy container: every slice loaded and protected, oomd on, linger on,
# /tmp on disk, a remote, and the state layer's own checks.
healthy() {
    export FAKE_VIRT=lxc FAKE_LINGER=yes FAKE_TMP_FSTYPE=ext2/ext3 TMPDIR=/data/tmp
    export FAKE_acfs_services="file 8589934592 auto"
    export FAKE_acfs_background="dropin 3221225472 auto"
    export FAKE_acfs_agents="file 0 kill"
    export GUARD
    GUARD="$(guard_json 40960 98304 41)"
    export FAKE_STATE_REPORT='[{"id":"state.layer","label":"State layer","status":"pass","details":"acfs-state-devbox","fix":""},
                               {"id":"state.lease","label":"Lease","status":"warn","details":"","fix":"acfs state lease --repair"}]'
}

echo "container section"

out="$(FAKE_VIRT=none run_doctor check_container)"
check_case "outside a container the section prints nothing" test -z "$out"

out="$(healthy; run_doctor check_container)"
check_case "a healthy container passes every check, in order" \
    test "$(cut -d'|' -f1,2 <<<"$out")" = "container.virt|pass
container.memory|pass
container.tmp|pass
container.tmpdir|pass
container.linger|pass
container.slices|pass
container.memory_low|pass
container.oomd|pass
state.layer|pass
state.lease|warn"
check_case "memory reports the working set against memory.high and the 80% line" \
    has_line "^container.memory|pass|working set 40960 MiB, 41% of memory.high (98304 MiB); spawn refuses over 80%|$" "$out"
check_case "MemoryLow is shown in GiB" \
    has_line "^container.memory_low|pass|MemoryLow 8 GiB on acfs-services.slice, 3 GiB on acfs-background.slice|$" "$out"
check_case "the state layer's empty details keep their place (the fix stays the fix)" \
    has_line "^state.lease|warn||acfs state lease --repair$" "$out"
check_case "the state layer is asked for its doctor report as JSON" \
    has_line "^state_layer doctor --json$" "$(cat "$WORK/calls")"
check_case "linger is read for the target user" \
    has_line "^loginctl show-user swarm --property=Linger --value$" "$(cat "$WORK/calls")"

out="$(healthy; GUARD="$(guard_json 13200 16384 80 '["the container'"'"'s working set (memory.current less inactive_file) is 13200 MiB, 80% of memory.high (16384 MiB), over 80%"]')" \
    run_doctor _acfs_doctor_container_memory)"
check_case "over the 80% line (the guard's own reason) warns, even at a floor of 80%" \
    has_line "^container.memory|warn|working set 13200 MiB is 80% of memory.high (16384 MiB): over 80%, so acfs agents spawn refuses|Retire idle agents" "$out"

out="$(healthy; GUARD="$(guard_json 1024 "" "")" run_doctor _acfs_doctor_container_memory)"
check_case "no memory limit warns" \
    has_line "^container.memory|warn|no limit (memory.high and memory.max are max)" "$out"

out="$(healthy; GUARD="not json" run_doctor _acfs_doctor_container_memory)"
check_case "no guard report skips" \
    test "$out" = "container.memory|skip|acfs capacity --guard gave no container report|"

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

echo "slices"

out="$(healthy; FAKE_acfs_services="none 0 auto" FAKE_acfs_background="none 0 auto" FAKE_acfs_agents="none 0 auto" \
    run_doctor _acfs_doctor_container_slices)"
check_case "slices with neither a unit file nor a drop-in (loaded, as systemd says of any slice) are one warning" \
    test "$(cut -d'|' -f1,2 <<<"$out")" = "container.slices|warn"

out="$(healthy; FAKE_acfs_background="none 0 auto" run_doctor _acfs_doctor_container_slices)"
check_case "a missing slice is named" \
    has_line "^container.slices|warn|not installed: acfs-background.slice|" "$out"

out="$(healthy; FAKE_acfs_services="file 0 auto" run_doctor _acfs_doctor_container_slices)"
check_case "the services' slice without MemoryLow warns" \
    has_line "^container.memory_low|warn|acfs-services.slice has no MemoryLow" "$out"

for ancestor in USER SLICE SERVICE; do
    out="$(healthy; export "FAKE_CHAIN_$ancestor=0"; run_doctor _acfs_doctor_container_slices)"
    case "$ancestor" in
        USER) name="user.slice" ;;
        SLICE) name="user-[0-9]*.slice" ;;
        SERVICE) name="user@[0-9]*.service" ;;
    esac
    check_case "an ancestor without MemoryLow ($name) is named, and the slice's protects nothing" \
        has_line "^container.memory_low|warn|no MemoryLow on $name, so acfs-services.slice's protects nothing" "$out"
done
out="$(healthy; FAKE_CHAIN_ACFS=0 run_doctor _acfs_doctor_container_slices)"
check_case "acfs.slice, the parent a dash gives acfs-services.slice, counts as an ancestor too" \
    has_line "^container.memory_low|warn|no MemoryLow on acfs.slice, so" "$out"
check_case "the chain is asked of the system manager and of the user manager" \
    bash -c 'grep -q "^systemctl show --property=MemoryLow --value user.slice user-[0-9]*.slice user@[0-9]*.service$" "$1" &&
             grep -q "^systemctl --user show --property=MemoryLow --value acfs.slice$" "$1"' _ "$WORK/calls"

out="$(healthy; FAKE_OOMD=inactive run_doctor _acfs_doctor_container_slices)"
check_case "no oomd and no fallback warns" \
    has_line "^container.oomd|warn|nothing kills an agent under memory pressure" "$out"
out="$(healthy; FAKE_OOMD=inactive FAKE_PRESSURE_UNIT=active run_doctor _acfs_doctor_container_slices)"
check_case "the fallback pressure unit stands in for oomd" \
    has_line "^container.oomd|pass|acfs-agents-pressure.service kills" "$out"
out="$(healthy; FAKE_acfs_agents="file 0 auto" run_doctor _acfs_doctor_container_slices)"
check_case "oomd running but not managing the agents' slice warns" \
    has_line "^container.oomd|warn" "$out"

out="$(healthy; FAKE_USER_MANAGER=down run_doctor _acfs_doctor_container_slices)"
check_case "an unreachable user manager skips" \
    test "$out" = "container.slices|skip|the user manager isn't reachable (systemctl --user)|"

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
