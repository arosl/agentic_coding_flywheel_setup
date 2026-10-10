#!/usr/bin/env bash
# ============================================================
# scripts/lib/herdr_agents.sh (acfs agents spawn/send/list/inbox) against a STUB
# herdr and a STUB am
#
# Proves which herdr and Agent Mail calls the helper makes, in which order
# and with which arguments, and how it reports and stops. The stubs answer
# with the JSON shapes herdr 0.9.3 and am print. Nothing here starts a
# real agent.
#
# Usage: bash tests/unit/test_herdr_agents.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/scripts/lib/herdr_agents.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-herdr-agents.XXXXXX")"
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

# ------------------------------------------------------------
# The stubs log one line per call to $STUB_DIR/calls and read their
# behaviour from files in $STUB_DIR.
# ------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/repo"
cat >"$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'herdr %s\n' "$*" >>"$STUB_DIR/calls"
fail_with() {
    printf '{"error":{"code":"%s","message":"%s"},"id":"cli:stub"}\n' "$1" "$2" >&2
    exit 1
}
case "$1 $2" in
    "tab create")
        n=$(( $(cat "$STUB_DIR/tabs" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$STUB_DIR/tabs"
        printf '{"id":"cli:tab:create","result":{"tab":{"tab_id":"w9:t%s"},"root_pane":{"pane_id":"w9:p%s"}}}\n' "$n" "$n"
        ;;
    "tab close")
        [[ ! -e "$STUB_DIR/tab_close_fail" ]] || fail_with tab_not_found "tab $3 not found"
        printf '{"id":"cli:tab:close","result":{"type":"ok"}}\n'
        ;;
    "pane process-info")
        # shell_starting_<pane> holds how many more polls see a startup
        # command in the foreground; shell_stuck makes every poll see one.
        starting="$STUB_DIR/shell_starting_$4"
        busy=false
        if [[ -e "$STUB_DIR/shell_stuck" ]]; then
            busy=true
        elif [[ -s "$starting" ]] && (( $(cat "$starting") > 0 )); then
            echo $(( $(cat "$starting") - 1 )) >"$starting"
            busy=true
        fi
        if [[ "$busy" == true ]]; then
            printf '{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":200,"foreground_processes":[{"name":"compinit","pid":200}],"pane_id":"%s","shell_pid":100}}}\n' "$4"
        else
            printf '{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":100,"foreground_processes":[],"pane_id":"%s","shell_pid":100}}}\n' "$4"
        fi
        ;;
    "agent start")
        # busy_<name> holds how many more starts herdr refuses as agent_pane_busy.
        busy="$STUB_DIR/busy_$3"
        if [[ -s "$busy" ]] && (( $(cat "$busy") > 0 )); then
            echo $(( $(cat "$busy") - 1 )) >"$busy"
            fail_with agent_pane_busy "agent target pane $5 is not an available shell"
        fi
        [[ ! -e "$STUB_DIR/not_ready_$3" ]] || fail_with agent_not_ready "agent $3 is not ready"
        printf '{"id":"cli:agent:start","result":{"agent":{"name":"%s"}}}\n' "$3"
        ;;
    "agent prompt")
        # <code>_<name> makes herdr answer with that error; after_<name> holds
        # the state a --wait matches (default: working with --until, else done).
        for code in agent_blocked agent_not_found; do
            [[ ! -e "$STUB_DIR/${code}_$3" ]] || fail_with "$code" "agent $3: $code"
        done
        printf '%s' "$4" >"$STUB_DIR/prompt_$3"
        for code in agent_prompt_stalled timeout; do
            [[ ! -e "$STUB_DIR/${code}_$3" ]] || fail_with "$code" "agent $3: $code"
        done
        state=done
        [[ "$*" != *--until* ]] || state=working
        [[ ! -s "$STUB_DIR/after_$3" ]] || state="$(cat "$STUB_DIR/after_$3")"
        printf '{"id":"cli:agent:prompt","result":{"agent":{"name":"%s","agent_status":"%s"},"type":"agent_prompted"}}\n' "$3" "$state"
        ;;
    "agent read")
        if [[ -e "$STUB_DIR/screen_$3" ]]; then
            cat "$STUB_DIR/screen_$3"
        else
            printf 'Do you trust the files in this folder?\n> 1. Yes, continue\n'
        fi
        ;;
    "agent send-keys") ;;
    "agent wait")
        [[ ! -e "$STUB_DIR/wait_fail_$3" ]] || fail_with timeout "agent $3 did not reach the requested state"
        printf '{"id":"cli:agent:wait","result":{"agent":{"name":"%s","agent_status":"idle"}}}\n' "$3"
        ;;
    "agent list") cat "$STUB_DIR/list.json" ;;
    "tab list") cat "$STUB_DIR/tabs.json" ;;
    "pane close") printf '{"id":"cli:pane:close","result":{"type":"ok"}}\n' ;;
    *) fail_with unexpected "stub herdr got: $*" ;;
