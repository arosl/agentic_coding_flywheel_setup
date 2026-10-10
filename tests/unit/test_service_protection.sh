#!/usr/bin/env bash
# ============================================================
# Service protection (acfs-ioo3.5): slices, drop-ins, herdr's unit, the agent
# shims and the pressure fallback.
#
# Runs scripts/lib/service_protection.sh against stub systemctl, systemd-run,
# systemd-detect-virt and pgrep (through ACFS_SP_SYSTEM_BIN_PREFIX), with
# /etc, /proc and /sys/fs/cgroup under a test root (ACFS_SP_ROOT). Nothing
# here reaches the host's service managers. One group runs the shim for real
# without ACFS_SP_ROOT, so the kernel's oom_score_adj of the agent process is
# what is checked; it only raises the score of the test's own child.
#
# Run with: bash tests/unit/test_service_protection.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
SP_SH="$REPO_ROOT/scripts/lib/service_protection.sh"

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

ROOT="$(mktemp -d)"
SYSBIN="$ROOT/sysbin"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l -o -type s \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT
UID_NUM="$(id -u)"
USER_NAME="$(id -un)"

# ------------------------------------------------------------
# Stubs
# ------------------------------------------------------------
mkdir -p "$SYSBIN"
chmod 700 "$ROOT" "$SYSBIN"

cat > "$SYSBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Stub systemctl; state in $STUB_STATE.
printf 'systemctl %s\n' "$*" >> "$STUB_STATE/calls"
user=false
[[ "${1:-}" == --user ]] && { user=true; shift; }
cmd="${1:-}"; shift || true
case "$cmd" in
    show-environment) [[ ! -e "$STUB_STATE/no-user-manager" ]] ;;
    daemon-reload) ;;
    is-active)
        [[ "${1:-}" == --quiet ]] && shift
        if [[ "$user" == false ]]; then [[ -e "$STUB_STATE/system-active-$1" ]]; else [[ -e "$STUB_STATE/active-$1" ]]; fi ;;
    enable|disable|start|restart|kill)
        now=false
        args=()
        for a in "$@"; do
            case "$a" in --now) now=true ;; --signal=*) ;; *) args+=("$a") ;; esac
        done
        for u in "${args[@]}"; do
            case "$cmd" in
                enable) touch "$STUB_STATE/enabled-$u"; [[ "$now" == false ]] || touch "$STUB_STATE/active-$u" ;;
                disable) rm -f "$STUB_STATE/enabled-$u"; [[ "$now" == false ]] || rm -f "$STUB_STATE/active-$u" ;;
                start|restart) touch "$STUB_STATE/active-$u" ;;
                kill) touch "$STUB_STATE/killed-$u" ;;
            esac
        done ;;
    show)
        prop="" unit=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -p) prop="$2"; shift 2 ;; --value) shift ;; *) unit="$1"; shift ;; esac
        done
        f="$STUB_STATE/$prop-$unit"
        if [[ -e "$f" ]]; then cat "$f"; elif [[ "$prop" == MainPID ]]; then echo 0; fi ;;
    list-units) if [[ -e "$STUB_STATE/scopes" ]]; then cat "$STUB_STATE/scopes"; fi ;;
esac
EOF

cat > "$SYSBIN/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
[[ -e "$STUB_STATE/container" ]]
EOF

cat > "$SYSBIN/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -e "$STUB_STATE/herdr-running" ]]
EOF

