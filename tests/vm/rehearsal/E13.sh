# shellcheck shell=bash
# E13 Rate limit, caam, CASR (METHOD-MATRIX E13; acfs-9hkh.94): a
# simulated limit, the replacement spawn's admission, and a session casr
# converts and nhm adopts. Pass conditions: nhm limits --json reports the
# limit within one pass and mails once; a replacement spawn on a plan
# with headroom is admitted, one at 90 % is refused; casr's dry run
# writes nothing; nhm resolve shows the converted session's provider and
# native session; the adopted session has a new generation, and a wait
# on the old one fails.
#
# The limit is a usage-limit line in the Claude's reply (the mock's
# 'mock-reply:' line): nhm limits reads the screen, and an agent can print
# a fake limit line, which is why a match only reports.
# casr runs in the sandbox from the host's binary, bound when the step
# file is sourced. The caam switch is not automated yet.

# At source time (outside the sandbox): casr.
if [[ -n "${SANDBOX_HOME:-}" ]] && command -v casr >/dev/null 2>&1; then
    sandbox_bin casr
fi

# e13_json LABEL CMD...: runs CMD in the project, saves its output as
# e13-LABEL.json and shows it.
e13_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e13" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e13-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e13_file() { printf '%s/e13-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e13_quota PERCENT: Claude's five-hour window at PERCENT, as Claude
# Code's statusLine feeds it to nhm.
e13_quota() {
    printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%d}}}' \
        "$1" "$(($(date +%s) + 3600))" | nhm quota record-claude >/dev/null 2>&1
}

# e13_row NAME: the agent's row in `nhm list --json` (one line), or nothing.
e13_row() {
    nhm list --json 2>/dev/null | jq -c --arg n "$1" 'first(.result.agents[]? | select(.binding.mail_name == $n)) // empty'
}

