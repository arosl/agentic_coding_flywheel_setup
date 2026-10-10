#!/usr/bin/env bash
# ============================================================
# doctor's herdr server and integration checks (acfs-p1k) against a stub
# herdr
#
# The checks must read `herdr status server --json` and `herdr integration
# status` and nothing else, warn rather than fail, judge only the agent
# CLIs that are installed, and name each fix without running it. doctor.sh
# ends in `main "$@"`, so its functions are loaded with that line
# stripped, as the bats tests do.
#
# Usage: bash tests/unit/test_doctor_herdr.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-doctor-herdr.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -z "${out:-}" ]] || printf '%s\n' "$out" | sed 's/^/       | /'; }
check_case() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }

# The stub herdr answers `status server --json` from $STUB_STATUS and
# `integration status` from $STUB_INTEGRATIONS, and logs every call.
mkdir -p "$WORK/bin"
cat >"$WORK/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
case "$*" in
    "status server --json") printf '%s\n' "$STUB_STATUS" ;;
    "integration status") printf '%s' "$STUB_INTEGRATIONS" ;;
    *) exit 99 ;;
esac
STUB
chmod +x "$WORK/herdr"

RUNNING='{"status":"running","running":true,"version":"0.9.3","protocol":22,"capabilities":{"live_handoff":true,"endpoint_protocol_generation":1,"health_check":true},"compatible":true,"endpoint_compatible":true,"socket":"/s","session":null,"restart_needed":false,"server_binary_stale":false}'
NOT_RUNNING='{"status":"not_running","running":false,"version":null,"protocol":null,"capabilities":null,"compatible":null,"endpoint_compatible":null,"socket":"/s","session":null,"restart_needed":false,"server_binary_stale":false}'
CURRENT=$'claude: current (v10) (/h/.claude/hooks/herdr-agent-state.sh)\ncodex: current (v8) (/h/.codex/herdr-agent-state.sh)\nantigravity-cli: current (v3) (/h/.gemini/config/hooks/herdr-agent-state.sh)\nopencode: not installed (/h/.config/opencode/plugins/herdr-agent-state.js)\n'

# Runs the check with doctor's functions loaded, herdr and the CLIs named
# in $3 (space-separated) present, and the collector replaced; prints one
# "id|status|details|fix" line per check.
run_check() {
    local status="$1" integrations="$2" clis="${3-claude codex agy}" ci="${4:-false}" herdr_present="${5:-true}"
    : >"$WORK/calls"
    STUB_CALLS="$WORK/calls" STUB_STATUS="$status" STUB_INTEGRATIONS="$integrations" \
    STUB_HERDR="$WORK/herdr" STUB_CLIS=" $clis " STUB_HERDR_PRESENT="$herdr_present" ACFS_DOCTOR_CI="$ci" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        source <(sed "\$d" "$1") >/dev/null 2>&1
        doctor_binary_path() {
            if [[ "$1" == herdr ]]; then
                [[ "$STUB_HERDR_PRESENT" == true ]] && printf "%s\n" "$STUB_HERDR"
                return 0
            fi
            [[ "$STUB_CLIS" == *" $1 "* ]] && printf "/stub/%s\n" "$1"
            return 0
        }
        _acfs_doctor_system_binary_path() { return 1; }
        check() { printf "%s|%s|%s|%s\n" "$1" "$3" "$4" "${5:-}"; }
        check_herdr_runtime
    ' _ "$DOCTOR"
}
line_of() { grep "^$1|" <<<"$out" || true; }
# shellcheck disable=SC2053 # $2 is a glob pattern on purpose
is() { [[ "$(line_of "$1")" == $2 ]]; }
only_reads() { ! grep -vxE 'status server --json|integration status' "$WORK/calls"; }

echo "tools.herdr.server"
out="$(run_check "$RUNNING" "$CURRENT")"
check_case "a running, compatible server passes with its version" is tools.herdr.server 'tools.herdr.server|pass|running (v0.9.3)|'
check_case "the checks only read status" only_reads

out="$(run_check "${RUNNING/\"server_binary_stale\":false/\"server_binary_stale\":true}" "$CURRENT")"
check_case "an older but compatible server passes, saying a restart picks up the binary" \
    is tools.herdr.server 'tools.herdr.server|pass|running v0.9.3; the herdr binary is newer*'

out="$(run_check "${RUNNING/\"compatible\":true/\"compatible\":false}" "$CURRENT")"
check_case "an incompatible protocol warns, with the restart as the fix" \
    is tools.herdr.server "tools.herdr.server|warn|running v0.9.3, which this herdr binary can't fully talk to*|When no agent is mid-turn: herdr server stop, then herdr"

out="$(run_check "${RUNNING/\"endpoint_compatible\":true/\"endpoint_compatible\":false}" "$CURRENT")"
check_case "an incompatible endpoint generation warns" is tools.herdr.server 'tools.herdr.server|warn|*'

out="$(run_check "${RUNNING/\"restart_needed\":false/\"restart_needed\":true}" "$CURRENT")"
check_case "a server herdr says needs a restart warns" is tools.herdr.server 'tools.herdr.server|warn|*'

