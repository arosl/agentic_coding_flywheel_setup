#!/usr/bin/env bash
# ============================================================
# The nhm rehearsal sandbox (acfs-9hkh.31.1; the operator's ruling of
# 2026-10-12: the rehearsal runs only in a bwrap sandbox on the
# development host, never in Incus, never install.sh or acfs update).
#
# Source this file. Outside the sandbox:
#
#   sandbox_init ROOT          make ROOT the sandbox: HOME, TMPDIR, bin,
#                              evidence. ROOT must be under
#                              $NHM_SANDBOX_PARENT (default /data/tmp,
#                              where the development host keeps scratch
#                              files) and never in this checkout.
#   sandbox_bin NAME [PATH]    put a host program into the sandbox's bin,
#                              read-only (PATH defaults to NAME on PATH,
#                              followed through its symlinks)
#   sandbox_nhm_release VER    fetch nhm VER's release archive, verify it
#                              against the release's SHA256SUMS, unpack it
#                              into the sandbox HOME and put nhm and
#                              nhm-hook into its bin
#   sandbox_nhm_build DIR      take nhm and nhm-hook from a local build
#   sandbox_exec CMD...        run CMD in the sandbox (below)
#
# sandbox_exec runs CMD in one bwrap: / read-only; ROOT writable; the
# real HOME, /tmp and /run/user hidden under empty tmpfs mounts; its own
# network namespace (only lo, so the live Agent Mail and every other
# host service are out of reach) and its own pid namespace (every
# process CMD starts ends with CMD). The environment is cleared, then
# set to the sandbox's own HOME, XDG_*, TMPDIR, CLAUDE_CONFIG_DIR,
# CODEX_HOME and HERDR_SOCKET_PATH, with Claude pointed at the mock API.
# CMD is usually `bash STEP.sh`; the step sources this file again and
# uses the inside functions:
#
#   sandbox_herdr_start        a headless herdr server on the sandbox's
#                              own socket; refuses when that socket
#                              resolves to the live server's
#   sandbox_herdr_stop
#   sandbox_mock_start [SCRIPT]
#                              the mock model APIs (mock_anthropic.py:
#                              Messages for Claude, Responses for Codex) on
#                              a free 127.0.0.1 port, with replies from
#                              SCRIPT, logging to the evidence dir; sets
#                              ANTHROPIC_BASE_URL and SANDBOX_MOCK_URL
#                              ($NHM_SANDBOX_MOCK names another mock file)
#   sandbox_claude_prepare DIR Claude Code's first-run state: onboarding
#                              done, the mock key approved, DIR trusted
#   sandbox_codex_prepare DIR  Codex's config.toml: the mock's Responses
#                              API, DIR trusted (after sandbox_mock_start)
#   sandbox_mock_stop
#   sandbox_mail_start         a separate Agent Mail server (am, which
#                              sandbox_bin must provide) on the sandbox's
#                              own lo, its storage in the sandbox HOME
#   sandbox_mail_stop
#
# sandbox_init also puts an `acfs` into the sandbox's bin that runs
# `acfs agents ...` from this checkout's scripts/lib/herdr_agents.sh.
#
# Nothing here installs anything on the host or touches the live herdr
# server, ~/.claude, ~/.codex, ~/.config or ~/.local.
# ============================================================

SANDBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Until sandbox_mock_start sets the mock's URL, the APIs point at a closed
# port (the sandbox has no network anyway).
SANDBOX_NO_API="http://127.0.0.1:9"
# Not a real key: the mock accepts any, and Claude Code wants one.
SANDBOX_MOCK_KEY="sk-ant-api03-acfs-rehearsal-mock-key-not-real-000000000000AA"

sandbox_die() {
    printf 'nhm_sandbox: %s\n' "$*" >&2
    return 1
}

# ---- outside the sandbox ----

