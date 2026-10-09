#!/usr/bin/env bash
# ============================================================
# ACFS Swarm Simulation - dry-run fleet-scale harness
#
# Runs deterministic 10/25/50 logical-agent simulations without
# launching tmux sessions, model CLIs, or CPU-heavy build commands.
# ============================================================

set -euo pipefail

SWARM_SIM_JSON=false
SWARM_SIM_COUNTS_RAW="10,25,50"
SWARM_SIM_COUNTS_EXPLICIT=false
SWARM_SIM_WORKLOAD="standard"
SWARM_SIM_ARTIFACT_DIR="${ACFS_SWARM_SIM_ARTIFACT_DIR:-}"
SWARM_SIM_STATUS_FILE=""
SWARM_SIM_MOCK_REHEARSAL=false
SWARM_SIM_MOCK_DURATION=1
SWARM_SIM_ALLOW_HIGH_COUNTS=false
SWARM_SIM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_STATUS_SCRIPT="${ACFS_SWARM_STATUS_SCRIPT:-$SWARM_SIM_SCRIPT_DIR/swarm_status.sh}"
SWARM_CAPACITY_SCRIPT="${ACFS_SWARM_CAPACITY_SCRIPT:-$SWARM_SIM_SCRIPT_DIR/capacity.sh}"
SWARM_SIM_GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
SWARM_SIM_COUNTS=()
SWARM_SIM_MOCK_PIDS=()

swarm_sim_usage() {
    cat <<'EOF'
Usage: acfs swarm simulate [OPTIONS]

Dry-run-only simulation harness for 10/25/50 logical ACFS agents.
No tmux sessions, model CLIs, Agent Mail mutations, Beads updates, or
CPU-heavy build commands are executed.

Options:
  --json                Emit machine-readable aggregate summary
  --counts LIST         Comma-separated agent counts (default: 10,25,50)
  --workload NAME       light, standard, or heavy (default: standard)
  --artifact-dir DIR    Directory for timing, plan, telemetry, and summaries
  --status-file FILE    Use an existing acfs swarm status JSON snapshot
  --mock-rehearsal      Launch inert local shell workers and collect artifacts
  --mock-duration SEC   Sleep duration for each mock worker (default: 1)
  --allow-high-counts   Permit mock rehearsals above 10 workers
  --help, -h            Show this help

Artifacts:
  summary.json
  scenario_<N>/launch_plan.json
  scenario_<N>/telemetry.json
  scenario_<N>/capacity.json
  scenario_<N>/resource_sample.json
  scenario_<N>/timing.json
  scenario_<N>/mock_rehearsal.json
  scenario_<N>/summary.json
EOF
}

