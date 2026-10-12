#!/usr/bin/env bash
# ============================================================
# The nhm maintain timer (acfs-9hkh.39): scripts/lib/nhm_maintain_timer.sh
# and doctor's stack.nhm.maintain check.
#
# A fake `systemctl` and a fake `nhm` come first on PATH; the units go to
# a fixture home. No real user manager is asked to change anything. When
# systemd-analyze is installed, the rendered units are also checked with
# `systemd-analyze --user verify`, which only reads them.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_nhm_maintain_timer.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/nhm_maintain_timer.sh"
DOCTOR="$REPO_ROOT/scripts/lib/doctor.sh"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}
check() { # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name" "${OUT:-}"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }

ROOT="$(mktemp -d)"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l -o -type s \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# The fake systemctl keeps the timer's state in $SYSD/state and logs each
# call to $SYSD/calls. FAKE_SYSTEMD_DOWN=1: no user manager answers.
FAKEBIN="$ROOT/fakebin"
SYSD="$ROOT/sysd"
mkdir -p "$FAKEBIN" "$SYSD"
cat >"$FAKEBIN/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYSD/calls"
[[ "\$1" == --user ]] && shift
[[ -n "\${FAKE_SYSTEMD_DOWN:-}" ]] && exit 1
case "\$1" in
    show-environment|daemon-reload) exit 0 ;;
    is-enabled) state="\$(cat "$SYSD/state" 2>/dev/null || echo disabled)"; echo "\$state"; [[ "\$state" == enabled ]] ;;
    is-active) [[ "\$(cat "$SYSD/state" 2>/dev/null)" == enabled ]] ;;
    enable) echo enabled >"$SYSD/state" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/systemctl"

# fixture <nhm: maintain|old|none> [state]: a fresh home with that nhm.
fixture() {
    HOMEDIR="$(mktemp -d -p "$ROOT")"
    mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/.acfs/scripts/lib"
    cp "$HELPER" "$HOMEDIR/.acfs/scripts/lib/"
    : >"$SYSD/calls"
    if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >"$SYSD/state"; else : >"$SYSD/state"; fi
    case "$1" in
        maintain)
            printf '#!/bin/sh\nif [ "$1 $2" = "maintain --help" ]; then echo "Usage: nhm maintain [--once]" >&2; exit 2; fi\necho "$*" >>"%s/ran"\n' \
                "$HOMEDIR" >"$HOMEDIR/.local/bin/nhm" ;;
        old) printf '#!/bin/sh\necho "nhm: unknown command \\"$1\\"" >&2\nexit 2\n' >"$HOMEDIR/.local/bin/nhm" ;;
    esac
    [[ "$1" == none ]] || chmod +x "$HOMEDIR/.local/bin/nhm"
}

helper() { # helper <args...>: run the helper as the fixture user; sets OUT and RC
    RC=0
    OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" NHM_BIN_DIR="" bash "$HELPER" "$@" 2>&1)" || RC=$?
}

UNITS() { printf '%s/.config/systemd/user\n' "$HOMEDIR"; }

echo "install"

fixture old
helper install
check "an nhm without maintain: exit 3, nothing written" test "$RC" -eq 3 -a ! -e "$(UNITS)/nhm-maintain.timer"
check "it says the next nhm update installs the timer" has "next nhm update"

fixture none
helper install
check "no nhm: exit 3" test "$RC" -eq 3

fixture maintain
FAKE_SYSTEMD_DOWN=1 helper install
check "no user manager: exit 4, nothing written" test "$RC" -eq 4 -a ! -e "$(UNITS)/nhm-maintain.timer"
check "it names the other runners" has "nhm maintain --loop"

fixture maintain
helper install
check "install: exit 0" test "$RC" -eq 0
check "it writes both units" test -f "$(UNITS)/nhm-maintain.service" -a -f "$(UNITS)/nhm-maintain.timer"
OUT="$(cat "$SYSD/calls")"
check "it reloads and enables the timer" bash -c '[[ "$1" == *"--user daemon-reload"*"--user enable --now nhm-maintain.timer"* ]]' _ "$OUT"
OUT="$(cat "$(UNITS)/nhm-maintain.service")"
check "the service runs this home's nhm, once, on the default server's socket" \
    has "' $HOMEDIR/.local/bin/nhm %E/herdr/herdr.sock"
