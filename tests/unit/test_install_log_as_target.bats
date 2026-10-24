#!/usr/bin/env bats
#
# install.sh's log, summary and performance budget (acfs-grmg). They go to
# ~/.acfs/logs, the target user's own directory, under names predictable to
# the second. Root wrote them by path: a redirect created or truncated a
# link's target, and at the end sed -i read a link at the log's name and put
# a regular copy of its target there, which root then chowned to the user.
# Now, when root installs for another account, the user writes them.
#
# The tests can't run as root. acfs_running_as_root is stubbed true, the
# target is this test's own user, and the home's directories are read-only
# to the test's shell: only a command through the run_as_target stub, which
# records each call, may make a name there. Files stay writable, so the live
# log's appends, which run in the background, need no unlock.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    local fn
    for fn in acfs_running_as_root acfs_log_path_as_target acfs_log_mkdir \
        acfs_log_write acfs_log_read acfs_log_skip_as_target acfs_log_tee \
        acfs_log_init acfs_log_close \
        acfs_dotfile_write_as_target acfs_performance_budget_emit acfs_summary_emit; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done

    TARGET_USER="$(id -un)"
    TARGET_HOME="$BATS_TEST_TMPDIR/home"
    ACFS_HOME="$TARGET_HOME/.acfs"
    MODE=safe
    # Stands for a root directory: the user can't write there.
    OUTSIDE="$BATS_TEST_TMPDIR/outside"
    CALLS="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$TARGET_HOME/.acfs" "$OUTSIDE"
    : > "$CALLS"

    log_detail() { :; }
    log_warn() { printf 'WARN: %s\n' "$*" >> "$CALLS"; }
    log_error() { printf 'ERROR: %s\n' "$*" >> "$CALLS"; }
    acfs_early_system_binary_path() { PATH=/usr/bin:/bin command -v "$1"; }
    acfs_home_for_user() { printf '%s\n' "$TARGET_HOME"; }
    acfs_running_as_root() { return 0; }
    chown() { printf 'chown %s\n' "$*" >> "$CALLS"; }
    # Names are predictable to the second; pin that second.
    date() {
        if [[ "${1:-}" == "+%Y%m%d_%H%M%S" ]]; then
            printf '20261024_073000\n'
        else
            command date "$@"
        fi
    }
    # The target user's rights: names in the home may change while the
    # command runs. An append makes no name, so it runs without the unlock.
    run_as_target() {
        local rc=0
        printf 'run_as_target %s\n' "${1##*/} ${*:2}" >> "$CALLS"
        if [[ "${1##*/}" == "tee" && "${2:-}" == "-a" ]]; then
            "$@"
            return
        fi
        unlock_home
        "$@" || rc=$?
        lock_home
        return "$rc"
    }
}

teardown() {
    unlock_home
    chmod -R u+rwX "$OUTSIDE" 2>/dev/null || true
}

lock_home() { find "$TARGET_HOME" -type d -exec chmod a-w {} +; }
unlock_home() { find "$TARGET_HOME" -type d -exec chmod u+w {} +; }

# Runs acfs_log_init, puts stderr back and prints its rc and log file.
init_log() {
    local rc=0
    acfs_log_init || rc=$?
    if [[ -n "${ACFS_LOG_ORIGINAL_STDERR_FD:-}" ]]; then
        exec 2>&"$ACFS_LOG_ORIGINAL_STDERR_FD"
    fi
    echo "rc=$rc file=${ACFS_LOG_FILE:-}"
}

# Waits up to 5s for FILE to hold TEXT: the live log's user-side tee writes
# in the background.
wait_for_text() {
    local file="$1" text="$2" i
    for i in $(seq 1 50); do
        grep -qF -- "$text" "$file" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

@test "the log's writes are the user's only in a root run for an existing account, under its existing home" {
    acfs_log_path_as_target "$TARGET_HOME/.acfs/logs/install.log"

    run acfs_log_path_as_target "$OUTSIDE/install.log"
    [[ "$status" -ne 0 ]]
    run acfs_log_path_as_target "$TARGET_HOME"
    [[ "$status" -ne 0 ]]
    TARGET_USER=root run acfs_log_path_as_target "$TARGET_HOME/.acfs/logs/install.log"
    [[ "$status" -ne 0 ]]
    TARGET_USER=acfs-no-such-user-x run acfs_log_path_as_target "$TARGET_HOME/.acfs/logs/install.log"
    [[ "$status" -ne 0 ]]
    TARGET_HOME="$BATS_TEST_TMPDIR/missing" run acfs_log_path_as_target "$BATS_TEST_TMPDIR/missing/.acfs/logs/install.log"
    [[ "$status" -ne 0 ]]
    acfs_running_as_root() { return 1; }
    run acfs_log_path_as_target "$TARGET_HOME/.acfs/logs/install.log"
    [[ "$status" -ne 0 ]]
}

@test "acfs_log_init as root for the user: the user makes ~/.acfs/logs and writes the header, and root chowns nothing" {
    lock_home
    run init_log
    local log="$TARGET_HOME/.acfs/logs/install-20261024_073000.log"
    [[ "$output" == *"rc=0 file=$log"* ]]
    [[ -f "$log" && ! -L "$log" ]]
    grep -qF '=== ACFS Install Log ===' "$log"
    grep -qxF "run_as_target mkdir -p -- $TARGET_HOME/.acfs/logs" "$CALLS"
    grep -qxF "run_as_target tee $log" "$CALLS"
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]
}

