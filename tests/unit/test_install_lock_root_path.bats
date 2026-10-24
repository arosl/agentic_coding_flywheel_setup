#!/usr/bin/env bats
#
# install.sh's install lock (acfs-0dmd). main opened ~/.acfs/.install.lock
# with `exec 199>`, as root when root installs for another user. A redirect
# truncates and follows a link, and the user owns ~/.acfs, so a link the user
# put at that name made root empty a file such as /etc/shadow, or create one
# such as /etc/nologin, on the next install. A root run now locks
# /run/acfs/install-<user>.lock, in a directory only root can write; a run as
# the user keeps its own ~/.acfs/.install.lock, and probes root's lock for it
# read-only.
#
# acfs-hhse: a sudo user installing for another account still took that
# account's ~/.acfs/.install.lock with `exec 199>`, so a link there truncated
# or created the sudo user's files. Every run now makes the lock only where
# nothing is (noclobber's O_EXCL), refuses a name that isn't a regular file,
# and main opens it read-only.
#
# The tests load acfs_install_lock_file and its helpers from install.sh.
# They can't run as root, so the root case is selected by overriding
# acfs_install_lock_as_root, and /run/acfs is a directory under the temp
# root, owned by the test's user.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    local fn
    for fn in acfs_install_lock_root_dir acfs_install_lock_as_root acfs_install_lock_file \
        acfs_install_lock_is_free acfs_install_lock_root_held; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$PROJECT_ROOT/install.sh")"
        [[ "$(type -t "$fn")" == "function" ]]
    done
    TEST_HOME="$BATS_TEST_TMPDIR/home/tester"
    OUTSIDE="$BATS_TEST_TMPDIR/etc"
    LOCK_ROOT="$BATS_TEST_TMPDIR/run/acfs"
    mkdir -p "$TEST_HOME/.acfs" "$OUTSIDE" "$BATS_TEST_TMPDIR/run"
    TARGET_USER=tester
    unset ACFS_HOME
    ERRORS="$BATS_TEST_TMPDIR/errors"
    log_error() { printf '%s\n' "$*" >> "$ERRORS"; }
    acfs_install_lock_root_dir() { printf '%s\n' "$LOCK_ROOT"; }
}

as_root() { acfs_install_lock_as_root() { return 0; }; }
as_user() { acfs_install_lock_as_root() { return 1; }; }

# main's open of the lock, as it runs after acfs_install_lock_file.
take_lock() {
    local file="$1"
    exec 199<"$file"
    flock -n 199
}

@test "a root run locks /run/acfs/install-<user>.lock, made 0755, and makes nothing in the home" {
    as_root
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$LOCK_ROOT/install-tester.lock" ]]
    [[ -d "$LOCK_ROOT" && ! -L "$LOCK_ROOT" ]]
    [[ "$(stat -c %a "$LOCK_ROOT")" == 755 ]]
    [[ -z "$(ls -A "$TEST_HOME/.acfs")" ]]
}

@test "a root run never opens a link the user put at ~/.acfs/.install.lock: the file behind it keeps its content and mode" {
    as_root
    printf 'root:x:0:0\n' > "$OUTSIDE/shadow"
    chmod 0600 "$OUTSIDE/shadow"
    ln -s "$OUTSIDE/shadow" "$TEST_HOME/.acfs/.install.lock"

    local file
    file="$(acfs_install_lock_file "$TEST_HOME")"
    take_lock "$file"

    [[ "$(cat "$OUTSIDE/shadow")" == "root:x:0:0" ]]
    [[ "$(stat -c %a "$OUTSIDE/shadow")" == 600 ]]
    [[ -L "$TEST_HOME/.acfs/.install.lock" ]]
}

@test "a root run never creates the target of a dangling link at ~/.acfs/.install.lock" {
    as_root
    ln -s "$OUTSIDE/nologin" "$TEST_HOME/.acfs/.install.lock"

    local file
    file="$(acfs_install_lock_file "$TEST_HOME")"
    take_lock "$file"

    [[ ! -e "$OUTSIDE/nologin" ]]
}

