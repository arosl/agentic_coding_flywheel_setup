#!/usr/bin/env bash
# ============================================================
# ACFS E2E Test Harness
#
# Provides standardized logging, timing, and artifact capture
# for tests/vm integration tests.
#
# Usage:
#   source tests/vm/lib/test_harness.sh
#   harness_init "Test Suite Name"
#   harness_section "Phase 1: Setup"
#   harness_run "Running command" my_command --args
#   harness_pass "Test passed"
#   harness_fail "Test failed"
#   harness_summary
#
# All log output goes to stderr; stdout is reserved for
# machine-parseable data (e.g., test results in JSON).
# ============================================================

# Colors (only if stderr is a terminal)
if [[ -t 2 ]]; then
    HARNESS_RED='\033[0;31m'
    HARNESS_GREEN='\033[0;32m'
    HARNESS_YELLOW='\033[0;33m'
    HARNESS_BLUE='\033[0;34m'
    HARNESS_CYAN='\033[0;36m'
    HARNESS_GRAY='\033[0;90m'
    HARNESS_BOLD='\033[1m'
    HARNESS_NC='\033[0m'
else
    HARNESS_RED=''
    HARNESS_GREEN=''
    HARNESS_YELLOW=''
    HARNESS_BLUE=''
    HARNESS_CYAN=''
    HARNESS_GRAY=''
    HARNESS_BOLD=''
    HARNESS_NC=''
fi

# State
HARNESS_SUITE_NAME=""
HARNESS_START_TIME=""
HARNESS_SECTION_START=""
HARNESS_PASS_COUNT=0
HARNESS_FAIL_COUNT=0
HARNESS_SKIP_COUNT=0
# A caller-chosen artifact directory (set before harness_init) is always
# kept. One harness_init creates is removed by harness_summary when every
# test passed, unless HARNESS_KEEP_ARTIFACTS=true; a failed or interrupted
# run keeps it for inspection.
HARNESS_ARTIFACT_DIR="${HARNESS_ARTIFACT_DIR:-}"
HARNESS_ARTIFACT_DIR_CREATED=false
HARNESS_CURRENT_SECTION=""

# ============================================================
# Timestamps
# ============================================================

harness_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

harness_timestamp_compact() {
    date '+%H:%M:%S'
}

harness_duration_human() {
    local seconds="$1"
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m $((seconds % 60))s"
    fi
}

# ============================================================
# Initialization
# ============================================================

harness_init() {
    local suite_name="${1:-E2E Tests}"
    HARNESS_SUITE_NAME="$suite_name"
    HARNESS_START_TIME="$(date +%s)"
    HARNESS_PASS_COUNT=0
    HARNESS_FAIL_COUNT=0
    HARNESS_SKIP_COUNT=0

    # Create artifact directory
    if [[ -n "$HARNESS_ARTIFACT_DIR" ]]; then
        mkdir -p "$HARNESS_ARTIFACT_DIR"
    else
        HARNESS_ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acfs-test-artifacts-$(date +%Y%m%d-%H%M%S).XXXXXX")"
        HARNESS_ARTIFACT_DIR_CREATED=true
    fi

    {
        echo ""
        echo "${HARNESS_BOLD}============================================================${HARNESS_NC}"
        echo "${HARNESS_BOLD}${HARNESS_SUITE_NAME}${HARNESS_NC}"
        echo "${HARNESS_GRAY}Started: $(harness_timestamp)${HARNESS_NC}"
        echo "${HARNESS_GRAY}Artifacts: ${HARNESS_ARTIFACT_DIR}${HARNESS_NC}"
        echo "${HARNESS_BOLD}============================================================${HARNESS_NC}"
        echo ""
    } >&2
}

# ============================================================
# Section Markers
# ============================================================

