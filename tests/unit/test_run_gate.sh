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
check "--help exits 0" usage_rc 0 --help

echo
echo "run_gate: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
