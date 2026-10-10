#!/usr/bin/env bash
# ============================================================
# ACFS herdr agents - spawn, prompt and list coding agents in herdr
#
# What ntm spawn/send did, over herdr 0.9's own commands. herdr has no
# multi-agent spawn and no broadcast: each agent is a tab plus
# `herdr agent start`, and a broadcast is a loop over `herdr agent list`
# and `herdr agent prompt`. This wraps exactly that and keeps no state.
#
# Names come from Agent Mail first (`am agents create`); the herdr name is
# that name lowercased, and the tab label is the Agent Mail name.
#
# Usage:
#   acfs agents spawn [--claude N] [--codex N] [--agy N] [--kind K [--count N]]...
#   acfs agents send (--all | --kind K | --name N)... <prompt>
#   acfs agents list [--workspace ID] [--kind K] [--json]
#   acfs agents inbox [--agent NAME] [--project KEY] [--keep-unread]
#   acfs agents codex-daemon (status [--json] | start | restart)
#   acfs agents retire <MailName> [--workspace ID] [--cwd DIR] [--token T] [--dry-run]
# ============================================================

set -euo pipefail

HERDR_AGENTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_AGENTS_NAME_PATTERN='^[a-z][a-z0-9_-]{0,31}$'
HERDR_AGENTS_NAME_ERROR=""
# How long a prompt may take to show that it was submitted (or, with send
# --wait, to finish), unless --timeout says otherwise.
HERDR_AGENTS_PROMPT_TIMEOUT_MS=15000
# The --limit inbox passes to am: far above any real mailbox. An answer this
# long could be a truncated one, so inbox refuses it.
HERDR_AGENTS_INBOX_LIMIT=1000000

herdr_agents_usage() {
    cat <<'EOF'
Usage:
  acfs agents spawn [--claude N] [--codex N] [--agy N] [--kind KIND [--count N]]...
                    [--workspace ID] [--cwd DIR] [--model MODEL]
                    [--prompt TEXT | --no-prompt] [--trust-folder] [--dry-run] [--json]
  acfs agents send  (--all | --kind KIND | --name NAME)... [--workspace ID]
                    [--wait] [--timeout MS] <prompt>
  acfs agents list  [--workspace ID] [--kind KIND] [--json]
  acfs agents inbox [--agent NAME] [--project KEY] [--keep-unread]
  acfs agents codex-daemon (status [--json] | start | restart)
  acfs agents retire <MailName> [--workspace ID] [--cwd DIR] [--token TOKEN] [--dry-run]

spawn  Start agents, each in its own tab of a herdr workspace. Each agent gets
       an Agent Mail identity first; its herdr name is that name lowercased and
       its tab is labelled with it. By default each agent is then sent its
       identity and the command palette's default_new_agent prompt.
       --model sets the model of the agent CLI (claude, codex and gemini take
       it; agy runs on the model agy-locked pins) and of its Agent Mail
       identity; a spawn whose kinds can't all take it is refused up front.
       A start herdr refuses because the new tab's shell is still starting is
       retried once, when that shell is idle; if it fails again, the tab is
       closed (only while it holds an idle shell) and spawn stops.
       An agent that stops at a dialog stops spawn. With --trust-folder, the
       first-run "trust this folder?" dialog of Claude Code or Codex is
       answered with "trust"; no other dialog ever is.
       Before the first Codex agent, spawn makes sure Codex's app-server
       daemon runs without any HERDR_* variable (see codex-daemon); it
       refuses to start Codex agents while a daemon that inherited a pane's
       variables is running.
       Each kickoff prompt must be seen submitted, as for send.
send   Prompt every matching agent, and wait until each is seen working, which
       proves the prompt was submitted (with --wait: until its turn ends), for
       at most --timeout ms (default 15000). Exits non-zero when any agent
       did not take the prompt: a --name no agent has, an agent blocked at an
       approval or question (skipped, never answered), or a prompt that
       stalled because nothing started working. For a stall, send reads the
       agent's screen and says whether a dialog or undimmed typed text is on
       it; it never presses a key there.
list   Show the agents herdr knows about.
inbox  Print every unread Agent Mail message sent to the agent (To or bcc,
       not cc), oldest first and grouped by thread, with bodies, then mark
       each one read, so that unread means not yet seen. am's own inbox shows
       only 20 rows, high importance first, and never marks anything read.
       inbox ends with a count of what it listed, the cc messages still
       unread and the messages whose ack is pending (acknowledge those
       yourself). --keep-unread lists without marking. The agent is --agent,
       else $AGENT_MAIL_AGENT, else $AGENT_NAME; the project key is
       --project, else $AGENT_MAIL_PROJECT, else the git top level.
codex-daemon
       Codex runs its hooks through one shared app-server daemon. Started from
       inside a herdr pane, the daemon keeps that pane's HERDR_* variables, and
       herdr's Codex hook then reports every Codex session on the host as that
       pane's occupant, which clears the pane's agent name again and again.
       status shows the daemon and the HERDR_* variables it carries (exit 1
       when it carries any); start and restart run it with every HERDR_*
       variable removed. restart interrupts every running Codex agent's
       connection to the daemon.
retire Retire an agent whose work is done: leave a handoff comment on its bead
       first. Refuses while the agent holds Agent Mail reservations, while a
       file it ever reserved has uncommitted changes (unless another agent
       holds that file now), while it is working, and while a worktree whose
       path names it is dirty or not merged to origin/main. Otherwise it
       removes its merged worktrees (git worktree remove, never --force),
       closes its herdr pane (its tab, when that is the tab's only pane) and,
       given the agent's registration token (--token or
       AGENT_MAIL_REGISTRATION_TOKEN), soft-retires its Agent Mail identity;
       unretire_agent restores it. --dry-run lists what it would do.

The workspace is --workspace, else $HERDR_WORKSPACE_ID. --cwd defaults to the
git top level of the current directory, which is also the Agent Mail project key.
EOF
}

herdr_agents_die() {
    printf 'acfs agents: %s\n' "$*" >&2
    exit 1
}

herdr_agents_note() {
    printf '%s\n' "$*" >&2
}

herdr_agents_require() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || herdr_agents_die "$tool not found in PATH"
    done
}

# Run herdr. Sets HERDR_AGENTS_OUT (stdout JSON) and HERDR_AGENTS_ERR_CODE
# (the .error.code herdr printed on stderr, or "failed" when it printed none).
HERDR_AGENTS_OUT=""
HERDR_AGENTS_ERR_CODE=""
HERDR_AGENTS_ERR_MESSAGE=""
herdr_agents_herdr() {
    local err_file status=0 err=""
    err_file="$(mktemp "${TMPDIR:-/tmp}/acfs-herdr-agents.XXXXXX")"
    HERDR_AGENTS_OUT="$(herdr "$@" 2>"$err_file")" || status=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    HERDR_AGENTS_ERR_CODE=""
    HERDR_AGENTS_ERR_MESSAGE=""
    if (( status != 0 )); then
        HERDR_AGENTS_ERR_CODE="$(jq -r '.error.code // empty' <<<"$err" 2>/dev/null || true)"
        HERDR_AGENTS_ERR_MESSAGE="$(jq -r '.error.message // empty' <<<"$err" 2>/dev/null || true)"
        [[ -n "$HERDR_AGENTS_ERR_CODE" ]] || HERDR_AGENTS_ERR_CODE="failed"
        [[ -n "$HERDR_AGENTS_ERR_MESSAGE" ]] || HERDR_AGENTS_ERR_MESSAGE="${err:-herdr exited $status}"
    fi
    return "$status"
}

