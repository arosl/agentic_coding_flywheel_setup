#!/usr/bin/env bash
# ============================================================
# ACFS herdr agents - spawn, prompt and list coding agents in herdr
#
# What ntm spawn/send did, over herdr 0.9's own commands. herdr has no
# multi-agent spawn and no broadcast: each agent is a tab plus
# `herdr agent start`, and a broadcast is a loop over `herdr agent list`
# and `herdr agent prompt`. This wraps exactly that and keeps no state, but
# for the mail cursors and timers of wake, limits and reap under
# ~/.acfs/state/.
#
# Names come from Agent Mail first (`am agents create`); the herdr name is
# that name lowercased, and the tab label is the Agent Mail name.
#
# Usage:
#   acfs agents spawn [--claude N] [--codex N] [--agy N] [--pi N] [--kind K [--count N]]...
#   acfs agents send (--all | --kind K | --name N)... <prompt>
#   acfs agents list [--workspace ID] [--kind K] [--json]
#   acfs agents inbox [--agent NAME] [--project KEY] [--keep-unread]
#   acfs agents wake [--workspace ID] [--project KEY] [--loop [--interval SEC]] [--dry-run]
#   acfs agents limits [--workspace ID] [--lines N] [--mail-from NAME [--project KEY]] [--loop [--interval SEC]] [--dry-run]
#   acfs agents codex-daemon (status [--json] | start | restart)
#   acfs agents retire <MailName> [--workspace ID] [--cwd DIR] [--token T] [--dry-run]
#   acfs agents recycle <MailName> [--prompt TEXT] [--dry-run]
#   acfs agents reap [--idle MIN] [--workspace ID] [--project KEY | --all-workspaces] [--loop [--interval SEC]] [--dry-run]
#   acfs agents quota [--json] | quota check <kind> | quota record-claude   (agent_quota.sh)
#   acfs agents sweep [--hours N] [--dir DIR] [--name-regex ERE] [--dry-run]   (temp_sweep.sh)
# ============================================================

set -euo pipefail

HERDR_AGENTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# capacity.sh, installed beside this script, answers spawn's capacity guard.
HERDR_AGENTS_CAPACITY_SCRIPT="${ACFS_AGENTS_CAPACITY_SCRIPT:-$HERDR_AGENTS_SCRIPT_DIR/capacity.sh}"
HERDR_AGENTS_NAME_PATTERN='^[a-z][a-z0-9_-]{0,31}$'
HERDR_AGENTS_NAME_ERROR=""
# How long a prompt may take to show that it was submitted (or, with send
# --wait, to finish), unless --timeout says otherwise.
HERDR_AGENTS_PROMPT_TIMEOUT_MS=15000
# The --limit inbox passes to am: far above any real mailbox. An answer this
# long could be a truncated one, so inbox refuses it.
HERDR_AGENTS_INBOX_LIMIT=1000000
# wake: what an agent is sent, and the fewest seconds between two wakes of one agent.
HERDR_AGENTS_WAKE_PROMPT="Check your Agent Mail inbox."
HERDR_AGENTS_WAKE_GAP=120
# recycle: what an agent is sent after its context is cleared, unless
# --prompt or ACFS_AGENTS_RECYCLE_PROMPT says otherwise.
HERDR_AGENTS_RECYCLE_PROMPT="You are {{agent}} in Agent Mail (herdr name {{herdr}}), project key {{project}}; your identity already exists. Fresh session: read AGENTS.md, then check your Agent Mail inbox and continue from there."
# reap: the labels that keep a bead from being bv's pick. Work only the
# operator can unblock is no work for an idle agent.
HERDR_AGENTS_REAP_NOT_READY_LABELS="hold,needs-operator"

herdr_agents_usage() {
    cat <<'EOF'
Usage:
  acfs agents spawn [--claude N] [--codex N] [--agy N] [--pi N] [--kind KIND [--count N]]...
                    [--workspace ID] [--cwd DIR] [--model MODEL]
                    [--prompt TEXT | --no-prompt] [--trust-folder] [--force] [--dry-run] [--json]
  acfs agents send  (--all | --kind KIND | --name NAME)... [--workspace ID]
                    [--wait] [--timeout MS] <prompt>
  acfs agents list  [--workspace ID] [--kind KIND] [--json]
  acfs agents inbox [--agent NAME] [--project KEY] [--keep-unread]
  acfs agents wake  [--workspace ID] [--project KEY] [--loop [--interval SEC]] [--dry-run]
  acfs agents limits [--workspace ID] [--lines N] [--mail-from NAME [--project KEY]]
                    [--loop [--interval SEC]] [--dry-run]
  acfs agents codex-daemon (status [--json] | start | restart)
  acfs agents retire <MailName> [--workspace ID] [--cwd DIR] [--token TOKEN] [--dry-run]
  acfs agents recycle <MailName> [--workspace ID] [--project KEY] [--prompt TEXT]
                    [--timeout MS] [--dry-run]
  acfs agents reap  [--idle MIN] [--workspace ID] [--project KEY | --all-workspaces]
                    [--loop [--interval SEC]] [--dry-run]
  acfs agents quota [--json] | quota check KIND [--limit PERCENT] | quota record-claude
  acfs agents sweep [--hours N] [--dir DIR] [--name-regex ERE] [--dry-run]

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
       Spawn refuses a kind whose plan has used $ACFS_AGENTS_QUOTA_LIMIT
       percent (default 90) of its 5-hour window, or reports a limit
       reached ('acfs agents quota check', before anything is created),
       and refuses when the host's capacity guard is red ('acfs capacity
       --guard --check': MemAvailable under 4 GiB, the --cwd or temp
       filesystem under 10% free, or PSI memory full avg60 over 10; its
       ACFS_CAPACITY_GUARD_* variables set the thresholds); --force spawns
       anyway. Unknown usage or capacity never refuses.
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
wake   Send "Check your Agent Mail inbox." to each idle agent of the workspace
       that got mail (To, cc or bcc) since it was last woken, or whose ack is
       newly overdue, through send's checked prompt. An agent's mailbox is its
       tab label, which spawn sets to its Agent Mail name. A working or
       blocked agent is left until it settles, an agent is woken at most once
       every 120 s, and the pane running wake is never prompted. Mail older
       than an agent's first wake cycle wakes nobody; each overdue ack wakes
       it once. One line per wake goes to stderr. --loop repeats every --interval seconds (default 60); run
       it in its own pane, or with --workspace from a user unit. The project
       key is --project, else $AGENT_MAIL_PROJECT, else the git top level;
       per-agent cursors live in ~/.acfs/state/wake/.
limits Report each agent of the workspace that a usage or rate limit stopped:
       one that is not working and whose screen's bottom --lines lines
       (default 15) show its kind's limit message (claude, codex, agy and
       gemini each have their own patterns). The report is a herdr
       notification and one line on stderr, and with --mail-from NAME also
       an Agent Mail message from NAME to the agent's tab label (its Agent
       Mail name). Each message is reported once, until it leaves the
       screen. Nothing runs this by default: start it with --loop (every
       --interval seconds, default 60) in its own pane, or with --workspace
       from a user unit. Per-agent state lives in ~/.acfs/state/limits/.
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
       path names it is dirty or not merged to origin/main (exit 2, and
       nothing is done; any other failure exits 1). Otherwise it
       removes its merged worktrees (git worktree remove, never --force),
       closes its herdr pane (its tab, when that is the tab's only pane) and,
       given the agent's registration token (--token or
       AGENT_MAIL_REGISTRATION_TOKEN), soft-retires its Agent Mail identity;
       unretire_agent restores it. --dry-run lists what it would do.
