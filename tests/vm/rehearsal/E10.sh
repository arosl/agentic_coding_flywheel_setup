# shellcheck shell=bash
# E10 Selective cross-review (METHOD-MATRIX E10; acfs-9hkh.31, OrangeMouse):
# select by state, send to that selection only, read the result. Three
# Claudes and a Codex; one Claude works on a slow turn. `nhm send --cc
# --state done --state idle` (between turns) must reach exactly the two
# Claudes that are between turns, never the Codex, and leave the working
# one alone; the result lists the frozen targets; nhm read shows each
# reviewer's answer (the stop rule reads it). The Codex is added with
# --allow-unguarded: its guards are E01's subject.

# e10_nhm VERB ARGS...: nhm spawn or add in the e10 project; prints JSON.
e10_nhm() {
    local verb="$1"
    shift
    (cd "$HOME/e10" && nhm "$verb" e10 "$@" --prompt "say hi" --json 2>&1)
}

step_E10() {
    local dir claudes codex pa pb pc out
    dir="$HOME/e10"
    mkdir -p "$dir" && git -C "$dir" init -q && sandbox_claude_prepare "$dir" >/dev/null &&
        sandbox_codex_prepare "$dir" >/dev/null
    # herdr's integration after sandbox_codex_prepare, which writes Codex's
    # config.toml whole; then Codex's trust in herdr's state hook, so the
    # Codex starts with no dialog herdr cannot read (acfs-9hkh.99).
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E10: Codex trusts herdr's state hook before the Codex starts" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E10: nhm could not take the server over"; return; }
    claudes="$(e10_nhm spawn --cc=3)"
    printf '%s\n' "$claudes" >"$SANDBOX_EVIDENCE/e10-spawn-claude.json"
    codex="$(e10_nhm add --cod=1 --allow-unguarded)"
    printf '%s\n' "$codex" >"$SANDBOX_EVIDENCE/e10-add-codex.json"
    pa="$(jq -r '.result.agents[0].pane_id // empty' <<<"$claudes" 2>/dev/null)"
    pb="$(jq -r '.result.agents[1].pane_id // empty' <<<"$claudes" 2>/dev/null)"
    pc="$(jq -r '.result.agents[2].pane_id // empty' <<<"$claudes" 2>/dev/null)"
    check "E10: three Claudes started" test -n "$pa" -a -n "$pb" -a -n "$pc"
    check "E10: a Codex started, and is ready (herdr reads its state)" \
        jq -e '.result.agents[0].pane_id and .result.agents[0].ready == true' <<<"$codex"
    for p in "$pa" "$pb" "$pc"; do settle "$p"; done
    # C works; A and B are between turns.
    herdr agent prompt "$pc" "keep working slow" >/dev/null 2>&1 || true
    until_state "$pc" '^working$' 10
    local na nb nc ncod a
    na="$(jq -r '.result.agents[0].mail_name' <<<"$claudes")"
    nb="$(jq -r '.result.agents[1].mail_name' <<<"$claudes")"
    nc="$(jq -r '.result.agents[2].mail_name' <<<"$claudes")"
    ncod="$(jq -r '.result.agents[0].mail_name // empty' <<<"$codex")"
    check "E10: the third Claude is working when the review goes out" test "$(state "$pc")" = working
    out="$(nhm send e10 "review the other's work slow" --cc --state "done" --state idle --json 2>&1)"
    echo "### nhm send e10 --cc --state done --state idle"
    echo "$out"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e10-send.json"
    check "E10: the send reaches exactly the two Claudes between turns" \
        jq -e --arg a "$na" --arg b "$nb" '[.result.targets[].mail_name] | sort == ([$a, $b] | sort)' <<<"$out"
    check "E10: both are submitted" jq -e '[.result.targets[].submission] | all(. == "submitted")' <<<"$out"
    check "E10: the working Claude is left alone" \
        jq -e --arg c "$nc" '[.result.targets[].mail_name] | index($c) == null' <<<"$out"
    check "E10: the Codex is never chosen" \
        jq -e --arg x "$ncod" '[.result.targets[] | select(.kind == "codex" or .mail_name == $x)] | length == 0' <<<"$out"
    check "E10: the result lists the frozen targets (state at selection)" \
        jq -e '[.result.targets[].baseline.state] | all(. == "idle" or . == "done")' <<<"$out"
    # The reviewers' answers, as the stop rule reads them.
    for a in "$na" "$nb"; do
        until_state "$(jq -r --arg m "$a" '.result.targets[] | select(.mail_name == $m) | .pane_id' <<<"$out")" '^(idle|done)$' 60
        check "E10: nhm read shows $a's answer" bash -c 'nhm read "$1" --source recent --lines 80 | grep -qi "mock"' _ "$a"
    done
    manual "E10: rounds every 45 minutes until two clean rounds (the step runs one round)"
}
