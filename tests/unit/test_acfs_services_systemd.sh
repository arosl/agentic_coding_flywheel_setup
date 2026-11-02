#!/usr/bin/env bash
# ============================================================
# acfs services on systemd user units (acfs-rr2).
#
# Runs scripts/lib/acfs-services.sh against stub systemctl, journalctl,
# curl, lsof and tmux (through ACFS_SERVICES_SYSTEM_BIN_PREFIX) and stub
# cm, cass and am binaries. The stubs keep unit state in files; nothing
# here reaches the host's real user service manager, and the test stops
# before any command if the script would resolve the real systemctl.
#
# Run with: bash tests/unit/test_acfs_services_systemd.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
SERVICES_SH="$REPO_ROOT/scripts/lib/acfs-services.sh"

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}

ROOT="$(mktemp -d)"
SYSBIN="$ROOT/sysbin"
STATE="$ROOT/state"
cleanup() {
    # Only files this test created under its own mktemp directory.
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# ------------------------------------------------------------
# Stubs
# ------------------------------------------------------------
mkdir -p "$SYSBIN" "$STATE"

cat > "$SYSBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Stub systemctl --user: unit state lives in $STUB_STATE.
printf 'systemctl %s\n' "$*" >> "$STUB_STATE/calls"
[[ "${1:-}" == "--user" ]] && shift
cmd="${1:-}"; shift || true
mkdir -p "$STUB_STATE/active" "$STUB_STATE/enabled"
case "$cmd" in
    show-environment)
        [[ -e "$STUB_STATE/no-systemd" ]] && exit 1
        echo "HOME=$HOME" ;;
    show)
        unit="$1"; shift
        if [[ " $* " == *" --value "* ]]; then
            case "${2:-}" in
                LoadState) [[ -e "$STUB_STATE/loaded-$unit" ]] && echo loaded || echo not-found ;;
                MainPID)   echo 0 ;;
            esac
            exit 0
        fi
        # "show <unit> -p A -p B": Key=Value lines. A file
        # $STUB_STATE/prop/<unit>.<Key> overrides the value.
        while [[ $# -gt 0 ]]; do
            [[ "$1" == "-p" ]] || { shift; continue; }
            prop="$2"; shift 2
            if [[ -f "$STUB_STATE/prop/$unit.$prop" ]]; then
                value="$(cat "$STUB_STATE/prop/$unit.$prop")"
            else
                case "$prop" in
                    ActiveState)    [[ -e "$STUB_STATE/active/$unit" ]] && value=active || value=inactive ;;
                    SubState)       [[ -e "$STUB_STATE/active/$unit" ]] && value=running || value=dead ;;
                    UnitFileState)  [[ -e "$STUB_STATE/enabled/$unit" ]] && value=enabled || value=disabled ;;
                    Result)         value=success ;;
                    NRestarts|ExecMainStatus) value=0 ;;
                    *)              value="" ;;
                esac
            fi
            printf '%s=%s\n' "$prop" "$value"
        done ;;
    is-active)
        [[ "${1:-}" == "--quiet" ]] && shift
        [[ -e "$STUB_STATE/active/$1" ]] ;;
    is-enabled)
        if [[ -e "$STUB_STATE/enabled/$1" ]]; then echo enabled; else echo disabled; exit 1; fi ;;
    daemon-reload) ;;
    reset-failed)
        # systemd keeps a unit "failed" through stop and disable; only
        # reset-failed clears it. Failed state lives in prop files here.
        for u in "$@"; do
            if grep -qx failed "$STUB_STATE/prop/$u.ActiveState" 2>/dev/null; then
                rm -f "$STUB_STATE/prop/$u".*
            fi
        done ;;
    enable)
        [[ "${1:-}" == "--now" ]] && shift
        [[ -e "$STUB_STATE/fail-start" ]] && exit 1
        for u in "$@"; do touch "$STUB_STATE/active/$u" "$STUB_STATE/enabled/$u"; done ;;
    disable)
        [[ "${1:-}" == "--now" ]] && shift
        for u in "$@"; do rm -f "$STUB_STATE/active/$u" "$STUB_STATE/enabled/$u"; done ;;
    start|restart)
        [[ -e "$STUB_STATE/fail-start" ]] && exit 1
        for u in "$@"; do touch "$STUB_STATE/active/$u"; done ;;
    stop)
        for u in "$@"; do rm -f "$STUB_STATE/active/$u"; done ;;
    *) exit 1 ;;
