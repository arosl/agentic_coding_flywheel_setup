#!/usr/bin/env bash
# ============================================================
# ACFS palette - the command palette as an interactive menu, over herdr
#
# What `ntm palette` did, for agents in herdr. Pick a prompt from the
# command palette (fuzzy filter, categories, preview, pins, favorites,
# recents), optionally edit it or write a new one, then pick who gets it:
# every agent in the workspace, one kind, or single agents, each shown with
# its live herdr status and a preview of its screen. The send itself is
# `acfs agents send --template FILE` (herdr_agents.sh), so placeholders,
# skipping agents blocked at a dialog and the check that each prompt was
# submitted stay in one place.
#
# Inside herdr, prefix+a (ctrl+b, then a) opens it in a popup over the
# current tab, as ntm's F6 did in tmux: `acfs palette bind` writes that
# [[keys.command]] into herdr's config.toml (the installer and acfs update
# run `bind --auto`), and the
# popup's HERDR_ACTIVE_* variables say which workspace and directory it was
# opened over. Anywhere else, run `acfs palette`.
#
# Palette files, first key wins: --file (or ACFS_PALETTE_FILE) alone when
# given; otherwise ./command_palette.md in the current directory and at its
# git root, ~/.config/acfs/command_palette.md, then the installed
# ~/.acfs/onboard/docs/ntm/command_palette.md. Same format as that file:
#   ## Category
#   ### key | Label
#   prompt text
#
# Pins, favorites and recents live under ~/.local/state/acfs/palette/.
#
# Usage:
#   acfs palette [--workspace ID] [--file PATH]
#   acfs palette --list [--json] [--file PATH]
#   acfs palette --show KEY [--file PATH]
#   acfs palette bind [--key KEY] [--auto] [--no-reload] [--dry-run]
#   acfs palette unbind [--no-reload] [--dry-run]
#
# Needs fzf 0.44 or later (Ubuntu 24.04's), jq, and herdr for the targets.
# ============================================================

set -euo pipefail

# herdr runs a popup with the herdr server's environment, whose PATH may
# lack ~/.local/bin, where ACFS installs herdr (acfs-simw).
if [[ -n "${HOME:-}" && -d "$HOME/.local/bin" && ":${PATH:-}:" != *":$HOME/.local/bin:"* ]]; then
    PATH="$HOME/.local/bin:${PATH:-}"
fi

PALETTE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PALETTE_SELF="$PALETTE_SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PALETTE_AGENTS_SCRIPT="${ACFS_PALETTE_AGENTS_SCRIPT:-$PALETTE_SCRIPT_DIR/herdr_agents.sh}"
PALETTE_STATE_DIR="${ACFS_PALETTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acfs/palette}"
PALETTE_FZF="${ACFS_PALETTE_FZF:-fzf}"
PALETTE_RECENTS_MAX=8
# The order kinds are offered in on the target step; others follow, sorted.
PALETTE_KIND_ORDER=(claude codex gemini agy pi)
# herdr's config file and the block `bind` manages in it.
PALETTE_HERDR_CONFIG="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
PALETTE_DEFAULT_KEY="prefix+a"
PALETTE_BLOCK_BEGIN="# >>> acfs palette >>>"
PALETTE_BLOCK_END="# <<< acfs palette <<<"

palette_usage() {
    cat <<'EOF'
Usage:
  acfs palette [--workspace ID] [--file PATH]
  acfs palette --list [--json] [--file PATH]
  acfs palette --show KEY [--file PATH]
  acfs palette bind [--key KEY] [--auto] [--no-reload] [--dry-run]
  acfs palette unbind [--no-reload] [--dry-run]

Open the command palette: pick a prompt, then the agents in herdr that get it.
In herdr, prefix+a (ctrl+b, then a) opens it in a popup (see bind).

Prompt step:
  type          fuzzy-filter prompts by label, key or category
  enter         send the prompt as it is
  ctrl-e        edit it first (in $VISUAL or $EDITOR)
  ctrl-n        write a new message instead
  ctrl-p        pin or unpin it (pinned prompts come first)
  ctrl-f        mark or unmark it as a favorite
  ctrl-/        show or hide the preview
  esc           close

Target step:
  1-9           pick a group: every agent here, or one kind
  tab           mark several agents
  enter         send
  ctrl-r        refresh the agents' status
  esc           back to the prompts

The send is 'acfs agents send --template FILE': {{session}}, {{agent}},
{{herdr}} and {{thread}} are filled in per agent (the palette asks for the
thread), agents blocked at a dialog are skipped, and each prompt is checked
to have been submitted.

Options:
  --workspace ID   offer the agents of this herdr workspace (default: the
                   one the palette runs in; outside herdr, every workspace)
  --file PATH      read prompts from this file only
  --list           print the prompts (key, label, category, file) and exit
  --json           with --list, as JSON
  --show KEY       print one prompt's text and exit

Palette files, first key wins: ./command_palette.md (here and at the git
root), ~/.config/acfs/command_palette.md, ~/.acfs/onboard/docs/ntm/command_palette.md.

bind writes a herdr key that opens the palette in a popup (prefix+a, where
ntm's palette had F6 in tmux; --key takes herdr's key syntax, such as
prefix+space)
into herdr's config.toml ($HERDR_CONFIG_PATH, else ~/.config/herdr/config.toml),
between "# >>> acfs palette >>>" and "# <<< acfs palette <<<", then reloads
a running herdr server. It refuses a key the file already uses. --auto,
which the installer and acfs update run, changes nothing when the file has
that block (bound or unbound), binds the palette itself, or uses the key.
unbind leaves the block empty, so --auto never binds it again.

The key lives in the herdr server's config. A client attached from another
machine with 'herdr --remote' uses that machine's keys instead; attach with
'herdr --remote <host> --remote-keybindings server' to get prefix+a there.
EOF
}

