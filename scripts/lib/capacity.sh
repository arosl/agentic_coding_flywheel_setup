#!/usr/bin/env bash
# ============================================================
# ACFS Capacity Report
#
# Fast, offline host sizing for multi-agent ACFS workflows.
# ============================================================

set -uo pipefail

CAPACITY_JSON=false
CAPACITY_WORKLOAD="standard"
CAPACITY_PROFILE=""
CAPACITY_RECOMMEND_HERDR=false
CAPACITY_RESOURCE_PROFILE=false
CAPACITY_RESOURCE_PROFILE_APPLY=false
CAPACITY_RESOURCE_PROFILE_DISABLE=false
CAPACITY_RESOURCE_PROFILE_ROOT=""
CAPACITY_GUARD=false
CAPACITY_GUARD_CHECK=false

capacity_usage() {
    cat <<'EOF'
Usage: acfs capacity [OPTIONS]

Options:
  --json                  Emit machine-readable JSON
  --workload <name>       light, standard, or heavy (default: standard)
  --profile <agents>      Check a target agent count, e.g. 25 or 25-agents
  --recommend-herdr       Include a herdr launch recommendation (acfs agents spawn)
  --resource-profile      Report opt-in systemd resource profile wrappers
  --apply-resource-profile
                          Write opt-in ACFS wrapper files under ~/.acfs
  --disable-resource-profile
                          Write a disabled profile marker/snippet, no deletion
  --guard                 Report the host's live headroom for one more agent:
                          MemAvailable, swap, disk free on the work and temp
                          filesystems, PSI memory and cpu, rch's posture and
                          workers, and a suggested maximum number of agents
  --check                 With --guard: exit 1 when the guard is red, with the
                          reasons on stderr; 0 otherwise; 2 when unreadable.
                          It reads neither rch nor herdr, which never make it red
  -h, --help              Show this help

The guard is red when MemAvailable is under 4 GiB, a work or temp filesystem
has under 10% free, or PSI memory "full" avg60 is over 10. It warns when the
host has no swap, rch has no workers, or a tmpfs /tmp is more than 50% full.
In an Incus system container (systemd-detect-virt -c says lxc) it reads the
container's own cgroup: it is red when the working set (memory.current less
inactive_file, so reclaimable page cache doesn't count) is over 80% of
memory.high (memory.max when there is no soft limit), and PSI comes from the
cgroup's memory.pressure, not /proc/pressure. Anywhere, the memory.pressure
of acfs-agents.slice (and the other acfs slices, reported) is read when the
slice exists; the agents' slice over the PSI line is red as well.
Thresholds: ACFS_CAPACITY_GUARD_MIN_MEM_MIB (4096),
ACFS_CAPACITY_GUARD_MIN_DISK_PCT (10), ACFS_CAPACITY_GUARD_MAX_PSI_FULL (10),
ACFS_CAPACITY_GUARD_MAX_CGROUP_PCT (80),
ACFS_CAPACITY_GUARD_AGENT_MIB (1024, one Claude agent with its MCP children)
and ACFS_CAPACITY_GUARD_GATE_MIB (4096, headroom kept for one gate run).

Environment overrides for tests:
  ACFS_CAPACITY_CPU_COUNT
  ACFS_CAPACITY_MEM_TOTAL_KB
  ACFS_CAPACITY_DISK_AVAILABLE_KB
  ACFS_CAPACITY_RCH_AVAILABLE=true|false
  ACFS_CAPACITY_HERDR_AVAILABLE=true|false
  ACFS_CAPACITY_SYSTEMD_RUN_AVAILABLE=true|false
  ACFS_CAPACITY_SYSTEMD_USER_AVAILABLE=true|false
  ACFS_CAPACITY_BIN_DIR
  ACFS_RESOURCE_PROFILE_HOME
  ACFS_CAPACITY_MEMINFO_FILE, ACFS_CAPACITY_PSI_DIR
  ACFS_CAPACITY_WORK_DIR, ACFS_CAPACITY_TEMP_DIR
  ACFS_CAPACITY_VIRT (what systemd-detect-virt -c would say),
  ACFS_CAPACITY_CGROUP_ROOT (/sys/fs/cgroup), ACFS_CAPACITY_UID
EOF
}

capacity_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                CAPACITY_JSON=true
                shift
                ;;
            --workload)
                [[ $# -ge 2 ]] || { echo "Error: --workload requires a value" >&2; return 2; }
                CAPACITY_WORKLOAD="$2"
                shift 2
                ;;
            --profile)
                [[ $# -ge 2 ]] || { echo "Error: --profile requires a value" >&2; return 2; }
                CAPACITY_PROFILE="$2"
                shift 2
                ;;
            --recommend-herdr)
                CAPACITY_RECOMMEND_HERDR=true
                shift
                ;;
            --resource-profile)
                CAPACITY_RESOURCE_PROFILE=true
                shift
                ;;
            --apply-resource-profile)
                CAPACITY_RESOURCE_PROFILE=true
                CAPACITY_RESOURCE_PROFILE_APPLY=true
                shift
                ;;
            --disable-resource-profile)
                CAPACITY_RESOURCE_PROFILE=true
                CAPACITY_RESOURCE_PROFILE_DISABLE=true
                shift
                ;;
            --guard)
                CAPACITY_GUARD=true
                shift
                ;;
            --check)
                CAPACITY_GUARD_CHECK=true
                shift
                ;;
            -h|--help)
                capacity_usage
                return 100
                ;;
            *)
                echo "Error: unknown option: $1" >&2
                echo "Run 'acfs capacity --help' for usage." >&2
                return 2
                ;;
        esac
    done

    case "$CAPACITY_WORKLOAD" in
        light|standard|heavy) ;;
        *)
            echo "Error: unsupported workload: $CAPACITY_WORKLOAD" >&2
            return 2
            ;;
    esac

    if [[ "$CAPACITY_GUARD_CHECK" == true && "$CAPACITY_GUARD" != true ]]; then
        echo "Error: --check needs --guard" >&2
        return 2
    fi

    if [[ "$CAPACITY_RESOURCE_PROFILE_APPLY" == true && "$CAPACITY_RESOURCE_PROFILE_DISABLE" == true ]]; then
        echo "Error: choose only one of --apply-resource-profile or --disable-resource-profile" >&2
        return 2
    fi
}

capacity_system_binary_path() {
    local name="${1:-}"
    local candidate=""

    [[ -n "$name" ]] || return 1
    case "$name" in
        .|..|*[!A-Za-z0-9._+-]*)
            return 1
            ;;
    esac

    if [[ -n "${ACFS_CAPACITY_BIN_DIR:-}" ]]; then
        candidate="${ACFS_CAPACITY_BIN_DIR%/}/$name"
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    for candidate in \
        "/usr/bin/$name" \
        "/bin/$name" \
        "/usr/local/bin/$name" \
        "/usr/local/sbin/$name" \
        "/usr/sbin/$name" \
        "/sbin/$name" \
        "${HOME:-}/.local/bin/$name" \
        "${HOME:-}/.cargo/bin/$name" \
        "${HOME:-}/.bun/bin/$name"
    do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi

    return 1
}

capacity_read_cpu_count() {
    if [[ "${ACFS_CAPACITY_CPU_COUNT:-}" =~ ^[0-9]+$ ]] && [[ "${ACFS_CAPACITY_CPU_COUNT}" -gt 0 ]]; then
        printf '%s\n' "$ACFS_CAPACITY_CPU_COUNT"
        return 0
    fi

    local nproc_bin=""
    nproc_bin="$(capacity_system_binary_path nproc 2>/dev/null || true)"
    if [[ -n "$nproc_bin" ]]; then
        "$nproc_bin" 2>/dev/null && return 0
    fi

    getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
}

capacity_read_mem_total_kb() {
    if [[ "${ACFS_CAPACITY_MEM_TOTAL_KB:-}" =~ ^[0-9]+$ ]] && [[ "${ACFS_CAPACITY_MEM_TOTAL_KB}" -gt 0 ]]; then
        printf '%s\n' "$ACFS_CAPACITY_MEM_TOTAL_KB"
        return 0
    fi

    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0\n'
}

capacity_read_disk_available_kb() {
    if [[ "${ACFS_CAPACITY_DISK_AVAILABLE_KB:-}" =~ ^[0-9]+$ ]] && [[ "${ACFS_CAPACITY_DISK_AVAILABLE_KB}" -ge 0 ]]; then
        printf '%s\n' "$ACFS_CAPACITY_DISK_AVAILABLE_KB"
        return 0
    fi

    local target="${ACFS_CAPACITY_DISK_PATH:-${HOME:-/}}"
    df -Pk "$target" 2>/dev/null | awk 'NR == 2 {print $4; exit}' || printf '0\n'
}

capacity_tool_available() {
    local tool="$1"
    local override_var="$2"
    local override="${!override_var:-}"

    case "$override" in
        true|false)
            printf '%s\n' "$override"
            return 0
            ;;
    esac

    if capacity_system_binary_path "$tool" >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