recycle
       Give an agent a fresh context in its own pane, tab and names, between
       two tasks: send /clear (Claude Code) or /new (Codex), see that it
       took, then send the prompt. Claude Code must show a new session in
       herdr; Codex, which reports none, must show an empty input box. The
       prompt is --prompt, else $ACFS_AGENTS_RECYCLE_PROMPT, else one that
       tells the agent who it is and to reread AGENTS.md and its inbox;
       {{agent}}, {{herdr}} and {{project}} in it become the Agent Mail
       name, the herdr name and the project key. Refuses, sending nothing,
       an agent that is not idle or done, or whose screen shows a dialog or
       unsent text (exit 2), and the pane running recycle (exit 1).
reap   Retire, through retire and all its refusals, each agent of this
       project (--project, else $AGENT_MAIL_PROJECT, else the git top level;
       an agent's project is its cwd) and of this workspace (--workspace,
       else $HERDR_WORKSPACE_ID, else any) that is done, with no work left:
       idle or done for --idle minutes (default 60), with no bead in progress
       assigned to its Agent Mail name (the first word of its tab label; any
       case), while its project has no work for it either. --all-workspaces
       reaps every workspace and project of the herdr server.
       A project has work while 'bv --robot-next --robot-not-ready-labels
       hold,needs-operator' has a pick there, or an open bead waits on a bead
       in progress (an agent waiting on a dependency; epics don't count):
       agents take their next bead themselves, and stop when bv has none for
       them. So while bv has a pick, reap retires nobody in that project; an
       agent that stopped anyway is retired by hand. An agent is busy,
       and kept, while it holds a file reservation or has unread mail or acks
       pending (a review or question it has yet to answer). Idle time is what
       reap itself saw: herdr reports no timestamps, so an agent counts from
       the first cycle that saw it between turns, and starts again when its
       state changes. A refused agent is tried again after another --idle
       minutes (at least 5). An in-progress bead with no assignee keeps
       nobody, and an agent waiting between turns on its own background work
       (a CI watch, a subagent) looks idle: claim beads with an assignee, and
       give such waits less than --idle minutes.
       Never reaped: the focused pane, the pane running reap, and a name the
       keep list in ~/.config/acfs/agents.toml ($ACFS_AGENTS_CONFIG) holds,
       in any project and any case: sessions you mark as your own, and
       agents whose role keeps them (a reviewer):
         [reap]
         keep = ["GreenCastle"]
       A config that can't be read, or holds any other key, reaps nobody;
       the old key, protected, is read as keep, with a warning.
       Each retirement is mailed, from the retired agent, to the keep-listed
       agents its project has. A refused retirement is logged and is no
       failure; reap exits non-zero when herdr, the config, an agent's beads,
       reservations or mail can't be read, or when a retirement or its mail
       fails for another reason. A retired agent's Agent Mail identity stays
       active (reap has no registration tokens; 'am agents reap' sweeps
       stale ones).
       --dry-run retires nothing, and says what it would do and why it
       keeps each agent. --loop repeats every --interval seconds
       (default 60); state lives in ~/.acfs/state/reap/. Nothing runs reap
       by default. A systemd user timer runs it unattended; installing one
       is a host unit change, the operator's call. The unit runs an
       installed acfs, never a working tree whose uncommitted edits would
       run unattended, in the project it reaps. The user manager's PATH
       has none of the user's tool directories, so the unit sets one; the
       installed acfs must be one that has this reap (acfs-update):
         ~/.config/systemd/user/acfs-agents-reap.service
           [Service]
           Type=oneshot
           WorkingDirectory=/data/projects/app
           Environment=PATH=%h/.local/bin:%h/.bun/bin:%h/.cargo/bin:/usr/local/bin:/usr/bin:/bin
           ExecStart=%h/.acfs/bin/acfs agents reap
         ~/.config/systemd/user/acfs-agents-reap.timer
           [Timer]
           OnBootSec=5min
           OnUnitActiveSec=5min
           [Install]
           WantedBy=timers.target
         systemctl --user enable --now acfs-agents-reap.timer
quota  Show how full each plan's 5-hour and weekly usage windows are, and how
       many live agents of each kind there are (agent_quota.sh; see
       'acfs agents quota --help'). Read-only.
sweep  Remove the temp dirs tests and browsers left in /tmp and $TMPDIR:
       only test-made names, owned by you, unchanged for --hours (6), holding
       no git worktree and used by no process (temp_sweep.sh; see
       'acfs agents sweep --help'). --dry-run lists them.

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
    local dry_run=false json=false trust_folder=false force=false
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
            --claude|--codex|--agy|--gemini|--pi)
                [[ $# -ge 2 ]] || herdr_agents_die "$1 needs a count"
                herdr_agents_add_kind "${1#--}" "$2"; shift 2 ;;
            --claude=*|--codex=*|--agy=*|--gemini=*|--pi=*)
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
            --force) force=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --json) json=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown spawn option: $1" ;;
        esac
    done
    [[ -z "$pending_kind" ]] || herdr_agents_add_kind "$pending_kind" 1
    (( ${#kinds[@]} > 0 )) || herdr_agents_die "nothing to spawn: pass --claude N, --codex N, --agy N, --pi N or --kind KIND [--count N]"
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
    # An agent spawned on a plan whose window is nearly used up stalls at its
    # first turns (acfs-ybg). Checked once per kind, before anything exists.
    if [[ "$force" == false ]]; then
        local quota_kind quota_status
        for quota_kind in $(printf '%s\n' "${kinds[@]}" | sort -u); do
            quota_status=0
            bash "$HERDR_AGENTS_SCRIPT_DIR/agent_quota.sh" check "$quota_kind" || quota_status=$?
            case "$quota_status" in
                0) ;;
                1) herdr_agents_die "spawn refused: $quota_kind is near its usage limit (see 'acfs agents quota'); --force spawns anyway" ;;
                *) herdr_agents_note "could not check $quota_kind's usage (agent_quota.sh exited $quota_status); spawning anyway" ;;
            esac
        done
    fi
    if [[ -z "$cwd" ]]; then
        cwd="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    [[ -d "$cwd" ]] || herdr_agents_die "--cwd is not a directory: $cwd"
    cwd="$(cd "$cwd" && pwd -P)"
    # Each Claude agent holds about 450 MB with its MCP servers: spawning into
    # a host short of memory gets agents and Agent Mail OOM-killed, and one
    # short of disk fails their writes (acfs-2xtg, acfs-gmbo). The guard
    # prints its reasons to stderr.
    if [[ "$force" == false ]]; then
        local guard_status=0
        if [[ -r "$HERDR_AGENTS_CAPACITY_SCRIPT" ]]; then
            ACFS_CAPACITY_WORK_DIR="$cwd" bash "$HERDR_AGENTS_CAPACITY_SCRIPT" --guard --check || guard_status=$?
        else
            guard_status=127
        fi
        case "$guard_status" in
            0) ;;
            1) herdr_agents_die "spawn refused: the host's capacity guard is red (see 'acfs capacity --guard'); retire idle agents ('acfs agents reap'), or --force spawns anyway" ;;
            127) herdr_agents_note "could not check the host's capacity ($HERDR_AGENTS_CAPACITY_SCRIPT not found); spawning anyway" ;;
            *) herdr_agents_note "could not check the host's capacity (capacity.sh exited $guard_status); spawning anyway" ;;
        esac
    fi

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

    local agents count i target name pane missing
    local sent=0 skipped=0
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
        if herdr_agents_prompt_one "$target" "$prompt" "$timeout" "$wait"; then
            sent=$((sent + 1))
        else
            skipped=$((skipped + 1))
        fi
    done
    herdr_agents_note "sent $sent, skipped $skipped"
    (( skipped == 0 ))
}

