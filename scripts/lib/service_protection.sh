#!/usr/bin/env bash
# ============================================================
# ACFS service protection: who the OOM killer and memory reclaim spare.
#
# Agents are the biggest processes on a swarm machine, so under memory
# pressure they must go first, and Agent Mail, herdr's server, cm and rchd
# last (acfs-ioo3.5, plan 3.2). Three user slices carry that:
#
#   acfs-services.slice    agent-mail, herdr's server, acfs-cm, rchd
#                          MemoryLow, OOMScoreAdjust 0 (-900 on a VM/VPS)
#   acfs-background.slice  acfs-cass-index: MemoryLow, OOMScoreAdjust 200
#   acfs-agents.slice      every agent, as a scope at oom_score_adj 500;
#                          systemd-oomd kills there at 40% memory pressure,
#                          or acfs-agents-pressure.service when oomd is off
#
# MemoryLow on a slice protects nothing unless every ancestor has it too, so
# apply-system puts it on user.slice, user-<uid>.slice and user@<uid>.service,
# and apply-user on acfs.slice, which the dash in the three names makes their
# parent (user@<uid>.service/acfs.slice/acfs-services.slice).
# Lowering an OOM score below the manager's floor needs CAP_SYS_RESOURCE in
# the initial user namespace: in an unprivileged container that is refused
# (and systemd ignores the failure), so -900 is only set outside one, where
# the user@<uid>.service drop-in lowers the floor first.
#
# Agents get into their slice through PATH shims in ~/.acfs/agent-scope/bin
# (claude, codex, gemini, agy, pi): herdr's `agent start` types the kind's
# executable into the pane, and acfs agents spawn goes through herdr. A scope
# takes no OOMScoreAdjust= (it is an exec setting), so the shim raises its own
# oom_score_adj, which needs no privilege, and the agent inherits it.
#
# Usage:
#   service_protection.sh apply-system <user>   as root: the system drop-ins
#   service_protection.sh apply-user [--restart]
#                         as the user: slices, drop-ins, herdr's unit, the
#                         shims, the pressure fallback; --restart restarts
#                         running services that are in the wrong slice
#   service_protection.sh verify                 check the live layout
#   service_protection.sh agent-exec <name> [args...]   (the shims)
#   service_protection.sh pressure-guard         (acfs-agents-pressure.service)
#
# ACFS_AGENT_SCOPE=off makes the shims run the agent directly.
# Tests only: ACFS_SP_ROOT prefixes /etc, /proc and /sys/fs/cgroup, and
# ACFS_SP_SYSTEM_BIN_PREFIX names a directory of stub system tools (honoured
# only when owned by this user and not group- or world-writable).
# ============================================================

set -euo pipefail

readonly SP_VERSION="1.0.0"
# A dash in a slice name nests it: the three below sit in acfs.slice.
readonly SP_PARENT_SLICE="acfs.slice"
readonly SP_SERVICES_SLICE="acfs-services.slice"
readonly SP_BACKGROUND_SLICE="acfs-background.slice"
readonly SP_AGENTS_SLICE="acfs-agents.slice"
readonly SP_HERDR_UNIT="acfs-herdr.service"
readonly SP_PRESSURE_UNIT="acfs-agents-pressure.service"
readonly SP_DROPIN_NAME="50-acfs-protection.conf"
readonly SP_AGENT_SCORE=500
readonly SP_BACKGROUND_SCORE=200
readonly SP_VM_SERVICE_SCORE=-900
# Units of acfs-services.slice that other installers write; ours get a drop-in.
readonly -a SP_SERVICE_UNITS=(agent-mail.service acfs-agent-mail.service acfs-cm.service rchd.service)
readonly -a SP_BACKGROUND_UNITS=(acfs-cass-index.service)
# The agent kinds acfs agents spawn starts (herdr's canonical executables).
readonly -a SP_AGENT_NAMES=(claude codex gemini agy pi)
# Pressure fallback: what oomd would do with ManagedOOMMemoryPressureLimit=40%.
readonly SP_PRESSURE_LIMIT=40

