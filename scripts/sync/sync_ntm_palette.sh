#!/usr/bin/env bash
# ============================================================
# Sync NTM Command Palette from upstream
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SOURCE_URL="https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/command_palette.md"
DEST_FILE="$PROJECT_ROOT/acfs/onboard/docs/ntm/command_palette.md"

# Security library (HTTPS-only curl enforcement + hashing helpers)
SECURITY_LIB="$PROJECT_ROOT/scripts/lib/security.sh"
if [[ -r "$SECURITY_LIB" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$SECURITY_LIB"
else
    echo "ERROR: security library not found at $SECURITY_LIB" >&2
    exit 1
fi

if ! enforce_https "$SOURCE_URL" "ntm command palette"; then
    exit 1
fi

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
  Downloads the latest command_palette.md from the NTM repository
  and saves it to acfs/onboard/docs/ntm/command_palette.md
EOF
}

check_mode=false

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

# Ensure destination directory exists
mkdir -p "$(dirname "$DEST_FILE")"

if [[ "$check_mode" == "true" ]]; then
    # Compare remote with local
    if [[ ! -f "$DEST_FILE" ]]; then
        echo "Local file missing - update needed"
        exit 1
    fi

    local_hash="$(calculate_sha256 < "$DEST_FILE")"
    remote_hash="$(acfs_curl "$SOURCE_URL" | calculate_sha256)"

    if [[ "$local_hash" == "$remote_hash" ]]; then
        echo -e "${GREEN}Up to date${NC}"
        exit 0
    else
        echo "Update available"
        exit 1
    fi
fi

# Download
echo "Syncing command_palette.md from NTM..."

if acfs_curl "$SOURCE_URL" -o "$DEST_FILE"; then
    lines=$(wc -l < "$DEST_FILE" | tr -d ' ')
    echo -e "${GREEN}Synced command_palette.md ($lines lines)${NC}"
    echo "Saved to: $DEST_FILE"
else
    echo -e "${RED}Failed to sync${NC}" >&2
    exit 1
fi
