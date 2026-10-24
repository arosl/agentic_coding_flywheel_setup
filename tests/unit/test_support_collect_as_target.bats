#!/usr/bin/env bats
#
# support.sh run as root for a home another account owns (a by-hand
# `sudo bash <checkout>/scripts/lib/support.sh`; the acfs wrapper already
# drops) would run that account's ~/.acfs scripts and read its files as root.
# acfs-wrdc: before it collects anything, it runs again as the account that
# owns the target, under a clean environment, and returns that run's status.
#
# A test can't be root, so support_running_as_root is replaced, and runuser,
# sudo and stat by stubs. The account is this test's own, with a passwd entry
# whose home is the test's target home.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    ME="$(id -un)"
    MY_UID="$(id -u)"
    MY_GID="$(id -g)"
    TARGET="$BATS_TEST_TMPDIR/home"
    SYSTEM_STATE="$BATS_TEST_TMPDIR/system-state.json"
    CALLS="$BATS_TEST_TMPDIR/calls"
    ARGV="$BATS_TEST_TMPDIR/argv"
    OWNERS="$BATS_TEST_TMPDIR/owners"
    mkdir -p "$TARGET/.acfs/scripts/lib"
    printf '{"target_user":"%s","target_home":"%s"}\n' "$ME" "$TARGET" > "$TARGET/.acfs/state.json"
    : > "$CALLS"
    export CALLS ARGV

    # The account's scripts, which only the account may run. Each records the
    # user it runs as and whether root's environment reached it.
    local script
    for script in scripts/lib/doctor.sh scripts/agent-readiness-audit.sh \
        scripts/lib/swarm_status.sh scripts/lib/provenance.sh; do
        printf '#!/bin/bash\nprintf "%%s USER=%%s ROOT_ONLY=%%s\\n" "%s" "${USER:-}" "${ROOT_ONLY:-}" >> "%s"\nprintf %s\n' \
            "${script##*/}" "$CALLS" "'{\"tools\":[]}'" > "$TARGET/.acfs/$script"
    done

    # runuser -u USER -- CMD... and sudo -n -u USER -- CMD...: record the
    # arguments, then exit with RUNNER_STATUS, or with FORWARD=1 run CMD.
    FAKE_RUNUSER="$BATS_TEST_TMPDIR/runuser"
    cat > "$FAKE_RUNUSER" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV"
printf 'runner\n' >> "$CALLS"
[[ "${FORWARD:-}" == 1 ]] || exit "${RUNNER_STATUS:-0}"
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
exec "$@"
STUB
    chmod 0755 "$FAKE_RUNUSER"
    FAKE_SUDO=""

    # stat -L -c FMT -- PATH: answers "uid:name" from OWNERS, "PATH uid:name" lines.
    FAKE_STAT="$BATS_TEST_TMPDIR/stat"
    cat > "$FAKE_STAT" <<'STUB'
#!/bin/bash
awk -v p="${!#}" '$1 == p { print $2; found = 1; exit } END { exit !found }' "$OWNERS"
STUB
    chmod 0755 "$FAKE_STAT"
    printf '%s %s:%s\n' "$TARGET" "$MY_UID" "$ME" "$TARGET/.acfs" "$MY_UID" "$ME" > "$OWNERS"
    export OWNERS

    # Only the collection knobs a case sets reach the account's run.
    unset ACFS_SWARM_INVENTORY_FILE ACFS_TEAM_PROFILE_PATH ACFS_RESOURCE_PROFILE_HOME \
        ACFS_LOCAL_PROGRESS_FILE ACFS_CHECKPOINT_STALE_SECONDS ACFS_SUPPORT_NOW_EPOCH \
        SUPPORT_BUNDLE_DOCTOR_TIMEOUT SUPPORT_BUNDLE_SWARM_STATUS_TIMEOUT \
        SUPPORT_BUNDLE_SWARM_TIMELINE_TIMEOUT SUPPORT_BUNDLE_PROVENANCE_TIMEOUT \
        SUPPORT_BUNDLE_RESOURCE_PROFILE_TIMEOUT SUPPORT_BUNDLE_CREDENTIAL_STATUS_TIMEOUT \
        SUPPORT_BUNDLE_SWARM_INVENTORY_TIMEOUT NO_COLOR TERM ACFS_HOME TARGET_USER

    TARGET_HOME="$TARGET" ACFS_SYSTEM_STATE_FILE="$SYSTEM_STATE"
    # shellcheck source=../../scripts/lib/support.sh
    source "$PROJECT_ROOT/scripts/lib/support.sh"
    eval "real_$(declare -f support_system_binary_path)"
    support_system_binary_path() {
        case "$1" in
            runuser) [[ -n "$FAKE_RUNUSER" ]] && printf '%s\n' "$FAKE_RUNUSER" ;;
            sudo) [[ -n "$FAKE_SUDO" ]] && printf '%s\n' "$FAKE_SUDO" ;;
            stat) printf '%s\n' "$FAKE_STAT" ;;
            *) real_support_system_binary_path "$1" ;;
        esac
    }
    support_getent_passwd_entry() {
        case "${1-}" in
            "$ME") printf '%s:x:%s:%s::%s:/bin/zsh\n' "$ME" "$MY_UID" "$MY_GID" "$TARGET" ;;
            other) printf 'other:x:4243:4243::/home/other:/bin/sh\n' ;;
            *) return 1 ;;
        esac
    }
}

