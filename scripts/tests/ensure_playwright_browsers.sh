#!/usr/bin/env bash
# ============================================================
# Install the Playwright browsers a gate run needs from a local zip
# mirror (acfs-l3r7)
#
# Playwright's own installer kept failing on the development host: its
# downloader was slow, and its unzip died silently after 18 MB of a
# 364 MB archive, every time. So this does the same job with plain
# tools. Playwright's `install --dry-run` names each browser's directory
# and its download URLs, fallbacks included. A browser whose directory
# has no INSTALLATION_COMPLETE marker gets its zip fetched once into the
# mirror by a resumable curl, checked with `unzip -t`, unpacked with the
# system's unzip, and marked as Playwright marks its own installs. An
# installed browser is left as it is.
#
# Run it under the host's browser lock, as run_gate.sh does: two
# installs into one browser cache at once would unpack over each other.
# ============================================================

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash scripts/tests/ensure_playwright_browsers.sh [--web DIR] BROWSER...

Makes sure each BROWSER (chromium, firefox, webkit) that the Playwright
in DIR (default: apps/web) uses is installed, with what it depends on.

Environment:
  PLAYWRIGHT_BROWSERS_PATH  Where the browsers go (Playwright's default:
                            ~/.cache/ms-playwright)
  ACFS_PLAYWRIGHT_MIRROR    The zip mirror, kept across runs (default:
                            ~/.cache/acfs/playwright-mirror)
  PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
                            Playwright 1.58 has no builds for Ubuntu
                            26.04; its ubuntu24.04 builds run there
                            (run_gate.sh sets it)

Exit status: 0 when every browser is installed, 1 when one could not be,
2 on bad usage.
USAGE
}

die() {
    echo "ensure_playwright_browsers: $*" >&2
    exit 1
}

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/apps/web"
BROWSERS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --web) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; WEB_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) BROWSERS+=("$1"); shift ;;
    esac
done
[[ ${#BROWSERS[@]} -gt 0 ]] || { usage >&2; exit 2; }
# The dry run below runs the CLI from inside WEB_DIR, so a relative path
# would no longer name it there.
web_abs="$(cd "$WEB_DIR" 2>/dev/null && pwd)" || die "no web directory at $WEB_DIR"
WEB_DIR="$web_abs"

CLI="$WEB_DIR/node_modules/.bin/playwright"
[[ -x "$CLI" ]] || die "no Playwright CLI at $CLI (run bun install --frozen-lockfile first)"
MIRROR="${ACFS_PLAYWRIGHT_MIRROR:-${XDG_CACHE_HOME:-$HOME/.cache}/acfs/playwright-mirror}"

plan="$(cd "$WEB_DIR" && "$CLI" install --dry-run "${BROWSERS[@]}")" \
    || die "playwright install --dry-run ${BROWSERS[*]} failed"

# One line per browser directory, the first time it appears: the
# directory, then its download URLs, tab-separated.
entries="$(awk '
    function emit() {
        if (dir != "" && dir != "<system>" && !(dir in seen)) { seen[dir] = 1; print dir urls }
        dir = ""
    }
    /^  Install location: / { emit(); dir = $0; sub(/^  Install location: +/, "", dir); urls = ""; next }
    /^  Download (url|fallback [0-9]+): / { url = $0; sub(/^  Download [^:]*: +/, "", url); urls = urls "\t" url; next }
    END { emit() }
' <<<"$plan")"
[[ -n "$entries" ]] || die "playwright install --dry-run named no browser directory for: ${BROWSERS[*]}"

# fetch <file> <url>...: the first URL that works, resuming a partial
# download that an earlier run left as <file>.part.
fetch() {
    local file="$1" url
    shift
    mkdir -p "$(dirname "$file")"
    for url in "$@"; do
        echo "ensure_playwright_browsers: fetching $url" >&2
        if curl -fsSL --retry 3 --retry-delay 2 -C - -o "$file.part" "$url"; then
            mv -f "$file.part" "$file"
            return 0
        fi
    done
    return 1
}

while IFS=$'\t' read -r -a fields; do
    dir="${fields[0]}"
    urls=("${fields[@]:1}")
    name="$(basename "$dir")"
    if [[ -f "$dir/INSTALLATION_COMPLETE" ]]; then
        echo "ensure_playwright_browsers: $name is installed"
        continue
    fi
    [[ ${#urls[@]} -gt 0 ]] \
        || die "Playwright names no download for $name on this host (on Ubuntu 26.04: PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64)"
    zip="$MIRROR/$name/$(basename "${urls[0]}")"
    if [[ ! -f "$zip" ]]; then
        fetch "$zip" "${urls[@]}" || die "could not fetch $name from any of: ${urls[*]}"
    fi
    unzip -tq "$zip" >/dev/null || die "the mirror's $zip is damaged; remove it and run again"
    mkdir -p "$dir"
    unzip -qo "$zip" -d "$dir"
    : >"$dir/INSTALLATION_COMPLETE"
    echo "ensure_playwright_browsers: installed $name from $zip"
done <<<"$entries"
