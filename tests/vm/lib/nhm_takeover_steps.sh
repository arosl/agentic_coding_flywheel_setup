#!/usr/bin/env bash
# ============================================================
# The takeover choreography of the nhm rehearsal (acfs-9hkh.31.1; plan-v8
# section 5 step 6, rehearsed in the sandbox per the operator's ruling of
# 2026-10-12).
#
# Source this file inside sandbox_exec (tests/vm/lib/nhm_sandbox.sh),
# after sandbox_herdr_start and sandbox_mail_start, with nhm and nhm-hook
# in the sandbox's bin (sandbox_nhm_build or sandbox_nhm_release). Each
# step writes <step>.json (nhm's --json envelope), <step>.stderr and
# <step>.rc into $SANDBOX_EVIDENCE, prints "ok <step>: ..." or
# "FAIL <step>: ...", and returns 0 or 1. First the precondition:
#
#   takeover_bash_agent DIR  an agent the Bash spawned, in a git project
#
# Then the steps in order:
#
#   takeover_enroll          nhm admin instance enroll: nhm knows this
#                            herdr server; the Bash still owns it
#   takeover_dry_run         nhm admin takeover --dry-run: passes, and
#                            changes nothing (the Bash still owns it)
#   takeover_run             nhm admin takeover --yes: nhm owns the
#                            server, and a Bash mutator now refuses
#
# takeover_all runs the three and returns 1 when any failed. The
# rehearsal ends with nhm the owner, as the takeover on the swarm host
# will (acfs-9hkh.32); nhm has no handback since v0.1.17 (nhm-te0).
# ============================================================

# takeover_bash_agent DIR: the precondition, an agent the Bash spawned.
# DIR becomes a git repository (nhm binds agents per project), Claude Code
# gets its first-run state (sandbox_claude_prepare), a herdr workspace
# opens on DIR, and `acfs agents spawn --claude 1` starts a real Claude
# there. Needs claude, git and jq in the sandbox, and the mock API and
# Agent Mail running. Prints the agent's herdr name.
takeover_bash_agent() {
    local dir="${1:-}" ws name
    [[ -n "$dir" ]] || { sandbox_die "takeover_bash_agent: give a directory"; return 1; }
    mkdir -p "$dir" || return 1
    if [[ ! -d "$dir/.git" ]]; then
        git -C "$dir" init -q &&
            git -C "$dir" -c user.name=rehearsal -c user.email=rehearsal@example.invalid \
                commit -q --allow-empty -m "rehearsal project" || return 1
    fi
    sandbox_claude_prepare "$dir" || return 1
    ws="$(herdr workspace create --cwd "$dir" --label rehearsal --no-focus 2>/dev/null |
        jq -r '.result.workspace.workspace_id // empty')"
    [[ -n "$ws" ]] || { sandbox_die "takeover_bash_agent: herdr made no workspace"; return 1; }
    if ! acfs agents spawn --claude 1 --workspace "$ws" --cwd "$dir" --no-prompt --trust-folder --force \
        >"$SANDBOX_EVIDENCE/bash-spawn.out" 2>&1; then
        sandbox_die "takeover_bash_agent: acfs agents spawn failed (bash-spawn.out)"
        return 1
    fi
    name="$(sed -n 's/^started: [A-Za-z]* (\([a-z]*\), claude).*/\1/p' "$SANDBOX_EVIDENCE/bash-spawn.out" | head -1)"
    [[ -n "$name" ]] || { sandbox_die "takeover_bash_agent: spawn named no agent (bash-spawn.out)"; return 1; }
    printf '%s\n' "$name"
}

# takeover_nhm STEP ARGS...: run nhm with --json, keep its output.
takeover_nhm() {
    local step="$1"
    shift
    local rc=0
    nhm "$@" --json >"$SANDBOX_EVIDENCE/$step.json" 2>"$SANDBOX_EVIDENCE/$step.stderr" || rc=$?
    printf '%s\n' "$rc" >"$SANDBOX_EVIDENCE/$step.rc"
    return "$rc"
}

# The owner as the Bash reads it: acfs-bash or nhm.
takeover_owner() {
    acfs agents owner 2>/dev/null
}

takeover_report() { # STATUS STEP TEXT
    printf '%s %s: %s\n' "$1" "$2" "$3"
    [[ "$1" == ok ]]
}

