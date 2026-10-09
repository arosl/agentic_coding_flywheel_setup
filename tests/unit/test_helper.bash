#!/usr/bin/env bash
# ============================================================
# ACFS Unit Test Helper
# Common setup, utilities, and mocks for bats unit tests
# ============================================================

# Determine paths
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
ACFS_LIB_DIR="$PROJECT_ROOT/scripts/lib"
FIXTURES_DIR="$TESTS_DIR/fixtures"
LOGS_DIR="$TESTS_DIR/logs"

# Ensure logs directory exists
mkdir -p "$LOGS_DIR"

# ============================================================
# Bats Helpers Loading
# ============================================================

# Try to load bats helpers from common locations
load_bats_helpers() {
    local helpers_loaded=0

    # Try npm global install location
    if [[ -d "$HOME/.bats-support" ]]; then
        source "$HOME/.bats-support/load.bash"
        source "$HOME/.bats-assert/load.bash"
        helpers_loaded=1
    # Try Ubuntu/Debian package location
    elif [[ -f "/usr/lib/bats/bats-support/load.bash" && -f "/usr/lib/bats/bats-assert/load.bash" ]]; then
        source "/usr/lib/bats/bats-support/load.bash"
        source "/usr/lib/bats/bats-assert/load.bash"
        helpers_loaded=1
    # Try legacy system package location
    elif [[ -d "/usr/lib/bats-support" ]]; then
        source "/usr/lib/bats-support/load.bash"
        source "/usr/lib/bats-assert/load.bash"
        helpers_loaded=1
    # Try brew location (macOS)
    elif [[ -d "/usr/local/lib/bats-support" ]]; then
        source "/usr/local/lib/bats-support/load.bash"
        source "/usr/local/lib/bats-assert/load.bash"
        helpers_loaded=1
    # Try bats-core bundled helpers
    elif command -v bats &>/dev/null; then
        local bats_path
        bats_path=$(command -v bats)
        local bats_dir
        bats_dir=$(dirname "$(dirname "$bats_path")")
        if [[ -d "$bats_dir/lib/bats-support" ]]; then
            source "$bats_dir/lib/bats-support/load.bash"
            source "$bats_dir/lib/bats-assert/load.bash"
            helpers_loaded=1
        fi
    fi

    # If helpers not found, define minimal assertion functions
    if [[ $helpers_loaded -eq 0 ]]; then
        # Minimal assert_success
        assert_success() {
            if [[ "$status" -ne 0 ]]; then
                echo "Expected success (exit 0), got exit $status"
                echo "Output: $output"
                return 1
            fi
        }

        # Minimal assert_failure
        assert_failure() {
            if [[ "$status" -eq 0 ]]; then
                echo "Expected failure (exit != 0), got exit 0"
                echo "Output: $output"
                return 1
            fi
        }

        # Minimal assert_output
        assert_output() {
            local expected="$1"
            if [[ "${2:-}" == "--partial" ]]; then
                expected="$1"
                if [[ "$output" != *"$expected"* ]]; then
                    echo "Expected partial output '$expected' not found in:"
                    echo "$output"
                    return 1
                fi
            elif [[ "$1" == "--partial" ]]; then
                expected="${2:-}"
                if [[ "$output" != *"$expected"* ]]; then
                    echo "Expected partial output '$expected' not found in:"
                    echo "$output"
                    return 1
                fi
            else
                if [[ "$output" != "$expected" ]]; then
                    echo "Expected output: $expected"
                    echo "Actual output: $output"
                    return 1
                fi
            fi
        }

        # Minimal refute_output
        refute_output() {
            local unexpected="$1"
            if [[ "$1" == "--partial" ]]; then
                unexpected="$2"
            fi
            if [[ "$output" == *"$unexpected"* ]]; then
                echo "Unexpected output '$unexpected' found in:"
                echo "$output"
                return 1
            fi
        }

        # Minimal assert_equal
        assert_equal() {
            if [[ "$1" != "$2" ]]; then
                echo "Expected: $2"
                echo "Actual:   $1"
                return 1
            fi
        }

        fail() {
            echo "${1:-Test failed}"
            return 1
        }
    fi
}

# Load helpers
load_bats_helpers

# ============================================================
# Test Logging
# ============================================================

# Create test-specific log file
BATS_TEST_LOG=""

setup_test_log() {
    local test_name="${BATS_TEST_NAME:-unknown}"
    # Sanitize test name for filename
    test_name="${test_name//[^a-zA-Z0-9_-]/_}"
    BATS_TEST_LOG="$LOGS_DIR/$(date +%Y%m%d_%H%M%S)_${test_name}.log"
}

# Log message to test log
log_test() {
    local level="$1"
    shift
    [[ -n "$BATS_TEST_LOG" ]] && echo "[$(date +%H:%M:%S.%3N)] [$level] $*" >> "$BATS_TEST_LOG"
}

# Log with PASS level
log_pass() {
    log_test "PASS" "$@"
}

# Log with FAIL level
log_fail() {
    log_test "FAIL" "$@"
}