check "the service keeps only warnings in the journal" has "LogLevelMax=warning"
OUT="$(cat "$(UNITS)/nhm-maintain.timer")"
check "the timer fires every 15 s" has "OnCalendar=*:*:0/15"

: >"$SYSD/calls"
helper install
OUT="$(cat "$SYSD/calls")"
check "a second install: exit 0, no reload for unchanged units" \
    bash -c '[[ "$2" -eq 0 && "$1" != *daemon-reload* && "$1" == *"enable --now"* ]]' _ "$OUT" "$RC"

printf 'stale\n' >"$(UNITS)/nhm-maintain.timer"
: >"$SYSD/calls"
helper install
OUT="$(cat "$SYSD/calls")"
check "a changed unit is rewritten and reloaded" \
    bash -c '[[ "$1" == *daemon-reload* ]] && grep -q OnCalendar "$2"' _ "$OUT" "$(UNITS)/nhm-maintain.timer"

fixture maintain masked
helper install
check "a masked timer: exit 5, nothing written, never enabled" \
    bash -c '[[ "$1" -eq 5 && ! -e "$2" ]] && ! grep -q "enable --now" "$3"' _ "$RC" "$(UNITS)/nhm-maintain.timer" "$SYSD/calls"

fixture maintain
mkdir -p "$ROOT/with space/bin"
cp "$HOMEDIR/.local/bin/nhm" "$ROOT/with space/bin/nhm"
RC=0
OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" NHM_BIN_DIR="$ROOT/with space/bin" bash "$HELPER" install 2>&1)" || RC=$?
check "an nhm path that a unit cannot hold: exit 1, nothing written" test "$RC" -eq 1 -a ! -e "$(UNITS)/nhm-maintain.service"

helper install extra
check "a usage error: exit 64" test "$RC" -eq 64

echo
echo "the unit's command"

# ExecStart as /bin/sh gets it: systemd turns \$\$ into \$ and %E into the
# config root.
fixture maintain
helper install
exec_line="$(sed -n 's/^ExecStart=//p' "$(UNITS)/nhm-maintain.service")"
script="$(sed -e "s/^\/bin\/sh -c '\\(.*\\)' .*/\\1/" -e 's/\$\$/$/g' <<<"$exec_line")"
sock="$ROOT/herdr.sock"
/bin/sh -c "$script" "$HOMEDIR/.local/bin/nhm" "$sock"
check "no herdr socket: exit 0, nhm not run" test $? -eq 0 -a ! -e "$HOMEDIR/ran"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
/bin/sh -c "$script" "$HOMEDIR/.local/bin/nhm" "$sock"
OUT="$(cat "$HOMEDIR/ran" 2>/dev/null)"
check "with the socket, nhm runs one pass on it" test "$OUT" = "maintain --once --socket $sock"

if command -v systemd-analyze >/dev/null 2>&1; then
    OUT="$(systemd-analyze --user verify "$(UNITS)/nhm-maintain.service" "$(UNITS)/nhm-maintain.timer" 2>&1)"
    check "systemd-analyze verifies both units" test $? -eq 0
else
    echo "SKIP: systemd-analyze is not installed"
fi

echo
echo "status"

fixture old
helper status
check "an nhm without maintain: no-maintain, exit 3" test "$RC" -eq 3 -a "$OUT" = no-maintain
fixture maintain
helper status
check "no timer: missing, exit 1" test "$RC" -eq 1 -a "$OUT" = missing
helper install
helper status
check "after install: enabled, exit 0" test "$RC" -eq 0 -a "$OUT" = enabled
FAKE_SYSTEMD_DOWN=1 helper status
check "a unit file but no user manager: unit-exists, exit 2" test "$RC" -eq 2 -a "$OUT" = unit-exists
fixture maintain masked
helper status
check "masked: exit 5" test "$RC" -eq 5 -a "$OUT" = masked

echo
echo "update_nhm_maintain_timer"

