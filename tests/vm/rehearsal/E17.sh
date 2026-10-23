# shellcheck shell=bash
# E17 The puppet-master hour (METHOD-MATRIX E17; acfs-9hkh.94): an agent
# drives E09's, E10's and E14's actions through nhm's --json and --robot-*
# forms only, nhm capabilities --json first. The puppet master is a Claude
# that runs each command with its shell tool (the mock's 'mock-tool:'
# line); the step talks to it only through nhm send. Its workers are two
# Claudes and a Codex in session e17w. Each round: --robot-status and
# attention (E14), mail and a wake pass (E09), a review sent to the
# Claudes between turns and waited for (E10). Once, between the phases:
# interrupt and recycle (E14). Phase a runs with no controller (plan-v8
# defers the controller; nhm maintain on a timer is the whole runner);
# phase b with nhm maintain --loop beside it. Pass conditions:
# - capabilities ran first, and lists the forms the puppet used;
# - every command the puppet ran exited 0, but the refusal below;
# - every operation in the puppet's results is in nhm's ledger, finished,
#   and so are maintain's in phase b;
# - no silent grant: an unguarded Codex is refused (exit 3) until the
#   puppet passes --allow-unguarded, and its operation records the grant;
# - no human keystroke: each prompt in the puppet's transcript came
#   through an nhm operation (its kickoff and the step's sends);
# - the controller's absence (a) and mode (b) are recorded.
# The matrix's hour is E17_SECONDS (default 3600), half for each phase.

# At source time (outside the sandbox): the run's length.
if [[ -n "${SANDBOX_HOME:-}" ]]; then
    if [[ "${E17_SECONDS:-3600}" =~ ^[0-9]+$ ]]; then
        mkdir -p "$SANDBOX_HOME" && printf '%s\n' "${E17_SECONDS:-3600}" >>"$SANDBOX_HOME/.e17-seconds"
    else
        echo "E17_SECONDS must be a whole number of seconds" >&2
    fi
fi

# e17_do LABEL CMD: the puppet runs the shell line CMD in the project with
# its shell tool; CMD's output lands in e17-LABEL.json and its exit code
# in e17-LABEL.rc. Uses step_E17's dir, puppet and pp. Returns 1 when the
# puppet has not run it within 3 minutes.
e17_do() {
    local label="$1" cmd="$2" out rc line end
    out="$SANDBOX_EVIDENCE/e17-$label.json"
    rc="$SANDBOX_EVIDENCE/e17-$label.rc"
    line="cd $(printf %q "$dir") && { $cmd; } >$(printf %q "$out") 2>&1; echo \$? >$(printf %q "$rc")"
    printf '%s\t%s\n' "$label" "$cmd" >>"$SANDBOX_EVIDENCE/e17-commands.tsv"
    (cd "$dir" && nhm send e17 "Step $label."$'\n'"$(jq -rn --arg c "$line" \
        '"mock-tool: " + ({name: "shell", input: {cmd: $c, description: "nhm"}} | tojson)')" \
        --name "$puppet" --json) >>"$SANDBOX_EVIDENCE/e17-sends.jsonl" 2>&1
    end=$((SECONDS + 180))
    until [[ -s "$rc" ]]; do
        ((SECONDS < end)) || { echo "### $label: the puppet did not run it in 3 minutes"; return 1; }
        sleep 0.5
    done
    settle "$pp"
    echo "### $label (exit $(cat "$rc")): $cmd"
    head -c 1200 "$out"
    echo
}

# e17_op LABEL: the operation id in e17-LABEL.json, or nothing.
e17_op() { jq -r '.operation_id // empty' "$SANDBOX_EVIDENCE/e17-$1.json" 2>/dev/null; }

