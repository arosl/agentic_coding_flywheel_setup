#!/usr/bin/env bash
# ============================================================
# machine.sh verify and machine_verify.sh (acfs-ioo3.4.2) against stubs
#
# The checks run with a fixture HOME and a PATH of stubs plus a few system
# tools, so no real agent, gh, Tailscale, herdr or Agent Mail is reached
# and nothing is paid for. machine.sh verify runs against a stub incus and
# ssh that run the streamed checks locally.
#
# Usage: bash tests/unit/test_incus_machine_verify.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACHINE="$ROOT/scripts/providers/machine.sh"
CHECKS="$ROOT/scripts/providers/machine_verify.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-machine-verify.XXXXXX")"
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

# System tools the checks may use; nothing else of the runner's is on PATH.
SYSBIN="$WORK/sysbin"
mkdir -p "$SYSBIN"
for tool in bash sh env cat sed tr cut head tail sort find stat mktemp rm mkdir mv chmod \
    grep awk basename dirname timeout jq printf sleep ls ssh-keygen date touch dd; do
    path="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$path" && "$path" == /* ]] && ln -sf "$path" "$SYSBIN/$tool"
done

STUBS="$WORK/stubs"
CALLS="$WORK/calls"
FIX="$WORK/fixture"
export CALLS FIX

# A stub that logs "<name> <args> @ <cwd>" and answers from
# $FIX/answer.<name> (stdout) and $FIX/rc.<name> (exit code); a
# $FIX/sleep.<name> makes it sleep that long first.
make_stub() {
    local name="$1"
    cat >"$STUBS/$name" <<STUB
#!/bin/bash
printf '%s %s @ %s\n' "$name" "\$*" "\$PWD" >>"\$CALLS"
[[ -f "\$FIX/sleep.$name" ]] && sleep "\$(cat "\$FIX/sleep.$name")"
[[ -f "\$FIX/answer.$name" ]] && cat "\$FIX/answer.$name"
exit "\$(cat "\$FIX/rc.$name" 2>/dev/null || echo 0)"
STUB
    chmod 0755 "$STUBS/$name"
}

# A fresh machine: an empty HOME, no stubs, no answers.
reset() {
    rm -rf "$STUBS" "$FIX" "$CALLS"
    mkdir -p "$STUBS" "$FIX/home" "$FIX/root" "$FIX/projects"
    : >"$CALLS"
    # sudo -n runs its command as is; findmnt reports $FIX/mounts.
    cat >"$STUBS/sudo" <<'STUB'
#!/bin/bash
[[ "$1" == -n ]] && shift
printf 'sudo %s\n' "$*" >>"$CALLS"
exec "$@"
STUB
    cat >"$STUBS/findmnt" <<'STUB'
#!/bin/bash
printf '/\n'
[[ -f "$FIX/mounts" ]] && cat "$FIX/mounts"
exit 0
STUB
    chmod 0755 "$STUBS/sudo" "$STUBS/findmnt"
    ssh-keygen -q -t ed25519 -N '' -C fixture -f "$FIX/host_key" >/dev/null
}

# Runs the checks the way the machine would (stdin, a `set --` line first).
run_checks() {
    RC=0
    local set_line="set --" arg
    for arg in "$@"; do set_line+=" $(printf '%q' "$arg")"; done
    { printf '%s\n' "$set_line"; cat "$CHECKS"; } \
        | env -i HOME="$FIX/home" PATH="$STUBS:$SYSBIN" TMPDIR="$WORK" CALLS="$CALLS" FIX="$FIX" \
            ACFS_VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-10}" ACFS_PROJECTS_DIR="$FIX/projects" \
            ACFS_VERIFY_HOST_KEY="$FIX/host_key.pub" ACFS_VERIFY_SEARCH_ROOT="$FIX/root" \
            ACFS_VERIFY_STATE_LAYER="$FIX/home/.acfs/scripts/lib/state_layer.sh" \
            "$SYSBIN/bash" -s >"$WORK/rows" 2>"$WORK/err" || RC=$?
    ROWS="$(cat "$WORK/rows")"
}
row() { grep "^$1|" <<<"$ROWS" | head -n 1; }
result_is() { [[ "$(row "$1" | cut -d'|' -f2)" == "$2" ]]; }
detail_has() { [[ "$(row "$1" | cut -d'|' -f3)" == *"$2"* ]]; }
called() { grep -qF -- "$1" "$CALLS"; }

login_file() {
    mkdir -p "$(dirname "$FIX/home/$1")"
    printf '{}\n' >"$FIX/home/$1"
    chmod "${2:-600}" "$FIX/home/$1"
}

echo "machine_verify.sh: nothing configured"
reset
run_checks
check "every tool without a login is not-configured, never ok" bash -c '
    for c in claude claude.session codex codex.session agy pi gh agent-mail tailscale herdr br cm lease; do
        grep -q "^$c|not-configured|" <<<"$1" || { echo "missing $c"; exit 1; }
    done' _ "$ROWS"
check "the host key row carries its fingerprint as the value to compare" \
    bash -c '[[ "$1" == "ssh.host-key|ok|ed25519 SHA256:"*"|SHA256:"* ]]' _ "$(row ssh.host-key)"
check "an empty root has no stray login file" result_is credentials ok
check "the checks exit 0, and nothing was called but the search" \
    bash -c '[[ "$1" -eq 0 ]] && ! grep -qv "^sudo find" "$2"' _ "$RC" "$CALLS"

echo "claude"
reset
login_file .claude/.credentials.json
mkdir -p "$FIX/home/.claude/projects/-work" "$FIX/work"
printf '{"type":"summary"}\n{"cwd":"%s","sessionId":"abc"}\n' "$FIX/work" >"$FIX/home/.claude/projects/-work/1111-2222.jsonl"
make_stub claude
printf 'ok\n' >"$FIX/answer.claude"
run_checks
check "a private login and an ok answer pass" result_is claude ok
check "the one-shot saves no session and runs in a scratch directory" \
    bash -c 'grep -q "^claude -p reply with ok --output-format text --no-session-persistence @ .*/acfs-verify\." "$1"' _ "$CALLS"
