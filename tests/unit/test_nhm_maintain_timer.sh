#!/usr/bin/env bash
# ============================================================
# The nhm maintain timer (acfs-9hkh.39): scripts/lib/nhm_maintain_timer.sh,
# install.sh's acfs_install_nhm_maintain_timer, update.sh's
# update_nhm_maintain_timer and doctor's stack.nhm.maintain check.
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
while [[ "\$1" == --user || "\$1" == --machine=* ]]; do shift; done
[[ -n "\${FAKE_SYSTEMD_DOWN:-}" ]] && exit 1
case "\$1" in
    show-environment|daemon-reload) exit 0 ;;
    is-enabled) state="\$(cat "$SYSD/state" 2>/dev/null)"; state="\${state:-disabled}"; echo "\$state"; [[ "\$state" == enabled ]] ;;
    is-active) [[ "\$(cat "$SYSD/state" 2>/dev/null)" == enabled ]] ;;
    enable) echo enabled >"$SYSD/state" ;;
    disable) echo disabled >"$SYSD/state" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/systemctl"

# fixture <nhm: maintain|old|none> [state] [enrolled: yes|no]: a fresh home.
fixture() {
    HOMEDIR="$(mktemp -d -p "$ROOT")"
    SOCK="$HOMEDIR/.config/herdr/herdr.sock"
    mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/.acfs/scripts/lib" "$HOMEDIR/.config/herdr"
    cp "$HELPER" "$HOMEDIR/.acfs/scripts/lib/"
    : >"$SYSD/calls"
    if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >"$SYSD/state"; else : >"$SYSD/state"; fi
    if [[ "${3:-yes}" == yes ]]; then
        mkdir -p "$HOMEDIR/.local/state/nhm/inst-0123456789ab"
        printf 'id = "inst-0123456789ab"\nsession = "default"\nsocket_path = "%s"\nenrolled_at = 2026-10-12T14:00:00Z\n' \
            "$SOCK" >"$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
    fi
    case "$1" in
        maintain)
            printf '#!/bin/sh\nif [ "$1 $2" = "maintain --help" ]; then echo "Usage: nhm maintain [--once]" >&2; exit 2; fi\necho "$*" >>"%s/ran"\n' \
                "$HOMEDIR" >"$HOMEDIR/.local/bin/nhm" ;;
        old) printf '#!/bin/sh\necho "nhm: unknown command \\"$1\\"" >&2\nexit 2\n' >"$HOMEDIR/.local/bin/nhm" ;;
    esac
    [[ "$1" == none ]] || chmod +x "$HOMEDIR/.local/bin/nhm"
}

helper() { # helper <args...>: run the home's ACFS copy of the helper, as install does; sets OUT and RC
    RC=0
    OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_STATE_HOME="" NHM_BIN_DIR="" \
        NHM_TIMER_SYSTEMCTL_MACHINE="" bash "$HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh" "$@" 2>&1)" || RC=$?
}

UNITS() { printf '%s/.config/systemd/user\n' "$HOMEDIR"; }
calls() { cat "$SYSD/calls"; }
mksock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }

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

# Review (a): a unit for a server nhm is not enrolled for would fail every
# 15 s; install enables nothing.
fixture maintain "" no
helper install
check "not enrolled: exit 6, nothing written" test "$RC" -eq 6 -a ! -e "$(UNITS)/nhm-maintain.timer"
check "it names the enroll command" has "nhm admin instance enroll --session default"

fixture maintain
helper install
check "install: exit 0" test "$RC" -eq 0
check "it writes both units" test -f "$(UNITS)/nhm-maintain.service" -a -f "$(UNITS)/nhm-maintain.timer"
OUT="$(calls)"
check "it reloads and enables the timer" bash -c '[[ "$1" == *"--user daemon-reload"*"--user enable --now nhm-maintain.timer"* ]]' _ "$OUT"
OUT="$(cat "$(UNITS)/nhm-maintain.service")"
check "the service runs this home's nhm, once, on the default server's socket" \
    has "ExecStart=$HOMEDIR/.local/bin/nhm maintain --once --socket $SOCK"
check "its condition is the helper's ready with absolute paths" \
    has "ExecCondition=/bin/bash $HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh ready $HOMEDIR/.local/bin/nhm $SOCK $HOMEDIR/.local/state/nhm"