@test "a second root run for the same user finds the lock held" {
    as_root
    local file
    file="$(acfs_install_lock_file "$TEST_HOME")"
    take_lock "$file"
    # A second installer, as a separate process: its own open and flock -n.
    run bash -c 'exec 198<"$1"; flock -n 198' _ "$(acfs_install_lock_file "$TEST_HOME")"
    [[ "$status" -ne 0 ]]
}

@test "a root run refuses a lock directory that is a link, or writable by group or other" {
    as_root
    mkdir -p "$OUTSIDE/elsewhere"
    ln -s "$OUTSIDE/elsewhere" "$LOCK_ROOT"
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -ne 0 ]]
    [[ -z "$(ls -A "$OUTSIDE/elsewhere")" ]]
    grep -qF "Refusing the ACFS install lock directory $LOCK_ROOT" "$ERRORS"

    rm -f "$LOCK_ROOT"
    mkdir -m 0777 "$LOCK_ROOT"
    chmod 0777 "$LOCK_ROOT"
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -ne 0 ]]
}

@test "a root run refuses a TARGET_USER that isn't a plain user name, before making anything" {
    as_root
    local name
    for name in '../tmp/x' 'Root' 'a b' '-x'; do
        TARGET_USER="$name"
        run acfs_install_lock_file "$TEST_HOME"
        [[ "$status" -ne 0 ]]
    done
    [[ ! -e "$LOCK_ROOT" ]]
}

@test "a run as the user keeps its own ~/.acfs/.install.lock" {
    as_user
    rmdir "$TEST_HOME/.acfs"
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$TEST_HOME/.acfs/.install.lock" ]]
    [[ -d "$TEST_HOME/.acfs" ]]
    [[ ! -e "$LOCK_ROOT" ]]
}

@test "main takes its lock from acfs_install_lock_file, and opens no name in the home as root" {
    local body
    body="$(sed -n '/^main() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    grep -qF '_acfs_lock_file="$(acfs_install_lock_file "$_acfs_lock_home")" || exit 1' <<<"$body"
    [[ "$body" != *'_acfs_lock_file="$_acfs_lock_dir/.install.lock"'* ]]
    [[ "$body" != *'mkdir -p "$_acfs_lock_dir"'* ]]
    # Read-only opens: no redirect in main truncates the lock (acfs-hhse).
    grep -qF 'exec 199<"$_acfs_lock_file"' <<<"$body"
    grep -qF 'exec 198<"$_acfs_lock_file"' <<<"$body"
    [[ "$body" != *'exec 199>"$_acfs_lock_file"'* && "$body" != *'exec 198>"$_acfs_lock_file"'* ]]
}

@test "any run makes its lock file only where nothing is, as a regular file, and keeps an existing one's content" {
    as_user
    local file
    file="$(acfs_install_lock_file "$TEST_HOME")"
    [[ "$file" == "$TEST_HOME/.acfs/.install.lock" ]]
    [[ -f "$file" && ! -L "$file" && ! -s "$file" ]]

    printf 'keep\n' > "$file"
    file="$(acfs_install_lock_file "$TEST_HOME")"
    take_lock "$file"
    [[ "$(cat "$file")" == "keep" ]]

    as_root
    file="$(acfs_install_lock_file "$TEST_HOME")"
    [[ "$file" == "$LOCK_ROOT/install-tester.lock" && -f "$file" && ! -L "$file" ]]
}

@test "a run that isn't root, a sudo user's for another account say, never writes through a link at ~/.acfs/.install.lock" {
    as_user
    printf 'ssh-ed25519 AAAA admin\n' > "$OUTSIDE/authorized_keys"
    ln -s "$OUTSIDE/authorized_keys" "$TEST_HOME/.acfs/.install.lock"
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -ne 0 ]]
    [[ "$(cat "$OUTSIDE/authorized_keys")" == "ssh-ed25519 AAAA admin" ]]
    grep -qF "Refusing the ACFS install lock $TEST_HOME/.acfs/.install.lock" "$ERRORS"

    rm "$TEST_HOME/.acfs/.install.lock"
    ln -s "$OUTSIDE/created" "$TEST_HOME/.acfs/.install.lock"
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -ne 0 ]]
    [[ ! -e "$OUTSIDE/created" ]]
}

