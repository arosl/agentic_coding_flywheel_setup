#!/usr/bin/env bash
# ============================================================
# scripts/hooks/check_generated.sh (acfs-s3tl) against fixture repos
#
# A stub bun stands in for the generator in a small fixture repo: it
# writes a ledger of the fixture's ledgered files. The check must refuse
# a commit whose ledger is stale, judge only what is committed (never the
# working tree), and print the command that fixes it. The last case runs
# the real generator in a shared clone of this checkout's HEAD; it skips
# without bun or packages/manifest/node_modules.
#
# Usage: bash tests/unit/test_check_generated.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/hooks/check_generated.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-check-generated-test.XXXXXX")"
cleanup() {
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

OUT="$WORK/out"
ERR="$WORK/err"
BIN="$WORK/bin"
CALLS="$WORK/bun-calls"
mkdir -p "$BIN"

# The stub generator: a ledger of the two ledgered fixture files, hashed
# from the tree it runs in.
cat > "$BIN/bun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$PWD $*" >> "$STUB_BUN_CALLS"
[[ "$*" == "run src/generate.ts" ]] || exit 2
root="$(cd ../.. && pwd)"
{
    echo "ACFS_INTERNAL_CHECKSUMS_COUNT=2"
    for f in acfs.manifest.yaml scripts/lib/a.sh; do
        printf '  [%s]="%s"\n' "$f" "$(sha256sum < "$root/$f" | cut -d' ' -f1)"
    done
} > "$root/scripts/generated/internal_checksums.sh"
EOF
chmod +x "$BIN/bun"
export STUB_BUN_CALLS="$CALLS"
export PATH="$BIN:$PATH"

git_fixture() { git -C "$REPO" "$@"; }

# A fresh fixture repo with an up-to-date ledger and the check installed.
make_repo() {
    REPO="$WORK/repo"
    rm -rf "$REPO"
    mkdir -p "$REPO/scripts/lib" "$REPO/scripts/generated" "$REPO/scripts/hooks" \
        "$REPO/packages/manifest/src" "$REPO/packages/manifest/node_modules" "$REPO/docs"
    git_fixture init -q -b main
    git_fixture config user.name fixture
    git_fixture config user.email fixture@example.invalid
    printf 'node_modules/\n' > "$REPO/.gitignore"
    echo "modules: []" > "$REPO/acfs.manifest.yaml"
    echo "echo a" > "$REPO/scripts/lib/a.sh"
    echo "echo b" > "$REPO/scripts/lib/b.sh"
    echo "notes" > "$REPO/docs/notes.md"
    echo "// generator" > "$REPO/packages/manifest/src/generate.ts"
    cp "$CHECK" "$REPO/scripts/hooks/check_generated.sh"
    (cd "$REPO/packages/manifest" && bun run src/generate.ts)
    git_fixture add -A
    git_fixture commit -q -m base
    (cd "$REPO" && bash scripts/hooks/check_generated.sh --install) > /dev/null
    : > "$CALLS"
}

commit_paths() {
    (cd "$REPO" && git commit -q -m change -- "$@") > "$OUT" 2> "$ERR"
}

refused() { ! commit_paths "$@"; }
err_has() { grep -qF -- "$1" "$ERR"; }
out_has() { grep -qF -- "$1" "$OUT"; }
generator_not_run() { [[ ! -s "$CALLS" ]]; }
ledger_matches_commit() {
    local want=""
    want="$(git_fixture show HEAD:scripts/lib/a.sh | sha256sum | cut -d' ' -f1)"
    git_fixture show HEAD:scripts/generated/internal_checksums.sh | grep -qF "[scripts/lib/a.sh]=\"$want\""
}
committed() { [[ "$(git_fixture log -1 --format=%s)" == change ]]; }

echo "unrelated commit"
make_repo
echo "more" >> "$REPO/docs/notes.md"
echo "echo b2" > "$REPO/scripts/lib/b.sh"
check "a commit of unledgered files passes" commit_paths docs/notes.md scripts/lib/b.sh
check "it does not run the generator" generator_not_run

echo "stale ledger"
make_repo
echo "echo a2" > "$REPO/scripts/lib/a.sh"
check "a ledgered change without regenerating is refused" refused scripts/lib/a.sh
check "the refusal names the stale file" err_has "scripts/generated/internal_checksums.sh"
check "the refusal names the fixing command" \
    err_has "bash scripts/hooks/check_generated.sh --regenerate -- scripts/lib/a.sh"
check "the refused commit left HEAD alone" [ "$(git_fixture log -1 --format=%s)" == base ]

echo "regenerate, then commit"
(cd "$REPO" && bash scripts/hooks/check_generated.sh --regenerate -- scripts/lib/a.sh) > "$OUT" 2> "$ERR"
check "--regenerate lists the ledger" out_has "scripts/generated/internal_checksums.sh"
check "--regenerate prints the commit command" \
    out_has "git commit -- scripts/lib/a.sh scripts/generated/internal_checksums.sh"
check "--regenerate leaves the index alone with paths" \
    [ -z "$(git_fixture diff --cached --name-only)" ]
check "the commit with the regenerated ledger passes" \
    commit_paths scripts/lib/a.sh scripts/generated/internal_checksums.sh
check "the committed ledger hashes the committed file" ledger_matches_commit

echo "the working tree doesn't leak in"
make_repo
echo "modules: [x]" > "$REPO/acfs.manifest.yaml"
echo "echo a3" > "$REPO/scripts/lib/a.sh"
(cd "$REPO" && bash scripts/hooks/check_generated.sh --regenerate -- scripts/lib/a.sh) > /dev/null
check "a pathspec commit passes despite another agent's unstaged ledgered edit" \
    commit_paths scripts/lib/a.sh scripts/generated/internal_checksums.sh
check "its ledger hashes the committed manifest, not the edited one" \
    bash -c "git -C '$REPO' show HEAD:scripts/generated/internal_checksums.sh \
        | grep -qF \"[acfs.manifest.yaml]=\\\"\$(git -C '$REPO' show HEAD:acfs.manifest.yaml | sha256sum | cut -d' ' -f1)\\\"\""
check "the edited manifest stays uncommitted in the working tree" \
    [ "$(cat "$REPO/acfs.manifest.yaml")" == "modules: [x]" ]

echo "a staged index commit"
make_repo
echo "echo a4" > "$REPO/scripts/lib/a.sh"
git_fixture add scripts/lib/a.sh
check "a plain commit of a staged ledgered change is refused" \
    bash -c "cd '$REPO' && ! git commit -q -m change 2> '$ERR'"
(cd "$REPO" && bash scripts/hooks/check_generated.sh --regenerate) > "$OUT" 2> "$ERR"
check "--regenerate without paths stages the ledger" \
    [ "$(git_fixture diff --cached --name-only | tr '\n' ' ')" == "scripts/generated/internal_checksums.sh scripts/lib/a.sh " ]
check "the plain commit then passes" bash -c "cd '$REPO' && git commit -q -m change"
check "and its ledger matches" ledger_matches_commit

echo "hand-edited generated file"
make_repo
sed -i 's/="[0-9a-f]*"$/="0000000000000000000000000000000000000000000000000000000000000000"/' \
    "$REPO/scripts/generated/internal_checksums.sh"
check "a hand-edited ledger is refused" refused scripts/generated/internal_checksums.sh

echo "no bun"
make_repo
echo "echo a5" > "$REPO/scripts/lib/a.sh"
check "a relevant commit without bun is refused" \
    bash -c "cd '$REPO' && ! PATH=/usr/bin:/bin git commit -q -m change -- scripts/lib/a.sh 2> '$ERR'"
check "the refusal says bun is missing" err_has "bun is not on PATH"

echo "install"
make_repo
hooks="$REPO/.git/hooks"
check "--install writes a plain pre-commit hook without Agent Mail" grep -qF -- "--hook" "$hooks/pre-commit"
check "--install is idempotent" bash -c "cd '$REPO' && bash scripts/hooks/check_generated.sh --install > /dev/null"
mv "$hooks/pre-commit" "$WORK/plain-hook"
printf '#!/usr/bin/env python3\n# mcp-agent-mail chain-runner (pre-commit)\n' > "$hooks/pre-commit"
mkdir -p "$hooks/hooks.d/pre-commit"
(cd "$REPO" && bash scripts/hooks/check_generated.sh --install) > "$OUT"
check "--install joins Agent Mail's chain" test -x "$hooks/hooks.d/pre-commit/40-acfs-check-generated"
check "--install leaves Agent Mail's runner alone" grep -qF "chain-runner" "$hooks/pre-commit"
rm -rf "$hooks/hooks.d"
check "--install refuses to replace another hook" \
    bash -c "cd '$REPO' && ! bash scripts/hooks/check_generated.sh --install 2> '$ERR'"
check "usage errors exit 2" \
    bash -c "cd '$REPO' && bash scripts/hooks/check_generated.sh --hook extra 2> /dev/null; [ \$? -eq 2 ]"

echo "the real generator"
REAL_BUN="$(PATH="${PATH#"$BIN:"}" command -v bun || true)"
if [[ -z "$REAL_BUN" || ! -d "$ROOT/packages/manifest/node_modules" ]]; then
    skip "needs bun and packages/manifest/node_modules"
else
    CLONE="$WORK/clone"
    git clone -q --shared --no-checkout "$ROOT" "$CLONE"
    git -C "$CLONE" checkout -q --detach "$(git -C "$ROOT" rev-parse HEAD)"
    git -C "$CLONE" config user.name fixture
    git -C "$CLONE" config user.email fixture@example.invalid
    ln -s "$ROOT/packages/manifest/node_modules" "$CLONE/packages/manifest/node_modules"
    cp "$CHECK" "$CLONE/scripts/hooks/check_generated.sh"
    real_path="$(dirname "$REAL_BUN"):/usr/bin:/bin"
    (cd "$CLONE" && PATH="$real_path" bash scripts/hooks/check_generated.sh --install) > /dev/null
    echo "# acfs-s3tl test" >> "$CLONE/scripts/lib/logging.sh"
    check "the real generator refuses a stale ledger" \
        bash -c "cd '$CLONE' && ! PATH='$real_path' git commit -q -m t -- scripts/lib/logging.sh 2> '$ERR'"
    check "and names internal_checksums.sh" err_has "scripts/generated/internal_checksums.sh"
    (cd "$CLONE" && PATH="$real_path" bash scripts/hooks/check_generated.sh --regenerate -- scripts/lib/logging.sh) > "$OUT"
    regenerated="$(sed -n 's/^  //p' "$OUT" | tr '\n' ' ')"
    check "the regenerated commit passes" \
        bash -c "cd '$CLONE' && PATH='$real_path' git commit -q -m t -- scripts/lib/logging.sh $regenerated"
    check "the clone's HEAD then needs no regeneration" \
        bash -c "cd '$CLONE/packages/manifest' && PATH='$real_path' bun run src/generate.ts --diff > /dev/null 2>&1"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
