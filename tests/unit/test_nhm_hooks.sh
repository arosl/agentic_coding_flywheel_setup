#!/usr/bin/env bash
# ============================================================
# scripts/lib/nhm_hooks.sh (nhm's hook lines for Claude Code and Codex)
#
# Proves that registering adds every nhm-hook line, is idempotent, keeps
# everything else in the file, never moves an existing entry (Codex keys
# hook trust by position), edits a symlinked file where it points, and
# leaves a file it cannot read unchanged. And that `trust codex` records
# Codex's trust for ACFS's own entries only, through a fake app-server.
#
# Usage: bash tests/unit/test_nhm_hooks.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$ROOT/scripts/lib/nhm_hooks.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-nhm-hooks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
jq_true() { jq -e "$1" "$2" >/dev/null; }
# jq_ok [jq options] FILTER FILE: jq_true with options.
jq_ok() { jq -e "$@" >/dev/null; }

# ------------------------------------------------------------
# Claude Code: a settings file with other hooks and settings
# ------------------------------------------------------------
cat >"$WORK/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      {"matcher": "^(startup|resume|clear|compact|fork)$", "hooks": [{"type": "command", "command": "bash /x/herdr-agent-state.sh session", "timeout": 10}]}
    ],
    "Stop": [{"hooks": [{"type": "command", "command": "bash /x/agent_mail_hook.sh stop"}]}]
  }
}
JSON
chmod 0600 "$WORK/settings.json"
bash "$HOOKS" register claude "$WORK/settings.json" 2>/dev/null
check "claude: registered" bash "$HOOKS" registered claude "$WORK/settings.json"
check "claude: PostToolUse runs nhm-hook posttooluse on Agent Mail registration" \
    jq_true '.hooks.PostToolUse[0] | .matcher == "^mcp__.+__(register_agent|create_agent_identity|macro_start_session)$"
        and .hooks[0].command == (env.HOME + "/.local/bin/nhm-hook posttooluse")' "$WORK/settings.json"
check "claude: SessionStart line appended after herdr's, without a matcher" \
    jq_true '(.hooks.SessionStart | length) == 2 and (.hooks.SessionStart[0].hooks[0].command | test("herdr"))
        and (.hooks.SessionStart[1] | has("matcher") | not)
        and .hooks.SessionStart[1].hooks[0].command == (env.HOME + "/.local/bin/nhm-hook sessionstart")' "$WORK/settings.json"
check "claude: other settings and hooks kept" \
    jq_true '.model == "opus" and (.hooks.Stop | length) == 1' "$WORK/settings.json"
check "claude: no PostCompact line" jq_true '.hooks | has("PostCompact") | not' "$WORK/settings.json"
check "claude: the file's mode is kept" test "$(stat -c %a "$WORK/settings.json")" = 600
cp "$WORK/settings.json" "$WORK/settings.once"
bash "$HOOKS" register claude "$WORK/settings.json" 2>/dev/null
check "claude: a second run changes nothing" cmp -s "$WORK/settings.json" "$WORK/settings.once"

# ------------------------------------------------------------
# Codex: entries are appended, never moved
# ------------------------------------------------------------
cat >"$WORK/hooks.json" <<'JSON'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "herdr-codex-hook"}]}],
           "Stop": [{"hooks": [{"type": "command", "command": "bash /x/agent_mail_hook.sh stop"}]}]}}
JSON
bash "$HOOKS" register codex "$WORK/hooks.json" 2>/dev/null
check "codex: registered" bash "$HOOKS" registered codex "$WORK/hooks.json"
check "codex: the existing SessionStart entry stays first" \
    jq_true '.hooks.SessionStart[0].hooks[0].command == "herdr-codex-hook" and (.hooks.SessionStart | length) == 2' "$WORK/hooks.json"
check "codex: PostCompact runs nhm-hook sessionstart" \
    jq_true '.hooks.PostCompact[0].hooks[0].command | endswith("/nhm-hook sessionstart")' "$WORK/hooks.json"
# An older ACFS line (ACFS's own path, an older timeout) in a pure group
# (ACFS's matcher, no other key, only nhm handlers) is rewritten in place
# to the exact line, so trust (position-keyed) and the doctor see what
# register wrote. acfs-9hkh.53: ACFS never edits a group that holds a
# handler of the user's, and an nhm-hook path ACFS never wrote is the
# user's.
jq -n --arg c "$HOME/.local/bin/nhm-hook sessionstart" \
    '{hooks: {SessionStart: [{hooks: [{type: "command", command: "herdr-x"}]}, {hooks: [{type: "command", command: $c, timeout: 10}]}]}}' >"$WORK/old.json"
check "registered: a line that is missing (no PostToolUse) is exit 1, not an upgrade" \
    bash -c 'bash "$1" registered claude "$2"; test $? -eq 1' _ "$HOOKS" "$WORK/old.json"
bash "$HOOKS" register claude "$WORK/old.json" 2>/dev/null
check "an older ACFS line in a pure group is rewritten in place" \
    jq_true '(.hooks.SessionStart | length) == 2 and .hooks.SessionStart[0].hooks[0].command == "herdr-x"
        and .hooks.SessionStart[1] == {hooks: [{type: "command", command: (env.HOME + "/.local/bin/nhm-hook sessionstart"), timeout: 5}]}' "$WORK/old.json"
jq -n --arg c "$HOME/.local/bin/nhm-hook sessionstart" \
    '{hooks: {SessionStart: [{hooks: [{type: "command", command: "user-a"}, {type: "command", command: $c, timeout: 10}]}]}}' >"$WORK/old2.json"
cp "$WORK/old2.json" "$WORK/old2.orig"
bash "$HOOKS" register claude "$WORK/old2.json" 2>/dev/null
check "an ACFS handler beside the user's handler stays untouched, and the exact line is appended" \
    jq_ok --slurpfile o "$WORK/old2.orig" '(.hooks.SessionStart | length) == 2 and .hooks.SessionStart[0] == $o[0].hooks.SessionStart[0]
        and .hooks.SessionStart[1] == {hooks: [{type: "command", command: (env.HOME + "/.local/bin/nhm-hook sessionstart"), timeout: 5}]}' "$WORK/old2.json"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/x/nhm-hook sessionstart"}]}]}}' >"$WORK/userpath.json"
bash "$HOOKS" register claude "$WORK/userpath.json" 2>/dev/null
check "an nhm-hook at a path the user chose is the user's: kept as written, the exact line appended" \
    jq_true '(.hooks.SessionStart | length) == 2 and .hooks.SessionStart[0].hooks[0] == {type: "command", command: "/opt/x/nhm-hook sessionstart"}' "$WORK/userpath.json"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"user-a"},{"type":"command","command":"/old/nhm-hook sessionstart"}]}]}}' >"$WORK/old3.json"
bash "$HOOKS" register claude "$WORK/old3.json" 2>/dev/null
check "an older nhm line that shares another matcher's group stays, and the exact line is appended" \
    jq_true '(.hooks.SessionStart | length) == 2 and (.hooks.SessionStart[0].hooks | length) == 2
        and .hooks.SessionStart[1].hooks[0].command == (env.HOME + "/.local/bin/nhm-hook sessionstart")' "$WORK/old3.json"
check "registered: every line exact after the upgrade" bash "$HOOKS" registered claude "$WORK/old.json"
# acfs-9hkh.45: a user's command that only contains nhm-hook is not an nhm
# line; ACFS's own line is still added, and registered sees it.
for user_cmd in 'myscript; nhm-hook sessionstart' 'cmd # nhm-hook sessionstart' 'nhm-hook sessionstart --extra' 'echo $(nhm-hook sessionstart)'; do
    jq -n --arg c "$user_cmd" '{hooks: {SessionStart: [{hooks: [{type: "command", command: $c}]}]}}' >"$WORK/user.json"
    bash "$HOOKS" register claude "$WORK/user.json" 2>/dev/null
    check "a user line '$user_cmd' does not stop ACFS's SessionStart line" \
        jq_true '(.hooks.SessionStart | length) == 2 and .hooks.SessionStart[1].hooks[0].command == (env.HOME + "/.local/bin/nhm-hook sessionstart")' "$WORK/user.json"
