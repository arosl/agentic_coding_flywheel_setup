#!/usr/bin/env bash
# ============================================================
# Root-owned tool binaries (acfs-u0wy): update_root_tool_ownership in
# scripts/lib/update.sh and check_root_tool_ownership in scripts/lib/doctor.sh
#
# Installs made before acfs-x2c9 left /usr/local/bin/lazygit and
# /usr/local/bin/lazydocker owned by the release tarball's uid. acfs update
# re-owns exactly those two to root:root 0755 when they aren't right; the
# doctor warns. Both read the owner and mode through one function, which
# this test answers for fixture files (no test user can own a file as
# another uid), and the updater's sudo runner is a stub that logs. Nothing
# under /usr/local/bin is read or touched.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_tool_ownership.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
UPDATE="$REPO_ROOT/scripts/lib/update.sh"
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

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

ROOT="$(mktemp -d)"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# The fixture "/usr/local/bin": lazygit and lazydocker exist when their
# files do; OWNERS holds "<path>=<uid>:<mode>" lines the stubbed owner
# lookup answers from.
BIN="$ROOT/bin"
mkdir -p "$BIN"
fixture() { # fixture <name> <uid:mode> | fixture <name> absent
    if [[ "$2" == absent ]]; then
        rm -f "$BIN/$1"
        OWNERS="$(grep -v "^$BIN/$1=" <<<"${OWNERS:-}")"
    else
        : >"$BIN/$1"
        OWNERS="$(grep -v "^$BIN/$1=" <<<"${OWNERS:-}")"$'\n'"$BIN/$1=$2"
    fi
}
reset_fixture() { OWNERS=""; fixture lazygit absent; fixture lazydocker absent; }

# The sudo the updater's real run_cmd_sudo runs: it logs its argv (chown
# root:root <path>, chmod 0755 <path>) and fails the chown of CHOWN_FAILS.
cat >"$ROOT/fakesudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SUDO_LOG"
[[ "$1" != chown || "$3" != "${CHOWN_FAILS:-}" ]] || exit 1
exit 0
STUB
chmod +x "$ROOT/fakesudo"

# run_update: sources update.sh (its guard keeps main from running), points
# the binary list at the fixture, stubs the owner lookup, the sudo prefix
# (the real run_cmd_sudo and run_cmd then run the fake sudo), the read-only
# flag and log_item, and runs update_root_tool_ownership. Env knobs:
# READ_ONLY, NO_SUDO (no sudo prefix at all), CHOWN_FAILS.
run_update() {
    : >"$ROOT/sudo.log"
    OUT="$(
        export HOME="$ROOT/home" TARGET_HOME="$ROOT/home" UPDATE_LOG_FILE="$ROOT/update.log"
        export FAKE_SUDO_LOG="$ROOT/sudo.log"
        mkdir -p "$HOME"
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME
        # shellcheck source=/dev/null
        source "$UPDATE" >/dev/null 2>&1
        DRY_RUN=false VERBOSE=false QUIET=true FAIL_COUNT=0
        UPDATE_ROOT_TOOL_BINARIES=("$BIN/lazygit" "$BIN/lazydocker")
        update_file_owner_mode() { sed -n "s|^$1=||p" <<<"$OWNERS" | tail -n 1; }
        update_is_read_only_mode() { [[ -n "${READ_ONLY:-}" ]]; }
        update_sudo_prefix() {
            local -n _prefix_ref="$1"
            _prefix_ref=()
            [[ -z "${NO_SUDO:-}" ]] || return 1
            _prefix_ref=("$ROOT/fakesudo")
        }
        log_item() { printf 'ITEM %s|%s|%s\n' "$1" "$2" "${3:-}"; }
        update_root_tool_ownership
        printf 'RC %s\n' "$?"
        printf 'FAILS %s\n' "$FAIL_COUNT"
    )"
    SUDO_LOG="$(cat "$ROOT/sudo.log")"
}
sudo_ran() { [[ "$SUDO_LOG" == *"$1"* ]]; }
sudo_ran_nothing() { [[ -z "$SUDO_LOG" ]]; }

