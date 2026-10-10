#!/usr/bin/env bash
# ============================================================
# ACFS agent quota - how much of each plan's usage windows is used
#
# Read-only. Each agent CLI exposes its subscription windows differently:
#   codex   writes them into every session log ($CODEX_HOME/sessions/**/
#           rollout-*.jsonl, token_count events: rate_limits.primary is the
#           5-hour window, .secondary the weekly one). The newest record
#           across all sessions is the plan's current state.
#   claude  hands them only to its statusLine command (rate_limits.five_hour
#           and .seven_day). `agent_quota.sh record-claude` is such a command:
#           it saves the windows to ~/.acfs/state/quota/claude.json.
#   agy     exposes no usage.
# Only percentages, reset times and plan types are read or printed, never a
# token, an account id or a session's content.
#
# Usage:
#   agent_quota.sh [show] [--json]
#   agent_quota.sh check <kind> [--limit PERCENT]
#   agent_quota.sh record-claude          (as Claude Code's statusLine command)
# ============================================================

set -euo pipefail

# check refuses a kind whose 5-hour window is at least this full.
AGENT_QUOTA_LIMIT_DEFAULT="${ACFS_AGENTS_QUOTA_LIMIT:-90}"
# Codex session logs older than the weekly window can't hold its state.
AGENT_QUOTA_CODEX_MAX_AGE_MIN=10080

agent_quota_usage() {
    cat <<'EOF'
Usage:
  acfs agents quota [--json]
  acfs agents quota check <kind> [--limit PERCENT]
  acfs agents quota record-claude

quota  Show, per plan, how full its 5-hour and weekly usage windows are, when
       each resets (UTC), when that was observed, and how many live agents of
       that kind herdr lists. Codex's state comes from its newest session log
       record; Claude's from the last record-claude run; agy exposes none. A
       window whose reset time has passed is shown as reset.
check  Exit 1 when the kind's 5-hour window is at least --limit percent used
       (default 90, or $ACFS_AGENTS_QUOTA_LIMIT), or its plan reports a limit
       reached; exit 0 otherwise, also when its usage is unknown. The reason
       goes to stderr.
record-claude
       Claude Code's statusLine command: reads the status JSON on stdin, saves
       its rate_limits windows to ~/.acfs/state/quota/claude.json and prints
       a one-line summary for the status line. Set it in ~/.claude/settings.json:
       "statusLine": {"type": "command", "command": "<this script> record-claude"}
EOF
}

agent_quota_die() {
    printf 'acfs agents quota: %s\n' "$*" >&2
    exit 2
}

agent_quota_state_dir() {
    printf '%s/state/quota\n' "${ACFS_HOME:-$HOME/.acfs}"
}

