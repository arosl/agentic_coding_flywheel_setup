#!/usr/bin/env bash
# ============================================================
# scripts/lib/agent_mail_hook.sh (the Agent Mail Stop hook) against a
# STUB am and a STUB herdr
#
# Proves when the hook sends an agent back to read its mail and when it
# stays silent, and that registering it in a Claude Code settings.json or
# a Codex hooks.json is idempotent and keeps everything else in the file.
#
# Usage: bash tests/unit/test_agent_mail_hook.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/scripts/lib/agent_mail_hook.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-agent-mail-hook.XXXXXX")"
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
# Stubs: am answers check-inbox from $STUB_DIR/inbox.json (or fails when
# $STUB_DIR/am_fail exists); herdr answers tab get and agent list.
# ------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/stub"
cat >"$WORK/bin/am" <<'STUB'
#!/usr/bin/env bash
printf 'am %s\n' "$*" >>"$STUB_DIR/calls"
[[ ! -e "$STUB_DIR/am_fail" ]] || exit 1
[[ "$1" == check-inbox ]] || exit 2
cat "$STUB_DIR/inbox.json" 2>/dev/null
STUB
cat >"$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >>"$STUB_DIR/calls"
case "$1 $2" in
    "tab get")
        label="$(cat "$STUB_DIR/label_$3" 2>/dev/null)" || exit 1
        printf '{"id":"cli:tab:get","result":{"tab":{"label":"%s","tab_id":"%s"},"type":"tab_info"}}\n' "$label" "$3"
        ;;
    "agent list")
        printf '{"id":"cli:agent:list","result":{"agents":[{"name":"icyknoll","tab_id":"w1:t7","agent_session":{"value":"sess-codex-7"}}]}}\n'
        ;;
    *) exit 2 ;;
esac
STUB
chmod 0755 "$WORK/bin/am" "$WORK/bin/herdr"
git -C "$WORK/repo" init -q
mkdir -p "$WORK/repo/sub"

export STUB_DIR="$WORK/stub"
export PATH="$WORK/bin:$PATH"
export HOME="$WORK/home"
mkdir -p "$HOME"
unset AGENT_MAIL_AGENT AGENT_NAME AGENT_MAIL_PROJECT HERDR_TAB_ID HERDR_PANE_ID

inbox() {
    # inbox <unread_count> <id>...
    local count="$1"
    shift
    local messages="" id
    for id in "$@"; do
        messages+="${messages:+,}{\"id\":$id,\"subject\":\"s$id\",\"from\":\"BlueLake\",\"importance\":\"normal\"}"
    done
    printf '{"agent":"x","unread_count":%s,"urgent_or_high_count":0,"messages":[%s]}\n' "$count" "$messages" >"$STUB_DIR/inbox.json"
}

event() {
    # event [stop_hook_active] [session_id] [cwd]
    printf '{"hook_event_name":"Stop","stop_hook_active":%s,"session_id":"%s","cwd":"%s"}' \
        "${1:-false}" "${2:-sess-1}" "${3:-$WORK/repo/sub}"
}

run_stop() {
    # Prints the hook's stdout; the exit status must always be 0.
    local out rc=0
    out="$(bash "$HOOK" stop 2>"$WORK/stderr")" || rc=$?
    [[ "$rc" -eq 0 ]] || out="EXIT $rc"
    printf '%s' "$out"
}