esac
STUB
cat >"$WORK/bin/am" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'am %s\n' "$*" >>"$STUB_DIR/calls"
# The mailbox (inbox tests) is $STUB_DIR/mailbox.json, with the ids marked
# read in $STUB_DIR/read_ids; `late` rows are not yet in `am mail inbox`.
# Both listings honour --limit (default 20), as am does.
limit=20
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[i]}" != --limit ]] || limit="${args[i + 1]}"
done
case "$1 ${2:-}" in
    "mail inbox")
        jq --argjson limit "$limit" '[.[] | select(.late | not)] | sort_by(-.id) | .[:$limit]
            | map({id, subject, from, importance, kind, created_ts, thread_id: .thread})' "$STUB_DIR/mailbox.json"
        exit 0 ;;
    "inbox "*)
        jq --argjson limit "$limit" --slurpfile read <(cat "$STUB_DIR/read_ids") '
            [.[] | select(.id as $i | $read | index($i) | not)]
            | sort_by([(if .importance == "high" then 0 else 1 end), -.id]) | .[:$limit]
            | {count: length, inbox: map({id, priority: "unread", from, subject, thread, age: "1m ago", ack_status, importance, body_md})}' \
            "$STUB_DIR/mailbox.json"
        exit 0 ;;
    "mail read")
        # Drain stdin, as a CLI may: a caller looping over ids must not feed it.
        cat >/dev/null
        id="${args[-1]}"
        [[ ! -e "$STUB_DIR/read_fail_$id" ]] || { echo "stub: cannot mark $id" >&2; exit 1; }
        echo "$id" >>"$STUB_DIR/read_ids"
        exit 0 ;;
    # retire's reads: am_unknown_<name> makes `agents show` fail;
    # reservations.json is `robot reservations --all --json`; reserved_ever
    # the `file_reservations list --all` table.
    "agents show")
        [[ ! -e "$STUB_DIR/am_unknown_$3" ]] || { echo "agent not found" >&2; exit 1; }
        printf '{"id":1,"name":"%s"}\n' "$3"
        exit 0 ;;
    "robot reservations")
        cat "$STUB_DIR/reservations.json" 2>/dev/null || printf '{"all_active":[]}\n'
        exit 0 ;;
    "file_reservations list")
        printf 'ID   PATTERN              AGENT       EXPIRES               REASON\n'
        cat "$STUB_DIR/reserved_ever" 2>/dev/null || true
        exit 0 ;;
    # wake's reads: events_<Agent>.json holds an agent's deliveries
    # ({cursor, kind}); overdue_<Agent> the rows of `am acks overdue`.
    "inbox-events "*)
        agent="" after="" position_now=false
        for ((i = 0; i < ${#args[@]}; i++)); do
            case "${args[i]}" in
                --agent) agent="${args[i + 1]}" ;;
                --after) after="${args[i + 1]}" ;;
                --position-now) position_now=true ;;
            esac
        done
        [[ ! -e "$STUB_DIR/events_fail_$agent" ]] || { echo "stub: no such agent $agent" >&2; exit 1; }
        events="$STUB_DIR/events_$agent.json"
        [[ -s "$events" ]] || printf '[]\n' >"$events"
        if [[ "$position_now" == true ]]; then
            jq -c '{events: [], next_cursor: ((map(.cursor) | max) // 0), has_more: false}' "$events"
        else
            jq -c --argjson after "$after" --argjson limit "$limit" '
                [.[] | select(.cursor > $after)] | sort_by(.cursor) as $new
                | ($new[:$limit]) as $page
                | {events: $page, next_cursor: (($page | map(.cursor) | max) // $after), has_more: (($new | length) > $limit)}' "$events"
        fi
        exit 0 ;;
    "acks overdue")
        if [[ -s "$STUB_DIR/overdue_$4" ]]; then
            printf 'OVERDUE acks (>60min TTL):\nID   FROM            SUBJECT       OVERDUE\n'
            cat "$STUB_DIR/overdue_$4"
        else
            printf 'No overdue acks.\n'
        fi
        exit 0 ;;
esac
n=$(( $(cat "$STUB_DIR/am_count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/am_count"
name="$(sed -n "${n}p" "$STUB_DIR/am_names")"
printf '{"id":%s,"name":"%s","program":"stub"}\n' "$n" "$name"
STUB
# The stub codex records the HERDR_* variables it was run with. Its
# `app-server daemon start|restart` writes the pid file of a fake daemon
# (pid 4242) whose /proc entries carry no HERDR_* variable.
cat >"$WORK/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex %s\n' "$*" >>"$STUB_DIR/calls"
# herdr's variables only; the helper's own HERDR_AGENTS_* test knobs may stay.
env | grep '^HERDR_' | grep -v '^HERDR_AGENTS_' | sort >>"$STUB_DIR/codex_env" || true
case "$*" in
    "app-server daemon start"|"app-server daemon restart")
        [[ ! -e "$STUB_DIR/daemon_start_fail" ]] || { echo "daemon failed" >&2; exit 1; }
        mkdir -p "$STUB_DIR/codex-home/app-server-daemon" "$STUB_DIR/proc/4242"
        printf '{"pid":4242,"processStartTime":"stub"}\n' >"$STUB_DIR/codex-home/app-server-daemon/daemon.pid"
        printf 'codex\0app-server\0--listen\0unix://\0--managed-daemon\0' >"$STUB_DIR/proc/4242/cmdline"
        printf 'HOME=/home/stub\0PATH=/usr/bin\0' >"$STUB_DIR/proc/4242/environ"
        ;;
esac
STUB
# The stub curl stands in for Agent Mail's HTTP MCP endpoint: it records the
# request body and answers a tool result (curl_refuse: a refusal).
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$STUB_DIR/calls"
cat >"$STUB_DIR/curl_body"
if [[ -e "$STUB_DIR/curl_refuse" ]]; then
    printf '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"invalid registration_token"}],"isError":true}}\n'
else
    printf 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{}"}],"isError":false}}\n'
fi
STUB
chmod +x "$WORK/bin/herdr" "$WORK/bin/am" "$WORK/bin/codex" "$WORK/bin/curl"

# A fresh stub state per case.
reset_stub() {
    STUB_DIR="$WORK/stub.$1"
    mkdir -p "$STUB_DIR/proc" "$STUB_DIR/codex-home"
    printf '%s\n' AlphaFox BetaOwl GammaYak DeltaElk >"$STUB_DIR/am_names"
    : >"$STUB_DIR/calls"
    export STUB_DIR
}

# A fake running Codex daemon, pid 777, in this case's CODEX_HOME and proc
# root: `clean` carries no HERDR_* variable, `leaked` the ones a pane's
# shell exports, `dead` has a pid file but no process, `unreadable` an
# environment the test user cannot read, `other` a reused pid that is not
# a codex process.
fake_daemon() {
    local how="$1"
    mkdir -p "$STUB_DIR/codex-home/app-server-daemon"
    printf '{"pid":777,"processStartTime":"stub"}\n' >"$STUB_DIR/codex-home/app-server-daemon/daemon.pid"
    [[ "$how" != dead ]] || return 0
    mkdir -p "$STUB_DIR/proc/777"
    if [[ "$how" == other ]]; then
        printf 'sleep\0100\0' >"$STUB_DIR/proc/777/cmdline"
        printf 'HOME=/home/stub\0' >"$STUB_DIR/proc/777/environ"
        return 0
    fi
    printf 'codex\0app-server\0--listen\0unix://\0--managed-daemon\0' >"$STUB_DIR/proc/777/cmdline"
    if [[ "$how" == leaked ]]; then
        printf 'HOME=/home/stub\0HERDR_ENV=1\0HERDR_PANE_ID=w1:pA\0HERDR_TAB_ID=w1:tA\0HERDR_WORKSPACE_ID=w1\0HERDR_SOCKET_PATH=/s\0HERDR_BIN_PATH=/b\0PATH=/usr/bin\0' >"$STUB_DIR/proc/777/environ"
    else
        printf 'HOME=/home/stub\0PATH=/usr/bin\0' >"$STUB_DIR/proc/777/environ"
    fi
    [[ "$how" != unreadable ]] || chmod 000 "$STUB_DIR/proc/777/environ"
}

# Run the helper with the stubs first on PATH; stdout, stderr and the
# exit code land in $OUT, $ERR and $RC. The environment is a herdr pane's:
# every HERDR_* variable the pane's shell exports is set. RUN_WRAPPER, when
# set, is a command the helper runs under (such as timeout for wake --loop).
RUN_WRAPPER=()
run_helper() {
    RC=0
    PATH="$WORK/bin:$PATH" HOME="$WORK/home" ACFS_HOME="$WORK/acfs-home" \
        CODEX_HOME="$STUB_DIR/codex-home" HERDR_AGENTS_PROC_ROOT="$STUB_DIR/proc" \
        HERDR_AGENTS_DAEMON_WAIT_TRIES=3 HERDR_AGENTS_DAEMON_WAIT_INTERVAL=0 \
        HERDR_ENV=1 HERDR_PANE_ID=w9:p9 HERDR_TAB_ID=w9:t9 HERDR_SOCKET_PATH=/stub.sock HERDR_BIN_PATH=/stub/herdr \
        "${RUN_WRAPPER[@]}" bash "$HELPER" "$@" >"$STUB_DIR/out" 2>"$STUB_DIR/err" || RC=$?
    OUT="$(cat "$STUB_DIR/out")"
    ERR="$(cat "$STUB_DIR/err")"
}

calls() { cat "$STUB_DIR/calls"; }
count_calls() { grep -c -- "$1" "$STUB_DIR/calls" || true; }

mkdir -p "$WORK/acfs-home/onboard/docs/ntm"
cat >"$WORK/acfs-home/onboard/docs/ntm/command_palette.md" <<'EOF'
# Palette

### default_new_agent | Default New Agent
Read AGENTS.md, register with Agent Mail, then work your beads.

### fresh_review | Fresh Review
Not part of the kickoff.
EOF

export HERDR_WORKSPACE_ID=w9
export HERDR_AGENTS_SHELL_WAIT_TRIES=3 HERDR_AGENTS_SHELL_WAIT_INTERVAL=0
unset HERDR_PANE_ID

echo "spawn"

reset_stub dry
run_helper spawn --claude 2 --codex=1 --cwd "$WORK/repo" --dry-run --json
check "--dry-run exits 0" test "$RC" -eq 0
check "--dry-run makes no Agent Mail or herdr call" test -z "$(calls)"
check "--dry-run reports three planned agents" test "$(jq '.agents | length' <<<"$OUT")" -eq 3
check "--dry-run names the workspace from HERDR_WORKSPACE_ID" test "$(jq -r .workspace <<<"$OUT")" = w9

reset_stub plain
run_helper spawn --claude 2 --codex 1 --workspace w5 --cwd "$WORK/repo" --model opus --no-prompt --json
check "spawn of three agents exits 0" test "$RC" -eq 0
check "spawn creates one Agent Mail identity per agent" test "$(count_calls '^am agents create')" -eq 3
check "the identity's program follows the kind" \
    test "$(grep '^am ' "$STUB_DIR/calls" | grep -o -- '--program [a-z-]*' | tr '\n' ' ')" = "--program claude-code --program claude-code --program codex-cli "
check "the identity's project key is the cwd" grep -q -- "--project $WORK/repo --program" "$STUB_DIR/calls"
check "the tab gets the Agent Mail name, the explicit workspace and --no-focus" \
    grep -qx -- "herdr tab create --workspace w5 --cwd $WORK/repo --label AlphaFox --no-focus" "$STUB_DIR/calls"
check "the herdr name is the Agent Mail name lowercased, started in the tab's root pane" \
    grep -q -- "^herdr agent start gammayak --kind codex --pane w9:p3 " "$STUB_DIR/calls"
check "--model reaches each agent CLI after --, and its Agent Mail identity" \
    bash -c '[[ $(grep -c -- "^herdr agent start [a-z]* --kind [a-z]* --pane w9:p[0-9] -- --model opus$" "$1") -eq 3 ]] \
        && [[ $(grep -c -- "^am agents create .* --model opus " "$1") -eq 3 ]]' _ "$STUB_DIR/calls"
check "--no-prompt sends no prompt" test "$(count_calls '^herdr agent prompt')" -eq 0
check "identity, then tab, then start, per agent" \
    test "$(grep -v '^codex ' "$STUB_DIR/calls" | cut -d' ' -f1-3 | head -3 | tr '\n' '|')" = "am agents create|herdr tab create|herdr agent start|"
check "the Codex daemon is seen to before the first identity" \
    test "$(head -1 "$STUB_DIR/calls")" = "codex app-server daemon start"
check "--json lists each agent as started" \
    test "$(jq -r '[.agents[].status] | unique | join(",")' <<<"$OUT")" = started

# acfs-gen.7: one call spawns per-kind counts of every kind into one workspace.
reset_stub kinds
run_helper spawn --claude 1 --codex=1 --agy 1 --pi=1 --workspace w5 --cwd "$WORK/repo" --no-prompt --json
check "spawn --claude --codex --agy --pi starts one agent of each kind, in order" \
    test "$RC/$(grep -o -- '^herdr agent start [a-z]* --kind [a-z]*' "$STUB_DIR/calls" | awk '{print $6}' | tr '\n' ' ')" \
        = "0/claude codex agy pi "
check "every tab of one spawn goes into the same workspace" \
    test "$(grep '^herdr tab create' "$STUB_DIR/calls" | grep -c -- '--workspace w5 ')" -eq 4
check "a pi agent's identity has the program pi" grep -q -- '^am agents create .* --program pi ' "$STUB_DIR/calls"

reset_stub kickoff
run_helper spawn --claude 1 --cwd "$WORK/repo"
check "spawn with the default kickoff exits 0" test "$RC" -eq 0
check "the kickoff carries the agent's identity" \
    grep -q "name AlphaFox, project key $WORK/repo .*herdr name is alphafox, in herdr workspace w9" "$STUB_DIR/prompt_alphafox"
check "the kickoff carries the palette's default_new_agent and stops at the next heading" \
    bash -c 'grep -q "register with Agent Mail" "$1" && ! grep -q "Not part" "$1"' _ "$STUB_DIR/prompt_alphafox"
check "the kickoff waits only until the agent works, for at most 15 s" \
    bash -c 'grep -q -- "--wait --until working --until blocked --timeout 15000$" "$1"' _ "$STUB_DIR/calls"

# acfs-gen.2: a kickoff that stalls fails the spawn and shows why.
reset_stub kickoffstall
touch "$STUB_DIR/agent_prompt_stalled_alphafox"
printf 'Teach auto mode about your environment?\n\xe2\x9d\xaf 1. Yes\n  2. Not now\nEnter to confirm\n' >"$STUB_DIR/screen_alphafox"
run_helper spawn --claude 1 --cwd "$WORK/repo" --json
check "a stalled kickoff fails the spawn and is reported" \
    bash -c '[[ "$1" -ne 0 ]] && [[ "$(jq -r ".agents[0].status" <<<"$2")" == "started; prompt failed: agent_prompt_stalled" ]]' _ "$RC" "$OUT"
check "the stall names the dialog on its screen, read in ANSI, and sends no key" \
    bash -c 'grep -q "a dialog is on its screen" <<<"$1" && grep -q -- "agent read alphafox --source visible --lines 30 --format ansi" "$2" && ! grep -q "send-keys" "$2"' _ "$ERR" "$STUB_DIR/calls"

check "without --model the agent CLI gets no arguments" \
    grep -qx -- "herdr agent start alphafox --kind claude --pane w9:p1" "$STUB_DIR/calls"

# acfs-zyo: --model is checked against every kind before anything exists.
reset_stub modelagy
run_helper spawn --claude 1 --agy 1 --cwd "$WORK/repo" --model opus --no-prompt
check "--model with an agy agent is refused before any identity or tab" \
    bash -c '[[ "$1" -ne 0 && -z "$(cat "$2")" ]] && grep -q "agy runs on the model agy-locked pins" <<<"$3"' _ "$RC" "$STUB_DIR/calls" "$ERR"

reset_stub modelother
run_helper spawn --kind opencode --cwd "$WORK/repo" --model x1 --no-prompt
check "--model with a kind spawn can't set it for is refused" \
    bash -c '[[ "$1" -ne 0 && -z "$(cat "$2")" ]]' _ "$RC" "$STUB_DIR/calls"

reset_stub modelbad
run_helper spawn --codex 1 --cwd "$WORK/repo" --model "--dangerously-bypass" --no-prompt
check "a --model value that could pass as an option is refused" \
    bash -c '[[ "$1" -ne 0 && -z "$(cat "$2")" ]] && grep -q "invalid --model" <<<"$3"' _ "$RC" "$STUB_DIR/calls" "$ERR"

reset_stub modelagyonly
run_helper spawn --agy 1 --cwd "$WORK/repo" --no-prompt --json
check "agy without --model still spawns, with no agent arguments" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx -- "herdr agent start alphafox --kind agy --pane w9:p1" "$2"' _ "$RC" "$STUB_DIR/calls"

reset_stub modeldry
run_helper spawn --codex 1 --cwd "$WORK/repo" --model gpt-6.1-sol --dry-run
check "--dry-run shows the model the agent CLI would get" grep -q -- "--pane <root pane> -- --model gpt-6.1-sol" <<<"$ERR"

reset_stub modelretry
echo 1 >"$STUB_DIR/busy_alphafox"
run_helper spawn --claude 1 --cwd "$WORK/repo" --model claude-fable-5-1 --no-prompt
check "the agent_pane_busy retry passes the model too" \
    test "$RC/$(count_calls '^herdr agent start alphafox --kind claude --pane w9:p1 -- --model claude-fable-5-1$')" = "0/2"

reset_stub custom
run_helper spawn --kind codex --count 1 --cwd "$WORK/repo" --prompt "Review the diff."
check "--prompt replaces the palette text" \
    bash -c 'grep -q "Review the diff." "$1" && ! grep -q "register with Agent Mail" "$1"' _ "$STUB_DIR/prompt_alphafox"

reset_stub notready
touch "$STUB_DIR/not_ready_betaowl"
run_helper spawn --claude 3 --cwd "$WORK/repo" --no-prompt --json
check "agent_not_ready stops the spawn with a nonzero exit" test "$RC" -ne 0
check "no identity is created after the agent that did not start" test "$(count_calls '^am agents create')" -eq 2
check "the dialog on its screen is shown" grep -q "trust the files in this folder" <<<"$ERR"
check "the stuck agent is reported with its pane, and the first as started" \
    test "$(jq -r '[.agents[] | "\(.herdr_name)=\(.status)@\(.pane_id)"] | join(" ")' <<<"$OUT")" = "alphafox=started@w9:p1 betaowl=agent_not_ready@w9:p2"

reset_stub promptfail
touch "$STUB_DIR/agent_blocked_alphafox"
run_helper spawn --claude 2 --cwd "$WORK/repo" --json
check "a failed kickoff makes spawn exit nonzero" test "$RC" -ne 0
check "an agent whose kickoff failed keeps its one identity and is not restarted" \
    test "$(count_calls '^am agents create')/$(count_calls '^herdr agent start alphafox')" = "2/1"
check "it is reported as started, with the prompt failure" \
    test "$(jq -r '.agents[0].status' <<<"$OUT")" = "started; prompt failed: agent_blocked"
check "the next agent still starts and gets its kickoff" test -s "$STUB_DIR/prompt_betaowl"

# The two folder-trust dialogs as herdr 0.9.3 read them from Claude Code and
# Codex on 2026-10-09 (acfs-nj9).
claude_trust_screen() {
    cat <<'EOF'
 Accessing workspace:

 /srv/project

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from
 your team). If not, take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
EOF
}
codex_trust_screen() {
    cat <<'EOF'
  Folder access
  /srv/project
  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings can run code
  automatically, even without a model request. Continue only if you trust these files. Your trust decision will be saved.
› 1. Trust and continue
  2. Back to Agent Command Center
  enter continue · esc back
EOF
}

reset_stub trustclaude
touch "$STUB_DIR/not_ready_betaowl"
claude_trust_screen >"$STUB_DIR/screen_betaowl"
run_helper spawn --claude 3 --cwd "$WORK/repo" --no-prompt --trust-folder --json
check "--trust-folder answers Claude's trust dialog and spawn goes on" \
    test "$RC/$(jq '.agents | length' <<<"$OUT")" = "0/3"
check "Claude's dialog gets Down then Enter (its default is 'No, exit')" \
    grep -qx -- "herdr agent send-keys betaowl down enter" "$STUB_DIR/calls"
check "it then waits for idle or done, not for blocked" \
    grep -qx -- "herdr agent wait betaowl --until idle --until done --timeout 30000" "$STUB_DIR/calls"
check "only the agent at the dialog gets keys" test "$(count_calls '^herdr agent send-keys')" -eq 1

reset_stub trustcodex
touch "$STUB_DIR/not_ready_alphafox"
codex_trust_screen >"$STUB_DIR/screen_alphafox"
run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt --trust-folder
check "Codex's trust dialog gets Enter (its default is 'Trust and continue')" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx -- "herdr agent send-keys alphafox enter" "$2"' _ "$RC" "$STUB_DIR/calls"

reset_stub trustother
touch "$STUB_DIR/not_ready_alphafox"
run_helper spawn --claude 1 --cwd "$WORK/repo" --no-prompt --trust-folder
check "--trust-folder never answers a dialog it does not recognise" \
    test "$RC/$(count_calls '^herdr agent send-keys')" = "1/0"

reset_stub trustoff
touch "$STUB_DIR/not_ready_alphafox"
claude_trust_screen >"$STUB_DIR/screen_alphafox"
run_helper spawn --claude 1 --cwd "$WORK/repo" --no-prompt
check "without --trust-folder even the trust dialog stops spawn, with a hint" \
    bash -c '[[ "$1" -ne 0 && "$2" -eq 0 ]] && grep -q -- "--trust-folder answers" <<<"$3"' _ "$RC" "$(count_calls '^herdr agent send-keys')" "$ERR"

reset_stub trustthen
touch "$STUB_DIR/not_ready_alphafox" "$STUB_DIR/wait_fail_alphafox"
codex_trust_screen >"$STUB_DIR/screen_alphafox"
run_helper spawn --codex 2 --cwd "$WORK/repo" --no-prompt --trust-folder --json
check "a second dialog after the trust answer stops spawn as agent_not_ready" \
    test "$RC/$(jq -r '.agents[0].status' <<<"$OUT")/$(count_calls '^am agents create')" = "1/agent_not_ready/1"

# acfs-zsz: herdr refuses agent start while a new tab's shell is still
# running its startup files (agent_pane_busy).
reset_stub busyonce
echo 1 >"$STUB_DIR/busy_alphafox"
echo 2 >"$STUB_DIR/shell_starting_w9:p1"
run_helper spawn --claude 2 --cwd "$WORK/repo" --no-prompt --json
check "agent_pane_busy: spawn waits for the shell, retries once in the same pane and goes on" \
    test "$RC/$(count_calls '^herdr agent start alphafox --kind claude --pane w9:p1')/$(jq '.agents | length' <<<"$OUT")" = "0/2/2"
check "it polls the pane until its shell holds the foreground" \
    test "$(count_calls '^herdr pane process-info --pane w9:p1')" -eq 3
check "a retried start closes no tab" test "$(count_calls '^herdr tab close')" -eq 0

reset_stub busytwice
echo 2 >"$STUB_DIR/busy_alphafox"
run_helper spawn --claude 2 --cwd "$WORK/repo" --no-prompt --json
check "a second agent_pane_busy stops spawn, after exactly one retry" \
    test "$RC/$(count_calls '^herdr agent start alphafox')/$(count_calls '^am agents create')" = "1/2/1"
check "the tab it created, holding only a shell, is closed" grep -qx -- "herdr tab close w9:t1" "$STUB_DIR/calls"
check "the result keeps the closed tab and pane and flags the unused identity" \
    test "$(jq -r '.agents[0] | "\(.status) \(.tab_id) \(.pane_id) \(.tab_closed) \(.unused_identity)"' <<<"$OUT")" \
        = "agent_pane_busy w9:t1 w9:p1 true true"
check "the unused Agent Mail identity is named on stderr" grep -q "identity AlphaFox exists but has no agent" <<<"$ERR"

reset_stub busystuck
echo 1 >"$STUB_DIR/busy_alphafox"
touch "$STUB_DIR/shell_stuck"
run_helper spawn --claude 1 --cwd "$WORK/repo" --no-prompt --json
check "a shell that never becomes available gets no retry, and its busy tab is left open" \
    test "$RC/$(count_calls '^herdr agent start')/$(count_calls '^herdr pane process-info')/$(count_calls '^herdr tab close')" = "1/1/4/0"
check "the left tab is named for the caller, with tab_closed false" \
    bash -c '[[ "$(jq -r ".agents[0] | \"\(.tab_id) \(.tab_closed)\"" <<<"$1")" == "w9:t1 false" ]] && grep -q "left its tab w9:t1" <<<"$2"' _ "$OUT" "$ERR"

reset_stub busycloses
echo 2 >"$STUB_DIR/busy_alphafox"
touch "$STUB_DIR/tab_close_fail"
run_helper spawn --claude 1 --cwd "$WORK/repo" --no-prompt --json
check "a tab that cannot be closed is named in the result and on stderr" \
    bash -c '[[ "$(jq -r ".agents[0].tab_id" <<<"$1")" == w9:t1 ]] && grep -q "herdr tab close w9:t1" <<<"$2"' _ "$OUT" "$ERR"

reset_stub notreadytab
touch "$STUB_DIR/not_ready_alphafox"
run_helper spawn --claude 1 --cwd "$WORK/repo" --no-prompt --json
check "an agent stuck at a dialog keeps its tab: it is running there" \
    test "$(count_calls '^herdr tab close')/$(jq -r '.agents[0].tab_id' <<<"$OUT")" = "0/w9:t1"

reset_stub badname
printf '%s\n' 'Not A Name' >"$STUB_DIR/am_names"
run_helper spawn --claude 1 --cwd "$WORK/repo" --no-prompt
check "a name herdr cannot take stops before any tab is created" \
    test "$RC/$(count_calls '^herdr')" = "1/0"

reset_stub noworkspace
RC=0
env -u HERDR_WORKSPACE_ID PATH="$WORK/bin:$PATH" bash "$HELPER" spawn --claude 1 --cwd "$WORK/repo" \
    >/dev/null 2>"$STUB_DIR/err" || RC=$?
check "without --workspace or HERDR_WORKSPACE_ID, spawn refuses" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "no workspace" "$2"' _ "$RC" "$STUB_DIR/err"

# acfs-gen.3: Codex's shared app-server daemon must not inherit a pane's
# HERDR_* variables, or every Codex session reports as that pane's agent.
echo "codex daemon"

reset_stub daemonstart
run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt --json
check "spawn --codex with no daemon starts one before any identity or tab" \
    test "$RC/$(cut -d' ' -f1-4 "$STUB_DIR/calls" | head -1)" = "0/codex app-server daemon start"
check "the daemon is started with every HERDR_* variable removed" test ! -s "$STUB_DIR/codex_env"
check "the Codex agent is then spawned as usual" \
    test "$(count_calls '^am agents create')/$(count_calls '^herdr agent start alphafox --kind codex')" = "1/1"

reset_stub daemonclaude
run_helper spawn --claude 2 --cwd "$WORK/repo" --no-prompt
check "a spawn without Codex agents never touches the daemon" test "$RC/$(count_calls '^codex')" = "0/0"

reset_stub daemonclean
fake_daemon clean
run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt
check "a running daemon without HERDR_* variables is left alone" test "$RC/$(count_calls '^codex')" = "0/0"

reset_stub daemonleaked
fake_daemon leaked
run_helper spawn --claude 1 --codex 1 --cwd "$WORK/repo" --no-prompt --json
check "a daemon carrying a pane's variables stops spawn before any identity, tab or codex call" \
    test "$RC/$(count_calls '^am')/$(count_calls '^herdr')/$(count_calls '^codex')" = "1/0/0/0"
check "it names the variables and the fix" \
    bash -c 'grep -q "pid 777" <<<"$1" && grep -q "HERDR_PANE_ID, HERDR_TAB_ID" <<<"$1" && grep -q "acfs agents codex-daemon restart" <<<"$1"' _ "$ERR"

reset_stub daemondead
fake_daemon dead
run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt
check "a pid file without a live process counts as not running" \
    test "$RC/$(count_calls '^codex app-server daemon start')" = "0/1"

reset_stub daemonother
fake_daemon other
run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt
check "a pid reused by a process that is not a codex app-server counts as not running" \
    test "$RC/$(count_calls '^codex app-server daemon start')" = "0/1"

# As root every file is readable, so this case can only run unprivileged.
if [[ "$(id -u)" -ne 0 ]]; then
    reset_stub daemonunreadable
    fake_daemon unreadable
    run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt --json
    check "a daemon whose environment cannot be read is unknown, not clean: spawn stops before any identity" \
        bash -c '[[ "$1" -ne 0 && "$2" -eq 0 && "$3" -eq 0 ]] && grep -q "environment cannot be read" <<<"$4"' \
        _ "$RC" "$(count_calls '^am')" "$(count_calls '^codex')" "$ERR"
    run_helper codex-daemon status --json
    check "status --json reports clean null and exits 2 for an unreadable environment" \
        test "$RC/$(jq -c '[.running, .clean, .leaked_herdr_vars]' <<<"$OUT")" = "2/[true,null,null]"
    run_helper codex-daemon status
    check "the text status says the variables are unknown" \
        grep -q "environment unreadable, HERDR_\* variables unknown" <<<"$OUT"
fi

reset_stub daemonfail
touch "$STUB_DIR/daemon_start_fail"
run_helper spawn --codex 1 --cwd "$WORK/repo" --no-prompt
check "a daemon that fails to start stops spawn before any identity" \
    test "$RC/$(count_calls '^am')" = "1/0"

reset_stub daemondry
run_helper spawn --codex 1 --cwd "$WORK/repo" --dry-run
check "--dry-run only says it would start the daemon" \
    bash -c '[[ "$1" -eq 0 && "$2" -eq 0 ]] && grep -q "would run: codex app-server daemon start" <<<"$3"' _ "$RC" "$(count_calls '^codex')" "$ERR"

reset_stub statusnone
run_helper codex-daemon status --json
check "codex-daemon status --json reports no daemon, exit 0" \
    test "$RC/$(jq -c '[.running, .clean, .leaked_herdr_vars]' <<<"$OUT")" = "0/[false,true,[]]"

reset_stub statusclean
fake_daemon clean
run_helper codex-daemon status
check "status of a clean daemon prints its pid, exit 0" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "running (pid 777), no HERDR_\* variables" <<<"$2"' _ "$RC" "$OUT"

reset_stub statusleaked
fake_daemon leaked
run_helper codex-daemon status --json
check "status --json of a leaked daemon lists the variables and exits 1" \
    test "$RC/$(jq -r '.leaked_herdr_vars | join(",")' <<<"$OUT")" = "1/HERDR_ENV,HERDR_PANE_ID,HERDR_TAB_ID,HERDR_WORKSPACE_ID,HERDR_SOCKET_PATH,HERDR_BIN_PATH"
run_helper codex-daemon status
check "the text status names the fix" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "with HERDR_ENV, HERDR_PANE_ID" <<<"$2" && grep -q "Fix: acfs agents codex-daemon restart" <<<"$2"' _ "$RC" "$OUT"

reset_stub restart
fake_daemon leaked
run_helper codex-daemon restart
check "codex-daemon restart runs the restart without HERDR_* variables and reports the clean daemon" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx "codex app-server daemon restart" "$2" && [[ ! -s "$3" ]] && grep -q "pid 4242" <<<"$4"' \
    _ "$RC" "$STUB_DIR/calls" "$STUB_DIR/codex_env" "$OUT"

reset_stub startcmd
run_helper codex-daemon start
check "codex-daemon start starts a missing daemon and reports it" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx "codex app-server daemon start" "$2" && grep -q "pid 4242" <<<"$3"' _ "$RC" "$STUB_DIR/calls" "$OUT"

reset_stub startleaked
fake_daemon leaked
run_helper codex-daemon start
check "codex-daemon start refuses to leave a leaked daemon in place" \
    test "$RC/$(count_calls '^codex')" = "1/0"

echo "send and list"

write_list() {
    cat >"$STUB_DIR/list.json" <<'EOF'
{"id":"cli:agent:list","result":{"agents":[
 {"agent":"claude","agent_status":"idle","name":"alphafox","pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"},
 {"agent":"codex","agent_status":"done","name":"betaowl","pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"},
 {"agent":"codex","agent_status":"blocked","name":"gammayak","pane_id":"w9:p3","tab_id":"w9:t3","workspace_id":"w9"},
 {"agent":"claude","agent_status":"working","pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2"}
]}}
EOF
}

reset_stub sendkind
write_list
touch "$STUB_DIR/agent_blocked_gammayak"
run_helper send --kind codex "Check your Agent Mail inbox."
check "send --kind prompts only that kind" \
    test "$(grep -o '^herdr agent prompt [a-z]*' "$STUB_DIR/calls" | tr '\n' '|')" = "herdr agent prompt betaowl|herdr agent prompt gammayak|"
check "a blocked agent is skipped and reported, and send exits nonzero" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "skipped gammayak: blocked" <<<"$2" && grep -q "sent 1, skipped 1" <<<"$2"' _ "$RC" "$ERR"
check "send waits until the agent is seen working, for at most 15 s" \
    grep -qx -- "herdr agent prompt betaowl Check your Agent Mail inbox. --wait --until working --until blocked --timeout 15000" "$STUB_DIR/calls"

# acfs-gen.2: every way a prompt can fail to arrive is reported, and fails send.
reset_stub sendmissing
write_list
run_helper send --name AlphaFox --name SwiftBasin ping
check "a --name herdr does not list is agent_not_found, and the rest are still sent" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "skipped swiftbasin (agent_not_found)" <<<"$2" && grep -q "sent 1, skipped 1" <<<"$2"' _ "$RC" "$ERR"
check "nothing is prompted under the missing name" bash -c '! grep -q "agent prompt swiftbasin" "$1"' _ "$STUB_DIR/calls"

reset_stub sendonlymissing
write_list
run_helper send --name ghost ping
check "send to only a missing name exits nonzero and prompts nobody" \
    bash -c '[[ "$1" -ne 0 && "$2" -eq 0 ]] && grep -q "skipped ghost (agent_not_found)" <<<"$3"' _ "$RC" "$(count_calls '^herdr agent prompt')" "$ERR"

reset_stub sendnotfound
write_list
touch "$STUB_DIR/agent_not_found_betaowl"
run_helper send --name betaowl ping
check "agent_not_found from herdr itself fails send" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "skipped betaowl (agent_not_found): herdr no longer knows" <<<"$2" && grep -q "sent 0, skipped 1" <<<"$2"' _ "$RC" "$ERR"

reset_stub sendtyped
write_list
touch "$STUB_DIR/agent_prompt_stalled_betaowl"
printf 'answer\r\n\e[0m\xe2\x9d\xaf\xc2\xa0\e[0mping\e[0m\r\n' >"$STUB_DIR/screen_betaowl"
run_helper send --name betaowl ping
check "a stall with undimmed text in the input box says it is typed but not submitted" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "not submitted to betaowl (agent_prompt_stalled)" <<<"$2" && grep -q "undimmed text is in its input box" <<<"$2"' _ "$RC" "$ERR"
check "the stall shows the screen without escape sequences, and sends no key" \
    bash -c 'grep -q "^    | .*ping$" <<<"$1" && ! grep -q $'"'"'\e'"'"' <<<"$1" && ! grep -q "send-keys" "$2"' _ "$ERR" "$STUB_DIR/calls"

reset_stub sendghost
write_list
touch "$STUB_DIR/agent_prompt_stalled_betaowl"
printf '\e[0m\xe2\x9d\xaf\xc2\xa0\e[0m\e[2mCheck your Agent Mail inbox.\e[0m\r\n\e[38;2;1;2;3m  auto mode on\e[0m\r\n' >"$STUB_DIR/screen_betaowl"
run_helper send --name betaowl ping
check "a dim line in the input box is a suggestion, not a pending prompt" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "nothing is typed in its input box" <<<"$2"' _ "$RC" "$ERR"

# acfs-patg: the screen check holds under every awk installed, in a UTF-8
# locale, where gawk (GitHub's runners) counts characters and mawk bytes.
for impl in mawk gawk original-awk; do
    impl_path="$(command -v "$impl" || true)"
    [[ -n "$impl_path" ]] || continue
    mkdir -p "$WORK/awk-$impl"
    ln -sf "$impl_path" "$WORK/awk-$impl/awk"
    reset_stub "sendghost-$impl"
    write_list
    touch "$STUB_DIR/agent_prompt_stalled_betaowl"
    printf '\e[0m\xe2\x9d\xaf\xc2\xa0\e[0m\e[2mCheck your Agent Mail inbox.\e[0m\r\n' >"$STUB_DIR/screen_betaowl"
    LC_ALL=C.UTF-8 PATH="$WORK/awk-$impl:$PATH" run_helper send --name betaowl ping
    check "under $impl in UTF-8, a dim line after the no-break space is a suggestion" \
        bash -c 'grep -q "nothing is typed in its input box" <<<"$1"' _ "$ERR"
    reset_stub "sendtyped-$impl"
    write_list
    touch "$STUB_DIR/agent_prompt_stalled_betaowl"
    printf '\e[0m\xe2\x9d\xaf\xc2\xa0\e[0mping\e[0m\r\n' >"$STUB_DIR/screen_betaowl"
    LC_ALL=C.UTF-8 PATH="$WORK/awk-$impl:$PATH" run_helper send --name betaowl ping
    check "under $impl in UTF-8, undimmed text after the no-break space is typed" \
        bash -c 'grep -q "undimmed text is in its input box" <<<"$1"' _ "$ERR"
done

reset_stub sendtimeout
write_list
touch "$STUB_DIR/timeout_betaowl"
run_helper send --name betaowl --wait --timeout 100 ping
check "a timeout is reported with the limit, and fails send" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "unconfirmed for betaowl (timeout): .* within 100 ms" <<<"$2"' _ "$RC" "$ERR"

reset_stub sendraised
write_list
echo blocked >"$STUB_DIR/after_betaowl"
run_helper send --name betaowl --timeout 3000 ping
check "a prompt that raised a question counts as sent, and says so" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "sent: betaowl, which is now blocked" <<<"$2"' _ "$RC" "$ERR"
check "--timeout works without --wait" \
    grep -qx -- "herdr agent prompt betaowl ping --wait --until working --until blocked --timeout 3000" "$STUB_DIR/calls"

reset_stub sendall
write_list
RC=0
PATH="$WORK/bin:$PATH" HERDR_PANE_ID=w9:p1 bash "$HELPER" send --all --workspace w9 --wait --timeout 5000 hello there \
    >/dev/null 2>"$STUB_DIR/err" || RC=$?
check "send --all --workspace skips this pane and other workspaces" \
    test "$(grep -o '^herdr agent prompt [a-z]*' "$STUB_DIR/calls" | tr '\n' '|')" = "herdr agent prompt betaowl|herdr agent prompt gammayak|"
check "--wait and --timeout pass through, with the prompt words joined" \
    grep -qx -- "herdr agent prompt betaowl hello there --wait --timeout 5000" "$STUB_DIR/calls"
check "send exits 0 when nothing was skipped" test "$RC" -eq 0

# acfs-gen.7: --all reports each target, and one agent gone since the list fails send.
reset_stub sendallmissing
write_list
touch "$STUB_DIR/agent_not_found_betaowl"
run_helper send --all --workspace w9 ping
check "send --all --workspace with one agent gone still prompts the rest, and exits nonzero" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "^sent: alphafox (working)$" <<<"$2" && grep -q "skipped betaowl (agent_not_found)" <<<"$2" \
        && grep -q "^sent: gammayak (working)$" <<<"$2" && grep -q "^sent 2, skipped 1$" <<<"$2"' _ "$RC" "$ERR"
check "send --all --workspace prompts no agent of another workspace" bash -c '! grep -q "agent prompt w2:" "$1"' _ "$STUB_DIR/calls"

reset_stub unnamed
write_list
run_helper send --all --workspace w2 ping
check "an agent without a name is prompted by its pane id" \
    grep -qx -- "herdr agent prompt w2:p1 ping --wait --until working --until blocked --timeout 15000" "$STUB_DIR/calls"

reset_stub sendnone
write_list
run_helper send hello
check "send without a selector refuses and prompts nobody" \
    test "$RC/$(count_calls '^herdr agent prompt')" = "1/0"

reset_stub list
write_list
run_helper list --workspace w9 --kind codex --json
check "list filters by workspace and kind" test "$(jq -r '[.[].name] | join(",")' <<<"$OUT")" = "betaowl,gammayak"
run_helper list
check "list prints a table with every agent" \
    bash -c 'head -1 <<<"$1" | grep -q "^NAME *KIND *STATUS *PANE *TAB$" && [[ $(wc -l <<<"$1") -eq 5 ]]' _ "$OUT"

# acfs-gen.5: inbox lists every unread message to the agent, oldest first,
# then marks each read.
echo "inbox"

# 45 unread messages to the agent (#1-#45, #44 a bcc) in two threads, #2
# needing an ack, #46 an unread cc, #47 already read, and #48 arriving
# between the helper's two am calls (unread, but not yet in `am mail inbox`).
write_mailbox() {
    jq -n '[range(1; 49) | {
        id: .,
        kind: (if . == 46 then "cc" elif . == 44 then "bcc" else "to" end),
        thread: (if . % 2 == 1 then "odd" else "even" end),
        created_ts: "2026-10-10T07:\(. | tostring | if length == 1 then "0" + . else . end):00Z",
        importance: (if . == 45 then "high" else "normal" end),
        ack_status: (if . == 2 then "required" else "none" end),
        from: "BlueLake", subject: "message \(.)", body_md: "body of \(.)",
        late: (. == 48)}]' >"$STUB_DIR/mailbox.json"
    echo 47 >"$STUB_DIR/read_ids"
}
unread_ids() {
    jq -c --slurpfile read <(cat "$STUB_DIR/read_ids") \
        '[.[] | select(.id as $i | $read | index($i) | not) | .id]' "$STUB_DIR/mailbox.json"
}

