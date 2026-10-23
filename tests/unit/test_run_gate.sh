#!/usr/bin/env bash
# ============================================================
# scripts/tests/run_gate.sh against a fixture checkout whose gate
# steps are stubs
#
# Proves the gate runs every step with TMPDIR and HOME inside one temp
# root, gives each command a fresh HOME, keeps going after a failure,
# and removes the root on exit: on success, on failure, and on a
# signal, but not with --keep.
#
# Usage: bash tests/unit/test_run_gate.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/tests/run_gate.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-run-gate-test.XXXXXX")"
cleanup() {
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# The fixture checkout: the policy step's two scripts are stubs that
# record their TMPDIR and HOME, leave a read-only dir in TMPDIR, and
# fail when told to.
FIXTURE="$WORK/checkout"
PARENT="$WORK/parent"
LOG="$WORK/calls"
mkdir -p "$FIXTURE/scripts/lib" "$FIXTURE/scripts/tests" "$PARENT"
for stub in scripts/lib/policy_lint.sh scripts/tests/lint_rch_offload_policy.sh; do
    cat >"$FIXTURE/$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s TMPDIR=%s HOME=%s umask=%s\n' "$(basename "$0")" "$TMPDIR" "$HOME" "$(umask)" >>"$GATE_TEST_LOG"
leak="$(mktemp -d)"
mkdir -p "$leak/locked"
chmod 0555 "$leak/locked"
[[ ! -e "$GATE_TEST_FAIL_DIR/$(basename "$0")" ]]
STUB
done
export GATE_TEST_LOG="$LOG"
export GATE_TEST_FAIL_DIR="$WORK/fail"
mkdir -p "$GATE_TEST_FAIL_DIR"

run_gate() {
    local rc=0
    : >"$LOG"
    bash "$GATE" --root "$FIXTURE" --tmp-parent "$PARENT" --step policy "$@" >"$WORK/out" 2>&1 || rc=$?
    return "$rc"
}
parent_empty() { [[ -z "$(find "$PARENT" -mindepth 1 -print -quit)" ]]; }
field() { sed -n "$1p" "$LOG" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

echo "run_gate: success"
check "a passing gate exits 0" run_gate
check "runs both policy scripts" test "$(wc -l <"$LOG")" -eq 2
gate_tmp="$(field 1 TMPDIR)"
check "TMPDIR is inside a gate root under --tmp-parent" \
    bash -c '[[ "$1" == "$2"/acfs-gate.*/tmp ]]' _ "$gate_tmp" "$PARENT"
check "HOME is inside the same gate root" \
    bash -c '[[ "$1" == "${2%/tmp}"/home.* ]]' _ "$(field 1 HOME)" "$gate_tmp"
check "each command gets its own HOME" test "$(field 1 HOME)" != "$(field 2 HOME)"
check "the steps run with CI's umask" test "$(field 1 umask)" = 0022
check "removes the gate root, read-only leftovers and all" parent_empty
check "the summary passes both" grep -q "PASS  policy: rch offload lint" "$WORK/out"

echo "run_gate: failure"
touch "$GATE_TEST_FAIL_DIR/policy_lint.sh"
rc=0; run_gate || rc=$?
check "a failing step makes the gate exit 1" test "$rc" -eq 1
check "the next step still runs after a failure" test "$(wc -l <"$LOG")" -eq 2
check "the summary names the failed step" grep -q "FAIL  policy: policy_lint" "$WORK/out"
check "removes the gate root after a failure" parent_empty

echo "run_gate: --keep"
rm -f "$GATE_TEST_FAIL_DIR/policy_lint.sh"
run_gate --keep || true
check "--keep keeps the gate root" test -d "$(dirname "$(field 1 TMPDIR)")"
chmod -R u+rwX "$PARENT"
find "$PARENT" -mindepth 1 -delete

echo "run_gate: signal"
cat >"$FIXTURE/scripts/lib/policy_lint.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >>"$GATE_TEST_LOG"
exec sleep 30
STUB
: >"$LOG"
bash "$GATE" --root "$FIXTURE" --tmp-parent "$PARENT" --step policy >/dev/null 2>&1 &
gate_pid=$!
tries=0
until [[ -s "$LOG" ]] || ((tries++ >= 100)); do sleep 0.1; done
# As timeout(1) or a reaper would: TERM to the gate, then its running
# step (bash runs the gate's trap once the step exits).
kill -TERM "$gate_pid"
kill -TERM "$(head -n1 "$LOG")" 2>/dev/null || true
rc=0; wait "$gate_pid" || rc=$?
check "a TERM stops the gate with 143" test "$rc" -eq 143
check "removes the gate root after a TERM" parent_empty

echo "run_gate: -- COMMAND"
cmd_rc=0
(cd "$WORK" && bash "$GATE" --tmp-parent "$PARENT" -- \
    bash -c 'printf "%s %s %s\n" "$PWD" "$TMPDIR" "$HOME" >"$1"; mktemp -d >/dev/null; exit 7' _ "$WORK/cmd") \
    >/dev/null 2>&1 || cmd_rc=$?
read -r cmd_pwd cmd_tmp cmd_home <"$WORK/cmd"
check "the command's exit status is the gate's" test "$cmd_rc" -eq 7
check "the command runs from the current directory" test "$cmd_pwd" = "$WORK"
check "the command's TMPDIR is in a gate root" bash -c '[[ "$1" == "$2"/acfs-gate.*/tmp ]]' _ "$cmd_tmp" "$PARENT"
check "the command's HOME is in the same root" bash -c '[[ "$1" == "${2%/tmp}"/home.* ]]' _ "$cmd_home" "$cmd_tmp"
check "removes the gate root after the command" parent_empty

echo "run_gate: Playwright (acfs-l3r7)"
pw_env() { # pw_env [VAR=VALUE...]: the gate's Playwright settings, for a caller whose HOME is $WORK/realhome
    (cd "$WORK" && env -u PLAYWRIGHT_SKIP_BROWSER_GC -u ACFS_PLAYWRIGHT_MIRROR -u PLAYWRIGHT_HOST_PLATFORM_OVERRIDE \
        -u XDG_CACHE_HOME HOME="$WORK/realhome" "$@" bash "$GATE" --tmp-parent "$PARENT" -- \
        bash -c 'printf "%s|%s|%s\n" "${PLAYWRIGHT_SKIP_BROWSER_GC:-}" "${ACFS_PLAYWRIGHT_MIRROR:-}" "${PLAYWRIGHT_HOST_PLATFORM_OVERRIDE:-}" >"$1"' \
        _ "$WORK/pwenv") >/dev/null 2>&1
    IFS='|' read -r pw_gc pw_mirror pw_platform <"$WORK/pwenv"
}
pw_env
check "skips Playwright's browser GC" test "$pw_gc" = 1
check "the zip mirror stays in the caller's cache" test "$pw_mirror" = "$WORK/realhome/.cache/acfs/playwright-mirror"
if grep -qx 'ID=ubuntu' /etc/os-release 2>/dev/null && grep -qx 'VERSION_ID="26.04"' /etc/os-release 2>/dev/null; then
    check "Ubuntu 26.04: Playwright's 24.04 builds" bash -c '[[ "$1" == ubuntu24.04-* ]]' _ "$pw_platform"
else
    check "not Ubuntu 26.04: no platform override" test -z "$pw_platform"
fi
pw_env ACFS_PLAYWRIGHT_MIRROR="$WORK/mirror" PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=mine
check "a caller's own mirror and platform are kept" \
    bash -c '[[ "$1" == "$2/mirror" && "$3" == mine ]]' _ "$pw_mirror" "$WORK" "$pw_platform"

# The web step against stubs: bun does nothing, and the browser helper
# records what it is asked for.
mkdir -p "$FIXTURE/apps/web" "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/bun"
chmod +x "$WORK/bin/bun"
cat >"$FIXTURE/scripts/tests/ensure_playwright_browsers.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GATE_TEST_LOG"
STUB
web_browsers() { # web_browsers [--browser-project NAME...]: the helper's arguments
    : >"$LOG"
    PATH="$WORK/bin:$PATH" ACFS_BROWSER_GATE_LOCK="$WORK/browser.lock" \
        bash "$GATE" --root "$FIXTURE" --tmp-parent "$PARENT" --step web --bun-memory-max none "$@" >"$WORK/out" 2>&1 || true
    cat "$LOG"
}
check "web: every project by default, so every browser" \
    test "$(web_browsers)" = "--web $FIXTURE/apps/web chromium firefox webkit"
check "web: Mobile Chrome needs only chromium" \
    test "$(web_browsers --browser-project 'Mobile Chrome')" = "--web $FIXTURE/apps/web chromium"
check "web: firefox and Mobile Safari add theirs" \
    test "$(web_browsers --browser-project firefox --browser-project 'Mobile Safari')" = "--web $FIXTURE/apps/web chromium firefox webkit"
check "removes the gate root after the web step" parent_empty

echo "run_gate: the bun memory cap (acfs-dpvr)"
# Stubs: bun records its arguments; systemctl answers the user manager's
# state from GATE_TEST_SYSTEMD_STATE; systemd-run records its options and
# runs the command after --, as a scope would.
mkdir -p "$FIXTURE/packages/manifest" "$WORK/capbin" "$WORK/oombin"
cat >"$WORK/capbin/bun" <<'STUB'
#!/usr/bin/env bash
printf 'bun %s\n' "$*" >>"$GATE_TEST_LOG"
STUB
cat >"$WORK/capbin/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == "--user is-system-running" ]] || exit 99
printf '%s\n' "$GATE_TEST_SYSTEMD_STATE"
[[ "$GATE_TEST_SYSTEMD_STATE" == running ]]
STUB
cat >"$WORK/capbin/systemd-run" <<'STUB'
#!/usr/bin/env bash
options=()
while [[ $# -gt 0 && "$1" != -- ]]; do options+=("$1"); shift; done
shift
printf 'systemd-run %s\n' "${options[*]}" >>"$GATE_TEST_LOG"
exec "$@"
STUB
chmod +x "$WORK/capbin/bun" "$WORK/capbin/systemctl" "$WORK/capbin/systemd-run"
manifest_gate() { # manifest_gate <user manager state> [options...]: the manifest step against the stubs
    local state="$1"
    shift
    : >"$LOG"
    PATH="$WORK/capbin:$PATH" GATE_TEST_SYSTEMD_STATE="$state" \
        bash "$GATE" --root "$FIXTURE" --tmp-parent "$PARENT" --step manifest "$@" >"$WORK/out" 2>&1
}
scoped_bun() { # scoped_bun <MemoryMax>: three bun commands, each after its scope
    [[ "$(grep -c "^systemd-run --user --scope --quiet -p MemoryMax=$1 -p MemorySwapMax=0\$" "$LOG")" -eq 3 \
        && "$(sed -n 1p "$LOG")" == systemd-run* && "$(sed -n 2p "$LOG")" == "bun run generate:validate" \
        && "$(sed -n 6p "$LOG")" == "bun test" ]]
}
bare_bun() { [[ "$(cat "$LOG")" == $'bun run generate:validate\nbun run generate --diff\nbun test' ]]; }
check "a user manager: the manifest step passes" manifest_gate running
check "a user manager: each bun command runs in a scope capped at 4G, without swap" scoped_bun 4G
check "a user manager: the run says so" grep -q "runs in a user scope capped at 4G" "$WORK/out"
check "a user manager: each step's log line names the command and the cap" \
    grep -qx 'run_gate: \[manifest: bun test\] bun test (in a user scope, MemoryMax=4G)' "$WORK/out"
check "--bun-memory-max sets the cap" manifest_gate running --bun-memory-max 512M
check "--bun-memory-max 512M reaches the scope" scoped_bun 512M
check "a degraded user manager still caps" manifest_gate degraded
check "a degraded user manager: the commands are scoped" \
    test "$(grep -c '^systemd-run ' "$LOG")" -eq 3
check "no user manager: the manifest step passes" manifest_gate offline
check "no user manager: bun runs bare" bare_bun
check "no user manager: the log line is the command alone" grep -qx 'run_gate: \[manifest: bun test\] bun test' "$WORK/out"
check "no user manager: the run says so" grep -q "no systemd user manager (offline); the bun commands run without a memory cap" "$WORK/out"
check "--bun-memory-max none: the manifest step passes" manifest_gate running --bun-memory-max none
check "--bun-memory-max none: bun runs bare" bare_bun
check "removes the gate root after the capped steps" parent_empty
# A real scope, where a user manager runs with the memory controller:
# a bun that outgrows a 64M cap is killed, and the gate names the cap.
cat >"$WORK/oombin/bun" <<'STUB'
#!/usr/bin/env bash
exec python3 -I -c 'a = bytearray(300 * 1024 * 1024)'
STUB
chmod +x "$WORK/oombin/bun"
user_state="$(systemctl --user is-system-running 2>/dev/null)" || true
user_cgroup="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if command -v systemd-run >/dev/null 2>&1 && [[ "$user_state" == running || "$user_state" == degraded ]] \
    && grep -qw memory "$user_cgroup" 2>/dev/null; then
    rc=0
    PATH="$WORK/oombin:$PATH" bash "$GATE" --root "$FIXTURE" --tmp-parent "$PARENT" --step manifest \
        --bun-memory-max 64M >"$WORK/out" 2>&1 || rc=$?
    check "a real scope: a bun over the cap fails the gate" test "$rc" -eq 1
    check "a real scope: the gate names the cap" grep -q "reached the bun memory cap (64M)" "$WORK/out"
    check "a real scope: the summary names the step" grep -q "FAIL  manifest: bun test" "$WORK/out"
    check "removes the gate root after a capped kill" parent_empty
else
    echo "  skip a real scope: no systemd user manager with the memory controller here"
fi

echo "run_gate: usage"
usage_rc() {
    local want="$1" rc=0
    shift
    bash "$GATE" "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq "$want" ]]
}
check "--step with a command is bad usage" usage_rc 2 --step policy -- true
check "an unknown step is bad usage" usage_rc 2 --step bogus
check "an unknown option is bad usage" usage_rc 2 --bogus
check "a missing --tmp-parent is bad usage" usage_rc 2 --tmp-parent "$WORK/missing"
check "a --bun-memory-max that isn't a size is bad usage" usage_rc 2 --bun-memory-max 4GiB
check "a missing --bun-memory-max is bad usage" usage_rc 2 --bun-memory-max
check "--help exits 0" usage_rc 0 --help

echo
echo "run_gate: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
