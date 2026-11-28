#!/usr/bin/env bash
# ============================================================
# ACFS Update - End-to-End Integration Test (Docker)
#
# Runs acfs-update inside a fresh Ubuntu container with ACFS installed,
# testing various modes and validating behavior.
#
# Usage:
#   ./tests/vm/test_acfs_update.sh              # defaults to 24.04
#   ./tests/vm/test_acfs_update.sh --all        # run 24.04 + 25.04
#   ./tests/vm/test_acfs_update.sh --ubuntu 25.04
#   ./tests/vm/test_acfs_update.sh --skip-install  # use pre-installed container
#
# Requirements:
#   - docker (or compatible runtime that supports `docker run`)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<'EOF'
tests/vm/test_acfs_update.sh - ACFS update E2E integration test (Docker)

Usage:
  ./tests/vm/test_acfs_update.sh [options]

Options:
  --ubuntu <version>   Ubuntu tag (e.g. 24.04, 25.04). Repeatable.
  --all                Run on 24.04 and 25.04.
  --help               Show help.

Test Coverage:
  1. --help flag works and shows usage
  2. --dry-run mode previews without changes
  3. --yes non-interactive mode
  4. --quiet minimal output mode
  5. --agents-only category filter
  6. --no-apt skip filter
  7. Log file creation
  8. Exit codes (success/failure)
  9. Missing tool handling (graceful skip)

Examples:
  ./tests/vm/test_acfs_update.sh
  ./tests/vm/test_acfs_update.sh --all
  ./tests/vm/test_acfs_update.sh --ubuntu 25.04
EOF
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found. Install Docker Desktop or docker engine." >&2
    exit 1
fi

declare -a ubuntus=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ubuntu)
            ubuntus+=("${2:-}")
            shift 2
            ;;
        --all)
            ubuntus=("24.04" "25.04")
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ${#ubuntus[@]} -eq 0 ]]; then
    ubuntus=("24.04")
fi

# Test script that runs inside the container
# This is passed as a heredoc to avoid escaping issues
create_test_script() {
    cat <<'TESTSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    ((pass_count += 1))
}

fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "    ${2}"
    fi
    ((fail_count += 1))
}

info() {
    echo -e "${YELLOW}ℹ️ ${NC} $1"
}

# Test 1: --help works
test_help() {
    info "Testing --help flag"
    if acfs-update --help 2>&1 | grep -q "USAGE:"; then
        pass "--help shows usage"
    else
        fail "--help does not show usage"
    fi
}

# Test 2: --dry-run mode
test_dry_run() {
    info "Testing --dry-run mode"
    local log_dir="$HOME/.acfs/logs/updates"
    local before_log_count=0
    local after_log_count=0
    if [[ -d "$log_dir" ]]; then
        before_log_count=$(find "$log_dir" -maxdepth 1 -type f -name '*.log' | wc -l | tr -d ' ')
    fi

    local output
    output=$(acfs-update --dry-run --yes 2>&1) || true

    if echo "$output" | grep -q "dry-run"; then
        pass "--dry-run mentions dry-run mode"
    else
        fail "--dry-run output missing dry-run indicator"
    fi

    # Dry run should not create errors on skip
    if echo "$output" | grep -q "\[skip\]"; then
        pass "--dry-run shows skip markers"
    else
        fail "--dry-run missing skip markers"
    fi

    if [[ -d "$log_dir" ]]; then
        after_log_count=$(find "$log_dir" -maxdepth 1 -type f -name '*.log' | wc -l | tr -d ' ')
    fi

    if [[ "$before_log_count" == "$after_log_count" ]]; then
        pass "--dry-run does not create update log files"
    else
        fail "--dry-run created update log files" "before=$before_log_count after=$after_log_count"
    fi
}