done
bash "$HOOKS" register codex 2>/dev/null
check "codex: default file ~/.codex/hooks.json" bash "$HOOKS" registered codex "$HOME/.codex/hooks.json"
check "codex: a new file is 0600" test "$(stat -c %a "$HOME/.codex/hooks.json")" = 600
check "registered checks the lines of the kind asked: a Codex file has every Claude line" \
    bash "$HOOKS" registered claude "$HOME/.codex/hooks.json"
check "codex: a Claude file lacks PostCompact" bash -c '! bash "$1" registered codex "$2"' _ "$HOOKS" "$WORK/settings.json"

# ------------------------------------------------------------
# Symlinks and files it cannot extend
# ------------------------------------------------------------
mkdir -p "$WORK/dotfiles"
printf '{}\n' >"$WORK/dotfiles/settings.json"
ln -s "$WORK/dotfiles/settings.json" "$WORK/linked.json"
bash "$HOOKS" register claude "$WORK/linked.json" 2>/dev/null
check "a symlinked file stays a symlink" test -L "$WORK/linked.json"
check "the symlink's target gets the lines" bash "$HOOKS" registered claude "$WORK/dotfiles/settings.json"

printf '{"hooks": []}\n' >"$WORK/bad.json"
cp "$WORK/bad.json" "$WORK/bad.orig"
check "refuses a file whose hooks isn't an object" bash -c '! bash "$1" register claude "$2" 2>/dev/null' _ "$HOOKS" "$WORK/bad.json"
check "the refused file is unchanged" cmp -s "$WORK/bad.json" "$WORK/bad.orig"
printf '{"hooks": {"SessionStart": {}}}\n' >"$WORK/bad2.json"
check "refuses an event that isn't an array" bash -c '! bash "$1" register claude "$2" 2>/dev/null' _ "$HOOKS" "$WORK/bad2.json"
printf '{not json\n' >"$WORK/broken.json"
check "refuses malformed JSON" bash -c '! bash "$1" register claude "$2" 2>/dev/null' _ "$HOOKS" "$WORK/broken.json"
check "refuses an unsafe bin dir" bash -c '! NHM_BIN_DIR="/tmp/a b" bash "$1" register claude "$2/unsafe.json" 2>/dev/null && test ! -e "$2/unsafe.json"' _ "$HOOKS" "$WORK"
check "unknown kind: usage error" bash -c 'bash "$1" register gemini 2>/dev/null; test $? -eq 2' _ "$HOOKS"

# ------------------------------------------------------------
# trust codex: Codex's trust for ACFS's own entries, through a fake
# `codex app-server` (tests/unit/fake_codex_app_server.py)
# ------------------------------------------------------------
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$ROOT/tests/unit/fake_codex_app_server.py" >"$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"
CODEX_DIR="$WORK/codexhome"
mkdir -p "$CODEX_DIR"
# A user hook ACFS does not own comes first; ACFS must not trust it.
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other","timeout":5}]}]}}' >"$CODEX_DIR/hooks.json"
bash "$HOOKS" register codex "$CODEX_DIR/hooks.json" 2>/dev/null
trust() { PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$CODEX_DIR/hooks.json" "$@"; }
batch_writes() { grep -c '"config/batchWrite"' "$CODEX_DIR/fake-requests.jsonl" 2>/dev/null || true; }

OUT="$(trust --dry-run 2>&1)"
check "trust --dry-run names the three nhm entries" bash -c '[[ $(grep -c "would trust" <<<"$1") -eq 3 ]]' _ "$OUT"
check "trust --dry-run writes nothing" test "$(batch_writes)" = 0
OUT="$(trust 2>&1)"
check "trust: Codex trusts the nhm entries" bash -c '[[ "$1" == *"trusts the 3 ACFS entries"*"(3 newly)"* ]]' _ "$OUT"
check "trust: one batchWrite of hooks.state" test "$(batch_writes)" = 1
check "trust: only nhm-hook entries were trusted, never the user's own" \
    jq_true '(keys | length) == 3 and all(keys[]; test(":(post_tool_use|session_start|post_compact):0:0$"))' "$CODEX_DIR/fake-trust.json"
OUT="$(trust 2>&1)"
check "trust again: nothing to write" bash -c '[[ "$1" != *newly* && $2 -eq 1 ]]' _ "$OUT" "$(batch_writes)"
check "trust: the app-server runs with CODEX_HOME at the file's directory" \
    grep -q '"cwds": \["'"$CODEX_DIR"'"\]' "$CODEX_DIR/fake-requests.jsonl"
check "trust: a write Codex does not keep fails" bash -c 'rm -f "$1/fake-trust.json"; ! FAKE_CODEX_DROP_WRITE=1 PATH="$2:$PATH" bash "$3" trust codex "$1/hooks.json" 2>/dev/null' \
    _ "$CODEX_DIR" "$FAKEBIN" "$HOOKS"
check "trust: an app-server that dies fails" bash -c '! FAKE_CODEX_FAIL=1 PATH="$2:$PATH" bash "$3" trust codex "$1/hooks.json" 2>/dev/null' \
    _ "$CODEX_DIR" "$FAKEBIN" "$HOOKS"
check "trust: no codex fails" bash -c '! PATH="/usr/bin:/bin" bash "$2" trust codex "$1/hooks.json" 2>/dev/null' _ "$CODEX_DIR" "$HOOKS"
# acfs-9hkh.60: a hooks file the driver cannot read fails with a note,
# never a Python traceback; a non-object "hooks" holds no ACFS entries.
for bad in '{not json' '[1, 2]'; do
    printf '%s\n' "$bad" >"$WORK/trust-bad.json"
    OUT="$(PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$WORK/trust-bad.json" --dry-run 2>&1)" && rc=0 || rc=$?
    check "trust: '$bad' fails with a note, no traceback" \
        bash -c '[[ $2 -eq 1 && "$1" == *"nhm_hooks: "* && "$1" != *Traceback* ]]' _ "$OUT" "$rc"
done
printf '{"hooks": []}\n' >"$WORK/trust-bad.json"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$WORK/trust-bad.json" --dry-run 2>&1)" && rc=0 || rc=$?
check "trust: a non-object hooks has no ACFS entries" \
    bash -c '[[ $2 -eq 0 && "$1" == *"has no nhm-hook entries"* && "$1" != *Traceback* ]]' _ "$OUT" "$rc"
# Review of 77cfc7c2/be761fae: older ACFS lines are not ACFS's exact lines,
# so trust finds none; register rewrites the pure groups in place, and
# trust then trusts those same positions. acfs-9hkh.53: PostToolUse's
# first group has the user's matcher "x", so it is the user's: it stays
# as it is, the exact line is appended, and `stray` names it.
OLDC="$WORK/codexold"
mkdir -p "$OLDC"
jq -n --arg p "$HOME/.local/bin/nhm-hook posttooluse" --arg s "$HOME/.local/bin/nhm-hook sessionstart" \
    --arg m '^mcp__.+__(register_agent|create_agent_identity|macro_start_session)$' \
    '{hooks: {Stop: [{hooks: [{type: "command", command: "echo user"}]}],
              PostToolUse: [{matcher: "x", hooks: [{type: "command", command: $p}]}, {matcher: $m, hooks: [{type: "command", command: $p, timeout: 10}]}],
              SessionStart: [{hooks: [{type: "command", command: $s, timeout: 10}]}],
              PostCompact: [{hooks: [{type: "command", command: $s}]}]}}' >"$OLDC/hooks.json"
