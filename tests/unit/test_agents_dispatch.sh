#!/usr/bin/env bash
# ============================================================
# `acfs agents <verb>` (doctor.sh's agents arm) reaches herdr_agents.sh
# for each verb herdr_agents.sh has, export, import and owner included
# (acfs-9hkh.59), and the rest still goes to the agent guide.
#
# A copy of scripts/lib in a temp tree, with a fake herdr_agents.sh that
# prints its arguments, so nothing real runs.
#
# Usage: bash tests/unit/test_agents_dispatch.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-agents-dispatch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/acfs/scripts"
cp -R "$ROOT/scripts/lib" "$WORK/acfs/scripts/lib"
printf '#!/usr/bin/env bash\necho "herdr_agents.sh: $*"\n' > "$WORK/acfs/scripts/lib/herdr_agents.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

agents() {
    TARGET_USER="$(id -un)" bash "$WORK/acfs/scripts/lib/doctor.sh" agents "$@" 2>&1 || true
}

# Every verb herdr_agents.sh's main dispatches, from the real file. Its
# help (help, -h, --help) is not routed: `acfs agents --help` is the
# agent guide's.
mapfile -t VERBS < <(sed -n '/^herdr_agents_main() {/,/^}/p' "$ROOT/scripts/lib/herdr_agents.sh" \
    | grep -oE '^[[:space:]]+[a-z][a-z|-]*\)' | tr -d ' )' | tr '|' '\n' | grep -vxE 'help|-.*' | sort -u)
if [[ ${#VERBS[@]} -ge 10 ]] && printf '%s\n' "${VERBS[@]}" | grep -qx export; then
    pass "read ${#VERBS[@]} verbs from herdr_agents.sh"
else
    fail "read herdr_agents.sh's verbs: ${VERBS[*]}"
fi

for verb in "${VERBS[@]}"; do
    # record-claude is quota's: acfs agents quota record-claude.
    [[ "$verb" == record-claude ]] && continue
    out="$(agents "$verb" --probe)"
    if [[ "$out" == "herdr_agents.sh: $verb --probe" ]]; then
        pass "acfs agents $verb reaches herdr_agents.sh"
    else
        fail "acfs agents $verb: $out"
    fi
done

out="$(agents quota record-claude)"
if [[ "$out" == "herdr_agents.sh: quota record-claude" ]]; then
    pass "acfs agents quota record-claude reaches herdr_agents.sh"
else
    fail "acfs agents quota record-claude: $out"
fi

out="$(agents nosuchverb)"
if [[ "$out" != herdr_agents.sh:* ]]; then
    pass "another word goes to the agent guide, not herdr_agents.sh"
else
    fail "acfs agents nosuchverb reached herdr_agents.sh"
fi

printf '\nagents dispatch: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
