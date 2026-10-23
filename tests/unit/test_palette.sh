#!/usr/bin/env bash
# ============================================================
# scripts/lib/palette.sh (acfs palette) against a STUB herdr, a STUB fzf
# and a STUB herdr_agents.sh
#
# Proves which palette files it reads and in which order, how pins,
# favorites and recents are kept, which rows each step offers, and which
# `acfs agents send` call a choice turns into. Nothing here prompts a
# real agent.
#
# Usage: bash tests/unit/test_palette.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PALETTE="$ROOT/scripts/lib/palette.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-palette.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# ------------------------------------------------------------
# Palette files: a project file in a git repo, a user file and the
# installed one, with keys that overlap.
# ------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/stub" "$WORK/repo/sub" "$WORK/config/acfs" "$WORK/acfs/onboard/docs/ntm" "$WORK/state"
git -C "$WORK/repo" init -q
cat >"$WORK/repo/command_palette.md" <<'EOF'
# Project palette

## Project

### fresh_review | Project Review
Review it the project's way.
EOF
cat >"$WORK/config/acfs/command_palette.md" <<'EOF'
## Mine

### my_prompt | My Prompt
Do my thing for {{agent}}.
EOF
cat >"$WORK/acfs/onboard/docs/ntm/command_palette.md" <<'EOF'
# Command Palette
#   ## Category Name

## Analysis & Review

### fresh_review | Fresh Review
Read your new code with fresh eyes.

### check_other_agents_work | Check Other Agents Work

Review the others' code.

Second paragraph.


## Coding

### fix_bug | Fix Bug
Fix the bug.
### bare_key
No label, no category change.
EOF

export ACFS_HOME="$WORK/acfs"
export XDG_CONFIG_HOME="$WORK/config"
export ACFS_PALETTE_STATE_DIR="$WORK/state"
export STUB_DIR="$WORK/stub"
export PATH="$WORK/bin:$PATH"
unset ACFS_PALETTE_FILE ACFS_PALETTE_CWD HERDR_ACTIVE_PANE_CWD HERDR_ACTIVE_WORKSPACE_ID HERDR_WORKSPACE_ID HERDR_PANE_ID

OUT="" ERR="" RC=0
run_palette() {
    local err_file="$WORK/err"
    RC=0
    OUT="$(cd "${RUN_CWD:-$WORK/repo/sub}" && bash "$PALETTE" "$@" 2>"$err_file")" || RC=$?
    ERR="$(cat "$err_file")"
}

# ------------------------------------------------------------
# palette files
# ------------------------------------------------------------
echo "palette files:"
run_palette --list
check "--list reads the git root's file, the user's and the installed one, first key wins" \
    bash -c '[[ "$1" -eq 0 ]] && [[ "$(cut -f1,2,3 <<<"$2")" == "$3" ]]' _ "$RC" "$OUT" \
    "$(printf '%s\t%s\t%s\n' \
        fresh_review "Project Review" Project \
        my_prompt "My Prompt" Mine \
        check_other_agents_work "Check Other Agents Work" "Analysis & Review" \
        fix_bug "Fix Bug" Coding \
        bare_key bare_key Coding)"
check "--list names the file each prompt comes from" \
    bash -c '[[ "$(sed -n 1p <<<"$1" | cut -f4)" == "$2" ]]' _ "$OUT" "$WORK/repo/command_palette.md"

run_palette --list --json
check "--list --json gives key, label, category and file" \
    bash -c '[[ "$(jq -r ".[3] | [.key, .label, .category] | join(\"|\")" <<<"$1")" == "fix_bug|Fix Bug|Coding" && "$(jq length <<<"$1")" == 5 ]]' _ "$OUT"

run_palette --show check_other_agents_work
check "--show prints the text, blank lines inside kept, outer ones dropped" \
    bash -c '[[ "$1" -eq 0 && "$2" == "$3" ]]' _ "$RC" "$OUT" "$(printf 'Review the others'"'"' code.\n\nSecond paragraph.')"

run_palette --show fresh_review
check "--show takes a key from the first file that has it" \
    bash -c '[[ "$1" == "Review it the project'"'"'s way." ]]' _ "$OUT"

run_palette --show no_such_key
check "--show fails for a key no file has" \
    bash -c '[[ "$1" -ne 0 ]] && grep -qF "no palette prompt has the key no_such_key" <<<"$2"' _ "$RC" "$ERR"