as_root() {
    support_running_as_root() { return 0; }
}

@test "a root run for a user's home runs again as that user, with a clean environment, before it collects" {
    as_root
    SUPPORT_BUNDLE_DOCTOR_TIMEOUT=7
    export ROOT_ONLY=secret

    run main --verbose --output "$BATS_TEST_TMPDIR/out"

    [[ "$status" -eq 0 ]]
    local expected
    expected="$(printf '%s\n' -u "$ME" -- "$(real_support_system_binary_path env)" -i \
        "HOME=$TARGET" "USER=$ME" "LOGNAME=$ME" "SHELL=/bin/zsh" \
        "PATH=$TARGET/.acfs/bin:$TARGET/.local/bin:$TARGET/.cargo/bin:$TARGET/.bun/bin:$TARGET/.atuin/bin:$TARGET/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "TARGET_HOME=$TARGET" "ACFS_HOME=$TARGET/.acfs" "ACFS_SYSTEM_STATE_FILE=$SYSTEM_STATE" \
        "SUPPORT_BUNDLE_DOCTOR_TIMEOUT=7" \
        "$(real_support_system_binary_path bash)" "$PROJECT_ROOT/scripts/lib/support.sh" \
        --verbose --output "$BATS_TEST_TMPDIR/out")"
    diff <(printf '%s\n' "$expected") "$ARGV"
    # Root ran none of the user's scripts and wrote nothing.
    [[ "$(cat "$CALLS")" == runner ]]
    [[ ! -e "$BATS_TEST_TMPDIR/out" && ! -e "$TARGET/.acfs/support" ]]
}

@test "the user's run collects the bundle into the user's ~/.acfs/support, without root's environment" {
    as_root
    export ROOT_ONLY=secret FORWARD=1

    run main

    [[ "$status" -eq 0 ]]
    [[ "${lines[-1]}" == "$(cd "$TARGET" && pwd -P)/.acfs/support/"*/diagnostics.tar.gz ]]
    [[ -f "${lines[-1]}" ]]
    [[ "$(head -n 1 "$CALLS")" == runner ]]
    grep -qx "doctor.sh USER=$ME ROOT_ONLY=" "$CALLS"
    [[ -z "$(grep 'ROOT_ONLY=secret' "$CALLS" || true)" ]]
}

@test "the user's run's exit status is the root run's" {
    as_root
    export RUNNER_STATUS=7

    run main

    [[ "$status" -eq 7 ]]
    [[ ! -e "$TARGET/.acfs/support" ]]
}

@test "without runuser it runs as the user through sudo -n; with neither it refuses to collect as root" {
    as_root
    FAKE_SUDO="$FAKE_RUNUSER"
    FAKE_RUNUSER=""

    run main

    [[ "$status" -eq 0 ]]
    [[ "$(head -n 4 "$ARGV" | tr '\n' ' ')" == "-n -u $ME -- " ]]

    FAKE_SUDO=""
    : > "$CALLS"
    run main

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Need runuser or sudo"*"refusing to collect as root"* ]]
    [[ ! -s "$CALLS" && ! -e "$TARGET/.acfs/support" ]]
}

@test "an owner without a matching account, or two owners, refuses to collect as root" {
    as_root
    printf '%s %s\n' "$TARGET" 4242:UNKNOWN "$TARGET/.acfs" "$MY_UID:$ME" > "$OWNERS"
    run main
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Cannot tell which account owns $TARGET; refusing to collect as root"* ]]

    # The name has an account, but not that uid.
    printf '%s %s\n' "$TARGET" "4242:$ME" "$TARGET/.acfs" "$MY_UID:$ME" > "$OWNERS"
    run main
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Cannot tell which account owns $TARGET; refusing to collect as root"* ]]

    printf '%s %s:%s\n' "$TARGET" "$MY_UID" "$ME" "$TARGET/.acfs" 4243 other > "$OWNERS"
    run main
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"belong to different accounts; refusing to collect as root"* ]]

    [[ ! -s "$CALLS" && ! -e "$TARGET/.acfs/support" ]]
}

@test "root's own home, or a run that isn't root, collects in this run" {
    SUPPORT_TARGET_HOME="$TARGET"
    _SUPPORT_ACFS_HOME="$TARGET/.acfs"
    run support_reexec_as_owner --verbose
    [[ "$status" -eq 0 ]]

    as_root
    printf '%s 0:root\n' "$TARGET" "$TARGET/.acfs" > "$OWNERS"
    run support_reexec_as_owner --verbose
    [[ "$status" -eq 0 ]]

    [[ ! -s "$CALLS" ]]
}
