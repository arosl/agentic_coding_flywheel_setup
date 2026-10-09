#!/usr/bin/env bash
# ============================================================
# ACFS Swarm Calibration - artifact-backed capacity review
#
# Reads local swarm simulation/rehearsal artifacts plus optional RCH timing
# evidence, then explains whether the static capacity assumptions look
# conservative, aligned, or too aggressive for this host. This command never
# mutates capacity defaults, RCH, herdr, Beads, or Agent Mail.
# ============================================================

set -euo pipefail

SWARM_CAL_JSON=false
SWARM_CAL_RCH_FILE=""
SWARM_CAL_GENERATED_AT="$(date -Iseconds 2>/dev/null || date)"
SWARM_CAL_ARTIFACT_DIRS=()

swarm_calibration_usage() {
    cat <<'EOF'
Usage: acfs swarm calibration [OPTIONS]

Options:
  --json                Emit machine-readable JSON
  --markdown            Emit Markdown output (default)
  --artifact-dir DIR    Read a simulation run directory or parent artifact dir
                        (repeatable; defaults to ~/.acfs/logs/swarm-simulations)
  --rch-file FILE       Optional local RCH timing/status JSON evidence
  --help, -h            Show this help

The command is advisory-only. It reads local artifact files and prints a
calibration report, but it never phones home, changes capacity defaults,
launches agents, mutates RCH/herdr state, sends Agent Mail, or updates Beads.
EOF
}