reset_stub inbox
write_mailbox
run_helper inbox --agent BetaOwl --project /stub/project
check "inbox lists every unread message to the agent, past am's 20-row default" \
    test "$(grep -c '^--- #' <<<"$OUT")" -eq 45
check "a message older than 40 newer ones is listed" grep -q '^--- #1 2026-10-10T07:01:00Z from BlueLake \[normal\]$' <<<"$OUT"
check "messages are grouped by thread, the thread of the oldest first, oldest first within it" \
    test "$(grep -o '^--- #[0-9]*' <<<"$OUT" | head -3 | tr '\n' ' ')" = "--- #1 --- #3 --- #5 "
check "the even thread follows the odd one" \
    bash -c 'grep "^== thread" <<<"$1" | tr "\n" "|" | grep -qx "== thread odd (23 unread)|== thread even (22 unread)|"' _ "$OUT"
check "bodies are printed, a bcc's too" grep -qx 'body of 44' <<<"$OUT"
check "the cc and the message that arrived late are not listed" \
    bash -c '! grep -q "^--- #4[678] " <<<"$1"' _ "$OUT"
check "each listed message is marked read with am mail read, and nothing else" \
    test "$(grep -c '^am mail read --project /stub/project --agent BetaOwl [0-9]*$' "$STUB_DIR/calls")/$(count_calls '^am mail read')" = "45/45"
