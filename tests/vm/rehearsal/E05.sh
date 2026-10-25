# shellcheck shell=bash
# E05 Polishing with a recycle and a Codex final pass (METHOD-MATRIX E05;
# acfs-9hkh.94): the palette's improve_beads prompt to a Claude for a
# bead, `nhm recycle` with a handoff, the third pass in the fresh
# session, and a fourth pass whose target is a Codex (--cod). Pass
# conditions: pass 3 runs after the recycle in a new session with the
# same name, pane and tab, and a bumped generation; the handoff receipt
# names the bead's handoff comment, the session (cass pack, or a direct
# excerpt while cass has not indexed it) and cm context; pass 4's only
# target is the Codex; each pass's summary is read with `nhm read`.
#
# The step's own improve_beads template stands in for the palette's (the
# sandbox has no ACFS palette); the passes ask the mock for a slow reply,
# so herdr sees each turn start. The Codex is added with
# --allow-unguarded: its guards are E01's subject. Its trust in herdr's
# state hook is recorded before it starts (sandbox_codex_trust_herdr), as
# the live swarm's was, so it comes up ready and pass 4 needs no
# --when any (acfs-9hkh.99).

# e05_row NAME: the agent's row in `nhm list --json` (one line), or nothing.
e05_row() {
    nhm list --json 2>/dev/null | jq -c --arg n "$1" 'first(.result.agents[]? | select(.binding.mail_name == $n)) // empty'
}

# e05_read LABEL NAME: `nhm read NAME`, saved as e05-read-LABEL.json and
# shown; succeeds when the pane shows the mock's reply.
e05_read() {
    local out
    out="$(nhm read "$2" --lines 40 --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e05-read-$1.json"
    echo "### nhm read $2 ($1)"
    echo "$out"
    grep -q 'mock reply' <<<"$out"
}

# e05_send LABEL ARGS...: nhm send in the e05 project, saved as
# e05-send-LABEL.json and shown.
e05_send() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e05" && nhm send e05 -t improve_beads --project "$HOME/e05" "$@" --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e05-send-$label.json"
    echo "### nhm send e05 -t improve_beads $* ($label)"
    echo "$out"
}

