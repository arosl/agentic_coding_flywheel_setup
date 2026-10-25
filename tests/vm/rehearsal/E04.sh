# shellcheck shell=bash
# E04 Plan to beads with a compaction mid-turn (METHOD-MATRIX E04;
# acfs-9hkh.94): one Claude converts the fixture plan into beads, and its
# turn fills the context, so Claude Code compacts in the middle of it.
# Pass conditions: nhm wait --until complete returns with the same
# generation; after the compaction the herdr name is back within 5 s,
# nhm shows compacted_at, and nhm's hook added only the name line; the
# bead count matches the plan's steps (the coverage audit).
#
# The turn is one shell command asked for with the mock's 'mock-tool:'
# line, and the mock's 'mock-context:' line has the reply report a full
# context: Claude Code then compacts before it sends the tool's result,
# as when a real turn fills the context. nhm's hook lines are registered
# in Claude's settings as ACFS's install does (nhm_hooks.sh register
# claude); the rehearsal's other steps run without them.

# e04_json LABEL CMD...: runs CMD in the project, saves its output as
# e04-LABEL.json and shows it.
e04_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e04" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e04-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e04_file() { printf '%s/e04-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e04_row NAME: the agent's row in `nhm list --json` (one line), or nothing.
e04_row() {
    nhm list --json 2>/dev/null | jq -c --arg n "$1" 'first(.result.agents[]? | select(.binding.mail_name == $n)) // empty'
}

# e04_name_back POLLS EPOCH: the poll log's first line at or after EPOCH
# whose herdr name is the binding's comes within 5 s of it (plus the
# mock log's one-second rounding). No such line fails.
e04_name_back() {
    awk -v t="$2" '$1 >= t && $2 == "match" { found = 1; ok = ($1 - t <= 6); exit }
        END { exit !(found && ok) }' "$1"
}