harness_section() {
    local section_name="$1"
    local now
    now="$(date +%s)"

    # End previous section if any
    if [[ -n "$HARNESS_CURRENT_SECTION" ]] && [[ -n "$HARNESS_SECTION_START" ]]; then
        local duration=$((now - HARNESS_SECTION_START))
        echo "${HARNESS_GRAY}  └─ Completed in $(harness_duration_human $duration)${HARNESS_NC}" >&2
        echo "" >&2
    fi

    HARNESS_CURRENT_SECTION="$section_name"
    HARNESS_SECTION_START="$now"

    {
        echo "${HARNESS_CYAN}[$(harness_timestamp_compact)]${HARNESS_NC} ${HARNESS_BOLD}${section_name}${HARNESS_NC}"
    } >&2
}

harness_subsection() {
    local name="$1"
    echo "${HARNESS_GRAY}  ├─ ${name}${HARNESS_NC}" >&2
}

# ============================================================
# Command Execution with Logging
# ============================================================

harness_run() {
    local description="$1"
    shift
    local cmd=("$@")

    local start_time
    start_time="$(date +%s)"

    echo "${HARNESS_GRAY}  ├─ ${description}${HARNESS_NC}" >&2
    echo "${HARNESS_GRAY}     \$ ${cmd[*]}${HARNESS_NC}" >&2

    local output_file
    output_file="${HARNESS_ARTIFACT_DIR}/cmd-$(date +%s)-${RANDOM}.log"

    local exit_code=0
    if "${cmd[@]}" > "$output_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi

    local end_time
    end_time="$(date +%s)"
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
        echo "${HARNESS_GREEN}     ✓ Success${HARNESS_NC} ${HARNESS_GRAY}($(harness_duration_human $duration))${HARNESS_NC}" >&2
    else
        echo "${HARNESS_RED}     ✗ Failed (exit code: ${exit_code})${HARNESS_NC} ${HARNESS_GRAY}($(harness_duration_human $duration))${HARNESS_NC}" >&2
        echo "${HARNESS_GRAY}     Output captured: ${output_file}${HARNESS_NC}" >&2
    fi

    return $exit_code
}

# Run command with live output (for long-running commands)
harness_run_live() {
    local description="$1"
    shift
    local cmd=("$@")

    local start_time
    start_time="$(date +%s)"

    echo "${HARNESS_GRAY}  ├─ ${description}${HARNESS_NC}" >&2
    echo "${HARNESS_GRAY}     \$ ${cmd[*]}${HARNESS_NC}" >&2

    local exit_code=0
    if "${cmd[@]}" >&2; then
        exit_code=0
    else
        exit_code=$?
    fi

    local end_time
    end_time="$(date +%s)"
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
        echo "${HARNESS_GREEN}     ✓ Success${HARNESS_NC} ${HARNESS_GRAY}($(harness_duration_human $duration))${HARNESS_NC}" >&2
    else
        echo "${HARNESS_RED}     ✗ Failed (exit code: ${exit_code})${HARNESS_NC}" >&2
    fi

    return $exit_code
}

# ============================================================
# Test Result Logging
# ============================================================

harness_pass() {
    local message="$1"
    HARNESS_PASS_COUNT=$((HARNESS_PASS_COUNT + 1))
    echo "${HARNESS_GREEN}  ✓ PASS${HARNESS_NC}: ${message}" >&2
}

harness_fail() {
    local message="$1"
    local details="${2:-}"
    HARNESS_FAIL_COUNT=$((HARNESS_FAIL_COUNT + 1))
    echo "${HARNESS_RED}  ✗ FAIL${HARNESS_NC}: ${message}" >&2
    if [[ -n "$details" ]]; then
        echo "${HARNESS_GRAY}         ${details}${HARNESS_NC}" >&2
    fi
}

harness_skip() {
    local message="$1"
    local reason="${2:-}"
    HARNESS_SKIP_COUNT=$((HARNESS_SKIP_COUNT + 1))
    echo "${HARNESS_YELLOW}  ⊘ SKIP${HARNESS_NC}: ${message}" >&2
    if [[ -n "$reason" ]]; then
        echo "${HARNESS_GRAY}         ${reason}${HARNESS_NC}" >&2
    fi
}

harness_info() {
    local message="$1"
    echo "${HARNESS_BLUE}  ℹ${HARNESS_NC} ${message}" >&2
}

