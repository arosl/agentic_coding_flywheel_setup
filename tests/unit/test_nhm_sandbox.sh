#!/usr/bin/env bash
# ============================================================
# tests/vm/lib/nhm_sandbox.sh (the nhm rehearsal sandbox, acfs-9hkh.31.1)
#
# Proves that the sandbox root must be under its parent and never in the
# checkout; that inside the sandbox the real HOME (and so the live herdr
# socket) is hidden, / is read-only, only the root is writable, and the
# only network is lo; that the sandbox herdr server runs on its own
# socket and refuses the live one; that the mock API answers; and that
# every process a step starts ends with the step.
#
# Needs bwrap that can make user, net and pid namespaces, and herdr. A
# host without them ends "RESULT: skip (...)" with exit 77, never 0.
#
# Usage: bash tests/unit/test_nhm_sandbox.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/tests/vm/lib/nhm_sandbox.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-nhm-sandbox.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

skip() {
    echo "RESULT: skip ($1)"
    exit 77
}
command -v bwrap >/dev/null 2>&1 || skip "bwrap is not installed"
bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent true 2>/dev/null ||
    skip "bwrap cannot make user, net and pid namespaces here"
HERDR="$(command -v herdr || true)"
[[ -n "$HERDR" ]] || skip "herdr is not installed"
HERDR="$(realpath -e "$HERDR")"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# A stand-in for the live server's socket, in the HOME the sandbox hides.
export HOME="$WORK/home"
mkdir -p "$HOME/.config/herdr"
: >"$HOME/.config/herdr/herdr.sock"
unset HERDR_SOCKET_PATH XDG_CONFIG_HOME
export NHM_SANDBOX_PARENT="$WORK"

# shellcheck source=tests/vm/lib/nhm_sandbox.sh
source "$LIB"

echo "the sandbox root"
check "a root outside NHM_SANDBOX_PARENT is refused" bash -c 'source "$1"; ! sandbox_init /var/tmp/acfs-nhm-not-here 2>/dev/null' _ "$LIB"
check "a root in the checkout is refused, and nothing is created there" \
    bash -c 'source "$1"; NHM_SANDBOX_PARENT="$2"; ! sandbox_init "$2/.acfs-sandbox-test" 2>/dev/null && [[ ! -e "$2/.acfs-sandbox-test" ]]' _ "$LIB" "$ROOT"
check "the parent itself is not a root" bash -c 'source "$1"; ! sandbox_init "$2" 2>/dev/null' _ "$LIB" "$WORK"
sandbox_init "$WORK/sb"
check "a root under the parent is made" test -d "$SANDBOX_HOME/.config" -a -d "$SANDBOX_EVIDENCE"
sandbox_bin herdr "$HERDR"

echo "inside the sandbox"
cat >"$WORK/sb/isolation.sh" <<'STEP'
set -u
out="$SANDBOX_EVIDENCE/isolation.txt"
: >"$out"
[[ -e "$SANDBOX_LIVE_SOCKET" ]] && echo "live-visible" >>"$out" || echo "live-hidden" >>"$out"
touch /usr/acfs-sandbox-probe 2>/dev/null && echo "root-writable" >>"$out" || echo "root-readonly" >>"$out"
touch "$SANDBOX_ROOT/written" && echo "sandbox-writable" >>"$out"
[[ "$HOME" == "$SANDBOX_HOME" ]] && echo "home-sandbox" >>"$out"
ifaces="$(awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }' /proc/net/dev | sort | tr '\n' ' ')"
[[ "$ifaces" == "lo " ]] && echo "net-lo-only" >>"$out" || echo "net: $ifaces" >>"$out"
STEP
sandbox_exec bash "$WORK/sb/isolation.sh"
iso="$(cat "$SANDBOX_EVIDENCE/isolation.txt")"
check "the live herdr socket is hidden" grep -qx live-hidden <<<"$iso"
check "/ is read-only" grep -qx root-readonly <<<"$iso"
check "the sandbox root is writable" grep -qx sandbox-writable <<<"$iso"
check "HOME is the sandbox's" grep -qx home-sandbox <<<"$iso"
check "the only network is lo" grep -qx net-lo-only <<<"$iso"
check "nothing was written outside the root" test ! -e /usr/acfs-sandbox-probe

