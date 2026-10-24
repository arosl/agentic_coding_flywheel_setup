#!/usr/bin/env bash
# ============================================================
# doctor's shell.login_shell check, with and without user.sh deployed
# (acfs-kcia)
#
# A runtime from before upstream's #473 lacks scripts/lib/user.sh until an
# update syncs it, and an update that can't pull deploys the new doctor.sh
# without it. That is a stale runtime, so the check warns; only a login
# shell the validator rejects fails. doctor.sh ends in `main "$@"`, so its
# functions are loaded with that line stripped, as the other doctor tests do.
#
# Usage: bash tests/unit/test_doctor_login_shell.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-login-shell.XXXXXX")"
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

# A stand-in user.sh whose validator answers with exit status $2.
write_user_lib() {
    mkdir -p "$1"
    printf 'user_login_shell_configured() { return %s; }\n' "$2" >"$1/user.sh"
}

# Run check_shell with doctor's functions loaded and the collector replaced;
# prints the shell.login_shell line as "id|status|details|fix".
run_check() {
    local lib_dir="$1"
    STUB_LIB_DIR="$lib_dir" HOME="$WORK/home" bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        TARGET_USER=swarm
        doctor_runtime_home() { printf "%s\n" "$HOME"; }
        _acfs_doctor_find_lib_script() { [[ -e "$STUB_LIB_DIR/$1" ]] && printf "%s\n" "$STUB_LIB_DIR/$1"; }
        section() { :; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_shell 2>/dev/null
    ' _ "$DOCTOR" | grep '^shell\.login_shell|'
}
mkdir -p "$WORK/home"

echo "shell.login_shell"

out="$(run_check "$WORK/no-lib")"
check_case "a runtime without user.sh warns, naming the update" \
    bash -c '[[ "$1" == "shell.login_shell|warn|user.sh validator is not deployed"*"|Run acfs-update"* ]]' _ "$out"

write_user_lib "$WORK/good-lib" 0
out="$(run_check "$WORK/good-lib")"
check_case "an approved login shell passes" \
    bash -c '[[ "$1" == "shell.login_shell|pass|"* ]]' _ "$out"

write_user_lib "$WORK/bad-lib" 1
out="$(run_check "$WORK/bad-lib")"
check_case "a login shell the validator rejects still fails" \
    bash -c '[[ "$1" == "shell.login_shell|fail|"* ]]' _ "$out"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
