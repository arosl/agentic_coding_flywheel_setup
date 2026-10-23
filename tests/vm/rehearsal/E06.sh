# shellcheck shell=bash
# E06 The mixed launch (METHOD-MATRIX E06; acfs-9hkh.94): one staggered
# spawn of two Claudes and two Codexes whose kickoffs carry --with-memory
# --with-cass, then one more launch while CASS hangs. Pass conditions:
# every agent's Agent Mail identity exists before its kickoff; every pane
# carries its name; the result has the stagger schedule and each agent's
# kickoff; the kickoffs' receipts record CM's rule ids and CASS's hit ids;
# with CASS hanging the kickoff still goes, records why CASS was left out,
# and waits at most about 5 s for it; each agent's guards are recorded.
#
# Not in the sandbox, so MANUAL: agy and pi (not installed), and "no two
# agents claim one bead in ten minutes" (the mock agents claim nothing).
# The Codexes are added with --allow-unguarded (their guards are E01's
# subject), after Codex trusts herdr's state hook, so they come up ready
# (acfs-9hkh.99).
#
# A first Claude's turn is indexed by CASS, so a kickoff has something to
# find: nhm gives CASS the kickoff's keywords (nhm-vbx), and the kickoff
# repeats that turn's words. A locked index is staged as a cass that
# hangs: to nhm, the same thing. It is one process (exec sleep): a cass
# whose child outlives it holds nhm past its budget (nhm-gne).
#
# What a kickoff's enrichment recorded is read from nhm's store, read
# only: no nhm command shows a kickoff's CASS part (nhm-p6r; feedback list
# is CM's, and --robot-send-receipt leaves it out).

# e06_kickoff: the launch's new-agent prompt.
e06_kickoff() { echo "Draft the e06 plan's first bead; reply slow."; }