check "the service keeps only warnings in the journal" has "LogLevelMax=warning"
OUT="$(cat "$(UNITS)/nhm-maintain.timer")"
check "the timer fires every 15 s" has "OnCalendar=*:*:0/15"

: >"$SYSD/calls"
helper install
OUT="$(calls)"
check "a second install: exit 0, no reload for unchanged units" \
    bash -c '[[ "$2" -eq 0 && "$1" != *daemon-reload* && "$1" == *"enable --now"* ]]' _ "$OUT" "$RC"

# A stale unit of ACFS's own (its header kept) is rewritten.
printf '%s\nstale\n' "# Written by ACFS (scripts/lib/nhm_maintain_timer.sh); a drop-in changes it." >"$(UNITS)/nhm-maintain.timer"
: >"$SYSD/calls"
helper install
OUT="$(calls)"
check "a changed unit is rewritten and reloaded" \
    bash -c '[[ "$1" == *daemon-reload* ]] && grep -q OnCalendar "$2"' _ "$OUT" "$(UNITS)/nhm-maintain.timer"

# A downgrade to an nhm without maintain removes the units it cannot run.
printf '#!/bin/sh\necho "nhm: unknown command" >&2\nexit 2\n' >"$HOMEDIR/.local/bin/nhm"
helper install
check "an older nhm after a newer one: exit 3, the units are removed" \
    test "$RC" -eq 3 -a ! -e "$(UNITS)/nhm-maintain.timer" -a ! -e "$(UNITS)/nhm-maintain.service"

fixture maintain masked
helper install
check "a masked timer: exit 5, nothing written, never enabled" \
    bash -c '[[ "$1" -eq 5 && ! -e "$2" ]] && ! grep -q "enable --now" "$3"' _ "$RC" "$(UNITS)/nhm-maintain.timer" "$SYSD/calls"

fixture maintain
mkdir -p "$ROOT/with space/bin"
cp "$HOMEDIR/.local/bin/nhm" "$ROOT/with space/bin/nhm"
RC=0
OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_STATE_HOME="" NHM_BIN_DIR="$ROOT/with space/bin" \
    bash "$HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh" install 2>&1)" || RC=$?
check "an nhm path that a unit cannot hold: exit 1, nothing written" test "$RC" -eq 1 -a ! -e "$(UNITS)/nhm-maintain.service"

helper install extra
check "a usage error: exit 64" test "$RC" -eq 64

echo
echo "remove"

# Review (b): without nhm, or with stack.nhm not selected, the units go.
fixture maintain
helper install
: >"$SYSD/calls"
helper remove
OUT="$(calls)"
check "remove disables the timer and deletes both units" \
    bash -c '[[ "$1" == *"disable --now nhm-maintain.timer"*"daemon-reload"* && ! -e "$2/nhm-maintain.timer" && ! -e "$2/nhm-maintain.service" ]]' \
    _ "$OUT" "$(UNITS)"
helper remove
check "a second remove: exit 0, nothing to do" test "$RC" -eq 0

fixture maintain masked
mkdir -p "$(UNITS)"
ln -s /dev/null "$(UNITS)/nhm-maintain.timer"
printf '[Service]\nExecStart=/bin/true\n' >"$(UNITS)/nhm-maintain.service"
helper remove
check "remove keeps a mask and a unit the user wrote" \
    test -L "$(UNITS)/nhm-maintain.timer" -a -f "$(UNITS)/nhm-maintain.service"

fixture maintain
helper install
FAKE_SYSTEMD_DOWN=1 helper remove
check "remove without a user manager still deletes ACFS's units" test ! -e "$(UNITS)/nhm-maintain.timer"

echo
echo "ready (the ExecCondition)"

