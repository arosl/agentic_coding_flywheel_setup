# shellcheck shell=bash
# E13 Rate limit, caam, CASR (METHOD-MATRIX E13; acfs-9hkh.94). a: a
# Claude; b: a Codex. Pass conditions, with plan-v8's contracts where the
# matrix predates them:
# - a fake limit line on an agent's screen yields one report and one mail
#   from nhm limits and an attention item (agent_at_limit), and changes no
#   admission: an agent can print a fake line, so a match only reports;
# - the provider's own limit record (Codex's session log) makes its pool
#   limited (quota_limited) and refuses a spawn of that kind;
# - a spawn on a plan at 90 % or more is refused with exit 3 (plan-v8's
#   code for an admission refusal; the matrix's quota_exhausted predates
#   it) and starts nothing, and one with headroom is admitted;
# - after a caam switch the earlier observation of that pool is unknown,
#   so the spawn the old 92 % refused is admitted with a warning;
# - casr's dry run writes nothing; the converted session, adopted with nhm
#   adopt, has a new generation, nhm resolve shows its kind, model and
#   native session, and a wait on the old generation fails.
#
# The limit lines are the agents' replies (the mock's 'mock-reply:' line).
# casr and caam run in the sandbox from the host's binaries, bound when
# the step file is sourced; the fork's caam keeps upstream's backup and
# activate.

# At source time (outside the sandbox): casr and caam.
if [[ -n "${SANDBOX_HOME:-}" ]]; then
    if command -v casr >/dev/null 2>&1; then sandbox_bin casr; fi
    if command -v caam >/dev/null 2>&1; then sandbox_bin caam; fi
fi

# e13_json LABEL CMD...: runs CMD in the project, saves its output as
# e13-LABEL.json and its exit code as e13-LABEL.rc, and shows both.
e13_json() {
    local label="$1" out rc
    shift
    out="$(cd "$HOME/e13" && "$@" 2>&1)"
    rc=$?
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e13-$label.json"
    printf '%s\n' "$rc" >"$SANDBOX_EVIDENCE/e13-$label.rc"
    echo "### $label (exit $rc): $*"
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

# e13_codex_record PERCENT [TYPE]: Codex's own rate-limit record, as Codex
# writes it: a token_count event with its five-hour window at PERCENT, and
# rate_limit_reached_type TYPE when given, in a session log.
e13_codex_record() {
    local now day reached=""
    now="$(date -u +%s)"
    day="$CODEX_HOME/sessions/$(date -u +%Y/%m/%d)"
    mkdir -p "$day" || return 1
    [[ -z "${2:-}" ]] || reached="$(printf ',"rate_limit_reached_type":"%s"' "$2")"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%d},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":%d}%s}}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$((now + 3600))" "$((now + 259200))" "$reached" \
        >>"$day/rollout-$(date -u +%Y-%m-%dT%H-%M-%S)-e13-limit.jsonl"
}

# e13_decision FILE: the admission decision in a spawn's JSON.
e13_decision() { jq -r '[.. | objects | select(has("admission")) | .admission.decision][0] // empty' "$1" 2>/dev/null; }