run_palette --list --file "$WORK/config/acfs/command_palette.md"
check "--file reads that file alone" \
    bash -c '[[ "$(cut -f1 <<<"$1")" == my_prompt ]]' _ "$OUT"

run_palette --file "$WORK/nope.md" --list
check "--file refuses a file it cannot read" \
    bash -c '[[ "$1" -ne 0 ]] && grep -qF "no such readable file" <<<"$2"' _ "$RC" "$ERR"

RUN_CWD="$WORK" run_palette --list
check "outside the project, its file is not read" \
    bash -c '[[ "$(grep "^fresh_review	" <<<"$1" | cut -f2)" == "Fresh Review" ]]' _ "$OUT"

HERDR_ACTIVE_PANE_CWD="$WORK/repo" RUN_CWD="$WORK" run_palette --list
check "a herdr popup reads the files of the pane it was opened over" \
    bash -c '[[ "$(sed -n 1p <<<"$1" | cut -f2)" == "Project Review" ]]' _ "$OUT"

# ------------------------------------------------------------
# pins, favorites and recents
# ------------------------------------------------------------
echo "pins, favorites and recents:"
rows_keys() { cut -f1 <<<"$OUT" | paste -sd ' '; }

run_palette __rows
check "rows follow file order with nothing pinned or recent" \
    bash -c '[[ "$1" == "fresh_review my_prompt check_other_agents_work fix_bug bare_key" ]]' _ "$(rows_keys)"

run_palette __toggle pins fix_bug
run_palette __rows
check "a pinned prompt comes first" \
    bash -c '[[ "$1" == "fix_bug fresh_review my_prompt check_other_agents_work bare_key" ]]' _ "$(rows_keys)"
check "pinning makes a favorite too" grep -qxF fix_bug "$WORK/state/favorites"

run_palette __toggle favorites fix_bug
check "unfavoriting a pinned prompt unpins it" \
    bash -c '! grep -qxF fix_bug "$1/pins" && ! grep -qxF fix_bug "$1/favorites"' _ "$WORK/state"

run_palette __toggle pins 'bad key;rm'
check "a key that is not a palette key is never written" \
    bash -c '! grep -qF "bad key" "$1/pins" 2>/dev/null' _ "$WORK/state"

(
    # shellcheck source=/dev/null
    source "$PALETTE"
    for key in k1 k2 k3 k4 k5 k6 k7 k8 k9 bare_key k3; do palette_record_recent "$key"; done
)
check "recents keep the newest 8, newest first, each once" \
    bash -c '[[ "$(paste -sd " " "$1/recents")" == "k3 bare_key k9 k8 k7 k6 k5 k4" ]]' _ "$WORK/state"

run_palette __rows
check "a recent prompt comes after the pinned ones, before the rest" \
    bash -c '[[ "$1" == "bare_key fresh_review my_prompt check_other_agents_work fix_bug" ]]' _ "$(rows_keys)"
check "rows say which section each prompt is in" \
    bash -c 'sed -n 1p <<<"$1" | sed "s/\x1b\[[0-9;]*m//g" | grep -q "recent .*bare_key"' _ "$OUT"

run_palette __preview my_prompt
check "the preview shows label, category, file, placeholders and text" \
    bash -c 't="$(sed "s/\x1b\[[0-9;]*m//g" <<<"$1")"; grep -qxF "My Prompt" <<<"$t" && grep -qF "Mine · my_prompt" <<<"$t" \
        && grep -qxF "$2" <<<"$t" && grep -qF "filled in per agent: {{agent}}" <<<"$t" && grep -qxF "Do my thing for {{agent}}." <<<"$t"' \
    _ "$OUT" "$WORK/config/acfs/command_palette.md"

# ------------------------------------------------------------
# target step, over a stub herdr
# ------------------------------------------------------------
echo "target step:"
cat >"$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >>"$STUB_DIR/calls"
case "$1 $2" in
    "agent list")
        cat <<'JSON'
{"id":"cli:agent:list","result":{"agents":[
 {"agent":"codex","agent_status":"working","name":"bluelake","pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","terminal_title_stripped":"Bead acfs-1"},
 {"agent":"claude","agent_status":"blocked","name":"alphafox","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"},
 {"agent":"claude","agent_status":"done","pane_id":"w1:p3","tab_id":"w1:t3","workspace_id":"w1"},
 {"agent":"zed","agent_status":"idle","name":"oddone","pane_id":"w1:p4","tab_id":"w1:t4","workspace_id":"w1"},
 {"agent":"claude","agent_status":"done","name":"farfox","pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2"}]}}
