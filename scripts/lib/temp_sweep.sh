#!/usr/bin/env bash
# ============================================================
# acfs agents sweep: remove stale temp entries (acfs-6nqh)
#
# Tests, the gate and browsers leave mktemp dirs behind in /tmp and
# TMPDIR. This removes a top-level entry of a temp dir only when all
# of these hold:
#   - its name is one tests and tools make (mktemp's tmp.XXXXXX,
#     acfs-*-<random>, unit tests' acfs-*-test-artifacts-<date>-
#     <time>-<pid>, Playwright's artifact and profile dirs,
#     Chromium's .org.chromium.* and node-gyp's .<hex>-N.node-gyp),
#     or matches a --name-regex the caller adds;
#   - it is owned by the user running the sweep, and is no symlink;
#   - nothing in it changed in the last N hours (default 6);
#   - it holds no git worktree (a test's own repository is fine);
#   - no process has it, or anything in it, as its cwd, root or
#     executable, an open file or a mapped file (/proc/*).
# Names of agents' worktrees, logs, plans and locks match none of the
# built-in patterns, so the sweep never sees them.
# ============================================================

set -euo pipefail

TEMP_SWEEP_HOURS=6
TEMP_SWEEP_DRY_RUN=false
TEMP_SWEEP_DIRS=()
TEMP_SWEEP_EXTRA_REGEX=()

# A random suffix from mktemp or Python's tempfile: six or more of
# [A-Za-z0-9_], with at least one digit, capital or underscore, so
# a plain word such as acfs-plans or acfs-archive never matches.
TEMP_SWEEP_SUFFIX='[A-Za-z0-9_]*[0-9A-Z_][A-Za-z0-9_]*'
TEMP_SWEEP_BUILTIN_REGEX=(
    "^tmp\\.${TEMP_SWEEP_SUFFIX}\$"
    "^acfs[-_][A-Za-z0-9_.-]*[._-]${TEMP_SWEEP_SUFFIX}\$"
    # Unit tests' artifact dirs: acfs-<name>-test-artifacts-<date>-<time>-<pid>
    '^acfs-[a-z0-9-]*test-artifacts-[0-9]{8}-[0-9]{6}(-[0-9]+)?$'
    "^playwright-artifacts-${TEMP_SWEEP_SUFFIX}\$"
    "^playwright_[a-z]+dev_profile-${TEMP_SWEEP_SUFFIX}\$"
    '^\.org\.chromium\.Chromium\.[A-Za-z0-9]+$'
    '^\.[0-9a-f]+-[0-9]+\.node-gyp$'
)

temp_sweep_usage() {
    cat <<'USAGE'
Usage: acfs agents sweep [options]

Removes stale temp entries that tests, the gate and browsers left in
the temp dirs: only names they make, owned by you, unchanged for N
hours, holding no git worktree, and not in use by any process.

Options:
  --hours N           Leave anything changed in the last N hours
                      (default 6)
  --dir DIR           Sweep this temp dir (repeatable; default /tmp and
                      $TMPDIR)
  --name-regex ERE    Also sweep top-level names matching this extended
                      regex (repeatable)
  --dry-run           List what would be removed; remove nothing
  -h, --help          Show this help

Exit status: 0 when the sweep finished, 1 when an entry could not be
removed, 2 on bad usage.
USAGE
}

temp_sweep_die() {
    echo "acfs agents sweep: $*" >&2
    exit 2
}

temp_sweep_name_matches() {
    local name="$1" regex
    for regex in "${TEMP_SWEEP_BUILTIN_REGEX[@]}" "${TEMP_SWEEP_EXTRA_REGEX[@]}"; do
        [[ "$name" =~ $regex ]] && return 0
    done
    return 1
}

# Print the top-level names under DIR that a process uses: its cwd,
# root, executable, an open file descriptor or a mapped file.
temp_sweep_names_in_use() {
    local dir="$1" proc link target
    for proc in /proc/[0-9]*; do
        for link in "$proc/cwd" "$proc/root" "$proc/exe" "$proc"/fd/*; do
            target="$(readlink -- "$link" 2>/dev/null)" || continue
            target="${target% (deleted)}"
            [[ "$target" == "$dir"/* ]] || continue
            target="${target#"$dir"/}"
            printf '%s\n' "${target%%/*}"
        done
        # The path is the sixth field; a path with spaces keeps them.
        awk -v dir="$dir/" 'index($6, dir) == 1 {
                sub(/^[^\/]*/, ""); sub(/ \(deleted\)$/, "")
                rest = substr($0, length(dir) + 1); sub(/\/.*/, "", rest); print rest
            }' "$proc/maps" 2>/dev/null || true
    done | sort -u
}