# Prompt one agent ($1, its herdr name or pane id) with $2 and report how it
# went. Always waits, so a prompt that was not submitted is a failure: with
# $4 = true until the turn ends, otherwise only until the agent is seen
# working (or blocked at a dialog the prompt raised; a prompt to an agent
# already working is queued), for at most $3 ms. $5 = quiet reports only a
# failure. Returns non-zero when the prompt was not taken.
herdr_agents_prompt_one() {
    local target="$1" prompt="$2" timeout="$3" wait="$4" quiet="${5:-}" state
    local -a prompt_args=(--wait)
    [[ "$wait" == true ]] || prompt_args+=(--until working --until blocked)
    prompt_args+=(--timeout "$timeout")
    if herdr_agents_herdr agent prompt "$target" "$prompt" "${prompt_args[@]}"; then
        [[ "$quiet" != quiet ]] || return 0
        state="$(jq -r '.result.agent.agent_status // empty' <<<"$HERDR_AGENTS_OUT")"
        if [[ "$state" == blocked ]]; then
            herdr_agents_note "sent: $target, which is now blocked at an approval or question"
        else
            herdr_agents_note "sent: $target${state:+ ($state)}"
        fi
        return 0
    fi
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
    return 1
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

# ------------------------------------------------------------
# wake
# ------------------------------------------------------------

# One wake cycle over the agents of workspace $1, for Agent Mail project $2,
# keeping each agent's state in $3; $4 = true only says what it would do.
# Fails when any wake failed. herdr names an agent by its Agent Mail name
# lowercased, and its tab label is that name (spawn sets both), so the label
# maps a herdr agent to its mailbox; an agent whose tab carries no such
# label is not one ACFS started, and is left alone.
herdr_agents_wake_cycle() {
    local workspace="$1" project="$2" state_dir="$3" dry_run="$4"
    local agents tabs count i name pane tab status mail_name failed=0
    agents="$(herdr_agents_select "$workspace" "[]" "[]")"
    herdr_agents_herdr tab list --workspace "$workspace" \
        || herdr_agents_die "herdr tab list failed: $HERDR_AGENTS_ERR_MESSAGE"
    tabs="$HERDR_AGENTS_OUT"
    count="$(jq 'length' <<<"$agents")"
    for ((i = 0; i < count; i++)); do
        name="$(jq -r ".[$i].name // empty" <<<"$agents")"
        pane="$(jq -r ".[$i].pane_id" <<<"$agents")"
        tab="$(jq -r ".[$i].tab_id // empty" <<<"$agents")"
        status="$(jq -r ".[$i].agent_status // \"unknown\"" <<<"$agents")"
        # Never prompt the pane running the loop.
        [[ -z "${HERDR_PANE_ID:-}" || "$pane" != "$HERDR_PANE_ID" ]] || continue
        mail_name="$(jq -r --arg t "$tab" 'first(.result.tabs[]? | select(.tab_id == $t) | .label // empty) // empty' <<<"$tabs")"
        [[ "$mail_name" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] || continue
        # herdr can drop an agent's name (acfs-i7p); its pane still answers.
        [[ -z "$name" || "$name" == "${mail_name,,}" ]] || continue
        herdr_agents_wake_one "$mail_name" "${name:-$pane}" "$status" "$project" "$state_dir" "$dry_run" \
            || failed=$((failed + 1))
    done
    (( failed == 0 ))
}

# Write agent state $2 (JSON) to file $1, whole or not at all.
herdr_agents_wake_save() {
    printf '%s\n' "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"
}

# Wake agent $1 (Agent Mail name; herdr target $2, herdr status $3) when
# mail reached it since its last wake. Its state file holds the Agent Mail
# delivery cursor it was last woken at, when that was, and the overdue acks
# it was already woken for. Mail older than the agent's first cycle wakes
# nobody, but each overdue ack wakes it once, however old.
herdr_agents_wake_one() {
    local mail_name="$1" target="$2" status="$3" project="$4" state_dir="$5" dry_run="$6"
    local file="$state_dir/$mail_name.json" state cursor scan last now page events=0 has_more
    local overdue new_overdue reason
    now="$(date +%s)"
    # A missing or unreadable state file counts as the agent's first cycle.
    state="$(jq -c 'select((.cursor | type) == "number" and (.last_wake | type) == "number" and (.overdue | type) == "array")' \
        "$file" 2>/dev/null || true)"
    if [[ -z "$state" ]]; then
        page="$(am inbox-events --agent "$mail_name" --project "$project" --position-now --json </dev/null)" \
            || { herdr_agents_note "wake: am inbox-events failed for $mail_name"; return 1; }
        state="$(jq -c '{cursor: .next_cursor, last_wake: 0, overdue: []}' <<<"$page")" \
            || { herdr_agents_note "wake: could not read am's inbox events for $mail_name"; return 1; }
        [[ "$dry_run" == true ]] || herdr_agents_wake_save "$file" "$state"
    fi
    # A working agent reads its mail when its turn ends, and a blocked one
    # waits for a person; both are looked at again next cycle.
    case "$status" in
        idle|done) ;;
        *) return 0 ;;
    esac
    last="$(jq -r '.last_wake' <<<"$state")"
    (( now - last >= HERDR_AGENTS_WAKE_GAP )) || return 0

    cursor="$(jq -r '.cursor' <<<"$state")"
    scan="$cursor"
    while :; do
        page="$(am inbox-events --agent "$mail_name" --project "$project" --after "$scan" --limit 1000 --json </dev/null)" \
            || { herdr_agents_note "wake: am inbox-events failed for $mail_name"; return 1; }
        events=$((events + $(jq '[.events[]? | select(.kind == "to" or .kind == "cc" or .kind == "bcc")] | length' <<<"$page")))
        scan="$(jq -r '.next_cursor' <<<"$page")"
        has_more="$(jq -r '.has_more' <<<"$page")"
        [[ "$has_more" == true ]] || break
    done
    # am prints overdue acks as a table only: an ID column of message ids.
    overdue="$(am acks overdue "$project" "$mail_name" </dev/null \
        | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 }' | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')" \
        || { herdr_agents_note "wake: am acks overdue failed for $mail_name"; return 1; }
    new_overdue="$(jq -n --argjson now "$overdue" --argjson seen "$(jq -c '.overdue' <<<"$state")" '$now - $seen | length')"

    if (( events == 0 && new_overdue == 0 )); then
        [[ "$dry_run" == true ]] || herdr_agents_wake_save "$file" \
            "$(jq -c --argjson c "$scan" --argjson o "$overdue" '.cursor = $c | .overdue = $o' <<<"$state")"
        return 0
    fi
    reason="$events new message(s)"
    (( new_overdue == 0 )) || reason+=", $new_overdue newly overdue ack(s)"
    if [[ "$dry_run" == true ]]; then
        herdr_agents_note "would wake $target ($mail_name): $reason"
        return 0
    fi
    if herdr_agents_prompt_one "$target" "$HERDR_AGENTS_WAKE_PROMPT" "$HERDR_AGENTS_PROMPT_TIMEOUT_MS" false quiet; then
        herdr_agents_note "$(date -u +%Y-%m-%dT%H:%M:%SZ) woke $target ($mail_name): $reason"
        herdr_agents_wake_save "$file" \
            "$(jq -c --argjson c "$scan" --argjson o "$overdue" --argjson t "$now" '.cursor = $c | .overdue = $o | .last_wake = $t' <<<"$state")"
        return 0
    fi
    # The cursor stays, so the next cycle after the gap tries again.
    herdr_agents_note "$(date -u +%Y-%m-%dT%H:%M:%SZ) could not wake $target ($mail_name): $reason"
    herdr_agents_wake_save "$file" "$(jq -c --argjson t "$now" '.last_wake = $t' <<<"$state")"
    return 1
}