# The Codex plan's state as JSON: {kind, plan_type, observed_at, limit_reached,
# windows: {five_hour, weekly}}, or nothing when no session log has a record.
agent_quota_codex() {
    local sessions="${CODEX_HOME:-$HOME/.codex}/sessions"
    [[ -d "$sessions" ]] || return 0
    # grep prefilters; jq parses only token_count events and skips any line
    # that isn't JSON (a log being written, or a message that names the field).
    find "$sessions" -type f -name 'rollout-*.jsonl' -mmin "-$AGENT_QUOTA_CODEX_MAX_AGE_MIN" -print0 2>/dev/null \
        | xargs -0 -r grep -h -F '"rate_limits"' 2>/dev/null \
        | jq -R -c 'fromjson? // empty
            | select(.type == "event_msg" and .payload.type? == "token_count" and (.payload.rate_limits | type) == "object")
            | {ts: .timestamp, rl: .payload.rate_limits}' 2>/dev/null \
        | jq -s -c '
            def window: if type == "object" then {used_percent, window_minutes, resets_at} else null end;
            (sort_by(.ts)) as $all
            | ([$all[] | select(.rl.primary != null or .rl.secondary != null)] | last) as $w
            | ($all | last) as $newest
            | if $newest == null then empty else
              {kind: "codex",
               plan_type: (($w // $newest).rl.plan_type),
               observed_at: (($w // $newest).ts),
               limit_reached: (if $newest.rl.rate_limit_reached_type != null
                               then {type: $newest.rl.rate_limit_reached_type, observed_at: $newest.ts}
                               else null end),
               windows: {five_hour: ($w.rl.primary | window), weekly: ($w.rl.secondary | window)},
               source: "codex session logs"}
              end'
}

# The Claude plan's state as JSON, from record-claude's file.
agent_quota_claude() {
    local file
    file="$(agent_quota_state_dir)/claude.json"
    [[ -r "$file" ]] || return 0
    jq -c '
        def window: if type == "object"
            then {used_percent: .used_percentage, window_minutes: null, resets_at}
            else null end;
        select(type == "object" and (.rate_limits | type) == "object")
        | {kind: "claude",
           plan_type: null,
           observed_at: .recorded_at,
           limit_reached: null,
           windows: {five_hour: (.rate_limits.five_hour | window), weekly: (.rate_limits.seven_day | window)},
           source: "claude statusLine (record-claude)"}' "$file" 2>/dev/null || true
}

# Live agents per kind, as {"claude": 2, ...}; {} when herdr can't be asked.
agent_quota_agent_counts() {
    command -v herdr >/dev/null 2>&1 || { printf '{}\n'; return 0; }
    herdr agent list 2>/dev/null \
        | jq -c '[.result.agents[]? | .agent // empty] | group_by(.) | map({key: .[0], value: length}) | from_entries' 2>/dev/null \
        || printf '{}\n'
}

# Every plan's state, as one JSON document. A window whose reset time has
# passed is marked reset, with its used percent as last seen. With $1
# "counts", herdr is asked how many agents of each kind are live.
agent_quota_collect() {
    local now codex claude counts="{}"
    now="$(date -u +%s)"
    codex="$(agent_quota_codex)"
    claude="$(agent_quota_claude)"
    [[ "${1:-}" != counts ]] || counts="$(agent_quota_agent_counts)"
    jq -n -c --argjson now "$now" --argjson counts "$counts" \
        --argjson codex "${codex:-null}" --argjson claude "${claude:-null}" '
        # A reset time that is not epoch seconds counts as unknown.
        def mark: if . == null then null
            else .resets_at |= (numbers // null) | . + {reset: ((.resets_at // 0) <= $now)} end;
        def epoch: if . == null then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdate? // 0) end;
        # A limit-reached record may have cleared since, with nothing newer
        # logged to say so: when a window has reset after it was seen, or it
        # is older than one 5-hour window.
        def age_limit: if .limit_reached == null then .
            else (.limit_reached.observed_at | epoch) as $seen
                 | ([.windows[] | select(. != null and .reset and .resets_at > $seen)] | length > 0) as $cleared
                 | .limit_reached += {stale: ($cleared or ($now - $seen) > 18000)} end;
        def unknown($kind; $note): {kind: $kind, plan_type: null, observed_at: null, limit_reached: null,
                                    windows: {five_hour: null, weekly: null}, source: null, note: $note};
        {generated_at: ($now | todate),
         plans: [
           ($claude // unknown("claude"; "no record: set record-claude as Claude Code'"'"'s statusLine command")),
           ($codex // unknown("codex"; "no Codex session log of the last 7 days has a rate_limits record")),
           unknown("agy"; "agy exposes no usage")
         ]
         | map(.windows |= map_values(mark) | age_limit
               | . + {agents: ($counts[.kind] // 0)})}'
}

agent_quota_show() {
    local json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            -h|--help) agent_quota_usage; return 0 ;;
            *) agent_quota_die "unknown option: $1" ;;
        esac
    done
    command -v jq >/dev/null 2>&1 || agent_quota_die "jq not found in PATH"
    local doc
    doc="$(agent_quota_collect counts)"
    if [[ "$json" == true ]]; then
        jq . <<<"$doc"
        return 0
    fi
    jq -r '
        def utc: if . == null then "-" else todate end;
        def pct: if . == null then "-" else "\(. | floor)%" end;
        def short: if . == null then "-" else sub("\\.[0-9]+Z$"; "Z") end;
        def pad($n): tostring | . + ([range([$n - length, 0] | max)] | map(" ") | join(""));
        def line: "\(.[0] | pad(14)) \(.[1] | pad(7)) \(.[2] | pad(15)) \(.[3] | pad(21)) \(.[4] | pad(21)) \(.[5])";
        def row($name):
            if . == null then empty
            else [$name, (if .reset then "reset (was \(.used_percent | pct))" else (.used_percent | pct) end),
                  (.resets_at | utc)] end;
        (["PLAN", "WINDOW", "USED", "RESETS (UTC)", "AS OF (UTC)", "AGENTS"] | line),
        (.plans[] as $p
         | ($p.kind + (if $p.plan_type then " (\($p.plan_type))" else "" end)) as $plan
         | ([($p.windows.five_hour | row("5h")), ($p.windows.weekly | row("weekly"))]) as $rows
         | (if ($rows | length) == 0
            then [$plan, "-", "unknown", "-", "-", $p.agents]
            else ($rows[] | [$plan] + . + [($p.observed_at | short), $p.agents])
            end | line),
           (if $p.limit_reached then "  \($p.kind): limit reached: \($p.limit_reached.type) (as of \($p.limit_reached.observed_at | short)\(if $p.limit_reached.stale then ", may have cleared since" else "" end))" else empty end),
           (if $p.note then "  \($p.kind): \($p.note)" else empty end))
    ' <<<"$doc"
}

agent_quota_check() {
    local kind="" limit="$AGENT_QUOTA_LIMIT_DEFAULT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit) [[ $# -ge 2 ]] || agent_quota_die "--limit needs a value"; limit="$2"; shift 2 ;;
            -h|--help) agent_quota_usage; return 0 ;;
            -*) agent_quota_die "unknown check option: $1" ;;
            *) [[ -z "$kind" ]] || agent_quota_die "check takes one kind"; kind="$1"; shift ;;
        esac
    done
    [[ -n "$kind" ]] || agent_quota_die "check needs a kind (claude, codex, agy, ...)"
    [[ "$limit" =~ ^[0-9]{1,3}$ ]] && (( 10#$limit <= 100 )) || agent_quota_die "--limit takes a whole percent, 0-100: $limit"
    command -v jq >/dev/null 2>&1 || agent_quota_die "jq not found in PATH"
    limit=$((10#$limit))
    local verdict
    verdict="$(agent_quota_collect | jq -r --arg kind "$kind" --argjson limit "$limit" '
        (first(.plans[] | select(.kind == $kind)) // null) as $p
        | if $p == null then "ok"
          elif $p.limit_reached and ($p.limit_reached.stale | not) then "over\t\($kind): limit reached: \($p.limit_reached.type) (as of \($p.limit_reached.observed_at))"
          elif ($p.windows.five_hour // null) == null then "ok"
          elif $p.windows.five_hour.reset then "ok"
          elif $p.windows.five_hour.used_percent >= $limit
            then "over\t\($kind): 5-hour window \($p.windows.five_hour.used_percent | floor)% used (limit \($limit)%), resets \($p.windows.five_hour.resets_at | todate)"
          else "ok" end')"
    if [[ "$verdict" == over* ]]; then
        printf '%s\n' "${verdict#over$'\t'}" >&2
        return 1
    fi
    return 0
}

# statusLine command: never fails the status line, whatever it is handed.
agent_quota_record_claude() {
    local input dir tmp line
    input="$(cat)"
    command -v jq >/dev/null 2>&1 || return 0
    if jq -e '(.rate_limits | type) == "object"' >/dev/null 2>&1 <<<"$input"; then
        dir="$(agent_quota_state_dir)"
        if mkdir -p "$dir" 2>/dev/null && tmp="$(mktemp "$dir/.claude.json.XXXXXX" 2>/dev/null)"; then
            if jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{recorded_at: $at, rate_limits: {five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day}}' \
                <<<"$input" >"$tmp" 2>/dev/null; then
                mv -f "$tmp" "$dir/claude.json" 2>/dev/null || rm -f "$tmp"
            else
                rm -f "$tmp"
            fi
        fi
    fi
    line="$(jq -r '
        [(.model.display_name // empty),
         (.rate_limits.five_hour.used_percentage // empty | "5h \(floor)%"),
         (.rate_limits.seven_day.used_percentage // empty | "7d \(floor)%")] | join(" · ")' 2>/dev/null <<<"$input" || true)"
    printf '%s\n' "$line"
}

agent_quota_main() {
    local subcommand="${1:-show}"
    case "$subcommand" in
        --json) agent_quota_show "$@"; return ;;
    esac
    [[ $# -gt 0 ]] && shift
    case "$subcommand" in
        show) agent_quota_show "$@" ;;
        check) agent_quota_check "$@" ;;
        record-claude) agent_quota_record_claude "$@" ;;
        help|-h|--help) agent_quota_usage ;;
        *) agent_quota_usage >&2; return 2 ;;
    esac
}

agent_quota_main "$@"
