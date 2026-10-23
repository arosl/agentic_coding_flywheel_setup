#!/usr/bin/env bash
# ============================================================
# scripts/tests/ensure_playwright_browsers.sh (acfs-l3r7): Playwright's
# browsers from a zip mirror, fetched by a resumable curl and unpacked
# with the system's unzip.
#
# A fake Playwright CLI prints a dry-run plan whose download URLs are
# file:// URLs of fixture zips, so nothing is downloaded and no real
# browser cache is touched.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_ensure_playwright_browsers.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/tests/ensure_playwright_browsers.sh"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${OUT:-}" ]] && printf '  got: %s\n' "$OUT"
    return 0
}
check() { # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }

ROOT="$(mktemp -d)"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# make_zip <file> <member> <text>: a zip holding one file.
make_zip() {
    python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr(sys.argv[2], sys.argv[3])' "$1" "$2" "$3"
}

# fixture: a web dir with the fake CLI, an empty browser cache and mirror,
# and two source zips under $SRC.
fixture() {
    CASE="$(mktemp -d -p "$ROOT")"
    WEB="$CASE/web"
    SRC="$CASE/src"
    export PLAYWRIGHT_BROWSERS_PATH="$CASE/browsers"
    export ACFS_PLAYWRIGHT_MIRROR="$CASE/mirror"
    mkdir -p "$WEB/node_modules/.bin" "$SRC" "$PLAYWRIGHT_BROWSERS_PATH"
    cat >"$WEB/node_modules/.bin/playwright" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls"
cat "$(dirname "$0")/plan"
EOF
    chmod +x "$WEB/node_modules/.bin/playwright"
    make_zip "$SRC/chrome-linux64.zip" chrome-linux64/chrome "chrome"
    make_zip "$SRC/ffmpeg-linux.zip" ffmpeg-linux "ffmpeg"
}

# plan <dir> <url>... [-- <dir> <url>...]: the dry-run text, one block per
# browser, in Playwright 1.58's format.
plan() {
    local out="$WEB/node_modules/.bin/plan" first=true i=0
    : >"$out"
    while [[ $# -gt 0 ]]; do
        printf 'Some Browser\n  Install location:    %s\n' "$1" >>"$out"
        shift
        first=true
        i=0
        while [[ $# -gt 0 && "$1" != -- ]]; do
            if [[ "$first" == true ]]; then
                printf '  Download url:        %s\n' "$1" >>"$out"
                first=false
            else
                i=$((i + 1))
                printf '  Download fallback %d: %s\n' "$i" "$1" >>"$out"
            fi
            shift
        done
        printf '\n' >>"$out"
        [[ $# -eq 0 ]] || shift
    done
}

run() { # run <args...>: sets OUT and RC
    RC=0
    OUT="$(bash "$HELPER" --web "$WEB" "$@" 2>&1)" || RC=$?
}

CHROMIUM() { printf '%s/chromium-1208\n' "$PLAYWRIGHT_BROWSERS_PATH"; }
installed() { [[ -f "$1/INSTALLATION_COMPLETE" && -f "$1/chrome-linux64/chrome" ]]; }

echo "ensure_playwright_browsers.sh"

fixture
plan "$(CHROMIUM)" "file://$SRC/chrome-linux64.zip"
mkdir -p "$(CHROMIUM)"
: >"$(CHROMIUM)/INSTALLATION_COMPLETE"
run chromium firefox
check "asks Playwright's dry run for the browsers named" \
    test "$(cat "$WEB/node_modules/.bin/calls")" = "install --dry-run chromium firefox"
check "an installed browser is left as it is, nothing fetched" \
    bash -c '[[ "$1" -eq 0 && "$2" == *"chromium-1208 is installed"* && ! -e "$3" ]]' _ "$RC" "$OUT" "$ACFS_PLAYWRIGHT_MIRROR"
RC=0
OUT="$(cd "$CASE" && bash "$HELPER" --web web chromium 2>&1)" || RC=$?
check "a relative --web works: the dry run runs from inside it" \
    bash -c '[[ "$1" -eq 0 && "$2" == *"chromium-1208 is installed"* ]]' _ "$RC" "$OUT"
RC=0
OUT="$(cd "$CASE" && bash "$HELPER" --web nowhere chromium 2>&1)" || RC=$?
check "a missing --web directory: exit 1, names it" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"no web directory at nowhere"* ]]' _ "$RC" "$OUT"

fixture
plan "$(CHROMIUM)" "file://$SRC/nowhere.zip"
mkdir -p "$ACFS_PLAYWRIGHT_MIRROR/chromium-1208"
cp "$SRC/chrome-linux64.zip" "$ACFS_PLAYWRIGHT_MIRROR/chromium-1208/nowhere.zip"
run chromium
check "a zip in the mirror is installed without a fetch" \
    bash -c '[[ "$1" -eq 0 && "$2" != *fetching* ]]' _ "$RC" "$OUT"
check "unpacked into the browser's directory and marked complete" installed "$(CHROMIUM)"

fixture
plan "$(CHROMIUM)" "file://$SRC/chrome-linux64.zip"
run chromium
check "a missing zip is fetched into the mirror, then installed" \
    bash -c '[[ "$1" -eq 0 && -f "$2/chromium-1208/chrome-linux64.zip" && ! -e "$2/chromium-1208/chrome-linux64.zip.part" ]]' \
    _ "$RC" "$ACFS_PLAYWRIGHT_MIRROR"
check "and the browser is installed" installed "$(CHROMIUM)"
run chromium
check "a second run finds it installed" has "chromium-1208 is installed"

fixture
plan "$(CHROMIUM)" "file://$SRC/gone/chrome-linux64.zip" "file://$SRC/chrome-linux64.zip"
run chromium
check "the first URL fails: the fallback is fetched" \
    bash -c '[[ "$1" -eq 0 && "$2" == *"fetching file://$3/gone/"*"fetching file://$3/chrome-linux64.zip"* ]]' _ "$RC" "$OUT" "$SRC"
check "and installed" installed "$(CHROMIUM)"

fixture
plan "$(CHROMIUM)" "file://$SRC/gone/a.zip" "file://$SRC/gone/b.zip"
run chromium
check "every URL fails: exit 1, nothing marked complete" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"could not fetch chromium-1208"* && ! -e "$3/INSTALLATION_COMPLETE" ]]' _ "$RC" "$OUT" "$(CHROMIUM)"

fixture
plan "$(CHROMIUM)" "file://$SRC/chrome-linux64.zip"
mkdir -p "$ACFS_PLAYWRIGHT_MIRROR/chromium-1208"
head -c 40 "$SRC/chrome-linux64.zip" >"$ACFS_PLAYWRIGHT_MIRROR/chromium-1208/chrome-linux64.zip"
run chromium
check "a damaged zip in the mirror: exit 1, says so, keeps it, marks nothing" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"is damaged; remove it"* && -f "$3/chromium-1208/chrome-linux64.zip" && ! -e "$4/INSTALLATION_COMPLETE" ]]' \
    _ "$RC" "$OUT" "$ACFS_PLAYWRIGHT_MIRROR" "$(CHROMIUM)"

fixture
plan "$(CHROMIUM)" "file://$SRC/chrome-linux64.zip"
mkdir -p "$ACFS_PLAYWRIGHT_MIRROR/chromium-1208"
head -c 60 "$SRC/chrome-linux64.zip" >"$ACFS_PLAYWRIGHT_MIRROR/chromium-1208/chrome-linux64.zip.part"
run chromium
check "a partial download is resumed to the whole zip" \
    bash -c '[[ "$1" -eq 0 ]] && cmp -s "$2" "$3/chromium-1208/chrome-linux64.zip"' _ "$RC" "$SRC/chrome-linux64.zip" "$ACFS_PLAYWRIGHT_MIRROR"
check "and installed" installed "$(CHROMIUM)"

fixture
plan "$(CHROMIUM)"
run chromium
check "no download for this host: exit 1, names the platform override" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64"* ]]' _ "$RC" "$OUT"

fixture
FFMPEG="$PLAYWRIGHT_BROWSERS_PATH/ffmpeg-1011"
plan "$(CHROMIUM)" "file://$SRC/chrome-linux64.zip" -- "$FFMPEG" "file://$SRC/ffmpeg-linux.zip" \
    -- "<system>" -- "$FFMPEG" "file://$SRC/ffmpeg-linux.zip"
run chromium firefox
check "every directory installed once, the system browser skipped" \
    bash -c '[[ "$1" -eq 0 && "$(grep -c "installed ffmpeg-1011" <<<"$2")" -eq 1 && "$2" != *"<system>"* ]] && [[ -f "$3/ffmpeg-linux" && -f "$3/INSTALLATION_COMPLETE" ]]' \
    _ "$RC" "$OUT" "$FFMPEG"

fixture
run
check "no browser named: usage, exit 2" test "$RC" -eq 2
run --bogus chromium
check "an unknown option: usage, exit 2" test "$RC" -eq 2
rm -f "$WEB/node_modules/.bin/playwright"
run chromium
check "no Playwright CLI: exit 1, says to install the packages" \
    bash -c '[[ "$1" -eq 1 && "$2" == *"bun install --frozen-lockfile"* ]]' _ "$RC" "$OUT"

echo
echo "ensure_playwright_browsers: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