herdr_agents_wake() {
    local workspace="" project="${AGENT_MAIL_PROJECT:-}" loop=false interval=60 dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --project) [[ $# -ge 2 ]] || herdr_agents_die "--project needs a value"; project="$2"; shift 2 ;;
            --loop) loop=true; shift ;;
            --interval) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || herdr_agents_die "--interval needs whole seconds"; interval="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown wake option: $1" ;;
        esac
    done
    herdr_agents_require herdr am jq flock sha256sum
    workspace="$(herdr_agents_resolve_workspace "$workspace")"
    if [[ -z "$project" ]]; then
        project="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi

    local state_dir lock_fd
    state_dir="${ACFS_HOME:-$HOME/.acfs}/state/wake/$(printf '%s' "$project" | sha256sum | cut -c1-16)"
    mkdir -p "$state_dir"
    printf '%s\n' "$project" >"$state_dir/project"
    # Two loops over one project would wake each agent twice.
    exec {lock_fd}>"$state_dir/lock"
    flock -n "$lock_fd" || herdr_agents_die "another acfs agents wake is running for $project"

    if [[ "$loop" == false ]]; then
        herdr_agents_wake_cycle "$workspace" "$project" "$state_dir" "$dry_run"
        return
    fi
    herdr_agents_note "waking idle agents in workspace $workspace on new mail, every ${interval}s"
    while :; do
        # A failed cycle (herdr or am unreachable) ends only that cycle.
        ( herdr_agents_wake_cycle "$workspace" "$project" "$state_dir" "$dry_run" ) || true
        sleep "$interval"
    done
}

# ------------------------------------------------------------
# limits
# ------------------------------------------------------------

# What agent kind $1 prints when its plan's usage limit or the API's rate
# limit stops it, as one case-insensitive extended regex: the one place
# these patterns live. Whole phrases, never a bare "rate limit", so that an
# agent's own prose about limits rarely matches. A kind without patterns of
# its own gets the generic ones.
herdr_agents_limit_pattern() {
    case "$1" in
        claude)
            printf '%s\n' "usage limit reached|you('|’)ve (hit|reached) your ([a-z0-9-]+ )?limit|(5-hour|session|weekly|opus|sonnet) limit reached|rate_limit_error|api error: 429" ;;
        codex)
            printf '%s\n' "you('|’)ve hit your usage limit|usage limit (has been )?reached|rate limit reached|429 too many requests" ;;
        agy|gemini)
            printf '%s\n' "resource_exhausted|quota (exceeded|exhausted)|(reached|exhausted) (your|the) [a-z0-9. -]{0,30}quota|usage limit reached|429 too many requests" ;;
        *)
            printf '%s\n' "usage limit reached|rate limit reached|quota exceeded|429 too many requests" ;;
    esac
}

# One pass over the workspace's agents: report each one newly stopped at a
# limit. An agent's state file holds the limit line last reported for it
# (empty once that line left its screen), so each line is reported once.
herdr_agents_limits_cycle() {
    local workspace="$1" lines="$2" state_dir="$3" mail_from="$4" project="$5" dry_run="$6"
    local agents tabs="" count i name pane tab kind status target line seen file mail_name failed=0
    agents="$(herdr_agents_select "$workspace" "[]" "[]")"
    if [[ -n "$mail_from" ]]; then
        herdr_agents_herdr tab list --workspace "$workspace" \
            || herdr_agents_die "herdr tab list failed: $HERDR_AGENTS_ERR_MESSAGE"
        tabs="$HERDR_AGENTS_OUT"
    fi
    count="$(jq 'length' <<<"$agents")"
    for ((i = 0; i < count; i++)); do
        name="$(jq -r ".[$i].name // empty" <<<"$agents")"
        pane="$(jq -r ".[$i].pane_id" <<<"$agents")"
        tab="$(jq -r ".[$i].tab_id // empty" <<<"$agents")"
        kind="$(jq -r ".[$i].agent // empty" <<<"$agents")"
        status="$(jq -r ".[$i].agent_status // \"unknown\"" <<<"$agents")"
        # A limit stops the agent, so a working one has not hit one.
        [[ "$status" != working ]] || continue
        target="${name:-$pane}"
        file="$state_dir/${pane//[^A-Za-z0-9_-]/_}"
        if ! herdr_agents_herdr agent read "$target" --source visible --lines "$lines" --format text; then
            herdr_agents_note "limits: could not read $target ($HERDR_AGENTS_ERR_CODE): $HERDR_AGENTS_ERR_MESSAGE"
            failed=$((failed + 1))
            continue
        fi
        line="$(grep -aiE -- "$(herdr_agents_limit_pattern "$kind")" <<<"$HERDR_AGENTS_OUT" | tail -n 1 \
            | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
        line="${line:0:200}"
        seen="$(cat "$file" 2>/dev/null || true)"
        if [[ -z "$line" ]]; then
            [[ -z "$seen" || "$dry_run" == true ]] || : >"$file"
            continue
        fi
        [[ "$line" != "$seen" ]] || continue
        if [[ "$dry_run" == true ]]; then
            herdr_agents_note "would report $target ($kind): $line"
            continue
        fi
        herdr_agents_note "$(date -u +%Y-%m-%dT%H:%M:%SZ) $target ($kind) stopped at a limit: $line"
        if ! herdr_agents_herdr notification show "$target stopped at a limit" --body "$line" --sound request; then
            herdr_agents_note "limits: herdr notification failed ($HERDR_AGENTS_ERR_CODE): $HERDR_AGENTS_ERR_MESSAGE"
            failed=$((failed + 1))
        fi
        if [[ -n "$mail_from" ]]; then
            mail_name="$(jq -r --arg t "$tab" 'first(.result.tabs[]? | select(.tab_id == $t) | .label // empty) // empty' <<<"$tabs")"
            if [[ ! "$mail_name" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]]; then
                herdr_agents_note "limits: no mail for $target: its tab label is not an Agent Mail name"
            elif ! am mail send --project "$project" --from "$mail_from" --to "$mail_name" \
                --subject "[limits] $mail_name stopped at a usage or rate limit" \
                --body "herdr showed $target ($kind) stopped at a limit at $(date -u +%Y-%m-%dT%H:%M:%SZ):"$'\n\n'"    $line"$'\n\n'"Its work waits until the limit resets; hand it over if it can't wait." \
                </dev/null >/dev/null; then
                herdr_agents_note "limits: am mail send failed for $mail_name"
                failed=$((failed + 1))
            fi
        fi
        printf '%s\n' "$line" >"$file"
    done
    (( failed == 0 ))
}