cp "$OLDC/hooks.json" "$OLDC/hooks.orig"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$OLDC/hooks.json" --dry-run 2>&1)"
check "older lines: trust finds no line ACFS wrote" bash -c '[[ "$1" == *"has no nhm-hook entries"* ]]' _ "$OUT"
check "older lines: registered says upgrade needed" bash -c 'bash "$1" registered codex "$2"; test $? -eq 3' _ "$HOOKS" "$OLDC/hooks.json"
bash "$HOOKS" register codex "$OLDC/hooks.json" 2>/dev/null
check "older lines: register rewrites the pure groups in place; the user's groups stay as they were" \
    jq_ok --slurpfile o "$OLDC/hooks.orig" '(.hooks.PostToolUse | length) == 2 and (.hooks.SessionStart | length) == 1 and (.hooks.PostCompact | length) == 1
        and .hooks.Stop == $o[0].hooks.Stop and .hooks.PostToolUse[0] == $o[0].hooks.PostToolUse[0]
        and .hooks.PostToolUse[1].hooks == [{type: "command", command: (env.HOME + "/.local/bin/nhm-hook posttooluse"), timeout: 5}]
        and .hooks.SessionStart[0] == {hooks: [{type: "command", command: (env.HOME + "/.local/bin/nhm-hook sessionstart"), timeout: 5}]}' "$OLDC/hooks.json"
check "stray: names ACFS's handler inside the user's group" \
    bash -c '[[ "$(bash "$1" stray codex "$2")" == "PostToolUse 0 0 user-group twice" ]]' _ "$HOOKS" "$OLDC/hooks.json"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$OLDC/hooks.json" 2>&1)"
check "older lines: after register, trust trusts the 3 rewritten positions, never the user's group" \
    bash -c '[[ "$1" == *"trusts the 3 ACFS entries"* ]] && jq -e "(keys | length) == 3 and all(keys[]; test(\":(post_tool_use:1|session_start:0|post_compact:0):0$\"))" "$2/fake-trust.json" >/dev/null' \
    _ "$OUT" "$OLDC"
# Review of b89811bd: ACFS trusts only what it wrote, the verify step needs
# every entry, and a stuck app-server behind a wrapper cannot hang it.
TRUST2="$WORK/codex2"
mkdir -p "$TRUST2"
bash "$HOOKS" register codex "$TRUST2/hooks.json" 2>/dev/null
# The user's own line that mentions nhm-hook, and an nhm entry the user edited.
jq --arg cmd "myscript; $HOME/.local/bin/nhm-hook sessionstart" \
    '.hooks.SessionStart += [{hooks: [{type: "command", command: $cmd, timeout: 5}]}]
     | .hooks.PostCompact[0].hooks[0].timeout = 9' "$TRUST2/hooks.json" >"$TRUST2/hooks.tmp"
mv "$TRUST2/hooks.tmp" "$TRUST2/hooks.json"
PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$TRUST2/hooks.json" 2>/dev/null
check "trust: a user line that mentions nhm-hook stays untrusted" \
    jq_true 'keys | all(test(":session_start:1:0$") | not)' "$TRUST2/fake-trust.json"
check "trust: an nhm entry the user edited stays untrusted" \
    jq_true '(keys | length) == 2 and all(keys[]; test(":(post_tool_use|session_start):0:0$"))' "$TRUST2/fake-trust.json"
check "trust: a second list that drops entries fails" bash -c 'rm -f "$1/fake-trust.json"; ! FAKE_CODEX_HIDE_AFTER_WRITE=1 PATH="$2:$PATH" bash "$3" trust codex "$1/hooks.json" 2>/dev/null' \
    _ "$CODEX_DIR" "$FAKEBIN" "$HOOKS"
# A wrapper whose child holds stdout open and never answers: only killing
# the process group ends it. The stuck app-server runs from a copy of the
# fake under this run's $WORK, so the checks see only this run's
# processes, never another test run's on the same host (acfs-9hkh.60: a
# host-wide pgrep made this check flaky).
HANGBIN="$WORK/hangbin"
mkdir -p "$HANGBIN"
cp "$ROOT/tests/unit/fake_codex_app_server.py" "$HANGBIN/fake_codex_app_server.py"
printf '#!/bin/sh\nFAKE_CODEX_HANG=1 python3 "%s" "$@" &\nwait\n' "$HANGBIN/fake_codex_app_server.py" >"$HANGBIN/codex"
chmod +x "$HANGBIN/codex"
# hang_gone: no process of this run's stuck app-server, waiting up to 5 s
# for a killed one to be reaped.
hang_gone() {
    local _
    for _ in $(seq 1 50); do
        pgrep -f "$HANGBIN/fake_codex_app_server.py app-server" >/dev/null || return 0
        sleep 0.1
    done
    return 1
}
check "trust: a stuck app-server behind a wrapper ends at the timeout" bash -c '
    start=$SECONDS
    NHM_HOOKS_TRUST_TIMEOUT=2 PATH="$2:$PATH" timeout 30 bash "$3" trust codex "$1/hooks.json" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 && $rc -ne 124 && $((SECONDS - start)) -lt 20 ]]' _ "$CODEX_DIR" "$HANGBIN" "$HOOKS"
check "trust: no process of the stuck app-server is left" hang_gone

# acfs-9hkh.46: install's and update's `timeout 90` sends SIGTERM to its
# process group; the app-server runs in a session of its own, so the
# driver must kill it on the way out, not leave it behind.
rc=0
NHM_HOOKS_TRUST_TIMEOUT=60 PATH="$HANGBIN:$PATH" timeout 2 bash "$HOOKS" trust codex "$CODEX_DIR/hooks.json" 2>/dev/null || rc=$?
check "trust: SIGTERM from timeout ends the run (124)" test "$rc" -eq 124
check "trust: SIGTERM from timeout leaves no app-server behind" hang_gone

printf '%s\n' '{"hooks":{}}' >"$WORK/empty-hooks.json"
check "trust: a file without nhm entries has nothing to do" \
    bash -c 'PATH="$1:$PATH" bash "$2" trust codex "$3" 2>/dev/null' _ "$FAKEBIN" "$HOOKS" "$WORK/empty-hooks.json"
check "trust: a missing file fails" bash -c '! bash "$1" trust codex "$2/nope.json" 2>/dev/null' _ "$HOOKS" "$WORK"
check "trust claude: usage error" bash -c 'bash "$1" trust claude 2>/dev/null; test $? -eq 2' _ "$HOOKS"

# ------------------------------------------------------------
# unregister (acfs-9hkh.46): when nhm-hook is gone, ACFS removes its own
# exact lines and nothing else
# ------------------------------------------------------------
UNREG="$WORK/unreg"
mkdir -p "$UNREG"
cp "$WORK/settings.once" "$UNREG/settings.json"
# The user's own line that mentions nhm-hook, and an older nhm command.
jq --arg cmd "myscript; $HOME/.local/bin/nhm-hook sessionstart" \
    '.hooks.SessionStart += [{hooks: [{type: "command", command: $cmd}]}, {hooks: [{type: "command", command: "/old/nhm-hook sessionstart"}]}]' \
    "$UNREG/settings.json" >"$UNREG/settings.tmp"
mv "$UNREG/settings.tmp" "$UNREG/settings.json"
chmod 0600 "$UNREG/settings.json"
bash "$HOOKS" unregister claude "$UNREG/settings.json" 2>/dev/null
check "unregister claude: no ACFS command is left" \
    jq_true '[.. | objects | .command? // empty | select(. == (env.HOME + "/.local/bin/nhm-hook posttooluse") or . == (env.HOME + "/.local/bin/nhm-hook sessionstart"))] | length == 0' "$UNREG/settings.json"