palette_die() {
    printf 'acfs palette: %s\n' "$*" >&2
    exit 1
}

palette_note() {
    printf '%s\n' "$*" >&2
}

palette_require() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || palette_die "$tool not found in PATH"
    done
}

# ------------------------------------------------------------
# palette files and prompts
# ------------------------------------------------------------

# The directory the palette is opened for: a herdr popup runs in the
# focused pane's directory, which herdr also passes as HERDR_ACTIVE_PANE_CWD.
palette_cwd() {
    local dir="${ACFS_PALETTE_CWD:-${HERDR_ACTIVE_PANE_CWD:-$PWD}}"
    [[ -d "$dir" ]] || dir="$PWD"
    printf '%s\n' "$dir"
}

# The palette files to read, in order, one per line: each readable one,
# once (by its resolved path). This checkout's copy stands in for the
# installed one only where none is installed.
palette_sources() {
    if [[ -n "${ACFS_PALETTE_FILE:-}" ]]; then
        [[ -r "$ACFS_PALETTE_FILE" ]] || palette_die "palette file not readable: $ACFS_PALETTE_FILE"
        printf '%s\n' "$ACFS_PALETTE_FILE"
        return 0
    fi
    local cwd root="" candidate resolved shipped
    local -A seen=()
    cwd="$(palette_cwd)"
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    shipped="${ACFS_HOME:-$HOME/.acfs}/onboard/docs/ntm/command_palette.md"
    [[ -r "$shipped" ]] || shipped="$PALETTE_SCRIPT_DIR/../../acfs/onboard/docs/ntm/command_palette.md"
    for candidate in \
        "$cwd/command_palette.md" \
        ${root:+"$root/command_palette.md"} \
        "${XDG_CONFIG_HOME:-$HOME/.config}/acfs/command_palette.md" \
        "$shipped"; do
        [[ -f "$candidate" && -r "$candidate" ]] || continue
        resolved="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        [[ -z "${seen[$resolved]+set}" ]] || continue
        seen[$resolved]=1
        printf '%s\n' "$candidate"
    done
}