capacity_max() {
    local a="$1"
    local b="$2"
    if (( a > b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

capacity_min3() {
    local a="$1"
    local b="$2"
    local c="$3"
    local min="$a"
    (( b < min )) && min="$b"
    (( c < min )) && min="$c"
    (( min < 0 )) && min=0
    printf '%s\n' "$min"
}

capacity_requested_agents() {
    local value="$1"
    local digits="${value//[^0-9]/}"
    [[ -n "$digits" ]] || return 1
    printf '%s\n' "$digits"
}

capacity_resource_profile_root() {
    if [[ -n "$CAPACITY_RESOURCE_PROFILE_ROOT" ]]; then
        printf '%s\n' "$CAPACITY_RESOURCE_PROFILE_ROOT"
        return 0
    fi

    CAPACITY_RESOURCE_PROFILE_ROOT="${ACFS_RESOURCE_PROFILE_HOME:-${HOME:-/tmp}/.acfs/resource-profile}"
    printf '%s\n' "$CAPACITY_RESOURCE_PROFILE_ROOT"
}

capacity_resource_systemd_run_available() {
    case "${ACFS_CAPACITY_SYSTEMD_RUN_AVAILABLE:-}" in
        true|false)
            printf '%s\n' "$ACFS_CAPACITY_SYSTEMD_RUN_AVAILABLE"
            return 0
            ;;
    esac

    if capacity_system_binary_path systemd-run >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

capacity_resource_systemd_user_available() {
    local systemctl_bin=""

    case "${ACFS_CAPACITY_SYSTEMD_USER_AVAILABLE:-}" in
        true|false)
            printf '%s\n' "$ACFS_CAPACITY_SYSTEMD_USER_AVAILABLE"
            return 0
            ;;
    esac

    systemctl_bin="$(capacity_system_binary_path systemctl 2>/dev/null || true)"
    if [[ -n "$systemctl_bin" ]] && "$systemctl_bin" --user show-environment >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

capacity_resource_profile_state() {
    if [[ "$CAPACITY_RESOURCE_PROFILE_DISABLE" == true ]]; then
        printf 'disabled\n'
    elif [[ "$CAPACITY_RESOURCE_PROFILE_APPLY" == true ]]; then
        printf 'applied\n'
    else
        printf 'dry-run\n'
    fi
}

capacity_resource_profile_json() {
    local root="$1"
    local state="$2"
    local systemd_run_available="$3"
    local systemd_user_available="$4"
    local status="${5:-pass}"
    local failure_reason="${6:-}"
    local bin_dir="$root/bin"
    local env_file="$root/acfs-resource-profile.sh"
    local manifest_file="$root/profile.json"

    command -v jq >/dev/null 2>&1 || {
        echo "Error: jq is required for resource profile JSON" >&2
        return 1
    }

    jq -n \
        --arg generated_at "$(date -Iseconds)" \
        --arg state "$state" \
        --arg root "$root" \
        --arg bin_dir "$bin_dir" \
        --arg env_file "$env_file" \
        --arg manifest_file "$manifest_file" \
        --arg status "$status" \
        --arg failure_reason "$failure_reason" \
        --argjson systemd_run_available "$systemd_run_available" \
        --argjson systemd_user_available "$systemd_user_available" \
        '{
            schema_version: 1,
            generated_at: $generated_at,
            status: $status,
            mode: $state,
            opt_in: true,
            root: $root,
            bin_dir: $bin_dir,
            env_file: $env_file,
            manifest_file: $manifest_file,
            systemd: {
                systemd_run_available: $systemd_run_available,
                user_manager_available: $systemd_user_available
            },
            safety: {
                no_hard_memory_limits_by_default: true,
                direct_agent_aliases_unchanged: true,
                rch_remains_preferred_build_path: true,
                limited_to_acfs_owned_files: true,
                destructive_cleanup_required: false
            },
            classes: [
                {name: "agent", slice: "acfs-agent.slice", properties: ["CPUAccounting=yes", "MemoryAccounting=yes", "IOAccounting=yes", "TasksAccounting=yes", "CPUWeight=100", "IOWeight=100", "TasksMax=512"]},
                {name: "background", slice: "acfs-background.slice", properties: ["CPUAccounting=yes", "MemoryAccounting=yes", "IOAccounting=yes", "TasksAccounting=yes", "CPUWeight=40", "IOWeight=50", "TasksMax=512"]},
                {name: "local-build", slice: "acfs-local-build.slice", properties: ["CPUAccounting=yes", "MemoryAccounting=yes", "IOAccounting=yes", "TasksAccounting=yes", "CPUWeight=60", "IOWeight=50", "TasksMax=512"]},
                {name: "support", slice: "acfs-support.slice", properties: ["CPUAccounting=yes", "MemoryAccounting=yes", "IOAccounting=yes", "TasksAccounting=yes", "CPUWeight=80", "IOWeight=100", "TasksMax=256"]},
                {name: "rch", slice: "acfs-rch.slice", properties: ["CPUAccounting=yes", "MemoryAccounting=yes", "IOAccounting=yes", "TasksAccounting=yes", "CPUWeight=100", "IOWeight=100", "TasksMax=512"]}
            ],
            wrappers: [
                {name: "acfs-scope", path: ($bin_dir + "/acfs-scope"), purpose: "Run an explicit command in an opt-in ACFS systemd user scope when available; otherwise execute directly."},
                {name: "ccs", path: ($bin_dir + "/ccs"), command: "acfs-scope agent -- claude"},
                {name: "cods", path: ($bin_dir + "/cods"), command: "acfs-scope agent -- codex"},
                {name: "gmis", path: ($bin_dir + "/gmis"), command: "acfs-scope agent -- gemini"},
                {name: "acfs-local-build", path: ($bin_dir + "/acfs-local-build"), command: "acfs-scope local-build --"}
            ],
            managed_files: [
                ($bin_dir + "/acfs-scope"),
                ($bin_dir + "/ccs"),
                ($bin_dir + "/cods"),
                ($bin_dir + "/gmis"),
                ($bin_dir + "/acfs-local-build"),
                $env_file,
                $manifest_file
            ],
            partial_apply_possible: ($state == "error"),
            remediation: (
                if $state == "error" then
                    [
                        "Resource profile application did not complete.",
                        "Inspect filesystem permissions under the ACFS resource profile root.",
                        "Fix the reported write failure, then rerun acfs capacity --resource-profile --apply-resource-profile."
                    ] + (if $failure_reason == "" then [] else [$failure_reason] end)
                else
                    []
                end
            ),
            actions: (
                if $state == "dry-run" then
                    ["would create wrapper directory", "would write opt-in wrappers", "would write shell snippet", "would write manifest"]
                elif $state == "disabled" then
                    ["wrote disabled shell snippet", "wrote disabled manifest"]
                elif $state == "applying" then
                    ["started profile write", "will write opt-in wrappers", "will write shell snippet", "will write final manifest"]
                elif $state == "error" then
                    ["failed before completing resource profile write", "left any already-written ACFS-owned files for inspection", "reported remediation guidance"]
                else
                    ["wrote wrapper directory", "wrote opt-in wrappers", "wrote shell snippet", "wrote manifest"]
                end
            )
        }'
}

capacity_write_resource_scope_wrapper() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: acfs-scope <agent|background|local-build|support|rch> -- <command> [args...]

Runs a command inside an opt-in ACFS systemd user scope when systemd user
scopes are available. Falls back to direct execution when unavailable.
USAGE
}

class="${1:-}"
if [[ -z "$class" || "$class" == "-h" || "$class" == "--help" ]]; then
    usage
    exit 0
fi
shift
if [[ "${1:-}" == "--" ]]; then
    shift
fi
if [[ $# -eq 0 ]]; then
    echo "Error: command required" >&2
    usage >&2
    exit 2
fi

slice=""
properties=()
case "$class" in
    agent)
        slice="acfs-agent.slice"
        properties=(CPUAccounting=yes MemoryAccounting=yes IOAccounting=yes TasksAccounting=yes CPUWeight=100 IOWeight=100 TasksMax=512)
        ;;
    background)
        slice="acfs-background.slice"
        properties=(CPUAccounting=yes MemoryAccounting=yes IOAccounting=yes TasksAccounting=yes CPUWeight=40 IOWeight=50 TasksMax=512)
        ;;
    local-build)
        slice="acfs-local-build.slice"
        properties=(CPUAccounting=yes MemoryAccounting=yes IOAccounting=yes TasksAccounting=yes CPUWeight=60 IOWeight=50 TasksMax=512)
        ;;
    support)
        slice="acfs-support.slice"
        properties=(CPUAccounting=yes MemoryAccounting=yes IOAccounting=yes TasksAccounting=yes CPUWeight=80 IOWeight=100 TasksMax=256)
        ;;
    rch)
        slice="acfs-rch.slice"
        properties=(CPUAccounting=yes MemoryAccounting=yes IOAccounting=yes TasksAccounting=yes CPUWeight=100 IOWeight=100 TasksMax=512)
        ;;
    *)
        echo "Error: unknown ACFS resource class: $class" >&2
        exit 2
        ;;
esac

if ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    exec "$@"
fi
if ! systemctl --user show-environment >/dev/null 2>&1; then
    exec "$@"
fi

args=(--user --scope --same-dir --collect "--slice=$slice")
for property in "${properties[@]}"; do
    args+=("--property=$property")
done

exec systemd-run "${args[@]}" "$@"
EOF
}

