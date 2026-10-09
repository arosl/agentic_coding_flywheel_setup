#!/usr/bin/env bash
# ============================================================
# ACFS newproj TUI Wizard - Success Screen
# Shows success message and next steps
# ============================================================

# Prevent multiple sourcing
if [[ -n "${_ACFS_SCREEN_SUCCESS_LOADED:-}" ]]; then
    return 0
fi
_ACFS_SCREEN_SUCCESS_LOADED=1

# ============================================================
# Screen: Success
# ============================================================

# Screen metadata
SCREEN_SUCCESS_ID="success"
SCREEN_SUCCESS_TITLE="Success"
SCREEN_SUCCESS_STEP=9

prepare_success_exec() {
    tui_cleanup
    finalize_logging 2>/dev/null || true
}

# Render the success screen
render_success_screen() {
    render_screen_header "Project Created!" "$SCREEN_SUCCESS_STEP" 9

    local project_name
    project_name=$(state_get "project_name")
    local project_dir
    project_dir=$(state_get "project_dir")
    local beads_initialized=false
    if [[ -d "$project_dir/.beads" ]]; then
        beads_initialized=true
    fi

    # Success banner
    if [[ "$TERM_HAS_UNICODE" == "true" ]]; then
        printf "%b\n" "${TUI_SUCCESS}"
        cat << 'BANNER'
    ╔══════════════════════════════════════════════════════╗
    ║                                                      ║
    ║       ✓ ✓ ✓   PROJECT CREATED SUCCESSFULLY   ✓ ✓ ✓  ║
    ║                                                      ║
    ╚══════════════════════════════════════════════════════╝
BANNER
        printf "%b\n" "${TUI_NC}"
    else
        echo ""
        printf "%b\n" "${TUI_SUCCESS}=== PROJECT CREATED SUCCESSFULLY ===${TUI_NC}"
        echo ""
    fi

    echo ""
    printf "%b\n" "Your new project ${TUI_PRIMARY}$project_name${TUI_NC} is ready!"
    echo ""

    # What was created
    printf "%b\n" "${TUI_BOLD}What was created:${TUI_NC}"
    draw_line 50

    printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} Project directory: $project_dir"
    printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} Git repository initialized"
    printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} README.md"
    printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} .gitignore"

    if [[ "$(state_get "enable_agents")" == "true" ]]; then
        printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} AGENTS.md for AI assistants"
    fi

    if [[ "$(state_get "enable_br")" == "true" && "$beads_initialized" == "true" ]]; then
        printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} Beads issue tracking (.beads/)"
    elif [[ "$(state_get "enable_br")" == "true" ]]; then
        printf "%b\n" "  ${TUI_WARNING}!${TUI_NC} Beads issue tracking requested but not initialized"
    fi

    if [[ "$(state_get "enable_claude")" == "true" ]]; then
        printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} Claude Code settings (.claude/)"
    fi

    if [[ "$(state_get "enable_ubsignore")" == "true" ]]; then
        printf "%b\n" "  ${TUI_SUCCESS}${BOX_CHECK}${TUI_NC} UBS ignore patterns (.ubsignore)"
    fi

    echo ""

    # Next steps
    printf "%b\n" "${TUI_BOLD}Next steps:${TUI_NC}"
    draw_line 50
    echo ""

    echo "  1. Navigate to your project:"
    printf "%b\n" "     ${TUI_CYAN}cd $project_dir${TUI_NC}"
    echo ""

    echo "  2. Start coding with Claude Code:"
    printf "%b\n" "     ${TUI_CYAN}claude${TUI_NC}"
    echo ""

    if [[ "$(state_get "enable_br")" == "true" && "$beads_initialized" == "true" ]]; then
        echo "  3. Create your first task:"
        printf "%b\n" "     ${TUI_CYAN}br create --title=\"First feature\" --type=feature${TUI_NC}"
        echo ""
    elif [[ "$(state_get "enable_br")" == "true" ]]; then
        echo "  3. Finish enabling Beads (optional):"
        printf "%b\n" "     ${TUI_CYAN}br init${TUI_NC}"
        echo ""
    fi

    echo "  For help, run:"
    printf "%b\n" "     ${TUI_CYAN}acfs help${TUI_NC}"
    echo ""

    draw_line 50
    echo ""
    echo "Options:"
    echo "  [Enter/o]   Open project in shell"
    echo "  [c]         Open in Claude Code"
    echo "  [n]         Start a multi-agent herdr workspace"
    echo "  [w]         Start agents and hand off ready Beads tasks"
    echo "  [q]         Exit wizard"
}