herdr_agents_limits() {
    local workspace="" project="${AGENT_MAIL_PROJECT:-}" mail_from="" lines=15 loop=false interval=60 dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --lines) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || herdr_agents_die "--lines needs a whole number above zero"; lines="$2"; shift 2 ;;
            --mail-from) [[ $# -ge 2 ]] || herdr_agents_die "--mail-from needs an Agent Mail name"; mail_from="$2"; shift 2 ;;
            --project) [[ $# -ge 2 ]] || herdr_agents_die "--project needs a value"; project="$2"; shift 2 ;;
            --loop) loop=true; shift ;;
            --interval) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || herdr_agents_die "--interval needs whole seconds"; interval="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown limits option: $1" ;;
        esac
    done
    herdr_agents_require herdr jq flock
    workspace="$(herdr_agents_resolve_workspace "$workspace")"
    if [[ -n "$mail_from" ]]; then
        herdr_agents_require am
        [[ -n "$project" ]] || project="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi

    local state_dir lock_fd
    state_dir="${ACFS_HOME:-$HOME/.acfs}/state/limits/${workspace//[^A-Za-z0-9_-]/_}"
    mkdir -p "$state_dir"
    # Two watchers over one workspace would report each limit twice.
    exec {lock_fd}>"$state_dir/lock"
    flock -n "$lock_fd" || herdr_agents_die "another acfs agents limits is running for workspace $workspace"

    if [[ "$loop" == false ]]; then
        herdr_agents_limits_cycle "$workspace" "$lines" "$state_dir" "$mail_from" "$project" "$dry_run"
        return
    fi
    herdr_agents_note "watching workspace $workspace for agents stopped at a limit, every ${interval}s"
    while :; do
        # A failed cycle (herdr or am unreachable) ends only that cycle.
        ( herdr_agents_limits_cycle "$workspace" "$lines" "$state_dir" "$mail_from" "$project" "$dry_run" ) || true
        sleep "$interval"
    done
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
        return 2
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

# ------------------------------------------------------------
# recycle
# ------------------------------------------------------------

# Prompt template $1 with {{agent}} (Agent Mail name $2), {{herdr}} (herdr
# name $3) and {{project}} ($4) filled in. The replacements are quoted, so
# an & in them stays literal under patsub_replacement.
herdr_agents_recycle_prompt() {
    local text="$1"
    text="${text//\{\{agent\}\}/"$2"}"
    text="${text//\{\{herdr\}\}/"$3"}"
    text="${text//\{\{project\}\}/"$4"}"
    printf '%s\n' "$text"
}

# Recycle agent $1 (Agent Mail name) in workspace $2 ("" = any): send its
# kind's clear command, see that it took, then send the prompt from
# template $4 (project key $3), each confirmed within $5 ms. $6 = true only
# says what it would do. Returns 0 when recycled, 2 when the agent is not
# between turns yet (working, blocked, a dialog or unsent text on its
# screen) and nothing was sent, 1 on any other failure.
herdr_agents_recycle_one() {
    local mail_name="$1" workspace="$2" project="$3" template="$4" timeout="$5" dry_run="$6"
    local herdr_name agents count agent status kind pane before command state prompt i
    local tries="${HERDR_AGENTS_RECYCLE_WAIT_TRIES:-30}" interval="${HERDR_AGENTS_RECYCLE_WAIT_INTERVAL:-0.5}"
    herdr_name="$(herdr_agents_herdr_name "$mail_name")" || { herdr_agents_note "recycle: $HERDR_AGENTS_NAME_ERROR"; return 1; }
    # select dies on a failed `herdr agent list`; here that only ends its subshell.
    agents="$(herdr_agents_select "$workspace" "[]" "$(jq -nc --arg n "$herdr_name" '[$n]')")" || return 1
    count="$(jq 'length' <<<"$agents")"
    if (( count != 1 )); then
        herdr_agents_note "recycle: herdr lists $count agents named $herdr_name${workspace:+ in workspace $workspace}; its herdr name may have dropped (see 'acfs agents list')"
        return 1
    fi
    agent="$(jq -c '.[0]' <<<"$agents")"
    status="$(jq -r '.agent_status // "unknown"' <<<"$agent")"
    kind="$(jq -r '.agent // empty' <<<"$agent")"
    pane="$(jq -r '.pane_id' <<<"$agent")"
    before="$(jq -r '.agent_session.value // empty' <<<"$agent")"
    if [[ -n "${HERDR_PANE_ID:-}" && "$pane" == "$HERDR_PANE_ID" ]]; then
        herdr_agents_note "recycle: $herdr_name runs in this pane"
        return 1
    fi
    case "$kind" in
        claude) command=/clear ;;
        codex) command=/new ;;
        *) herdr_agents_note "recycle: $herdr_name is a ${kind:-unknown} agent; recycle knows claude (/clear) and codex (/new)"; return 1 ;;
    esac
    case "$status" in
        idle|done) ;;
        *) herdr_agents_note "recycle: $herdr_name is $status; an agent is recycled only between turns (idle or done)"; return 2 ;;
    esac
    # Never type over a dialog or over text someone typed and has not sent.
    if ! herdr_agents_herdr agent read "$herdr_name" --source visible --lines 30 --format ansi; then
        herdr_agents_note "recycle: the screen of $herdr_name could not be read ($HERDR_AGENTS_ERR_CODE)"
        return 1
    fi
    state="$(herdr_agents_screen_state <<<"$HERDR_AGENTS_OUT")"
    case "$state" in
        empty|suggestion) ;;
        dialog) herdr_agents_note "recycle: a dialog is on the screen of $herdr_name; answer it in its pane first"; return 2 ;;
        typed) herdr_agents_note "recycle: unsent text is in the input box of $herdr_name; look at its pane first"; return 2 ;;
        *) herdr_agents_note "recycle: no input box is recognised on the screen of $herdr_name"; return 2 ;;
    esac
    prompt="$(herdr_agents_recycle_prompt "$template" "$mail_name" "$herdr_name" "$project")"
    if [[ "$dry_run" == true ]]; then
        herdr_agents_note "would recycle $herdr_name ($mail_name): send $command, then: $prompt"
        return 0
    fi

    if ! herdr_agents_herdr agent prompt "$herdr_name" "$command"; then
        herdr_agents_note "recycle: $command was not sent to $herdr_name ($HERDR_AGENTS_ERR_CODE): $HERDR_AGENTS_ERR_MESSAGE"
        return 1
    fi
    # Claude Code starts a new session on /clear, which herdr reports as a
    # new agent_session. Codex reports no session, so for it the command
    # must at least have left the input box (it is not still typed there).
    for ((i = 0; i < tries; i++)); do
        if [[ -n "$before" ]]; then
            herdr_agents_herdr agent get "$herdr_name" \
                && jq -e --arg b "$before" '.result.agent
                    | (.agent_session.value // "") as $s
                    | $s != "" and $s != $b and (.agent_status == "idle" or .agent_status == "done")' \
                    <<<"$HERDR_AGENTS_OUT" >/dev/null 2>&1 \
                && break
        elif herdr_agents_herdr agent read "$herdr_name" --source visible --lines 30 --format ansi; then
            state="$(herdr_agents_screen_state <<<"$HERDR_AGENTS_OUT")"
            [[ "$state" != empty && "$state" != suggestion ]] || break
        fi
        sleep "$interval"
    done
    if (( i == tries )); then
        herdr_agents_note "recycle: $herdr_name shows no fresh session after $command; look at its pane (the prompt was not sent)"
        return 1
    fi
    herdr_agents_prompt_one "$herdr_name" "$prompt" "$timeout" false quiet || return 1
    herdr_agents_note "$(date -u +%Y-%m-%dT%H:%M:%SZ) recycled $herdr_name ($mail_name): $command, then the prompt"
}