out="$(run_check "$NOT_RUNNING" "$CURRENT")"
check_case "no server warns, naming what stops working and how to start it" \
    is tools.herdr.server 'tools.herdr.server|warn|not running: no agent shows working, done or blocked*|Run: herdr (starts the server and attaches)'
check_case "and the integrations are still checked" is tools.herdr.integrations 'tools.herdr.integrations|pass|*'

out="$(run_check "$NOT_RUNNING" "$CURRENT" "claude codex agy" true)"
check_case "no server in CI passes" is tools.herdr.server 'tools.herdr.server|pass|expected in CI|'

out="$(run_check "garbage" "$CURRENT")"
check_case "an unusable answer warns as unknown" \
    is tools.herdr.server 'tools.herdr.server|warn|status unknown*|Run: herdr status server'

out="$(run_check "$RUNNING" "$CURRENT" "claude codex agy" false false)"
check_case "without herdr, neither check reports (tools.herdr does)" test -z "$out"
check_case "and herdr isn't run" test ! -s "$WORK/calls"

echo "tools.herdr.integrations"
out="$(run_check "$RUNNING" "$CURRENT")"
check_case "current integrations for the installed CLIs pass" \
    is tools.herdr.integrations 'tools.herdr.integrations|pass|current for each installed agent CLI|'
check_case "an integration for a CLI that isn't installed is ignored" bash -c '! grep -q opencode <<<"$1"' _ "$out"

out="$(run_check "$RUNNING" "${CURRENT/codex: current (v8)/codex: outdated (v6 < v8)}")"
check_case "an outdated one warns with its state, and names acfs update and the install" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|not current: codex (outdated (v6 < v8));*|Run: acfs update (or: herdr integration install codex)'

out="$(run_check "$RUNNING" "${CURRENT/claude: current (v10)/claude: needs repair (v10)}")"
check_case "one needing repair warns as not current" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|not current: claude (needs repair (v10));*'

out="$(run_check "$RUNNING" "${CURRENT/claude: current (v10)/claude: outdated (v8 < v10)}" "claude codex agy" true)"
check_case "an outdated one still warns in CI" is tools.herdr.integrations 'tools.herdr.integrations|warn|*'

out="$(run_check "$RUNNING" "${CURRENT/codex: current (v8)/codex: not installed}")"
# acfs update installs only pending and outdated targets, so the fix is
# herdr's own command (VioletFortress's review; acfs-74rq).
check_case "a missing one warns, naming herdr integration install for it" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|not installed: codex;*|Start each agent named once (herdr needs its config directory), then run: herdr integration install codex'

out="$(run_check "$RUNNING" "$(sed -e 's/^claude: current (v10)/claude: outdated (v8 < v10)/' -e 's/^codex: current (v8)/codex: not installed/' <<<"$CURRENT")")"
check_case "one outdated and one missing give a single result" \
    test "$(grep -c '^tools.herdr.integrations|' <<<"$out")" = 1
check_case "naming both, and installing both" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|not current: claude (outdated (v8 < v10)); not installed: codex;*|Start each agent named once (herdr needs its config directory), then run: herdr integration install claude && herdr integration install codex'

out="$(run_check "$RUNNING" "${CURRENT/codex: current (v8)/codex: not installed}" "claude codex agy" true)"
check_case "a missing one in CI passes" is tools.herdr.integrations 'tools.herdr.integrations|pass|expected in CI|'

out="$(run_check "$RUNNING" $'claude: current (v10) (/x)\n')"
check_case "a CLI whose target herdr doesn't list counts as not installed" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|not installed: codex antigravity-cli;*'

out="$(run_check "$RUNNING" $'claude: current (v10) (/x)\nopencode (experimental): outdated (v1 < v2) (/y)\n' "claude opencode")"
check_case "an experimental target's line is read" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|not current: opencode (outdated (v1 < v2));*'

out="$(run_check "$RUNNING" "")"
check_case "no answer from integration status warns as unknown" \
    is tools.herdr.integrations 'tools.herdr.integrations|warn|status unknown*|Run: herdr integration status'

out="$(run_check "$RUNNING" "$CURRENT" "")"
check_case "with no agent CLI installed, integrations aren't reported" test -z "$(line_of tools.herdr.integrations)"
check_case "nor asked for" bash -c '! grep -q integration "$1"' _ "$WORK/calls"

echo "the pairs"
manifest_pairs="$(sed -n 's/^ *for pair in \(.*\); do$/\1/p' "$ROOT/acfs.manifest.yaml" | grep -m 1 'claude:claude')"
doctor_pairs="$(sed -n 's/^HERDR_INTEGRATION_PAIRS=(\(.*\))$/\1/p' "$DOCTOR")"
out="manifest: $manifest_pairs; doctor: $doctor_pairs"
check_case "doctor's CLI-to-integration pairs are tools.herdr's install step's" \
    test -n "$doctor_pairs" -a "$manifest_pairs" = "$doctor_pairs"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
