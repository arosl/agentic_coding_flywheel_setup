# shellcheck shell=bash
# E07 The hand-started agent (METHOD-MATRIX E07; acfs-9hkh.94, re-tests
# acfs-kc1): a Claude started by hand, not by nhm, registers in Agent
# Mail. Pass conditions: its pane is renamed and its tab labelled within
# 2 s of the registration's response; nhm sends it no prompt; Agent Mail
# shows one identity; nhm resolve returns it; nhm status shows its dcg
# guard active; a `claude -p` run from its shell changes nothing.
#
# The Claude has the sandbox's Agent Mail as an MCP server, and nhm's
# hook lines are registered as ACFS's install does (nhm_hooks.sh
# register claude): nhm binds a hand-started agent from the PostToolUse
# hook of its registration. The registration is a macro_start_session
# call, asked for with the mock's 'mock-tool:' line.

# e07_json LABEL CMD...: runs CMD in the project, saves its output as
# e07-LABEL.json and shows it.
e07_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e07" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e07-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e07_file() { printf '%s/e07-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e07_mcp: the sandbox's Agent Mail as Claude Code's MCP server
# "agent-mail" (user scope, in the .claude.json sandbox_claude_prepare
# wrote).
e07_mcp() {
    local f="$CLAUDE_CONFIG_DIR/.claude.json" tmp
    tmp="$(mktemp "$CLAUDE_CONFIG_DIR/.claude.json.XXXXXX")" || return 1
    jq --arg u "${AGENT_MAIL_URL:-http://127.0.0.1:8765/mcp/}" \
        '.mcpServers["agent-mail"] = {type: "http", url: $u}' "$f" >"$tmp" && mv "$tmp" "$f"
}

# e07_resolve PANE: nhm resolve's binding, one line: "id generation name".
e07_resolve() {
    nhm resolve "$1" --json 2>/dev/null |
        jq -r '.result.binding // empty | select(.status == "active") | "\(.binding_id) \(.generation) \(.mail_name)"'
}

