#!/usr/bin/env bash
# ============================================================
# tests/vm/test_incus_provider.sh's preflight (acfs-ioo3.11) against a STUB
# incus
#
# The real-Incus harness must tell a skip from a pass: each reason it can't
# run (no server, no KVM on the server, no test project) ends in
# "RESULT: skip (...)" and exit 77, never 0. These tests drive the preflight
# only: the stub reports the instance as existing, so the harness stops
# (exit 2) before it would create anything.
#
# Usage: bash tests/unit/test_incus_harness_preflight.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$ROOT/tests/vm/test_incus_provider.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-incus-harness.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# The stub logs each call. FAKE_INFO_RC answers `incus info [<remote>:]`,
# FAKE_DRIVER is /1.0's environment.driver, FAKE_PROJECT_RC answers the
# test project's list, and an instance always exists, so a preflight that
# passes stops at "already exists".
mkdir -p "$WORK/bin"
cat >"$WORK/bin/incus" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
args=("$@")
[[ "${args[0]}" == --project ]] && args=("${args[@]:2}")
case "${args[0]}" in
    info)
        if [[ ${#args[@]} -eq 1 || "${args[1]}" == *: ]]; then exit "${FAKE_INFO_RC:-0}"; fi
        exit 0 ;;
    query) printf '{"environment":{"driver":"%s"}}\n' "${FAKE_DRIVER-lxc | qemu}" ;;
    list) exit "${FAKE_PROJECT_RC:-0}" ;;
    image) exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod 0755 "$WORK/bin/incus"
export CALLS="$WORK/calls"

run_harness() {
    RC=0
    : >"$CALLS"
    PATH="$WORK/bin:$PATH" bash "$HARNESS" "$@" >"$WORK/out" 2>&1 || RC=$?
    OUT="$(cat "$WORK/out")"
}

echo "skips are exit 77, never a pass"
FAKE_DRIVER="lxc" run_harness --vm devbox-vm
check "a server without qemu skips the VM tier with exit 77" \
    bash -c '[[ "$1" -eq 77 && "$2" == *"RESULT: skip (the Incus server here has no qemu driver (lxc)"* ]]' _ "$RC" "$OUT"
FAKE_DRIVER="lxc" run_harness --vm host:probe-1
check "KVM is the remote's: its driver list decides, and the skip names the remote" \
    bash -c '[[ "$1" -eq 77 && "$2" == *"server host has no qemu driver"* ]] && grep -qx "query host:/1.0" "$3"' _ "$RC" "$OUT" "$CALLS"
check "the local /dev/kvm plays no part" bash -c '! grep -q kvm "$1"' _ "$CALLS"
FAKE_INFO_RC=1 run_harness host:probe-2
check "a remote that doesn't answer skips with exit 77" \
    bash -c '[[ "$1" -eq 77 && "$2" == *"RESULT: skip (the remote host doesn"* ]]' _ "$RC" "$OUT"
FAKE_PROJECT_RC=1 run_harness host:probe-2
check "a test project the certificate can't use skips with exit 77" \
    bash -c '[[ "$1" -eq 77 && "$2" == *"the project acfs-tests isn"*"usable on host"* ]]' _ "$RC" "$OUT"

echo "a passing preflight"
run_harness --vm host:probe-1
check "with qemu on the remote, the preflight passes and stops at the existing instance (exit 2)" \
    bash -c '[[ "$1" -eq 2 && "$2" == *"already exists"* && "$2" != *SKIP* ]]' _ "$RC" "$OUT"
check "through a remote, every instance call is in the test project" \
    bash -c 'grep -qx -- "--project acfs-tests list host: -f csv -c n" "$1" && grep -qx -- "--project acfs-tests info host:probe-1" "$1"' _ "$CALLS"
ACFS_TEST_PROJECT=other-tests run_harness host:probe-3
check "ACFS_TEST_PROJECT picks another project" grep -qx -- "--project other-tests info host:probe-3" "$CALLS"
run_harness devbox
check "a local container goes the launcher's way: no test project, no driver probe" \
    bash -c '[[ "$1" -eq 2 ]] && ! grep -q -- "--project" "$2" && ! grep -q "^query" "$2"' _ "$RC" "$CALLS"

echo "arguments"
run_harness
check "no name is a usage error (exit 2)" bash -c '[[ "$1" -eq 2 && "$2" == *Usage:* ]]' _ "$RC" "$OUT"
run_harness host:Bad_Name
check "a name Incus wouldn't take is refused before any call" \
    bash -c '[[ "$1" -eq 2 && ! -s "$2" ]]' _ "$RC" "$CALLS"
run_harness "host:$(printf 'a%.0s' {1..51})"
check "a name over 50 characters is refused (its -over-limit twin must fit)" bash -c '[[ "$1" -eq 2 ]]' _ "$RC"

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0))
