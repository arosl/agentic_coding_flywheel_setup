#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================
# E15 of the nhm rehearsal (METHOD-MATRIX E15; acfs-9hkh.31): the
# designated pusher and retire's refusals. SELECT one, SEND, RETIRE.
#
# Sourced by tests/vm/test_nhm_rehearsal.sh, which copies step_E15 and
# the e15_ helpers into the step's script (run_step) beside its own
# helpers (check, show, nhm_owner, state, until_state, settle,
# claude_guards). Runs inside the sandbox with nhm as the owner, in
# $HOME/e15: a git repository with a bead database (br), and two Claudes
# that nhm spawns there.
#
# Pass conditions (the matrix's):
#   - the commit prompt reaches one agent: `nhm send --name A` submits to
#     A and to no one else;
#   - `nhm retire A` exits 2 and changes nothing while A holds a
#     reservation, then while a file A reserved has uncommitted changes,
#     then while A's bead is in progress without a handoff comment;
#   - after the handoff comment, `nhm retire A` retires A cleanly: exit
#     0, A's pane is gone, its Agent Mail identity retired.
# ============================================================

# e15_git DIR ARGS...: git with a fixed identity (the sandbox has no
# global git config).
e15_git() {
    local dir="$1"
    shift
    git -C "$dir" -c user.name=rehearsal -c user.email=rehearsal@example.invalid "$@"
}

# e15_retire LABEL NAME DIR: one `nhm retire`, its JSON saved and shown;
# prints the exit code.
e15_retire() {
    local label="$1" name="$2" dir="$3" out rc=0
    out="$(cd "$dir" && nhm retire "$name" --project "$dir" --json 2>&1)" || rc=$?
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e15-retire-$label.json"
    {
        echo "### nhm retire $name ($label, exit $rc)"
        echo "$out"
    } >&2
    printf '%s\n' "$rc"
}

# e15_refused FILE LABEL RC PANE NAME WHY: the pass conditions of one
# refusal (e15-retire-FILE.json): exit 2, the pane still there, the
# binding still active, and the refusal naming WHY (a regular
# expression).
e15_refused() {
    local file="$1" label="$2" rc="$3" pane="$4" name="$5" why="$6"
    check "E15: retire refuses $label (exit 2)" test "$rc" = 2
    check "E15: and names why ($why)" \
        jq -e --arg re "$why" '[.result.refusals[]?, (.error | strings)] | any(test($re; "i"))' \
        "$SANDBOX_EVIDENCE/e15-retire-$file.json"
    check "E15: and A's pane stays" test -n "$(state "$pane")"
    check "E15: and A stays bound" e15_bound "$name"
}

# e15_bound NAME: NAME has an active binding; e15_unbound: it has none.
e15_bound() {
    nhm list --json 2>/dev/null | jq -e --arg n "$1" '.result.agents[]? | select(.binding.mail_name == $n)' >/dev/null
}
e15_unbound() { ! e15_bound "$1"; }