capacity_write_resource_command_wrapper() {
    local path="$1"
    local class="$2"
    shift 2

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'exec acfs-scope %q --' "$class"
        # printf ' %q' with zero args still emits " ''", which made the
        # generated wrapper exec the empty string.
        if (($#)); then
            printf ' %q' "$@"
        fi
        printf ' "$@"\n'
    } > "$path"
}

capacity_apply_resource_profile() {
    local root="$1"
    local state="$2"
    local profile_json="$3"
    local bin_dir="$root/bin"
    local env_file="$root/acfs-resource-profile.sh"
    local manifest_file="$root/profile.json"

    mkdir -p "$bin_dir" || return 1

    if [[ "$state" == "disabled" ]]; then
        cat > "$env_file" <<'EOF' || return 1
# ACFS resource profile disabled.
# Re-enable with: acfs capacity --resource-profile --apply-resource-profile
EOF
        printf '%s\n' "$profile_json" > "$manifest_file" || return 1
        return 0
    fi

    local applying_json=""
    applying_json="$(capacity_resource_profile_json "$root" "applying" "$(capacity_resource_systemd_run_available)" "$(capacity_resource_systemd_user_available)" "pending")" || return 1
    printf '%s\n' "$applying_json" > "$manifest_file" || return 1

    capacity_write_resource_scope_wrapper "$bin_dir/acfs-scope" || return 1
    capacity_write_resource_command_wrapper "$bin_dir/ccs" agent claude || return 1
    capacity_write_resource_command_wrapper "$bin_dir/cods" agent codex || return 1
    capacity_write_resource_command_wrapper "$bin_dir/gmis" agent gemini || return 1
    capacity_write_resource_command_wrapper "$bin_dir/acfs-local-build" local-build || return 1
    chmod +x "$bin_dir/acfs-scope" "$bin_dir/ccs" "$bin_dir/cods" "$bin_dir/gmis" "$bin_dir/acfs-local-build" || return 1

    cat > "$env_file" <<EOF || return 1
# ACFS opt-in resource profile wrappers.
# Source this file to add wrapper commands without changing cc/cod/agy.
case ":\${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *) export PATH="$bin_dir:\${PATH:-}" ;;
esac
EOF
    printf '%s\n' "$profile_json" > "$manifest_file" || return 1
}

capacity_emit_resource_profile_json() {
    local root state systemd_run_available systemd_user_available profile_json failure_reason
    root="$(capacity_resource_profile_root)"
    state="$(capacity_resource_profile_state)"
    systemd_run_available="$(capacity_resource_systemd_run_available)"
    systemd_user_available="$(capacity_resource_systemd_user_available)"
    profile_json="$(capacity_resource_profile_json "$root" "$state" "$systemd_run_available" "$systemd_user_available")"

    if [[ "$CAPACITY_RESOURCE_PROFILE_APPLY" == true || "$CAPACITY_RESOURCE_PROFILE_DISABLE" == true ]]; then
        if ! capacity_apply_resource_profile "$root" "$state" "$profile_json"; then
            failure_reason="Failed to write the complete ACFS resource profile."
            profile_json="$(capacity_resource_profile_json "$root" "error" "$systemd_run_available" "$systemd_user_available" "fail" "$failure_reason")"
            printf '%s\n' "$profile_json"
            return 1
        fi
        profile_json="$(capacity_resource_profile_json "$root" "$state" "$systemd_run_available" "$systemd_user_available")"
    fi

    printf '%s\n' "$profile_json"
}

capacity_emit_resource_profile_human() {
    local jq_bin root state systemd_run_available systemd_user_available profile_json apply_failed failure_reason
    jq_bin="$(capacity_system_binary_path jq 2>/dev/null || true)"
    if [[ -z "$jq_bin" ]]; then
        echo "Error: jq is required for resource profile output" >&2
        return 1
    fi

    root="$(capacity_resource_profile_root)"
    state="$(capacity_resource_profile_state)"
    systemd_run_available="$(capacity_resource_systemd_run_available)"
    systemd_user_available="$(capacity_resource_systemd_user_available)"
    profile_json="$(capacity_resource_profile_json "$root" "$state" "$systemd_run_available" "$systemd_user_available")"
    apply_failed=false
    failure_reason=""

    if [[ "$CAPACITY_RESOURCE_PROFILE_APPLY" == true || "$CAPACITY_RESOURCE_PROFILE_DISABLE" == true ]]; then
        if ! capacity_apply_resource_profile "$root" "$state" "$profile_json"; then
            apply_failed=true
            state="error"
            failure_reason="Failed to write the complete ACFS resource profile."
            profile_json="$(capacity_resource_profile_json "$root" "$state" "$systemd_run_available" "$systemd_user_available" "fail" "$failure_reason")"
        else
            profile_json="$(capacity_resource_profile_json "$root" "$state" "$systemd_run_available" "$systemd_user_available")"
        fi
    fi

    echo "ACFS Resource Profile"
    echo "Mode: $state"
    echo "Root: $root"
    echo "Systemd user manager: $systemd_user_available"
    echo "systemd-run: $systemd_run_available"
    echo ""
    echo "Safety"
    echo "  Opt-in only:          true"
    echo "  Hard MemoryMax:       not set"
    echo "  Direct cc/cod/agy:    unchanged"
    echo "  RCH build path:       remains preferred"
    echo ""
    echo "Wrappers"
    "$jq_bin" -r '.wrappers[] | "  \(.name): \(.path)"' <<< "$profile_json"
    echo ""
    echo "Resource Classes"
    "$jq_bin" -r '.classes[] | "  \(.name): \(.slice) [" + (.properties | join(", ")) + "]"' <<< "$profile_json"
    echo ""
    echo "Actions"
    "$jq_bin" -r '.actions[] | "  - " + .' <<< "$profile_json"

    if [[ "$state" == "dry-run" ]]; then
        echo ""
        echo "Apply: acfs capacity --resource-profile --apply-resource-profile"
        echo "Disable marker/snippet: acfs capacity --resource-profile --disable-resource-profile"
    elif [[ "$state" == "applied" ]]; then
        echo ""
        echo "Enable in current shell: source $root/acfs-resource-profile.sh"
        echo "Inspect: $root/bin/acfs-scope --help"
        echo "Disable marker/snippet: acfs capacity --resource-profile --disable-resource-profile"
    else
        echo ""
        echo "Disabled. Re-enable with: acfs capacity --resource-profile --apply-resource-profile"
    fi

    if [[ "$apply_failed" == true ]]; then
        echo "" >&2
        echo "Error: $failure_reason" >&2
        return 1
    fi
}

# Observe the execution context, not just the machine's advertised resources.
# Keep this collector embedded: capacity.sh is already an installed, verified
# asset and must work identically through doctor, inventory and the planner.
capacity_process_limits() {
    local python_bin=""
    python_bin="$(capacity_system_binary_path python3 2>/dev/null || true)"
    [[ -n "$python_bin" ]] || return 1
    "$python_bin" -I - "$1" "$2" "${ACFS_CAPACITY_CPU_COUNT:-}" "${ACFS_CAPACITY_MEM_TOTAL_KB:-}" <<'ACFS_PROCESS_LIMITS_PY'
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


class LimitsError(ValueError):
    pass


def number(value, positive=False):
    if not re.fullmatch(r"[0-9]{1,20}", value):
        raise LimitsError("invalid_limit")
    result = int(value)
    if result > 2**64 - 1 or (positive and result == 0):
        raise LimitsError("invalid_limit")
    return result


def text(path, limit=262144):
    # Kernel pseudo-files report size 0; bound reads instead of trusting st_size.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise LimitsError("invalid_kernel_file")
        raw = source.read(limit + 1)
    if len(raw) > limit:
        raise LimitsError("oversized_kernel_file")
    return raw.decode("utf-8", "strict")


def path_parts(value):
    if not value.startswith("/") or "\x00" in value:
        raise LimitsError("invalid_cgroup_path")
    parts = value.split("/")[1:]
    if any(part in (".", "..") for part in parts):
        raise LimitsError("unresolved_cgroup_namespace")
    return tuple(part for part in parts if part)


def mount_unescape(value):
    # mountinfo escapes space, tab, newline and backslash in pathname fields.
    return re.sub(r"\\(040|011|012|134)", lambda m: chr(int(m[1], 8)), value)


def memberships(raw):
    result = {}
    for line in raw.splitlines():
        fields = line.split(":", 2)
        if len(fields) != 3 or not fields[0].isdigit():
            raise LimitsError("invalid_cgroup_membership")
        hierarchy, controllers, name = fields
        keys = controllers.split(",") if controllers else ["v2"]
        for key in keys:
            if key not in ("cpu", "memory", "v2"):
                continue
            if key in result or (key == "v2" and hierarchy != "0"):
                raise LimitsError("ambiguous_cgroup_membership")
            result[key] = path_parts(name)
    return result


def mounts(raw):
    result = []
    for line in raw.splitlines():
        before, separator, after = line.partition(" - ")
        fields, extra = before.split(), after.split()
        if not separator or len(fields) < 6 or len(extra) < 3:
            raise LimitsError("invalid_mountinfo")
        if extra[0] not in ("cgroup", "cgroup2"):
            continue
        root = path_parts(mount_unescape(fields[3]))
        point = mount_unescape(fields[4])
        path_parts(point)
        controllers = {"v2"} if extra[0] == "cgroup2" else set(extra[2].split(","))
        result.append((root, point, controllers))
    return result


def open_directory(path):
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path_parts(str(path)):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def values_from_hierarchy(group, available, controller):
    choices = [(root, point) for root, point, controllers in available
               if controller in controllers and group[:len(root)] == root]
    if not choices:
        raise LimitsError("cgroup_mount_unavailable")
    # Prefer the widest visible hierarchy, not a convenient subtree bind mount
    # that would hide a tighter ancestor. Never look above its mount boundary.
    root, point = min(choices, key=lambda item: (len(item[0]), item[1]))
    relative = group[len(root):]
    if len(relative) > 128:
        raise LimitsError("cgroup_hierarchy_too_deep")
    directories = []
    try:
        directories.append(open_directory(point))
        for part in relative:
            directories.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=directories[-1]))
        values = []
        for fd in reversed(directories):
            def read(name):
                try:
                    child = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    return None  # Controller not enabled here, or real root.
                with os.fdopen(child, "rb") as source:
                    if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                        raise LimitsError("invalid_controller_file")
                    data = source.read(4097)
                if len(data) > 4096:
                    raise LimitsError("oversized_controller_file")
                return data.decode("ascii", "strict").strip()
            if controller == "v2":
                memory, cpu = read("memory.max"), read("cpu.max")
                if memory is not None and memory != "max":
                    values.append(("memory", number(memory)))
                if cpu is not None:
                    pair = cpu.split()
                    if len(pair) != 2:
                        raise LimitsError("invalid_cpu_quota")
                    period = number(pair[1], positive=True)
                    if pair[0] != "max":
                        values.append(("cpu", number(pair[0], positive=True) * 1000 // period))
            elif controller == "memory":
                memory = read("memory.limit_in_bytes")
                if memory is not None and memory != "-1":
                    values.append(("memory", number(memory)))
                # This kernel-computed ceiling also covers hierarchical limits
                # hidden by a v1 subtree mount. Not present on every kernel.
                summary = read("memory.stat")
                if summary is not None:
                    for line in summary.splitlines():
                        pair = line.split()
                        if pair and pair[0] == "hierarchical_memory_limit":
                            if len(pair) != 2:
                                raise LimitsError("invalid_memory_stat")
                            values.append(("memory", number(pair[1])))
            else:
                quota, period = read("cpu.cfs_quota_us"), read("cpu.cfs_period_us")
                if (quota is None) != (period is None):
                    raise LimitsError("incomplete_cpu_quota")
                if quota is not None:
                    period = number(period, positive=True)
                    if quota != "-1":
                        values.append(("cpu", number(quota, positive=True) * 1000 // period))
        return values, len(directories), bool(root)
    finally:
        for fd in directories:
            os.close(fd)


def inspect_limits(proc=Path("/proc"), affinity=None):
    result = {"status": "known", "scope": "current_process_visible_hierarchy",
              "cgroup_version": "none", "affinity_cpus": None,
              "cpu_quota_millicores": None, "memory_limit_bytes": None,
              "ancestor_observations": 0, "subtree_mount": False, "errors": []}
    try:
        # The scheduler's affinity already includes effective cpuset constraints.
        result["affinity_cpus"] = len(os.sched_getaffinity(0)) if affinity is None else affinity
        if type(result["affinity_cpus"]) is not int or result["affinity_cpus"] < 1:
            raise LimitsError("cpu_affinity_unavailable")
        groups_raw = text(proc / "self/cgroup")
        mounts_raw = text(proc / "self/mountinfo", 4 * 1024 * 1024)
        groups, available = memberships(groups_raw), mounts(mounts_raw)
        relevant = set(groups)
        if relevant:
            result["cgroup_version"] = "hybrid" if "v2" in relevant and len(relevant) > 1 else (
                "v2" if "v2" in relevant else "v1")
        values = []
        for controller, group in groups.items():
            observed, count, subtree = values_from_hierarchy(group, available, controller)
            values.extend(observed)
            result["ancestor_observations"] += count
            result["subtree_mount"] |= subtree
        for key, field in (("cpu", "cpu_quota_millicores"), ("memory", "memory_limit_bytes")):
            candidates = [value for kind, value in values if kind == key]
            if candidates:
                result[field] = min(candidates)
        if groups_raw != text(proc / "self/cgroup") or mounts_raw != text(proc / "self/mountinfo", 4 * 1024 * 1024):
            raise LimitsError("cgroup_changed_during_observation")
    except (OSError, ValueError, AttributeError) as error:
        result["status"] = "unavailable"
        # Never copy kernel paths, process identifiers or raw exception text.
        result["errors"] = [str(error) if isinstance(error, LimitsError) else "kernel_limits_unreadable"]
    return result


def model_limits(cpu, memory_kb, cpu_override="", memory_override="", proc=Path("/proc"), affinity=None):
    cpu, memory_kb = number(cpu, positive=True), number(memory_kb)
    if cpu > 1000000 or memory_kb > 2**53 - 1:
        raise LimitsError("host_resource_out_of_range")
    def supplied(value, expected):
        return bool(re.fullmatch(r"[0-9]{1,20}", value)) and int(value) > 0 and int(value) == expected
    cpu_fixture, memory_fixture = supplied(cpu_override, cpu), supplied(memory_override, memory_kb)
    result = ({"status": "fixture", "scope": "explicit_test_overrides", "errors": []}
              if cpu_fixture and memory_fixture else inspect_limits(proc, affinity))
    result["cpu_source"] = "test_override" if cpu_fixture else "kernel"
    result["memory_source"] = "test_override" if memory_fixture else "kernel"
    effective_cpu, effective_memory = cpu * 1000, memory_kb
    if not cpu_fixture:
        if result["status"] != "known":
            effective_cpu = 0
        else:
            effective_cpu = min(effective_cpu, result["affinity_cpus"] * 1000)
            if result["cpu_quota_millicores"] is not None:
                effective_cpu = min(effective_cpu, result["cpu_quota_millicores"])
    if not memory_fixture:
        if result["status"] != "known":
            effective_memory = 0
        elif result["memory_limit_bytes"] is not None:
            effective_memory = min(effective_memory, result["memory_limit_bytes"] // 1024)
    result["effective_cpu_millicores"] = effective_cpu
    result["effective_memory_kb"] = effective_memory
    return effective_cpu, effective_memory, result


if __name__ == "__main__":
    try:
        cpu, memory, result = model_limits(*sys.argv[1:])
        print(str(cpu) + "\t" + str(memory) + "\t" + json.dumps(result, separators=(",", ":")))
    except (OSError, ValueError, TypeError):
        sys.exit(1)
ACFS_PROCESS_LIMITS_PY
}

capacity_apply_process_limits() {
    local observed="" cpu="" memory="" details=""
    CAPACITY_EFFECTIVE_CPU_MILLI=0
    CAPACITY_EFFECTIVE_MEM_TOTAL_KB=0
    CAPACITY_PROCESS_LIMITS_JSON='{"status":"unavailable","errors":["collector_failed"]}'
    if observed="$(capacity_process_limits "$1" "$2")"; then
        IFS=$'\t' read -r cpu memory details <<< "$observed"
        if [[ "$cpu" =~ ^[0-9]{1,10}$ && "$memory" =~ ^[0-9]{1,16}$ && "$details" == \{*\} ]]; then
            CAPACITY_EFFECTIVE_CPU_MILLI="$cpu"
            CAPACITY_EFFECTIVE_MEM_TOTAL_KB="$memory"
            CAPACITY_PROCESS_LIMITS_JSON="$details"
            return 0
        fi
    fi
    echo "Warning: unable to observe process resource limits; no positive agent capacity is recommended." >&2
}

capacity_collect_model() {
    local cpu_count mem_total_kb disk_available_kb rch_available herdr_available
    cpu_count="$(capacity_read_cpu_count)"
    mem_total_kb="$(capacity_read_mem_total_kb)"
    disk_available_kb="$(capacity_read_disk_available_kb)"
    rch_available="$(capacity_tool_available rch ACFS_CAPACITY_RCH_AVAILABLE)"
    herdr_available="$(capacity_tool_available herdr ACFS_CAPACITY_HERDR_AVAILABLE)"
    CAPACITY_PHYSICAL_MEM_TOTAL_MIB=$((mem_total_kb / 1024))
    capacity_apply_process_limits "$cpu_count" "$mem_total_kb"
    mem_total_kb="$CAPACITY_EFFECTIVE_MEM_TOTAL_KB"
    # Keep fractional CPU quotas in millicores until dividing by the workload.

    local mem_total_mib disk_available_mib reserve_mib usable_mem_mib
    mem_total_mib=$((mem_total_kb / 1024))
    disk_available_mib=$((disk_available_kb / 1024))
    reserve_mib="$(capacity_max 4096 $((mem_total_mib / 10)))"
    usable_mem_mib=$((mem_total_mib - reserve_mib))
    (( usable_mem_mib < 0 )) && usable_mem_mib=0

    local per_agent_mib cpu_milli_per_agent
    case "$CAPACITY_WORKLOAD" in
        light)
            per_agent_mib=2048
            cpu_milli_per_agent=500
            ;;
        heavy)
            per_agent_mib=4096
            cpu_milli_per_agent=2000
            ;;
        *)
            per_agent_mib=3072
            cpu_milli_per_agent=1000
            ;;
    esac

    local disk_reserve_mib=10240
    local disk_per_agent_mib=2048
    local usable_disk_mib=$((disk_available_mib - disk_reserve_mib))
    (( usable_disk_mib < 0 )) && usable_disk_mib=0

    local mem_limit cpu_limit disk_limit safe_agents recommended_agents
    mem_limit=$((usable_mem_mib / per_agent_mib))
    cpu_limit=$((CAPACITY_EFFECTIVE_CPU_MILLI / cpu_milli_per_agent))
    disk_limit=$((usable_disk_mib / disk_per_agent_mib))
    safe_agents="$(capacity_min3 "$mem_limit" "$cpu_limit" "$disk_limit")"
    recommended_agents=$(((safe_agents * 70) / 100))
    if (( safe_agents > 0 && recommended_agents < 1 )); then
        recommended_agents=1
    fi

    local requested_agents="" profile_status="unknown" profile_reason="No profile requested"
    if [[ -n "$CAPACITY_PROFILE" ]]; then
        requested_agents="$(capacity_requested_agents "$CAPACITY_PROFILE" 2>/dev/null || true)"
        if [[ -z "$requested_agents" ]]; then
            profile_status="unknown"
            profile_reason="Profile did not include an agent count"
        elif (( requested_agents <= recommended_agents )); then
            profile_status="pass"
            profile_reason="Requested count is within the recommended tier"
        elif (( requested_agents <= safe_agents )); then
            profile_status="warn"
            profile_reason="Requested count is above recommended but within the safe maximum"
        else
            profile_status="fail"
            profile_reason="Requested count exceeds the safe maximum"
        fi
    fi

    local capacity_status="pass"
    if (( safe_agents < 1 )); then
        capacity_status="fail"
    elif [[ "$rch_available" != "true" ]]; then
        capacity_status="warn"
    fi

    CAPACITY_CPU_COUNT="$cpu_count"
    CAPACITY_MEM_TOTAL_MIB="$mem_total_mib"
    CAPACITY_DISK_AVAILABLE_MIB="$disk_available_mib"
    CAPACITY_RESERVE_MIB="$reserve_mib"
    CAPACITY_PER_AGENT_MIB="$per_agent_mib"
    CAPACITY_CPU_MILLI_PER_AGENT="$cpu_milli_per_agent"
    CAPACITY_DISK_RESERVE_MIB="$disk_reserve_mib"
    CAPACITY_DISK_PER_AGENT_MIB="$disk_per_agent_mib"
    CAPACITY_MEM_LIMIT="$mem_limit"
    CAPACITY_CPU_LIMIT="$cpu_limit"
    CAPACITY_DISK_LIMIT="$disk_limit"
    CAPACITY_SAFE_AGENTS="$safe_agents"
    CAPACITY_RECOMMENDED_AGENTS="$recommended_agents"
    CAPACITY_RCH_AVAILABLE="$rch_available"
    CAPACITY_HERDR_AVAILABLE="$herdr_available"
    CAPACITY_REQUESTED_AGENTS="$requested_agents"
    CAPACITY_PROFILE_STATUS="$profile_status"
    CAPACITY_PROFILE_REASON="$profile_reason"
    CAPACITY_STATUS="$capacity_status"
}

capacity_emit_json() {
    command -v jq >/dev/null 2>&1 || {
        echo "Error: jq is required for --json output" >&2
        return 1
    }

    jq -n \
        --arg generated_at "$(date -Iseconds)" \
        --arg workload "$CAPACITY_WORKLOAD" \
        --arg profile "$CAPACITY_PROFILE" \
        --arg profile_status "$CAPACITY_PROFILE_STATUS" \
        --arg profile_reason "$CAPACITY_PROFILE_REASON" \
        --argjson requested_agents "${CAPACITY_REQUESTED_AGENTS:-null}" \
        --argjson cpu_count "$CAPACITY_CPU_COUNT" \
        --argjson effective_cpu_millicores "$CAPACITY_EFFECTIVE_CPU_MILLI" \
        --argjson physical_mem_total_mib "$CAPACITY_PHYSICAL_MEM_TOTAL_MIB" \
        --argjson process_limits "$CAPACITY_PROCESS_LIMITS_JSON" \
        --argjson mem_total_mib "$CAPACITY_MEM_TOTAL_MIB" \
        --argjson disk_available_mib "$CAPACITY_DISK_AVAILABLE_MIB" \
        --argjson reserve_mib "$CAPACITY_RESERVE_MIB" \
        --argjson per_agent_mib "$CAPACITY_PER_AGENT_MIB" \
        --argjson cpu_milli_per_agent "$CAPACITY_CPU_MILLI_PER_AGENT" \
        --argjson disk_reserve_mib "$CAPACITY_DISK_RESERVE_MIB" \
        --argjson disk_per_agent_mib "$CAPACITY_DISK_PER_AGENT_MIB" \
        --argjson mem_limit "$CAPACITY_MEM_LIMIT" \
        --argjson cpu_limit "$CAPACITY_CPU_LIMIT" \
        --argjson disk_limit "$CAPACITY_DISK_LIMIT" \
        --argjson safe_agents "$CAPACITY_SAFE_AGENTS" \
        --argjson recommended_agents "$CAPACITY_RECOMMENDED_AGENTS" \
        --argjson rch_available "$CAPACITY_RCH_AVAILABLE" \
        --argjson herdr_available "$CAPACITY_HERDR_AVAILABLE" \
        --argjson recommend_herdr "$CAPACITY_RECOMMEND_HERDR" \
        --arg status "$CAPACITY_STATUS" '
        {
            schema_version: 1,
            generated_at: $generated_at,
            status: $status,
            host: {
                cpu_count: $cpu_count,
                effective_cpu_millicores: $effective_cpu_millicores,
                physical_mem_total_mib: $physical_mem_total_mib,
                mem_total_mib: $mem_total_mib,
                disk_available_mib: $disk_available_mib
            },
            resource_limits: $process_limits,
            tools: {
                rch: {available: $rch_available},
                herdr: {available: $herdr_available}
            },
            assumptions: {
                workload: $workload,
                reserve_mib: $reserve_mib,
                per_agent_mib: $per_agent_mib,
                cpu_milli_per_agent: $cpu_milli_per_agent,
                disk_reserve_mib: $disk_reserve_mib,
                disk_per_agent_mib: $disk_per_agent_mib
            },
            capacity: {
                memory_limited_agents: $mem_limit,
                cpu_limited_agents: $cpu_limit,
                disk_limited_agents: $disk_limit,
                recommended_agent_count: $recommended_agents,
                safe_agent_count: $safe_agents,
                max_agent_count: $safe_agents
            },
            profile_check: {
                requested_profile: (if $profile == "" then null else $profile end),
                requested_agents: $requested_agents,
                status: $profile_status,
                reason: $profile_reason
            },
            recommendations: (
                [
                    if $process_limits.status == "unavailable" then "Unable to observe process resource limits; repair cgroup/Python visibility before launching agents." else empty end,
                    if $rch_available then empty else "Install or repair RCH before launching CPU-heavy Rust build/test swarms." end,
                    if $safe_agents < 1 then "Increase RAM, CPU, or disk headroom before launching agents." else empty end,
                    if $recommended_agents > 0 then "Start at the recommended tier, then increase only after status/doctor checks stay clean." else empty end
                ]
            ),
            herdr: {
                recommended: $recommend_herdr,
                agent_count: (if $recommend_herdr then $recommended_agents else null end),
                launch_plan: (if $recommend_herdr then "Run acfs agents spawn inside the herdr workspace of the project, sized to the recommended agent count; each agent gets its own tab and the kickoff prompt from the command palette." else null end),
                profiles: (
                    if $recommend_herdr then
                        def profile_status($count):
                            if $count <= $recommended_agents then "pass"
                            elif $count <= $safe_agents then "warn"
                            else "fail"
                            end;
                        [
                            {agents: 5, cc: 2, cod: 2, agy: 1, label: "swarm-5"},
                            {agents: 10, cc: 4, cod: 4, agy: 2, label: "swarm-10"},
                            {agents: 25, cc: 10, cod: 10, agy: 5, label: "swarm-25"},
                            {agents: 50, cc: 20, cod: 20, agy: 10, label: "swarm-50"}
                        ] | map(. + {
                            status: profile_status(.agents),
                            command: ("acfs agents spawn --claude=" + (.cc | tostring) + " --codex=" + (.cod | tostring) + " --agy=" + (.agy | tostring)),
                            rch_policy: "Use rch exec -- for cargo build/test/check/clippy/bench/run/doc commands inside every agent pane.",
                            agent_mail: "Register agents, send a start message on the bead thread, and reserve files before edits.",
                            beads: "Use br ready --json and bv --robot-triage for assignment truth; never launch bare bv."
                        })
                    else
                        []
                    end
                )
            }
        }'
}

capacity_emit_human() {
    echo "ACFS Capacity Report"
    echo "Workload: $CAPACITY_WORKLOAD"
    echo ""
    echo "Host / Current Process Budget"
    echo "  Visible CPU cores:   $CAPACITY_CPU_COUNT"
    echo "  Effective CPU:       ${CAPACITY_EFFECTIVE_CPU_MILLI} millicores"
    echo "  Host memory:         ${CAPACITY_PHYSICAL_MEM_TOTAL_MIB} MiB"
    echo "  Effective memory:    ${CAPACITY_MEM_TOTAL_MIB} MiB"
    echo "  Disk available:      ${CAPACITY_DISK_AVAILABLE_MIB} MiB"
    echo "  Scope:               current process and visible cgroup ancestors"
    echo ""
    echo "Agent Capacity"
    echo "  Recommended agents:  $CAPACITY_RECOMMENDED_AGENTS"
    echo "  Safe max agents:     $CAPACITY_SAFE_AGENTS"
    echo "  Memory limit:        $CAPACITY_MEM_LIMIT"
    echo "  CPU limit:           $CAPACITY_CPU_LIMIT"
    echo "  Disk limit:          $CAPACITY_DISK_LIMIT"
    echo ""
    echo "Assumptions"
    echo "  Reserved memory:     ${CAPACITY_RESERVE_MIB} MiB"
    echo "  Per-agent memory:    ${CAPACITY_PER_AGENT_MIB} MiB"
    echo "  Per-agent CPU:       ${CAPACITY_CPU_MILLI_PER_AGENT} milli-cores"
    echo ""
    echo "Tooling"
    echo "  RCH available:       $CAPACITY_RCH_AVAILABLE"
    echo "  herdr available:     $CAPACITY_HERDR_AVAILABLE"

    if [[ -n "$CAPACITY_PROFILE" ]]; then
        echo ""
        echo "Profile Check"
        echo "  Requested:           $CAPACITY_PROFILE"
        echo "  Status:              $CAPACITY_PROFILE_STATUS"
        echo "  Reason:              $CAPACITY_PROFILE_REASON"
    fi

    if [[ "$CAPACITY_RECOMMEND_HERDR" == "true" ]]; then
        echo ""
        echo "herdr Recommendation"
        echo "  Agent count:         $CAPACITY_RECOMMENDED_AGENTS"
        echo "  Plan:                acfs agents spawn in the project's herdr workspace, one tab per agent"
        echo ""
        echo "Launch Profiles"
        echo "  5 agents:            acfs agents spawn --claude=2 --codex=2 --agy=1"
        echo "  10 agents:           acfs agents spawn --claude=4 --codex=4 --agy=2"
        echo "  25 agents:           acfs agents spawn --claude=10 --codex=10 --agy=5"
        echo "  50 agents:           acfs agents spawn --claude=20 --codex=20 --agy=10"
        echo ""
        echo "Coordination"
        echo "  RCH:                 use rch exec -- for CPU-heavy Rust build/test commands"
        echo "  Agent Mail:          register, announce start, reserve files before edits"
        echo "  Beads/BV:            use br ready --json and bv --robot-triage; never bare bv"
    fi

    if [[ "$CAPACITY_RCH_AVAILABLE" != "true" ]]; then
        echo ""
        echo "Warning: RCH is not available; offload CPU-heavy Rust builds/tests before scaling."
    fi
}

# ------------------------------------------------------------
# Guard: the host's live headroom, read before another agent starts
# ------------------------------------------------------------

capacity_guard_threshold() {
    local value="$1" default="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$((10#$value))"
    else
        printf '%s\n' "$default"
    fi
}

# A /proc/meminfo field in kB; nothing when it can't be read.
capacity_guard_meminfo_kb() {
    local field="$1"
    awk -v field="$field:" '$1 == field {print $2; exit}' "${ACFS_CAPACITY_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null || true
}

# A PSI avg60 ("some" or "full") from a pressure file (/proc/pressure/memory
# or a cgroup's memory.pressure); nothing when the file can't be read.
capacity_guard_psi_avg60() {
    local file="$1" kind="$2"
    awk -v kind="$kind" '$1 == kind {
            for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/^avg60=/, "", $i); print $i; exit }
        }' "$file" 2>/dev/null || true
}