step_E05() {
    local dir out a pa bead before after cod pcod
    for tool in br cm cass; do
        command -v "$tool" >/dev/null 2>&1 || { echo "FAIL E05: $tool is not in the sandbox (sandbox_bin $tool)"; return; }
    done
    dir="$HOME/e05"
    mkdir -p "$dir/.nhm/templates" && git -C "$dir" init -q || { echo "FAIL E05: the project"; return; }
    (cd "$dir" && br init >"$SANDBOX_EVIDENCE/e05-br-init.out" 2>&1) || { echo "FAIL E05: br init"; return; }
    printf 'Improve the beads around {{bead_id}}: {{bead_title}}. Tighten each one; reply slow.\n' \
        >"$dir/.nhm/templates/improve_beads.md"
    sandbox_claude_prepare "$dir" >/dev/null && sandbox_codex_prepare "$dir" >/dev/null
    # herdr's integration after sandbox_codex_prepare, which writes Codex's
    # config.toml whole.
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E05: Codex trusts herdr's state hook before the Codex starts" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E05: nhm could not take the server over"; return; }
    CASS_MEMORY_LLM=none cm playbook add "Polish beads in passes; tighten each bead's acceptance" --category workflow --json \
        >"$SANDBOX_EVIDENCE/e05-cm-rule.json" 2>&1 || true

    out="$(cd "$dir" && nhm spawn e05 --cc=1 --prompt "say hi" --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e05-spawn.json"
    a="$(jq -r '._nhm.result.agents[0].mail_name // empty' <<<"$out")"
    pa="$(jq -r '._nhm.result.agents[0].pane_id // empty' <<<"$out")"
    check "E05: nhm spawned the Claude" test -n "$a" -a -n "$pa"
    [[ -n "$a" ]] || return
    settle "$pa"
    bead="$(cd "$dir" && br create --title "e05: polish the plan's beads" --type task --assignee "$a" --silent 2>/dev/null)"
    (cd "$dir" && br update "$bead" --status in_progress >/dev/null 2>&1 &&
        br comments add "$bead" "handoff: passes 1 and 2 tightened the acceptance of every bead; pass 3 checks the dependencies" \
            >/dev/null 2>&1)
    check "E05: the Claude has a bead in progress, with a handoff comment" test -n "$bead"

    # Passes 1 and 2.
    e05_send pass1 --name "$a" --bead "$bead"
    check "E05: pass 1 is submitted" jq -e '.result.targets[0].submission == "submitted"' "$SANDBOX_EVIDENCE/e05-send-pass1.json"
    settle "$pa"
    check "E05: pass 1's summary is read with nhm read" e05_read pass1 "$a"
    e05_send pass2 --name "$a" --bead "$bead"
    settle "$pa"
    check "E05: pass 2's summary is read with nhm read" e05_read pass2 "$a"

    # The recycle.
    before="$(e05_row "$a")"
    echo "### before the recycle: $before"
    out="$(cd "$dir" && nhm recycle "$a" --prompt "Pass 3 on $bead: check the beads' dependencies; reply slow." \
        --project "$dir" --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e05-recycle.json"
    echo "### nhm recycle $a"
    echo "$out"
    check "E05: nhm recycle succeeds" jq -e '.error == null and .result.stage == "done"' <<<"$out"
    after="$(e05_row "$a")"
    echo "### after the recycle: $after"
    check "E05: the same name and pane" \
        jq -e --arg a "$a" --arg p "$pa" '.result.mail_name == $a and .result.pane_id == $p' <<<"$out"
    check "E05: the generation is bumped" \
        jq -en --argjson b "${before:-null}" --argjson r "$(jq -c .result <<<"$out" 2>/dev/null || echo null)" \
            '$r.generation == ($b.binding.generation + 1)'
    check "E05: a new session" \
        jq -en --argjson b "${before:-null}" --argjson x "${after:-null}" \
            '$b.agent_session.value as $o | $x.agent_session.value as $n | $o != null and $n != null and $o != $n'
    check "E05: the same tab" \
        jq -en --argjson b "${before:-null}" --argjson x "${after:-null}" '$b.tab_id != null and $b.tab_id == $x.tab_id'
    check "E05: the handoff names the bead's handoff comment" jq -e '.result.handoff.sources | index("bead") != null' <<<"$out"
    check "E05: and the last session (cass pack, or a direct excerpt)" \
        jq -e '.result.handoff.sources | (index("cass") != null or index("excerpt") != null)' <<<"$out"
    check "E05: and cm context" jq -e '.result.handoff.sources | index("cm") != null' <<<"$out"

    # Pass 3, in the fresh session (the recycle's kickoff).
    check "E05: pass 3 (the recycle's kickoff) is sent" \
        jq -e '.result.kickoff_submission == "submitted" or .result.kickoff_submission == "possibly_submitted"' <<<"$out"
    settle "$pa"
    check "E05: pass 3's summary is read with nhm read" e05_read pass3 "$a"

    # Pass 4: a Codex.
    out="$(cd "$dir" && nhm add e05 --cod=1 --allow-unguarded --prompt "say hi" --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e05-add-codex.json"
    cod="$(jq -r '._nhm.result.agents[0].mail_name // empty' <<<"$out")"
    pcod="$(jq -r '._nhm.result.agents[0].pane_id // empty' <<<"$out")"
    check "E05: a Codex joins" test -n "$cod" -a -n "$pcod"
    check "E05: the Codex is ready (herdr reads its state)" jq -e '._nhm.result.agents[0].ready == true' <<<"$out"
    settle "$pcod"
    e05_send pass4 --cod --bead "$bead"
    check "E05: pass 4's only target is the Codex" \
        jq -e --arg c "$cod" '[.result.targets[] | .mail_name] == [$c] and .result.targets[0].kind == "codex"' \
            "$SANDBOX_EVIDENCE/e05-send-pass4.json"
    check "E05: and is submitted" jq -e '.result.targets[0].submission | test("submitted")' "$SANDBOX_EVIDENCE/e05-send-pass4.json"
    sleep 10
    check "E05: pass 4's summary is read with nhm read" e05_read pass4 "$cod"
}