step_E15() {
    local dir out a b pa pb rc bead targets
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    command -v br >/dev/null 2>&1 || { echo "FAIL E15: br is not in the sandbox (sandbox_bin br)"; return; }
    dir="$HOME/e15"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E15: the project"; return; }
    printf 'first line\n' >"$dir/notes.txt"
    e15_git "$dir" add notes.txt && e15_git "$dir" commit -q -m "e15 project" || { echo "FAIL E15: the first commit"; return; }
    (cd "$dir" && br init >"$SANDBOX_EVIDENCE/e15-br-init.out" 2>&1) || { echo "FAIL E15: br init"; return; }
    sandbox_claude_prepare "$dir" >/dev/null
    claude_guards
    nhm_owner || { echo "FAIL E15: nhm could not take the server over"; return; }

    out="$(cd "$dir" && nhm spawn e15 --cc=2 --prompt "say hi" --json 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e15-spawn.json"
    echo "### nhm spawn e15 --cc=2"
    echo "$out"
    a="$(jq -r '._nhm.result.agents[0].mail_name // empty' <<<"$out")"
    b="$(jq -r '._nhm.result.agents[1].mail_name // empty' <<<"$out")"
    pa="$(jq -r '._nhm.result.agents[0].pane_id // empty' <<<"$out")"
    pb="$(jq -r '._nhm.result.agents[1].pane_id // empty' <<<"$out")"
    check "E15: nhm spawned two agents" test -n "$a" -a -n "$b"
    [[ -n "$a" && -n "$b" ]] || return
    settle "$pa"
    settle "$pb"

    # SELECT one, SEND: the commit prompt reaches A only.
    out="$(nhm send e15 "You are the designated pusher: commit your work, merge origin/main, run the gate, then push." \
        --name "$a" --json 2>&1)" || true
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e15-send.json"
    echo "### nhm send e15 --name $a"
    echo "$out"
    targets="$(jq -c '[.result.targets[]? | .mail_name]' <<<"$out" 2>/dev/null)"
    check "E15: the commit prompt has exactly one target, A" test "$targets" = "[\"$a\"]"
    check "E15: and it was submitted to A" \
        jq -e --arg a "$a" '.result.targets[]? | select(.mail_name == $a and (.submission | test("submitted|delivered|accepted")))' <<<"$out"
    settle "$pa"

    # A's work: a bead in progress, and notes.txt reserved and changed.
    bead="$(cd "$dir" && br create --title "e15: A's change to notes.txt" --type task --assignee "$a" --silent 2>/dev/null)"
    (cd "$dir" && br update "$bead" --status in_progress >/dev/null 2>&1)
    check "E15: A has a bead in progress" test -n "$bead"

    # RETIRE refusals, each with nothing changed.
    am file_reservations reserve "$dir" "$a" notes.txt --exclusive --reason "$bead" \
        >"$SANDBOX_EVIDENCE/e15-reserve.out" 2>&1
    rc="$(e15_retire reservation "$a" "$dir")"
    e15_refused reservation "while A holds a reservation" "$rc" "$pa" "$a" "holds reservations: notes.txt"

    am file_reservations release "$dir" "$a" --paths notes.txt >"$SANDBOX_EVIDENCE/e15-release.out" 2>&1
    printf 'a change A did not commit\n' >>"$dir/notes.txt"
    rc="$(e15_retire dirty "$a" "$dir")"
    e15_refused dirty "while a file A reserved is dirty" "$rc" "$pa" "$a" "uncommitted changes in files .* reserved: notes.txt"
    check "E15: and the released reservation no longer counts" \
        jq -e '[.result.refusals[]? | select(test("holds reservations"))] | length == 0' "$SANDBOX_EVIDENCE/e15-retire-dirty.json"

    e15_git "$dir" commit -q -am "$bead: A's change"
    rc="$(e15_retire no-handoff "$a" "$dir")"
    e15_refused no-handoff "while A's bead has no handoff comment" "$rc" "$pa" "$a" "no handoff comment"
    check "E15: and that is the only refusal left" \
        jq -e '(.result.refusals | length) == 1' "$SANDBOX_EVIDENCE/e15-retire-no-handoff.json"

    # After the handoff comment, A retires cleanly; B stays.
    (cd "$dir" && br comments add "$bead" "handoff: notes.txt is committed; nothing left in progress" >/dev/null 2>&1)
    settle "$pa"
    rc="$(e15_retire clean "$a" "$dir")"
    check "E15: after the handoff, retire succeeds (exit 0)" test "$rc" = 0
    check "E15: and reports A retired" jq -e '.result.done == true' "$SANDBOX_EVIDENCE/e15-retire-clean.json"
    check "E15: and A's Agent Mail identity is retired" jq -e '.result.identity_retired == true' "$SANDBOX_EVIDENCE/e15-retire-clean.json"
    check "E15: and A's pane is gone" test -z "$(state "$pa")"
    check "E15: and A is no longer bound" e15_unbound "$a"
    check "E15: and B is still there" test -n "$(state "$pb")"
}
