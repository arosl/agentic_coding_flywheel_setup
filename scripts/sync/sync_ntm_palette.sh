#!/usr/bin/env bash
# ============================================================
# Sync NTM Command Palette from upstream
#
# The fork runs its agents in herdr, not ntm, so it keeps its own
# version of the palette's header and of the prompts that called ntm
# (acfs-x6b). A sync takes everything else from the ntm repo and keeps
# those fork-owned blocks; --check reports drift outside them only.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SOURCE_URL="https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/command_palette.md"
DEST_FILE="$PROJECT_ROOT/acfs/onboard/docs/ntm/command_palette.md"

# The palette's header (everything before the first "## " category) and
# these command_keys are the fork's herdr ports; a sync keeps them.
PALETTE_FORK_KEYS="ensemble_list ensemble_run ensemble_status ensemble_synthesize ensemble_modes_core ensemble_modes_advanced check_project_inbox"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    cat << 'EOF'
sync_ntm_palette.sh - Sync NTM command palette from upstream

Usage:
  ./sync_ntm_palette.sh [options]

Options:
  --check    Only check if update available (don't download)
  --help     Show this help

Description:
  Downloads the latest command_palette.md from the NTM repository and
  saves it to acfs/onboard/docs/ntm/command_palette.md, keeping the
  fork's header and its herdr versions of the prompts that called ntm.
EOF
}

# Print upstream's palette with the fork's header and fork-owned prompt
# blocks from the local palette in their place. A block runs from its
# "### command_key | Label" line to the next "## " or "### " line.
# Warns on stderr, and returns 1, for each fork-owned key upstream lacks.
# Usage: palette_overlay_fork_prompts <local_palette> <upstream_palette>
palette_overlay_fork_prompts() {
    local local_file="$1"
    local upstream_file="$2"

    awk -v keys="$PALETTE_FORK_KEYS" '
        BEGIN {
            n = split(keys, list, " ")
            for (i = 1; i <= n; i++) owned[list[i]] = 1
        }
        function key_of(line,    s) {
            s = substr(line, 5)
            sub(/[[:space:]]*\|.*/, "", s)
            return s
        }
        FNR == 1 { file++; cur = "header" }
        /^## / { cur = "" }
        /^### / { cur = key_of($0) }
        file == 1 {
            if (cur == "header" || (cur in owned)) fork[cur] = fork[cur] $0 "\n"
            next
        }
        cur == "header" {
            if (!("header" in done)) { printf "%s", fork["header"]; done["header"] = 1 }
            next
        }
        (cur in owned) && (cur in fork) {
            if (!(cur in done)) { printf "%s", fork[cur]; done[cur] = 1 }
            next
        }
        { print }
        END {
            missing = 0
            for (k in owned) {
                if (!(k in done)) {
                    printf "WARNING: fork-owned prompt %s is not in the upstream palette; review before syncing\n", k > "/dev/stderr"
                    missing = 1
                }
            }
            exit missing
        }
    ' "$local_file" "$upstream_file"
}

main() {
    # Security library (HTTPS-only curl enforcement + hashing helpers)
    local security_lib="$PROJECT_ROOT/scripts/lib/security.sh"
    if [[ -r "$security_lib" ]]; then
        # shellcheck disable=SC1090,SC1091
        source "$security_lib"
    else
        echo "ERROR: security library not found at $security_lib" >&2
        exit 1
    fi

    if ! enforce_https "$SOURCE_URL" "ntm command palette"; then
        exit 1
    fi

    local check_mode=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --check)
                check_mode=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    if [[ ! -f "$DEST_FILE" ]]; then
        echo -e "${RED}Local palette missing: $DEST_FILE${NC}" >&2
        echo "It holds the fork's herdr prompts, which a sync keeps; restore it from git first." >&2
        exit 1
    fi

    local work_dir upstream merged overlay_status=0
    work_dir="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: work_dir is local to main
    trap "rm -f '$work_dir/upstream.md' '$work_dir/merged.md'; rmdir '$work_dir' 2>/dev/null || true" EXIT
    upstream="$work_dir/upstream.md"
    merged="$work_dir/merged.md"

    if ! acfs_curl "$SOURCE_URL" -o "$upstream"; then
        echo -e "${RED}Failed to fetch $SOURCE_URL${NC}" >&2
        exit 1
    fi
    palette_overlay_fork_prompts "$DEST_FILE" "$upstream" > "$merged" || overlay_status=$?

    if [[ "$check_mode" == "true" ]]; then
        if [[ "$overlay_status" -eq 0 ]] && cmp -s "$merged" "$DEST_FILE"; then
            echo -e "${GREEN}Up to date${NC} (fork's herdr prompts kept: $PALETTE_FORK_KEYS)"
            exit 0
        fi
        echo "Update available"
        diff -u "$DEST_FILE" "$merged" || true
        exit 1
    fi

    if [[ "$overlay_status" -ne 0 ]]; then
        echo -e "${RED}Not syncing: a fork-owned prompt is missing upstream (see above)${NC}" >&2
        exit 1
    fi

    echo "Syncing command_palette.md from NTM (keeping the fork's herdr prompts)..."
    cp "$merged" "$DEST_FILE"
    local lines
    lines=$(wc -l < "$DEST_FILE" | tr -d ' ')
    echo -e "${GREEN}Synced command_palette.md ($lines lines)${NC}"
    echo "Saved to: $DEST_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
