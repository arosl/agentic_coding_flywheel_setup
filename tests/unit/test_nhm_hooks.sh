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
check "trust: Codex trusts the nhm entries" bash -c '[[ "$1" == *"trusts the 3 nhm-hook entries"*"(3 newly)"* ]]' _ "$OUT"
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
    bash -c '[[ "$1" == *"trusts the 3 nhm-hook entries"* ]] && jq -e "(keys | length) == 3 and all(keys[]; test(\":(post_tool_use:1|session_start:0|post_compact:0):0$\"))" "$2/fake-trust.json" >/dev/null' \
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
# the process group ends it.
HANGBIN="$WORK/hangbin"
mkdir -p "$HANGBIN"
printf '#!/bin/sh\nFAKE_CODEX_HANG=1 python3 "%s" "$@" &\nwait\n' "$ROOT/tests/unit/fake_codex_app_server.py" >"$HANGBIN/codex"
chmod +x "$HANGBIN/codex"
check "trust: a stuck app-server behind a wrapper ends at the timeout" bash -c '
    start=$SECONDS
    NHM_HOOKS_TRUST_TIMEOUT=2 PATH="$2:$PATH" timeout 30 bash "$3" trust codex "$1/hooks.json" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 && $rc -ne 124 && $((SECONDS - start)) -lt 20 ]]' _ "$CODEX_DIR" "$HANGBIN" "$HOOKS"
check "trust: no process of the stuck app-server is left" \
    bash -c '! pgrep -f "[f]ake_codex_app_server.py app-server" >/dev/null'

# acfs-9hkh.46: install's and update's `timeout 90` sends SIGTERM to its
# process group; the app-server runs in a session of its own, so the
# driver must kill it on the way out, not leave it behind.
check "trust: SIGTERM from timeout leaves no app-server behind" bash -c '
    NHM_HOOKS_TRUST_TIMEOUT=60 PATH="$2:$PATH" timeout 2 bash "$3" trust codex "$1/hooks.json" 2>/dev/null
    rc=$?
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "[f]ake_codex_app_server.py app-server" >/dev/null || break
        sleep 0.5
    done
    [[ $rc -eq 124 ]] && ! pgrep -f "[f]ake_codex_app_server.py app-server" >/dev/null' _ "$CODEX_DIR" "$HANGBIN" "$HOOKS"

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

echo
echo "nhm_hooks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
