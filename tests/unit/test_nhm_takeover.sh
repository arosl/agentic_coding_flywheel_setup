#!/usr/bin/env bash
# ============================================================
# nhm owns the herdr server on every install (acfs-9hkh.93):
# nhm_hooks.sh owner take, install.sh's acfs_install_nhm_owner, update.sh's
# update_nhm_owner, and doctor's stack.nhm.owner check, which reads
# owner.toml in the instance nhm enrolled for the default herdr server.
#
# A fake `nhm` (admin takeover) sits in a fixture home's ~/.local/bin, and
# each doctor case builds nhm's state directory there. No real nhm, herdr
# or state is touched.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_nhm_takeover.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/nhm_hooks.sh"
DOCTOR="$REPO_ROOT/scripts/lib/doctor.sh"

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
# v0.1.17 answers with --json:
#   fresh     the dry run passes; --yes makes nhm the owner (~/nhm-owner)
#   refuse    exit 2: the Bash keeps tokens and herdr is not running
#   error     exit 1: the Bash's state cannot be read
#   garbage   exit 1 with no JSON
#   yes-race  the dry run passes; --yes finds nhm the owner already
#   yes-refuse the dry run passes; --yes refuses (the import changed)
#   refuse-two exit 2 with two reasons on two lines, as nhm joins them
# With ~/nhm-owner, every dry run exits 2: nhm owns it already. It records
# each call in ~/nhm-calls.
fixture() {
    HOMEDIR="$(mktemp -d -p "$ROOT")"
    STATE="$HOMEDIR/.local/state/nhm"
    mkdir -p "$HOMEDIR/.local/bin" "$HOMEDIR/.acfs/scripts/lib" "$HOMEDIR/.config/herdr"
    cp "$HELPER" "$HOMEDIR/.acfs/scripts/lib/nhm_hooks.sh"
    if [[ "${1:-yes}" == yes ]]; then
        cat >"$HOMEDIR/.local/bin/nhm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/nhm-calls"
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
    error) reply 1 "" 0 "the Bash's state cannot be read: open $HOME/.acfs/state/tokens: permission denied" ;;
    garbage) echo "panic: boom" >&2; exit 1 ;;
    yes-race)
        [[ "$3" == --yes ]] || reply 0 acfs-bash 0 ""
        reply 2 nhm 1 "refused: core: nhm owns the instance already" ;;
    yes-refuse)
        [[ "$3" == --yes ]] || reply 0 acfs-bash 0 ""
        reply 2 acfs-bash 0 "the import changed between the check and the takeover (the Bash stays the owner)" ;;
    refuse-two) reply 2 acfs-bash 0 "$(printf 'refused: the token of AlphaFox is not imported\nrefused: the token of BetaOwl is not imported')" ;;
    *) exit 1 ;;
esac
EOF
        chmod +x "$HOMEDIR/.local/bin/nhm"
    fi
    echo fresh >"$HOMEDIR/nhm-takeover-mode"
}

helper() { # helper <args...>: ACFS's copy of the helper in the fixture home; sets OUT and RC
    RC=0
    OUT="$(env -u ACFS_HOME PATH="$BASEPATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_DATA_HOME="" \
        bash "$HOMEDIR/.acfs/scripts/lib/nhm_hooks.sh" "$@" 2>&1)" || RC=$?
}
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
    test "$(calls)" = "$(printf 'admin takeover --dry-run %s\nadmin takeover --yes %s' "$(SOCK_ARGS)" "$(SOCK_ARGS)")"
: >"$HOMEDIR/nhm-calls"
helper owner take
check "run again: exit 0, nhm owns it already" \
    bash -c '[[ "$1" -eq 0 && "$2" == "nhm_hooks: nhm owns the default herdr server already" ]]' _ "$RC" "$OUT"
check "and no --yes" bash -c '[[ "$1" != *"--yes"* ]]' _ "$(calls)"

fixture
mode refuse
helper owner take
check "a refusal: exit 5, nhm's reason, and the dry run to see it all" \
    bash -c '[[ "$1" -eq 5 && "$2" == "nhm_hooks: nhm'"'"'s takeover refused, so the default herdr server'"'"'s owner stays as it was: refused: herdr is not running, and the Bash keeps 2 tokens"*"; see: $3/.local/bin/nhm admin takeover --dry-run --socket $3/.config/herdr/herdr.sock" ]]' \
    _ "$RC" "$OUT" "$HOMEDIR"
check "and no --yes" bash -c '[[ "$1" != *"--yes"* ]]' _ "$(calls)"

fixture
mode error
helper owner take
check "a failed dry run: exit 1 with nhm's error, no --yes" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"takeover failed, so the default herdr server'"'"'s owner stays as it was: the Bash'"'"'s state cannot be read: "* && "$3" != *"--yes"* ]]' \
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
    bash -c '[[ "$1" -eq 5 && "$2" == *"refused, so the default herdr server'"'"'s owner stays as it was: "*"the import changed"* ]]' _ "$RC" "$OUT"