check "unregister claude: an empty PostToolUse is removed" jq_true '.hooks | has("PostToolUse") | not' "$UNREG/settings.json"
check "unregister claude: herdr's, the user's and the older nhm line stay, in order" \
    jq_true '[.hooks.SessionStart[].hooks[0].command] == ["bash /x/herdr-agent-state.sh session", (env.HOME + "/.local/bin/nhm-hook sessionstart" | "myscript; " + .), "/old/nhm-hook sessionstart"]' "$UNREG/settings.json"
check "unregister claude: other settings stay" jq_true '.model == "opus" and (.hooks.Stop | length) == 1' "$UNREG/settings.json"
check "unregister claude: the file's mode is kept" test "$(stat -c %a "$UNREG/settings.json")" = 600
cp "$UNREG/settings.json" "$UNREG/settings.once"
bash "$HOOKS" unregister claude "$UNREG/settings.json" 2>/dev/null
check "unregister claude: a second run changes nothing" cmp -s "$UNREG/settings.json" "$UNREG/settings.once"

# Codex keys trust by position: only entries that nothing follows go.
bash "$HOOKS" register codex "$UNREG/hooks.json" 2>/dev/null
jq '.hooks.SessionStart += [{hooks: [{type: "command", command: "user-after"}]}]' "$UNREG/hooks.json" >"$UNREG/hooks.tmp"
mv "$UNREG/hooks.tmp" "$UNREG/hooks.json"
OUT="$(bash "$HOOKS" unregister codex "$UNREG/hooks.json" 2>&1)"
check "unregister codex: trailing ACFS entries are removed" \
    jq_true '(.hooks | has("PostToolUse") | not) and (.hooks | has("PostCompact") | not)' "$UNREG/hooks.json"
check "unregister codex: an ACFS entry another entry follows stays, so no trust key moves" \
    jq_true '[.hooks.SessionStart[].hooks[0].command] == [(env.HOME + "/.local/bin/nhm-hook sessionstart"), "user-after"]' "$UNREG/hooks.json"
check "unregister codex: it says which lines it left" bash -c '[[ "$1" == *"left 1 nhm hook lines"* ]]' _ "$OUT"
check "unregister: a missing file is fine and stays missing" \
    bash -c 'bash "$1" unregister codex "$2/none.json" 2>/dev/null && test ! -e "$2/none.json"' _ "$HOOKS" "$UNREG"
printf '{not json\n' >"$UNREG/broken.json"
check "unregister: malformed JSON fails and stays unchanged" \
    bash -c '! bash "$1" unregister claude "$2" 2>/dev/null && [[ "$(cat "$2")" == "{not json" ]]' _ "$HOOKS" "$UNREG/broken.json"
check "unregister: unknown kind is a usage error" bash -c 'bash "$1" unregister gemini 2>/dev/null; test $? -eq 2' _ "$HOOKS"

# acfs-9hkh.53: ACFS never edits a group that holds anything of the
# user's (another matcher, other keys, other handlers). ACFS's handler
# alone in a group with the user's matcher and key stays as it is; the
# exact line is appended; unregister removes only the exact line and
# reports the stray.
SESSION_CMD="$HOME/.local/bin/nhm-hook sessionstart"
jq -n --arg c "$SESSION_CMD" '{hooks: {SessionStart: [{matcher: "startup", note: "mine", hooks: [{type: "command", command: $c}]}]}}' >"$UNREG/lone.json"
cp "$UNREG/lone.json" "$UNREG/lone.orig"
bash "$HOOKS" register claude "$UNREG/lone.json" 2>/dev/null
check "register: ACFS's handler in the user's group stays as it is; the exact line is appended" \
    jq_ok --slurpfile o "$UNREG/lone.orig" '.hooks.SessionStart[0] == $o[0].hooks.SessionStart[0] and (.hooks.SessionStart | length) == 2
        and .hooks.SessionStart[1] == {hooks: [{type: "command", command: (env.HOME + "/.local/bin/nhm-hook sessionstart"), timeout: 5}]}' "$UNREG/lone.json"
check "registered: every line exact" bash "$HOOKS" registered claude "$UNREG/lone.json"
check "stray: names the handler in the user's group" \
    bash -c '[[ "$(bash "$1" stray claude "$2")" == "SessionStart 0 0 user-group twice" ]]' _ "$HOOKS" "$UNREG/lone.json"
check "stray: before register, the handler in the user's group runs once" \
    bash -c '[[ "$(bash "$1" stray claude "$2")" == "SessionStart 0 0 user-group once" ]]' _ "$HOOKS" "$UNREG/lone.orig"
cp "$UNREG/lone.json" "$UNREG/lone.once"
bash "$HOOKS" register claude "$UNREG/lone.json" 2>/dev/null
check "register: a second run changes nothing" cmp -s "$UNREG/lone.json" "$UNREG/lone.once"
OUT="$(bash "$HOOKS" unregister claude "$UNREG/lone.json" 2>&1)"
check "unregister claude: the exact line goes; the user's group stays as it was" \
    cmp -s <(jq -S . "$UNREG/lone.json") <(jq -S . "$UNREG/lone.orig")
check "unregister claude: it says what it removed and names the stray it left" \
    bash -c '[[ "$1" == *"removed the nhm hook lines"* && "$1" == *"left 1 nhm-hook handler(s) inside your own hook groups"* ]]' _ "$OUT"
# acfs-9hkh.60: a second exact group (a hand edit) runs the hook twice;
# stray names it, and Claude's unregister removes both.
jq '.hooks.SessionStart += [.hooks.SessionStart[1]]' "$UNREG/lone.once" >"$UNREG/dup.tmp"
mv "$UNREG/dup.tmp" "$UNREG/dup.json"
check "stray: a second exact line is a duplicate" \
    bash -c '[[ "$(bash "$1" stray claude "$2")" == *"SessionStart 2 0 duplicate twice"* ]]' _ "$HOOKS" "$UNREG/dup.json"
bash "$HOOKS" unregister claude "$UNREG/dup.json" 2>/dev/null
check "unregister claude: both exact lines go" \
    jq_true '[.hooks.SessionStart[] | select(.matcher != "startup")] | length == 0' "$UNREG/dup.json"
# A group with the user's handler beside ACFS's: never edited.
jq -n --arg c "$SESSION_CMD" '{hooks: {SessionStart: [{hooks: [{type: "command", command: "user-a"}, {type: "command", command: $c, timeout: 5}]}]}}' >"$UNREG/shared.json"
cp "$UNREG/shared.json" "$UNREG/shared.orig"
bash "$HOOKS" unregister claude "$UNREG/shared.json" 2>/dev/null
check "unregister claude: a group with the user's handler stays whole" cmp -s "$UNREG/shared.json" "$UNREG/shared.orig"
# SageOak's probe (review of 1946e6d0): register then unregister leaves
# the user's group exactly as it was, for Claude and Codex.
for kind in claude codex; do
    printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup","x":1,"hooks":[{"command":"nhm-hook sessionstart"}]}]}}' >"$UNREG/probe-$kind.json"
    cp "$UNREG/probe-$kind.json" "$UNREG/probe-$kind.orig"
    bash "$HOOKS" register "$kind" "$UNREG/probe-$kind.json" 2>/dev/null
    check "probe ($kind): register keeps the user's group as it was" \
        jq_ok --slurpfile o "$UNREG/probe-$kind.orig" '.hooks.SessionStart[0] == $o[0].hooks.SessionStart[0]' "$UNREG/probe-$kind.json"
    bash "$HOOKS" unregister "$kind" "$UNREG/probe-$kind.json" 2>/dev/null
    check "probe ($kind): register then unregister gives the file back" \
        cmp -s <(jq -S . "$UNREG/probe-$kind.json") <(jq -S . "$UNREG/probe-$kind.orig")
