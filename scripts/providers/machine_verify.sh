#!/usr/bin/env bash
# ============================================================
# ACFS machine verify, the checks inside the machine (acfs-ioo3.4.2)
#
#   machine_verify.sh [--mail-agent <name> --mail-project <key>]
#
# `scripts/providers/machine.sh verify` streams this file into the
# machine, as its user and in a login shell (incus exec, or ssh for a VPS),
# and reads one line per check from stdout:
#
#   <check>|<result>|<detail>|<value>
#
# result is ok, not-configured, invalid-login, network, quota or failed.
# A tool without a login reports not-configured: never a pass, and never a
# login prompt. value is set only for what machine.sh compares with the
# machine's last run: the ed25519 host key, the tailnet name and herdr's
# workspaces. Every detail is redacted and cut to one short line.
#
# Each configured tool gets its stored metadata checked (present, private
# mode), then ONE small authenticated request under a timeout. The agent
# requests are paid, so this is not the doctor, whose state section keeps
# the read-only, local parts (plan 4.7.5). The requests run in a private
# scratch directory; the session checks fork the newest session of each
# kind without saving the fork, so no existing session changes. The lease
# and the credential search read as root through sudo -n, never prompting.
# ============================================================

set -uo pipefail

# A non-interactive login shell doesn't read acfs.zshrc, which puts the
# tools on PATH; the same directories, in its order (the last first).
for dir in "$HOME/.cargo/bin" "$HOME/go/bin" /usr/local/go/bin "$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/bin"; do
    [[ -d "$dir" ]] && PATH="$dir:$PATH"
done
# nvm's newest node, which the node-based agents need.
node_bin="$(printf '%s\n' "$HOME"/.nvm/versions/node/*/bin | sort -V | tail -n 1)"
[[ -d "$node_bin" ]] && PATH="$node_bin:$PATH"
export PATH

TIMEOUT="${ACFS_VERIFY_TIMEOUT:-120}"
PROMPT="reply with ok"
PROJECTS_DIR="${ACFS_PROJECTS_DIR:-/data/projects}"
STATE_LAYER="${ACFS_VERIFY_STATE_LAYER:-$HOME/.acfs/scripts/lib/state_layer.sh}"
HOST_KEY="${ACFS_VERIFY_HOST_KEY:-/etc/ssh/ssh_host_ed25519_key.pub}"
# The search root and the mounts left out of it; tests move them.
SEARCH_ROOT="${ACFS_VERIFY_SEARCH_ROOT:-/}"
MAIL_URL="${AGENT_MAIL_URL:-http://127.0.0.1:${ACFS_AGENT_MAIL_PORT:-8765}/mcp/}"
MAIL_AGENT=""
MAIL_PROJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mail-agent) MAIL_AGENT="${2:-}"; shift 2 ;;
        --mail-project) MAIL_PROJECT="${2:-}"; shift 2 ;;
        *) printf 'verify|failed|unknown option %s|\n' "$1"; exit 2 ;;
    esac
done

# Credentials never reach a detail: API keys, GitHub, Slack and Tailscale
# tokens, JWTs and bearer headers become [redacted]. One line, 200 chars.
redact() {
    tr '\n\r\t|' '    ' | sed -E \
        -e 's/(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[abprs]-[A-Za-z0-9-]{8,}|tskey-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+)/[redacted]/g' \
        -e 's/([Bb]earer) +[^ ]+/\1 [redacted]/g' \
        -e 's/([Tt]oken|[Aa]uthorization|[Kk]ey|[Ss]ecret|[Pp]assword)([=:]) *[^ ]+/\1\2[redacted]/g' \
        -e 's/  +/ /g; s/^ //; s/ $//' | cut -c1-200
}

emit() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "$(printf '%s' "${3:-}" | redact)" "$(printf '%s' "${4:-}" | redact)"
}

