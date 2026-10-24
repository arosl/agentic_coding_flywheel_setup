#!/usr/bin/env bats
#
# acfs-37bx: where root hands a run to the account's own code (acfs-global,
# acfs-update, support.sh, doctor.sh and flywheel-update-agents-md drop
# with runuser -u), the account's code must not get root's terminal: a
# process it leaves behind keeps the terminal open and can read what the
# admin types next, or push input where TIOCSTI is allowed. So each drop
# passes runuser --pty, but only when fds 0, 1 and 2 are all terminals:
# runuser's pty would merge stderr into stdout and turn \n into \r\n in a
# pipe or a captured --dry-run.
#
# A test can't be root, so each case takes the drop function from its
# script, with its EUID test rewritten and its helpers stubbed, and a
# runuser stub that records its arguments. It runs three times: under a
# pty (python3's pty.spawn gives it one on all three fds), on pipes, and
# under the pty with stdout sent to a file.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    ARGV="$BATS_TEST_TMPDIR/argv"
    FAKE_RUNUSER="$BATS_TEST_TMPDIR/bin/runuser"
    ACCT_HOME="$BATS_TEST_TMPDIR/home/acct"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$ACCT_HOME/.acfs"
    cat >"$FAKE_RUNUSER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGV"
STUB
    chmod 0755 "$FAKE_RUNUSER"
    export ARGV FAKE_RUNUSER ACCT_HOME
    command -v python3 >/dev/null 2>&1 || skip "python3 is needed for a pty"
}

# fn_body FILE NAME [INDENT]: the function NAME as FILE defines it.
fn_body() {
    local body
    body="$(sed -n "/^${3:-}$2() {\$/,/^${3:-}}\$/p" "$PROJECT_ROOT/$1")"
    [[ -n "$body" ]] || { echo "$2 not found in $1" >&2; return 1; }
    printf '%s\n' "${body//\"\$EUID\"/\"\$FAKE_EUID\"}"
}

# write_driver STUBS BODY CALL: a script that defines STUBS and BODY, then
# runs CALL; with "partial" as its argument, its stdout is a file first.
write_driver() {
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\nFAKE_EUID=0\n'
        printf '%s\n' "$1" "$2"
        printf '[[ "${1:-}" != partial ]] || exec >"%s/partial.out"\n' "$BATS_TEST_TMPDIR"
        printf '%s\n' "$3"
    } >"$BATS_TEST_TMPDIR/driver.sh"
}

# runner_options MODE: the runuser options before "--" for one run of the
# driver: pty (all three fds are a terminal), pipes, or partial (a terminal
# on stdin and stderr, a file on stdout).
runner_options() {
    rm -f "$ARGV"
    case "$1" in
        pipes) bash "$BATS_TEST_TMPDIR/driver.sh" </dev/null >"$BATS_TEST_TMPDIR/out" 2>&1 || true ;;
        pty | partial)
            python3 -I -c 'import os, pty, sys
sys.exit(os.waitstatus_to_exitcode(pty.spawn(["bash"] + sys.argv[1:])))' \
                "$BATS_TEST_TMPDIR/driver.sh" "$1" </dev/null >"$BATS_TEST_TMPDIR/out" 2>&1 || true
            ;;
    esac
    [[ -s "$ARGV" ]] || { echo "runuser didn't run ($1): $(cat "$BATS_TEST_TMPDIR/out")" >&2; return 1; }
    sed '/^--$/q' "$ARGV" | sed '$d' | tr '\n' ' '
}

assert_pty_only_on_a_terminal() { # assert_pty_only_on_a_terminal USER
    local got
    got="$(runner_options pty)"
    [[ "$got" == "-u $1 --pty " ]] || { echo "pty: '$got'" >&2; return 1; }
    got="$(runner_options pipes)"
    [[ "$got" == "-u $1 " ]] || { echo "pipes: '$got'" >&2; return 1; }
    got="$(runner_options partial)"
    [[ "$got" == "-u $1 " ]] || { echo "partial: '$got'" >&2; return 1; }
}

# The stubs acfs-global's and acfs-update's exec_as_target_user call.
WRAPPER_STUBS='
sanitize_abs_nonroot_path() { [[ "${1:-}" == /* ]] && printf "%s\n" "$1"; }
validate_target_user_or_die() { :; }
state_file_matches_target_home() { return 0; }
system_binary_path() { case "$1" in runuser) printf "%s\n" "$FAKE_RUNUSER" ;; *) command -v "$1" ;; esac; }
TARGET_HOME="$ACCT_HOME"'

@test "acfs-global's drop to the owner passes --pty only when fds 0, 1 and 2 are terminals" {
    write_driver "$WRAPPER_STUBS" "$(fn_body scripts/acfs-global exec_as_target_user '    ')" \
        'exec_as_target_user acct /bin/true'
    assert_pty_only_on_a_terminal acct
}

@test "acfs-update's drop to the owner passes --pty only when fds 0, 1 and 2 are terminals" {
    write_driver "$WRAPPER_STUBS" "$(fn_body scripts/acfs-update exec_as_target_user)" \
        'exec_as_target_user acct /bin/true'
    assert_pty_only_on_a_terminal acct
}

@test "support.sh's run as the owner passes --pty only when fds 0, 1 and 2 are terminals" {
    write_driver '
support_running_as_root() { return 0; }
support_path_owner_account() { printf "acct\n"; }
support_getent_passwd_entry() { printf "acct:x:4242:4242::%s:/bin/sh\n" "$ACCT_HOME"; }
support_passwd_home_from_entry() { printf "%s\n" "$ACCT_HOME"; }
support_system_binary_path() { case "$1" in runuser) printf "%s\n" "$FAKE_RUNUSER" ;; sudo) return 1 ;; *) command -v "$1" ;; esac; }
log_error() { printf "ERR %s\n" "$*" >&2; }
log_step() { :; }
SUPPORT_TARGET_HOME="$ACCT_HOME"
_SUPPORT_ACFS_HOME="$ACCT_HOME/.acfs"
_SUPPORT_SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"' \
        "$(fn_body scripts/lib/support.sh support_reexec_as_owner)" \
        'support_reexec_as_owner --verbose'
    assert_pty_only_on_a_terminal acct
}

@test "doctor.sh's drop before the user's helpers passes --pty only when fds 0, 1 and 2 are terminals" {
    local body
    body="$(fn_body scripts/lib/doctor.sh _acfs_doctor_reexec_as_target_if_root)"
    # The drop runs only when doctor.sh is the script bash runs, not here.
    body="${body//'[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0'/:}"
    write_driver '
_acfs_doctor_system_binary_path() { case "$1" in runuser) printf "%s\n" "$FAKE_RUNUSER" ;; *) command -v "$1" ;; esac; }
_acfs_doctor_validate_bin_dir_for_home() { return 1; }
TARGET_USER=acct
TARGET_HOME="$ACCT_HOME"' "$body" '_acfs_doctor_reexec_as_target_if_root'
    assert_pty_only_on_a_terminal acct
}

@test "flywheel-update-agents-md's run as the user passes --pty only when fds 0, 1 and 2 are terminals" {
    write_driver "PATH=\"${FAKE_RUNUSER%/*}:\$PATH\"
TARGET_USER=acct
TARGET_HOME=\"\$ACCT_HOME\"" "$(fn_body scripts/generate-root-agents-md.sh run_as_user)" 'run_as_user --dry-run'
    assert_pty_only_on_a_terminal acct
}