done
# Codex: a pure ACFS group another entry follows stays, and is reported.
jq -n --arg c "$SESSION_CMD" '{hooks: {SessionStart: [{hooks: [{type: "command", command: $c, timeout: 5}]}, {hooks: [{type: "command", command: "user-after"}]}]}}' >"$UNREG/codex-user.json"
cp "$UNREG/codex-user.json" "$UNREG/codex-user.orig"
OUT="$(bash "$HOOKS" unregister codex "$UNREG/codex-user.json" 2>&1)"
check "unregister codex: ACFS's line another entry follows stays, the file unchanged" cmp -s "$UNREG/codex-user.json" "$UNREG/codex-user.orig"
check "unregister codex: it reports the line it left, not a removal" \
    bash -c '[[ "$1" == *"left 1 nhm hook lines"* && "$1" != *"removed"* ]]' _ "$OUT"

# ------------------------------------------------------------
# codex-dcg: dcg's Bash guard in Codex's hooks.json (acfs-9hkh.81),
# byte for byte as dcg's own installer writes it
# ------------------------------------------------------------
DCGD="$WORK/codex-dcg"
mkdir -p "$DCGD" "$HOME/.local/bin"
DCG="$HOME/.local/bin/dcg"
DCG_ENTRY="$(jq -cn --arg c "$DCG" '{matcher: "Bash", hooks: [{type: "command", command: $c}]}')"
dcg_count() { jq '[.hooks.PreToolUse[]? | .hooks[]? | select(.command | test("/dcg$"))] | length' "$1"; }

check "codex-dcg register: no dcg installed refuses, and writes nothing" \
    bash -c '! bash "$1" codex-dcg register "$2/none.json" 2>/dev/null && [[ ! -e "$2/none.json" ]]' _ "$HOOKS" "$DCGD"
printf '#!/bin/sh\nexit 0\n' >"$DCG"
chmod +x "$DCG"

printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"user-edit"}]}]}}' >"$DCGD/plain.json"
bash "$HOOKS" codex-dcg register "$DCGD/plain.json" 2>/dev/null
check "codex-dcg register: dcg's exact line is appended after the user's group" \
    jq_ok --argjson e "$DCG_ENTRY" '.hooks.PreToolUse == [{"matcher":"Edit","hooks":[{"type":"command","command":"user-edit"}]}, $e]' "$DCGD/plain.json"
check "codex-dcg registered: 0 for the line register wrote" bash "$HOOKS" codex-dcg registered "$DCGD/plain.json"
cp "$DCGD/plain.json" "$DCGD/plain.before"
bash "$HOOKS" codex-dcg register "$DCGD/plain.json" 2>/dev/null
check "codex-dcg register again: nothing changes" cmp -s "$DCGD/plain.json" "$DCGD/plain.before"

# dcg's installer puts dcg first in the user's Bash group: that counts,
# and ACFS adds no second copy.
jq -n --arg c "$DCG" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}, {type: "command", command: "user-bash"}]}]}}' >"$DCGD/dcgfirst.json"
cp "$DCGD/dcgfirst.json" "$DCGD/dcgfirst.before"
check "codex-dcg registered: 0 for dcg's installer form inside the user's Bash group" \
    bash "$HOOKS" codex-dcg registered "$DCGD/dcgfirst.json"
bash "$HOOKS" codex-dcg register "$DCGD/dcgfirst.json" 2>/dev/null
check "codex-dcg register: dcg's installer form stays as it is" cmp -s "$DCGD/dcgfirst.json" "$DCGD/dcgfirst.before"

# A dcg at another path is the user's: registered says 3, register adds none.
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/tools/dcg"}]}]}}' >"$DCGD/other.json"
cp "$DCGD/other.json" "$DCGD/other.before"
check "codex-dcg registered: 3 when only a dcg at another path guards Bash" \
    bash -c 'bash "$1" codex-dcg registered "$2"; [[ $? -eq 3 ]]' _ "$HOOKS" "$DCGD/other.json"
bash "$HOOKS" codex-dcg register "$DCGD/other.json" 2>/dev/null
check "codex-dcg register: no second dcg next to the user's" bash -c '[[ $(jq "[.hooks.PreToolUse[].hooks[]] | length" "$1") -eq 1 ]] && cmp -s "$1" "$2"' _ "$DCGD/other.json" "$DCGD/other.before"
check "codex-dcg registered: 1 when no dcg guards Bash" \
    bash -c 'printf "{}\n" >"$2/empty.json"; bash "$1" codex-dcg registered "$2/empty.json"; [[ $? -eq 1 ]]' _ "$HOOKS" "$DCGD"
check "codex-dcg registered: a dcg handler in a group that is not Bash's does not count" \
    bash -c 'jq -n --arg c "$3" "{hooks: {PreToolUse: [{matcher: \"Edit\", hooks: [{type: \"command\", command: \$c}]}]}}" >"$2/edit.json"; bash "$1" codex-dcg registered "$2/edit.json"; [[ $? -eq 1 ]]' _ "$HOOKS" "$DCGD" "$DCG"
printf '{not json\n' >"$DCGD/bad.json"
check "codex-dcg register: a file jq cannot read stays unchanged" \
    bash -c '! bash "$1" codex-dcg register "$2/bad.json" 2>/dev/null && [[ "$(cat "$2/bad.json")" == "{not json" ]]' _ "$HOOKS" "$DCGD"

# The review of 59dee517: after register, dcg's installer (rerun by the
# next acfs update) must find the file settled and move nothing. Its own
# check and merge come from tests/unit/dcg_codex_merge.py.
MERGE="$ROOT/tests/unit/dcg_codex_merge.py"
dcg_check() { python3 -I "$MERGE" check "$1" "$DCG"; }
dcg_merge() { python3 -I "$MERGE" merge "$1" "$DCG"; }
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"mcp__x","hooks":[{"type":"command","command":"mcp-hook"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"/u/lint"}]}]}}' >"$DCGD/review.json"
cp "$DCGD/review.json" "$DCGD/review.before"
OUT="$(bash "$HOOKS" codex-dcg register "$DCGD/review.json" 2>&1)"
check "review: next to the user's Bash group, register writes nothing" cmp -s "$DCGD/review.json" "$DCGD/review.before"
check "review: and says dcg's installer places it" bash -c '[[ "$1" == *"left"*"to dcg'"'"'s installer"* ]]' _ "$OUT"
check "review: registered says not settled (1: no dcg yet)" \
    bash -c 'bash "$1" codex-dcg registered "$2"; [[ $? -eq 1 ]]' _ "$HOOKS" "$DCGD/review.json"
dcg_merge "$DCGD/review.json"
check "review: dcg's merge puts dcg first in one Bash group at the top" \
    jq_ok --arg c "$DCG" '.hooks.PreToolUse[0] == {matcher: "Bash", hooks: [{type: "command", command: $c}, {type: "command", command: "/u/lint"}]}' "$DCGD/review.json"
check "review: registered then says settled" bash "$HOOKS" codex-dcg registered "$DCGD/review.json"
cp "$DCGD/review.json" "$DCGD/review.merged"
bash "$HOOKS" codex-dcg register "$DCGD/review.json" 2>/dev/null
dcg_merge "$DCGD/review.json"
check "review: register, then dcg's installer again: nothing moves" cmp -s "$DCGD/review.json" "$DCGD/review.merged"
for layout in plain dcgfirst; do
    cp "$DCGD/$layout.json" "$DCGD/settle-$layout.json"
    bash "$HOOKS" codex-dcg register "$DCGD/settle-$layout.json" 2>/dev/null
    check "review ($layout): dcg's installer finds register's result already there" \
        bash -c '[[ "$(python3 -I "$1" check "$2" "$3")" == already ]]' _ "$MERGE" "$DCGD/settle-$layout.json" "$DCG"