# Open project in new shell
open_in_shell() {
    local project_dir
    project_dir=$(state_get "project_dir")

    if [[ ! -d "$project_dir" ]]; then
        echo ""
        printf "%b\n" "${TUI_WARNING}Project directory no longer exists: $project_dir${TUI_NC}"
        return 1
    fi

    local shell_bin="${SHELL:-}"
    if [[ -z "$shell_bin" ]] || ! command -v "$shell_bin" &>/dev/null; then
        shell_bin="$(command -v zsh 2>/dev/null || command -v bash 2>/dev/null || true)"
    fi
    if [[ -z "$shell_bin" ]]; then
        echo ""
        printf "%b\n" "${TUI_WARNING}No interactive shell found in PATH${TUI_NC}"
        return 1
    fi

    echo ""
    printf "%b\n" "${TUI_PRIMARY}Opening project shell...${TUI_NC}"
    echo ""
    prepare_success_exec
    cd "$project_dir" || return 1
    exec "$shell_bin" -i
}

# Open project in Claude Code
open_in_claude() {
    local project_dir
    project_dir=$(state_get "project_dir")

    if [[ ! -d "$project_dir" ]]; then
        echo ""
        printf "%b\n" "${TUI_WARNING}Project directory no longer exists: $project_dir${TUI_NC}"
        return 1
    fi

    if ! command -v claude &>/dev/null; then
        echo ""
        printf "%b\n" "${TUI_WARNING}Claude Code not found in PATH${TUI_NC}"
        echo "Run manually:"
        printf "%b\n" "  ${TUI_CYAN}cd $project_dir && claude${TUI_NC}"
        return 1
    fi

    echo ""
    printf "%b\n" "${TUI_PRIMARY}Opening in Claude Code...${TUI_NC}"
    prepare_success_exec
    cd "$project_dir" || return 1
    exec claude
}

# `acfs agents spawn` (scripts/lib/herdr_agents.sh) starts the agents; this
# screen never starts one itself. It is in this screen's parent directory,
# in the checkout and in ~/.acfs/scripts/lib alike.
NEWPROJ_HERDR_AGENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/herdr_agents.sh"

# Canonicalize the exact project selected by the wizard. Never use project
# names or paths as shell source.
newproj_herdr_project() {
    local project_dir
    project_dir=$(state_get "project_dir") || return 1
    if [[ -z "$project_dir" || "$project_dir" == *[[:cntrl:]]* || ! -d "$project_dir" ]]; then
        echo "The project directory is missing or invalid; no agents were started." >&2
        return 1
    fi
    (CDPATH='' cd -P -- "$project_dir" && pwd -P)
}

