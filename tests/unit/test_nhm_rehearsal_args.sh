#!/usr/bin/env bash
# ============================================================
# tests/vm/test_nhm_rehearsal.sh: what it does before it makes anything
#
# The harness runs in a bwrap sandbox, and each run is named and
# authorised (--authorised). It must refuse, with exit 2 and without
# making its sandbox root, when --authorised is missing or any argument is
# wrong, and refuse a root that exists. Nothing here runs the sandbox.
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

SANDBOX="$WORK/sandbox"
# run EXPECTED-EXIT DESCRIPTION ARGS...: the harness with its own sandbox
# root; checks the exit code, and that a refusal made no root.
run() {
    local want="$1" what="$2" rc=0
    shift 2
    NHM_SANDBOX_PARENT="$WORK" bash "$HARNESS" --root "$SANDBOX" "$@" >"$WORK/out" 2>&1 || rc=$?
    if [[ "$rc" -ne "$want" ]]; then
        fail "$what: exit $rc, want $want: $(tail -n 2 "$WORK/out")"
        return
    fi
    if [[ "$want" -eq 2 && -e "$SANDBOX" && ! -e "$WORK/keep" ]]; then
        fail "$what: the sandbox root was made"
        return
    fi
    pass "$what"
}

echo "== refusals before anything"
run 2 "no --authorised" --nhm-version 0.1.2
run 2 "an --authorised id with a space" --authorised "go ahead" --nhm-version 0.1.2
run 2 "no nhm source" --authorised r1
run 2 "two nhm sources" --authorised r1 --nhm-version 0.1.2 --nhm-build "$WORK"
run 2 "a bad nhm version" --authorised r1 --nhm-version latest
run 2 "an unknown release" --authorised r1 --nhm-version 0.1.2 --release 0.9
run 2 "a step outside the release" --authorised r1 --nhm-version 0.1.2 --steps E02
run 2 "an unknown argument" --authorised r1 --nhm-version 0.1.2 --force
run 2 "a positional argument (no instance any more)" --authorised r1 --nhm-version 0.1.2 rehearsal-1
run 2 "--owner with --steps" --authorised r1 --nhm-version 0.1.2 --owner --steps E00
run 2 "--owner with --takeover" --authorised r1 --nhm-version 0.1.2 --owner --takeover

echo "== an existing root"
mkdir -p "$SANDBOX"
: >"$WORK/keep"
run 2 "a sandbox root that exists is refused" --authorised r1 --nhm-version 0.1.2
if [[ -z "$(ls -A "$SANDBOX")" ]]; then
    pass "nothing was written into it"
else
    fail "something was written into it: $(ls -A "$SANDBOX")"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
