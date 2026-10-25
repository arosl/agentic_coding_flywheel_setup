#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================
# E20 of the nhm rehearsal (METHOD-MATRIX E20; acfs-9hkh.31): close the
# flywheel. Retire the agent whose bead closed, record its outcome,
# reflect, and give the next kickoff the rule learned today.
#
# Sourced by tests/vm/test_nhm_rehearsal.sh, which copies step_E20 and
# the e20_ helpers into the step's script (run_step) beside its own
# helpers. Runs inside the sandbox with nhm as the owner, in $HOME/e20: a
# git repository with a bead database (br), and two Claudes against the
# mock API. Needs br, cm and cass bound into the sandbox.
#
# Pass conditions (the matrix's), and how nhm meets them (plan-v8 2.13):
#   - one `cm outcome` per closed bead, with the receipt's rule ids, and
#     none for the open bead: with the learning profile
#     (learning.implicit_outcome = "closed-assigned"), `nhm feedback
#     outcomes` applies one for A's closed bead, with the rule A's send
#     carried, and leaves B's open bead waiting; cm counts the rule
#     helpful;
#   - `cass search` finds the retired session's last turn: retire indexes
#     A's transcript in place;
#   - feedback is recorded once: a second `nhm feedback outcomes` only
#     repeats;
#   - the next `nhm spawn --with-memory` kickoff carries a rule learned
#     today, attributed to the bead closed today: `cm reflect` on A's
#     transcript adds it (nhm never reflects: the operator does), and the
#     kickoff's receipt (`nhm feedback list --op`) lists it.
# The step writes the learning profile into the sandbox's nhm config: the
# plan has ACFS ship it. The sandbox has no LLM, so `cm reflect` runs with
# cm's reflector stubs (CM_REFLECTOR_STUBS, CASS_MEMORY_LLM=none): they
# stand for the rule a reflector would propose, and the rest is cm's own
# path (the diary from the session, the delta, the rule's source
# session). The sends ask for a slow reply, so herdr sees each turn start
# and nhm records them as submitted (only submitted sends count).
# ============================================================

# e20_git DIR ARGS...: git with a fixed identity.
e20_git() {
    local dir="$1"
    shift
    git -C "$dir" -c user.name=rehearsal -c user.email=rehearsal@example.invalid "$@"
}

# e20_json LABEL CMD...: runs CMD, saves its output as e20-LABEL.json and
# shows it; returns CMD's status.
e20_json() {
    local label="$1" out rc=0
    shift
    out="$("$@" 2>&1)" || rc=$?
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e20-$label.json"
    echo "### $label (exit $rc): $*"
    echo "$out"
    return "$rc"
}

