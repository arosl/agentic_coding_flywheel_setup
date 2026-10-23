#!/usr/bin/env bash
# ============================================================
# ACFS Agent Mail Stop hook - read mail before going idle
#
# An agent sees Agent Mail only when something prompts it. This is the
# Stop hook that Claude Code and Codex run when a turn ends: if the agent
# has unread Agent Mail it hasn't been told about yet, the hook answers
# {"decision":"block","reason":...}, and both tools then continue the turn
# with that reason as the next prompt. Otherwise it prints nothing.
#
# The hook fails open: no jq, no am, an unknown agent, Agent Mail down or
# any error lets the agent stop. It tells an agent about a given message
# once: it keeps the highest message id it has reported per agent and
# project under ~/.acfs/state/agent_mail_hook/, so an agent that leaves a
# message unread isn't sent back on every turn.
#
# Who the agent is: AGENT_MAIL_AGENT, then AGENT_NAME (the variables `am`
# reads), then nhm's binding for the agent's herdr pane, then the label of
# the pane's herdr tab, but only when the agent is alone in that tab. The
# pane is HERDR_PANE_ID, or, for a hook run outside the pane (Codex's
# app-server daemon), the pane of the herdr agent whose session is the
# hook's session_id. The project is AGENT_MAIL_PROJECT, then the git top
# level of the hook's cwd, then the cwd itself.
#
# Usage:
#   agent_mail_hook.sh stop                         (the hook; JSON on stdin)
#   agent_mail_hook.sh register claude|codex [FILE] (add the hook, idempotent)
#   agent_mail_hook.sh registered FILE              (exit 0 if FILE has it)
# ============================================================

set -uo pipefail

AGENT_MAIL_HOOK_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# Agent Mail names are adjective+noun in CamelCase (IcyKnoll).
AGENT_MAIL_HOOK_NAME_PATTERN='^[A-Z][a-z]+[A-Z][a-z]+$'
# How a registered entry is recognised, wherever this file is installed.
AGENT_MAIL_HOOK_COMMAND_PATTERN='(^|[[:space:]/])agent_mail_hook\.sh[[:space:]]+stop([[:space:]]|$)'
AGENT_MAIL_HOOK_TIMEOUT_SECONDS=10

agent_mail_hook_usage() {
    cat <<'EOF'
Usage:
  agent_mail_hook.sh stop                          Stop hook: JSON event on stdin
  agent_mail_hook.sh register claude|codex [FILE]  Add the Stop hook to FILE
                                                   (default ~/.claude/settings.json
                                                   or ~/.codex/hooks.json)
  agent_mail_hook.sh registered FILE               Exit 0 if FILE has the hook
EOF
}

agent_mail_hook_note() {
    printf 'agent_mail_hook: %s\n' "$*" >&2
}

# The Agent Mail name of the agent whose turn ended, or nothing. In order:
# AGENT_MAIL_AGENT or AGENT_NAME; nhm's active binding for the agent's
# pane (HERDR_PANE_ID, or for a hook run outside the pane, Codex's
# app-server daemon, the pane of the herdr agent whose session is the
# hook's session_id); then the label of the pane's tab, but only for an
# agent alone in its tab. Several agents share a tab when nhm or a swarm
# put them there, and the label names only one of them; the others would
# read its inbox and write its state file (acfs-ja4l).
agent_mail_hook_agent_name() {
    local session_id="${1:-}"
    local name="${AGENT_MAIL_AGENT:-${AGENT_NAME:-}}"
    local pane_id="${HERDR_PANE_ID:-}" tab_id="${HERDR_TAB_ID:-}"
    local agents="" agents_read=false count=""

    # The name also names the state file, so it must be an Agent Mail name
    # wherever it comes from.
    if [[ -n "$name" ]]; then
        [[ "$name" =~ $AGENT_MAIL_HOOK_NAME_PATTERN ]] || return 1
        printf '%s\n' "$name"
        return 0
    fi
    if [[ -z "$pane_id" && -n "$session_id" ]] && command -v herdr >/dev/null 2>&1; then
        agents="$(timeout 2 herdr agent list 2>/dev/null)" || agents=""
        agents_read=true
        pane_id="$(jq -r --arg s "$session_id" \
            '[.result.agents[]? | select(.agent_session.value? == $s) | .pane_id] | first // empty' <<<"$agents" 2>/dev/null)"
    fi
    if [[ -n "$pane_id" ]] && command -v nhm >/dev/null 2>&1; then
        name="$(timeout 1 nhm resolve "$pane_id" --json 2>/dev/null \
            | jq -r '.result.binding? // {} | select(.status == "active") | .mail_name // empty' 2>/dev/null)"
        if [[ -n "$name" ]]; then
            [[ "$name" =~ $AGENT_MAIL_HOOK_NAME_PATTERN ]] || return 1
            printf '%s\n' "$name"
            return 0
        fi
    fi

    # The tab's label, for an agent alone in its tab.
    command -v herdr >/dev/null 2>&1 || return 1
    if [[ "$agents_read" == false ]]; then
        agents="$(timeout 2 herdr agent list 2>/dev/null)" || agents=""
    fi
    if [[ -z "$tab_id" && -n "$pane_id" ]]; then
        tab_id="$(jq -r --arg p "$pane_id" \
            '[.result.agents[]? | select(.pane_id == $p) | .tab_id] | first // empty' <<<"$agents" 2>/dev/null)"
    fi
    [[ -n "$tab_id" ]] || return 1
    count="$(jq -r --arg t "$tab_id" '[.result.agents[]? | select(.tab_id == $t)] | length' <<<"$agents" 2>/dev/null)"
    [[ "$count" == 1 ]] || return 1
    name="$(timeout 1 herdr tab get "$tab_id" 2>/dev/null | jq -r '.result.tab.label // empty' 2>/dev/null)"
    [[ "$name" =~ $AGENT_MAIL_HOOK_NAME_PATTERN ]] || return 1
    printf '%s\n' "$name"
}

