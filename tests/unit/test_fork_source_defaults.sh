#!/usr/bin/env bash
# ============================================================
# Fork source defaults: no runtime file and no install
# instruction points at upstream ACFS
# (Dicklesworthstone/agentic_coding_flywheel_setup), or at a short
# URL that serves upstream's installer.
#
# The installer and acfs update choose their source from
# ACFS_REPO_OWNER, whose default is the fork's owner. An upstream
# merge can bring back an upstream default or URL without any
# textual conflict, so this test checks files, not a diff: the
# installer and the scripts it runs, every file the installer
# fetches through $ACFS_RAW (found by reading the installer, so a
# newly fetched file is checked too), and the install instructions.
# A listed path that no longer exists fails the test.
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

# Upstream's short install URLs: both serve upstream's install.sh
# (agent-flywheel.com/install through apps/web/app/install/route.ts).
UPSTREAM_SHORT_URLS='agent-flywheel\.com/install|https://acfs\.sh'

# Files that run, or are installed, on a user's machine: any mention
# of this repo upstream, an upstream owner default, or a short URL
# that installs upstream is flagged.
RUNTIME_PATTERN="Dicklesworthstone/agentic_coding_flywheel_setup|:-Dicklesworthstone\\}|\"Dicklesworthstone\"|${UPSTREAM_SHORT_URLS}"
RUNTIME_FILES=(
    install.sh
    acfs.manifest.yaml
    scripts/acfs-update
    scripts/acfs-global
    scripts/preflight.sh
    scripts/lib/*.sh
    scripts/generated/*.sh
    scripts/templates/*
    scripts/completions/*
    acfs/zsh/*
    packages/onboard/onboard.sh
)

# Every file the installer and the scripts it runs fetch through
# $ACFS_RAW and place on the user's machine.
INSTALLER_SOURCES=(install.sh acfs.manifest.yaml scripts/lib/*.sh scripts/generated/*.sh)
mapfile -t RAW_FETCHED < <(
    grep -hoE 'ACFS_RAW\}?/[A-Za-z0-9_./-]+' "${INSTALLER_SOURCES[@]}" \
        | sed -E 's#^ACFS_RAW\}?/##' | sort -u
)
RUNTIME_FILES+=("${RAW_FETCHED[@]}")

# Install instructions: only a fetch from upstream is flagged, so
# attribution links to upstream stay allowed.
DOCS_PATTERN="(raw\\.githubusercontent\\.com|cdn\\.jsdelivr\\.net/gh|api\\.github\\.com/repos)/Dicklesworthstone/agentic_coding_flywheel_setup|${UPSTREAM_SHORT_URLS}"
DOCS_FILES=(
    README.md
    docs/operations/*.md
)

# file|fixed string|reason
ALLOWED=(
    'install.sh|"$resume_repo_owner" != "Dicklesworthstone"|the acfs.sh short URL serves upstream'"'"'s installer, so the resume hint offers it only to the upstream owner'
    'install.sh|install_url="https://acfs.sh"|the resume hint'"'"'s branch for the upstream owner and name only; every other owner gets the raw URL'
    'install.sh|local fallback_url="https://acfs.sh"|print_resume_hint'"'"'s fallback; the lines after it replace it with the raw URL for any owner or name other than upstream'"'"'s'
    'scripts/lib/report.sh|install_url="https://acfs.sh"|unreachable: only install.sh sources report.sh, and it always sets ACFS_RAW, whose branch comes first'
    'scripts/lib/errors.sh|https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup/issues|an issue link; it fetches nothing'
    'scripts/lib/security.sh|https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup/issues|an issue link; it fetches nothing'
    'scripts/lib/update.sh|# See: https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup/issues/125|a comment citing the upstream issue behind the code'
    'scripts/lib/gum_ui.sh|github.com/Dicklesworthstone/agentic_coding_flywheel_setup║|attribution in the banner'
    'acfs/AGENTS.md|[Agentic Coding Flywheel Setup (ACFS)](https://github.com/Dicklesworthstone/agentic_coding_flywheel_setup)|attribution in the workspace AGENTS.md template; it fetches nothing'
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
    done < <(grep -HnE -- "$pattern" "$@")
}

# Each listed path must exist: a renamed file, or a glob that matches
# nothing, would otherwise drop out of the check without a sound.
runtime_present=()
docs_present=()
mapfile -t runtime_listed < <(printf '%s\n' "${RUNTIME_FILES[@]}" | sort -u)
for path in "${runtime_listed[@]}" "${DOCS_FILES[@]}"; do
    if [[ ! -f "$path" ]]; then
        printf 'FAIL: listed path does not exist: %s\n' "$path"
        failures=$((failures + 1))
    fi
done
for path in "${runtime_listed[@]}"; do
    [[ -f "$path" ]] && runtime_present+=("$path")
done
for path in "${DOCS_FILES[@]}"; do
    [[ -f "$path" ]] && docs_present+=("$path")
done

check_matches "$RUNTIME_PATTERN" "${runtime_present[@]}"
check_matches "$DOCS_PATTERN" "${docs_present[@]}"

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
