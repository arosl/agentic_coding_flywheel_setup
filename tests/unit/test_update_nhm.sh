#!/usr/bin/env bash
# ============================================================
# acfs update installs nhm and registers its hook lines (acfs-9hkh.24):
# update_nhm_pinned_version, update_nhm and update_nhm_hooks in
# scripts/lib/update.sh.
#
# Sources update.sh (its guard keeps main from running), stubs the helpers
# that look at the host or run an installer, and runs the real
# nhm_hooks.sh against a fixture home. No installer runs, and nothing here
# touches the caller's ~/.claude or ~/.codex.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_update_nhm.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

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

# A fake `codex app-server` first on PATH: trust codex talks to it, never
# to a real Codex (FAKE_CODEX_FAIL=1 makes it die).
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$REPO_ROOT/tests/unit/fake_codex_app_server.py" >"$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"

# run_update <function> <installed binaries...>: a fresh fixture home with
# ACFS's copy of nhm_hooks.sh, then the function with the given binaries
# "installed". Env knobs: SAME_USER (default 1), READ_ONLY, NO_HELPER,
# DCG (a ~/.local/bin/dcg), NO_HOOK_BIN (no ~/.local/bin/nhm-hook), PRESEED (ACFS's lines already in
# both files), BIN_DIR (nhm-hook in $FIX_HOME/$BIN_DIR, which NHM_BIN_DIR
# names), PIN_URL (replaces
# KNOWN_INSTALLERS[nhm]), DROP_PIN (a checksums.yaml entry to drop),
# BAD_PIN (an entry whose pin becomes malformed). The repo's checksums.yaml
# stands in for the one update_require_security fetches.
run_update() {
    local fn="$1"; shift
    FIX_HOME="$(mktemp -d -p "$ROOT")"
    mkdir -p "$FIX_HOME/.acfs/scripts/lib" "$FIX_HOME/.claude" "$FIX_HOME/.codex" "$FIX_HOME/.local/bin"
    [[ -n "${NO_HELPER:-}" ]] || cp "$REPO_ROOT/scripts/lib/nhm_hooks.sh" "$FIX_HOME/.acfs/scripts/lib/"
    if [[ -z "${NO_HOOK_BIN:-}" ]]; then
        printf '#!/bin/sh\nexit 0\n' > "$FIX_HOME/.local/bin/nhm-hook"
        chmod 0755 "$FIX_HOME/.local/bin/nhm-hook"
    fi
    printf '{\n  "model": "opus",\n  "hooks": {}\n}\n' > "$FIX_HOME/.claude/settings.json"
    # STATUSLINE: a statusLine command already in Claude Code's settings.
    if [[ -n "${STATUSLINE:-}" ]]; then
        jq --arg c "$STATUSLINE" '.statusLine = {type: "command", command: $c}' "$FIX_HOME/.claude/settings.json" \
            > "$FIX_HOME/.claude/settings.tmp" && mv "$FIX_HOME/.claude/settings.tmp" "$FIX_HOME/.claude/settings.json"
    fi
    if [[ -n "${PRESEED:-}" ]]; then
        HOME="$FIX_HOME" env -u NHM_BIN_DIR bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" register claude "$FIX_HOME/.claude/settings.json" 2>/dev/null
        HOME="$FIX_HOME" env -u NHM_BIN_DIR bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" statusline claude set "$FIX_HOME/.claude/settings.json" 2>/dev/null
        HOME="$FIX_HOME" env -u NHM_BIN_DIR bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" register codex "$FIX_HOME/.codex/hooks.json" 2>/dev/null
    fi
    if [[ -n "${DCG:-}" ]]; then
        printf '#!/bin/sh\nexit 0\n' > "$FIX_HOME/.local/bin/dcg"
        chmod 0755 "$FIX_HOME/.local/bin/dcg"
    fi
    if [[ -n "${BIN_DIR:-}" ]]; then
        mkdir -p "$FIX_HOME/$BIN_DIR"
        printf '#!/bin/sh\nexit 0\n' > "$FIX_HOME/$BIN_DIR/nhm-hook"
        chmod 0755 "$FIX_HOME/$BIN_DIR/nhm-hook"
    fi
    OUT="$(
        export HOME="$FIX_HOME" TARGET_HOME="$FIX_HOME" UPDATE_LOG_FILE="$ROOT/update.log" PATH="$FAKEBIN:$PATH"
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME NHM_BIN_DIR CODEX_HOME
        [[ -z "${BIN_DIR:-}" ]] || export NHM_BIN_DIR="$FIX_HOME/$BIN_DIR"
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/update.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/security.sh" >/dev/null 2>&1
        [[ -z "${PIN_URL:-}" ]] || KNOWN_INSTALLERS["nhm"]="$PIN_URL"
        update_require_security() {
            load_checksums "$REPO_ROOT/checksums.yaml" >/dev/null 2>&1 || return 1
            [[ -z "${DROP_PIN:-}" ]] || unset 'LOADED_CHECKSUMS[$DROP_PIN]'
            [[ -z "${BAD_PIN:-}" ]] || LOADED_CHECKSUMS["$BAD_PIN"]="not-a-sha"
            return 0
        }
        INSTALLED=" $* "
        update_binary_exists() { [[ "$INSTALLED" == *" $1 "* ]]; }
        update_binary_path() { [[ "$INSTALLED" == *" $1 "* ]] && printf '%s\n' "$FIX_HOME/.local/bin/$1"; }
        update_runtime_acfs_home() { printf '%s\n' "$FIX_HOME/.acfs"; }
        update_target_user() { printf 'ubuntu\n'; }
        update_target_home() { printf '%s\n' "$FIX_HOME"; }
        # enroll --json, which update_nhm reads for the socket (NO_SOCKET
        # makes it report none).
        # Each call is logged to $FIX_HOME/target-calls; ENROLL_FAIL makes
        # enroll exit 1.
        update_run_in_target_context() {
            printf '%s\n' "$*" >> "$FIX_HOME/target-calls"
            if [[ " $* " == *" enroll "* && -n "${ENROLL_FAIL:-}" ]]; then
                return 1
            fi
            if [[ " $* " == *" enroll "*" --json "* && -z "${NO_SOCKET:-}" ]]; then
                printf '{"command":"admin instance enroll","result":{"socket_path":"/run/test/herdr.sock"}}\n'
            fi
        }
        update_current_user() { if [[ "${SAME_USER:-1}" == 1 ]]; then printf 'ubuntu\n'; else printf 'root\n'; fi; }
        update_is_read_only_mode() { [[ -n "${READ_ONLY:-}" ]]; }
        capture_version_before() { :; }
        capture_version_after() { return 1; }
        log_detail() { printf 'DETAIL %s\n' "$1"; }
        log_item() { printf 'ITEM %s|%s|%s\n' "$1" "$2" "${3:-}"; }
        run_cmd() { local desc="$1"; shift; printf 'RUN %s: %s\n' "$desc" "$*"; }
        UPDATE_STACK="${STACK:-true}"
        "$fn"
        printf 'RC %s\n' "$?"
    )"
}
registered_in() { HOME="$FIX_HOME" bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" registered "$1" "$2"; }

# ------------------------------------------------------------
# update_nhm: the pinned release, then enroll
# ------------------------------------------------------------
run_update update_nhm nhm
# The archive pins: only in checksums.yaml (acfs-9hkh.47).
NHM_AMD64="linux-amd64=$(awk '/^  nhm_archive_linux_amd64:$/ { f = 1 } f && /sha256:/ { gsub(/[" ]|sha256:/, ""); print; exit }' "$REPO_ROOT/checksums.yaml")"
NHM_ARM64="linux-arm64=$(awk '/^  nhm_archive_linux_arm64:$/ { f = 1 } f && /sha256:/ { gsub(/[" ]|sha256:/, ""); print; exit }' "$REPO_ROOT/checksums.yaml")"
check "update_nhm: installs the release the pinned URL names, with its archive pins from checksums.yaml" \
    has "RUN nhm 0.1.11: update_run_verified_installer nhm --version 0.1.11 --archive-sha256 $NHM_AMD64 --archive-sha256 $NHM_ARM64"

