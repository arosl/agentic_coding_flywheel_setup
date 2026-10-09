#!/usr/bin/env bash
# ============================================================
# Fork source defaults: no runtime file and no install
# instruction points at upstream ACFS
# (Dicklesworthstone/agentic_coding_flywheel_setup).
#
# The installer and acfs update choose their source from
# ACFS_REPO_OWNER, whose default is the fork's owner. An upstream
# merge can bring back an upstream default or URL without any
# textual conflict, so this test checks the whole tree, not a diff.
#
# Each allowed line is listed below by file and a fixed string,
# never by line number, with the reason it may stay. An entry that
# no longer matches any line fails the test too, so the list
# cannot go stale.
#
# Run with: bash tests/unit/test_fork_source_defaults.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Files that run, or are installed, on a user's machine: any mention
# of this repo upstream, or an upstream owner default, is flagged.
RUNTIME_PATTERN='Dicklesworthstone/agentic_coding_flywheel_setup|:-Dicklesworthstone\}|"Dicklesworthstone"'
RUNTIME_FILES=(
    install.sh
    acfs.manifest.yaml
    scripts/acfs-update
    scripts/acfs-global
    scripts/preflight.sh
    scripts/lib/*.sh
    scripts/generated/*.sh
    scripts/templates/*
)

# Install instructions: only a fetch from upstream is flagged, so
# attribution links to upstream stay allowed.
DOCS_PATTERN='(raw\.githubusercontent\.com|cdn\.jsdelivr\.net/gh|api\.github\.com/repos)/Dicklesworthstone/agentic_coding_flywheel_setup'
DOCS_FILES=(
    README.md
    docs/operations/*.md
)

# file|fixed string|reason
ALLOWED=(
    'install.sh|"$resume_repo_owner" != "Dicklesworthstone"|the acfs.sh short URL serves upstream'"'"'s installer, so the resume hint offers it only to the upstream owner'
    'scripts/lib/errors.sh|https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup/issues|an issue link; it fetches nothing'
    'scripts/lib/security.sh|https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup/issues|an issue link; it fetches nothing'
    'scripts/lib/update.sh|# See: https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup/issues/125|a comment citing the upstream issue behind the code'
    'scripts/lib/gum_ui.sh|github.com/Dicklesworthstone/agentic_coding_flywheel_setup║|attribution in the banner'
    'scripts/templates/acfs-nightly-update.service|Documentation=https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup|attribution in a unit file; systemd fetches nothing from it'
    'scripts/templates/acfs-nightly-update.timer|Documentation=https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup|attribution in a unit file; systemd fetches nothing from it'
    'scripts/templates/acfs-upgrade-resume.service|Documentation=https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup|attribution in a unit file; systemd fetches nothing from it'
    'scripts/templates/acfs-checksum-monitor.service|Dicklesworthstone/agentic_coding_flywheel_setup|upstream'"'"'s maintainer checksum monitor; nothing in install.sh, scripts/lib or the manifest installs it'
    'scripts/templates/acfs-checksum-monitor.timer|Dicklesworthstone/agentic_coding_flywheel_setup|upstream'"'"'s maintainer checksum monitor; nothing in install.sh, scripts/lib or the manifest installs it'
    'docs/operations/provider-provisioning-packet.md|raw.githubusercontent.com/Dicklesworthstone/agentic_coding_flywheel_setup/main/install.sh|an example of the packet apps/web builds, whose commandBuilder still names upstream'
)

# The fork's own one-liner must be there, so the docs check can't
# pass on a README that lost it.
FORK_ONE_LINER='https://raw.githubusercontent.com/arosl/agentic_coding_flywheel_setup/main/install.sh'

failures=0
declare -A entry_used=()

check_matches() {
    local pattern="$1"
    shift
    local match file text i entry allowed
    while IFS= read -r match; do
        [[ -n "$match" ]] || continue
        file="${match%%:*}"
        text="${match#*:}"
        text="${text#*:}"
        allowed=false
        for i in "${!ALLOWED[@]}"; do
            entry="${ALLOWED[$i]}"
            IFS='|' read -r entry_file entry_string _ <<< "$entry"
            if [[ "$file" == "$entry_file" && "$text" == *"$entry_string"* ]]; then
                entry_used[$i]=1
                allowed=true
                break
            fi
        done
        if [[ "$allowed" != true ]]; then
            printf 'FAIL: points at upstream: %s\n' "${match:0:200}"
            failures=$((failures + 1))
        fi
    done < <(grep -HnE -- "$pattern" "$@" 2>/dev/null)
}

check_matches "$RUNTIME_PATTERN" "${RUNTIME_FILES[@]}"
check_matches "$DOCS_PATTERN" "${DOCS_FILES[@]}"

for i in "${!ALLOWED[@]}"; do
    if [[ -z "${entry_used[$i]:-}" ]]; then
        printf 'FAIL: stale allowlist entry, nothing matches it: %s\n' "${ALLOWED[$i]%%|*}|$(cut -d'|' -f2 <<< "${ALLOWED[$i]}")"
        failures=$((failures + 1))
    fi
done

if ! grep -qF -- "$FORK_ONE_LINER" README.md; then
    printf 'FAIL: README.md has no install one-liner for the fork (%s)\n' "$FORK_ONE_LINER"
    failures=$((failures + 1))
fi

if [[ "$failures" -eq 0 ]]; then
    printf 'PASS: no runtime file or install instruction points at upstream (%d allowed entries in use)\n' "${#ALLOWED[@]}"
    exit 0
fi
printf '\n%d failure(s)\n' "$failures"
exit 1
