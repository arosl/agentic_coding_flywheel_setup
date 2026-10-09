#!/usr/bin/env bash
# ============================================================
# ACFS Services — Unified background daemon management
# Manages Agent Mail, CM serve, and the CASS indexer as systemd user
# services. Agent Mail reuses the native agent-mail.service when it is
# installed; otherwise ACFS runs it in its own acfs-agent-mail.service.
#
# Usage:
#   acfs services start       Start all services (repairs a partial group)
#   acfs services stop        Stop all services
#   acfs services status      Show which services are running
#   acfs services restart [svc...]  Restart everything, or just named services
#   acfs services repair      Restart only the services that are not running
#   acfs services drift       Report services running a replaced binary
#   acfs services logs [svc]  Follow a service's journal
#
# Services and their units (in ~/.config/systemd/user):
#   agent-mail: agent-mail.service (native), or acfs-agent-mail.service
#   cm:         acfs-cm.service          (cm serve)
#   cass:       acfs-cass-index.service  (cass index --watch)
#
# `start` writes the units and enables them, so they restart after a crash
# and come back after a reboot (the installer enables linger). Older ACFS
# ran cm and cass in a tmux session named "acfs-svc"; `start` stops that
# session once so its processes release their ports.
# ============================================================

set -euo pipefail

# --- Constants ---
readonly ACFS_LEGACY_TMUX_SESSION="acfs-svc"
readonly ACFS_SVC_VERSION="2.0.0"

# --- HTTP service endpoints ---
# Both `am serve-http` and `cm serve` default to 127.0.0.1:8765, so launching
# them together makes the second one fail to bind ("address already in use").
# Agent Mail's managed ACFS service owns 8765. Move CM to 8766, matching the
# manifest, installer, doctor checks, README, and the original command contract.
readonly ACFS_DEFAULT_AGENT_MAIL_HOST="127.0.0.1"
readonly ACFS_DEFAULT_AGENT_MAIL_PORT="8765"
readonly ACFS_DEFAULT_CM_HOST="127.0.0.1"
readonly ACFS_DEFAULT_CM_PORT="8766"

ACFS_AGENT_MAIL_HOST="${ACFS_AGENT_MAIL_HOST:-$ACFS_DEFAULT_AGENT_MAIL_HOST}"
ACFS_AGENT_MAIL_PORT="${ACFS_AGENT_MAIL_PORT:-$ACFS_DEFAULT_AGENT_MAIL_PORT}"
ACFS_CM_HOST="${ACFS_CM_HOST:-$ACFS_DEFAULT_CM_HOST}"
ACFS_CM_PORT="${ACFS_CM_PORT:-$ACFS_DEFAULT_CM_PORT}"

readonly -a ACFS_SERVICE_NAMES=("agent-mail" "cm" "cass")
readonly ACFS_NATIVE_AGENT_MAIL_UNIT="agent-mail.service"

# --- State ---
_DRY_RUN=false
_LEGACY_SESSION_STOPPED=false
_TMUX_BIN=""
_CURL_BIN=""
_SS_BIN=""
_LSOF_BIN=""
_SYSTEMCTL_BIN=""
_JOURNALCTL_BIN=""
_AM_BIN=""
_CM_BIN=""
_CASS_BIN=""

# --- Colors (degrade gracefully) ---
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    _C_RESET=$'\033[0m'
    _C_BOLD=$'\033[1m'
    _C_GREEN=$'\033[32m'
    _C_RED=$'\033[31m'
    _C_YELLOW=$'\033[33m'
    _C_CYAN=$'\033[36m'
    _C_DIM=$'\033[2m'
else
    _C_RESET="" _C_BOLD="" _C_GREEN="" _C_RED="" _C_YELLOW="" _C_CYAN="" _C_DIM=""
fi

# --- Helpers ---

_info()  { printf '%s[acfs-services]%s %s\n' "$_C_CYAN" "$_C_RESET" "$*" >&2; }
_ok()    { printf '%s[acfs-services]%s %s%s%s\n' "$_C_CYAN" "$_C_RESET" "$_C_GREEN" "$*" "$_C_RESET" >&2; }
_warn()  { printf '%s[acfs-services]%s %s%s%s\n' "$_C_CYAN" "$_C_RESET" "$_C_YELLOW" "$*" "$_C_RESET" >&2; }
_err()   { printf '%s[acfs-services]%s %s%s%s\n' "$_C_CYAN" "$_C_RESET" "$_C_RED" "$*" "$_C_RESET" >&2; }