check "the newest session is resumed as a fork, unsaved, in its own cwd" \
    bash -c 'grep -qF "claude -p reply with ok --resume 1111-2222 --fork-session --no-session-persistence --output-format text @ $2" "$1"' _ "$CALLS" "$FIX/work"
check "the session row passes" result_is claude.session ok

reset
login_file .claude/.credentials.json 644
make_stub claude
run_checks
check "a login file others can read fails by its mode, and claude is never asked" \
    bash -c 'grep -q "^claude|failed|.*mode 644" <<<"$1" && ! grep -q "^claude " "$2"' _ "$ROWS" "$CALLS"

echo "classifying an answer"
classify_case() {
    local answer="$1" rc="$2" want="$3"
    reset
    login_file .claude/.credentials.json
    make_stub claude
    printf '%s\n' "$answer" >"$FIX/answer.claude"
    printf '%s\n' "$rc" >"$FIX/rc.claude"
    run_checks
    result_is claude "$want"
}
check "'Please run /login' is invalid-login" classify_case "Invalid API key · Please run /login" 1 invalid-login
check "a usage limit is quota, even when it names the account" classify_case "Claude AI usage limit reached for your account" 1 quota
check "a resolver failure is network" classify_case "getaddrinfo ENOTFOUND api.anthropic.com" 1 network
check "an unknown failure is failed, not ok" classify_case "something odd" 3 failed
check "ok with a non-zero exit is failed" classify_case "ok" 2 failed
reset
login_file .claude/.credentials.json
make_stub claude
printf '3\n' >"$FIX/sleep.claude"
VERIFY_TIMEOUT=1 run_checks
check "a request past the timeout is network, with the timeout named" \
    bash -c 'grep -q "^claude|network|claude -p timed out after 1s" <<<"$1"' _ "$ROWS"

reset
login_file .claude/.credentials.json
make_stub claude
printf 'Error: key sk-ant-api03-abcdefghijklmnop rejected; Authorization: Bearer abc.def.ghi; token=xyz123\n' >"$FIX/answer.claude"
printf '1\n' >"$FIX/rc.claude"
run_checks
check "credentials in an answer are redacted" \
    bash -c '[[ "$1" != *sk-ant-api03* && "$1" != *abc.def.ghi* && "$1" != *xyz123* && "$1" == *"[redacted]"* ]]' _ "$(row claude)"

echo "codex"
reset
login_file .codex/auth.json
mkdir -p "$FIX/home/.codex/sessions/2026/10/10" "$FIX/repo"
printf '{"type":"session_meta","payload":{"id":"0199-aaaa","cwd":"%s"}}\n' "$FIX/repo" \
    >"$FIX/home/.codex/sessions/2026/10/10/rollout-2026-10-10T10-00-00-0199-aaaa.jsonl"
