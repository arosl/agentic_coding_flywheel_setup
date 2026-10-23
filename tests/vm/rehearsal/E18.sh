# shellcheck shell=bash
# E18 Interactive and remote (METHOD-MATRIX E18; acfs-9hkh.94). The
# sandbox lays nhm out as its installer does (current, the stable nhm and
# nhm-hook links, a plugin/ directory) and ACFS's palette where ACFS
# installs it, then links the plugin and binds its keys through ACFS's
# own path (nhm_hooks.sh plugin bind). Checked here:
# - c: the ensembles (nhm ensemble list, nhm modes list --tier core);
# - the keys: one nhm block in the server's config, with the palette,
#   board and menu keys once each, and nhm bind --print-client's block
#   for a remote client; the palette's catalog;
# - a: with two projects open, herdr runs the palette action with an
#   agent pane's context, as typed in a server pane, and nhm ui palette
#   opens its popup. A popup needs a client to show in, so the step opens
#   the palette's entrypoint as a tab with the context the action hands
#   it, and drives it by its screen: fresh_review to target 2 sends once,
#   to the captured project's two Claudes only; Esc sends nothing;
# - b: a context without a workspace opens the picker with both projects
#   (the Go palette, [ui] palette = "go"; v0.1.12's default fzf palette
#   takes its pane's workspace).
# The matrix's confirmation popup is not in nhm's palettes (both send at
# the target key). What only a client shows (the popup in the
# invoking client, the board over the attention feed, the spawn wizard's
# prompts, the Mac's key path) stays MANUAL. A third project, e18c, starts
# its Claude with nhm's --trust-folder, newproj's path, which fails in
# the sandbox's 40-column panes until nhm-za8.

# e18_lib NAME: a file of ACFS's scripts/lib.
e18_lib() { printf '%s/../../../scripts/lib/%s\n' "$(dirname "$SANDBOX_LIB")" "$1"; }

# e18_layout: nhm's installer's layout under ~/.local/share/nhm, from the
# release the sandbox unpacked, and ACFS's palette where ACFS puts it.
e18_layout() {
    local d="$HOME/.local/share/nhm" ver
    ver="$(find "$d/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -n 1)"
    [[ -n "$ver" && -f "$d/releases/$ver/plugin/herdr-plugin.toml" ]] || return 1
    ln -sfn "releases/$ver" "$d/current" &&
        ln -sfn current/nhm "$d/nhm" &&
        ln -sfn current/nhm-hook "$d/nhm-hook" &&
        mkdir -p "$d/plugin" "$HOME/.acfs/onboard/docs/ntm" &&
        cp "$d/current/plugin/herdr-plugin.toml" "$d/plugin/herdr-plugin.toml" &&
        cp "$(dirname "$SANDBOX_LIB")/../../../acfs/onboard/docs/ntm/command_palette.md" "$HOME/.acfs/onboard/docs/ntm/"
}

# e18_json LABEL CMD...: runs CMD, saves its output as e18-LABEL.json and
# its exit code as e18-LABEL.rc, and shows both.
e18_json() {
    local label="$1" out rc
    shift
    out="$("$@" 2>&1)"
    rc=$?
    printf '%s\n' "$out" >"$SANDBOX_EVIDENCE/e18-$label.json"
    printf '%s\n' "$rc" >"$SANDBOX_EVIDENCE/e18-$label.rc"
    echo "### $label (exit $rc): $*"
    printf '%s\n' "$out" | head -c 2000
    echo
}
e18_file() { printf '%s/e18-%s.json\n' "$SANDBOX_EVIDENCE" "$1"; }

# e18_palette WORKSPACE CONTEXT: opens nhm's palette as a tab of WORKSPACE,
# with CONTEXT as the popup's context (what nhm ui palette hands its popup
# in NHM_CONTEXT); prints the new pane.
e18_palette() {
    local out
    out="$(herdr plugin pane open --plugin nhm --entrypoint palette --placement tab \
        --workspace "$1" --env "NHM_CONTEXT=$2" 2>&1)"
    printf '%s\n' "$out" >>"$SANDBOX_EVIDENCE/e18-palette-open.json"
    jq -r '.result.plugin_pane.pane.pane_id // empty' <<<"$out" 2>/dev/null
}