herdr_agents_recycle() {
    local workspace="" project="${AGENT_MAIL_PROJECT:-}" dry_run=false
    local mail_name="" timeout="$HERDR_AGENTS_PROMPT_TIMEOUT_MS"
    local template="${ACFS_AGENTS_RECYCLE_PROMPT:-$HERDR_AGENTS_RECYCLE_PROMPT}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --project) [[ $# -ge 2 ]] || herdr_agents_die "--project needs a value"; project="$2"; shift 2 ;;
            --prompt) [[ $# -ge 2 && -n "$2" ]] || herdr_agents_die "--prompt needs a text"; template="$2"; shift 2 ;;
            --timeout) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || herdr_agents_die "--timeout needs milliseconds"; timeout="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            -*) herdr_agents_die "unknown recycle option: $1" ;;
            *) [[ -z "$mail_name" ]] || herdr_agents_die "recycle takes one agent name"; mail_name="$1"; shift ;;
        esac
    done
    [[ -n "$mail_name" ]] || herdr_agents_die "recycle needs the agent's Agent Mail name"
    if [[ -z "$project" ]]; then
        project="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    herdr_agents_require herdr jq
    local rc=0
    herdr_agents_recycle_one "$mail_name" "$workspace" "$project" "$template" "$timeout" "$dry_run" || rc=$?
    return "$rc"
}

# ------------------------------------------------------------
# reap
# ------------------------------------------------------------

# The names agents.toml's [reap] keep list holds, as a JSON array. No file
# keeps nothing by name; a file that can't be read, or holds any other key
# under [reap], fails, so that reap retires nobody. The old key, protected,
# is read as keep too, with a warning, until the configs are migrated.
herdr_agents_reap_config() {
    local file="${ACFS_AGENTS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/acfs/agents.toml}"
    if [[ ! -e "$file" ]]; then
        printf '[]\n'
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { herdr_agents_note "reap: reading $file needs python3; nobody is reaped"; return 1; }
    python3 -I - "$file" <<'PY' || { herdr_agents_note "reap: $file is not a valid reap config; nobody is reaped"; return 1; }
import json
import sys
import tomllib

try:
    with open(sys.argv[1], "rb") as handle:
        reap = tomllib.load(handle).get("reap", {})
except (OSError, tomllib.TOMLDecodeError) as error:
    sys.exit(f"{sys.argv[1]}: {error}")
if not isinstance(reap, dict):
    sys.exit("[reap] must be a table")
unknown = sorted(set(reap) - {"keep", "protected"})
if unknown:
    sys.exit(f"[reap] takes only keep, not: {', '.join(unknown)}")
names = []
for key in ("keep", "protected"):
    value = reap.get(key, [])
    if not isinstance(value, list) or not all(isinstance(name, str) for name in value):
        sys.exit(f"reap.{key} must be a list of Agent Mail names")
    names += value
if "protected" in reap:
    print(f"reap: {sys.argv[1]}: [reap] protected is read as keep; rename it to keep", file=sys.stderr)
print(json.dumps(names))
PY
}

# What reap needs from the herdr server: HERDR_AGENTS_REAP_KEEP
# (agents.toml's keep list) and HERDR_AGENTS_REAP_AGENTS (herdr's agents in
# workspace $1, "" = every one, whose cwd is project $2, "" = any).
HERDR_AGENTS_REAP_KEEP=""
HERDR_AGENTS_REAP_AGENTS=""
herdr_agents_reap_load() {
    local agents
    HERDR_AGENTS_REAP_KEEP="$(herdr_agents_reap_config)" || return 1
    # select dies on a failed `herdr agent list`; here that only ends its subshell.
    agents="$(herdr_agents_select "$1" "[]" "[]")" || return 1
    HERDR_AGENTS_REAP_AGENTS="$(jq -c --arg p "$2" 'map(select($p == "" or .cwd == $p))' <<<"$agents")"
}

# Why agent $1 (herdr's JSON for it; Agent Mail name $2) is never reaped, or
# nothing when it may be.
herdr_agents_reap_exemption() {
    jq -r --arg mail "${2,,}" --arg self "${HERDR_PANE_ID:-}" --argjson keep "$HERDR_AGENTS_REAP_KEEP" '
        if .focused == true then "it is the focused pane"
        elif $self != "" and .pane_id == $self then "it runs in this pane"
        elif $keep | map(ascii_downcase) | index($mail) then "agents.toml keeps it"
        else empty end' <<<"$1"
}

# Why project $1 still has work for its idle agents, or nothing when it has
# none: bv has a pick (past beads labelled hold or needs-operator), or an
# open bead waits on a bead in progress, so that an agent waiting on a
# dependency is not taken for one with no work. A project without .beads
# has none; failing to read its beads fails.
herdr_agents_reap_work() {
    [[ -d "$1/.beads" ]] || return 0
    command -v br >/dev/null 2>&1 && command -v bv >/dev/null 2>&1 || return 1
    local next progress blocked
    next="$(cd "$1" && bv --robot-next --robot-not-ready-labels "$HERDR_AGENTS_REAP_NOT_READY_LABELS" </dev/null 2>/dev/null)" \
        || return 1
    next="$(jq -r 'if .actionable == true and ((.id // "") != "") then .id else empty end' <<<"$next" 2>/dev/null)" \
        || return 1
    if [[ -n "$next" ]]; then
        printf 'bv has %s ready in %s\n' "$next" "$1"
        return 0
    fi
    progress="$(cd "$1" && br list --status in_progress --limit 0 --json </dev/null 2>/dev/null)" || return 1
    blocked="$(cd "$1" && br blocked --limit 0 --json </dev/null 2>/dev/null)" || return 1
    # Epics are containers nobody works on: br lists one as blocked by its
    # open children, and an epic in progress is no bead someone finishes.
    jq -r --argjson progress "$progress" --arg p "$1" '
        [$progress.issues[]? | select(.issue_type != "epic") | .id] as $ip
        | [.issues[]? | select(.issue_type != "epic")
            | select(any(.blocked_by[]?; . as $b | $ip | index($b))) | .id]
        | if length > 0 then "\(.[0]) in \($p) waits on a bead in progress" else empty end' <<<"$blocked" 2>/dev/null
}

# Why agent $2 is busy in project $1 though herdr shows it between turns,
# or nothing when it isn't: it holds a file reservation, or has unread mail
# or acks pending (a review or question it has yet to answer).
herdr_agents_reap_busy() {
    local active held unread pending
    active="$(am robot reservations --project "$1" --all --json </dev/null 2>/dev/null)" || return 1
    held="$(jq -r --arg a "$2" '[.all_active[]? | select(.agent == $a) | .path] | join(", ")' <<<"$active")" || return 1
    if [[ -n "$held" ]]; then
        printf 'it holds reservations: %s\n' "$held"
        return 0
    fi
    unread="$(am inbox --project "$1" --agent "$2" --unread --limit "$HERDR_AGENTS_INBOX_LIMIT" --json </dev/null 2>/dev/null \
        | jq -e '.inbox | length' 2>/dev/null)" || return 1
    if (( unread > 0 )); then
        printf 'it has %s unread message(s)\n' "$unread"
        return 0
    fi
    # am prints pending acks as a table only: an ID column of message ids.
    pending="$(am acks pending "$1" "$2" </dev/null 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { n++ } END { print n + 0 }')" \
        || return 1
    if (( pending > 0 )); then
        printf 'it has %s ack(s) pending\n' "$pending"
    fi
}