swarm_sim_binary_path() {
    local name="${1:-}"
    local path_value=""

    [[ -n "$name" ]] || return 1
    case "$name" in
        .|..|*/*) return 1 ;;
    esac

    path_value="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$path_value" && -x "$path_value" ]] || return 1
    printf '%s\n' "$path_value"
}

swarm_sim_now_ms() {
    local now=""
    now="$(date +%s%3N 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$now"
        return 0
    fi
    now="$(date +%s 2>/dev/null || echo 0)"
    printf '%s000\n' "$now"
}

swarm_sim_parse_counts() {
    local raw="$1"
    local part=""
    local count_value=0
    local seen=","
    local -a parts=()

    IFS=',' read -r -a parts <<<"$raw"
    if [[ ${#parts[@]} -eq 0 ]]; then
        echo "Error: --counts requires at least one count" >&2
        return 2
    fi

    SWARM_SIM_COUNTS=()
    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"
        if [[ ! "$part" =~ ^[0-9]+$ ]]; then
            echo "Error: invalid agent count: $part" >&2
            return 2
        fi
        count_value=$((10#$part))
        if (( count_value < 1 || count_value > 200 )); then
            echo "Error: invalid agent count: $part" >&2
            return 2
        fi
        if [[ "$seen" == *",$count_value,"* ]]; then
            echo "Error: duplicate agent count: $count_value" >&2
            return 2
        fi
        seen+="$count_value,"
        SWARM_SIM_COUNTS+=("$count_value")
    done
}

swarm_sim_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                SWARM_SIM_JSON=true
                shift
                ;;
            --counts)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --counts requires a comma-separated list" >&2
                    return 2
                fi
                SWARM_SIM_COUNTS_RAW="$2"
                SWARM_SIM_COUNTS_EXPLICIT=true
                shift 2
                ;;
            --workload)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --workload requires a value" >&2
                    return 2
                fi
                SWARM_SIM_WORKLOAD="$2"
                shift 2
                ;;
            --artifact-dir)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --artifact-dir requires a path" >&2
                    return 2
                fi
                SWARM_SIM_ARTIFACT_DIR="$2"
                shift 2
                ;;
            --status-file)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --status-file requires a path" >&2
                    return 2
                fi
                SWARM_SIM_STATUS_FILE="$2"
                shift 2
                ;;
            --mock-rehearsal)
                SWARM_SIM_MOCK_REHEARSAL=true
                shift
                ;;
            --mock-duration)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --mock-duration requires seconds" >&2
                    return 2
                fi
                if [[ ! "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 || 10#$2 > 30 )); then
                    echo "Error: --mock-duration must be 1-30 seconds" >&2
                    return 2
                fi
                SWARM_SIM_MOCK_DURATION=$((10#$2))
                shift 2
                ;;
            --allow-high-counts)
                SWARM_SIM_ALLOW_HIGH_COUNTS=true
                shift
                ;;
            --help|-h)
                swarm_sim_usage
                return 100
                ;;
            *)
                echo "Error: unknown option: $1" >&2
                echo "Run 'acfs swarm simulate --help' for usage." >&2
                return 2
                ;;
        esac
    done

    case "$SWARM_SIM_WORKLOAD" in
        light|standard|heavy) ;;
        *)
            echo "Error: unsupported workload: $SWARM_SIM_WORKLOAD" >&2
            return 2
            ;;
    esac

    if [[ "$SWARM_SIM_MOCK_REHEARSAL" == true && "$SWARM_SIM_COUNTS_EXPLICIT" == false ]]; then
        SWARM_SIM_COUNTS_RAW="10"
    fi

    swarm_sim_parse_counts "$SWARM_SIM_COUNTS_RAW" || return $?

    if [[ "$SWARM_SIM_MOCK_REHEARSAL" == true && "$SWARM_SIM_ALLOW_HIGH_COUNTS" != true ]]; then
        local count=""
        for count in "${SWARM_SIM_COUNTS[@]}"; do
            if (( count > 10 )); then
                echo "Error: mock rehearsals above 10 workers require --allow-high-counts" >&2
                return 2
            fi
        done
    fi
}

swarm_sim_prepare_artifact_dir() {
    local base_dir=""
    local timestamp=""

    if [[ -z "$SWARM_SIM_ARTIFACT_DIR" ]]; then
        base_dir="${ACFS_SWARM_SIM_BASE_DIR:-${HOME:-/tmp}/.acfs/logs/swarm-simulations}"
        timestamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
        SWARM_SIM_ARTIFACT_DIR="$base_dir/$timestamp-$$"
    fi

    mkdir -p "$SWARM_SIM_ARTIFACT_DIR"
}

swarm_sim_fallback_status_json() {
    local jq_bin="$1"
    "$jq_bin" -n \
        --arg generated_at "$SWARM_SIM_GENERATED_AT" \
        '{
            schema_version: 1,
            generated_at: $generated_at,
            status: "warn",
            warnings: ["swarm_status.sh unavailable; using simulation fallback telemetry"],
            host: {
                status: "warn",
                duration_ms: 0,
                warnings: ["host telemetry unavailable"],
                cpu_count: 0,
                load_1m: null,
                mem_total_kb: 0,
                mem_available_kb: 0,
                disk_available_kb: 0
            },
            probes: {
                herdr: {status: "warn", available: false, server_ok: false, workspace_count: null, agent_count: null, duration_ms: 0, warnings: ["not probed"]},
                agent_mail: {status: "warn", available: false, healthy: null, duration_ms: 0, warnings: ["not probed"]},
                beads: {status: "warn", available: false, ready_count: null, in_progress_count: null, open_count: null, duration_ms: 0, warnings: ["not probed"]},
                bv: {status: "warn", available: false, robot_ok: false, duration_ms: 0, warnings: ["not probed"]},
                rch: {status: "warn", available: false, status_json_ok: false, duration_ms: 0, warnings: ["not probed"]}
            }
        }'
}

swarm_sim_collect_status_json() {
    local jq_bin="$1"
    local output=""
    local exit_status=0

    if [[ -n "$SWARM_SIM_STATUS_FILE" ]]; then
        if [[ ! -f "$SWARM_SIM_STATUS_FILE" ]]; then
            echo "Error: status file not found: $SWARM_SIM_STATUS_FILE" >&2
            return 2
        fi
        cat "$SWARM_SIM_STATUS_FILE"
        return 0
    fi

    if [[ ! -f "$SWARM_STATUS_SCRIPT" ]]; then
        swarm_sim_fallback_status_json "$jq_bin"
        return 0
    fi

    set +e
    output="$(bash "$SWARM_STATUS_SCRIPT" --json 2>/dev/null)"
    exit_status=$?
    set -e
    if [[ $exit_status -eq 0 && -n "$output" ]] && printf '%s' "$output" | "$jq_bin" . >/dev/null 2>&1; then
        printf '%s\n' "$output"
        return 0
    fi

    swarm_sim_fallback_status_json "$jq_bin"
}

swarm_sim_mock_alive_count() {
    local alive=0
    local pid=""

    for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
            alive=$((alive + 1))
        fi
    done

    printf '%s\n' "$alive"
}

swarm_sim_cleanup_mock_pids() {
    local pid=""

    for pid in "${SWARM_SIM_MOCK_PIDS[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

swarm_sim_mock_resource_snapshot_json() {
    local jq_bin="$1"
    local count="$2"
    local phase="$3"
    local alive="$4"
    local load_1m="null"
    local mem_available_kb=0

    if [[ -r /proc/loadavg ]]; then
        load_1m="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo null)"
        [[ "$load_1m" =~ ^[0-9]+([.][0-9]+)?$ ]] || load_1m="null"
    fi
    if [[ -r /proc/meminfo ]]; then
        mem_available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        [[ "$mem_available_kb" =~ ^[0-9]+$ ]] || mem_available_kb=0
    fi

    "$jq_bin" -n \
        --arg generated_at "$SWARM_SIM_GENERATED_AT" \
        --arg phase "$phase" \
        --argjson count "$count" \
        --argjson alive "$alive" \
        --argjson load_1m "$load_1m" \
        --argjson mem_available_kb "$mem_available_kb" \
        '{
            schema_version: 1,
            generated_at: $generated_at,
            phase: $phase,
            requested_workers: $count,
            alive_workers: $alive,
            load_1m: $load_1m,
            mem_available_kb: $mem_available_kb
        }'
}

swarm_sim_skipped_mock_rehearsal_json() {
    local jq_bin="$1"
    local count="$2"
    local scenario_dir="$3"
    local output_file="$4"

    "$jq_bin" -n \
        --arg scenario_dir "$scenario_dir" \
        --argjson count "$count" \
        '{
            schema_version: 1,
            mode: "local-mock-rehearsal",
            enabled: false,
            skipped: true,
            requested_workers: $count,
            launched_workers: 0,
            completed_workers: 0,
            artifact_dir: $scenario_dir,
            safety: {
                no_model_cli: true,
                no_agent_mail_mutation: true,
                no_beads_mutation: true,
                no_cargo_build: true
            },
            artifacts: {}
        }' > "$output_file"
}

swarm_sim_run_mock_rehearsal() {
    local jq_bin="$1"
    local count="$2"
    local scenario_dir="$3"
    local output_file="$4"
    local launch_log="$scenario_dir/mock_launch.log"
    local status_snapshots_file="$scenario_dir/mock_status_snapshots.json"
    local resource_samples_file="$scenario_dir/mock_resource_samples.json"
    local before_status_file="$scenario_dir/mock_status_before.json"
    local after_status_file="$scenario_dir/mock_status_after.json"
    local sample_before_file="$scenario_dir/mock_resource_before.json"
    local sample_during_file="$scenario_dir/mock_resource_during.json"
    local sample_after_file="$scenario_dir/mock_resource_after.json"
    local start_ms=""
    local end_ms=""
    local duration_ms=""
    local alive=0
    local completed=0
    local failures=0
    local index=0
    local pid=""

    : > "$launch_log"
    start_ms="$(swarm_sim_now_ms)"
    swarm_sim_collect_status_json "$jq_bin" > "$before_status_file"
    swarm_sim_mock_resource_snapshot_json "$jq_bin" "$count" before 0 > "$sample_before_file"

    SWARM_SIM_MOCK_PIDS=()
    trap 'swarm_sim_cleanup_mock_pids' EXIT INT TERM
    for ((index = 1; index <= count; index++)); do
        (
            printf 'mock-agent-%s start\n' "$index" >> "$launch_log"
            sleep "$SWARM_SIM_MOCK_DURATION"
            printf 'mock-agent-%s complete\n' "$index" >> "$launch_log"
        ) &
        SWARM_SIM_MOCK_PIDS+=("$!")
    done

    alive="$(swarm_sim_mock_alive_count "${SWARM_SIM_MOCK_PIDS[@]}")"
    swarm_sim_mock_resource_snapshot_json "$jq_bin" "$count" during "$alive" > "$sample_during_file"

    for pid in "${SWARM_SIM_MOCK_PIDS[@]}"; do
        if wait "$pid"; then
            completed=$((completed + 1))
        else
            failures=$((failures + 1))
        fi
    done
    trap - EXIT INT TERM
    SWARM_SIM_MOCK_PIDS=()

    alive="$(swarm_sim_mock_alive_count "${SWARM_SIM_MOCK_PIDS[@]}")"
    swarm_sim_mock_resource_snapshot_json "$jq_bin" "$count" after "$alive" > "$sample_after_file"
    "$jq_bin" -s '{schema_version: 1, samples: .}' \
        "$sample_before_file" \
        "$sample_during_file" \
        "$sample_after_file" \
        > "$resource_samples_file"

    swarm_sim_collect_status_json "$jq_bin" > "$after_status_file"
    "$jq_bin" -n \
        --slurpfile before "$before_status_file" \
        --slurpfile after "$after_status_file" \
        '{schema_version: 1, before: ($before[0] // {}), after: ($after[0] // {})}' \
        > "$status_snapshots_file"

    end_ms="$(swarm_sim_now_ms)"
    duration_ms=$((end_ms - start_ms))
    "$jq_bin" -n \
        --arg scenario_dir "$scenario_dir" \
        --arg launch_log "$launch_log" \
        --arg status_snapshots "$status_snapshots_file" \
        --arg resource_samples "$resource_samples_file" \
        --argjson count "$count" \
        --argjson duration_seconds "$SWARM_SIM_MOCK_DURATION" \
        --argjson start_ms "$start_ms" \
        --argjson end_ms "$end_ms" \
        --argjson duration_ms "$duration_ms" \
        --argjson completed "$completed" \
        --argjson failures "$failures" \
        '{
            schema_version: 1,
            mode: "local-mock-rehearsal",
            enabled: true,
            skipped: false,
            requested_workers: $count,
            launched_workers: $count,
            completed_workers: $completed,
            failed_workers: $failures,
            duration_seconds: $duration_seconds,
            timing: {
                start_ms: $start_ms,
                end_ms: $end_ms,
                duration_ms: $duration_ms
            },
            status: (if $failures == 0 and $completed == $count then "pass" else "fail" end),
            artifact_dir: $scenario_dir,
            safety: {
                no_model_cli: true,
                no_agent_mail_mutation: true,
                no_beads_mutation: true,
                no_cargo_build: true
            },
            artifacts: {
                launch_log: $launch_log,
                status_snapshots: $status_snapshots,
                resource_samples: $resource_samples
            }
        }' > "$output_file"
}

swarm_sim_capacity_json() {
    local jq_bin="$1"
    local count="$2"
    local output=""
    local exit_status=0

    if [[ -f "$SWARM_CAPACITY_SCRIPT" ]]; then
        set +e
        output="$(bash "$SWARM_CAPACITY_SCRIPT" --json --workload "$SWARM_SIM_WORKLOAD" --profile "${count}-agents" --recommend-ntm 2>/dev/null)"
        exit_status=$?
        set -e
        if [[ $exit_status -eq 0 && -n "$output" ]] && printf '%s' "$output" | "$jq_bin" . >/dev/null 2>&1; then
            printf '%s\n' "$output"
            return 0
        fi
    fi

    "$jq_bin" -n \
        --arg workload "$SWARM_SIM_WORKLOAD" \
        --argjson count "$count" \
        '{
            schema_version: 1,
            status: "warn",
            assumptions: {workload: $workload},
            tools: {rch: {available: false}, ntm: {available: false}},
            capacity: {safe_agent_count: null, recommended_agent_count: null},
            profile_check: {
                status: "warn",
                requested_agents: $count,
                reason: "capacity.sh unavailable; scenario shape only"
            },
            ntm: {agent_count: $count, profiles: []}
        }'
}

swarm_sim_launch_plan_json() {
    local jq_bin="$1"
    local count="$2"

    "$jq_bin" -n \
        --arg workload "$SWARM_SIM_WORKLOAD" \
        --argjson count "$count" \
        '{
            schema_version: 1,
            simulation_only: true,
            not_a_provider_factory_test: true,
            profile: {
                agent_count: $count,
                workload: $workload,
                label: ("swarm-" + ($count | tostring))
            },
            launch: {
                dry_run: true,
                command: ("ntm spawn acfs-sim --count " + ($count | tostring) + " --label swarm-" + ($count | tostring) + " --dry-run"),
                not_executed: true
            },
            coordination: {
                agent_mail_thread_id: "bd-bhns5",
                bead_selection_command: "br ready --json",
                graph_triage_command: "bv --robot-next",
                reservation_policy: "exclusive reservations only for files each logical agent edits",
                completion_policy: "send Agent Mail completion, release reservations, run br sync --flush-only"
            },
            rch_policy: {
                cpu_heavy_commands_require_rch: true,
                required_prefix: "rch exec --",
                examples: ["rch exec -- cargo test", "rch exec -- cargo clippy"],
                forbidden_local_examples: ["cargo test", "cargo build --release"]
            },
            agents: [
                range(0; $count) | {
                    index: (. + 1),
                    name: ("agent-" + ((. + 1) | tostring)),
                    role: (["implementation", "test", "review", "docs"][. % 4]),
                    startup_steps: [
                        "read AGENTS.md and README.md",
                        "register Agent Mail identity",
                        "inspect br ready --json",
                        "reserve owned files before edits",
                        "use rch exec -- for CPU-heavy builds/tests"
                    ]
                }
            ]
        }'
}

swarm_sim_resource_sample_json() {
    local jq_bin="$1"
    local count="$2"
    local status_file="$3"
    local capacity_file="$4"

    "$jq_bin" -n \
        --slurpfile status "$status_file" \
        --slurpfile capacity "$capacity_file" \
        --argjson count "$count" \
        --arg generated_at "$SWARM_SIM_GENERATED_AT" \
        '
        ($status[0] // {}) as $s
        | ($capacity[0] // {}) as $c
        | ($s.host // {}) as $host
        | {
            schema_version: 1,
            generated_at: $generated_at,
            mode: "projected-dry-run",
            agent_count: $count,
            host: {
                cpu_count: ($host.cpu_count // 0),
                load_1m: ($host.load_1m // null),
                mem_total_mib: ((($host.mem_total_kb // 0) / 1024) | floor),
                mem_available_mib: ((($host.mem_available_kb // 0) / 1024) | floor),
                disk_available_mib: ((($host.disk_available_kb // 0) / 1024) | floor)
            },
            capacity: {
                safe_agent_count: ($c.capacity.safe_agent_count // null),
                recommended_agent_count: ($c.capacity.recommended_agent_count // null),
                profile_status: ($c.profile_check.status // "unknown")
            },
            pressure: {
                projected_agents: $count,
                status: (if ($c.profile_check.status // "warn") == "fail" then "fail" elif ($c.profile_check.status // "warn") == "warn" then "warn" else "pass" end),
                reason: ($c.profile_check.reason // "capacity unavailable")
            }
        }'
}

swarm_sim_scenario_summary_json() {
    local jq_bin="$1"
    local count="$2"
    local scenario_dir="$3"
    local launch_plan_file="$4"
    local telemetry_file="$5"
    local capacity_file="$6"
    local resource_file="$7"
    local timing_file="$8"
    local rehearsal_file="$9"

    "$jq_bin" -n \
        --slurpfile plan "$launch_plan_file" \
        --slurpfile telemetry "$telemetry_file" \
        --slurpfile capacity "$capacity_file" \
        --slurpfile resource "$resource_file" \
        --slurpfile timing "$timing_file" \
        --slurpfile rehearsal "$rehearsal_file" \
        --argjson count "$count" \
        --arg scenario_dir "$scenario_dir" \
        '
        def check($id; $status; $summary):
            {id: $id, status: $status, summary: $summary};
        ($plan[0] // {}) as $p
        | ($telemetry[0] // {}) as $t
        | ($capacity[0] // {}) as $c
        | ($resource[0] // {}) as $r
        | ($timing[0] // {}) as $time
        | ($rehearsal[0] // {}) as $m
        | [
            check(
                "launch_plan_shape";
                (if (($p.agents // []) | length) == $count and ($p.launch.dry_run == true) and ($p.simulation_only == true) then "pass" else "fail" end);
                "Generated launch plan has the expected logical agent count and dry-run marker"
            ),
            check(
                "coordination_assumptions";
                (if ($t.probes.beads.available == false or $t.probes.agent_mail.available == false or $t.probes.bv.available == false) then "warn"
                 elif (($t.probes.beads.in_progress_count // 0) > 0) then "warn"
                 else "pass" end);
                "Agent Mail, Beads, and bv assumptions are represented without mutating live state"
            ),
            check(
                "rch_policy";
                (if (($p.rch_policy.cpu_heavy_commands_require_rch == true) and (($p.rch_policy.examples // []) | all(.[]; startswith("rch exec -- ")))) then "pass" else "fail" end);
                "CPU-heavy proof commands are modeled with the rch exec -- prefix"
            ),
            check(
                "telemetry_snapshot";
                (if (($t.schema_version == 1) and (($t.host | type) == "object") and (($t.probes | type) == "object")) then (if ($t.status == "fail") then "warn" else "pass" end) else "fail" end);
                "Telemetry collector output is captured as structured JSON"
            ),
            check(
                "resource_pressure";
                (if ($r.pressure.status == "fail") then "fail" elif ($r.pressure.status == "warn") then "warn" else "pass" end);
                ($r.pressure.reason // "Resource projection captured")
            ),
            check(
                "timing";
                (if (($time.duration_ms // -1) >= 0) then "pass" else "fail" end);
                "Scenario timing artifact records a non-negative duration"
            ),
            check(
                "mock_rehearsal";
                (if ($m.enabled == true) then ($m.status // "fail") else "pass" end);
                (if ($m.enabled == true) then "Local inert mock workers completed without invoking model CLIs or build commands" else "Mock rehearsal disabled; dry-run simulation only" end)
            )
        ] as $checks
        | {
            schema_version: 1,
            scenario: {
                agent_count: $count,
                workload: ($p.profile.workload // "unknown"),
                artifact_dir: $scenario_dir
            },
            mock_rehearsal: ($m.enabled // false),
            status: (if any($checks[]; .status == "fail") then "fail" elif any($checks[]; .status == "warn") then "warn" else "pass" end),
            checks: $checks,
            artifacts: {
                launch_plan: ($scenario_dir + "/launch_plan.json"),
                telemetry: ($scenario_dir + "/telemetry.json"),
                capacity: ($scenario_dir + "/capacity.json"),
                resource_sample: ($scenario_dir + "/resource_sample.json"),
                timing: ($scenario_dir + "/timing.json"),
                mock_rehearsal: ($scenario_dir + "/mock_rehearsal.json"),
                summary: ($scenario_dir + "/summary.json")
            }
        }'
}

swarm_sim_run_scenario() {
    local jq_bin="$1"
    local count="$2"
    local status_file="$3"
    local scenario_dir="$SWARM_SIM_ARTIFACT_DIR/scenario_$count"
    local start_ms=""
    local end_ms=""
    local duration_ms=""
    local launch_plan_file="$scenario_dir/launch_plan.json"
    local telemetry_file="$scenario_dir/telemetry.json"
    local capacity_file="$scenario_dir/capacity.json"
    local resource_file="$scenario_dir/resource_sample.json"
    local timing_file="$scenario_dir/timing.json"
    local rehearsal_file="$scenario_dir/mock_rehearsal.json"
    local summary_file="$scenario_dir/summary.json"

    mkdir -p "$scenario_dir"
    start_ms="$(swarm_sim_now_ms)"

    swarm_sim_launch_plan_json "$jq_bin" "$count" > "$launch_plan_file"
    cp "$status_file" "$telemetry_file"
    swarm_sim_capacity_json "$jq_bin" "$count" > "$capacity_file"
    swarm_sim_resource_sample_json "$jq_bin" "$count" "$telemetry_file" "$capacity_file" > "$resource_file"
    if [[ "$SWARM_SIM_MOCK_REHEARSAL" == true ]]; then
        swarm_sim_run_mock_rehearsal "$jq_bin" "$count" "$scenario_dir" "$rehearsal_file"
    else
        swarm_sim_skipped_mock_rehearsal_json "$jq_bin" "$count" "$scenario_dir" "$rehearsal_file"
    fi

    end_ms="$(swarm_sim_now_ms)"
    duration_ms=$((end_ms - start_ms))
    "$jq_bin" -n \
        --argjson start_ms "$start_ms" \
        --argjson end_ms "$end_ms" \
        --argjson duration_ms "$duration_ms" \
        '{schema_version: 1, start_ms: $start_ms, end_ms: $end_ms, duration_ms: $duration_ms}' \
        > "$timing_file"

    swarm_sim_scenario_summary_json \
        "$jq_bin" \
        "$count" \
        "$scenario_dir" \
        "$launch_plan_file" \
        "$telemetry_file" \
        "$capacity_file" \
        "$resource_file" \
        "$timing_file" \
        "$rehearsal_file" \
        > "$summary_file"
    printf '%s\n' "$summary_file"
}

swarm_sim_aggregate_summary() {
    local jq_bin="$1"
    shift

    "$jq_bin" -s \
        --arg generated_at "$SWARM_SIM_GENERATED_AT" \
        --arg artifact_dir "$SWARM_SIM_ARTIFACT_DIR" \
        --arg counts "$SWARM_SIM_COUNTS_RAW" \
        '{
            schema_version: 1,
            generated_at: $generated_at,
            simulation_only: true,
            not_a_provider_factory_test: true,
            artifact_dir: $artifact_dir,
            requested_counts: $counts,
            status: (if any(.[]; .status == "fail") then "fail" elif any(.[]; .status == "warn") then "warn" else "pass" end),
            summary: {
                total: length,
                failed: ([.[] | select(.status == "fail")] | length),
                warnings: ([.[] | select(.status == "warn")] | length),
                passed: ([.[] | select(.status == "pass")] | length)
            },
            scenarios: .
        }' "$@" > "$SWARM_SIM_ARTIFACT_DIR/summary.json"
}

swarm_sim_emit_human() {
    local jq_bin="$1"
    local summary_file="$2"

    echo "ACFS Swarm Simulation"
    echo "Status: $("$jq_bin" -r '.status' "$summary_file")"
    echo "Artifacts: $("$jq_bin" -r '.artifact_dir' "$summary_file")"
    echo "Simulation only: no agents, tmux sessions, model CLIs, Beads updates, or CPU-heavy commands were executed."
    echo ""
    echo "Scenarios:"
    "$jq_bin" -r '.scenarios[] | "  - \(.scenario.agent_count) agents: \(.status) (\(.checks | map(select(.status == "fail")) | length) fail, \(.checks | map(select(.status == "warn")) | length) warn)"' "$summary_file"
}

swarm_sim_main() {
    local parse_status=0
    local jq_bin=""
    local status_file=""
    local summary_file=""
    local summary_status=""
    local exit_code=0
    local scenario_summary=""
    local -a scenario_summaries=()
    local count=""

    set +e
    swarm_sim_parse_args "$@"
    parse_status=$?
    set -e
    if [[ $parse_status -eq 100 ]]; then
        return 0
    elif [[ $parse_status -ne 0 ]]; then
        return "$parse_status"
    fi

    jq_bin="$(swarm_sim_binary_path jq 2>/dev/null || true)"
    if [[ -z "$jq_bin" ]]; then
        echo "Error: jq is required for swarm simulation" >&2
        return 2
    fi

    swarm_sim_prepare_artifact_dir
    status_file="$SWARM_SIM_ARTIFACT_DIR/source_swarm_status.json"
    swarm_sim_collect_status_json "$jq_bin" > "$status_file"

    for count in "${SWARM_SIM_COUNTS[@]}"; do
        scenario_summary="$(swarm_sim_run_scenario "$jq_bin" "$count" "$status_file")"
        scenario_summaries+=("$scenario_summary")
    done

    swarm_sim_aggregate_summary "$jq_bin" "${scenario_summaries[@]}"
    summary_file="$SWARM_SIM_ARTIFACT_DIR/summary.json"
    summary_status="$("$jq_bin" -r '.status' "$summary_file")"
    case "$summary_status" in
        fail) exit_code=2 ;;
        warn) exit_code=1 ;;
        *) exit_code=0 ;;
    esac

    if [[ "$SWARM_SIM_JSON" == true ]]; then
        cat "$summary_file"
    else
        swarm_sim_emit_human "$jq_bin" "$summary_file"
    fi

    return "$exit_code"
}

swarm_sim_main "$@"