@test "a link the user put at ~/.acfs/logs, or at the log's name, gets no file from the install, which goes on without a log" {
    ln -s "$OUTSIDE" "$TARGET_HOME/.acfs/logs"
    chmod a-w "$OUTSIDE"
    lock_home
    run init_log
    [[ "$output" == *"rc=0 file="* && "$output" != *"rc=0 file=/"* ]]
    [[ -z "$(ls -A "$OUTSIDE")" ]]
    grep -qF "WARN: No install log this run: $TARGET_USER can't write $TARGET_HOME/.acfs/logs" "$CALLS"

    unlock_home
    rm "$TARGET_HOME/.acfs/logs"
    mkdir "$TARGET_HOME/.acfs/logs"
    chmod u+w "$OUTSIDE"
    printf 'root:x:0:0\n' > "$OUTSIDE/shadow"
    chmod 0400 "$OUTSIDE/shadow"
    ln -s "$OUTSIDE/shadow" "$TARGET_HOME/.acfs/logs/install-20261024_073000.log"
    lock_home
    run init_log
    [[ "$output" == *"rc=0 file="* && "$output" != *"rc=0 file=/"* ]]
    [[ "$(cat "$OUTSIDE/shadow")" == "root:x:0:0" ]]
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]
}

@test "a ~/.acfs the user can't write, which root left behind: no log this run, a warning, and the install goes on" {
    lock_home
    # Stands for root's ~/.acfs: the user's mkdir of logs there fails.
    run_as_target() {
        printf 'run_as_target %s\n' "${1##*/} ${*:2}" >> "$CALLS"
        return 1
    }
    run init_log
    [[ "$output" == *"rc=0 file="* && "$output" != *"rc=0 file=/"* ]]
    [[ ! -e "$TARGET_HOME/.acfs/logs" ]]
    grep -qxF "run_as_target mkdir -p -- $TARGET_HOME/.acfs/logs" "$CALLS"
    grep -qF "WARN: No install log this run" "$CALLS"
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]

    # A run as the user that can't make its own log directory stops, as before.
    acfs_running_as_root() { return 1; }
    chmod a-w "$TARGET_HOME/.acfs"
    run init_log
    [[ "$output" == *"rc=1"* ]]
}

@test "acfs_log_close as root for the user: the user strips the colours and appends the footer, and root chowns nothing" {
    mkdir -p "$TARGET_HOME/.acfs/logs"
    ACFS_LOG_FILE="$TARGET_HOME/.acfs/logs/install-20261024_073000.log"
    printf 'header\n\033[1;32mgreen\033[0m line\n' > "$ACFS_LOG_FILE"
    ACFS_LOG_INITIALIZED=true
    lock_home
    acfs_log_close
    [[ "$(sed -n 2p "$ACFS_LOG_FILE")" == "green line" ]]
    grep -q '^Finished: ' "$ACFS_LOG_FILE"
    grep -q "^run_as_target sed -i .* $ACFS_LOG_FILE\$" "$CALLS"
    grep -qxF "run_as_target tee -a $ACFS_LOG_FILE" "$CALLS"
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]
}

@test "a link the user swapped in at the log's name before acfs_log_close isn't copied, and nothing is handed over" {
    mkdir -p "$TARGET_HOME/.acfs/logs"
    printf 'root:$6$secret:19000::\n' > "$OUTSIDE/shadow"
    chmod 0000 "$OUTSIDE/shadow"
    ACFS_LOG_FILE="$TARGET_HOME/.acfs/logs/install-20261024_073000.log"
    ln -s "$OUTSIDE/shadow" "$ACFS_LOG_FILE"
    ACFS_LOG_INITIALIZED=true
    lock_home
    acfs_log_close
    [[ -L "$ACFS_LOG_FILE" ]]
    grep -q "^run_as_target sed -i .* $ACFS_LOG_FILE\$" "$CALLS"
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]
    chmod 0400 "$OUTSIDE/shadow"
    [[ "$(cat "$OUTSIDE/shadow")" == 'root:$6$secret:19000::' ]]
}