step_E07() {
    local dir ws pane tab call t0 pid name alias reg_ts reg_epoch before after mock start
    # The mock's log is the run's, shared by its steps: E07 reads only the
    # requests made after this line.
    mock="$SANDBOX_EVIDENCE/mock-requests.jsonl"
    start="$(wc -l <"$mock" 2>/dev/null || echo 0)"
    dir="$HOME/e07"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E07: the project"; return; }
    sandbox_claude_prepare "$dir" >/dev/null
    check "E07: the Claude has the sandbox's Agent Mail as an MCP server" e07_mcp
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    claude_guards
    check "E07: nhm's hooks are registered for Claude, as ACFS's install does" \
        env NHM_BIN_DIR="$SANDBOX_BIN" bash "$(dirname "$SANDBOX_LIB")/../../../scripts/lib/nhm_hooks.sh" \
            register claude "$CLAUDE_CONFIG_DIR/settings.json"
    nhm_owner || { echo "FAIL E07: nhm could not take the server over"; return; }

    # The hand start: herdr starts the Claude in a new workspace, not nhm.
    e07_json workspace herdr workspace create --cwd "$dir" --label e07 --no-focus
    pane="$(jq -r '.result.root_pane.pane_id // empty' "$(e07_file workspace)")"
    tab="$(jq -r '.result.root_pane.tab_id // empty' "$(e07_file workspace)")"
    sleep 1
    e07_json start herdr agent start hand --kind claude --pane "$pane" --timeout 60000 -- --dangerously-skip-permissions
    check "E07: the hand-started Claude is ready" jq -e '.result.agent.agent_status | test("idle|done")' "$(e07_file start)"
    check "E07: nhm has no binding for it yet" bash -c '[[ -z "$1" ]]' _ "$(e07_resolve "$pane")"

    # It registers in Agent Mail (one tool call), typed into its pane as a
    # user would, while herdr's name and the tab's label are polled.
    call="$(jq -cn --arg d "$dir" '{name: "mcp__agent-mail__macro_start_session",
        input: {human_key: $d, program: "claude-code", model: "mock-model", task_description: "e07"}}')"
    : >"$SANDBOX_EVIDENCE/e07-polls.txt"
    (herdr agent prompt "$pane" "Register in Agent Mail."$'\n'"mock-tool: $call" --wait --timeout 90000 \
        >"$SANDBOX_EVIDENCE/e07-prompt.json" 2>&1) &
    pid=$!
    t0=$SECONDS
    while ((SECONDS - t0 < 120)); do
        printf '%s %s %s\n' "$(date +%s)" \
            "$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.name // "-"')" \
            "$(herdr tab get "$tab" 2>/dev/null | jq -r '.result.tab.label // "-"')" >>"$SANDBOX_EVIDENCE/e07-polls.txt"
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    wait "$pid"
    sleep 5
    e07_json agents am agents list "$dir" --json
    name="$(jq -r '[(if type == "array" then . else .agents end)[]? | .name] | first // empty' "$(e07_file agents)")"
    alias="${name,,}"
    echo "### registered as ${name:-nothing} (herdr ${alias:-nothing})"
    check "E07: Agent Mail shows one identity" \
        jq -e '[(if type == "array" then . else .agents end)[]?] | length == 1' "$(e07_file agents)"
    check "E07: nhm resolve returns it" bash -c '[[ "${1##* }" == "$2" && -n "$2" ]]' _ "$(e07_resolve "$pane")" "$name"

    # Within 2 s of the registration's response. The response comes after
    # the mock handed out the tool call (the request whose reply asked for
    # it), so the first poll that shows the name may come at most 2 s
    # after that request; the mock's log has whole seconds, so 3 s here.
    tail -n +"$((start + 1))" "$mock" >"$SANDBOX_EVIDENCE/e07-mock-requests.jsonl" 2>/dev/null
    reg_ts="$(jq -r 'select((.tool_calls // []) | index("mcp__agent-mail__macro_start_session")) | .ts' \
        "$SANDBOX_EVIDENCE/e07-mock-requests.jsonl" | head -n 1)"
    reg_epoch="$(date -d "$reg_ts" +%s 2>/dev/null || echo 0)"
    echo "### the registration was asked for at $reg_ts ($reg_epoch)"
    check "E07: its pane is renamed within 2 s of the registration" \
        awk -v t="$reg_epoch" -v n="$alias" 'n != "" && $2 == n { found = 1; ok = ($1 - t <= 3); exit }
            END { exit !(found && ok) }' "$SANDBOX_EVIDENCE/e07-polls.txt"
    check "E07: and its tab labelled within 2 s" \
        awk -v t="$reg_epoch" -v n="$name" 'n != "" && $3 == n { found = 1; ok = ($1 - t <= 3); exit }
            END { exit !(found && ok) }' "$SANDBOX_EVIDENCE/e07-polls.txt"
    check "E07: nhm sent it no prompt (the mock saw one turn from it, the one typed in)" \
        bash -c '[[ $(jq -s "[.[] | select(.path == \"/v1/messages\" and (.tool_results // 0) == 0 and
            ((.user_text // \"\") | test(\"Register in Agent Mail\")))] | length" "$1") -ge 1 &&
            $(jq -s "[.[] | select(.path == \"/v1/messages\" and (.tool_results // 0) == 0 and
            ((.user_text // \"\") | test(\"Your Agent Mail identity|nhm context\")))] | length" "$1") -eq 0 ]]' \
            _ "$SANDBOX_EVIDENCE/e07-mock-requests.jsonl"
    e07_json status nhm status e07 --json
    # nhm's guard states have no "active": configured is the hook in
    # place, the nearest form for an agent nhm did not launch
    # (verified_for_launch is for nhm's own launches).
    check "E07: nhm status shows its dcg guard active (configured)" \
        jq -e --arg n "$name" '[.result.agents[]? | select(.binding.mail_name == $n) | .guards.dcg] | .[0] == "configured"' \
            "$(e07_file status)"

    # A claude -p run from its shell: the pane's environment, a one-shot
    # Claude. Its hooks fire with the pane's id; nothing may change.
    before="$(e07_resolve "$pane")"
    (cd "$dir" && HERDR_PANE_ID="$pane" timeout 120 claude -p "say hi" --dangerously-skip-permissions \
        >"$SANDBOX_EVIDENCE/e07-claude-p.out" 2>&1) || true
    sleep 2
    after="$(e07_resolve "$pane")"
    echo "### before: $before; after: $after"
    check "E07: a claude -p run from its shell changes nothing: the binding" \
        bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "$before" "$after"
    check "E07: herdr's name" bash -c '[[ "$(herdr agent get "$1" | jq -r .result.agent.name)" == "$2" ]]' _ "$pane" "$alias"
    e07_json agents-after am agents list "$dir" --json
    check "E07: and Agent Mail's one identity" \
        jq -e '[(if type == "array" then . else .agents end)[]?] | length == 1' "$(e07_file agents-after)"
}
