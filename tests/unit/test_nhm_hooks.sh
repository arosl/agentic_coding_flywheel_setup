#!/usr/bin/env bash
# ============================================================
# scripts/lib/nhm_hooks.sh (nhm's hook lines for Claude Code and Codex)
#
# Proves that registering adds every nhm-hook line, is idempotent, keeps
# everything else in the file, never moves an existing entry (Codex keys
# hook trust by position), edits a symlinked file where it points, and
# leaves a file it cannot read unchanged.
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

echo
echo "nhm_hooks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
