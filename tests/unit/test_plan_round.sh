#!/usr/bin/env bash
# ============================================================
# .agents/skills/plan-round/plan_round.sh against a fake apr and Oracle
#
# Proves that start renders the bundle without Oracle's banner, that it
# starts apr's ChatGPT Pro review only when the Oracle host answers its
# /health check (and says why not otherwise), that the review apr writes
# is moved aside and collected, and that collect concatenates the round's
# reviews into the round_N.md apr integrates from.
#
# Usage: bash tests/unit/test_plan_round.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAN_ROUND="$ROOT/.agents/skills/plan-round/plan_round.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-plan-round-test.XXXXXX")"
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

OUT="" RC=0
run_plan_round() {
    RC=0
    OUT="$(bash "$PLAN_ROUND" -C "$PLAN" "$@" 2>&1)" || RC=$?
}
rc_is() { [[ "$RC" -eq "$1" ]]; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
file_has() { grep -qF -- "$2" "$1"; }
file_lacks() { ! grep -qF -- "$2" "$1"; }
first_line_is() { [[ "$(head -n 1 "$1")" == "$2" ]]; }
absent() { [[ ! -e "$1" ]]; }

# ------------------------------------------------------------
# A plan directory with an apr workflow, and a fake apr: it renders a
# bundle behind a banner, and its run writes a review to round_N.md the
# way apr's Oracle run does.
# ------------------------------------------------------------
PLAN="$WORK/plan"
ROUNDS="$PLAN/.apr/rounds/demo"
mkdir -p "$PLAN/.apr/workflows" "$WORK/bin"
printf 'default_workflow: demo\n' >"$PLAN/.apr/config.yaml"
printf 'name: demo\nrounds:\n  output_dir: ".apr/rounds/demo"\n' >"$PLAN/.apr/workflows/demo.yaml"
cat >"$WORK/bin/apr" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == run ]] || exit 9
if [[ "${3:-}" == --render ]]; then
    printf 'oracle banner\n[SYSTEM]\nrevise this plan, round %s\n' "$2"
    exit 0
fi
mkdir -p .apr/rounds/demo
printf 'gpt pro says: better plan\n' >".apr/rounds/demo/round_$2.md"
EOF
chmod +x "$WORK/bin/apr"
export PATH="$WORK/bin:$PATH"

# A stand-in for `oracle serve`: /health answers ok to the right token.
cat >"$WORK/server.py" <<'EOF'
import http.server, sys
class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/health" and self.headers.get("Authorization") == "Bearer right-token"
        self.send_response(200 if ok else 401)
        self.end_headers()
        self.wfile.write(b'{"ok": true}' if ok else b'{"error": "unauthorized"}')
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Health)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
python3 -I "$WORK/server.py" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
HOST="127.0.0.1:$(cat "$WORK/port")"
# A port with nothing listening: the server's, once it is stopped, is not
# reliable, so a closed low port stands in.
DEAD_HOST="127.0.0.1:9"

echo "oracle"
unset ORACLE_REMOTE_HOST ORACLE_REMOTE_TOKEN
run_plan_round oracle
check "no host: skipped, exit 1" rc_is 1
check "no host: says why" out_has "gpt-pro: skipped (ORACLE_REMOTE_HOST is not set)"
ORACLE_REMOTE_HOST="$HOST" run_plan_round oracle
check "no token: skipped" out_has "ORACLE_REMOTE_TOKEN is not set"
ORACLE_REMOTE_HOST="$HOST" ORACLE_REMOTE_TOKEN=wrong-token run_plan_round oracle
check "wrong token: skipped, exit 1" rc_is 1
check "wrong token: says /health is not ok" out_has "its /health is not ok"
ORACLE_REMOTE_HOST="$DEAD_HOST" ORACLE_REMOTE_TOKEN=right-token run_plan_round oracle
check "nothing listening: skipped" out_has "gpt-pro: skipped ($DEAD_HOST does not answer"
ORACLE_REMOTE_HOST="$HOST" ORACLE_REMOTE_TOKEN=right-token run_plan_round oracle
check "a host that answers: exit 0" rc_is 0
check "a host that answers: says so" out_has "gpt-pro: $HOST answers"

echo "start without Oracle"
run_plan_round start 1
check "start exits 0" rc_is 0
check "the bundle starts at [SYSTEM]" first_line_is "$PLAN/.apr/round_1.bundle.md" "[SYSTEM]"
check "the bundle drops Oracle's banner" file_lacks "$PLAN/.apr/round_1.bundle.md" "oracle banner"
check "the bundle holds the round's prompt" file_has "$PLAN/.apr/round_1.bundle.md" "revise this plan, round 1"
check "start names where reviews go" out_has "$ROUNDS/round_1.<reviewer>.md"
check "start says ChatGPT Pro is skipped" out_has "gpt-pro: skipped (ORACLE_REMOTE_HOST is not set)"
check "no apr run without Oracle" absent "$ROUNDS/round_1.gpt-pro.log"

echo "collect"
run_plan_round collect 1
check "no reviews: exit 2" rc_is 2
printf 'codex: tighten section 2\n' >"$ROUNDS/round_1.codex.md"
printf 'claude: add a rollback\n' >"$ROUNDS/round_1.claude.md"
run_plan_round collect 1
check "collect exits 0" rc_is 0
check "collect counts the reviews" out_has "collected 2 review(s)"
check "round_1.md carries collect's marker" first_line_is "$ROUNDS/round_1.md" "<!-- collected by plan_round.sh -->"
check "round_1.md names the codex reviewer" file_has "$ROUNDS/round_1.md" "## Reviewer: codex"
check "round_1.md holds the codex review" file_has "$ROUNDS/round_1.md" "codex: tighten section 2"
check "round_1.md holds the claude review" file_has "$ROUNDS/round_1.md" "claude: add a rollback"

echo "start with Oracle"
ORACLE_REMOTE_HOST="$HOST" ORACLE_REMOTE_TOKEN=right-token run_plan_round start 1
check "start says apr run started" out_has "gpt-pro: apr run 1 started"
for _ in $(seq 100); do [[ -f "$ROUNDS/round_1.gpt-pro.md" ]] && grep -qF "gpt pro says" "$ROUNDS/round_1.md" && break; sleep 0.1; done
check "apr's review is moved to round_1.gpt-pro.md" file_has "$ROUNDS/round_1.gpt-pro.md" "gpt pro says: better plan"
check "the round is collected again with it" file_has "$ROUNDS/round_1.md" "## Reviewer: gpt-pro"
check "the other reviews stay in round_1.md" file_has "$ROUNDS/round_1.md" "codex: tighten section 2"
check "round_1.md is collect's, not apr's" first_line_is "$ROUNDS/round_1.md" "<!-- collected by plan_round.sh -->"

echo "usage"
run_plan_round start x
check "a bad round number exits 2" rc_is 2
mkdir -p "$WORK/empty"
RC=0
OUT="$(bash "$PLAN_ROUND" -C "$WORK/empty" collect 1 2>&1)" || RC=$?
check "a directory without .apr exits 2" rc_is 2
check "a directory without .apr says so" out_has "no apr workflow in"
run_plan_round bogus
check "an unknown command exits 2" rc_is 2

echo
echo "plan_round: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