# e20_file LABEL: the saved output's path.
e20_file() { printf '%s/e20-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e20_cm ARGS...: cm without an LLM (the sandbox has none).
e20_cm() { CASS_MEMORY_LLM=none cm "$@"; }

# e20_rule ID: the rule's playbook entry (JSON), from `cm playbook list`.
e20_rule() {
    e20_cm playbook list --json 2>/dev/null | jq -c --arg id "$1" 'first(.. | objects | select(.id? == $id)) // empty'
}

# e20_helpful ID: cm counts the rule helpful at least once.
e20_helpful() { e20_rule "$1" | jq -e '(.helpfulCount // 0) >= 1' >/dev/null; }

# e20_created_on ID DAY: cm created the rule on DAY (YYYY-MM-DD, UTC).
e20_created_on() { e20_rule "$1" | jq -e --arg d "$2" '.createdAt | startswith($d)' >/dev/null; }

# e20_closed_on DIR BEAD DAY: br has BEAD closed on DAY.
e20_closed_on() {
    (cd "$1" && br show "$2" --json 2>/dev/null) |
        jq -e --arg d "$3" '(.[0] // .) | .status == "closed" and ((.closed_at // "") | startswith($d))' >/dev/null
}

step_E20() {
    local dir a b pa pb b1 b2 cfg r0 r1 transcript last op stubs today
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    for tool in br cm cass; do
        command -v "$tool" >/dev/null 2>&1 || { echo "FAIL E20: $tool is not in the sandbox (sandbox_bin $tool)"; return; }
    done
    today="$(date -u +%Y-%m-%d)"
    dir="$HOME/e20"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E20: the project"; return; }
    printf 'e20\n' >"$dir/README"
    e20_git "$dir" add README && e20_git "$dir" commit -q -m "e20 project" || { echo "FAIL E20: the first commit"; return; }
    (cd "$dir" && br init >"$SANDBOX_EVIDENCE/e20-br-init.out" 2>&1) || { echo "FAIL E20: br init"; return; }
    mkdir -p "$dir/.nhm/templates"
    printf 'Work on {{bead_id}}: {{bead_title}}. Run the gate before you push. Reply slow.\n' >"$dir/.nhm/templates/e20-work.md"
    sandbox_claude_prepare "$dir" >/dev/null
    claude_guards
    nhm_owner || { echo "FAIL E20: nhm could not take the server over"; return; }

    # The learning profile (plan-v8 2.13).
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nhm/config.toml"
    mkdir -p "${cfg%/*}"
    printf '\n[learning]\nimplicit_outcome = "closed-assigned"\n' >>"$cfg"
    show "the nhm config" cat "$cfg"

    # A rule from before today, for the sends to carry.
    e20_json rule-before e20_cm playbook add "Run the gate before you push, every time" --category testing --json || true
    r0="$(sed -n '/^{/,$p' "$(e20_file rule-before)" | jq -r '.data.bullet.id // empty' 2>/dev/null)"
    check "E20: cm has a rule from before today ($r0)" test -n "$r0"

    e20_json spawn bash -c "cd '$dir' && nhm spawn e20 --cc=2 --prompt 'say hi' --json" || true
    a="$(jq -r '._nhm.result.agents[0].mail_name // empty' "$(e20_file spawn)")"
    b="$(jq -r '._nhm.result.agents[1].mail_name // empty' "$(e20_file spawn)")"
    pa="$(jq -r '._nhm.result.agents[0].pane_id // empty' "$(e20_file spawn)")"
    pb="$(jq -r '._nhm.result.agents[1].pane_id // empty' "$(e20_file spawn)")"
    check "E20: nhm spawned two agents" test -n "$a" -a -n "$b"
    [[ -n "$a" && -n "$b" ]] || return
    settle "$pa"
    settle "$pb"

    # Each has a bead and gets it with its memory.
    b1="$(cd "$dir" && br create --title "e20: A's work" --type task --assignee "$a" --silent 2>/dev/null)"
    b2="$(cd "$dir" && br create --title "e20: B's work" --type task --assignee "$b" --silent 2>/dev/null)"
    (cd "$dir" && br update "$b1" --status in_progress >/dev/null 2>&1 && br update "$b2" --status in_progress >/dev/null 2>&1)
    check "E20: A and B each have a bead in progress" test -n "$b1" -a -n "$b2"
    e20_json send-a nhm send e20 --name "$a" -t e20-work --bead "$b1" --with-memory --project "$dir" --json || true
    e20_json send-b nhm send e20 --name "$b" -t e20-work --bead "$b2" --with-memory --project "$dir" --json || true
    check "E20: A's send carries the rule" \
        jq -e --arg r "$r0" '[.result.injections[]?.items[]? | select(.id == $r and .status == "included")] | length == 1' "$(e20_file send-a)"
    check "E20: and is submitted" jq -e '.result.targets[0].submission == "submitted"' "$(e20_file send-a)"
    check "E20: B's send is submitted too" jq -e '.result.targets[0].submission == "submitted"' "$(e20_file send-b)"
    settle "$pa"
    settle "$pb"

    # A's bead closes, and A retires; B's bead stays open.
    (cd "$dir" && br close "$b1" --reason "done" >/dev/null 2>&1)
    e20_json retire-a bash -c "cd '$dir' && nhm retire '$a' --project '$dir' --json" || true
    check "E20: A retires (its bead closed)" jq -e '.result.done == true' "$(e20_file retire-a)"
    check "E20: and retire lists the closed bead" jq -e --arg b "$b1" '.result.closed_beads | index($b) != null' "$(e20_file retire-a)"
    transcript="$(jq -r '.result.transcript.original_path // empty' "$(e20_file retire-a)")"
    check "E20: and names A's transcript" test -s "$transcript"

    # OUTCOME: one for A's closed bead, with the receipt's rule; none for B's.
    e20_json outcomes nhm feedback outcomes --json || true
    check "E20: one outcome is applied, for A's closed bead" \
        jq -e --arg b "$b1" --arg a "$a" '[.result[]? | select(.state == "applied")] | length == 1 and .[0].bead_id == $b and .[0].mail_name == $a' \
        "$(e20_file outcomes)"
    check "E20: with the receipt's rule" \
        jq -e --arg b "$b1" --arg r "$r0" '.result[]? | select(.bead_id == $b and .state == "applied") | .rules | index($r) != null' \
        "$(e20_file outcomes)"
    check "E20: and with A's session" \
        jq -e --arg b "$b1" --arg s "$transcript" '.result[]? | select(.bead_id == $b and .state == "applied") | .session == $s' \
        "$(e20_file outcomes)"
    check "E20: none for B's open bead" \
        jq -e --arg b "$b2" '[.result[]? | select(.bead_id == $b and .state != "waiting")] | length == 0' "$(e20_file outcomes)"
    check "E20: cm counts the rule helpful" e20_helpful "$r0"
    e20_json outcomes-again nhm feedback outcomes --json || true
    check "E20: feedback is recorded once (a second pass only repeats)" \
        jq -e --arg b "$b1" '[.result[]? | select(.state == "applied")] == [] and ([.result[]? | select(.bead_id == $b) | .state] == ["repeat"])' \
        "$(e20_file outcomes-again)"

    # CASS: the retired session's last turn.
    last="$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$transcript" 2>/dev/null | tail -1)"
    echo "### A's last turn: $last"
    e20_json cass cass search --robot --limit 20 -- "$last" || true
    check "E20: cass search finds the retired session's last turn" \
        jq -e --arg s "$transcript" '[.hits[]? | select(.source_path == $s)] | length >= 1' "$(e20_file cass)"

    # INJECT: the operator reflects on A's session, and cm learns a rule.
    stubs='[{"deltas":[{"type":"add","bullet":{"content":"Close the bead before you retire; the next kickoff learns from it","category":"workflow"},"reason":"e20","sourceSession":"x"}]}]'
    CM_REFLECTOR_STUBS="$stubs" e20_json reflect e20_cm reflect --session "$transcript" --json || true
    r1="$(e20_cm playbook list --json 2>/dev/null | jq -r --arg s "$transcript" \
        'first(.. | objects | select(has("id") and has("content")) | select((.sourceSessions // []) | index($s) != null) | .id) // empty')"
    check "E20: cm reflect learns a rule from A's session ($r1)" test -n "$r1"
    show "rule $r1" e20_rule "$r1"

    # The next kickoff carries it.
    e20_json kickoff bash -c "cd '$dir' && nhm spawn e20next --cc=1 --with-memory --prompt 'Close the bead before you retire, then push' --json" || true
    op="$(jq -r '._nhm.result.agents[0].kickoff_operation // empty' "$(e20_file kickoff)")"
    e20_json kickoff-receipt nhm feedback list --op "$op" --json || true
    check "E20: the next kickoff carries the rule learned today" \
        jq -e --arg r "$r1" '[.result[]?.rules[]? | select(.id == $r)] | length >= 1' "$(e20_file kickoff-receipt)"
    check "E20: which was learned today" e20_created_on "$r1" "$today"
    check "E20: from the session of the bead closed today" e20_closed_on "$dir" "$b1" "$today"
}
