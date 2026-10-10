#!/usr/bin/env bash
# ============================================================
# scripts/lib/agent_quota.sh (acfs agents quota) against fixture Codex
# session logs, fixture Claude statusLine input and a STUB herdr
#
# Proves which record each plan's state comes from, when check refuses, and
# that nothing but percentages, reset times and plan types is printed or
# saved.
#
# Usage: bash tests/unit/test_agent_quota.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/scripts/lib/agent_quota.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-agent-quota.XXXXXX")"
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

mkdir -p "$WORK/bin"
cat >"$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >>"$STUB_DIR/herdr_calls"
[[ "$1 $2" == "agent list" ]] || exit 1
[[ -e "$STUB_DIR/herdr_down" ]] && exit 1
printf '{"result":{"agents":[{"agent":"claude","name":"a"},{"agent":"claude","name":"b"},{"agent":"codex","name":"c"}]}}\n'
STUB
chmod +x "$WORK/bin/herdr"
# A stub capacity.sh, so quota's host section never reads this host.
cat >"$WORK/capacity.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --guard ]] || exit 2
if [[ "${2:-}" == --json ]]; then
    printf '{"status":"red","reasons":["MemAvailable is 2048 MiB, under 4096 MiB"],"agents":{"suggested_max":3}}\n'
else
    printf 'Host capacity guard: red\n  RED: MemAvailable is 2048 MiB, under 4096 MiB\n'
fi
STUB
export ACFS_AGENTS_CAPACITY_SCRIPT="$WORK/capacity.sh"

NOW="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z; }

# A token_count event as Codex writes it, with the usage totals and fields a
# real one carries; $1 timestamp, $2 primary JSON, $3 secondary JSON, $4
# rate_limit_reached_type JSON.
token_count() {
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":64645671,"total_tokens":64788445}},"rate_limits":{"limit_id":"codex","primary":%s,"secondary":%s,"credits":{"has_credits":false},"plan_type":"pro","rate_limit_reached_type":%s,"account_id":"acct-SECRET-42"}}}\n' \
        "$(iso "$1")" "$2" "$3" "$4"
}
window() { printf '{"used_percent":%s,"window_minutes":%s,"resets_at":%s}' "$1" "$2" "$3"; }

CASE=""
new_case() {
    CASE="$WORK/$1"
    mkdir -p "$CASE/codex/sessions/2026/10/10" "$CASE/acfs"
    export STUB_DIR="$CASE"
}
log_file() { printf '%s/codex/sessions/2026/10/10/rollout-%s.jsonl' "$CASE" "$1"; }

OUT=""
ERR=""
RC=0
run_helper() {
    RC=0
    OUT="$(PATH="$WORK/bin:$PATH" CODEX_HOME="$CASE/codex" ACFS_HOME="$CASE/acfs" HOME="$CASE" \
        bash "$HELPER" "$@" 2>"$CASE/stderr")" || RC=$?
    ERR="$(cat "$CASE/stderr")"
}
jq_out() { jq -e "$1" >/dev/null <<<"$OUT"; }

echo "codex: the newest record across session logs"
new_case newest
# The older session file holds the newer record.
token_count $((NOW - 60)) "$(window 71.0 300 $((NOW + 3600)))" "$(window 30.0 10080 $((NOW + 86400)))" null >"$(log_file a)"
token_count $((NOW - 600)) "$(window 12.0 300 $((NOW + 3600)))" "$(window 20.0 10080 $((NOW + 86400)))" null >"$(log_file b)"
{
    printf 'not json, but names "rate_limits"\n'
    printf '{"timestamp":"%s","type":"response_item","payload":{"type":"message","content":"\\"rate_limits\\": 1"}}\n' "$(iso "$NOW")"
} >>"$(log_file b)"
touch -d '-1 hour' "$(log_file a)"
run_helper --json
check "the newest record wins, whichever file holds it" \
    jq_out '.plans[] | select(.kind == "codex") | .windows.five_hour.used_percent == 71 and .windows.weekly.used_percent == 30 and .plan_type == "pro"'
check "lines that aren't token_count events are skipped" test "$RC" -eq 0
check "live agents are counted per kind from herdr" \
    jq_out '[.plans[] | {(.kind): .agents}] | add == {"claude": 2, "codex": 1, "agy": 0}'
check "no token count or account id is printed" \
    bash -c '! grep -q -e acct-SECRET -e 64645671 -e total_token <<<"$1"' _ "$OUT"
