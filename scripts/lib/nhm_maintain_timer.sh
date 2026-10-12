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
# The units are ACFS's: install rewrites them when they differ. Change
# them with a drop-in (systemctl --user edit nhm-maintain.service), or
# mask the timer to opt out; install respects a mask.
#
# Install needs an nhm with `maintain` (newer than 0.1.1); with an older
# one it changes nothing, and the next nhm update installs the timer.
#
# Usage:
#   nhm_maintain_timer.sh install   write the units and enable the timer
#   nhm_maintain_timer.sh status    say whether the timer runs (read-only)
# Exit codes (both): 0 enabled; 1 not installed or not enabled (install:
# failed); 2 the unit exists, the user manager is unreachable (status
# only); 3 no nhm with maintain; 4 no systemd user manager; 5 masked;
# 64 a usage error.
# ============================================================

set -uo pipefail

NHM_MAINTAIN_TIMER_UNIT="nhm-maintain"

nhm_maintain_timer_usage() {
    cat <<'EOF'
Usage:
  nhm_maintain_timer.sh install   Write nhm-maintain.service and .timer to
                                  ~/.config/systemd/user and enable the timer
  nhm_maintain_timer.sh status    Say whether the timer runs (read-only)
EOF
}

nhm_maintain_timer_note() { printf 'nhm_maintain_timer: %s\n' "$*" >&2; }

nhm_maintain_timer_nhm() { printf '%s/nhm\n' "${NHM_BIN_DIR:-$HOME/.local/bin}"; }

nhm_maintain_timer_unit_dir() { printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# Whether the installed nhm has `maintain`: its usage names the verb (an
# older nhm says "unknown command").
nhm_maintain_timer_has_maintain() {
    local nhm="$1" usage=""
    [[ -x "$nhm" ]] || return 1
    usage="$(timeout 10 "$nhm" maintain --help 2>&1 </dev/null)"
    [[ "$usage" == *"Usage: nhm maintain"* ]]
}

# Whether this user's systemd manager answers.
nhm_maintain_timer_systemd() {
    command -v systemctl >/dev/null 2>&1 && timeout 10 systemctl --user show-environment >/dev/null 2>&1
}

nhm_maintain_timer_service() {
    local nhm="$1"
    cat <<EOF
# Written by ACFS (scripts/lib/nhm_maintain_timer.sh); a drop-in changes it.
[Unit]
Description=nhm: the maintenance pass (due wakes, inboxes, pane names)
Documentation=https://github.com/arosl/nhm

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:%h/.acfs/bin:%h/.cargo/bin:%h/.bun/bin:/usr/local/bin:/usr/bin:/bin
# No herdr server: nothing to do, and no failed unit every 15 s.
ExecStart=/bin/sh -c 'test -S "\$\$1" || exit 0; exec "\$\$0" maintain --once --socket "\$\$1"' $nhm %E/herdr/herdr.sock
TimeoutStartSec=60
# The journal keeps nhm's warnings and errors, not a line per pass.
StandardOutput=null
SyslogLevel=warning
LogLevelMax=warning
EOF
}

nhm_maintain_timer_timer() {
    cat <<'EOF'
# Written by ACFS (scripts/lib/nhm_maintain_timer.sh); a drop-in changes it.
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
    if [[ -f "$file" ]] && [[ "$(cat -- "$file")" == "$content" ]]; then
        return 1
    fi
    tmp="$(mktemp "$file.XXXXXX")" || return 2
    if ! printf '%s\n' "$content" >"$tmp" || ! mv -f -- "$tmp" "$file"; then
        nhm_maintain_timer_note "cannot write $file"
        return 2
    fi
    return 0
}

nhm_maintain_timer_install() {
    local nhm="" dir="" rc=0 changed=false state=""
    nhm="$(nhm_maintain_timer_nhm)"
    if ! nhm_maintain_timer_has_maintain "$nhm"; then
        nhm_maintain_timer_note "$nhm has no 'maintain'; the next nhm update installs the timer"
        return 3
    fi
    # systemd splits ExecStart on spaces and expands % and $.
    if [[ "$nhm" =~ [[:space:]%\$\"\'\\] ]]; then
        nhm_maintain_timer_note "the path $nhm cannot go into a unit file; run nhm maintain --loop instead"
        return 1
    fi
    if ! nhm_maintain_timer_systemd; then
        nhm_maintain_timer_note "no systemd user manager; run nhm maintain --loop, or open nhm's board"
        return 4
    fi
    state="$(timeout 10 systemctl --user is-enabled "$NHM_MAINTAIN_TIMER_UNIT.timer" 2>/dev/null)"
    if [[ "$state" == masked* ]]; then
        nhm_maintain_timer_note "$NHM_MAINTAIN_TIMER_UNIT.timer is masked: left as it is (systemctl --user unmask $NHM_MAINTAIN_TIMER_UNIT.timer to let ACFS run it)"
        return 5
    fi
    dir="$(nhm_maintain_timer_unit_dir)"
    mkdir -p -- "$dir" || { nhm_maintain_timer_note "cannot create $dir"; return 1; }
    nhm_maintain_timer_write "$dir/$NHM_MAINTAIN_TIMER_UNIT.service" "$(nhm_maintain_timer_service "$nhm")"
    rc=$?
    (( rc == 2 )) && return 1
    (( rc == 0 )) && changed=true
    nhm_maintain_timer_write "$dir/$NHM_MAINTAIN_TIMER_UNIT.timer" "$(nhm_maintain_timer_timer)"
    rc=$?
    (( rc == 2 )) && return 1
    (( rc == 0 )) && changed=true
    if [[ "$changed" == true ]]; then
        timeout 30 systemctl --user daemon-reload || { nhm_maintain_timer_note "systemctl --user daemon-reload failed"; return 1; }
    fi
    if ! timeout 30 systemctl --user enable --now "$NHM_MAINTAIN_TIMER_UNIT.timer" >/dev/null 2>&1; then
        nhm_maintain_timer_note "systemctl --user enable --now $NHM_MAINTAIN_TIMER_UNIT.timer failed"
        return 1
    fi
    return 0
}

nhm_maintain_timer_status() {
    local nhm="" dir="" state=""
    nhm="$(nhm_maintain_timer_nhm)"
    if ! nhm_maintain_timer_has_maintain "$nhm"; then
        echo "no-maintain"
        return 3
    fi
    dir="$(nhm_maintain_timer_unit_dir)"
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
    state="$(timeout 10 systemctl --user is-enabled "$NHM_MAINTAIN_TIMER_UNIT.timer" 2>/dev/null)"
    case "$state" in
        enabled*)
            if timeout 10 systemctl --user is-active --quiet "$NHM_MAINTAIN_TIMER_UNIT.timer" 2>/dev/null; then
                echo "enabled"
                return 0
            fi
            echo "inactive"
            return 1 ;;
        masked*) echo "masked"; return 5 ;;
        *) echo "missing"; return 1 ;;
    esac
}

nhm_maintain_timer_main() {
    local subcommand="${1:-}"
    [[ $# -eq 0 ]] || shift
    [[ $# -eq 0 ]] || { nhm_maintain_timer_usage >&2; return 64; }
    case "$subcommand" in
        install) nhm_maintain_timer_install ;;
        status) nhm_maintain_timer_status ;;
        -h|--help|help) nhm_maintain_timer_usage ;;
        *) nhm_maintain_timer_usage >&2; return 64 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nhm_maintain_timer_main "$@"
fi
