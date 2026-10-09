#!/usr/bin/env bash
# ============================================================
# scripts/lib/herdr_agents.sh (acfs agents spawn/send/list) against a STUB
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
    "agent start")
        [[ ! -e "$STUB_DIR/not_ready_$3" ]] || fail_with agent_not_ready "agent $3 is not ready"
        printf '{"id":"cli:agent:start","result":{"agent":{"name":"%s"}}}\n' "$3"
        ;;
    "agent prompt")
        [[ ! -e "$STUB_DIR/blocked_$3" ]] || fail_with agent_blocked "agent $3 is blocked"
        printf '%s' "$4" >"$STUB_DIR/prompt_$3"
        printf '{"id":"cli:agent:prompt","result":{"submitted":true}}\n'
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
    *) fail_with unexpected "stub herdr got: $*" ;;
esac
STUB
cat >"$WORK/bin/am" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'am %s\n' "$*" >>"$STUB_DIR/calls"
n=$(( $(cat "$STUB_DIR/am_count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/am_count"
name="$(sed -n "${n}p" "$STUB_DIR/am_names")"
printf '{"id":%s,"name":"%s","program":"stub"}\n' "$n" "$name"
STUB
chmod +x "$WORK/bin/herdr" "$WORK/bin/am"

# A fresh stub state per case.
reset_stub() {
    STUB_DIR="$WORK/stub.$1"
    mkdir -p "$STUB_DIR"
    printf '%s\n' AlphaFox BetaOwl GammaYak DeltaElk >"$STUB_DIR/am_names"
    : >"$STUB_DIR/calls"
    export STUB_DIR
}

# Run the helper with the stubs first on PATH; stdout, stderr and the
# exit code land in $OUT, $ERR and $RC.
run_helper() {
    RC=0
    PATH="$WORK/bin:$PATH" HOME="$WORK/home" ACFS_HOME="$WORK/acfs-home" \
        bash "$HELPER" "$@" >"$STUB_DIR/out" 2>"$STUB_DIR/err" || RC=$?
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
    grep -qx -- "herdr agent start gammayak --kind codex --pane w9:p3" "$STUB_DIR/calls"
check "--no-prompt sends no prompt" test "$(count_calls '^herdr agent prompt')" -eq 0
check "identity, then tab, then start, per agent" \
    test "$(cut -d' ' -f1-3 "$STUB_DIR/calls" | head -3 | tr '\n' '|')" = "am agents create|herdr tab create|herdr agent start|"
check "--json lists each agent as started" \
    test "$(jq -r '[.agents[].status] | unique | join(",")' <<<"$OUT")" = started

reset_stub kickoff
run_helper spawn --claude 1 --cwd "$WORK/repo"
check "spawn with the default kickoff exits 0" test "$RC" -eq 0
check "the kickoff carries the agent's identity" \
    grep -q "name AlphaFox, project key $WORK/repo .*herdr name is alphafox, in herdr workspace w9" "$STUB_DIR/prompt_alphafox"
check "the kickoff carries the palette's default_new_agent and stops at the next heading" \
    bash -c 'grep -q "register with Agent Mail" "$1" && ! grep -q "Not part" "$1"' _ "$STUB_DIR/prompt_alphafox"
check "the kickoff is submitted without --wait" bash -c '! grep -q -- "--wait" "$1"' _ "$STUB_DIR/calls"

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
touch "$STUB_DIR/blocked_alphafox"
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
touch "$STUB_DIR/blocked_gammayak"
run_helper send --kind codex "Check your Agent Mail inbox."
check "send --kind prompts only that kind" \
    test "$(grep -o '^herdr agent prompt [a-z]*' "$STUB_DIR/calls" | tr '\n' '|')" = "herdr agent prompt betaowl|herdr agent prompt gammayak|"
check "a blocked agent is skipped and reported, and send exits nonzero" \
    bash -c '[[ "$1" -ne 0 ]] && grep -q "skipped gammayak: blocked" <<<"$2" && grep -q "sent 1, skipped 1" <<<"$2"' _ "$RC" "$ERR"
check "send never waits with --until" bash -c '! grep -q -- "--until" "$1"' _ "$STUB_DIR/calls"

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

reset_stub unnamed
write_list
run_helper send --all --workspace w2 ping
check "an agent without a name is prompted by its pane id" grep -qx -- "herdr agent prompt w2:p1 ping" "$STUB_DIR/calls"

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

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
