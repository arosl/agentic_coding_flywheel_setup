#!/usr/bin/env bash
# ============================================================
# nhm owns the herdr server on every install (acfs-9hkh.93):
# nhm_hooks.sh owner take.
#
# A fake `nhm` (admin takeover) sits in a fixture home's ~/.local/bin. No
# real nhm, herdr or state is touched.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_nhm_takeover.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/nhm_hooks.sh"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}
check() { # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name" "${OUT:-}"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
lacks() { [[ "$OUT" != *"$1"* ]]; }

ROOT="$(mktemp -d)"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# Only the fake and the system's tools: the host's own nhm stays out of
# every case.
BASEPATH="/usr/bin:/bin"

# fixture [nhm: yes|no]: a fresh home with ACFS's copy of nhm_hooks.sh and
# the fake nhm. The fake's takeover follows ~/nhm-takeover-mode, as nhm
# v0.1.10 answers with --json:
#   fresh     the dry run passes; --yes makes nhm the owner (~/nhm-owner)
#   refuse    exit 2: the Bash keeps tokens and herdr is not running
#   error     exit 1: the Bash's state cannot be exported
#   garbage   exit 1 with no JSON
#   yes-race  the dry run passes; --yes finds nhm the owner already
#   yes-refuse the dry run passes; --yes refuses (the import changed)
# With ~/nhm-owner, every dry run exits 2: nhm owns it already. It records
# each call, and the ACFS_BIN it got, in ~/nhm-calls.
fixture() {
    HOMEDIR="$(mktemp -d -p "$ROOT")"
    mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/.acfs/scripts/lib" "$HOMEDIR/.config/herdr"
    cp "$HELPER" "$HOMEDIR/.acfs/scripts/lib/nhm_hooks.sh"
    if [[ "${1:-yes}" == yes ]]; then
        cat >"$HOMEDIR/.local/bin/nhm" <<'EOF'
#!/usr/bin/env bash
printf '%s ACFS_BIN=%s\n' "$*" "${ACFS_BIN-unset}" >>"$HOME/nhm-calls"
[[ "$1 $2" == "admin takeover" ]] || exit 1
reply() { # reply <exit> <owner> <generation> <error or "">
    jq -n --arg o "$2" --argjson g "$3" --arg e "$4" \
        '{schema: "nhm.v1", command: "admin takeover", result: {dry_run: false, owner: {owner: $o, generation: $g},
          bindings: {dry_run: false, items: [], imported: 0, warnings: []}, tokens: [], wake: [], keep: [], excluded: [], notes: []},
          warnings: [], error: (if $e == "" then null else $e end)}'
    exit "$1"
}
if [[ -e "$HOME/nhm-owner" ]]; then
    reply 2 nhm 1 "refused: nhm owns the instance already (generation 1)"
fi
case "$(cat "$HOME/nhm-takeover-mode" 2>/dev/null)" in
    fresh)
        [[ "$3" == --yes ]] || reply 0 acfs-bash 0 ""
        : >"$HOME/nhm-owner"
        reply 0 nhm 1 "" ;;
    refuse) reply 2 acfs-bash 0 "refused: herdr is not running, and the Bash keeps 2 tokens and 0 wake entries: start herdr, so the takeover can import its agents" ;;
    error) reply 1 "" 0 "the Bash's state cannot be exported: acfs agents export: exec: \"acfs\": executable file not found in \$PATH" ;;
    garbage) echo "panic: boom" >&2; exit 1 ;;
    yes-race)
        [[ "$3" == --yes ]] || reply 0 acfs-bash 0 ""
        reply 2 nhm 1 "refused: core: nhm owns the instance already" ;;
    yes-refuse)
        [[ "$3" == --yes ]] || reply 0 acfs-bash 0 ""
        reply 2 acfs-bash 0 "the import changed between the check and the takeover (the Bash stays the owner)" ;;
    *) exit 1 ;;
esac
EOF
        chmod +x "$HOMEDIR/.local/bin/nhm"
    fi
    echo fresh >"$HOMEDIR/nhm-takeover-mode"
}

helper() { # helper <args...>: ACFS's copy of the helper in the fixture home; sets OUT and RC
    RC=0
    OUT="$(env -u ACFS_BIN -u ACFS_HOME PATH="$BASEPATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_DATA_HOME="" \
        "${HELPER_ENV[@]}" bash "$HOMEDIR/.acfs/scripts/lib/nhm_hooks.sh" "$@" 2>&1)" || RC=$?
}
HELPER_ENV=()
calls() { cat "$HOMEDIR/nhm-calls" 2>/dev/null; }
mode() { echo "$1" >"$HOMEDIR/nhm-takeover-mode"; }
SOCK_ARGS() { printf -- '--socket %s/.config/herdr/herdr.sock --json' "$HOMEDIR"; }

