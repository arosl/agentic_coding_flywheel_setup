#!/usr/bin/env bats
#
# acfs-me42: since acfs-wiip (install_asset) and acfs-hmf1
# (install_checksums_yaml), the target user writes every file those put
# under the target's home, so root's chown -h after them changed nothing
# there and was root's last act by name in a directory the user controls.
# acfs_own_outside_home hands over only what is outside the home, where
# root still writes: an ACFS_HOME or ACFS_BIN_DIR set elsewhere.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CALLS="$BATS_TEST_TMPDIR/sudo-calls"
    FAKE_SUDO="$BATS_TEST_TMPDIR/sudo"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CALLS" > "$FAKE_SUDO"
    chmod 0755 "$FAKE_SUDO"
    eval "$(sed -n '/^acfs_own_outside_home() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    declare -F acfs_own_outside_home >/dev/null
    SUDO="$FAKE_SUDO"
    TARGET_USER=u
    TARGET_HOME=/home/u
}

@test "acfs_own_outside_home: a path under the target's home is left alone" {
    acfs_own_outside_home /home/u/.acfs/bin/acfs /home/u/.p10k.zsh
    [[ ! -e "$CALLS" ]]
}

@test "acfs_own_outside_home: a path outside the home is handed over with chown -h" {
    acfs_own_outside_home /opt/acfs/bin/acfs
    [[ "$(cat "$CALLS")" == "chown -h u:u /opt/acfs/bin/acfs" ]]
}

@test "acfs_own_outside_home: of a mixed list, only the paths outside the home, in one call" {
    acfs_own_outside_home /usr/local/bin/agy /home/u/.local/bin/gmi /home/user2/x /home/u
    [[ "$(cat "$CALLS")" == "chown -h u:u /usr/local/bin/agy /home/user2/x /home/u" ]]
}

@test "acfs_own_outside_home: a trailing slash on TARGET_HOME, and an unset one" {
    TARGET_HOME=/home/u/
    acfs_own_outside_home /home/u/.acfs/VERSION
    [[ ! -e "$CALLS" ]]
    unset TARGET_HOME
    acfs_own_outside_home /home/u/.acfs/VERSION
    [[ "$(cat "$CALLS")" == "chown -h u:u /home/u/.acfs/VERSION" ]]
}

@test "acfs_own_outside_home: chown's failure is the caller's" {
    printf '#!/bin/sh\nexit 3\n' > "$FAKE_SUDO"
    run acfs_own_outside_home /opt/acfs/VERSION
    [[ "$status" -eq 3 ]]
}

@test "install.sh: no chown of the target user's follows an install_asset or install_checksums_yaml directly" {
    # Four lines: the palette's chown sat three below its install_asset,
    # inside an `if` (CrimsonFern's review).
    run awk '
        /^[[:space:]]*#/ { next }
        /install_asset |install_checksums_yaml / { last = NR }
        /chown[^_]/ && /TARGET_USER/ && last && NR - last <= 4 { print NR ": " $0 }
    ' "$PROJECT_ROOT/install.sh"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]] || { echo "$output" >&2; return 1; }
}