# Log with INFO level
log_info() {
    log_test "INFO" "$@"
}

# Log with DEBUG level
log_debug() {
    log_test "DEBUG" "$@"
}

# ============================================================
# Mock Terminal Environment
# ============================================================

# Set up mock terminal for TUI tests
setup_mock_terminal() {
    export TERM=dumb
    export ACFS_TEST_MODE=1
    export COLUMNS=80
    export LINES=24
    # Disable any interactive prompts
    export ACFS_NONINTERACTIVE=1
    
    # Disable colors for easier matching
    export ACFS_RED=""
    export ACFS_GREEN=""
    export ACFS_YELLOW=""
    export ACFS_BLUE=""
    export ACFS_GRAY=""
    export ACFS_NC=""
}

# Reset terminal settings
teardown_mock_terminal() {
    unset ACFS_TEST_MODE
    unset ACFS_NONINTERACTIVE
}

# ============================================================
# Temporary Project Helpers
# ============================================================

# Array to track temp dirs for cleanup
declare -a TEMP_DIRS=()

# Create a temporary project directory with specific tech stack
# Usage: create_temp_project [tech_stack...]
# Returns: path to temp directory
create_temp_project() {
    local tmpdir
    tmpdir=$(mktemp -d)
    TEMP_DIRS+=("$tmpdir")

    for tech in "$@"; do
        case "$tech" in
            nodejs|node)
                echo '{"name": "test-project", "version": "1.0.0"}' > "$tmpdir/package.json"
                ;;
            typescript|ts)
                echo '{"compilerOptions": {"target": "ES2022"}}' > "$tmpdir/tsconfig.json"
                ;;
            python|py)
                cat > "$tmpdir/pyproject.toml" << 'PYPROJECT'
[project]
name = "test-project"
version = "0.1.0"
PYPROJECT
                ;;
            rust)
                cat > "$tmpdir/Cargo.toml" << 'CARGO'
[package]
name = "test-project"
version = "0.1.0"
CARGO
                ;;
            go|golang)
                cat > "$tmpdir/go.mod" << 'GOMOD'
module test-project
go 1.21
GOMOD
                ;;
            docker)
                echo 'FROM alpine:latest' > "$tmpdir/Dockerfile"
                ;;
            git)
                git init "$tmpdir" &>/dev/null
                ;;
        esac
    done

    echo "$tmpdir"
}

# Create an empty temporary directory
create_temp_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    TEMP_DIRS+=("$tmpdir")
    echo "$tmpdir"
}

# Cleanup all temporary directories
cleanup_temp_dirs() {
    for dir in "${TEMP_DIRS[@]}"; do
        [[ -d "$dir" ]] && rm -rf "$dir"
    done
    TEMP_DIRS=()
}