# run_doctor: doctor.sh's functions with main stripped, the binary list at
# the fixture and the owner lookup stubbed; prints "id|status|details|fix".
run_doctor() {
    OUT="$(
        OWNERS="$OWNERS" bash -c '
            set +e
            # shellcheck disable=SC1090
            source <(sed "\$d" "$1") >/dev/null 2>&1
            DOCTOR_ROOT_TOOL_BINARIES=("$2/lazygit" "$2/lazydocker")
            doctor_file_owner_mode() { sed -n "s|^$1=||p" <<<"$OWNERS" | tail -n 1; }
            section() { printf "SECTION %s\n" "$1"; }
            check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
            check_root_tool_ownership
            printf "RC %s\n" "$?"
        ' _ "$DOCTOR" "$BIN"
    )"
}

echo "== update: binaries that are root's and 0755 are left alone"
reset_fixture
fixture lazygit 0:755
fixture lazydocker 0:755
run_update
check "returns 0" has "RC 0"
check "reports them as root's" has "ITEM ok|Root-owned tool binaries|lazygit and lazydocker, where installed, are root's"
check "runs no sudo command" sudo_ran_nothing

echo "== update: a binary owned by the tarball's uid is re-owned, the other left alone"
reset_fixture
fixture lazygit 1001:755
fixture lazydocker 0:755
run_update
check "returns 0" has "RC 0"
check "chowns exactly lazygit" sudo_ran "chown root:root $BIN/lazygit"
check "chmods exactly lazygit" sudo_ran "chmod 0755 $BIN/lazygit"
check "leaves lazydocker alone" bash -c '[[ "$1" != *lazydocker* ]]' _ "$SUDO_LOG"
check "reports what it re-owned as a warning, since the contents can't be trusted" has "ITEM warn|Root-owned tool binaries|re-owned root:root 0755: $BIN/lazygit; a binary another uid owned may have been altered, so reinstall it from the pinned release"
check "adds nothing to FAIL_COUNT" has "FAILS 0"

echo "== update: a root-owned binary writable by group or other is re-owned too"
reset_fixture
fixture lazydocker 0:775
run_update
check "chmods lazydocker" sudo_ran "chmod 0755 $BIN/lazydocker"
check "reports it" has "re-owned root:root 0755: $BIN/lazydocker"
reset_fixture
fixture lazygit 0:755
ln -sf /usr/bin/true "$BIN/lazydocker"
run_update
check "a symlink is left alone, whatever its mode" bash -c '[[ "$1" != *lazydocker* ]]' _ "$SUDO_LOG"
check "a symlink is reported as not ACFS's binary" has "ITEM skip|Root-owned tool binaries|left as they are, not the binaries ACFS installs (symlinks): $BIN/lazydocker"
rm -f "$BIN/lazydocker"
reset_fixture
fixture lazydocker 0:4755
run_update
check "a setuid root binary with no group or other write bits is left alone" sudo_ran_nothing

echo "== update: both wrong, both fixed"
reset_fixture
fixture lazygit 1001:755
fixture lazydocker 1001:755
run_update
check "chowns both" bash -c '[[ "$1" == *"chown root:root $2/lazygit"* && "$1" == *"chown root:root $2/lazydocker"* ]]' _ "$SUDO_LOG" "$BIN"
check "reports both" has "re-owned root:root 0755: $BIN/lazygit $BIN/lazydocker"

echo "== update: dry-run changes nothing and says what it would do"
reset_fixture
fixture lazygit 1001:755
READ_ONLY=1 run_update
check "returns 0" has "RC 0"
check "runs no sudo command" sudo_ran_nothing
check "names the path it would re-own" has "ITEM skip|Root-owned tool binaries|dry-run: would chown root:root and chmod 0755: $BIN/lazygit"