DROP_PIN=nhm_archive_linux_arm64 run_update update_nhm nhm
check "update_nhm: a missing archive pin installs nothing" lacks "RUN nhm 0"
check "update_nhm: and says so" has "ITEM warn|nhm|no pinned nhm archives"
BAD_PIN=nhm_archive_linux_amd64 run_update update_nhm nhm
check "update_nhm: a malformed archive pin installs nothing" lacks "RUN nhm 0"

# The install (stack.nhm's checksum_args) and acfs update read the same
# checksums.yaml entries: one per release archive security.sh knows, each
# at the version the installer URL pins.
manifest_block="$(awk '/^  - id: stack.nhm$/ { m = 1; next } m && /^  - id: / { exit } m' "$REPO_ROOT/acfs.manifest.yaml")"
manifest_args="$(awk '/args:/ { a = 1 } a { print } a && /\]/ { exit }' <<<"$manifest_block" | tr -d '\n ')"
check "each archive pin is <platform>=<64 hex>" \
    bash -c '[[ "$1" =~ ^linux-amd64=[0-9a-f]{64}$ && "$2" =~ ^linux-arm64=[0-9a-f]{64}$ ]]' _ "$NHM_AMD64" "$NHM_ARM64"
check "stack.nhm's checksum_args name each nhm release archive in security.sh, and nothing else" \
    bash -c 'want="$(source "$2/scripts/lib/security.sh" >/dev/null 2>&1
            for n in "${!KNOWN_RELEASE_ARCHIVES[@]}"; do [[ "$n" == nhm_archive_* ]] && printf "%s=%s\n" "${n#nhm_archive_}" "$n"; done | sort)"
        got="$(grep -oE "prefix: \"[a-z0-9-]+=\", checksum: nhm_archive_[a-z0-9_]+" <<<"$1" | sed -E "s/prefix: \"([a-z0-9-]+)=\", checksum: (.*)/\1=\2/; s/-/_/" | sort)"
        [[ -n "$want" && "$want" == "$got" ]] && [[ "$(grep -c -- "flag: \"--archive-sha256\"" <<<"$1")" -eq "$(wc -l <<<"$want")" ]]' \
    _ "$manifest_block" "$REPO_ROOT"
check "security.sh's nhm archive URLs carry the version its installer URL pins" \
    bash -c 'source "$1/scripts/lib/security.sh" >/dev/null 2>&1
        [[ "${KNOWN_INSTALLERS[nhm]}" =~ /v([0-9.]+)/install ]] || exit 1; v="${BASH_REMATCH[1]}"
        for n in "${!KNOWN_RELEASE_ARCHIVES[@]}"; do
            [[ "$n" != nhm_archive_* ]] || [[ "${KNOWN_RELEASE_ARCHIVES[$n]}" == */v$v/nhm-$v-* ]] || exit 1
        done' _ "$REPO_ROOT"
check "stack.nhm's args and installed_check name the version security.sh's URL pins" \
    bash -c 'v="$(source "$4/scripts/lib/security.sh" >/dev/null 2>&1; [[ "${KNOWN_INSTALLERS[nhm]}" =~ /v([0-9.]+)/install ]] && printf %s "${BASH_REMATCH[1]}")"
        [[ -n "$v" && "$1" == *"\"--version\",\"$v\""* ]] && grep -qF "\"version\": \"$v\"" "$4/acfs.manifest.yaml"' \
    _ "$manifest_args" "" "" "$REPO_ROOT"

run_update update_nhm nhm
check "update_nhm: enrolls the default herdr server once, as the target user (acfs-9hkh.89)" \
    bash -c '[[ "$(grep -c " admin instance enroll " "$1")" == 1 ]] &&
        grep -qxF " $2 admin instance enroll --session default --json" "$1"' _ "$FIX_HOME/target-calls" "$FIX_HOME/.local/bin/nhm"
check "update_nhm: runs nhm's restore on the socket enroll reports (acfs-9hkh.40)" \
    has "RUN nhm restore: update_run_in_target_context  $FIX_HOME/.local/bin/nhm admin restore --socket /run/test/herdr.sock"
check "update_nhm: returns 0" has "RC 0"

NO_SOCKET=1 run_update update_nhm nhm
check "update_nhm: no socket from enroll runs no restore" lacks "RUN nhm restore"
check "update_nhm: and says how to run it" has "ITEM warn|nhm|nhm reported no herdr socket"

ENROLL_FAIL=1 run_update update_nhm nhm
check "update_nhm: a failed enroll warns and runs no restore (acfs-9hkh.89)" \
    bash -c '[[ "$1" == *"ITEM warn|nhm|nhm could not enroll"* && "$1" != *"RUN nhm restore"* && "$1" == *"RC 0"* ]]' _ "$OUT"

PIN_URL="https://raw.githubusercontent.com/arosl/nhm/main/install.sh" run_update update_nhm nhm
check "update_nhm: an unpinned URL installs nothing" lacks "RUN nhm"
check "update_nhm: and says so" has "ITEM warn|nhm|no pinned nhm release"

READ_ONLY=1 run_update update_nhm nhm
check "update_nhm: read-only mode does not enroll" lacks "RUN nhm enroll"

run_update update_nhm
check "update_nhm: no nhm on PATH after the installer warns" has "ITEM warn|nhm|nhm is not on PATH"

# ------------------------------------------------------------
# update_nhm_hooks: the hook lines for the installed agents
# ------------------------------------------------------------
run_update update_nhm_hooks nhm claude codex
check "hooks: Claude Code gets the lines" registered_in claude "$FIX_HOME/.claude/settings.json"
check "hooks: Codex gets the lines" registered_in codex "$FIX_HOME/.codex/hooks.json"
check "hooks: reports both" has "ITEM ok|nhm hook lines|registered for claude, codex"
check "hooks: Codex trust recorded, so no /hooks step" lacks "DETAIL Codex asks to trust"
trust_entries() { jq -e '(keys | length) == 3' "$FIX_HOME/.codex/fake-trust.json" >/dev/null; }
check "hooks: trust holds the three nhm entries" trust_entries
OUT="$(cat "$FIX_HOME/.claude/settings.json")"
check "hooks: other settings are kept" has '"model": "opus"'

FAKE_CODEX_FAIL=1 run_update update_nhm_hooks nhm codex
check "hooks: Codex trust not recorded names /hooks" has "DETAIL Codex asks to trust the nhm hook lines once"
check "hooks: and the lines are still registered" has "ITEM ok|nhm hook lines|registered for codex"

run_update update_nhm_hooks nhm
check "hooks: no agent CLI skips" has "ITEM skip|nhm hook lines|neither Claude Code nor Codex is installed"

run_update update_nhm_hooks claude
check "hooks: no nhm skips" has "ITEM skip|nhm hook lines|nhm is not installed"

NO_HELPER=1 run_update update_nhm_hooks nhm claude
check "hooks: no helper skips" has "ITEM skip|nhm hook lines|nhm_hooks.sh is not installed"

NO_HOOK_BIN=1 run_update update_nhm_hooks nhm claude codex
check "hooks: no ~/.local/bin/nhm-hook warns" has "ITEM warn|nhm hook lines|nhm-hook is not installed"
check "hooks: and adds no line that points at nothing" \
    bash -c '! bash "$1" registered claude "$2" && test ! -e "$3"' _ "$REPO_ROOT/scripts/lib/nhm_hooks.sh" \
    "$FIX_HOME/.claude/settings.json" "$FIX_HOME/.codex/hooks.json"

# acfs-9hkh.46: lines an earlier run added go when nhm-hook goes, as install
# does; and nhm-hook is looked for where NHM_BIN_DIR says.
PRESEED=1 NO_HOOK_BIN=1 run_update update_nhm_hooks nhm claude codex
check "hooks: nhm-hook gone warns" has "ITEM warn|nhm hook lines|nhm-hook is not installed"
check "hooks: and removes ACFS's Claude Code lines" bash -c '! grep -q nhm-hook "$1"' _ "$FIX_HOME/.claude/settings.json"
check "hooks: and ACFS's Codex lines" bash -c '! grep -q nhm-hook "$1"' _ "$FIX_HOME/.codex/hooks.json"
check "hooks: and keeps the other settings" grep -q '"model": "opus"' "$FIX_HOME/.claude/settings.json"

check "hooks: and nhm's statusLine with them (acfs-5917)" \
    jq -e 'has("statusLine") | not' "$FIX_HOME/.claude/settings.json"

PRESEED=1 NO_HOOK_BIN=1 run_update update_nhm_hooks claude codex
check "hooks: nhm uninstalled skips" has "ITEM skip|nhm hook lines|nhm is not installed"
check "hooks: and still removes the lines" bash -c '! grep -q nhm-hook "$1" && ! grep -q nhm-hook "$2"' _ \
    "$FIX_HOME/.claude/settings.json" "$FIX_HOME/.codex/hooks.json"

# acfs-5917: Claude Code's statusLine runs nhm quota record-claude, the
# only way nhm learns Claude's windows.
statusline_is() { jq -e --arg c "$1" '.statusLine.command == $c' "$FIX_HOME/.claude/settings.json" >/dev/null; }
run_update update_nhm_hooks nhm claude
check "statusLine: set to nhm's command" statusline_is "$FIX_HOME/.local/bin/nhm quota record-claude"
check "statusLine: reported" has "ITEM ok|Claude statusLine|records Claude's windows for nhm's quota"
STATUSLINE='bash /home/u/.acfs/scripts/lib/agent_quota.sh record-claude' run_update update_nhm_hooks nhm claude
check "statusLine: ACFS's agent_quota.sh line is replaced" statusline_is "$FIX_HOME/.local/bin/nhm quota record-claude"
STATUSLINE='/usr/local/bin/my-status' run_update update_nhm_hooks nhm claude
check "statusLine: the user's own is kept" statusline_is '/usr/local/bin/my-status'
check "statusLine: and reported as kept" has "ITEM skip|Claude statusLine|your own statusLine is kept"
run_update update_nhm_hooks nhm codex
check "statusLine: no Claude Code, no statusLine step" lacks "Claude statusLine"

BIN_DIR=alt NO_HOOK_BIN=1 run_update update_nhm_hooks nhm claude
check "hooks: nhm-hook under NHM_BIN_DIR counts" has "ITEM ok|nhm hook lines|registered for claude"
check "hooks: and the lines run that nhm-hook" grep -q "$FIX_HOME/alt/nhm-hook sessionstart" "$FIX_HOME/.claude/settings.json"

SAME_USER=0 run_update update_nhm_hooks nhm claude
check "hooks: another user only warns with the command" has "ITEM warn|nhm hook lines|run as ubuntu: bash"
check "hooks: and registers nothing" bash -c '! bash "$1" registered claude "$2"' _ "$REPO_ROOT/scripts/lib/nhm_hooks.sh" "$FIX_HOME/.claude/settings.json"

READ_ONLY=1 run_update update_nhm_hooks nhm claude
check "hooks: read-only mode registers nothing" has "ITEM skip|nhm hook lines|dry-run"

# ------------------------------------------------------------
# update_codex_dcg_hook: dcg's Bash guard for Codex (acfs-9hkh.81)
# ------------------------------------------------------------
dcg_in() { HOME="$FIX_HOME" bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" codex-dcg registered "$FIX_HOME/.codex/hooks.json"; }
DCG=1 run_update update_codex_dcg_hook codex
check "dcg: Codex gets dcg's Bash guard" dcg_in
check "dcg: it is trusted, so no /hooks step" has "ITEM ok|dcg guard for Codex|in Codex's hooks.json, and trusted"
check "dcg: trust holds dcg's entry" jq -e 'keys | any(test(":pre_tool_use:0:0$"))' "$FIX_HOME/.codex/fake-trust.json"

DCG=1 FAKE_CODEX_FAIL=1 run_update update_codex_dcg_hook codex
check "dcg: trust not recorded names /hooks" has "DETAIL Codex asks to trust dcg's guard once"
check "dcg: and the line is still there" dcg_in

DCG=1 run_update update_codex_dcg_hook
check "dcg: no Codex skips" has "ITEM skip|dcg guard for Codex|Codex is not installed"
check "dcg: and writes nothing" test ! -e "$FIX_HOME/.codex/hooks.json"

run_update update_codex_dcg_hook codex
check "dcg: no dcg skips" has "ITEM skip|dcg guard for Codex|dcg is not installed"
check "dcg: and adds no line that points at nothing" test ! -e "$FIX_HOME/.codex/hooks.json"

DCG=1 run_update update_codex_dcg_hook codex
rm -f "$FIX_HOME/.local/bin/dcg"
(
    export HOME="$FIX_HOME" UPDATE_LOG_FILE="$ROOT/update.log"
    bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" codex-dcg unregister "$FIX_HOME/.codex/hooks.json" 2>/dev/null
)
check "dcg: dcg gone, its line goes" bash -c '! jq -e ".hooks.PreToolUse" "$1" >/dev/null' _ "$FIX_HOME/.codex/hooks.json"

DCG=1 SAME_USER=0 run_update update_codex_dcg_hook codex
check "dcg: another user only warns with the command" has "ITEM warn|dcg guard for Codex|run as ubuntu: bash"
DCG=1 READ_ONLY=1 run_update update_codex_dcg_hook codex
check "dcg: read-only mode writes nothing" has "ITEM skip|dcg guard for Codex|dry-run"

# ------------------------------------------------------------
# update_nhm_learning_profile: nhm's [learning] implicit_outcome
# (acfs-9hkh.88)
# ------------------------------------------------------------
learning_in() { python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb")).get("learning", {}).get("implicit_outcome", ""))' "$FIX_HOME/.config/nhm/config.toml"; }
run_update update_nhm_learning_profile nhm
check "learning: acfs update sets closed-assigned in nhm's config" test "$(learning_in)" = closed-assigned
check "learning: reports it on" has "ITEM ok|nhm learning profile|on"

run_update update_nhm_learning_profile nhm
mkdir -p "$FIX_HOME/.config/nhm"
printf '[learning]\nimplicit_outcome = "off"\n' >"$FIX_HOME/.config/nhm/config.toml"
(
    export HOME="$FIX_HOME" TARGET_HOME="$FIX_HOME" UPDATE_LOG_FILE="$ROOT/update.log"
    unset XDG_CONFIG_HOME
    bash "$REPO_ROOT/scripts/lib/nhm_hooks.sh" learning-profile set 2>/dev/null
)
check "learning: the user's own value stays" test "$(learning_in)" = off

run_update update_nhm_learning_profile
check "learning: no nhm does nothing" lacks "nhm learning profile"
SAME_USER=0 run_update update_nhm_learning_profile nhm
check "learning: another user only warns with the command" has "ITEM warn|nhm learning profile|run as ubuntu: bash"
READ_ONLY=1 run_update update_nhm_learning_profile nhm
check "learning: read-only mode writes nothing" has "ITEM skip|nhm learning profile|dry-run"
check "learning: and no config appears" test ! -e "$FIX_HOME/.config/nhm/config.toml"

echo
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