# Create a temporary file with optional content
# Usage: create_temp_file [content]
# Returns: path to temp file
create_temp_file() {
    local content="${1:-}"
    local tmpfile
    tmpfile=$(mktemp)
    # Track the file via a temp dir wrapper or just rely on OS cleanup?
    # Better to put it in a tracked temp dir.
    
    if [[ ${#TEMP_DIRS[@]} -eq 0 ]]; then
        create_temp_dir >/dev/null
    fi
    local dir="${TEMP_DIRS[0]}"
    tmpfile=$(mktemp -p "$dir")
    
    if [[ -n "$content" ]]; then
        echo "$content" > "$tmpfile"
    fi
    echo "$tmpfile"
}

# ============================================================
# Command Stubbing (PATH manipulation)
# ============================================================

# Directory for stubbed commands
STUB_DIR=""

# Initialize stub directory
init_stub_dir() {
    if [[ -z "$STUB_DIR" ]]; then
        STUB_DIR=$(create_temp_dir)
        export PATH="$STUB_DIR:$PATH"
        log_debug "Initialized stub directory: $STUB_DIR"
    fi
}

# Stub a command to return specific output and/or exit code
# Usage: stub_command "cmd_name" "output" [exit_code]
stub_command() {
    init_stub_dir
    local cmd="$1"
    local output="${2:-}"
    local exit_code="${3:-0}"
    local stub_path="$STUB_DIR/$cmd"

    cat > "$stub_path" <<EOF
#!/bin/bash
printf '%s' "$output"
exit $exit_code
EOF
    chmod +x "$stub_path"
    log_debug "Stubbed command: $cmd (exit $exit_code)"
}

# Stub a command to act as a spy (log args to file)
# Usage: spy_command "cmd_name" [exit_code]
# Logs calls to: $STUB_DIR/cmd_name.log
spy_command() {
    init_stub_dir
    local cmd="$1"
    local exit_code="${2:-0}"
    local stub_path="$STUB_DIR/$cmd"
    local log_path="$STUB_DIR/$cmd.log"

    cat > "$stub_path" <<EOF
#!/bin/bash
echo "\$@" >> "$log_path"
exit $exit_code
EOF
    chmod +x "$stub_path"
    log_debug "Spied command: $cmd (logging to $log_path)"
}

# Stub curl to return content (handles -o flag for file output)
# Usage: stub_curl "content" [exit_code]
stub_curl() {
    init_stub_dir
    local content="$1"
    local exit_code="${2:-0}"
    local stub_path="$STUB_DIR/curl"

    cat > "$stub_path" <<'STUB_EOF'
#!/bin/bash
CONTENT="__CONTENT_PLACEHOLDER__"
EXIT_CODE=__EXIT_CODE__

# Parse args to find -o flag
output_file=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-o" ]]; then
        output_file="${args[$((i+1))]}"
        break
    fi
done

if [[ -n "$output_file" ]]; then
    # Write to file
    printf '%s' "$CONTENT" > "$output_file"
else
    # Write to stdout
    printf '%s' "$CONTENT"
fi
exit $EXIT_CODE
STUB_EOF

    # Replace placeholders with actual values
    # Use @ as sed delimiter since content might have /
    sed -i "s@__CONTENT_PLACEHOLDER__@$content@g" "$stub_path"
    sed -i "s@__EXIT_CODE__@$exit_code@g" "$stub_path"

    chmod +x "$stub_path"
    log_debug "Stubbed curl with content (exit $exit_code)"
}

# ============================================================
# Common Setup/Teardown
# ============================================================

# Standard setup for all tests
common_setup() {
    setup_test_log
    setup_mock_terminal
    log_info "Starting test: ${BATS_TEST_NAME:-unknown}"
}

# Standard teardown for all tests
common_teardown() {
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_pass "Test passed"
    else
        log_fail "Test failed with exit code $exit_code"
    fi
    cleanup_temp_dirs
    teardown_mock_terminal
    log_info "Finished test: ${BATS_TEST_NAME:-unknown}"
}

# ============================================================
# Assertion Wrappers with Logging
# ============================================================

# Assert success with logging
assert_success_logged() {
    log_debug "Checking for success (exit 0)"
    if [[ "$status" -ne 0 ]]; then
        log_fail "Expected exit 0, got exit $status"
        log_fail "Output: $output"
        return 1
    fi
    log_pass "Command succeeded with exit 0"
}

# Assert failure with logging
assert_failure_logged() {
    log_debug "Checking for failure (exit != 0)"
    if [[ "$status" -eq 0 ]]; then
        log_fail "Expected failure, got exit 0"
        log_fail "Output: $output"
        return 1
    fi
    log_pass "Command failed with exit $status (expected)"
}

# Assert output contains string with logging
assert_contains_logged() {
    local expected="$1"
    log_debug "Checking output contains: $expected"
    if [[ "$output" != *"$expected"* ]]; then
        log_fail "Expected to find '$expected' in output"
        log_fail "Actual output: $output"
        return 1
    fi
    log_pass "Found expected string in output"
}

# ============================================================
# File Comparison Helpers
# ============================================================

# Compare output to a golden file
assert_matches_golden() {
    local golden_file="$1"
    local actual_file
    actual_file=$(mktemp)
    echo "$output" > "$actual_file"

    if ! diff -q "$golden_file" "$actual_file" &>/dev/null; then
        log_fail "Output does not match golden file: $golden_file"
        log_fail "Diff:"
        diff "$golden_file" "$actual_file" >> "$BATS_TEST_LOG" 2>&1 || true
        rm -f "$actual_file"
        return 1
    fi

    rm -f "$actual_file"
    log_pass "Output matches golden file"
}

# ============================================================
# Source Code Under Test
# ============================================================

# Source a library file from scripts/lib
source_lib() {
    local lib_name="$1"
    local lib_path="$ACFS_LIB_DIR/${lib_name}.sh"

    if [[ ! -f "$lib_path" ]]; then
        echo "DEBUG: ACFS_LIB_DIR=$ACFS_LIB_DIR" >&2
        echo "DEBUG: PROJECT_ROOT=$PROJECT_ROOT" >&2
        echo "DEBUG: TESTS_DIR=$TESTS_DIR" >&2
        log_fail "Library not found: $lib_path"
        return 1
    fi

    log_debug "Sourcing library: $lib_path"
    source "$lib_path"
}

# ============================================================
# Mock Function Helpers
# ============================================================

# Create a mock function that returns specific output
# Usage: mock_function function_name "return value"
mock_function() {
    local func_name="$1"
    local return_value="$2"
    local quoted_value=""

    [[ "$func_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    printf -v quoted_value '%q' "$return_value"
    # The function name is validated and the value is shell-quoted literal data.
    eval "${func_name}() { printf '%s\\n' $quoted_value; }" # ubs:ignore -- validated name and shell-quoted literal
    log_debug "Created mock for: $func_name"
}

# Create a mock function that fails
# Usage: mock_function_fail function_name [exit_code]
mock_function_fail() {
    local func_name="$1"
    local exit_code="${2:-1}"

    [[ "$func_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    [[ "$exit_code" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$exit_code <= 255 )) || return 1
    # Only a validated function name and a bounded decimal status enter eval.
    eval "${func_name}() { return $((10#$exit_code)); }" # ubs:ignore -- validated name and bounded integer
    log_debug "Created failing mock for: $func_name (exit $exit_code)"
}