# How many beads in progress project $1 has assigned to $2, whatever the
# case of the assignee (br's --assignee matches it exactly). A project
# without .beads has none; failing to read them fails.
herdr_agents_reap_beads() {
    [[ -d "$1/.beads" ]] || { printf '0\n'; return 0; }
    command -v br >/dev/null 2>&1 || return 1
    (cd "$1" && br list --status in_progress --limit 0 --json </dev/null 2>/dev/null) \
        | jq -e --arg a "${2,,}" '.issues | map(select((.assignee // "") | ascii_downcase == $a)) | length' 2>/dev/null
}

# Tell project $1's keep-listed agents, by Agent Mail from retired agent $2,
# that reap retired it, and why ($3). Names on the keep list that the
# project doesn't have are skipped.
herdr_agents_reap_notify() {
    local project="$1" mail_name="$2" why="$3" name failed=0
    local -a to=()
    while IFS= read -r name; do
        [[ -n "$name" && "${name,,}" != "${mail_name,,}" ]] || continue
        am agents show "$name" --project "$project" --json </dev/null >/dev/null 2>&1 && to+=("$name")
    done < <(jq -r '.[]' <<<"$HERDR_AGENTS_REAP_KEEP")
    (( ${#to[@]} > 0 )) || return 0
    for name in "${to[@]}"; do
        am mail send --project "$project" --from "$mail_name" --to "$name" \
            --subject "[reap] $mail_name retired: idle, with no work left" \
            --body "acfs agents reap retired $mail_name at $(date -u +%Y-%m-%dT%H:%M:%SZ): $why. Its Agent Mail identity stays active; spawn a fresh agent when work comes back." \
            </dev/null >/dev/null || { herdr_agents_note "reap: am mail send to $name failed"; failed=1; }
    done
    return "$failed"
}

# Retire agent $1 (herdr's JSON for it; Agent Mail name $2) unless it is
# exempt, busy, has a bead in progress or its project still has work ($5,
# as reap_work says); $3 says why it is reaped, $4 true only says what
# would happen. Returns 0 when it is retired or kept on purpose, 2 when
# retire refused it or its state changed since the sweep looked (both
# expected, and tried again later), 1 when it could not be checked, retire
# failed otherwise, or its project could not be told.
herdr_agents_reap_one() {
    local agent="$1" mail_name="$2" why="$3" dry_run="$4" work="$5" name workspace cwd reason beads busy
    local -a retire_args=()
    name="$(jq -r '.name' <<<"$agent")"
    workspace="$(jq -r '.workspace_id' <<<"$agent")"
    cwd="$(jq -r '.cwd // empty' <<<"$agent")"
    # Called under `||`, where set -e is off: a failed check keeps.
    if ! reason="$(herdr_agents_reap_exemption "$agent" "$mail_name")"; then
        herdr_agents_note "reap: keeps $mail_name: its exemptions could not be checked"
        return 1
    fi
    if [[ -n "$reason" ]]; then
        [[ "$dry_run" == false ]] || herdr_agents_note "reap: keeps $mail_name: $reason"
        return 0
    fi
    if [[ -n "$work" ]]; then
        [[ "$dry_run" == false ]] || herdr_agents_note "reap: keeps $mail_name: $work"
        return 0
    fi
    if ! beads="$(herdr_agents_reap_beads "$cwd" "$mail_name")"; then
        herdr_agents_note "reap: keeps $mail_name: the beads in $cwd could not be read"
        return 1
    fi
    if (( beads > 0 )); then
        [[ "$dry_run" == false ]] || herdr_agents_note "reap: keeps $mail_name: $beads bead(s) in progress are assigned to it in $cwd"
        return 0
    fi
    if ! busy="$(herdr_agents_reap_busy "$cwd" "$mail_name")"; then
        herdr_agents_note "reap: keeps $mail_name: its reservations, mail or acks in $cwd could not be read"
        return 1
    fi
    if [[ -n "$busy" ]]; then
        [[ "$dry_run" == false ]] || herdr_agents_note "reap: keeps $mail_name: $busy"
        return 0
    fi
    # The agent must still be in the state reap decided on: a turn that
    # started (or ran and ended) since then keeps it.
    if ! herdr_agents_herdr agent get "$name" </dev/null; then
        herdr_agents_note "reap: keeps $mail_name: herdr could not show it ($HERDR_AGENTS_ERR_CODE)"
        return 1
    fi
    if ! jq -e --argjson was "$agent" '.result.agent
            | (.agent_status == "idle" or .agent_status == "done")
              and (.state_change_seq // null) == ($was.state_change_seq // null)' <<<"$HERDR_AGENTS_OUT" >/dev/null 2>&1; then
        herdr_agents_note "reap: keeps $mail_name: its state changed since the sweep looked"
        return 2
    fi
    herdr_agents_note "$(date -u +%Y-%m-%dT%H:%M:%SZ) reap: retiring $mail_name ($name, workspace $workspace, $cwd): $why"
    retire_args=("$mail_name" --workspace "$workspace" --cwd "$cwd")
    [[ "$dry_run" == false ]] || retire_args+=(--dry-run)
    # The token in this environment, if any, is the caller's own, never the
    # reaped agent's: retire_agent would refuse it after the pane closed.
    local rc=0
    (unset AGENT_MAIL_REGISTRATION_TOKEN; herdr_agents_retire "${retire_args[@]}") </dev/null || rc=$?
    case "$rc" in
        0) ;;
        2) herdr_agents_note "reap: $mail_name was not retired: retire refused it"; return 2 ;;
        *) herdr_agents_note "reap: $mail_name was not retired: retire failed"; return 1 ;;
    esac
    [[ "$dry_run" == false ]] || return 0
    herdr_agents_reap_notify "$cwd" "$mail_name" "$why"
}

# One sweep over workspace $1 ("" = every one) and project $5 ("" = every
# one): retire each agent seen between turns for $2 minutes, as reap_one
# decides. File $4 keeps, per pane and name, herdr's state_change_seq, when
# reap first saw it between turns at that seq, and when retiring it last
# failed.
herdr_agents_reap_sweep() {
    local workspace="$1" idle_min="$2" dry_run="$3" file="$4" project="$5"
    local now state agent key name tab label mail_name cwd rc failed=0
    local idle_s=$(( $2 * 60 )) retry_s
    retry_s=$(( idle_s > 300 ? idle_s : 300 ))
    (( idle_min > 0 )) || retry_s=0
    herdr_agents_reap_load "$workspace" "$project" || return 1
    now="$(date +%s)"
    state="$(jq -c 'if type == "object" then . else empty end' "$file" 2>/dev/null || true)"
    [[ -n "$state" ]] || state="{}"
    # Only agents between turns are tracked; any other state starts over.
    # A sweep of one workspace or project keeps the others' entries; an
    # entry that names no project is dropped.
    state="$(jq -c --argjson prev "$state" --argjson now "$now" --arg ws "$workspace" --arg p "$project" '
        ($prev | with_entries(select(($ws != "" and .value.workspace != $ws)
                                     or ($p != "" and ((.value.project // "") | if . == "" then $p else . end) != $p)))) + (
        map(select(.name != null and (.agent_status == "idle" or .agent_status == "done"))
            | (.pane_id + " " + .name) as $key
            | (.state_change_seq // null) as $seq
            | ($prev[$key] // {}) as $e
            | {key: $key, value: (if $e.since != null and $e.seq == $seq then $e
                                  else {seq: $seq, since: $now, workspace: .workspace_id, project: (.cwd // "")} end)})
        | from_entries)' <<<"$HERDR_AGENTS_REAP_AGENTS")"

    local -A labels=() work=() unreadable=()
    local ws
    while IFS= read -r agent; do
        name="$(jq -r '.name' <<<"$agent")"
        key="$(jq -r '.pane_id' <<<"$agent") $name"
        jq -e --arg k "$key" --argjson now "$now" --argjson idle "$idle_s" --argjson retry "$retry_s" '
            .[$k] as $e | $e != null and $now - $e.since >= $idle
            and ($e.failed == null or $now - $e.failed >= $retry)' <<<"$state" >/dev/null || continue
        # The Agent Mail name is the tab label's first word: spawn sets the
        # label to the name, and people append a model after it.
        ws="$(jq -r '.workspace_id' <<<"$agent")"
        if [[ -z "${labels[$ws]+set}" ]]; then
            if herdr_agents_herdr tab list --workspace "$ws" </dev/null; then
                labels[$ws]="$(jq -c '[.result.tabs[]? | {key: .tab_id, value: (.label // "")}] | from_entries' <<<"$HERDR_AGENTS_OUT")"
            else
                herdr_agents_note "reap: herdr tab list failed for workspace $ws: $HERDR_AGENTS_ERR_MESSAGE"
                labels[$ws]="{}"
            fi
        fi
        tab="$(jq -r '.tab_id' <<<"$agent")"
        label="$(jq -r --arg t "$tab" '.[$t] // empty' <<<"${labels[$ws]}")"
        mail_name="${label%% *}"
        if [[ "${mail_name,,}" != "$name" ]]; then
            [[ "$dry_run" == false ]] || herdr_agents_note "reap: keeps $name: its tab label '${label}' does not start with its Agent Mail name"
            continue
        fi
        cwd="$(jq -r '.cwd // empty' <<<"$agent")"
        if [[ -z "$cwd" || ! -d "$cwd" ]]; then
            herdr_agents_note "reap: keeps $mail_name: its cwd '${cwd}' is not a directory"
            failed=$((failed + 1))
            continue
        fi
        # A project's work is read once per sweep.
        if [[ -z "${work[$cwd]+set}" ]]; then
            work[$cwd]=""
            if ! work[$cwd]="$(herdr_agents_reap_work "$cwd")"; then
                herdr_agents_note "reap: keeps the agents in $cwd: its beads could not be read (br and bv)"
                unreadable[$cwd]=1
                failed=$((failed + 1))
            fi
        fi
        [[ -z "${unreadable[$cwd]+set}" ]] || continue
        rc=0
        herdr_agents_reap_one "$agent" "$mail_name" \
            "between turns for $(( (now - $(jq -r --arg k "$key" '.[$k].since' <<<"$state")) / 60 )) min, with no bead in progress and no work left in its project" \
            "$dry_run" "${work[$cwd]}" || rc=$?
        if (( rc != 0 )); then
            # A refusal is expected and fails nothing; it is tried again later.
            (( rc == 2 )) || failed=$((failed + 1))
            # A dry run tried nothing, so it delays no real retirement.
            [[ "$dry_run" == true ]] \
                || state="$(jq -c --arg k "$key" --argjson now "$now" '.[$k].failed = $now' <<<"$state")"
        fi
    done < <(jq -c '.[] | select(.name != null)' <<<"$HERDR_AGENTS_REAP_AGENTS")
    herdr_agents_wake_save "$file" "$state"
    (( failed == 0 ))
}

herdr_agents_reap() {
    local workspace="${HERDR_WORKSPACE_ID:-}" project="${AGENT_MAIL_PROJECT:-}" all=false
    local idle=60 loop=false interval=60 dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace) [[ $# -ge 2 ]] || herdr_agents_die "--workspace needs a value"; workspace="$2"; shift 2 ;;
            --project) [[ $# -ge 2 ]] || herdr_agents_die "--project needs a value"; project="$2"; shift 2 ;;
            --all-workspaces) all=true; shift ;;
            --idle) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || herdr_agents_die "--idle needs whole minutes"; idle="$((10#$2))"; shift 2 ;;
            --loop) loop=true; shift ;;
            --interval) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || herdr_agents_die "--interval needs whole seconds"; interval="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) herdr_agents_usage; return 0 ;;
            *) herdr_agents_die "unknown reap option: $1" ;;
        esac
    done
    if [[ "$all" == true ]]; then
        workspace="" project=""
    elif [[ -z "$project" ]]; then
        project="$(git rev-parse --show-toplevel 2>/dev/null)" \
            || herdr_agents_die "reap: run it in a project's git checkout, or pass --project KEY or --all-workspaces"
    fi
    herdr_agents_require herdr jq am git flock
    local state_dir lock_fd file
    state_dir="${ACFS_HOME:-$HOME/.acfs}/state/reap"
    mkdir -p "$state_dir"
    file="$state_dir/idle.json"
    # Two reapers would retire one agent twice and share one state file.
    exec {lock_fd}>"$state_dir/reap.lock"
    flock -n "$lock_fd" || herdr_agents_die "another acfs agents reap is running"

    if [[ "$loop" == false ]]; then
        herdr_agents_reap_sweep "$workspace" "$idle" "$dry_run" "$file" "$project"
        return
    fi
    herdr_agents_note "reaping agents between turns for ${idle} min in ${project:-every project}${workspace:+, workspace $workspace}, every ${interval}s"
    while :; do
        ( herdr_agents_reap_sweep "$workspace" "$idle" "$dry_run" "$file" "$project" ) || true
        sleep "$interval"
    done
}

herdr_agents_main() {
    local subcommand="${1:-help}"
    [[ $# -gt 0 ]] && shift
    case "$subcommand" in
        spawn) herdr_agents_spawn "$@" ;;
        send) herdr_agents_send "$@" ;;
        list|ls) herdr_agents_list "$@" ;;
        inbox) herdr_agents_inbox "$@" ;;
        wake) herdr_agents_wake "$@" ;;
        limits) herdr_agents_limits "$@" ;;
        codex-daemon) herdr_agents_codex_daemon "$@" ;;
        retire) herdr_agents_retire "$@" ;;
        recycle) herdr_agents_recycle "$@" ;;
        reap) herdr_agents_reap "$@" ;;
        quota) exec bash "$HERDR_AGENTS_SCRIPT_DIR/agent_quota.sh" "$@" ;;
        sweep) exec bash "$HERDR_AGENTS_SCRIPT_DIR/temp_sweep.sh" "$@" ;;
        help|-h|--help) herdr_agents_usage ;;
        *) herdr_agents_usage >&2; return 1 ;;
    esac
}

herdr_agents_main "$@"