fixture maintain
helper install
cond="$(sed -n 's/^ExecCondition=//p' "$(UNITS)/nhm-maintain.service")"
read -r -a cond_argv <<<"$cond"
RC=0; "${cond_argv[@]}" >/dev/null 2>&1 || RC=$?
check "no herdr socket: skip (exit 1, not a failure)" test "$RC" -eq 1
mksock "$SOCK"
RC=0; "${cond_argv[@]}" >/dev/null 2>&1 || RC=$?
check "socket and enrolment: run (exit 0)" test "$RC" -eq 0
exec_line="$(sed -n 's/^ExecStart=//p' "$(UNITS)/nhm-maintain.service")"
read -r -a exec_argv <<<"$exec_line"
"${exec_argv[@]}"
OUT="$(cat "$HOMEDIR/ran" 2>/dev/null)"
check "then nhm runs one pass on the socket" test "$OUT" = "maintain --once --socket $SOCK"
mv "$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml" "$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml.gone"
RC=0; "${cond_argv[@]}" >/dev/null 2>&1 || RC=$?
check "enrolment gone: skip" test "$RC" -eq 1
mv "$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml.gone" "$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
mv "$HOMEDIR/.local/bin/nhm" "$HOMEDIR/.local/bin/nhm.gone"
RC=0; "${cond_argv[@]}" >/dev/null 2>&1 || RC=$?
check "nhm gone: skip" test "$RC" -eq 1
mv "$HOMEDIR/.local/bin/nhm.gone" "$HOMEDIR/.local/bin/nhm"
helper ready only-two args
check "ready with the wrong arguments: exit 64 (a skip for systemd)" test "$RC" -eq 64

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
rm -f "$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
helper status
check "enabled but no longer enrolled: not-enrolled, exit 6" test "$RC" -eq 6 -a "$OUT" = not-enrolled
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
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME XDG_STATE_HOME NHM_BIN_DIR NHM_TIMER_SYSTEMCTL_MACHINE
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/update.sh" >/dev/null 2>&1
        INSTALLED=" $* "
        # NHM_AT puts the installed nhm somewhere other than ~/.local/bin.
        update_binary_path() { [[ "$INSTALLED" == *" $1 "* ]] && printf '%s\n' "${NHM_AT:-$HOMEDIR/.local/bin/$1}"; }
        update_binary_exists() { update_binary_path "$1" >/dev/null; }
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
READ_ONLY=1 run_update nhm
check "dry-run: says what it would do, writes nothing" \
    bash -c '[[ "$1" == *"ITEM skip|nhm maintain timer|dry-run: would install"* && ! -e "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"
SAME_USER=0 run_update nhm
check "another user: warns with the command" has "ITEM warn|nhm maintain timer|run as ubuntu: bash $HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh install"
run_update nhm
check "installs and enables the timer" \
    bash -c '[[ "$1" == *"ITEM ok|nhm maintain timer|"*"RC 0"* && -f "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"
run_update
check "nhm gone: the timer is removed" \
    bash -c '[[ "$1" == *"ITEM skip|nhm maintain timer|nhm is not installed; ACFS'"'"'s nhm-maintain.timer is removed"* && ! -e "$2" ]]' \
    _ "$OUT" "$(UNITS)/nhm-maintain.timer"
# acfs-9hkh.84: an nhm that update finds outside ~/.local/bin is the one
# the helper checks and the service runs.
fixture maintain
mkdir -p "$HOMEDIR/opt/bin"
mv "$HOMEDIR/.local/bin/nhm" "$HOMEDIR/opt/bin/nhm"
NHM_AT="$HOMEDIR/opt/bin/nhm" run_update nhm
check "an nhm outside ~/.local/bin: installs, and the service runs that nhm" \
    bash -c '[[ "$1" == *"ITEM ok|nhm maintain timer|"*"RC 0"* ]] && grep -qF "ExecStart=$3 maintain --once" "$2"' \
    _ "$OUT" "$(UNITS)/nhm-maintain.service" "$HOMEDIR/opt/bin/nhm"
fixture old
run_update nhm
check "an nhm without maintain: skip, never a failure" \
    bash -c '[[ "$1" == *"ITEM skip|nhm maintain timer|this nhm has no"*"RC 0"* ]]' _ "$OUT"
fixture maintain masked
run_update nhm
check "a masked timer: skip" has "ITEM skip|nhm maintain timer|nhm-maintain.timer is masked"
fixture maintain "" no
run_update nhm
check "not enrolled: warn with the enroll command" has "ITEM warn|nhm maintain timer|nhm is not enrolled"

echo
echo "install.sh: acfs_install_nhm_maintain_timer"