# Group or other access on a login file is a finding of its own.
private_or_report() {
    local check="$1" file="$2" mode
    mode="$(stat -c %a "$file" 2>/dev/null)" || { emit "$check" failed "cannot stat ${file/#$HOME/~}"; return 1; }
    if (( (8#$mode & 8#077) != 0 )); then
        emit "$check" failed "${file/#$HOME/~} is mode $mode; it should allow its owner only (chmod 600)"
        return 1
    fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/acfs-verify.XXXXXX")" || { emit verify failed "cannot make a scratch directory"; exit 1; }
trap 'rm -rf -- "$SCRATCH"' EXIT

# Runs one request under the timeout in the given directory; sets OUT and
# RC. Its stdin is /dev/null: this script is the shell's stdin.
request() {
    local dir="$1"
    shift
    RC=0
    OUT="$(cd "$dir" && timeout "$TIMEOUT" "$@" 2>&1 </dev/null)" || RC=$?
}

# Maps a request's exit code and output to a result. An ok answer wins:
# a working run's chatter (session ids, token counts) may hold any of the
# words below. Among failures quota comes first, since a rate-limit message
# often mentions the account too; status codes match as whole numbers.
classify() {
    local check="$1" what="$2" lower
    lower="$(printf '%s' "$OUT" | tr '[:upper:]' '[:lower:]')"
    if (( RC == 0 )) && [[ "$lower" =~ (^|[^a-z])ok([^a-z]|$) ]]; then
        emit "$check" ok "$what answered"
    elif (( RC == 124 )); then
        emit "$check" network "$what timed out after ${TIMEOUT}s"
    elif [[ "$lower" =~ (rate[\ _-]?limit|usage\ limit|quota|too\ many\ requests|(^|[^0-9])429([^0-9]|$)|limit\ reached|insufficient_quota|credit\ balance) ]]; then
        emit "$check" quota "$what: $OUT"
    elif [[ "$lower" =~ (not\ logged\ in|log\ ?in\ again|/login|unauthori[sz]ed|(^|[^0-9])40[13]([^0-9]|$)|invalid\ api\ key|invalid_grant|expired|revoked|authenticat|credentials) ]]; then
        emit "$check" invalid-login "$what: $OUT"
    elif [[ "$lower" =~ (could\ not\ resolve|enotfound|econnrefused|econnreset|etimedout|eai_again|network|connection\ (refused|reset|timed\ out)|getaddrinfo|certificate|offline) ]]; then
        emit "$check" network "$what: $OUT"
    else
        emit "$check" failed "$what exited $RC: $OUT"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- Agents: one one-shot each, then one forked session per kind ---------

# The newest file matching a find expression under a directory.
newest() {
    local dir="$1"
    shift
    [[ -d "$dir" ]] || return 1
    find "$dir" "$@" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-
}

check_claude() {
    local creds="$HOME/.claude/.credentials.json" session id cwd
    if ! have claude || [[ ! -f "$creds" ]]; then
        emit claude not-configured "no claude, or no ~/.claude/.credentials.json"
        emit claude.session not-configured "no claude login"
        return 0
    fi
    private_or_report claude "$creds" || { emit claude.session not-configured "the claude login file isn't private"; return 0; }
    request "$SCRATCH" claude -p "$PROMPT" --output-format text --no-session-persistence
    classify claude "claude -p"
    session="$(newest "$HOME/.claude/projects" -maxdepth 2 -name '*.jsonl')" || session=""
    if [[ -z "$session" ]]; then
        emit claude.session not-configured "no saved session under ~/.claude/projects"
        return 0
    fi
    id="$(basename "$session" .jsonl)"
    cwd="$(jq -r 'select(.cwd != null) | .cwd' "$session" 2>/dev/null | head -n 1)"
    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
        emit claude.session failed "session $id has no working directory that exists here (${cwd:-none})"
        return 0
    fi
    request "$cwd" claude -p "$PROMPT" --resume "$id" --fork-session --no-session-persistence --output-format text
    classify claude.session "claude --resume $id (forked, in ${cwd/#$HOME/~})"
}

check_codex() {
    local auth="$HOME/.codex/auth.json" session id cwd
    if ! have codex || [[ ! -f "$auth" ]]; then
        emit codex not-configured "no codex, or no ~/.codex/auth.json"
        emit codex.session not-configured "no codex login"
        return 0
    fi
    private_or_report codex "$auth" || { emit codex.session not-configured "the codex login file isn't private"; return 0; }
    request "$SCRATCH" codex login status
    if (( RC != 0 )); then
        classify codex "codex login status"
        emit codex.session not-configured "codex login status failed"
        return 0
    fi
    request "$SCRATCH" codex exec --skip-git-repo-check --ephemeral "$PROMPT"
    classify codex "codex exec"
    session="$(newest "$HOME/.codex/sessions" -name 'rollout-*.jsonl')" || session=""
    if [[ -z "$session" ]]; then
        emit codex.session not-configured "no saved session under ~/.codex/sessions"
        return 0
    fi
    id="$(head -n 1 "$session" | jq -r '.payload.id // empty' 2>/dev/null)"
    cwd="$(head -n 1 "$session" | jq -r '.payload.cwd // empty' 2>/dev/null)"
    if [[ -z "$id" || -z "$cwd" || ! -d "$cwd" ]]; then
        emit codex.session failed "the newest session names no id or no working directory that exists here"
        return 0
    fi
    request "$cwd" codex exec fork --skip-git-repo-check --ephemeral "$id" "$PROMPT"
    classify codex.session "codex exec fork $id (in ${cwd/#$HOME/~})"
}

# agy and pi: a one-shot when their login file exists.
check_oneshot() {
    local check="$1" bin="$2" marker="$3"
    if ! have "$bin" || [[ ! -f "$HOME/$marker" ]]; then
        emit "$check" not-configured "no $bin, or no ~/$marker"
        return 0
    fi
    private_or_report "$check" "$HOME/$marker" || return 0
    request "$SCRATCH" "$bin" -p "$PROMPT"
    classify "$check" "$bin -p"
}

# --- Accounts and services ------------------------------------------------

check_gh() {
    local hosts="$HOME/.config/gh/hosts.yml"
    if ! have gh || [[ ! -f "$hosts" ]]; then
        emit gh not-configured "no gh, or no ~/.config/gh/hosts.yml"
        return 0
    fi
    private_or_report gh "$hosts" || return 0
    request "$SCRATCH" gh auth status
    if (( RC == 0 )); then
        emit gh ok "gh auth status: logged in"
    else
        classify gh "gh auth status"
    fi
}

# MCP initialize, then a non-consuming fetch_inbox when an agent is named
# (otherwise health_check). The bearer token goes to curl through a
# header file, never argv.
check_agent_mail() {
    local env_file="$HOME/.config/mcp-agent-mail/config.env" token headers body
    if [[ ! -f "$env_file" ]]; then
        emit agent-mail not-configured "no ~/.config/mcp-agent-mail/config.env"
        return 0
    fi
    private_or_report agent-mail "$env_file" || return 0
    if ! have curl || ! have jq; then
        emit agent-mail failed "needs curl and jq"
        return 0
    fi
    token="$(sed -n 's/^HTTP_BEARER_TOKEN=//p' "$env_file" | tail -n 1 | sed -E "s/^[\"']//; s/[\"']\$//")"
    headers="$SCRATCH/mail-headers"
    (umask 077; {
        printf 'Content-Type: application/json\n'
        printf 'Accept: application/json, text/event-stream\n'
        [[ -n "$token" ]] && printf 'Authorization: Bearer %s\n' "$token"
    } >"$headers")
    mail_call() {
        RC=0
        OUT="$(curl -sS --max-time 30 -X POST "$MAIL_URL" -H "@$headers" --data-binary @- 2>&1 <<<"$1")" || RC=$?
        # A streamed answer arrives as an SSE "data:" line.
        OUT="$(sed -n 's/^data: //p; /^{/p' <<<"$OUT" | tail -n 1)"
    }
    mail_call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"acfs-machine-verify","version":"1"}}}'
    if (( RC != 0 )) || [[ -z "$OUT" ]]; then
        emit agent-mail network "MCP initialize at $MAIL_URL got no answer (curl exit $RC)"
        return 0
    fi
    if [[ "$(jq -r '.result.serverInfo != null' <<<"$OUT" 2>/dev/null)" != true ]]; then
        OUT="MCP initialize: $(jq -r '.error.message // .' <<<"$OUT" 2>/dev/null || printf '%s' "$OUT")"
        RC=1
        classify agent-mail "Agent Mail"
        return 0
    fi
    if [[ -n "$MAIL_AGENT" && -n "$MAIL_PROJECT" ]]; then
        body="$(jq -nc --arg p "$MAIL_PROJECT" --arg a "$MAIL_AGENT" \
            '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "fetch_inbox", arguments: {project_key: $p, agent_name: $a, limit: 1, mark_read: false}}}')"
    else
        body='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"health_check","arguments":{}}}'
    fi
    mail_call "$body"
    if (( RC == 0 )) && [[ "$(jq -r '(.result != null) and (.result.isError != true)' <<<"$OUT" 2>/dev/null)" == true ]]; then
        emit agent-mail ok "MCP initialize and $(jq -r '.params.name' <<<"$body") answered"
    else
        OUT="$(jq -r '.error.message // (.result.content[0].text // .)' <<<"$OUT" 2>/dev/null || printf '%s' "$OUT")"
        RC=1
        classify agent-mail "Agent Mail $(jq -r '.params.name' <<<"$body")"
    fi
}

check_tailscale() {
    local state host
    if ! have tailscale; then
        emit tailscale not-configured "no tailscale"
        return 0
    fi
    request "$SCRATCH" tailscale status --json
    state="$(jq -r '.BackendState // empty' <<<"$OUT" 2>/dev/null)"
    case "$state" in
        Running)
            host="$(jq -r '.Self.HostName // empty' <<<"$OUT" 2>/dev/null)"
            emit tailscale ok "on the tailnet as $host" "$host"
            ;;
        NeedsLogin|NeedsMachineAuth) emit tailscale invalid-login "tailscale is $state" ;;
        NoState|Stopped|"") emit tailscale not-configured "tailscale is ${state:-not running}" ;;
        *) emit tailscale network "tailscale is $state" ;;
    esac
}

