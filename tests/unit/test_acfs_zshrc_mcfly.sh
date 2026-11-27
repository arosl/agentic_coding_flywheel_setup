#!/usr/bin/env bash
# ============================================================
# acfs.zshrc's mcfly + mcfly-fzf block (acfs-wyzm):
#   - agents' shells (`zsh -c`, `zsh -i -c`) never record history:
#     mcfly records from its precmd hook, which zsh runs only before a
#     prompt; a shell on a real terminal (the positive control) does
#   - Ctrl-R is mcfly-fzf in the emacs and viins keymaps, also when the
#     shell starts with EDITOR=nvim (viins main) and `bindkey -e` follows
#   - ACFS_NO_MCFLY_INIT=1, a missing mcfly-fzf or fzf, a missing mcfly,
#     and a missing history file
# The stubs print a cut-down copy of upstream's init scripts (mcfly v0.9.4
# mcfly.zsh, mcfly-fzf 1.0.4 shell/mcfly-fzf.zsh): the same interactive
# guards, precmd hook and key bindings.
# Usage: bash tests/unit/test_acfs_zshrc_mcfly.sh
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZSHRC="$REPO_ROOT/acfs/zsh/acfs.zshrc"

if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-zshrc-mcfly.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The block only, so the test needs neither oh-my-zsh nor the other tools.
BLOCK="$WORK/mcfly-block.zsh"
awk '/^# mcfly \+ mcfly-fzf \(shell history\)/{on=1} /^# --- Prompt config ---/{on=0} on' "$ZSHRC" > "$BLOCK"
if ! grep -q 'mcfly init zsh' "$BLOCK" || ! grep -q 'mcfly-fzf init zsh' "$BLOCK"; then
    echo "FAIL: could not extract the mcfly block from $ZSHRC"
    exit 1
fi
if grep -Eq 'atuin (init|daemon)' "$ZSHRC"; then
    echo "FAIL: $ZSHRC still starts Atuin"
    exit 1
fi

PASS=0
FAIL=0
check() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); echo "ok   $name"
    else
        FAIL=$((FAIL + 1)); echo "FAIL $name"; echo "     want: $want"; echo "     got:  $got"
    fi
}

# The shells under test see only a stub directory on PATH, so a real fzf or
# mcfly on this host cannot answer for a stub.
ZSH_BIN="$(command -v zsh)"
CAT_BIN="$(command -v cat)"
STUBS="$WORK/stubs"        # mcfly, mcfly-fzf, fzf
NO_FZF="$WORK/stubs-nofzf" # mcfly, mcfly-fzf
ONLY_MCFLY="$WORK/stubs-mcfly"
EMPTY="$WORK/stubs-none"
mkdir -p "$STUBS" "$NO_FZF" "$ONLY_MCFLY" "$EMPTY"
# Upstream's init finds mcfly with an external `which`.
WHICH_BIN="$(type -P which || true)"
if [[ -z "$WHICH_BIN" ]]; then
    echo "SKIP: which(1) not installed"
    exit 0
fi
for d in "$STUBS" "$NO_FZF" "$ONLY_MCFLY"; do ln -s "$WHICH_BIN" "$d/which"; done

cat > "$WORK/mcfly.init.zsh" <<'EOF'
() {
  [[ -o interactive ]] || return 0
  export MCFLY_HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
  if [[ ! -r "${MCFLY_HISTFILE}" ]]; then
    echo "McFly: ${MCFLY_HISTFILE} does not exist or is not readable."
    return 1
  fi
  export MCFLY_SESSION_ID=stub-session
  MCFLY_PATH=${MCFLY_PATH:-$(command which mcfly)}
  function mcfly_prompt_command {
    local exit_code=$?
    $MCFLY_PATH --history_format zsh add --exit ${exit_code}
    return ${exit_code}
  }
  precmd_functions+=(mcfly_prompt_command)
  mcfly-history-widget() { :; }
  zle -N mcfly-history-widget
  bindkey '^R' mcfly-history-widget
}
EOF
cat > "$WORK/mcfly-fzf.init.zsh" <<'EOF'
if [[ -o interactive ]] && [[ "$__MCFLY_FZF_LOADED" != "loaded" ]]; then
  __MCFLY_FZF_LOADED="loaded"
  if [[ ! -n "$MCFLY_SESSION_ID" ]]; then
    echo "Mcfly-fzf: Must initialize mcfly before mcfly-fzf"
    return 1
  fi
  mcfly-fzf-history-widget() { :; }
  zle -N mcfly-fzf-history-widget
  bindkey '^R' mcfly-fzf-history-widget