# System tools are resolved from fixed directories, never from PATH.
# ACFS_SERVICES_SYSTEM_BIN_PREFIX (tests only) names one directory searched
# first, so a test can put stub systemctl/curl/lsof in front of the real ones
# and never reach the host's user service manager. It is honoured only for an
# absolute directory owned by this user that neither group nor others can
# write; anything else is ignored.
_system_bin_prefix_trusted() {
    local dir="${ACFS_SERVICES_SYSTEM_BIN_PREFIX:-}"
    local perms=""

    [[ -n "$dir" && "$dir" == /* && -d "$dir" && -O "$dir" ]] || return 1
    [[ -x /usr/bin/stat ]] || return 1
    perms="$(/usr/bin/stat -c '%a' "$dir" 2>/dev/null || true)"
    [[ "$perms" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$perms & 8#022) == 0 ))
}

_system_binary_path() {
    local name="${1:-}"
    local dir=""
    local -a dirs=()

    [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    _system_bin_prefix_trusted && dirs+=("$ACFS_SERVICES_SYSTEM_BIN_PREFIX")
    dirs+=(/usr/bin /bin /usr/sbin /sbin /usr/local/bin /usr/local/sbin /opt/homebrew/bin)
    for dir in "${dirs[@]}"; do
        if [[ -x "$dir/$name" && ! -d "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

# Directories ACFS installs user-scoped tools into, in resolution order.
# `acfs services` is routinely invoked from a noninteractive SSH command whose
# PATH does not include them (#382), so PATH alone must not decide whether a
# managed binary exists.
_user_install_dirs() {
    local home_dir="${HOME:-}"
    local dir=""
    local -a dirs=()

    [[ -n "${ACFS_BIN_DIR:-}" ]] && dirs+=("$ACFS_BIN_DIR")
    if [[ -n "$home_dir" && "$home_dir" == /* ]]; then
        dirs+=("$home_dir/.local/bin" "$home_dir/.acfs/bin" "$home_dir/.cargo/bin" "$home_dir/bin")
    fi
    dirs+=("/usr/local/bin" "/opt/homebrew/bin")

    for dir in "${dirs[@]}"; do
        [[ -n "$dir" && "$dir" == /* ]] || continue
        printf '%s\n' "$dir"
    done
}

_user_binary_path() {
    local name="${1:-}"
    local resolved=""
    local dir=""

    [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    resolved="$(type -P "$name" 2>/dev/null || true)"
    if [[ -n "$resolved" && "$resolved" == /* && -x "$resolved" && ! -d "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi

    # PATH did not resolve it: fall back to the known ACFS install locations.
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ -x "$dir/$name" && ! -d "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done < <(_user_install_dirs)
    return 1
}

_initialize_bins() {
    _TMUX_BIN="$(_system_binary_path tmux 2>/dev/null || _user_binary_path tmux 2>/dev/null || true)"
    _CURL_BIN="$(_system_binary_path curl 2>/dev/null || true)"
    _SS_BIN="$(_system_binary_path ss 2>/dev/null || true)"
    _LSOF_BIN="$(_system_binary_path lsof 2>/dev/null || true)"
    _SYSTEMCTL_BIN="$(_system_binary_path systemctl 2>/dev/null || true)"
    _JOURNALCTL_BIN="$(_system_binary_path journalctl 2>/dev/null || true)"
    _AM_BIN="$(_user_binary_path am 2>/dev/null || true)"
    _CM_BIN="$(_user_binary_path cm 2>/dev/null || true)"
    _CASS_BIN="$(_user_binary_path cass 2>/dev/null || true)"
}

_service_desc() {
    case "$1" in
        agent-mail) printf '%s\n' "Agent Mail HTTP server" ;;
        cm)         printf '%s\n' "CASS Memory server" ;;
        cass)       printf '%s\n' "CASS indexer (watch mode)" ;;
        *)          return 1 ;;
    esac
}

# The command line a service runs, one argument per line.
_service_argv() {
    case "$1" in
        agent-mail)
            printf '%s\n' "$_AM_BIN" serve-http --no-tui --host "$ACFS_AGENT_MAIL_HOST" --port "$ACFS_AGENT_MAIL_PORT"
            ;;
        cm)
            printf '%s\n' "$_CM_BIN" serve --host "$ACFS_CM_HOST" --port "$ACFS_CM_PORT"
            ;;
        cass)
            printf '%s\n' "$_CASS_BIN" index --watch
            ;;
        *)
            return 1
            ;;
    esac
}

# The command as one line for a unit's ExecStart and for messages. Every
# argument must be a plain word (absolute paths, flags, validated hosts and
# ports), so it needs no systemd quoting; anything else is refused.
_service_cmd() {
    local service="$1"
    local arg="" line=""
    local -a argv=()

    mapfile -t argv < <(_service_argv "$service") || return 1
    ((${#argv[@]})) || return 1
    for arg in "${argv[@]}"; do
        if [[ -z "$arg" || ! "$arg" =~ ^[A-Za-z0-9._:/+=-]+$ ]]; then
            _err "Refusing to put '$arg' in a systemd unit for $service: only plain paths and words are allowed."
            return 1
        fi
        line+="${line:+ }$arg"
    done
    [[ "${argv[0]}" == /* ]] || { _err "The $service binary path '${argv[0]}' is not absolute."; return 1; }
    printf '%s\n' "$line"
}

# --- systemd user units ---

_unit_dir() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
}

# The ACFS-owned unit for a service. Agent Mail's native unit is not ours;
# acfs-agent-mail.service is only used when that native unit is missing.
_unit_name() {
    case "$1" in
        agent-mail) printf '%s\n' "acfs-agent-mail.service" ;;
        cm)         printf '%s\n' "acfs-cm.service" ;;
        cass)       printf '%s\n' "acfs-cass-index.service" ;;
        *)          return 1 ;;
    esac
}

_systemctl_user() {
    "$_SYSTEMCTL_BIN" --user "$@"
}

_systemd_user_available() {
    [[ -n "$_SYSTEMCTL_BIN" ]] || return 1
    _systemctl_user show-environment >/dev/null 2>&1
}

_require_systemd_user() {
    _systemd_user_available && return 0
    _err "acfs services needs a systemd user manager ('systemctl --user'), and none is reachable."
    if [[ -z "$_SYSTEMCTL_BIN" ]]; then
        _err "systemctl is not installed."
    fi
    _err "On WSL, enable systemd in /etc/wsl.conf ([boot] systemd=true) and restart WSL."
    _err "Over SSH as another user, log in as that user so it has a user session (the installer enables linger)."
    _err "Without systemd, run the services yourself: $(_service_argv cm | tr '\n' ' ')and $(_service_argv cass | tr '\n' ' ')"
    return 1
}

_unit_text() {
    local service="$1"
    local exec_line="" desc=""

    exec_line="$(_service_cmd "$service")" || return 1
    desc="$(_service_desc "$service")" || return 1
    cat <<EOF
# Written by 'acfs services start' (acfs-services.sh $ACFS_SVC_VERSION). Rewritten on
# every start; edit ACFS_* settings instead, then run 'acfs services start'.
[Unit]
Description=ACFS $desc
# Give up after 5 failed starts in 2 minutes (e.g. a port held by another
# process) instead of crash-looping; 'acfs services repair' clears it.
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$exec_line
Restart=on-failure
RestartSec=5
Environment=PATH=%h/.acfs/bin:%h/.local/bin:%h/.cargo/bin:%h/.bun/bin:%h/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=%h

[Install]
WantedBy=default.target
EOF
}

# Write a service's unit when its content changed. Sets _UNIT_CHANGED.
_UNIT_CHANGED=false
_write_unit() {
    local service="$1"
    local unit="" dir="" path="" text="" tmp=""

    _UNIT_CHANGED=false
    unit="$(_unit_name "$service")" || return 1
    text="$(_unit_text "$service")" || return 1
    dir="$(_unit_dir)"
    path="$dir/$unit"

    if [[ -f "$path" ]] && [[ "$(cat "$path" 2>/dev/null || true)" == "$text" ]]; then
        return 0
    fi
    mkdir -p "$dir" || { _err "Cannot create $dir"; return 1; }
    tmp="$(mktemp "$dir/.$unit.XXXXXX")" || { _err "Cannot write to $dir"; return 1; }
    if ! printf '%s\n' "$text" > "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        _err "Failed to write $path"
        return 1
    fi
    _UNIT_CHANGED=true
}

_unit_file_exists() {
    local unit=""
    unit="$(_unit_name "$1")" || return 1
    [[ -f "$(_unit_dir)/$unit" ]]
}

_unit_is_active() {
    _systemctl_user is-active --quiet "$1" >/dev/null 2>&1
}

_unit_main_pid() {
    local pid=""
    pid="$(_systemctl_user show "$1" -p MainPID --value 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) || return 1
    printf '%s\n' "$pid"
}

# Is this managed service's own ACFS unit running?
_service_unit_active() {
    local unit=""
    unit="$(_unit_name "$1")" || return 1
    _unit_is_active "$unit"
}

# --- Endpoint validation ---

# Validate a value is a usable TCP port (1-65535).
_is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

_is_valid_host() {
    local host="$1"
    [[ -n "$host" && "$host" =~ ^[A-Za-z0-9._:-]+$ ]]
}

_hosts_overlap() {
    local left="$1" right="$2"

    [[ "$left" == "$right" ]] && return 0
    case "$left" in
        0.0.0.0|\*|::) return 0 ;;
    esac
    case "$right" in
        0.0.0.0|\*|::) return 0 ;;
    esac
    [[ "$left" == "localhost" && ( "$right" == "127.0.0.1" || "$right" == "::1" ) ]] && return 0
    [[ "$right" == "localhost" && ( "$left" == "127.0.0.1" || "$left" == "::1" ) ]]
}

# Return 0 if something is already listening on host:port, 1 if free,
# 2 if we have no tool to check (treated as "free" by callers).
_port_is_listening() {
    local host="$1" port="$2"
    local socket_addr=""
    local bound_host=""

    if [[ -n "$_LSOF_BIN" ]]; then
        "$_LSOF_BIN" -nP "-iTCP@${host}:${port}" -sTCP:LISTEN &>/dev/null
        return $?
    elif [[ -n "$_SS_BIN" ]]; then
        while IFS= read -r socket_addr; do
            [[ -n "$socket_addr" ]] || continue
            bound_host="${socket_addr%:$port}"
            bound_host="${bound_host#[}"
            bound_host="${bound_host%]}"
            if _hosts_overlap "$host" "$bound_host"; then
                return 0
            fi
        done < <("$_SS_BIN" -H -ltn "sport = :$port" 2>/dev/null | while read -r _ _ _ local_address _; do printf '%s\n' "$local_address"; done)
        return 1
    fi
    return 2
}

_http_url_host() {
    local host="$1"
    if [[ "$host" == *:* ]]; then
        printf '[%s]\n' "$host"
    else
        printf '%s\n' "$host"
    fi
}

# Returns: 0 = alive and ready; 1 = down (liveness failed); 2 = alive but
# readiness not confirmed. Liveness stays on a tight 3s timeout, while the
# readiness probe gets 10s -- a busy Agent Mail (e.g. SQLite maintenance)
# can legitimately take >3s to answer readiness without being down (#362).
_agent_mail_is_healthy() {
    local url_host=""
    local readiness_body=""
    local readiness_path=""

    [[ -n "$_CURL_BIN" ]] || return 1
    url_host="$(_http_url_host "$ACFS_AGENT_MAIL_HOST")"
    "$_CURL_BIN" -fsS --max-time 3 \
        "http://${url_host}:${ACFS_AGENT_MAIL_PORT}/health/liveness" >/dev/null 2>&1 || return 1

    for readiness_path in /health/readiness /health; do
        readiness_body="$("$_CURL_BIN" -fsS --max-time 10 \
            "http://${url_host}:${ACFS_AGENT_MAIL_PORT}${readiness_path}" 2>/dev/null)" || continue
        if [[ "$readiness_body" =~ \"status\"[[:space:]]*:[[:space:]]*\"ready\"([[:space:]]*[,\}]) ]]; then
            return 0
        fi
    done
    return 2
}

_native_agent_mail_unit_available() {
    [[ "$ACFS_AGENT_MAIL_HOST" == "$ACFS_DEFAULT_AGENT_MAIL_HOST" ]] || return 1
    [[ "$ACFS_AGENT_MAIL_PORT" == "$ACFS_DEFAULT_AGENT_MAIL_PORT" ]] || return 1
    _systemd_user_available || return 1
    [[ "$(_systemctl_user show "$ACFS_NATIVE_AGENT_MAIL_UNIT" -p LoadState --value 2>/dev/null || true)" == "loaded" ]]
}

_native_agent_mail_is_active() {
    _native_agent_mail_unit_available || return 1
    _unit_is_active "$ACFS_NATIVE_AGENT_MAIL_UNIT"
}

# Once the native agent-mail.service exists, ACFS's own acfs-agent-mail.service
# (written while there was none) must not stay enabled: at the next boot both
# would race for the same port. Stop and disable it; the unit file stays.
_retire_acfs_agent_mail_unit() {
    local unit=""
    unit="$(_unit_name agent-mail)"

    _unit_file_exists agent-mail || return 0
    _unit_is_active "$unit" || \
        [[ "$(_systemctl_user is-enabled "$unit" 2>/dev/null || true)" == "enabled" ]] || return 0
    if $_DRY_RUN; then
        _info "[dry-run] Would stop and disable $unit: the native $ACFS_NATIVE_AGENT_MAIL_UNIT replaces it."
        return 0
    fi
    _info "The native $ACFS_NATIVE_AGENT_MAIL_UNIT is installed; stopping and disabling $unit."
    if ! _systemctl_user disable --now "$unit" >/dev/null 2>&1; then
        _err "Failed to disable $unit. Disable it yourself: systemctl --user disable --now $unit"
        return 1
    fi
    return 0
}

# Who runs Agent Mail here: native (its own agent-mail.service), acfs
# (acfs-agent-mail.service), or external (something else serves the port).
_agent_mail_owner() {
    if _native_agent_mail_is_active; then
        printf '%s\n' "native"
    elif _systemd_user_available && _service_unit_active agent-mail; then
        printf '%s\n' "acfs"
    else
        printf '%s\n' "external"
    fi
}

_wait_for_agent_mail() {
    local max_wait="${1:-15}"
    local waited=0

    while true; do
        _agent_mail_is_healthy && return 0
        (( waited >= max_wait )) && return 1
        sleep 1
        waited=$((waited + 1))
    done
}

# Static endpoint validation: host/port syntax and the Agent Mail / CM
# collision. Contains no live socket probing, so it is safe to run as a
# preflight while the services are still up (#382).
_validate_endpoint_config() {
    local rc=0
    local p
    local h

    for h in "ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_HOST" "ACFS_CM_HOST:$ACFS_CM_HOST"; do
        local host_name="${h%%:*}" host_value="${h#*:}"
        if ! _is_valid_host "$host_value"; then
            _err "$host_name='$host_value' is not a valid host name or IP address."
            rc=1
        fi
    done
    for p in "ACFS_AGENT_MAIL_PORT:$ACFS_AGENT_MAIL_PORT" "ACFS_CM_PORT:$ACFS_CM_PORT"; do
        local name="${p%%:*}" val="${p#*:}"
        if ! _is_valid_port "$val"; then
            _err "$name='$val' is not a valid TCP port (1-65535)."
            rc=1
        fi
    done
    (( rc )) && return 1

    if [[ "$ACFS_AGENT_MAIL_PORT" == "$ACFS_CM_PORT" ]] && \
       _hosts_overlap "$ACFS_AGENT_MAIL_HOST" "$ACFS_CM_HOST"; then
        _err "Agent Mail and CM resolve to the same endpoint ($ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT)."
        _err "They cannot share a port. Override with ACFS_AGENT_MAIL_PORT / ACFS_CM_PORT."
        return 1
    fi
    return 0
}

# Validate the resolved HTTP endpoints before starting anything. Fails fast
# (non-zero) with an actionable message on bad/duplicate/occupied ports so we
# never report "started" over a unit that cannot bind. A port held by our own
# running unit is expected and fine.
_validate_http_endpoints() {
    local rc=0

    _validate_endpoint_config || return 1

    # During --dry-run we only validate config, not live socket state.
    $_DRY_RUN && return 0

    # A healthy Agent Mail listener is the expected native-service state and is
    # reused. An unidentified listener on its endpoint remains a hard conflict.
    if _port_is_listening "$ACFS_AGENT_MAIL_HOST" "$ACFS_AGENT_MAIL_PORT" && \
       ! _agent_mail_is_healthy; then
        _err "$ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT is occupied by a service that is not a ready Agent Mail server."
        rc=1
    fi
    if ! _service_unit_active cm && _port_is_listening "$ACFS_CM_HOST" "$ACFS_CM_PORT"; then
        _err "$ACFS_CM_HOST:$ACFS_CM_PORT (CM) is already in use. Stop the other process or set ACFS_CM_PORT."
        rc=1
    fi
    return $rc
}

# --- Legacy tmux session (ACFS before acfs-rr2) ---

# True only for an "acfs-svc" session that older ACFS created: it tagged
# every service pane with the @acfs_service option. A user's own session
# that happens to share the name has no such pane and is left alone.
_legacy_session_exists() {
    local tag=""

    [[ -n "$_TMUX_BIN" ]] || return 1
    "$_TMUX_BIN" has-session -t "$ACFS_LEGACY_TMUX_SESSION" 2>/dev/null || return 1
    while IFS= read -r tag; do
        case "$tag" in
            agent-mail|cm|cass) return 0 ;;
        esac
    done < <("$_TMUX_BIN" list-panes -s -t "$ACFS_LEGACY_TMUX_SESSION" -F '#{@acfs_service}' 2>/dev/null || true)
    return 1
}

# Older ACFS ran cm, cass (and sometimes Agent Mail) in the "acfs-svc" tmux
# session. Stop exactly that session, so its processes release their ports
# before the units start. Other tmux sessions are never touched.
_stop_legacy_tmux_session() {
    local pane_id=""

    _legacy_session_exists || return 0
    if $_DRY_RUN; then
        _info "[dry-run] Would stop the old tmux session '$ACFS_LEGACY_TMUX_SESSION' (replaced by systemd units)."
        return 0
    fi
    _info "Stopping the old tmux session '$ACFS_LEGACY_TMUX_SESSION'; systemd units replace it."
    while IFS= read -r pane_id; do
        [[ -n "$pane_id" ]] || continue
        "$_TMUX_BIN" send-keys -t "$pane_id" C-c 2>/dev/null || true
    done < <("$_TMUX_BIN" list-panes -s -t "$ACFS_LEGACY_TMUX_SESSION" -F '#{pane_id}' 2>/dev/null || true)
    sleep 2
    if ! "$_TMUX_BIN" kill-session -t "$ACFS_LEGACY_TMUX_SESSION" 2>/dev/null; then
        _err "Failed to stop the old tmux session '$ACFS_LEGACY_TMUX_SESSION'."
        _err "Stop it yourself (tmux kill-session -t $ACFS_LEGACY_TMUX_SESSION), then re-run: acfs services start"
        return 1
    fi
    _LEGACY_SESSION_STOPPED=true
    return 0
}

# --- Binary preflight (issue #382) ---
#
# Every command that is about to stop or (re)launch a managed process proves
# the replacement binary can actually run FIRST. The verdict vocabulary matches
# the updater's post-install smoke check (issue #378):
#   healthy      -- a probe exited 0.
#   unsupported  -- the binary executed but rejected every probe as an unknown
#                   argument. Not a broken binary; never a reason to abort.
#   broken       -- the binary timed out, could not be executed (wrong
#                   architecture, missing loader), died by a signal, or failed
#                   every probe without a usage-style rejection.
_SMOKE_VERDICT=""
_SMOKE_DETAIL=""

_smoke_exit_status_is_fatal() {
    local status="${1:-0}"
    [[ "$status" =~ ^[0-9]+$ ]] || return 1
    ((status == 124 || status == 126 || status == 127 || status > 128))
}

_smoke_output_indicates_probe_rejected() {
    local output="${1:-}"
    local lowered=""
    # LC_ALL=C: probe output can contain bytes a UTF-8 tr rejects, and that
    # must never abort the caller under errexit.
    lowered="$(printf '%s' "$output" | LC_ALL=C tr '[:upper:]' '[:lower:]' 2>/dev/null || true)"
    case "$lowered" in
        *"usage:"*|*"usage :"*|*"unknown flag"*|*"unknown option"*|*"unknown command"*|\
        *"unknown argument"*|*"unknown subcommand"*|*"unexpected argument"*|\
        *"unrecognized argument"*|*"unrecognized option"*|*"unrecognised option"*|\
        *"no such option"*|*"no such command"*|*"invalid option"*|*"invalid flag"*|\
        *"illegal option"*|*"not a valid"*|*"try '"*"--help'"*|*"try \`"*"--help'"*)
            return 0 ;;
    esac
    return 1
}

_run_smoke_probe() {
    local binary="${1:-}"
    shift
    local timeout_bin=""

    timeout_bin="$(_system_binary_path timeout 2>/dev/null || true)"
    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" --kill-after=5s "${ACFS_SVC_SMOKE_TIMEOUT:-15}" \
            "$binary" "$@" </dev/null 2>&1
    else
        "$binary" "$@" </dev/null 2>&1
    fi
}

# Leaves the verdict in $_SMOKE_VERDICT and the human-readable reason in
# $_SMOKE_DETAIL (globals, so callers must not run this in a subshell).
# Returns 0 only for a healthy binary.
_binary_smoke_verdict() {
    local binary="${1:-}"
    local probe="" output="" status=0
    local all_rejected=true
    local -a attempts=()

    _SMOKE_VERDICT="broken"
    _SMOKE_DETAIL=""
    if [[ -z "$binary" || ! -f "$binary" || ! -x "$binary" ]]; then
        _SMOKE_DETAIL="binary missing or not executable"
        return 1
    fi

    for probe in "--version" "--help" "version"; do
        if output="$(_run_smoke_probe "$binary" "$probe")"; then
            status=0
        else
            status=$?
        fi
        output="${output:0:4096}"
        if ((status == 0)); then
            _SMOKE_VERDICT="healthy"
            _SMOKE_DETAIL="'$binary $probe' exited 0"
            return 0
        fi
        attempts+=("'$probe' exit $status")
        if _smoke_exit_status_is_fatal "$status"; then
            case "$status" in
                124) _SMOKE_DETAIL="'$binary $probe' timed out after ${ACFS_SVC_SMOKE_TIMEOUT:-15}s" ;;
                126) _SMOKE_DETAIL="'$binary' exists but cannot be executed (wrong architecture, missing loader, or not executable)" ;;
                127) _SMOKE_DETAIL="'$binary' could not be started (missing interpreter or shared library)" ;;
                *)   _SMOKE_DETAIL="'$binary $probe' was killed by a signal (exit $status)" ;;
            esac
            return 1
        fi
        _smoke_output_indicates_probe_rejected "$output" || all_rejected=false
    done

    local summary=""
    summary="$(printf '%s; ' "${attempts[@]}")"
    summary="${summary%; }"
    if [[ "$all_rejected" == "true" ]]; then
        _SMOKE_VERDICT="unsupported"
        _SMOKE_DETAIL="'$binary' executed but rejected every probe as an unknown argument ($summary)"
    else
        _SMOKE_VERDICT="broken"
        _SMOKE_DETAIL="'$binary' failed every probe without a usage-style rejection ($summary)"
    fi
    return 1
}

_service_binary_var() {
    case "${1:-}" in
        agent-mail) printf '%s\n' "$_AM_BIN" ;;
        cm)         printf '%s\n' "$_CM_BIN" ;;
        cass)       printf '%s\n' "$_CASS_BIN" ;;
        *)          return 1 ;;
    esac
}

_service_binary_name() {
    case "${1:-}" in
        agent-mail) printf '%s\n' "am" ;;
        cm)         printf '%s\n' "cm" ;;
        cass)       printf '%s\n' "cass" ;;
        *)          return 1 ;;
    esac
}

# Set by a full restart when Agent Mail runs in our own acfs-agent-mail unit:
# that process is about to be stopped, so the `am` binary IS required for the
# restart even though the endpoint is healthy right now.
_PREFLIGHT_AGENT_MAIL_WILL_STOP=false

# Does this service need its own binary launched by us? Agent Mail does not
# when the native user unit owns it, or when something other than our own
# acfs-agent-mail.service already serves it. When our unit serves it, `start`
# rewrites that unit, so `am` must resolve.
_service_needs_own_binary() {
    local service="${1:-}"
    [[ "$service" == "agent-mail" ]] || return 0
    $_PREFLIGHT_AGENT_MAIL_WILL_STOP && return 0
    _native_agent_mail_unit_available && return 1
    if _agent_mail_is_healthy && [[ "$(_agent_mail_owner)" != "acfs" ]]; then
        return 1
    fi
    return 0
}

# Validate one service's launch binary. Returns 1 only when the binary is
# missing or provably broken; an unsupported probe is reported and accepted.
_preflight_service_binary() {
    local service="${1:-}"
    local binary="" name="" verdict=""

    _service_needs_own_binary "$service" || return 0
    name="$(_service_binary_name "$service")" || return 1
    binary="$(_service_binary_var "$service")" || return 1

    if [[ -z "$binary" ]]; then
        if [[ "$service" == "agent-mail" ]]; then
            _err "Missing binary: am (needed for the Agent Mail fallback)"
        else
            _err "Missing binary: $name (needed for $service)"
        fi
        _err "Looked on PATH and in: $(_user_install_dirs | tr '\n' ' ')"
        return 1
    fi

    _binary_smoke_verdict "$binary" || true
    verdict="$_SMOKE_VERDICT"
    case "$verdict" in
        healthy) return 0 ;;
        unsupported)
            _warn "$name: ${_SMOKE_DETAIL}; treating it as runnable."
            return 0
            ;;
        *)
            _err "$name is not runnable: ${_SMOKE_DETAIL}"
            return 1
            ;;
    esac
}

# Preflight everything needed to launch the given services (default: all).
# Performs no live-state changes and probes no listening sockets, so callers
# can run it while the services are still up.
_preflight_services() {
    local -a targets=()
    local service=""
    local rc=0

    (($#)) && targets=("$@")
    ((${#targets[@]})) || targets=("${ACFS_SERVICE_NAMES[@]}")

    for service in "${targets[@]}"; do
        _preflight_service_binary "$service" || rc=1
    done

    if [[ -z "$_CURL_BIN" ]]; then
        _err "Missing system binary: curl (needed for health checks)"
        rc=1
    fi

    _validate_endpoint_config || rc=1
    return $rc
}

# --- Readiness ---

_service_is_running() {
    local service="$1"
    if [[ "$service" == "agent-mail" ]]; then
        _agent_mail_is_healthy
        return $?
    fi
    _service_unit_active "$service"
}

# Readiness for exactly one service, so a targeted repair or restart does not
# wait on (or fail because of) a service the operator did not touch.
_wait_for_service_ready() {
    local service="$1"
    local max_wait="${2:-15}"
    local waited=0

    if [[ "$service" == "agent-mail" ]]; then
        _wait_for_agent_mail "$max_wait"
        return $?
    fi

    while true; do
        if _service_unit_active "$service"; then
            if [[ "$service" != "cm" ]] || _port_is_listening "$ACFS_CM_HOST" "$ACFS_CM_PORT"; then
                return 0
            fi
        fi
        (( waited >= max_wait )) && return 1
        sleep 1
        waited=$((waited + 1))
    done
}

# --- Running-binary drift detection (issue #381) ---
#
# A tool update replaces the file on disk; the running service keeps executing
# the old (now deleted) inode until it is restarted. `cass --version` then
# reports the new release while the watcher still runs the old code. These
# helpers compare what the SERVICE actually executes against the installed
# binary ACFS resolves -- never against whatever the caller's PATH happens to
# find, because on a normal host those can legitimately differ.

_proc_fs_available() {
    [[ -d /proc/self && -r /proc/self/exe ]]
}

# Resolve /proc/<pid>/exe into the globals _EXE_PATH and _EXE_DELETED
# (globals, not stdout: a command substitution would discard the deleted flag).
# Returns 1 when the link cannot be read.
_EXE_PATH=""
_EXE_DELETED=false
_proc_exe_path() {
    local pid="$1"
    local link=""

    _EXE_PATH=""
    _EXE_DELETED=false
    link="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    [[ -n "$link" ]] || return 1
    if [[ "$link" == *" (deleted)" ]]; then
        _EXE_DELETED=true
        link="${link% (deleted)}"
    fi
    _EXE_PATH="$link"
    return 0
}

# Device:inode identity of a path, following symlinks. Empty when unknown.
_file_identity() {
    local path="$1"
    local stat_bin=""

    stat_bin="$(_system_binary_path stat 2>/dev/null || true)"
    [[ -n "$stat_bin" && -e "$path" ]] || return 1
    "$stat_bin" -Lc '%d:%i' "$path" 2>/dev/null || return 1
}

_file_sha256() {
    local path="$1"
    local bin=""
    local out=""

    bin="$(_system_binary_path sha256sum 2>/dev/null || true)"
    if [[ -n "$bin" ]]; then
        out="$("$bin" "$path" 2>/dev/null || true)"
    else
        bin="$(_system_binary_path shasum 2>/dev/null || true)"
        [[ -n "$bin" ]] || return 1
        out="$("$bin" -a 256 "$path" 2>/dev/null || true)"
    fi
    [[ -n "$out" ]] || return 1
    printf '%s\n' "${out%% *}"
}

_short_sha() {
    local path="$1"
    local sha=""

    sha="$(_file_sha256 "$path" 2>/dev/null || true)"
    [[ -n "$sha" ]] || { printf '%s\n' "unknown"; return 0; }
    printf '%s\n' "${sha:0:12}"
}

# Direct children of a pid, from procfs. Falls back to scanning /proc when the
# kernel does not expose the children file.
_child_pids() {
    local pid="$1"
    local children=""
    local stat_line=""
    local candidate=""
    local rest=""
    local ppid=""

    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
    if [[ -n "$children" ]]; then
        local child=""
        for child in $children; do
            printf '%s\n' "$child"
        done
        return 0
    fi

    for candidate in /proc/[0-9]*; do
        [[ -r "$candidate/stat" ]] || continue
        stat_line="$(cat "$candidate/stat" 2>/dev/null || true)"
        [[ -n "$stat_line" ]] || continue
        # Skip "pid (comm) " -- comm can contain spaces and parentheses.
        rest="${stat_line##*) }"
        # rest is now "state ppid ..."
        ppid="$(printf '%s\n' "$rest" | while read -r _state parent _; do printf '%s\n' "$parent"; break; done)"
        [[ "$ppid" == "$pid" ]] && printf '%s\n' "${candidate##*/}"
    done
    return 0
}

# Find the pid at or under $1 whose executable basename is $2 (depth-limited).
# A unit's MainPID is normally the binary itself; a wrapper (an interpreter
# running a script) puts it one level down.
_descendant_pid_for_binary() {
    local root_pid="$1"
    local want="$2"
    local -a queue=("$root_pid")
    local -a next=()
    local depth=0
    local pid="" exe="" child=""

    while ((${#queue[@]} && depth < 4)); do
        next=()
        for pid in "${queue[@]}"; do
            exe=""
            _proc_exe_path "$pid" 2>/dev/null && exe="$_EXE_PATH"
            if [[ -n "$exe" && "${exe##*/}" == "$want" ]]; then
                printf '%s\n' "$pid"
                return 0
            fi
            while IFS= read -r child; do
                [[ -n "$child" ]] && next+=("$child")
            done < <(_child_pids "$pid")
        done
        queue=("${next[@]+"${next[@]}"}")
        depth=$((depth + 1))
    done
    return 1
}

# Pid of the live process for one managed service, or nothing.
_service_process_pid() {
    local service="$1"
    local name="" unit="" main_pid=""

    name="$(_service_binary_name "$service")" || return 1
    _systemd_user_available || return 1

    if [[ "$service" == "agent-mail" ]] && _native_agent_mail_is_active; then
        _unit_main_pid "$ACFS_NATIVE_AGENT_MAIL_UNIT"
        return $?
    fi

    unit="$(_unit_name "$service")" || return 1
    _unit_is_active "$unit" || return 1
    main_pid="$(_unit_main_pid "$unit")" || return 1
    _descendant_pid_for_binary "$main_pid" "$name"
}

# Emits "<service>|<state>|<detail>" for one service.
#   ok           running the installed binary
#   stale        running a replaced/deleted/different executable
#   not-running  no live process
#   unknown      could not compare (no procfs, unreadable link, no installed
#                binary resolved)
_service_binary_drift() {
    local service="$1"
    local pid="" exe="" installed="" running_id="" installed_id=""
    local deleted=false

    # procfs first: without it we cannot even identify the service process, so
    # "no live process" would be a lie rather than an observation.
    if ! _proc_fs_available; then
        printf '%s|%s|%s\n' "$service" "unknown" "no procfs on this platform"
        return 0
    fi

    installed="$(_service_binary_var "$service" 2>/dev/null || true)"
    pid="$(_service_process_pid "$service" 2>/dev/null || true)"

    if [[ -z "$pid" ]]; then
        printf '%s|%s|%s\n' "$service" "not-running" "no live process"
        return 0
    fi
    if [[ -z "$installed" ]]; then
        printf '%s|%s|%s\n' "$service" "unknown" "no installed binary resolved for $service"
        return 0
    fi

    if ! _proc_exe_path "$pid" 2>/dev/null; then
        printf '%s|%s|%s\n' "$service" "unknown" "cannot read /proc/$pid/exe"
        return 0
    fi
    exe="$_EXE_PATH"
    deleted=$_EXE_DELETED

    if $deleted; then
        printf '%s|%s|%s\n' "$service" "stale" \
            "pid $pid runs a deleted executable ($exe); installed: $installed (sha256 $(_short_sha "$installed"))"
        return 0
    fi

    running_id="$(_file_identity "/proc/$pid/exe" 2>/dev/null || true)"
    installed_id="$(_file_identity "$installed" 2>/dev/null || true)"
    if [[ -z "$running_id" || -z "$installed_id" ]]; then
        printf '%s|%s|%s\n' "$service" "unknown" "cannot compare $exe with $installed"
        return 0
    fi
    if [[ "$running_id" == "$installed_id" ]]; then
        printf '%s|%s|%s\n' "$service" "ok" "pid $pid runs $installed"
        return 0
    fi

    printf '%s|%s|%s\n' "$service" "stale" \
        "pid $pid runs $exe (sha256 $(_short_sha "/proc/$pid/exe")); installed: $installed (sha256 $(_short_sha "$installed"))"
}

# Warn loudly about every managed service running something other than the
# installed binary. Returns 0 when everything is current, 1 when any service
# is running a stale executable.
_report_binary_drift() {
    local service="" line="" state="" detail=""
    local drift_found=false

    for service in "${ACFS_SERVICE_NAMES[@]}"; do
        line="$(_service_binary_drift "$service")"
        state="${line#*|}"
        detail="${state#*|}"
        state="${state%%|*}"
        [[ "$state" == "stale" ]] || continue
        if ! $drift_found; then
            printf '\n' >&2
            _warn "Running-binary drift: an updated tool is installed but the live service still runs the old executable."
            drift_found=true
        fi
        _warn "  $service: $detail"
        _warn "  Restart just this service: acfs services restart $service"
    done

    if $drift_found; then
        _warn "A restart interrupts that service; Agent Mail stays up unless you restart it too."
        _warn "Pick a quiescent moment: in-flight agent work in that service is cut off."
        printf '\n' >&2
        return 1
    fi
    return 0
}

cmd_drift() {
    local robot=false
    local service="" line="" state=""
    local rc=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --robot|--porcelain) robot=true; shift ;;
            "") shift ;;
            *)
                _err "Unknown option for 'drift': '$1'"
                _info "Usage: acfs services drift [--robot]"
                return 1
                ;;
        esac
    done

    _initialize_bins

    if $robot; then
        for service in "${ACFS_SERVICE_NAMES[@]}"; do
            line="$(_service_binary_drift "$service")"
            printf '%s\n' "$line"
            state="${line#*|}"
            [[ "${state%%|*}" == "stale" ]] && rc=1
        done
        return $rc
    fi

    if _report_binary_drift; then
        _ok "Every running ACFS-managed service is executing its installed binary."
    else
        rc=1
    fi
    return $rc
}

# --- Starting units ---

# Write, enable and start the given services' ACFS units. A unit whose text
# changed while it was running is restarted, so a moved binary or a new port
# takes effect.
_enable_service_units() {
    local service="" unit=""
    local -a units=() restart_units=()
    local reload=false

    for service in "$@"; do
        unit="$(_unit_name "$service")" || return 1
        local was_active=false
        _unit_is_active "$unit" && was_active=true
        _write_unit "$service" || return 1
        if $_UNIT_CHANGED; then
            reload=true
            $was_active && restart_units+=("$unit")
        fi
        units+=("$unit")
    done

    if $reload && ! _systemctl_user daemon-reload >/dev/null 2>&1; then
        _err "systemctl --user daemon-reload failed."
        return 1
    fi
    for unit in "${units[@]}"; do
        # A unit that crashed too often sits in "failed"; clear it so start works.
        _systemctl_user reset-failed "$unit" >/dev/null 2>&1 || true
    done
    if ! _systemctl_user enable --now "${units[@]}" >/dev/null 2>&1; then
        _err "Failed to enable and start: ${units[*]}"
        _err "Inspect with: systemctl --user status ${units[*]}"
        return 1
    fi
    if ((${#restart_units[@]})) && ! _systemctl_user restart "${restart_units[@]}" >/dev/null 2>&1; then
        _err "Failed to restart with the new unit settings: ${restart_units[*]}"
        return 1
    fi
    return 0
}

# --- Commands ---

cmd_start() {
    _initialize_bins
    _require_systemd_user || return 1

    # Pre-flight: every binary we are about to launch must exist and run
    # (issue #382). Endpoint syntax is validated here too.
    if ! _preflight_services; then
        _err "Cannot start services -- fix the problems above first."
        return 1
    fi

    _stop_legacy_tmux_session || return 1

    # Fail fast on bad/duplicate/occupied HTTP ports before starting anything.
    if ! _validate_http_endpoints; then
        if $_LEGACY_SESSION_STOPPED; then
            _err "The old tmux session '$ACFS_LEGACY_TMUX_SESSION' was already stopped, so cm and cass stay down until 'acfs services start' succeeds."
        fi
        return 1
    fi

    local agent_mail_own_unit=false
    if _native_agent_mail_unit_available; then
        _retire_acfs_agent_mail_unit || return 1
        if _agent_mail_is_healthy; then
            _info "Reusing healthy Agent Mail at $ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT ($(_agent_mail_owner))."
        elif $_DRY_RUN; then
            _info "[dry-run] Would start the native $ACFS_NATIVE_AGENT_MAIL_UNIT."
        else
            _info "Starting native Agent Mail user service..."
            if ! _systemctl_user start "$ACFS_NATIVE_AGENT_MAIL_UNIT" >/dev/null 2>&1 || \
               ! _wait_for_agent_mail 15; then
                _err "Agent Mail user service did not become ready."
                _err "Inspect it with: systemctl --user status $ACFS_NATIVE_AGENT_MAIL_UNIT"
                return 1
            fi
        fi
    elif _agent_mail_is_healthy && [[ "$(_agent_mail_owner)" != "acfs" ]]; then
        _info "Reusing healthy Agent Mail at $ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT (external)."
    else
        # No native unit: Agent Mail is ours. Passing it on rewrites a stale
        # acfs-agent-mail.service (moved am, new port); an unchanged running
        # unit is left alone.
        agent_mail_own_unit=true
    fi

    local -a services=("cm" "cass")
    if $agent_mail_own_unit; then
        services=("agent-mail" "${services[@]}")
    fi

    if $_DRY_RUN; then
        local service=""
        _info "[dry-run] Would write, enable and start these units in $(_unit_dir):"
        for service in "${services[@]}"; do
            _info "  $(_unit_name "$service"): $(_service_cmd "$service")"
        done
        return 0
    fi

    _info "Starting ACFS services as systemd user units..."
    _enable_service_units "${services[@]}" || return 1

    if ! _wait_for_agent_mail 15 || ! _wait_for_service_ready cm 15 || ! _wait_for_service_ready cass 15; then
        _err "One or more services failed readiness checks; their units were left running for diagnosis."
        cmd_status || true
        return 1
    fi

    _ok "All services are ready. They restart after a crash and start again after a reboot."
    _info "View logs: acfs services logs [agent-mail|cm|cass]"
}

# Converge toward ready: start Agent Mail if it is down, and start only the
# services whose units are not running (#383). With no arguments every
# managed service is considered; names narrow it down.
cmd_repair() {
    local -a targets=()
    local -a repaired=()
    local service="" unit=""
    local rc=0

    (($#)) && targets=("$@")

    _initialize_bins

    ((${#targets[@]})) || targets=("${ACFS_SERVICE_NAMES[@]}")
    for service in "${targets[@]}"; do  # never empty after the default above
        if ! _service_desc "$service" >/dev/null 2>&1; then
            _err "Unknown service: '$service'"
            _info "Available services: ${ACFS_SERVICE_NAMES[*]}"
            return 1
        fi
    done

    _require_systemd_user || return 1

    if ! _unit_file_exists cm && ! _unit_file_exists cass; then
        _err "The ACFS service units are not set up. Start with: acfs services start"
        return 1
    fi

    if $_DRY_RUN; then
        _info "[dry-run] Would start these services if they are not running: ${targets[*]}"
        return 0
    fi

    _validate_endpoint_config || return 1

    for service in "${targets[@]}"; do
        if [[ "$service" == "agent-mail" ]]; then
            if _native_agent_mail_unit_available; then
                _retire_acfs_agent_mail_unit || rc=1
                _agent_mail_is_healthy && continue
                repaired+=("agent-mail")
                _info "Starting native Agent Mail user service..."
                if ! _systemctl_user start "$ACFS_NATIVE_AGENT_MAIL_UNIT" >/dev/null 2>&1; then
                    _err "Agent Mail user service failed to start."
                    _err "Inspect it with: systemctl --user status $ACFS_NATIVE_AGENT_MAIL_UNIT"
                    rc=1
                fi
                continue
            fi
            # No native unit: Agent Mail runs in acfs-agent-mail.service,
            # unless something outside ACFS already serves it.
            _service_unit_active agent-mail && continue
            _agent_mail_is_healthy && continue
        elif _service_unit_active "$service"; then
            continue
        fi

        repaired+=("$service")
        unit="$(_unit_name "$service")"
        _preflight_service_binary "$service" || { rc=1; continue; }
        _info "Starting $unit..."
        _enable_service_units "$service" || rc=1
    done

    if ((${#repaired[@]} == 0)); then
        _info "Every ACFS-managed service is already running; nothing to repair."
        return $rc
    fi

    for service in "${repaired[@]}"; do
        if ! _wait_for_service_ready "$service" 15; then
            _err "$service did not pass its readiness check after being started; it was left running for diagnosis."
            rc=1
        fi
    done
    return $rc
}

cmd_stop() {
    _initialize_bins

    if $_DRY_RUN; then
        _info "[dry-run] Would stop the native Agent Mail service when active."
        _info "[dry-run] Would stop and disable the ACFS service units, and the old tmux session '$ACFS_LEGACY_TMUX_SESSION' when present."
        return 0
    fi

    local stopped_any=false
    local rc=0
    local service="" unit=""
    _info "Stopping ACFS services..."

    if _systemd_user_available; then
        if _native_agent_mail_is_active; then
            stopped_any=true
            if ! _systemctl_user stop "$ACFS_NATIVE_AGENT_MAIL_UNIT" >/dev/null 2>&1; then
                _err "Failed to stop native Agent Mail service."
                rc=1
            fi
        fi

        for service in "${ACFS_SERVICE_NAMES[@]}"; do
            unit="$(_unit_name "$service")"
            _unit_file_exists "$service" || continue
            _unit_is_active "$unit" && stopped_any=true
            # disable --now: stopped, and it stays stopped across a reboot.
            if ! _systemctl_user disable --now "$unit" >/dev/null 2>&1; then
                _err "Failed to stop $unit."
                rc=1
            fi
        done
    fi

    if _legacy_session_exists; then
        stopped_any=true
        _stop_legacy_tmux_session || rc=1
    fi

    if ! $stopped_any; then
        _info "No ACFS-managed services were running."
    elif (( rc == 0 )); then
        _ok "All ACFS-managed services stopped. They stay stopped until 'acfs services start'."
    fi

    if _agent_mail_is_healthy; then
        _warn "Agent Mail is still healthy but is not owned by an ACFS-managed unit; it was left untouched."
    fi
    return $rc
}

cmd_status() {
    _initialize_bins

    local rc=0
    local owner=""
    local systemd=true
    _systemd_user_available || systemd=false
    owner="$(_agent_mail_owner)"

    local am_health_rc=0
    _agent_mail_is_healthy || am_health_rc=$?
    if (( am_health_rc == 0 )); then
        printf '  %-12s  %sready%s    %s  (%s)\n' "agent-mail" "$_C_GREEN" "$_C_RESET" \
            "$ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT" "$owner"
    elif (( am_health_rc == 2 )); then
        printf '  %-12s  %salive, readiness slow%s  %s  (%s)\n' "agent-mail" "$_C_YELLOW" "$_C_RESET" \
            "$ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT" "$owner"
        rc=1
    else
        printf '  %-12s  %snot ready%s  %s\n' "agent-mail" "$_C_RED" "$_C_RESET" \
            "$ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT"
        rc=1
    fi

    if $systemd && _service_unit_active cm && \
       _port_is_listening "$ACFS_CM_HOST" "$ACFS_CM_PORT"; then
        printf '  %-12s  %sready%s    %s  (%s)\n' "cm" "$_C_GREEN" "$_C_RESET" \
            "$ACFS_CM_HOST:$ACFS_CM_PORT" "$(_unit_name cm)"
    else
        printf '  %-12s  %snot ready%s  %s\n' "cm" "$_C_RED" "$_C_RESET" \
            "$ACFS_CM_HOST:$ACFS_CM_PORT"
        rc=1
    fi

    if $systemd && _service_unit_active cass; then
        printf '  %-12s  %srunning%s          (%s)\n' "cass" "$_C_GREEN" "$_C_RESET" "$(_unit_name cass)"
    else
        printf '  %-12s  %snot running%s\n' "cass" "$_C_RED" "$_C_RESET"
        rc=1
    fi

    printf '\n'
    _info "Logs:   acfs services logs [agent-mail|cm|cass]"
    if ! $systemd; then
        _warn "No systemd user manager is reachable, so cm and cass cannot run as ACFS units here."
    fi
    if _legacy_session_exists; then
        _warn "The old tmux session '$ACFS_LEGACY_TMUX_SESSION' is still running; 'acfs services start' replaces it with systemd units."
    fi
    if (( rc != 0 )); then
        # Lifecycle contract (#196, documented per #360): "not running" can be
        # intentional. Say exactly what owns what and what the fix is.
        printf '\n'
        _info "Lifecycle: the installer does not start cm and cass; 'acfs services start' does."
        _info "Once started they are systemd user units: they restart after a crash and start again"
        _info "after a reboot, until 'acfs services stop'. Leaving cm/cass off is fine if you only"
        _info "use 'cm context'/'cm reflect' or are diagnosing indexing/resource problems."
    fi

    # A service can be perfectly "ready" and still be executing the binary an
    # update replaced days ago (#381). Say so; do not let readiness read green
    # while the shipped fix is not actually live.
    _report_binary_drift || true
    return $rc
}

# Restart exactly one service through its unit, so restarting cass never
# interrupts Agent Mail or CM.
_restart_one_service() {
    local service="$1"
    local unit=""

    if [[ "$service" == "agent-mail" ]] && _native_agent_mail_is_active; then
        _info "Restarting native Agent Mail user service..."
        if ! _systemctl_user restart "$ACFS_NATIVE_AGENT_MAIL_UNIT" >/dev/null 2>&1 || \
           ! _wait_for_agent_mail 15; then
            _err "Agent Mail user service did not become ready after restart."
            _err "Inspect it with: systemctl --user status $ACFS_NATIVE_AGENT_MAIL_UNIT"
            return 1
        fi
        return 0
    fi

    unit="$(_unit_name "$service")" || return 1
    if [[ "$service" == "agent-mail" ]] && ! _unit_is_active "$unit"; then
        _err "Agent Mail is not owned by ACFS here (no native unit, $unit not running); refusing to restart it."
        _err "Whatever serves $ACFS_AGENT_MAIL_HOST:$ACFS_AGENT_MAIL_PORT was started outside ACFS -- restart it there."
        return 1
    fi
    if ! _unit_file_exists "$service"; then
        _err "$unit is not set up. Start with: acfs services start"
        return 1
    fi

    # Rewrite the unit first, so a restart also picks up a moved binary.
    _write_unit "$service" || return 1
    if $_UNIT_CHANGED && ! _systemctl_user daemon-reload >/dev/null 2>&1; then
        _err "systemctl --user daemon-reload failed."
        return 1
    fi
    _systemctl_user reset-failed "$unit" >/dev/null 2>&1 || true
    if ! _systemctl_user restart "$unit" >/dev/null 2>&1; then
        _err "Failed to restart $unit. Inspect with: systemctl --user status $unit"
        return 1
    fi
    if ! _wait_for_service_ready "$service" 15; then
        _err "$service did not pass its readiness check after the restart."
        return 1
    fi
    return 0
}

cmd_restart() {
    local -a targets=()
    local service=""
    local rc=0
    local stop_rc=0

    (($#)) && targets=("$@")

    _initialize_bins

    for service in "${targets[@]+"${targets[@]}"}"; do
        if ! _service_desc "$service" >/dev/null 2>&1; then
            _err "Unknown service: '$service'"
            _info "Available services: ${ACFS_SERVICE_NAMES[*]}"
            return 1
        fi
    done

    _require_systemd_user || return 1

    # A full restart stops acfs-agent-mail.service too, so its binary must
    # preflight even though Agent Mail is healthy right now.
    if ((${#targets[@]} == 0)) && [[ "$(_agent_mail_owner)" == "acfs" ]]; then
        _PREFLIGHT_AGENT_MAIL_WILL_STOP=true
    fi

    # Preflight BEFORE anything is stopped (issue #382): a restart that cannot
    # resolve or run the replacement binaries must leave healthy services up.
    if ! _preflight_services "${targets[@]+"${targets[@]}"}"; then
        _err "Preflight failed: no service was stopped and nothing changed."
        _err "Fix the problems above, then re-run: acfs services restart${targets[*]:+ ${targets[*]}}"
        return 1
    fi

    if ((${#targets[@]})); then
        if $_DRY_RUN; then
            _info "[dry-run] Would restart: ${targets[*]}"
            return 0
        fi
        _info "Restarting ACFS services: ${targets[*]}"
        for service in "${targets[@]+"${targets[@]}"}"; do
            _restart_one_service "$service" || rc=1
        done
        cmd_status || true
        return $rc
    fi

    _info "Restarting ACFS services..."
    cmd_stop || stop_rc=$?
    if (( stop_rc != 0 )); then
        _err "Stop reported errors; not starting on top of an unknown state."
        _err "Inspect with 'acfs services status', then run 'acfs services start'."
        return "$stop_rc"
    fi
    if ! cmd_start; then
        rc=$?
        _err "Services were stopped but did not come back up (start exit $rc)."
        _err "Recover with: acfs services start   (after fixing the errors above)"
        return "$rc"
    fi
}

cmd_logs() {
    local target="${1:-}"
    local -a unit_args=()
    local service="" unit=""

    _initialize_bins

    if [[ -n "$target" ]]; then
        case "$target" in
            agent-mail|cm|cass) ;;
            *)
                _err "Unknown service: '$target'"
                _info "Available services: ${ACFS_SERVICE_NAMES[*]}"
                return 1
                ;;
        esac
    fi

    if [[ -z "$_JOURNALCTL_BIN" ]]; then
        _err "journalctl is unavailable, so the service logs cannot be shown."
        return 1
    fi

    for service in "${ACFS_SERVICE_NAMES[@]}"; do
        [[ -z "$target" || "$target" == "$service" ]] || continue
        if [[ "$service" == "agent-mail" ]] && _native_agent_mail_unit_available; then
            unit="$ACFS_NATIVE_AGENT_MAIL_UNIT"
        else
            unit="$(_unit_name "$service")"
            if [[ -n "$target" ]] && ! _unit_file_exists "$service"; then
                _err "$unit is not set up. Start with: acfs services start"
                return 1
            fi
        fi
        unit_args+=(-u "$unit")
    done

    if $_DRY_RUN; then
        _info "[dry-run] Would follow: journalctl --user ${unit_args[*]} -f"
        return 0
    fi
    exec "$_JOURNALCTL_BIN" --user "${unit_args[@]}" -f
}

# --- Usage ---

usage() {
    cat <<'EOF'
ACFS Services — Unified background daemon management

Usage: acfs services <command> [options]

Commands:
  start               Write the systemd user units and start every service.
                      Running services are left as they are, unless their
                      unit settings changed.
  stop                Stop all services; they stay stopped across reboots
  status              Show which services are running
  restart [service…]  Restart everything, or only the named services.
                      Binaries are validated before anything is stopped.
  repair              Start only the services that are not running
  drift [--robot]     Report managed services still executing a binary that
                      has since been replaced on disk
  logs [service]      Follow the services' journal (optionally one service)

Services managed:
  agent-mail      agent-mail.service (native) or acfs-agent-mail.service  [default 127.0.0.1:8765]
  cm              acfs-cm.service: cm serve (CASS Memory server)          [default 127.0.0.1:8766]
  cass            acfs-cass-index.service: cass index --watch

Agent Mail and CM both default to port 8765 upstream; ACFS assigns them
distinct ports so they don't collide. Override the defaults with:
  ACFS_AGENT_MAIL_HOST   (default 127.0.0.1)
  ACFS_AGENT_MAIL_PORT   (default 8765)
  ACFS_CM_HOST           (default 127.0.0.1)
  ACFS_CM_PORT           (default 8766)

Options:
  --dry-run       Show what would be done without doing it
  --help, -h      Show this help message

Examples:
  acfs services start              # Start all daemons (or repair a partial group)
  acfs services status             # Quick health check
  acfs services logs agent-mail    # Follow Agent Mail's log
  acfs services restart            # Restart everything
  acfs services restart cass       # Restart only CASS; Agent Mail stays up
  acfs services drift              # Are the live services on the installed binaries?
  acfs services stop               # Stop everything until the next start

The services are systemd user units in ~/.config/systemd/user. Once started
they restart after a crash and start again after a reboot. Agent Mail reuses
the native agent-mail.service when it is installed. Start and status return
nonzero unless every service passes its runtime readiness check.
EOF
}

# --- Main ---

main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    # Parse global flags
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) _DRY_RUN=true; shift ;;
            *)         args+=("$1"); shift ;;
        esac
    done

    # Also check if --dry-run was the first arg (before cmd)
    if [[ "$cmd" == "--dry-run" ]]; then
        _DRY_RUN=true
        cmd="${args[0]:-}"
        args=("${args[@]:1}")
    fi

    case "$cmd" in
        start)   cmd_start ;;
        stop)    cmd_stop ;;
        status)  cmd_status ;;
        restart) cmd_restart "${args[@]+"${args[@]}"}" ;;
        repair)  cmd_repair "${args[@]+"${args[@]}"}" ;;
        drift)   cmd_drift "${args[@]+"${args[@]}"}" ;;
        logs|log|attach)
            cmd_logs "${args[0]:-}" ;;
        help|-h|--help|"")
            usage ;;
        *)
            _err "Unknown command: '$cmd'"
            usage >&2
            return 1
            ;;
    esac
}

# Allow sourcing for testing without executing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${1:-}" == "--source-test" ]]; then
    if [[ "${1:-}" == "--source-test" ]]; then
        # Source-test mode: just validate syntax and function definitions
        shift
        if [[ $# -gt 0 ]]; then
            "$@"
        fi
    else
        main "$@"
    fi
fi