step_E13() {
    local dir oper l pl limit x px bx gen sess t waitpid i cred
    for tool in codex casr caam am; do
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

    # --- a: a fake limit line --------------------------------------------
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
    # A short session's screen has blank lines above Claude's prompt box;
    # nhm limits reads past them since v0.1.13 (nhm-1q7). The dry run mails
    # nothing and leaves the line unseen.
    e13_json limits-default nhm limits e13 --once --dry-run --json
    check "E13: a dry run sees a new agent's limit with the default --lines (nhm-1q7)" \
        jq -e --arg n "$l" '[.result.reports[]? | select(.name == $n and (.mailed | not))] | length == 1' "$(e13_file limits-default)"
    e13_json limits-1 nhm limits e13 --once --mail-from "$oper" --json
    check "E13: nhm limits --json reports the limit in one pass" \
        jq -e --arg n "$l" '[.result.reports[]? | select(.name == $n and (.line | test("hit your limit")))] | length == 1' \
            "$(e13_file limits-1)"
    check "E13: and mails it" \
        jq -e --arg n "$l" '[.result.reports[]? | select(.name == $n and .mailed)] | length == 1' "$(e13_file limits-1)"
    e13_json limits-2 nhm limits e13 --once --mail-from "$oper" --json
    check "E13: a second pass reports it no more (after the first did)" \
        bash -c 'jq -e --arg n "$3" "[.result.reports[]? | select(.name == \$n)] | length == 1" "$1" >/dev/null &&
            jq -e --arg n "$3" "[.result.reports[]? | select(.name == \$n)] | length == 0" "$2" >/dev/null' \
            _ "$(e13_file limits-1)" "$(e13_file limits-2)" "$l"
    e13_json inbox am check-inbox --agent "$oper" --project "$dir" --rate-limit 0 --json
    check "E13: the operator has one message about it (mailed once)" \
        jq -e --arg n "$l" '[.messages[]? | select(((.subject // "") + (.body_md // "")) | contains($n))] | length == 1' \
            "$(e13_file inbox)"
    e13_json attention-limit nhm attention --json
    check "E13: the line is an attention item (agent_at_limit)" \
        jq -e --arg n "$l" '[.result[]? | select(.kind == "agent_at_limit" and ((.mail_name // "") == $n or (.detail | contains($n))))]
            | length == 1' "$(e13_file attention-limit)"

    # --- a: the replacement spawn's admission ----------------------------
    e13_quota 50
    e13_json admit-50 nhm spawn e13r --cc=1 --prompt "say hi" --dry-run --json
    check "E13: the fake line changes no admission: with headroom (50 %) a spawn is admitted" \
        test "$(e13_decision "$(e13_file admit-50)")" = admit
    e13_quota 92
    e13_json refuse-92 nhm spawn e13r --cc=1 --prompt "say hi" --json
    # The refused spawn lists its targets as planned, with no pane.
    check "E13: at 92 % a spawn is refused with exit 3 and starts nothing" \
        bash -c '[[ "$2" == refuse && "$(cat "${1%.json}.rc")" == 3 ]] &&
            jq -e "[.result.agents[]? | select((.pane_id // \"\") != \"\" or .status != \"planned\")] | length == 0" "$1" >/dev/null' \
            _ "$(e13_file refuse-92)" "$(e13_decision "$(e13_file refuse-92)")"
    e13_quota 10

    # --- b: a Codex's fake limit line ------------------------------------
    e13_json cod nhm spawn e13c --cod=1 --allow-unguarded --prompt "say hi" --json
    x="$(jq -r '.result.agents[0].mail_name // empty' "$(e13_file cod)")"
    px="$(jq -r '.result.agents[0].pane_id // empty' "$(e13_file cod)")"
    bx="$(jq -r '.result.agents[0].binding_id // empty' "$(e13_file cod)")"
    check "E13: the Codex starts, ready" jq -e '.result.agents[0].ready == true' "$(e13_file cod)"
    [[ -n "$x" ]] || return
    settle "$px"
    e13_json cod-limit-send nhm send e13c \
        "Go on."$'\n'"mock-reply: You've hit your usage limit. Upgrade to Pro or try again at 5:00 PM." --name "$x" --json
    settle "$px"
    herdr pane read "$px" --source visible --lines 40 >"$SANDBOX_EVIDENCE/e13-cod-limit-screen.txt" 2>&1
    e13_json cod-limits nhm limits e13c --once --mail-from "$oper" --json
    check "E13 b: nhm limits reports the Codex's limit line and mails it" \
        jq -e --arg n "$x" '[.result.reports[]? | select(.name == $n and .kind == "codex" and .mailed)] | length == 1' \
            "$(e13_file cod-limits)"

    # --- casr: the Codex's session converted for Claude, adopted -----------
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
        --dangerously-skip-permissions --model sonnet --resume "$t"
    check "E13: Claude resumes the converted session in the Codex's pane" \
        jq -e '.result.agent.agent_status | test("idle|done")' "$(e13_file resume)"
    e13_json adopt nhm adopt "$x" --pane "$px" --handoff-from "$bx" --kind claude --model sonnet --json
    check "E13: nhm adopt takes it over with a new generation" \
        jq -e --argjson g "${gen:-0}" '.error == null and .result.binding.generation == ($g + 1)' "$(e13_file adopt)"
    nhm resolve "$px" --json >"$SANDBOX_EVIDENCE/e13-resolve.json" 2>&1
    check "E13: nhm resolve shows the kind, the model and the native session" \
        jq -e --arg n "$x" --arg t "$t" '.result.binding | .mail_name == $n and .kind == "claude" and .model == "sonnet"
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

    # --- b: Codex's own limit record (after casr, which reads the logs) ----
    e13_codex_record 100.0 primary || echo "FAIL E13: could not write the Codex record"
    e13_json quota-codex nhm quota --json
    check "E13 b: Codex's record makes the codex pool limited" \
        jq -e '[.result.pools[]? | select(.pool_id == "codex" and .limit_reached != null and (.limit_reached.stale | not))] | length == 1' \
            "$(e13_file quota-codex)"
    e13_json attention-quota nhm attention --json
    check "E13 b: and is an attention item (quota_limited)" \
        jq -e '[.result[]? | select(.kind == "quota_limited" and (.detail | startswith("codex")))] | length >= 1' \
            "$(e13_file attention-quota)"
    e13_json refuse-codex nhm spawn e13s --cod=1 --allow-unguarded --prompt "say hi" --dry-run --json
    check "E13 b: a Codex spawn is refused at the limit" test "$(e13_decision "$(e13_file refuse-codex)")" = refuse
    # The window resets: Codex's next record has no limit, and the pool is
    # open again (the later steps of a run share this HOME).
    sleep 1
    e13_codex_record 10.0 || echo "FAIL E13: could not write the Codex record"
    e13_json quota-codex-reset nhm quota --json
    check "E13 b: a newer record without the limit opens the codex pool again" \
        jq -e '[.result.pools[]? | select(.pool_id == "codex" and .limit_reached == null)] | length == 1' \
            "$(e13_file quota-codex-reset)"

    # --- a: a caam switch (last: it puts stand-in credentials in place) ----
    # The sandbox's Claude has an API key and no credentials file; caam
    # backs up and restores the file, so two stand-ins make two accounts.
    cred="$HOME/.claude/.credentials.json"
    printf '{"claudeAiOauth":{"accessToken":"e13-account-a"}}\n' >"$cred.new" && mv -f "$cred.new" "$cred"
    e13_json caam-a caam backup claude e13a
    printf '{"claudeAiOauth":{"accessToken":"e13-account-b"}}\n' >"$cred.new" && mv -f "$cred.new" "$cred"
    e13_json caam-b caam backup claude e13b
    e13_json caam-on-a caam activate claude e13a
    e13_quota 92
    e13_json switch-before nhm spawn e13r --cc=1 --prompt "say hi" --dry-run --json
    check "E13: on account a at 92 % a spawn is refused" test "$(e13_decision "$(e13_file switch-before)")" = refuse
    e13_json caam-switch caam activate claude e13b
    e13_json caam-status caam status claude --json
    check "E13: caam switches Claude to account b" \
        jq -e '[.tools[]? | select(.tool == "claude") | .active_profile][0] == "e13b"' "$(e13_file caam-status)"
    e13_json switch-quota nhm quota --json
    check "E13: after the switch the earlier Claude observation is unknown (nhm-kyt)" \
        jq -e '[.result.pools[]? | select(.pool_id == "claude") | .observed_at][0] == null' "$(e13_file switch-quota)"
    e13_json switch-after nhm spawn e13r --cc=1 --prompt "say hi" --dry-run --json
    check "E13: so the spawn account a's 92 % refused is admitted, with a warning (nhm-kyt)" \
        bash -c '[[ "$2" == admit ]] && jq -e "[.. | objects | select(has(\"admission\")) | .admission.warnings // [] | length][0] > 0" "$1" >/dev/null' \
            _ "$(e13_file switch-after)" "$(e13_decision "$(e13_file switch-after)")"
    e13_quota 10
}
