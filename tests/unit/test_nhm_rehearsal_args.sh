#!/usr/bin/env bash
# ============================================================
# tests/vm/test_nhm_rehearsal.sh: what it does before it makes anything
#
# A rehearsal run is the operator's call (plan-v8 section 7), so the
# harness must refuse, without one call to incus and without an evidence
# directory, when --authorised is missing or any argument is wrong. With
# good arguments and an Incus it cannot reach, it skips (exit 77) after
# read-only calls only. A fake incus first on PATH records every call.
#
# Usage: bash tests/unit/test_nhm_rehearsal_args.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$ROOT/tests/vm/test_nhm_rehearsal.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-nhm-rehearsal-args.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/incus" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INCUS_CALLS"
exit 1
EOF
chmod +x "$WORK/bin/incus"
export INCUS_CALLS="$WORK/calls"

# run EXPECTED-EXIT DESCRIPTION ARGS...: runs the harness with its own
# evidence directory and checks the exit code, the calls and the evidence.
run() {
    local want="$1" what="$2" rc=0
    shift 2
    : >"$INCUS_CALLS"
    PATH="$WORK/bin:$PATH" bash "$HARNESS" --evidence "$WORK/evidence" "$@" >"$WORK/out" 2>&1 || rc=$?
    if [[ "$rc" -ne "$want" ]]; then
        fail "$what: exit $rc, want $want: $(tail -n 2 "$WORK/out")"
        return
    fi
    if [[ "$want" -eq 2 && -s "$INCUS_CALLS" ]]; then
        fail "$what: incus was called: $(cat "$INCUS_CALLS")"
        return
    fi
    if grep -Evq '^(info|image info)( |$)' "$INCUS_CALLS"; then
        fail "$what: a call that changes something: $(grep -Ev '^(info|image info)( |$)' "$INCUS_CALLS")"
        return
    fi
    if [[ -e "$WORK/evidence" ]]; then
        fail "$what: an evidence directory was made"
        return
    fi
    pass "$what"
}

echo "== refusals before anything"
run 2 "no --authorised" rehearsal-1
run 2 "an --authorised id with a space" --authorised "go ahead" rehearsal-1
run 2 "an unknown release" --authorised r1 --release 0.9 rehearsal-1
run 2 "a step outside the release" --authorised r1 --steps E02 rehearsal-1
run 2 "a bad instance name" --authorised r1 Bad_Name
run 2 "no instance name" --authorised r1
run 2 "an unknown option" --authorised r1 --force rehearsal-1

echo "== an Incus it cannot reach"
run 77 "good arguments, no Incus daemon: a skip after read-only calls" --authorised r1 --steps E00,E01 rehearsal-1
if grep -q 'RESULT: skip' "$WORK/out"; then
    pass "the skip says RESULT: skip"
else
    fail "the skip says RESULT: skip: $(tail -n 1 "$WORK/out")"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
