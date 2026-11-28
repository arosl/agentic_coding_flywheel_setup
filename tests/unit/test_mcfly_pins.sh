#!/usr/bin/env bash
# ============================================================
# mcfly and mcfly-fzf are pinned twice (acfs-wyzm): in the manifest's
# tools.mcfly and tools.mcfly_fzf, which install.sh runs, and in update.sh's
# UPDATE_MCFLY_PINS, which acfs update uses. Neither project publishes
# checksums, so the pins are the only check on what is installed.
#
# This runs each module's generated install script for x86_64 and aarch64,
# with stubs that record the URL it fetches and the SHA-256 it checks, and
# fails unless both match update.sh's entry for that command and machine,
# and unless the module's installed_check expects the version that entry
# expects. It also checks the asset names against the release triples.
# Usage: bash tests/unit/test_mcfly_pins.sh
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_TOOLS="$REPO_ROOT/scripts/generated/install_tools.sh"
MANIFEST_INDEX="$REPO_ROOT/scripts/generated/manifest_index.sh"
UPDATE_SH="$REPO_ROOT/scripts/lib/update.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-mcfly-pins.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); echo "ok   $name"
    else
        FAIL=$((FAIL + 1)); echo "FAIL $name"; echo "     want: $want"; echo "     got:  $got"
    fi
}

# update.sh's pins, one "cmd|machine|version line|url|sha" per line.
awk '/^UPDATE_MCFLY_PINS=\(/{on=1; next} on && /^\)/{exit} on' "$UPDATE_SH" |
    sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' > "$WORK/pins"
check "update.sh pins four entries" "4" "$(grep -c . "$WORK/pins")"

# The module's install script: the first heredoc of its generated function.
module_script() {
    local marker="$1"
    awk -v m="$marker" '
        !on && index($0, "<<'\''" m "'\''") { on = 1; next }
        on && $0 == m { exit }
        on { print }
    ' "$INSTALL_TOOLS"
}

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/uname" <<'EOF'
#!/bin/bash
echo "$FAKE_MACHINE"
EOF
cat > "$STUBS/curl" <<'EOF'
#!/bin/bash
out="" url=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --proto|--proto-redir|--retry) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf 'url %s\n' "$url" >> "$STUB_LOG"
: > "$out"
EOF
# The script pipes "<sha>  <file>" into `sha256sum -c -`.
cat > "$STUBS/sha256sum" <<'EOF'
#!/bin/bash
read -r sha _
printf 'sha %s\n' "$sha" >> "$STUB_LOG"
EOF
cat > "$STUBS/tar" <<'EOF'
#!/bin/bash
printf 'stub\n'
EOF
cat > "$STUBS/install" <<'EOF'
#!/bin/bash
printf 'install %s\n' "${*: -1}" >> "$STUB_LOG"
EOF
chmod +x "$STUBS"/*

for entry in mcfly:INSTALL_TOOLS_MCFLY:tools.mcfly mcfly-fzf:INSTALL_TOOLS_MCFLY_FZF:tools.mcfly_fzf; do
    IFS=: read -r cmd marker module <<< "$entry"
    module_script "$marker" > "$WORK/$cmd.sh"
    if ! grep -q 'sha256sum -c' "$WORK/$cmd.sh"; then
        FAIL=$((FAIL + 1)); echo "FAIL could not extract $module's install script from $INSTALL_TOOLS"
        continue
    fi
    for machine in x86_64 aarch64; do
        home="$WORK/home-$cmd-$machine"
        mkdir -p "$home"
        : > "$WORK/log"
        env -i HOME="$home" TMPDIR="$WORK" PATH="$STUBS:/usr/bin:/bin" FAKE_MACHINE="$machine" STUB_LOG="$WORK/log" \
            bash -euo pipefail "$WORK/$cmd.sh" >/dev/null 2>&1
        rc=$?
        pin="$(grep -E "^$cmd\\|$machine\\|" "$WORK/pins")"
        IFS='|' read -r _ _ pin_want pin_url pin_sha <<< "$pin"
        check "$module $machine: install script ran" "0" "$rc"
        check "$module $machine: URL matches update.sh" "url $pin_url" "$(grep '^url ' "$WORK/log")"
        check "$module $machine: SHA-256 matches update.sh" "sha $pin_sha" "$(grep '^sha ' "$WORK/log")"
        check "$module $machine: installs ~/.local/bin/$cmd" "install $home/.local/bin/$cmd" "$(grep '^install ' "$WORK/log")"
        asset=no
        [[ "$pin_url" == */"$cmd"-*"$machine"-unknown-linux-musl.tar.gz ]] && asset=yes
        check "$module $machine: the asset is the $machine musl build" "yes" "$asset"
    done
    # installed_check expects the version line update.sh expects.
    want_line="$(bash -c 'source "$1"; printf "%s" "${ACFS_MODULE_INSTALLED_CHECK[$2]}"' _ "$MANIFEST_INDEX" "$module" |
        sed -n 's/.*grep -qx "\([^"]*\)".*/\1/p')"
    for machine in x86_64 aarch64; do
        IFS='|' read -r _ _ pin_want _ _ <<< "$(grep -E "^$cmd\\|$machine\\|" "$WORK/pins")"
        check "$module $machine: installed_check expects '$pin_want'" "$pin_want" "$want_line"
    done
done

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