# e17_round R: one round of the puppet's actions (E14, E09, E10). The
# puppet waits for its review by the send's operation (--after-op,
# --until complete): a worker in a pane nobody views ends its turn in
# herdr's done, which the native --until idle never matches (nhm-y56). A
# wake's nudges are operations without receipts, which --after-op refuses
# (nhm-qaa), so the woken turns are waited for by state, in the robot
# form, whose idle is ntm's: idle or done.
e17_round() {
    local r="$1" op
    e17_do "$r-robot-status" "nhm --robot-status" &&
        e17_do "$r-attention" "nhm attention --json" &&
        e17_do "$r-wake" "am mail send --project $(printf %q "$dir") --from $oper --to $w1,$w2 -s $r -b $(printf %q "round $r") --json >/dev/null && nhm wake --once --json" &&
        e17_do "$r-woken" "nhm --robot-wait=e17w --condition=idle --type=claude --wait-timeout=90s" &&
        e17_do "$r-review" "nhm send e17w --cc --state between $(printf %q "Review round $r."$'\n'"mock-reply: review $r ok") --json" ||
        return 1
    op="$(e17_op "$r-review")"
    [[ -n "$op" ]] || { echo "### $r-review: no operation id"; return 1; }
    e17_do "$r-reviewed" "nhm wait e17w --after-op $op --until complete --timeout 90s --json"
}

# e17_phase NAME SECONDS: rounds NAME1, NAME2… until SECONDS have passed;
# prints how many ran.
e17_phase() {
    local name="$1" end=$((SECONDS + $2)) n=0
    while ((SECONDS < end)); do
        n=$((n + 1))
        e17_round "$name$n" || { echo "### round $name$n stopped"; break; }
    done
    echo "### phase $name: $n rounds" >&2
    printf '%s\n' "$n" >"$SANDBOX_EVIDENCE/e17-rounds-$name"
}

# e17_ledger: checks the operations in the puppet's results (and
# maintain's) against nhm's ledger; prints what it found, fails on a gap.
e17_ledger() {
    local db
    db="$(printf '%s\n' "$HOME/.local/state/nhm"/inst-*/nhm.sqlite3 | head -n 1)"
    python3 -I - "$db" "$SANDBOX_EVIDENCE" <<'PY'
import glob, json, os, sqlite3, sys
db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
evid = sys.argv[2]

def objects(path):
    """Every JSON object in a file of one or more JSON values."""
    text, dec, i, out = open(path, encoding="utf-8", errors="replace").read(), json.JSONDecoder(), 0, []
    while i < len(text):
        j = text.find("{", i)
        if j < 0:
            break
        try:
            obj, i = dec.raw_decode(text, j)
            out.append(obj)
        except ValueError:
            i = j + 1
    return out

def op_ids(obj, found):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "operation_id" and isinstance(v, str) and v:
                found.add(v)
            else:
                op_ids(v, found)
    elif isinstance(obj, list):
        for v in obj:
            op_ids(v, found)

ids = {}
files = glob.glob(os.path.join(evid, "e17-*.json")) + glob.glob(os.path.join(evid, "e17-*.jsonl"))
for path in sorted(files):
    found = set()
    for obj in objects(path):
        op_ids(obj, found)
    for op in found:
        ids.setdefault(op, os.path.basename(path))
bad = []
for op, where in sorted(ids.items()):
    row = db.execute("SELECT verb, status, completed_at FROM operations WHERE operation_id = ?", (op,)).fetchone()
    if row is None:
        bad.append(f"{op} ({where}): not in the ledger")
    elif not row[2]:
        bad.append(f"{op} ({where}): {row[0]} {row[1]}, not finished")
verbs = {}
for (verb,) in db.execute("SELECT verb FROM operations"):
    verbs[verb] = verbs.get(verb, 0) + 1
print(f"operations in the results: {len(ids)}; in the ledger by verb: {json.dumps(verbs, sort_keys=True)}")
for b in bad:
    print("  " + b)
sys.exit(1 if bad or not ids else 0)
PY
}

# e17_prompts SESSION-ID: the puppet's prompts, from its Claude transcript:
# user entries that are neither tool results nor Claude Code's own meta
# lines. Prints the count.
e17_prompts() {
    local f
    f="$(find "$HOME/.claude/projects" -name "$1.jsonl" 2>/dev/null | head -n 1)"
    [[ -n "$f" ]] || { echo "no transcript for $1" >&2; return 1; }
    python3 -I - "$f" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary"):
        continue
    c = (e.get("message") or {}).get("content")
    if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
        continue
    n += 1
print(n)
PY
}