SP_ROOT="${ACFS_SP_ROOT:-}"

_sp_note() { printf '[service-protection] %s\n' "$*" >&2; }
_sp_die() { _sp_note "$*"; exit 1; }

# --- System tools, from fixed directories (as acfs-services.sh does) ---

_sp_bin_prefix_trusted() {
    local dir="${ACFS_SP_SYSTEM_BIN_PREFIX:-}" perms=""
    [[ -n "$dir" && "$dir" == /* && -d "$dir" && -O "$dir" ]] || return 1
    [[ -x /usr/bin/stat ]] || return 1
    perms="$(/usr/bin/stat -c '%a' "$dir" 2>/dev/null || true)"
    [[ "$perms" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$perms & 8#022) == 0 ))
}

_sp_system_bin() {
    local name="$1" dir=""
    local -a dirs=()
    _sp_bin_prefix_trusted && dirs+=("$ACFS_SP_SYSTEM_BIN_PREFIX")
    dirs+=(/usr/bin /bin /usr/sbin /sbin)
    for dir in "${dirs[@]}"; do
        if [[ -x "$dir/$name" && ! -d "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

# Is this a container? systemd-detect-virt -c exits 0 inside one.
_sp_in_container() {
    local detect=""
    detect="$(_sp_system_bin systemd-detect-virt)" || return 1
    "$detect" -c -q >/dev/null 2>&1
}

# --- Memory sizes ---

# MemTotal in MiB (inside an Incus container lxcfs shows the container's).
_sp_mem_total_mib() {
    local kib=""
    kib="$(awk '/^MemTotal:/ {print $2; exit}' "$SP_ROOT/proc/meminfo" 2>/dev/null || true)"
    [[ "$kib" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(( kib / 1024 ))"
}

# min(cap MiB, pct% of RAM), as a MemoryLow value. The plan's numbers (12G
# along the chain, 8G services, 3G background) are for a 96 GiB devbox; a
# small VPS gets the same proportions instead of protecting more than it has.
_sp_size() {
    local cap_mib="$1" pct="$2" total="" share=""
    total="$(_sp_mem_total_mib)" || { printf '%sM\n' "$cap_mib"; return 0; }
    share=$(( total * pct / 100 ))
    (( share < cap_mib )) || share="$cap_mib"
    printf '%sM\n' "$share"
}

_sp_chain_low() { _sp_size 12288 50; }
_sp_services_low() { _sp_size 8192 33; }
_sp_background_low() { _sp_size 3072 12; }
# acfs.slice: the dash makes it the parent of the three slices, so it carries
# what its protected children need between them; the agents' share is 0.
_sp_parent_low() {
    local services="" background=""
    services="$(_sp_services_low)"; background="$(_sp_background_low)"
    printf '%sM\n' "$(( ${services%M} + ${background%M} ))"
}

# --- Writing files ---

# Write $2 to $1 when its content differs. Returns 0 when written, 1 when
# unchanged; fails the script on a write error.
_sp_write() {
    local path="$1" text="$2" dir="" tmp=""
    if [[ -f "$path" && "$(cat "$path" 2>/dev/null || true)" == "$text" ]]; then
        return 1
    fi
    dir="$(dirname "$path")"
    mkdir -p "$dir" || _sp_die "cannot create $dir"
    tmp="$(mktemp "$dir/.acfs-protection.XXXXXX")" || _sp_die "cannot write in $dir"
    if ! printf '%s\n' "$text" > "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        _sp_die "failed to write $path"
    fi
    return 0
}

_sp_header() {
    printf '# Written by service_protection.sh %s (acfs-ioo3.5); rewritten by the\n# installer and acfs update.\n' "$SP_VERSION"
}

# ============================================================
# apply-system (root)
# ============================================================

sp_apply_system() {
    local user="${1:-}" uid="" sysdir="$SP_ROOT/etc/systemd" changed=false
    local chain="" user_at="" systemctl=""
    [[ -n "$user" ]] || _sp_die "usage: service_protection.sh apply-system <user>"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || _sp_die "invalid user name: $user"
    uid="$(id -u "$user" 2>/dev/null)" || _sp_die "no such user: $user"
    [[ -n "$SP_ROOT" || "$(id -u)" == 0 ]] || _sp_die "apply-system runs as root"
    systemctl="$(_sp_system_bin systemctl)" || { _sp_note "no systemctl: skipped (no systemd)"; return 0; }

    chain="$(_sp_chain_low)"
    local slice_text
    slice_text="$(_sp_header)
[Slice]
MemoryLow=$chain"
    _sp_write "$sysdir/system/user.slice.d/$SP_DROPIN_NAME" "$slice_text" && changed=true
    _sp_write "$sysdir/system/user-$uid.slice.d/$SP_DROPIN_NAME" "$slice_text" && changed=true

    user_at="$(_sp_header)
[Service]
MemoryLow=$chain"
    if _sp_in_container; then
        # Lowering the floor is refused here; leave the manager where it is.
        rm -f "$sysdir/user.conf.d/$SP_DROPIN_NAME"
    else
        # The manager at -900 sets every user process's floor to -900, so the
        # services' drop-ins can ask for it. DefaultOOMScoreAdjust keeps every
        # other user unit at systemd's usual 200 (manager + 100 at 100).
        user_at+="
# Lowers the floor so acfs-services.slice's units can run at $SP_VM_SERVICE_SCORE.
OOMScoreAdjust=$SP_VM_SERVICE_SCORE"
        _sp_write "$sysdir/user.conf.d/$SP_DROPIN_NAME" "$(_sp_header)
[Manager]
DefaultOOMScoreAdjust=200" && changed=true
    fi
    _sp_write "$sysdir/system/user@$uid.service.d/$SP_DROPIN_NAME" "$user_at" && changed=true

    # Under a test root, reload only through a stub systemctl.
    if [[ "$changed" == true ]] && { [[ -z "$SP_ROOT" ]] || _sp_bin_prefix_trusted; }; then
        "$systemctl" daemon-reload >/dev/null 2>&1 || _sp_note "systemctl daemon-reload failed; the drop-ins apply at the next boot"
    fi
    _sp_note "system: MemoryLow=$chain on user.slice, user-$uid.slice and user@$uid.service$(_sp_in_container && printf ' (container: no OOM floor change)' || printf ', user manager floor %s from its next start' "$SP_VM_SERVICE_SCORE")"
}

# ============================================================
# apply-user
# ============================================================

_sp_unit_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }
_sp_acfs_home() { printf '%s\n' "${ACFS_HOME:-$HOME/.acfs}"; }
_sp_installed_lib() { printf '%s\n' "$(_sp_acfs_home)/scripts/lib/service_protection.sh"; }
_sp_shim_dir() { printf '%s\n' "$(_sp_acfs_home)/agent-scope/bin"; }

# Did apply-system lower the user manager's floor (a VM or VPS)?
_sp_floor_lowered() {
    local uid=""
    uid="$(id -u)"
    grep -q "^OOMScoreAdjust=$SP_VM_SERVICE_SCORE\$" \
        "$SP_ROOT/etc/systemd/system/user@$uid.service.d/$SP_DROPIN_NAME" 2>/dev/null
}

_sp_service_score() {
    if _sp_floor_lowered; then printf '%s\n' "$SP_VM_SERVICE_SCORE"; else printf '0\n'; fi
}

# herdr's binary, where the herdr installer puts it.
_sp_herdr_bin() {
    local candidate=""
    for candidate in "$HOME/.local/bin/herdr" "$(type -P herdr 2>/dev/null || true)"; do
        [[ -n "$candidate" && "$candidate" == /* && -x "$candidate" && ! -d "$candidate" ]] || continue
        [[ "$candidate" =~ ^[A-Za-z0-9._/+-]+$ ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

_sp_user_units_text() {
    local name="$1" score=""
    score="$(_sp_service_score)"
    case "$name" in
        "$SP_PARENT_SLICE")
            printf '%s\n[Unit]\nDescription=ACFS: services, background work and agents\n\n[Slice]\nMemoryLow=%s\n' \
                "$(_sp_header)" "$(_sp_parent_low)" ;;
        "$SP_SERVICES_SLICE")
            printf '%s\n[Unit]\nDescription=ACFS services: Agent Mail, herdr, cm, rchd\n\n[Slice]\nMemoryLow=%s\n' \
                "$(_sp_header)" "$(_sp_services_low)" ;;
        "$SP_BACKGROUND_SLICE")
            printf '%s\n[Unit]\nDescription=ACFS background work: the CASS indexer\n\n[Slice]\nMemoryLow=%s\n' \
                "$(_sp_header)" "$(_sp_background_low)" ;;
        "$SP_AGENTS_SLICE")
            printf '%s\n[Unit]\nDescription=ACFS agents, killed first under memory pressure\n\n[Slice]\nManagedOOMMemoryPressure=kill\nManagedOOMMemoryPressureLimit=%s%%\n' \
                "$(_sp_header)" "$SP_PRESSURE_LIMIT" ;;
        service-dropin)
            printf '%s\n[Service]\nSlice=%s\nOOMScoreAdjust=%s\n' "$(_sp_header)" "$SP_SERVICES_SLICE" "$score" ;;
        background-dropin)
            printf '%s\n[Service]\nSlice=%s\nOOMScoreAdjust=%s\n' "$(_sp_header)" "$SP_BACKGROUND_SLICE" "$SP_BACKGROUND_SCORE" ;;
        *) return 1 ;;
    esac
}

_sp_herdr_unit_text() {
    local herdr="$1"
    cat <<EOF
$(_sp_header)
# herdr's server holds every agent pane. Run here, it sits in
# $SP_SERVICES_SLICE; the agents it starts move to $SP_AGENTS_SLICE.
[Unit]
Description=herdr server (ACFS)

[Service]
Type=simple
ExecStart=$herdr server
Slice=$SP_SERVICES_SLICE
OOMScoreAdjust=$(_sp_service_score)
Restart=on-failure
RestartSec=5
Environment=PATH=%h/.acfs/agent-scope/bin:%h/.acfs/bin:%h/.local/bin:%h/.cargo/bin:%h/.bun/bin:%h/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=%h

[Install]
WantedBy=default.target
EOF
}

_sp_pressure_unit_text() {
    cat <<EOF
$(_sp_header)
# Kills the newest agent scope when $SP_AGENTS_SLICE's memory pressure stays
# above $SP_PRESSURE_LIMIT%. Enabled only when systemd-oomd is not active.
[Unit]
Description=ACFS agents' memory-pressure guard (systemd-oomd fallback)

[Service]
Type=simple
ExecStart=/bin/bash $(_sp_installed_lib) pressure-guard
Slice=$SP_SERVICES_SLICE
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
}

_sp_shim_text() {
    local name="$1"
    cat <<EOF
#!/usr/bin/env bash
# acfs-agent-scope-shim: written by service_protection.sh $SP_VERSION (acfs-ioo3.5).
# Starts $name in $SP_AGENTS_SLICE at oom_score_adj $SP_AGENT_SCORE.
lib="$(_sp_installed_lib)"
if [[ -r "\$lib" ]]; then
    exec bash "\$lib" agent-exec $name "\$@"
fi
# ACFS's library is gone: run $name from the rest of PATH.
shim_dir="\$(cd "\$(dirname "\$0")" && pwd -P)"
IFS=: read -r -a dirs <<<"\$PATH"
PATH=""
for d in "\${dirs[@]}"; do
    [[ -n "\$d" && "\$(cd "\$d" 2>/dev/null && pwd -P)" != "\$shim_dir" ]] && PATH="\${PATH:+\$PATH:}\$d"
done
export PATH
exec $name "\$@"
EOF
}

_sp_systemctl_user() {
    local systemctl=""
    systemctl="$(_sp_system_bin systemctl)" || return 1
    "$systemctl" --user "$@"
}

_sp_oomd_active() {
    local systemctl=""
    systemctl="$(_sp_system_bin systemctl)" || return 1
    "$systemctl" is-active --quiet systemd-oomd.service >/dev/null 2>&1
}

# A herdr server this user runs outside our unit (started by a herdr client).
_sp_herdr_server_running() {
    local pgrep=""
    pgrep="$(_sp_system_bin pgrep)" || return 1
    "$pgrep" -u "$(id -u)" -f '(^|/)herdr server$' >/dev/null 2>&1
}

sp_apply_user() {
    local restart=false unit_dir="" reload=false unit="" name="" herdr="" lib=""
    local -a wrong_slice=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart) restart=true; shift ;;
            *) _sp_die "unknown apply-user option: $1" ;;
        esac
    done
    [[ "$(id -u)" != 0 ]] || _sp_die "apply-user runs as the target user, not root"
    if ! _sp_systemctl_user show-environment >/dev/null 2>&1; then
        _sp_note "no systemd user manager reachable: skipped (run 'service_protection.sh apply-user' after logging in)"
        return 0
    fi
    unit_dir="$(_sp_unit_dir)"
    lib="$(_sp_installed_lib)"

    for unit in "$SP_PARENT_SLICE" "$SP_SERVICES_SLICE" "$SP_BACKGROUND_SLICE" "$SP_AGENTS_SLICE"; do
        _sp_write "$unit_dir/$unit" "$(_sp_user_units_text "$unit")" && reload=true
    done
    # Drop-ins on the services' units, ours and other installers' alike: a
    # drop-in for a unit that is not installed yet takes effect when it is.
    for unit in "${SP_SERVICE_UNITS[@]}"; do
        _sp_write "$unit_dir/$unit.d/$SP_DROPIN_NAME" "$(_sp_user_units_text service-dropin)" && reload=true
    done
    for unit in "${SP_BACKGROUND_UNITS[@]}"; do
        _sp_write "$unit_dir/$unit.d/$SP_DROPIN_NAME" "$(_sp_user_units_text background-dropin)" && reload=true
    done

    if herdr="$(_sp_herdr_bin)"; then
        _sp_write "$unit_dir/$SP_HERDR_UNIT" "$(_sp_herdr_unit_text "$herdr")" && reload=true
    else
        _sp_note "herdr is not installed: no $SP_HERDR_UNIT"
    fi

    if [[ -r "$lib" ]]; then
        _sp_write "$unit_dir/$SP_PRESSURE_UNIT" "$(_sp_pressure_unit_text)" && reload=true
        for name in "${SP_AGENT_NAMES[@]}"; do
            if _sp_write "$(_sp_shim_dir)/$name" "$(_sp_shim_text "$name")"; then
                chmod 755 "$(_sp_shim_dir)/$name"
            fi
        done
    else
        _sp_note "$lib is not installed: no agent shims and no pressure fallback"
    fi

    if [[ "$reload" == true ]] && ! _sp_systemctl_user daemon-reload >/dev/null 2>&1; then
        _sp_die "systemctl --user daemon-reload failed"
    fi

    if [[ -n "$herdr" ]]; then
        _sp_systemctl_user enable "$SP_HERDR_UNIT" >/dev/null 2>&1 \
            || _sp_note "could not enable $SP_HERDR_UNIT"
        if _sp_systemctl_user is-active --quiet "$SP_HERDR_UNIT" >/dev/null 2>&1; then
            :
        elif _sp_herdr_server_running; then
            # Starting a second server would fight over herdr's socket, and
            # stopping the running one closes every pane.
            _sp_note "a herdr server already runs outside $SP_HERDR_UNIT; it takes over at the next boot, or now: herdr server stop && systemctl --user start $SP_HERDR_UNIT"
        elif ! _sp_systemctl_user start "$SP_HERDR_UNIT" >/dev/null 2>&1; then
            _sp_note "could not start $SP_HERDR_UNIT; see: systemctl --user status $SP_HERDR_UNIT"
        fi
    fi

    if [[ -r "$lib" ]]; then
        if _sp_oomd_active; then
            _sp_systemctl_user disable --now "$SP_PRESSURE_UNIT" >/dev/null 2>&1 || true
        elif ! _sp_systemctl_user enable --now "$SP_PRESSURE_UNIT" >/dev/null 2>&1; then
            _sp_note "could not start $SP_PRESSURE_UNIT; see: systemctl --user status $SP_PRESSURE_UNIT"
        fi
    fi

    # A running service keeps its old slice until it restarts.
    for unit in "${SP_SERVICE_UNITS[@]}" "${SP_BACKGROUND_UNITS[@]}"; do
        _sp_systemctl_user is-active --quiet "$unit" >/dev/null 2>&1 || continue
        local want="$SP_SERVICES_SLICE" have=""
        [[ " ${SP_BACKGROUND_UNITS[*]} " != *" $unit "* ]] || want="$SP_BACKGROUND_SLICE"
        have="$(_sp_systemctl_user show -p ControlGroup --value "$unit" 2>/dev/null || true)"
        [[ "$have" == *"/$want/"* ]] || wrong_slice+=("$unit")
    done
    if (( ${#wrong_slice[@]} )); then
        if [[ "$restart" == true ]]; then
            _sp_systemctl_user restart "${wrong_slice[@]}" >/dev/null 2>&1 \
                || _sp_note "could not restart: ${wrong_slice[*]}"
        else
            _sp_note "still in their old slice until restarted: ${wrong_slice[*]} (systemctl --user restart ${wrong_slice[*]}, at a quiet moment)"
        fi
    fi
    _sp_note "user: $SP_SERVICES_SLICE, $SP_BACKGROUND_SLICE and $SP_AGENTS_SLICE are in place; agents start through $(_sp_shim_dir)"
}

# ============================================================
# agent-exec (the shims)
# ============================================================

# The first $1 on PATH that is not in the shim directory.
_sp_real_binary() {
    local name="$1" shim_dir="" dir="" real_dir=""
    local -a dirs=()
    shim_dir="$(cd "$(_sp_shim_dir)" 2>/dev/null && pwd -P || printf '%s' "$(_sp_shim_dir)")"
    IFS=: read -r -a dirs <<<"${PATH:-}"
    for dir in "${dirs[@]}"; do
        [[ -n "$dir" ]] || continue
        real_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
        [[ "$real_dir" != "$shim_dir" ]] || continue
        if [[ -x "$dir/$name" && ! -d "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

_sp_in_agents_slice() {
    grep -q "/$SP_AGENTS_SLICE/" "$SP_ROOT/proc/self/cgroup" 2>/dev/null
}

sp_agent_exec() {
    local name="${1:-}" real="" run="" adj_file="$SP_ROOT/proc/self/oom_score_adj" adj=""
    [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || _sp_die "agent-exec: invalid name '$name'"
    shift
    if ! real="$(_sp_real_binary "$name")"; then
        printf '%s: command not found (outside %s)\n' "$name" "$(_sp_shim_dir)" >&2
        exit 127
    fi
    # Raise, never lower: raising needs no privilege, and a process already
    # above 500 keeps its score.
    adj="$(cat "$adj_file" 2>/dev/null || true)"
    if [[ "$adj" =~ ^-?[0-9]+$ ]] && (( adj < SP_AGENT_SCORE )); then
        printf '%s\n' "$SP_AGENT_SCORE" > "$adj_file" 2>/dev/null || true
    fi
    if [[ "${ACFS_AGENT_SCOPE:-on}" == off ]] || _sp_in_agents_slice \
        || ! run="$(_sp_system_bin systemd-run)" \
        || [[ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]]; then
        exec "$real" "$@"
    fi
    # systemd-run --scope moves this process into the scope, then execs the
    # agent: same PID and terminal, so herdr still sees the agent it typed.
    exec "$run" --user --scope --quiet --collect --slice="$SP_AGENTS_SLICE" \
        --unit="acfs-agent-$name-$$" -- "$real" "$@"
}

# ============================================================
# pressure-guard (acfs-agents-pressure.service)
# ============================================================

# The agents' slice's "full avg10" memory pressure, as an integer percent.
_sp_agents_pressure() {
    local cgroup="" file=""
    cgroup="$(_sp_systemctl_user show -p ControlGroup --value "$SP_AGENTS_SLICE" 2>/dev/null || true)"
    [[ "$cgroup" == /* ]] || return 1
    file="$SP_ROOT/sys/fs/cgroup$cgroup/memory.pressure"
    awk '$1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); printf "%d\n", $i; found = 1 } }
         END { exit found ? 0 : 1 }' "$file" 2>/dev/null
}

# The agent scope that started last.
_sp_newest_agent_scope() {
    local unit="" ts="" best="" best_ts=-1
    while read -r unit _; do
        [[ "$unit" == acfs-agent-*.scope ]] || continue
        ts="$(_sp_systemctl_user show -p ActiveEnterTimestampMonotonic --value "$unit" 2>/dev/null || true)"
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts > best_ts )); then best="$unit"; best_ts="$ts"; fi
    done < <(_sp_systemctl_user list-units --type=scope --state=running --plain --no-legend --no-pager 'acfs-agent-*' 2>/dev/null || true)
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}

sp_pressure_guard() {
    local interval="${ACFS_SP_PRESSURE_INTERVAL:-10}" samples="${ACFS_SP_PRESSURE_SAMPLES:-3}"
    local loops="${ACFS_SP_PRESSURE_MAX_LOOPS:-0}" over=0 n=0 pressure="" victim=""
    [[ "$interval" =~ ^[0-9]+$ && "$samples" =~ ^[1-9][0-9]*$ && "$loops" =~ ^[0-9]+$ ]] \
        || _sp_die "pressure-guard: bad ACFS_SP_PRESSURE_* setting"
    while :; do
        if _sp_oomd_active; then
            over=0
        elif pressure="$(_sp_agents_pressure)" && (( pressure > SP_PRESSURE_LIMIT )); then
            over=$(( over + 1 ))
            if (( over >= samples )); then
                over=0
                if victim="$(_sp_newest_agent_scope)"; then
                    _sp_note "$(date -u +%Y-%m-%dT%H:%M:%SZ) $SP_AGENTS_SLICE memory pressure ${pressure}% > ${SP_PRESSURE_LIMIT}% for $samples samples: killing $victim"
                    _sp_systemctl_user kill --signal=SIGKILL "$victim" >/dev/null 2>&1 \
                        || _sp_note "could not kill $victim"
                fi
            fi
        else
            over=0
        fi
        n=$(( n + 1 ))
        (( loops == 0 || n < loops )) || return 0
        sleep "$interval"
    done
}

# ============================================================
# verify
# ============================================================

_sp_pid_line() {
    local pid="$1"
    printf 'oom_score_adj=%s cgroup=%s' \
        "$(cat "$SP_ROOT/proc/$pid/oom_score_adj" 2>/dev/null || printf '?')" \
        "$(sed -n 's/^0:://p' "$SP_ROOT/proc/$pid/cgroup" 2>/dev/null || printf '?')"
}

# One line per check: PASS|FAIL|SKIP <what>: <detail>. Exits 1 on any FAIL.
sp_verify() {
    local failed=false unit="" pid="" want="" score="" cgroup="" low="" path="" uid=""
    local scope="" agents=0
    _sp_systemctl_user show-environment >/dev/null 2>&1 || _sp_die "no systemd user manager reachable"
    uid="$(id -u)"
    _sp_result() { printf '%s %s: %s\n' "$1" "$2" "$3"; [[ "$1" != FAIL ]] || failed=true; }

    for unit in "${SP_SERVICE_UNITS[@]}" "$SP_HERDR_UNIT" "${SP_BACKGROUND_UNITS[@]}"; do
        pid="$(_sp_systemctl_user show -p MainPID --value "$unit" 2>/dev/null || true)"
        if ! [[ "$pid" =~ ^[0-9]+$ ]] || (( pid == 0 )); then
            _sp_result SKIP "$unit" "not running"
            continue
        fi
        want="$SP_SERVICES_SLICE"; score="$(_sp_service_score)"
        if [[ " ${SP_BACKGROUND_UNITS[*]} " == *" $unit "* ]]; then
            want="$SP_BACKGROUND_SLICE"; score="$SP_BACKGROUND_SCORE"
        fi
        cgroup="$(sed -n 's/^0:://p' "$SP_ROOT/proc/$pid/cgroup" 2>/dev/null || true)"
        if [[ "$cgroup" == *"/$want/"* && "$(cat "$SP_ROOT/proc/$pid/oom_score_adj" 2>/dev/null)" == "$score" ]]; then
            _sp_result PASS "$unit" "$(_sp_pid_line "$pid")"
        else
            _sp_result FAIL "$unit" "$(_sp_pid_line "$pid"), want $want at $score"
        fi
    done

    while read -r scope _; do
        [[ "$scope" == acfs-agent-*.scope ]] || continue
        agents=$(( agents + 1 ))
        pid="$(_sp_systemctl_user show -p MainPID --value "$scope" 2>/dev/null || true)"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { _sp_result SKIP "$scope" "no main PID"; continue; }
        cgroup="$(sed -n 's/^0:://p' "$SP_ROOT/proc/$pid/cgroup" 2>/dev/null || true)"
        score="$(cat "$SP_ROOT/proc/$pid/oom_score_adj" 2>/dev/null || true)"
        if [[ "$cgroup" == *"/$SP_AGENTS_SLICE/"* && "$score" =~ ^-?[0-9]+$ ]] && (( score >= SP_AGENT_SCORE )); then
            _sp_result PASS "$scope" "$(_sp_pid_line "$pid")"
        else
            _sp_result FAIL "$scope" "$(_sp_pid_line "$pid"), want $SP_AGENTS_SLICE at $SP_AGENT_SCORE"
        fi
    done < <(_sp_systemctl_user list-units --type=scope --state=running --plain --no-legend --no-pager 'acfs-agent-*' 2>/dev/null || true)
    (( agents )) || _sp_result SKIP "agents" "no acfs-agent-*.scope running"

    path="$SP_ROOT/sys/fs/cgroup"
    for unit in user.slice "user-$uid.slice" "user@$uid.service" "$SP_PARENT_SLICE" "$SP_SERVICES_SLICE"; do
        path+="/$unit"
        low="$(cat "$path/memory.low" 2>/dev/null || true)"
        if [[ "$low" =~ ^[0-9]+$ ]] && (( low > 0 )) || [[ "$low" == max ]]; then
            _sp_result PASS "memory.low $unit" "$low"
        else
            _sp_result FAIL "memory.low $unit" "${low:-unreadable}"
        fi
    done

    if _sp_oomd_active; then
        _sp_result PASS "pressure killer" "systemd-oomd is active"
    elif _sp_systemctl_user is-active --quiet "$SP_PRESSURE_UNIT" >/dev/null 2>&1; then
        _sp_result PASS "pressure killer" "$SP_PRESSURE_UNIT is active"
    else
        _sp_result FAIL "pressure killer" "neither systemd-oomd nor $SP_PRESSURE_UNIT is active"
    fi
    [[ "$failed" == false ]]
}

# ============================================================

sp_main() {
    local cmd="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$cmd" in
        apply-system) sp_apply_system "$@" ;;
        apply-user) sp_apply_user "$@" ;;
        verify) sp_verify "$@" ;;
        agent-exec) sp_agent_exec "$@" ;;
        pressure-guard) sp_pressure_guard "$@" ;;
        -h|--help|help) sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *) _sp_die "usage: service_protection.sh apply-system <user> | apply-user [--restart] | verify | agent-exec <name> [args] | pressure-guard" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sp_main "$@"
fi