harness_warn() {
    local message="$1"
    echo "${HARNESS_YELLOW}  ⚠${HARNESS_NC} ${message}" >&2
}

# ============================================================
# Assertions
# ============================================================

harness_assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$expected" == "$actual" ]]; then
        harness_pass "$message"
        return 0
    else
        harness_fail "$message" "expected '$expected', got '$actual'"
        return 1
    fi
}

harness_assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if echo "$haystack" | grep -q "$needle"; then
        harness_pass "$message"
        return 0
    else
        harness_fail "$message" "output does not contain '$needle'"
        return 1
    fi
}

harness_assert_file_exists() {
    local path="$1"
    local message="${2:-File exists: $path}"

    if [[ -f "$path" ]]; then
        harness_pass "$message"
        return 0
    else
        harness_fail "$message" "file not found: $path"
        return 1
    fi
}

harness_assert_dir_exists() {
    local path="$1"
    local message="${2:-Directory exists: $path}"

    if [[ -d "$path" ]]; then
        harness_pass "$message"
        return 0
    else
        harness_fail "$message" "directory not found: $path"
        return 1
    fi
}

harness_assert_cmd_succeeds() {
    local message="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        harness_pass "$message"
        return 0
    else
        harness_fail "$message" "command failed: $*"
        return 1
    fi
}

harness_assert_cmd_fails() {
    local message="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        harness_fail "$message" "command succeeded (expected failure): $*"
        return 1
    else
        harness_pass "$message"
        return 0
    fi
}

# ============================================================
# Artifact Capture
# ============================================================

harness_capture_file() {
    local source_path="$1"
    local description="${2:-$(basename "$source_path")}"

    if [[ -f "$source_path" ]]; then
        local artifact_name
        artifact_name="artifact-$(date +%s)-$(basename "$source_path")"
        cp "$source_path" "${HARNESS_ARTIFACT_DIR}/${artifact_name}"
        echo "${HARNESS_GRAY}  📄 Captured: ${description} → ${artifact_name}${HARNESS_NC}" >&2
        return 0
    else
        echo "${HARNESS_YELLOW}  📄 Not found: ${source_path}${HARNESS_NC}" >&2
        return 1
    fi
}

harness_capture_dir() {
    local source_path="$1"
    local description="${2:-$(basename "$source_path")}"

    if [[ -d "$source_path" ]]; then
        local artifact_name
        artifact_name="artifact-$(date +%s)-$(basename "$source_path")"
        cp -r "$source_path" "${HARNESS_ARTIFACT_DIR}/${artifact_name}"
        echo "${HARNESS_GRAY}  📁 Captured: ${description} → ${artifact_name}${HARNESS_NC}" >&2
        return 0
    else
        echo "${HARNESS_YELLOW}  📁 Not found: ${source_path}${HARNESS_NC}" >&2
        return 1
    fi
}

harness_capture_output() {
    local description="$1"
    local content="$2"

    local artifact_name
    artifact_name="output-$(date +%s)-${RANDOM}.txt"
    echo "$content" > "${HARNESS_ARTIFACT_DIR}/${artifact_name}"
    echo "${HARNESS_GRAY}  📝 Captured: ${description} → ${artifact_name}${HARNESS_NC}" >&2
}

# Capture common ACFS artifacts
harness_capture_acfs_state() {
    local acfs_home="${1:-$HOME/.acfs}"

    harness_subsection "Capturing ACFS artifacts"

    harness_capture_file "${acfs_home}/state.json" "ACFS state"
    harness_capture_dir "${acfs_home}/logs" "ACFS logs"
    harness_capture_file "/tmp/acfs-install.log" "Install log"
}

# ============================================================
# Summary
# ============================================================

