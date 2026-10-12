#!/usr/bin/env bash
# ============================================================
# install.sh and acfs update ignore a caller's NHM_BIN_DIR (acfs-9hkh.60)
#
# nhm's verified installer runs in a clean environment (env -i), so it
# never sees NHM_BIN_DIR and installs to ~/.local/bin. Every other
# stack.nhm step (verify, enroll, the hook check, the hook lines) reads
# ${NHM_BIN_DIR:-~/.local/bin}; when install or update runs as the target
# user itself, those steps would inherit the caller's value and look
# elsewhere. So both unset it before any step runs.
#
# Usage: bash tests/unit/test_nhm_bin_dir_unset.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
check() {
    local description="$1"
    shift
    if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$description"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$description"; fi
}

# install.sh: an unconditional top-level `unset NHM_BIN_DIR` before main()
# and before the first function that runs a step as the target user.
install_unset_line="$(grep -n '^unset NHM_BIN_DIR$' "$ROOT/install.sh" | head -1 | cut -d: -f1)"
install_main_line="$(grep -n '^main() {' "$ROOT/install.sh" | head -1 | cut -d: -f1)"
install_rat_line="$(grep -n '^run_as_target() {' "$ROOT/install.sh" | head -1 | cut -d: -f1)"
check "install.sh unsets NHM_BIN_DIR at the top level" test -n "$install_unset_line"
check "install.sh unsets it before run_as_target and main are defined" \
    bash -c '(( $1 < $2 && $1 < $3 ))' _ "${install_unset_line:-999999}" "${install_main_line:-0}" "${install_rat_line:-0}"


# update.sh: main() unsets it first, before it runs anything.
update_body="$(awk '/^main\(\) \{/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$ROOT/scripts/lib/update.sh")"
first_stmt="$(grep -v -E '^\s*(#|$)' <<<"$update_body" | sed -n 2p | sed -E 's/^\s+//')"
check "acfs update's main() unsets NHM_BIN_DIR before anything else" test "$first_stmt" = "unset NHM_BIN_DIR"

# acfs-9hkh.84: the acfs CLI (doctor.sh's main(), which runs doctor and
# acfs agents) unsets it first too, and herdr_agents.sh and swarm_status.sh,
# which can also run directly, look for nhm in ~/.local/bin only.
doctor_body="$(awk '/^main\(\) \{/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$ROOT/scripts/lib/doctor.sh")"
doctor_first="$(grep -v -E '^\s*(#|$)' <<<"$doctor_body" | sed -n 2p | sed -E 's/^\s+//')"
check "the acfs CLI's main() unsets NHM_BIN_DIR before anything else" test "$doctor_first" = "unset NHM_BIN_DIR"
for f in scripts/lib/herdr_agents.sh scripts/lib/swarm_status.sh; do
    check "$f reads no NHM_BIN_DIR" bash -c '! grep -v "^\s*#" "$1" | grep -q "NHM_BIN_DIR"' _ "$ROOT/$f"
done

echo
echo "nhm_bin_dir_unset: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
