#!/usr/bin/env bash
# ============================================================
# ACFS nhm maintain timer - run `nhm maintain --once` every 15 s
#
# nhm's maintenance pass (nhm plan-v8 2.8) settles wake attempts, reads
# each bound agent's inbox, delivers the due wakes and reconciles pane
# names. ACFS runs it from a systemd --user timer (plan-v8 F.29, the
# operator: yes). Without the timer, nhm's board or `nhm maintain --loop`
# must run it. nhm holds its own singleton lock, so a pass that outlasts
# 15 s never runs twice, and under ACFS's Bash the pass does nothing.
#
# A pass runs only when it can do its work: the service's ExecCondition
# (`ready`) skips it quietly, never as a failure, unless nhm is installed,
# the default herdr server's socket is there, and nhm is enrolled for that
# server. So no state of the machine puts an error in the journal every
# 15 s.
#
# The units are ACFS's: install rewrites them when they differ, and remove
# deletes only files with ACFS's header. Change them with a drop-in
# (systemctl --user edit nhm-maintain.service), or mask the timer to opt
# out; install and remove leave a mask alone.
#
# Usage:
#   nhm_maintain_timer.sh install   write the units and enable the timer
#   nhm_maintain_timer.sh remove    disable the timer and delete the units
#   nhm_maintain_timer.sh status    say whether the timer runs (read-only)
#   nhm_maintain_timer.sh ready NHM SOCKET STATE_ROOT
#                                   the service's ExecCondition (read-only)
# Exit codes: 0 enabled (remove: done; ready: run the pass); 1 not
# installed or not enabled (install: failed; ready: skip); 2 the unit
# exists, the user manager is unreachable (status only); 3 no nhm with
# maintain; 4 no systemd user manager; 5 masked; 6 nhm is not enrolled for
# the default herdr server; 7 a unit of the user's own is there (never
# overwritten); 64 a usage error.
# NHM_TIMER_SYSTEMCTL_MACHINE=user@.host makes status ask that user's
# manager (doctor run as root).
# ============================================================

set -uo pipefail

NHM_MAINTAIN_TIMER_UNIT="nhm-maintain"
# The first line of every unit ACFS writes; remove deletes only these.
NHM_MAINTAIN_TIMER_HEADER="# Written by ACFS (scripts/lib/nhm_maintain_timer.sh); a drop-in changes it."

nhm_maintain_timer_usage() {
    cat <<'EOF'
Usage:
  nhm_maintain_timer.sh install   Write nhm-maintain.service and .timer to
                                  ~/.config/systemd/user and enable the timer
  nhm_maintain_timer.sh remove    Disable the timer and delete ACFS's units
  nhm_maintain_timer.sh status    Say whether the timer runs (read-only)
  nhm_maintain_timer.sh ready NHM SOCKET STATE_ROOT
                                  Exit 0 when a pass can run (ExecCondition)
EOF
}

nhm_maintain_timer_note() { printf 'nhm_maintain_timer: %s\n' "$*" >&2; }

# The nhm binary: NHM_MAINTAIN_NHM when the caller resolved it (acfs
# update passes the nhm its own lookup found, so an nhm outside
# ~/.local/bin is the same one for both, acfs-9hkh.84), else where ACFS
# installs it.
nhm_maintain_timer_nhm() {
    if [[ "${NHM_MAINTAIN_NHM:-}" == /* ]]; then
        printf '%s\n' "$NHM_MAINTAIN_NHM"
        return 0
    fi
    printf '%s/nhm\n' "${NHM_BIN_DIR:-$HOME/.local/bin}"
}

nhm_maintain_timer_unit_dir() { printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# clean_path makes a path absolute and clean (no trailing or doubled "/",
# no "." or ".."), without following links, as nhm's filepath.Clean does.
nhm_maintain_timer_clean_path() { realpath -ms -- "$1" 2>/dev/null || printf '%s\n' "$1"; }

# nhm's state root (internal/store StateRoot).
nhm_maintain_timer_state_root() { nhm_maintain_timer_clean_path "${XDG_STATE_HOME:-$HOME/.local/state}/nhm"; }

# The socket of the herdr server that nhm enrolled as session "default"
# under ROOT (`nhm admin instance enroll --session default`), or nothing.
# The unit uses this path, so an XDG_CONFIG_HOME that differs between the
# enrolment and now does not matter.
nhm_maintain_timer_socket() {
    local root="$1" toml="" line="" session="" socket=""
    for toml in "$root"/*/instance.toml; do
        [[ -f "$toml" ]] || continue
        session="" socket=""
        while IFS= read -r line; do
            case "$line" in
                'session = "'*'"') session="${line#session = \"}"; session="${session%\"}" ;;
                'socket_path = "'*'"') socket="${line#socket_path = \"}"; socket="${socket%\"}" ;;
            esac
        done <"$toml"
        if [[ "$session" == default && -n "$socket" ]]; then
            nhm_maintain_timer_clean_path "$socket"
            return 0
        fi
    done
    return 1
}