run_helper
check "the table shows the 5h and weekly rows with UTC times" \
    bash -c 'grep -Eq "^codex \(pro\) +5h +71% +[0-9-]{10}T[0-9:]{8}Z" <<<"$1" && grep -Eq "^codex \(pro\) +weekly +30%" <<<"$1"' _ "$OUT"
check "the table prints no secret either" bash -c '! grep -q acct-SECRET <<<"$1"' _ "$OUT"

echo "codex: check"
rm -f "$CASE/herdr_calls"
run_helper check codex
check "71% passes the default 90% limit" test "$RC" -eq 0
check "check never asks herdr (spawn runs it before any herdr call)" test ! -e "$CASE/herdr_calls"
run_helper check codex --limit 70
check "71% is refused at --limit 70, with the reason and reset time" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "codex: 5-hour window 71% used (limit 70%), resets 20" <<<"$2"' _ "$RC" "$ERR"
ACFS_AGENTS_QUOTA_LIMIT=50 run_helper check codex
check "ACFS_AGENTS_QUOTA_LIMIT sets the default limit" test "$RC" -eq 1
run_helper check codex --limit 070
check "--limit is decimal, also with a leading zero" test "$RC" -eq 1
run_helper check codex --limit 101
check "--limit takes 0-100 only" bash -c '[[ "$1" -eq 2 ]] && grep -q "whole percent" <<<"$2"' _ "$RC" "$ERR"

new_case reset
token_count $((NOW - 7200)) "$(window 99.0 300 $((NOW - 60)))" "$(window 40.0 10080 $((NOW + 86400)))" null >"$(log_file a)"
run_helper check codex
check "a 5h window whose reset time has passed doesn't refuse" test "$RC" -eq 0
run_helper
check "and is shown as reset, with what it was" bash -c 'grep -Eq "^codex \(pro\) +5h +reset \(was 99%\)" <<<"$1"' _ "$OUT"

new_case reached
token_count $((NOW - 900)) "$(window 40.0 300 $((NOW + 3600)))" "$(window 40.0 10080 $((NOW + 86400)))" null >"$(log_file a)"
# A credits record carries no windows, only the reached type.
token_count $((NOW - 300)) null null '"workspace_member_credits_depleted"' >>"$(log_file a)"
run_helper check codex
check "a recent limit-reached record refuses, whatever the windows say" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "codex: limit reached: workspace_member_credits_depleted" <<<"$2"' _ "$RC" "$ERR"
run_helper --json
check "the windows still come from the newest record that has them" \
    jq_out '.plans[] | select(.kind == "codex") | .windows.five_hour.used_percent == 40 and .limit_reached.stale == false'

new_case stale
token_count $((NOW - 30000)) "$(window 40.0 300 $((NOW - 12000)))" null '"rate_limit"' >"$(log_file a)"
run_helper check codex
check "a limit-reached record older than 5 h no longer refuses" test "$RC" -eq 0
run_helper
check "it is still shown, marked as maybe cleared" bash -c 'grep -q "limit reached: rate_limit (as of .*, may have cleared since)" <<<"$1"' _ "$OUT"

new_case resetafter
token_count $((NOW - 1200)) "$(window 99.0 300 $((NOW - 300)))" "$(window 40.0 10080 $((NOW + 86400)))" null >"$(log_file a)"
token_count $((NOW - 900)) null null '"workspace_member_credits_depleted"' >>"$(log_file a)"
run_helper check codex
check "a limit seen before its 5h window reset no longer refuses" test "$RC" -eq 0

new_case cleared
token_count $((NOW - 900)) null null '"rate_limit"' >"$(log_file a)"
token_count $((NOW - 60)) "$(window 5.0 300 $((NOW + 3600)))" null null >>"$(log_file a)"
run_helper check codex
check "a newer record without a reached type clears the limit" test "$RC" -eq 0

new_case old
token_count $((NOW - 60)) "$(window 95.0 300 $((NOW + 3600)))" null null >"$(log_file a)"
touch -d '-8 days' "$(log_file a)"
run_helper --json
check "session logs older than the weekly window are not read" \
    jq_out '.plans[] | select(.kind == "codex") | .windows.five_hour == null and (.note | test("no Codex session log"))'
run_helper check codex
check "and an unknown plan passes check" test "$RC" -eq 0