step_E17() {
    local dir oper puppet pp w1 w2 seconds half mpid sess prompts sends caps_first used tool
    seconds="$(head -n 1 "$HOME/.e17-seconds" 2>/dev/null)"
    seconds="${seconds:-3600}"
    half=$((seconds / 2))
    for tool in codex am python3; do
        command -v "$tool" >/dev/null 2>&1 || { echo "FAIL E17: $tool is not in the sandbox"; return; }
    done
    dir="$HOME/e17"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E17: the project"; return; }
    sandbox_claude_prepare "$dir" >/dev/null && sandbox_codex_prepare "$dir" >/dev/null
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E17: Codex trusts herdr's state hook" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E17: nhm could not take the server over"; return; }
    oper="$(am agents create --project "$dir" --program operator --model none --json 2>/dev/null | jq -r '.name // .agent.name // empty')"
    check "E17: the operator's Agent Mail identity" test -n "$oper"
    echo "### run: ${seconds}s, ${half}s per phase"

    # The puppet master: the one agent the step starts, and its only voice.
    (cd "$dir" && nhm spawn e17 --cc=1 --prompt "say hi" --json) >"$SANDBOX_EVIDENCE/e17-puppet.json" 2>&1
    puppet="$(jq -r '.result.agents[0].mail_name // empty' "$SANDBOX_EVIDENCE/e17-puppet.json")"
    pp="$(jq -r '.result.agents[0].pane_id // empty' "$SANDBOX_EVIDENCE/e17-puppet.json")"
    check "E17: the puppet master starts" test -n "$puppet" -a -n "$pp"
    [[ -n "$puppet" && -n "$oper" ]] || return
    settle "$pp"

    # Capabilities first, then the workers, then the grant.
    e17_do caps "nhm capabilities --json"
    e17_do robot-caps "nhm --robot-capabilities"
    e17_do spawn "nhm spawn e17w --cc=2 --prompt 'say hi' --json"
    w1="$(jq -r '.result.agents[0].mail_name // empty' "$SANDBOX_EVIDENCE/e17-spawn.json")"
    w2="$(jq -r '.result.agents[1].mail_name // empty' "$SANDBOX_EVIDENCE/e17-spawn.json")"
    check "E17: the puppet spawns two Claudes" test -n "$w1" -a -n "$w2"
    [[ -n "$w1" && -n "$w2" ]] || return
    # The robot form's idle is ntm's: idle or done.
    e17_do settled "nhm --robot-wait=e17w --condition=idle --wait-timeout=90s"
    e17_do grant-no "nhm add e17w --cod=1 --prompt 'say hi' --json"
    e17_do grant-yes "nhm add e17w --cod=1 --allow-unguarded --prompt 'say hi' --json"
    e17_do codex-settled "nhm --robot-wait=e17w --condition=idle --type=codex --wait-timeout=90s"

    # Phase a: no controller. ([n] keeps pgrep off its own command line.)
    pgrep -af '[n]hm maintain' >"$SANDBOX_EVIDENCE/e17-controller-a.txt" 2>&1
    echo "controller: none (plan-v8 defers the controller; nhm maintain does not run)" >>"$SANDBOX_EVIDENCE/e17-controller-a.txt"
    check "E17 a: no controller runs" bash -c '! pgrep -f "[n]hm maintain" >/dev/null'
    e17_phase a "$half"

    # E14's interrupt and recycle, once. The sandbox has no palette, so the
    # recycle's kickoff is a prompt.
    e17_do interrupt "nhm interrupt e17w --name $w1 --json"
    e17_do recycle "nhm recycle $w2 --prompt 'say hi' --json"
    e17_do recycled "nhm --robot-wait=e17w --condition=idle --type=claude --wait-timeout=90s"

    # Phase b: the controller is plan-v8's runner, nhm maintain on a timer
    # (--once --json every 20 s; --loop prints only what changed, as text).
    (cd "$dir" && while :; do nhm maintain --once --json; sleep 20; done >>"$SANDBOX_EVIDENCE/e17-maintain.jsonl" 2>&1) &
    mpid=$!
    printf 'controller: nhm maintain --once --json every 20 s (timer pid %s)\n' "$mpid" >"$SANDBOX_EVIDENCE/e17-controller-b.txt"
    sleep 1
    check "E17 b: the controller runs" kill -0 "$mpid"
    e17_phase b "$half"
    kill "$mpid" 2>/dev/null
    wait "$mpid" 2>/dev/null

    # --- The checks -------------------------------------------------------
    echo "### rounds: a $(cat "$SANDBOX_EVIDENCE/e17-rounds-a" 2>/dev/null), b $(cat "$SANDBOX_EVIDENCE/e17-rounds-b" 2>/dev/null)"
    check "E17: the puppet ran rounds in both phases" \
        bash -c '(( $(cat "$1/e17-rounds-a") > 0 && $(cat "$1/e17-rounds-b") > 0 ))' _ "$SANDBOX_EVIDENCE"
    caps_first="$(head -n 1 "$SANDBOX_EVIDENCE/e17-commands.tsv" | cut -f1)"
    check "E17: capabilities came first" test "$caps_first" = caps
    check "E17: capabilities answered" jq -e '.result.forms | length > 0' "$SANDBOX_EVIDENCE/e17-caps.json"
    used="$(cut -f2 "$SANDBOX_EVIDENCE/e17-commands.tsv" | grep -oE 'nhm (--robot-[a-z-]+|[a-z]+)' | sort -u | tr '\n' ',')"
    echo "### forms the puppet used: $used"
    # capabilities lists ntm's inventory; nhm's own verbs (attention, wake,
    # recycle, capabilities) are not in it.
    jq -r --arg used "$used" '.result.forms as $f | $used | split(",") | map(select(. != "") | sub("^nhm "; ""))[]
        | . as $u | [$f[] | select(.form | test("(^|[ `])" + $u + "([ =`]|$)"))] as $rows
        | "\($u): " + (if ($rows | length) == 0 then "nhm only" elif ($rows | map(.available) | any) then "available"
            else "NOT available: " + ($rows | map(.reason) | join("; ")) end)' \
        "$SANDBOX_EVIDENCE/e17-caps.json" | tee "$SANDBOX_EVIDENCE/e17-forms.txt"
    check "E17: capabilities lists each ntm form the puppet used as available" \
        bash -c 'grep -q ": available$" "$1" && ! grep -q "NOT available" "$1"' _ "$SANDBOX_EVIDENCE/e17-forms.txt"
    echo "### commands that did not exit 0"
    grep -L '^0$' "$SANDBOX_EVIDENCE"/e17-*.rc | sed 's|.*/e17-||; s|\.rc$||' | tee "$SANDBOX_EVIDENCE/e17-nonzero.txt"
    check "E17: every command the puppet ran exited 0, but the refused grant" \
        bash -c '[[ "$(cat "$1")" == grant-no ]]' _ "$SANDBOX_EVIDENCE/e17-nonzero.txt"
    echo "### the ledger"
    check "E17: every operation in the results is in nhm's ledger, finished" e17_ledger
    check "E17: no silent grant: without --allow-unguarded the Codex is refused (exit 3)" \
        test "$(cat "$SANDBOX_EVIDENCE/e17-grant-no.rc")" = 3
    check "E17: and the grant is in its operation's request" \
        bash -c 'op="$(jq -r ".operation_id // empty" "$1")" && [[ -n "$op" ]] &&
            python3 -I -c "import json, sqlite3, sys
db = sqlite3.connect(\"file:\" + sys.argv[1] + \"?mode=ro\", uri=True)
row = db.execute(\"SELECT request_json FROM operations WHERE operation_id = ?\", (sys.argv[2],)).fetchone()
sys.exit(0 if row and json.loads(row[0]).get(\"allow_unguarded\") is True else 1)" \
            "$(printf "%s\n" "$HOME/.local/state/nhm"/inst-*/nhm.sqlite3 | head -n 1)" "$op"' \
            _ "$SANDBOX_EVIDENCE/e17-grant-yes.json"
    sess="$(nhm resolve "$pp" --json 2>/dev/null | jq -r '.result.binding | (.native_session_json // .native_session)
        | (if type == "string" then fromjson else . end) | .value // empty')"
    prompts="$(e17_prompts "$sess")"
    sends="$(jq -s '[.[] | select(.operation_id != null and .error == null)] | length' "$SANDBOX_EVIDENCE/e17-sends.jsonl" 2>/dev/null)"
    echo "### the puppet's prompts: $prompts; the step's sends: $sends, plus its kickoff"
    check "E17: no human keystroke: each prompt of the puppet came through nhm (kickoff + sends)" \
        test "${prompts:-x}" = "$((${sends:-0} + 1))"
    check "E17 b: the controller made passes" bash -c 'grep -q "\"command\": *\"maintain\"" "$1"' _ "$SANDBOX_EVIDENCE/e17-maintain.jsonl"
}