# The systemctl command for this user's manager, or the one that
# NHM_TIMER_SYSTEMCTL_MACHINE names.
nhm_maintain_timer_systemctl() {
    if [[ -n "${NHM_TIMER_SYSTEMCTL_MACHINE:-}" ]]; then
        timeout 10 systemctl --machine="$NHM_TIMER_SYSTEMCTL_MACHINE" --user "$@"
    else
        timeout 30 systemctl --user "$@"
    fi
}

# Whether the installed nhm has `maintain`: its usage names the verb (an
# older nhm says "unknown command").
nhm_maintain_timer_has_maintain() {
    local nhm="$1" usage=""
    [[ -x "$nhm" ]] || return 1
    usage="$(nhm_maintain_timer_run_nhm "$nhm" maintain --help 2>&1 </dev/null)"
    [[ "$usage" == *"Usage: nhm maintain"* ]]
}

# Whether nhm is enrolled for SOCKET: an instance.toml under STATE_ROOT
# names it (nhm's store.Lookup compares the same clean path).
nhm_maintain_timer_enrolled() {
    local socket="" root="$2" toml="" line="" have=""
    socket="$(nhm_maintain_timer_clean_path "$1")"
    for toml in "$root"/*/instance.toml; do
        [[ -f "$toml" ]] || continue
        while IFS= read -r line; do
            [[ "$line" == 'socket_path = "'*'"' ]] || continue
            have="${line#socket_path = \"}"
            if [[ "$(nhm_maintain_timer_clean_path "${have%\"}")" == "$socket" ]]; then
                return 0
            fi
        done <"$toml"
    done
    return 1
}

# Runs nhm as the target user when the doctor runs as root for another
# user (NHM_TIMER_SYSTEMCTL_MACHINE=<user>@.host): a target's binary never
# runs as root.
nhm_maintain_timer_run_nhm() {
    local machine="${NHM_TIMER_SYSTEMCTL_MACHINE:-}" user=""
    user="${machine%@*}"
    if [[ -n "$machine" && "$EUID" -eq 0 && -n "$user" && "$user" != root ]]; then
        command -v runuser >/dev/null 2>&1 || return 1
        timeout 10 runuser -u "$user" -- "$@"
    else
        timeout 10 "$@"
    fi
}

# Whether this user's systemd manager answers.
nhm_maintain_timer_systemd() {
    command -v systemctl >/dev/null 2>&1 && nhm_maintain_timer_systemctl show-environment >/dev/null 2>&1
}

nhm_maintain_timer_masked() {
    local state=""
    state="$(nhm_maintain_timer_systemctl is-enabled "$NHM_MAINTAIN_TIMER_UNIT.timer" 2>/dev/null)"
    [[ "$state" == masked* ]]
}

# A path a unit file can hold: absolute, without what systemd splits on
# or expands (space, %, $, quotes, backslash).
nhm_maintain_timer_unit_safe() {
    [[ "$1" == /* && ! "$1" =~ [[:space:]%\$\"\'\\] ]]
}

nhm_maintain_timer_service() {
    local nhm="$1" socket="$2" root="$3" helper="$4"
    cat <<EOF
$NHM_MAINTAIN_TIMER_HEADER
[Unit]
Description=nhm: the maintenance pass (due wakes, inboxes, pane names)
Documentation=https://github.com/arosl/nhm

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:%h/.acfs/bin:%h/.cargo/bin:%h/.bun/bin:/usr/local/bin:/usr/bin:/bin
# No nhm, no herdr server or no enrolment: the pass is skipped, not failed.
ExecCondition=/bin/bash $helper ready $nhm $socket $root
ExecStart=$nhm maintain --once --socket $socket
TimeoutStartSec=60
# The journal keeps nhm's warnings and errors, not a line per pass.
StandardOutput=null
SyslogLevel=warning
LogLevelMax=warning
EOF
}

nhm_maintain_timer_timer() {
    cat <<EOF
$NHM_MAINTAIN_TIMER_HEADER
[Unit]
Description=nhm: run nhm maintain --once every 15 s
Documentation=https://github.com/arosl/nhm

[Timer]
OnCalendar=*:*:0/15
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# write_if_changed <file> <content>: 0 written, 1 unchanged, 2 failed.
nhm_maintain_timer_write() {
    local file="$1" content="$2" tmp=""
    if [[ -f "$file" && ! -L "$file" ]] && [[ "$(cat -- "$file")" == "$content" ]]; then
        return 1
    fi
    tmp="$(mktemp "$file.XXXXXX")" || return 2
    if ! printf '%s\n' "$content" >"$tmp" || ! mv -f -- "$tmp" "$file"; then
        nhm_maintain_timer_note "cannot write $file"
        return 2
    fi
    return 0
}

# Whether FILE is a unit ACFS wrote: a regular file whose first line is
# ACFS's header. A mask (a link to /dev/null) and a user's own unit are not.
nhm_maintain_timer_ours() {
    local file="$1" first=""
    [[ -f "$file" && ! -L "$file" ]] || return 1
    IFS= read -r first <"$file" || true
    [[ "$first" == "$NHM_MAINTAIN_TIMER_HEADER" ]]
}

nhm_maintain_timer_install() {
    local nhm="" socket="" root="" helper="" dir="" rc=0 changed=false
    nhm="$(nhm_maintain_timer_nhm)"
    root="$(nhm_maintain_timer_state_root)"
    helper="$(readlink -f -- "${BASH_SOURCE[0]}")"
    if ! nhm_maintain_timer_has_maintain "$nhm"; then
        # An older nhm, or none: units from a newer one would fail.
        nhm_maintain_timer_remove >/dev/null 2>&1
        nhm_maintain_timer_note "$nhm has no 'maintain'; the next nhm update installs the timer"
        return 3
    fi
    if ! socket="$(nhm_maintain_timer_socket "$root")"; then
        nhm_maintain_timer_note "nhm has no enrolled default herdr server under $root; run: nhm admin instance enroll --session default (the next install or update enables the timer)"
        return 6
    fi
    dir="$(nhm_maintain_timer_unit_dir)"
    # A unit of the user's own (no ACFS header) is never overwritten, as
    # remove never deletes it.
    local f
    for f in "$dir/$NHM_MAINTAIN_TIMER_UNIT.service" "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer"; do
        if [[ -e "$f" && ! -L "$f" ]] && ! nhm_maintain_timer_ours "$f"; then
            nhm_maintain_timer_note "$f is not ACFS's: left as it is, and the timer is not installed"
            return 7
        fi
    done
    local p
    for p in "$nhm" "$socket" "$root" "$helper"; do
        if ! nhm_maintain_timer_unit_safe "$p"; then
            nhm_maintain_timer_note "the path $p cannot go into a unit file; run nhm maintain --loop instead"
            return 1
        fi
    done
    if ! nhm_maintain_timer_systemd; then
        nhm_maintain_timer_note "no systemd user manager; run nhm maintain --loop, or open nhm's board"
        return 4
    fi
    if nhm_maintain_timer_masked; then
        nhm_maintain_timer_note "$NHM_MAINTAIN_TIMER_UNIT.timer is masked: left as it is (systemctl --user unmask $NHM_MAINTAIN_TIMER_UNIT.timer to let ACFS run it)"
        return 5
    fi
    mkdir -p -- "$dir" || { nhm_maintain_timer_note "cannot create $dir"; return 1; }
    nhm_maintain_timer_write "$dir/$NHM_MAINTAIN_TIMER_UNIT.service" "$(nhm_maintain_timer_service "$nhm" "$socket" "$root" "$helper")"
    rc=$?
    (( rc == 2 )) && return 1
    (( rc == 0 )) && changed=true
    nhm_maintain_timer_write "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer" "$(nhm_maintain_timer_timer)"
    rc=$?
    (( rc == 2 )) && return 1
    (( rc == 0 )) && changed=true
    if [[ "$changed" == true ]]; then
        nhm_maintain_timer_systemctl daemon-reload || { nhm_maintain_timer_note "systemctl --user daemon-reload failed"; return 1; }
    fi
    if ! nhm_maintain_timer_systemctl enable --now "$NHM_MAINTAIN_TIMER_UNIT.timer" >/dev/null 2>&1; then
        nhm_maintain_timer_note "systemctl --user enable --now $NHM_MAINTAIN_TIMER_UNIT.timer failed"
        return 1
    fi
    return 0
}

# remove disables the timer and deletes ACFS's units, for a machine where
# nhm is gone or stack.nhm is not selected. A mask and a user's own unit
# stay. Idempotent: no units, nothing to do.
nhm_maintain_timer_remove() {
    local dir="" f="" removed=false systemd=false
    dir="$(nhm_maintain_timer_unit_dir)"
    nhm_maintain_timer_systemd && systemd=true
    if [[ "$systemd" == true ]] && nhm_maintain_timer_ours "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer"; then
        nhm_maintain_timer_systemctl disable --now "$NHM_MAINTAIN_TIMER_UNIT.timer" >/dev/null 2>&1 || true
    fi
    for f in "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer" "$dir/$NHM_MAINTAIN_TIMER_UNIT.service"; do
        if nhm_maintain_timer_ours "$f"; then
            rm -f -- "$f" && removed=true
        fi
    done
    # Without a user manager, `disable` did not run: the enable link to a
    # timer that is gone now would dangle. Only that link goes.
    local wants="$dir/timers.target.wants/$NHM_MAINTAIN_TIMER_UNIT.timer"
    if [[ -L "$wants" && ! -e "$wants" ]]; then
        rm -f -- "$wants" && removed=true
    fi
    if [[ "$removed" == true && "$systemd" == true ]]; then
        nhm_maintain_timer_systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    return 0
}

# ready is the service's ExecCondition: 0 runs the pass; 1 skips it, which
# systemd does not count as a failure.
nhm_maintain_timer_ready() {
    local nhm="${1:-}" socket="${2:-}" root="${3:-}"
    [[ -n "$nhm" && -n "$socket" && -n "$root" ]] || return 1
    [[ -x "$nhm" && -S "$socket" ]] || return 1
    nhm_maintain_timer_enrolled "$socket" "$root"
}

nhm_maintain_timer_status() {
    local nhm="" dir="" state=""
    nhm="$(nhm_maintain_timer_nhm)"
    if ! nhm_maintain_timer_has_maintain "$nhm"; then
        echo "no-maintain"
        return 3
    fi
    dir="$(nhm_maintain_timer_unit_dir)"
    if [[ -e "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer" && ! -L "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer" ]] \
            && ! nhm_maintain_timer_ours "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer"; then
        echo "user-unit"
        return 7
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "no-systemd"
        return 4
    fi
    if ! nhm_maintain_timer_systemd; then
        if [[ -f "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer" ]]; then
            echo "unit-exists"
            return 2
        fi
        echo "no-systemd"
        return 4
    fi
    state="$(nhm_maintain_timer_systemctl is-enabled "$NHM_MAINTAIN_TIMER_UNIT.timer" 2>/dev/null)"
    case "$state" in
        enabled*)
            if ! nhm_maintain_timer_systemctl is-active --quiet "$NHM_MAINTAIN_TIMER_UNIT.timer" 2>/dev/null; then
                echo "inactive"
                return 1
            fi
            if ! nhm_maintain_timer_socket "$(nhm_maintain_timer_state_root)" >/dev/null; then
                echo "not-enrolled"
                return 6
            fi
            echo "enabled"
            return 0 ;;
        masked*) echo "masked"; return 5 ;;
        *) echo "missing"; return 1 ;;
    esac
}

nhm_maintain_timer_main() {
    local subcommand="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$subcommand" in
        install|remove|status)
            [[ $# -eq 0 ]] || { nhm_maintain_timer_usage >&2; return 64; } ;;
        ready)
            [[ $# -eq 3 ]] || { nhm_maintain_timer_usage >&2; return 64; } ;;
    esac
    case "$subcommand" in
        install) nhm_maintain_timer_install ;;
        remove) nhm_maintain_timer_remove ;;
        status) nhm_maintain_timer_status ;;
        ready) nhm_maintain_timer_ready "$@" ;;
        -h|--help|help) nhm_maintain_timer_usage ;;
        *) nhm_maintain_timer_usage >&2; return 64 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nhm_maintain_timer_main "$@"
fi