fi
EOF

# Each stub logs its calls to $STUB_LOG: "init" for `init zsh`, "add" for
# the precmd hook's `add`.
write_stub() {
    local path="$1" name="$2"
    cat > "$path" <<EOF
#!/bin/bash
if [[ "\${1:-} \${2:-}" == "init zsh" ]]; then
    printf '%s init\n' "$name" >> "\$STUB_LOG"
    "$CAT_BIN" "$WORK/$name.init.zsh"
    exit 0
fi
for arg in "\$@"; do
    [[ "\$arg" == add ]] && printf '%s add\n' "$name" >> "\$STUB_LOG"
done
exit 0
EOF
    chmod +x "$path"
}
write_stub "$STUBS/mcfly" mcfly
write_stub "$STUBS/mcfly-fzf" mcfly-fzf
printf '#!/bin/bash\nexit 0\n' > "$STUBS/fzf"; chmod +x "$STUBS/fzf"
write_stub "$NO_FZF/mcfly" mcfly
write_stub "$NO_FZF/mcfly-fzf" mcfly-fzf
write_stub "$ONLY_MCFLY/mcfly" mcfly
printf '#!/bin/bash\nexit 0\n' > "$ONLY_MCFLY/fzf"; chmod +x "$ONLY_MCFLY/fzf"

# run_zsh LABEL STUBDIR ZSH_FLAGS SCRIPT [ENV...]: runs SCRIPT in a clean
# zsh after sourcing the block; prints the script's output.
run_zsh() {
    local label="$1" stubdir="$2" flags="$3" script="$4"
    shift 4
    local home="$WORK/home-$label"
    mkdir -p "$home"
    : > "$home/.zsh_history"
    : > "$WORK/log-$label"
    # shellcheck disable=SC2086  # $flags holds several zsh options
    env -i HOME="$home" PATH="$stubdir" TERM=dumb STUB_LOG="$WORK/log-$label" "$@" \
        "$ZSH_BIN" $flags -c "source '$BLOCK'; $script" 2>&1
}
log_of() { tr '\n' ' ' < "$WORK/log-$1" | sed 's/ $//'; }

# --- Agents' shells ---------------------------------------------------
# Claude Code, Codex and pi run each command through `<shell> -c`: no
# prompt, so no precmd. Non-interactive: the block does not even run init.
run_zsh agent-c "$STUBS" "-f" 'echo agent-cmd' >/dev/null
check "zsh -c: no init, nothing recorded" "" "$(log_of agent-c)"

# Interactive without a prompt (`zsh -i -c`): init runs and registers the
# hook, and still nothing is recorded.
out="$(run_zsh agent-ic "$STUBS" "-f -i" 'echo agent-cmd; print -r -- "hooks=${precmd_functions[*]}"')"
check "zsh -i -c: hook registered" "hooks=mcfly_prompt_command" "$(printf '%s\n' "$out" | grep '^hooks=')"
check "zsh -i -c: init ran, nothing recorded" "mcfly init mcfly-fzf init" "$(log_of agent-ic)"

# The hook records when zsh runs it: proof that the stubs are wired.
run_zsh hook-manual "$STUBS" "-f -i" 'for f in $precmd_functions; do $f; done' >/dev/null
check "precmd hook run by hand records" "mcfly init mcfly-fzf init mcfly add" "$(log_of hook-manual)"

