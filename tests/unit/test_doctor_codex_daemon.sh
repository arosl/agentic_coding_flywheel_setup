#!/usr/bin/env bash
# ============================================================
# doctor's agent.codex_daemon check (acfs-gen.3) against a stub
# herdr_agents.sh
#
# The check must report what `acfs agents codex-daemon status` says and
# never run the fix itself. doctor.sh ends in `main "$@"`, so its
# functions are loaded with that line stripped, as the bats tests do.
#
# Usage: bash tests/unit/test_doctor_codex_daemon.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-codex-daemon.XXXXXX")"
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

# The stub helper answers `codex-daemon status` from $HELPER_LINE and
# $HELPER_RC, and logs every call.
mkdir -p "$WORK/lib" "$WORK/bin"
cat >"$WORK/lib/herdr_agents.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HELPER_CALLS"
printf '%s\n' "$HELPER_LINE"
exit "$HELPER_RC"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/codex"
chmod +x "$WORK/lib/herdr_agents.sh" "$WORK/bin/codex"

# Run the check in a subshell with doctor's functions loaded, the stub
# helper found and the collector replaced; prints "status|details|fix".
run_check() {
    local line="$1" rc="$2" codex_present="${3:-true}"
    : >"$WORK/calls"
    HELPER_CALLS="$WORK/calls" HELPER_LINE="$line" HELPER_RC="$rc" \
    STUB_LIB_DIR="$WORK/lib" STUB_CODEX_PRESENT="$codex_present" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        _acfs_doctor_find_lib_script() { printf "%s\n" "$STUB_LIB_DIR/$1"; }
        _acfs_doctor_exec_bash_script() { local s="$1"; shift; bash "$s" "$@"; }
        if [[ "$STUB_CODEX_PRESENT" == true ]]; then
            doctor_binary_exists() { [[ "$1" == codex ]]; }
        else
            doctor_binary_exists() { return 1; }
        fi
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_codex_daemon_env
    ' _ "$DOCTOR"
}

echo "agent.codex_daemon"

out="$(run_check 'codex app-server daemon: running (pid 777), no HERDR_* variables' 0)"
check_case "a clean daemon passes" \
    test "$out" = "agent.codex_daemon|pass|running without HERDR_* variables|"

out="$(run_check 'codex app-server daemon: not running' 0)"
check_case "no daemon passes, naming who starts it clean" \
    bash -c '[[ "$1" == agent.codex_daemon\|pass\|*"not running"* ]]' _ "$out"

out="$(run_check "codex app-server daemon: running (pid 777) with HERDR_PANE_ID, HERDR_TAB_ID; every Codex session on this host reports as that pane's agent. Fix: acfs agents codex-daemon restart" 1)"
check_case "a daemon carrying HERDR_* variables fails, with the variables and the fix" \
    bash -c '[[ "$1" == agent.codex_daemon\|fail\|"running (pid 777) with HERDR_PANE_ID, HERDR_TAB_ID"*\|"Run: acfs agents codex-daemon restart"* ]]' _ "$out"
check_case "the check only asks for status; it never restarts" \
    test "$(cat "$WORK/calls")" = "codex-daemon status"

out="$(run_check '' 2)"
check_case "a helper that fails warns instead of guessing" \
    bash -c '[[ "$1" == agent.codex_daemon\|warn\|*"exited 2"*\|* ]]' _ "$out"

out="$(run_check 'x' 0 false)"
check_case "without a codex binary the check is silent" test -z "$out"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