reset_state() {
    rm -rf "${HOME:?}/.acfs" "${STUB_DIR:?}"/*
}

echo "Stop hook"

reset_state
inbox 2 41 42
out="$(event | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "unread mail: blocks with the count" \
    test "$out" = '{"decision":"block","reason":"You have 2 unread Agent Mail messages; read them before you stop."}'
check "asks am for the agent, the git top level as project, no rate limit" \
    grep -qxF "am check-inbox --agent IcyKnoll --project $WORK/repo --rate-limit 0 --json" "$STUB_DIR/calls"

out="$(event | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "the same mail again: silent" test -z "$out"

inbox 3 41 42 43
out="$(event | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "a newer message: blocks again" \
    test "$out" = '{"decision":"block","reason":"You have 3 unread Agent Mail messages; read them before you stop."}'

reset_state
inbox 2 41 42
out="$(event true | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "stop_hook_active: silent" test -z "$out"
check "stop_hook_active: am not called" test ! -e "$STUB_DIR/calls"

reset_state
inbox 0
out="$(event | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "no unread mail: silent" test -z "$out"

reset_state
inbox 1 50
touch "$STUB_DIR/am_fail"
out="$(event | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "am fails: silent, exit 0" test -z "$out"

reset_state
inbox 1 50
out="$(event | PATH="$WORK/nobin:/usr/bin:/bin" AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "am missing: silent, exit 0" test -z "$out"

reset_state
inbox 1 50
out="$(event | run_stop)"
check "no agent name and no herdr tab: silent" test -z "$out"
check "no agent name: am not called" bash -c '! grep -q "^am " "$1"/calls 2>/dev/null' _ "$STUB_DIR"

reset_state
inbox 1 50
echo IcyKnoll >"$STUB_DIR/label_w1:t3"
out="$(event | HERDR_TAB_ID=w1:t3 run_stop)"
check "name from the herdr tab label (HERDR_TAB_ID), one message in the singular" \
    test "$out" = '{"decision":"block","reason":"You have 1 unread Agent Mail message; read them before you stop."}'

reset_state
inbox 1 50
echo IcyKnoll >"$STUB_DIR/label_w1:t7"
out="$(event false sess-codex-7 | run_stop)"
check "name from the herdr agent with the hook's session (Codex daemon)" \
    test "$out" = '{"decision":"block","reason":"You have 1 unread Agent Mail message; read them before you stop."}'
check "session lookup asked am for that tab's label" \
    grep -q -- "--agent IcyKnoll" "$STUB_DIR/calls"

reset_state
inbox 1 50
echo "my shell" >"$STUB_DIR/label_w1:t3"
out="$(event | HERDR_TAB_ID=w1:t3 run_stop)"
check "a tab label that isn't an Agent Mail name: silent" test -z "$out"

reset_state
inbox 1 50
out="$(event | AGENT_NAME=IcyKnoll AGENT_MAIL_PROJECT=/srv/proj run_stop)"
check "AGENT_NAME and AGENT_MAIL_PROJECT are used" \
    grep -qxF "am check-inbox --agent IcyKnoll --project /srv/proj --rate-limit 0 --json" "$STUB_DIR/calls"

reset_state
inbox 1 50
out="$(event | AGENT_NAME='../../escaped' run_stop)"
check "a name from the environment that isn't an Agent Mail name: silent" test -z "$out"
check "such a name writes no state file anywhere" test ! -e "$HOME/.acfs"

reset_state
out="$(printf 'not json' | AGENT_MAIL_AGENT=IcyKnoll run_stop)"
check "malformed event: silent, exit 0" test -z "$out"

echo "Register"

settings="$HOME/.claude/settings.json"
bash "$HOOK" register claude 2>/dev/null
check "creates a missing settings.json" test -f "$settings"
check "the new file is private (0600)" test "$(stat -c %a "$settings")" = 600
check "registered sees the hook" bash "$HOOK" registered "$settings"
check "the entry runs this file's stop with a timeout" \
    test "$(jq -c '.hooks.Stop' "$settings")" = "[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash $HOOK stop\",\"timeout\":10}]}]"
cp "$settings" "$WORK/first.json"
bash "$HOOK" register claude 2>/dev/null
check "a second run changes nothing" cmp -s "$settings" "$WORK/first.json"

fixture="$WORK/fixture.json"
cat >"$fixture" <<'JSON'
{
  "cleanupPeriodDays": 99999,
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/dcg"}]}],
    "Stop": [
      {"hooks": [{"type": "command", "command": "claude-done-notifier"}]},
      {"hooks": [{"type": "command", "command": "bash /old/home/.acfs/scripts/lib/agent_mail_hook.sh stop", "timeout": 10}]}
    ]
  }
}
JSON
chmod 0640 "$fixture"
bash "$HOOK" register claude "$fixture" 2>/dev/null
check "keeps other settings and hooks" \
    test "$(jq -c '[.cleanupPeriodDays, .hooks.PreToolUse[0].hooks[0].command, .hooks.Stop[0].hooks[0].command]' "$fixture")" \
    = '[99999,"/usr/local/bin/dcg","claude-done-notifier"]'
check "replaces an entry from an older install path" \
    test "$(jq -c '[.hooks.Stop[].hooks[].command | select(test("agent_mail_hook"))]' "$fixture")" = "[\"bash $HOOK stop\"]"
check "keeps the file's mode" test "$(stat -c %a "$fixture")" = 640
cp "$fixture" "$WORK/second.json"
bash "$HOOK" register claude "$fixture" 2>/dev/null
check "fixture: a second run changes nothing" cmp -s "$fixture" "$WORK/second.json"

mkdir -p "$WORK/dotfiles"
printf '{"model":"opus"}\n' >"$WORK/dotfiles/settings.json"
ln -s "$WORK/dotfiles/settings.json" "$WORK/linked.json"
bash "$HOOK" register claude "$WORK/linked.json" 2>/dev/null
check "a symlinked file stays a symlink" test -L "$WORK/linked.json"
check "the symlink's target gets the hook" bash "$HOOK" registered "$WORK/dotfiles/settings.json"

printf '{"hooks": []}\n' >"$WORK/bad.json"
cp "$WORK/bad.json" "$WORK/bad.orig"
check "refuses a file whose hooks isn't an object" bash -c '! bash "$1" register claude "$2" 2>/dev/null' _ "$HOOK" "$WORK/bad.json"
check "the refused file is unchanged" cmp -s "$WORK/bad.json" "$WORK/bad.orig"
printf '{not json\n' >"$WORK/broken.json"
check "refuses malformed JSON" bash -c '! bash "$1" register claude "$2" 2>/dev/null' _ "$HOOK" "$WORK/broken.json"

bash "$HOOK" register codex 2>/dev/null
check "codex: registers in ~/.codex/hooks.json" bash "$HOOK" registered "$HOME/.codex/hooks.json"
check "registered: false for a file without the hook" bash -c '! bash "$1" registered "$2"' _ "$HOOK" "$WORK/dotfiles/../bad.json"
check "unknown kind: usage error" bash -c 'bash "$1" register gemini 2>/dev/null; test $? -eq 2' _ "$HOOK"

echo
echo "agent_mail_hook: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