# run_update [installed binaries...]: update.sh's function against the
# fixture home, with update.sh's host helpers stubbed as in
# test_update_nhm.sh. Env: SAME_USER (default 1), READ_ONLY.
run_update() {
    OUT="$(
        export HOME="$HOMEDIR" UPDATE_LOG_FILE="$ROOT/update.log" PATH="$FAKEBIN:$PATH"
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME NHM_BIN_DIR
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/update.sh" >/dev/null 2>&1
        INSTALLED=" $* "
        update_binary_exists() { [[ "$INSTALLED" == *" $1 "* ]]; }
        update_runtime_acfs_home() { printf '%s\n' "$HOMEDIR/.acfs"; }
        update_target_user() { printf 'ubuntu\n'; }
        update_current_user() { if [[ "${SAME_USER:-1}" == 1 ]]; then printf 'ubuntu\n'; else printf 'root\n'; fi; }
        update_is_read_only_mode() { [[ -n "${READ_ONLY:-}" ]]; }
        log_item() { printf 'ITEM %s|%s|%s\n' "$1" "$2" "${3:-}"; }
        UPDATE_STACK=true
        update_nhm_maintain_timer
        printf 'RC %s\n' "$?"
    )"
}

fixture maintain
run_update
check "no nhm: skip" has "ITEM skip|nhm maintain timer|nhm is not installed"
READ_ONLY=1 run_update nhm
check "dry-run: says what it would do, writes nothing" \
    bash -c '[[ "$1" == *"ITEM skip|nhm maintain timer|dry-run"* && ! -e "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"
SAME_USER=0 run_update nhm
check "another user: warns with the command" has "ITEM warn|nhm maintain timer|run as ubuntu: bash $HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh install"
run_update nhm
check "installs and enables the timer" \
    bash -c '[[ "$1" == *"ITEM ok|nhm maintain timer|"*"RC 0"* && -f "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"
fixture old
run_update nhm
check "an nhm without maintain: skip, never a failure" \
    bash -c '[[ "$1" == *"ITEM skip|nhm maintain timer|this nhm has no"*"RC 0"* ]]' _ "$OUT"
fixture maintain masked
run_update nhm
check "a masked timer: skip" has "ITEM skip|nhm maintain timer|nhm-maintain.timer is masked"

echo
echo "doctor: stack.nhm.maintain"

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
# run_doctor [nhm present: true|false]: prints "id|status|details|fix".
run_doctor() {
    PATH="$FAKEBIN:$PATH" STUB_HOME="$HOMEDIR" STUB_NHM="${1:-true}" bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$STUB_HOME"; }
        doctor_binary_exists() { [[ "$1" == nhm && "$STUB_NHM" == true ]]; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_nhm_maintain
    ' _ "$DOCTOR"
}

fixture maintain
OUT="$(run_doctor false)"
check "no nhm: skip" has "stack.nhm.maintain|skip|"
OUT="$(run_doctor)"
check "no timer: warn, the other runners, and the install command" \
    bash -c '[[ "$1" == "stack.nhm.maintain|warn|"*"nhm maintain --loop"*"|"*"nhm_maintain_timer.sh install"* ]]' _ "$OUT"
helper install
OUT="$(run_doctor)"
check "an enabled timer passes" has "stack.nhm.maintain|pass|"
fixture old
OUT="$(run_doctor)"
check "an nhm without maintain: skip, the next update adds it" \
    bash -c '[[ "$1" == "stack.nhm.maintain|skip|"*"next nhm update"* ]]' _ "$OUT"
fixture maintain
rm -f "$HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh"
OUT="$(run_doctor)"
check "no helper: warn, acfs update" bash -c '[[ "$1" == "stack.nhm.maintain|warn|"*"acfs update"* ]]' _ "$OUT"
fixture maintain masked
OUT="$(run_doctor)"
check "a masked timer is the operator's opt-out: skip" has "stack.nhm.maintain|skip|"
fixture maintain
before="$(find "$HOMEDIR" -type f | sort)"
run_doctor >/dev/null
check "the check writes nothing" test "$(find "$HOMEDIR" -type f | sort)" = "$before"

echo
echo "nhm maintain timer: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