esac
EOF

cat > "$SYSBIN/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >> "$STUB_STATE/calls"
EOF

# Agent Mail answers when one of its units is active or an external one runs.
cat > "$SYSBIN/curl" <<'EOF'
#!/usr/bin/env bash
if [[ -e "$STUB_STATE/active/agent-mail.service" || -e "$STUB_STATE/active/acfs-agent-mail.service" \
      || -e "$STUB_STATE/am-external" ]]; then
    case "$*" in
        *liveness*) exit 0 ;;
        *) echo '{"status":"ready"}'; exit 0 ;;
    esac
fi
exit 7
EOF

# Port 8766 listens while acfs-cm.service is active; 8765 while Agent Mail is up.
cat > "$SYSBIN/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *:8766*) [[ -e "$STUB_STATE/active/acfs-cm.service" || -e "$STUB_STATE/cm-port-taken" ]] ;;
    *:8765*) [[ -e "$STUB_STATE/active/agent-mail.service" || -e "$STUB_STATE/active/acfs-agent-mail.service" \
               || -e "$STUB_STATE/am-external" ]] ;;
    *) exit 1 ;;
esac
EOF

cat > "$SYSBIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$STUB_STATE/calls"
case "${1:-}" in
    has-session)  [[ -e "$STUB_STATE/tmux-acfs-svc" && "$*" == *"-t acfs-svc"* ]] ;;
    list-panes)
        # The file holds the panes' @acfs_service tags: older ACFS tagged its
        # panes; a user's own session of the same name has empty tags.
        if [[ "$*" == *"@acfs_service"* ]]; then
            cat "$STUB_STATE/tmux-acfs-svc"
        else
            echo "%1"; echo "%2"
        fi ;;
    send-keys)    ;;
    kill-session) [[ "$*" == *"-t acfs-svc"* ]] && rm -f "$STUB_STATE/tmux-acfs-svc" ;;
    *) exit 1 ;;
esac
EOF

HOMEDIR="$ROOT/home"
mkdir -p "$HOMEDIR/.local/bin"
for tool in cm cass am; do
    printf '#!/usr/bin/env bash\necho "%s 1.0.0"\n' "$tool" > "$HOMEDIR/.local/bin/$tool"