harness_summary() {
    local now
    now="$(date +%s)"

    # End current section
    if [[ -n "$HARNESS_CURRENT_SECTION" ]] && [[ -n "$HARNESS_SECTION_START" ]]; then
        local section_duration=$((now - HARNESS_SECTION_START))
        echo "${HARNESS_GRAY}  └─ Completed in $(harness_duration_human $section_duration)${HARNESS_NC}" >&2
        echo "" >&2
    fi

    local total_duration=$((now - HARNESS_START_TIME))
    local total_tests=$((HARNESS_PASS_COUNT + HARNESS_FAIL_COUNT + HARNESS_SKIP_COUNT))
    local remove_artifacts=false
    local artifacts_note="${HARNESS_ARTIFACT_DIR}"
    if [[ $HARNESS_FAIL_COUNT -eq 0 ]] && [[ "$HARNESS_ARTIFACT_DIR_CREATED" == "true" ]] &&
        [[ "${HARNESS_KEEP_ARTIFACTS:-false}" != "true" ]]; then
        remove_artifacts=true
        artifacts_note="${HARNESS_ARTIFACT_DIR} (removed: all passed; HARNESS_KEEP_ARTIFACTS=true keeps it)"
    fi

    {
        echo "${HARNESS_BOLD}============================================================${HARNESS_NC}"
        echo "${HARNESS_BOLD}${HARNESS_SUITE_NAME} - Summary${HARNESS_NC}"
        echo "${HARNESS_BOLD}============================================================${HARNESS_NC}"
        echo ""
        echo "  Total tests:  ${total_tests}"
        echo "  ${HARNESS_GREEN}Passed:       ${HARNESS_PASS_COUNT}${HARNESS_NC}"
        echo "  ${HARNESS_RED}Failed:       ${HARNESS_FAIL_COUNT}${HARNESS_NC}"
        echo "  ${HARNESS_YELLOW}Skipped:      ${HARNESS_SKIP_COUNT}${HARNESS_NC}"
        echo ""
        echo "  Duration:     $(harness_duration_human $total_duration)"
        echo "  Artifacts:    ${artifacts_note}"
        echo ""

        if [[ $HARNESS_FAIL_COUNT -eq 0 ]]; then
            echo "${HARNESS_GREEN}✅ All tests passed!${HARNESS_NC}"
        else
            echo "${HARNESS_RED}❌ ${HARNESS_FAIL_COUNT} test(s) failed${HARNESS_NC}"
        fi
        echo "${HARNESS_BOLD}============================================================${HARNESS_NC}"
    } >&2

    # Output JSON summary to stdout for machine parsing
    cat <<EOF
{
  "suite": "${HARNESS_SUITE_NAME}",
  "passed": ${HARNESS_PASS_COUNT},
  "failed": ${HARNESS_FAIL_COUNT},
  "skipped": ${HARNESS_SKIP_COUNT},
  "duration_seconds": ${total_duration},
  "artifacts_dir": "${HARNESS_ARTIFACT_DIR}",
  "success": $([[ $HARNESS_FAIL_COUNT -eq 0 ]] && echo true || echo false)
}
EOF

    if [[ "$remove_artifacts" == "true" ]] && [[ -d "$HARNESS_ARTIFACT_DIR" ]]; then
        rm -rf -- "$HARNESS_ARTIFACT_DIR"
    fi

    # Return appropriate exit code
    [[ $HARNESS_FAIL_COUNT -eq 0 ]]
}

# ============================================================
# Cleanup
# ============================================================

harness_cleanup() {
    local keep_artifacts="${1:-false}"

    if [[ "$keep_artifacts" != "true" ]] && [[ -d "$HARNESS_ARTIFACT_DIR" ]]; then
        rm -rf "$HARNESS_ARTIFACT_DIR"
    fi
}

# Export functions
export -f harness_timestamp harness_timestamp_compact harness_duration_human
export -f harness_init harness_section harness_subsection
export -f harness_run harness_run_live
export -f harness_pass harness_fail harness_skip harness_info harness_warn
export -f harness_assert_eq harness_assert_contains harness_assert_file_exists
export -f harness_assert_dir_exists harness_assert_cmd_succeeds harness_assert_cmd_fails
export -f harness_capture_file harness_capture_dir harness_capture_output harness_capture_acfs_state
export -f harness_summary harness_cleanup