check_host_key() {
    local fp
    if [[ ! -r "$HOST_KEY" ]]; then
        emit ssh.host-key failed "no readable $HOST_KEY"
        return 0
    fi
    fp="$(ssh-keygen -lf "$HOST_KEY" 2>/dev/null | awk '{print $2}')"
    [[ -n "$fp" ]] || { emit ssh.host-key failed "ssh-keygen can't read $HOST_KEY"; return 0; }
    emit ssh.host-key ok "ed25519 $fp" "$fp"
}

check_herdr() {
    local labels
    if ! have herdr; then
        emit herdr not-configured "no herdr"
        return 0
    fi
    request "$SCRATCH" herdr status server
    if (( RC != 0 )) || ! grep -q '^status: running' <<<"$OUT"; then
        emit herdr failed "herdr's server isn't running: $OUT"
        return 0
    fi
    request "$SCRATCH" herdr workspace list
    labels="$(jq -r '[.result.workspaces[]?.label] | sort | join(",")' <<<"$OUT" 2>/dev/null)" \
        || { emit herdr failed "herdr workspace list: $OUT"; return 0; }
    emit herdr ok "server running; workspaces: ${labels:-none}" "${labels:-none}"
}

check_br() {
    local dir found=0 bad=""
    if ! have br; then
        emit br not-configured "no br"
        return 0
    fi
    for dir in "$PROJECTS_DIR"/*/; do
        [[ -d "$dir.beads" ]] || continue
        found=$((found + 1))
        request "$dir" br ready --json
        if (( RC != 0 )) || ! jq -e . >/dev/null 2>&1 <<<"$OUT"; then
            bad+="${bad:+, }$(basename "$dir")"
        fi
    done
    if (( found == 0 )); then
        emit br not-configured "no project with .beads under $PROJECTS_DIR"
    elif [[ -n "$bad" ]]; then
        emit br failed "br ready --json failed in $bad"
    else
        emit br ok "br ready --json answered in $found project(s)"
    fi
}

check_cm() {
    if ! have cm; then
        emit cm not-configured "no cm"
        return 0
    fi
    request "$SCRATCH" cm context "verify the machine" --json
    if (( RC == 0 )) && jq -e . >/dev/null 2>&1 <<<"$OUT"; then
        emit cm ok "cm context answered"
    else
        emit cm failed "cm context exited $RC: $OUT"
    fi
}

# --- Root's view: the lease and the negative credential search ------------

check_lease() {
    if [[ ! -f "$STATE_LAYER" ]]; then
        emit lease not-configured "no state layer (${STATE_LAYER/#$HOME/~})"
        return 0
    fi
    request "$SCRATCH" sudo -n bash "$STATE_LAYER" lease status
    if (( RC != 0 )); then
        emit lease failed "sudo -n state_layer.sh lease status exited $RC: $OUT"
    elif grep -q '^match: yes' <<<"$OUT"; then
        emit lease ok "this instance holds the state volume"
    elif grep -q '^volume lease: *none' <<<"$OUT" && grep -q '^instance lease: *none' <<<"$OUT"; then
        emit lease not-configured "no lease on the volume or the instance (no state layer, or a VPS)"
    else
        emit lease failed "the state volume's lease doesn't match this instance's: $OUT"
    fi
}

# No login file outside the state volume and the two host-state
# directories (plan 3.6). Mount points under the root are left out by name
# from findmnt: a dir pool shares st_dev, so -xdev can't tell them apart.
check_credentials() {
    local -a prune=() found=()
    local mount line
    for mount in /home /data /etc/ssh/acfs-host-keys /var/lib/tailscale; do
        prune+=(-path "${SEARCH_ROOT%/}$mount" -prune -o)
    done
    # Every other mount (the volumes, /proc, /sys, /run ...) is not the
    # root volume. findmnt -r escapes a space in a target as \x20.
    while IFS= read -r mount; do
        [[ -n "$mount" && "$mount" != / ]] || continue
        mount="$(printf '%b' "$mount")"
        prune+=(-path "${SEARCH_ROOT%/}$mount" -prune -o)
    done < <(findmnt -rn -o TARGET 2>/dev/null)
    RC=0
    OUT="$(timeout "$TIMEOUT" sudo -n find "$SEARCH_ROOT" "${prune[@]}" \
        \( -name .credentials.json -o -name auth.json -o -name hosts.yml -o -name '*oauth*token*' \) -print 2>/dev/null </dev/null)" || RC=$?
    if (( RC == 124 )); then
        emit credentials failed "the search timed out after ${TIMEOUT}s"
        return 0
    fi
    if (( RC != 0 )) && [[ -z "$OUT" ]]; then
        emit credentials failed "sudo -n find exited $RC (needs passwordless sudo)"
        return 0
    fi
    while IFS= read -r line; do [[ -n "$line" ]] && found+=("$line"); done <<<"$OUT"
    if (( ${#found[@]} > 0 )); then
        emit credentials failed "login files outside the state volume: ${found[*]}"
    else
        emit credentials ok "no login file outside the state volume"
    fi
}

check_claude
check_codex
check_oneshot agy agy .gemini/antigravity-cli/antigravity-oauth-token
check_oneshot pi pi .pi/agent/auth.json
check_gh
check_agent_mail
check_tailscale
check_host_key
check_herdr
check_br
check_cm
check_lease
check_credentials
