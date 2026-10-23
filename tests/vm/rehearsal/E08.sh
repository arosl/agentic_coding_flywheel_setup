# shellcheck shell=bash
# E08 One complete bead (METHOD-MATRIX E08; acfs-9hkh.94): the work loop.
# A Claude claims a bead, reserves its files, writes the change and its
# test, runs the test and UBS, commits, releases, hands off and closes the
# bead; then the self-review, `nhm send --state done -t fresh_review`,
# reaches only that agent while another one works. Pass conditions: br
# and Agent Mail records; the real test and UBS output in the pane; the
# fresh review reached only that agent; nhm wrote no bead.
#
# The work is one shell command asked for with the mock's 'mock-tool:'
# line. UBS runs in the sandbox from the host's ubs script and its
# modules (~/.local/share/ubs), bound read-only below; the sandbox has no
# network, so ubs cannot fetch them itself.

# At source time (outside the sandbox): ubs and its modules and tools.
if [[ -n "${SANDBOX_HOME:-}" ]]; then
    if command -v ubs >/dev/null 2>&1; then
        sandbox_bin ubs
    fi
    if [[ -d "$HOME/.local/share/ubs/modules" ]]; then
        mkdir -p "$SANDBOX_HOME/.local/share/ubs"
        SANDBOX_BINDS+=("$HOME/.local/share/ubs" "$SANDBOX_HOME/.local/share/ubs")
    fi
fi

# e08_json LABEL CMD...: runs CMD in the project, saves its output as
# e08-LABEL.json and shows it.
e08_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e08" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e08-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e08_file() { printf '%s/e08-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e08_work_cmd DIR BEAD NAME: the work, as one shell command: claim,
# reserve, write, test, ubs, commit, release, hand off, close.
e08_work_cmd() {
    local dir="$1" bead="$2" name="$3" greet test
    greet='greet() { echo "Hello, $1"; }'
    test='. ./greet.sh && [[ "$(greet you)" == "Hello, you" ]] && echo "test_greet: ok"'
    printf '%s' "set -o pipefail; cd $(printf %q "$dir") && br update $bead --status in_progress --assignee $name >/dev/null"
    printf '%s' " && am file_reservations reserve $(printf %q "$dir") $name greet.sh test_greet.sh --exclusive --reason $bead >/dev/null"
    printf '%s' " && printf '%s\\n' $(printf %q "$greet") >> greet.sh && printf '%s\\n' $(printf %q "$test") >> test_greet.sh"
    printf '%s' " && bash test_greet.sh && ubs --only=bash greet.sh test_greet.sh | grep -E '^(Critical|Warning):'"
    printf '%s' " && git add greet.sh test_greet.sh && git -c user.name=$name -c user.email=$name@e08.invalid commit -qm '$bead: greet.sh and its test'"
    printf '%s' " && am file_reservations release $(printf %q "$dir") $name >/dev/null"
    printf '%s' " && br comments add $bead 'handoff: greet.sh and its test; the test and ubs are clean' >/dev/null"
    printf '%s' " && br close $bead --reason 'greet.sh and its test' >/dev/null"
}