herdr_agents_resolve_workspace() {
    local workspace="$1"
    [[ -n "$workspace" ]] || workspace="${HERDR_WORKSPACE_ID:-}"
    [[ -n "$workspace" ]] || herdr_agents_die "no workspace: pass --workspace ID (see 'herdr workspace list'), or run inside herdr"
    printf '%s\n' "$workspace"
}

# The Agent Mail program name for a herdr agent kind.
herdr_agents_program_for_kind() {
    case "$1" in
        claude) printf 'claude-code\n' ;;
        codex) printf 'codex-cli\n' ;;
        gemini) printf 'gemini-cli\n' ;;
        agy) printf 'antigravity\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

herdr_agents_herdr_name() {
    local name="${1,,}"
    if [[ ! "$name" =~ $HERDR_AGENTS_NAME_PATTERN ]]; then
        HERDR_AGENTS_NAME_ERROR="'$1' lowercased is not a valid herdr agent name ([a-z][a-z0-9_-]{0,31})"
        return 1
    fi
    printf '%s\n' "$name"
}

# The command palette's default_new_agent prompt: the paragraph after its
# heading. The installed copy first, then this checkout's.
herdr_agents_default_prompt() {
    local candidate
    for candidate in \
        "${ACFS_HOME:-$HOME/.acfs}/onboard/docs/ntm/command_palette.md" \
        "$HERDR_AGENTS_SCRIPT_DIR/../../acfs/onboard/docs/ntm/command_palette.md"; do
        [[ -r "$candidate" ]] || continue
        awk '
            /^### default_new_agent[[:space:]]*\|/ { found = 1; next }
            found && /^### / { exit }
            found && NF { printf "%s%s", sep, $0; sep = "\n" }
        ' "$candidate"
        return 0
    done
    return 1
}

# ------------------------------------------------------------
# prompt outcomes
# ------------------------------------------------------------

# What an agent's screen shows, read on stdin as `herdr agent read --format
# ansi` prints it: "dialog" (a question or a menu), "typed" (text in normal
# brightness after the input box's ❯ or ›: typed but not submitted),
# "suggestion" (dim text there: the CLI's ghost suggestion, nothing typed),
# "empty", or "unknown" when neither a dialog nor an input box is recognised.
# The bottom-most input box line counts. awk may work on bytes (mawk) or,
# in a UTF-8 locale, on characters (gawk, as on GitHub's runners), so the
# markers are matched as whole strings, never in brackets, and skipped by
# their length() rather than a byte count.
herdr_agents_screen_state() {
    awk '
        # Skip the spaces and escape sequences before the first visible
        # character of s; set TEXT to the rest and DIM to whether SGR left
        # it dim. 38, 48 and 58 take a colour argument that is no mode.
        function scan(s,    n, i, p, params) {
            DIM = 0
            while (length(s) > 0) {
                if (substr(s, 1, 1) == " ") { s = substr(s, 2); continue }
                if (index(s, "\302\240") == 1) { s = substr(s, length("\302\240") + 1); continue }
                if (match(s, /^\033\[[0-9;]*m/)) {
                    n = split(substr(s, 3, RLENGTH - 3), params, ";")
                    s = substr(s, RLENGTH + 1)
                    if (n == 0) DIM = 0
                    for (i = 1; i <= n; i++) {
                        p = params[i] + 0
                        if (p == 0 || p == 22) DIM = 0
                        else if (p == 2) DIM = 1
                        else if (p == 38 || p == 48 || p == 58) i += (params[i + 1] == "5") ? 2 : 4
                    }
                    continue
                }
                if (match(s, /^\033\[[0-9;?]*[A-Za-z]/)) { s = substr(s, RLENGTH + 1); continue }
                break
            }
            TEXT = s
        }
        {
            sub(/\r$/, "")
            text = $0
            gsub(/\033\[[0-9;?]*[A-Za-z]/, "", text)
            # Key hints and a highlighted numbered choice; never wording an
            # agent could also write in its answer.
            if (text ~ /Enter to confirm|Enter to select|Esc to cancel/) dialog = 1
            if (text ~ /^[ \t]*(❯|›|>)[ \t]*[0-9]+\. /) dialog = 1
            if (text !~ /^[ \t]*(❯|›)/) next
            marker = "❯"
            at = index($0, marker)
            if (at == 0) { marker = "›"; at = index($0, marker) }
            scan(substr($0, at + length(marker)))
            if (TEXT ~ /^[ \t]*$/) state = "empty"
            else if (DIM) state = "suggestion"
            else state = "typed"
        }
        END {
            if (dialog) print "dialog"
            else if (state != "") print state
            else print "unknown"
        }
    '
}

# After agent $1 left a prompt stalled (herdr saw nothing start working):
# say what its screen shows, and show it. Never presses a key there: a blind
# Enter could answer a dialog or submit something nobody meant to send.
herdr_agents_explain_stall() {
    local target="$1" state
    if ! herdr_agents_herdr agent read "$target" --source visible --lines 30 --format ansi; then
        herdr_agents_note "  its screen could not be read ($HERDR_AGENTS_ERR_CODE): look at its pane"
        return 0
    fi
    state="$(herdr_agents_screen_state <<<"$HERDR_AGENTS_OUT")"
    case "$state" in
        dialog) herdr_agents_note "  a dialog is on its screen, though herdr does not report it blocked: answer it in the pane, then send again" ;;
        typed) herdr_agents_note "  undimmed text is in its input box: typed but not submitted. Look at the pane before sending again" ;;
        suggestion|empty) herdr_agents_note "  nothing is typed in its input box (a dim line there is the CLI's suggestion, not a pending prompt)" ;;
        *) herdr_agents_note "  neither a dialog nor an input box is recognised on its screen" ;;
    esac
    herdr_agents_note "  its screen:"
    sed -e $'s/\e\\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' <<<"$HERDR_AGENTS_OUT" \
        | awk 'NF' | tail -n 12 | sed 's/^/    | /' >&2
}

# ------------------------------------------------------------
# spawn
# ------------------------------------------------------------

# The keys that answer a recognised folder-trust dialog with "trust": $1 is
# the kind, $2 the visible screen. Claude Code's dialog defaults to "No, exit";
# Codex's to "Trust and continue". Anything else is not ours to answer.
herdr_agents_trust_keys() {
    local kind="$1" screen="$2"
    case "$kind" in
        claude)
            [[ "$screen" == *"Is this a project you created or one you trust?"* ]] || return 1
            if grep -Eq '❯ *No, exit' <<<"$screen" && grep -Eq '^ *Yes, I trust this folder' <<<"$screen"; then
                printf 'down enter\n'
            elif grep -Eq '❯ *Yes, I trust this folder' <<<"$screen"; then
                printf 'enter\n'
            else
                return 1
            fi
            ;;
        codex)
            [[ "$screen" == *"Trust this folder?"* ]] && grep -Eq '› *1\. Trust and continue' <<<"$screen" || return 1
            printf 'enter\n'
            ;;
        *) return 1 ;;
    esac
}

# Answer agent $1's (kind $2) folder-trust dialog, then wait until it is
# ready. Fails, leaving the agent as it is, when the screen is not exactly
# that dialog or the agent does not become ready.
herdr_agents_trust_folder() {
    local name="$1" kind="$2" keys=""
    local -a key_list=()
    herdr_agents_herdr agent read "$name" --source visible --lines 40 || return 1
    keys="$(herdr_agents_trust_keys "$kind" "$HERDR_AGENTS_OUT")" || return 1
    read -ra key_list <<<"$keys"
    herdr_agents_herdr agent send-keys "$name" "${key_list[@]}" || return 1
    # Not blocked: another dialog after this one stops spawn as usual.
    herdr_agents_herdr agent wait "$name" --until idle --until "done" --timeout 30000 || return 1
    herdr_agents_note "trusted the folder for $name ($kind)"
}