# e18_until PANE REGEX: waits up to 20 s for the pane's screen to match.
e18_until() {
    local i
    for i in $(seq 1 40); do
        herdr pane read "$1" --source visible --lines 60 2>/dev/null | grep -Eq "$2" && return 0
        sleep 0.5
    done
    return 1
}

# e18_screen PANE NAME: saves the pane's screen as e18-NAME.txt.
e18_screen() { herdr pane read "$1" --source visible --lines 60 >"$SANDBOX_EVIDENCE/e18-$2.txt" 2>&1; }

# e18_sends: nhm's send operations, one per line: the operation and the
# bindings of its receipts.
e18_sends() {
    python3 -I - "$(printf '%s\n' "$HOME/.local/state/nhm"/inst-*/nhm.sqlite3 | head -n 1)" <<'PY'
import sqlite3, sys
db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
for (op,) in db.execute("SELECT operation_id FROM operations WHERE verb = 'send' ORDER BY rowid"):
    b = sorted(r[0] or "" for r in db.execute("SELECT binding_id FROM receipts WHERE operation_id = ?", (op,)))
    print(op, ",".join(b))
PY
}

step_E18() {
    local da db dc cfg pa pb ctx log i pal pid
    da="$HOME/e18a"
    db="$HOME/e18b"
    # sandbox_claude_prepare trusts one project (it writes .claude.json
    # whole): e18a; e18b's trust is added beside it. e18c's Claude gets its
    # trust from nhm spawn --trust-folder, newproj's path.
    dc="$HOME/e18c"
    mkdir -p "$da" "$db" "$dc" && git -C "$da" init -q && git -C "$db" init -q && git -C "$dc" init -q &&
        sandbox_claude_prepare "$da" >/dev/null &&
        jq --arg d "$db" '.projects[$d] = {hasTrustDialogAccepted: true}' "$CLAUDE_CONFIG_DIR/.claude.json" \
            >"$CLAUDE_CONFIG_DIR/.claude.json.e18" && mv -f "$CLAUDE_CONFIG_DIR/.claude.json.e18" "$CLAUDE_CONFIG_DIR/.claude.json" ||
        { echo "FAIL E18: the projects"; return; }
    herdr integration install claude >"$SANDBOX_EVIDENCE/herdr-integration.out" 2>&1 || true
    claude_guards
    nhm_owner || { echo "FAIL E18: nhm could not take the server over"; return; }

    # --- c: ensembles -----------------------------------------------------
    e18_json ensembles nhm ensemble list --json
    check "E18 c: nhm ensemble list shows ntm's presets" \
        jq -e '.result.presets | length > 0 and all(.mode_count > 0 and (.mode_codes | length) == .mode_count)' "$(e18_file ensembles)"
    e18_json modes nhm modes list --tier core --json
    check "E18 c: nhm modes list --tier core shows core modes only" \
        jq -e '[.. | objects | select(has("tier"))] as $m | ($m | length > 0) and ($m | all(.tier == "core"))' "$(e18_file modes)"

    # --- The plugin and its keys, through ACFS's path ---------------------
    check "E18: nhm's installer layout and ACFS's palette" e18_layout
    e18_json plugin-bind bash "$(e18_lib nhm_hooks.sh)" plugin bind
    check "E18: ACFS links nhm's plugin and binds its keys (nhm_hooks.sh plugin bind)" \
        test "$(cat "$SANDBOX_EVIDENCE/e18-plugin-bind.rc")" = 0
    e18_json plugin-status bash "$(e18_lib nhm_hooks.sh)" plugin status
    e18_json actions herdr plugin action list
    check "E18: herdr lists the plugin's palette, board and menu" \
        jq -e '[.result.actions[]? | select(.plugin_id == "nhm") | .action_id] as $a | ["palette", "board", "menu"] | all(. as $x | $a | index($x))' \
            "$(e18_file actions)"
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
    cp "$cfg" "$SANDBOX_EVIDENCE/e18-herdr-config.toml" 2>/dev/null
    check "E18: the server's config has one nhm block" \
        bash -c '[[ "$(grep -c "^# >>> nhm >>>" "$1")" == 1 && "$(grep -c "^# <<< nhm <<<" "$1")" == 1 ]]' _ "$cfg"
    # Each [[keys.command]] stanza: key, then command.
    check "E18: its keys are prefix+a (palette), prefix+d (board) and prefix+m (menu), once each" \
        bash -c 'got="$(sed -n "/^# >>> nhm >>>/,/^# <<< nhm <<</p" "$1" |
            awk -F" = " "/^key = /{k=\$2} /^command = /{print k, \$2}" | tr -d "\"" | sort | tr "\n" ,)"
            [[ "$got" == "prefix+a nhm.palette,prefix+d nhm.board,prefix+m nhm.menu," ]]' _ "$cfg"
    e18_json print-client nhm bind --print-client
    check "E18: nhm bind --print-client prints the block for a remote client" \
        bash -c 'grep -q "prefix+a" "$1" && grep -q "palette" "$1"' _ "$(e18_file print-client)"
    e18_json palette-list nhm palette --list --json
    check "E18: the palette lists fresh_review and default_new_agent" \
        jq -e '[.. | objects | select(has("key")) | .key] as $k | ($k | index("fresh_review")) and ($k | index("default_new_agent"))' \
            "$(e18_file palette-list)"

    # --- a: the palette, invoked as typed in a server pane -----------------
    (cd "$da" && nhm spawn e18a --cc=2 --prompt "say hi" --json) >"$(e18_file spawn-a)" 2>&1
    (cd "$db" && nhm spawn e18b --cc=1 --prompt "say hi" --json) >"$(e18_file spawn-b)" 2>&1
    pa="$(jq -r '.result.agents[0].pane_id // empty' "$(e18_file spawn-a)")"
    pb="$(jq -r '.result.agents[0].pane_id // empty' "$(e18_file spawn-b)")"
    check "E18 a: two projects open (e18a with two Claudes, e18b with one)" test -n "$pa" -a -n "$pb"
    [[ -n "$pa" && -n "$pb" ]] || return
    settle "$pa"
    settle "$pb"
    # Fails until nhm-za8: the sandbox's 40-column pane wraps Claude Code's
    # trust question, which nhm looks for on one line.
    (cd "$dc" && nhm spawn e18c --cc=1 --trust-folder --prompt "say hi" --json) >"$(e18_file spawn-c)" 2>&1
    check "E18: nhm spawn --trust-folder answers Claude's trust dialog in a narrow pane (nhm-za8)" \
        jq -e '.error == null and .result.agents[0].ready == true' "$(e18_file spawn-c)"
    e18_screen "$(jq -r '.result.agents[0].pane_id // "none"' "$(e18_file spawn-c)")" e18c-screen
    ctx="$(herdr pane get "$pa" 2>/dev/null | jq -c '.result.pane // {}')"
    echo "### the invoking pane: $ctx"
    e18_json panes-before herdr pane list
    herdr pane read "$pa" --source visible --lines 30 >"$SANDBOX_EVIDENCE/e18-invoking-screen.txt" 2>&1
    e18_json invoke env HERDR_PANE_ID="$pa" HERDR_WORKSPACE_ID="${pa%%:*}" \
        herdr plugin action invoke palette --plugin nhm
    check "E18 a: herdr runs the palette action with the pane's context" \
        jq -e --arg p "$pa" '.result.context.focused_pane_id == $p and .result.context.workspace_label == "e18a"' "$(e18_file invoke)"
    # The action's own run: its log entry, once it has finished.
    log="$(jq -r '.result.log.log_id // empty' "$(e18_file invoke)")"
    for i in $(seq 1 20); do
        herdr plugin log list --plugin nhm --limit 50 2>/dev/null |
            jq -c --arg id "$log" '.result.logs[]? | select(.log_id == $id)' >"$(e18_file action-log)"
        jq -e '.status != "running"' "$(e18_file action-log)" >/dev/null 2>&1 && break
        sleep 0.5
    done
    echo "### the palette action's run"
    cat "$(e18_file action-log)"
    check "E18 a: the action opens its popup (nhm ui palette exits 0, no error)" \
        jq -e '.status == "succeeded" and .exit_code == 0 and (.stderr // "") == ""' "$(e18_file action-log)"

    # --- a: the palette's flow, driven without a client --------------------
    # The popup has no client to show in, so the step opens the palette's
    # entrypoint as a tab of e18a, with the context the action hands it,
    # and drives it by its screen: fresh_review, then target 2 (one kind).
    ctx="$(jq -cn --arg s "$HERDR_SOCKET_PATH" --arg i "$(jq -r '.scope.instance_id // empty' "$(e18_file spawn-a)")" \
        --arg w "${pa%%:*}" --arg p "$pa" \
        '{version: 1, instance_id: $i, socket_path: $s, workspace_id: $w, workspace_label: "e18a", pane_id: $p,
          agent: "claude", invocation_source: "cli"}')"
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-before.txt"
    pal="$(e18_palette "${pa%%:*}" "$ctx")"
    check "E18 a: the palette opens with the captured context" e18_until "${pal:-none}" 'fresh_review|Fresh review'
    e18_screen "$pal" palette-list
    herdr pane send-text "$pal" "fresh" >/dev/null 2>&1
    sleep 1
    e18_screen "$pal" palette-filtered
    herdr pane send-keys "$pal" enter >/dev/null 2>&1
    # fzf's "send to>" list, or the Go palette's target keys.
    check "E18 a: fresh_review asks for its targets" e18_until "$pal" 'send to>|every claude agent|all agents|one kind'
    e18_screen "$pal" palette-targets
    herdr pane send-text "$pal" "2" >/dev/null 2>&1
    e18_until "$pal" '(submitted|sent|receipt|Sent|Submitted)' || true
    e18_screen "$pal" palette-result
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-after.txt"
    echo "### the palette's send"
    diff "$SANDBOX_EVIDENCE/e18-sends-before.txt" "$SANDBOX_EVIDENCE/e18-sends-after.txt"
    check "E18 a: target 2 sends fresh_review once, to e18a's two Claudes only" \
        bash -c 'new="$(comm -13 <(sort "$1") <(sort "$2"))"
            want="$(jq -r "[.result.agents[].binding_id] | sort | join(\",\")" "$3")"
            [[ "$(wc -l <<<"$new")" == 1 && "${new#* }" == "$want" ]]' \
            _ "$SANDBOX_EVIDENCE/e18-sends-before.txt" "$SANDBOX_EVIDENCE/e18-sends-after.txt" "$(e18_file spawn-a)"
    herdr pane send-keys "$pal" esc >/dev/null 2>&1
    # Esc on a fresh palette sends nothing.
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-esc-before.txt"
    pal="$(e18_palette "${pa%%:*}" "$ctx")"
    check "E18 a: a second palette opens" e18_until "${pal:-none}" 'fresh_review|Fresh review'
    herdr pane send-keys "${pal:-none}" esc >/dev/null 2>&1
    sleep 2
    e18_screen "${pal:-none}" palette-esc
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-esc-after.txt"
    check "E18 a: Esc closes it and sends nothing" \
        bash -c '[[ -n "$1" ]] && ! herdr pane get "$1" >/dev/null 2>&1 && cmp -s "$2" "$3"' \
            _ "$pal" "$SANDBOX_EVIDENCE/e18-sends-esc-before.txt" "$SANDBOX_EVIDENCE/e18-sends-esc-after.txt"
    # The palette acts on the captured workspace, not the one its pane is
    # in: opened in e18b's workspace with e18a's context, target 2 reaches
    # e18a's Claudes.
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-cross-before.txt"
    pal="$(e18_palette "${pb%%:*}" "$ctx")"
    e18_until "${pal:-none}" 'fresh_review|Fresh' || true
    pid="$(pgrep -nf 'ui palette-popup')"
    { [[ -n "$pid" ]] && tr '\0' '\n' <"/proc/$pid/environ" | grep -E '^(NHM_CONTEXT|HERDR_PLUGIN_CONTEXT_JSON|HERDR_WORKSPACE_ID|HERDR_PANE_ID)='; } \
        >"$SANDBOX_EVIDENCE/e18-palette-env.txt" 2>&1
    echo "### the palette process's context environment"
    cat "$SANDBOX_EVIDENCE/e18-palette-env.txt"
    herdr pane send-text "${pal:-none}" "fresh" >/dev/null 2>&1
    sleep 1
    herdr pane send-keys "${pal:-none}" enter >/dev/null 2>&1
    e18_until "${pal:-none}" 'send to>|every claude agent|all agents|one kind' || true
    e18_screen "${pal:-none}" palette-cross-targets
    herdr pane send-text "${pal:-none}" "2" >/dev/null 2>&1
    e18_until "${pal:-none}" '(submitted|Submitted)' || true
    e18_screen "${pal:-none}" palette-cross-result
    herdr pane send-keys "${pal:-none}" esc >/dev/null 2>&1
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-cross-after.txt"
    check "E18 a: opened in e18b's workspace with e18a's context, the palette sends to e18a's Claudes" \
        bash -c 'new="$(comm -13 <(sort "$1") <(sort "$2"))"
            want="$(jq -r "[.result.agents[].binding_id] | sort | join(\",\")" "$3")"
            [[ "$(wc -l <<<"$new")" == 1 && "${new#* }" == "$want" ]]' \
            _ "$SANDBOX_EVIDENCE/e18-sends-cross-before.txt" "$SANDBOX_EVIDENCE/e18-sends-cross-after.txt" "$(e18_file spawn-a)"
    # A context without a workspace: the Go palette asks for one first
    # (ntm's session selector), with both projects; Esc there sends
    # nothing. v0.1.12's default palette is the fzf one, which takes its
    # pane's workspace instead; the Go palette is the default after it
    # (nhm-qbi.12), and [ui] palette = "go" selects it before.
    mkdir -p "$HOME/.config/nhm" && printf '\n[ui]\npalette = "go"\n' >>"$HOME/.config/nhm/config.toml"
    pal="$(e18_palette "${pa%%:*}" "$(jq -c 'del(.workspace_id, .workspace_label, .pane_id, .agent)' <<<"$ctx")")"
    check "E18 b: a missing context opens the picker, with both projects" \
        bash -c 'for i in $(seq 1 40); do
                s="$(herdr pane read "$1" --source visible --lines 60 2>/dev/null)"
                grep -q e18a <<<"$s" && grep -q e18b <<<"$s" && exit 0
                sleep 0.5
            done; exit 1' _ "${pal:-none}"
    e18_screen "${pal:-none}" palette-picker
    herdr pane send-keys "${pal:-none}" esc >/dev/null 2>&1
    sleep 2
    e18_sends >"$SANDBOX_EVIDENCE/e18-sends-picker-after.txt"
    check "E18 b: Esc at the picker sends nothing" \
        cmp -s "$SANDBOX_EVIDENCE/e18-sends-cross-after.txt" "$SANDBOX_EVIDENCE/e18-sends-picker-after.txt"
    e18_json panes-after herdr pane list
    manual "E18 a: the palette's popup shows in the invoking client, and its keys reach it there (needs a herdr client)"
    manual "E18 b: prefix+d opens the board over the attention feed without changing either client's Agent view; nhm spawn S --interactive runs its prompts in a popup (needs a herdr client)"
    manual "E18: from the Mac, the verified key path (herdr --remote) reaches the palette; no Mac keybinding was installed before the evidence"
}