# run_install <selected: yes|no>: the function from install.sh, with the
# installer's helpers stubbed; the target user is the caller.
run_install() {
    OUT="$(
        export HOME="$HOMEDIR" PATH="$FAKEBIN:$PATH" ACFS_HOME="$HOMEDIR/.acfs" TARGET_USER=ubuntu
        unset XDG_CONFIG_HOME XDG_STATE_HOME NHM_BIN_DIR NHM_TIMER_SYSTEMCTL_MACHINE
        SELECTED="$1"
        run_as_target() { "$@"; }
        acfs_legacy_module_selected() { [[ "$1" == stack.nhm && "$SELECTED" == yes ]]; }
        log_detail() { printf 'DETAIL %s\n' "$1"; }
        log_warn() { printf 'WARN %s\n' "$1"; }
        # shellcheck source=/dev/null
        source <(sed -n '/^acfs_install_nhm_maintain_timer() {/,/^}/p' "$REPO_ROOT/install.sh")
        acfs_install_nhm_maintain_timer 2>&1
        printf 'RC %s\n' "$?"
    )"
}

[[ -n "$(sed -n '/^acfs_install_nhm_maintain_timer() {/,/^}/p' "$REPO_ROOT/install.sh")" ]] \
    || { echo "install.sh has no acfs_install_nhm_maintain_timer" >&2; exit 1; }
fixture maintain
run_install yes
check "selected, nhm with maintain, enrolled: enabled" \
    bash -c '[[ "$1" == *"DETAIL nhm-maintain.timer runs"* && -f "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"
run_install no
check "stack.nhm not selected: the timer is removed" test ! -e "$(UNITS)/nhm-maintain.timer"
run_install yes
rm -f "$HOMEDIR/.local/bin/nhm"
run_install yes
check "nhm missing: the timer is removed" \
    bash -c '[[ "$1" == *"RC 0"* && ! -e "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"
fixture maintain "" no
run_install yes
check "not enrolled: a note, no timer, never a failure" \
    bash -c '[[ "$1" == *"DETAIL nhm-maintain.timer not enabled"*"RC 0"* && ! -e "$2" ]]' _ "$OUT" "$(UNITS)/nhm-maintain.timer"

echo
echo "doctor: stack.nhm.maintain"

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
# run_doctor [nhm present: true|false]: prints "id|status|details|fix".
# DOCTOR_TARGET: a TARGET_USER other than the caller.
run_doctor() {
    PATH="$FAKEBIN:$PATH" STUB_HOME="$HOMEDIR" STUB_NHM="${1:-true}" TARGET_USER="${DOCTOR_TARGET:-}" \
        XDG_CONFIG_HOME="" XDG_STATE_HOME="" bash -c '
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
: >"$SYSD/calls"
OUT="$(DOCTOR_TARGET=someoneelse run_doctor)"
check "run as another user, it asks that user's manager (--machine)" \
    bash -c '[[ "$1" == *"stack.nhm.maintain|pass|"* ]] && grep -q -- "--machine=someoneelse@.host --user is-enabled" "$2"' _ "$OUT" "$SYSD/calls"
rm -f "$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
OUT="$(run_doctor)"
check "enabled but not enrolled: warn with the enroll command" \
    bash -c '[[ "$1" == "stack.nhm.maintain|warn|"*"not enrolled"*"|Run: nhm admin instance enroll --session default" ]]' _ "$OUT"
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
echo "acfs-9hkh.84: the timer lows (BlueLake)"

# Paths are cleaned as nhm cleans them: a trailing or doubled "/" in
# XDG_STATE_HOME, or in the enrolled socket path, still matches.
fixture maintain "" no
mkdir -p "$HOMEDIR/.local/state/nhm/inst-0123456789ab"
printf 'id = "inst-0123456789ab"\nsession = "default"\nsocket_path = "%s"\n' "$HOMEDIR/.config//herdr/./herdr.sock" \
    >"$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
RC=0
OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_STATE_HOME="$HOMEDIR/.local/state/" NHM_BIN_DIR="" \
    NHM_TIMER_SYSTEMCTL_MACHINE="" bash "$HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh" install 2>&1)" || RC=$?
check "a trailing / in XDG_STATE_HOME and a doubled / in the enrolled socket: enabled" test "$RC" -eq 0
OUT="$(cat "$(UNITS)/nhm-maintain.service" 2>/dev/null)"
check "the unit names the clean socket and state root" \
    has "ready $HOMEDIR/.local/bin/nhm $HOMEDIR/.config/herdr/herdr.sock $HOMEDIR/.local/state/nhm"

# The socket is the one nhm enrolled as session "default", not one built
# from today's XDG_CONFIG_HOME.
fixture maintain "" no
mkdir -p "$HOMEDIR/.local/state/nhm/inst-0123456789ab" "$HOMEDIR/elsewhere"
printf 'id = "inst-0123456789ab"\nsession = "default"\nsocket_path = "%s"\n' "$HOMEDIR/elsewhere/herdr.sock" \
    >"$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
