#!/usr/bin/env bash
# ============================================================
# The command palette's herdr ports (acfs-x6b) survive a sync.
#
# scripts/sync/sync_ntm_palette.sh takes the palette from the ntm repo
# but keeps the fork's header and its herdr versions of the prompts that
# called ntm. This checks that overlay on fixtures (no network), and
# that the shipped palette sends no prompt that runs ntm.
#
# Run with: bash tests/unit/test_sync_ntm_palette.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
SYNC_SH="$REPO_ROOT/scripts/sync/sync_ntm_palette.sh"
PALETTE="$REPO_ROOT/acfs/onboard/docs/ntm/command_palette.md"

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}

# shellcheck source=scripts/sync/sync_ntm_palette.sh
source "$SYNC_SH"
# The script sets -euo pipefail for its own run; this test checks
# failing calls, so turn errexit back off.
set +e

work="$(mktemp -d)"
cleanup() { rm -f "$work"/*.md "$work"/err; rmdir "$work"; }
trap cleanup EXIT

# A fork palette and an upstream palette that differ in the header, in a
# fork-owned prompt, in a prompt the fork doesn't own, and by one prompt
# only upstream has.
cat > "$work/fork.md" <<'EOF'
# Fork header
# about herdr

## Ensemble

### ensemble_list | Ensemble Presets (Core)
Fork text: run acfs agents list.

### ensemble_status | Ensemble Status
Fork status text.

## Docs

### fresh_review | Fresh Review
Old review text.

### check_project_inbox | Check Project Inbox
Fork inbox text.
EOF

cat > "$work/upstream.md" <<'EOF'
# NTM Command Palette
# about ntm palette

## Ensemble

### ensemble_list | Ensemble Presets (Core)
Run `ntm ensemble list`.

### ensemble_status | Ensemble Status
Run `ntm ensemble status`.

## Docs

### fresh_review | Fresh Review
New review text from upstream.

### brand_new | Brand New
Only upstream has this.

### check_project_inbox | Check Project Inbox
Run 'ntm mail inbox'.
EOF

# Only the keys the fixtures carry are fork-owned here.
PALETTE_FORK_KEYS="ensemble_list ensemble_status check_project_inbox"
merged="$(palette_overlay_fork_prompts "$work/fork.md" "$work/upstream.md" 2>"$work/err")"
rc=$?

if [[ "$rc" -eq 0 && ! -s "$work/err" ]]; then
    pass "overlay succeeds when every fork-owned prompt is upstream"
else
    fail "overlay succeeds when every fork-owned prompt is upstream" "rc=$rc $(<"$work/err")"
fi

if [[ "$merged" == "# Fork header"$'\n'"# about herdr"$'\n\n'"## Ensemble"* ]]; then
    pass "the fork's header replaces upstream's"
else
    fail "the fork's header replaces upstream's" "${merged:0:80}"
fi

if [[ "$merged" == *"Fork text: run acfs agents list."* && "$merged" == *"Fork status text."* \
    && "$merged" == *"Fork inbox text."* && "$merged" != *"ntm"* ]]; then
    pass "fork-owned prompts keep the fork's text, and no ntm text survives"
else
    fail "fork-owned prompts keep the fork's text, and no ntm text survives" "$merged"
fi

if [[ "$merged" == *"New review text from upstream."* && "$merged" != *"Old review text."* \
    && "$merged" == *"### brand_new | Brand New"$'\n'"Only upstream has this."* ]]; then
    pass "prompts the fork doesn't own, and new ones, come from upstream"
else
    fail "prompts the fork doesn't own, and new ones, come from upstream" "$merged"
fi

# Upstream drops a fork-owned prompt: warn and fail, so a sync stops.
grep -v -e '^### ensemble_status' -e '^Run `ntm ensemble status`' "$work/upstream.md" > "$work/dropped.md"
palette_overlay_fork_prompts "$work/fork.md" "$work/dropped.md" >/dev/null 2>"$work/err"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'fork-owned prompt ensemble_status is not in the upstream palette' "$work/err"; then
    pass "a fork-owned prompt missing upstream is reported and fails the overlay"
else
    fail "a fork-owned prompt missing upstream is reported and fails the overlay" "rc=$rc $(<"$work/err")"
fi

# ------------------------------------------------------------
# The shipped palette
# ------------------------------------------------------------
PALETTE_FORK_KEYS="$(sed -n 's/^PALETTE_FORK_KEYS="\(.*\)"$/\1/p' "$SYNC_SH")"
missing=""
for key in $PALETTE_FORK_KEYS; do
    grep -q "^### $key | " "$PALETTE" || missing+="$key "
done
if [[ -n "$PALETTE_FORK_KEYS" && -z "$missing" ]]; then
    pass "every fork-owned key is a prompt in the shipped palette"
else
    fail "every fork-owned key is a prompt in the shipped palette" "missing: ${missing:-PALETTE_FORK_KEYS unset}"
fi

ntm_lines="$(grep -n -E '`ntm |'"'"'ntm |^Run ntm ' "$PALETTE" || true)"
if [[ -z "$ntm_lines" ]]; then
    pass "no palette prompt asks the agent to run ntm"
else
    fail "no palette prompt asks the agent to run ntm" "$ntm_lines"
fi

# The shipped palette is its own fixed point: overlaying it on itself
# changes nothing, so a sync with no upstream change is a no-op.
if palette_overlay_fork_prompts "$PALETTE" "$PALETTE" 2>/dev/null | cmp -s - "$PALETTE"; then
    pass "overlaying the shipped palette on itself is a no-op"
else
    fail "overlaying the shipped palette on itself is a no-op"
fi

printf '\nTests passed: %d\nTests failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