# Positive control: a shell on a terminal draws prompts, so it records.
if command -v script >/dev/null 2>&1; then
    home="$WORK/home-pty"; mkdir -p "$home"; : > "$home/.zsh_history"; : > "$WORK/log-pty"
    printf 'source %q\necho human-cmd\nexit\n' "$BLOCK" |
        timeout 20 script -q -e -c "env -i HOME='$home' PATH='$STUBS' TERM=dumb STUB_LOG='$WORK/log-pty' '$ZSH_BIN' -f -i" /dev/null >/dev/null 2>&1
    if grep -q '^mcfly add$' "$WORK/log-pty"; then
        PASS=$((PASS + 1)); echo "ok   interactive shell on a pty records (positive control)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL interactive shell on a pty records (positive control)"; echo "     log: $(log_of pty)"
    fi
else
    echo "skip interactive shell on a pty records (script(1) not installed)"
fi

# --- Ctrl-R -------------------------------------------------------------
keys='bindkey -e; print -r -- "$(bindkey -M emacs "^R")|$(bindkey -M viins "^R")|$(bindkey "^R")"'
want_fzf='"^R" mcfly-fzf-history-widget|"^R" mcfly-fzf-history-widget|"^R" mcfly-fzf-history-widget'
check "Ctrl-R is mcfly-fzf" "$want_fzf" "$(run_zsh keys "$STUBS" "-f -i" "$keys" | tail -n 1)"
check "Ctrl-R is mcfly-fzf when EDITOR=nvim made viins main" "$want_fzf" \
    "$(run_zsh keys-vi "$STUBS" "-f -i" "$keys" EDITOR=nvim | tail -n 1)"
only_ctrl_r='for l in ${(f)"$(bindkey -M emacs; bindkey -M viins; bindkey -M vicmd)"}; do [[ $l == *mcfly* && $l != "\"^R\" "* ]] && print -r -- $l; done; print -r -- "up=$(bindkey -M emacs "^[OA")"'
check "only Ctrl-R is mcfly's; the Up arrow is left to zsh" 'up="^[OA" up-line-or-history' \
    "$(run_zsh up "$STUBS" "-f -i" "$only_ctrl_r")"

want_mcfly='"^R" mcfly-history-widget|"^R" mcfly-history-widget|"^R" mcfly-history-widget'
check "no fzf: Ctrl-R is mcfly's own search" "$want_mcfly" \
    "$(run_zsh nofzf "$NO_FZF" "-f -i" "$keys" EDITOR=nvim | tail -n 1)"
check "no fzf: mcfly-fzf init skipped" "mcfly init" "$(log_of nofzf)"
check "no mcfly-fzf: Ctrl-R is mcfly's own search" "$want_mcfly" \
    "$(run_zsh nomf "$ONLY_MCFLY" "-f -i" "$keys" | tail -n 1)"

# --- Overrides and missing pieces ----------------------------------------
out="$(run_zsh optout "$STUBS" "-f -i" "$keys" ACFS_NO_MCFLY_INIT=1 | tail -n 1)"
check "ACFS_NO_MCFLY_INIT=1: zsh's own Ctrl-R" \
    '"^R" history-incremental-search-backward|"^R" redisplay|"^R" history-incremental-search-backward' "$out"
check "ACFS_NO_MCFLY_INIT=1: no init" "" "$(log_of optout)"
check "no mcfly: no output, no init" "" "$(run_zsh none "$EMPTY" "-f -i" ':')"

home="$WORK/home-nohist"; mkdir -p "$home"; : > "$WORK/log-nohist"
out="$(env -i HOME="$home" PATH="$STUBS" TERM=dumb STUB_LOG="$WORK/log-nohist" \
    "$ZSH_BIN" -f -i -c "source '$BLOCK'; print -r -- \"\$MCFLY_SESSION_ID\"" 2>&1)"
check "missing history file: created, mcfly starts quietly" "stub-session" "$out"
check "missing history file: created private" "600" "$(stat -c '%a' "$home/.zsh_history" 2>/dev/null)"

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