echo "== update: without sudo it warns with the command, and never fails the update"
reset_fixture
fixture lazygit 1001:755
NO_SUDO=1 run_update
check "returns 0" has "RC 0"
check "warns with the command to run" has "ITEM warn|Root-owned tool binaries|no sudo to re-own $BIN/lazygit; run: sudo chown root:root <path> && sudo chmod 0755 <path>, then reinstall it from the pinned release"
check "runs no command and adds nothing to FAIL_COUNT" bash -c '[[ -z "$1" && "$2" == *"FAILS 0"* ]]' _ "$SUDO_LOG" "$OUT"
reset_fixture
fixture lazygit 1001:755
fixture lazydocker 1001:755
CHOWN_FAILS="$BIN/lazygit" run_update
check "one failure: the other is still re-owned" has "re-owned root:root 0755: $BIN/lazydocker"
check "one failure: the failed one is named" has "could not re-own $BIN/lazygit;"
check "one failure: counted as one failed command, like any other" has "FAILS 1"

echo "== update: nothing installed, nothing to do"
reset_fixture
run_update
check "returns 0" has "RC 0"
check "reports ok" has "ITEM ok|Root-owned tool binaries|"
check "runs no sudo command" sudo_ran_nothing

echo "== update: the function is called from main after the Agent Mail hook"
OUT="$(grep -E '^    update_(agent_mail_stop_hook|root_tool_ownership|root_agents_md)$' "$UPDATE" | sed 's/^ *//' | tr '\n' ' ')"
check "main calls it between the Stop hook and root AGENTS.md" bash -c '[[ "$1" == "update_agent_mail_stop_hook update_root_tool_ownership update_root_agents_md " ]]' _ "$OUT"

echo "== doctor: root's and 0755 passes"
reset_fixture
fixture lazygit 0:755
fixture lazydocker 0:755
run_doctor
check "returns 0" has "RC 0"
check "opens its section" has "SECTION Root-owned tool binaries"
check "lazygit passes" has "tools.lazygit.owner|pass|root:root, mode 755|"
check "lazydocker passes" has "tools.lazydocker.owner|pass|root:root, mode 755|"

echo "== doctor: the tarball's uid warns, with the fix and the update's role"
reset_fixture
fixture lazygit 1001:755
run_doctor
check "warns that the contents can't be trusted, with the reinstall first" has "tools.lazygit.owner|warn|owned by uid 1001, the release tarball's owner; an account with that uid could have replaced it, so its contents can't be trusted|reinstall it from the pinned release (re-run the installer's tools phase); until then: sudo chown root:root $BIN/lazygit && sudo chmod 0755 $BIN/lazygit, which acfs update does too"
check "says nothing about the absent lazydocker" lacks "lazydocker"

echo "== doctor: a symlink is reported, never judged by its target"
reset_fixture
ln -sf /usr/bin/true "$BIN/lazygit"
run_doctor
check "skips the link" has "tools.lazygit.owner|skip|a symlink, not the binary ACFS installs; left as it is|"
rm -f "$BIN/lazygit"

echo "== doctor: group or other write warns"
reset_fixture
fixture lazydocker 0:775
run_doctor
check "warns on the mode" has "tools.lazydocker.owner|warn|mode 775 lets group or other write it|sudo chmod 0755 $BIN/lazydocker (acfs update does this too)"

echo "== doctor: an unreadable owner warns rather than passes"
reset_fixture
fixture lazygit garbage
run_doctor
check "warns" has "tools.lazygit.owner|warn|stat can't read its owner and mode|"

echo "== doctor: nothing installed prints no section and no check"
reset_fixture
run_doctor
check "returns 0" has "RC 0"
check "prints nothing but the status" bash -c '[[ "$1" == "RC 0" ]]' _ "$OUT"

echo "== doctor: the check is called from main after check_coexistence"
OUT="$(grep -E '^    check_(coexistence|root_tool_ownership|updates_health)$' "$DOCTOR" | sed 's/^ *//' | tr '\n' ' ')"
check "main calls it between check_coexistence and check_updates_health" bash -c '[[ "$1" == "check_coexistence check_root_tool_ownership check_updates_health " ]]' _ "$OUT"

echo "== both lists name the same two binaries"
OUT="$(grep -E '^(UPDATE|DOCTOR)_ROOT_TOOL_BINARIES=' "$UPDATE" "$DOCTOR" | sed 's/^.*=(//; s/)$//' | sort -u | wc -l | tr -d ' ')"
check "update.sh and doctor.sh list the same paths" bash -c '[[ "$1" == 1 ]]' _ "$OUT"

echo
echo "root-owned tool binaries: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
