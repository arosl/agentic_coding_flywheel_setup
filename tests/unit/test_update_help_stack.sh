#!/usr/bin/env bash
# ============================================================
# acfs update --help: the stack section names the tools update_stack
# really installs when missing, and lists the guarded ones apart (acfs-bfm)
#
# update_stack installs most stack tools when they are missing, but a tool
# behind `if update_binary_exists X || [[ "$FORCE_MODE" == "true" ]]` is
# opt-in: updated only when installed, or installed with --force. One
# behind `if update_binary_exists X` alone is updated only when installed.
# The guards are read from update_stack itself, so this test follows the
# code, not a second list.
#
# Usage: bash tests/unit/test_update_help_stack.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE="$ROOT/scripts/lib/update.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-update-help.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# Each guarded tool that update_stack installs (its run_cmd calls an
# update_run_* installer, which leaves out steps such as the DCG hook), as
# "force|installed<TAB>binary<TAB>run_cmd label".
guarded_tools() {
    awk '
        /^update_stack\(\)/ { inside = 1; next }
        inside && /^}/ { exit }
        !inside { next }
        match($0, /if update_binary_exists [a-z_]+/) {
            binary = substr($0, RSTART + 24, RLENGTH - 24)
            kind = ($0 ~ /FORCE_MODE/) ? "force" : "installed"
            pending = 4
            next
        }
        pending > 0 {
            pending--
            if (match($0, /run_cmd "[^"]+" update_run_/)) {
                label = substr($0, RSTART + 9)
                sub(/".*/, "", label)
                printf "%s\t%s\t%s\n", kind, binary, label
                pending = 0
            }
        }
    ' "$UPDATE"
}

# Whether $1 names the tool: by its run_cmd label ($2) or its binary in
# capitals ($3), as the help writes JFP for JeffreysPrompts. $4 = list
# matches whole items, one per line; text matches anywhere.
names_tool() {
    local upper="${3^^}"
    if [[ "$4" == list ]]; then
        grep -qxF -e "$2" -e "$upper" <<<"$1"
    else
        grep -qF -e "$2" -e "$upper" <<<"$1"
    fi
}

HOME="$WORK" bash "$UPDATE" --help >"$WORK/help" 2>&1 || true
# The comma-separated items of the stack section's "Installs missing tools"
# list: from that header to the next line that isn't a list line.
always="$(awk '
    /Installs missing tools/ { on = 1; next }
    on && /:/ { exit }
    on && NF { gsub(/^ +/, ""); printf "%s,", $0 }
' "$WORK/help" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' || true)"
stack_section="$(sed -n '/^  stack:/,/^[A-Z]/p' "$WORK/help")"

guards="$(guarded_tools)"
if [[ -n "$guards" && -n "$always" ]]; then
    pass "update_stack's guarded tools and the help's always-installed list are both found"
else
    fail "update_stack's guarded tools and the help's always-installed list are both found"
fi

while IFS=$'\t' read -r kind binary name; do
    [[ -n "$name" ]] || continue
    if names_tool "$always" "$name" "$binary" list; then
        fail "$name ($kind-guarded) is not listed as installed when missing"
    else
        pass "$name ($kind-guarded) is not listed as installed when missing"
    fi
    if names_tool "$stack_section" "$name" "$binary" text; then
        pass "$name is named in the stack section"
    else
        fail "$name is named in the stack section"
    fi
done <<<"$guards"

if grep -q -- '--force' <<<"$stack_section"; then
    pass "the stack section says opt-in tools install with --force"
else
    fail "the stack section says opt-in tools install with --force"
fi

printf '\npassed: %s, failed: %s\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