@test "the live log: root's tee feeds the user's tee, and the terminal copy goes on when the user's side stops" {
    mkdir -p "$TARGET_HOME/.acfs/logs"
    ACFS_LOG_FILE="$TARGET_HOME/.acfs/logs/install-20261024_073000.log"
    : > "$ACFS_LOG_FILE"
    lock_home
    local term="$BATS_TEST_TMPDIR/terminal"
    printf 'live line\n' | acfs_log_tee 1 > "$term"
    [[ "$(cat "$term")" == "live line" ]]
    wait_for_text "$ACFS_LOG_FILE" "live line"
    grep -qxF "run_as_target tee -a $ACFS_LOG_FILE" "$CALLS"

    # The user's tee is gone at once; root's tee still copies everything.
    run_as_target() { return 1; }
    seq 1 200000 | acfs_log_tee 1 > "$term" || true
    [[ "$(wc -l < "$term")" -eq 200000 ]]
    [[ "$(tail -n 1 "$term")" == "200000" ]]
}

@test "the summary and the performance budget: the user makes and writes them, the budget reads the summary through the user, and root chowns nothing" {
    command -v jq >/dev/null || skip "jq is not installed"
    lock_home
    acfs_summary_emit success 42
    local summary="$TARGET_HOME/.acfs/logs/install_summary_20261024_073000.json"
    local budget="$TARGET_HOME/.acfs/logs/performance_budget_20261024_073000.json"
    [[ "$ACFS_SUMMARY_FILE" == "$summary" ]]
    jq -e '.status == "success"' "$summary" >/dev/null
    jq -e '.artifacts[0].path == "install_summary_20261024_073000.json"' "$budget" >/dev/null
    grep -qxF "run_as_target mkdir -p -- $TARGET_HOME/.acfs/logs" "$CALLS"
    grep -qxF "run_as_target tee $summary" "$CALLS"
    grep -qxF "run_as_target cat -- $summary" "$CALLS"
    grep -qxF "run_as_target tee $budget" "$CALLS"
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]
}

@test "a link the user put at the summary's name gets nothing written through it" {
    command -v jq >/dev/null || skip "jq is not installed"
    mkdir -p "$TARGET_HOME/.acfs/logs"
    printf 'keep\n' > "$OUTSIDE/victim"
    chmod 0444 "$OUTSIDE/victim"
    ln -s "$OUTSIDE/victim" "$TARGET_HOME/.acfs/logs/install_summary_20261024_073000.json"
    lock_home
    run acfs_summary_emit success 42
    [[ "$status" -ne 0 ]]
    [[ "$(cat "$OUTSIDE/victim")" == "keep" ]]
    [[ -z "$(grep '^chown' "$CALLS" || true)" ]]
}

@test "a run as the user, or for an account that doesn't exist yet, writes by path as before" {
    acfs_running_as_root() { return 1; }
    acfs_log_mkdir "$TARGET_HOME/.acfs/logs"
    printf 'mine\n' | acfs_log_write "$TARGET_HOME/.acfs/logs/a.log"
    printf 'more\n' | acfs_log_write "$TARGET_HOME/.acfs/logs/a.log" --append
    [[ "$(cat "$TARGET_HOME/.acfs/logs/a.log")" == $'mine\nmore' ]]
    [[ "$(acfs_log_read "$TARGET_HOME/.acfs/logs/a.log")" == $'mine\nmore' ]]
    [[ ! -s "$CALLS" ]]

    acfs_running_as_root() { return 0; }
    TARGET_USER=acfs-no-such-user-x
    printf 'new\n' | acfs_log_write "$TARGET_HOME/.acfs/logs/b.log"
    [[ "$(cat "$TARGET_HOME/.acfs/logs/b.log")" == "new" ]]
    [[ ! -s "$CALLS" ]]
}

@test "install.sh writes nothing in the log directory as root by path: every write goes through the as-target helpers" {
    local body fn
    for fn in acfs_log_init acfs_log_close acfs_summary_emit acfs_performance_budget_emit; do
        body="$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ -n "$body" ]]
        [[ "$body" != *'> "$ACFS_LOG_FILE"'* && "$body" != *'>> "$ACFS_LOG_FILE"'* ]]
        [[ "$body" != *'> "$ACFS_SUMMARY_FILE"'* && "$body" != *'> "$budget_file"'* ]]
        [[ "$body" != *'tee -a "$ACFS_LOG_FILE"'* ]]
        [[ "$body" != *'mkdir -p "$log_dir"'* && "$body" != *'mkdir -p "$summary_dir"'* ]]
    done
}
