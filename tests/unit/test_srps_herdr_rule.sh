#!/usr/bin/env bash
# ============================================================
# The ananicy rule that gives herdr's server nice -10 (acfs-7mu.6)
#
# stack.srps installs it on a new host and update_srps_herdr_rule in
# update.sh adds it on an existing one. Checks that both carry the same
# rule, and runs the update function against a scratch rules directory
# with a stub systemctl. Nothing here touches /etc.
#
# Usage: bash tests/unit/test_srps_herdr_rule.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE_SH="$ROOT/scripts/lib/update.sh"
MANIFEST="$ROOT/acfs.manifest.yaml"
GENERATED="$ROOT/scripts/generated/install_stack.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-srps-herdr.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# ------------------------------------------------------------
# The rule itself, in the manifest step and in update.sh
# ------------------------------------------------------------
manifest_rule="$(sed -n "s/^ *rule='\(.*herdr.*\)'$/\1/p" "$MANIFEST")"
update_rule="$(sed -n "s/^UPDATE_SRPS_HERDR_RULE='\(.*\)'$/\1/p" "$UPDATE_SH")"

check "the manifest step carries one herdr rule" test "$(wc -l <<<"$manifest_rule")" -eq 1
check "the manifest rule is JSON naming herdr at nice -10" \
    jq -e '.name == "herdr" and .nice == -10 and (keys | length) == 2' <<<"$manifest_rule" >/dev/null
check "update.sh writes the same rule as the manifest" test "$update_rule" = "$manifest_rule"
check "the manifest step writes into 10-local" \
    grep -q '^ *rule_file=/etc/ananicy.d/10-local/acfs-herdr.rules$' "$MANIFEST"
check "the manifest step skips where ananicy-cpp is not installed" \
    grep -q 'if \[\[ ! -d /etc/ananicy.d \]\]; then' "$MANIFEST"
check "the manifest step never prompts for a password" \
    bash -c '! sed -n "/acfs-7mu.6/,/^    verify:/p" "$1" | grep -E "(^|[^-])sudo [^-]" | grep -v "WARN:"' _ "$MANIFEST"
check "the generated stack installer carries the step" grep -q 'acfs-herdr.rules' "$GENERATED"
check "update_stack adds the rule right after SRPS" \
    bash -c 'grep -A1 "run_cmd \"SRPS\" update_run_verified_installer srps" "$1" | grep -q "^ *update_srps_herdr_rule$"' _ "$UPDATE_SH"

# ------------------------------------------------------------
# update_srps_herdr_rule against a scratch directory. The sudo prefix is
# empty, so the commands run as this user; systemctl is a stub.
# ------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STUB_CALLS"
STUB
chmod +x "$WORK/bin/systemctl"

# run_update <ananicy dir> <sudo: ok|missing> [DRY_RUN]
run_update() {
    local dir="$1" sudo_mode="$2" dry_run="${3:-false}"
    : >"$WORK/calls"
    OUT="$(
        STUB_CALLS="$WORK/calls" PATH="$WORK/bin:$PATH" HOME="$WORK" \
            ANANICY_DIR_ARG="$dir" SUDO_MODE="$sudo_mode" DRY_RUN_ARG="$dry_run" \
            UPDATE_SH="$UPDATE_SH" bash -c '
                set -uo pipefail
                source "$UPDATE_SH"
                UPDATE_ANANICY_DIR="$ANANICY_DIR_ARG"
                QUIET=false
                VERBOSE=false
                DRY_RUN="$DRY_RUN_ARG"
                update_sudo_prefix() {
                    local -n _ref="$1"
                    _ref=()
                    [[ "$SUDO_MODE" == ok ]]
                }
                update_srps_herdr_rule
                echo "rc=$?"
            ' 2>&1
    )"
}

rules="$WORK/ananicy.d"
rule_file="$rules/10-local/acfs-herdr.rules"

run_update "$WORK/absent" ok
check "no ananicy dir: skips and returns 0" \
    bash -c 'grep -q "\[skip\] herdr ananicy rule" <<<"$1" && grep -q "^rc=0$" <<<"$1"' _ "$OUT"
check "no ananicy dir: writes nothing" test ! -e "$WORK/absent"

mkdir -p "$rules"
run_update "$rules" ok true
check "dry run: writes nothing" test ! -e "$rule_file"

run_update "$rules" missing
check "no sudo: warns, writes nothing and returns 0" \
    bash -c 'grep -q "\[warn\] herdr ananicy rule" <<<"$1" && grep -q "^rc=0$" <<<"$1" && [[ ! -e "$2" ]]' _ "$OUT" "$rule_file"

run_update "$rules" ok
check "writes the rule into 10-local" test "$(cat "$rule_file" 2>/dev/null)" = "$update_rule"
check "restarts ananicy-cpp once, only if it runs" test "$(cat "$WORK/calls")" = "systemctl try-restart ananicy-cpp"

run_update "$rules" ok
check "second run: reports ok and restarts nothing" \
    bash -c 'grep -q "\[ok\] herdr ananicy rule" <<<"$1" && [[ ! -s "$2" ]]' _ "$OUT" "$WORK/calls"

printf '{"name": "herdr", "nice": 5}\n' >"$rule_file"
run_update "$rules" ok
check "a changed rule is rewritten" test "$(cat "$rule_file")" = "$update_rule"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