RC=0
OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="$HOMEDIR/other-config" XDG_STATE_HOME="" NHM_BIN_DIR="" \
    NHM_TIMER_SYSTEMCTL_MACHINE="" bash "$HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh" install 2>&1)" || RC=$?
check "an XDG_CONFIG_HOME that differs from the enrolment's: the enrolled socket is used" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q -- "--socket $2/elsewhere/herdr.sock" "$3"' _ "$RC" "$HOMEDIR" \
    "$HOMEDIR/other-config/systemd/user/nhm-maintain.service"
fixture maintain "" no
mkdir -p "$HOMEDIR/.local/state/nhm/inst-0123456789ab"
printf 'id = "inst-0123456789ab"\nsession = "work"\nsocket_path = "%s"\n' "$SOCK" \
    >"$HOMEDIR/.local/state/nhm/inst-0123456789ab/instance.toml"
helper install
check "only a server enrolled as another session: exit 6" test "$RC" -eq 6 -a ! -e "$(UNITS)/nhm-maintain.timer"

# A unit of the user's own is never overwritten, as remove never deletes it.
fixture maintain
mkdir -p "$(UNITS)"
printf '[Service]\nExecStart=/usr/local/bin/my-nhm-pass\n' >"$(UNITS)/nhm-maintain.service"
helper install
check "a user's own service unit: exit 7, kept, no timer written" \
    bash -c '[[ "$1" -eq 7 && ! -e "$3/nhm-maintain.timer" ]] && grep -q my-nhm-pass "$3/nhm-maintain.service"' _ "$RC" "" "$(UNITS)"
helper status
check "a user's own service only: status says no ACFS timer (missing, exit 1)" test "$RC" -eq 1 -a "$OUT" = missing
fixture maintain
mkdir -p "$(UNITS)"
printf '[Timer]\nOnCalendar=hourly\n' >"$(UNITS)/nhm-maintain.timer"
helper status
check "a user's own timer: status user-unit, exit 7" test "$RC" -eq 7 -a "$OUT" = user-unit
OUT="$(run_doctor)"
check "the doctor skips a user's own units" has "stack.nhm.maintain|skip|nhm-maintain units of your own"

# Without a user manager, remove also drops the enable link that would
# dangle; another link stays.
fixture maintain
helper install
mkdir -p "$(UNITS)/timers.target.wants"
ln -s "$(UNITS)/nhm-maintain.timer" "$(UNITS)/timers.target.wants/nhm-maintain.timer"
ln -s "$(UNITS)/other.timer" "$(UNITS)/timers.target.wants/other.timer"
FAKE_SYSTEMD_DOWN=1 helper remove
check "remove without a user manager drops the dangling enable link" \
    test ! -L "$(UNITS)/timers.target.wants/nhm-maintain.timer" -a -L "$(UNITS)/timers.target.wants/other.timer"

# Run as root for another user, the doctor never runs that user's nhm as
# root: runuser runs it as the target.
fixture maintain
cat >"$FAKEBIN/runuser" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYSD/runuser"
[[ "\$1" == -u && "\$3" == -- ]] || exit 99
shift 3
exec "\$@"
EOF
chmod +x "$FAKEBIN/runuser"
: >"$SYSD/runuser"
OUT="$(PATH="$FAKEBIN:$PATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_STATE_HOME="" NHM_TIMER_SYSTEMCTL_MACHINE="someoneelse@.host" \
    bash -c 'source "$1"; nhm_maintain_timer_has_maintain "$2" && echo yes' _ \
    "$HOMEDIR/.acfs/scripts/lib/nhm_maintain_timer.sh" "$HOMEDIR/.local/bin/nhm" 2>&1)"
if [[ "$EUID" -eq 0 ]]; then
    check "as root for another user, nhm runs through runuser -u <target>" \
        bash -c '[[ "$1" == yes ]] && grep -q -- "-u someoneelse -- " "$2"' _ "$OUT" "$SYSD/runuser"
else
    check "not root: nhm runs directly, without runuser" bash -c '[[ "$1" == yes && ! -s "$2" ]]' _ "$OUT" "$SYSD/runuser"
fi
rm -f "$FAKEBIN/runuser"

echo
echo "nhm maintain timer: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
