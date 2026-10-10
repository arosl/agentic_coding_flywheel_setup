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
#       refuses the commit if a generated file's content or mode differs.
#       It names the command that fixes it.
#   check_generated.sh --regenerate [-- <path>...]
#       Regenerates from HEAD plus the working-tree copies of <path>
#       (what `git commit -- <path>...` would commit), or from the index
#       without paths, and writes the generated files that change into
#       the working tree. Without paths it also stages them. It never
#       overwrites a working-tree file that holds changes outside the
#       snapshot (another agent's work); it names it and fails instead.
#   check_generated.sh --install
#       Installs the hook: into Agent Mail's hooks.d/pre-commit chain when
#       that exists, otherwise as the pre-commit hook.
#
# Runs under bash 3.2 (macOS) too: no associative arrays or mapfile.
# ============================================================

set -euo pipefail

LEDGER_PATH="scripts/generated/internal_checksums.sh"
HOOK_NAME="40-acfs-check-generated"
INSTALL_MARK="Installed by check_generated.sh --install"
WORK=""

die() {
    printf 'check_generated: %s\n' "$1" >&2
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# Runs under/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

make_work() {
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-check-generated.XXXXXX")"
}
cleanup() {
    if [[ -n "$WORK" ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# Paths the ledger covers, read from the given tree-ish (or the index).
ledger_keys() {
    git show "$1:$LEDGER_PATH" 2>/dev/null \
        | sed -n 's/^[[:space:]]*\[\([^]]*\)\]="[0-9a-f]\{64\}"$/\1/p' || true
}

# True when a changed path is something the generator reads or writes,
# or that decides which generator runs.
is_generator_input() {
    local path="$1" ledgered="$2"
    case "$path" in
        acfs.manifest.yaml|checksums.yaml|VERSION|README.md|package.json|bun.lock) return 0 ;;
        packages/manifest/*|scripts/generated/*|apps/web/lib/generated/*) return 0 ;;
    esac
    printf '%s\n' "$ledgered" | grep -Fxq -- "$path"
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

# One line per file in the snapshot: its hash and path, and an "x" line
# for each executable, so the generator's content and mode changes both
# show up as differing lines.
snapshot_listing() {
    local -a hasher=(sha256sum)
    command -v sha256sum >/dev/null 2>&1 || hasher=(shasum -a 256)
    (
        cd "$1" || exit 1
        find . -path ./packages/manifest/node_modules -prune -o -type f -print0 \
            | LC_ALL=C sort -z | xargs -0 "${hasher[@]}"
        find . -path ./packages/manifest/node_modules -prune -o -type f -perm -u+x -print \
            | LC_ALL=C sort | sed 's/^/x  /'
    )
}

# Checks out the index named by $GIT_INDEX_FILE (git's default when unset)
# into $WORK/tree, runs the generator there, and lists the paths whose
# content or mode it changed in $WORK/changed.
generate_in_snapshot() {
    local top="$1" node_modules="" rc=0

    command -v bun >/dev/null 2>&1 \
        || die "bun is not on PATH, so the generated files can't be checked. Install bun, then commit again."
    node_modules="$(find_node_modules "$top")" \
        || die "packages/manifest has no node_modules. Run: bun install --frozen-lockfile --filter '@acfs/manifest'"

    git checkout-index -a --prefix="$WORK/tree/"
    ln -s "$node_modules" "$WORK/tree/packages/manifest/node_modules"
    snapshot_listing "$WORK/tree" > "$WORK/before"
    if ! (cd "$WORK/tree/packages/manifest" && bun run src/generate.ts) > "$WORK/generate.log" 2>&1; then
        tail -n 20 "$WORK/generate.log" >&2
        die "the generator failed on this commit's files. Fix what the log names (a generated file it no longer produces needs git rm), then commit again."
    fi
    snapshot_listing "$WORK/tree" > "$WORK/after"
    diff "$WORK/before" "$WORK/after" > "$WORK/diff" || rc=$?
    [[ "$rc" -le 1 ]] || die "could not compare the snapshot before and after generating"
    sed -n 's/^[<>] [0-9a-fx]\{1,64\}  \.\///p' "$WORK/diff" | LC_ALL=C sort -u > "$WORK/changed"
}

# The hash of a path in the snapshot listing "before" or "after"
# generating.
listed_hash() {
    awk -v path="$2" 'substr($0, 65, 4) == "  ./" && substr($0, 69) == path { print substr($0, 1, 64) }' \
        "$WORK/$1"
}

run_hook() {
    local top="$1" base="" path="" relevant=false ledgered="" index_name="" merging=false
    local -a changed_inputs=()

    git cat-file -e ":packages/manifest/src/generate.ts" 2>/dev/null || exit 0
    if base="$(git rev-parse --verify -q HEAD)"; then
        ledgered="$(ledger_keys "$base")"
    fi
    ledgered="$ledgered"$'\n'"$(ledger_keys "")"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        changed_inputs+=("$path")
        if is_generator_input "$path" "$ledgered"; then relevant=true; fi
    done < <(git diff --cached --name-only --no-renames)
    [[ "$relevant" == true ]] || exit 0

    make_work
    generate_in_snapshot "$top"
    [[ -s "$WORK/changed" ]] || exit 0

    index_name="$(basename "${GIT_INDEX_FILE:-index}")"
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then merging=true; fi
    {
        echo "check_generated: this commit's generated files don't match what its own files generate:"
        sed 's/^/  /' "$WORK/changed"
        echo "Regenerate from exactly what you commit (not the shared working tree), then commit again with the files it lists:"
        if [[ "$index_name" == next-index-* && "$merging" == false ]]; then
            printf '  bash scripts/hooks/check_generated.sh --regenerate --'
            printf ' %q' "${changed_inputs[@]}"
            printf '\n'
        else
            echo "  bash scripts/hooks/check_generated.sh --regenerate"
            echo "  (it regenerates from the index and stages what it writes; for git commit -a,"
            echo "  stage your changes first, since -a adds them only at commit time)"
        fi
    } >&2
    exit 1
}

run_regenerate() {
    local top="$1" path="" have="" caller_index="" caller_index_set=false
    shift
    local -a paths=("$@") written=() blocked=()

    # The caller's own index (a temporary one, for a commit that must leave
    # others' uncommitted lines out) is where the result is staged, so put
    # it back after the snapshot's index, never fall back to .git/index.
    if [[ -n "${GIT_INDEX_FILE+x}" ]]; then
        caller_index="$GIT_INDEX_FILE"
        caller_index_set=true
    fi
    make_work
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
    if [[ "$caller_index_set" == true ]]; then
        export GIT_INDEX_FILE="$caller_index"
    else
        unset GIT_INDEX_FILE
    fi

    if [[ ! -s "$WORK/changed" ]]; then
        echo "check_generated: the generated files are already up to date."
        return 0
    fi

    # Write back only over a working-tree copy that is the snapshot's own,
    # already the regenerated one (a re-run), or absent: anything else
    # holds work that isn't in this commit.
    while IFS= read -r path; do
        [[ -f "$WORK/tree/$path" ]] || {
            printf 'check_generated: the generator removed %s; git rm it if that is intended.\n' "$path" >&2
            continue
        }
        [[ -f "$top/$path" ]] || continue
        have="$(sha256_stdin < "$top/$path")"
        if [[ "$have" != "$(listed_hash before "$path")" && "$have" != "$(listed_hash after "$path")" ]]; then
            blocked+=("$path")
        fi
    done < "$WORK/changed"
    if [[ ${#blocked[@]} -gt 0 ]]; then
        echo "check_generated: these working-tree files hold changes that aren't in this commit, so nothing was written:" >&2
        printf '  %s\n' "${blocked[@]}" >&2
        echo "If those changes are yours (an earlier run, or your own edit), add the files to the paths you pass." >&2
        die "Otherwise commit or settle them with whoever made them, then run this again."
    fi

    while IFS= read -r path; do
        [[ -f "$WORK/tree/$path" ]] || continue
        mkdir -p "$(dirname "$top/$path")"
        cp -p "$WORK/tree/$path" "$top/$path"
        written+=("$path")
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
        grep -q "chain-runner" "$hooks_dir/pre-commit" 2>/dev/null \
            || die "$hooks_dir/hooks.d/pre-commit exists, but $hooks_dir/pre-commit isn't Agent Mail's chain-runner, so nothing would run it. Run 'am guard install' first."
        target="$hooks_dir/hooks.d/pre-commit/$HOOK_NAME"
    else
        mkdir -p "$hooks_dir"
        target="$hooks_dir/pre-commit"
    fi
    if [[ -e "$target" ]] && ! grep -qF "$INSTALL_MARK" "$target"; then
        die "$target is another hook. Add 'bash scripts/hooks/check_generated.sh --hook' to it."
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

case "$MODE" in
    install) run_install ;;
    hook) run_hook "$TOP" ;;
    regenerate) run_regenerate "$TOP" "$@" ;;
esac