step_E13() {
    local dir oper l pl limit x px bx gen sess t waitpid i
    for tool in codex casr am; do
        command -v "$tool" >/dev/null 2>&1 || { echo "FAIL E13: $tool is not in the sandbox (is it on the host's PATH?)"; return; }
    done
    dir="$HOME/e13"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E13: the project"; return; }
    sandbox_claude_prepare "$dir" >/dev/null && sandbox_codex_prepare "$dir" >/dev/null
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E13: Codex trusts herdr's state hook" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E13: nhm could not take the server over"; return; }

    # --- The simulated limit ---------------------------------------------
    e13_json oper am agents create --project "$dir" --program operator --model none --json
    oper="$(jq -r '.name // .agent.name // empty' "$(e13_file oper)")"
    check "E13: the operator's Agent Mail identity" test -n "$oper"
    e13_quota 10
    e13_json spawn nhm spawn e13 --cc=1 --prompt "say hi" --json
    l="$(jq -r '.result.agents[0].mail_name // empty' "$(e13_file spawn)")"
    pl="$(jq -r '.result.agents[0].pane_id // empty' "$(e13_file spawn)")"
    check "E13: the Claude starts" test -n "$l" -a -n "$pl"
    [[ -n "$l" && -n "$oper" ]] || return
    settle "$pl"
    limit="You've hit your limit · resets 5pm (UTC)"
    e13_json limit-send nhm send e13 "Go on."$'\n'"mock-reply: $limit" --name "$l" --json
    settle "$pl"
    herdr pane read "$pl" --source visible --lines 25 >"$SANDBOX_EVIDENCE/e13-limit-screen.txt" 2>&1
    # With its default 15 lines nhm limits misses the line: a short
    # session's screen has blank lines above Claude's prompt box (nhm-1q7).
    # This check fails until nhm reads past them; the dry run mails nothing
    # and leaves the line unseen. The passes below read 40 lines.
    e13_json limits-default nhm limits e13 --once --dry-run --json
    check "E13: nhm limits sees a new agent's limit with its default --lines (nhm-1q7)" \
        jq -e --arg n "$l" '[.result.reports[]? | select(.name == $n)] | length == 1' "$(e13_file limits-default)"
    e13_json limits-1 nhm limits e13 --once --lines 40 --mail-from "$oper" --json
    check "E13: nhm limits --json reports the limit in one pass" \
        jq -e --arg n "$l" '[.result.reports[]? | select(.name == $n and (.line | test("hit your limit")))] | length == 1' \
            "$(e13_file limits-1)"
    check "E13: and mails it" \
        jq -e --arg n "$l" '[.result.reports[]? | select(.name == $n and .mailed)] | length == 1' "$(e13_file limits-1)"
    e13_json limits-2 nhm limits e13 --once --lines 40 --mail-from "$oper" --json
    check "E13: a second pass reports it no more (after the first did)" \
        bash -c 'jq -e --arg n "$3" "[.result.reports[]? | select(.name == \$n)] | length == 1" "$1" >/dev/null &&
            jq -e --arg n "$3" "[.result.reports[]? | select(.name == \$n)] | length == 0" "$2" >/dev/null' \
            _ "$(e13_file limits-1)" "$(e13_file limits-2)" "$l"
    e13_json inbox am check-inbox --agent "$oper" --project "$dir" --rate-limit 0 --json
    check "E13: the operator has one message about it (mailed once)" \
        jq -e --arg n "$l" '[.messages[]? | select(((.subject // "") + (.body_md // "")) | contains($n))] | length == 1' \
            "$(e13_file inbox)"

    # --- The replacement spawn's admission --------------------------------
    e13_quota 50
    e13_json admit-50 nhm spawn e13r --cc=1 --prompt "say hi" --dry-run --json
    check "E13: a replacement spawn with headroom (50 %) is admitted" \
        jq -e '[.. | objects | select(has("admission")) | .admission.decision][0] == "admit"' "$(e13_file admit-50)"
    e13_quota 92
    e13_json admit-92 nhm spawn e13r --cc=1 --prompt "say hi" --dry-run --json
    check "E13: one at 92 % is refused" \
        jq -e '[.. | objects | select(has("admission")) | .admission.decision][0] == "refuse"' "$(e13_file admit-92)"
    e13_quota 10

    # --- casr: a Codex's session converted for Claude, adopted -------------
    e13_json cod nhm spawn e13c --cod=1 --allow-unguarded --prompt "say hi" --json
    x="$(jq -r '.result.agents[0].mail_name // empty' "$(e13_file cod)")"
    px="$(jq -r '.result.agents[0].pane_id // empty' "$(e13_file cod)")"
    bx="$(jq -r '.result.agents[0].binding_id // empty' "$(e13_file cod)")"
    check "E13: the Codex starts, ready" jq -e '.result.agents[0].ready == true' "$(e13_file cod)"
    [[ -n "$x" ]] || return
    settle "$px"
    gen="$(e13_row "$x" | jq -r '.binding.generation // empty')"
    sess="$(e13_row "$x" | jq -r '.agent_session.value // empty')"
    echo "### $x in $px ($bx, generation $gen), Codex session $sess"
    check "E13: the Codex has a session" test -n "$sess"
    # The Codex leaves its pane; a wait on its binding starts.
    # /quit, then Codex's double Ctrl-C if it is still there.
    herdr pane send-text "$px" "/quit" >/dev/null 2>&1
    sleep 0.5
    herdr pane send-keys "$px" enter >/dev/null 2>&1
    for i in $(seq 1 40); do
        herdr agent get "$px" >/dev/null 2>&1 || break
        if ((i == 10)); then
            herdr pane send-keys "$px" ctrl+c >/dev/null 2>&1
            sleep 0.3
            herdr pane send-keys "$px" ctrl+c >/dev/null 2>&1
        fi
        sleep 0.5
    done
    check "E13: the Codex left its pane" bash -c '! herdr agent get "$1" >/dev/null 2>&1' _ "$px"
    (cd "$dir" && nhm wait e13c --name "$x" --until idle --timeout 3m --json >"$SANDBOX_EVIDENCE/e13-old-wait.json" 2>&1;
        echo "exit $?" >>"$SANDBOX_EVIDENCE/e13-old-wait.json") &
    waitpid=$!
    e13_json casr-dry casr --json resume cc "$sess" --dry-run
    check "E13: casr's dry run plans the conversion and writes nothing" \
        jq -e '.ok and .dry_run and .source_provider == "codex" and .target_provider == "claude-code" and .written_paths == null' \
            "$(e13_file casr-dry)"
    e13_json casr casr --json resume cc "$sess" --enrich
    t="$(jq -r '.target_session_id // empty' "$(e13_file casr)")"
    check "E13: casr converts the session" test -n "$t"
    e13_json resume herdr agent start converted --kind claude --pane "$px" --timeout 60000 -- \
        --dangerously-skip-permissions --resume "$t"
    check "E13: Claude resumes the converted session in the Codex's pane" \
        jq -e '.result.agent.agent_status | test("idle|done")' "$(e13_file resume)"
    e13_json adopt nhm adopt "$x" --pane "$px" --handoff-from "$bx" --kind claude --json
    check "E13: nhm adopt takes it over with a new generation" \
        jq -e --argjson g "${gen:-0}" '.error == null and .result.binding.generation == ($g + 1)' "$(e13_file adopt)"
    nhm resolve "$px" --json >"$SANDBOX_EVIDENCE/e13-resolve.json" 2>&1
    check "E13: nhm resolve shows the provider and the native session" \
        jq -e --arg n "$x" --arg t "$t" '.result.binding | .mail_name == $n and .kind == "claude"
            and (.native_session_json // .native_session | (if type == "string" then fromjson else . end) | .value == $t)' \
            "$SANDBOX_EVIDENCE/e13-resolve.json"
    for i in $(seq 1 60); do
        kill -0 "$waitpid" 2>/dev/null || break
        sleep 0.5
    done
    kill "$waitpid" 2>/dev/null
    wait "$waitpid" 2>/dev/null
    echo "### the old wait"
    cat "$SANDBOX_EVIDENCE/e13-old-wait.json"
    check "E13: the wait on the old generation fails" \
        bash -c 'grep -q "^exit 1$" "$1" && grep -Eq "replaced|continuity_lost" "$1"' _ "$SANDBOX_EVIDENCE/e13-old-wait.json"

    echo "FAIL E13: the caam switch is not automated yet (acfs-9hkh.94)"
}
