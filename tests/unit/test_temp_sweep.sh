#!/usr/bin/env bash
# ============================================================
# scripts/lib/temp_sweep.sh (acfs agents sweep) against a fixture
# temp dir
#
# Proves the sweep removes only stale entries with a test's temp name,
# and keeps what is recent, in use by a process (cwd or open file),
# a git worktree, a symlink, or named like an agent's own files.
#
# Usage: bash tests/unit/test_temp_sweep.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWEEP="$ROOT/scripts/lib/temp_sweep.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-temp-sweep-test.XXXXXX")"
PIDS=()
cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
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

D="$WORK/tmp"
OUT="$WORK/out"
ERR="$WORK/err"

age() {
    find "$1" -exec touch -h -d '10 hours ago' {} +
}

# A fresh fixture temp dir: what each entry is, in its name.
make_fixture() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    PIDS=()
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$D"
    mkdir -p "$D" "$WORK/elsewhere"

    mkdir -p "$D/tmp.Stale1" "$D/acfs-read-only-test-Ab12Cd/locked/inner"
    printf 'x\n' >"$D/tmp.Stale1/file"
    printf 'x\n' >"$D/acfs-read-only-test-Ab12Cd/locked/inner/file"
    mkdir -p "$D/acfs-fixture-repo-Ef34Gh/repo/.git" "$D/acfs-gate-wt-Ij56Kl/wt"
    printf 'gitdir: /somewhere/.git/worktrees/wt\n' >"$D/acfs-gate-wt-Ij56Kl/wt/.git"
    mkdir -p "$D/tmp.InUse1/sub" "$D/tmp.OpenF1" "$D/tmp.Nested1/deep"
    printf 'x\n' >"$D/tmp.OpenF1/held"
    printf 'x\n' >"$D/tmp.Nested1/deep/new"
    mkdir -p "$D/acfs-plans/round" "$D/old-cache" "$D/playwright-artifacts-Mn78Op"
    mkdir -p "$D/acfs-policy-lint-test-artifacts-20261010-171000-4242"
    printf 'x\n' >"$D/swiftbasin-gate.log"
    printf 'x\n' >"$D/.0a1b2c3d-1.node-gyp"
    ln -s "$WORK/elsewhere" "$D/tmp.Link01"
    mkdir -p "$D/tmp.Fresh1"

    age "$D"
    touch -h -d '10 hours ago' "$WORK/elsewhere"
    # Recent: the new top-level dir, and a file deep in an old one.
    touch "$D/tmp.Fresh1" "$D/tmp.Nested1/deep/new"
    chmod 0555 "$D/acfs-read-only-test-Ab12Cd/locked" "$D/acfs-read-only-test-Ab12Cd/locked/inner"

    (cd "$D/tmp.InUse1/sub" && exec sleep 300) &
    PIDS+=("$!")
    (exec 3<"$D/tmp.OpenF1/held"; exec sleep 300) &
    PIDS+=("$!")
    # Let both reach their sleep, with cwd and fd in place.
    local tries=0
    while [[ "$(readlink "/proc/${PIDS[0]}/cwd" 2>/dev/null)" != "$D/tmp.InUse1/sub" \
        || ! -e "/proc/${PIDS[1]}/fd/3" ]] && ((tries++ < 50)); do
        sleep 0.1
    done
}

run_sweep() {
    local rc=0
    bash "$SWEEP" "$@" >"$OUT" 2>"$ERR" || rc=$?
    return "$rc"
}

gone() { [[ ! -e "$D/$1" && ! -L "$D/$1" ]]; }
kept() { [[ -e "$D/$1" || -L "$D/$1" ]]; }

echo "temp_sweep: dry run"
make_fixture
check "dry run exits 0" run_sweep --dir "$D" --dry-run
check "dry run lists the stale tmp dir" grep -qx "would remove $D/tmp.Stale1 (.*" "$OUT"
check "dry run removes nothing" kept tmp.Stale1
check "dry run names in-use entries" grep -q "keep    $D/tmp.InUse1 (in use)" "$ERR"

echo "temp_sweep: sweep"
check "sweep exits 0" run_sweep --dir "$D" --hours 6
check "removes a stale mktemp dir" gone tmp.Stale1
check "removes a stale dir with read-only subdirs" gone acfs-read-only-test-Ab12Cd
check "removes a test's own repository" gone acfs-fixture-repo-Ef34Gh
check "removes a stale Playwright artifacts dir" gone playwright-artifacts-Mn78Op
check "removes a stale node-gyp file" gone .0a1b2c3d-1.node-gyp
check "removes a unit test's stale artifacts dir" gone acfs-policy-lint-test-artifacts-20261010-171000-4242
check "keeps a dir that is a process's cwd" kept tmp.InUse1
check "keeps a dir holding an open file" kept tmp.OpenF1
check "keeps a dir with a recent file deep inside" kept tmp.Nested1
check "keeps a recent dir" kept tmp.Fresh1
check "keeps a dir holding a git worktree" kept acfs-gate-wt-Ij56Kl
check "says why it keeps the worktree" grep -q "keep    $D/acfs-gate-wt-Ij56Kl (worktree)" "$ERR"
check "keeps a symlink with a temp name" kept tmp.Link01
check "leaves the symlink's target alone" test -d "$WORK/elsewhere"
check "keeps names that no test makes (plans)" kept acfs-plans
check "keeps names that no test makes (logs)" kept swiftbasin-gate.log
check "keeps an unmatched name without --name-regex" kept old-cache
check "reports what it removed" grep -q "^removed $D/tmp.Stale1 " "$OUT"

echo "temp_sweep: --name-regex and --hours"
check "a caller's regex adds a name" run_sweep --dir "$D" --name-regex '^old-cache$'
check "removes the name the regex matched" gone old-cache
check "--hours above the age keeps everything" run_sweep --dir "$D" --hours 24 --name-regex '^acfs-plans$'
check "keeps a matched name younger than --hours" kept acfs-plans

echo "temp_sweep: usage"
usage_rc() {
    local want="$1" rc=0
    shift
    bash "$SWEEP" "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq "$want" ]]
}
check "--hours 0 is bad usage" usage_rc 2 --dir "$D" --hours 0
check "an unknown option is bad usage" usage_rc 2 --bogus
check "a missing dir is bad usage" usage_rc 2 --dir "$WORK/missing"
check "refuses to sweep /" usage_rc 2 --dir /
check "--help exits 0" usage_rc 0 --help

echo
echo "temp_sweep: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
