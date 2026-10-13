# shellcheck shell=bash
# E21 A stack tool through nhm (METHOD-MATRIX E21; acfs-sag): the arosl
# brenner fork at the tag ACFS pins (the harness fetches and checks it)
# runs its cockpit's two calls through nhm, `nhm spawn THREAD <args>` and
# `nhm send THREAD --all <message>`, and its doctor checks nhm in ntm's
# place. ru's driver functions are E21's other half; they pass against
# nhm's stub in ru's own tests (arosl/repo_updater), not here.
#
# The cockpit spawns one Claude (--ntm-args=--cc=1): the sandbox mocks
# only Anthropic's API, so a Codex or Antigravity agent could not start.
# brenner's default roster, --cc=1 --cod=1 --agy=1, is checked as nhm
# parses it, with --dry-run. The kickoff goes to a roster name through
# the sandbox Agent Mail, as an operator's roster would.

#
# A spawn without --prompt sends ACFS's default_new_agent kickoff, which
# nhm reads from ACFS's palette catalog; the step installs the catalog
# where ACFS's install puts it.

# e21_asked TEXT: the mock was asked a prompt that holds TEXT (it logs
# each prompt whole).
e21_asked() { grep -qF -- "$1" "$SANDBOX_EVIDENCE/mock-requests.jsonl" 2>/dev/null; }

step_E21() {
    local dir doctor dry plan run op receipt inbox status repo
    if ! command -v brenner >/dev/null 2>&1; then
        echo "FAIL E21: no brenner fork in the sandbox (the harness's sandbox_brenner_release)"
        return
    fi
    show "brenner version" brenner --version || true
    export AGENT_MAIL_BASE_URL="http://127.0.0.1:8765" AGENT_MAIL_PATH="/mcp/"
    repo="$(dirname "$SANDBOX_LIB")/../../.."
    mkdir -p "$HOME/.acfs/onboard/docs/ntm"
    cp "$repo/acfs/onboard/docs/ntm/command_palette.md" "$HOME/.acfs/onboard/docs/ntm/command_palette.md"
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    dir="$HOME/e21"
    mkdir -p "$dir" && git -C "$dir" init -q
    printf 'E21 rehearsal excerpt: a short passage for the kickoff.\n' >"$dir/excerpt.md"
    sandbox_claude_prepare "$dir" >/dev/null
    claude_guards
    nhm_owner || { echo "FAIL E21: nhm could not take the server over"; return; }

    doctor="$(cd "$dir" && brenner doctor --json --skip-cass --skip-cm 2>&1)"
    printf '%s\n' "$doctor" >"$SANDBOX_EVIDENCE/e21-doctor.json"
    check "E21: brenner doctor finds nhm in ntm's place and runs 'nhm version'" \
        jq -e '.checks.ntm.status == "ok" and .checks.ntm.verifyCommand == "nhm version"' <<<"$doctor"
    check "E21: brenner doctor passes (cass and cm skipped: the sandbox has no CASS index)" \
        bash -c 'cd "$1" && brenner doctor --json --skip-cass --skip-cm >/dev/null 2>&1' _ "$dir"

    dry="$(cd "$dir" && brenner cockpit start --dry-run --json --project-key "$dir" --thread-id e21 \
        --sender GrayHeron --to BlueLake --role-map "BlueLake=hypothesis_generator" \
        --excerpt-file "$dir/excerpt.md" --question "Does the cockpit reach nhm?" 2>&1)"
    printf '%s\n' "$dry" >"$SANDBOX_EVIDENCE/e21-dry-run.json"
    check "E21: the cockpit's spawn is nhm spawn with ntm's roster arguments" \
        jq -e '.ntm.spawn.argv == ["nhm", "spawn", "e21", "--cc=1", "--cod=1", "--agy=1"]' <<<"$dry"
    check "E21: the cockpit's broadcast is nhm send THREAD --all" \
        jq -e '.ntm.broadcast.argv[0:4] == ["nhm", "send", "e21", "--all"]' <<<"$dry"
    # The sandbox sets only Claude's guards; --allow-unguarded keeps nhm's
    # guard admission out of a dry run that checks the grammar.
    plan="$(cd "$dir" && nhm spawn e21-roster --cc=1 --cod=1 --agy=1 --dry-run --allow-unguarded --json 2>&1)"
    printf '%s\n' "$plan" >"$SANDBOX_EVIDENCE/e21-roster-plan.json"
    check "E21: nhm parses brenner's default roster (--cc=1 --cod=1 --agy=1, dry run)" \
        jq -e '(.error // null) == null' <<<"$plan"

    # --ntm-args=VALUE: brenner's parser takes a separate value that starts
    # with -- for the next flag.
    run="$(cd "$dir" && brenner cockpit start --json --ntm-args=--cc=1 --project-key "$dir" --thread-id e21 \
        --sender GrayHeron --to BlueLake --role-map "BlueLake=hypothesis_generator" \
        --excerpt-file "$dir/excerpt.md" --question "Does the cockpit reach nhm?" 2>"$SANDBOX_EVIDENCE/e21-cockpit.err")"
    printf '%s\n' "$run" >"$SANDBOX_EVIDENCE/e21-cockpit.json"
    check "E21: cockpit start succeeds" jq -e '.ok == true' <<<"$run"
    check "E21: its nhm spawn exited 0" jq -e '[.ntm[] | select(.action == "spawn") | .exitCode] == [0]' <<<"$run"
    check "E21: its nhm send --all exited 0" jq -e '[.ntm[] | select(.action == "broadcast") | .exitCode] == [0]' <<<"$run"
    check "E21: the kickoff went out through Agent Mail" jq -e '.sent == 1' <<<"$run"

    status="$(nhm status e21 --json 2>&1)"
    printf '%s\n' "$status" >"$SANDBOX_EVIDENCE/e21-status.json"
    check "E21: nhm runs one agent in the cockpit's session" \
        jq -e '[.result.agents[]?] | length == 1' <<<"$status"
    inbox="$(am mail inbox --project "$dir" --agent BlueLake --json 2>&1)"
    printf '%s\n' "$inbox" >"$SANDBOX_EVIDENCE/e21-inbox.json"
    check "E21: the roster's inbox holds the kickoff for thread e21" \
        jq -e '[.. | objects | select(.thread_id? == "e21")] | length >= 1' <<<"$inbox"

    op="$(jq -r '.ntm[] | select(.action == "broadcast") | .stdout' <<<"$run" | grep -oE 'op-[A-Za-z0-9-]+' | head -1)"
    receipt="$(nhm --robot-send-receipt="$op" --robot-format=json 2>&1)"
    printf '%s\n' "$receipt" >"$SANDBOX_EVIDENCE/e21-receipt.json"
    check "E21: nhm's receipt for the broadcast reads submitted" \
        jq -e '.success and (.. | objects | select(has("successful")) | .successful | length == 1)' <<<"$receipt"
    sleep 5
    check "E21: the broadcast reached the agent (the model was asked about thread e21)" \
        e21_asked "Agent Mail inbox for thread: e21"
}