echo "nhm_hooks.sh owner take"

fixture no
helper owner take
check "no nhm: exit 3" bash -c '[[ "$1" -eq 3 && "$2" == "nhm_hooks: nhm is not installed" ]]' _ "$RC" "$OUT"

fixture
helper owner take
check "a fresh install: exit 0, nhm owns the server now" \
    bash -c '[[ "$1" -eq 0 && "$2" == "nhm_hooks: nhm owns the default herdr server now (generation 1; agents imported: 0)" ]]' _ "$RC" "$OUT"
check "the dry run first, then --yes, both for the default server's socket" \
    test "$(calls | cut -d' ' -f1-6)" = "$(printf 'admin takeover --dry-run %s\nadmin takeover --yes %s' "$(SOCK_ARGS)" "$(SOCK_ARGS)")"
check "with no acfs command of ACFS's own, nhm finds acfs on PATH" \
    bash -c '[[ "$(head -n 1 <<<"$1")" == *" ACFS_BIN=" ]]' _ "$(calls)"
: >"$HOMEDIR/nhm-calls"
helper owner take
check "run again: exit 0, nhm owns it already" \
    bash -c '[[ "$1" -eq 0 && "$2" == "nhm_hooks: nhm owns the default herdr server already" ]]' _ "$RC" "$OUT"
check "and no --yes" bash -c '[[ "$1" != *"--yes"* ]]' _ "$(calls)"

fixture
mkdir -p "$HOMEDIR/.acfs/bin"
printf '#!/usr/bin/env bash\n' >"$HOMEDIR/.acfs/bin/acfs"
chmod +x "$HOMEDIR/.acfs/bin/acfs"
helper owner take
check "ACFS's acfs command: nhm exports the Bash's state with it" \
    bash -c '[[ "$(head -n 1 <<<"$1")" == *" ACFS_BIN=$2/.acfs/bin/acfs" ]]' _ "$(calls)" "$HOMEDIR"
fixture
HELPER_ENV=(ACFS_BIN=/opt/acfs/bin/acfs)
helper owner take
check "ACFS_BIN set: kept" bash -c '[[ "$(head -n 1 <<<"$1")" == *" ACFS_BIN=/opt/acfs/bin/acfs" ]]' _ "$(calls)"
HELPER_ENV=()

fixture
mode refuse
helper owner take
check "a refusal: exit 5, nhm's reason, and the dry run to see it all" \
    bash -c '[[ "$1" -eq 5 && "$2" == "nhm_hooks: nhm'"'"'s takeover refused, so ACFS'"'"'s Bash keeps the default herdr server: refused: herdr is not running, and the Bash keeps 2 tokens"*"; see: $3/.local/bin/nhm admin takeover --dry-run --socket $3/.config/herdr/herdr.sock" ]]' \
    _ "$RC" "$OUT" "$HOMEDIR"
check "and no --yes" bash -c '[[ "$1" != *"--yes"* ]]' _ "$(calls)"

fixture
mode error
helper owner take
check "a failed dry run: exit 1 with nhm's error, no --yes" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"takeover failed, so ACFS'"'"'s Bash keeps"*"cannot be exported"* && "$3" != *"--yes"* ]]' \
    _ "$RC" "$OUT" "$(calls)"
mode garbage
helper owner take
check "no JSON: exit 1, naming the pass and its exit" \
    bash -c '[[ "$1" -eq 1 && "$2" == *": nhm admin takeover --dry-run exited 1" ]]' _ "$RC" "$OUT"

fixture
mode yes-race
helper owner take
check "nhm became the owner between the passes: exit 0, already" \
    bash -c '[[ "$1" -eq 0 && "$2" == *"owns the default herdr server already" ]]' _ "$RC" "$OUT"
fixture
mode yes-refuse
helper owner take
check "--yes refuses after the dry run passed: exit 5 with its reason" \
    bash -c '[[ "$1" -eq 5 && "$2" == *"refused, so ACFS'"'"'s Bash keeps"*"the import changed"* ]]' _ "$RC" "$OUT"

fixture
helper owner
check "owner with no verb: usage, exit 2" test "$RC" -eq 2
helper owner take --yes
check "owner take takes no arguments: exit 2, no nhm call" bash -c '[[ "$1" -eq 2 && ! -e "$2/nhm-calls" ]]' _ "$RC" "$HOMEDIR"

echo
echo "nhm takeover: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