done
printf '{}\n' >"$DCGD/settle-empty.json"
bash "$HOOKS" codex-dcg register "$DCGD/settle-empty.json" 2>/dev/null
check "review (empty): register's line is what dcg's installer calls already there" \
    bash -c '[[ "$(python3 -I "$1" check "$2" "$3")" == already ]]' _ "$MERGE" "$DCGD/settle-empty.json" "$DCG"
# What 59dee517 wrote (dcg appended after the user's Bash group) is not
# settled, so registered says 3 and dcg's installer will merge it.
jq --argjson e "$DCG_ENTRY" '.hooks.PreToolUse += [$e]' "$DCGD/review.before" >"$DCGD/old81.json"
check "review: a line appended after the user's Bash group is not settled (3)" \
    bash -c 'bash "$1" codex-dcg registered "$2"; [[ $? -eq 3 ]] && [[ "$(python3 -I "$3" check "$2" "$4")" == merge ]]' _ "$HOOKS" "$DCGD/old81.json" "$MERGE" "$DCG"
unset -f dcg_check dcg_merge

# trust codex trusts dcg's guard where it stands, never the user's handler
# beside it.
TDCG="$WORK/codex-dcg-trust"
mkdir -p "$TDCG"
cp "$DCGD/dcgfirst.json" "$TDCG/hooks.json"
bash "$HOOKS" register codex "$TDCG/hooks.json" 2>/dev/null
OUT="$(PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$TDCG/hooks.json" --dry-run 2>&1)"
check "trust --dry-run counts the nhm-hook and dcg entries it checked (the doctor reads it)" \
    bash -c '[[ "$1" == *"checked 3 nhm-hook and 1 dcg entries"* ]]' _ "$OUT"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$HOOKS" trust codex "$TDCG/hooks.json" 2>&1)"
check "trust: dcg's guard is trusted with the nhm entries" \
    bash -c '[[ "$1" == *"trusts the 4 ACFS entries"* ]] && jq -e "keys | any(test(\":pre_tool_use:0:0$\"))" "$2/fake-trust.json" >/dev/null' _ "$OUT" "$TDCG"
check "trust: the user's handler in dcg's Bash group stays untrusted" \
    jq_true 'keys | all(test(":pre_tool_use:0:1$") | not)' "$TDCG/fake-trust.json"

# unregister (dcg gone): only a trailing pure group goes.
cp "$DCGD/plain.before" "$DCGD/unreg.json"
bash "$HOOKS" codex-dcg unregister "$DCGD/unreg.json" 2>/dev/null
check "codex-dcg unregister: the trailing line goes, the user's group stays" \
    jq_ok '.hooks.PreToolUse == [{"matcher":"Edit","hooks":[{"type":"command","command":"user-edit"}]}]' "$DCGD/unreg.json"
jq --arg c "$DCG" '.hooks.PreToolUse += [{matcher: "Write", hooks: [{type: "command", command: "user-after"}]}]' "$DCGD/plain.before" >"$DCGD/followed.json"
cp "$DCGD/followed.json" "$DCGD/followed.before"
OUT="$(bash "$HOOKS" codex-dcg unregister "$DCGD/followed.json" 2>&1)"
check "codex-dcg unregister: a line another entry follows stays, and is reported" \
    bash -c 'cmp -s "$1" "$2" && [[ "$3" == *"left dcg'"'"'s Bash guard"* ]]' _ "$DCGD/followed.json" "$DCGD/followed.before" "$OUT"
cp "$DCGD/dcgfirst.before" "$DCGD/shared.json"
bash "$HOOKS" codex-dcg unregister "$DCGD/shared.json" 2>/dev/null
check "codex-dcg unregister: dcg in the user's group is never edited" cmp -s "$DCGD/shared.json" "$DCGD/dcgfirst.before"
check "codex-dcg: one dcg handler in each file, never two" \
    bash -c 'for f in "$@"; do [[ $(jq "[.hooks.PreToolUse[]? | .hooks[]? | select(.command | test(\"/dcg\$\"))] | length" "$f") -le 1 ]] || exit 1; done' _ "$DCGD"/plain.json "$DCGD"/dcgfirst.json "$TDCG/hooks.json"
unset -f dcg_count

# ------------------------------------------------------------
# learning-profile: nhm's [learning] implicit_outcome (acfs-9hkh.88)
# ------------------------------------------------------------
LP="$WORK/learning"
mkdir -p "$LP"
lp() { bash "$HOOKS" learning-profile "$@"; }
toml_value() { python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb")).get("learning", {}).get("implicit_outcome", ""))' "$1"; }

check "learning-profile check: no file is not set (1)" bash -c 'bash "$1" learning-profile check "$2"; [[ $? -eq 1 ]]' _ "$HOOKS" "$LP/none/config.toml"
lp set "$LP/new/config.toml" 2>/dev/null
check "learning-profile set: a new config holds it" test "$(toml_value "$LP/new/config.toml")" = closed-assigned
check "learning-profile check: then 0" lp check "$LP/new/config.toml"

printf '[reap]\nkeep = ["GreenCastle"]\n' >"$LP/other.toml"
lp set "$LP/other.toml" 2>/dev/null
check "learning-profile set: a config without [learning] gets the table, its other settings kept" \
    bash -c '[[ "$(python3 -I -c "import sys, tomllib; d = tomllib.load(open(sys.argv[1], \"rb\")); print(d[\"reap\"][\"keep\"][0], d[\"learning\"][\"implicit_outcome\"])" "$1")" == "GreenCastle closed-assigned" ]]' _ "$LP/other.toml"

printf '# mine\n[learning]  # my table\nmax_items = 3\n\n[reap]\nkeep = []\n' >"$LP/table.toml"
lp set "$LP/table.toml" 2>/dev/null
check "learning-profile set: an existing [learning] table gets the key, nothing else moves" \
    bash -c '[[ "$(sed -n 2,4p "$1")" == "[learning]  # my table"$'"'"'\n'"'"'"implicit_outcome = \"closed-assigned\""*$'"'"'\n'"'"'"max_items = 3" ]] && [[ $(grep -c "^\[learning\]" "$1") -eq 1 ]]' _ "$LP/table.toml"
check "learning-profile set: the result is valid TOML with the value" test "$(toml_value "$LP/table.toml")" = closed-assigned
cp "$LP/table.toml" "$LP/table.before"
lp set "$LP/table.toml" 2>/dev/null
check "learning-profile set again: nothing changes" cmp -s "$LP/table.toml" "$LP/table.before"

printf 'learning.max_items = 3\n\n[reap]\nkeep = []\n' >"$LP/dotted.toml"
lp set "$LP/dotted.toml" 2>/dev/null
check "learning-profile set: dotted learning.* keys get a dotted key, valid TOML" \
    bash -c '[[ "$(python3 -I -c "import sys, tomllib; d = tomllib.load(open(sys.argv[1], \"rb\"))[\"learning\"]; print(d[\"max_items\"], d[\"implicit_outcome\"])" "$1")" == "3 closed-assigned" ]]' _ "$LP/dotted.toml"

printf '[learning]\nimplicit_outcome = "off"\n' >"$LP/off.toml"
cp "$LP/off.toml" "$LP/off.before"
check "learning-profile check: the user's own value is 3" bash -c 'bash "$1" learning-profile check "$2"; [[ $? -eq 3 ]]' _ "$HOOKS" "$LP/off.toml"
lp set "$LP/off.toml" 2>/dev/null
check "learning-profile set: the user's own value stays" cmp -s "$LP/off.toml" "$LP/off.before"

printf '[learning\nbroken = \n' >"$LP/bad.toml"
cp "$LP/bad.toml" "$LP/bad.before"
check "learning-profile set: a file that is not TOML fails and stays as it is" \
    bash -c '! bash "$1" learning-profile set "$2" 2>/dev/null && cmp -s "$2" "$3"' _ "$HOOKS" "$LP/bad.toml" "$LP/bad.before"
check "learning-profile check: and is not set (1)" bash -c 'bash "$1" learning-profile check "$2" 2>/dev/null; [[ $? -eq 1 ]]' _ "$HOOKS" "$LP/bad.toml"
# The review of a21aaef2 (acfs-9hkh.90): line ends, trailing blank lines,
# a header-like line inside a string, and the file's mode stay right.
printf '[reap]\r\nkeep = []\r\n' >"$LP/crlf.toml"
lp set "$LP/crlf.toml" 2>/dev/null
# every line of FILE ends in CR LF
all_crlf() { python3 -I -c 'import sys; b = open(sys.argv[1], "rb").read(); sys.exit(0 if b.count(b"\n") > 2 and b.count(b"\n") == b.count(b"\r\n") else 1)' "$1"; }
check "learning-profile set: a CRLF file stays CRLF throughout" all_crlf "$LP/crlf.toml"
check "learning-profile set: and holds the value" test "$(toml_value "$LP/crlf.toml")" = closed-assigned
printf '[learning]\nmax_items = 3\n\n\n' >"$LP/blank.toml"
lp set "$LP/blank.toml" 2>/dev/null
check "learning-profile set: trailing blank lines stay" \
    python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1], "rb").read().endswith(b"max_items = 3\n\n\n") else 1)' "$LP/blank.toml"
