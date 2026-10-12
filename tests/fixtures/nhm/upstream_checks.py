"""What upstream's swarm scripts assert on ntm's robot output.

The predicates are copied from upstream ACFS at
b1819865b33119c832498ebcb6817cd44f371ff9, with "NTM" kept in the messages:
- spawn_response: scripts/lib/swarm_launch.sh, spawn_response (lines 191-210);
- send_preview: scripts/lib/swarm_packet.sh, deliver (lines 1082-1093), the
  dry-run check and the injection check;
- outcome: scripts/lib/swarm_packet.sh, outcome (lines 949-965);
- status_sessions: plan-v8 2.12, sessions as an array of StatusSessionHeader
  (upstream's swarm_status.sh only needs exit 0 and output).

acfs-9hkh.27's nhm branch must accept nhm's output under exactly these
predicates; tests/unit/test_nhm_caller_fixtures.sh checks the fixtures
beside this file against them.
"""

import re
from collections import Counter


class CheckError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckError(message)


def spawn_response(result, request, dry_run):
    require(isinstance(result, dict) and result.get("success") is True
            and result.get("session") == request["session"] and result.get("working_dir") == request["repo"]
            and result.get("effective_project_key", request["repo"]) == request["repo"]
            and result.get("dry_run", False) is dry_run and not result.get("assignments")
            and not result.get("error"), "NTM did not confirm the exact requested native-agent launch.")
    pressure = result.get("admission")
    require(isinstance(pressure, dict) and pressure.get("decision") == "admit",
            "NTM resource admission is unavailable or does not admit this launch.")
    agents = result.get("would_create" if dry_run else "agents")
    require(isinstance(agents, list) and len(agents) == len(request["agents"])
            and all(isinstance(a, dict) and a.get("type") in ("claude", "codex")
                    and isinstance(a.get("pane"), str) and re.fullmatch(r"[0-9]+\.[0-9]+", a["pane"])
                    and not a.get("error") for a in agents), "NTM returned unexpected agent topology.")
    require(len({a["pane"] for a in agents}) == len(agents)
            and Counter(a["type"] for a in agents) == Counter(a["agent_type"] for a in request["agents"]),
            "NTM returned duplicate panes or the wrong agent mix.")
    require(dry_run or all(a.get("ready") is True for a in agents),
            "Some native agents are not ready; inspect the retained session, do not relaunch.")
    return agents


def send_preview(preview, request):
    require(isinstance(preview, dict) and preview.get("success") is True
            and preview.get("session") == request["session"] and preview.get("dry_run") is True
            and preview.get("blocked") is False and preview.get("successful") == []
            and preview.get("failed") == [] and isinstance(preview.get("would_send_to"), list)
            and len(preview["would_send_to"]) == 1 and isinstance(preview["would_send_to"][0], str),
            "NTM did not confirm exactly one matching agent target; no prompt was sent.")
    for key in ("cm_injection", "memory_injection", "cass_injection"):
        enrichment = preview.get(key)
        require(enrichment is None or (isinstance(enrichment, dict) and enrichment.get("enabled") is False),
                "Disable NTM send-time context injection before delivering an already-reviewed packet.")
    return preview["would_send_to"][0]


def outcome(response, request, target, receipt_query=False):
    require(isinstance(response, dict), "Unrecognized NTM response; inspect the receipt.")
    operation = response.get("operation")
    require(isinstance(operation, dict), "NTM did not return a durable operation; inspect the receipt.")
    require(response.get("session") == request["session"]
            and operation.get("operation_id") == request["operation_id"]
            and operation.get("payload_sha256") == request["payload_sha256"]
            and operation.get("payload_bytes") == request["payload_bytes"],
            "NTM receipt does not match this packet and session; no automatic retry.")
    result = response.get("outcome") if receipt_query else response
    admissions = operation.get("admissions")
    submitted = (response.get("success") is True and operation.get("status") == "completed"
                 and isinstance(result, dict) and result.get("success") is True
                 and result.get("targets") == [target] and result.get("successful") == [target]
                 and result.get("failed") == []
                 and admissions == [{"target": target, "state": "submitted"}])
    return "submitted" if submitted else "unconfirmed"


def status_sessions(status):
    require(isinstance(status, dict) and status.get("success") is True
            and isinstance(status.get("sessions"), list)
            and all(isinstance(s, dict) and isinstance(s.get("name"), str)
                    and type(s.get("agent_count")) is int and isinstance(s.get("health"), dict)
                    for s in status["sessions"]),
            "--robot-status sessions are not an array of StatusSessionHeader.")
    return status["sessions"]