@test "a root run refuses a link at its own lock name too" {
    as_root
    mkdir -m 0755 "$LOCK_ROOT"
    ln -s "$OUTSIDE/elsewhere.lock" "$LOCK_ROOT/install-tester.lock"
    run acfs_install_lock_file "$TEST_HOME"
    [[ "$status" -ne 0 ]]
    [[ ! -e "$OUTSIDE/elsewhere.lock" ]]
}

@test "the probe finds a free lock free and a held one busy, and changes nothing" {
    local file="$BATS_TEST_TMPDIR/probe.lock"
    printf 'keep\n' > "$file"
    run acfs_install_lock_is_free "$file"
    [[ "$status" -eq 0 ]]

    # Another installer's lock: an open file description of its own.
    exec 196<"$file"
    flock -n 196
    run acfs_install_lock_is_free "$file"
    [[ "$status" -ne 0 ]]
    exec 196<&-

    [[ "$(cat "$file")" == "keep" ]]
    run acfs_install_lock_is_free "$BATS_TEST_TMPDIR/missing.lock"
    [[ "$status" -ne 0 ]]
    [[ ! -e "$BATS_TEST_TMPDIR/missing.lock" ]]
}

@test "a run as the user finds root's lock for it held, and names it" {
    mkdir -m 0755 "$LOCK_ROOT"
    : > "$LOCK_ROOT/install-tester.lock"
    chmod 0644 "$LOCK_ROOT/install-tester.lock"
    exec 196<"$LOCK_ROOT/install-tester.lock"
    flock -n 196

    as_user
    run acfs_install_lock_root_held tester
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$LOCK_ROOT/install-tester.lock" ]]

    # Root's lock for another user doesn't stop this one.
    : > "$LOCK_ROOT/install-other.lock"
    run acfs_install_lock_root_held other
    [[ "$status" -ne 0 ]]
    exec 196<&-
}

@test "a run as the user goes on when root's lock is free, missing or a link; a root run never probes it" {
    as_user
    run acfs_install_lock_root_held tester
    [[ "$status" -ne 0 ]]
    [[ ! -e "$LOCK_ROOT" ]]

    mkdir -m 0755 "$LOCK_ROOT"
    : > "$LOCK_ROOT/install-tester.lock"
    run acfs_install_lock_root_held tester
    [[ "$status" -ne 0 && -z "$output" ]]

    : > "$OUTSIDE/held"
    exec 196<"$OUTSIDE/held"
    flock -n 196
    ln -s "$OUTSIDE/held" "$LOCK_ROOT/install-linked.lock"
    run acfs_install_lock_root_held linked
    [[ "$status" -ne 0 ]]

    exec 195<"$LOCK_ROOT/install-tester.lock"
    flock -n 195
    as_root
    run acfs_install_lock_root_held tester
    [[ "$status" -ne 0 ]]
    exec 195<&- 196<&-
}

@test "main refuses or attaches while root's lock for the user is held; the attach poll probes read-only" {
    local body poll
    body="$(sed -n '/^main() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    grep -qF '_acfs_busy_lock="$(acfs_install_lock_root_held "${TARGET_USER:-ubuntu}" || true)"' <<<"$body"
    grep -qF 'acfs_attach_to_running_install "$_acfs_busy_lock" "$_acfs_lock_dir/logs"' <<<"$body"
    poll="$(sed -n '/^acfs_attach_to_running_install() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    grep -qF 'if acfs_install_lock_is_free "$lock_file"; then' <<<"$poll"
    [[ "$poll" != *'exec 197>'* ]]
}
