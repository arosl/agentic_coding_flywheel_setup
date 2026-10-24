#!/usr/bin/env bats
#
# cli.modern's gh on the legacy Ubuntu path (acfs-iabw). cli.modern's verify
# runs `gh --version` as root with PATH /usr/sbin:/usr/bin:/sbin:/bin
# (_acfs_privileged_path_export_source), and upstream's #474 runs it after
# phase 5. install_cli_tools took any gh that binary_path found as installed,
# also one in /usr/local/bin, /snap/bin or the target user's ~/.local/bin, and
# installed nothing; phase 5 then failed with "Required module is not ready:
# cli.modern". It also ran that gh as root for its version line. Now only a gh
# in the system directories counts, and otherwise the apt gh is installed,
# as the manifest's install does.
#
# The tests run the real install_github_cli and the real gh step of
# install_cli_tools, from install.sh. The host's directories sit under a temp
# root, and apt-get is a stub that logs its arguments.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FAKE_ROOT="$BATS_TEST_TMPDIR/root"
    APT_LOG="$BATS_TEST_TMPDIR/apt-get.log"
    GH_RAN="$BATS_TEST_TMPDIR/gh-ran"
    mkdir -p "$FAKE_ROOT/stubs"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$APT_LOG" >"$FAKE_ROOT/stubs/apt-get"
    chmod +x "$FAKE_ROOT/stubs/apt-get"
    PATH="$FAKE_ROOT/stubs:$PATH"
    SUDO=""
    ACFS_DISTRO_FAMILY="ubuntu"

    eval "$(sed -n '/^install_github_cli() {$/,/^}$/p' "$PROJECT_ROOT/install.sh")"
    [[ "$(type -t install_github_cli)" == "function" ]]
    local gh_step=""
    gh_step="$(sed -n '/^    local gh_bin=""$/,/^    # Git LFS setup/p' "$PROJECT_ROOT/install.sh")"
    [[ -n "$gh_step" ]]
    eval "install_cli_tools_gh_step() {
$gh_step
}"

    log_detail() { printf 'detail: %s\n' "$*"; }
    log_success() { printf 'success: %s\n' "$*"; }
    log_fatal() { printf 'fatal: %s\n' "$*"; return 1; }
    try_step() { shift; "$@"; }
}

# install.sh's lookups, under the temp root: acfs_early_system_binary_path
# searches root's verify PATH, binary_path also the target user's bin
# directory, /usr/local/bin and /snap/bin.
acfs_early_system_binary_path() {
    local dir=""
    for dir in usr/bin bin usr/sbin sbin; do
        [[ -x "$FAKE_ROOT/$dir/$1" ]] || continue
        printf '%s\n' "$FAKE_ROOT/$dir/$1"
        return 0
    done
    return 1
}

binary_path() {
    local dir=""
    for dir in home/.local/bin usr/local/bin usr/local/sbin usr/bin bin snap/bin; do
        [[ -x "$FAKE_ROOT/$dir/$1" ]] || continue
        printf '%s\n' "$FAKE_ROOT/$dir/$1"
        return 0
    done
    return 1
}

binary_installed() {
    [[ -n "$(binary_path "$1" 2>/dev/null || true)" ]]
}

# A gh in <dir> under the temp root that notes when it runs.
place_gh() {
    mkdir -p "$FAKE_ROOT/$1"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >>"%s"\necho "gh version 2.99.0"\n' "$1" "$GH_RAN" >"$FAKE_ROOT/$1/gh"
    chmod +x "$FAKE_ROOT/$1/gh"
}

# install_github_cli with a gh only in <dir> under the temp root.
installs_apt_gh_beside() {
    place_gh "$1"
    run install_github_cli
    [[ "$status" -eq 0 ]]
    grep -q -- 'install -y gh$' "$APT_LOG"
}

@test "install_github_cli installs the apt gh when gh is only in /usr/local/bin" {
    installs_apt_gh_beside usr/local/bin
}

@test "install_github_cli installs the apt gh when gh is only in /snap/bin" {
    installs_apt_gh_beside snap/bin
}

@test "install_github_cli installs the apt gh when gh is only in ~/.local/bin" {
    installs_apt_gh_beside home/.local/bin
}

@test "install_github_cli installs nothing when gh is in /usr/bin" {
    place_gh usr/bin
    run install_github_cli
    [[ "$status" -eq 0 ]]
    [[ ! -e "$APT_LOG" ]]
}

@test "install_cli_tools installs the apt gh, and runs no gh as root, when gh is only in ~/.local/bin" {
    place_gh home/.local/bin
    run install_cli_tools_gh_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"success: gh installed"* ]]
    [[ "$output" != *"gh already installed"* ]]
    grep -q -- 'install -y gh$' "$APT_LOG"
    [[ ! -e "$GH_RAN" ]]
}

@test "install_cli_tools installs the apt gh when gh is only in /snap/bin" {
    place_gh snap/bin
    run install_cli_tools_gh_step
    [[ "$status" -eq 0 ]]
    grep -q -- 'install -y gh$' "$APT_LOG"
}

@test "install_cli_tools keeps the gh in /usr/bin and installs nothing" {
    place_gh usr/bin
    run install_cli_tools_gh_step
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"detail: gh already installed (gh version 2.99.0)"* ]]
    [[ ! -e "$APT_LOG" ]]
}
