#!/usr/bin/env bash
# ============================================================
# doctor's tool.sg check when ~/.local/bin/ast-grep is ast-grep's sg
# launcher (acfs-zbrk)
#
# The launcher runs `ast-grep` from PATH, itself, until fork fails, so the
# check must recognise it without running it, and must not probe sg either.
# doctor.sh ends in `main "$@"`, so its functions are loaded with that line
# stripped, as the other doctor tests do.
#
# Usage: bash tests/unit/test_doctor_ast_grep_launcher.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-ast-grep.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check_case() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

# Each stand-in leaves a marker when it runs. The launcher carries the real
# launcher's banner.
write_launcher() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\n# WARNING: `sg` is deprecated. Use `ast-grep` instead.\ntouch "%s/ran"\n' "$WORK" >"$1"
    chmod +x "$1"
}
write_real() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho "ast-grep 0.50.0"\n' >"$1"
    chmod +x "$1"
}

# Run the check with doctor's functions loaded in a fresh home, and the
# collector replaced; prints "id|status|details|fix".
run_check() {
    local home="$1"
    rm -f "$WORK/ran"
    HOME="$home" bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$HOME"; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_ast_grep
    ' _ "$DOCTOR"
}

echo "tool.sg"

home="$WORK/launcher-home"
write_launcher "$home/.local/bin/ast-grep"
write_real "$home/.cargo/bin/ast-grep"
write_launcher "$home/.cargo/bin/sg"
out="$(run_check "$home")"
check_case "a launcher at ~/.local/bin/ast-grep fails, naming the fix" \
    bash -c '[[ "$1" == "tool.sg|fail|$2/.local/bin/ast-grep is ast-grep'"'"'s sg launcher"*"|acfs update"* ]]' _ "$out" "$home"
check_case "neither the launcher nor sg is run" test ! -e "$WORK/ran"

home="$WORK/real-home"
write_real "$home/.local/bin/ast-grep"
write_real "$home/.cargo/bin/sg"
out="$(run_check "$home")"
check_case "a real ast-grep passes through check_command" \
    bash -c '[[ "$1" == "tool.sg|pass|installed|"* ]]' _ "$out"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