# Wait until the shell in pane $1 holds the foreground with no command
# running, which `agent start` requires. A new tab's shell can still be
# running its startup files when spawn reaches it (acfs-zsz). Fails when it
# never does within HERDR_AGENTS_SHELL_WAIT_TRIES polls (default 50, 0.2s
# apart).
herdr_agents_wait_shell() {
    local pane="$1" tries="${HERDR_AGENTS_SHELL_WAIT_TRIES:-50}"
    local interval="${HERDR_AGENTS_SHELL_WAIT_INTERVAL:-0.2}" i
    for ((i = 0; i < tries; i++)); do
        herdr_agents_shell_idle "$pane" && return 0
        sleep "$interval"
    done
    return 1
}

# True when herdr reports pane $1's own shell in the foreground: no command,
# editor or agent is running there.
herdr_agents_shell_idle() {
    herdr_agents_herdr pane process-info --pane "$1" \
        && jq -e --arg pane "$1" '.result.process_info
            | .pane_id == $pane and .foreground_process_group_id == .shell_pid' \
            <<<"$HERDR_AGENTS_OUT" >/dev/null 2>&1
}

# The agent CLI flag that selects a model for kind $1. Fails for a kind
# whose model spawn does not set: agy runs on the model agy-locked pins.
herdr_agents_model_flag() {
    case "$1" in
        claude|codex|gemini) printf -- '--model\n' ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------
# codex-daemon
# ------------------------------------------------------------
# Codex 0.162 runs its hooks through one shared app-server daemon, started
# by the first Codex that needs it. Started from inside a herdr pane, the
# daemon keeps that pane's HERDR_* environment, and herdr's Codex
# SessionStart hook (which reads HERDR_PANE_ID from its environment) then
# reports every Codex session on the host as that pane's occupant: herdr
# "replaces" the agent there on each report and clears its name, and the
# other Codex panes never get a session (acfs-gen.3). So the daemon has to
# start with no HERDR_* variable at all.
#
# The daemon's pid file is $CODEX_HOME/app-server-daemon/daemon.pid, JSON
# with a "pid". Its environment is read from /proc; HERDR_AGENTS_PROC_ROOT
# points the tests at a fake one.

herdr_agents_codex_home() {
    printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
}

# The pid of the running Codex app-server daemon: the pid file's process,
# when it is alive, ours (a reused pid can belong to another user) and a
# codex app-server. Fails when none runs.
herdr_agents_codex_daemon_pid() {
    local pid_file pid cmdline proc_root="${HERDR_AGENTS_PROC_ROOT:-/proc}"
    pid_file="$(herdr_agents_codex_home)/app-server-daemon/daemon.pid"
    [[ -r "$pid_file" ]] || return 1
    pid="$(jq -r '.pid // empty' "$pid_file" 2>/dev/null)" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "$proc_root/$pid" && -O "$proc_root/$pid" ]] || return 1
    cmdline="$(tr '\0' ' ' <"$proc_root/$pid/cmdline" 2>/dev/null)" || return 1
    [[ "$cmdline" == *"app-server"* ]] || return 1
    printf '%s\n' "$pid"
}

# The HERDR_* variables in process $1's environment, one NAME=VALUE per
# line. Fails when the environment cannot be read: that is unknown, not
# clean.
herdr_agents_codex_daemon_leaked_vars() {
    local environ="${HERDR_AGENTS_PROC_ROOT:-/proc}/$1/environ"
    [[ -r "$environ" ]] || return 1
    tr '\0' '\n' <"$environ" | grep '^HERDR_' || true
}

# Run codex with every HERDR_* variable removed from its environment: the
# ones a pane's shell exports (HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID,
# HERDR_WORKSPACE_ID, HERDR_SOCKET_PATH, HERDR_BIN_PATH) and any herdr adds
# later. This helper's own HERDR_AGENTS_* knobs are not herdr's and stay.
herdr_agents_codex_outside_herdr() {
    local var
    local -a unset_args=()
    for var in "${!HERDR_@}"; do
        [[ "$var" == HERDR_AGENTS_* ]] || unset_args+=(-u "$var")
    done
    env "${unset_args[@]}" codex "$@"
}

# One JSON object describing the daemon: running, pid, leaked_herdr_vars
# (names), clean (true when it carries none, or none runs; null when its
# environment cannot be read).
herdr_agents_codex_daemon_status_json() {
    local pid leaked="[]" vars
    if pid="$(herdr_agents_codex_daemon_pid)"; then
        if vars="$(herdr_agents_codex_daemon_leaked_vars "$pid")"; then
            leaked="$(cut -d= -f1 <<<"$vars" | grep . | jq -Rc . | jq -sc .)"
            jq -nc --argjson pid "$pid" --argjson leaked "$leaked" \
                '{running: true, pid: $pid, leaked_herdr_vars: $leaked, clean: ($leaked | length == 0)}'
        else
            jq -nc --argjson pid "$pid" '{running: true, pid: $pid, leaked_herdr_vars: null, clean: null}'
        fi
    else
        jq -nc '{running: false, pid: null, leaked_herdr_vars: [], clean: true}'
    fi
}

# Wait until the pid file names a live daemon, HERDR_AGENTS_DAEMON_WAIT_TRIES
# polls apart (default 25, 0.2s).
herdr_agents_codex_daemon_wait() {
    local tries="${HERDR_AGENTS_DAEMON_WAIT_TRIES:-25}" interval="${HERDR_AGENTS_DAEMON_WAIT_INTERVAL:-0.2}" i
    for ((i = 0; i < tries; i++)); do
        herdr_agents_codex_daemon_pid >/dev/null && return 0
        sleep "$interval"
    done
    return 1
}

# Make sure a daemon without HERDR_* variables runs: start one when none
# runs; fail, naming the variables and the fix, when the running one
# carries any. The caller has checked that codex and jq are installed.
herdr_agents_codex_daemon_ensure() {
    local status pid
    status="$(herdr_agents_codex_daemon_status_json)"
    if [[ "$(jq -r '.running' <<<"$status")" == true ]]; then
        pid="$(jq -r '.pid' <<<"$status")"
        case "$(jq -r '.clean' <<<"$status")" in
            true) return 0 ;;
            null)
                herdr_agents_note "the Codex app-server daemon (pid $pid) is running but its environment cannot be read, so its HERDR_* variables are unknown"
                herdr_agents_note "  check it with 'acfs agents codex-daemon status' as the user who started it, or restart it with 'acfs agents codex-daemon restart'"
                return 1
                ;;
        esac
        herdr_agents_note "the Codex app-server daemon (pid $pid) carries $(jq -r '.leaked_herdr_vars | join(", ")' <<<"$status"): it was started inside a herdr pane, and every Codex session on this host reports as that pane's agent"
        herdr_agents_note "  restart it with 'acfs agents codex-daemon restart' (running Codex agents lose their daemon connection until they reconnect), then spawn again"
        return 1
    fi
    herdr_agents_note "starting the Codex app-server daemon without HERDR_* variables"
    if ! herdr_agents_codex_outside_herdr app-server daemon start >/dev/null; then
        herdr_agents_note "codex app-server daemon start failed"
        return 1
    fi
    if ! herdr_agents_codex_daemon_wait; then
        herdr_agents_note "the Codex app-server daemon did not come up: no live pid in $(herdr_agents_codex_home)/app-server-daemon/daemon.pid"
        return 1
    fi
    status="$(herdr_agents_codex_daemon_status_json)"
    [[ "$(jq -r '.clean' <<<"$status")" == true ]] && return 0
    herdr_agents_note "the Codex app-server daemon came up carrying $(jq -r '.leaked_herdr_vars | join(", ")' <<<"$status")"
    return 1
}

