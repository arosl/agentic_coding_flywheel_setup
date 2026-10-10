#!/usr/bin/env bash
# ============================================================
# check_generated.sh - keep committed generated files in step with
# what the commit itself generates (acfs-s3tl)
#
# A commit that changes a file the internal checksum ledger covers, the
# manifest or the generator, without regenerating, breaks install.sh's
# integrity checks for everyone until the next pusher regenerates. This
# check runs the generator on a snapshot of exactly what is committed, in
# a temp checkout, never on the shared working tree, where other agents'
# uncommitted edits would leak into the ledger.
#
# Usage:
#   check_generated.sh --hook
#       Pre-commit check. Snapshots the commit's index (git's temp index
#       for `git commit -- <paths>`), runs the generator there, and
#       refuses the commit if a generated file differs. It names the
#       command that fixes it.
#   check_generated.sh --regenerate [-- <path>...]
#       Regenerates from HEAD plus the working-tree copies of <path>
#       (what `git commit -- <path>...` would commit), or from the index
#       without paths, and writes the generated files that change into
#       the working tree. Without paths it also stages them.
#   check_generated.sh --install
#       Installs the hook: into Agent Mail's hooks.d/pre-commit chain when
#       that exists, otherwise as the pre-commit hook.
# ============================================================

set -euo pipefail

LEDGER_PATH="scripts/generated/internal_checksums.sh"
HOOK_NAME="40-acfs-check-generated"
INSTALL_MARK="Installed by check_generated.sh --install"

