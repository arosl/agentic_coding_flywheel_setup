#!/usr/bin/env bash
# E01's Codex dcg guard (acfs-9hkh.31), sourced by test_nhm_rehearsal.sh
# after its own steps; step_E01 calls e01_codex_dcg.
#
# ACFS's install (acfs_install_codex_dcg_hook) adds dcg's Bash guard to
# ~/.codex/hooks.json with `nhm_hooks.sh codex-dcg register` and records
# Codex's trust in it with `nhm_hooks.sh trust codex`. e01_codex_dcg does
# the same in the sandbox HOME, so the doctor's "guard codex dcg" check
# reads what an install leaves.
#
# At source time (outside the sandbox) this file binds two things:
#   - dcg at ~/.local/bin/dcg in the sandbox HOME: the guard's command is
#     $HOME/.local/bin/dcg, and register refuses when no dcg is there;
#   - Codex's own binary as codex: an npm-installed codex is a wrapper
#     that runs bun or node from the real HOME, which the sandbox hides.
#     `trust codex` runs Codex's app-server, so it needs the binary that
#     the npm package carries (vendor/<target>/bin/codex).

# e01_codex_native: Codex's binary for the codex on PATH: the codex itself
# when it is a binary; else the npm package's vendor binary, found from the
# codex.js the wrapper runs.
e01_codex_native() {
    local codex word js pkg bin
    codex="$(command -v codex 2>/dev/null)" || return 1
    codex="$(realpath -e "$codex")" || return 1
    if [[ "$(head -c 4 "$codex" 2>/dev/null | od -An -c | tr -d ' ')" == '177ELF' ]]; then
        printf '%s\n' "$codex"
        return 0
    fi
    js="$codex"
    if [[ "$codex" != *.js ]]; then
        js=""
        # The wrapper's exec line names the package's bin/codex(.js).
        for word in $(grep -m1 '^exec ' "$codex" 2>/dev/null | tr -d '"'"'"); do
            [[ "$word" == */codex || "$word" == */codex.js ]] && [[ -e "$word" ]] && js="$(realpath -e "$word")"
        done
    fi
    [[ -n "$js" ]] || return 1
    pkg="$(dirname "$(dirname "$js")")"
    for bin in "$pkg"/vendor/*/bin/codex "$pkg"/../codex-linux-*/vendor/*/bin/codex; do
        if [[ -f "$bin" && -x "$bin" ]]; then
            realpath -e "$bin"
            return 0
        fi
    done
    return 1
}

if [[ -n "${SANDBOX_HOME:-}" ]]; then
    if command -v dcg >/dev/null 2>&1; then
        mkdir -p "$SANDBOX_HOME/.local/bin"
        : >"$SANDBOX_HOME/.local/bin/dcg"
        SANDBOX_BINDS+=("$(realpath -e "$(command -v dcg)")" "$SANDBOX_HOME/.local/bin/dcg")
    fi
    if e01_codex_bin="$(e01_codex_native)"; then
        # A later bind of the same path wins: this replaces the wrapper.
        sandbox_bin codex "$e01_codex_bin"
    fi
    unset e01_codex_bin
fi

# e01_codex_dcg: in the sandbox, as ACFS's install: register dcg's Bash
# guard in Codex's hooks.json, then trust it (the helper bounds Codex's
# app-server at 60 s; the timeout bounds the helper, as install does).
e01_codex_dcg() {
    local hooks file="${CODEX_HOME:-$HOME/.codex}/hooks.json" out="$SANDBOX_EVIDENCE/guard-codex-dcg.out"
    hooks="$(dirname "$SANDBOX_LIB")/../../../scripts/lib/nhm_hooks.sh"
    if [[ ! -x "$HOME/.local/bin/dcg" ]]; then
        echo "FAIL E01: no dcg at ~/.local/bin/dcg in the sandbox (is dcg on the host's PATH?)"
        return 0
    fi
    if ! command -v codex >/dev/null 2>&1; then
        echo "FAIL E01: no codex in the sandbox (is codex on the host's PATH?)"
        return 0
    fi
    {
        show "codex-dcg register" bash "$hooks" codex-dcg register "$file"
        show "trust codex" timeout 90 bash "$hooks" trust codex "$file"
        show "codex-dcg registered" bash "$hooks" codex-dcg registered "$file"
        echo "### $file"
        cat "$file"
    } >"$out" 2>&1
    check "E01: Codex's hooks.json has dcg's Bash guard, as install writes it" \
        bash "$hooks" codex-dcg registered "$file"
    check "E01: Codex trusts dcg's Bash guard (trust codex exits 0)" \
        bash -c 'awk "/^### trust codex/{f=1} f && /^\\(exit /{print; exit}" "$1" | grep -qx "(exit 0)"' _ "$out"
}