step_E08() {
    local dir out bead w pw b pb cmd
    command -v ubs >/dev/null 2>&1 || { echo "FAIL E08: ubs is not in the sandbox (is ubs on the host's PATH?)"; return; }
    dir="$HOME/e08"
    mkdir -p "$dir/.nhm/templates" && git -C "$dir" init -q &&
        git -C "$dir" -c user.name=e08 -c user.email=e08@e08.invalid commit -q --allow-empty -m "e08: the project" ||
        { echo "FAIL E08: the project"; return; }
    (cd "$dir" && br init >"$SANDBOX_EVIDENCE/e08-br-init.out" 2>&1) || { echo "FAIL E08: br init"; return; }
    printf 'Fresh review: re-read the change you just made and fix what you find; reply.\n' \
        >"$dir/.nhm/templates/fresh_review.md"
    sandbox_claude_prepare "$dir" >/dev/null
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    claude_guards
    nhm_owner || { echo "FAIL E08: nhm could not take the server over"; return; }
    bead="$(cd "$dir" && br create --title "e08: add greet.sh and its test" --type task --silent 2>/dev/null)"
    check "E08: the bead exists" test -n "$bead"

    e08_json spawn nhm spawn e08 --cc=2 --prompt "say hi" --json
    w="$(jq -r '.result.agents[0].mail_name // empty' "$(e08_file spawn)")"
    pw="$(jq -r '.result.agents[0].pane_id // empty' "$(e08_file spawn)")"
    b="$(jq -r '.result.agents[1].mail_name // empty' "$(e08_file spawn)")"
    pb="$(jq -r '.result.agents[1].pane_id // empty' "$(e08_file spawn)")"
    check "E08: the worker and a second agent start" test -n "$w" -a -n "$b"
    [[ -n "$w" && -n "$b" && -n "$bead" ]] || return
    settle "$pw"
    settle "$pb"

    # The work, one turn.
    cmd="$(e08_work_cmd "$dir" "$bead" "$w")"
    e08_json work nhm send e08 "Work bead $bead."$'\n'"$(jq -rn --arg c "$cmd" \
        '"mock-tool: " + ({name: "shell", input: {cmd: $c, description: "Do the bead"}} | tojson)')" --name "$w" --json
    settle "$pw"
    e08_json show br show "$bead" --json
    check "E08: br: the bead is closed, the worker's, with its handoff" \
        jq -e --arg w "$w" '(if type == "array" then .[0] else . end) | .status == "closed" and .assignee == $w
            and ([.comments[]? | select(.text | startswith("handoff:"))] | length >= 1)' "$(e08_file show)"
    check "E08: git: the change and its test are committed" \
        bash -c 'git -C "$1" log --format=%s | grep -qx "$2: greet.sh and its test" && [[ -z "$(git -C "$1" status --porcelain -- greet.sh test_greet.sh)" ]]' \
            _ "$dir" "$bead"
    e08_json reservations am file_reservations list "$dir" --all
    check "E08: Agent Mail: the worker reserved the files, and released them" \
        bash -c 'grep -qw "$2" "$1" && grep -q greet.sh "$1" && ! am file_reservations active "$3" | grep -qw "$2"' \
            _ "$(e08_file reservations)" "$w" "$dir"
    # Claude Code shows a command's first output lines after "⎿" (the rest
    # folded) and the files it changed; the test's line must be output,
    # not the test file's text, which holds the same words.
    e08_json read-work nhm read "$w" --lines 80 --json
    jq -r '.result.text // empty' "$(e08_file read-work)" >"$SANDBOX_EVIDENCE/e08-pane.txt"
    # (After "⎿" Claude Code puts a space and a no-break space.)
    check "E08: the pane shows the real test's output" grep -qE '⎿.{1,8}test_greet: ok *$' "$SANDBOX_EVIDENCE/e08-pane.txt"
    check "E08: and UBS's (its scan)" grep -q 'Scanning bash' "$SANDBOX_EVIDENCE/e08-pane.txt"

    # The self-review, while the second agent works.
    herdr agent prompt "$pb" "keep working slow" >/dev/null 2>&1 || true
    until_state "$pb" '^working$' 10
    check "E08: the second agent is working when the review goes out" test "$(state "$pb")" = working
    # herdr reads a Claude whose turn ended as idle, not done, so the
    # selection is nhm's --state between (idle or done), as E10's.
    echo "### the worker's state: $(state "$pw")"
    e08_json review nhm send e08 -t fresh_review --state between --json
    check "E08: nhm send --state between -t fresh_review reached only the worker" \
        jq -e --arg w "$w" '[.result.targets[].mail_name] == [$w] and .result.targets[0].submission == "submitted"' "$(e08_file review)"
    settle "$pw"
    check "E08: the worker read the review prompt" \
        jq -e 'select((.user_text // "") | test("Fresh review: re-read the change"))' "$SANDBOX_EVIDENCE/mock-requests.jsonl"

    e08_json beads br list --all --json
    check "E08: nhm wrote no bead (the project holds only the step's own)" \
        jq -e '[(if type == "array" then . else .issues end)[]?] | length == 1' "$(e08_file beads)"
}