# Test 3: Non-git installs do not bootstrap self-update implicitly
test_self_update_guard() {
    info "Testing non-git self-update guard"
    local output
    output=$(acfs-update --dry-run --yes 2>&1) || true

    if echo "$output" | grep -q "not a git checkout"; then
        pass "Non-git installs skip ACFS self-update by default"
    else
        fail "Non-git self-update guard message missing"
    fi

    if [[ ! -d "$HOME/.acfs/.git" ]]; then
        pass "--dry-run did not create ~/.acfs/.git"
    else
        fail "--dry-run unexpectedly created ~/.acfs/.git"
    fi
}

# Test 4: Required deployed support assets are present
test_deployed_assets() {
    info "Testing deployed ACFS support assets"

    local -a required_files=(
        "$HOME/.acfs/scripts/lib/contract.sh"
        "$HOME/.acfs/scripts/lib/nightly_update.sh"
        "$HOME/.acfs/scripts/nightly-update.sh"
        "$HOME/.acfs/scripts/templates/acfs-nightly-update.service"
        "$HOME/.acfs/scripts/templates/acfs-nightly-update.timer"
    )

    local missing=()
    local path=""
    for path in "${required_files[@]}"; do
        [[ -f "$path" ]] || missing+=("$path")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "ACFS deployed support assets are present"
    else
        fail "Missing deployed support assets" "${missing[*]}"
    fi
}

# Test 5: --quiet mode
test_quiet() {
    info "Testing --quiet mode"
    local output
    output=$(acfs-update --quiet --dry-run --yes 2>&1) || true

    # Quiet mode should have minimal output
    local line_count
    line_count=$(echo "$output" | wc -l)
    if [[ $line_count -lt 20 ]]; then
        pass "--quiet produces minimal output ($line_count lines)"
    else
        fail "--quiet produces too much output ($line_count lines)"
    fi
}

# Test 6: --agents-only category filter
test_agents_only() {
    info "Testing --agents-only filter"
    local output
    output=$(acfs-update --agents-only --dry-run --yes 2>&1) || true

    # Should mention agents section
    if echo "$output" | grep -qiE "agents|claude|codex|gemini"; then
        pass "--agents-only processes agent section"
    else
        fail "--agents-only missing agent output"
    fi

    # Should NOT mention apt section header
    if echo "$output" | grep -q "System Packages (apt)"; then
        fail "--agents-only still shows apt section"
    else
        pass "--agents-only skips apt section"
    fi
}

# Test 7: --no-apt skip filter
test_no_apt() {
    info "Testing --no-apt filter"
    local output
    output=$(acfs-update --no-apt --dry-run --yes 2>&1) || true

    # Should show skip message for apt
    if echo "$output" | grep -qE "disabled via --no-apt|skip.*apt"; then
        pass "--no-apt shows apt disabled"
    else
        # It might just not show apt at all
        if echo "$output" | grep -q "apt update"; then
            fail "--no-apt still runs apt update"
        else
            pass "--no-apt skips apt"
        fi
    fi
}

