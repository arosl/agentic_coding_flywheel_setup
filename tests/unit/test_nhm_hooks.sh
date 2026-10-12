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
check "codex: an older nhm entry is left where it is" bash -c '
    printf "%s\n" "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/old/nhm-hook sessionstart\"}]}]}}" >"$1/old.json"
    bash "$2" register codex "$1/old.json" 2>/dev/null
    jq -e ".hooks.SessionStart | length == 1 and .[0].hooks[0].command == \"/old/nhm-hook sessionstart\"" "$1/old.json" >/dev/null' _ "$WORK" "$HOOKS"
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

printf '%s\n' '{"hooks":{}}' >"$WORK/empty-hooks.json"
check "trust: a file without nhm entries has nothing to do" \
    bash -c 'PATH="$1:$PATH" bash "$2" trust codex "$3" 2>/dev/null' _ "$FAKEBIN" "$HOOKS" "$WORK/empty-hooks.json"
check "trust: a missing file fails" bash -c '! bash "$1" trust codex "$2/nope.json" 2>/dev/null' _ "$HOOKS" "$WORK"
check "trust claude: usage error" bash -c 'bash "$1" trust claude 2>/dev/null; test $? -eq 2' _ "$HOOKS"

echo
echo "nhm_hooks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