# Records its arguments, then runs the command after `--`, as --scope does.
cat > "$SYSBIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_STATE/systemd-run"
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
shift
exec "$@"
EOF
chmod 755 "$SYSBIN"/*

# A fresh world per case: state, test root, HOME with herdr and an agent.
new_world() {
    WORLD=$((WORLD + 1))
    W="$ROOT/w$WORLD"
    STATE="$W/state" FAKE="$W/root" HOMEDIR="$W/home"
    mkdir -p "$STATE" "$FAKE/proc/self" "$FAKE/etc/systemd" "$HOMEDIR/.local/bin" "$HOMEDIR/.acfs/scripts/lib"
    printf 'MemTotal:       201326592 kB\n' > "$FAKE/proc/meminfo"   # 192 GiB
    printf '0\n' > "$FAKE/proc/self/oom_score_adj"
    printf '0::/user.slice/user-%s.slice/user@%s.service/app.slice/x.scope\n' "$UID_NUM" "$UID_NUM" > "$FAKE/proc/self/cgroup"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOMEDIR/.local/bin/herdr"
    cat > "$HOMEDIR/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'agent adj=%s args=' "$(cat /proc/self/oom_score_adj)"
printf '[%s]' "$@"
printf '\n'
EOF
    chmod 755 "$HOMEDIR/.local/bin/herdr" "$HOMEDIR/.local/bin/claude"
    cp "$SP_SH" "$HOMEDIR/.acfs/scripts/lib/service_protection.sh"
    UNITS="$HOMEDIR/.config/systemd/user"
}
WORLD=0

sp() { # sp <args...>: run the script in the current world
    env -i HOME="$HOMEDIR" PATH="$HOMEDIR/.local/bin:/usr/bin:/bin" TERM=dumb \
        ACFS_SP_ROOT="$FAKE" ACFS_SP_SYSTEM_BIN_PREFIX="$SYSBIN" STUB_STATE="$STATE" \
        XDG_RUNTIME_DIR="$W/run" ${EXTRA_ENV:-} bash "$SP_SH" "$@" 2>&1
}

has() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

# ------------------------------------------------------------
# apply-system
# ------------------------------------------------------------
new_world
touch "$STATE/container"
OUT="$(sp apply-system "$USER_NAME")"; RC=$?
SYSD="$FAKE/etc/systemd/system"
check "apply-system succeeds in a container" test "$RC" -eq 0
check "user.slice gets MemoryLow=12288M" has "$SYSD/user.slice.d/50-acfs-protection.conf" "MemoryLow=12288M"
check "user-<uid>.slice gets MemoryLow" has "$SYSD/user-$UID_NUM.slice.d/50-acfs-protection.conf" "MemoryLow=12288M"
check "user@<uid>.service gets MemoryLow" has "$SYSD/user@$UID_NUM.service.d/50-acfs-protection.conf" "MemoryLow=12288M"
check "a container gets no OOM floor change" lacks "$SYSD/user@$UID_NUM.service.d/50-acfs-protection.conf" "OOMScoreAdjust"
check "a container gets no user.conf.d" test ! -e "$FAKE/etc/systemd/user.conf.d/50-acfs-protection.conf"
check "apply-system reloads the system manager" has "$STATE/calls" "systemctl daemon-reload"

new_world
OUT="$(sp apply-system "$USER_NAME")"; RC=$?
SYSD="$FAKE/etc/systemd/system"
check "apply-system succeeds on a VM" test "$RC" -eq 0
check "a VM lowers the user manager's floor to -900" has "$SYSD/user@$UID_NUM.service.d/50-acfs-protection.conf" "OOMScoreAdjust=-900"
check "a VM keeps other user units at 200" has "$FAKE/etc/systemd/user.conf.d/50-acfs-protection.conf" "DefaultOOMScoreAdjust=200"
: > "$STATE/calls"
OUT="$(sp apply-system "$USER_NAME")"
check "a second apply-system changes nothing and does not reload" lacks "$STATE/calls" "daemon-reload"

new_world
printf 'MemTotal:       16777216 kB\n' > "$FAKE/proc/meminfo"   # 16 GiB
OUT="$(sp apply-system "$USER_NAME")"
check "16 GiB: the chain is capped at half of RAM" has "$FAKE/etc/systemd/system/user.slice.d/50-acfs-protection.conf" "MemoryLow=8192M"

OUT="$(sp apply-system 'bad;name')"; RC=$?
check "apply-system refuses an invalid user name" test "$RC" -ne 0

# ------------------------------------------------------------
# apply-user
# ------------------------------------------------------------
new_world
touch "$STATE/container"
OUT="$(sp apply-user)"; RC=$?
check "apply-user succeeds" test "$RC" -eq 0
check "services slice has MemoryLow=8192M" has "$UNITS/acfs-services.slice" "MemoryLow=8192M"
check "acfs.slice, their parent, protects services plus background" has "$UNITS/acfs.slice" "MemoryLow=11264M"
check "background slice has MemoryLow=3072M" has "$UNITS/acfs-background.slice" "MemoryLow=3072M"
check "agents slice: oomd kills at 40% pressure" has "$UNITS/acfs-agents.slice" "ManagedOOMMemoryPressureLimit=40%"
check "agents slice: ManagedOOMMemoryPressure=kill" has "$UNITS/acfs-agents.slice" "ManagedOOMMemoryPressure=kill"
check "agents slice has no MemoryLow" lacks "$UNITS/acfs-agents.slice" "MemoryLow"
for unit in agent-mail.service acfs-agent-mail.service acfs-cm.service rchd.service; do
    check "$unit moves to acfs-services.slice" has "$UNITS/$unit.d/50-acfs-protection.conf" "Slice=acfs-services.slice"
    check "$unit keeps score 0 in a container" has "$UNITS/$unit.d/50-acfs-protection.conf" "OOMScoreAdjust=0"
done
check "cass moves to acfs-background.slice" has "$UNITS/acfs-cass-index.service.d/50-acfs-protection.conf" "Slice=acfs-background.slice"
check "cass runs at +200" has "$UNITS/acfs-cass-index.service.d/50-acfs-protection.conf" "OOMScoreAdjust=200"
check "herdr gets a user unit" has "$UNITS/acfs-herdr.service" "ExecStart=$HOMEDIR/.local/bin/herdr server"
check "herdr's unit is in acfs-services.slice" has "$UNITS/acfs-herdr.service" "Slice=acfs-services.slice"
check "herdr's panes find the shims first" has "$UNITS/acfs-herdr.service" "Environment=PATH=%h/.acfs/agent-scope/bin:"
check "herdr's unit is enabled and started" test -e "$STATE/enabled-acfs-herdr.service" -a -e "$STATE/active-acfs-herdr.service"
for name in claude codex gemini agy pi; do
    check "shim $name is executable" test -x "$HOMEDIR/.acfs/agent-scope/bin/$name"
done
check "without oomd the pressure fallback runs" test -e "$STATE/active-acfs-agents-pressure.service"
check "the pressure unit runs the installed library" has "$UNITS/acfs-agents-pressure.service" "$HOMEDIR/.acfs/scripts/lib/service_protection.sh pressure-guard"
check "apply-user reloads the user manager" has "$STATE/calls" "systemctl --user daemon-reload"
: > "$STATE/calls"
OUT="$(sp apply-user)"
check "a second apply-user does not reload" lacks "$STATE/calls" "daemon-reload"

# After a VM's apply-system, the services ask for -900.
new_world
OUT="$(sp apply-system "$USER_NAME")"
OUT="$(sp apply-user)"
check "on a VM the services run at -900" has "$UNITS/acfs-cm.service.d/50-acfs-protection.conf" "OOMScoreAdjust=-900"
check "on a VM herdr runs at -900" has "$UNITS/acfs-herdr.service" "OOMScoreAdjust=-900"
check "on a VM cass stays at +200" has "$UNITS/acfs-cass-index.service.d/50-acfs-protection.conf" "OOMScoreAdjust=200"

# A herdr server outside the unit is left alone.
new_world
touch "$STATE/herdr-running"
OUT="$(sp apply-user)"
check "a running herdr server: the unit is enabled" test -e "$STATE/enabled-acfs-herdr.service"
check "a running herdr server: the unit is not started" test ! -e "$STATE/active-acfs-herdr.service"
check "a running herdr server: it says how to switch" grep -qF "herdr server stop" <<<"$OUT"

# oomd active: the fallback is off.
new_world
touch "$STATE/system-active-systemd-oomd.service" "$STATE/active-acfs-agents-pressure.service"
OUT="$(sp apply-user)"
check "with oomd active the fallback is stopped" test ! -e "$STATE/active-acfs-agents-pressure.service"

# A running service in its old slice: named, and restarted only with --restart.
new_world
touch "$STATE/active-agent-mail.service"
printf '/user.slice/user-%s.slice/user@%s.service/app.slice/agent-mail.service\n' "$UID_NUM" "$UID_NUM" > "$STATE/ControlGroup-agent-mail.service"
OUT="$(sp apply-user)"
check "a service in its old slice is named" grep -qF "still in their old slice until restarted: agent-mail.service" <<<"$OUT"
check "without --restart nothing restarts" lacks "$STATE/calls" "restart agent-mail.service"
OUT="$(sp apply-user --restart)"
check "--restart restarts it" has "$STATE/calls" "systemctl --user restart agent-mail.service"

# No user manager: nothing written.
new_world
touch "$STATE/no-user-manager"
OUT="$(sp apply-user)"; RC=$?
check "no user manager: apply-user skips cleanly" test "$RC" -eq 0 -a ! -e "$UNITS/acfs-services.slice"

# No installed library: no shims, no pressure unit, slices still written.
new_world
mv "$HOMEDIR/.acfs/scripts/lib/service_protection.sh" "$W/sp.sh"
OUT="$(sp apply-user)"
check "no installed library: no shims" test ! -e "$HOMEDIR/.acfs/agent-scope/bin/claude"
check "no installed library: slices still written" test -e "$UNITS/acfs-agents.slice"

# ------------------------------------------------------------
# agent-exec and the shims (real oom_score_adj)
# ------------------------------------------------------------
new_world
OUT="$(sp apply-user)"
SHIMS="$HOMEDIR/.acfs/agent-scope/bin"
mkdir -p "$W/run"
# Run a shim as herdr's pane would: shims first on PATH, no ACFS_SP_ROOT.
shim() {
    env -i HOME="$HOMEDIR" PATH="$SHIMS:$HOMEDIR/.local/bin:/usr/bin:/bin" TERM=dumb \
        ACFS_SP_SYSTEM_BIN_PREFIX="$SYSBIN" STUB_STATE="$STATE" XDG_RUNTIME_DIR="$W/run" \
        ${EXTRA_ENV:-} "$SHIMS/claude" "$@" 2>&1
}
OUT="$(shim --resume 'two words')"
check "no user bus: the agent runs directly" test ! -e "$STATE/systemd-run"
check "no user bus: the agent still runs at oom_score_adj 500" grep -qF "agent adj=500 args=[--resume][two words]" <<<"$OUT"

python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$W/run/bus"
OUT="$(shim -p 'hi there')"
check "with a user bus: the agent runs through systemd-run" test -e "$STATE/systemd-run"
check "the scope is in acfs-agents.slice" has "$STATE/systemd-run" "--user --scope --quiet --collect --slice=acfs-agents.slice --unit=acfs-agent-claude-"
check "the scope runs the real binary, not the shim" has "$STATE/systemd-run" "-- $HOMEDIR/.local/bin/claude -p hi there"
check "the agent in the scope is at oom_score_adj 500" grep -qF "agent adj=500 args=[-p][hi there]" <<<"$OUT"

rm -f "$STATE/systemd-run"
OUT="$(EXTRA_ENV="ACFS_AGENT_SCOPE=off" shim x)"
check "ACFS_AGENT_SCOPE=off: no scope" test ! -e "$STATE/systemd-run"
check "ACFS_AGENT_SCOPE=off: the agent runs" grep -qF "agent adj=500 args=[x]" <<<"$OUT"

# Already in the agents' slice (a nested agent): no second scope.
printf '0::/user.slice/user-%s.slice/user@%s.service/acfs.slice/acfs-agents.slice/acfs-agent-claude-1.scope\n' "$UID_NUM" "$UID_NUM" > "$FAKE/proc/self/cgroup"
OUT="$(sp agent-exec claude y)"
check "inside acfs-agents.slice: no nested scope" test ! -e "$STATE/systemd-run"
check "agent-exec under a test root writes the fake score" grep -qx 500 "$FAKE/proc/self/oom_score_adj"
printf '700\n' > "$FAKE/proc/self/oom_score_adj"
OUT="$(sp agent-exec claude y)"
check "a higher score is never lowered" grep -qx 700 "$FAKE/proc/self/oom_score_adj"

OUT="$(sp agent-exec nosuchagent)"; RC=$?
check "a missing agent exits 127" test "$RC" -eq 127
OUT="$(sp agent-exec '../x')"; RC=$?
check "an invalid name is refused" test "$RC" -eq 1

# The shim without ACFS's library still runs the agent, skipping itself.
mv "$HOMEDIR/.acfs/scripts/lib/service_protection.sh" "$W/sp.sh"
OUT="$(shim z)"; RC=$?
check "shim without the library runs the agent" grep -qF "args=[z]" <<<"$OUT"

# ------------------------------------------------------------
# pressure-guard
# ------------------------------------------------------------
new_world
CG="/user.slice/user-$UID_NUM.slice/user@$UID_NUM.service/acfs.slice/acfs-agents.slice"
printf '%s\n' "$CG" > "$STATE/ControlGroup-acfs-agents.slice"
mkdir -p "$FAKE/sys/fs/cgroup$CG"
printf 'some avg10=70.00 avg60=50.00 avg300=10.00 total=1\nfull avg10=55.12 avg60=40.00 avg300=9.00 total=1\n' > "$FAKE/sys/fs/cgroup$CG/memory.pressure"
printf 'acfs-agent-claude-10.scope loaded active running x\nacfs-agent-codex-20.scope loaded active running x\n' > "$STATE/scopes"
echo 100 > "$STATE/ActiveEnterTimestampMonotonic-acfs-agent-claude-10.scope"
echo 200 > "$STATE/ActiveEnterTimestampMonotonic-acfs-agent-codex-20.scope"
guard() { EXTRA_ENV="ACFS_SP_PRESSURE_INTERVAL=0 ACFS_SP_PRESSURE_SAMPLES=3 ACFS_SP_PRESSURE_MAX_LOOPS=$1" sp pressure-guard; }
OUT="$(guard 2)"
check "two samples over the limit kill nothing" test ! -e "$STATE/killed-acfs-agent-codex-20.scope"
OUT="$(guard 3)"
check "three samples over the limit kill the newest scope" test -e "$STATE/killed-acfs-agent-codex-20.scope"
check "the older scope is kept" test ! -e "$STATE/killed-acfs-agent-claude-10.scope"
check "the kill is logged in UTC" grep -qE '^\[service-protection\] [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z .*killing acfs-agent-codex-20.scope' <<<"$OUT"
rm -f "$STATE/killed-"*
printf 'some avg10=70.00 avg60=0 avg300=0 total=1\nfull avg10=12.00 avg60=0 avg300=0 total=1\n' > "$FAKE/sys/fs/cgroup$CG/memory.pressure"
OUT="$(guard 4)"
check "pressure under the limit kills nothing" test ! -e "$STATE/killed-acfs-agent-codex-20.scope"
printf 'full avg10=90.00 avg60=0 avg300=0 total=1\n' > "$FAKE/sys/fs/cgroup$CG/memory.pressure"
touch "$STATE/system-active-systemd-oomd.service"
OUT="$(guard 4)"
check "with oomd active the fallback kills nothing" test ! -e "$STATE/killed-acfs-agent-codex-20.scope"

# ------------------------------------------------------------
# verify
# ------------------------------------------------------------
new_world
touch "$STATE/container"
U="/user.slice/user-$UID_NUM.slice/user@$UID_NUM.service"
fake_pid() { # fake_pid <pid> <cgroup> <adj>
    mkdir -p "$FAKE/proc/$1"
    printf '0::%s\n' "$2" > "$FAKE/proc/$1/cgroup"
    printf '%s\n' "$3" > "$FAKE/proc/$1/oom_score_adj"
}
echo 101 > "$STATE/MainPID-agent-mail.service";     fake_pid 101 "$U/acfs.slice/acfs-services.slice/agent-mail.service" 0
echo 102 > "$STATE/MainPID-acfs-herdr.service";     fake_pid 102 "$U/acfs.slice/acfs-services.slice/acfs-herdr.service" 0
echo 103 > "$STATE/MainPID-acfs-cass-index.service"; fake_pid 103 "$U/acfs.slice/acfs-background.slice/acfs-cass-index.service" 200
echo 104 > "$STATE/MainPID-acfs-cm.service";        fake_pid 104 "$U/app.slice/acfs-cm.service" 200
printf 'acfs-agent-claude-10.scope loaded active running x\n' > "$STATE/scopes"
echo 110 > "$STATE/MainPID-acfs-agent-claude-10.scope"; fake_pid 110 "$U/acfs.slice/acfs-agents.slice/acfs-agent-claude-10.scope" 500
P="$FAKE/sys/fs/cgroup"
for d in user.slice "user-$UID_NUM.slice" "user@$UID_NUM.service" acfs.slice acfs-services.slice; do
    P="$P/$d"; mkdir -p "$P"; echo 8589934592 > "$P/memory.low"
done
touch "$STATE/active-acfs-agents-pressure.service"
OUT="$(sp verify)"; RC=$?
check "verify: agent-mail passes" grep -qF "PASS agent-mail.service: oom_score_adj=0" <<<"$OUT"
check "verify: herdr passes" grep -qF "PASS acfs-herdr.service" <<<"$OUT"
check "verify: cass passes at 200" grep -qF "PASS acfs-cass-index.service: oom_score_adj=200" <<<"$OUT"
check "verify: cm in its old slice fails" grep -qF "FAIL acfs-cm.service" <<<"$OUT"
check "verify: the agent scope passes" grep -qF "PASS acfs-agent-claude-10.scope: oom_score_adj=500" <<<"$OUT"
check "verify: memory.low along the chain passes" grep -qF "PASS memory.low acfs-services.slice" <<<"$OUT"
check "verify: the fallback counts as the pressure killer" grep -qF "PASS pressure killer: acfs-agents-pressure.service is active" <<<"$OUT"
check "verify: not running is a skip" grep -qF "SKIP rchd.service: not running" <<<"$OUT"
check "verify exits 1 on a failure" test "$RC" -eq 1

# ------------------------------------------------------------
# update_service_protection in update.sh. The sudo prefix is empty, so
# apply-system runs as this user against the test root.
# ------------------------------------------------------------
UPDATE_SH="$REPO_ROOT/scripts/lib/update.sh"
check "update.sh syncs service_protection.sh" \
    grep -qF '"scripts/lib/service_protection.sh:scripts/lib/service_protection.sh"' "$UPDATE_SH"
check "update's main applies it right after the stack" \
    bash -c 'grep -A1 "^    update_stack$" "$1" | grep -q "^    update_service_protection$"' _ "$UPDATE_SH"

# run_update <target user> [DRY_RUN]
run_update() {
    OUT="$(env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin" TERM=dumb \
        ACFS_SP_ROOT="$FAKE" ACFS_SP_SYSTEM_BIN_PREFIX="$SYSBIN" STUB_STATE="$STATE" \
        XDG_RUNTIME_DIR="$W/run" ACFS_HOME_ARG="$HOMEDIR/.acfs" TARGET_ARG="$1" DRY_RUN_ARG="${2:-false}" \
        UPDATE_SH="$UPDATE_SH" bash -c '
            set -uo pipefail
            source "$UPDATE_SH"
            QUIET=false
            VERBOSE=false
            DRY_RUN="$DRY_RUN_ARG"
            update_runtime_acfs_home() { printf "%s\n" "$ACFS_HOME_ARG"; }
            update_target_user() { printf "%s\n" "$TARGET_ARG"; }
            update_sudo_prefix() { local -n _ref="$1"; _ref=(); }
            update_service_protection
            echo "rc=$?"
        ' 2>&1)"
}

new_world
mv "$HOMEDIR/.acfs/scripts/lib/service_protection.sh" "$W/sp.sh"
run_update "$USER_NAME"
check "update: not installed is a skip" grep -qF "service protection" <<<"$OUT"
check "update: not installed returns 0" grep -qx "rc=0" <<<"$OUT"
mv "$W/sp.sh" "$HOMEDIR/.acfs/scripts/lib/service_protection.sh"
run_update "$USER_NAME" true
check "update: dry-run writes nothing" test ! -e "$FAKE/etc/systemd/system/user.slice.d" -a ! -e "$UNITS/acfs-agents.slice"
run_update "$USER_NAME"
check "update: system drop-ins written" test -e "$FAKE/etc/systemd/system/user.slice.d/50-acfs-protection.conf"
check "update: user slices written" test -e "$UNITS/acfs-agents.slice"
check "update: never restarts services" lacks "$STATE/calls" " restart "
check "update: returns 0" grep -qx "rc=0" <<<"$OUT"

new_world
run_update "someone-else"
check "update as another user: the user part is skipped" test ! -e "$UNITS/acfs-agents.slice"
check "update as another user: it says how to apply it" grep -qF "apply-user" <<<"$OUT"

printf '\nTests passed: %d\nTests failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
