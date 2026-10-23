#!/usr/bin/env bash
# ============================================================
# Root-owned tool binaries (acfs-u0wy): update_root_tool_ownership in
# scripts/lib/update.sh and check_root_tool_ownership in scripts/lib/doctor.sh
#
# Installs made before acfs-x2c9 left /usr/local/bin/lazygit and
# /usr/local/bin/lazydocker owned by the release tarball's uid. acfs update
# and the doctor warn about exactly those two when they aren't right, and
# name the reinstall from the pinned release; neither changes them
# (acfs-ea2d). That command is the same in both: --no-deps, and the mode
# the install's state.json records, safe when it records none. doctor --fix
# lists it as a manual fix. Both read the owner and mode through one
# function, which this test answers for fixture files (no test user can own
# a file as another uid), and the updater's sudo is a stub that logs, so
# the test proves nothing runs as root. Nothing under /usr/local/bin is
# read or touched.
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

# The install's state.json, the target user's ~/.acfs/state.json for both
# update.sh and the doctor: state_mode vibe|safe writes that mode, none a
# state without one, and anything else that string as the mode.
STATE="$ROOT/home/.acfs/state.json"
mkdir -p "${STATE%/*}"
state_mode() { # state_mode <mode>|none [file]
    local file="${2:-$STATE}"
    if [[ "$1" == none ]]; then
        printf '{\n  "version": "0.0.0",\n  "target_user": "nobody"\n}\n' >"$file"
    else
        printf '{\n  "version": "0.0.0",\n  "mode": "%s"\n}\n' "$1" >"$file"
    fi
}
state_mode vibe

