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
        unit="$1"; prop="${3:-}"
        case "$prop" in
            LoadState) [[ -e "$STUB_STATE/loaded-$unit" ]] && echo loaded || echo not-found ;;
            MainPID)   echo 0 ;;
        esac ;;
    is-active)
        [[ "${1:-}" == "--quiet" ]] && shift
        [[ -e "$STUB_STATE/active/$1" ]] ;;
    daemon-reload|reset-failed) ;;
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
chmod 755 "$SYSBIN"/* "$HOMEDIR/.local/bin"/*

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