done
# The script trusts the stub directory only when group and others cannot write
# it, so set that explicitly rather than inherit the umask.
chmod 755 "$SYSBIN" "$SYSBIN"/* "$HOMEDIR/.local/bin"/*

UNIT_DIR="$HOMEDIR/.config/systemd/user"

# Run acfs-services.sh in the sandbox. Output goes to $OUT, exit code to $RC.
OUT=""
RC=0
svc() {
    OUT="$(env -i HOME="$HOMEDIR" PATH="$HOMEDIR/.local/bin:/usr/bin:/bin" TERM=dumb \
        ACFS_SERVICES_SYSTEM_BIN_PREFIX="$SYSBIN" STUB_STATE="$STATE" \
        ACFS_SVC_SMOKE_TIMEOUT=5 ${EXTRA_ENV:+"$EXTRA_ENV"} \
        bash "$SERVICES_SH" "$@" 2>&1)"
    RC=$?
}

reset_state() {
    find "$STATE" -mindepth 1 \( -type f -o -type l \) -exec rm -f {} +
    find "$UNIT_DIR" -mindepth 1 -type f -exec rm -f {} + 2>/dev/null
    return 0
}

calls() { cat "$STATE/calls" 2>/dev/null; }

# ------------------------------------------------------------
# Guard: the script must resolve the stub systemctl, never the host's.
# ------------------------------------------------------------
resolved="$(env -i HOME="$HOMEDIR" PATH="$HOMEDIR/.local/bin:/usr/bin:/bin" \
    ACFS_SERVICES_SYSTEM_BIN_PREFIX="$SYSBIN" \
    bash -c 'source "$1" --source-test; _initialize_bins; printf "%s|%s|%s" "$_SYSTEMCTL_BIN" "$_CURL_BIN" "$_CM_BIN"' _ "$SERVICES_SH")"
if [[ "$resolved" == "$SYSBIN/systemctl|$SYSBIN/curl|$HOMEDIR/.local/bin/cm" ]]; then
    pass "the script resolves the stub systemctl, curl and cm"
else
    fail "the script resolves the stub systemctl, curl and cm" "$resolved"
    printf '\nRefusing to run further tests: they could reach the real user service manager.\n'
    exit 1
fi

# ------------------------------------------------------------
# start, with no native Agent Mail and none running
# ------------------------------------------------------------
reset_state
svc start
if [[ "$RC" -eq 0 ]]; then
    pass "start succeeds"
else
    fail "start succeeds" "rc=$RC $OUT"
fi

if [[ -f "$UNIT_DIR/acfs-cm.service" && -f "$UNIT_DIR/acfs-cass-index.service" && -f "$UNIT_DIR/acfs-agent-mail.service" ]]; then
    pass "start writes acfs-cm, acfs-cass-index and (no native unit) acfs-agent-mail units"
else
    fail "start writes acfs-cm, acfs-cass-index and (no native unit) acfs-agent-mail units" "$(ls "$UNIT_DIR" 2>&1)"
fi

exec_cm="$(grep '^ExecStart=' "$UNIT_DIR/acfs-cm.service" 2>/dev/null)"
exec_cass="$(grep '^ExecStart=' "$UNIT_DIR/acfs-cass-index.service" 2>/dev/null)"
exec_am="$(grep '^ExecStart=' "$UNIT_DIR/acfs-agent-mail.service" 2>/dev/null)"
if [[ "$exec_cm" == "ExecStart=$HOMEDIR/.local/bin/cm serve --host 127.0.0.1 --port 8766" \
    && "$exec_cass" == "ExecStart=$HOMEDIR/.local/bin/cass index --watch" \
    && "$exec_am" == "ExecStart=$HOMEDIR/.local/bin/am serve-http --no-tui --host 127.0.0.1 --port 8765" ]]; then
    pass "units run the resolved absolute binaries with ACFS's ports"
else
    fail "units run the resolved absolute binaries with ACFS's ports" "$exec_cm | $exec_cass | $exec_am"
fi

if grep -q '^Restart=on-failure$' "$UNIT_DIR/acfs-cm.service" && grep -q '^WantedBy=default.target$' "$UNIT_DIR/acfs-cm.service"; then
    pass "units restart on failure and start with the user manager"
else
    fail "units restart on failure and start with the user manager"
fi

if calls | grep -q '^systemctl --user enable --now acfs-agent-mail.service acfs-cm.service acfs-cass-index.service$'; then
    pass "start enables and starts the three units in one call"
else
    fail "start enables and starts the three units in one call" "$(calls)"
fi

if ! calls | grep -q '^tmux '; then
    pass "start without an old session never runs a tmux command beyond has-session"
else
    if calls | grep '^tmux ' | grep -qv 'has-session'; then
        fail "start without an old session never runs a tmux command beyond has-session" "$(calls | grep '^tmux ')"
    else
        pass "start without an old session never runs a tmux command beyond has-session"
    fi
fi

# A second start changes nothing: no daemon-reload, no restart.
: > "$STATE/calls"
svc start
if [[ "$RC" -eq 0 ]] && ! calls | grep -q -e 'daemon-reload' -e ' restart '; then
    pass "a second start is idempotent: units unchanged, nothing reloaded or restarted"
else
    fail "a second start is idempotent: units unchanged, nothing reloaded or restarted" "rc=$RC $(calls)"
fi

# ------------------------------------------------------------
# start with the native agent-mail.service
# ------------------------------------------------------------
reset_state
touch "$STATE/loaded-agent-mail.service"
svc start
if [[ "$RC" -eq 0 && ! -f "$UNIT_DIR/acfs-agent-mail.service" ]] \
    && calls | grep -q '^systemctl --user start agent-mail.service$' \
    && calls | grep -q '^systemctl --user enable --now acfs-cm.service acfs-cass-index.service$'; then
    pass "with a native agent-mail.service, start uses it and writes no acfs-agent-mail unit"
else
    fail "with a native agent-mail.service, start uses it and writes no acfs-agent-mail unit" "rc=$RC $(calls)"
fi

# A machine that got acfs-agent-mail.service and later the native unit:
# start retires ACFS's unit, so the two never race for 8765 at boot.
reset_state
svc start
touch "$STATE/loaded-agent-mail.service"
: > "$STATE/calls"
svc start
if [[ "$RC" -eq 0 && ! -e "$STATE/active/acfs-agent-mail.service" && ! -e "$STATE/enabled/acfs-agent-mail.service" ]] \
    && calls | grep -q '^systemctl --user disable --now acfs-agent-mail.service$' \
    && calls | grep -q '^systemctl --user start agent-mail.service$'; then
    pass "once a native agent-mail.service exists, start disables acfs-agent-mail.service and uses the native one"
else
    fail "once a native agent-mail.service exists, start disables acfs-agent-mail.service and uses the native one" "rc=$RC $(calls)"
fi
# It may have crash-looped on the native unit's port: retiring it also
# clears its failed state, so health never reports it failed.
if calls | grep -A1 -x 'systemctl --user disable --now acfs-agent-mail.service' \
        | grep -qx 'systemctl --user reset-failed acfs-agent-mail.service'; then
    pass "retiring acfs-agent-mail.service clears its failed state"
else
    fail "retiring acfs-agent-mail.service clears its failed state" "$(calls)"
fi

# acfs-agent-mail.service serving a healthy Agent Mail, but its unit is stale
# (written for another am path): start rewrites it and restarts that unit.
reset_state
svc start
sed -i 's|^ExecStart=.*|ExecStart=/opt/old/am serve-http --no-tui --host 127.0.0.1 --port 8765|' \
    "$UNIT_DIR/acfs-agent-mail.service"
: > "$STATE/calls"
svc start
exec_am="$(grep '^ExecStart=' "$UNIT_DIR/acfs-agent-mail.service")"
if [[ "$RC" -eq 0 && "$exec_am" == "ExecStart=$HOMEDIR/.local/bin/am serve-http"* ]] \
    && calls | grep -q '^systemctl --user restart acfs-agent-mail.service$' \
    && ! calls | grep -q 'restart acfs-cm.service'; then
    pass "start refreshes a stale acfs-agent-mail.service while it serves Agent Mail, and restarts only that unit"
else
    fail "start refreshes a stale acfs-agent-mail.service while it serves Agent Mail, and restarts only that unit" "rc=$RC $exec_am $(calls)"
fi

# ------------------------------------------------------------
# The test hook only trusts a private stub directory
# ------------------------------------------------------------
OPEN_SYSBIN="$ROOT/open-sysbin"
mkdir -p "$OPEN_SYSBIN"
cp "$SYSBIN/systemctl" "$OPEN_SYSBIN/systemctl"
chmod 775 "$OPEN_SYSBIN"
open_resolved="$(env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin" ACFS_SERVICES_SYSTEM_BIN_PREFIX="$OPEN_SYSBIN" \
    bash -c 'source "$1" --source-test; _initialize_bins; printf "%s" "$_SYSTEMCTL_BIN"' _ "$SERVICES_SH")"
if [[ "$open_resolved" != "$OPEN_SYSBIN/systemctl" ]]; then
    pass "a group-writable ACFS_SERVICES_SYSTEM_BIN_PREFIX is ignored"
else
    fail "a group-writable ACFS_SERVICES_SYSTEM_BIN_PREFIX is ignored" "$open_resolved"
fi

# ------------------------------------------------------------
# No systemd user manager: refuse, write nothing
# ------------------------------------------------------------
reset_state
touch "$STATE/no-systemd"
svc start
if [[ "$RC" -ne 0 && "$OUT" == *"needs a systemd user manager"* && ! -e "$UNIT_DIR/acfs-cm.service" ]]; then
    pass "without a systemd user manager, start refuses and writes no unit"
else
    fail "without a systemd user manager, start refuses and writes no unit" "rc=$RC $OUT"
fi

# ------------------------------------------------------------
# Migration from the old tmux session
# ------------------------------------------------------------
reset_state
printf 'cm\ncass\n' > "$STATE/tmux-acfs-svc"
svc start
if [[ "$RC" -eq 0 && ! -e "$STATE/tmux-acfs-svc" ]] && calls | grep -q '^tmux kill-session -t acfs-svc$' \
    && ! calls | grep '^tmux kill-session' | grep -qv -- '-t acfs-svc$'; then
    pass "start stops the old acfs-svc tmux session, and only that session"
else
    fail "start stops the old acfs-svc tmux session, and only that session" "rc=$RC $(calls | grep '^tmux')"
fi

# A user's own session that happens to be named acfs-svc has no tagged pane.
reset_state
printf '\n\n' > "$STATE/tmux-acfs-svc"
svc start
if [[ "$RC" -eq 0 && -e "$STATE/tmux-acfs-svc" ]] && ! calls | grep -q -e '^tmux kill-session' -e '^tmux send-keys'; then
    pass "an untagged session named acfs-svc is not ACFS's and is left alone"
else
    fail "an untagged session named acfs-svc is not ACFS's and is left alone" "rc=$RC $(calls | grep '^tmux')"
fi

# ------------------------------------------------------------
# CM port held by something else
# ------------------------------------------------------------
reset_state
touch "$STATE/cm-port-taken"
svc start
if [[ "$RC" -ne 0 && "$OUT" == *"(CM) is already in use"* ]] && ! calls | grep -q 'enable --now'; then
    pass "start refuses when another process holds CM's port, before enabling anything"
else
    fail "start refuses when another process holds CM's port, before enabling anything" "rc=$RC $OUT"
fi

# ------------------------------------------------------------
# restart one service, repair, stop, logs
# ------------------------------------------------------------
reset_state
svc start
: > "$STATE/calls"
svc restart cass
if [[ "$RC" -eq 0 ]] && calls | grep -q '^systemctl --user restart acfs-cass-index.service$' \
    && ! calls | grep -q -e 'restart acfs-cm' -e 'stop ' -e 'disable'; then
    pass "restart cass restarts only acfs-cass-index.service"
else
    fail "restart cass restarts only acfs-cass-index.service" "rc=$RC $(calls)"
fi

rm -f "$STATE/active/acfs-cass-index.service"
: > "$STATE/calls"
svc repair
if [[ "$RC" -eq 0 ]] && calls | grep -q 'enable --now acfs-cass-index.service$' \
    && ! calls | grep -E '(enable|start|restart|stop|disable)' | grep -q 'acfs-cm.service'; then
    pass "repair starts only the unit that is not running"
else
    fail "repair starts only the unit that is not running" "rc=$RC $(calls)"
fi

svc stop
if [[ "$RC" -eq 0 && ! -e "$STATE/active/acfs-cm.service" && ! -e "$STATE/enabled/acfs-cm.service" \
    && -f "$UNIT_DIR/acfs-cm.service" ]]; then
    pass "stop stops and disables the units and leaves the unit files"
else
    fail "stop stops and disables the units and leaves the unit files" "rc=$RC $OUT"
fi

svc logs cm --dry-run
if [[ "$RC" -eq 0 && "$OUT" == *"journalctl --user -u acfs-cm.service -f"* ]]; then
    pass "logs cm follows acfs-cm.service's journal"
else
    fail "logs cm follows acfs-cm.service's journal" "rc=$RC $OUT"
fi

# ------------------------------------------------------------
# The cass unit's log level and restart policy (acfs-eyvw)
# ------------------------------------------------------------
CASS_UNIT="$UNIT_DIR/acfs-cass-index.service"
CM_UNIT="$UNIT_DIR/acfs-cm.service"
set_prop() { mkdir -p "$STATE/prop"; printf '%s\n' "$3" > "$STATE/prop/$1.$2"; }

reset_state
svc start
if grep -qx 'Environment=RUST_LOG=warn' "$CASS_UNIT" && grep -qx 'StartLimitIntervalSec=0' "$CASS_UNIT" \
    && ! grep -q '^StartLimitBurst=' "$CASS_UNIT" && grep -qx 'Restart=on-failure' "$CASS_UNIT" \
    && grep -qx 'RestartSec=5' "$CASS_UNIT" && grep -qx 'RestartSteps=6' "$CASS_UNIT" \
    && grep -qx 'RestartMaxDelaySec=300' "$CASS_UNIT"; then
    pass "the cass unit logs warnings and errors only, and backs off to 5 min with no start limit"
else
    fail "the cass unit logs warnings and errors only, and backs off to 5 min with no start limit" "$(cat "$CASS_UNIT")"
fi

if grep -qx 'StartLimitIntervalSec=120' "$CM_UNIT" && grep -qx 'StartLimitBurst=5' "$CM_UNIT" \
    && ! grep -q -e 'RUST_LOG' -e '^RestartSteps=' "$CM_UNIT"; then
    pass "cm keeps its start limit, and gets no log level or backoff"
else
    fail "cm keeps its start limit, and gets no log level or backoff" "$(cat "$CM_UNIT")"
fi

# ------------------------------------------------------------
# health: units that are down, or on older settings (acfs-eyvw)
# ------------------------------------------------------------
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"agent-mail|ok|"* && "$OUT" == *"cm|ok|"* && "$OUT" == *"cass|ok|"* ]]; then
    pass "health --robot reports every running unit ok and exits 0"
else
    fail "health --robot reports every running unit ok and exits 0" "rc=$RC $OUT"
fi

# systemd gave up on cass, as it did on the full disk.
rm -f "$STATE/active/acfs-cass-index.service"
set_prop acfs-cass-index.service ActiveState failed
set_prop acfs-cass-index.service Result exit-code
set_prop acfs-cass-index.service ExecMainStatus 14
set_prop acfs-cass-index.service NRestarts 5
svc health --robot
if [[ "$RC" -eq 1 && "$OUT" == *"cass|failed|acfs-cass-index.service has failed (result exit-code, last exit status 14, 5 automatic restarts)"* \
    && "$OUT" == *"cm|ok|"* ]]; then
    pass "health --robot reports a failed cass unit with its last exit status, and exits 1"
else
    fail "health --robot reports a failed cass unit with its last exit status, and exits 1" "rc=$RC $OUT"
fi

svc status
if [[ "$RC" -ne 0 && "$OUT" == *"cass: acfs-cass-index.service has failed"* \
    && "$OUT" == *"Fix: acfs services repair cass"* ]]; then
    pass "status names a failed unit and its repair"
else
    fail "status names a failed unit and its repair" "rc=$RC $OUT"
fi

set_prop acfs-cass-index.service ActiveState activating
set_prop acfs-cass-index.service SubState auto-restart
svc health --robot
if [[ "$RC" -eq 1 && "$OUT" == *"cass|restarting|acfs-cass-index.service exited (result exit-code, last exit status 14, 5 automatic restarts) and waits for its next automatic restart"* ]]; then
    pass "health --robot reports a unit waiting for its next automatic restart"
else
    fail "health --robot reports a unit waiting for its next automatic restart" "rc=$RC $OUT"
fi

find "$STATE/prop" -type f -exec rm -f {} +
svc health --robot
if [[ "$RC" -eq 1 && "$OUT" == *"cass|stopped|acfs-cass-index.service is enabled but not running"* ]]; then
    pass "health --robot reports an enabled unit that is not running"
else
    fail "health --robot reports an enabled unit that is not running" "rc=$RC $OUT"
fi

# cass failed, then 'acfs services stop': systemd keeps it failed through
# disable --now, so stop clears it, and health calls it disabled.
set_prop acfs-cass-index.service ActiveState failed
: > "$STATE/calls"
svc stop
if [[ "$RC" -eq 0 ]] && calls | grep -A1 -x 'systemctl --user disable --now acfs-cass-index.service' \
        | grep -qx 'systemctl --user reset-failed acfs-cass-index.service'; then
    pass "stop clears a failed unit's failed state after disabling it"
else
    fail "stop clears a failed unit's failed state after disabling it" "rc=$RC $(calls)"
fi
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cass|disabled|"* ]]; then
    pass "after stop, a unit that had failed is disabled, not failed"
else
    fail "after stop, a unit that had failed is disabled, not failed" "rc=$RC $OUT"
fi

# A unit still failed but no longer enabled (stopped by an older ACFS,
# which did not reset it) is not a fault either.
set_prop acfs-cass-index.service ActiveState failed
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cass|disabled|acfs-cass-index.service is not enabled (it had failed before it was stopped)"* ]]; then
    pass "health --robot reports a failed unit that is not enabled as disabled"
else
    fail "health --robot reports a failed unit that is not enabled as disabled" "rc=$RC $OUT"
fi
find "$STATE/prop" -type f -exec rm -f {} +
svc start
rm -f "$STATE/active/acfs-cass-index.service"

svc stop
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cm|disabled|"* && "$OUT" == *"cass|disabled|"* ]]; then
    pass "after stop, health --robot reports the units disabled, not as faults"
else
    fail "after stop, health --robot reports the units disabled, not as faults" "rc=$RC $OUT"
fi

reset_state
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cm|not-set-up|"* && "$OUT" == *"cass|not-set-up|"* && "$OUT" == *"agent-mail|not-set-up|"* ]]; then
    pass "before the first start, health --robot reports no unit set up, not as a fault"
else
    fail "before the first start, health --robot reports no unit set up, not as a fault" "rc=$RC $OUT"
fi

svc health --bogus
if [[ "$RC" -ne 0 && "$OUT" == *"Unknown option for 'health'"* ]]; then
    pass "health refuses an unknown option"
else
    fail "health refuses an unknown option" "rc=$RC $OUT"
fi

# A cass unit that ACFS wrote before acfs-eyvw: no log level, a start limit.
reset_state
svc start
cat > "$CASS_UNIT" <<EOF
# Written by 'acfs services start' (acfs-services.sh 2.0.0). Rewritten on
# every start; edit ACFS_* settings instead, then run 'acfs services start'.
[Unit]
Description=ACFS CASS indexer (watch mode)
# Give up after 5 failed starts in 2 minutes (e.g. a port held by another
# process) instead of crash-looping; 'acfs services repair' clears it.
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$HOMEDIR/.local/bin/cass index --watch
Restart=on-failure
RestartSec=5
Environment=PATH=%h/.acfs/bin:%h/.local/bin:%h/.cargo/bin:%h/.bun/bin:%h/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=%h

[Install]
WantedBy=default.target
EOF
svc health --robot
if [[ "$RC" -eq 1 && "$OUT" == *"cass|outdated|acfs-cass-index.service runs on older settings"* \
    && "$OUT" == *"cm|ok|"* && "$OUT" == *"agent-mail|ok|"* ]]; then
    pass "health --robot reports a running cass unit with older settings as outdated"
else
    fail "health --robot reports a running cass unit with older settings as outdated" "rc=$RC $OUT"
fi

svc health
if [[ "$RC" -eq 1 && "$OUT" == *"Fix: acfs services restart cass"* ]]; then
    pass "health names the restart that applies the new settings"
else
    fail "health names the restart that applies the new settings" "rc=$RC $OUT"
fi

: > "$STATE/calls"
svc start
if [[ "$RC" -eq 0 ]] && grep -qx 'Environment=RUST_LOG=warn' "$CASS_UNIT" \
    && calls | grep -q '^systemctl --user restart acfs-cass-index.service$' \
    && ! calls | grep -q -e 'restart acfs-cm.service' -e 'restart acfs-agent-mail.service'; then
    pass "start rewrites an outdated cass unit and restarts cass only"
else
    fail "start rewrites an outdated cass unit and restarts cass only" "rc=$RC $(calls)"
fi

svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cass|ok|"* ]]; then
    pass "after the rewrite, health --robot reports cass ok"
else
    fail "after the rewrite, health --robot reports cass ok" "rc=$RC $OUT"
fi

# A different binary path alone is not older settings: a run with another
# PATH resolves cass elsewhere, and start rewrites a moved binary anyway.
sed -i 's|^ExecStart=.*|ExecStart=/opt/other/cass index --watch|' "$CASS_UNIT"
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cass|ok|"* ]]; then
    pass "health --robot ignores ExecStart when it compares unit settings"
else
    fail "health --robot ignores ExecStart when it compares unit settings" "rc=$RC $OUT"
fi

touch "$STATE/no-systemd"
svc health --robot
if [[ "$RC" -eq 0 && "$OUT" == *"cass|unknown|no systemd user manager is reachable"* ]]; then
    pass "without a systemd user manager, health --robot reports unknown, not a fault"
else
    fail "without a systemd user manager, health --robot reports unknown, not a fault" "rc=$RC $OUT"
fi
rm -f "$STATE/no-systemd"

# ------------------------------------------------------------
# A binary path systemd would need quoting for is refused
# ------------------------------------------------------------
reset_state
mkdir -p "$ROOT/odd dir"
cp "$HOMEDIR/.local/bin/cm" "$ROOT/odd dir/cm"
OUT="$(env -i HOME="$HOMEDIR" PATH="$ROOT/odd dir:$HOMEDIR/.local/bin:/usr/bin:/bin" TERM=dumb \
    ACFS_SERVICES_SYSTEM_BIN_PREFIX="$SYSBIN" STUB_STATE="$STATE" ACFS_SVC_SMOKE_TIMEOUT=5 \
    bash "$SERVICES_SH" start 2>&1)"
RC=$?
if [[ "$RC" -ne 0 && "$OUT" == *"Refusing to put"* && ! -e "$UNIT_DIR/acfs-cm.service" ]]; then
    pass "a binary path with a space is refused rather than written into ExecStart"
else
    fail "a binary path with a space is refused rather than written into ExecStart" "rc=$RC $OUT"
fi

printf '\nTests passed: %d\nTests failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