make_stub codex
printf 'session id: 0199-4291-401a\nok\ntokens used\n1,429\n' >"$FIX/answer.codex"
run_checks
check "codex checks its login, then one exec, unsaved" \
    bash -c 'grep -q "^codex login status @" "$1" && grep -q "^codex exec --skip-git-repo-check --ephemeral reply with ok @ .*/acfs-verify\." "$1"' _ "$CALLS"
check "the newest codex session is forked, unsaved, in its cwd" \
    bash -c 'grep -qF "codex exec fork --skip-git-repo-check --ephemeral 0199-aaaa reply with ok @ $2" "$1"' _ "$CALLS" "$FIX/repo"
check "both codex rows pass, though the chatter holds 429 and 401" bash -c '[[ "$1" == "codex|ok|"* && "$2" == "codex.session|ok|"* ]]' _ "$(row codex)" "$(row codex.session)"

reset
login_file .codex/auth.json
make_stub codex
printf 'Not logged in\n' >"$FIX/answer.codex"
printf '1\n' >"$FIX/rc.codex"
run_checks
check "a stored codex login that status rejects is invalid-login, with no exec" \
    bash -c 'grep -q "^codex|invalid-login|" <<<"$1" && ! grep -q "^codex exec" "$2"' _ "$ROWS" "$CALLS"

echo "agy, pi and gh"
reset
login_file .gemini/antigravity-cli/antigravity-oauth-token
login_file .pi/agent/auth.json
login_file .config/gh/hosts.yml
make_stub agy; make_stub pi; make_stub gh
printf 'ok\n' >"$FIX/answer.agy"
printf 'OK.\n' >"$FIX/answer.pi"
run_checks
check "agy and pi get one -p each and pass" \
    bash -c 'grep -q "^agy -p reply with ok" "$1" && grep -q "^pi -p reply with ok" "$1" && grep -q "^agy|ok|" <<<"$2" && grep -q "^pi|ok|" <<<"$2"' _ "$CALLS" "$ROWS"
check "gh auth status with exit 0 passes" result_is gh ok
printf 'You are not logged into any GitHub hosts.\n' >"$FIX/answer.gh"
printf '1\n' >"$FIX/rc.gh"
run_checks
check "gh with a stale login is invalid-login" result_is gh invalid-login

echo "Agent Mail"
mail_stub() {
    cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$CALLS"
body="$(cat)"
printf '%s\n' "$body" >>"$FIX/mail-bodies"
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == -H ]]; then j=$((i + 1)); h="${!j}"; [[ "$h" == @* ]] && cat "${h#@}" >>"$FIX/mail-headers"; fi
done
case "$body" in
    *'"initialize"'*) printf 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"mcp-agent-mail"}}}\n' ;;
    *) cat "$FIX/mail-tool" ;;
esac
STUB
    chmod 0755 "$STUBS/curl"
}
reset
mkdir -p "$FIX/home/.config/mcp-agent-mail"
printf 'HTTP_BEARER_TOKEN="s3cr3t-mail-token"\n' >"$FIX/home/.config/mcp-agent-mail/config.env"
chmod 600 "$FIX/home/.config/mcp-agent-mail/config.env"
mail_stub
printf '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}\n' >"$FIX/mail-tool"
run_checks
check "MCP initialize and health_check pass" \
    bash -c '[[ "$1" == "agent-mail|ok|MCP initialize and health_check answered|" ]]' _ "$(row agent-mail)"
check "the bearer token goes in a header file, never on curl's argv" \
    bash -c '! grep -q s3cr3t "$1" && grep -q "^Authorization: Bearer s3cr3t-mail-token$" "$2"' _ "$CALLS" "$FIX/mail-headers"
run_checks --mail-agent BlueLake --mail-project /p/x
check "with an agent named, fetch_inbox peeks without marking anything read" \
    bash -c 'grep "fetch_inbox" "$1" | jq -e ".params.arguments == {project_key:\"/p/x\",agent_name:\"BlueLake\",limit:1,mark_read:false}" >/dev/null' _ "$FIX/mail-bodies"
printf '{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"401 Unauthorized"}]}}\n' >"$FIX/mail-tool"
run_checks
check "a tool error that says unauthorized is invalid-login" result_is agent-mail invalid-login
printf '1\n' >"$FIX/rc.curl"
cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl: (7) Failed to connect to 127.0.0.1 port 8765" >&2
exit 7
STUB
run_checks
check "no server is network" result_is agent-mail network

