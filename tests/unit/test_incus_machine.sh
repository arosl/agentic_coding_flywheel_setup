#!/usr/bin/env bash
# ============================================================
# scripts/providers/machine.sh (acfs-ioo3.4.1) against a STUB incus.sh
#
# The stub records its arguments and prints an attach block, so these
# tests prove what `machine.sh up` hands the launcher, what reaches stdout
# and stderr, and what it refuses before running anything.
#
# Usage: bash tests/unit/test_incus_machine.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACHINE="$ROOT/scripts/providers/machine.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-machine.XXXXXX")"
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

# The stub launcher: one line per argument in $WORK/args, the attach block
# on stdout, progress on stderr, and the exit code in $WORK/rc (default 0).
cat >"$WORK/incus.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_WORK/args"
echo "launcher progress" >&2
printf 'Host %s\n' "$1"
exit "$(cat "$STUB_WORK/rc" 2>/dev/null || echo 0)"
STUB
export STUB_WORK="$WORK"

run_machine() {
    RC=0
    rm -f "$WORK/args" "$WORK/rc"
    ACFS_MACHINE_INCUS_SH="$WORK/incus.sh" ACFS_MACHINE_UNAME="${UNAME:-Linux}" \
        bash "$MACHINE" "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
    OUT="$(cat "$WORK/out")"
    ERR="$(cat "$WORK/err")"
}
args() { cat "$WORK/args" 2>/dev/null || true; }

echo "machine up"

run_machine up devbox --ssh-key /keys/a.pub --jump host1
check "the incus target is the default, and the name and options go to the launcher as given" \
    test "$(args)" = "$(printf '%s\n' devbox --ssh-key /keys/a.pub --jump host1)"
check "the launcher's attach block is stdout, and its progress stays on stderr" \
    bash -c '[[ "$1" -eq 0 && "$2" == "Host devbox" ]] && grep -q "launcher progress" <<<"$3"' _ "$RC" "$OUT" "$ERR"

run_machine up --target incus host2:devbox --vm
check "--target incus with a remote: the name keeps its remote, and --vm goes through" \
    test "$(args)" = "$(printf '%s\n' host2:devbox --vm)"

cat >"$WORK/incus.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_WORK/args"
exit 7
STUB
run_machine up devbox
check "the launcher's exit code is machine.sh's" test "$RC" -eq 7
cat >"$WORK/incus.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_WORK/args"
printf 'Host %s\n' "$1"
STUB

run_machine up --target vps myvps
check "the vps target runs nothing, exits 2 and shows the installer's way in" \
    bash -c '[[ "$1" -eq 2 && -z "$2" && -z "$3" ]] \
        && grep -q "README.md, \"Quick Install\"" <<<"$4" && grep -q "scripts/providers/hetzner.md" <<<"$4"' \
        _ "$RC" "$(args)" "$OUT" "$ERR"

run_machine up --target vps myvps --ssh-key k
check "the vps target refuses launcher options" \
    bash -c '[[ "$1" -eq 1 && -z "$2" ]] && grep -q "takes no launcher options" <<<"$3"' _ "$RC" "$(args)" "$ERR"

run_machine up --target cloud devbox
check "an unknown target is refused before the launcher runs" \
    bash -c '[[ "$1" -eq 1 && -z "$2" ]] && grep -q "unknown target: cloud" <<<"$3"' _ "$RC" "$(args)" "$ERR"

run_machine up
check "up without a name is refused" \
    bash -c '[[ "$1" -eq 1 && -z "$2" ]] && grep -q "up needs a machine name" <<<"$3"' _ "$RC" "$(args)" "$ERR"

run_machine up --ssh-key k devbox
check "an option before the name is refused, naming the order" \
    bash -c '[[ "$1" -eq 1 && -z "$2" ]] && grep -q "the machine name comes before the launcher" <<<"$3"' _ "$RC" "$(args)" "$ERR"

UNAME=Darwin run_machine up devbox
check "on macOS the incus target is refused: Colima isn't started yet" \
    bash -c '[[ "$1" -eq 1 && -z "$2" ]] && grep -q "macOS" <<<"$3"' _ "$RC" "$(args)" "$ERR"

run_machine destroy devbox
check "an unknown subcommand is refused" \
    bash -c '[[ "$1" -eq 1 && -z "$2" ]] && grep -q "unknown subcommand: destroy" <<<"$3"' _ "$RC" "$(args)" "$ERR"

run_machine --help
check "--help prints the usage on stdout" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "machine.sh up \[--target incus|vps\] <name>" <<<"$2"' _ "$RC" "$OUT"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
