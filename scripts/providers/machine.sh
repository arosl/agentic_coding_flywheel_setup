#!/usr/bin/env bash
# ============================================================
# ACFS machine: one entry command for the two deploy targets (acfs-ioo3.4)
#
#   machine.sh up [--target incus|vps] <name> [launcher options]
#   machine.sh verify [--target incus|vps] <name> [verify options]
#
# incus, the default, is the swarm machine: an Incus system container that
# scripts/providers/incus.sh creates (or resumes) from this checkout's
# committed HEAD. The name and every option after it go to that launcher
# unchanged, and its attach block is this command's stdout.
#
# vps is any VM that runs install.sh: a cloud VPS, an Incus VM or a NixOS
# machine. Nothing here creates one, so it prints how one is set up and
# exits 2, having created nothing.
#
# verify proves a machine's logins work, after it was made or updated: it
# streams machine_verify.sh into the machine as its user (incus exec, or
# ssh for a VPS), adds an ssh check from here, and prints one row per
# check. The ed25519 host key, the tailnet name and herdr's workspaces must
# match the machine's last run, kept under ~/.local/state/acfs/machine. It
# makes small paid requests, so it runs only when asked; it is not doctor.
#
# It runs where the launcher runs: on the Incus host, from a checkout. On
# macOS the container target needs Colima, which it doesn't start yet.
# Progress goes to stderr; stdout carries only the attach block, or
# verify's rows.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

# Overridable so the tests can run a stub launcher and pretend to be a Mac.
INCUS_SH="${ACFS_MACHINE_INCUS_SH:-$SCRIPT_DIR/incus.sh}"
UNAME="${ACFS_MACHINE_UNAME:-$(uname -s)}"
VERIFY_SH="$SCRIPT_DIR/machine_verify.sh"
STATE_DIR="${ACFS_MACHINE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acfs/machine}"
# The user the launcher creates in a container.
MACHINE_USER="ubuntu"

usage() {
    cat <<'EOF'
Usage: scripts/providers/machine.sh up [--target incus|vps] <name> [launcher options]

Brings up the ACFS machine <name>.

  --target incus  (default) An unprivileged Incus system container, made or
                  resumed by scripts/providers/incus.sh. <name> may carry a
                  remote (<remote>:<name>), and every option after it goes
                  to the launcher: see 'scripts/providers/incus.sh --help'.
                  Its attach block is printed on stdout.
  --target vps    Any VM that runs install.sh. Nothing is created: the
                  command prints how to set one up, and exits 2.

The machine name comes before the launcher's options. Runs on the Incus
host, from a checkout. On macOS, the container target needs Colima, which
this command doesn't start yet.

Usage: scripts/providers/machine.sh verify [--target incus|vps] <name> [options]

Checks that the machine's logins work: each configured agent, gh, Agent
Mail, Tailscale, the SSH host key, herdr, br, cm, the state lease, and that
no login file sits outside the state volume. Each configured tool gets ONE
small authenticated request, so this may cost a little. A row reads ok,
not-configured, invalid-login, network, quota or failed. It exits 0 when
every row is ok or not-configured, and 1 otherwise.

  --target incus  (default) Runs the checks with incus exec, as ubuntu.
  --target vps    Runs them over ssh <name>.
  --mail-agent <name> --mail-project <key>
                  Peek at that agent's inbox (fetch_inbox, nothing marked
                  read) instead of Agent Mail's health_check.
  --rebaseline    Accept a changed host key, tailnet name or herdr
                  workspace list as the new expected value.
EOF
}

die() {
    log_error "machine: $*"
    exit 1
}

# What a VPS needs: install.sh, run on the VM itself. Exits 2: nothing created.
up_vps() {
    local name="$1"
    {
        printf 'A VPS is set up by running the ACFS installer (install.sh) on it; nothing here creates one.\n'
        printf 'On %s, as root or as a user with sudo, run the one-liner in README.md, "Quick Install".\n' "$name"
        printf 'Provider guides: scripts/providers/hetzner.md (with hetzner-cloud-init.yml),\n'
        printf 'scripts/providers/contabo.md and scripts/providers/ovh.md.\n'
    } >&2
    exit 2
}

up() {
    local target="incus"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ $# -ge 2 ]] || die "--target needs incus or vps"
                target="$2"
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            -*) die "the machine name comes before the launcher's options (got $1)" ;;
            *) break ;;
        esac
    done
    [[ $# -gt 0 ]] || die "up needs a machine name"
    local name="$1"
    shift

    case "$target" in
        incus)
            if [[ "$UNAME" == Darwin ]]; then
                die "on macOS the container target runs inside Colima, which this command doesn't start yet; run it on a Linux Incus host"
            fi
            [[ -f "$INCUS_SH" ]] || die "the launcher is missing: $INCUS_SH (run this from an ACFS checkout)"
            exec bash "$INCUS_SH" "$name" "$@"
            ;;
        vps)
            [[ $# -eq 0 ]] || die "the vps target takes no launcher options (got $1)"
            up_vps "$name"
            ;;
        *) die "unknown target: $target (incus or vps)" ;;
    esac
}

# --- verify ----------------------------------------------------------------

