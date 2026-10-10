#!/usr/bin/env bash
# ============================================================
# Unit tests for the repo's agent skills (.agents/skills)
#
# Codex reads .agents/skills; Claude Code reads .claude/skills,
# a symlink to it. Each skill points at a palette prompt or a
# jfp prompt by name, so both names must still resolve.
# ============================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.agents/skills"
PALETTE="$REPO_ROOT/acfs/onboard/docs/ntm/command_palette.md"

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "PASS: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Reason: $2"
    fi
    return 0
}

# The value of a top-level key in a SKILL.md's frontmatter.
frontmatter_value() {
    local file="$1" key="$2"
    awk -v key="$key" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        NR > 1 && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
    ' "$file"
}

test_claude_skills_link() {
    local link="$REPO_ROOT/.claude/skills"
    if [[ ! -L "$link" ]]; then
        fail ".claude/skills is a symlink" "not a symlink: $link"
    elif [[ "$(readlink "$link")" != "../.agents/skills" ]]; then
        fail ".claude/skills is a symlink" "points at $(readlink "$link"), not ../.agents/skills"
    else
        pass ".claude/skills links to ../.agents/skills"
    fi
}

test_skill_frontmatter() {
    local skill_md dir name description count=0
    for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
        [[ -e "$skill_md" ]] || continue
        count=$((count + 1))
        dir="$(basename "$(dirname "$skill_md")")"
        name="$(frontmatter_value "$skill_md" name)"
        description="$(frontmatter_value "$skill_md" description)"
        if [[ "$name" != "$dir" ]]; then
            fail "$dir: frontmatter name matches its directory" "name is '$name'"
        elif [[ -z "$description" ]]; then
            fail "$dir: frontmatter has a description"
        else
            pass "$dir: frontmatter name and description"
        fi
    done
    if [[ "$count" -eq 0 ]]; then
        fail "skills exist" "no SKILL.md under $SKILLS_DIR"
    fi
}

test_palette_keys_resolve() {
    local skill_md key
    while IFS=: read -r skill_md key; do
        if grep -q "^### $key | " "$PALETTE"; then
            pass "$(basename "$(dirname "$skill_md")"): palette prompt $key exists"
        else
            fail "$(basename "$(dirname "$skill_md")"): palette prompt $key exists" "no '### $key | ' heading in the palette"
        fi
    done < <(grep -o -H "/\^### [a-z_]* /" "$SKILLS_DIR"/*/SKILL.md | sed -E 's|/\^### ([a-z_]*) /$|\1|')
}

test_jfp_ids_resolve() {
    local skill_md id
    if ! command -v jfp >/dev/null 2>&1; then
        echo "SKIP: jfp not installed; jfp prompt ids not checked"
        return 0
    fi
    while IFS=: read -r skill_md id; do
        if jfp show "$id" --json >/dev/null 2>&1; then
            pass "$(basename "$(dirname "$skill_md")"): jfp prompt $id exists"
        else
            fail "$(basename "$(dirname "$skill_md")"): jfp prompt $id exists" "jfp show $id failed"
        fi
    done < <(grep -o -H "jfp show [a-z0-9-]*" "$SKILLS_DIR"/*/SKILL.md | sed -E 's|jfp show ||')
}

test_claude_skills_link
test_skill_frontmatter
test_palette_keys_resolve
test_jfp_ids_resolve

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
