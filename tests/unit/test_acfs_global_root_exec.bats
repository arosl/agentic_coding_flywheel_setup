#!/usr/bin/env bats
#
# scripts/acfs-global's direct-exec branch (acfs-67mn). When no ACFS owner
# resolves, or the caller is the owner, the wrapper runs acfs_bin itself.
# As root, that must never be a file another account controls, such as a
# user's ~/.acfs/bin/acfs: root_may_exec_directly allows it only when root
# owns it and every directory above it, as named and as resolved, and
# nothing there is writable by group or other.
#
# The ownership cases replace stat and readlink (path_owner_mode_type,
# resolve_path_fully) with a table of paths, since a test can't make root's
# files. One case uses the real ones on this host's own files.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WRAPPER="$PROJECT_ROOT/scripts/acfs-global"
    local fn
    for fn in system_binary_path path_owner_mode_type resolve_path_fully \
        root_owned_path_chain root_may_exec_directly; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$WRAPPER")"
        [[ "$(type -t "$fn")" == "function" ]]
    done
    LINKS=""
    TABLE="
/ 0 755 directory
/root 0 700 directory
/root/.acfs 0 755 directory
/root/.acfs/bin 0 755 directory
/root/.acfs/bin/acfs 0 755 regular file
/root/.local 0 755 directory
/root/.local/bin 0 755 directory
/root/.local/bin/acfs 0 777 symbolic link
/home 0 755 directory
/home/u 1000 750 directory
/home/u/.acfs 1000 755 directory
/home/u/.acfs/bin 1000 755 directory
/home/u/.acfs/bin/acfs 1000 755 regular file
/home/u/.acfs/bin/rootfile 0 755 regular file
/srv 0 755 directory
/srv/u 0 755 directory
/srv/u/acfs 1000 755 regular file
/srv/link 0 777 symbolic link
/srv/dir 0 755 directory
/tmp 0 1777 directory
/tmp/acfs 0 755 regular file
/opt 0 775 directory
/opt/acfs 0 755 regular file"
}

# The table stands in for stat; LINKS ("link target" lines) for readlink -f.
use_table() {
    path_owner_mode_type() {
        local line=""
        line="$(awk -v p="$1" '$1 == p { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$TABLE")"
        [[ -n "$line" ]] || return 1
        printf '%s\n' "$line"
    }
    resolve_path_fully() {
        local target=""
        target="$(awk -v p="$1" '$1 == p { print $2; exit }' <<<"$LINKS")"
        printf '%s\n' "${target:-$1}"
    }
}

@test "root's own install runs directly, by its path or through root's link to it" {
    use_table
    root_may_exec_directly /root/.acfs/bin/acfs
    LINKS="/root/.local/bin/acfs /root/.acfs/bin/acfs"
    root_may_exec_directly /root/.local/bin/acfs
}

@test "a user's ~/.acfs/bin/acfs never runs as root, nor a root file in a directory the user owns" {
    use_table
    run root_may_exec_directly /home/u/.acfs/bin/acfs
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /home/u/.acfs/bin/rootfile
    [[ "$status" -ne 0 ]]
}

@test "a root link to a user's file, or a user's file in root's directories, never runs as root" {
    use_table
    LINKS="/srv/link /home/u/.acfs/bin/acfs"
    run root_may_exec_directly /srv/link
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /srv/u/acfs
    [[ "$status" -ne 0 ]]
}

@test "a root file under a directory others can write never runs as root: sticky /tmp, group-writable /opt" {
    use_table
    run root_may_exec_directly /tmp/acfs
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /opt/acfs
    [[ "$status" -ne 0 ]]
}

@test "something that isn't a regular file, or that stat can't read, never runs as root" {
    use_table
    run root_may_exec_directly /srv/dir
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /srv/missing
    [[ "$status" -ne 0 ]]
    run root_owned_path_chain relative/acfs
    [[ "$status" -ne 0 ]]
}

@test "on this host: a root-owned system binary passes, and a file this test made is refused" {
    [[ "$(stat -c '%u' /usr/bin/env)" == 0 ]] || skip "/usr/bin/env isn't root's here"
    root_may_exec_directly /usr/bin/env
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/acfs"
    chmod 0755 "$BATS_TEST_TMPDIR/acfs"
    if [[ "$(id -u)" -ne 0 ]]; then
        run root_may_exec_directly "$BATS_TEST_TMPDIR/acfs"
        [[ "$status" -ne 0 ]]
    fi
}

@test "main's direct-exec branch checks root_may_exec_directly as root before it runs acfs_bin" {
    local body branch
    body="$(sed -n '/^main() {$/,/^}$/p' "$WRAPPER")"
    branch="$(sed -n '/# If owner detection failed or we.re already the target user, run directly/,/^    fi$/p' <<<"$body")"
    [[ -n "$branch" ]]
    grep -qF 'if [[ "$EUID" -eq 0 ]] && ! root_may_exec_directly "$acfs_bin"; then' <<<"$branch"
    # The guard comes before every exec of acfs_bin in that branch.
    local guard first_exec
    guard="$(grep -nF 'root_may_exec_directly "$acfs_bin"' <<<"$branch" | head -1 | cut -d: -f1)"
    first_exec="$(grep -nF '"$acfs_bin" "$@"' <<<"$branch" | head -1 | cut -d: -f1)"
    [[ -n "$guard" && -n "$first_exec" ]]
    (( guard < first_exec ))
}

@test "read_user_for_home names a home's passwd user, then its stat owner, before what the home's own state.json claims" {
    local fn
    for fn in sanitize_abs_nonroot_path is_valid_username read_state_string \
        read_target_user_from_state_file read_target_home_from_state_file \
        resolve_home_for_user read_user_for_home; do
        eval "$(sed -n "/^$fn() {\$/,/^}\$/p" "$WRAPPER")"
        [[ "$(type -t "$fn")" == "function" ]]
    done
    local home="$BATS_TEST_TMPDIR/home/u" me
    me="$(id -un)"
    mkdir -p "$home/.acfs"
    # The user's own file, claiming root.
    printf '{"target_user": "root", "target_home": "%s"}\n' "$home" > "$home/.acfs/state.json"

    getent_passwd_entry() { printf 'u:x:1000:1000::%s:/bin/bash\n' "$home"; }
    run read_user_for_home "$home"
    [[ "$status" -eq 0 && "$output" == "u" ]]

    # No passwd entry has this home: the directory's owner decides.
    getent_passwd_entry() { printf 'other:x:1001:1001::/home/other:/bin/bash\n'; }
    run read_user_for_home "$home"
    [[ "$status" -eq 0 && "$output" == "$me" ]]

    # Only with neither passwd nor stat does the home's state.json speak,
    # and it can name root: the gap root_may_exec_directly closes.
    system_binary_path() { [[ "$1" != stat ]] && PATH=/usr/bin:/bin command -v "$1"; }
    run read_user_for_home "$home"
    [[ "$output" == "root" ]]
}