# Runs machine_verify.sh in the machine as its user, with its options as a
# `set --` line ahead of it on stdin: no argument passes through a remote
# shell's parser. Its rows are this function's stdout.
verify_remote() {
    local target="$1" name="$2"
    shift 2
    local set_line="set --"
    local arg
    for arg in "$@"; do set_line+=" $(printf '%q' "$arg")"; done
    case "$target" in
        incus)
            { printf '%s\n' "$set_line"; cat "$VERIFY_SH"; } \
                | incus exec "$name" -- runuser -l "$MACHINE_USER" -c 'bash -s'
            ;;
        vps)
            { printf '%s\n' "$set_line"; cat "$VERIFY_SH"; } \
                | ssh -o BatchMode=yes -o ConnectTimeout=15 "$name" 'bash -l -s'
            ;;
    esac
}

# The ssh check, from here: the host key known here, and a login with no
# prompt. HostKeyAlias and the user come from the attach block's entry.
verify_ssh() {
    local alias="$1" rc=0 err
    err="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 "$alias" true 2>&1 </dev/null)" || rc=$?
    err="$(printf '%s' "$err" | tr '\n|' '  ' | cut -c1-200)"
    if ((rc == 0)) && [[ -z "$err" ]]; then
        printf 'ssh|ok|ssh %s true, with no warning|\n' "$alias"
    elif ((rc == 0)); then
        printf 'ssh|failed|ssh %s warned: %s|\n' "$alias" "$err"
    elif [[ "$err" == *"Host key verification failed"* || "$err" == *"IDENTIFICATION HAS CHANGED"* || "$err" == *"No ED25519 host key is known"* ]]; then
        printf 'ssh|failed|the host key for %s doesn'"'"'t match the one known here: %s|\n' "$alias" "$err"
    elif [[ "$err" == *"Permission denied"* ]]; then
        printf 'ssh|invalid-login|%s refused the key: %s|\n' "$alias" "$err"
    else
        printf 'ssh|network|ssh %s exited %s: %s|\n' "$alias" "$rc" "$err"
    fi
}

# Rows whose value must match the machine's last run. A first value is
# recorded; a changed one fails until --rebaseline accepts it.
verify_baseline() {
    local file="$1" rebaseline="$2" check result detail value old
    local -a keep=()
    if [[ -f "$file" ]]; then
        while IFS= read -r old; do keep+=("$old"); done <"$file"
    fi
    while IFS='|' read -r check result detail value; do
        if [[ -n "$value" && "$result" == ok ]]; then
            old=""
            local line
            for line in "${keep[@]+"${keep[@]}"}"; do
                [[ "$line" == "$check="* ]] && old="${line#*=}"
            done
            if [[ -z "$old" || "$rebaseline" == true ]]; then
                [[ -z "$old" ]] && detail+=" (recorded)"
                [[ -n "$old" && "$old" != "$value" ]] && detail+=" (accepted, was $old)"
                local -a next=()
                for line in "${keep[@]+"${keep[@]}"}"; do
                    [[ "$line" == "$check="* ]] || next+=("$line")
                done
                keep=("${next[@]+"${next[@]}"}" "$check=$value")
            elif [[ "$old" != "$value" ]]; then
                result=failed
                detail="changed since the last run: was $old, now $value (--rebaseline accepts it)"
            fi
        fi
        printf '%s|%s|%s\n' "$check" "$result" "$detail"
    done
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "${keep[@]+"${keep[@]}"}" | sed '/^$/d' >"$file.tmp" && mv -f "$file.tmp" "$file"
}

verify() {
    local target="incus" rebaseline=false
    local -a remote_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ $# -ge 2 ]] || die "--target needs incus or vps"
                target="$2"
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            -*) die "the machine name comes before verify's options (got $1)" ;;
            *) break ;;
        esac
    done
    [[ $# -gt 0 ]] || die "verify needs a machine name"
    local name="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mail-agent|--mail-project)
                [[ $# -ge 2 ]] || die "$1 needs a value"
                remote_args+=("$1" "$2")
                shift 2
                ;;
            --rebaseline) rebaseline=true; shift ;;
            *) die "unknown verify option: $1 (see --help)" ;;
        esac
    done
    case "$target" in
        incus|vps) ;;
        *) die "unknown target: $target (incus or vps)" ;;
    esac
    [[ -f "$VERIFY_SH" ]] || die "the checks are missing: $VERIFY_SH (run this from an ACFS checkout)"

    # The ssh alias is the instance name without its remote.
    local alias="${name##*:}" rows rc=0
    log_info "machine: verifying $name ($target); each configured tool gets one small request" >&2
    rows="$(verify_remote "$target" "$name" "${remote_args[@]+"${remote_args[@]}"}")" || rc=$?
    if [[ -z "$rows" ]]; then
        die "the checks in $name reported nothing (exit $rc)"
    fi
    rows+=$'\n'"$(verify_ssh "$alias")"
    rows="$(verify_baseline "$STATE_DIR/${name//[^A-Za-z0-9._-]/_}.baseline" "$rebaseline" <<<"$rows")"

    local check result detail bad=0
    while IFS='|' read -r check result detail; do
        [[ -n "$check" ]] || continue
        printf '%-16s %-15s %s\n' "$check" "$result" "$detail"
        case "$result" in ok|not-configured) ;; *) bad=$((bad + 1)) ;; esac
    done <<<"$rows"
    if ((bad > 0)); then
        log_error "machine: $bad check(s) on $name need attention" >&2
        exit 1
    fi
    log_info "machine: $name passed; not-configured rows are tools without a login" >&2
}

main() {
    [[ $# -gt 0 ]] || { usage >&2; exit 1; }
    local subcommand="$1"
    shift
    case "$subcommand" in
        up) up "$@" ;;
        verify) verify "$@" ;;
        -h|--help|help) usage ;;
        *) die "unknown subcommand: $subcommand (see --help)" ;;
    esac
}

main "$@"
