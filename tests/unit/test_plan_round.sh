#!/usr/bin/env bash
# ============================================================
# .agents/skills/plan-round/plan_round.sh against a fake apr and Oracle
#
# Proves that start renders the bundle without Oracle's banner, that the
# prompt it sends names each attached file (start writes a template that
# does, rewrites it when the plan moves on, and refuses a hand-written one
# that misses a file), that it starts apr's ChatGPT Pro review only when the
# Oracle host answers its /health check (and says why not otherwise), that
# the review apr writes is waited for, moved aside and collected, and that
# collect concatenates the round's reviews into the round_N.md apr
# integrates from, never over a round_N.md it did not write.
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
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
file_has() { grep -qF -- "$2" "$1"; }
file_lacks() { ! grep -qF -- "$2" "$1"; }
first_line_is() { [[ "$(head -n 1 "$1")" == "$2" ]]; }
absent() { [[ ! -e "$1" ]]; }
same_file() { cmp -s "$1" "$2"; }
count_is() { [[ "$(grep -cxF -- "$2" "$1")" -eq "$3" ]]; }
# The prompt of a bundle: its [USER] text, up to the first attached file.
prompt_of() { awk '/^### File: / { exit } seen { print } /^\[USER\]$/ { seen = 1 }' "$1"; }
prompt_has() { grep -qF -- "$2" <<<"$(prompt_of "$1")"; }
prompt_lacks() { ! grep -qF -- "$2" <<<"$(prompt_of "$1")"; }
wait_for() {
    local _
    for _ in $(seq 100); do "$@" && return 0; sleep 0.1; done
    return 1
}

# ------------------------------------------------------------
# A plan directory with an apr workflow, and a fake apr. Its render prints
# a banner, then a bundle: the workflow's template (or apr's default prompt,
# with its empty slots), then each document under Oracle's "### File:"
# heading. Its run writes a review to round_N.md the way apr's Oracle run
# does: at once with --wait, and a second after it returns without.
# ------------------------------------------------------------
PLAN="$WORK/plan"
ROUNDS="$PLAN/.apr/rounds/demo"
WORKFLOW="$PLAN/.apr/workflows/demo.yaml"
export FAKE_APR_SENT="$WORK/sent"
mkdir -p "$PLAN/.apr/workflows" "$WORK/bin" "$FAKE_APR_SENT"
printf 'default_workflow: demo\n' >"$PLAN/.apr/config.yaml"
printf 'the brief\n' >"$PLAN/BRIEF.md"
printf 'plan, version 1\n' >"$PLAN/plan-v1.md"
printf 'plan, version 2\n' >"$PLAN/plan-v2.md"
printf 'the evidence\n' >"$PLAN/CONTEXT.md"
write_workflow() {
    printf 'name: demo\ndocuments:\n  readme: "BRIEF.md"\n  spec: "%s"\n' "$1" >"$WORKFLOW"
    [[ -z "${2:-}" ]] || printf '  implementation: "%s"\n' "$2" >>"$WORKFLOW"
    printf 'rounds:\n  output_dir: ".apr/rounds/demo"\n' >>"$WORKFLOW"
}
write_workflow plan-v1.md
cat >"$WORK/bin/apr" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == run ]] || exit 9
round="$2" mode="${3:-}"
wf=".apr/workflows/$(awk '$1 == "default_workflow:" { print $2; exit }' .apr/config.yaml).yaml"
value() { awk -v key="$1" '$1 == key ":" { gsub(/"/, "", $2); print $2; exit }' "$wf"; }
block() { awk -v key="$1" '$0 == key ": |" { on = 1; next } on && /^[^ ]/ { exit } on { sub(/^  /, ""); print }' "$wf"; }
files=("$(value readme)")
[[ -z "$(value implementation)" ]] || files+=("$(value implementation)")
files+=("$(value spec)")
prompt=""
[[ "${#files[@]}" -ne 3 ]] || prompt="$(block template_with_impl)"
[[ -n "$prompt" ]] || prompt="$(block template)"
[[ -n "$prompt" ]] || prompt='First, read this README:

<contents of README will be included by oracle>

NOW: review the plan shown below:

<contents of spec will be included by oracle>'
bundle() {
    printf '[SYSTEM]\nYou are Oracle.\n\n[USER]\n%s\n' "$prompt"
    for f in "${files[@]}"; do
        printf '\n### File: %s\nLines: 1-1\n```md\n1 | %s\n```\n' "$f" "$(head -n 1 "$f")"
    done
}
review() {
    out="$(value output_dir)/round_$round.md"
    mkdir -p "${out%/*}"
    bundle >"$FAKE_APR_SENT/round_$round"
    printf 'gpt pro says: better plan\n' >"$out"
}
case "$mode" in
    --render)
        echo "oracle banner"
        bundle
        ;;
    --wait)
        [[ -z "${FAKE_APR_FAIL:-}" ]] || exit 3
        review
        ;;
    *)
        (
            sleep 1
            review
        ) &
        echo "Oracle running in background"
        ;;
esac
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
MARKER="# plan_round.sh's template: start rewrites it each round, from this line to the end of the file."

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

echo "start without Oracle, on a workflow without a template"
BUNDLE="$PLAN/.apr/round_1.bundle.md"
run_plan_round start 1
check "start exits 0" rc_is 0
check "the bundle starts at [SYSTEM]" first_line_is "$BUNDLE" "[SYSTEM]"
check "the bundle drops Oracle's banner" file_lacks "$BUNDLE" "oracle banner"
check "start says it wrote a template" out_has "template: $WORKFLOW now names this round's documents"
check "the template starts at its marker" count_is "$WORKFLOW" "$MARKER" 1
check "the workflow keeps its own settings" file_has "$WORKFLOW" 'output_dir: ".apr/rounds/demo"'
check "the prompt has no empty slot" prompt_lacks "$BUNDLE" "will be included by oracle"
check "the prompt names the README" prompt_has "$BUNDLE" 'First, read the README, `BRIEF.md`.'
check "the prompt names the plan" prompt_has "$BUNDLE" 'review this entire plan, `plan-v1.md`, for me'
check "the bundle attaches the plan" file_has "$BUNDLE" "### File: plan-v1.md"
check "start names where reviews go" out_has "$ROUNDS/round_1.<reviewer>.md"
check "start says ChatGPT Pro is skipped" out_has "gpt-pro: skipped (ORACLE_REMOTE_HOST is not set)"
check "no apr run without Oracle" absent "$ROUNDS/round_1.gpt-pro.log"
cp "$WORKFLOW" "$WORK/workflow.round1"
run_plan_round start 1
check "the same documents: start exits 0" rc_is 0
check "the same documents: the template is not rewritten" out_lacks "template:"
check "the same documents: the workflow is unchanged" same_file "$WORKFLOW" "$WORK/workflow.round1"

echo "start on the plan's next version"
# The plan's author points the spec at plan-v2.md; start's template from
# round 1 still names plan-v1.md.
write_workflow plan-v2.md
awk -v marker="$MARKER" '$0 == marker { on = 1 } on' "$WORK/workflow.round1" >>"$WORKFLOW"
BUNDLE="$PLAN/.apr/round_2.bundle.md"
run_plan_round start 2
check "a new spec: start exits 0" rc_is 0
check "a new spec: start rewrites its template" out_has "template: $WORKFLOW now names this round's documents"
check "a new spec: one template, not two" count_is "$WORKFLOW" "$MARKER" 1
check "a new spec: the template names it" file_has "$WORKFLOW" '`plan-v2.md`'
check "a new spec: the template drops the old one" file_lacks "$WORKFLOW" '`plan-v1.md`'
check "a new spec: the prompt names it" prompt_has "$BUNDLE" '`plan-v2.md`'
write_workflow plan-v2.md CONTEXT.md
BUNDLE="$PLAN/.apr/round_3.bundle.md"
run_plan_round start 3
check "an implementation: start exits 0" rc_is 0
check "an implementation: the prompt names it" prompt_has "$BUNDLE" 'And `CONTEXT.md` is a document detailing the implementation'
check "an implementation: the prompt still names the plan" prompt_has "$BUNDLE" '`plan-v2.md`'
cp "$WORKFLOW" "$WORK/workflow.round3"
write_workflow plan-v2.md
awk -v marker="$MARKER" '$0 == marker { on = 1 } on' "$WORK/workflow.round3" >>"$WORKFLOW"
BUNDLE="$PLAN/.apr/round_6.bundle.md"
run_plan_round start 6
check "no implementation again: start exits 0" rc_is 0
check "no implementation again: start rewrites its template" out_has "template: $WORKFLOW now names this round's documents"
check "no implementation again: the prompt drops it" prompt_lacks "$BUNDLE" "CONTEXT.md"
check "no implementation again: the prompt still names the plan" prompt_has "$BUNDLE" '`plan-v2.md`'

