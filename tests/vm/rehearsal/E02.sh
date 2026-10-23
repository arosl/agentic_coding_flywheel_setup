# shellcheck shell=bash
# E02 Independent planning (METHOD-MATRIX E02; acfs-9hkh.94): two planners
# of different kinds, a Claude and a Codex, get the same long brief from
# a file and write separate plans; a synthesis sees both. Pass
# conditions: two session ids; two files; the --msg-file send's receipts
# show each planner's prompt submitted and the payload digest; the
# synthesis prompt names both paths.
#
# The brief asks for one shell command with the mock's 'mock-tool:' line
# (the 'shell' alias: Claude Code's Bash, Codex's exec_command), so one
# brief serves both kinds. Each planner names its plan by its own herdr
# pane (HERDR_PANE_ID), which is how the same brief makes two files.

# e02_json LABEL CMD...: runs CMD in the project, saves its output as
# e02-LABEL.json and shows it.
e02_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e02" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e02-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e02_file() { printf '%s/e02-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e02_session NAME: the agent's native session id in nhm list, or nothing.
e02_session() {
    nhm list --json 2>/dev/null | jq -r --arg n "$1" 'first(.result.agents[]? | select(.binding.mail_name == $n) | .agent_session.value) // empty'
}

# e02_brief DIR: the long brief, about 4 KB, with its one tool line.
e02_brief() {
    local dir="$1" i cmd
    echo "# The e02 brief: plan the e02 service"
    echo
    for i in $(seq 1 40); do
        echo "Requirement $i: the e02 service keeps part $i of its state in one place, and a plan says how."
    done
    echo
    # Append (>>): the Claude's dcg guard refuses a truncating redirect to
    # a path the shell builds at run time, and the plan file is new.
    cmd="cd $(printf %q "$dir") && mkdir -p plans && p=\"\${HERDR_PANE_ID//:/-}\" && printf 'Plan for the e02 brief, by pane %s\\n' \"\$HERDR_PANE_ID\" >> \"plans/plan-\$p.md\""
    jq -rn --arg c "$cmd" '"mock-tool: " + ({name: "shell", input: {cmd: $c, description: "Write my plan"}} | tojson)'
    echo
    echo "Write your plan to plans/plan-<your pane>.md and reply with its path."
}

step_E02() {
    local dir out names kinds panes i paths=() synth spane sname brief
    dir="$HOME/e02"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E02: the project"; return; }
    sandbox_claude_prepare "$dir" >/dev/null && sandbox_codex_prepare "$dir" >/dev/null
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E02: Codex trusts herdr's state hook before the planners start" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E02: nhm could not take the server over"; return; }

    e02_json spawn nhm spawn e02 --cc=1 --cod=1 --allow-unguarded --prompt "say hi" --json
    check "E02: two planners start, a Claude and a Codex, each ready" \
        jq -e '[.result.agents[] | select(.ready) | .kind] | sort == ["claude", "codex"]' "$(e02_file spawn)"
    mapfile -t names < <(jq -r '.result.agents[].mail_name' "$(e02_file spawn)")
    mapfile -t kinds < <(jq -r '.result.agents[].kind' "$(e02_file spawn)")
    mapfile -t panes < <(jq -r '.result.agents[].pane_id' "$(e02_file spawn)")
    ((${#names[@]} == 2)) || { echo "FAIL E02: no two planners"; return; }
    for i in 0 1; do settle "${panes[i]}"; done

    # The same long brief to both, from a file.
    brief="$dir/brief.md"
    e02_brief "$dir" >"$brief"
    echo "### the brief: $(wc -c <"$brief") bytes"
    e02_json send nhm send e02 --all --msg-file "$brief" --json
    check "E02: the brief went to both planners" \
        jq -e --argjson n "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s 'sort')" '[.result.targets[].mail_name] | sort == $n' "$(e02_file send)"
    check "E02: each planner's prompt is submitted" jq -e '[.result.targets[].submission] | all(. == "submitted")' "$(e02_file send)"
    check "E02: the receipt has the payload's digest, of the whole brief" \
        jq -e --argjson b "$(wc -c <"$brief")" '(.result.payload_sha256 | test("^[0-9a-f]{64}$")) and .result.payload_bytes >= $b' "$(e02_file send)"
    for i in 0 1; do settle "${panes[i]}"; done

    for i in 0 1; do
        paths[i]="$dir/plans/plan-${panes[i]//:/-}.md"
        check "E02: ${names[i]} (${kinds[i]}) wrote its own plan" grep -q "by pane ${panes[i]}\$" "${paths[i]}"
    done
    check "E02: two session ids" \
        bash -c 'a="$1" b="$2"; [[ -n "$a" && -n "$b" && "$a" != "$b" ]]' _ "$(e02_session "${names[0]}")" "$(e02_session "${names[1]}")"

    # The synthesis: a fresh Claude, its prompt naming both plans.
    e02_json synth nhm add e02 --cc=1 --prompt "say hi" --json
    sname="$(jq -r '.result.agents[0].mail_name // empty' "$(e02_file synth)")"
    spane="$(jq -r '.result.agents[0].pane_id // empty' "$(e02_file synth)")"
    check "E02: the synthesis agent starts" test -n "$sname" -a -n "$spane"
    settle "$spane"
    synth="Synthesize the two plans ${paths[0]} and ${paths[1]} into synthesis.md."$'\n'"$(jq -rn \
        --arg c "cd $(printf %q "$dir") && cat $(printf %q "${paths[0]}") $(printf %q "${paths[1]}") > synthesis.md" \
        '"mock-tool: " + ({name: "shell", input: {cmd: $c, description: "Merge the plans"}} | tojson)')"
    e02_json send-synth nhm send e02 "$synth" --name "$sname" --json
    settle "$spane"
    check "E02: the synthesis prompt names both paths" \
        jq -e --arg a "${paths[0]}" --arg b "${paths[1]}" \
            'select((.user_text // "") | (contains($a) and contains($b)))' "$SANDBOX_EVIDENCE/mock-requests.jsonl"
    check "E02: and the synthesis sees both plans" \
        bash -c 'grep -q "by pane $2\$" "$1" && grep -q "by pane $3\$" "$1"' _ "$dir/synthesis.md" "${panes[0]}" "${panes[1]}"
}