# Print status $1 (as JSON when $2 is true). Exit 0 for a clean daemon or
# none, 1 for one carrying HERDR_* variables, 2 when its environment is
# unreadable.
herdr_agents_codex_daemon_print_status() {
    local status="$1" json="$2" clean
    clean="$(jq -r '.clean' <<<"$status")"
    if [[ "$json" == true ]]; then
        printf '%s\n' "$status"
    elif [[ "$(jq -r '.running' <<<"$status")" != true ]]; then
        printf 'codex app-server daemon: not running\n'
    elif [[ "$clean" == true ]]; then
        printf 'codex app-server daemon: running (pid %s), no HERDR_* variables\n' "$(jq -r '.pid' <<<"$status")"
    elif [[ "$clean" == null ]]; then
        printf 'codex app-server daemon: running (pid %s), environment unreadable, HERDR_* variables unknown\n' "$(jq -r '.pid' <<<"$status")"
    else
        printf 'codex app-server daemon: running (pid %s) with %s; every Codex session on this host reports as that pane'"'"'s agent. Fix: acfs agents codex-daemon restart\n' \
            "$(jq -r '.pid' <<<"$status")" "$(jq -r '.leaked_herdr_vars | join(", ")' <<<"$status")"
    fi
    case "$clean" in
        true) return 0 ;;
        null) return 2 ;;
        *) return 1 ;;
    esac
}

herdr_agents_codex_daemon() {
    local action="${1:-}" json=false status
    [[ -n "$action" ]] || herdr_agents_die "codex-daemon needs status, start or restart"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown codex-daemon option: $1" ;;
        esac
    done
    herdr_agents_require jq
    case "$action" in
        status)
            herdr_agents_codex_daemon_print_status "$(herdr_agents_codex_daemon_status_json)" "$json"
            ;;
        start)
            herdr_agents_require codex
            herdr_agents_codex_daemon_ensure || return 1
            herdr_agents_codex_daemon_print_status "$(herdr_agents_codex_daemon_status_json)" "$json"
            ;;
        restart)
            herdr_agents_require codex
            herdr_agents_note "restarting the Codex app-server daemon without HERDR_* variables; running Codex agents lose their daemon connection until they reconnect"
            herdr_agents_codex_outside_herdr app-server daemon restart >/dev/null \
                || herdr_agents_die "codex app-server daemon restart failed"
            herdr_agents_codex_daemon_wait \
                || herdr_agents_die "the Codex app-server daemon did not come back: no live pid in $(herdr_agents_codex_home)/app-server-daemon/daemon.pid"
            status="$(herdr_agents_codex_daemon_status_json)"
            herdr_agents_codex_daemon_print_status "$status" "$json" \
                || herdr_agents_die "the restarted daemon still carries HERDR_* variables; restart it from a shell outside herdr"
            ;;
        *) herdr_agents_die "unknown codex-daemon action: $action (status, start or restart)" ;;
    esac
}

# True when one of the kinds in $@ is codex.
herdr_agents_kinds_include_codex() {
    local kind
    for kind in "$@"; do [[ "$kind" == codex ]] && return 0; done
    return 1
}