printf 'motd = """\n[learning]\nnot a table\n"""\n\n[learning]\nmax_items = 3\n' >"$LP/string.toml"
lp set "$LP/string.toml" 2>/dev/null
check "learning-profile set: a [learning] line inside a string is skipped for the real table" \
    bash -c '[[ "$(python3 -I -c "import sys, tomllib; d = tomllib.load(open(sys.argv[1], \"rb\")); print(d[\"learning\"][\"implicit_outcome\"], \"implicit\" in d[\"motd\"])" "$1")" == "closed-assigned False" ]]' _ "$LP/string.toml"
printf '[reap]\nkeep = []\n' >"$LP/mode.toml"
chmod 640 "$LP/mode.toml"
lp set "$LP/mode.toml" 2>/dev/null
check "learning-profile set: the file keeps its mode" test "$(stat -c %a "$LP/mode.toml")" = 640
check "learning-profile set: a new file is 0600" test "$(stat -c %a "$LP/new/config.toml")" = 600

check "learning-profile: the default file is XDG_CONFIG_HOME's" \
    bash -c 'XDG_CONFIG_HOME="$2/xdg" bash "$1" learning-profile set 2>/dev/null && [[ -f "$2/xdg/nhm/config.toml" ]]' _ "$HOOKS" "$LP"
unset -f lp toml_value all_crlf

# ------------------------------------------------------------
# capacity-provider: nhm's [providers] capacity (acfs-hd37), the same
# driver as learning-profile
# ------------------------------------------------------------
CP="$WORK/capacity"
mkdir -p "$CP"
cp_() { bash "$HOOKS" capacity-provider "$@"; }
# [providers] capacity of FILE as compact JSON; "none" when unset
cap_value() { python3 -I -c 'import json, sys, tomllib; v = tomllib.load(open(sys.argv[1], "rb")).get("providers", {}).get("capacity"); print("none" if v is None else json.dumps(v, separators=(",", ":")))' "$1"; }
CAP_WANT='["acfs","capacity","--guard","--json","--for-spawn"]'

check "capacity-provider check: no file is not set (1)" bash -c 'bash "$1" capacity-provider check "$2"; [[ $? -eq 1 ]]' _ "$HOOKS" "$CP/none/config.toml"
cp_ set "$CP/new/config.toml" 2>/dev/null
check "capacity-provider set: a new config holds acfs capacity --guard --json --for-spawn" test "$(cap_value "$CP/new/config.toml")" = "$CAP_WANT"
check "capacity-provider check: then 0" cp_ check "$CP/new/config.toml"
check "capacity-provider set: a new file is 0600" test "$(stat -c %a "$CP/new/config.toml")" = 600

printf '[reap]\nkeep = ["GreenCastle"]\n' >"$CP/other.toml"
cp_ set "$CP/other.toml" 2>/dev/null
check "capacity-provider set: a config without [providers] gets the table, its other settings kept" \
    bash -c '[[ "$(python3 -I -c "import sys, tomllib; d = tomllib.load(open(sys.argv[1], \"rb\")); print(d[\"reap\"][\"keep\"][0], \" \".join(d[\"providers\"][\"capacity\"]))" "$1")" == "GreenCastle acfs capacity --guard --json --for-spawn" ]]' _ "$CP/other.toml"

printf '[providers]  # mine\nother = ["x"]\n\n[quota]\nadmit_unknown = ["agy"]\n' >"$CP/table.toml"
cp_ set "$CP/table.toml" 2>/dev/null
check "capacity-provider set: an existing [providers] table gets the key, the user's key stays" \
    bash -c '[[ "$(sed -n 1,3p "$1")" == "[providers]  # mine"$'"'"'\n'"'"'"capacity = [\"acfs\", \"capacity\", \"--guard\", \"--json\", \"--for-spawn\"]"*$'"'"'\n'"'"'"other = [\"x\"]" ]] && [[ $(grep -c "^\[providers\]" "$1") -eq 1 ]]' _ "$CP/table.toml"
check "capacity-provider set: the result is valid TOML with the value" test "$(cap_value "$CP/table.toml")" = "$CAP_WANT"
cp "$CP/table.toml" "$CP/table.before"
cp_ set "$CP/table.toml" 2>/dev/null
check "capacity-provider set again: nothing changes" cmp -s "$CP/table.toml" "$CP/table.before"

# The host-sized argv, from before --for-spawn (acfs-w1f0), is a valid
# provider too, so it counts as the user's choice and set keeps it.
for own in '[]' '["my-guard", "--json"]' '["acfs", "capacity", "--guard", "--json"]'; do
    printf '[providers]\ncapacity = %s\n' "$own" >"$CP/own.toml"
    cp "$CP/own.toml" "$CP/own.before"
    check "capacity-provider check: the user's own value ($own) is 3" bash -c 'bash "$1" capacity-provider check "$2"; [[ $? -eq 3 ]]' _ "$HOOKS" "$CP/own.toml"
    cp_ set "$CP/own.toml" 2>/dev/null
    check "capacity-provider set: the user's own value ($own) stays" cmp -s "$CP/own.toml" "$CP/own.before"
done

printf '[providers\ncapacity = \n' >"$CP/bad.toml"
cp "$CP/bad.toml" "$CP/bad.before"
check "capacity-provider set: a file that is not TOML fails and stays as it is" \
    bash -c '! bash "$1" capacity-provider set "$2" 2>/dev/null && cmp -s "$2" "$3"' _ "$HOOKS" "$CP/bad.toml" "$CP/bad.before"
check "capacity-provider check: and is not set (1)" bash -c 'bash "$1" capacity-provider check "$2" 2>/dev/null; [[ $? -eq 1 ]]' _ "$HOOKS" "$CP/bad.toml"
# An inline table is closed: no edit of it is valid TOML, so nothing is written.
printf 'providers = { other = ["x"] }\n' >"$CP/inline.toml"
cp "$CP/inline.toml" "$CP/inline.before"
check "capacity-provider set: an inline [providers] table fails and stays as it is" \
    bash -c '! bash "$1" capacity-provider set "$2" 2>/dev/null && cmp -s "$2" "$3"' _ "$HOOKS" "$CP/inline.toml" "$CP/inline.before"

