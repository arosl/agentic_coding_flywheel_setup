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
# nhm entry with an older command is left where it is.
#
# Codex runs a hook only when config.toml holds its current trusted_hash.
# `trust codex` records that for ACFS's own nhm-hook entries, through
# Codex's own write path (plan-v8 F.25): `codex app-server` on stdio,
# hooks/list, then config/batchWrite with each entry's currentHash under
# hooks.state. It trusts no other entry. A Codex that cannot do that
# leaves the user's /hooks screen as the way.
#
# Usage:
#   nhm_hooks.sh register claude|codex [FILE]   (default ~/.claude/settings.json
#                                                or ~/.codex/hooks.json)
#   nhm_hooks.sh registered claude|codex FILE   (exit 0 if FILE has every line)
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
  nhm_hooks.sh register claude|codex [FILE]  Add the nhm-hook lines to FILE
                                             (default ~/.claude/settings.json
                                             or ~/.codex/hooks.json)
  nhm_hooks.sh registered claude|codex FILE  Exit 0 if FILE has every line
  nhm_hooks.sh trust codex [FILE] [--dry-run]
                                             Record Codex's trust for the
                                             nhm-hook entries of FILE
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
    [[ "$kind" != codex ]] || line+="; Codex runs them once trusted (nhm_hooks.sh trust codex, or Codex's /hooks)"
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


def ours():
    """The positions of the entries that are exactly what register writes."""
    with open(hooks_file, encoding="utf-8") as f:
        hooks = json.load(f).get("hooks", {})
    found = set()
    for want in spec:
        groups = hooks.get(want["event"])
        if want["event"] not in LABELS or not isinstance(groups, list):
            continue
        handler = {"type": "command", "command": want["command"], "timeout": want["timeout"]}
        for gi, group in enumerate(groups):
            if not isinstance(group, dict) or group.get("matcher", "") != want["matcher"]:
                continue
            if set(group) - {"matcher", "hooks"}:
                continue
            for hi, h in enumerate(group.get("hooks") or []):
                if h == handler:
                    found.add((LABELS[want["event"]], gi, hi))
    return found


real = os.path.realpath(hooks_file)
mine = ours()
if not mine:
    note(f"{hooks_file} has no nhm-hook entries that ACFS wrote")
    sys.exit(0)
proc = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, cwd=os.path.dirname(real), start_new_session=True)


def kill_group(sig):
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


killer = threading.Timer(float(os.environ.get("NHM_HOOKS_TRUST_TIMEOUT") or 60), kill_group, args=(signal.SIGKILL,))
killer.start()
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
    call("initialize", {"clientInfo": {"name": "acfs-nhm-hooks", "title": None, "version": "1"}, "capabilities": None})
    proc.stdin.write(json.dumps({"method": "initialized"}) + "\n")
    proc.stdin.flush()
    before = listed()
    todo = {k: {"trusted_hash": h["currentHash"]} for k, h in before.items()
            if h.get("trustStatus") in ("untrusted", "modified") and h.get("currentHash")}
    missing = len(mine) - len(before)
    if missing:
        note(f"Codex does not list {missing} nhm-hook entries of {hooks_file}")
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
            note(f"Codex trusts the {len(after)} nhm-hook entries of {hooks_file}" +
                 (f" ({len(todo)} newly)" if todo else ""))
            status = 0
except (RuntimeError, OSError, ValueError, KeyError) as e:
    note(f"could not record Codex's trust: {e}")
finally:
    killer.cancel()
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

# The JSON list of the Codex entries `register` writes:
# [{event, command, matcher, timeout}, ...].
nhm_hooks_codex_spec() {
    local event="" verb="" matcher="" spec="[]"
    while IFS='|' read -r event verb matcher; do
        [[ -n "$event" ]] || continue
        spec="$(jq -c --arg e "$event" --arg c "$(nhm_hooks_command "$verb")" --arg m "$matcher" \
            --argjson t "$NHM_HOOKS_TIMEOUT_SECONDS" '. + [{event: $e, command: $c, matcher: $m, timeout: $t}]' <<<"$spec")" || return 1
    done < <(nhm_hooks_lines codex)
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
        trust) nhm_hooks_trust "$@" ;;
        -h|--help|help) nhm_hooks_usage ;;
        *) nhm_hooks_usage >&2; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nhm_hooks_main "$@"
fi