herdr_agents_spawn() {
    local workspace="" cwd="" model="unknown" model_given=false prompt="" prompt_mode="palette"
    local dry_run=false json=false trust_folder=false
    local -a kinds=()
    local pending_kind=""

    herdr_agents_add_kind() {
        local kind="$1" count="$2" i
        [[ "$kind" =~ ^[a-z][a-z0-9_-]*$ ]] || herdr_agents_die "invalid agent kind: $kind"
        [[ "$count" =~ ^[0-9]+$ ]] || herdr_agents_die "invalid count for $kind: $count"
        for ((i = 0; i < count; i++)); do kinds+=("$kind"); done
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --claude|--codex|--agy|--gemini)
                [[ $# -ge 2 ]] || herdr_agents_die "$1 needs a count"
                herdr_agents_add_kind "${1#--}" "$2"; shift 2 ;;
            --claude=*|--codex=*|--agy=*|--gemini=*)
                local flag="${1%%=*}"
                herdr_agents_add_kind "${flag#--}" "${1#*=}"; shift ;;
            --kind)
                [[ $# -ge 2 ]] || herdr_agents_die "--kind needs a value"
                [[ -z "$pending_kind" ]] || herdr_agents_add_kind "$pending_kind" 1
                pending_kind="$2"; shift 2 ;;
            --count)
                [[ $# -ge 2 && -n "$pending_kind" ]] || herdr_agents_die "--count follows --kind KIND"
                herdr_agents_add_kind "$pending_kind" "$2"; pending_kind=""; shift 2 ;;
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --cwd) [[ $# -ge 2 ]] || herdr_agents_die "--cwd needs a value"; cwd="$2"; shift 2 ;;
            --model) [[ $# -ge 2 ]] || herdr_agents_die "--model needs a value"; model="$2"; model_given=true; shift 2 ;;
            --prompt) [[ $# -ge 2 ]] || herdr_agents_die "--prompt needs a value"; prompt="$2"; prompt_mode="custom"; shift 2 ;;
            --no-prompt) prompt_mode="none"; shift ;;
            --trust-folder) trust_folder=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --json) json=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown spawn option: $1" ;;
        esac
    done
    [[ -z "$pending_kind" ]] || herdr_agents_add_kind "$pending_kind" 1
    (( ${#kinds[@]} > 0 )) || herdr_agents_die "nothing to spawn: pass --claude N, --codex N, --agy N or --kind KIND [--count N]"
    # --model reaches the agent CLI, not just its Agent Mail identity, so
    # every kind in this spawn must take it. Checked before anything exists.
    if [[ "$model_given" == true ]]; then
        [[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$ ]] \
            || herdr_agents_die "invalid --model: $model (letters, digits and ._:/@+- only)"
        local model_kind
        for model_kind in "${kinds[@]}"; do
            if ! herdr_agents_model_flag "$model_kind" >/dev/null; then
                [[ "$model_kind" != agy ]] \
                    || herdr_agents_die "--model can't be set for agy agents: agy runs on the model agy-locked pins. Spawn them without --model"
                herdr_agents_die "--model can't be set for $model_kind agents: spawn them without --model"
            fi
        done
    fi

    herdr_agents_require herdr jq
    [[ "$dry_run" == true ]] || herdr_agents_require am
    workspace="$(herdr_agents_resolve_workspace "$workspace")"
    if [[ -z "$cwd" ]]; then
        cwd="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    [[ -d "$cwd" ]] || herdr_agents_die "--cwd is not a directory: $cwd"
    cwd="$(cd "$cwd" && pwd -P)"

    local base_prompt=""
    case "$prompt_mode" in
        palette)
            base_prompt="$(herdr_agents_default_prompt)" \
                || herdr_agents_die "command palette not found; pass --prompt TEXT or --no-prompt"
            [[ -n "$base_prompt" ]] || herdr_agents_die "the command palette has no default_new_agent prompt; pass --prompt TEXT or --no-prompt"
            ;;
        custom) base_prompt="$prompt" ;;
    esac

    # Codex agents need the app-server daemon up, and free of HERDR_*
    # variables, before the first one starts (acfs-gen.3). Checked before
    # any identity or tab exists.
    if herdr_agents_kinds_include_codex "${kinds[@]}"; then
        if [[ "$dry_run" == true ]]; then
            herdr_agents_note "would run: codex app-server daemon start (without HERDR_* variables) unless a daemon without them runs"
        else
            herdr_agents_require codex
            herdr_agents_codex_daemon_ensure || herdr_agents_die "spawn stopped: Codex agents need an app-server daemon without HERDR_* variables"
        fi
    fi

    local results="[]" kind mail_name herdr_name tab_id pane_id kickoff status
    local failed=false
    local -a agent_args=()
    for kind in "${kinds[@]}"; do
        # Arguments herdr passes to the agent CLI after `--`.
        agent_args=()
        [[ "$model_given" == false ]] || agent_args=(-- "$(herdr_agents_model_flag "$kind")" "$model")
        if [[ "$dry_run" == true ]]; then
            herdr_agents_note "would run: am agents create --project $cwd --program $(herdr_agents_program_for_kind "$kind") --model $model --json"
            herdr_agents_note "would run: herdr tab create --workspace $workspace --cwd $cwd --label <AgentMailName> --no-focus"
            herdr_agents_note "would run: herdr agent start <agentmailname> --kind $kind --pane <root pane>${agent_args[*]:+ ${agent_args[*]}}"
            [[ "$prompt_mode" == none ]] || herdr_agents_note "would run: herdr agent prompt <agentmailname> <kickoff>"
            results="$(jq -c --arg kind "$kind" '. + [{kind: $kind, status: "dry-run"}]' <<<"$results")"
            continue
        fi

        mail_name="$(am agents create --project "$cwd" --program "$(herdr_agents_program_for_kind "$kind")" \
            --model "$model" --json 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)"
        if [[ -z "$mail_name" ]]; then
            herdr_agents_note "spawn stopped: am agents create failed for a $kind agent (is Agent Mail running?)"
            failed=true
            break
        fi
        if ! herdr_name="$(herdr_agents_herdr_name "$mail_name")"; then
            herdr_agents_note "spawn stopped: $HERDR_AGENTS_NAME_ERROR"
            failed=true
            break
        fi

        if ! herdr_agents_herdr tab create --workspace "$workspace" --cwd "$cwd" --label "$mail_name" --no-focus; then
            herdr_agents_note "spawn stopped: herdr tab create failed for $mail_name: $HERDR_AGENTS_ERR_MESSAGE"
            herdr_agents_note "  the Agent Mail identity $mail_name exists but has no agent"
            results="$(jq -c --arg kind "$kind" --arg name "$mail_name" --arg herdr "$herdr_name" \
                --arg status "$HERDR_AGENTS_ERR_CODE" \
                '. + [{kind: $kind, agent_mail_name: $name, herdr_name: $herdr, status: $status, unused_identity: true}]' <<<"$results")"
            failed=true
            break
        fi
        tab_id="$(jq -r '.result.tab.tab_id // empty' <<<"$HERDR_AGENTS_OUT")"
        pane_id="$(jq -r '.result.root_pane.pane_id // empty' <<<"$HERDR_AGENTS_OUT")"
        [[ -n "$pane_id" ]] || herdr_agents_die "herdr tab create returned no root pane for $mail_name"

        local started=true start_error="" unused_identity=false tab_closed=false
        if ! herdr_agents_herdr agent start "$herdr_name" --kind "$kind" --pane "$pane_id" "${agent_args[@]}"; then
            started=false
            # Kept apart: the calls below reset HERDR_AGENTS_ERR_CODE.
            status="$HERDR_AGENTS_ERR_CODE"
            start_error="$HERDR_AGENTS_ERR_MESSAGE"
            # herdr refused before typing anything: the shell was still
            # starting. Wait for it, then retry once in the same pane.
            if [[ "$status" == agent_pane_busy ]] && herdr_agents_wait_shell "$pane_id"; then
                herdr_agents_note "retrying $herdr_name: the shell in $pane_id was not ready yet"
                if herdr_agents_herdr agent start "$herdr_name" --kind "$kind" --pane "$pane_id" "${agent_args[@]}"; then
                    started=true
                else
                    status="$HERDR_AGENTS_ERR_CODE"
                    start_error="$HERDR_AGENTS_ERR_MESSAGE"
                fi
            fi
            if [[ "$started" == false && "$status" == agent_not_ready && "$trust_folder" == true ]] \
                && herdr_agents_trust_folder "$herdr_name" "$kind"; then
                started=true
            fi
        fi
        if [[ "$started" == false ]]; then
            herdr_agents_note "spawn stopped: $kind agent $herdr_name in $pane_id did not start ($status): $start_error"
            # agent_pane_busy means herdr started nothing. Close the tab spawn
            # created only when its shell is seen idle, so nothing runs there;
            # otherwise leave it for the caller.
            if [[ "$status" == agent_pane_busy ]]; then
                unused_identity=true
                if ! herdr_agents_shell_idle "$pane_id"; then
                    herdr_agents_note "  left its tab $tab_id: something runs in $pane_id; close it with 'herdr tab close $tab_id' once it is free"
                elif herdr_agents_herdr tab close "$tab_id"; then
                    tab_closed=true
                    herdr_agents_note "  closed its tab $tab_id, which held only an idle shell"
                else
                    herdr_agents_note "  could not close its tab $tab_id ($HERDR_AGENTS_ERR_CODE): close it with 'herdr tab close $tab_id'"
                fi
                herdr_agents_note "  the Agent Mail identity $mail_name exists but has no agent"
            fi
            if [[ "$status" == agent_not_ready ]]; then
                herdr_agents_note "  it is waiting at a dialog (a first-run question such as 'Trust this folder?'). Its screen:"
                # agent read prints the terminal text itself, not JSON.
                if herdr_agents_herdr agent read "$herdr_name" --source visible --lines 15; then
                    sed 's/^/    | /' <<<"$HERDR_AGENTS_OUT" >&2
                fi
                herdr_agents_note "  answer it in the tab ($tab_id), or with 'herdr agent send-keys $herdr_name', then re-run spawn for the rest"
                [[ "$trust_folder" == true ]] \
                    || herdr_agents_note "  (--trust-folder answers the folder-trust dialog only, when you trust --cwd)"
            fi
            results="$(jq -c --arg kind "$kind" --arg name "$mail_name" --arg herdr "$herdr_name" \
                --arg tab "$tab_id" --arg pane "$pane_id" --arg status "$status" \
                --argjson unused "$unused_identity" --argjson closed "$tab_closed" \
                '. + [{kind: $kind, agent_mail_name: $name, herdr_name: $herdr, tab_id: $tab, pane_id: $pane, status: $status}
                      + (if $unused then {unused_identity: true, tab_closed: $closed} else {} end)]' <<<"$results")"
            failed=true
            break
        fi

        status="started"
        if [[ "$prompt_mode" != none ]]; then
            kickoff="Your Agent Mail identity is already registered: name $mail_name, project key $cwd (use it; don't register a new one). Your herdr name is $herdr_name, in herdr workspace $workspace."
            kickoff+=$'\n\n'"$base_prompt"
            # Wait only until the agent is seen working, which proves the
            # kickoff was submitted: the turn itself runs for a long time.
            if herdr_agents_herdr agent prompt "$herdr_name" "$kickoff" \
                --wait --until working --until blocked --timeout "$HERDR_AGENTS_PROMPT_TIMEOUT_MS"; then
                status="prompted"
                [[ "$(jq -r '.result.agent.agent_status // empty' <<<"$HERDR_AGENTS_OUT")" != blocked ]] \
                    || herdr_agents_note "$herdr_name took its kickoff prompt and is now blocked at an approval or question"
            else
                herdr_agents_note "$herdr_name started, but its kickoff prompt failed ($HERDR_AGENTS_ERR_CODE): $HERDR_AGENTS_ERR_MESSAGE"
                status="started; prompt failed: $HERDR_AGENTS_ERR_CODE"
                failed=true
                [[ "$HERDR_AGENTS_ERR_CODE" != agent_prompt_stalled ]] || herdr_agents_explain_stall "$herdr_name"
            fi
        fi
        herdr_agents_note "$status: $mail_name ($herdr_name, $kind) in tab $tab_id, pane $pane_id"
        results="$(jq -c --arg kind "$kind" --arg name "$mail_name" --arg herdr "$herdr_name" \
            --arg tab "$tab_id" --arg pane "$pane_id" --arg status "$status" \
            '. + [{kind: $kind, agent_mail_name: $name, herdr_name: $herdr, tab_id: $tab, pane_id: $pane, status: $status}]' <<<"$results")"
    done

    if [[ "$json" == true ]]; then
        jq -n --arg workspace "$workspace" --arg cwd "$cwd" --argjson dry_run "$dry_run" \
            --argjson ok "$([[ "$failed" == true ]] && echo false || echo true)" --argjson agents "$results" \
            '{workspace: $workspace, cwd: $cwd, dry_run: $dry_run, ok: $ok, agents: $agents}'
    fi
    [[ "$failed" == false ]]
}

# ------------------------------------------------------------
# list / send
# ------------------------------------------------------------

# Agents from `herdr agent list`, filtered: $1 workspace ("" = all), $2 a
# JSON array of kinds ([] = all), $3 a JSON array of names ([] = all).
herdr_agents_select() {
    herdr_agents_herdr agent list || herdr_agents_die "herdr agent list failed: $HERDR_AGENTS_ERR_MESSAGE"
    jq -c --arg workspace "$1" --argjson kinds "$2" --argjson names "$3" '
        [.result.agents[]?
         | select($workspace == "" or .workspace_id == $workspace)
         | select(($kinds | length) == 0 or (.agent as $k | $kinds | index($k)))
         | select(($names | length) == 0 or ((.name // "") as $n | $names | index($n)))]
    ' <<<"$HERDR_AGENTS_OUT"
}

herdr_agents_list() {
    local workspace="" json=false kinds="[]"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --kind) [[ $# -ge 2 ]] || herdr_agents_die "--kind needs a value"; kinds="$(jq -c --arg k "$2" '. + [$k]' <<<"$kinds")"; shift 2 ;;
            --json) json=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown list option: $1" ;;
        esac
    done
    herdr_agents_require herdr jq

    local agents
    agents="$(herdr_agents_select "$workspace" "$kinds" "[]")"
    if [[ "$json" == true ]]; then
        printf '%s\n' "$agents"
        return 0
    fi
    if [[ "$(jq 'length' <<<"$agents")" == 0 ]]; then
        herdr_agents_note "no agents"
        return 0
    fi
    jq -r '(["NAME", "KIND", "STATUS", "PANE", "TAB"] | @tsv),
           (.[] | [(.name // "-"), .agent, (.agent_status // "unknown"), .pane_id, .tab_id] | @tsv)' <<<"$agents" \
        | awk -F '\t' '
            { rows[NR] = $0; for (i = 1; i <= NF; i++) if (length($i) > width[i]) width[i] = length($i) }
            END {
                for (r = 1; r <= NR; r++) {
                    n = split(rows[r], cell, "\t"); line = ""
                    for (i = 1; i < n; i++) line = line sprintf("%-" width[i] "s  ", cell[i])
                    print line cell[n]
                }
            }'
}

herdr_agents_send() {
    local workspace="" all=false wait=false timeout="" kinds="[]" names="[]"
    local -a prompt_words=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all=true; shift ;;
            --kind) [[ $# -ge 2 ]] || herdr_agents_die "--kind needs a value"; kinds="$(jq -c --arg k "$2" '. + [$k]' <<<"$kinds")"; shift 2 ;;
            --name) [[ $# -ge 2 ]] || herdr_agents_die "--name needs a value"; names="$(jq -c --arg n "${2,,}" '. + [$n]' <<<"$names")"; shift 2 ;;
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --wait) wait=true; shift ;;
            --timeout) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || herdr_agents_die "--timeout needs milliseconds"; timeout="$2"; shift 2 ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            --) shift; prompt_words+=("$@"); break ;;
            -*) herdr_agents_die "unknown send option: $1" ;;
            *) prompt_words+=("$1"); shift ;;
        esac
    done
    local prompt="${prompt_words[*]:-}"
    [[ -n "$prompt" ]] || herdr_agents_die "send needs a prompt"
    if [[ "$all" == false && "$kinds" == "[]" && "$names" == "[]" ]]; then
        herdr_agents_die "send needs --all, --kind KIND or --name NAME"
    fi
    herdr_agents_require herdr jq
    timeout="${timeout:-$HERDR_AGENTS_PROMPT_TIMEOUT_MS}"

    local agents count i target name pane state missing
    local sent=0 skipped=0
    # Always wait, so a prompt that was not submitted is a failure. Without
    # --wait, only until the agent is seen working (or blocked at a dialog
    # the prompt raised); a prompt to an agent already working is queued.
    local -a prompt_args=(--wait)
    [[ "$wait" == true ]] || prompt_args+=(--until working --until blocked)
    prompt_args+=(--timeout "$timeout")
    agents="$(herdr_agents_select "$workspace" "$kinds" "$names")"
    count="$(jq 'length' <<<"$agents")"
    # A --name herdr does not list is a failure, not a quiet no-op: an
    # agent's herdr name can drop while it runs.
    missing="$(jq -r --argjson names "$names" \
        '[.[].name // empty] as $have | $names[] | select(. as $n | $have | any(. == $n) | not)' <<<"$agents")"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        skipped=$((skipped + 1))
        herdr_agents_note "skipped $name (agent_not_found): herdr lists no such agent${workspace:+ in workspace $workspace}; its herdr name may have dropped (see 'acfs agents list')"
    done <<<"$missing"
    if (( count == 0 && skipped == 0 )); then
        herdr_agents_note "no matching agents"
        return 1
    fi
    for ((i = 0; i < count; i++)); do
        name="$(jq -r ".[$i].name // empty" <<<"$agents")"
        pane="$(jq -r ".[$i].pane_id" <<<"$agents")"
        target="${name:-$pane}"
        # Never prompt the agent that is running this command.
        if [[ -n "${HERDR_PANE_ID:-}" && "$pane" == "$HERDR_PANE_ID" ]]; then
            herdr_agents_note "skipped $target: that is this pane"
            continue
        fi
        if herdr_agents_herdr agent prompt "$target" "$prompt" "${prompt_args[@]}"; then
            sent=$((sent + 1))
            state="$(jq -r '.result.agent.agent_status // empty' <<<"$HERDR_AGENTS_OUT")"
            if [[ "$state" == blocked ]]; then
                herdr_agents_note "sent: $target, which is now blocked at an approval or question"
            else
                herdr_agents_note "sent: $target${state:+ ($state)}"
            fi
        else
            skipped=$((skipped + 1))
            case "$HERDR_AGENTS_ERR_CODE" in
                agent_blocked)
                    herdr_agents_note "skipped $target: blocked at an approval or question; answer it in its pane first" ;;
                agent_not_found)
                    herdr_agents_note "skipped $target (agent_not_found): herdr no longer knows that name (see 'acfs agents list')" ;;
                agent_prompt_stalled)
                    herdr_agents_note "not submitted to $target (agent_prompt_stalled): it did not start working after the prompt"
                    herdr_agents_explain_stall "$target" ;;
                timeout)
                    herdr_agents_note "unconfirmed for $target (timeout): it did not reach the awaited state within $timeout ms" ;;
                *)
                    herdr_agents_note "skipped $target ($HERDR_AGENTS_ERR_CODE): $HERDR_AGENTS_ERR_MESSAGE" ;;
            esac
        fi
    done
    herdr_agents_note "sent $sent, skipped $skipped"
    (( skipped == 0 ))
}

# List every unread message sent To (or bcc) the agent, oldest first and
# grouped by thread, with bodies; then mark each listed one read. `am inbox`
# alone shows 20 rows by importance and never marks anything read, so older
# normal mail sinks out of sight. The unread set (with bodies) comes from
# `am inbox --unread`, the to/cc kind and the send time from `am mail inbox`;
# only a message in both is listed, so one that arrives in between stays
# unread.
herdr_agents_inbox() {
    local agent="${AGENT_MAIL_AGENT:-${AGENT_NAME:-}}" project="${AGENT_MAIL_PROJECT:-}" keep_unread=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) [[ $# -ge 2 ]] || herdr_agents_die "--agent needs a value"; agent="$2"; shift 2 ;;
            --project) [[ $# -ge 2 ]] || herdr_agents_die "--project needs a value"; project="$2"; shift 2 ;;
            --keep-unread) keep_unread=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown inbox option: $1" ;;
        esac
    done
    herdr_agents_require am jq
    [[ -n "$agent" ]] || herdr_agents_die "inbox needs --agent (or AGENT_MAIL_AGENT / AGENT_NAME)"
    if [[ -z "$project" ]]; then
        project="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi

    local all unread
    all="$(am mail inbox --project "$project" --agent "$agent" --limit "$HERDR_AGENTS_INBOX_LIMIT" --json)" \
        || herdr_agents_die "am mail inbox failed for $agent"
    unread="$(am inbox --project "$project" --agent "$agent" --unread --include-bodies --limit "$HERDR_AGENTS_INBOX_LIMIT" --json)" \
        || herdr_agents_die "am inbox --unread failed for $agent"
    if (( $(jq 'length' <<<"$all") >= HERDR_AGENTS_INBOX_LIMIT || $(jq '.inbox | length' <<<"$unread") >= HERDR_AGENTS_INBOX_LIMIT )); then
        herdr_agents_die "am returned $HERDR_AGENTS_INBOX_LIMIT rows, so the listing may be cut short"
    fi

    # The unread rows To (or bcc) this agent, oldest first, each with its
    # kind and send time; and how many unread cc rows stay unread. Both
    # answers go in on stdin: a whole mailbox is too long for one argument.
    local joined listed cc_unread
    joined="$(printf '%s\n%s\n' "$all" "$unread" | jq -cs '
        (.[0] | map({key: (.id | tostring), value: .}) | from_entries) as $meta
        | [.[1].inbox[] | . + {kind: $meta[(.id | tostring)].kind, created_ts: $meta[(.id | tostring)].created_ts}]
        | {listed: (map(select(.kind == "to" or .kind == "bcc")) | sort_by(.id)),
           cc: (map(select(.kind == "cc")) | length)}')" || herdr_agents_die "could not read am's inbox JSON"
    listed="$(jq -c '.listed' <<<"$joined")"
    cc_unread="$(jq '.cc' <<<"$joined")"

    # Threads in the order of their oldest unread message.
    jq -r '
        group_by(.thread // "")
        | sort_by(.[0].id)[]
        | "== thread \(.[0].thread // "(none)") (\(length) unread)",
          (.[] | "--- #\(.id) \(.created_ts) from \(.from) [\(.importance)]"
                 + (if .ack_status == "required" or .ack_status == "overdue" then " [ack \(.ack_status)]" else "" end),
                 "Subject: \(.subject)", "", (.body_md // ""), ""),
          ""' <<<"$listed"

    local count=0 failed=0 id
    count="$(jq 'length' <<<"$listed")"
    if [[ "$keep_unread" == false ]]; then
        # am gets no stdin, which holds the ids still to mark.
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            am mail read --project "$project" --agent "$agent" "$id" </dev/null >/dev/null \
                || { herdr_agents_note "could not mark #$id read"; failed=$((failed + 1)); }
        done < <(jq -r '.[].id' <<<"$listed")
    fi

    local ack_pending
    ack_pending="$(jq -r '[.[] | select(.ack_status == "required" or .ack_status == "overdue") | .id] | map("#\(.)") | join(" ")' <<<"$listed")"
    if [[ "$keep_unread" == true ]]; then
        printf 'listed %s unread (left unread)' "$count"
    else
        printf 'listed %s unread, marked %s read' "$count" "$((count - failed))"
    fi
    printf '; %s cc still unread' "$cc_unread"
    [[ -z "$ack_pending" ]] || printf '; ack pending: %s' "$ack_pending"
    printf '\n'
    (( failed == 0 )) || return 1
}

# The repo's files with uncommitted changes, one path per line.
herdr_agents_dirty_files() {
    git -C "$1" status --porcelain=v1 -z --untracked-files=all 2>/dev/null \
        | tr '\0' '\n' | sed -n 's/^.. //p'
}

# Patterns the agent ever reserved in the project (active, expired or
# released), one per line. `am file_reservations list` prints a table whose
# columns are separated by two or more spaces.
herdr_agents_reserved_ever() {
    am file_reservations list "$1" --all 2>/dev/null \
        | awk -v agent="$2" 'NR > 1 { n = split($0, f, /  +/); if (n >= 3 && f[3] == agent) print f[2] }'
}

# Soft-retire an Agent Mail identity. Over HTTP the server takes only the
# agent's own registration token.
herdr_agents_retire_identity() {
    local cwd="$1" mail_name="$2" token="$3" url response
    url="${AGENT_MAIL_URL:-http://127.0.0.1:${ACFS_AGENT_MAIL_PORT:-8765}/mcp/}"
    response="$(jq -nc --arg p "$cwd" --arg a "$mail_name" --arg t "$token" \
        '{jsonrpc: "2.0", id: 1, method: "tools/call",
          params: {name: "retire_agent", arguments: {project_key: $p, agent_name: $a, registration_token: $t}}}' \
        | curl -sS --max-time 15 -X POST "$url" -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' --data-binary @- 2>&1)" || {
        herdr_agents_note "retire_agent failed: $response"
        return 1
    }
    # A streamed answer arrives as an SSE "data:" line.
    response="$(sed -n 's/^data: //p; /^{/p' <<<"$response" | tail -n 1)"
    if [[ "$(jq -r '(.error != null) or (.result.isError == true)' <<<"$response" 2>/dev/null)" != false ]]; then
        herdr_agents_note "retire_agent refused: $(jq -r '.error.message // (.result.content[0].text // .)' <<<"$response" 2>/dev/null || printf '%s' "$response")"
        return 1
    fi
}

herdr_agents_retire() {
    local workspace="" cwd="" dry_run=false token="${AGENT_MAIL_REGISTRATION_TOKEN:-}" mail_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --cwd) [[ $# -ge 2 ]] || herdr_agents_die "--cwd needs a value"; cwd="$2"; shift 2 ;;
            --token) [[ $# -ge 2 ]] || herdr_agents_die "--token needs a value"; token="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            -*) herdr_agents_die "unknown retire option: $1" ;;
            *) [[ -z "$mail_name" ]] || herdr_agents_die "retire takes one agent name"; mail_name="$1"; shift ;;
        esac
    done
    [[ -n "$mail_name" ]] || herdr_agents_die "retire needs the agent's Agent Mail name"
    herdr_agents_require herdr jq am git
    [[ -z "$token" ]] || herdr_agents_require curl
    if [[ -z "$cwd" ]]; then
        cwd="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    [[ -d "$cwd" ]] || herdr_agents_die "--cwd is not a directory: $cwd"
    cwd="$(cd "$cwd" && pwd -P)"
    local herdr_name
    herdr_name="$(herdr_agents_herdr_name "$mail_name")" || herdr_agents_die "$HERDR_AGENTS_NAME_ERROR"
    am agents show "$mail_name" --project "$cwd" --json >/dev/null 2>&1 \
        || herdr_agents_die "Agent Mail has no agent $mail_name in project $cwd"

    local -a refusals=() actions=()

    # 1. Reservations: the agent releases its own.
    local active held
    active="$(am robot reservations --project "$cwd" --all --json 2>/dev/null)" \
        || herdr_agents_die "could not read Agent Mail's reservations for $cwd"
    held="$(jq -r --arg a "$mail_name" '[.all_active[]? | select(.agent == $a) | .path] | join(", ")' <<<"$active")"
    [[ -z "$held" ]] || refusals+=("$mail_name still holds reservations: $held")

    # 2. Uncommitted changes it owns: a changed file that matches a pattern it
    # ever reserved, unless another agent holds that file now.
    local file pattern owned=""
    local -a ever=() others=()
    mapfile -t ever < <(herdr_agents_reserved_ever "$cwd" "$mail_name")
    mapfile -t others < <(jq -r --arg a "$mail_name" '.all_active[]? | select(.agent != $a) | .path' <<<"$active")
    if (( ${#ever[@]} > 0 )); then
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            local mine=false
            for pattern in "${ever[@]}"; do
                # shellcheck disable=SC2053 # the pattern is a reservation glob
                [[ "$file" == $pattern ]] && { mine=true; break; }
            done
            for pattern in "${others[@]}"; do
                # shellcheck disable=SC2053
                [[ "$file" == $pattern ]] && { mine=false; break; }
            done
            [[ "$mine" == false ]] || owned+="${owned:+, }$file"
        done < <(herdr_agents_dirty_files "$cwd")
    fi
    [[ -z "$owned" ]] || refusals+=("uncommitted changes in files $mail_name reserved: $owned")

    # 3. Its worktrees (a path naming the agent): a clean one whose HEAD is on
    # origin/main is removed; any other refuses the retirement.
    local wt
    local -a merged_worktrees=()
    while IFS= read -r wt; do
        [[ -n "$wt" && "$wt" != "$cwd" ]] || continue
        [[ "${wt,,}" == *"$herdr_name"* ]] || continue
        if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
            refusals+=("worktree $wt has uncommitted changes")
        elif ! git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
            refusals+=("worktree $wt is not merged to origin/main")
        else
            merged_worktrees+=("$wt")
            actions+=("remove merged worktree $wt (git worktree remove)")
        fi
    done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

    # 4. Its pane: never a working agent, never this pane. A tab with other
    # panes keeps them, and only the agent's pane closes.
    herdr_agents_herdr agent list || herdr_agents_die "herdr agent list failed: $HERDR_AGENTS_ERR_MESSAGE"
    local agent pane="" tab="" tab_workspace="" status="" close_cmd=() pane_count
    agent="$(jq -c --arg n "$herdr_name" --arg w "$workspace" \
        '[.result.agents[]? | select(.name == $n) | select($w == "" or .workspace_id == $w)] | first // empty' <<<"$HERDR_AGENTS_OUT")"
    if [[ -n "$agent" ]]; then
        pane="$(jq -r '.pane_id' <<<"$agent")"
        tab="$(jq -r '.tab_id' <<<"$agent")"
        tab_workspace="$(jq -r '.workspace_id' <<<"$agent")"
        status="$(jq -r '.agent_status // "unknown"' <<<"$agent")"
    else
        # herdr can drop an agent's name (acfs-i7p); its tab keeps the label.
        tab_workspace="$workspace"
        [[ -n "$tab_workspace" ]] || tab_workspace="${HERDR_WORKSPACE_ID:-}"
    fi
    if [[ -n "$tab_workspace" ]]; then
        herdr_agents_herdr tab list --workspace "$tab_workspace" \
            || herdr_agents_die "herdr tab list failed: $HERDR_AGENTS_ERR_MESSAGE"
        local tab_row
        tab_row="$(jq -c --arg t "$tab" --arg l "$mail_name" \
            '[.result.tabs[]? | select(if $t != "" then .tab_id == $t else .label == $l end)] | first // empty' <<<"$HERDR_AGENTS_OUT")"
        if [[ -n "$tab_row" ]]; then
            tab="$(jq -r '.tab_id' <<<"$tab_row")"
            pane_count="$(jq -r '.pane_count // 1' <<<"$tab_row")"
            if [[ -n "$pane" ]] && (( pane_count > 1 )); then
                close_cmd=(pane close "$pane")
                actions+=("close pane $pane (tab $tab keeps its other panes)")
            elif [[ -n "$pane" ]] || (( pane_count == 1 )); then
                close_cmd=(tab close "$tab")
                actions+=("close tab $tab")
            else
                refusals+=("herdr lists no agent $herdr_name, and tab $tab labelled $mail_name has $pane_count panes")
            fi
        fi
    fi
    if [[ "$status" == working ]]; then
        refusals+=("$herdr_name is working; retire it once its turn is done")
    fi
    if [[ -n "${HERDR_PANE_ID:-}" && -n "$pane" && "$pane" == "$HERDR_PANE_ID" ]]; then
        refusals+=("$herdr_name runs in this pane")
    fi
    (( ${#close_cmd[@]} > 0 )) || herdr_agents_note "no herdr pane or tab found for $mail_name; nothing to close"

    if [[ -n "$token" ]]; then
        actions+=("soft-retire Agent Mail identity $mail_name (unretire_agent restores it)")
    else
        herdr_agents_note "no registration token (--token or AGENT_MAIL_REGISTRATION_TOKEN): the Agent Mail identity stays active; the agent can call retire_agent itself"
    fi

    local line
    if (( ${#refusals[@]} > 0 )); then
        for line in "${refusals[@]}"; do herdr_agents_note "refused: $line"; done
        return 1
    fi
    if [[ "$dry_run" == true ]]; then
        for line in "${actions[@]}"; do herdr_agents_note "would $line"; done
        return 0
    fi
    for wt in "${merged_worktrees[@]}"; do
        git -C "$cwd" worktree remove "$wt" || herdr_agents_die "git worktree remove $wt failed; retirement stopped"
        herdr_agents_note "removed worktree $wt"
    done
    if (( ${#close_cmd[@]} > 0 )); then
        herdr_agents_herdr "${close_cmd[@]}" \
            || herdr_agents_die "herdr ${close_cmd[*]} failed: $HERDR_AGENTS_ERR_MESSAGE"
        herdr_agents_note "closed ${close_cmd[0]} ${close_cmd[2]}"
    fi
    if [[ -n "$token" ]]; then
        herdr_agents_retire_identity "$cwd" "$mail_name" "$token" || return 1
        herdr_agents_note "retired Agent Mail identity $mail_name"
    fi
    herdr_agents_note "retired $mail_name"
}

herdr_agents_main() {
    local subcommand="${1:-help}"
    [[ $# -gt 0 ]] && shift
    case "$subcommand" in
        spawn) herdr_agents_spawn "$@" ;;
        send) herdr_agents_send "$@" ;;
        list|ls) herdr_agents_list "$@" ;;
        inbox) herdr_agents_inbox "$@" ;;
        codex-daemon) herdr_agents_codex_daemon "$@" ;;
        retire) herdr_agents_retire "$@" ;;
        help|-h|--help) herdr_agents_usage ;;
        *) herdr_agents_usage >&2; return 1 ;;
    esac
}

herdr_agents_main "$@"
