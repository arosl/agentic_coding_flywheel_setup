#!/usr/bin/env bash
# shellcheck disable=SC2016
# ============================================================
# Fork source: with no ACFS_REPO_OWNER in the environment, the
# installer, its resume hint and acfs update all use this fork
# (arosl/agentic_coding_flywheel_setup), never upstream ACFS.
#
# Run with: bash tests/unit/test_fork_source.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UPDATE_SH="$REPO_ROOT/scripts/lib/update.sh"

FORK_REPO="arosl/agentic_coding_flywheel_setup"
UPSTREAM_REPO="Dicklesworthstone/agentic_coding_flywheel_setup"

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
}

# Run bash with no repo-source overrides inherited from the caller.
clean_bash() {
    env -u ACFS_REPO_OWNER -u ACFS_REPO_NAME -u ACFS_REF -u ACFS_CHECKSUMS_REF \
        -u ACFS_RAW -u ACFS_CHECKSUMS_RAW bash -c "$@"
}

# ------------------------------------------------------------
# install.sh: the top-level block that decides the source
# ------------------------------------------------------------
install_source="$(clean_bash '
    eval "$(sed -n "/^ACFS_REPO_OWNER=/,/^ACFS_CHECKSUMS_RAW=/p" "$1")"
    printf "%s\n%s\n" "$ACFS_RAW" "$ACFS_CHECKSUMS_RAW"
' _ "$INSTALL_SH")"
expected_raw="https://raw.githubusercontent.com/$FORK_REPO/main"
if [[ "$install_source" == "$expected_raw"$'\n'"$expected_raw" ]]; then
    pass "install.sh fetches code and checksums from the fork by default"
else
    fail "install.sh fetches code and checksums from the fork by default" "$install_source"
fi

# ------------------------------------------------------------
# install.sh: the resume hint of a streamed (curl | bash) install
# ------------------------------------------------------------
resume_hint="$(clean_bash '
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_detail() { :; }
    eval "$(sed -n "/^generate_resume_hint()/,/^}$/p" "$1")"
    SCRIPT_DIR=""; ACFS_COMMIT_SHA_FULL=""; ACFS_REF_INPUT="main"
    ACFS_CHECKSUMS_REF=""; ACFS_CHECKSUMS_REF_EXPLICIT=false
    MODE="vibe"; SKIP_POSTGRES=false; SKIP_VAULT=false; SKIP_CLOUD=false
    SKIP_PREFLIGHT=false; SKIP_UBUNTU_UPGRADE=false; YES_MODE=false
    STRICT_MODE=false; ACFS_STRICT_MODE=false; DRY_RUN=false; PRINT_MODE=false
    AUTO_FIX_MODE="prompt"; ACFS_VERIFIED_INSTALLER_CACHE=""
    generate_resume_hint "" ""
' _ "$INSTALL_SH")"
if [[ "$resume_hint" == *"raw.githubusercontent.com/$FORK_REPO/main/install.sh"* ]]; then
    pass "the resume hint re-runs the fork's installer"
else
    fail "the resume hint re-runs the fork's installer" "$resume_hint"
fi

# ------------------------------------------------------------
# acfs update: which origin self-update accepts
# ------------------------------------------------------------
origin_verdicts="$(clean_bash '
    source "$1"
    for url in "https://github.com/$2.git" "https://github.com/$3.git"; do
        if is_expected_acfs_origin_url "$url"; then echo accept; else echo reject; fi
    done
' _ "$UPDATE_SH" "$FORK_REPO" "$UPSTREAM_REPO")"
if [[ "$origin_verdicts" == $'accept\nreject' ]]; then
    pass "acfs update self-updates from the fork's origin and refuses upstream's"
else
    fail "acfs update self-updates from the fork's origin and refuses upstream's" "$origin_verdicts"
fi

# ------------------------------------------------------------
# acfs update: where a tarball install bootstraps self-update from
# ------------------------------------------------------------
acfs_root="$(mktemp -d)"
bootstrap_message="$(clean_bash '
    source "$1"
    log_section() { :; }
    log_item() { printf "%s\n" "$3"; }
    UPDATE_SELF=true; ACFS_SELF_UPDATE_DONE=false; BOOTSTRAP_SELF_UPDATE=true
    DRY_RUN=true; ACFS_REPO_ROOT="$2"
    update_acfs_self
' _ "$UPDATE_SH" "$acfs_root")"
rmdir "$acfs_root"
if [[ "$bootstrap_message" == *"https://github.com/$FORK_REPO.git"* ]]; then
    pass "acfs update bootstraps self-update from the fork"
else
    fail "acfs update bootstraps self-update from the fork" "$bootstrap_message"
fi

printf '\nTests passed: %d\nTests failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