echo "the sandbox herdr server and the mock API"
cat >"$WORK/sb/server.sh" <<'STEP'
set -u
source "$SANDBOX_LIB"
out="$SANDBOX_EVIDENCE/server.txt"
: >"$out"
# A step that points HERDR_SOCKET_PATH at the live socket is refused.
if ( HERDR_SOCKET_PATH="$SANDBOX_LIVE_SOCKET" sandbox_herdr_start 2>/dev/null ); then
    echo "live-accepted" >>"$out"
else
    echo "live-refused" >>"$out"
fi
sandbox_herdr_start && echo "herdr-up" >>"$out"
herdr workspace list | grep -q '"workspace_list"' && echo "herdr-answers" >>"$out"
[[ -S "$SANDBOX_HOME/.config/herdr/herdr.sock" ]] && echo "own-socket" >>"$out"
sandbox_mock_start && echo "mock-up" >>"$out"
python3 -I -c 'import json,sys,urllib.request
req = urllib.request.Request(sys.argv[1] + "/v1/messages", data=json.dumps({"model": "m", "messages": [{"role": "user", "content": "hi"}]}).encode(), headers={"content-type": "application/json"})
print(json.load(urllib.request.urlopen(req, timeout=5))["content"][0]["text"])' "$ANTHROPIC_BASE_URL" | grep -q '^mock reply' && echo "mock-answers" >>"$out"
mkdir -p "$SANDBOX_ROOT/work"
sandbox_codex_prepare "$SANDBOX_ROOT/work" &&
    grep -qx "base_url = \"$SANDBOX_MOCK_URL/v1\"" "$CODEX_HOME/config.toml" && echo "codex-mock" >>"$out"
sandbox_claude_prepare "$SANDBOX_ROOT/work" &&
    jq -e '.hasCompletedOnboarding and (.projects | length == 1)' "$CLAUDE_CONFIG_DIR/.claude.json" >/dev/null &&
    echo "claude-ready" >>"$out"
# Left running on purpose, with the root in its command line, as the mock
# has: the pid namespace must end them with the step.
bash -c 'sleep 300' "left-running-$SANDBOX_ROOT" &
STEP
sandbox_exec bash "$WORK/sb/server.sh"
srv="$(cat "$SANDBOX_EVIDENCE/server.txt")"
check "a step aimed at the live socket is refused" grep -qx live-refused <<<"$srv"
check "the sandbox herdr server comes up" grep -qx herdr-up <<<"$srv"
check "it answers on its own socket" grep -qx herdr-answers <<<"$srv"
check "its socket is in the sandbox HOME" grep -qx own-socket <<<"$srv"
check "the mock API comes up" grep -qx mock-up <<<"$srv"
check "the mock answers a Messages request" grep -qx mock-answers <<<"$srv"
check "the mock logged the request" grep -q '"path": "/v1/messages"' "$SANDBOX_EVIDENCE/mock-requests.jsonl"
check "Codex's config.toml points at the mock's Responses API" grep -qx codex-mock <<<"$srv"
check "Claude Code's first-run state is written" grep -qx claude-ready <<<"$srv"
# The namespace's processes die as the step ends; give the kernel a moment.
none_left() {
    local _
    for _ in $(seq 1 30); do
        pgrep -u "$(id -u)" -f -- "$SANDBOX_ROOT" >/dev/null || return 0
        sleep 0.1
    done
    return 1
}
check "nothing the step started outlives it (the mock, a left-running child)" none_left
check "the inside functions refuse to run outside" bash -c 'source "$1"; ! sandbox_herdr_start 2>/dev/null' _ "$LIB"

echo
echo "passed: $PASS, failed: $FAIL"
((FAIL == 0))