# Every prompt, one per line: key, label, category and file, tab-separated,
# in file order. A key already given by an earlier file is skipped.
palette_entries() {
    local -a files=()
    mapfile -t files < <(palette_sources)
    [[ ${#files[@]} -gt 0 ]] || return 0
    awk '
        FNR == 1 { category = "" }
        /^##[[:space:]]/ && !/^###/ {
            category = $0
            sub(/^##[[:space:]]+/, "", category)
            sub(/[[:space:]]+$/, "", category)
            next
        }
        /^###[[:space:]]/ {
            heading = $0
            sub(/^###[[:space:]]+/, "", heading)
            key = heading; label = heading
            if (index(heading, "|")) {
                sub(/[[:space:]]*\|.*$/, "", key)
                sub(/^[^|]*\|[[:space:]]*/, "", label)
            }
            sub(/[[:space:]]+$/, "", key)
            sub(/[[:space:]]+$/, "", label)
            if (key !~ /^[A-Za-z0-9_.-]+$/ || (key in seen)) next
            seen[key] = 1
            gsub(/\t/, " ", label); gsub(/\t/, " ", category)
            printf "%s\t%s\t%s\t%s\n", key, (label == "" ? key : label), (category == "" ? "Other" : category), FILENAME
        }
    ' "${files[@]}"
}

# The entry line for key $1, or nothing.
palette_entry() {
    palette_entries | awk -F '\t' -v key="$1" '$1 == key { print; exit }'
}

# The text of prompt $1 in file $2: the lines under its heading up to the
# next heading of any level, blank lines inside kept, leading and trailing
# ones dropped (as herdr_agents_palette_prompt reads it).
palette_text_in() {
    awk -v key="$1" '
        /^##/ {
            if (found) exit
            heading = $0
            if (sub(/^###[[:space:]]+/, "", heading)) {
                sub(/[[:space:]]*\|.*$/, "", heading)
                sub(/[[:space:]]+$/, "", heading)
                found = (heading == key)
            }
            next
        }
        found { lines[++n] = $0 }
        END {
            if (!found) exit 1
            first = 1; last = n
            while (first <= last && lines[first] !~ /[^[:space:]]/) first++
            while (last >= first && lines[last] !~ /[^[:space:]]/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    ' "$2"
}

# The text of prompt $1, from whichever file gives that key first.
palette_text() {
    local entry file
    entry="$(palette_entry "$1")"
    [[ -n "$entry" ]] || return 1
    file="$(cut -f4 <<<"$entry")"
    palette_text_in "$1" "$file"
}

# ------------------------------------------------------------
# pins, favorites and recents
# ------------------------------------------------------------

palette_state_file() {
    printf '%s/%s\n' "$PALETTE_STATE_DIR" "$1"
}

# The keys in state list $1 (pins, favorites or recents), one per line.
palette_state_list() {
    local file
    file="$(palette_state_file "$1")"
    [[ -r "$file" ]] || return 0
    grep -E '^[A-Za-z0-9_.-]+$' "$file" || true
}

# Replace state list $1 with stdin, atomically.
palette_state_write() {
    local file tmp
    file="$(palette_state_file "$1")"
    mkdir -p "$PALETTE_STATE_DIR"
    tmp="$(mktemp "$PALETTE_STATE_DIR/.$1.XXXXXX")"
    cat >"$tmp"
    mv -f "$tmp" "$file"
}

palette_state_has() {
    palette_state_list "$1" | grep -qxF -- "$2"
}

# Toggle key $2 in state list $1 (pins or favorites). A pinned prompt is a
# favorite too, as in ntm; unfavoriting one unpins it.
palette_toggle() {
    local list="$1" key="$2"
    [[ "$list" == pins || "$list" == favorites ]] || return 0
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
    if palette_state_has "$list" "$key"; then
        { palette_state_list "$list" | grep -vxF -- "$key" || true; } | palette_state_write "$list"
        if [[ "$list" == favorites ]] && palette_state_has pins "$key"; then
            { palette_state_list pins | grep -vxF -- "$key" || true; } | palette_state_write pins
        fi
    else
        { palette_state_list "$list"; printf '%s\n' "$key"; } | palette_state_write "$list"
        if [[ "$list" == pins ]] && ! palette_state_has favorites "$key"; then
            { palette_state_list favorites; printf '%s\n' "$key"; } | palette_state_write favorites
        fi
    fi
}

# Put key $1 first in recents, keeping the newest PALETTE_RECENTS_MAX.
palette_record_recent() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
    { printf '%s\n' "$1"; palette_state_list recents | grep -vxF -- "$1" || true; } \
        | head -n "$PALETTE_RECENTS_MAX" | palette_state_write recents
}

# ------------------------------------------------------------
# prompt step
# ------------------------------------------------------------

# The prompt step's rows: key, then what fzf shows. Pinned prompts first,
# then recent ones, then the rest by category, in file order.
palette_rows() {
    local entries pins favorites recents
    entries="$(palette_entries)"
    [[ -n "$entries" ]] || return 0
    pins="$(palette_state_list pins)"
    favorites="$(palette_state_list favorites)"
    recents="$(palette_state_list recents)"
    # The lists go in through the environment: mawk refuses a newline in -v.
    PALETTE_PINS="$pins" PALETTE_FAVORITES="$favorites" PALETTE_RECENTS="$recents" awk -F '\t' '
        function row(k, section, color,    mark) {
            mark = (k in pin) ? "\033[33m◆\033[0m" : ((k in fav) ? "\033[33m★\033[0m" : " ")
            printf "%s\t%s %s%-24.24s\033[0m \033[1m%s\033[0m  \033[2m%s\033[0m\n", k, mark, color, section, label[k], k
        }
        BEGIN {
            np = split(ENVIRON["PALETTE_PINS"], p, "\n"); for (i = 1; i <= np; i++) if (p[i] != "") pin[p[i]] = 1
            nf = split(ENVIRON["PALETTE_FAVORITES"], f, "\n"); for (i = 1; i <= nf; i++) if (f[i] != "") fav[f[i]] = 1
            nr = split(ENVIRON["PALETTE_RECENTS"], r, "\n")
        }
        { label[$1] = $2; category[$1] = $3; order[NR] = $1; n = NR }
        END {
            for (i = 1; i <= np; i++) if (p[i] in label) { row(p[i], "pinned", "\033[33m"); shown[p[i]] = 1 }
            for (i = 1; i <= nr; i++) if ((r[i] in label) && !(r[i] in shown)) { row(r[i], "recent", "\033[36m"); shown[r[i]] = 1 }
            for (i = 1; i <= n; i++) if (!(order[i] in shown)) row(order[i], category[order[i]], "\033[2m")
        }
    ' <<<"$entries"
}

# The prompt step's preview of key $1.
palette_preview() {
    local entry label category file text marks="" placeholders
    entry="$(palette_entry "$1")"
    [[ -n "$entry" ]] || { printf 'No prompt with key %s.\n' "$1"; return 0; }
    IFS=$'\t' read -r _ label category file <<<"$entry"
    text="$(palette_text_in "$1" "$file" || true)"
    palette_state_has pins "$1" && marks+=" pinned"
    palette_state_has favorites "$1" && marks+=" favorite"
    printf '\033[1m%s\033[0m\n' "$label"
    printf '\033[2m%s · %s%s\033[0m\n' "$category" "$1" "${marks:+ ·$marks}"
    printf '\033[2m%s\033[0m\n' "${file/#$HOME/\~}"
    placeholders="$(grep -o '{{[^{}]*}}' <<<"$text" | sort -u | tr '\n' ' ' || true)"
    [[ -z "$placeholders" ]] || printf '\033[2mfilled in per agent: %s\033[0m\n' "$placeholders"
    printf '\n%s\n' "$text"
}

# Run fzf for the prompt step. Prints the key pressed (empty for enter),
# then the chosen row. Returns fzf's status: 130 when closed with esc, 1
# when ctrl-e or ctrl-n was pressed with no prompt matching.
palette_pick_prompt() {
    local self_q header
    self_q="$(printf '%q' "$PALETTE_SELF")"
    header="enter send · ctrl-e edit first · ctrl-n new message · ctrl-p pin · ctrl-f favorite · ctrl-/ preview · esc close"
    palette_rows | SHELL="$(command -v bash)" "$PALETTE_FZF" \
        --ansi --delimiter=$'\t' --with-nth=2 \
        --layout=reverse --border=rounded --info=inline --tiebreak=index \
        --prompt='palette> ' --header="$header" \
        --expect=ctrl-e,ctrl-n --bind='enter:accept-non-empty' \
        --preview="bash $self_q __preview {1}" \
        --preview-window='right,55%,wrap,<110(down,45%,wrap)' \
        --bind="ctrl-p:execute-silent(bash $self_q __toggle pins {1})+reload(bash $self_q __rows)" \
        --bind="ctrl-f:execute-silent(bash $self_q __toggle favorites {1})+reload(bash $self_q __rows)" \
        --bind='ctrl-/:toggle-preview'
}

# Open $1 in the user's editor, on the palette's own terminal.
palette_edit_file() {
    local editor="${VISUAL:-${EDITOR:-}}"
    if [[ -z "$editor" ]]; then
        local candidate
        for candidate in nano vim vi; do
            command -v "$candidate" >/dev/null 2>&1 && { editor="$candidate"; break; }
        done
    fi
    [[ -n "$editor" ]] || { palette_note "no editor: set \$EDITOR"; return 1; }
    # $editor may carry arguments ("code --wait"), so it is split on purpose.
    # shellcheck disable=SC2086
    $editor "$1"
}

# ------------------------------------------------------------
# target step
# ------------------------------------------------------------

# The agents herdr lists, as a JSON array, in workspace $1 (all when empty).
palette_agents() {
    local out
    out="$(herdr agent list 2>/dev/null)" || { printf '[]\n'; return 0; }
    jq -c --arg ws "$1" '[.result.agents[]? | select($ws == "" or .workspace_id == $ws)]' <<<"$out" 2>/dev/null \
        || printf '[]\n'
}

# The kinds among agents $1, in PALETTE_KIND_ORDER, then the rest sorted.
palette_kinds() {
    local present kind
    present="$(jq -r '[.[].agent // empty] | unique[]' <<<"$1")"
    for kind in "${PALETTE_KIND_ORDER[@]}"; do
        grep -qxF -- "$kind" <<<"$present" && printf '%s\n' "$kind"
    done
    grep -vxF -f <(printf '%s\n' "${PALETTE_KIND_ORDER[@]}") <<<"$present" || true
}

# The target step's rows for workspace $1: type (group or agent), its id
# (all, kind:K, or a pane id), its herdr name ("-" for none: read splits a
# tab-separated line on runs of tabs, so no field may be empty), then what
# fzf shows. Groups come first and are numbered for their key.
palette_target_rows() {
    local ws="$1" agents kind n=1 count scope
    agents="$(palette_agents "$ws")"
    count="$(jq 'length' <<<"$agents")"
    scope="${ws:+in this workspace}"
    scope="${scope:-in every workspace}"
    printf 'group\tall\t-\t\033[1m%d\033[0m  every agent %s \033[2m(%d)\033[0m\n' "$n" "$scope" "$count"
    while IFS= read -r kind; do
        [[ -n "$kind" ]] || continue
        n=$((n + 1))
        printf 'group\tkind:%s\t-\t\033[1m%d\033[0m  every %s agent \033[2m(%d)\033[0m\n' "$kind" "$n" "$kind" \
            "$(jq --arg k "$kind" '[.[] | select(.agent == $k)] | length' <<<"$agents")"
    done < <(palette_kinds "$agents")
    # herdr can drop an agent's name (acfs-i7p), leaving "" or "-".
    jq -r '
        def icon:
            if . == "working" then "\u001b[33m● working\u001b[0m"
            elif . == "blocked" then "\u001b[31m▲ blocked\u001b[0m"
            elif . == "done" then "\u001b[32m✓ done   \u001b[0m"
            elif . == "idle" then "\u001b[2m○ idle   \u001b[0m"
            else "\u001b[2m? \(.)\u001b[0m" end;
        .[] | ((.name // "") | if . == "" then "-" else . end) as $name
        | ["agent", .pane_id, $name,
           "   \((.agent_status // "unknown") | icon)  \u001b[1m\(if $name == "-" then "(unnamed)" else $name end)\u001b[0m  \(.agent)  \u001b[2m\(.terminal_title_stripped // "" | .[0:60])\u001b[0m"]
        | @tsv' <<<"$agents"
}

# The target step's preview of row type $1, id $2, in workspace $3.
palette_target_preview() {
    local type="$1" id="$2" ws="$3" agents
    if [[ "$type" == agent ]]; then
        herdr agent read "$id" --source visible --lines 80 2>/dev/null || printf 'Cannot read pane %s.\n' "$id"
        return 0
    fi
    agents="$(palette_agents "$ws")"
    [[ "$id" == all ]] || agents="$(jq -c --arg k "${id#kind:}" '[.[] | select(.agent == $k)]' <<<"$agents")"
    jq -r '
        if length == 0 then "No agents."
        else .[] | ((.name // "") | if . == "" or . == "-" then "(unnamed)" else . end) as $name
             | "\(.agent_status // "unknown" | .[0:10] | . + (" " * (10 - length)))  \($name)  (\(.agent))" end' <<<"$agents"
    jq -e 'any(.[]; .agent_status == "blocked")' <<<"$agents" >/dev/null \
        && printf '\nBlocked agents are skipped: answer their dialog first.\n'
    jq -e 'any(.[]; (.name // "") | . == "" or . == "-")' <<<"$agents" >/dev/null \
        && printf '\nUnnamed agents get a prompt only through a group.\n'
    return 0
}

# Run fzf for the target step in workspace $1. Prints the chosen rows.
palette_pick_targets() {
    local ws="$1" self_q ws_q header i
    local -a digits=()
    self_q="$(printf '%q' "$PALETTE_SELF")"
    ws_q="$(printf '%q' "$ws")"
    for i in 1 2 3 4 5 6 7 8 9; do
        digits+=("--bind=$i:deselect-all+pos($i)+accept")
    done
    header="1-9 a group · tab mark agents · enter send · ctrl-r refresh · esc back"
    palette_target_rows "$ws" | SHELL="$(command -v bash)" "$PALETTE_FZF" \
        --ansi --delimiter=$'\t' --with-nth=4 \
        --multi --layout=reverse --border=rounded --info=inline --no-sort \
        --prompt='send to> ' --header="$header" --bind='enter:accept-non-empty' \
        --preview="bash $self_q __target-preview {1} {2} $ws_q" \
        --preview-window='right,55%,<110(down,45%)' \
        --bind="ctrl-r:reload(bash $self_q __target-rows $ws_q)" \
        --bind='ctrl-/:toggle-preview' \
        "${digits[@]}"
}

# The `acfs agents send` selection flags for target rows $2 (as fzf printed
# them) in workspace $1, one per line. One group row maps to --all or
# --kind; anything else is expanded to the agents' names, since send ANDs
# --kind with --name.
palette_send_flags() {
    local ws="$1" rows="$2" type id name agents
    local -a names=()
    if [[ "$(grep -c . <<<"$rows")" == 1 ]]; then
        IFS=$'\t' read -r type id _ <<<"$rows"
        if [[ "$type" == group ]]; then
            [[ -z "$ws" ]] || printf -- '--workspace\n%s\n' "$ws"
            if [[ "$id" == all ]]; then
                printf -- '--all\n'
            else
                printf -- '--kind\n%s\n' "${id#kind:}"
            fi
            return 0
        fi
    fi
    agents="$(palette_agents "$ws")"
    while IFS=$'\t' read -r type id name _; do
        case "$type" in
            group)
                mapfile -t -O "${#names[@]}" names < <(jq -r --arg id "$id" '
                    .[] | select($id == "all" or "kind:\(.agent)" == $id) | .name // empty | select(. != "-")' <<<"$agents")
                ;;
            agent)
                if [[ -n "$name" && "$name" != "-" ]]; then
                    names+=("$name")
                else
                    palette_note "skipped pane $id: it has no herdr name (send it through a group)"
                fi
                ;;
        esac
    done <<<"$rows"
    [[ ${#names[@]} -gt 0 ]] || return 1
    [[ -z "$ws" ]] || printf -- '--workspace\n%s\n' "$ws"
    printf '%s\n' "${names[@]}" | sort -u | while IFS= read -r name; do
        printf -- '--name\n%s\n' "$name"
    done
}

# ------------------------------------------------------------
# herdr key: bind and unbind
# ------------------------------------------------------------

# Config file $1 without the block `bind` manages.
palette_config_outside_block() {
    [[ -f "$1" ]] || return 0
    awk -v begin="$PALETTE_BLOCK_BEGIN" -v end="$PALETTE_BLOCK_END" '
        index($0, begin) == 1 { inside = 1; next }
        inside && index($0, end) == 1 { inside = 0; next }
        !inside { print }
    ' "$1"
}

palette_config_has_block() {
    [[ -f "$1" ]] && grep -qF -- "$PALETTE_BLOCK_BEGIN" "$1"
}

# Whether config file $1 has a begin marker with no end marker after it.
# Rewriting such a file would drop everything after the begin marker.
palette_config_block_unterminated() {
    [[ -f "$1" ]] || return 1
    awk -v begin="$PALETTE_BLOCK_BEGIN" -v end="$PALETTE_BLOCK_END" '
        index($0, begin) == 1 { inside = 1; next }
        inside && index($0, end) == 1 { inside = 0 }
        END { exit !inside }
    ' "$1"
}

# Whether config file $1, outside the block, assigns key $2 to anything
# (`key = "prefix+a"` in a [[keys.command]], `zoom = "prefix+a"` or
# `zoom = ["prefix+a", ...]`
# in [keys], over one line or several), ignoring case: any quoted value
# that is exactly the key.
palette_config_uses_key() {
    palette_config_outside_block "$1" | awk -v want="$2" '
        /^[[:space:]]*#/ { next }
        {
            line = tolower($0)
            # The value side of `name = value`; an array line has no name.
            if (match(line, /^[[:space:]]*[a-z0-9_."-]+[[:space:]]*=/)) line = substr(line, RLENGTH + 1)
            while (match(line, /"[^"]*"/)) {
                if (substr(line, RSTART + 1, RLENGTH - 2) == want) found = 1
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END { exit !found }'
}

# Whether config file $1, outside the block, already runs the palette.
palette_config_binds_palette() {
    palette_config_outside_block "$1" \
        | grep -qE '^[[:space:]]*command[[:space:]]*=.*(acfs palette|palette\.sh)'
}

# The command the popup runs: this script, by its absolute path, so the
# popup needs nothing on the herdr server's PATH. A path TOML would need
# escaping for falls back to `acfs palette`.
palette_popup_command() {
    if [[ "$PALETTE_SELF" =~ ^/[A-Za-z0-9_./+-]+$ ]]; then
        printf "bash '%s'\n" "$PALETTE_SELF"
    else
        printf 'acfs palette\n'
    fi
}

# The managed block binding key $1, or the unbound block for an empty $1.
palette_block() {
    if [[ -z "$1" ]]; then
        printf '%s unbound by `acfs palette unbind`; `acfs palette bind` binds it again\n' "$PALETTE_BLOCK_BEGIN"
    else
        printf '%s managed by `acfs palette bind`; `acfs palette unbind` removes it\n' "$PALETTE_BLOCK_BEGIN"
        printf '[[keys.command]]\n'
        printf 'key = "%s"\n' "$1"
        printf 'type = "popup"\n'
        printf 'command = "%s"\n' "$(palette_popup_command)"
        printf 'description = "command palette (acfs palette)"\n'
        printf 'width = "90%%"\n'
        printf 'height = "80%%"\n'
    fi
    printf '%s\n' "$PALETTE_BLOCK_END"
}

# What `herdr config check` reports for config file $1, one issue per line:
# empty when herdr finds none.
palette_config_issues() {
    HERDR_CONFIG_PATH="$1" herdr config check 2>&1 | grep -vxF -e 'config: ok' -e 'config: issues found' || true
}

# Replace config file $1 with the file outside the block plus block $2.
# A symlinked config is written through: its target changes, keeping its
# mode, and the link stays. When herdr is installed it checks the result
# first: any issue it reports that the old file didn't have (the key
# conflicting with another binding, a parse error that would make herdr
# ignore the whole file) leaves the file as it was.
palette_config_write() {
    local file="$1" block="$2" dir tmp outside before after added
    if [[ -L "$file" ]]; then
        file="$(readlink -f -- "$file")" || palette_die "can't resolve the symlink $1"
    fi
    if palette_config_block_unterminated "$file"; then
        palette_die "$file has '$PALETTE_BLOCK_BEGIN' with no '$PALETTE_BLOCK_END' after it; fix the block by hand first"
    fi
    dir="$(dirname "$file")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.config.toml.acfs-palette.XXXXXX")"
    outside="$(palette_config_outside_block "$file")"
    # Drop the trailing blank lines, then one blank line before the block.
    outside="$(printf '%s\n' "$outside" | awk 'NF { for (; blank > 0; blank--) print ""; print; next } { blank++ }')"
    { [[ -z "$outside" ]] || printf '%s\n\n' "$outside"; printf '%s\n' "$block"; } >"$tmp"
    if [[ -f "$file" ]]; then
        chmod "$(stat -L -c '%a' "$file" 2>/dev/null || stat -L -f '%Lp' "$file" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null || true
    fi
    if command -v herdr >/dev/null 2>&1; then
        before=""
        [[ ! -f "$file" ]] || before="$(palette_config_issues "$file")"
        after="$(palette_config_issues "$tmp")"
        added="$(grep -vxF -f <(printf '%s\n' "$before") <<<"$after" || true)"
        if [[ -n "$added" ]]; then
            rm -f "$tmp"
            palette_die "herdr would not accept the new $file, so it is unchanged: $(printf '%s' "$added" | tr '\n' ' ')"
        fi
    fi
    mv -f "$tmp" "$file"
}

# Where a herdr client on another machine gets the key from.
palette_remote_note() {
    palette_note "a client attached with 'herdr --remote' uses its own machine's keys; attach with 'herdr --remote <host> --remote-keybindings server' to get $1 there"
}

# Ask a running herdr server to read its config again.
palette_reload() {
    if command -v herdr >/dev/null 2>&1 && herdr server reload-config >/dev/null 2>&1; then
        palette_note "reloaded the running herdr server's config"
    else
        palette_note "herdr reads it when its server next starts (or run: herdr server reload-config)"
    fi
}

palette_bind() {
    local key="$PALETTE_DEFAULT_KEY" auto=false reload=true dry_run=false file="$PALETTE_HERDR_CONFIG" block
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key) [[ $# -ge 2 && -n "$2" ]] || palette_die "--key needs a key, such as prefix+a or prefix+space"; key="${2,,}"; shift 2 ;;
            --auto) auto=true; shift ;;
            --no-reload) reload=false; shift ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) palette_usage; return 0 ;;
            *) palette_die "unknown bind option: $1" ;;
        esac
    done
    [[ "$key" =~ ^[a-z0-9+.-]+$ ]] || palette_die "--key $key: not a herdr key (such as prefix+a, ctrl+space or prefix+space)"

    if [[ "$auto" == true ]]; then
        if ! command -v herdr >/dev/null 2>&1; then
            palette_note "herdr is not installed; no palette key bound"
            return 0
        fi
        if palette_config_has_block "$file"; then
            palette_note "herdr's config already has the palette's block; left as it is"
            return 0
        fi
        if palette_config_binds_palette "$file"; then
            palette_note "herdr's config already opens the palette; left as it is"
            return 0
        fi
        if palette_config_uses_key "$file" "$key"; then
            palette_note "herdr's config already uses $key; no palette key bound (pick one: acfs palette bind --key KEY)"
            return 0
        fi
    else
        if palette_config_binds_palette "$file"; then
            palette_die "$file already opens the palette outside the acfs palette block; remove that binding first"
        fi
        if palette_config_uses_key "$file" "$key"; then
            palette_die "$file already uses $key; pick another with --key"
        fi
    fi

    block="$(palette_block "$key")"
    if [[ "$dry_run" == true ]]; then
        printf 'Would write to %s:\n%s\n' "$file" "$block"
        return 0
    fi
    palette_config_write "$file" "$block"
    palette_note "bound $key to the command palette in $file"
    palette_remote_note "$key"
    [[ "$reload" == false ]] || palette_reload
}

palette_unbind() {
    local reload=true dry_run=false file="$PALETTE_HERDR_CONFIG"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-reload) reload=false; shift ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) palette_usage; return 0 ;;
            *) palette_die "unknown unbind option: $1" ;;
        esac
    done
    if [[ "$dry_run" == true ]]; then
        printf 'Would write to %s:\n%s\n' "$file" "$(palette_block "")"
        return 0
    fi
    palette_config_write "$file" "$(palette_block "")"
    palette_note "unbound the command palette's key in $file; acfs update leaves it unbound"
    [[ "$reload" == false ]] || palette_reload
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

# Send the text in file $1 to target rows $3 of workspace $2, through
# `acfs agents send --template`. Asks for the thread when the text needs
# one. Returns send's status.
palette_send() {
    local file="$1" ws="$2" rows="$3" thread=""
    local -a flags=() args=()
    mapfile -t flags < <(palette_send_flags "$ws" "$rows") || true
    if [[ ${#flags[@]} -eq 0 ]]; then
        palette_note "no agent to send to"
        return 1
    fi
    args=(send "${flags[@]}" --template "$file")
    if grep -qF '{{thread}}' "$file"; then
        read -r -p "Thread for {{thread}} (a bead id, e.g. acfs-123): " thread || true
        [[ -n "$thread" ]] || { palette_note "no thread given; nothing sent"; return 1; }
        args+=(--thread "$thread")
    fi
    bash "$PALETTE_AGENTS_SCRIPT" "${args[@]}"
}

palette_interactive() {
    local ws="$1" picked action key entry text_file rows status reply
    palette_require "$PALETTE_FZF" jq herdr
    [[ -r "$PALETTE_AGENTS_SCRIPT" ]] || palette_die "herdr_agents.sh not found beside palette.sh (run acfs update)"
    [[ -n "$(palette_entries | head -n 1)" ]] || palette_die "no palette prompts found (see 'acfs palette --help' for the files it reads)"
    text_file="$(mktemp "${TMPDIR:-/tmp}/acfs-palette.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f $(printf '%q' "$text_file")" EXIT

    while true; do
        status=0
        picked="$(palette_pick_prompt)" || status=$?
        # 1: ctrl-e or ctrl-n with nothing matching; anything else is a close.
        (( status == 0 || status == 1 )) || return 0
        action="$(sed -n 1p <<<"$picked")"
        key="$(sed -n 2p <<<"$picked" | cut -f1)"
        case "$action" in
            ctrl-n)
                : >"$text_file"
                palette_edit_file "$text_file" || continue
                key=""
                ;;
            *)
                [[ -n "$key" ]] || continue
                entry="$(palette_entry "$key")"
                [[ -n "$entry" ]] || continue
                palette_text_in "$key" "$(cut -f4 <<<"$entry")" >"$text_file" || continue
                if [[ "$action" == ctrl-e ]]; then
                    palette_edit_file "$text_file" || continue
                fi
                ;;
        esac
        if ! grep -q '[^[:space:]]' "$text_file"; then
            palette_note "empty prompt; nothing sent"
            continue
        fi

        rows="$(palette_pick_targets "$ws")" || continue
        [[ -n "$rows" ]] || continue
        status=0
        palette_send "$text_file" "$ws" "$rows" || status=$?
        if [[ -n "$key" ]] && (( status == 0 )); then
            palette_record_recent "$key"
        fi
        printf '\nenter: back to the palette · any other key: close ' >&2
        IFS= read -r -s -n 1 reply || reply="q"
        printf '\n' >&2
        [[ -z "$reply" ]] || return "$status"
    done
}

palette_main() {
    local mode="interactive" json=false key="" workspace="" workspace_set=false
    case "${1:-}" in
        bind) shift; palette_bind "$@"; return 0 ;;
        unbind) shift; palette_unbind "$@"; return 0 ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || palette_die "--workspace needs a value"; workspace="$2"; workspace_set=true; shift 2 ;;
            --file)
                [[ $# -ge 2 && -n "$2" ]] || palette_die "--file needs a path"
                [[ -f "$2" && -r "$2" ]] || palette_die "--file $2: no such readable file"
                ACFS_PALETTE_FILE="$(readlink -f "$2")"
                export ACFS_PALETTE_FILE
                shift 2
                ;;
            --list) mode="list"; shift ;;
            --json) json=true; shift ;;
            --show) [[ $# -ge 2 && -n "$2" ]] || palette_die "--show needs a key"; mode="show"; key="$2"; shift 2 ;;
            -h|--help|help) palette_usage; return 0 ;;
            # Internal: fzf's reload, preview and bind commands call back in.
            __rows) palette_rows; return 0 ;;
            __preview) palette_preview "${2:-}"; return 0 ;;
            __toggle) palette_toggle "${2:-}" "${3:-}"; return 0 ;;
            __target-rows) palette_target_rows "${2:-}"; return 0 ;;
            __target-preview) palette_target_preview "${2:-}" "${3:-}" "${4:-}"; return 0 ;;
            *) palette_die "unknown option: $1 (see 'acfs palette --help')" ;;
        esac
    done
    # fzf's callbacks run in new processes: they read the same files.
    export ACFS_PALETTE_CWD
    ACFS_PALETTE_CWD="$(palette_cwd)"

    case "$mode" in
        list)
            palette_require jq
            if [[ "$json" == true ]]; then
                palette_entries | jq -R -s -c '
                    [split("\n")[] | select(length > 0) | split("\t")
                     | {key: .[0], label: .[1], category: .[2], file: .[3]}]'
            else
                palette_entries
            fi
            ;;
        show)
            palette_text "$key" || palette_die "no palette prompt has the key $key"
            ;;
        interactive)
            [[ -t 0 && -t 1 ]] || [[ "${ACFS_PALETTE_ASSUME_TTY:-}" == 1 ]] \
                || palette_die "needs a terminal; use --list, --show KEY, or 'acfs agents send --template KEY'"
            if [[ "$workspace_set" == false ]]; then
                workspace="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
            fi
            palette_interactive "$workspace"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    palette_main "$@"
fi
