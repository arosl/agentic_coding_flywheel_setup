#!/usr/bin/env bash
# ============================================================
# doctor's host capacity checks (acfs-gmbo) against a stub capacity.sh
#
# doctor warns on a host with no swap, an rch with no workers and a tmpfs
# /tmp more than half full, from 'acfs capacity --guard --json'. doctor.sh
# ends in `main "$@"`, so its functions are loaded with that line stripped,
# as the bats tests do.
#
# Usage: bash tests/unit/test_doctor_host_capacity.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-host-capacity.XXXXXX")"
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

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

# The stub capacity.sh prints $GUARD_JSON for --guard --json and logs its
# arguments.
mkdir -p "$WORK/lib"
cat >"$WORK/lib/capacity.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GUARD_CALLS"
printf '%s\n' "$GUARD_JSON"
STUB
chmod +x "$WORK/lib/capacity.sh"

# A guard report: $1 swap MiB, $2 rch posture, $3 workers, $4 /tmp fstype,
# $5 /tmp free percent.
guard_json() {
    jq -n -c --argjson swap "$1" --arg posture "$2" --argjson workers "$3" \
        --arg fstype "$4" --argjson free "$5" '
        {schema_version: 1, status: "yellow",
         memory: {total_mib: 32000, available_mib: 20000, swap_total_mib: $swap, swap_free_mib: $swap},
         rch: {posture: $posture, workers_total: $workers, workers_healthy: $workers},
         filesystems: [{role: "work", mount: "/", fstype: "ext4", free_percent: 40},
                       {role: "temp", mount: "/tmp", fstype: $fstype, free_percent: $free}]}'
}

# Runs the check with doctor's functions loaded and the stub found; prints
# one "id|status|details|fix" line per check.
run_check() {
    : >"$WORK/calls"
    GUARD_CALLS="$WORK/calls" GUARD_JSON="$1" STUB_LIB_DIR="$WORK/lib" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        _acfs_doctor_find_lib_script() { printf "%s\n" "$STUB_LIB_DIR/$1"; }
        _acfs_doctor_exec_bash_script() { local s="$1"; shift; bash "$s" "$@"; }
        section() { :; }
        blank_line() { :; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_host_capacity
    ' _ "$DOCTOR"
}

echo "host capacity"

out="$(run_check "$(guard_json 8192 remote_ready 4 tmpfs 80)")"
check_case "a healthy host passes all three" \
    test "$out" = "host.swap|pass|8192 MiB|
host.rch_workers|pass|4 of 4 healthy (remote_ready)|
host.tmp_tmpfs|pass|20% full|"
check_case "the check only asks the guard for its JSON report" \
    test "$(cat "$WORK/calls")" = "--guard --json"

out="$(run_check "$(guard_json 0 local_only 0 tmpfs 22)")"
check_case "no swap warns" \
    bash -c 'grep -q "^host.swap|warn|none: " <<<"$1"' _ "$out"
check_case "rch with no workers warns, with a fix" \
    bash -c 'grep -q "^host.rch_workers|warn|0 of 0 healthy (posture local_only): every build runs locally|Run: rch doctor" <<<"$1"' _ "$out"
check_case "a tmpfs /tmp 78% full warns" \
    bash -c 'grep -q "^host.tmp_tmpfs|warn|78% full" <<<"$1"' _ "$out"

out="$(run_check "$(guard_json 8192 not_installed 0 ext4 10)")"
check_case "no rch (stack.rch already warns) and a disk /tmp add no checks" \
    test "$out" = "host.swap|pass|8192 MiB|"

out="$(run_check "$(guard_json 8192 remote_ready 4 tmpfs 50)")"
check_case "a tmpfs /tmp exactly half full passes" \
    bash -c 'grep -q "^host.tmp_tmpfs|pass|50% full" <<<"$1"' _ "$out"

out="$(run_check "not json")"
check_case "a guard that gives no report skips instead of guessing" \
    test "$out" = "host.capacity|skip|acfs capacity --guard gave no report|"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