# Why ENTRY must stay, in one pass over it: "recent" when something in
# it changed after the cutoff, "worktree" when it holds a git worktree
# (a .git file linking to a repository elsewhere, where an agent's
# uncommitted work may live), "unreadable" when find can't read all of
# it. Nothing printed: it may go. A test's own repository (a .git dir)
# is a fixture and doesn't keep it.
temp_sweep_keep_reason() {
    local entry="$1" cutoff="$2" reason
    reason="$(find "$entry" \( -newermt "@$cutoff" -printf 'recent\n' -quit \) \
        -o \( -name .git -type f -printf 'worktree\n' -quit \) 2>/dev/null)" || reason="${reason:-unreadable}"
    printf '%s' "$reason"
}

temp_sweep_dir() {
    local dir="$1" cutoff="$2" uid name entry kib reason
    local -A in_use=()
    uid="$(id -u)"
    while IFS= read -r name; do
        [[ -n "$name" ]] && in_use["$name"]=1
    done < <(temp_sweep_names_in_use "$dir")

    local -a names=()
    mapfile -t names < <(find "$dir" -mindepth 1 -maxdepth 1 -user "$uid" ! -type l -printf '%f\n' 2>/dev/null)
    for name in "${names[@]}"; do
        temp_sweep_name_matches "$name" || continue
        entry="$dir/$name"
        if [[ -n "${in_use[$name]:-}" ]]; then
            echo "keep    $entry (in use)" >&2
            continue
        fi
        reason="$(temp_sweep_keep_reason "$entry" "$cutoff")"
        case "$reason" in
            "") ;;
            recent) continue ;;
            *) echo "keep    $entry ($reason)" >&2; continue ;;
        esac
        kib="$(du -sk -- "$entry" 2>/dev/null | cut -f1)" || kib=0
        if [[ "$TEMP_SWEEP_DRY_RUN" == true ]]; then
            echo "would remove $entry (${kib:-0} KiB)"
            TEMP_SWEEP_COUNT=$((TEMP_SWEEP_COUNT + 1))
            TEMP_SWEEP_KIB=$((TEMP_SWEEP_KIB + ${kib:-0}))
            continue
        fi
        # Tests leave read-only dirs; make them removable first.
        if [[ -d "$entry" ]]; then
            chmod -R u+rwX -- "$entry" 2>/dev/null || true
        fi
        if rm -rf --one-file-system -- "$entry" && [[ ! -e "$entry" ]]; then
            echo "removed $entry (${kib:-0} KiB)"
            TEMP_SWEEP_COUNT=$((TEMP_SWEEP_COUNT + 1))
            TEMP_SWEEP_KIB=$((TEMP_SWEEP_KIB + ${kib:-0}))
        else
            echo "acfs agents sweep: could not remove $entry" >&2
            TEMP_SWEEP_ERRORS=$((TEMP_SWEEP_ERRORS + 1))
        fi
    done
}

temp_sweep_main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hours)
                [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || temp_sweep_die "--hours needs a whole number above zero"
                TEMP_SWEEP_HOURS="$2"; shift 2 ;;
            --dir) [[ $# -ge 2 ]] || temp_sweep_die "--dir needs a directory"; TEMP_SWEEP_DIRS+=("$2"); shift 2 ;;
            --name-regex) [[ $# -ge 2 && -n "$2" ]] || temp_sweep_die "--name-regex needs an extended regex"; TEMP_SWEEP_EXTRA_REGEX+=("$2"); shift 2 ;;
            --dry-run) TEMP_SWEEP_DRY_RUN=true; shift ;;
            -h|--help) temp_sweep_usage; return 0 ;;
            *) temp_sweep_usage >&2; temp_sweep_die "unknown option: $1" ;;
        esac
    done
    if [[ ${#TEMP_SWEEP_DIRS[@]} -eq 0 ]]; then
        TEMP_SWEEP_DIRS=(/tmp)
        if [[ -n "${TMPDIR:-}" ]]; then
            TEMP_SWEEP_DIRS+=("$TMPDIR")
        fi
    fi

    local cutoff dir real
    local -A seen=()
    cutoff=$(( $(date +%s) - TEMP_SWEEP_HOURS * 3600 ))
    TEMP_SWEEP_COUNT=0
    TEMP_SWEEP_KIB=0
    TEMP_SWEEP_ERRORS=0
    for dir in "${TEMP_SWEEP_DIRS[@]}"; do
        real="$(realpath -e -- "$dir" 2>/dev/null)" || temp_sweep_die "not a directory: $dir"
        [[ -d "$real" ]] || temp_sweep_die "not a directory: $dir"
        [[ "$real" != / ]] || temp_sweep_die "refusing to sweep /"
        [[ -z "${seen[$real]:-}" ]] || continue
        seen["$real"]=1
        temp_sweep_dir "$real" "$cutoff"
    done

    local verb="removed"
    [[ "$TEMP_SWEEP_DRY_RUN" == false ]] || verb="would remove"
    echo "acfs agents sweep: $verb $TEMP_SWEEP_COUNT entries, $((TEMP_SWEEP_KIB / 1024)) MiB, older than ${TEMP_SWEEP_HOURS}h" >&2
    [[ "$TEMP_SWEEP_ERRORS" -eq 0 ]]
}

temp_sweep_main "$@"