JSON
        ;;
    "agent read") printf 'screen of %s\n' "$3" ;;
    # The issues herdr 0.9.3 reports: a key it can't parse, a key one of its
    # default bindings already has (here f8, unquoted), and invalid TOML
    # (an inline keys.command next to a [[keys.command]] table), after which
    # herdr ignores the whole file. A "stale = true" line stands for an
    # issue the file already had.
    "config check")
        issues=()
        grep -q '"bogus' "$HERDR_CONFIG_PATH" \
            && issues+=('invalid keybinding: keys.command[0].key = "bogus+zz"; disabling binding')
        grep -qxF 'key = "f8"' "$HERDR_CONFIG_PATH" \
            && issues+=('f8: kept keys.toggle_sidebar, disabled keys.command[0].key')
        grep -q '^command = \[' "$HERDR_CONFIG_PATH" && grep -qxF '[[keys.command]]' "$HERDR_CONFIG_PATH" \
            && issues+=('config parse error: TOML parse error at line 4, column 1' 'duplicate key `command` in table `keys`' '; using defaults')
        grep -qxF 'stale = true' "$HERDR_CONFIG_PATH" \
            && issues+=('unknown field `stale`')
        if [[ ${#issues[@]} -eq 0 ]]; then
            echo 'config: ok'
        else
            echo 'config: issues found'
            printf '%s\n' "${issues[@]}"
            exit 1
        fi
        ;;
    "server reload-config") [[ ! -e "$STUB_DIR/no_server" ]] ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/herdr"

run_palette __target-rows w1
strip() { sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
check "groups come first: every agent, then each kind (claude, codex, then the rest)" \
    bash -c '[[ "$(cut -f1,2 <<<"$1" | head -4 | paste -sd " ")" == "group	all group	kind:claude group	kind:codex group	kind:zed" ]]' _ "$OUT"
check "groups are numbered and counted" \
    bash -c 's="$(sed "s/\x1b\[[0-9;]*m//g" <<<"$1")"; grep -qF "1  every agent in this workspace (4)" <<<"$s" && grep -qF "2  every claude agent (2)" <<<"$s"' _ "$OUT"
check "each agent of the workspace follows with its pane, name and status" \
    bash -c '[[ "$(grep "^agent" <<<"$1" | cut -f2,3 | paste -sd " ")" == "w1:p2	bluelake w1:p1	alphafox w1:p3	- w1:p4	oddone" ]] \
        && grep -qF "▲ blocked" <<<"$1" && grep -qF "(unnamed)" <<<"$1"' _ "$(strip "$OUT")"

run_palette __target-rows ""
check "with no workspace, groups say every workspace and list every agent" \
    bash -c 'grep -qF "every agent in every workspace (5)" <<<"$1"' _ "$(strip "$OUT")"

run_palette __target-preview agent w1:p2 w1
check "an agent's preview is its screen" bash -c '[[ "$1" == "screen of w1:p2" ]]' _ "$OUT"
run_palette __target-preview group kind:claude w1
check "a group's preview lists its agents and warns about blocked and unnamed ones" \
    bash -c 'grep -qF "alphafox" <<<"$1" && grep -qF "Blocked agents are skipped" <<<"$1" && grep -qF "Unnamed agents" <<<"$1" && ! grep -qF bluelake <<<"$1"' _ "$OUT"

# The rows fzf would print back, taken from the rows the step offers.
run_palette __target-rows w1
TARGET_ROWS="$OUT"
rows() {
    local id
    for id; do grep -F "	$id	" <<<"$TARGET_ROWS"; done
}
flags() {
    # shellcheck source=/dev/null
    (source "$PALETTE"; palette_send_flags "$1" "$2" 2>"$WORK/flags_err") | paste -sd ' '
}
check "one group row maps to --workspace and --all" \
    bash -c '[[ "$1" == "--workspace w1 --all" ]]' _ "$(flags w1 "$(rows all)")"
check "one kind row maps to --kind" \
    bash -c '[[ "$1" == "--workspace w1 --kind codex" ]]' _ "$(flags w1 "$(rows kind:codex)")"
check "with no workspace, --all reaches every workspace" \
    bash -c '[[ "$1" == "--all" ]]' _ "$(flags "" "$(rows all)")"
check "marked agents map to --name each, sorted and once" \
    bash -c '[[ "$1" == "--workspace w1 --name alphafox --name bluelake" ]]' _ "$(flags w1 "$(rows w1:p2 w1:p1 w1:p2)")"
check "a group with marked agents is expanded to names, since send ANDs --kind with --name" \
    bash -c '[[ "$1" == "--workspace w1 --name alphafox --name bluelake" ]]' _ "$(flags w1 "$(rows kind:claude w1:p2)")"
check "an unnamed agent is skipped and said so, never sent its row's text as a name" \
    bash -c '[[ -z "$1" ]] && grep -qF "skipped pane w1:p3" "$2"' _ "$(flags w1 "$(rows w1:p3)")" "$WORK/flags_err"
check "with an unnamed agent marked too, only the named ones get it" \
    bash -c '[[ "$1" == "--workspace w1 --name oddone" ]]' _ "$(flags w1 "$(rows w1:p3 w1:p4)")"

# ------------------------------------------------------------
# herdr key, in a scratch config.toml
# ------------------------------------------------------------
echo "herdr key:"
export HERDR_CONFIG_PATH="$WORK/herdr/config.toml"
mkdir -p "$WORK/herdr"
printf 'onboarding = false\n\n[keys]\nzoom = "prefix+z"\n\n[theme]\nname = "catppuccin"\n\n\n' >"$HERDR_CONFIG_PATH"
ORIGINAL_CONFIG="$(cat "$HERDR_CONFIG_PATH")"
block_lines() { awk '/^# >>> acfs palette >>>/,/^# <<< acfs palette <<</' "$HERDR_CONFIG_PATH"; }

: >"$STUB_DIR/calls"
run_palette bind --auto
check "bind --auto appends a popup on prefix+a that runs this script, after one blank line" \
    bash -c '[[ "$1" -eq 0 && "$(cat "$2")" == "$3"$'"'"'\n\n'"'"'"$4" ]] && grep -qxF "key = \"prefix+a\"" "$2" && grep -qxF "type = \"popup\"" "$2" \
        && grep -qxF "command = \"bash '"'"'$5'"'"'\"" "$2"' \
    _ "$RC" "$HERDR_CONFIG_PATH" "$ORIGINAL_CONFIG" "$(block_lines)" "$PALETTE"
check "bind asks herdr to check the result, then reloads the running server" \
    bash -c 'grep -qx "herdr config check" "$1" && grep -qx "herdr server reload-config" "$1" && grep -qF "reloaded the running herdr server" <<<"$2"' \
    _ "$STUB_DIR/calls" "$ERR"

BOUND_CONFIG="$(cat "$HERDR_CONFIG_PATH")"
run_palette bind --auto --key prefix+space
check "bind --auto leaves a config that has the block alone" \
    bash -c '[[ "$1" -eq 0 && "$(cat "$2")" == "$3" ]]' _ "$RC" "$HERDR_CONFIG_PATH" "$BOUND_CONFIG"

touch "$STUB_DIR/no_server"
run_palette bind --key prefix+space
check "bind --key rebinds in place, the rest of the file unchanged" \
    bash -c '[[ "$1" -eq 0 && "$(grep -c "acfs palette >>>" "$2")" == 1 ]] && grep -qxF "key = \"prefix+space\"" "$2" \
        && ! grep -qxF "key = \"prefix+a\"" "$2" && [[ "$(head -7 "$2")" == "$3" ]]' _ "$RC" "$HERDR_CONFIG_PATH" "$ORIGINAL_CONFIG"
check "with no herdr server running, bind says how to reload" \
    bash -c 'grep -qF "herdr server reload-config" <<<"$1"' _ "$ERR"
rm -f "$STUB_DIR/no_server"

run_palette bind --key prefix+Z --no-reload
check "bind refuses a key the config already uses, ignoring case" \
    bash -c '[[ "$1" -ne 0 ]] && grep -qF "already uses prefix+z" <<<"$2" && grep -qxF "key = \"prefix+space\"" "$3"' _ "$RC" "$ERR" "$HERDR_CONFIG_PATH"

run_palette bind --key bogus+zz --no-reload
check "bind leaves the file as it was when herdr calls the key invalid" \
    bash -c '[[ "$1" -ne 0 ]] && grep -qF "herdr would not accept" <<<"$2" && grep -qF "bogus+zz" <<<"$2" && grep -qxF "key = \"prefix+space\"" "$3" \
        && [[ -z "$(find "$(dirname "$3")" -name ".config.toml.acfs-palette.*")" ]]' _ "$RC" "$ERR" "$HERDR_CONFIG_PATH"

run_palette bind --key 'prefix+a"; rm' --no-reload
check "bind refuses a key that is not herdr key syntax" \
    bash -c '[[ "$1" -ne 0 ]] && grep -qF "not a herdr key" <<<"$2"' _ "$RC" "$ERR"

run_palette unbind --no-reload
check "unbind leaves an empty block, the rest of the file unchanged" \
    bash -c '[[ "$1" -eq 0 && "$(block_count=$(grep -c "^\[\[keys.command\]\]" "$2"); echo "$block_count")" == 0 ]] \
        && grep -qF "unbound by" "$2" && [[ "$(head -7 "$2")" == "$3" ]]' _ "$RC" "$HERDR_CONFIG_PATH" "$ORIGINAL_CONFIG"
run_palette bind --auto --no-reload
check "after unbind, bind --auto (acfs update) leaves it unbound" \
    bash -c '! grep -q "^\[\[keys.command\]\]" "$1"' _ "$HERDR_CONFIG_PATH"
run_palette bind --no-reload
check "an explicit bind after unbind binds prefix+a again" grep -qxF 'key = "prefix+a"' "$HERDR_CONFIG_PATH"

printf '[[keys.command]]\nkey = "prefix+a"\ntype = "popup"\ncommand = "lazygit"\n' >"$HERDR_CONFIG_PATH"
run_palette bind --auto --no-reload
check "bind --auto binds nothing over a key the user has, and says so" \
    bash -c '[[ "$1" -eq 0 && "$(grep -c "^\[\[keys.command\]\]" "$2")" == 1 ]] && grep -qF "already uses prefix+a" <<<"$3"' _ "$RC" "$HERDR_CONFIG_PATH" "$ERR"

printf '[[keys.command]]\nkey = "f7"\ntype = "popup"\ncommand = "acfs palette"\n' >"$HERDR_CONFIG_PATH"
run_palette bind --auto --no-reload
check "bind --auto leaves a user's own palette binding alone" \
    bash -c '[[ "$1" -eq 0 ]] && ! grep -qF "acfs palette >>>" "$2"' _ "$RC" "$HERDR_CONFIG_PATH"

printf '[keys]\nzoom = ["prefix+z", "Prefix+A"]\n' >"$HERDR_CONFIG_PATH"
run_palette bind --auto --no-reload
check "bind --auto binds nothing over a key in an array value" \
    bash -c '[[ "$1" -eq 0 ]] && ! grep -qF "acfs palette >>>" "$2" && grep -qF "already uses prefix+a" <<<"$3"' _ "$RC" "$HERDR_CONFIG_PATH" "$ERR"
printf '[keys]\nzoom = [\n  "prefix+z",\n  "prefix+a",\n]\n' >"$HERDR_CONFIG_PATH"
run_palette bind --no-reload
check "bind refuses a key in an array value over several lines" \
    bash -c '[[ "$1" -ne 0 ]] && ! grep -qF "acfs palette >>>" "$2" && grep -qF "already uses prefix+a" <<<"$3"' _ "$RC" "$HERDR_CONFIG_PATH" "$ERR"

printf '[keys]\nzoom = "prefix+z"\n' >"$HERDR_CONFIG_PATH"
BEFORE="$(cat "$HERDR_CONFIG_PATH")"
run_palette bind --key f8 --no-reload
check "bind leaves the file as it was when herdr reports the key in conflict, unquoted" \
    bash -c '[[ "$1" -ne 0 && "$(cat "$2")" == "$3" ]] && grep -qF "f8: kept keys.toggle_sidebar" <<<"$4" \
        && [[ -z "$(find "$(dirname "$2")" -name ".config.toml.acfs-palette.*")" ]]' _ "$RC" "$HERDR_CONFIG_PATH" "$BEFORE" "$ERR"

printf '[keys]\nzoom = "prefix+z"\ncommand = [{ key = "f7", type = "popup", command = "lazygit" }]\n' >"$HERDR_CONFIG_PATH"
BEFORE="$(cat "$HERDR_CONFIG_PATH")"
run_palette bind --auto --no-reload
check "bind leaves the file as it was when the result would not parse" \
    bash -c '[[ "$1" -ne 0 && "$(cat "$2")" == "$3" ]] && grep -qF "TOML parse error" <<<"$4"' _ "$RC" "$HERDR_CONFIG_PATH" "$BEFORE" "$ERR"

printf 'stale = true\n' >"$HERDR_CONFIG_PATH"
run_palette bind --no-reload
check "an issue the file already had doesn't stop bind" \
    bash -c '[[ "$1" -eq 0 ]] && grep -qxF "key = \"prefix+a\"" "$2"' _ "$RC" "$HERDR_CONFIG_PATH"

rm -f "$HERDR_CONFIG_PATH"
mkdir -p "$WORK/dot"
printf '[keys]\nzoom = "prefix+z"\n' >"$WORK/dot/herdr.toml"
chmod 640 "$WORK/dot/herdr.toml"
ln -s "$WORK/dot/herdr.toml" "$HERDR_CONFIG_PATH"
run_palette bind --no-reload
check "a symlinked config stays a symlink; its target gets the block and keeps its mode" \
    bash -c '[[ "$1" -eq 0 && -L "$2" && "$(readlink "$2")" == "$3" && "$(stat -c %a "$3")" == 640 ]] \
        && grep -qxF "key = \"prefix+a\"" "$3" && [[ -z "$(find "$(dirname "$3")" "$(dirname "$2")" -name ".config.toml.acfs-palette.*")" ]]' \
    _ "$RC" "$HERDR_CONFIG_PATH" "$WORK/dot/herdr.toml"
check "bind says how a herdr --remote client gets the key" \
    bash -c 'grep -qF -- "--remote-keybindings server" <<<"$1"' _ "$ERR"
rm -f "$HERDR_CONFIG_PATH" "$WORK/dot/herdr.toml"
rmdir "$WORK/dot"

printf '# >>> acfs palette >>> managed by `acfs palette bind`\n[[keys.command]]\nkey = "prefix+a"\n\n[keys]\nzoom = "ctrl+z"\n' >"$HERDR_CONFIG_PATH"
BEFORE="$(cat "$HERDR_CONFIG_PATH")"
run_palette unbind --no-reload
check "unbind refuses a block with no end marker, and deletes nothing" \
    bash -c '[[ "$1" -ne 0 && "$(cat "$2")" == "$3" ]] && grep -qF "no '"'"'# <<< acfs palette <<<'"'"'" <<<"$4"' \
    _ "$RC" "$HERDR_CONFIG_PATH" "$BEFORE" "$ERR"
run_palette bind --key f9 --no-reload
check "bind refuses a block with no end marker, and deletes nothing" \
    bash -c '[[ "$1" -ne 0 && "$(cat "$2")" == "$3" ]]' _ "$RC" "$HERDR_CONFIG_PATH" "$BEFORE"

rm -f "$HERDR_CONFIG_PATH"
rmdir "$WORK/herdr"
run_palette bind --auto --no-reload
check "with no config yet, bind --auto writes one holding only the block" \
    bash -c '[[ "$1" -eq 0 && "$(head -1 "$2")" == "# >>> acfs palette >>>"* ]]' _ "$RC" "$HERDR_CONFIG_PATH"

run_palette bind --dry-run --key prefix+space
check "--dry-run prints the block and writes nothing" \
    bash -c 'grep -qF "Would write to" <<<"$1" && ! grep -qF "prefix+space" "$2"' _ "$OUT" "$HERDR_CONFIG_PATH"

mv "$WORK/bin/herdr" "$WORK/bin/herdr.off"
rm -f "$HERDR_CONFIG_PATH"
PATH="$WORK/bin:/usr/bin:/bin" run_palette bind --auto
check "without herdr, bind --auto writes nothing" \
    bash -c '[[ "$1" -eq 0 && ! -e "$2" ]] && grep -qF "herdr is not installed" <<<"$3"' _ "$RC" "$HERDR_CONFIG_PATH" "$ERR"
mv "$WORK/bin/herdr.off" "$WORK/bin/herdr"
unset HERDR_CONFIG_PATH

# ------------------------------------------------------------
# the whole menu, over a stub fzf and a stub send
# ------------------------------------------------------------
echo "menu:"
cat >"$WORK/bin/fzf" <<'STUB'
#!/usr/bin/env bash
# Answers each step from the next line of $STUB_DIR/fzf_script:
#   <step> <exit status> <expect key or -> <grep -E pattern for the rows to pick>
# and logs the rows it was offered.
rows="$(cat)"
step=prompt
for arg; do [[ "$arg" == "--prompt=send to> " ]] && step=target; done
printf '%s\n' "$rows" >"$STUB_DIR/offered_$step"
n=$(( $(cat "$STUB_DIR/fzf_n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/fzf_n"
read -r want status key pattern < <(sed -n "${n}p" "$STUB_DIR/fzf_script")
[[ "$want" == "$step" ]] || { echo "stub fzf: expected step $want, got $step" >&2; exit 2; }
[[ "$step" == target ]] || { [[ "$key" == - ]] && echo || echo "$key"; }
[[ -z "$pattern" ]] || grep -E -- "$pattern" <<<"$rows" || true
exit "$status"
STUB
cat >"$WORK/bin/send_stub" <<'STUB'
#!/usr/bin/env bash
# `owner` says who drives the agents: STUB_OWNER, by default the Bash.
if [[ "${1:-}" == owner ]]; then echo "${STUB_OWNER:-acfs-bash}"; exit 0; fi
printf '%s\n' "$*" >>"$STUB_DIR/sends"
for arg; do [[ -f "$arg" ]] && cp "$arg" "$STUB_DIR/sent_text"; done
exit "$(cat "$STUB_DIR/send_status" 2>/dev/null || echo 0)"
STUB
cat >"$WORK/bin/editor_stub" <<'STUB'
#!/usr/bin/env bash
printf 'edited line\n' >>"$1"
STUB
chmod +x "$WORK/bin/fzf" "$WORK/bin/send_stub" "$WORK/bin/editor_stub"

menu_case() {
    rm -f "$STUB_DIR/fzf_n" "$STUB_DIR/sends" "$STUB_DIR/sent_text" "$STUB_DIR/send_status" "$STUB_DIR/offered_"*
    printf '%s\n' "$@" >"$STUB_DIR/fzf_script"
}
run_menu() {
    ACFS_PALETTE_ASSUME_TTY=1 ACFS_PALETTE_AGENTS_SCRIPT="$WORK/bin/send_stub" EDITOR="$WORK/bin/editor_stub" \
        HERDR_ACTIVE_WORKSPACE_ID=w1 run_palette "$@" </dev/null
}

menu_case "prompt 0 - ^fix_bug" "target 0 - ^group	kind:claude"
run_menu
check "enter, then a group: sends the prompt's text to that kind in this workspace" \
    bash -c '[[ "$1" -eq 0 && "$(cat "$2/sends")" == "send --workspace w1 --kind claude --template "* && "$(cat "$2/sent_text")" == "Fix the bug." ]]' _ "$RC" "$STUB_DIR"
check "a sent prompt becomes the newest recent" bash -c '[[ "$(head -1 "$1/recents")" == fix_bug ]]' _ "$WORK/state"

menu_case "prompt 0 ctrl-e ^my_prompt" "target 0 - ^agent	w1:p(1|2)	"
run_menu
check "ctrl-e edits the text first, and marked agents get it by name" \
    bash -c '[[ "$(cat "$2/sends")" == "send --workspace w1 --name alphafox --name bluelake --template "* \
        && "$(cat "$2/sent_text")" == "$(printf "Do my thing for {{agent}}.\nedited line")" ]]' _ "$RC" "$STUB_DIR"

menu_case "prompt 1 ctrl-n" "target 0 - ^group	all"
run_menu
check "ctrl-n sends a new message, even with no prompt matching, and records no recent" \
    bash -c '[[ "$(cat "$2/sends")" == "send --workspace w1 --all --template "* && "$(cat "$2/sent_text")" == "edited line" \
        && "$(head -1 "$3/recents")" == my_prompt ]]' _ "$RC" "$STUB_DIR" "$WORK/state"

menu_case "prompt 0 - ^fresh_review" "target 130 -" "prompt 130 -"
run_menu
check "esc on the targets goes back to the prompts; esc there closes without sending" \
    bash -c '[[ "$1" -eq 0 && ! -e "$2/sends" && "$(cat "$2/fzf_n")" == 3 ]]' _ "$RC" "$STUB_DIR"

menu_case "prompt 0 - ^fix_bug" "target 0 - ^group	all"
echo 1 >"$STUB_DIR/send_status"
run_menu
check "a failed send is the palette's status, and records no recent" \
    bash -c '[[ "$1" -eq 1 && "$(head -1 "$2/recents")" == my_prompt ]]' _ "$RC" "$WORK/state"

# nhm: records its arguments and the directory nhm-palette is told to use.
cat >"$WORK/bin/nhm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/nhm_calls"
printf '%s\n' "${NHM_PALETTE_CWD:-}" >"$STUB_DIR/nhm_cwd"
STUB
chmod +x "$WORK/bin/nhm"

menu_case "prompt 0 - ^fix_bug" "target 0 - ^group	all"
rm -f "$STUB_DIR/nhm_calls" "$STUB_DIR/nhm_cwd"
STUB_OWNER=nhm run_menu
check "nhm owns the server: the palette is nhm's, for this workspace" \
    bash -c '[[ "$1" -eq 0 && "$(cat "$2/nhm_calls")" == "palette --workspace w1" ]]' _ "$RC" "$STUB_DIR"
check "nhm owns the server: nothing goes through acfs agents send, and no menu opens here" \
    bash -c '[[ ! -e "$1/sends" && ! -e "$1/fzf_n" ]]' _ "$STUB_DIR"
check "nhm owns the server: nhm-palette reads the files of the directory the palette was opened in" \
    bash -c '[[ "$(cat "$1/nhm_cwd")" == "$2" ]]' _ "$STUB_DIR" "$WORK/repo/sub"
check "nhm owns the server: a ~/.config/acfs palette gets a note to move it" \
    grep -qF "reads ~/.config/nhm/command_palette.md, not ~/.config/acfs/command_palette.md" <<<"$ERR"
rm -f "$STUB_DIR/nhm_calls"
STUB_OWNER=nhm run_menu --file "$WORK/repo/command_palette.md"
check "nhm owns the server: --file carries over" \
    bash -c '[[ "$(cat "$1/nhm_calls")" == "palette --workspace w1 --file $2" ]]' _ "$STUB_DIR" "$WORK/repo/command_palette.md"
check "nhm owns the server: with --file, no note about ~/.config/acfs" \
    bash -c '! grep -qF "~/.config/acfs/command_palette.md" <<<"$1"' _ "$ERR"
rm -f "$STUB_DIR/nhm_calls"
NHM_BIN="$WORK/nowhere/nhm" STUB_OWNER=nhm run_menu
check "nhm owns the server but isn't installed: refuses, naming nhm" \
    bash -c '[[ "$1" -ne 0 && ! -e "$3/nhm_calls" && ! -e "$3/sends" ]] && grep -qF "nhm isn'"'"'t on PATH" <<<"$2"' _ "$RC" "$ERR" "$STUB_DIR"
menu_case "prompt 0 - ^fix_bug" "target 0 - ^group	all"
rm -f "$STUB_DIR/nhm_calls"
run_menu
check "the Bash drives the agents: the palette sends itself, and nhm isn't called" \
    bash -c '[[ "$1" -eq 0 && "$(cat "$2/sends")" == "send --workspace w1 --all --template "* && ! -e "$2/nhm_calls" ]]' _ "$RC" "$STUB_DIR"

menu_case "prompt 0 - ^fix_bug"
RC=0
OUT="$(cd "$WORK/repo" && bash "$PALETTE" </dev/null 2>"$WORK/err")" || RC=$?
check "without a terminal it refuses and names the commands that work" \
    bash -c '[[ "$1" -ne 0 ]] && grep -qF -- "--list, --show KEY" "$2"' _ "$RC" "$WORK/err"

run_palette --bogus
check "an unknown option is refused" bash -c '[[ "$1" -ne 0 ]] && grep -qF "unknown option: --bogus" <<<"$2"' _ "$RC" "$ERR"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