printf '[reap]\nkeep = []\n' >"$CP/both.toml"
bash "$HOOKS" learning-profile set "$CP/both.toml" 2>/dev/null
cp_ set "$CP/both.toml" 2>/dev/null
check "capacity-provider and learning-profile: both settings in one valid file" \
    bash -c '[[ "$(python3 -I -c "import sys, tomllib; d = tomllib.load(open(sys.argv[1], \"rb\")); print(d[\"learning\"][\"implicit_outcome\"], d[\"providers\"][\"capacity\"][2], d[\"reap\"][\"keep\"])" "$1")" == "closed-assigned --guard []" ]]' _ "$CP/both.toml"

check "capacity-provider: the default file is XDG_CONFIG_HOME's" \
    bash -c 'XDG_CONFIG_HOME="$2/xdg" bash "$1" capacity-provider set 2>/dev/null && [[ -f "$2/xdg/nhm/config.toml" ]]' _ "$HOOKS" "$CP"
unset -f cp_ cap_value

# ------------------------------------------------------------
# statusline claude (acfs-5917): Claude Code's statusLine runs
# nhm quota record-claude, so nhm knows Claude's windows
# ------------------------------------------------------------
SL="$WORK/statusline"
mkdir -p "$SL"
NHM_LINE="$HOME/.local/bin/nhm quota record-claude"
sl() { bash "$HOOKS" statusline claude "$@"; }
# sl_rc EXPECTED ARGS...: the exit code of statusline claude ARGS is EXPECTED.
sl_rc() { local want="$1" rc=0; shift; sl "$@" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq "$want" ]]; }

printf '{"model": "opus", "hooks": {"Stop": []}}\n' >"$SL/none.json"
chmod 0600 "$SL/none.json"
check "statusline: none set is check 1" sl_rc 1 check "$SL/none.json"
check "statusline: check prints none" test "$(sl check "$SL/none.json" 2>/dev/null)" = none
sl set "$SL/none.json" 2>/dev/null
check "statusline: set writes nhm's command line" \
    jq_ok --arg c "$NHM_LINE" '.statusLine == {type: "command", command: $c}' "$SL/none.json"
check "statusline: other settings kept" jq_true '.model == "opus" and (.hooks.Stop | length) == 0' "$SL/none.json"
check "statusline: the file's mode is kept" test "$(stat -c %a "$SL/none.json")" = 600
check "statusline: check is 0 after set" sl_rc 0 check "$SL/none.json"
cp "$SL/none.json" "$SL/none.once"
sl set "$SL/none.json" 2>/dev/null
check "statusline: a second set changes nothing" cmp -s "$SL/none.json" "$SL/none.once"

printf '{"statusLine": {"type": "command", "command": "bash /home/u/.acfs/scripts/lib/agent_quota.sh record-claude", "padding": 0}}\n' >"$SL/old.json"
check "statusline: ACFS's agent_quota.sh line is acfs-quota, check 1" \
    bash -c '[[ "$(bash "$1" statusline claude check "$2" 2>/dev/null)" == acfs-quota ]]' _ "$HOOKS" "$SL/old.json"
sl set "$SL/old.json" 2>/dev/null
check "statusline: set replaces ACFS's old line and keeps its padding" \
    jq_ok --arg c "$NHM_LINE" '.statusLine == {type: "command", command: $c, padding: 0}' "$SL/old.json"

printf '{"statusLine": {"type": "command", "command": "~/bin/my-status --short"}}\n' >"$SL/user.json"
cp "$SL/user.json" "$SL/user.orig"
check "statusline: the user's own line is check 3" sl_rc 3 check "$SL/user.json"
check "statusline: set leaves the user's own line (exit 3)" sl_rc 3 set "$SL/user.json"
check "statusline: the user's file is unchanged" cmp -s "$SL/user.json" "$SL/user.orig"
check "statusline: remove leaves the user's own line" \
    bash -c 'bash "$1" statusline claude remove "$2" 2>/dev/null && cmp -s "$2" "$3"' _ "$HOOKS" "$SL/user.json" "$SL/user.orig"
printf '{"statusLine": {"type": "static", "text": "x"}}\n' >"$SL/static.json"
check "statusline: a statusLine of another type is the user's" sl_rc 3 check "$SL/static.json"

printf '{"statusLine": {"type": "command", "command": "nhm quota record-claude"}}\n' >"$SL/bare.json"
cp "$SL/bare.json" "$SL/bare.orig"
check "statusline: the bare nhm command counts as nhm's" sl_rc 0 check "$SL/bare.json"
sl set "$SL/bare.json" 2>/dev/null
check "statusline: set keeps the bare nhm command" cmp -s "$SL/bare.json" "$SL/bare.orig"

sl remove "$SL/none.json" 2>/dev/null
check "statusline: remove deletes nhm's line and nothing else" \
    jq_true '(has("statusLine") | not) and .model == "opus"' "$SL/none.json"
printf '{"statusLine": {"type": "command", "command": "bash /home/u/.acfs/scripts/lib/agent_quota.sh record-claude"}}\n' >"$SL/old2.json"
cp "$SL/old2.json" "$SL/old2.orig"
sl remove "$SL/old2.json" 2>/dev/null
check "statusline: remove leaves ACFS's old line (only set replaces it)" cmp -s "$SL/old2.json" "$SL/old2.orig"

check "statusline: a missing file is check 1 (none)" sl_rc 1 check "$SL/new/settings.json"
check "statusline: check does not create the file" test ! -e "$SL/new/settings.json"
sl set "$SL/new/settings.json" 2>/dev/null
check "statusline: set creates a 0600 file" test "$(stat -c %a "$SL/new/settings.json")" = 600
check "statusline: the new file holds nhm's line" \
    jq_ok --arg c "$NHM_LINE" '.statusLine.command == $c' "$SL/new/settings.json"

printf '{"statusLine": ' >"$SL/broken.json"
cp "$SL/broken.json" "$SL/broken.orig"
check "statusline: malformed JSON is check 4" sl_rc 4 check "$SL/broken.json"
check "statusline: set refuses malformed JSON (exit 4)" sl_rc 4 set "$SL/broken.json"
check "statusline: the malformed file is unchanged" cmp -s "$SL/broken.json" "$SL/broken.orig"
printf '[1, 2]\n' >"$SL/array.json"
check "statusline: a JSON array is not a settings object" sl_rc 4 check "$SL/array.json"

mkdir -p "$SL/dotfiles"
printf '{}\n' >"$SL/dotfiles/settings.json"
ln -s "$SL/dotfiles/settings.json" "$SL/linked.json"
sl set "$SL/linked.json" 2>/dev/null
check "statusline: a symlinked file stays a symlink" test -L "$SL/linked.json"
check "statusline: the symlink's target gets nhm's line" sl_rc 0 check "$SL/dotfiles/settings.json"

check "statusline: NHM_BIN_DIR names the nhm in the line" \
    bash -c 'NHM_BIN_DIR=/opt/nhm/bin bash "$1" statusline claude set "$2" 2>/dev/null &&
        jq -e ".statusLine.command == \"/opt/nhm/bin/nhm quota record-claude\"" "$2" >/dev/null' _ "$HOOKS" "$SL/bindir.json"
check "statusline: an unsafe NHM_BIN_DIR is refused and nothing written" \
    bash -c '! NHM_BIN_DIR="/tmp/a b" bash "$1" statusline claude set "$2" 2>/dev/null && test ! -e "$2"' _ "$HOOKS" "$SL/unsafe.json"
check "statusline: an unknown action is a usage error" \
    bash -c 'bash "$1" statusline claude toggle 2>/dev/null; test $? -eq 2' _ "$HOOKS"
check "statusline: another kind is a usage error" \
    bash -c 'bash "$1" statusline codex check 2>/dev/null; test $? -eq 2' _ "$HOOKS"
unset -f sl sl_rc

echo
echo "nhm_hooks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
