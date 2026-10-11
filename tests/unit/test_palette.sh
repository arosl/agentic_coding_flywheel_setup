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
