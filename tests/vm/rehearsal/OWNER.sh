# shellcheck shell=bash
# OWNER ACFS's own takeover (acfs-9hkh.93): install.sh and acfs update run
# `nhm_hooks.sh owner take`, so every install ends with nhm as the owner of
# the herdr server. --owner runs this step alone, on a new sandbox root,
# with three cases in this order:
#   1. a fresh install: nhm enrolled, no herdr server running, and the Bash
#      keeps nothing: owner take exits 0, and nhm owns the server;
#   2. an upgraded install whose Bash keeps an agent and a token that no
#      agent holds: owner take exits 5 (refused), the Bash stays the owner,
#      and its state and nhm's bindings are as they were;
#   3. the same install once that token is gone: owner take exits 0, nhm
#      owns the server with the agent imported, and a Bash mutator refuses.
# Between 1 and 2 the sandbox gives the server back to the Bash by
# removing nhm's owner.toml, as on an install from before acfs-9hkh.93: a
# fixture reset that nhm itself never does.

owner_hooks() { printf '%s/../../../scripts/lib/nhm_hooks.sh\n' "$(dirname "$SANDBOX_LIB")"; }

# owner_take LABEL: ACFS's step, as install.sh and acfs update run it.
# Shows its note and exit code; sets OWNER_RC.
owner_take() {
    OWNER_RC=0
    show "$1: nhm_hooks.sh owner take" bash "$(owner_hooks)" owner take || OWNER_RC=$?
}

owner_is() { [[ "$(acfs agents owner 2>/dev/null)" == "$1" ]]; }

# owner_bound NAME: nhm has a binding for the agent herdr names NAME.
owner_bound() {
    nhm list --json --no-mail 2>/dev/null |
        jq -e --arg n "$1" '[.result.agents[]? | select(.herdr_name == $n and .binding != null)] | length == 1' >/dev/null
}
owner_unbound() { ! owner_bound "$1"; }

# owner_state: what the Bash keeps (acfs agents export, without its time)
# and nhm's bindings, to compare across a refusal.
owner_state() {
    acfs agents export 2>/dev/null | jq -S 'del(.exported_at)'
    nhm list --json --no-mail 2>/dev/null |
        jq -S '.result | [.agents[]?.binding, .absent_bindings[]?, .displaced_bindings[]?] | map({binding_id, generation, status, mail_name})'
}

step_OWNER() {
    local inst name before after ghostdir dir="$HOME/project"
    inst="$(compgen -G "${XDG_STATE_HOME:-$HOME/.local/state}/nhm/inst-*/instance.toml" | head -n 1)"
    inst="${inst%/instance.toml}"
    [[ -n "$inst" ]] || { echo "FAIL OWNER: nhm enrolled no instance"; return; }

    # 1. A fresh install: install.sh enrolls nhm, but starts no herdr server.
    sandbox_herdr_stop
    owner_take "OWNER 1"
    check "OWNER 1: a fresh install: owner take exits 0" test "$OWNER_RC" -eq 0
    check "OWNER 1: nhm owns the server" owner_is nhm
    check "OWNER 1: nhm wrote owner.toml" test -f "$inst/owner.toml"
    owner_take "OWNER 1 again"
    check "OWNER 1: run again (an install re-run), it exits 0: nhm owns it already" test "$OWNER_RC" -eq 0

    # The fixture reset: the Bash owns the server again, as before this bead.
    rm -f "$inst/owner.toml"
    sandbox_herdr_start || { echo "FAIL OWNER: the herdr server did not start again"; return; }
    check "OWNER: after the reset the Bash owns the server" owner_is acfs-bash

    # 2. An upgrade whose Bash keeps an agent, and a token no agent holds.
    # The agent is not read into nhm's bindings first (bash_agent does
    # that), so only the takeover can bind it.
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 ||
        { echo "FAIL OWNER: herdr integration install claude"; return; }
    # shellcheck source=tests/vm/lib/nhm_takeover_steps.sh
    source "$(dirname "$SANDBOX_LIB")/nhm_takeover_steps.sh"
    name="$(takeover_bash_agent "$dir")" || { echo "FAIL OWNER: the Bash spawn (bash-spawn.out)"; return; }
    echo "agent: $name"
    ghostdir="${ACFS_HOME:-$HOME/.acfs}/state/tokens/$(printf '%s' "$dir" | sha256sum | cut -c1-16)"
    mkdir -p "$ghostdir" && printf '%s\n' "$dir" >"$ghostdir/.project" && printf 'tok-ghost\n' >"$ghostdir/GhostOwl"
    check "OWNER 2: before the takeover nhm has no binding for the Bash's agent" owner_unbound "$name"
    before="$(owner_state)"
    owner_take "OWNER 2"
    after="$(owner_state)"
    check "OWNER 2: a token no agent holds: owner take refuses (exit 5)" test "$OWNER_RC" -eq 5
    check "OWNER 2: the Bash still owns the server" owner_is acfs-bash
    check "OWNER 2: nothing changed: the Bash's state and nhm's bindings" test "$before" = "$after"

    # 3. The same upgrade without that token.
    rm -f "$ghostdir/GhostOwl"
    owner_take "OWNER 3"
    check "OWNER 3: owner take exits 0" test "$OWNER_RC" -eq 0
    check "OWNER 3: nhm owns the server" owner_is nhm
    check "OWNER 3: the takeover bound the Bash's agent in nhm" owner_bound "$name"
    check "OWNER 3: acfs agents spawn refuses: nhm owns this herdr server" bash -c '! acfs agents spawn --claude 1 >"$1" 2>&1 &&
        grep -q "nhm owns this herdr server" "$1"' _ "$SANDBOX_EVIDENCE/owner-bash-spawn.out"
}