echo "Tailscale, herdr, br and cm"
reset
make_stub tailscale
printf '{"BackendState":"Running","Self":{"HostName":"devbox"}}\n' >"$FIX/answer.tailscale"
cat >"$STUBS/herdr" <<'STUB'
#!/bin/bash
case "$*" in
    "status server") printf 'status: running\nversion: 0.9.3\n' ;;
    "workspace list") printf '{"result":{"workspaces":[{"label":"zeta"},{"label":"alpha"}]}}\n' ;;
esac
STUB
chmod 0755 "$STUBS/herdr"
mkdir -p "$FIX/projects/one/.beads" "$FIX/projects/two/.beads" "$FIX/projects/plain"
cat >"$STUBS/br" <<'STUB'
#!/bin/bash
[[ "$PWD" == */two ]] && { echo "database locked" >&2; exit 1; }
echo '[]'
STUB
chmod 0755 "$STUBS/br"
make_stub cm
printf '{"playbook":[]}\n' >"$FIX/answer.cm"
run_checks
check "a running tailnet passes and carries its host name" \
    bash -c '[[ "$1" == "tailscale|ok|on the tailnet as devbox|devbox" ]]' _ "$(row tailscale)"
check "herdr passes with its workspaces sorted as the value" \
    bash -c '[[ "$1" == "herdr|ok|server running; workspaces: alpha,zeta|alpha,zeta" ]]' _ "$(row herdr)"
check "br fails naming the project whose br ready fails" \
    bash -c '[[ "$1" == "br|failed|br ready --json failed in two|" ]]' _ "$(row br)"
check "cm context with JSON passes" result_is cm ok
printf '{"BackendState":"NeedsLogin"}\n' >"$FIX/answer.tailscale"
run_checks
check "a tailnet that needs a login is invalid-login" result_is tailscale invalid-login

echo "the lease and the credential search"
reset
mkdir -p "$FIX/home/.acfs/scripts/lib"
printf 'echo "volume lease:   set"; echo "instance lease: set"; echo "match: yes"\n' >"$FIX/home/.acfs/scripts/lib/state_layer.sh"
mkdir -p "$FIX/root/home/ubuntu/.codex" "$FIX/root/etc/stray" "$FIX/root/mnt/vol" "$FIX/root/data/x"
touch "$FIX/root/home/ubuntu/.codex/auth.json" "$FIX/root/etc/stray/auth.json" "$FIX/root/mnt/vol/hosts.yml" "$FIX/root/data/x/.credentials.json"
printf '/mnt/vol\n' >"$FIX/mounts"
run_checks
check "a matching lease passes, read through sudo -n lease status" \
    bash -c 'grep -q "^lease|ok|" <<<"$1" && grep -q "^sudo bash .*state_layer.sh lease status" "$2"' _ "$ROWS" "$CALLS"
check "the search finds the stray file only: the home, /data and other mounts are left out" \
    bash -c '[[ "$1" == "credentials|failed|login files outside the state volume: $2/etc/stray/auth.json|" ]]' _ "$(row credentials)" "$FIX/root"
printf 'echo "volume lease:   set"; echo "instance lease: set"; echo "match: no"\n' >"$FIX/home/.acfs/scripts/lib/state_layer.sh"
run_checks
check "a lease that doesn't match fails" result_is lease failed

echo "machine.sh verify"
# The stub incus and ssh run the streamed checks locally, with this
# fixture's environment; ssh <alias> true answers per $FIX/ssh.
make_transport() {
    cat >"$STUBS/incus" <<'STUB'
#!/bin/bash
printf 'incus %s\n' "$*" >>"$CALLS"
[[ "$1" == exec ]] || exit 2
exec env -i HOME="$FIX/home" PATH="$STUBS:$SYSBIN" TMPDIR="$WORK" CALLS="$CALLS" FIX="$FIX" \
    ACFS_PROJECTS_DIR="$FIX/projects" ACFS_VERIFY_HOST_KEY="$FIX/host_key.pub" \
    ACFS_VERIFY_SEARCH_ROOT="$FIX/root" ACFS_VERIFY_STATE_LAYER="$FIX/none" bash -s
STUB
    cat >"$STUBS/ssh" <<'STUB'
#!/bin/bash
printf 'ssh %s\n' "$*" >>"$CALLS"
if [[ "${*: -1}" == true ]]; then
    case "$(cat "$FIX/ssh" 2>/dev/null || echo ok)" in
        ok) exit 0 ;;
        changed) echo "Host key verification failed." >&2; exit 255 ;;
        denied) echo "ubuntu@devbox: Permission denied (publickey)." >&2; exit 255 ;;
        down) echo "ssh: connect to host devbox port 22: Connection timed out" >&2; exit 255 ;;
    esac
