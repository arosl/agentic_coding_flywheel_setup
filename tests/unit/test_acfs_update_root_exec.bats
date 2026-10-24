#!/usr/bin/env bats
#
# scripts/acfs-update's direct-exec branch (acfs-evgn), as acfs-global's
# (acfs-67mn): when no ACFS owner resolves, or the caller is the owner, the
# wrapper runs the update script itself. As root, that must never be a
# file another account controls, such as a user's
# ~/.acfs/scripts/lib/update.sh: root_may_exec_directly allows it only
# when root owns it and every directory above it, as named and as
# resolved, and nothing there is writable by group or other. Root runs
# /usr/local/bin/acfs-update as a root-owned copy, so this is the last
# check before update.sh.
#
# The ownership cases replace stat and readlink (path_owner_mode_type,
# resolve_path_fully) with a table of paths, since a test can't make root's
# files. One case uses the real ones on this host's own files.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WRAPPER="$PROJECT_ROOT/scripts/acfs-update"
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
/root/.acfs/scripts 0 755 directory
/root/.acfs/scripts/lib 0 755 directory
/root/.acfs/scripts/lib/update.sh 0 755 regular file
/root/update.sh 0 777 symbolic link
/home 0 755 directory
/home/u 1000 750 directory
/home/u/.acfs 1000 755 directory
/home/u/.acfs/scripts 1000 755 directory
/home/u/.acfs/scripts/lib 1000 755 directory
/home/u/.acfs/scripts/lib/update.sh 1000 755 regular file
/home/u/.acfs/scripts/lib/rootfile.sh 0 755 regular file
/srv 0 755 directory
/srv/u 0 755 directory
/srv/u/update.sh 1000 755 regular file
/srv/link 0 777 symbolic link
/srv/dir 0 755 directory
/tmp 0 1777 directory
/tmp/update.sh 0 755 regular file
/opt 0 775 directory
/opt/update.sh 0 755 regular file"
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
    root_may_exec_directly /root/.acfs/scripts/lib/update.sh
    LINKS="/root/update.sh /root/.acfs/scripts/lib/update.sh"
    root_may_exec_directly /root/update.sh
}

@test "a user's ~/.acfs/scripts/lib/update.sh never runs as root, nor a root file in a directory the user owns" {
    use_table
    run root_may_exec_directly /home/u/.acfs/scripts/lib/update.sh
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /home/u/.acfs/scripts/lib/rootfile.sh
    [[ "$status" -ne 0 ]]
}

@test "a root link to a user's file, or a user's file in root's directories, never runs as root" {
    use_table
    LINKS="/srv/link /home/u/.acfs/scripts/lib/update.sh"
    run root_may_exec_directly /srv/link
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /srv/u/update.sh
    [[ "$status" -ne 0 ]]
}

@test "a root file under a directory others can write never runs as root: sticky /tmp, group-writable /opt" {
    use_table
    run root_may_exec_directly /tmp/update.sh
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /opt/update.sh
    [[ "$status" -ne 0 ]]
}

@test "something that isn't a regular file, or that stat can't read, never runs as root" {
    use_table
    run root_may_exec_directly /srv/dir
    [[ "$status" -ne 0 ]]
    run root_may_exec_directly /srv/missing
    [[ "$status" -ne 0 ]]
    run root_owned_path_chain relative/update.sh
    [[ "$status" -ne 0 ]]
}

@test "on this host: a root-owned system binary passes, and a file this test made is refused" {
    [[ "$(stat -c '%u' /usr/bin/env)" == 0 ]] || skip "/usr/bin/env isn't root's here"
    root_may_exec_directly /usr/bin/env
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/update.sh"
    chmod 0755 "$BATS_TEST_TMPDIR/update.sh"
    if [[ "$(id -u)" -ne 0 ]]; then
        run root_may_exec_directly "$BATS_TEST_TMPDIR/update.sh"
        [[ "$status" -ne 0 ]]
    fi
}

@test "main's direct-exec branch checks root_may_exec_directly as root before it runs the update script" {
    local body branch
    body="$(sed -n '/^main() {$/,/^}$/p' "$WRAPPER")"
    branch="$(sed -n '/if \[\[ -z "\$target_user" || "\$current_user" == "\$target_user" \]\]; then/,/^  fi$/p' <<<"$body")"
    [[ -n "$branch" ]]
    grep -qF 'if [[ "$EUID" -eq 0 ]] && ! root_may_exec_directly "$update_script"; then' <<<"$branch"
    # The guard comes before every exec of the update script in that branch.
    local guard first_exec
    guard="$(grep -nF 'root_may_exec_directly "$update_script"' <<<"$branch" | head -1 | cut -d: -f1)"
    first_exec="$(grep -nF '"$update_script" "$@"' <<<"$branch" | head -1 | cut -d: -f1)"
    [[ -n "$guard" && -n "$first_exec" ]]
    (( guard < first_exec ))
}