# What systemd-detect-virt -c says ("lxc" in an Incus system container), or
# "none".
capacity_guard_container_virt() {
    local virt="${ACFS_CAPACITY_VIRT:-}" detect_bin=""
    if [[ -z "$virt" ]]; then
        detect_bin="$(capacity_system_binary_path systemd-detect-virt 2>/dev/null || true)"
        [[ -n "$detect_bin" ]] && virt="$("$detect_bin" --container 2>/dev/null || true)"
    fi
    [[ "$virt" =~ ^[a-z0-9-]+$ ]] || virt="none"
    printf '%s\n' "$virt"
}

# A slice's cgroup path below its manager: a dash in a slice name nests it,
# so acfs-agents.slice is acfs.slice/acfs-agents.slice.
capacity_guard_slice_path() {
    local -a parts=()
    local part prefix="" path=""
    IFS=- read -r -a parts <<<"${1%.slice}"
    for part in "${parts[@]}"; do
        prefix="${prefix:+$prefix-}$part"
        path="${path:+$path/}$prefix.slice"
    done
    printf '%s\n' "$path"
}

# A cgroup's memory.stat field in bytes; nothing when unreadable.
capacity_guard_memory_stat() {
    awk -v field="$2" '$1 == field && $2 ~ /^[0-9]+$/ && length($2) < 16 {print $2; exit}' "$1/memory.stat" 2>/dev/null || true
}

