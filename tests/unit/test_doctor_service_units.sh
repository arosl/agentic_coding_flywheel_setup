#!/usr/bin/env bash
# ============================================================
# doctor's services.unit.<service> checks (acfs-eyvw)
#
# check_service_units reads `acfs-services.sh health --robot`: a unit
# systemd gave up on fails; one waiting for its next automatic restart, one
# enabled but not running, and one on older unit settings warn. Every other
# state is no finding. doctor.sh ends in `main "$@"`, so its functions are
# loaded with that line stripped, as the other doctor tests do. The last
# case runs the real acfs-services.sh against a stub systemctl.
#
# Usage: bash tests/unit/test_doctor_service_units.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
SERVICES="$ROOT/scripts/lib/acfs-services.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-service-units.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       got: %s\n' "$2"; return 0; }

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

# A stand-in acfs-services.sh that prints $1's lines for `health --robot`.
write_services_stub() {
    mkdir -p "$WORK/stub-lib"
    printf '%s\n' "$1" > "$WORK/stub-lib/health.out"
    cat > "$WORK/stub-lib/acfs-services.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "health --robot" ]] || exit 2
cat "$(dirname "$0")/health.out"
exit 1
EOF
}

# Run check_service_units with doctor's functions loaded; prints each check
# as "id|status|details|fix". $1 is the directory acfs-services.sh is in.
run_check() {
    local lib_dir="$1"
    env -u XDG_CONFIG_HOME STUB_LIB_DIR="$lib_dir" HOME="${RUN_HOME:-$WORK/home}" bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        _acfs_doctor_find_lib_script() { [[ -e "$STUB_LIB_DIR/$1" ]] && printf "%s\n" "$STUB_LIB_DIR/$1"; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_service_units 2>/dev/null || echo "check_service_units exited $?"
    ' _ "$DOCTOR"
}
mkdir -p "$WORK/home"

echo "services.unit"

write_services_stub "agent-mail|disabled|acfs-agent-mail.service is not enabled
cm|ok|acfs-cm.service is running
cass|failed|acfs-cass-index.service has failed (result exit-code, last exit status 14, 5 automatic restarts); systemd will not start it again by itself"
out="$(run_check "$WORK/stub-lib")"
[[ "$out" == "services.unit.cass|fail|acfs-cass-index.service has failed (result exit-code, last exit status 14, 5 automatic restarts); systemd will not start it again by itself|acfs services repair cass" ]] \
    && pass "a failed cass unit fails, naming the repair; ok and disabled units are no finding" \
    || fail "a failed cass unit fails, naming the repair; ok and disabled units are no finding" "$out"

write_services_stub "cass|restarting|acfs-cass-index.service exited and waits for its next automatic restart"
out="$(run_check "$WORK/stub-lib")"
[[ "$out" == "services.unit.cass|warn|acfs-cass-index.service exited and waits for its next automatic restart|systemd retries it by itself; see why: acfs services logs cass" ]] \
    && pass "a unit waiting for its next automatic restart warns, naming its logs" \
    || fail "a unit waiting for its next automatic restart warns, naming its logs" "$out"

write_services_stub "cm|stopped|acfs-cm.service is enabled but not running"
out="$(run_check "$WORK/stub-lib")"
[[ "$out" == "services.unit.cm|warn|acfs-cm.service is enabled but not running|acfs services repair cm" ]] \
    && pass "an enabled unit that is not running warns, naming the repair" \
    || fail "an enabled unit that is not running warns, naming the repair" "$out"

write_services_stub "cass|outdated|acfs-cass-index.service runs on older settings than 'acfs services start' writes now"
out="$(run_check "$WORK/stub-lib")"
[[ "$out" == "services.unit.cass|warn|acfs-cass-index.service runs on older settings than 'acfs services start' writes now|acfs services restart cass" ]] \
    && pass "a unit on older settings warns, naming the restart that applies them" \
    || fail "a unit on older settings warns, naming the restart that applies them" "$out"

write_services_stub "agent-mail|not-set-up|no acfs-agent-mail.service
cm|changing|acfs-cm.service is starting
cass|unknown|no systemd user manager is reachable
odd name|failed|not a service name"
out="$(run_check "$WORK/stub-lib")"
[[ -z "$out" ]] \
    && pass "no unit set up, a unit starting, no systemd and a malformed line are no finding" \
    || fail "no unit set up, a unit starting, no systemd and a malformed line are no finding" "$out"

out="$(run_check "$WORK/no-lib")"
[[ -z "$out" ]] \
    && pass "a runtime without acfs-services.sh has no finding" \
    || fail "a runtime without acfs-services.sh has no finding" "$out"

grep -A1 -x '    check_service_binary_drift' "$DOCTOR" | grep -qx '    check_service_units' \
    && pass "the doctor runs check_service_units after the drift check" \
    || fail "the doctor runs check_service_units after the drift check"

# The real acfs-services.sh, with a cass unit that systemd gave up on. The
# stub directory must be private to this user, or the script ignores it.
SYSBIN="$WORK/sysbin"
mkdir -p "$SYSBIN" "$WORK/real-home/.config/systemd/user" "$WORK/real-lib"
cat > "$SYSBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
    show-environment) echo "HOME=$HOME" ;;
    show)
        [[ "${2:-}" == "acfs-cass-index.service" ]] || exit 0
        printf '%s\n' ActiveState=failed SubState=failed UnitFileState=enabled \
            Result=start-limit-hit NRestarts=7 ExecMainStatus=14 ;;
    *) exit 1 ;;
esac
EOF
chmod 700 "$SYSBIN"
chmod 755 "$SYSBIN/systemctl"
printf '[Unit]\nDescription=old\n' > "$WORK/real-home/.config/systemd/user/acfs-cass-index.service"
cp "$SERVICES" "$WORK/real-lib/acfs-services.sh"
out="$(ACFS_SERVICES_SYSTEM_BIN_PREFIX="$SYSBIN" RUN_HOME="$WORK/real-home" run_check "$WORK/real-lib")"
[[ "$out" == "services.unit.cass|fail|acfs-cass-index.service has failed (result start-limit-hit, last exit status 14, 7 automatic restarts); systemd will not start it again by itself|acfs services repair cass" ]] \
    && pass "with the real acfs-services.sh, a cass unit at its start limit fails" \
    || fail "with the real acfs-services.sh, a cass unit at its start limit fails" "$out"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
