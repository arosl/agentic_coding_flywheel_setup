#!/usr/bin/env bash
# ============================================================
# ACFS nhm hook lines - register nhm-hook with Claude Code and Codex
#
# nhm (stack.nhm) learns who is in each herdr pane from hooks the agent
# CLIs run anyway, at no token cost (nhm plan-v8 2.7): PostToolUse on
# Agent Mail's registration tools names the pane, and SessionStart (and,
# for Codex, PostCompact) tells nhm that a session continued or changed.
# This file adds those hook lines. The command is the stable link
# ~/.local/bin/nhm-hook, so an nhm update never changes the lines.
#
# Registering is idempotent and appends only. Codex keys hook trust by an
# entry's position in hooks.json, so existing entries are never moved; an
# nhm entry with an older command is left where it is. Codex runs a new
# hook only after the user trusts it once in its /hooks screen.
#
# Usage:
#   nhm_hooks.sh register claude|codex [FILE]   (default ~/.claude/settings.json
#                                                or ~/.codex/hooks.json)
#   nhm_hooks.sh registered claude|codex FILE   (exit 0 if FILE has every line)
# ============================================================

set -uo pipefail

NHM_HOOKS_TIMEOUT_SECONDS=5
# The Agent Mail tools whose PostToolUse names the pane, as Claude Code
# and Codex name an MCP tool: mcp__<server>__<tool>.
NHM_HOOKS_REGISTRATION_MATCHER='^mcp__.+__(register_agent|create_agent_identity|macro_start_session)$'

nhm_hooks_usage() {
    cat <<'EOF'
Usage:
  nhm_hooks.sh register claude|codex [FILE]  Add the nhm-hook lines to FILE
                                             (default ~/.claude/settings.json
                                             or ~/.codex/hooks.json)
  nhm_hooks.sh registered claude|codex FILE  Exit 0 if FILE has every line
EOF
}

nhm_hooks_note() {
    printf 'nhm_hooks: %s\n' "$*" >&2
}

# The hook lines of a kind, one per line: <event>|<nhm-hook verb>|<matcher>.
# The matcher is last: it is a regular expression and may hold "|".
nhm_hooks_lines() {
    case "$1" in
        claude)
            printf '%s\n' \
                "PostToolUse|posttooluse|$NHM_HOOKS_REGISTRATION_MATCHER" \
                "SessionStart|sessionstart|"
            ;;
        codex)
            # Codex starts a session at its first turn and sends no
            # SessionStart after /compact; PostCompact is its cue.
            printf '%s\n' \
                "PostToolUse|posttooluse|$NHM_HOOKS_REGISTRATION_MATCHER" \
                "SessionStart|sessionstart|" \
                "PostCompact|sessionstart|"
            ;;
        *) return 2 ;;
    esac
}

# The jq program that appends one nhm hook line to an event, unless an
# entry under that event already runs nhm-hook with the same verb.
nhm_hooks_register_filter() {
    cat <<'JQ'
def ours: type == "object"
  and ((.command? // "") | type) == "string"
  and ((.command? // "") | test("(^|[[:space:]/])nhm-hook[[:space:]]+" + $verb + "([[:space:]]|$)"));
def entry: (if $matcher == "" then {} else {matcher: $matcher} end)
  + {hooks: [{type: "command", command: $cmd, timeout: $timeout}]};
if type != "object" then error("the file's top level is not a JSON object")
elif has("hooks") and (.hooks | type) != "object" then error("\"hooks\" is not a JSON object")
elif (.hooks? // {} | has($event)) and (.hooks[$event] | type) != "array" then error("\"hooks.\($event)\" is not an array")
elif ([(.hooks[$event] // [])[] | (.hooks? // []) | arrays | .[] | select(ours)] | length) > 0 then .
else .hooks[$event] = ((.hooks[$event] // []) + [entry])
end
JQ
}

nhm_hooks_command() {
    local verb="$1" bin_dir="${NHM_BIN_DIR:-$HOME/.local/bin}"
    printf '%s/nhm-hook %s' "$bin_dir" "$verb"
}

nhm_hooks_register() {
    local kind="${1:-}"
    local file="${2:-}"
    local target="" dir="" current="" updated="" tmp="" line="" event="" matcher="" verb="" cmd=""

    case "$kind" in
        claude) [[ -n "$file" ]] || file="$HOME/.claude/settings.json" ;;
        codex) [[ -n "$file" ]] || file="$HOME/.codex/hooks.json" ;;
        *) nhm_hooks_usage >&2; return 2 ;;
    esac
    command -v jq >/dev/null 2>&1 || { nhm_hooks_note "jq not found"; return 1; }
    # The command runs through a shell: keep the path free of anything it
    # would interpret.
    cmd="$(nhm_hooks_command posttooluse)"
    if [[ ! "${cmd% posttooluse}" =~ ^/[A-Za-z0-9._/+-]+$ ]]; then
        nhm_hooks_note "refusing to register: unsafe path ${cmd% posttooluse}"
        return 1
    fi

    # A dotfiles symlink is edited where it points, not replaced.
    target="$file"
    if [[ -L "$file" ]]; then
        target="$(readlink -f -- "$file")" || { nhm_hooks_note "cannot resolve $file"; return 1; }
    fi
    dir="$(dirname -- "$target")"
    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] || { nhm_hooks_note "$target is not a regular file"; return 1; }
        current="$(cat -- "$target")" || return 1
    fi
    [[ -n "${current//[[:space:]]/}" ]] || current='{}'

    updated="$current"
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        cmd="$(nhm_hooks_command "$verb")"
        # jq's stderr is kept apart, so nothing it prints can reach the file.
        if ! updated="$(jq --arg event "$event" --arg matcher "$matcher" --arg verb "$verb" --arg cmd "$cmd" \
                --argjson timeout "$NHM_HOOKS_TIMEOUT_SECONDS" \
                "$(nhm_hooks_register_filter)" <<<"$updated" 2>/dev/null)"; then
            nhm_hooks_note "left $file unchanged: it is not a hooks file jq can extend (see: jq . $file)"
            return 1
        fi
    done < <(nhm_hooks_lines "$kind")

    if [[ -e "$target" ]] && [[ "$(jq -c . <<<"$current")" == "$(jq -c . <<<"$updated")" ]]; then
        nhm_hooks_note "$file already has the nhm hook lines"
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
    line="added the nhm hook lines to $file"
    [[ "$kind" != codex ]] || line+="; trust them once in Codex's /hooks"
    nhm_hooks_note "$line"
}

nhm_hooks_registered() {
    local kind="${1:-}" file="${2:-}" event="" matcher="" verb=""

    [[ -f "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    nhm_hooks_lines "$kind" >/dev/null 2>&1 || return 2
    # shellcheck disable=SC2034 # matcher: registered checks the command only.
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        jq -e --arg event "$event" --arg verb "$verb" '
            [(.hooks?[$event]? // []) | arrays | .[] | (.hooks? // []) | arrays | .[]
              | select(type == "object" and ((.command? // "") | type) == "string"
                       and ((.command? // "") | test("(^|[[:space:]/])nhm-hook[[:space:]]+" + $verb + "([[:space:]]|$)")))]
            | length > 0
        ' "$file" >/dev/null 2>&1 || return 1
    done < <(nhm_hooks_lines "$kind")
    return 0
}

nhm_hooks_main() {
    local subcommand="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$subcommand" in
        register) nhm_hooks_register "$@" ;;
        registered) nhm_hooks_registered "$@" ;;
        -h|--help|help) nhm_hooks_usage ;;
        *) nhm_hooks_usage >&2; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nhm_hooks_main "$@"
fi