echo "claude: record-claude and its record"
new_case claude
status_json() {
    printf '{"session_id":"sess-SECRET","transcript_path":"/x/y.jsonl","model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":41.2,"resets_at":%s}}}' \
        "$1" "$2" $((NOW + 86400))
}
RC=0
OUT="$(status_json 93.5 $((NOW + 3600)) | ACFS_HOME="$CASE/acfs" bash "$HELPER" record-claude)" || RC=$?
check "record-claude prints a one-line summary for the status line" \
    bash -c '[[ "$1" -eq 0 && "$2" == "Opus · 5h 93% · 7d 41%" ]]' _ "$RC" "$OUT"
check "it saves only the windows and when they were recorded" \
    bash -c 'jq -e "(keys == [\"rate_limits\", \"recorded_at\"]) and (.rate_limits | keys == [\"five_hour\", \"seven_day\"])" "$1" >/dev/null' _ "$CASE/acfs/state/quota/claude.json"
check "no session id or path is saved" bash -c '! grep -q -e sess-SECRET -e transcript "$1"' _ "$CASE/acfs/state/quota/claude.json"
run_helper check claude
check "check reads it: 93% is refused at the default limit" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "claude: 5-hour window 93% used (limit 90%)" <<<"$2"' _ "$RC" "$ERR"
run_helper
check "the table shows Claude's windows" bash -c 'grep -Eq "^claude +5h +93%" <<<"$1" && grep -Eq "^claude +weekly +41%" <<<"$1"' _ "$OUT"

RC=0
OUT="$(printf '{"model":{"display_name":"Opus"}}' | ACFS_HOME="$CASE/acfs" bash "$HELPER" record-claude)" || RC=$?
check "input without rate_limits keeps the last record" \
    bash -c '[[ "$1" -eq 0 && "$2" == "Opus" ]] && jq -e ".rate_limits.five_hour.used_percentage == 93.5" "$3" >/dev/null' \
    _ "$RC" "$OUT" "$CASE/acfs/state/quota/claude.json"
RC=0
OUT="$(printf 'garbage' | ACFS_HOME="$CASE/acfs" bash "$HELPER" record-claude)" || RC=$?
check "garbage input never fails the status line" test "$RC" -eq 0

new_case badreset
token_count $((NOW - 60)) '{"used_percent":95.0,"window_minutes":300,"resets_at":"soon"}' null null >"$(log_file a)"
run_helper
check "a reset time that isn't epoch seconds shows as unknown instead of failing" \
    bash -c '[[ "$1" -eq 0 ]] && grep -Eq "^codex \(pro\) +5h +reset \(was 95%\) +- " <<<"$2"' _ "$RC" "$OUT"

echo "nothing known"
new_case empty
touch "$CASE/herdr_down"
run_helper --json
check "with no data, every plan is unknown and herdr's absence counts 0 agents" \
    jq_out '[.plans[] | .windows.five_hour == null and .agents == 0] | all'
check "agy says it exposes no usage" jq_out '.plans[] | select(.kind == "agy") | .note == "agy exposes no usage"'
for kind in claude codex agy pi; do
    run_helper check "$kind"
    check "check $kind passes when its usage is unknown" test "$RC" -eq 0
done
run_helper check
check "check needs a kind" test "$RC" -eq 2

echo "host capacity"
new_case host
run_helper --json
check "--json carries the capacity guard under host" \
    jq_out '.host.status == "red" and .host.agents.suggested_max == 3 and (.plans | length) == 3'
run_helper
check "the table is followed by the guard's report" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "^Host capacity guard: red" <<<"$2" && grep -q "RED: MemAvailable is 2048 MiB" <<<"$2"' _ "$RC" "$OUT"
printf '#!/usr/bin/env bash\nprintf "Host capacity guard: red\\n  MemAvailable:\\n"\nexit 1\n' >"$WORK/capacity-partial.sh"
ACFS_AGENTS_CAPACITY_SCRIPT="$WORK/capacity-partial.sh" run_helper
check "a guard that fails part way shows as unavailable, with none of its partial report" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "^Host capacity guard: unavailable" <<<"$2" && ! grep -q "MemAvailable:" <<<"$2"' _ "$RC" "$OUT"
ACFS_AGENTS_CAPACITY_SCRIPT="$WORK/missing.sh" run_helper --json
check "without capacity.sh, host is null and quota still answers" \
    bash -c '[[ "$1" -eq 0 ]] && jq -e ".host == null and (.plans | length) == 3" >/dev/null <<<"$2"' _ "$RC" "$OUT"
run_helper check claude
check "check reads no host capacity (spawn asks the guard itself)" test "$RC" -eq 0

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