fixture
mode refuse-two
helper owner take
check "a refusal with two reasons: one note line that names both" \
    bash -c '[[ "$1" -eq 5 && "$2" != *$'"'"'\n'"'"'* && "$2" == *"refused, so the default herdr server'"'"'s owner stays as it was: "*"AlphaFox is not imported; refused: the token of BetaOwl"* ]]' _ "$RC" "$OUT"

fixture
helper owner
check "owner with no verb: usage, exit 2" test "$RC" -eq 2
helper owner take --yes
check "owner take takes no arguments: exit 2, no nhm call" bash -c '[[ "$1" -eq 2 && ! -e "$2/nhm-calls" ]]' _ "$RC" "$HOMEDIR"

echo
echo "update.sh: update_nhm_owner"

# run_update [nhm installed: yes|no]: update.sh's function against the
# fixture home, its host helpers stubbed. Env: DRY.
run_update() {
    OUT="$(
        export HOME="$HOMEDIR" PATH="$BASEPATH"
        unset XDG_CONFIG_HOME XDG_DATA_HOME ACFS_HOME
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/update.sh" >/dev/null 2>&1
        NHM_INSTALLED="${1:-yes}"
        update_binary_exists() { [[ "$1" == nhm && "$NHM_INSTALLED" == yes ]]; }
        update_target_user() { printf 'ubuntu\n'; }
        update_target_home() { printf '%s\n' "$HOMEDIR"; }
        update_system_binary_path() { printf '/bin/%s\n' "$1"; }
        update_run_in_target_context() { shift; "$@"; }
        log_item() { printf 'ITEM %s|%s|%s\n' "$1" "$2" "${3:-}"; }
        DRY_RUN="${DRY:-false}"
        update_nhm_owner
        printf 'RC %s\n' "$?"
    )"
}

fixture
DRY=true run_update
check "dry-run: says what it would do, runs no takeover" \
    bash -c '[[ "$1" == *"ITEM skip|herdr server owner|dry-run: would run nhm'"'"'s takeover"* && ! -e "$2/nhm-calls" ]]' _ "$OUT" "$HOMEDIR"
run_update
check "an install the Bash owns: nhm takes it over" \
    has "ITEM ok|herdr server owner|nhm owns the default herdr server now (generation 1; agents imported: 0)"
run_update
check "the next update: nhm owns it already" has "ITEM ok|herdr server owner|nhm owns the default herdr server already"
fixture
mode refuse
run_update
check "a refusal warns with nhm's reason and the dry run, and never fails the update" \
    bash -c '[[ "$1" == *"ITEM warn|herdr server owner|nhm'"'"'s takeover refused, so the default herdr server'"'"'s owner stays as it was: "*"; see: "*"admin takeover --dry-run --socket "*"RC 0"* ]]' _ "$OUT"
mode refuse-two
run_update
check "a refusal with two reasons: the update's warning keeps both" \
    bash -c '[[ "$1" == *"ITEM warn|herdr server owner|nhm'"'"'s takeover refused"*"AlphaFox"*"BetaOwl"* ]]' _ "$OUT"
mode error
run_update
check "a failed takeover warns, and never fails the update" \
    bash -c '[[ "$1" == *"ITEM warn|herdr server owner|nhm'"'"'s takeover failed"*"RC 0"* ]]' _ "$OUT"
fixture
run_update no
check "without nhm: nothing logged, nothing run" bash -c '[[ "$1" != *"ITEM "* && "$1" == *"RC 0"* && ! -e "$2/nhm-calls" ]]' _ "$OUT" "$HOMEDIR"

echo
echo "install.sh: acfs_install_nhm_owner"

# run_install <stack.nhm selected: yes|no>: the function from install.sh,
# with the installer's helpers stubbed; the target user is the caller.
run_install() {
    OUT="$(
        export HOME="$HOMEDIR" PATH="$BASEPATH" ACFS_HOME="$HOMEDIR/.acfs"
        unset XDG_CONFIG_HOME XDG_DATA_HOME
        SELECTED="$1"
        run_as_target() { "$@"; }
        acfs_legacy_module_selected() { [[ "$1" == stack.nhm && "$SELECTED" == yes ]]; }
        log_detail() { printf 'DETAIL %s\n' "$1"; }
        log_warn() { printf 'WARN %s\n' "$1"; }
        # shellcheck source=/dev/null
        source <(sed -n '/^acfs_install_nhm_owner() {/,/^}/p' "$REPO_ROOT/install.sh")
        acfs_install_nhm_owner 2>&1
        printf 'RC %s\n' "$?"
    )"
}

[[ -n "$(sed -n '/^acfs_install_nhm_owner() {/,/^}/p' "$REPO_ROOT/install.sh")" ]] \
    || { echo "install.sh has no acfs_install_nhm_owner" >&2; exit 1; }
