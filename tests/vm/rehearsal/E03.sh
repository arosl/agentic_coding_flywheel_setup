# shellcheck shell=bash
# E03 Review rounds (METHOD-MATRIX E03; acfs-9hkh.94): each round spawns
# two fresh reviewers of different kinds, a Claude and a Codex (Codex
# only reviews), has each write its review, reads both, and retires
# them. Pass conditions: each round's session ids are new; both reviews
# exist as files; `nhm retire` of each leaves no reservation and no pane;
# the round file names each reviewer, its kind and its session.
#
# A reviewer's turn is one shell command, asked for with the mock's
# 'mock-tool:' line (Claude Code's Bash, Codex's exec_command): reserve
# its review file in Agent Mail, write the review, commit it, release
# the reservation, as a reviewer does before it is retired. A reviewer
# works no bead, so it is retired with --no-beads.

# e03_json LABEL CMD...: runs CMD in the project, saves its output as
# e03-LABEL.json and shows it.
e03_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e03" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e03-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e03_file() { printf '%s/e03-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e03_review_cmd NAME KIND ROUND: the reviewer's shell command.
e03_review_cmd() {
    local dir="$HOME/e03" f="reviews/round$3-$1.md"
    printf 'cd %q && am file_reservations reserve %q %q %q --exclusive >/dev/null && printf %q %q %q > %q && git add %q && git -c user.name=%q -c user.email=%q commit -qm %q && am file_reservations release %q %q --paths %q >/dev/null' \
        "$dir" "$dir" "$1" "$f" 'Review by %s (%s): the plan holds.\n' "$1" "$2" "$f" "$f" "$1" "$1@e03.invalid" "review round $3 by $1" "$dir" "$1" "$f"
}

# e03_review_line NAME KIND ROUND: the 'mock-tool:' line that has the
# reviewer run its command (Claude Code's Bash, Codex's exec_command).
e03_review_line() {
    local cmd
    cmd="$(e03_review_cmd "$@")"
    if [[ "$2" == codex ]]; then
        jq -rn --arg c "$cmd" '"mock-tool: " + ({name: "exec_command", input: {cmd: $c}} | tojson)'
    else
        jq -rn --arg c "$cmd" '"mock-tool: " + ({name: "Bash", input: {command: $c, description: "Write and commit my review"}} | tojson)'
    fi
}

# e03_session NAME: the agent's native session id in nhm list, or nothing.
e03_session() {
    nhm list --json 2>/dev/null | jq -r --arg n "$1" 'first(.result.agents[]? | select(.binding.mail_name == $n) | .agent_session.value) // empty'
}

step_E03() {
    local dir round out names kinds panes i name kind pane sessions="" earlier="" roundfile
    dir="$HOME/e03"
    mkdir -p "$dir/reviews" && git -C "$dir" init -q &&
        git -C "$dir" -c user.name=e03 -c user.email=e03@e03.invalid commit -q --allow-empty -m "e03: the plan" ||
        { echo "FAIL E03: the project"; return; }
    sandbox_claude_prepare "$dir" >/dev/null && sandbox_codex_prepare "$dir" >/dev/null
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E03: Codex trusts herdr's state hook before the first round" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E03: nhm could not take the server over"; return; }

    for round in 1 2; do
        e03_json "spawn-$round" nhm spawn "e03r$round" --cc=1 --cod=1 --allow-unguarded --prompt "say hi" --json
        check "E03: round $round's two reviewers start, a Claude and a Codex, each ready" \
            jq -e '[._nhm.result.agents[] | select(.ready) | .kind] | sort == ["claude", "codex"]' "$(e03_file "spawn-$round")"
        mapfile -t names < <(jq -r '._nhm.result.agents[].mail_name' "$(e03_file "spawn-$round")")
        mapfile -t kinds < <(jq -r '._nhm.result.agents[].kind' "$(e03_file "spawn-$round")")
        mapfile -t panes < <(jq -r '._nhm.result.agents[].pane_id' "$(e03_file "spawn-$round")")
        ((${#names[@]} == 2)) || { echo "FAIL E03: round $round has no two reviewers"; return; }
        for i in 0 1; do
            settle "${panes[i]}"
        done

        # One reviewer at a time: both commit to the same repository.
        for i in 0 1; do
            name="${names[i]}" kind="${kinds[i]}" pane="${panes[i]}"
            e03_json "send-$round-$name" nhm send "e03r$round" "$(e03_review_line "$name" "$kind" "$round")" --name "$name" --json
            settle "$pane"
            check "E03: round $round: $name ($kind) wrote its review" \
                grep -q "Review by $name ($kind)" "$dir/reviews/round$round-$name.md"
            check "E03: round $round: and committed it" \
                bash -c '[[ -z "$(git -C "$1" status --porcelain -- "$2")" ]] && git -C "$1" log --format=%s | grep -qx "$3"' \
                    _ "$dir" "reviews/round$round-$name.md" "review round $round by $name"
            e03_json "read-$round-$name" nhm read "$name" --lines 40 --json
            check "E03: round $round: $name's turn is read, closed after its tool ran" \
                grep -q 'mock: read 1 tool result' "$(e03_file "read-$round-$name")"
        done

        # The round file: each reviewer, its kind and its session.
        roundfile="$dir/reviews/round$round.md"
        : >"$roundfile"
        sessions=""
        for i in 0 1; do
            out="$(e03_session "${names[i]}")"
            printf '%s %s %s\n' "${names[i]}" "${kinds[i]}" "${out:-unknown}" >>"$roundfile"
            sessions+="$out "
        done
        echo "### $roundfile"
        cat "$roundfile"
        check "E03: round $round's file names each reviewer, its kind and a session" \
            bash -c '[[ $(grep -cE "^[A-Za-z]+ (claude|codex) [^ ]+$" "$1") == 2 ]] && ! grep -q " unknown$" "$1"' _ "$roundfile"
        if [[ -n "$earlier" ]]; then
            check "E03: round $round's sessions are new" \
                bash -c 'for s in $1; do [[ " $2 " != *" $s "* ]] || exit 1; done' _ "$sessions" "$earlier"
        fi
        earlier="$sessions"

        for i in 0 1; do
            name="${names[i]}" pane="${panes[i]}"
            e03_json "retire-$round-$name" nhm retire "$name" --no-beads --json
            check "E03: round $round: $name is retired" jq -e '.error == null' "$(e03_file "retire-$round-$name")"
            check "E03: and its pane is gone" bash -c '! herdr pane get "$1" >/dev/null 2>&1' _ "$pane"
            check "E03: and it holds no reservation" \
                bash -c 'out="$(am file_reservations active "$1")" && ! grep -qw "$2" <<<"$out"' _ "$dir" "$name"
        done
    done
}
