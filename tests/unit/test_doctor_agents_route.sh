#!/usr/bin/env bash
# ============================================================
# `acfs agents <subcommand>` routing in doctor.sh's main, against a stub
# herdr_agents.sh
#
# Every herdr_agents.sh subcommand must reach it with its arguments
# unchanged; the guide subcommands (update, path, ...) must not.
# doctor.sh ends in `main "$@"`, so its functions are loaded without that
# last line.
#
# Usage: bash tests/unit/test_doctor_agents_route.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-agents-route.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
    local description="$1"
    shift
    if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$description"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$description"; fi
}

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

mkdir -p "$WORK/lib"
cat >"$WORK/lib/herdr_agents.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HELPER_CALLS"
STUB

# Run `main agents "$@"` with doctor's functions loaded and the stub found.
route() {
    : >"$WORK/calls"
    HELPER_CALLS="$WORK/calls" STUB_LIB_DIR="$WORK/lib" HOME="$WORK/home" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        shift
        _acfs_doctor_find_lib_script() { printf "%s\n" "$STUB_LIB_DIR/$1"; }
        _acfs_doctor_exec_bash_script() { local s="$1"; shift; bash "$s" "$@"; exit $?; }
        doctor_binary_path() { return 1; }
        main agents "$@"
    ' _ "$DOCTOR" "$@" >/dev/null 2>&1 || true
    cat "$WORK/calls"
}

echo "acfs agents routing"
for sub in spawn send list ls inbox wake codex-daemon retire quota; do
    check "acfs agents $sub reaches herdr_agents.sh" test "$(route "$sub" --x "a b")" = "$sub --x a b"
done
for sub in update path help; do
    check "acfs agents $sub stays with the guide generator" test -z "$(route "$sub")"
done

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