echo "start on a hand-written template"
write_workflow plan-v2.md
printf 'template: |\n  Read `BRIEF.md`, then review `plan-v1.md`.\n' >>"$WORKFLOW"
cp "$WORKFLOW" "$WORK/workflow.hand"
run_plan_round start 4
check "a stale hand template: exit 2" rc_is 2
check "a stale hand template: names the file it misses" out_has "does not name plan-v2.md"
check "a stale hand template: says how to fix it" out_has "or delete it, and start writes one that does"
check "a stale hand template: is left as it was" same_file "$WORKFLOW" "$WORK/workflow.hand"
check "a stale hand template: no bundle" absent "$PLAN/.apr/round_4.bundle.md"
write_workflow plan-v2.md
printf 'template: |\n  Read `BRIEF.md`, then review `plan-v2.md`.\n' >>"$WORKFLOW"
cp "$WORKFLOW" "$WORK/workflow.hand"
run_plan_round start 4
check "a hand template naming each file: exit 0" rc_is 0
check "a hand template naming each file: is left as it was" same_file "$WORKFLOW" "$WORK/workflow.hand"
check "a hand template naming each file: is the prompt" prompt_has "$PLAN/.apr/round_4.bundle.md" 'then review `plan-v2.md`.'
write_workflow plan-v2.md
printf 'template: |\n  First, read this README:\n  <contents of README will be included by oracle>\n  Review `BRIEF.md` and `plan-v2.md`.\n' >>"$WORKFLOW"
run_plan_round start 4
check "a hand template with apr's slots: exit 2" rc_is 2
check "a hand template with apr's slots: says so" out_has "keeps apr's empty"
write_workflow plan-v1.md

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
printf 'codex: one more\n' >"$ROUNDS/round_7.codex.md"
printf 'gpt pro says: not moved yet\n' >"$ROUNDS/round_7.md"
run_plan_round collect 7
check "a round_7.md collect did not write: exit 2" rc_is 2
check "a round_7.md collect did not write: says where to move it" out_has "move it to round_7.gpt-pro.md"
check "a round_7.md collect did not write: is left as it was" first_line_is "$ROUNDS/round_7.md" "gpt pro says: not moved yet"

echo "start with Oracle"
ORACLE_REMOTE_HOST="$HOST" ORACLE_REMOTE_TOKEN=right-token run_plan_round start 1
check "start says apr run started" out_has "gpt-pro: apr run 1 started"
gpt_pro_collected() { [[ -f "$ROUNDS/round_1.gpt-pro.md" ]] && grep -qF "## Reviewer: gpt-pro" "$ROUNDS/round_1.md"; }
wait_for gpt_pro_collected || true
# apr's run without --wait would land its review a second later, after the
# move: give it the time to, so the checks below would see that.
sleep 1.5
check "apr's review is moved to round_1.gpt-pro.md" file_has "$ROUNDS/round_1.gpt-pro.md" "gpt pro says: better plan"
check "the round is collected again with it" file_has "$ROUNDS/round_1.md" "## Reviewer: gpt-pro"
check "the other reviews stay in round_1.md" file_has "$ROUNDS/round_1.md" "codex: tighten section 2"
check "round_1.md is collect's, not apr's" first_line_is "$ROUNDS/round_1.md" "<!-- collected by plan_round.sh -->"
check "the prompt apr sent has no empty slot" prompt_lacks "$FAKE_APR_SENT/round_1" "will be included by oracle"
check "the prompt apr sent names the plan" prompt_has "$FAKE_APR_SENT/round_1" '`plan-v1.md`'
FAKE_APR_FAIL=1 ORACLE_REMOTE_HOST="$HOST" ORACLE_REMOTE_TOKEN=right-token run_plan_round start 5
gpt_pro_failed() { grep -qF "gpt-pro: apr run 5 --wait failed (exit 3)" "$ROUNDS/round_5.gpt-pro.log"; }
check "a failed apr run says so in its log" wait_for gpt_pro_failed
check "a failed apr run moves nothing" absent "$ROUNDS/round_5.gpt-pro.md"

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
