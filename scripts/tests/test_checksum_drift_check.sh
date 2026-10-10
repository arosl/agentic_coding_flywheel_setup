#!/usr/bin/env bash
# ============================================================
# scripts/checksum-drift-check.sh against a STUB security.sh (acfs-2iq)
#
# The stub prints a saved `security.sh --verify --json` report and exits as
# the real one does (1 on any mismatch, fetch error or incomplete entry).
# Proves the check's exit code, its Markdown report, and that it only ever
# asks security.sh to verify, never to update.
#
# Usage: bash scripts/tests/test_checksum_drift_check.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/checksum-drift-check.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-drift-check.XXXXXX")"
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

# The stub logs its arguments, prints $WORK/report.json and exits with
# $WORK/rc (default 0).
cat >"$WORK/security.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_WORK/calls"
echo "progress on stderr" >&2
cat "$STUB_WORK/report.json" 2>/dev/null || true
exit "$(cat "$STUB_WORK/rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$WORK/security.sh"
export STUB_WORK="$WORK"

# A report with the given mismatches, errors and skipped entries (JSON arrays).
report() {
    jq -nc --argjson mismatches "$1" --argjson errors "$2" --argjson skipped "$3" '{
        schema: "acfs.installer-checksum-verification.v1", schemaVersion: 1,
        timestamp: "2026-10-10T05:00:00Z", checksumsYamlSha256: ("a" * 64),
        total: (2 + ($mismatches | length) + ($errors | length) + ($skipped | length)),
        matches: [{name: "bun", url: "https://bun.sh/install", checksum: ("b" * 64)},
                  {name: "uv", url: "https://astral.sh/uv/install.sh", checksum: ("c" * 64)}],
        mismatches: $mismatches, errors: $errors, skipped: $skipped}' >"$WORK/report.json"
}

run_check() {
    RC=0
    : >"$WORK/calls"
    ACFS_DRIFT_SECURITY_SH="$WORK/security.sh" bash "$CHECK" "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
    OUT="$(cat "$WORK/out")"
    ERR="$(cat "$WORK/err")"
}

echo "checksum drift check"

report '[]' '[]' '[]'
echo 0 >"$WORK/rc"
run_check
check "no drift exits 0 and says every pin matches" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "No drift: all 2 pinned installers match checksums.yaml" <<<"$2"' _ "$RC" "$OUT"
check "it only asks security.sh to verify, as JSON" test "$(cat "$WORK/calls")" = "--verify --json"
check "security.sh's progress stays on stderr" \
    bash -c 'grep -q "progress on stderr" <<<"$1" && ! grep -q "progress on stderr" <<<"$2"' _ "$ERR" "$OUT"

report '[{"name":"dcg","url":"https://example.test/dcg/install.sh","expected":"'"$(printf '1%.0s' {1..64})"'","actual":"'"$(printf '2%.0s' {1..64})"'"}]' '[]' '[]'
echo 1 >"$WORK/rc"
run_check
check "a changed installer exits 1 and is listed with its pinned and current hash" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "^| dcg | https://example.test/dcg/install.sh | 1\{64\} | 2\{64\} |$" <<<"$2"' _ "$RC" "$OUT"
check "the report counts it and names the canonical refresh as the fix" \
    bash -c 'grep -q "3 pinned installers: 2 match, 1 changed upstream, 0 could not be fetched, 0 incomplete" <<<"$1" \
        && grep -q -- "--update-checksums" <<<"$1" && grep -q "Verified Installer Checksum Discipline" <<<"$1"' _ "$OUT"

report '[]' '[{"name":"fmd","url":"https://example.test/fmd","error":"curl: (22) 404 | not found\nretry failed"}]' '[]'
echo 1 >"$WORK/rc"
run_check
check "a fetch error exits 1, on one table row with its pipe escaped" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "^| fmd | https://example.test/fmd | curl: (22) 404 \\\\| not found retry failed |$" <<<"$2"' _ "$RC" "$OUT"

report '[]' '[]' '[{"name":"half","url":"","reason":"policy entry is incomplete"}]'
echo 1 >"$WORK/rc"
run_check
check "an incomplete entry exits 1 and is listed" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "^| half |  | policy entry is incomplete |$" <<<"$2"' _ "$RC" "$OUT"

report '[]' '[]' '[]'
printf 'not json\n' >"$WORK/report.json"
echo 1 >"$WORK/rc"
run_check
check "no valid report exits 2, and says the check itself failed" \
    bash -c '[[ "$1" -eq 2 ]] && grep -q "no valid report from security.sh --verify --json" <<<"$2"' _ "$RC" "$ERR"

report '[]' '[]' '[]'
jq -c '.schema = "something.else"' "$WORK/report.json" >"$WORK/other.json"
cp "$WORK/other.json" "$WORK/report.json"
echo 0 >"$WORK/rc"
run_check
check "a report of another schema exits 2" test "$RC" -eq 2

report '[]' '[]' '[]'
jq -c 'del(.checksumsYamlSha256)' "$WORK/report.json" >"$WORK/other.json"
cp "$WORK/other.json" "$WORK/report.json"
run_check
check "a report without its checksums.yaml digest exits 2" test "$RC" -eq 2

report '[{"name":"dcg","url":"u","expected":"'"$(printf '1%.0s' {1..64})"'","actual":"'"$(printf '2%.0s' {1..64})"'"}]' '[]' '[]'
cp "$WORK/report.json" "$WORK/saved.json"
run_check --report "$WORK/saved.json"
check "--report reads a saved report and runs nothing" \
    bash -c '[[ "$1" -eq 1 && ! -s "$2" ]]' _ "$RC" "$WORK/calls"

run_check --update
check "an unknown option exits 2" test "$RC" -eq 2

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