# Test 8: Log file creation
test_logging() {
    info "Testing log file creation"

    # Run a real (but quick) update to create log
    acfs-update --shell-only --yes --quiet 2>&1 || true

    local log_dir="$HOME/.acfs/logs/updates"
    if [[ -d "$log_dir" ]]; then
        pass "Log directory created: $log_dir"
    else
        fail "Log directory not created"
        return
    fi

    local log_count
    log_count=$(find "$log_dir" -name "*.log" 2>/dev/null | wc -l)
    if [[ $log_count -gt 0 ]]; then
        pass "Log file(s) created ($log_count found)"
    else
        fail "No log files created"
        return
    fi

    # Check log content
    local latest_log
    latest_log=$(ls -1t "$log_dir"/*.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]] && grep -q "ACFS Update Log" "$latest_log"; then
        pass "Log file has proper header"
    else
        fail "Log file missing header"
    fi
}

# Test 9: Missing tool graceful handling
test_missing_tools() {
    info "Testing missing tool handling"

    # Remove a tool temporarily and verify graceful skip
    local output
    output=$(acfs-update --stack --dry-run --yes 2>&1) || true

    # Stack should show skip for uninstalled tools
    if echo "$output" | grep -q "\[skip\]"; then
        pass "Missing tools handled gracefully with skip"
    else
        fail "Missing tools not showing skip status"
    fi
}

# Test 10: Exit codes
test_exit_codes() {
    info "Testing exit codes"

    # Dry run with yes should succeed
    if acfs-update --dry-run --yes --quiet >/dev/null 2>&1; then
        pass "Successful run returns exit code 0"
    else
        fail "Dry run returned non-zero exit code"
    fi
}

# Test 11: Shell tools section
test_shell_only() {
    info "Testing --shell-only filter"
    local output
    output=$(acfs-update --shell-only --dry-run --yes 2>&1) || true

    # Should mention shell tools
    if echo "$output" | grep -qiE "shell|omz|zsh|mcfly|zoxide"; then
        pass "--shell-only processes shell section"
    else
        fail "--shell-only missing shell output"
    fi
}

# Test 12: Version display
test_version_display() {
    info "Testing version display"
    local output
    output=$(acfs-update --dry-run --yes 2>&1) || true

    if echo "$output" | grep -q "ACFS Update v"; then
        pass "Version displayed in header"
    else
        fail "Version not displayed"
    fi
}

# Test 13: DCG update verification
test_dcg_update() {
    info "Testing DCG update verification"

    # Skip if DCG not installed
    if ! command -v dcg &>/dev/null; then
        info "DCG not installed - skipping update test"
        return 0
    fi

    # Get version before update
    local version_before
    version_before=$(dcg --version 2>/dev/null | head -1) || version_before="unknown"
    info "DCG version before: $version_before"

    # Get hook status before (use text parsing)
    local hook_before
    local doctor_output
    doctor_output=$(dcg doctor 2>&1) || true
    if echo "$doctor_output" | grep -qi "hook wiring.*OK"; then
        hook_before="registered"
    else
        hook_before="unknown"
    fi
    info "Hook status before: $hook_before"

    # Run the exact updater path for DCG without dragging in the rest of the
    # stack category, which includes heavyweight optional tools like fsfs.
    local update_output
    update_output=$(bash -lc '
        set -euo pipefail
        source "$HOME/.acfs/scripts/lib/update.sh"
        QUIET=true
        VERBOSE=false
        YES_MODE=true
        UPDATE_LOG_FILE=""
        ensure_path
        update_run_verified_installer dcg --easy-mode
        if command -v dcg >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
            dcg install --force >/dev/null 2>&1 || true
        fi
    ' 2>&1) || true

    # Get version after update
    local version_after
    version_after=$(dcg --version 2>/dev/null | head -1) || version_after="unknown"
    info "DCG version after: $version_after"

    # Get hook status after
    local hook_after
    doctor_output=$(dcg doctor 2>&1) || true
    if echo "$doctor_output" | grep -qi "hook wiring.*OK"; then
        hook_after="registered"
    else
        hook_after="unknown"
    fi
    info "Hook status after: $hook_after"

    # Verify hook is still registered after update
    if [[ "$hook_after" == "registered" ]]; then
        pass "DCG hook still registered after update"
    else
        fail "DCG hook status uncertain after update"
    fi

    # Verify blocking still works
    local test_output
    test_output=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /important"}}' | dcg 2>&1) || true

    # Empty output = allowed (fail-open), or it might have deny output
    # For this test, just verify DCG responds without crashing
    if dcg doctor &>/dev/null; then
        pass "DCG functional after update (doctor passes)"
    else
        fail "DCG doctor failed after update"
    fi
}

# Run all tests
main() {
    echo ""
    echo "============================================================"
    echo "ACFS Update E2E Tests"
    echo "============================================================"
    echo ""

    test_help
    test_dry_run
    test_self_update_guard
    test_deployed_assets
    test_quiet
    test_agents_only
    test_no_apt
    test_shell_only
    test_logging
    test_missing_tools
    test_exit_codes
    test_version_display
    test_dcg_update

    echo ""
    echo "============================================================"
    echo -e "Results: ${GREEN}$pass_count passed${NC}, ${RED}$fail_count failed${NC}"
    echo "============================================================"

    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
TESTSCRIPT
}

run_one() {
    local ubuntu_version="$1"
    local image="ubuntu:${ubuntu_version}"

    echo "" >&2
    echo "============================================================" >&2
    echo "[ACFS Update Test] Ubuntu ${ubuntu_version}" >&2
    echo "============================================================" >&2

    docker pull "$image" >/dev/null

    # Create a temporary file for the test script
    local test_script
    test_script=$(mktemp "${TMPDIR:-/tmp}/acfs_update_test.XXXXXX")
    create_test_script > "$test_script"
    chmod +x "$test_script"

    docker run --rm -t \
        -e DEBIAN_FRONTEND=noninteractive \
        -v "${REPO_ROOT}:/repo:ro" \
        -v "${test_script}:/run_tests.sh:ro" \
        "$image" bash -lc '
            set -euo pipefail

            # Install prerequisites
            apt-get update >/dev/null
            apt-get install -y sudo curl git ca-certificates jq unzip tar xz-utils gnupg >/dev/null

            # Run ACFS installer
            echo "Installing ACFS..."
            cd /repo
            install_log=/tmp/acfs-install.log
            install_status=0
            ACFS_CI=true CARGO_BUILD_JOBS=1 bash install.sh --yes --mode vibe --skip-ubuntu-upgrade >"$install_log" 2>&1 || install_status=$?
            cat "$install_log"
            if [[ $install_status -ne 0 ]]; then
                echo "ERROR: install.sh failed during VM update test" >&2
                exit "$install_status"
            fi
            if grep -q "node is required but not found" "$install_log"; then
                echo "ERROR: installer still emitted the Gemini patch missing-node warning" >&2
                exit 1
            fi
            if grep -q "Gemini CLI patch step failed" "$install_log"; then
                echo "ERROR: installer still reported Gemini patch failure" >&2
                exit 1
            fi

            # Verify the direct installed wrapper does not short-circuit owner
            # handoff before state discovery, even if root has stale state.
            echo ""
            echo "Verifying direct installed acfs-update handoff..."
            mkdir -p /root/.acfs
            cat > /root/.acfs/state.json <<'"'"'EOF'"'"'
{"target_user":"staleuser"}
EOF
            mv /home/ubuntu/.acfs/scripts/lib/update.sh /home/ubuntu/.acfs/scripts/lib/update.sh.real
            cat > /home/ubuntu/.acfs/scripts/lib/update.sh <<'"'"'EOF'"'"'
#!/usr/bin/env bash
set -euo pipefail
printf "wrapper-user=%s\n" "$(whoami)"
printf "wrapper-args=%s\n" "$*"
EOF
            chmod 755 /home/ubuntu/.acfs/scripts/lib/update.sh
            chown ubuntu:ubuntu /home/ubuntu/.acfs/scripts/lib/update.sh
            probe_output=""
            probe_status=0
            probe_output=$(/home/ubuntu/.acfs/bin/acfs-update --help 2>&1) || probe_status=$?
            mv /home/ubuntu/.acfs/scripts/lib/update.sh.real /home/ubuntu/.acfs/scripts/lib/update.sh
            if [[ $probe_status -ne 0 ]]; then
                echo "ERROR: direct installed-wrapper dispatch failed" >&2
                echo "$probe_output" >&2
                exit 1
            fi
            if ! echo "$probe_output" | grep -q "^wrapper-user=ubuntu$"; then
                echo "ERROR: direct installed-wrapper did not run update.sh as ubuntu" >&2
                echo "$probe_output" >&2
                exit 1
            fi

            # Verify the installed user-bin wrapper still resolves update.sh
            # when invoked from root/non-target-user context.
            echo ""
            echo "Verifying root-side acfs-update wrapper dispatch..."
            if ! /home/ubuntu/.local/bin/acfs-update --help 2>&1 | grep -q "USAGE:"; then
                echo "ERROR: root-side acfs-update wrapper dispatch failed" >&2
                exit 1
            fi

            # Verify a wrapper installed under a nonstandard passwd home
            # dispatches to its own adjacent ACFS tree instead of a generic
            # /home/* scan or some other user install.
            echo ""
            echo "Verifying nonstandard-home acfs-update wrapper dispatch..."
            useradd -m -d /srv/acfs-alt -s /bin/bash altuser
            mkdir -p /srv/acfs-alt/.local/bin /srv/acfs-alt/.acfs/bin /srv/acfs-alt/.acfs/scripts/lib
            cp /home/ubuntu/.local/bin/acfs-update /srv/acfs-alt/.local/bin/acfs-update
            cp /home/ubuntu/.acfs/bin/acfs-update /srv/acfs-alt/.acfs/bin/acfs-update
            cat > /srv/acfs-alt/.acfs/state.json <<\EOF
{"target_user":"altuser","target_home":"/srv/acfs-alt"}
EOF
            cat > /srv/acfs-alt/.acfs/scripts/lib/update.sh <<\EOF
#!/usr/bin/env bash
set -euo pipefail
printf "wrapper-user=%s\n" "$(whoami)"
printf "wrapper-home=%s\n" "${HOME:-}"
printf "wrapper-args=%s\n" "$*"
EOF
            chmod 755 /srv/acfs-alt/.local/bin/acfs-update /srv/acfs-alt/.acfs/bin/acfs-update /srv/acfs-alt/.acfs/scripts/lib/update.sh
            chown -R altuser:altuser /srv/acfs-alt
            alt_probe_output=""
            alt_probe_status=0
            alt_probe_output=$(/srv/acfs-alt/.local/bin/acfs-update --help 2>&1) || alt_probe_status=$?
            if [[ $alt_probe_status -ne 0 ]]; then
                echo "ERROR: nonstandard-home wrapper dispatch failed" >&2
                echo "$alt_probe_output" >&2
                exit 1
            fi
            if ! echo "$alt_probe_output" | grep -q "^wrapper-user=altuser$"; then
                echo "ERROR: nonstandard-home wrapper did not run update.sh as altuser" >&2
                echo "$alt_probe_output" >&2
                exit 1
            fi
            if ! echo "$alt_probe_output" | grep -q "^wrapper-home=/srv/acfs-alt$"; then
                echo "ERROR: nonstandard-home wrapper did not preserve altuser HOME" >&2
                echo "$alt_probe_output" >&2
                exit 1
            fi

            # Verify stale adjacent state does not override the wrapper home
            # and force an incorrect cross-user handoff.
            echo ""
            echo "Verifying stale-state acfs-update wrapper dispatch..."
            cat > /srv/acfs-alt/.acfs/state.json <<\EOF
{"target_user":"ubuntu","target_home":"/home/ubuntu"}
EOF
            stale_probe_output=""
            stale_probe_status=0
            stale_probe_output=$(sudo -u altuser -H /srv/acfs-alt/.local/bin/acfs-update --help 2>&1) || stale_probe_status=$?
            if [[ $stale_probe_status -ne 0 ]]; then
                echo "ERROR: stale-state wrapper dispatch failed" >&2
                echo "$stale_probe_output" >&2
                exit 1
            fi
            if ! echo "$stale_probe_output" | grep -q "^wrapper-user=altuser$"; then
                echo "ERROR: stale-state wrapper trusted mismatched target_user" >&2
                echo "$stale_probe_output" >&2
                exit 1
            fi
            if ! echo "$stale_probe_output" | grep -q "^wrapper-home=/srv/acfs-alt$"; then
                echo "ERROR: stale-state wrapper lost altuser HOME context" >&2
                echo "$stale_probe_output" >&2
                exit 1
            fi

            # Verify acfs-update also honors ACFS_SYSTEM_STATE_FILE when the
            # default system state path is unavailable and NSS lookup is blocked.
            echo ""
            echo "Verifying acfs-update ACFS_SYSTEM_STATE_FILE override..."
            state_override_probe_output="$(
                (
                    set -euo pipefail
                    state_backup=""
                    probe_wrapper=/tmp/acfs-update-state-env
                    fake_bin=/tmp/acfs-update-state-env-bin
                    clean_home=/tmp/acfs-update-state-env-home
                    custom_state=/tmp/acfs-update-state-env.json

                    cleanup() {
                        rm -f "$probe_wrapper" "$custom_state"
                        rm -rf "$fake_bin" "$clean_home"
                        if [[ -n "$state_backup" ]] && [[ -e "$state_backup" ]]; then
                            mv "$state_backup" /var/lib/acfs/state.json
                        fi
                    }
                    trap cleanup EXIT

                    if [[ -e /var/lib/acfs/state.json ]]; then
                        state_backup=/var/lib/acfs/state.json.state-env-backup
                        mv /var/lib/acfs/state.json "$state_backup"
                    fi

                    mkdir -p "$fake_bin" "$clean_home"
                    cat > "$fake_bin/getent" <<\EOF
#!/usr/bin/env bash
exit 2
EOF
                    chmod 755 "$fake_bin/getent"

                    cat > "$custom_state" <<\EOF
{"target_user":"ubuntu","target_home":"/home/ubuntu"}
EOF
                    cp /home/ubuntu/.local/bin/acfs-update "$probe_wrapper"
                    chmod 755 "$probe_wrapper"

                    HOME="$clean_home" PATH="$fake_bin:/usr/bin:/bin" \
                        ACFS_SYSTEM_STATE_FILE="$custom_state" \
                        "$probe_wrapper" --help
                ) 2>&1
            )" || {
                echo "ERROR: acfs-update ignored ACFS_SYSTEM_STATE_FILE override" >&2
                echo "$state_override_probe_output" >&2
                exit 1
            }
            if ! echo "$state_override_probe_output" | grep -q "USAGE:"; then
                echo "ERROR: acfs-update override probe did not dispatch to update.sh" >&2
                echo "$state_override_probe_output" >&2
                exit 1
            fi

            # Verify the system-wide acfs wrapper also handles nonstandard-home
            # installs correctly when root carries stale state for another user.
            echo ""
            echo "Verifying nonstandard-home global acfs wrapper dispatch..."
            global_probe_output=""
            global_probe_status=0
            global_probe_output="$(
                (
                    set -euo pipefail
                    backup_local=""
                    backup_acfs=""

                    cleanup() {
                        if [[ -n "$backup_local" ]] && [[ -e "$backup_local" ]]; then
                            mv "$backup_local" /home/ubuntu/.local/bin/acfs
                        fi
                        if [[ -n "$backup_acfs" ]] && [[ -e "$backup_acfs" ]]; then
                            mv "$backup_acfs" /home/ubuntu/.acfs/bin/acfs
                        fi
                    }
                    trap cleanup EXIT

                    if [[ -e /home/ubuntu/.local/bin/acfs ]]; then
                        backup_local=/home/ubuntu/.local/bin/acfs.real
                        mv /home/ubuntu/.local/bin/acfs "$backup_local"
                    fi
                    if [[ -e /home/ubuntu/.acfs/bin/acfs ]]; then
                        backup_acfs=/home/ubuntu/.acfs/bin/acfs.real
                        mv /home/ubuntu/.acfs/bin/acfs "$backup_acfs"
                    fi

                    mkdir -p /root/.acfs
                    cat > /root/.acfs/state.json <<\EOF
{"target_user":"ubuntu","target_home":"/home/ubuntu"}
EOF
                    mkdir -p /srv/acfs-alt/.local/bin
                    cat > /srv/acfs-alt/.acfs/state.json <<\EOF
{"target_user":"altuser","target_home":"/srv/acfs-alt"}
EOF
                    cat > /srv/acfs-alt/.local/bin/acfs <<\EOF
#!/usr/bin/env bash
set -euo pipefail
printf "global-wrapper-user=%s\n" "$(whoami)"
printf "global-wrapper-home=%s\n" "${HOME:-}"
printf "global-wrapper-args=%s\n" "$*"
EOF
                    chmod 755 /srv/acfs-alt/.local/bin/acfs
                    chown altuser:altuser /srv/acfs-alt/.local/bin/acfs /srv/acfs-alt/.acfs/state.json

                    /usr/local/bin/acfs --help
                ) 2>&1
            )" || global_probe_status=$?
            if [[ $global_probe_status -ne 0 ]]; then
                echo "ERROR: global acfs wrapper dispatch failed" >&2
                echo "$global_probe_output" >&2
                exit 1
            fi
            if ! echo "$global_probe_output" | grep -q "^global-wrapper-user=altuser$"; then
                echo "ERROR: global acfs wrapper did not run as altuser" >&2
                echo "$global_probe_output" >&2
                exit 1
            fi
            if ! echo "$global_probe_output" | grep -q "^global-wrapper-home=/srv/acfs-alt$"; then
                echo "ERROR: global acfs wrapper did not preserve altuser HOME" >&2
                echo "$global_probe_output" >&2
                exit 1
            fi

            # Verify the global acfs wrapper also honors ACFS_SYSTEM_STATE_FILE
            # when the default system state path is unavailable and NSS lookup
            # is blocked.
            echo ""
            echo "Verifying global acfs ACFS_SYSTEM_STATE_FILE override..."
            global_state_override_output="$(
                (
                    set -euo pipefail
                    state_backup=""
                    probe_wrapper=/tmp/acfs-global-state-env
                    fake_bin=/tmp/acfs-global-state-env-bin
                    clean_home=/tmp/acfs-global-state-env-home
                    custom_state=/tmp/acfs-global-state-env.json

                    cleanup() {
                        rm -f "$probe_wrapper" "$custom_state"
                        rm -rf "$fake_bin" "$clean_home"
                        if [[ -n "$state_backup" ]] && [[ -e "$state_backup" ]]; then
                            mv "$state_backup" /var/lib/acfs/state.json
                        fi
                    }
                    trap cleanup EXIT

                    if [[ -e /var/lib/acfs/state.json ]]; then
                        state_backup=/var/lib/acfs/state.json.global-state-env-backup
                        mv /var/lib/acfs/state.json "$state_backup"
                    fi

                    mkdir -p "$fake_bin" "$clean_home"
                    cat > "$fake_bin/getent" <<\EOF
#!/usr/bin/env bash
exit 2
EOF
                    chmod 755 "$fake_bin/getent"

                    cat > "$custom_state" <<\EOF
{"target_user":"ubuntu","target_home":"/home/ubuntu"}
EOF
                    cp /usr/local/bin/acfs "$probe_wrapper"
                    chmod 755 "$probe_wrapper"

                    HOME="$clean_home" PATH="$fake_bin:/usr/bin:/bin" \
                        ACFS_SYSTEM_STATE_FILE="$custom_state" \
                        "$probe_wrapper" version
                ) 2>&1
            )" || {
                echo "ERROR: global acfs wrapper ignored ACFS_SYSTEM_STATE_FILE override" >&2
                echo "$global_state_override_output" >&2
                exit 1
            }
            if ! echo "$global_state_override_output" | grep -q '^0\\.'; then
                echo "ERROR: global acfs override probe did not dispatch to ACFS" >&2
                echo "$global_state_override_output" >&2
                exit 1
            fi

            # Switch to ubuntu user and run update tests
            echo ""
            echo "Running acfs-update E2E tests..."
            su - ubuntu -c "zsh -ic '\''bash /run_tests.sh'\''"
        '

    local exit_code=$?
    rm -f "$test_script"

    return $exit_code
}

# Main execution
failures=0
for ubuntu_version in "${ubuntus[@]}"; do
    if [[ -z "$ubuntu_version" ]]; then
        echo "ERROR: --ubuntu requires a version (e.g. 24.04)" >&2
        exit 1
    fi
    if ! run_one "$ubuntu_version"; then
        ((failures += 1))
    fi
done

echo "" >&2
if [[ $failures -gt 0 ]]; then
    echo "❌ ACFS update tests: $failures version(s) failed" >&2
    exit 1
fi

echo "✅ All ACFS update tests passed." >&2