sandbox_init() {
    local root="${1:-}"
    [[ -n "$root" ]] || { sandbox_die "sandbox_init: give the sandbox root"; return 1; }
    command -v bwrap >/dev/null 2>&1 || { sandbox_die "bwrap is not installed"; return 1; }
    # Check before creating anything, and again on the resolved path.
    local checkout parent candidate
    checkout="$(realpath -e "$SANDBOX_LIB_DIR/../../..")"
    parent="$(realpath -m "${NHM_SANDBOX_PARENT:-/data/tmp}")"
    for candidate in "$(realpath -m "$root")" ""; do
        if [[ -z "$candidate" ]]; then
            mkdir -p "$root" || return 1
            candidate="$(realpath -e "$root")" || return 1
        fi
        case "$candidate/" in
            "$parent"/?*/) ;;
            *) sandbox_die "the root must be under $parent (NHM_SANDBOX_PARENT), not $candidate"; return 1 ;;
        esac
        case "$candidate/" in
            "$checkout"/*) sandbox_die "the root must not be in the checkout ($checkout)"; return 1 ;;
        esac
        root="$candidate"
    done
    SANDBOX_ROOT="$root"
    SANDBOX_HOME="$root/home"
    SANDBOX_BIN="$root/bin"
    SANDBOX_EVIDENCE="$root/evidence"
    SANDBOX_BINDS=()
    mkdir -p "$SANDBOX_HOME/.config" "$SANDBOX_HOME/.local/state" "$SANDBOX_HOME/.local/share" \
        "$SANDBOX_HOME/.cache" "$SANDBOX_HOME/.claude" "$SANDBOX_HOME/.codex" \
        "$root/tmp" "$root/run" "$SANDBOX_BIN" "$SANDBOX_EVIDENCE" "$root/dl" || return 1
    chmod 700 "$root/run" || return 1
    # `acfs agents ...` runs this checkout's own Bash (nhm's takeover calls
    # it as ACFS_BIN); no other acfs verb exists in the sandbox.
    printf '%s\n' '#!/usr/bin/env bash' \
        'case "${1:-}" in' \
        "    agents) shift; exec bash '$checkout/scripts/lib/herdr_agents.sh' \"\$@\" ;;" \
        '    *) echo "acfs (sandbox): only acfs agents exists here" >&2; exit 2 ;;' \
        'esac' >"$SANDBOX_BIN/acfs" || return 1
    chmod 755 "$SANDBOX_BIN/acfs" || return 1
    export SANDBOX_ROOT SANDBOX_HOME SANDBOX_BIN SANDBOX_EVIDENCE
}

sandbox_bin() {
    local name="${1:-}" src="${2:-}"
    [[ -n "${SANDBOX_ROOT:-}" ]] || { sandbox_die "sandbox_bin: run sandbox_init first"; return 1; }
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { sandbox_die "sandbox_bin: bad name '$name'"; return 1; }
    if [[ -z "$src" ]]; then
        src="$(command -v "$name")" || { sandbox_die "sandbox_bin: $name is not on PATH"; return 1; }
    fi
    src="$(realpath -e "$src")" || return 1
    [[ -f "$src" && -x "$src" ]] || { sandbox_die "sandbox_bin: $src is not an executable file"; return 1; }
    : > "$SANDBOX_BIN/$name" || return 1
    SANDBOX_BINDS+=("$src" "$SANDBOX_BIN/$name")
}

sandbox_nhm_release() {
    local ver="${1:-}" arch asset base sums want got dest
    [[ -n "${SANDBOX_ROOT:-}" ]] || { sandbox_die "sandbox_nhm_release: run sandbox_init first"; return 1; }
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { sandbox_die "sandbox_nhm_release: '$ver' is not X.Y.Z"; return 1; }
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) sandbox_die "no nhm release for $(uname -m)"; return 1 ;;
    esac
    asset="nhm-$ver-linux-$arch.tar.zst"
    base="https://github.com/arosl/nhm/releases/download/v$ver"
    sums="$SANDBOX_ROOT/dl/SHA256SUMS-$ver"
    curl -fsSL --proto '=https' -o "$sums" "$base/SHA256SUMS" || { sandbox_die "could not fetch $base/SHA256SUMS"; return 1; }
    curl -fsSL --proto '=https' -o "$SANDBOX_ROOT/dl/$asset" "$base/$asset" || { sandbox_die "could not fetch $base/$asset"; return 1; }
    want="$(awk -v a="$asset" '$2 == a { print $1 }' "$sums")"
    got="$(sha256sum "$SANDBOX_ROOT/dl/$asset" | awk '{ print $1 }')"
    [[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] || { sandbox_die "$asset does not match SHA256SUMS"; return 1; }
    dest="$SANDBOX_HOME/.local/share/nhm/releases/$ver"
    mkdir -p "$dest" || return 1
    tar --zstd -xf "$SANDBOX_ROOT/dl/$asset" -C "$dest" --strip-components=1 || return 1
    ln -sfn "$dest/nhm" "$SANDBOX_BIN/nhm" || return 1
    ln -sfn "$dest/nhm-hook" "$SANDBOX_BIN/nhm-hook" || return 1
}

sandbox_nhm_build() {
    local dir="${1:-}" b
    [[ -n "${SANDBOX_ROOT:-}" ]] || { sandbox_die "sandbox_nhm_build: run sandbox_init first"; return 1; }
    for b in nhm nhm-hook; do
        [[ -x "$dir/$b" ]] || { sandbox_die "sandbox_nhm_build: no $dir/$b"; return 1; }
        cp -f "$dir/$b" "$SANDBOX_BIN/$b" || return 1
    done
}

# The live herdr socket, resolved, so the inside can refuse to be it.
sandbox_live_socket() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    local live="${HERDR_SOCKET_PATH:-$cfg/herdr/herdr.sock}"
    realpath -m "$live"
}

sandbox_exec() {
    [[ -n "${SANDBOX_ROOT:-}" ]] || { sandbox_die "sandbox_exec: run sandbox_init first"; return 1; }
    (($# > 0)) || { sandbox_die "sandbox_exec: give a command"; return 1; }
    local real_home live args=() i
    real_home="$(realpath -m "$HOME")"
    live="$(sandbox_live_socket)"
    args=(--ro-bind / / --dev /dev --proc /proc
        --tmpfs "$real_home" --tmpfs /tmp --tmpfs /run/user
        --bind "$SANDBOX_ROOT" "$SANDBOX_ROOT")
    for ((i = 0; i < ${#SANDBOX_BINDS[@]}; i += 2)); do
        args+=(--ro-bind "${SANDBOX_BINDS[i]}" "${SANDBOX_BINDS[i + 1]}")
    done
    args+=(--unshare-net --unshare-pid --unshare-ipc --die-with-parent --new-session --clearenv
        --setenv HOME "$SANDBOX_HOME"
        --setenv USER "${USER:-sandbox}" --setenv LOGNAME "${USER:-sandbox}"
        --setenv SHELL /bin/bash --setenv TERM xterm-256color --setenv LANG C.UTF-8
        --setenv PATH "$SANDBOX_BIN:/usr/bin:/bin"
        --setenv TMPDIR "$SANDBOX_ROOT/tmp"
        --setenv XDG_CONFIG_HOME "$SANDBOX_HOME/.config"
        --setenv XDG_STATE_HOME "$SANDBOX_HOME/.local/state"
        --setenv XDG_DATA_HOME "$SANDBOX_HOME/.local/share"
        --setenv XDG_CACHE_HOME "$SANDBOX_HOME/.cache"
        --setenv XDG_RUNTIME_DIR "$SANDBOX_ROOT/run"
        --setenv CLAUDE_CONFIG_DIR "$SANDBOX_HOME/.claude"
        --setenv CODEX_HOME "$SANDBOX_HOME/.codex"
        --setenv HERDR_CONFIG_PATH "$SANDBOX_HOME/.config/herdr/config.toml"
        --setenv HERDR_SOCKET_PATH "$SANDBOX_HOME/.config/herdr/herdr.sock"
        --setenv ANTHROPIC_BASE_URL "$SANDBOX_NO_API"
        --setenv OPENAI_BASE_URL "$SANDBOX_NO_API/v1"
        --setenv ANTHROPIC_API_KEY "$SANDBOX_MOCK_KEY"
        --setenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1
        --setenv DISABLE_AUTOUPDATER 1
        --setenv SANDBOX_INSIDE 1
        --setenv SANDBOX_ROOT "$SANDBOX_ROOT"
        --setenv SANDBOX_HOME "$SANDBOX_HOME"
        --setenv SANDBOX_BIN "$SANDBOX_BIN"
        --setenv SANDBOX_EVIDENCE "$SANDBOX_EVIDENCE"
        --setenv SANDBOX_LIVE_SOCKET "$live"
        --setenv SANDBOX_LIB "$SANDBOX_LIB_DIR/nhm_sandbox.sh")
    [[ -z "${NHM_SANDBOX_MOCK:-}" ]] || args+=(--setenv NHM_SANDBOX_MOCK "$NHM_SANDBOX_MOCK")
    bwrap "${args[@]}" "$@"
}

# ---- inside the sandbox ----

sandbox_inside_check() {
    [[ "${SANDBOX_INSIDE:-}" == 1 ]] || { sandbox_die "$1: run it inside sandbox_exec"; return 1; }
}

sandbox_herdr_start() {
    sandbox_inside_check sandbox_herdr_start || return 1
    local sock live
    sock="$(realpath -m "$HERDR_SOCKET_PATH")"
    live="${SANDBOX_LIVE_SOCKET:-}"
    if [[ -z "$live" || "$sock" == "$live" || "$sock" != "$SANDBOX_HOME"/* ]]; then
        sandbox_die "refusing: herdr socket $sock is the live one or outside the sandbox"
        return 1
    fi
    if [[ -e "$live" ]]; then
        sandbox_die "refusing: the live socket $live is visible inside the sandbox"
        return 1
    fi
    command -v herdr >/dev/null 2>&1 || { sandbox_die "no herdr in the sandbox (sandbox_bin herdr)"; return 1; }
    mkdir -p "$(dirname "$sock")" || return 1
    herdr server >"$SANDBOX_EVIDENCE/herdr-server.out" 2>&1 &
    SANDBOX_HERDR_PID=$!
    local _
    for _ in $(seq 1 100); do
        if [[ -S "$sock" ]] && herdr workspace list >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$SANDBOX_HERDR_PID" 2>/dev/null || break
        sleep 0.1
    done
    sandbox_die "the sandbox herdr server did not come up (see $SANDBOX_EVIDENCE/herdr-server.out)"
    return 1
}

sandbox_herdr_stop() {
    sandbox_inside_check sandbox_herdr_stop || return 1
    herdr server stop >/dev/null 2>&1 || true
    if [[ -n "${SANDBOX_HERDR_PID:-}" ]]; then
        wait "$SANDBOX_HERDR_PID" 2>/dev/null || true
        SANDBOX_HERDR_PID=""
    fi
}

sandbox_mock_start() {
    sandbox_inside_check sandbox_mock_start || return 1
    local script="${1:-}" ready="$SANDBOX_EVIDENCE/mock.ready" url args=()
    local mock="${NHM_SANDBOX_MOCK:-$SANDBOX_LIB_DIR/mock_anthropic.py}"
    args=(--ready "$ready" --log "$SANDBOX_EVIDENCE/mock-requests.jsonl")
    [[ -z "$script" ]] || args+=(--script "$script")
    rm -f "$ready"
    python3 -I "$mock" "${args[@]}" >"$SANDBOX_EVIDENCE/mock.out" 2>&1 &
    SANDBOX_MOCK_PID=$!
    local _
    for _ in $(seq 1 100); do
        url="$(jq -r '.url // empty' "$ready" 2>/dev/null)"
        if [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then
            # Claude reads the Messages API from here; Codex reads the
            # Responses API through its config.toml (sandbox_codex_prepare).
            export ANTHROPIC_BASE_URL="$url" ANTHROPIC_API_KEY="$SANDBOX_MOCK_KEY" SANDBOX_MOCK_URL="$url"
            return 0
        fi
        kill -0 "$SANDBOX_MOCK_PID" 2>/dev/null || break
        sleep 0.1
    done
    sandbox_die "the mock API did not come up (see $SANDBOX_EVIDENCE/mock.out)"
    return 1
}

# sandbox_claude_prepare DIR: Claude Code's first-run state in the sandbox
# HOME, as experiment 4 needed it: onboarding done, the mock key approved
# (Claude keeps its last 20 characters), DIR trusted, and the
# skip-permissions mode accepted. No dialog is then left to answer.
sandbox_claude_prepare() {
    sandbox_inside_check sandbox_claude_prepare || return 1
    local dir="${1:-}" version
    [[ -d "$dir" ]] || { sandbox_die "sandbox_claude_prepare: no directory '$dir'"; return 1; }
    dir="$(realpath -e "$dir")" || return 1
    version="$(claude --version 2>/dev/null | awk 'NR == 1 { print $1 }')"
    jq -n --arg dir "$dir" --arg key "${SANDBOX_MOCK_KEY: -20}" --arg v "${version:-0}" '{
        hasCompletedOnboarding: true, lastOnboardingVersion: $v,
        bypassPermissionsModeAccepted: true,
        customApiKeyResponses: {approved: [$key], rejected: []},
        projects: {($dir): {hasTrustDialogAccepted: true}}
    }' >"$CLAUDE_CONFIG_DIR/.claude.json"
}

# sandbox_codex_prepare DIR: Codex's config.toml in the sandbox
# CODEX_HOME, pointing it at the mock's Responses API (as experiment 3
# ran Codex 0.162), with DIR trusted. Run it after sandbox_mock_start.
sandbox_codex_prepare() {
    sandbox_inside_check sandbox_codex_prepare || return 1
    local dir="${1:-}"
    [[ -d "$dir" ]] || { sandbox_die "sandbox_codex_prepare: no directory '$dir'"; return 1; }
    [[ -n "${SANDBOX_MOCK_URL:-}" ]] || { sandbox_die "sandbox_codex_prepare: start the mock first"; return 1; }
    dir="$(realpath -e "$dir")" || return 1
    cat >"$CODEX_HOME/config.toml" <<EOF
model = "mock-model"
model_provider = "mock"
approval_policy = "never"
check_for_update_on_startup = false

[model_providers.mock]
name = "mock"
base_url = "$SANDBOX_MOCK_URL/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false

[projects."$dir"]
trust_level = "trusted"
EOF
}

sandbox_mail_start() {
    sandbox_inside_check sandbox_mail_start || return 1
    command -v am >/dev/null 2>&1 || { sandbox_die "no am in the sandbox (sandbox_bin am)"; return 1; }
    # Its storage is under the sandbox HOME; its port is the sandbox's
    # own lo, never the live server's.
    am serve-http --host 127.0.0.1 --port 8765 --no-tui --no-auth >"$SANDBOX_EVIDENCE/agent-mail.out" 2>&1 &
    SANDBOX_MAIL_PID=$!
    export AGENT_MAIL_URL="http://127.0.0.1:8765/mcp/"
    local _
    for _ in $(seq 1 100); do
        if python3 -I -c 'import sys,urllib.request; urllib.request.urlopen(sys.argv[1], timeout=1)' \
            "http://127.0.0.1:8765/health/liveness" 2>/dev/null; then
            return 0
        fi
        kill -0 "$SANDBOX_MAIL_PID" 2>/dev/null || break
        sleep 0.1
    done
    sandbox_die "the sandbox Agent Mail did not come up (see $SANDBOX_EVIDENCE/agent-mail.out)"
    return 1
}

sandbox_mail_stop() {
    sandbox_inside_check sandbox_mail_stop || return 1
    if [[ -n "${SANDBOX_MAIL_PID:-}" ]]; then
        kill "$SANDBOX_MAIL_PID" 2>/dev/null || true
        wait "$SANDBOX_MAIL_PID" 2>/dev/null || true
        SANDBOX_MAIL_PID=""
    fi
}

sandbox_mock_stop() {
    sandbox_inside_check sandbox_mock_stop || return 1
    if [[ -n "${SANDBOX_MOCK_PID:-}" ]]; then
        kill "$SANDBOX_MOCK_PID" 2>/dev/null || true
        wait "$SANDBOX_MOCK_PID" 2>/dev/null || true
        SANDBOX_MOCK_PID=""
    fi
}