fi
exec env -i HOME="$FIX/home" PATH="$STUBS:$SYSBIN" TMPDIR="$WORK" CALLS="$CALLS" FIX="$FIX" \
    ACFS_PROJECTS_DIR="$FIX/projects" ACFS_VERIFY_HOST_KEY="$FIX/host_key.pub" \
    ACFS_VERIFY_SEARCH_ROOT="$FIX/root" ACFS_VERIFY_STATE_LAYER="$FIX/none" bash -s
STUB
    chmod 0755 "$STUBS/incus" "$STUBS/ssh"
}
export STUBS SYSBIN WORK
run_machine() {
    RC=0
    PATH="$STUBS:$PATH" ACFS_MACHINE_STATE_DIR="$WORK/state" \
        bash "$MACHINE" "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
    OUT="$(cat "$WORK/out")"
    ERR="$(cat "$WORK/err")"
}
out_row() { grep "^$1 " <<<"$OUT" | head -n 1; }

reset
rm -rf "$WORK/state"
make_transport
run_machine verify host2:devbox
check "a machine with nothing configured passes (exit 0), as its user through incus exec" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qF "incus exec host2:devbox -- runuser -l ubuntu -c bash -s" "$2"' _ "$RC" "$CALLS"
check "the ssh check runs from here against the alias without the remote, strictly" \
    bash -c 'grep -qF "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 devbox true" "$1"' _ "$CALLS"
check "the first run records the host key" \
    bash -c '[[ "$1" == *"(recorded)"* ]] && grep -q "^ssh.host-key=SHA256:" "$2"' _ "$(out_row ssh.host-key)" "$WORK/state/host2_devbox.baseline"
check "rows print as check, result, detail; progress stays on stderr" \
    bash -c 'grep -qE "^claude +not-configured +no claude" <<<"$1" && grep -q "verifying host2:devbox" <<<"$2"' _ "$OUT" "$ERR"
run_machine verify host2:devbox
check "an unchanged host key passes without a note" \
    bash -c '[[ "$1" == "ssh.host-key"*" ok "* && "$1" != *recorded* ]]' _ "$(out_row ssh.host-key)"

ssh-keygen -q -t ed25519 -N '' -C other -f "$FIX/host_key2" >/dev/null
mv -f "$FIX/host_key2.pub" "$FIX/host_key.pub"
run_machine verify host2:devbox
check "a changed host key fails and exits 1, naming --rebaseline" \
    bash -c '[[ "$1" -eq 1 && "$2" == "ssh.host-key"*" failed "*"changed since the last run"*"--rebaseline"* ]]' _ "$RC" "$(out_row ssh.host-key)"
run_machine verify host2:devbox --rebaseline
check "--rebaseline accepts the new key, and the next run passes" \
    bash -c '[[ "$1" -eq 0 && "$2" == *"(accepted, was SHA256:"* ]]' _ "$RC" "$(out_row ssh.host-key)"

for state in changed denied down; do
    printf '%s\n' "$state" >"$FIX/ssh"
    run_machine verify host2:devbox
    case "$state" in
        changed) want=failed ;;
        denied) want=invalid-login ;;
        down) want=network ;;
    esac
    check "ssh that is $state reports $want and exits 1" \
        bash -c '[[ "$1" -eq 1 && "$2" =~ ^ssh\ +$3\  ]]' _ "$RC" "$(out_row ssh)" "$want"
done
rm -f "$FIX/ssh"

: >"$CALLS"
run_machine verify --target vps vps1 --mail-agent BlueLake --mail-project /p/x
check "a VPS runs the checks over ssh in a login shell, options in the set line" \
    bash -c 'grep -qF "ssh -o BatchMode=yes -o ConnectTimeout=15 vps1 bash -l -s" "$1" && [[ "$2" -eq 0 ]]' _ "$CALLS" "$RC"
run_machine verify devbox --bogus
check "an unknown verify option is refused before anything runs" \
    bash -c '[[ "$1" -ne 0 && "$2" == *"unknown verify option: --bogus"* ]]' _ "$RC" "$ERR"
run_machine verify --target lxd devbox
check "an unknown target is refused" bash -c '[[ "$1" -ne 0 && "$2" == *"unknown target: lxd"* ]]' _ "$RC" "$ERR"

cat >"$STUBS/incus" <<'STUB'
#!/bin/bash
exit 1
STUB
run_machine verify devbox
check "a machine whose checks report nothing fails clearly" \
    bash -c '[[ "$1" -ne 0 && "$2" == *"reported nothing"* ]]' _ "$RC" "$ERR"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
