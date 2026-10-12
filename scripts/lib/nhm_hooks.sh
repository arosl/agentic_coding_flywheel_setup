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
# entry's position in hooks.json, so existing entries are never moved.
# ACFS never edits a hook group that holds a handler of the user's; an
# nhm-hook handler inside such a group stays, and the doctor names it.
#
# Codex runs a hook only when config.toml holds its current trusted_hash.
# `trust codex` records that for ACFS's own entries (the nhm-hook lines,
# and dcg's Bash guard: codex-dcg below), through
# Codex's own write path (plan-v8 F.25): `codex app-server` on stdio,
# hooks/list, then config/batchWrite with each entry's currentHash under
# hooks.state. It trusts no other entry. A Codex that cannot do that
# leaves the user's /hooks screen as the way.
#
# Usage:
#   nhm_hooks.sh register claude|codex [FILE]   (default ~/.claude/settings.json
#                                                or ~/.codex/hooks.json)
#   nhm_hooks.sh registered claude|codex FILE   (exit 0 if FILE has every line
#                                                exact; 3 if register must
#                                                upgrade an older nhm line)
#   nhm_hooks.sh unregister claude|codex [FILE] (remove ACFS's exact lines;
#                                                Codex: trailing ones only)
#   nhm_hooks.sh stray claude|codex FILE        (list nhm-hook handlers inside
#                                                the user's own hook groups,
#                                                and duplicate ACFS lines)
#   nhm_hooks.sh trust codex [FILE] [--dry-run] (FILE is $CODEX_HOME/hooks.json;
#                                                default ~/.codex/hooks.json)
# ============================================================

set -uo pipefail

NHM_HOOKS_TIMEOUT_SECONDS=5
# The Agent Mail tools whose PostToolUse names the pane, as Claude Code
# and Codex name an MCP tool: mcp__<server>__<tool>.
NHM_HOOKS_REGISTRATION_MATCHER='^mcp__.+__(register_agent|create_agent_identity|macro_start_session)$'