die() {
    printf 'check_generated: %s\n' "$1" >&2
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

# Paths the ledger covers, read from the given index (or HEAD's tree).
ledger_keys() {
    git show "$1:$LEDGER_PATH" 2>/dev/null \
        | sed -n 's/^[[:space:]]*\[\([^]]*\)\]="[0-9a-f]\{64\}"$/\1/p' || true
}

# True when a changed path is something the generator reads or writes.
is_generator_input() {
    local path="$1"
    case "$path" in
        acfs.manifest.yaml|checksums.yaml|VERSION|README.md) return 0 ;;
        packages/manifest/*|scripts/generated/*|apps/web/lib/generated/*) return 0 ;;
    esac
    [[ -n "${LEDGERED[$path]+present}" ]]
}

# The manifest package's node_modules: this checkout's, or the main
# worktree's when this is a gate worktree without its own.
find_node_modules() {
    local top="$1" main=""
    if [[ -d "$top/packages/manifest/node_modules" ]]; then
        printf '%s\n' "$top/packages/manifest/node_modules"
        return 0
    fi
    main="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    if [[ -n "$main" && -d "$main/packages/manifest/node_modules" ]]; then
        printf '%s\n' "$main/packages/manifest/node_modules"
        return 0
    fi
    return 1
}

# Hash every file in the snapshot, so the generator's changes show up as
# differing lines. shasum covers macOS, which has no sha256sum.
snapshot_hashes() {
    local -a hasher=(sha256sum)
    command -v sha256sum >/dev/null 2>&1 || hasher=(shasum -a 256)
    (cd "$1" && find . -path ./packages/manifest/node_modules -prune -o -type f -print0 \
        | LC_ALL=C sort -z | xargs -0 "${hasher[@]}")
}

# Checks out the index named by $GIT_INDEX_FILE (git's default when unset)
# into $WORK/tree, runs the generator there, and lists the paths it
# changed in $WORK/changed.
generate_in_snapshot() {
    local top="$1" node_modules=""

    command -v bun >/dev/null 2>&1 \
        || die "bun is not on PATH, so the generated files can't be checked. Install bun, then commit again."
    node_modules="$(find_node_modules "$top")" \
        || die "packages/manifest has no node_modules. Run: bun install --frozen-lockfile --filter '@acfs/manifest'"

    git checkout-index -a --prefix="$WORK/tree/"
    ln -s "$node_modules" "$WORK/tree/packages/manifest/node_modules"
    snapshot_hashes "$WORK/tree" > "$WORK/before"
    if ! (cd "$WORK/tree/packages/manifest" && bun run src/generate.ts) > "$WORK/generate.log" 2>&1; then
        tail -n 20 "$WORK/generate.log" >&2
        die "the generator failed on this commit's files; fix that first."
    fi
    snapshot_hashes "$WORK/tree" > "$WORK/after"
    diff "$WORK/before" "$WORK/after" | sed -n 's/^[<>] [0-9a-f]\{64\}  \.\///p' \
        | LC_ALL=C sort -u > "$WORK/changed" || true
}

run_hook() {
    local top="$1" base="" path="" relevant=false
    local -a changed_inputs=()

    git cat-file -e ":packages/manifest/src/generate.ts" 2>/dev/null || exit 0
    if base="$(git rev-parse --verify -q HEAD)"; then
        while IFS= read -r path; do LEDGERED["$path"]=1; done < <(ledger_keys "$base")
    fi
    while IFS= read -r path; do LEDGERED["$path"]=1; done < <(ledger_keys "")

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        changed_inputs+=("$path")
        is_generator_input "$path" && relevant=true
    done < <(git diff --cached --name-only --no-renames)
    [[ "$relevant" == true ]] || exit 0

    generate_in_snapshot "$top"
    [[ -s "$WORK/changed" ]] || exit 0

    {
        echo "check_generated: this commit's generated files don't match what its own files generate:"
        sed 's/^/  /' "$WORK/changed"
        echo "Regenerate from exactly what you commit (not the shared working tree), then commit again with the files it lists:"
        printf '  bash scripts/hooks/check_generated.sh --regenerate --'
        printf ' %q' "${changed_inputs[@]}"
        printf '\n'
    } >&2
    exit 1
}

run_regenerate() {
    local top="$1" path=""
    shift
    local -a paths=("$@") written=()

    if [[ ${#paths[@]} -gt 0 ]]; then
        export GIT_INDEX_FILE="$WORK/index"
        if git rev-parse --verify -q HEAD >/dev/null; then
            git read-tree HEAD
        else
            git read-tree --empty
        fi
        git add -A -- "${paths[@]}"
    fi
    generate_in_snapshot "$top"
    unset GIT_INDEX_FILE

    if [[ ! -s "$WORK/changed" ]]; then
        echo "check_generated: the generated files are already up to date."
        return 0
    fi
    while IFS= read -r path; do
        if [[ -f "$WORK/tree/$path" ]]; then
            mkdir -p "$(dirname "$top/$path")"
            cp -p "$WORK/tree/$path" "$top/$path"
            written+=("$path")
        else
            printf 'check_generated: the generator removed %s; remove it yourself if that is intended.\n' "$path" >&2
        fi
    done < "$WORK/changed"
    [[ ${#written[@]} -gt 0 ]] || return 0

    echo "check_generated: regenerated:"
    printf '  %s\n' "${written[@]}"
    if [[ ${#paths[@]} -gt 0 ]]; then
        printf 'Commit them together: git commit --'
        printf ' %q' "${paths[@]}" "${written[@]}"
        printf '\n'
    else
        git add -- "${written[@]}"
        echo "Staged them."
    fi
}

run_install() {
    local hooks_dir="" target="" tmp=""

    hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
    if [[ -d "$hooks_dir/hooks.d/pre-commit" ]]; then
        target="$hooks_dir/hooks.d/pre-commit/$HOOK_NAME"
    elif [[ ! -e "$hooks_dir/pre-commit" ]] || grep -qF "$INSTALL_MARK" "$hooks_dir/pre-commit"; then
        mkdir -p "$hooks_dir"
        target="$hooks_dir/pre-commit"
    else
        die "$hooks_dir/pre-commit is another hook. Add 'bash scripts/hooks/check_generated.sh --hook' to it."
    fi

    tmp="$(mktemp "$target.XXXXXX")"
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# Installed by check_generated.sh --install (acfs-s3tl).
# Runs the copy in the checkout being committed, so a worktree runs its own.
top="$(git rev-parse --show-toplevel)" || exit 1
[[ -f "$top/scripts/hooks/check_generated.sh" ]] || exit 0
exec bash "$top/scripts/hooks/check_generated.sh" --hook
EOF
    chmod 0755 "$tmp"
    mv -f "$tmp" "$target"
    echo "check_generated: installed $target"
}

MODE=""
case "${1:-}" in
    --hook|--regenerate|--install) MODE="${1#--}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [[ "$MODE" == regenerate && $# -gt 0 ]]; then
    [[ "$1" == "--" ]] || { usage >&2; exit 2; }
    shift
elif [[ $# -gt 0 ]]; then
    usage >&2
    exit 2
fi

TOP="$(git rev-parse --show-toplevel)" || die "not inside a git checkout"
cd "$TOP" || exit 1
if [[ "$MODE" == install ]]; then
    run_install
    exit 0
fi

declare -A LEDGERED=()
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-check-generated.XXXXXX")"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

case "$MODE" in
    hook) run_hook "$TOP" ;;
    regenerate) run_regenerate "$TOP" "$@" ;;
esac