takeover_enroll() {
    local rc=0 owner
    takeover_nhm enroll admin instance enroll || rc=$?
    owner="$(takeover_owner)"
    if ((rc != 0)); then
        takeover_report FAIL enroll "nhm admin instance enroll exited $rc (enroll.stderr)"
    elif [[ "$owner" != acfs-bash ]]; then
        takeover_report FAIL enroll "after enroll the owner is '$owner', not acfs-bash"
    else
        takeover_report ok enroll "nhm is enrolled; the Bash owns the server"
    fi
}

# takeover_unimported FILE: why the report leaves a Bash agent or token
# behind, one line each; empty when it took every one. Every agent herdr
# runs here was spawned by the Bash, so each must end bound (imported,
# would_import, or already_bound by enroll's import), and each token must
# reach a binding: acfs_only and no_binding leave it with the Bash
# (plan-v8 section 5: an entry that cannot be imported refuses).
takeover_unimported() {
    jq -r '
        ((.result.bindings.items // [])[] | select(.action == "skipped")
            | "agent \(.herdr_name // .pane_id): skipped: \(.reason // "")"),
        ((.result.tokens // [])[] | select(.action == "acfs_only" or .action == "no_binding")
            | "token \(.mail_name // "?"): \(.action)")
    ' "$1" 2>/dev/null
}

takeover_dry_run() {
    local rc=0 owner dry left
    takeover_nhm takeover-dry-run admin takeover --dry-run || rc=$?
    owner="$(takeover_owner)"
    dry="$(jq -r '.result.dry_run // empty' "$SANDBOX_EVIDENCE/takeover-dry-run.json" 2>/dev/null)"
    left="$(takeover_unimported "$SANDBOX_EVIDENCE/takeover-dry-run.json")"
    if ((rc != 0)); then
        takeover_report FAIL takeover-dry-run "exited $rc: $(jq -r '.error.message // .error // empty' "$SANDBOX_EVIDENCE/takeover-dry-run.json" 2>/dev/null)"
    elif [[ "$dry" != true ]]; then
        takeover_report FAIL takeover-dry-run "the report does not say dry_run"
    elif [[ -n "$left" ]]; then
        takeover_report FAIL takeover-dry-run "it would pass but leave Bash state behind: ${left//$'\n'/; }"
    elif [[ "$owner" != acfs-bash ]]; then
        takeover_report FAIL takeover-dry-run "a dry run changed the owner to '$owner'"
    else
        takeover_report ok takeover-dry-run "it would pass, and the Bash still owns the server"
    fi
}

takeover_run() {
    local rc=0 owner refuse_rc=0 left
    takeover_nhm takeover admin takeover --yes || rc=$?
    owner="$(takeover_owner)"
    left="$(takeover_unimported "$SANDBOX_EVIDENCE/takeover.json")"
    # A Bash mutator must now refuse, and start nothing.
    acfs agents spawn --claude 1 >"$SANDBOX_EVIDENCE/bash-spawn-after-takeover.out" 2>&1 || refuse_rc=$?
    if ((rc != 0)); then
        takeover_report FAIL takeover "exited $rc: $(jq -r '.error.message // .error // empty' "$SANDBOX_EVIDENCE/takeover.json" 2>/dev/null)"
    elif [[ "$owner" != nhm ]]; then
        takeover_report FAIL takeover "after the takeover the owner is '$owner', not nhm"
    elif [[ -n "$left" ]]; then
        takeover_report FAIL takeover "nhm owns the server but left Bash state behind: ${left//$'\n'/; }"
    elif ((refuse_rc == 0)); then
        takeover_report FAIL takeover "acfs agents spawn still ran with nhm the owner"
    elif ! grep -q 'nhm owns this herdr server' "$SANDBOX_EVIDENCE/bash-spawn-after-takeover.out"; then
        takeover_report FAIL takeover "acfs agents spawn failed, but not because nhm owns the server"
    else
        takeover_report ok takeover "nhm owns the server, and acfs agents spawn refuses"
    fi
}

takeover_all() {
    local failed=0
    takeover_enroll || failed=1
    takeover_dry_run || failed=1
    takeover_run || failed=1
    return "$failed"
}