check "afterwards only the cc and the late message are unread" test "$(unread_ids)" = "[46,48]"
check "inbox counts what it listed and what stays unread, and names the ack pending" \
    grep -qx 'listed 45 unread, marked 45 read; 1 cc still unread; ack pending: #2' <<<"$OUT"
check "inbox exits 0" test "$RC" -eq 0

reset_stub inboxkeep
write_mailbox
run_helper inbox --agent BetaOwl --project /stub/project --keep-unread
check "--keep-unread lists the same messages and marks none read" \
    test "$(grep -c '^--- #' <<<"$OUT")/$(count_calls '^am mail read')/$(unread_ids | jq length)" = "45/0/47"

reset_stub inboxfail
write_mailbox
touch "$STUB_DIR/read_fail_7"
run_helper inbox --agent BetaOwl --project /stub/project
check "a message am cannot mark read is named, counted and fails the call" \
    bash -c '[[ "$1" -eq 1 ]] && grep -q "could not mark #7 read" <<<"$2" && grep -q "marked 44 read" <<<"$3"' _ "$RC" "$ERR" "$OUT"

reset_stub inboxenv
write_mailbox
RC=0
(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" AGENT_NAME=BetaOwl AGENT_MAIL_PROJECT='' AGENT_MAIL_AGENT='' \
    bash "$HELPER" inbox >/dev/null 2>&1) || RC=$?
check "inbox takes the agent from AGENT_NAME, and the project from the directory outside git" \
    grep -qx "am mail inbox --project $WORK/repo --agent BetaOwl --limit 1000000 --json" "$STUB_DIR/calls"

reset_stub inboxnoagent
write_mailbox
RC=0
PATH="$WORK/bin:$PATH" AGENT_NAME='' AGENT_MAIL_AGENT='' bash "$HELPER" inbox >/dev/null 2>&1 || RC=$?
check "inbox without an agent refuses and calls no am" test "$RC/$(count_calls '^am ')" = "1/0"

echo "retire"

# A git repo for this case, with origin/main at its first commit.
retire_repo() {
    REPO="$STUB_DIR/repo"
    git init -q -b main "$REPO"
    printf 'a\n' >"$REPO/a.txt"
    printf 'b\n' >"$REPO/b.txt"
    git -C "$REPO" add a.txt b.txt
    git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q -m init
    git -C "$REPO" update-ref refs/remotes/origin/main HEAD
}
# Tab w9:t1 holds $1 panes (default 1).
write_tabs() {
    printf '{"result":{"tabs":[{"label":"AlphaFox","pane_count":%s,"tab_id":"w9:t1","workspace_id":"w9"},{"label":"BetaOwl","pane_count":1,"tab_id":"w9:t2","workspace_id":"w9"}]}}\n' \
        "${1:-1}" >"$STUB_DIR/tabs.json"
}
retire_case() {
    reset_stub "$1"
    write_list
    write_tabs "${2:-1}"
    retire_repo
}

retire_case rdry
run_helper retire AlphaFox --cwd "$REPO" --dry-run
check "retire --dry-run exits 0 and says it would close the agent's tab" \
    bash -c '[[ "$1" -eq 0 ]] && grep -q "would close tab w9:t1" <<<"$2"' _ "$RC" "$ERR"
check "retire --dry-run closes nothing" test "$(count_calls 'close')" -eq 0
check "without a token the identity stays, and retire says so" grep -q "identity stays active" <<<"$ERR"

retire_case rtab
run_helper retire AlphaFox --cwd "$REPO"
check "retire closes the tab of an agent alone in it" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx "herdr tab close w9:t1" "$2"' _ "$RC" "$STUB_DIR/calls"
check "retire looks the agent up in Agent Mail by its Agent Mail name" \
    grep -qx -- "am agents show AlphaFox --project $REPO --json" "$STUB_DIR/calls"

retire_case rpane 2
run_helper retire AlphaFox --cwd "$REPO"
check "in a grouped tab, retire closes only the agent's pane" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx "herdr pane close w9:p1" "$2" && ! grep -q "tab close" "$2"' _ "$RC" "$STUB_DIR/calls"

retire_case rheld
printf '{"all_active":[{"agent":"AlphaFox","path":"a.txt"},{"agent":"BetaOwl","path":"b.txt"}]}\n' >"$STUB_DIR/reservations.json"
run_helper retire AlphaFox --cwd "$REPO"
check "an agent holding reservations is refused, naming them, and nothing closes" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "refused: AlphaFox still holds reservations: a.txt$" <<<"$2" && ! grep -q close "$3"' _ "$RC" "$ERR" "$STUB_DIR/calls"

retire_case rdirty
printf '7    *.txt                AlphaFox    2026-10-10T08:00:00.  acfs-x\n' >"$STUB_DIR/reserved_ever"
printf 'changed\n' >>"$REPO/a.txt"
printf 'changed\n' >>"$REPO/b.txt"
printf '{"all_active":[{"agent":"BetaOwl","path":"b.txt"}]}\n' >"$STUB_DIR/reservations.json"
run_helper retire AlphaFox --cwd "$REPO"
check "uncommitted changes in a file the agent once reserved refuse retirement" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "uncommitted changes in files AlphaFox reserved: a.txt$" <<<"$2"' _ "$RC" "$ERR"
printf '{"all_active":[{"agent":"BetaOwl","path":"*.txt"}]}\n' >"$STUB_DIR/reservations.json"
run_helper retire AlphaFox --cwd "$REPO"
check "a changed file another agent holds now is not the retiring agent's" test "$RC" -eq 0

retire_case rworking
sed -i 's/"agent_status":"idle","name":"alphafox"/"agent_status":"working","name":"alphafox"/' "$STUB_DIR/list.json"
run_helper retire AlphaFox --cwd "$REPO"
check "a working agent is refused" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "alphafox is working" <<<"$2" && ! grep -q close "$3"' _ "$RC" "$ERR" "$STUB_DIR/calls"

retire_case rself
RC=0
PATH="$WORK/bin:$PATH" HERDR_PANE_ID=w9:p1 bash "$HELPER" retire AlphaFox --cwd "$REPO" >/dev/null 2>"$STUB_DIR/err" || RC=$?
check "retire refuses the agent in this pane" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "runs in this pane" "$2"' _ "$RC" "$STUB_DIR/err"

retire_case rwt
git -C "$REPO" worktree add -q "$STUB_DIR/alphafox-merged" HEAD
git -C "$REPO" worktree add -q -b side "$STUB_DIR/alphafox-ahead" HEAD
git -C "$STUB_DIR/alphafox-ahead" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m ahead
git -C "$REPO" worktree add -q "$STUB_DIR/betaowl-other" HEAD
run_helper retire AlphaFox --cwd "$REPO"
check "an unmerged worktree naming the agent refuses retirement" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "worktree .*alphafox-ahead is not merged to origin/main" <<<"$2"' _ "$RC" "$ERR"
check "a refused retirement removes no worktree" test -d "$STUB_DIR/alphafox-merged"
git -C "$REPO" worktree remove --force "$STUB_DIR/alphafox-ahead"
printf 'x\n' >"$STUB_DIR/alphafox-merged/new.txt"
run_helper retire AlphaFox --cwd "$REPO"
check "a dirty worktree naming the agent refuses retirement" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "alphafox-merged has uncommitted changes" <<<"$2"' _ "$RC" "$ERR"
rm -f "$STUB_DIR/alphafox-merged/new.txt"
run_helper retire AlphaFox --cwd "$REPO"
check "a clean merged worktree naming the agent is removed, others stay" \
    bash -c '[[ "$1" -eq 0 && ! -e "$2/alphafox-merged" && -d "$2/betaowl-other" ]]' _ "$RC" "$STUB_DIR"

retire_case rtoken
run_helper retire AlphaFox --cwd "$REPO" --token tok123
check "with a token, retire soft-retires the identity through retire_agent" \
    bash -c '[[ "$1" -eq 0 ]] && jq -e --arg p "$3" ".params.name == \"retire_agent\" and .params.arguments == {project_key: \$p, agent_name: \"AlphaFox\", registration_token: \"tok123\"}" "$2" >/dev/null' \
    _ "$RC" "$STUB_DIR/curl_body" "$REPO"
check "the identity is retired after the tab closes" \
    test "$(grep -E -o '^(herdr tab close|curl)' "$STUB_DIR/calls" | tr '\n' '|')" = "herdr tab close|curl|"
touch "$STUB_DIR/curl_refuse"
run_helper retire AlphaFox --cwd "$REPO" --token bad
check "a refused retire_agent fails retire and says why" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "retire_agent refused: invalid registration_token" <<<"$2"' _ "$RC" "$ERR"

retire_case rdropped
sed -i '/"name":"alphafox"/d' "$STUB_DIR/list.json"
run_helper retire AlphaFox --cwd "$REPO"
check "an agent whose herdr name dropped is found by its tab label" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx "herdr tab close w9:t1" "$2"' _ "$RC" "$STUB_DIR/calls"

retire_case runknown
touch "$STUB_DIR/am_unknown_NoSuch"
run_helper retire NoSuch --cwd "$REPO"
check "retire refuses a name Agent Mail doesn't have, before touching herdr" \
    bash -c '[[ "$1" -ne 0 ]] && ! grep -q "^herdr" "$2"' _ "$RC" "$STUB_DIR/calls"

echo "wake"
# Three agents in workspace w9, each in a tab labelled with its Agent Mail
# name: AlphaFox idle, BetaOwl done, GammaYak blocked. Each case uses its
# own project key, so its own state directory.
wake_case() {
    reset_stub "$1"
    WAKE_PROJECT="/proj/$1"
    cat >"$STUB_DIR/list.json" <<'EOF'
{"id":"cli:agent:list","result":{"agents":[
 {"agent":"claude","agent_status":"idle","name":"alphafox","pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"},
 {"agent":"codex","agent_status":"done","name":"betaowl","pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"},
 {"agent":"codex","agent_status":"blocked","name":"gammayak","pane_id":"w9:p3","tab_id":"w9:t3","workspace_id":"w9"}
]}}
EOF
    printf '{"result":{"tabs":[{"label":"AlphaFox","tab_id":"w9:t1"},{"label":"BetaOwl","tab_id":"w9:t2"},{"label":"GammaYak","tab_id":"w9:t3"}]}}\n' \
        >"$STUB_DIR/tabs.json"
}
# Deliver message cursor $2 (kind $3, default to) to agent $1.
deliver() {
    local file="$STUB_DIR/events_$1.json"
    [[ -s "$file" ]] || printf '[]\n' >"$file"
    jq -c --argjson c "$2" --arg k "${3:-to}" '. + [{cursor: $c, message_id: $c, kind: $k}]' "$file" >"$file.new"
    mv "$file.new" "$file"
}
set_status() { sed -i "s/\"agent_status\":\"[a-z]*\",\"name\":\"$1\"/\"agent_status\":\"$2\",\"name\":\"$1\"/" "$STUB_DIR/list.json"; }
wake_state() { printf '%s/acfs-home/state/wake/%s/%s.json' "$WORK" "$(printf '%s' "$WAKE_PROJECT" | sha256sum | cut -c1-16)" "$1"; }
# Let agent $1's 120 s gap pass.
gap_passes() { local f; f="$(wake_state "$1")"; jq -c '.last_wake = 0' "$f" >"$f.new" && mv "$f.new" "$f"; }
run_wake() { run_helper wake --workspace w9 --project "$WAKE_PROJECT" "$@"; }

wake_case wakeidle
deliver AlphaFox 1
run_wake
check "mail older than the first cycle wakes nobody" \
    bash -c '[[ "$1" -eq 0 && "$2" -eq 0 ]]' _ "$RC" "$(count_calls '^herdr agent prompt')"
deliver AlphaFox 5
deliver BetaOwl 6 cc
deliver GammaYak 7
run_wake
check "new mail to an idle and a done agent wakes both through the checked prompt" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qx -- "herdr agent prompt alphafox Check your Agent Mail inbox. --wait --until working --until blocked --timeout 15000" "$2" && grep -q "^herdr agent prompt betaowl " "$2"' \
    _ "$RC" "$STUB_DIR/calls"
check "a blocked agent is not prompted" bash -c '! grep -q "^herdr agent prompt gammayak" "$1"' _ "$STUB_DIR/calls"
check "each wake is one line on stderr, with the time in UTC" \
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z woke alphafox \(AlphaFox\): 1 new message\(s\)$' <<<"$ERR"
deliver AlphaFox 8
run_wake
check "an agent is not woken twice within 120 s" test "$(count_calls '^herdr agent prompt alphafox')" = 1
gap_passes AlphaFox
run_wake
check "after the gap, the mail that came meanwhile wakes it" test "$(count_calls '^herdr agent prompt alphafox')" = 2
set_status gammayak idle
run_wake
check "the blocked agent is woken on the cycle after it settles" test "$(count_calls '^herdr agent prompt gammayak')" = 1
run_wake
check "with no new mail, nobody is woken" test "$(count_calls '^herdr agent prompt')" = 4

wake_case wakeworking
run_wake
set_status alphafox working
deliver AlphaFox 3
run_wake
check "a working agent is not prompted" test "$(count_calls '^herdr agent prompt')" = 0
set_status alphafox idle
run_wake
check "it is prompted on the next cycle after it settles" test "$(count_calls '^herdr agent prompt alphafox')" = 1

wake_case wakeself
sed -i 's/"pane_id":"w9:p1"/"pane_id":"w9:p9"/' "$STUB_DIR/list.json"
run_wake
deliver AlphaFox 2
run_wake
check "the pane running wake is never prompted" test "$(count_calls '^herdr agent prompt')" = 0

wake_case wakeoverdue
run_wake
printf '62   VioletFortress  Re: [main-sync] Stop  993min\n' >"$STUB_DIR/overdue_BetaOwl"
run_wake
check "a newly overdue ack wakes its agent and says so" \
    bash -c 'grep -q "^herdr agent prompt betaowl " "$1" && grep -q "woke betaowl (BetaOwl): 0 new message(s), 1 newly overdue ack(s)" <<<"$2"' _ "$STUB_DIR/calls" "$ERR"
gap_passes BetaOwl
run_wake
check "the same overdue ack does not wake it again" test "$(count_calls '^herdr agent prompt betaowl')" = 1

wake_case wakestall
run_wake
deliver AlphaFox 4
touch "$STUB_DIR/agent_prompt_stalled_alphafox"
printf '\e[0m\xe2\x9d\xaf\xc2\xa0\e[0m\e[2mCheck your Agent Mail inbox.\e[0m\r\n' >"$STUB_DIR/screen_alphafox"
run_wake
check "a wake whose prompt stalled fails the cycle and says why" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "could not wake alphafox (AlphaFox): 1 new message(s)" <<<"$2" && grep -q "agent_prompt_stalled" <<<"$2"' _ "$RC" "$ERR"
rm -f "$STUB_DIR/agent_prompt_stalled_alphafox"
gap_passes AlphaFox
run_wake
check "the failed wake's mail is retried after the gap" \
    bash -c '[[ "$1" -eq 0 && "$2" -eq 2 ]]' _ "$RC" "$(count_calls '^herdr agent prompt alphafox')"

wake_case wakedropped
run_wake
sed -i 's/"name":"alphafox",//' "$STUB_DIR/list.json"
sed -i 's/"label":"BetaOwl"/"label":"SomeoneElse"/' "$STUB_DIR/tabs.json"
deliver AlphaFox 2
deliver BetaOwl 3
run_wake
check "an agent whose herdr name dropped is woken by its pane, found by its tab label" \
    grep -q "^herdr agent prompt w9:p1 " "$STUB_DIR/calls"
check "an agent whose tab label is another name is left alone" bash -c '! grep -q "^herdr agent prompt betaowl" "$1"' _ "$STUB_DIR/calls"

wake_case wakedry
run_wake
deliver AlphaFox 2
run_wake --dry-run
check "--dry-run says whom it would wake and prompts nobody" \
    bash -c 'grep -q "would wake alphafox (AlphaFox): 1 new message(s)" <<<"$1" && [[ "$2" -eq 0 ]]' _ "$ERR" "$(count_calls '^herdr agent prompt')"
run_wake
check "a dry run moves no cursor" test "$(count_calls '^herdr agent prompt alphafox')" = 1

wake_case wakecorrupt
run_wake
deliver AlphaFox 2
printf 'not json\n' >"$(wake_state AlphaFox)"
run_wake
check "an unreadable state file counts as a first cycle, and the cycle still runs" \
    bash -c '[[ "$1" -eq 0 && "$2" -eq 0 ]] && jq -e ".cursor == 2" "$3" >/dev/null' _ "$RC" "$(count_calls '^herdr agent prompt')" "$(wake_state AlphaFox)"

wake_case wakelock
run_wake
exec {wake_lock_fd}>"$(dirname "$(wake_state AlphaFox)")/lock"
flock -n "$wake_lock_fd"
run_wake
exec {wake_lock_fd}>&-
check "a second wake for the same project refuses to run" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "another acfs agents wake is running for /proj/wakelock" <<<"$2"' _ "$RC" "$ERR"

wake_case wakeloop
run_wake
( sleep 1.5; deliver AlphaFox 2 ) &
RUN_WRAPPER=(timeout 4)
run_wake --loop --interval 1
RUN_WRAPPER=()
wait
check "with the loop running, mail to an idle agent wakes it within one interval" \
    bash -c '[[ "$1" -eq 124 && "$2" -eq 1 ]] && grep -q "woke alphafox (AlphaFox)" <<<"$3"' _ "$RC" "$(count_calls '^herdr agent prompt alphafox')" "$ERR"
check "the loop keeps cycling: herdr is listed once per interval" \
    bash -c '[[ "$1" -ge 3 ]]' _ "$(count_calls '^herdr agent list')"

wake_case wakeinterval
run_wake --loop --interval 0
check "--interval takes only whole seconds above zero" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q -- "--interval needs whole seconds" <<<"$2"' _ "$RC" "$ERR"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