# The fix command both print: fix_cmd <name> <mode> [owner].
fix_cmd() {
    printf 'curl -fsSL https://raw.githubusercontent.com/%s/agentic_coding_flywheel_setup/main/install.sh | bash -s -- --yes --mode %s --no-deps --force-reinstall --only tools.%s' "${3:-arosl}" "$2" "$1"
}
NOTE="reinstall it from the pinned release (this also brings ACFS up to date from main): "

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
# READ_ONLY, NO_SUDO (no sudo prefix at all), CHOWN_FAILS, EXPLICIT_STATE
# (exported as ACFS_STATE_FILE).
run_update() {
    : >"$ROOT/sudo.log"
    OUT="$(
        export HOME="$ROOT/home" TARGET_HOME="$ROOT/home" UPDATE_LOG_FILE="$ROOT/update.log"
        export FAKE_SUDO_LOG="$ROOT/sudo.log"
        mkdir -p "$HOME"
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME ACFS_STATE_FILE
        [[ -z "${EXPLICIT_STATE:-}" ]] || export ACFS_STATE_FILE="$EXPLICIT_STATE"
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
# The doctor takes the current user's home from passwd, whatever HOME
# says, so its state.json lookup is led to the fixture by setting the home
# it resolved.
run_doctor() {
    OUT="$(
        OWNERS="$OWNERS" HOME="$ROOT/home" bash -c '
            set +e
            # shellcheck disable=SC1090
            source <(sed "\$d" "$1") >/dev/null 2>&1
            _acfs_doctor_current_home="$3"
            DOCTOR_ROOT_TOOL_BINARIES=("$2/lazygit" "$2/lazydocker")
            doctor_file_owner_mode() { sed -n "s|^$1=||p" <<<"$OWNERS" | tail -n 1; }
            section() { printf "SECTION %s\n" "$1"; }
            check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
            check_root_tool_ownership
            printf "RC %s\n" "$?"
        ' _ "$DOCTOR" "$BIN" "$ROOT/home"
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

FIX_LAZYGIT="$(fix_cmd lazygit vibe)"
FIX_LAZYDOCKER="$(fix_cmd lazydocker vibe)"

echo "== update: a binary owned by the tarball's uid is reported, never re-owned (acfs-ea2d)"
reset_fixture
fixture lazygit 1001:755
fixture lazydocker 0:755
run_update
check "returns 0" has "RC 0"
check "runs no sudo command: re-owning would make it look trusted" sudo_ran_nothing
check "warns about exactly lazygit, naming the reinstall from the pinned release and that it updates ACFS" has "ITEM warn|Root-owned tool binaries|$BIN/lazygit is owned by uid 1001, so another account could have replaced it; $NOTE$FIX_LAZYGIT"
check "says nothing of the root-owned lazydocker" lacks "$BIN/lazydocker is"
check "adds nothing to FAIL_COUNT" has "FAILS 0"

echo "== update: a root-owned binary writable by group or other is reported too"
reset_fixture
fixture lazydocker 0:775
run_update
check "runs no sudo command" sudo_ran_nothing
check "warns, naming the mode and the lazydocker reinstall" has "ITEM warn|Root-owned tool binaries|$BIN/lazydocker is writable by group or other (mode 775), so another account could have replaced it; $NOTE$FIX_LAZYDOCKER"
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
check "a setuid root binary with no group or other write bits passes" has "ITEM ok|Root-owned tool binaries|"

echo "== update: both wrong, both reported"
reset_fixture
fixture lazygit 1001:755
fixture lazydocker 1001:755
run_update
check "warns about lazygit" has "$BIN/lazygit is owned by uid 1001"
check "warns about lazydocker" has "$BIN/lazydocker is owned by uid 1001"
check "runs no sudo command" sudo_ran_nothing

echo "== update: dry-run and no sudo say the same, and run nothing"
reset_fixture
fixture lazygit 1001:755
READ_ONLY=1 run_update
check "dry-run: returns 0 and runs nothing" bash -c '[[ "$1" == *"RC 0"* && -z "$2" ]]' _ "$OUT" "$SUDO_LOG"
check "dry-run: the same warning" has "$BIN/lazygit is owned by uid 1001, so another account could have replaced it"
NO_SUDO=1 run_update
check "no sudo: the same warning, nothing failed" bash -c '[[ "$1" == *"is owned by uid 1001"* && "$1" == *"FAILS 0"* && -z "$2" ]]' _ "$OUT" "$SUDO_LOG"

echo "== update: the fix command follows the repository owner"
reset_fixture
fixture lazygit 1001:755
ACFS_REPO_OWNER=someone run_update
check "names that owner's install.sh" has "$(fix_cmd lazygit vibe someone)"

echo "== update: the fix command keeps the install's mode; safe when state.json names none (acfs-ea2d)"
reset_fixture
fixture lazygit 1001:755
state_mode safe
run_update
check "a safe install: --mode safe" has "$NOTE$(fix_cmd lazygit safe)"
state_mode none
run_update
check "no mode in state.json: --mode safe, never install.sh's vibe default" has "$NOTE$(fix_cmd lazygit safe)"
state_mode 'vibe --only tools.docker'
run_update
check "a mode that is neither vibe nor safe: --mode safe, the value never reaches the command" has "$NOTE$(fix_cmd lazygit safe)"
state_mode vibe
state_mode safe "$ROOT/explicit.json"
EXPLICIT_STATE="$ROOT/explicit.json" run_update
check "ACFS_STATE_FILE comes before ~/.acfs/state.json" has "$NOTE$(fix_cmd lazygit safe)"
rm -f "$ROOT/explicit.json"
run_update
check "--no-deps keeps --force-reinstall to the one module" has "--no-deps --force-reinstall --only tools.lazygit"

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

echo "== doctor: the tarball's uid warns, and the fix is the reinstall"
reset_fixture
fixture lazygit 1001:755
run_doctor
check "warns that the contents can't be trusted; the fix reinstalls from the pinned release and updates ACFS" has "tools.lazygit.owner|warn|owned by uid 1001, the release tarball's owner; an account with that uid could have replaced it, so its contents can't be trusted. The fix reinstalls it from the pinned release (this also brings ACFS up to date from main)|$FIX_LAZYGIT"
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
check "warns on the mode; the fix is the reinstall" has "tools.lazydocker.owner|warn|mode 775 lets group or other write it, so its contents can't be trusted. The fix reinstalls it from the pinned release (this also brings ACFS up to date from main)|$FIX_LAZYDOCKER"

echo "== doctor: the fix command keeps the install's mode; safe when state.json names none (acfs-ea2d)"
reset_fixture
fixture lazygit 1001:755
state_mode safe
run_doctor
check "a safe install: --mode safe" has "|$(fix_cmd lazygit safe)"
state_mode none
run_doctor
check "no mode in state.json: --mode safe, never the vibe ACFS_MODE falls back to" has "|$(fix_cmd lazygit safe)"
state_mode 'vibe --only tools.docker'
run_doctor
check "a mode that is neither vibe nor safe: --mode safe" has "|$(fix_cmd lazygit safe)"
state_mode vibe
ACFS_REPO_OWNER=someone run_doctor
check "names the repository owner's install.sh" has "|$(fix_cmd lazygit vibe someone)"

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

echo "== update and the doctor print the same fix command (acfs-ea2d)"
for mode in vibe safe none bogus; do
    reset_fixture
    fixture lazydocker 1001:755
    state_mode "$mode"
    run_update
    UPDATE_FIX="$(grep -F 'ITEM warn|' <<<"$OUT")"
    UPDATE_FIX="${UPDATE_FIX#*"$NOTE"}"
    run_doctor
    DOCTOR_FIX="$(sed -n 's/^tools\.lazydocker\.owner|warn|[^|]*|//p' <<<"$OUT")"
    check "state.json mode $mode: the same command" bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "$UPDATE_FIX" "$DOCTOR_FIX"
done
state_mode vibe

echo "== doctor --fix lists the reinstall as a manual fix, without --yes"
OUT="$(
    HOME="$ROOT/home" SCRIPT_DIR="$REPO_ROOT/scripts/lib" bash -c '
        set +e
        # shellcheck disable=SC1090,SC1091
        source "$1/scripts/lib/autofix.sh" >/dev/null 2>&1
        # shellcheck disable=SC1090,SC1091
        source "$1/scripts/lib/doctor_fix.sh" >/dev/null 2>&1
        DOCTOR_FIX_YES=false
        doctor_fix_log() { printf "LOG %s\n" "$*"; }
        dispatch_fix tools.lazygit.owner warn "$2"
        dispatch_fix tools.lazydocker.owner pass ""
        printf "MANUAL %s SKIPPED %s APPLIED %s\n" "$FIX_MANUAL" "$FIX_SKIPPED" "$FIX_APPLIED"
        print_fix_summary
    ' _ "$REPO_ROOT" "$FIX_LAZYGIT"
)"
check "counts one manual fix, applies and skips nothing" has "MANUAL 1 SKIPPED 0 APPLIED 0"
check "is not left as a warning for --yes" lacks "warning left as-is"
check "names the check and says the command updates ACFS" has "[tools.lazygit.owner] Reinstall it from the pinned release (this also brings ACFS up to date from main)"
check "prints the command whole, pipe and all" has "Run: $FIX_LAZYGIT"
check "says nothing of a passing check" lacks "tools.lazydocker.owner"

echo "== both lists name the same two binaries"
OUT="$(grep -E '^(UPDATE|DOCTOR)_ROOT_TOOL_BINARIES=' "$UPDATE" "$DOCTOR" | sed 's/^.*=(//; s/)$//' | sort -u | wc -l | tr -d ' ')"
check "update.sh and doctor.sh list the same paths" bash -c '[[ "$1" == 1 ]]' _ "$OUT"

echo
echo "root-owned tool binaries: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