agent_mail_hook_project() {
    local cwd="${1:-}"
    local top=""

    if [[ -n "${AGENT_MAIL_PROJECT:-}" ]]; then
        printf '%s\n' "$AGENT_MAIL_PROJECT"
        return 0
    fi
    [[ "$cwd" == /* && -d "$cwd" ]] || return 1
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || top=""
    printf '%s\n' "${top:-$cwd}"
}

agent_mail_hook_stop() {
    local event="" stop_hook_active="" session_id="" cwd=""
    local agent="" project="" inbox="" unread=0 newest=0 reported=0
    local state_dir="" state_file="" key=""

    command -v jq >/dev/null 2>&1 || return 0
    command -v am >/dev/null 2>&1 || return 0
    event="$(cat)" || return 0
    stop_hook_active="$(jq -r '.stop_hook_active // false' <<<"$event" 2>/dev/null)" || return 0
    # A turn this hook already continued may stop: it was told once.
    [[ "$stop_hook_active" != true ]] || return 0
    session_id="$(jq -r '.session_id // empty' <<<"$event" 2>/dev/null)" || session_id=""
    cwd="$(jq -r '.cwd // empty' <<<"$event" 2>/dev/null)" || cwd=""
    [[ -n "$cwd" ]] || cwd="$PWD"

    agent="$(agent_mail_hook_agent_name "$session_id")" || return 0
    [[ -n "$agent" ]] || return 0
    project="$(agent_mail_hook_project "$cwd")" || return 0

    # 2 (agent list) + 1 (nhm) + 1 (tab get) + 5 seconds at worst stays
    # inside the registered 10 s timeout.
    inbox="$(timeout 5 am check-inbox --agent "$agent" --project "$project" --rate-limit 0 --json 2>/dev/null)" || return 0
    [[ -n "$inbox" ]] || return 0
    unread="$(jq -r '.unread_count // 0 | floor' <<<"$inbox" 2>/dev/null)" || return 0
    newest="$(jq -r '[.messages[]?.id | numbers] | max // 0' <<<"$inbox" 2>/dev/null)" || return 0
    [[ "$unread" =~ ^[0-9]+$ && "$newest" =~ ^[0-9]+$ ]] || return 0
    (( unread > 0 && newest > 0 )) || return 0

    state_dir="$HOME/.acfs/state/agent_mail_hook"
    key="$(printf '%s' "$project" | cksum | cut -d' ' -f1)"
    state_file="$state_dir/$agent.$key"
    if [[ -f "$state_file" ]]; then
        reported="$(head -n1 "$state_file" 2>/dev/null)"
        [[ "$reported" =~ ^[0-9]+$ ]] || reported=0
    fi
    (( newest > reported )) || return 0
    mkdir -p "$state_dir" 2>/dev/null && printf '%s\n' "$newest" >"$state_file" 2>/dev/null || return 0

    local noun="messages"
    (( unread != 1 )) || noun="message"
    jq -cn --arg reason "You have $unread unread Agent Mail $noun; read them before you stop." \
        '{decision: "block", reason: $reason}'
}

# The jq program that adds this hook's Stop entry to a Claude Code
# settings.json or a Codex hooks.json (both use the same "hooks" shape).
# An entry already registered with the same command is left as it is, so
# a second run changes nothing; one with another command (an older install
# path) is replaced.
agent_mail_hook_register_filter() {
    cat <<'JQ'
def ours: type == "object"
  and ((.command? // "") | type) == "string"
  and ((.command? // "") | test($pattern));
def entry: {hooks: [{type: "command", command: $cmd, timeout: $timeout}]};
if type != "object" then error("the file's top level is not a JSON object")
elif has("hooks") and (.hooks | type) != "object" then error("\"hooks\" is not a JSON object")
elif (.hooks? // {} | has("Stop")) and (.hooks.Stop | type) != "array" then error("\"hooks.Stop\" is not an array")
else
  [(.hooks.Stop // [])[] | (.hooks? // []) | arrays | .[] | select(ours)] as $found
  | if ($found | length) == 1 and $found[0].command == $cmd then .
    else
      .hooks.Stop = (
        [(.hooks.Stop // [])[]
          | if type == "object" and (.hooks | type) == "array"
            then .hooks |= map(select(ours | not)) else . end
          | select(type != "object" or (.hooks | type) != "array" or (.hooks | length) > 0)]
        + [entry])
    end
end
JQ
}

agent_mail_hook_register() {
    local kind="${1:-}"
    local file="${2:-}"
    local target="" dir="" current="" updated="" tmp="" cmd=""

    case "$kind" in
        claude) [[ -n "$file" ]] || file="$HOME/.claude/settings.json" ;;
        codex) [[ -n "$file" ]] || file="$HOME/.codex/hooks.json" ;;
        *) agent_mail_hook_usage >&2; return 2 ;;
    esac
    command -v jq >/dev/null 2>&1 || { agent_mail_hook_note "jq not found"; return 1; }
    # The command runs through a shell: keep the path free of anything it
    # would interpret.
    if [[ ! "$AGENT_MAIL_HOOK_SELF" =~ ^/[A-Za-z0-9._/+-]+$ ]]; then
        agent_mail_hook_note "refusing to register: unsafe path $AGENT_MAIL_HOOK_SELF"
        return 1
    fi
    cmd="bash $AGENT_MAIL_HOOK_SELF stop"

    # A dotfiles symlink is edited where it points, not replaced.
    target="$file"
    if [[ -L "$file" ]]; then
        target="$(readlink -f -- "$file")" || { agent_mail_hook_note "cannot resolve $file"; return 1; }
    fi
    dir="$(dirname -- "$target")"
    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] || { agent_mail_hook_note "$target is not a regular file"; return 1; }
        current="$(cat -- "$target")" || return 1
    fi
    [[ -n "${current//[[:space:]]/}" ]] || current='{}'

    # jq's stderr is kept apart, so nothing it prints can reach the file.
    local jq_error=""
    if ! updated="$(jq --arg cmd "$cmd" --arg pattern "$AGENT_MAIL_HOOK_COMMAND_PATTERN" \
            --argjson timeout "$AGENT_MAIL_HOOK_TIMEOUT_SECONDS" \
            "$(agent_mail_hook_register_filter)" <<<"$current" 2>/dev/null)"; then
        jq_error="$(jq --arg cmd "$cmd" --arg pattern "$AGENT_MAIL_HOOK_COMMAND_PATTERN" \
            --argjson timeout "$AGENT_MAIL_HOOK_TIMEOUT_SECONDS" \
            "$(agent_mail_hook_register_filter)" <<<"$current" 2>&1 >/dev/null)"
        agent_mail_hook_note "left $file unchanged: ${jq_error##*: }"
        return 1
    fi
    if [[ -e "$target" ]] && [[ "$(jq -c . <<<"$current")" == "$(jq -c . <<<"$updated")" ]]; then
        agent_mail_hook_note "$file already has the Agent Mail Stop hook"
        return 0
    fi

    mkdir -p -- "$dir" || return 1
    tmp="$(mktemp "$target.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$updated" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    # Keep the file's mode (settings files are often 0600).
    if [[ -e "$target" ]]; then
        chmod --reference="$target" "$tmp" 2>/dev/null || true
    else
        chmod 0600 "$tmp" 2>/dev/null || true
    fi
    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    agent_mail_hook_note "added the Agent Mail Stop hook to $file"
}

agent_mail_hook_registered() {
    local file="${1:-}"

    [[ -f "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg pattern "$AGENT_MAIL_HOOK_COMMAND_PATTERN" '
        [(.hooks?.Stop? // []) | arrays | .[] | (.hooks? // []) | arrays | .[]
          | select(type == "object" and ((.command? // "") | type) == "string"
                   and ((.command? // "") | test($pattern)))] | length > 0
    ' "$file" >/dev/null 2>&1
}

agent_mail_hook_main() {
    local subcommand="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$subcommand" in
        stop) agent_mail_hook_stop; return 0 ;;
        register) agent_mail_hook_register "$@" ;;
        registered) agent_mail_hook_registered "$@" ;;
        -h|--help|help) agent_mail_hook_usage ;;
        *) agent_mail_hook_usage >&2; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    agent_mail_hook_main "$@"
fi
