#!/usr/bin/env bash
# ============================================================
# ACFS machine: one entry command for the two deploy targets (acfs-ioo3.4)
#
#   machine.sh up [--target incus|vps] <name> [launcher options]
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
# It runs where the launcher runs: on the Incus host, from a checkout. On
# macOS the container target needs Colima, which it doesn't start yet.
# Progress goes to stderr; stdout carries only the attach block.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/scripts/lib/logging.sh"

# Overridable so the tests can run a stub launcher and pretend to be a Mac.
INCUS_SH="${ACFS_MACHINE_INCUS_SH:-$SCRIPT_DIR/incus.sh}"
UNAME="${ACFS_MACHINE_UNAME:-$(uname -s)}"

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

main() {
    [[ $# -gt 0 ]] || { usage >&2; exit 1; }
    local subcommand="$1"
    shift
    case "$subcommand" in
        up) up "$@" ;;
        -h|--help|help) usage ;;
        *) die "unknown subcommand: $subcommand (see --help)" ;;
    esac
}

main "$@"
