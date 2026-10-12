#!/usr/bin/env bash
# ============================================================
# nhm's herdr plugin and keys (acfs-9hkh.50): nhm_hooks.sh plugin
# link|bind|status, install.sh's acfs_install_herdr_keys, update.sh's
# update_herdr_palette_key and doctor's stack.nhm.plugin check.
#
# A fake `herdr` (plugin link and plugin list) and a fake `nhm` (bind)
# sit in a fixture home's ~/.local/bin, and palette.sh is a stub that
# records its calls. No real herdr server or config is touched.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_nhm_plugin_bind.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/nhm_hooks.sh"
DOCTOR="$REPO_ROOT/scripts/lib/doctor.sh"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}
check() { # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name" "${OUT:-}"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
lacks() { [[ "$OUT" != *"$1"* ]]; }

ROOT="$(mktemp -d)"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l -o -type s \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# Only the fakes and the system's tools: the host's own herdr and nhm stay
# out of every case.
BASEPATH="/usr/bin:/bin"

# fixture [nhm: yes|no] [herdr: yes|no]: a fresh home with nhm's plugin
# directory, the fakes, ACFS's copy of nhm_hooks.sh and a palette.sh stub.
# The fake nhm's bind follows ~/nhm-bind-mode: ok (writes nhm's block),
# refuse (exit 2, as before the takeover) or error (exit 1).
fixture() {
    HOMEDIR="$(mktemp -d -p "$ROOT")"
    PLUGIN="$HOMEDIR/.local/share/nhm/plugin"
    mkdir -p "$HOMEDIR/.local/bin" "$PLUGIN" "$HOMEDIR/.acfs/scripts/lib" "$HOMEDIR/.config/herdr"
    printf 'name = "nhm"\n' >"$PLUGIN/herdr-plugin.toml"
    cp "$HELPER" "$HOMEDIR/.acfs/scripts/lib/nhm_hooks.sh"
    cat >"$HOMEDIR/.acfs/scripts/lib/palette.sh" <<'EOF'
#!/usr/bin/env bash
printf 'palette %s\n' "$*" >>"$HOME/palette-calls"
echo "bound prefix+a to the palette"
EOF
    if [[ "${2:-yes}" == yes ]]; then
        cat >"$HOMEDIR/.local/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/herdr-calls"
case "$1 $2" in
    "plugin list")
        if [[ -s "$HOME/herdr-linked" ]]; then
            jq -cn --arg r "$(cat "$HOME/herdr-linked")" '{result: {plugins: [{plugin_id: "nhm", plugin_root: $r}]}}'
        else
            echo '{"result":{"plugins":[]}}'
        fi ;;
    "plugin link") printf '%s\n' "$3" >"$HOME/herdr-linked" ;;
    *) exit 1 ;;
esac
EOF
        chmod +x "$HOMEDIR/.local/bin/herdr"
    fi
    if [[ "${1:-yes}" == yes ]]; then
        cat >"$HOMEDIR/.local/bin/nhm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/nhm-calls"
case "$(cat "$HOME/nhm-bind-mode" 2>/dev/null)" in
    ok) printf '# >>> nhm >>>\n[keys]\n# <<< nhm <<<\n' >>"$HOME/.config/herdr/config.toml" ;;
    refuse) echo "nhm bind: ACFS's Bash owns this herdr server (generation 0), so nhm's palette cannot send" >&2; exit 2 ;;
    *) echo "nhm bind: boom" >&2; exit 1 ;;
esac
EOF
        chmod +x "$HOMEDIR/.local/bin/nhm"
    fi
    echo refuse >"$HOMEDIR/nhm-bind-mode"
}

helper() { # helper <args...>: ACFS's copy of the helper in the fixture home; sets OUT and RC
    RC=0
    OUT="$(PATH="$BASEPATH" HOME="$HOMEDIR" XDG_CONFIG_HOME="" XDG_DATA_HOME="" \
        bash "$HOMEDIR/.acfs/scripts/lib/nhm_hooks.sh" "$@" 2>&1)" || RC=$?
}
calls() { cat "$HOMEDIR/$1" 2>/dev/null; }

echo "nhm_hooks.sh plugin"

fixture no
helper plugin status
check "no nhm: no-plugin" test "$OUT" = no-plugin
helper plugin bind
check "no nhm: bind exits 3 and links nothing" test "$RC" -eq 3 -a ! -e "$HOMEDIR/herdr-calls"

fixture yes no
helper plugin bind
check "no herdr: bind exits 4" test "$RC" -eq 4

fixture
rm -f "$PLUGIN/herdr-plugin.toml"
helper plugin bind
check "a release without the plugin: bind exits 3, links nothing" \
    bash -c '[[ "$1" -eq 3 ]] && ! grep -q "plugin link" "$2/herdr-calls" 2>/dev/null' _ "$RC" "$HOMEDIR"