fixture
run_install yes
check "a fresh install: nhm owns the server, logged" \
    bash -c '[[ "$1" == *"DETAIL nhm owns the default herdr server now"*"RC 0"* ]]' _ "$OUT"
fixture
mode refuse
run_install yes
check "a refusal warns with nhm's reason, and never fails the install" \
    bash -c '[[ "$1" == *"WARN "*"nhm'"'"'s takeover refused"*"RC 0"* ]]' _ "$OUT"
fixture
run_install no
check "stack.nhm not selected: no takeover, the Bash stays the owner" \
    bash -c '[[ "$1" == "RC 0" && ! -e "$2/nhm-calls" ]]' _ "$OUT" "$HOMEDIR"
# nhm's keys need nhm as the owner.
FINALIZE="$(sed -n '/^finalize() {$/,/^}$/p' "$REPO_ROOT/install.sh")"
OWNER_LINE="$(grep -n '^    acfs_install_nhm_owner$' <<<"$FINALIZE" | cut -d: -f1)"
KEYS_LINE="$(grep -n '^    acfs_install_herdr_keys$' <<<"$FINALIZE" | cut -d: -f1)"
check "finalize: the takeover runs once, before the keys" \
    bash -c '[[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && "$2" -gt "$1" ]]' _ "$OWNER_LINE" "$KEYS_LINE"

echo
echo "doctor: stack.nhm.owner"

# instance <id> <session>: an instance directory as nhm enroll writes it.
instance() {
    local dir="$STATE/$1"
    mkdir -p "$dir"
    printf 'id = "%s"\nsession = "%s"\nsocket_path = "%s"\nenrolled_at = 2026-10-13T20:00:00Z\n' \
        "$1" "$2" "$HOMEDIR/.config/herdr/herdr.sock" >"$dir/instance.toml"
    INST="$dir"
}

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
# run_doctor [nhm present: true|false]: prints "id|status|details|fix".
run_doctor() {
    env PATH="$BASEPATH" STUB_HOME="$HOMEDIR" STUB_NHM="${1:-true}" TARGET_USER="" XDG_STATE_HOME="" bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$STUB_HOME"; }
        doctor_binary_exists() { [[ "$1" == nhm && "$STUB_NHM" == true ]]; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        HOME="$STUB_HOME" check_nhm_owner
    ' _ "$DOCTOR"
}

fixture
OUT="$(run_doctor false)"
check "no nhm: skip, the Bash tools drive agents by choice" has "stack.nhm.owner|skip|nhm not installed: ACFS's Bash tools"
OUT="$(run_doctor)"
check "not enrolled: skip, pointing at the nhm check" has "stack.nhm.owner|skip|nhm is not enrolled for the default herdr server"
instance inst-0123456789ab other
OUT="$(run_doctor)"
check "only another session enrolled: skip" has "stack.nhm.owner|skip|nhm is not enrolled for the default herdr server"
instance inst-abcdefabcdef default
OUT="$(run_doctor)"
check "no owner.toml: the Bash owns it, warn with the takeover and the socket" \
    bash -c '[[ "$1" == "stack.nhm.owner|warn|ACFS'"'"'s Bash tools drive agents"*"|Run: nhm admin takeover --dry-run --socket $2 "*"--yes; acfs update runs both" ]]' \
    _ "$OUT" "$HOMEDIR/.config/herdr/herdr.sock"
printf 'owner = "acfs-bash"\ngeneration = 2\nupdated_at = 2026-10-13T20:00:00Z\n' >"$INST/owner.toml"
OUT="$(run_doctor)"
check "owner acfs-bash (enrolled, no takeover yet): warn" has "stack.nhm.owner|warn|ACFS's Bash tools drive agents"
printf 'owner = "nhm"\ngeneration = 1\nupdated_at = 2026-10-13T20:00:00Z\n' >"$INST/owner.toml"
OUT="$(run_doctor)"
check "owner nhm: pass" has "stack.nhm.owner|pass|nhm drives agents on the default herdr server"
printf "  owner = 'nhm'  # by hand\ngeneration = 1\n" >"$INST/owner.toml"
OUT="$(run_doctor)"
check "owner nhm in single quotes with a comment: pass" has "stack.nhm.owner|pass|"
printf 'owner = "someone"\n' >"$INST/owner.toml"
OUT="$(run_doctor)"
check "an owner neither reads: warn, repair by hand" \
    bash -c '[[ "$1" == "stack.nhm.owner|warn|"*"names neither nhm nor acfs-bash"*"|Repair it by hand"* ]]' _ "$OUT"

fixture
mkdir -p "$STATE/inst-abcdefabcdef.bak"
printf 'id = "inst-abcdefabcdef"\nsession = "default"\n' >"$STATE/inst-abcdefabcdef.bak/instance.toml"
OUT="$(run_doctor)"
check "a copy such as inst-<id>.bak is not an instance" has "stack.nhm.owner|skip|nhm is not enrolled"
check "the doctor runs the check" grep -q '^    check_nhm_owner$' "$DOCTOR"

echo
echo "nhm takeover: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