# The first line of a cgroup v2 file when it is a byte count or "max";
# nothing otherwise.
capacity_guard_cgroup_value() {
    local value=""
    { IFS= read -r value <"$1"; } 2>/dev/null || true
    [[ "$value" =~ ^(0|[1-9][0-9]{0,18}|max)$ ]] && printf '%s\n' "$value"
    return 0
}

# "<fstype> <size_kb> <avail_kb> <mountpoint>" for the filesystem holding a path.
capacity_guard_df() {
    local path="$1" df_bin=""
    df_bin="$(capacity_system_binary_path df 2>/dev/null || true)"
    [[ -n "$df_bin" ]] || return 1
    "$df_bin" -PkT -- "$path" 2>/dev/null | awk 'NR == 2 && $3 > 0 {print $2, $3, $5, $7; exit}'
}

# Runs a command with stderr dropped, under a 10-second timeout when one
# exists, so a wedged rch or herdr can't hang spawn or doctor.
capacity_guard_run_timed() {
    local timeout_bin=""
    timeout_bin="$(capacity_system_binary_path timeout 2>/dev/null || true)"
    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" 10 "$@" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
}

# Sets CAPACITY_GUARD_RCH_{POSTURE,WORKERS,HEALTHY}. Posture is rch's own
# word (remote_ready, local_only, ...), "not_installed" or "unknown".
capacity_guard_read_rch() {
    CAPACITY_GUARD_RCH_POSTURE="not_installed"
    CAPACITY_GUARD_RCH_WORKERS=""
    CAPACITY_GUARD_RCH_HEALTHY=""

    [[ "${ACFS_CAPACITY_RCH_AVAILABLE:-}" == false ]] && return 0
    local rch_bin="" status_json=""
    rch_bin="$(capacity_system_binary_path rch 2>/dev/null || true)"
    [[ -n "$rch_bin" ]] || return 0
    CAPACITY_GUARD_RCH_POSTURE="unknown"
    command -v jq >/dev/null 2>&1 || return 0

    status_json="$(capacity_guard_run_timed "$rch_bin" status --json || true)"

    local parsed=""
    parsed="$(jq -r '
        .data as $d
        | [($d.posture // "unknown"),
           ($d.daemon.daemon.workers_total // "" | tostring),
           ($d.daemon.daemon.workers_healthy // "" | tostring)]
        | join(" ")' <<<"$status_json" 2>/dev/null || true)"
    [[ -n "$parsed" ]] || return 0
    read -r CAPACITY_GUARD_RCH_POSTURE CAPACITY_GUARD_RCH_WORKERS CAPACITY_GUARD_RCH_HEALTHY <<<"$parsed"
    [[ "$CAPACITY_GUARD_RCH_POSTURE" =~ ^[A-Za-z0-9_-]+$ ]] || CAPACITY_GUARD_RCH_POSTURE="unknown"
    [[ "$CAPACITY_GUARD_RCH_WORKERS" =~ ^[0-9]+$ ]] || CAPACITY_GUARD_RCH_WORKERS=""
    [[ "$CAPACITY_GUARD_RCH_HEALTHY" =~ ^[0-9]+$ ]] || CAPACITY_GUARD_RCH_HEALTHY=""
}

# How many agents herdr lists across every workspace; nothing when unknown.
capacity_guard_live_agents() {
    [[ "${ACFS_CAPACITY_HERDR_AVAILABLE:-}" == false ]] && return 0
    local herdr_bin=""
    herdr_bin="$(capacity_system_binary_path herdr 2>/dev/null || true)"
    [[ -n "$herdr_bin" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    capacity_guard_run_timed "$herdr_bin" agent list | jq -r '[.result.agents[]?] | length' 2>/dev/null || true
}

# Is decimal $1 greater than decimal $2?
capacity_guard_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) > (b + 0)) }'
}

capacity_guard_collect() {
    local min_mem_mib min_disk_pct max_psi_full agent_mib gate_mib max_cg_pct
    min_mem_mib="$(capacity_guard_threshold "${ACFS_CAPACITY_GUARD_MIN_MEM_MIB:-}" 4096)"
    min_disk_pct="$(capacity_guard_threshold "${ACFS_CAPACITY_GUARD_MIN_DISK_PCT:-}" 10)"
    max_psi_full="$(capacity_guard_threshold "${ACFS_CAPACITY_GUARD_MAX_PSI_FULL:-}" 10)"
    agent_mib="$(capacity_guard_threshold "${ACFS_CAPACITY_GUARD_AGENT_MIB:-}" 1024)"
    gate_mib="$(capacity_guard_threshold "${ACFS_CAPACITY_GUARD_GATE_MIB:-}" 4096)"
    max_cg_pct="$(capacity_guard_threshold "${ACFS_CAPACITY_GUARD_MAX_CGROUP_PCT:-}" 80)"
    (( agent_mib > 0 )) || agent_mib=1024
    (( max_cg_pct > 0 && max_cg_pct <= 100 )) || max_cg_pct=80

    CAPACITY_GUARD_MIN_MEM_MIB="$min_mem_mib"
    CAPACITY_GUARD_MIN_DISK_PCT="$min_disk_pct"
    CAPACITY_GUARD_MAX_PSI_FULL="$max_psi_full"
    CAPACITY_GUARD_MAX_CGROUP_PCT="$max_cg_pct"
    CAPACITY_GUARD_AGENT_MIB="$agent_mib"
    CAPACITY_GUARD_GATE_MIB="$gate_mib"
    CAPACITY_GUARD_REASONS=()
    CAPACITY_GUARD_WARNINGS=()
    CAPACITY_GUARD_READABLE=true

    local mem_total_kb mem_avail_kb swap_total_kb swap_free_kb
    mem_total_kb="$(capacity_guard_meminfo_kb MemTotal)"
    mem_avail_kb="$(capacity_guard_meminfo_kb MemAvailable)"
    swap_total_kb="$(capacity_guard_meminfo_kb SwapTotal)"
    swap_free_kb="$(capacity_guard_meminfo_kb SwapFree)"
    [[ "$mem_total_kb" =~ ^[0-9]+$ ]] || mem_total_kb=""
    [[ "$swap_total_kb" =~ ^[0-9]+$ ]] || swap_total_kb=""
    [[ "$swap_free_kb" =~ ^[0-9]+$ ]] || swap_free_kb=""
    CAPACITY_GUARD_MEM_TOTAL_MIB="${mem_total_kb:+$((mem_total_kb / 1024))}"
    CAPACITY_GUARD_SWAP_TOTAL_MIB="${swap_total_kb:+$((swap_total_kb / 1024))}"
    CAPACITY_GUARD_SWAP_FREE_MIB="${swap_free_kb:+$((swap_free_kb / 1024))}"
    if [[ "$mem_avail_kb" =~ ^[0-9]+$ ]]; then
        CAPACITY_GUARD_MEM_AVAILABLE_MIB=$((mem_avail_kb / 1024))
        if (( CAPACITY_GUARD_MEM_AVAILABLE_MIB < min_mem_mib )); then
            CAPACITY_GUARD_REASONS+=("MemAvailable is ${CAPACITY_GUARD_MEM_AVAILABLE_MIB} MiB, under ${min_mem_mib} MiB")
        fi
    else
        CAPACITY_GUARD_MEM_AVAILABLE_MIB=""
        CAPACITY_GUARD_READABLE=false
    fi
    if [[ "$swap_total_kb" == 0 ]]; then
        CAPACITY_GUARD_WARNINGS+=("the host has no swap: a memory spike goes straight to the OOM killer")
    fi

    # In an Incus system container, /sys/fs/cgroup is the container's own
    # cgroup: its memory.high (the soft limit) is what the swarm may use, and
    # its memory.pressure is the container's PSI, where /proc/pressure would
    # be the host's.
    local cgroot="${ACFS_CAPACITY_CGROUP_ROOT:-/sys/fs/cgroup}"
    local psi_memory_file="${ACFS_CAPACITY_PSI_DIR:-/proc/pressure}/memory"
    local psi_cpu_file="${ACFS_CAPACITY_PSI_DIR:-/proc/pressure}/cpu"
    local cg_current="" cg_high="" cg_max="" cg_limit="" cg_room_mib=""
    CAPACITY_GUARD_VIRT="$(capacity_guard_container_virt)"
    CAPACITY_GUARD_PSI_SOURCE="proc"
    CAPACITY_GUARD_CG_CURRENT_MIB=""
    CAPACITY_GUARD_CG_WORKING_SET_MIB=""
    CAPACITY_GUARD_CG_LIMIT_MIB=""
    CAPACITY_GUARD_CG_LIMIT_FILE=""
    CAPACITY_GUARD_CG_USED_PCT=""
    if [[ "$CAPACITY_GUARD_VIRT" == lxc ]]; then
        psi_memory_file="$cgroot/memory.pressure"
        psi_cpu_file="$cgroot/cpu.pressure"
        CAPACITY_GUARD_PSI_SOURCE="cgroup"
        cg_current="$(capacity_guard_cgroup_value "$cgroot/memory.current")"
        cg_high="$(capacity_guard_cgroup_value "$cgroot/memory.high")"
        cg_max="$(capacity_guard_cgroup_value "$cgroot/memory.max")"
        # A limit past 2^50 bytes (1 PiB) is no limit, and keeps the
        # percentage arithmetic below inside 64 bits.
        if [[ "$cg_high" =~ ^[0-9]+$ ]] && (( ${#cg_high} < 16 && cg_high > 0 && cg_high < 1125899906842624 )); then
            cg_limit="$cg_high"
            CAPACITY_GUARD_CG_LIMIT_FILE="memory.high"
        elif [[ "$cg_max" =~ ^[0-9]+$ ]] && (( ${#cg_max} < 16 && cg_max > 0 && cg_max < 1125899906842624 )); then
            cg_limit="$cg_max"
            CAPACITY_GUARD_CG_LIMIT_FILE="memory.max"
        fi
        if [[ ! "$cg_current" =~ ^[0-9]+$ ]] || (( ${#cg_current} >= 16 )); then
            CAPACITY_GUARD_READABLE=false
        else
            CAPACITY_GUARD_CG_CURRENT_MIB=$((cg_current / 1048576))
            # memory.current counts page cache, which a soft limit leaves in
            # place until usage reaches memory.high, so a busy container sits
            # near 100% with most of it reclaimable. The admission line is
            # for the working set: memory.current less inactive_file, the
            # kubelet's measure.
            local cg_inactive_file="" cg_working_set="$cg_current"
            cg_inactive_file="$(capacity_guard_memory_stat "$cgroot" inactive_file)"
            if [[ -n "$cg_inactive_file" ]]; then
                cg_working_set=$((cg_current - cg_inactive_file))
                (( cg_working_set >= 0 )) || cg_working_set=0
            fi
            CAPACITY_GUARD_CG_WORKING_SET_MIB=$((cg_working_set / 1048576))
            if [[ -n "$cg_limit" ]]; then
                CAPACITY_GUARD_CG_LIMIT_MIB=$((cg_limit / 1048576))
                CAPACITY_GUARD_CG_USED_PCT=$((cg_working_set * 100 / cg_limit))
                cg_room_mib=$(((cg_limit * max_cg_pct / 100 - cg_working_set) / 1048576))
                (( cg_room_mib >= 0 )) || cg_room_mib=0
                if (( cg_working_set * 100 > cg_limit * max_cg_pct )); then
                    CAPACITY_GUARD_REASONS+=("the container's working set (memory.current less inactive_file) is ${CAPACITY_GUARD_CG_WORKING_SET_MIB} MiB, ${CAPACITY_GUARD_CG_USED_PCT}% of ${CAPACITY_GUARD_CG_LIMIT_FILE} (${CAPACITY_GUARD_CG_LIMIT_MIB} MiB), over ${max_cg_pct}%")
                fi
            else
                CAPACITY_GUARD_WARNINGS+=("the container has no memory limit (memory.high and memory.max are max): the swarm can take the host's RAM")
            fi
        fi
    fi

    CAPACITY_GUARD_PSI_MEMORY_SOME="$(capacity_guard_psi_avg60 "$psi_memory_file" some)"
    CAPACITY_GUARD_PSI_MEMORY_FULL="$(capacity_guard_psi_avg60 "$psi_memory_file" full)"
    CAPACITY_GUARD_PSI_CPU_SOME="$(capacity_guard_psi_avg60 "$psi_cpu_file" some)"
    local psi_var
    for psi_var in CAPACITY_GUARD_PSI_MEMORY_SOME CAPACITY_GUARD_PSI_MEMORY_FULL CAPACITY_GUARD_PSI_CPU_SOME; do
        [[ "${!psi_var}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || printf -v "$psi_var" '%s' ""
    done
    if [[ -n "$CAPACITY_GUARD_PSI_MEMORY_FULL" ]] && capacity_guard_gt "$CAPACITY_GUARD_PSI_MEMORY_FULL" "$max_psi_full"; then
        CAPACITY_GUARD_REASONS+=("PSI memory full avg60 is ${CAPACITY_GUARD_PSI_MEMORY_FULL}, over ${max_psi_full}")
    fi

    # The acfs slices (acfs-ioo3.5) under the user's manager, each one that
    # exists. The agents' slice can stall while the services' slice runs, so
    # its own "full" line turns the guard red too.
    local uid="${ACFS_CAPACITY_UID:-}" slice slice_file slice_some slice_full
    [[ "$uid" =~ ^[0-9]+$ ]] || uid="$(id -u 2>/dev/null || true)"
    CAPACITY_GUARD_SLICE_LINES=()
    if [[ "$uid" =~ ^[0-9]+$ ]]; then
        for slice in acfs-services acfs-background acfs-agents; do
            slice_file="$cgroot/user.slice/user-$uid.slice/user@$uid.service/$(capacity_guard_slice_path "$slice.slice")/memory.pressure"
            [[ -r "$slice_file" ]] || continue
            slice_some="$(capacity_guard_psi_avg60 "$slice_file" some)"
            slice_full="$(capacity_guard_psi_avg60 "$slice_file" full)"
            [[ "$slice_some" =~ ^[0-9]+(\.[0-9]+)?$ ]] || slice_some="-"
            [[ "$slice_full" =~ ^[0-9]+(\.[0-9]+)?$ ]] || slice_full="-"
            CAPACITY_GUARD_SLICE_LINES+=("$slice.slice $slice_some $slice_full")
            if [[ "$slice" == acfs-agents && "$slice_full" != "-" ]] && capacity_guard_gt "$slice_full" "$max_psi_full"; then
                CAPACITY_GUARD_REASONS+=("PSI memory full avg60 of acfs-agents.slice is ${slice_full}, over ${max_psi_full}")
            fi
        done
    fi

    # Filesystems: the work directory and the temp directories, each mount once.
    local -a fs_roles=() fs_paths=()
    fs_roles+=(work)
    fs_paths+=("${ACFS_CAPACITY_WORK_DIR:-$PWD}")
    if [[ -n "${ACFS_CAPACITY_TEMP_DIR:-}" ]]; then
        fs_roles+=(temp)
        fs_paths+=("$ACFS_CAPACITY_TEMP_DIR")
    else
        fs_roles+=(temp)
        fs_paths+=("${TMPDIR:-/tmp}")
        fs_roles+=(temp)
        fs_paths+=(/tmp)
    fi

    CAPACITY_GUARD_FS_LINES=()
    local i line fstype size_kb avail_kb mount free_pct used_pct seen=" "
    for i in "${!fs_paths[@]}"; do
        line="$(capacity_guard_df "${fs_paths[$i]}" || true)"
        [[ -n "$line" ]] || continue
        read -r fstype size_kb avail_kb mount <<<"$line"
        [[ "$size_kb" =~ ^[0-9]+$ && "$avail_kb" =~ ^[0-9]+$ ]] || continue
        [[ "$seen" == *" $mount "* ]] && continue
        seen+="$mount "
        free_pct=$((avail_kb * 100 / size_kb))
        used_pct=$((100 - free_pct))
        CAPACITY_GUARD_FS_LINES+=("${fs_roles[$i]} $mount $fstype $((size_kb / 1024)) $((avail_kb / 1024)) $free_pct")
        if (( free_pct < min_disk_pct )); then
            CAPACITY_GUARD_REASONS+=("$mount (${fs_roles[$i]}) has ${free_pct}% free, under ${min_disk_pct}%")
        fi
        if [[ "$fstype" == tmpfs && "$mount" == /tmp ]] && (( used_pct > 50 )); then
            CAPACITY_GUARD_WARNINGS+=("/tmp is a tmpfs ${used_pct}% full: it holds RAM that agents need")
        fi
    done

    # rch and herdr only warn and inform, never turn the guard red, so
    # --check (spawn's question) doesn't wait on them.
    if [[ "$CAPACITY_GUARD_CHECK" == true ]]; then
        CAPACITY_GUARD_RCH_POSTURE="skipped"
        CAPACITY_GUARD_RCH_WORKERS=""
        CAPACITY_GUARD_RCH_HEALTHY=""
    else
        capacity_guard_read_rch
    fi
    case "$CAPACITY_GUARD_RCH_POSTURE" in
        skipped) ;;
        not_installed)
            CAPACITY_GUARD_WARNINGS+=("rch is not installed: every build runs locally") ;;
        unknown)
            CAPACITY_GUARD_WARNINGS+=("rch's posture is unknown (rch status --json gave nothing usable)") ;;
        *)
            if [[ "$CAPACITY_GUARD_RCH_POSTURE" == local_only || "$CAPACITY_GUARD_RCH_HEALTHY" == 0 || "$CAPACITY_GUARD_RCH_WORKERS" == 0 ]]; then
                CAPACITY_GUARD_WARNINGS+=("rch has no healthy workers (posture $CAPACITY_GUARD_RCH_POSTURE): every build runs locally")
            fi
            ;;
    esac

    CAPACITY_GUARD_LIVE_AGENTS=""
    [[ "$CAPACITY_GUARD_CHECK" == true ]] || CAPACITY_GUARD_LIVE_AGENTS="$(capacity_guard_live_agents)"
    [[ "$CAPACITY_GUARD_LIVE_AGENTS" =~ ^[0-9]+$ ]] || CAPACITY_GUARD_LIVE_AGENTS=""
    CAPACITY_GUARD_MORE_AGENTS=""
    CAPACITY_GUARD_MAX_AGENTS=""
    if [[ -n "$CAPACITY_GUARD_MEM_AVAILABLE_MIB" ]]; then
        CAPACITY_GUARD_MORE_AGENTS=$(((CAPACITY_GUARD_MEM_AVAILABLE_MIB - gate_mib) / agent_mib))
        # In a container, the room left under the admission line can be less
        # than MemAvailable, which lxcfs may show as the host's.
        if [[ -n "$cg_room_mib" ]] && (( cg_room_mib / agent_mib < CAPACITY_GUARD_MORE_AGENTS )); then
            CAPACITY_GUARD_MORE_AGENTS=$((cg_room_mib / agent_mib))
        fi
        # A red guard has room for none, whatever memory says.
        if (( CAPACITY_GUARD_MORE_AGENTS < 0 || ${#CAPACITY_GUARD_REASONS[@]} > 0 )); then
            CAPACITY_GUARD_MORE_AGENTS=0
        fi
        if [[ -n "$CAPACITY_GUARD_LIVE_AGENTS" ]]; then
            CAPACITY_GUARD_MAX_AGENTS=$((CAPACITY_GUARD_LIVE_AGENTS + CAPACITY_GUARD_MORE_AGENTS))
        fi
    fi

    if (( ${#CAPACITY_GUARD_REASONS[@]} > 0 )); then
        CAPACITY_GUARD_STATUS="red"
    elif [[ "$CAPACITY_GUARD_READABLE" != true ]]; then
        CAPACITY_GUARD_STATUS="unknown"
    elif (( ${#CAPACITY_GUARD_WARNINGS[@]} > 0 )); then
        CAPACITY_GUARD_STATUS="yellow"
    else
        CAPACITY_GUARD_STATUS="green"
    fi
}

capacity_guard_emit_json() {
    command -v jq >/dev/null 2>&1 || {
        echo "Error: jq is required for --json output" >&2
        return 1
    }

    local reasons_json warnings_json fs_json slices_json
    reasons_json="$(printf '%s\n' "${CAPACITY_GUARD_REASONS[@]}" | jq -R . | jq -s -c 'map(select(. != ""))')"
    warnings_json="$(printf '%s\n' "${CAPACITY_GUARD_WARNINGS[@]}" | jq -R . | jq -s -c 'map(select(. != ""))')"
    fs_json="$(printf '%s\n' "${CAPACITY_GUARD_FS_LINES[@]}" | jq -R -c 'select(. != "") | split(" ")
        | {role: .[0], mount: .[1], fstype: .[2], size_mib: (.[3] | tonumber),
           available_mib: (.[4] | tonumber), free_percent: (.[5] | tonumber)}' | jq -s -c .)"
    slices_json="$(printf '%s\n' "${CAPACITY_GUARD_SLICE_LINES[@]}" | jq -R -c 'select(. != "") | split(" ")
        | {slice: .[0],
           memory_some_avg60: (if .[1] == "-" then null else (.[1] | tonumber) end),
           memory_full_avg60: (if .[2] == "-" then null else (.[2] | tonumber) end)}' | jq -s -c .)"

    jq -n \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg status "$CAPACITY_GUARD_STATUS" \
        --argjson reasons "$reasons_json" \
        --argjson warnings "$warnings_json" \
        --argjson filesystems "$fs_json" \
        --argjson slices "$slices_json" \
        --arg virt "$CAPACITY_GUARD_VIRT" \
        --arg psi_source "$CAPACITY_GUARD_PSI_SOURCE" \
        --arg cg_current "$CAPACITY_GUARD_CG_CURRENT_MIB" \
        --arg cg_working_set "$CAPACITY_GUARD_CG_WORKING_SET_MIB" \
        --arg cg_limit "$CAPACITY_GUARD_CG_LIMIT_MIB" \
        --arg cg_limit_file "$CAPACITY_GUARD_CG_LIMIT_FILE" \
        --arg cg_used "$CAPACITY_GUARD_CG_USED_PCT" \
        --argjson max_cg "$CAPACITY_GUARD_MAX_CGROUP_PCT" \
        --arg mem_total "$CAPACITY_GUARD_MEM_TOTAL_MIB" \
        --arg mem_available "$CAPACITY_GUARD_MEM_AVAILABLE_MIB" \
        --arg swap_total "$CAPACITY_GUARD_SWAP_TOTAL_MIB" \
        --arg swap_free "$CAPACITY_GUARD_SWAP_FREE_MIB" \
        --arg psi_mem_some "$CAPACITY_GUARD_PSI_MEMORY_SOME" \
        --arg psi_mem_full "$CAPACITY_GUARD_PSI_MEMORY_FULL" \
        --arg psi_cpu_some "$CAPACITY_GUARD_PSI_CPU_SOME" \
        --arg rch_posture "$CAPACITY_GUARD_RCH_POSTURE" \
        --arg rch_workers "$CAPACITY_GUARD_RCH_WORKERS" \
        --arg rch_healthy "$CAPACITY_GUARD_RCH_HEALTHY" \
        --arg live "$CAPACITY_GUARD_LIVE_AGENTS" \
        --arg more "$CAPACITY_GUARD_MORE_AGENTS" \
        --arg max "$CAPACITY_GUARD_MAX_AGENTS" \
        --argjson min_mem "$CAPACITY_GUARD_MIN_MEM_MIB" \
        --argjson min_disk "$CAPACITY_GUARD_MIN_DISK_PCT" \
        --argjson max_psi "$CAPACITY_GUARD_MAX_PSI_FULL" \
        --argjson agent_mib "$CAPACITY_GUARD_AGENT_MIB" \
        --argjson gate_mib "$CAPACITY_GUARD_GATE_MIB" '
        def num: if . == "" then null else tonumber end;
        {
            schema_version: 1,
            generated_at: $generated_at,
            status: $status,
            reasons: $reasons,
            warnings: $warnings,
            memory: {
                total_mib: ($mem_total | num),
                available_mib: ($mem_available | num),
                swap_total_mib: ($swap_total | num),
                swap_free_mib: ($swap_free | num)
            },
            container: {
                virt: $virt,
                memory_current_mib: ($cg_current | num),
                memory_working_set_mib: ($cg_working_set | num),
                memory_limit_mib: ($cg_limit | num),
                memory_limit_file: (if $cg_limit_file == "" then null else $cg_limit_file end),
                memory_used_percent: ($cg_used | num)
            },
            pressure: {
                source: $psi_source,
                memory_some_avg60: ($psi_mem_some | num),
                memory_full_avg60: ($psi_mem_full | num),
                cpu_some_avg60: ($psi_cpu_some | num),
                slices: $slices
            },
            filesystems: $filesystems,
            rch: {
                posture: $rch_posture,
                workers_total: ($rch_workers | num),
                workers_healthy: ($rch_healthy | num)
            },
            agents: {
                live: ($live | num),
                more: ($more | num),
                suggested_max: ($max | num)
            },
            thresholds: {
                min_mem_available_mib: $min_mem,
                min_disk_free_percent: $min_disk,
                max_psi_memory_full_avg60: $max_psi,
                max_container_memory_percent: $max_cg,
                per_agent_mib: $agent_mib,
                gate_headroom_mib: $gate_mib
            }
        }'
}

capacity_guard_emit_human() {
    local line role mount fstype size_mib avail_mib free_pct item
    echo "Host capacity guard: $CAPACITY_GUARD_STATUS"
    echo "  MemAvailable:        ${CAPACITY_GUARD_MEM_AVAILABLE_MIB:-unknown} MiB of ${CAPACITY_GUARD_MEM_TOTAL_MIB:-unknown} MiB (red under ${CAPACITY_GUARD_MIN_MEM_MIB} MiB)"
    if [[ "$CAPACITY_GUARD_SWAP_TOTAL_MIB" == 0 ]]; then
        echo "  Swap:                none"
    else
        echo "  Swap:                ${CAPACITY_GUARD_SWAP_FREE_MIB:-unknown} MiB free of ${CAPACITY_GUARD_SWAP_TOTAL_MIB:-unknown} MiB"
    fi
    if [[ "$CAPACITY_GUARD_VIRT" == lxc ]]; then
        if [[ -z "$CAPACITY_GUARD_CG_CURRENT_MIB" ]]; then
            echo "  Container (lxc):     memory.current unreadable"
        elif [[ -n "$CAPACITY_GUARD_CG_LIMIT_MIB" ]]; then
            echo "  Container (lxc):     working set ${CAPACITY_GUARD_CG_WORKING_SET_MIB} MiB (memory.current ${CAPACITY_GUARD_CG_CURRENT_MIB} MiB), ${CAPACITY_GUARD_CG_USED_PCT}% of ${CAPACITY_GUARD_CG_LIMIT_FILE} ${CAPACITY_GUARD_CG_LIMIT_MIB} MiB (red over ${CAPACITY_GUARD_MAX_CGROUP_PCT}%)"
        else
            echo "  Container (lxc):     memory.current ${CAPACITY_GUARD_CG_CURRENT_MIB} MiB, no memory limit"
        fi
    fi
    printf '  %-20s memory some %s, full %s (red over %s); cpu some %s\n' \
        "PSI avg60 ($CAPACITY_GUARD_PSI_SOURCE):" "${CAPACITY_GUARD_PSI_MEMORY_SOME:-n/a}" \
        "${CAPACITY_GUARD_PSI_MEMORY_FULL:-n/a}" "$CAPACITY_GUARD_MAX_PSI_FULL" "${CAPACITY_GUARD_PSI_CPU_SOME:-n/a}"
    local slice slice_some slice_full
    for line in "${CAPACITY_GUARD_SLICE_LINES[@]}"; do
        read -r slice slice_some slice_full <<<"$line"
        echo "    $slice: memory some ${slice_some/#-/n/a}, full ${slice_full/#-/n/a}"
    done
    for line in "${CAPACITY_GUARD_FS_LINES[@]}"; do
        read -r role mount fstype size_mib avail_mib free_pct <<<"$line"
        printf '  Disk (%s):%*s%s %s: %s MiB free of %s MiB, %s%% (red under %s%%)\n' \
            "$role" $((13 - ${#role})) "" "$mount" "$fstype" "$avail_mib" "$size_mib" "$free_pct" "$CAPACITY_GUARD_MIN_DISK_PCT"
    done
    echo "  rch:                 $CAPACITY_GUARD_RCH_POSTURE, ${CAPACITY_GUARD_RCH_HEALTHY:-?} of ${CAPACITY_GUARD_RCH_WORKERS:-?} workers healthy"
    echo "  Agents:              ${CAPACITY_GUARD_LIVE_AGENTS:-unknown} live; room for ${CAPACITY_GUARD_MORE_AGENTS:-unknown} more; suggested max ${CAPACITY_GUARD_MAX_AGENTS:-unknown}"
    echo "                       (${CAPACITY_GUARD_AGENT_MIB} MiB per agent, ${CAPACITY_GUARD_GATE_MIB} MiB kept for one gate)"
    for item in "${CAPACITY_GUARD_REASONS[@]}"; do
        echo "  RED: $item"
    done
    for item in "${CAPACITY_GUARD_WARNINGS[@]}"; do
        echo "  WARN: $item"
    done
}

capacity_guard_main() {
    capacity_guard_collect

    if [[ "$CAPACITY_GUARD_CHECK" == true ]]; then
        local item
        case "$CAPACITY_GUARD_STATUS" in
            red)
                for item in "${CAPACITY_GUARD_REASONS[@]}"; do
                    printf 'capacity guard: %s\n' "$item" >&2
                done
                return 1
                ;;
            unknown)
                [[ -n "$CAPACITY_GUARD_MEM_AVAILABLE_MIB" ]] ||
                    printf 'capacity guard: cannot read MemAvailable\n' >&2
                [[ "$CAPACITY_GUARD_VIRT" == lxc && -z "$CAPACITY_GUARD_CG_CURRENT_MIB" ]] &&
                    printf "capacity guard: cannot read the container's memory.current\\n" >&2
                return 2
                ;;
        esac
        return 0
    fi

    if [[ "$CAPACITY_JSON" == "true" ]]; then
        capacity_guard_emit_json
    else
        capacity_guard_emit_human
    fi
}

capacity_main() {
    capacity_parse_args "$@"
    local parse_status=$?
    if [[ $parse_status -eq 100 ]]; then
        return 0
    elif [[ $parse_status -ne 0 ]]; then
        return "$parse_status"
    fi

    if [[ "$CAPACITY_GUARD" == "true" ]]; then
        capacity_guard_main
        return $?
    fi

    if [[ "$CAPACITY_RESOURCE_PROFILE" == "true" ]]; then
        if [[ "$CAPACITY_JSON" == "true" ]]; then
            capacity_emit_resource_profile_json
        else
            capacity_emit_resource_profile_human
        fi
        return $?
    fi

    capacity_collect_model

    if [[ "$CAPACITY_JSON" == "true" ]]; then
        capacity_emit_json
    else
        capacity_emit_human
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    capacity_main "$@"
fi