fixture
helper plugin status
check "an unlinked plugin: unlinked" test "$OUT" = unlinked
helper plugin link
check "link: exit 0, herdr links the stable plugin directory" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qxF "plugin link $2" "$3/herdr-calls"' _ "$RC" "$PLUGIN" "$HOMEDIR"
check "link runs no nhm bind" test ! -e "$HOMEDIR/nhm-calls"
helper plugin status
check "then: linked" test "$OUT" = linked
helper plugin link
check "a second link links nothing again" test "$(grep -c '^plugin link' "$HOMEDIR/herdr-calls")" -eq 1

helper plugin bind --no-reload
check "bind refused (ACFS's Bash owns the server): exit 5 with nhm's reason" \
    bash -c '[[ "$1" -eq 5 && "$2" == *"ACFS'"'"'s Bash owns this herdr server"* ]]' _ "$RC" "$OUT"
check "bind asks for the default server, without a reload" \
    test "$(calls nhm-calls)" = "bind --socket $HOMEDIR/.config/herdr/herdr.sock --no-reload"
echo ok >"$HOMEDIR/nhm-bind-mode"
helper plugin bind
check "bind after the takeover: exit 0, the keys named" \
    bash -c '[[ "$1" -eq 0 && "$2" == *"prefix+a palette, prefix+d agent board, prefix+m menu"* ]]' _ "$RC" "$OUT"
check "and herdr reloads (no --no-reload)" test "$(calls nhm-calls | tail -1)" = "bind --socket $HOMEDIR/.config/herdr/herdr.sock"
helper plugin status
check "then: bound" test "$OUT" = bound
echo error >"$HOMEDIR/nhm-bind-mode"
helper plugin bind
check "a failing nhm bind: exit 1 with its message" bash -c '[[ "$1" -eq 1 && "$2" == *"boom"* ]]' _ "$RC" "$OUT"

fixture
mv "$PLUGIN" "$HOMEDIR/.local/share/nhm/plugin-real"
ln -s "$HOMEDIR/.local/share/nhm/plugin-real" "$PLUGIN"
helper plugin bind
check "a symlinked plugin directory is never linked (herdr would keep its target)" \
    bash -c '[[ "$1" -eq 1 ]] && ! grep -q "plugin link" "$2/herdr-calls" 2>/dev/null' _ "$RC" "$HOMEDIR"

fixture
helper plugin status --no-reload
check "status takes no --no-reload" test "$RC" -eq 2
helper plugin unknown
check "an unknown verb: usage, exit 2" test "$RC" -eq 2

echo
echo "update.sh: update_herdr_palette_key"

# run_update [nhm installed: yes|no]: update.sh's function against the
# fixture home, its host helpers stubbed. Env: DRY.
run_update() {
    OUT="$(
        export HOME="$HOMEDIR" PATH="$BASEPATH"
        unset XDG_CONFIG_HOME XDG_DATA_HOME
        # shellcheck source=/dev/null
        source "$REPO_ROOT/scripts/lib/update.sh" >/dev/null 2>&1
        NHM_INSTALLED="${1:-yes}"
        update_binary_path() { [[ "$1" == herdr ]] && printf '%s\n' "$HOMEDIR/.local/bin/herdr"; }
        update_binary_exists() { [[ "$1" == nhm && "$NHM_INSTALLED" == yes ]]; }
        update_target_user() { printf 'ubuntu\n'; }
        update_target_home() { printf '%s\n' "$HOMEDIR"; }
        update_system_binary_path() { printf '/bin/%s\n' "$1"; }
        update_run_in_target_context() { shift; "$@"; }
        log_item() { printf 'ITEM %s|%s|%s\n' "$1" "$2" "${3:-}"; }
        DRY_RUN="${DRY:-false}"
        update_herdr_palette_key
        printf 'RC %s\n' "$?"
    )"
}

fixture
DRY=true run_update
check "dry-run: says what it would do, links nothing" \
    bash -c '[[ "$1" == *"ITEM skip|herdr keys|dry-run: would link nhm'"'"'s herdr plugin and run nhm bind"* ]] && [[ ! -e "$2/herdr-calls" ]]' \
    _ "$OUT" "$HOMEDIR"
run_update
check "before the takeover: links the plugin, says why nhm's keys wait" \
    bash -c '[[ "$1" == *"ITEM skip|herdr keys|nhm bind: ACFS'"'"'s Bash owns"*"ACFS'"'"'s palette keeps prefix+a"* ]] && [[ -s "$2/herdr-linked" ]]' \
    _ "$OUT" "$HOMEDIR"
check "and ACFS's palette keeps prefix+a" test "$(calls palette-calls)" = "palette bind --auto"
echo ok >"$HOMEDIR/nhm-bind-mode"
: >"$HOMEDIR/palette-calls"
run_update
check "after the takeover: nhm's keys" has "ITEM ok|herdr keys|nhm: prefix+a palette, prefix+d agent board, prefix+m menu"
check "and palette.sh is not run" test ! -s "$HOMEDIR/palette-calls"
check "never fails the update" has "RC 0"
fixture
run_update no
check "without nhm: only ACFS's palette, as before" \
    bash -c '[[ "$1" != *"herdr keys"* && "$1" == *"ITEM ok|herdr palette key|"* ]] && [[ ! -e "$2/herdr-calls" ]]' _ "$OUT" "$HOMEDIR"