# e06_json LABEL CMD...: runs CMD in the project, saves its output as
# e06-LABEL.json and shows it.
e06_json() {
    local label="$1" out
    shift
    out="$(cd "$HOME/e06" && "$@" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e06-$label.json"
    echo "### $label: $*"
    echo "$out"
}
e06_file() { printf '%s/e06-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e06_recorded OP: what nhm recorded for operation OP's enrichment, read
# only from its store (the sandbox's one instance), saved as
# e06-recorded-OP.json and shown: {"cm": [included ids], "cass": [...],
# "cass_error", "cass_skipped"}.
e06_recorded() {
    local db out
    db="$(printf '%s\n' "$HOME/.local/state/nhm"/inst-*/nhm.sqlite3 | head -n 1)"
    out="$(python3 -I -c '
import json, sqlite3, sys
db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
op = sys.argv[2]
out = {"cm": [], "cass": [], "cass_error": "", "cass_skipped": ""}
for src, items in db.execute("SELECT source, items_json FROM injections WHERE operation_id = ?", (op,)):
    if src in ("cm", "cass"):
        out[src] += [i.get("id", "") for i in json.loads(items) if i.get("status") == "included"]
row = db.execute("SELECT scope_json FROM operations WHERE operation_id = ?", (op,)).fetchone()
cass = (json.loads(row[0]) or {}).get("cass_injection") or {} if row else {}
out["cass_error"] = cass.get("error", "")
out["cass_skipped"] = cass.get("skipped_reason", "")
print(json.dumps(out))
' "$db" "$1" 2>&1)"
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e06-recorded-$1.json"
    echo "### recorded for $1: $out"
}

# e06_receipts SOURCE OP...: each operation's recorded enrichment includes
# at least one item from SOURCE (cm or cass).
e06_receipts() {
    local source="$1" op
    shift
    (($# > 0)) || return 1
    for op in "$@"; do
        jq -e --arg s "$source" '.[$s] | length >= 1' "$SANDBOX_EVIDENCE/e06-recorded-$op.json" >/dev/null || return 1
    done
}

step_E06() {
    local dir p ops op names slow t0 t1
    for tool in cm cass codex; do
        command -v "$tool" >/dev/null 2>&1 || { echo "FAIL E06: $tool is not in the sandbox (sandbox_bin $tool)"; return; }
    done
    dir="$HOME/e06"
    mkdir -p "$dir" && git -C "$dir" init -q || { echo "FAIL E06: the project"; return; }
    sandbox_claude_prepare "$dir" >/dev/null && sandbox_codex_prepare "$dir" >/dev/null
    # herdr's integration after sandbox_codex_prepare, which writes Codex's
    # config.toml whole; then Codex's trust in herdr's state hook.
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    herdr integration install codex >>"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    check "E06: Codex trusts herdr's state hook before the launch" sandbox_codex_trust_herdr
    claude_guards
    nhm_owner || { echo "FAIL E06: nhm could not take the server over"; return; }
    CASS_MEMORY_LLM=none cm playbook add "Draft a plan's first bead before its others" --category workflow --json \
        >"$SANDBOX_EVIDENCE/e06-cm-rule.json" 2>&1 || true

    # Before the launch: a Claude turn for CASS to find.
    e06_json pre nhm spawn e06pre --cc=1 --prompt "$(e06_kickoff)" --json
    p="$(jq -r '.result.agents[0].pane_id // empty' "$(e06_file pre)")"
    settle "$p"
    cass index --full --json >"$SANDBOX_EVIDENCE/e06-cass-index.json" 2>&1 || true

    # The launch: two Claudes and two Codexes, staggered.
    e06_json spawn nhm spawn e06 --cc=2 --cod=2 --allow-unguarded --stagger-mode fixed --stagger-delay 1s \
        --with-memory --with-cass --prompt "$(e06_kickoff)" --json
    check "E06: four agents start, two Claudes and two Codexes, each ready" \
        jq -e '[.result.agents[] | select(.ready) | .kind] | sort == ["claude", "claude", "codex", "codex"]' "$(e06_file spawn)"
    manual "E06: agy and pi in the same launch (neither is in the sandbox)"
    manual "E06: no two agents claim one bead in ten minutes (the mock agents claim nothing)"
    check "E06: each identity was made before its kickoff" \
        jq -e '[.result.agents[] | select((.identity_provenance // "") != "" and (.kickoff_operation // "") != "")] | length == 4' \
            "$(e06_file spawn)"
    names="$(jq -c '[.result.agents[].mail_name]' "$(e06_file spawn)")"
    e06_json list nhm list --json
    check "E06: every pane carries its agent's name" \
        jq -e --argjson n "$names" '[.result.agents[]? | select(.binding.mail_name as $m | $n | index($m)) | .binding.name_matches] | length == 4 and all' \
            "$(e06_file list)"
    check "E06: the launch is staggered" \
        jq -e '.result.stagger_mode == "fixed" and ([.result.agents[].delay_ms] | . == sort and .[-1] > .[0])' "$(e06_file spawn)"
    e06_json robot nhm --robot-spawn=e06r --spawn-dir="$dir" --spawn-cc=2 --spawn-cod=2 --dry-run
    check "E06: the robot result has the stagger schedule" jq -e '(.stagger.schedule | length) == 4' "$(e06_file robot)"
    mapfile -t ops < <(jq -r '.result.agents[].kickoff_operation // empty' "$(e06_file spawn)")
    for op in "${ops[@]}"; do
        e06_json "receipt-$op" nhm feedback list --op "$op" --json
        e06_recorded "$op"
    done
    check "E06: the kickoffs' receipts record CM's rule ids" e06_receipts cm "${ops[@]}"
    check "E06: and CASS's hit ids" e06_receipts cass "${ops[@]}"
    e06_json status nhm status e06 --json
    check "E06: each agent's guards are recorded" \
        jq -e --argjson n "$names" '[.result.agents[]? | select(.binding.mail_name as $m | $n | index($m)) | .guards | objects | select(length > 0)] | length == 4' \
            "$(e06_file status)"

    # CASS hangs (a locked index): the kickoff still goes within 5 s.
    slow="$HOME/e06-slow-cass"
    mkdir -p "$slow"
    printf '#!/bin/sh\nexec sleep 30\n' >"$slow/cass"
    chmod +x "$slow/cass"
    t0=$SECONDS
    PATH="$slow:$PATH" e06_json locked nhm add e06 --cc=1 --with-memory --with-cass --prompt "$(e06_kickoff)" --json
    t1=$SECONDS
    echo "### the launch with CASS hanging took $((t1 - t0)) s"
    op="$(jq -r '.result.agents[0].kickoff_operation // empty' "$(e06_file locked)")"
    check "E06: with CASS hanging the kickoff still goes" \
        jq -e '.result.agents[0].kickoff_submission | test("submitted")' "$(e06_file locked)"
    e06_recorded "$op"
    check "E06: and records why CASS was left out" \
        jq -e '(.cass | length) == 0 and ((.cass_error + .cass_skipped) != "")' "$(e06_file "recorded-$op")"
    check "E06: and CM still went in" jq -e '(.cm | length) >= 1' "$(e06_file "recorded-$op")"
    # The 5 s budget is the enrichment's; the agent's own start is apart.
    check "E06: the enrichment waited at most 5 s for CASS" \
        jq -e '.result.agents[0].startup_ms as $s | (.result.total_startup_ms - $s) <= 8000' "$(e06_file locked)"
}