# Validate before either task creation or agent launch can mutate the project.
newproj_validate_herdr_request() {
    local project_dir="$1" label="$2" cc="$3" cod="$4" agy="$5"
    local count total=0 tool
    if [[ ! "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; then
        echo "Use a workspace name of 1-64 letters, numbers, underscores, or hyphens." >&2
        return 1
    fi
    for count in "$cc" "$cod" "$agy"; do
        if [[ ! "$count" =~ ^[0-4]$ ]]; then
            echo "Choose 0-4 agents per provider, with 1-8 agents in total." >&2
            return 1
        fi
        total=$((total + count))
    done
    if ((total < 1 || total > 8)); then
        echo "Choose 1-8 agents in total." >&2
        return 1
    fi
    if [[ "$project_dir" != /* || "$project_dir" == / || "$project_dir" == *[[:cntrl:]]* || ! -d "$project_dir" ]]; then
        echo "An existing absolute project directory is required." >&2
        return 1
    fi
    for tool in herdr jq am; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'Missing %s. Run acfs doctor before starting a workspace.\n' "$tool" >&2
            return 1
        fi
    done
    if [[ ! -r "$NEWPROJ_HERDR_AGENTS" ]]; then
        echo "Missing herdr_agents.sh (acfs agents). Run acfs update before starting a workspace." >&2
        return 1
    fi
    if ! herdr status server 2>/dev/null | grep -q '^ *status: running$'; then
        echo "The herdr server isn't running. Start it by running herdr in another terminal, then try again." >&2
        return 1
    fi
    if { ((cc > 0)) && ! command -v claude >/dev/null 2>&1; } ||
       { ((cod > 0)) && ! command -v codex >/dev/null 2>&1; } ||
       { ((agy > 0)) && ! command -v agy >/dev/null 2>&1; }; then
        echo "A selected agent CLI is missing; adjust the mix or run acfs doctor." >&2
        return 1
    fi
}

# Scope Beads to this project. A terminal can inherit another repository's
# database overrides; changing cwd alone is not sufficient. The subshell
# preserves the caller's environment and directory.
newproj_herdr_project_command() (
    local project_dir="$1"
    shift
    unset BEADS_DB BD_DB BD_DATABASE BEADS_JSONL
    export BEADS_DIR="$project_dir/.beads"
    cd -- "$project_dir" || return 1
    "$@"
)

# Read the local ready queue before asking for permission to hand off work.
newproj_herdr_ready_work() {
    local project_dir="$1" ready
    if [[ ! -d "$project_dir/.beads" || -L "$project_dir/.beads" ]]; then
        echo "This project needs its own initialized .beads directory. Run br init first." >&2
        return 1
    fi
    if ! command -v br >/dev/null 2>&1 || ! command -v bv >/dev/null 2>&1; then
        echo "Beads Rust (br) and Beads Viewer (bv) are required for task handoff." >&2
        return 1
    fi
    ready=$(newproj_herdr_project_command "$project_dir" br ready --json) || {
        echo "Could not read ready tasks; no work was assigned." >&2
        return 1
    }
    if ! jq -e -s '
        length == 1 and (.[0] | type == "array" and all(.[];
            type == "object" and
            (.id | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$")) and
            (.title | type == "string")))
    ' >/dev/null 2>&1 <<< "$ready"; then
        echo "Beads returned an invalid ready queue; no work was assigned." >&2
        return 1
    fi
    printf '%s\n' "$ready"
}

# Creates the workspace, starts the agents in it and prints the workspace
# ID. Ordinary launch sends no prompt. Work mode sends each agent the
# kickoff `acfs agents spawn` sends by default: its Agent Mail identity and
# the command palette's default_new_agent prompt, which has it pick, claim
# and start a ready Beads task. herdr can't confirm a claim, so it reports
# prompted agents, not delivered tasks.
newproj_start_herdr() {
    local project_dir="$1" label="$2" cc="$3" cod="$4" agy="$5" work="${6:-false}"
    local response status=0 total workspace want
    newproj_validate_herdr_request "$project_dir" "$label" "$cc" "$cod" "$agy" || return 1
    total=$((cc + cod + agy))
    local -a prompt_args=()
    case "$work" in
        true)
            newproj_herdr_ready_work "$project_dir" >/dev/null || return 1
            want=prompted
            ;;
        false)
            prompt_args=(--no-prompt)
            want=started
            ;;
        *) echo "Work assignment requires an explicit true/false choice." >&2; return 1 ;;
    esac
    # A new workspace every time: an existing one may belong to another
    # project or hold live work.
    response=$(herdr workspace create --cwd "$project_dir" --label "$label" --no-focus) || status=$?
    workspace=$(jq -r '.result.workspace.workspace_id // empty' 2>/dev/null <<< "$response" || true)
    if ((status != 0)) || [[ ! "$workspace" =~ ^[a-zA-Z0-9][a-zA-Z0-9:_-]{0,63}$ ]]; then
        echo "herdr did not confirm a new workspace; no agents were started." >&2
        return 1
    fi
    response=$(bash "$NEWPROJ_HERDR_AGENTS" spawn --workspace "$workspace" --cwd "$project_dir" \
        --claude "$cc" --codex "$cod" --agy "$agy" "${prompt_args[@]}" --json) || status=$?
    if ((status != 0)) || ! jq -e -s --arg ws "$workspace" --arg dir "$project_dir" \
        --argjson count "$total" --arg want "$want" '
        length == 1 and (.[0] |
        type == "object" and .ok == true and .workspace == $ws and
        .cwd == $dir and .dry_run == false and
        (.agents | type == "array" and length == $count and
            all(.[]; type == "object" and .status == $want)))
    ' >/dev/null 2>&1 <<< "$response"; then
        echo "herdr did not confirm the requested agents. No automatic retry or cleanup was attempted." >&2
        printf 'Inspect acfs agents list --workspace %s and acfs doctor; a partial workspace may need attention.\n' "$workspace" >&2
        return 1
    fi
    if [[ "$work" == true ]]; then
        printf 'Prompted %s agent(s) to pick up ready Beads tasks.\n' "$total" >&2
        echo "Each agent claims its own task; br list --status=in_progress shows what they took." >&2
    fi
    printf '%s\n' "$workspace"
}

open_in_herdr() {
    local project_dir project_name label answer cc=0 cod=0 agy=0 available=0
    local work="${1:-false}" ready task_title="" created_task="" workspace
    [[ "$work" == true || "$work" == false ]] || return 1
    project_dir=$(newproj_herdr_project) || return 1
    project_name=$(state_get "project_name") || return 1
    for answer in herdr jq am; do
        if ! command -v "$answer" >/dev/null 2>&1; then
            printf 'Missing %s. Run acfs doctor before starting a workspace.\n' "$answer" >&2
            return 1
        fi
    done
    command -v claude >/dev/null 2>&1 && { cc=1; available=$((available + 1)); }
    command -v codex >/dev/null 2>&1 && { cod=1; available=$((available + 1)); }
    command -v agy >/dev/null 2>&1 && { agy=1; available=$((available + 1)); }
    if ((available == 0)); then
        echo "Install Claude Code, Codex, or Antigravity before starting a workspace." >&2
        return 1
    fi
    # Even a single-provider installation can start a useful two-agent workspace.
    if ((available == 1)); then
        ((cc > 0)) && cc=2
        ((cod > 0)) && cod=2
        ((agy > 0)) && agy=2
    fi
    label="acfs-${project_name:0:48}"
    printf '\nProject: %s\n' "$project_dir"
    echo "Start each agent in its own tab of a new herdr workspace, beside a tab with your own shell."
    echo "Each agent gets an Agent Mail identity, and its tab is named after it."
    echo "Installed does not mean authenticated. Sign in inside each agent as needed."
    echo "Agents may incur provider charges."
    if [[ "$work" == true ]]; then
        echo "Work mode prompts each agent to pick a ready Beads task, claim it and start work."
    else
        echo "ACFS will not send any prompt to the agents."
    fi
    read -r -p "Workspace name [$label]: " answer || return 1
    label="${answer:-$label}"
    if ((cc > 0)); then
        read -r -p "Claude agents, 0-4 [$cc]: " answer || return 1
        cc="${answer:-$cc}"
    fi
    if ((cod > 0)); then
        read -r -p "Codex agents, 0-4 [$cod]: " answer || return 1
        cod="${answer:-$cod}"
    fi
    if ((agy > 0)); then
        read -r -p "Antigravity agents, 0-4 [$agy]: " answer || return 1
        agy="${answer:-$agy}"
    fi
    printf '\nWorkspace: %s\nClaude: %s  Codex: %s  Antigravity: %s\n' "$label" "$cc" "$cod" "$agy"
    newproj_validate_herdr_request "$project_dir" "$label" "$cc" "$cod" "$agy" || return 1
    if [[ "$work" == true ]]; then
        ready=$(newproj_herdr_ready_work "$project_dir") || return 1
        if [[ "$(jq 'length' <<< "$ready")" == 0 ]]; then
            echo "No tasks are ready. Enter a concrete first task, or leave blank to cancel."
            read -r -p "First task: " task_title || return 1
            if [[ -z "${task_title//[[:space:]]/}" || ${#task_title} -gt 512 || "$task_title" == *[[:cntrl:]]* ]]; then
                echo "A nonblank task title of at most 512 characters is required." >&2
                return 1
            fi
            printf 'Will create a priority-2 task: %s\n' "$task_title"
        else
            echo "Ready task preview (up to eight; agents recheck the queue before claiming):"
            jq -r '.[:8][] | "  \(.id | @json): \(.title | @json)"' <<< "$ready"
        fi
        echo "Consent covers agents claiming currently ready tasks, not only this preview."
        echo "Tasks, claims and agents are preserved if launch or a prompt fails."
    fi
    read -r -p "Start these agents? Type yes to continue: " answer || return 1
    if [[ "$answer" != yes ]]; then
        echo "Workspace launch cancelled; your project is unchanged."
        return 1
    fi
    if [[ -n "$task_title" ]]; then
        # --silent is br's single-ID output contract. A title stays one argument,
        # including quotes or shell syntax. Never recreate automatically on error.
        if ! created_task=$(newproj_herdr_project_command "$project_dir" br create "--title=$task_title" --type=task --priority=2 --silent) ||
           [[ ! "$created_task" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]]; then
            echo "Task creation was not confirmed. Inspect br list before retrying; existing work was preserved." >&2
            return 1
        fi
        printf 'Created task %s. It remains in Beads even if workspace launch fails.\n' "$created_task"
    fi
    if ! workspace=$(newproj_start_herdr "$project_dir" "$label" "$cc" "$cod" "$agy" "$work"); then
        return 1
    fi
    herdr workspace focus "$workspace" >/dev/null 2>&1 || true
    if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
        # Already inside herdr: the new workspace is focused; nothing to attach.
        printf '\nWorkspace %s started and focused. Ctrl+b then w lists your workspaces.\n' "$label"
        return 0
    fi
    printf '\nWorkspace %s started. Reconnect any time by running herdr; Ctrl+b then w lists workspaces.\n' "$label"
    echo "Agents keep running after you disconnect."
    prepare_success_exec
    cd -- "$project_dir" || return 1
    exec herdr
}

# Handle input for success screen
handle_success_input() {
    while true; do
        render_success_screen

        local key
        # EOF is not consent to open a shell or launch agents.
        read -rsn1 key || return 0

        case "$key" in
            ''|'o'|'O')
                # Open in shell
                log_input "success" "open_shell"
                if open_in_shell; then
                    return 0
                fi
                ;;
            'c'|'C')
                # Open in Claude Code
                log_input "success" "open_claude"
                if open_in_claude; then
                    return 0
                fi
                ;;
            'n'|'N')
                log_input "success" "open_herdr"
                if open_in_herdr; then
                    return 0
                fi
                echo "Press any key to return to the project menu."
                read -rsn1 key || return 0
                ;;
            'w'|'W')
                log_input "success" "open_herdr_work"
                if open_in_herdr true; then
                    return 0
                fi
                echo "Press any key to return to the project menu."
                read -rsn1 key || return 0
                ;;
            'q'|'Q'|$'\e')
                # Quit
                log_input "success" "quit"
                return 0
                ;;
        esac
    done
}

# Run the success screen
run_success_screen() {
    log_screen "ENTER" "success"

    handle_success_input

    # Clean up
    tui_cleanup
    finalize_logging 2>/dev/null || true

    return 0
}
