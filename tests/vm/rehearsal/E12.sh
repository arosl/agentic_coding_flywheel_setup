# shellcheck shell=bash
# E12 The fleet path (METHOD-MATRIX E12; acfs-9hkh.31, OrangeMouse):
# acfs swarm packet --deliver runs through nhm in ntm's robot grammar. A
# bead becomes a packet; the preview names nhm and one target with no
# injection; --send submits once; nhm's receipt for the operation reads
# submitted; reusing the delivery receipt sends nothing again.
#
# acfs swarm launch is MANUAL here: its planner refuses any launch while
# RCH reports no workers, and the sandbox has no network to reach them.
# The agent is spawned with nhm instead. The bead's title says "slow" so
# the mock's reply lasts long enough for herdr to see the turn.

e12_lib() { printf '%s/../../../scripts/lib/%s\n' "$(dirname "$SANDBOX_LIB")" "$1"; }

# e12_deliver ARGS...: swarm packet --deliver for the e12 agent.
e12_deliver() {
    (cd "$HOME/e12" && bash "$(e12_lib swarm_packet.sh)" --deliver "$HOME/packet.json" --repo "$HOME/e12" "$@" 2>&1)
}

# e12_mock_count TEXT: the mock's requests so far whose prompt holds TEXT
# (the mock logs each prompt whole).
e12_mock_count() {
    local n
    n="$(grep -cF -- "$1" "$SANDBOX_EVIDENCE/mock-requests.jsonl" 2>/dev/null)"
    printf '%s\n' "${n:-0}"
}

step_E12() {
    local dir rdir out pane ws bead preview sha sent receipt again before after
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    dir="$HOME/e12"
    rdir="$HOME/receipts"
    mkdir -p "$dir" "$rdir" && chmod 700 "$rdir"
    git -C "$dir" init -q && git -C "$dir" -c user.name=r -c user.email=r@example.invalid commit -q --allow-empty -m init
    sandbox_claude_prepare "$dir" >/dev/null
    claude_guards
    nhm_owner || { echo "FAIL E12: nhm could not take the server over"; return; }
    out="$(cd "$dir" && nhm spawn e12 --cc=1 --prompt "say hi" --json 2>&1)"
    pane="$(jq -r '._nhm.result.agents[0].pane_id // empty' <<<"$out")"
    ws="${pane%%:*}"
    check "E12: nhm started the agent" test -n "$pane"
    settle "$pane"
    (cd "$dir" && br init >/dev/null 2>&1)
    bead="$(cd "$dir" && br create --title "rehearsal packet task, answer slow" --type task --priority 2 --json 2>/dev/null |
        jq -r '.id // .issue.id // empty')"
    (cd "$dir" && bash "$(e12_lib swarm_packet.sh)" --bead "$bead" --repo "$dir" --json --no-live-context \
        >"$HOME/packet.json" 2>"$SANDBOX_EVIDENCE/e12-packet.err")
    check "E12: swarm packet made a packet for the bead" jq -e --arg b "$bead" '.. | strings | select(. == $b)' "$HOME/packet.json"

    preview="$(e12_deliver --workspace "$ws" --pane-id "$pane" --agent-type claude --operation-id e12-1 --receipt "$rdir/d1.json")"
    printf '%s\n' "$preview" >"$SANDBOX_EVIDENCE/e12-preview.json"
    check "E12: the preview sends through nhm" jq -e '.status == "preview" and (.sends_prompt | not)' <<<"$preview"
    check "E12: the preview names one target and no injection" jq -e --arg p "$pane" '
        (.nhm_argv | index("--panes=" + $p) != null) and (.nhm_argv | index("--no-cass") != null)
        and (.nhm_argv | index("--with-memory=false") != null) and (.nhm_argv[0] == "nhm")' <<<"$preview"
    sha="$(jq -r '.request.packet_sha256 // empty' <<<"$preview")"

    before="$(e12_mock_count "$bead")"
    sent="$(e12_deliver --workspace "$ws" --pane-id "$pane" --agent-type claude --operation-id e12-1 --receipt "$rdir/d1.json" \
        --expect-sha256 "$sha" --send)"
    printf '%s\n' "$sent" >"$SANDBOX_EVIDENCE/e12-send.json"
    until_state "$pane" '^(idle|done)$' 60
    check "E12: the packet reached the agent (the model was asked about the bead)" test "$(e12_mock_count "$bead")" -gt "$before"
    receipt="$(nhm --robot-send-receipt=e12-1 2>&1)"
    printf '%s\n' "$receipt" >"$SANDBOX_EVIDENCE/e12-receipt.json"
    check "E12: nhm's receipt for the operation reads submitted" \
        jq -e '.success and (.. | objects | select(has("successful")) | .successful | length == 1)' <<<"$receipt"

    # The same delivery receipt again: it queries nhm's receipt and never
    # sends again.
    before="$(e12_mock_count "$bead")"
    again="$(e12_deliver --workspace "$ws" --pane-id "$pane" --agent-type claude --operation-id e12-1 --receipt "$rdir/d1.json" \
        --expect-sha256 "$sha" --send)"
    printf '%s\n' "$again" >"$SANDBOX_EVIDENCE/e12-again.json"
    sleep 3
    after="$(e12_mock_count "$bead")"
    check "E12: reusing the receipt sends nothing again" test "$after" -eq "$before"
    manual "E12: acfs swarm launch through nhm (its planner refuses while RCH reports no workers; the sandbox has no network)"
    manual "E12: a forced unconfirmed delivery is never re-sent on the next run (needs a submission nhm cannot confirm)"
}