nhm_hooks_usage() {
    cat <<'EOF'
Usage:
  nhm_hooks.sh codex-dcg register|registered|unregister [FILE]
                                             dcg's Bash guard line in Codex's
                                             hooks.json (stack.dcg), as dcg's
                                             installer writes it; registered:
                                             0 there, 3 a dcg at another path,
                                             1 missing
  nhm_hooks.sh register claude|codex [FILE]  Add the nhm-hook lines to FILE
                                             (default ~/.claude/settings.json
                                             or ~/.codex/hooks.json)
  nhm_hooks.sh registered claude|codex FILE  Exit 0 if FILE has every line exact,
                                             3 if an older nhm line needs register
  nhm_hooks.sh unregister claude|codex [FILE]
                                             Remove the lines register wrote
                                             (Codex: only those no other
                                             entry follows)
  nhm_hooks.sh stray claude|codex FILE       Print "<event> <group> <handler>
                                             <kind> <runs>" for each nhm-hook
                                             handler inside your own hook
                                             groups (kind user-group) and each
                                             second copy of ACFS's line
                                             (duplicate); runs: twice or once
  nhm_hooks.sh trust codex [FILE] [--dry-run]
                                             Record Codex's trust for ACFS's
                                             entries of FILE: the nhm-hook
                                             lines and dcg's Bash guard
                                             (default ~/.codex/hooks.json)
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

# The jq definitions that register, registered, stray and unregister
# share. The rule (acfs-9hkh.53): ACFS never edits a group that holds a
# handler of the user's.
#
# - ACFS's line for an event is exact: a group that is exactly what
#   register writes, {matcher?, hooks: [{type, command, timeout}]}, and
#   nothing else. That is what registered, trust and the doctor count.
# - An nhm handler is one whose command is one of ACFS's own install
#   paths for the verb ($known: ~/.local/bin/nhm-hook and
#   $NHM_BIN_DIR/nhm-hook, the only paths ACFS ever wrote), with any
#   timeout. A path the user chose is the user's.
# - A pure group is ACFS's own: the line's matcher, no other key, and
#   only nhm handlers. register may rewrite it; unregister may remove it.
# - A stray is an nhm handler inside any other group: the user's group.
#   It stays as it is; the doctor names it.
nhm_hooks_jq_defs() {
    cat <<'JQ'
def nhmish: type == "object" and ((.type // "command") == "command")
  and ((.command? // null) | type) == "string" and (.command as $c | $known | index($c) != null);
def handler: {type: "command", command: $cmd, timeout: $timeout};
def entry: (if $matcher == "" then {} else {matcher: $matcher} end) + {hooks: [handler]};
def group_fits: type == "object" and ((.matcher // "") == $matcher) and ((keys - ["matcher", "hooks"]) | length) == 0;
def pure: group_fits and (.hooks | type) == "array" and (.hooks | length) > 0 and all(.hooks[]; nhmish);
def groups: (.hooks?[$event]? // []) | arrays | to_entries[];
def exact_at: [groups | select(.value == entry) | .key];
def older_at: [groups | select(.value != entry and (.value | pure)) | .key];
def stray_at: [groups | .key as $gi | .value | select(type == "object" and (.hooks | type) == "array" and (pure | not))
    | .hooks | to_entries[] | select(.value | nhmish) | [$gi, .key]];
def duplicate_at: exact_at[1:];
JQ
}

# The jq program that makes ACFS's line for one event exact. It keeps an
# exact line as it is. It rewrites a pure group in place (an older
# timeout, or the other known path), so Codex's position-keyed trust then
# trusts the same position. Otherwise it appends the exact line; a stray
# nhm handler inside the user's group stays untouched.
nhm_hooks_register_filter() {
    nhm_hooks_jq_defs
    cat <<'JQ'
if type != "object" then error("the file's top level is not a JSON object")
elif has("hooks") and (.hooks | type) != "object" then error("\"hooks\" is not a JSON object")
elif (.hooks? // {} | has($event)) and (.hooks[$event] | type) != "array" then error("\"hooks.\($event)\" is not an array")
elif (exact_at | length) > 0 then .
elif (older_at | length) > 0 then .hooks[$event][older_at[0]] = entry
else .hooks[$event] = ((.hooks[$event] // []) + [entry])
end
JQ
}

# The JSON list of ACFS's own command lines for a verb: the paths an ACFS
# release ever wrote.
nhm_hooks_known() {
    local verb="$1"
    jq -cn --arg a "$HOME/.local/bin/nhm-hook $verb" --arg b "$(nhm_hooks_command "$verb")" '[$a, $b] | unique'
}

nhm_hooks_command() {
    local verb="$1" bin_dir="${NHM_BIN_DIR:-$HOME/.local/bin}"
    printf '%s/nhm-hook %s' "$bin_dir" "$verb"
}

# Replace TARGET with CONTENT through a temp file beside it, keeping
# TARGET's mode (settings files are often 0600); a new file is 0600.
nhm_hooks_write() {
    local target="$1" content="$2" tmp=""
    tmp="$(mktemp "$target.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$content" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ -e "$target" ]]; then
        chmod --reference="$target" "$tmp" 2>/dev/null || true
    else
        chmod 0600 "$tmp" 2>/dev/null || true
    fi
    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

nhm_hooks_register() {
    local kind="${1:-}"
    local file="${2:-}"
    local target="" dir="" current="" updated="" line="" event="" matcher="" verb="" cmd=""

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
        if ! updated="$(jq --arg event "$event" --arg matcher "$matcher" --arg cmd "$cmd" \
                --argjson timeout "$NHM_HOOKS_TIMEOUT_SECONDS" --argjson known "$(nhm_hooks_known "$verb")" \
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
    nhm_hooks_write "$target" "$updated" || return 1
    line="added the nhm hook lines to $file"
    [[ "$kind" != codex ]] || line+="; Codex runs them once trusted (nhm_hooks.sh trust codex, or Codex's /hooks)"
    nhm_hooks_note "$line"
}

# registered: exit 0 when every line of the kind is exact (as trust and
# the doctor count it); 3 when a line exists only as a pure group that
# `register` rewrites in place; 1 when a line is missing (register
# appends it; a stray in the user's group does not count).
nhm_hooks_registered() {
    local kind="${1:-}" file="${2:-}" event="" matcher="" verb="" state="" upgrade=false

    [[ -f "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    nhm_hooks_lines "$kind" >/dev/null 2>&1 || return 2
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        state="$(jq -r --arg event "$event" --arg matcher "$matcher" \
            --arg cmd "$(nhm_hooks_command "$verb")" --argjson timeout "$NHM_HOOKS_TIMEOUT_SECONDS" \
            --argjson known "$(nhm_hooks_known "$verb")" "$(nhm_hooks_jq_defs)"'
            if (exact_at | length) > 0 then "exact" elif (older_at | length) > 0 then "older" else "missing" end
        ' "$file" 2>/dev/null)" || return 1
        case "$state" in
            exact) ;;
            older) upgrade=true ;;
            *) return 1 ;;
        esac
    done < <(nhm_hooks_lines "$kind")
    [[ "$upgrade" == false ]] || return 3
    return 0
}

# The jq program that removes ACFS's own groups for one event: exact
# lines and pure groups (nhm_hooks_jq_defs), nothing else. A group that
# holds a handler of the user's is never edited, so a stray nhm handler in
# it stays. For Codex it removes only trailing groups, since Codex keys
# trust by position and removing one would move every entry after it.
# With $count it prints "<ACFS groups left> <strays>" instead.
nhm_hooks_unregister_filter() {
    nhm_hooks_jq_defs
    cat <<'JQ'
def ours: . == entry or pure;
def drop_trailing: if length > 0 and (.[-1] | ours) then .[:-1] | drop_trailing else . end;
if type != "object" or ((.hooks? // {}) | type) != "object" or ((.hooks? // {})[$event] | type) != "array"
then (if $count then "0 0" else . end)
elif $count then "\([.hooks[$event][] | select(ours)] | length) \(stray_at | length)"
else .hooks[$event] |= (if $codex then drop_trailing else map(select(ours | not)) end)
  | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
end
JQ
}

# unregister claude|codex [FILE]: remove ACFS's nhm-hook lines, for when
# nhm-hook is gone and the lines would point at nothing in every turn.
nhm_hooks_unregister() {
    local kind="${1:-}" file="${2:-}"
    local target="" current="" updated="" event="" matcher="" verb="" cmd="" known="" counts=""
    local left=0 strays=0 n=0 s=0 is_codex=false

    case "$kind" in
        claude) [[ -n "$file" ]] || file="$HOME/.claude/settings.json" ;;
        codex) [[ -n "$file" ]] || file="$HOME/.codex/hooks.json"; is_codex=true ;;
        *) nhm_hooks_usage >&2; return 2 ;;
    esac
    command -v jq >/dev/null 2>&1 || { nhm_hooks_note "jq not found"; return 1; }
    target="$file"
    if [[ -L "$file" ]]; then
        target="$(readlink -f -- "$file")" || { nhm_hooks_note "cannot resolve $file"; return 1; }
    fi
    [[ -e "$target" ]] || return 0
    [[ -f "$target" ]] || { nhm_hooks_note "$target is not a regular file"; return 1; }
    current="$(cat -- "$target")" || return 1
    [[ -n "${current//[[:space:]]/}" ]] || return 0

    updated="$current"
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        cmd="$(nhm_hooks_command "$verb")"
        known="$(nhm_hooks_known "$verb")"
        if ! updated="$(jq --arg event "$event" --arg matcher "$matcher" --arg cmd "$cmd" \
                --argjson timeout "$NHM_HOOKS_TIMEOUT_SECONDS" --argjson known "$known" \
                --argjson codex "$is_codex" --argjson count false \
                "$(nhm_hooks_unregister_filter)" <<<"$updated" 2>/dev/null)"; then
            nhm_hooks_note "left $file unchanged: jq cannot read it (see: jq . $file)"
            return 1
        fi
        counts="$(jq -r --arg event "$event" --arg matcher "$matcher" --arg cmd "$cmd" \
                --argjson timeout "$NHM_HOOKS_TIMEOUT_SECONDS" --argjson known "$known" \
                --argjson codex "$is_codex" --argjson count true \
                "$(nhm_hooks_unregister_filter)" <<<"$updated" 2>/dev/null)" || counts="0 0"
        read -r n s <<<"$counts"
        left=$((left + ${n:-0}))
        strays=$((strays + ${s:-0}))
    done < <(nhm_hooks_lines "$kind")

    if [[ "$(jq -c . <<<"$current")" != "$(jq -c . <<<"$updated")" ]]; then
        nhm_hooks_write "$target" "$updated" || return 1
        nhm_hooks_note "removed the nhm hook lines from $file"
    fi
    if (( left > 0 )); then
        nhm_hooks_note "left $left nhm hook lines in $file: other entries follow them, and Codex keys trust by position, so removing them would untrust those entries"
    fi
    if (( strays > 0 )); then
        nhm_hooks_note "left $strays nhm-hook handler(s) inside your own hook groups in $file: ACFS never edits your groups; remove them by hand"
    fi
    return 0
}

# stray claude|codex FILE: print "<event> <group> <handler> <kind> <runs>"
# (positions from 0) for each nhm handler that runs besides ACFS's one exact
# line: kind "user-group", inside a group of the user's (nhm_hooks_jq_defs),
# or "duplicate", a second exact group (only a hand edit makes one). runs
# is "twice" when ACFS's exact line is there too, else "once". ACFS never
# edits the user's group; the doctor names each one, to be removed by hand.
nhm_hooks_stray() {
    local kind="${1:-}" file="${2:-}" event="" matcher="" verb=""

    nhm_hooks_lines "$kind" >/dev/null 2>&1 || { nhm_hooks_usage >&2; return 2; }
    [[ -f "$file" ]] || return 0
    command -v jq >/dev/null 2>&1 || { nhm_hooks_note "jq not found"; return 1; }
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        jq -r --arg event "$event" --arg matcher "$matcher" --arg cmd "$(nhm_hooks_command "$verb")" \
            --argjson timeout "$NHM_HOOKS_TIMEOUT_SECONDS" --argjson known "$(nhm_hooks_known "$verb")" \
            "$(nhm_hooks_jq_defs)"'
            if (.hooks? | type) == "object" and (.hooks[$event] | type) == "array"
            then (if (exact_at | length) > 0 then "twice" else "once" end) as $runs
              | (stray_at[] | "\($event) \(.[0]) \(.[1]) user-group \($runs)"),
                (duplicate_at[] | "\($event) \(.) 0 duplicate twice")
            else empty end
        ' "$file" 2>/dev/null || { nhm_hooks_note "cannot read $file"; return 1; }
    done < <(nhm_hooks_lines "$kind")
}

# ---- dcg's Bash guard in Codex's hooks.json (stack.dcg; acfs-9hkh.81) ----
#
# dcg runs as a Codex PreToolUse hook (Codex 0.125+), but `dcg install`
# configures Claude Code only. dcg's own installer (the verified installer
# stack.dcg runs) merges the line into $HOME/.codex/hooks.json when it
# finds codex: matcher "Bash", one handler {type: "command", command:
# "$HOME/.local/bin/dcg"} with no timeout, dcg first among the Bash
# handlers, and its "already there" test compares that exact command. So
# ACFS's line is byte for byte dcg's: otherwise the two would each add
# one, dcg would run twice, and every update would move entries and lose
# Codex's position-keyed trust.
#
# - registered: 0 when a Bash group's first handler is exactly that line
#   (dcg's form, which may sit in a group of the user's); 3 when only a
#   dcg at another path guards Bash (the user's; ACFS adds no second);
#   1 when no dcg guards Bash.
# - register: appends a pure group only when no dcg guards Bash; it never
#   edits a group that holds another handler.
# - unregister: for when dcg is gone; removes only trailing pure groups
#   (Codex keys trust by position).
# - trust codex records the line's trust with the nhm-hook entries'.

nhm_hooks_dcg_command() {
    printf '%s/.local/bin/dcg' "$HOME"
}

# jq definitions of the dcg line ($cmd: its command).
nhm_hooks_dcg_jq_defs() {
    cat <<'JQ'
def dcg_handler: {type: "command", command: $cmd};
def dcg_entry: {matcher: "Bash", hooks: [dcg_handler]};
def pre: (.hooks?.PreToolUse? // []) | arrays;
def bash_group: type == "object" and .matcher == "Bash" and (.hooks | type) == "array";
def is_dcg: type == "object" and ((.command? // null) | type) == "string"
  and ((.command | split(" ")[0] | split("/") | last) == "dcg");
def ours_at: [pre | to_entries[] | select((.value | bash_group) and (.value.hooks[0]? == dcg_handler)) | .key];
def any_dcg: [pre[] | select(bash_group) | .hooks[] | select(is_dcg)] | length > 0;
JQ
}

nhm_hooks_codex_dcg() {
    local verb="${1:-}" file="${2:-}" target="" current="" updated="" cmd="" state=""
    [[ -n "$file" ]] || file="${CODEX_HOME:-$HOME/.codex}/hooks.json"
    command -v jq >/dev/null 2>&1 || { nhm_hooks_note "jq not found"; return 1; }
    cmd="$(nhm_hooks_dcg_command)"
    target="$file"
    if [[ -L "$file" ]]; then
        target="$(readlink -f -- "$file")" || { nhm_hooks_note "cannot resolve $file"; return 1; }
    fi
    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] || { nhm_hooks_note "$target is not a regular file"; return 1; }
        current="$(cat -- "$target")" || return 1
    fi
    [[ -n "${current//[[:space:]]/}" ]] || current='{}'
    case "$verb" in
        registered)
            [[ -e "$target" ]] || return 1
            state="$(jq -r --arg cmd "$cmd" "$(nhm_hooks_dcg_jq_defs)"'
                if (ours_at | length) > 0 then "exact" elif any_dcg then "other" else "missing" end
            ' <<<"$current" 2>/dev/null)" || return 1
            case "$state" in
                exact) return 0 ;;
                other) return 3 ;;
                *) return 1 ;;
            esac
            ;;
        register)
            [[ "$cmd" =~ ^/[A-Za-z0-9._/+-]+$ ]] || { nhm_hooks_note "refusing to register: unsafe path $cmd"; return 1; }
            [[ -x "$cmd" ]] || { nhm_hooks_note "no dcg at $cmd: install dcg first"; return 1; }
            if ! updated="$(jq --arg cmd "$cmd" "$(nhm_hooks_dcg_jq_defs)"'
                if type != "object" then error("the top level is not a JSON object")
                elif has("hooks") and (.hooks | type) != "object" then error("\"hooks\" is not a JSON object")
                elif (.hooks? // {} | has("PreToolUse")) and (.hooks.PreToolUse | type) != "array" then error("\"hooks.PreToolUse\" is not an array")
                elif any_dcg then .
                else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [dcg_entry])
                end
            ' <<<"$current" 2>/dev/null)"; then
                nhm_hooks_note "left $file unchanged: it is not a hooks file jq can extend (see: jq . $file)"
                return 1
            fi
            if [[ -e "$target" ]] && [[ "$(jq -c . <<<"$current")" == "$(jq -c . <<<"$updated")" ]]; then
                nhm_hooks_note "$file already has dcg's Bash guard"
                return 0
            fi
            mkdir -p -- "$(dirname -- "$target")" || return 1
            nhm_hooks_write "$target" "$updated" || return 1
            nhm_hooks_note "added dcg's Bash guard to $file; Codex runs it once trusted (nhm_hooks.sh trust codex, or Codex's /hooks)"
            ;;
        unregister)
            [[ -e "$target" ]] || return 0
            if ! updated="$(jq --arg cmd "$cmd" "$(nhm_hooks_dcg_jq_defs)"'
                def drop_trailing: if length > 0 and (.[-1] == dcg_entry) then .[:-1] | drop_trailing else . end;
                if type != "object" or ((.hooks? // {}) | type) != "object" or ((.hooks? // {}).PreToolUse | type) != "array" then .
                else .hooks.PreToolUse |= drop_trailing
                  | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
                end
            ' <<<"$current" 2>/dev/null)"; then
                nhm_hooks_note "left $file unchanged: jq cannot read it (see: jq . $file)"
                return 1
            fi
            if [[ "$(jq -c . <<<"$current")" != "$(jq -c . <<<"$updated")" ]]; then
                nhm_hooks_write "$target" "$updated" || return 1
                nhm_hooks_note "removed dcg's Bash guard from $file"
            fi
            if [[ "$(jq -r --arg cmd "$cmd" "$(nhm_hooks_dcg_jq_defs)"'ours_at | length' <<<"$updated" 2>/dev/null)" != 0 ]]; then
                nhm_hooks_note "left dcg's Bash guard in $file: other entries follow it, or it shares a group with your handlers"
            fi
            ;;
        *) nhm_hooks_usage >&2; return 2 ;;
    esac
}

# The app-server driver of `trust codex`. Arguments: the hooks file, the
# codex binary, "dry-run" or "write", and the JSON list of the entries
# `register` writes ({event, command, matcher, timeout}). It talks
# JSON-RPC lines to `codex app-server` (as Codex's TUI does), trusts only
# the entries that are exactly what `register` writes (an entry the user
# edited, or a user line that mentions nhm-hook, is not ACFS's), and
# checks with a second hooks/list that every one of them is trusted.
# The app-server runs in a session of its own and is killed as a process
# group: ACFS's codex is a wrapper whose child holds stdout open.
# Exit 0: every ACFS entry is trusted (or would be, with dry-run); 1: not.
nhm_hooks_trust_driver() {
    cat <<'PY'
import json, os, signal, subprocess, sys, threading

hooks_file, codex, mode, spec = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
LABELS = {"PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use", "SessionStart": "session_start",
          "PostCompact": "post_compact", "PreCompact": "pre_compact", "Stop": "stop",
          "UserPromptSubmit": "user_prompt_submit", "SessionEnd": "session_end"}


def note(msg):
    print("nhm_hooks: " + msg, file=sys.stderr)


class HooksFileError(ValueError):
    """The hooks file cannot be read as a JSON object."""


def ours():
    """The positions of the entries that are exactly what register writes."""
    try:
        with open(hooks_file, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise HooksFileError(f"cannot read {hooks_file}: {e}") from None
    if not isinstance(data, dict):
        raise HooksFileError(f"{hooks_file}: the top level is not a JSON object")
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        return set()
    found = set()
    for want in spec:
        groups = hooks.get(want["event"])
        if want["event"] not in LABELS or not isinstance(groups, list):
            continue
        if want.get("first"):
            # dcg's Bash guard: the first handler of a Bash group, exactly
            # as dcg's installer writes it (it may share the group with
            # handlers of the user's, which stay untrusted).
            handler = {"type": "command", "command": want["command"]}
            for gi, group in enumerate(groups):
                if (isinstance(group, dict) and group.get("matcher") == want["matcher"]
                        and isinstance(group.get("hooks"), list) and group["hooks"][:1] == [handler]):
                    found.add((LABELS[want["event"]], gi, 0))
            continue
        handler = {"type": "command", "command": want["command"], "timeout": want["timeout"]}
        entry = {"hooks": [handler]}
        if want["matcher"]:
            entry["matcher"] = want["matcher"]
        # Only a group that is exactly what register writes: a group that
        # holds a handler of the user's is the user's (acfs-9hkh.53).
        for gi, group in enumerate(groups):
            if group == entry:
                found.add((LABELS[want["event"]], gi, 0))
    return found


def on_signal(signum, _frame):
    # The caller's `timeout` sends SIGTERM to its own process group, which
    # the app-server (a session of its own) is not in. Exit through the
    # finally below, which kills the app-server's group.
    sys.exit(128 + signum)


for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(sig, on_signal)

real = os.path.realpath(hooks_file)
try:
    mine = ours()
except HooksFileError as e:
    note(str(e))
    sys.exit(1)
if not mine:
    note(f"{hooks_file} has no nhm-hook entries that ACFS wrote, and no dcg Bash guard")
    sys.exit(0)
proc = None
killer = None


def kill_group(sig):
    if proc is None:
        return
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


seq = [0]


def call(method, params):
    seq[0] += 1
    rid = seq[0]
    proc.stdin.write(json.dumps({"id": rid, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(f"codex app-server ended during {method}")
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == rid:
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg.get("result") or {}


def listed():
    out = {}
    for entry in call("hooks/list", {"cwds": [os.path.dirname(real)]}).get("data", []):
        for h in entry.get("hooks", []):
            path, label, gi, hi = (h.get("key", "").rsplit(":", 3) + ["", "", "", ""])[:4]
            if not (gi.isdigit() and hi.isdigit()) or os.path.realpath(path) != real:
                continue
            if (label, int(gi), int(hi)) in mine:
                out[h["key"]] = h
    return out


status = 1
try:
    proc = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, cwd=os.path.dirname(real), start_new_session=True)
    killer = threading.Timer(float(os.environ.get("NHM_HOOKS_TRUST_TIMEOUT") or 60), kill_group, args=(signal.SIGKILL,))
    killer.start()
    call("initialize", {"clientInfo": {"name": "acfs-nhm-hooks", "title": None, "version": "1"}, "capabilities": None})
    proc.stdin.write(json.dumps({"method": "initialized"}) + "\n")
    proc.stdin.flush()
    before = listed()
    todo = {k: {"trusted_hash": h["currentHash"]} for k, h in before.items()
            if h.get("trustStatus") in ("untrusted", "modified") and h.get("currentHash")}
    missing = len(mine) - len(before)
    if missing:
        note(f"Codex does not list {missing} ACFS entries of {hooks_file}")
    if mode == "dry-run":
        for k in sorted(todo):
            note("would trust " + k)
        status = 0 if not missing else 1
    else:
        if todo:
            call("config/batchWrite", {"edits": [{"keyPath": "hooks.state", "value": todo, "mergeStrategy": "upsert"}],
                                       "filePath": None, "expectedVersion": None, "reloadUserConfig": True})
        after = listed()
        untrusted = sorted(k for k, h in after.items() if h.get("trustStatus") != "trusted")
        if untrusted or len(after) != len(mine):
            note("not trusted: " + ", ".join(untrusted or [f"Codex lists {len(after)} of the {len(mine)} ACFS entries"]))
        else:
            note(f"Codex trusts the {len(after)} ACFS entries of {hooks_file}" +
                 (f" ({len(todo)} newly)" if todo else ""))
            status = 0
except (RuntimeError, OSError, ValueError, KeyError) as e:
    note(f"could not record Codex's trust: {e}")
finally:
    # A second signal must not cut the cleanup short.
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)
    if killer is not None:
        killer.cancel()
    if proc is not None:
        try:
            proc.stdin.close()
        except OSError:
            pass
        kill_group(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        kill_group(signal.SIGKILL)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
sys.exit(status)
PY
}

# The JSON list of ACFS's Codex entries, the ones `trust codex` trusts:
# [{event, command, matcher, timeout, first?}, ...]. first: dcg's Bash
# guard, the first handler of a Bash group (codex-dcg).
nhm_hooks_codex_spec() {
    local event="" verb="" matcher="" spec="[]"
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        spec="$(jq -c --arg e "$event" --arg c "$(nhm_hooks_command "$verb")" --arg m "$matcher" \
            --argjson t "$NHM_HOOKS_TIMEOUT_SECONDS" '. + [{event: $e, command: $c, matcher: $m, timeout: $t}]' <<<"$spec")" || return 1
    done < <(nhm_hooks_lines codex)
    # dcg's Bash guard (codex-dcg): trusted where the file holds it.
    spec="$(jq -c --arg c "$(nhm_hooks_dcg_command)" \
        '. + [{event: "PreToolUse", command: $c, matcher: "Bash", timeout: null, first: true}]' <<<"$spec")" || return 1
    printf '%s\n' "$spec"
}

# trust codex [FILE] [--dry-run]: record Codex's trust for the nhm-hook
# entries of FILE through Codex's app-server. FILE must be the user layer's
# hooks.json, $CODEX_HOME/hooks.json; the app-server runs with CODEX_HOME
# set to FILE's directory, so it reads that file and writes that
# config.toml.
nhm_hooks_trust() {
    local kind="${1:-}" file="" dry_run=false arg="" codex_bin="" target="" spec=""
    [[ "$kind" == codex ]] || { nhm_hooks_usage >&2; return 2; }
    shift
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            -*) nhm_hooks_usage >&2; return 2 ;;
            *) [[ -z "$file" ]] || { nhm_hooks_usage >&2; return 2; }; file="$arg" ;;
        esac
    done
    [[ -n "$file" ]] || file="${CODEX_HOME:-$HOME/.codex}/hooks.json"
    [[ -f "$file" ]] || { nhm_hooks_note "$file does not exist: register first"; return 1; }
    command -v python3 >/dev/null 2>&1 || { nhm_hooks_note "python3 not found; trust the nhm hook lines in Codex's /hooks"; return 1; }
    command -v jq >/dev/null 2>&1 || { nhm_hooks_note "jq not found"; return 1; }
    codex_bin="$(command -v codex 2>/dev/null)" || { nhm_hooks_note "codex not found"; return 1; }
    target="$(readlink -f -- "$file")" || { nhm_hooks_note "cannot resolve $file"; return 1; }
    spec="$(nhm_hooks_codex_spec)" || return 1
    # -I: isolated mode, so no json.py in the caller's directory (acfs
    # update's) is imported in place of the standard library's.
    CODEX_HOME="$(dirname -- "$target")" python3 -I -c "$(nhm_hooks_trust_driver)" \
        "$target" "$codex_bin" "$([[ "$dry_run" == true ]] && echo dry-run || echo write)" "$spec" </dev/null
}

nhm_hooks_main() {
    local subcommand="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$subcommand" in
        register) nhm_hooks_register "$@" ;;
        registered) nhm_hooks_registered "$@" ;;
        unregister) nhm_hooks_unregister "$@" ;;
        stray) nhm_hooks_stray "$@" ;;
        trust) nhm_hooks_trust "$@" ;;
        codex-dcg) nhm_hooks_codex_dcg "$@" ;;
        -h|--help|help) nhm_hooks_usage ;;
        *) nhm_hooks_usage >&2; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nhm_hooks_main "$@"
fi