echo
echo "install.sh: acfs_install_herdr_keys"

# run_install <stack.nhm selected: yes|no>: the function from install.sh,
# with the installer's helpers stubbed; the target user is the caller.
run_install() {
    OUT="$(
        export HOME="$HOMEDIR" PATH="$BASEPATH" ACFS_HOME="$HOMEDIR/.acfs"
        unset XDG_CONFIG_HOME XDG_DATA_HOME
        SELECTED="$1"
        run_as_target() { "$@"; }
        acfs_legacy_module_selected() { [[ "$1" == stack.nhm && "$SELECTED" == yes ]]; }
        try_step() { shift; "$@"; }
        log_detail() { printf 'DETAIL %s\n' "$1"; }
        log_warn() { printf 'WARN %s\n' "$1"; }
        # shellcheck source=/dev/null
        source <(sed -n '/^acfs_install_herdr_keys() {/,/^}/p' "$REPO_ROOT/install.sh")
        acfs_install_herdr_keys 2>&1
        printf 'RC %s\n' "$?"
    )"
}

[[ -n "$(sed -n '/^acfs_install_herdr_keys() {/,/^}/p' "$REPO_ROOT/install.sh")" ]] \
    || { echo "install.sh has no acfs_install_herdr_keys" >&2; exit 1; }
grep -q '^    acfs_install_herdr_keys$' "$REPO_ROOT/install.sh" \
    || { echo "install.sh never calls acfs_install_herdr_keys" >&2; exit 1; }
fixture
run_install yes
check "a fresh install (the Bash owns the server): plugin linked, ACFS's palette, no reload" \
    bash -c '[[ "$1" == *"RC 0"* && -s "$2/herdr-linked" ]] && [[ "$(cat "$2/palette-calls")" == "palette bind --auto --no-reload" ]]' \
    _ "$OUT" "$HOMEDIR"
check "and nhm bind was asked without a reload" bash -c 'grep -q -- "--no-reload" "$1/nhm-calls"' _ "$HOMEDIR"
echo ok >"$HOMEDIR/nhm-bind-mode"
: >"$HOMEDIR/palette-calls"
run_install yes
check "nhm owns the server: nhm's keys, no palette.sh" \
    bash -c '[[ "$1" == *"DETAIL nhm'"'"'s keys in herdr"* ]] && [[ ! -s "$2/palette-calls" ]]' _ "$OUT" "$HOMEDIR"
fixture
run_install no
check "stack.nhm not selected: ACFS's palette only" \
    bash -c '[[ ! -e "$1/herdr-calls" && "$(cat "$1/palette-calls")" == "palette bind --auto --no-reload" ]]' _ "$HOMEDIR"
fixture
echo error >"$HOMEDIR/nhm-bind-mode"
run_install yes
check "a failing nhm bind warns, keeps ACFS's palette, never fails the install" \
    bash -c '[[ "$1" == *"WARN nhm'"'"'s herdr plugin or keys"*"RC 0"* && -s "$2/palette-calls" ]]' _ "$OUT" "$HOMEDIR"

echo
echo "doctor: stack.nhm.plugin"

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
# run_doctor [nhm present: true|false]: prints "id|status|details|fix".
run_doctor() {
    PATH="$BASEPATH" STUB_HOME="$HOMEDIR" STUB_NHM="${1:-true}" TARGET_USER="" \
        XDG_CONFIG_HOME="" XDG_DATA_HOME="" bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_runtime_home() { printf "%s\n" "$STUB_HOME"; }
        doctor_binary_exists() { [[ "$1" == nhm && "$STUB_NHM" == true ]]; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        HOME="$STUB_HOME" check_nhm_plugin
    ' _ "$DOCTOR"
}

fixture
OUT="$(run_doctor false)"
check "no nhm: skip" has "stack.nhm.plugin|skip|nhm not installed"
OUT="$(run_doctor)"
check "unlinked: warn, with the link command" \
    bash -c '[[ "$1" == "stack.nhm.plugin|warn|"*"not linked"*"|Run: bash "*"nhm_hooks.sh plugin link (or acfs update)" ]]' _ "$OUT"
helper plugin link
OUT="$(run_doctor)"
check "linked before the takeover: pass, prefix+a stays ACFS's palette" \
    bash -c '[[ "$1" == "stack.nhm.plugin|pass|linked; prefix+a is ACFS'"'"'s palette"*"nhm bind"* ]]' _ "$OUT"
echo ok >"$HOMEDIR/nhm-bind-mode"
helper plugin bind
OUT="$(run_doctor)"
check "bound: pass, nhm's keys" has "stack.nhm.plugin|pass|linked; nhm's keys: prefix+a palette"
rm -f "$PLUGIN/herdr-plugin.toml"
OUT="$(run_doctor)"
check "a release without the plugin: skip" has "stack.nhm.plugin|skip|this nhm has no herdr plugin"
check "the doctor runs the check" grep -q '^    check_nhm_plugin$' "$DOCTOR"

echo
echo "nhm plugin and keys: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