step_E04() {
    local dir out name pane alias gen op i cmd prompt waitpid t0 compact_ts compact_epoch session transcript boundary
    # The plan's steps (a local: the harness carries only functions into
    # the sandbox).
    local E04_STEPS=5
    dir="$HOME/e04"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E04: the project"; return; }
    (cd "$dir" && br init >"$SANDBOX_EVIDENCE/e04-br-init.out" 2>&1) || { echo "FAIL E04: br init"; return; }
    {
        echo "# The e04 plan"
        for i in $(seq 1 "$E04_STEPS"); do
            printf '\n## Step %s\n\nPart %s of the e04 service, with its own acceptance.\n' "$i" "$i"
        done
    } >"$dir/plan.md"
    sandbox_claude_prepare "$dir" >/dev/null
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    claude_guards
    # nhm's own hook lines, as ACFS's install registers them: the
    # SessionStart hook records the compaction and prints the name line.
    check "E04: nhm's hooks are registered for Claude, as ACFS's install does" \
        env NHM_BIN_DIR="$SANDBOX_BIN" bash "$(dirname "$SANDBOX_LIB")/../../../scripts/lib/nhm_hooks.sh" \
            register claude "$CLAUDE_CONFIG_DIR/settings.json"
    nhm_owner || { echo "FAIL E04: nhm could not take the server over"; return; }

    e04_json spawn nhm spawn e04 --cc=1 --prompt "say hi" --json
    name="$(jq -r '._nhm.result.agents[0].mail_name // empty' "$(e04_file spawn)")"
    pane="$(jq -r '._nhm.result.agents[0].pane_id // empty' "$(e04_file spawn)")"
    alias="$(jq -r '._nhm.result.agents[0].herdr_name // empty' "$(e04_file spawn)")"
    check "E04: the converter starts" test -n "$name" -a -n "$pane" -a -n "$alias"
    [[ -n "$name" ]] || return
    settle "$pane"
    gen="$(e04_row "$name" | jq -r '.binding.generation // empty')"
    echo "### $name in $pane, herdr $alias, generation $gen"

    # The conversion: one command makes a bead per step of the plan; the
    # reply reports a full context, so Claude Code compacts mid-turn.
    cmd="cd $(printf %q "$dir") && for i in \$(seq 1 $E04_STEPS); do br create --title \"e04: step \$i of the plan\" --type task --silent >/dev/null || exit 1; done"
    prompt="Convert plan.md into beads, one per step."$'\n'"mock-context: 990000"$'\n'"$(jq -rn --arg c "$cmd" \
        '"mock-tool: " + ({name: "shell", input: {cmd: $c, description: "Make the beads"}} | tojson)')"
    e04_json send nhm send e04 "$prompt" --name "$name" --json
    op="$(jq -r '.result.operation_id // empty' "$(e04_file send)")"
    check "E04: the conversion is submitted" jq -e '.result.targets[0].submission == "submitted"' "$(e04_file send)"

    # nhm wait for the turn's completion, while herdr's name is polled.
    t0=$SECONDS
    (cd "$dir" && nhm wait e04 --name "$name" --until complete --after-op "$op" --timeout 4h --json \
        >"$SANDBOX_EVIDENCE/e04-wait.json" 2>&1) &
    waitpid=$!
    : >"$SANDBOX_EVIDENCE/e04-name-polls.txt"
    while kill -0 "$waitpid" 2>/dev/null && ((SECONDS - t0 < 300)); do
        if [[ "$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.name // empty')" == "$alias" ]]; then
            echo "$(date +%s) match" >>"$SANDBOX_EVIDENCE/e04-name-polls.txt"
        else
            echo "$(date +%s) other" >>"$SANDBOX_EVIDENCE/e04-name-polls.txt"
        fi
        sleep 0.5
    done
    wait "$waitpid"
    echo "### nhm wait (after $((SECONDS - t0)) s)"
    cat "$SANDBOX_EVIDENCE/e04-wait.json"
    check "E04: nhm wait --until complete returns complete" \
        jq -e '(.result // .) | .met and .targets[0].outcome == "complete"' "$SANDBOX_EVIDENCE/e04-wait.json"
    check "E04: with the same generation" \
        jq -e --argjson g "${gen:-null}" '(.result // .) | .targets[0].generation == $g' "$SANDBOX_EVIDENCE/e04-wait.json"

    # The compaction, mid-turn: after the tool call, before its result.
    compact_ts="$(jq -r 'select((.user_text // "") | test("detailed summary of the conversation so far")) | .ts' \
        "$SANDBOX_EVIDENCE/mock-requests.jsonl" | head -n 1)"
    check "E04: Claude Code compacted in the middle of the turn" test -n "$compact_ts"
    # nhm status's binding has no compacted_at (nhm-8ns); nhm resolve
    # shows the whole binding, the nearest form.
    nhm resolve "$pane" --json >"$SANDBOX_EVIDENCE/e04-resolve.json" 2>&1
    check "E04: nhm shows compacted_at (nhm resolve; nhm status has no such field)" \
        jq -e '.result.binding.compacted_at | type == "string"' "$SANDBOX_EVIDENCE/e04-resolve.json"
    check "E04: and the same generation" bash -c '[[ "$1" == "$2" ]]' _ "$(e04_row "$name" | jq -r '.binding.generation')" "$gen"
    compact_epoch="$(date -d "$compact_ts" +%s 2>/dev/null || echo 0)"
    check "E04: after the compaction the herdr name is back within 5 s" \
        e04_name_back "$SANDBOX_EVIDENCE/e04-name-polls.txt" "$compact_epoch"

    # nhm's hook after the compaction: the name line, and nothing else of
    # the kickoff's (its identity text) comes back.
    session="$(e04_row "$name" | jq -r '.agent_session.value // empty')"
    transcript="$(printf '%s\n' "$CLAUDE_CONFIG_DIR"/projects/*/"$session".jsonl | head -n 1)"
    boundary="$(grep -n 'compact_boundary' "$transcript" 2>/dev/null | head -n 1 | cut -d: -f1)"
    echo "### transcript $transcript, compact boundary at line ${boundary:-none}"
    check "E04: the transcript has the compaction's boundary" test -n "$boundary"
    check "E04: after it, nhm's hook added the name line" \
        bash -c 'tail -n +"$1" "$2" | grep -qF "You are $3 (herdr $4)."' _ "${boundary:-1}" "$transcript" "$name" "$alias"
    check "E04: and only the name line (no kickoff identity text again)" \
        bash -c '! tail -n +"$1" "$2" | grep -qF "Your Agent Mail identity is already registered"' _ "${boundary:-1}" "$transcript"

    # The coverage audit: one bead per step of the plan.
    e04_json beads br list --json
    check "E04: the bead count matches the plan's $E04_STEPS steps" \
        jq -e --argjson n "$E04_STEPS" '[(.issues // .)[] | select(.title | startswith("e04: step "))] | length == $n' "$(e04_file beads)"
}
