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
# NO_HOOK_BIN (no ~/.local/bin/nhm-hook), PIN_URL (replaces
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
    OUT="$(
        export HOME="$FIX_HOME" TARGET_HOME="$FIX_HOME" UPDATE_LOG_FILE="$ROOT/update.log" PATH="$FAKEBIN:$PATH"
        unset TARGET_USER ACFS_HOME XDG_CONFIG_HOME NHM_BIN_DIR CODEX_HOME
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
    has "RUN nhm 0.1.2: update_run_verified_installer nhm --version 0.1.2 --archive-sha256 $NHM_AMD64 --archive-sha256 $NHM_ARM64"

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
check "update_nhm: enrolls the default herdr server as the target user" \
    has "RUN nhm enroll: update_run_in_target_context  $FIX_HOME/.local/bin/nhm admin instance enroll --session default"
check "update_nhm: returns 0" has "RC 0"

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

SAME_USER=0 run_update update_nhm_hooks nhm claude
check "hooks: another user only warns with the command" has "ITEM warn|nhm hook lines|run as ubuntu: bash"
check "hooks: and registers nothing" bash -c '! bash "$1" registered claude "$2"' _ "$REPO_ROOT/scripts/lib/nhm_hooks.sh" "$FIX_HOME/.claude/settings.json"

READ_ONLY=1 run_update update_nhm_hooks nhm claude
check "hooks: read-only mode registers nothing" has "ITEM skip|nhm hook lines|dry-run"

echo
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