swarm_calibration_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                SWARM_CAL_JSON=true
                shift
                ;;
            --markdown)
                SWARM_CAL_JSON=false
                shift
                ;;
            --artifact-dir)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --artifact-dir requires a path" >&2
                    return 2
                fi
                SWARM_CAL_ARTIFACT_DIRS+=("$2")
                shift 2
                ;;
            --rch-file)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --rch-file requires a path" >&2
                    return 2
                fi
                SWARM_CAL_RCH_FILE="$2"
                shift 2
                ;;
            --help|-h)
                swarm_calibration_usage
                return 100
                ;;
            *)
                echo "Error: unknown option: $1" >&2
                echo "Run 'acfs swarm calibration --help' for usage." >&2
                return 2
                ;;
        esac
    done

    if [[ ${#SWARM_CAL_ARTIFACT_DIRS[@]} -eq 0 ]]; then
        SWARM_CAL_ARTIFACT_DIRS+=("${ACFS_SWARM_CALIBRATION_ARTIFACT_DIR:-${ACFS_SWARM_SIM_BASE_DIR:-${HOME:-/tmp}/.acfs/logs/swarm-simulations}}")
    fi
}

swarm_calibration_binary_path() {
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

swarm_calibration_json_array() {
    local jq_bin="$1"
    shift

    if [[ $# -eq 0 ]]; then
        printf '[]\n'
        return 0
    fi

    printf '%s\n' "$@" | "$jq_bin" -R . | "$jq_bin" -s .
}

swarm_calibration_read_single_json() {
    local jq_bin="$1"
    local path="$2"
    local output=""

    output="$("$jq_bin" -c -s 'if length == 1 then .[0] else empty end' "$path" 2>/dev/null)" || return 1
    [[ -n "$output" ]] || return 1
    printf '%s\n' "$output"
}

swarm_calibration_json_number_or_null() {
    local value="${1:-}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        printf 'null\n'
    fi
}

swarm_calibration_scenario_json() {
    local jq_bin="$1"
    local scenario_dir="$2"
    local summary_file="$scenario_dir/summary.json"
    local capacity_file="$scenario_dir/capacity.json"
    local resource_file="$scenario_dir/resource_sample.json"
    local timing_file="$scenario_dir/timing.json"
    local rehearsal_file="$scenario_dir/mock_rehearsal.json"
    local telemetry_file="$scenario_dir/telemetry.json"
    local summary_json="{}"
    local capacity_json="{}"
    local resource_json="{}"
    local timing_json="{}"
    local rehearsal_json="{}"
    local telemetry_json="{}"
    local warnings_json=""
    local dir_count="null"
    local base_name=""
    local malformed_count=0
    local missing_count=0
    local -a warnings=()

    base_name="$(basename "$scenario_dir")"
    if [[ "$base_name" =~ ^scenario_([0-9]+)$ ]]; then
        dir_count="${BASH_REMATCH[1]}"
    fi

    if [[ -f "$summary_file" ]]; then
        if summary_json="$(swarm_calibration_read_single_json "$jq_bin" "$summary_file")"; then
            :
        else
            summary_json="{}"
            malformed_count=$((malformed_count + 1))
            warnings+=("$summary_file is malformed JSON")
        fi
    else
        missing_count=$((missing_count + 1))
        warnings+=("$summary_file is missing")
    fi

    if [[ -f "$capacity_file" ]]; then
        if capacity_json="$(swarm_calibration_read_single_json "$jq_bin" "$capacity_file")"; then
            :
        else
            capacity_json="{}"
            malformed_count=$((malformed_count + 1))
            warnings+=("$capacity_file is malformed JSON")
        fi
    else
        missing_count=$((missing_count + 1))
        warnings+=("$capacity_file is missing")
    fi

    if [[ -f "$resource_file" ]]; then
        if resource_json="$(swarm_calibration_read_single_json "$jq_bin" "$resource_file")"; then
            :
        else
            resource_json="{}"
            malformed_count=$((malformed_count + 1))
            warnings+=("$resource_file is malformed JSON")
        fi
    else
        missing_count=$((missing_count + 1))
        warnings+=("$resource_file is missing")
    fi

    if [[ -f "$timing_file" ]]; then
        if timing_json="$(swarm_calibration_read_single_json "$jq_bin" "$timing_file")"; then
            :
        else
            timing_json="{}"
            malformed_count=$((malformed_count + 1))
            warnings+=("$timing_file is malformed JSON")
        fi
    else
        missing_count=$((missing_count + 1))
        warnings+=("$timing_file is missing")
    fi

    if [[ -f "$rehearsal_file" ]]; then
        if rehearsal_json="$(swarm_calibration_read_single_json "$jq_bin" "$rehearsal_file")"; then
            :
        else
            rehearsal_json="{}"
            malformed_count=$((malformed_count + 1))
            warnings+=("$rehearsal_file is malformed JSON")
        fi
    else
        missing_count=$((missing_count + 1))
        warnings+=("$rehearsal_file is missing")
    fi

    if [[ -f "$telemetry_file" ]]; then
        if telemetry_json="$(swarm_calibration_read_single_json "$jq_bin" "$telemetry_file")"; then
            :
        else
            telemetry_json="{}"
            malformed_count=$((malformed_count + 1))
            warnings+=("$telemetry_file is malformed JSON")
        fi
    else
        missing_count=$((missing_count + 1))
        warnings+=("$telemetry_file is missing")
    fi

    warnings_json="$(swarm_calibration_json_array "$jq_bin" "${warnings[@]}")"

    "$jq_bin" -c -n \
        --arg scenario_dir "$scenario_dir" \
        --argjson dir_count "$(swarm_calibration_json_number_or_null "$dir_count")" \
        --argjson summary "$summary_json" \
        --argjson capacity "$capacity_json" \
        --argjson resource "$resource_json" \
        --argjson timing "$timing_json" \
        --argjson rehearsal "$rehearsal_json" \
        --argjson telemetry "$telemetry_json" \
        --argjson warnings "$warnings_json" \
        --argjson malformed_count "$malformed_count" \
        --argjson missing_count "$missing_count" \
        '
        def n($v):
          if ($v | type) == "number" then $v
          elif (($v | type) == "string" and ($v | test("^[0-9]+([.][0-9]+)?$"))) then ($v | tonumber)
          else null end;
        def status_text($v):
          ($v // "unknown" | tostring | ascii_downcase);
        def observed_status:
          status_text($summary.status // $resource.pressure.status // $rehearsal.status // $capacity.profile_check.status // "unknown");
        (n($summary.scenario.agent_count) // n($resource.agent_count) // n($capacity.profile_check.requested_agents) // $dir_count) as $agent_count
        | (observed_status) as $observed
        | (status_text($capacity.profile_check.status // $resource.capacity.profile_status // "unknown")) as $profile_status
        | (n($capacity.capacity.recommended_agent_count) // n($resource.capacity.recommended_agent_count)) as $recommended
        | (n($capacity.capacity.safe_agent_count) // n($resource.capacity.safe_agent_count) // n($capacity.capacity.max_agent_count)) as $safe
        | {
            artifact_dir: $scenario_dir,
            valid: (($agent_count != null) and ($malformed_count == 0) and (($summary | length) > 0)),
            agent_count: $agent_count,
            workload: ($summary.scenario.workload // $capacity.assumptions.workload // "unknown"),
            observed_status: $observed,
            capacity_profile_status: $profile_status,
            capacity_reason: ($capacity.profile_check.reason // $resource.pressure.reason // null),
            recommended_agent_count: $recommended,
            safe_agent_count: $safe,
            timing_ms: (n($timing.duration_ms) // n($rehearsal.timing.duration_ms)),
            mock_rehearsal: {
              enabled: ($rehearsal.enabled // $summary.mock_rehearsal // false),
              status: (status_text($rehearsal.status // "unknown")),
              requested_workers: (n($rehearsal.requested_workers) // $agent_count),
              completed_workers: n($rehearsal.completed_workers),
              failed_workers: n($rehearsal.failed_workers)
            },
            resource_pressure: {
              status: (status_text($resource.pressure.status // "unknown")),
              reason: ($resource.pressure.reason // null)
            },
            rch_snapshot: {
              status: (status_text($telemetry.probes.rch.status // "unknown")),
              available: ($telemetry.probes.rch.available // null),
              queue_depth: n($telemetry.probes.rch.queue_depth),
              active_build_count: n($telemetry.probes.rch.active_build_count),
              slots_total: n($telemetry.probes.rch.slots_total),
              slots_available: n($telemetry.probes.rch.slots_available),
              workers_healthy: n($telemetry.probes.rch.workers_healthy),
              duration_ms: n($telemetry.probes.rch.duration_ms)
            },
            warnings: $warnings,
            diagnostics: {
              malformed_files: $malformed_count,
              missing_files: $missing_count
            }
          }
        '
}

swarm_calibration_collect_scenarios_json() {
    local jq_bin="$1"
    shift

    local input_dir=""
    local scenario_dir=""
    local scenario_json=""
    local -a scenario_jsons=()
    local -a input_warnings=()
    local input_warnings_json=""

    for input_dir in "$@"; do
        if [[ ! -d "$input_dir" ]]; then
            input_warnings+=("Artifact directory not found: $input_dir")
            continue
        fi

        while IFS= read -r scenario_dir; do
            [[ -n "$scenario_dir" ]] || continue
            scenario_json="$(swarm_calibration_scenario_json "$jq_bin" "$scenario_dir")"
            scenario_jsons+=("$scenario_json")
        done < <(
            {
                case "$(basename "$input_dir")" in
                    scenario_*) printf '%s\n' "$input_dir" ;;
                esac
                find "$input_dir" -type d -name 'scenario_*' -print 2>/dev/null || true
            } | sort -u
        )
    done

    input_warnings_json="$(swarm_calibration_json_array "$jq_bin" "${input_warnings[@]}")"

    if [[ ${#scenario_jsons[@]} -eq 0 ]]; then
        "$jq_bin" -n --argjson input_warnings "$input_warnings_json" '{scenarios: [], input_warnings: $input_warnings}'
    else
        printf '%s\n' "${scenario_jsons[@]}" | "$jq_bin" -s --argjson input_warnings "$input_warnings_json" '{scenarios: ., input_warnings: $input_warnings}'
    fi
}

swarm_calibration_rch_json() {
    local jq_bin="$1"
    local rch_file="$2"
    local rch_json="{}"
    local rch_status="missing"
    local -a warnings=()
    local warnings_json=""

    if [[ -z "$rch_file" ]]; then
        warnings_json="$(swarm_calibration_json_array "$jq_bin" "No --rch-file provided; using simulation telemetry only")"
        "$jq_bin" -n --argjson warnings "$warnings_json" '{status: "missing", provided: false, source: null, raw: {}, warnings: $warnings}'
        return 0
    fi

    if [[ ! -f "$rch_file" ]]; then
        warnings+=("RCH timing file not found: $rch_file")
        warnings_json="$(swarm_calibration_json_array "$jq_bin" "${warnings[@]}")"
        "$jq_bin" -n --arg source "$rch_file" --argjson warnings "$warnings_json" '{status: "warn", provided: true, source: $source, raw: {}, warnings: $warnings}'
        return 0
    fi

    if rch_json="$(swarm_calibration_read_single_json "$jq_bin" "$rch_file")"; then
        rch_status="present"
    else
        warnings+=("RCH timing file is malformed JSON: $rch_file")
        rch_status="warn"
        rch_json="{}"
    fi

    warnings_json="$(swarm_calibration_json_array "$jq_bin" "${warnings[@]}")"
    "$jq_bin" -n \
        --arg status "$rch_status" \
        --arg source "$rch_file" \
        --argjson raw "$rch_json" \
        --argjson warnings "$warnings_json" \
        '{status: $status, provided: true, source: $source, raw: $raw, warnings: $warnings}'
}

swarm_calibration_build_report() {
    local jq_bin="$1"
    local inputs_json="$2"
    local rch_json="$3"
    local artifact_dirs_json=""

    artifact_dirs_json="$(swarm_calibration_json_array "$jq_bin" "${SWARM_CAL_ARTIFACT_DIRS[@]}")"

    "$jq_bin" -n \
        --arg generated_at "$SWARM_CAL_GENERATED_AT" \
        --argjson inputs "$inputs_json" \
        --argjson rch "$rch_json" \
        --argjson artifact_dirs "$artifact_dirs_json" \
        '
        def n($v):
          if ($v | type) == "number" then $v
          elif (($v | type) == "string" and ($v | test("^[0-9]+([.][0-9]+)?$"))) then ($v | tonumber)
          else null end;
        def max_or_null: if length == 0 then null else max end;
        def avg_or_null: if length == 0 then null else (add / length) end;
        def bad_status($s): (($s // "unknown") | IN("fail", "failed", "error"));
        def warn_status($s): (($s // "unknown") | IN("warn", "warning", "degraded"));
        def pass_status($s): (($s // "unknown") | IN("pass", "passed", "ok", "success"));
        def classify($s):
          if ($s.valid | not) then "invalid_artifact"
          elif (($s.agent_count != null) and ($s.recommended_agent_count != null) and bad_status($s.observed_status) and ($s.agent_count <= $s.recommended_agent_count)) then "model_too_aggressive"
          elif (($s.agent_count != null) and ($s.recommended_agent_count != null) and warn_status($s.observed_status) and ($s.agent_count <= $s.recommended_agent_count)) then "recommended_tier_warned"
          elif (($s.agent_count != null) and ($s.safe_agent_count != null) and bad_status($s.observed_status) and ($s.agent_count <= $s.safe_agent_count)) then "safe_tier_failed"
          elif (($s.agent_count != null) and ($s.recommended_agent_count != null) and pass_status($s.observed_status) and ($s.agent_count > $s.recommended_agent_count)) then "model_conservative"
          elif pass_status($s.observed_status) then "aligned"
          elif warn_status($s.observed_status) then "watch"
          else "unknown" end;
        def posture($valid):
          if ($valid | length) == 0 then "insufficient_data"
          elif any($valid[]; classify(.) == "model_too_aggressive") then "too_aggressive"
          elif any($valid[]; classify(.) == "recommended_tier_warned" or classify(.) == "safe_tier_failed") then "aggressive_near_limit"
          elif any($valid[]; classify(.) == "model_conservative") then "conservative"
          else "aligned" end;
        def recommendation($posture):
          if $posture == "too_aggressive" then "Do not raise default swarm profiles on this host; reduce recommended counts until recommended-tier rehearsals pass cleanly."
          elif $posture == "aggressive_near_limit" then "Keep default profiles conservative and repeat rehearsals under representative load before increasing agent counts."
          elif $posture == "conservative" then "The static recommendation appears conservative for observed artifacts; consider a larger real rehearsal before changing defaults."
          elif $posture == "aligned" then "Static capacity assumptions match the observed local artifacts."
          else "Run acfs swarm simulate --mock-rehearsal and rerun this calibration with its artifact directory." end;
        def rch_metrics($rch):
          if $rch.status != "present" then {
              status: $rch.status,
              provided: $rch.provided,
              source: $rch.source,
              queue_depth: null,
              active_build_count: null,
              slots_total: null,
              slots_available: null,
              workers_total: null,
              workers_healthy: null,
              duration_ms: null,
              build_duration_ms: null,
              warnings: $rch.warnings
            }
          else
            ($rch.raw // {}) as $raw
            | {
                status: $rch.status,
                provided: $rch.provided,
                source: $rch.source,
                queue_depth: n($raw.queue_depth // $raw.queue.depth // $raw.daemon.queue_depth),
                active_build_count: n($raw.active_build_count // $raw.active_builds_count // ($raw.active_builds | length?)),
                slots_total: n($raw.slots_total // $raw.daemon.slots_total),
                slots_available: n($raw.slots_available // $raw.daemon.slots_available),
                workers_total: n($raw.workers_total // $raw.daemon.workers_total // ($raw.workers | length?)),
                workers_healthy: n($raw.workers_healthy // $raw.workers_available // $raw.daemon.workers_healthy),
                duration_ms: n($raw.duration_ms // $raw.timing.duration_ms),
                build_duration_ms: ([($raw.builds // $raw.timings // [])[]? | n(.duration_ms // .elapsed_ms // .wall_ms)] | map(select(. != null)) | avg_or_null),
                warnings: $rch.warnings
              }
          end;
        ($inputs.scenarios // []) as $scenarios
        | [$scenarios[] | select(.valid == true)] as $valid
        | [$scenarios[] | .warnings[]?] as $scenario_warnings
        | ($inputs.input_warnings + $scenario_warnings + (if ($rch.status == "warn") then $rch.warnings else [] end)) as $warnings
        | (posture($valid)) as $posture
        | (if ($valid | length) == 0 then "fail"
           elif (($warnings | length) > 0 or ($posture | IN("too_aggressive", "aggressive_near_limit"))) then "warn"
           else "pass" end) as $status
        | {
            schema_version: 1,
            generated_at: $generated_at,
            status: $status,
            advisory_only: true,
            simulation_only_evidence: true,
            mutations: {
              capacity_defaults: false,
              rch: false,
              ntm: false,
              beads: false,
              agent_mail: false,
              filesystem_inputs_only: true
            },
            inputs: {
              artifact_dirs: $artifact_dirs,
              rch_file: $rch.source
            },
            summary: {
              artifact_dirs_requested: ($artifact_dirs | length),
              scenarios_total: ($scenarios | length),
              valid_scenarios: ($valid | length),
              malformed_files: ([$scenarios[].diagnostics.malformed_files] | add // 0),
              missing_files: ([$scenarios[].diagnostics.missing_files] | add // 0),
              rehearsal_scenarios: ([$valid[] | select(.mock_rehearsal.enabled == true)] | length),
              max_passing_agents: ([$valid[] | select(pass_status(.observed_status)) | .agent_count] | max_or_null),
              max_recommended_agents_seen: ([$valid[] | .recommended_agent_count | select(. != null)] | max_or_null),
              max_safe_agents_seen: ([$valid[] | .safe_agent_count | select(. != null)] | max_or_null)
            },
            calibration: {
              posture: $posture,
              recommendation: recommendation($posture),
              default_profiles: [
                10, 25, 50
                | . as $count
                | {
                    agent_count: $count,
                    observed_status: (([$valid[] | select(.agent_count == $count) | .observed_status][0]) // "missing"),
                    classification: (([$valid[] | select(.agent_count == $count) | classify(.)][0]) // "missing")
                  }
              ]
            },
            rch: rch_metrics($rch),
            scenarios: [
              $scenarios[]
              | . + {classification: classify(.)}
            ],
            warnings: $warnings,
            next_commands: (
              if ($valid | length) == 0 then
                ["acfs swarm simulate --mock-rehearsal --artifact-dir <dir>", "acfs swarm calibration --artifact-dir <dir>"]
              elif $posture == "too_aggressive" or $posture == "aggressive_near_limit" then
                ["acfs swarm simulate --mock-rehearsal --counts 10 --artifact-dir <dir>", "acfs capacity --json --recommend-ntm"]
              else
                ["acfs swarm simulate --mock-rehearsal --counts 10 --artifact-dir <dir>", "acfs swarm calibration --artifact-dir <dir>"]
              end
            )
          }
        '
}

swarm_calibration_emit_markdown() {
    local report="$1"
    local jq_bin="$2"

    "$jq_bin" -r '
        "ACFS Swarm Capacity Calibration",
        "Status: \(.status)",
        "Posture: \(.calibration.posture)",
        "Recommendation: \(.calibration.recommendation)",
        "",
        "Evidence:",
        "  Artifact dirs: \(.summary.artifact_dirs_requested)",
        "  Scenarios: \(.summary.valid_scenarios)/\(.summary.scenarios_total) valid",
        "  Max passing agents: \(.summary.max_passing_agents // "unknown")",
        "  Max recommended agents seen: \(.summary.max_recommended_agents_seen // "unknown")",
        "  Max safe agents seen: \(.summary.max_safe_agents_seen // "unknown")",
        "  RCH timing: \(.rch.status)",
        "",
        "Default profiles:",
        (.calibration.default_profiles[] | "  - \(.agent_count) agents: \(.observed_status) (\(.classification))"),
        "",
        "Scenarios:",
        (if (.scenarios | length) == 0 then
          "  - None"
        else
          (.scenarios[] | "  - \(.agent_count // "unknown") agents: \(.observed_status) / capacity \(.capacity_profile_status) / \(.classification) / \(.timing_ms // "unknown") ms")
        end),
        "",
        "Warnings:",
        (if (.warnings | length) == 0 then
          "  - None"
        else
          (.warnings[] | "  - \(.)")
        end),
        "",
        "Next commands:",
        (.next_commands[] | "  - \(.)")
    ' <<< "$report"
}

swarm_calibration_main() {
    local parse_status=0
    local jq_bin=""
    local scenarios_inputs_json=""
    local rch_json=""
    local report=""
    local report_status=""

    swarm_calibration_parse_args "$@" || parse_status=$?
    case "$parse_status" in
        0) ;;
        100) return 0 ;;
        *) return "$parse_status" ;;
    esac

    jq_bin="$(swarm_calibration_binary_path jq 2>/dev/null || true)"
    if [[ -z "$jq_bin" ]]; then
        echo "Error: jq is required for swarm capacity calibration" >&2
        return 2
    fi

    scenarios_inputs_json="$(swarm_calibration_collect_scenarios_json "$jq_bin" "${SWARM_CAL_ARTIFACT_DIRS[@]}")"
    rch_json="$(swarm_calibration_rch_json "$jq_bin" "$SWARM_CAL_RCH_FILE")"
    report="$(swarm_calibration_build_report "$jq_bin" "$scenarios_inputs_json" "$rch_json")"

    if [[ "$SWARM_CAL_JSON" == true ]]; then
        printf '%s\n' "$report"
    else
        swarm_calibration_emit_markdown "$report" "$jq_bin"
    fi

    report_status="$("$jq_bin" -r '.status' <<< "$report")"
    case "$report_status" in
        fail) return 2 ;;
        warn) return 1 ;;
        *) return 0 ;;
    esac
}

swarm_calibration_main "$@"
