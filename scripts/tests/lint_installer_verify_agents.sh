#!/usr/bin/env bash
# ============================================================
# Installer CI's "Verify key tools" agent checks match the manifest (acfs-9ij4)
#
# The step runs `<cli> --version` for each agent under its "# Agents"
# comment. Every such CLI must be the agent.cli of an agents.* module that
# is enabled_by_default, or the step fails on a tool the installer never
# installs (gemini, retired upstream). Every default agent must be checked.
#
# Usage: bash scripts/tests/lint_installer_verify_agents.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ACFS_LINT_WORKFLOW:-$ROOT/.github/workflows/installer.yml}"
MANIFEST="${ACFS_LINT_MANIFEST:-$ROOT/acfs.manifest.yaml}"

# "<cli> <enabled_by_default>" for each agents.* module.
mapfile -t agents < <(awk '
    /^  - id: /         { in_agent = ($3 ~ /^agents\./); enabled = "" }
    in_agent && /^    enabled_by_default:/ { enabled = $2 }
    in_agent && /^      cli:/ { print $2, enabled }
' "$MANIFEST")

# CLIs the Verify key tools step checks after its "# Agents" comment.
mapfile -t checked < <(awk '
    /- name: Verify key tools/ { in_step = 1; next }
    in_step && /^      - name:|^  [a-z]/ { in_step = 0 }
    in_step && /# Agents/ { in_agents = 1; next }
    in_step && in_agents && /^ *#/ { in_agents = 0 }
    in_step && in_agents && /su - ubuntu -c "zsh -ic \047/ {
        line = $0
        sub(/.*zsh -ic \047/, "", line)
        split(line, words, /[ \047]/)
        print words[1]
    }
' "$WORKFLOW")

errors=0
if [[ ${#agents[@]} -eq 0 ]]; then
    echo "FAIL: no agents.* modules with agent.cli found in $MANIFEST" >&2
    errors=$((errors + 1))
fi
if [[ ${#checked[@]} -eq 0 ]]; then
    echo "FAIL: no agent checks found under '# Agents' in Verify key tools ($WORKFLOW)" >&2
    errors=$((errors + 1))
fi

declare -A enabled_by_cli=()
for entry in "${agents[@]}"; do
    enabled_by_cli["${entry%% *}"]="${entry#* }"
done

for cli in "${checked[@]}"; do
    if [[ -z "${enabled_by_cli[$cli]+set}" ]]; then
        echo "FAIL: Verify key tools checks '$cli', which is no agents.* module's agent.cli" >&2
        errors=$((errors + 1))
    elif [[ "${enabled_by_cli[$cli]}" != "true" ]]; then
        echo "FAIL: Verify key tools checks '$cli', whose module is not enabled_by_default" >&2
        errors=$((errors + 1))
    fi
done

for cli in "${!enabled_by_cli[@]}"; do
    [[ "${enabled_by_cli[$cli]}" == "true" ]] || continue
    found=0
    for checked_cli in "${checked[@]}"; do
        [[ "$checked_cli" == "$cli" ]] && found=1
    done
    if [[ $found -eq 0 ]]; then
        echo "FAIL: default agent '$cli' is not checked in Verify key tools" >&2
        errors=$((errors + 1))
    fi
done

if [[ $errors -gt 0 ]]; then
    exit 1
fi
echo "OK: Verify key tools checks exactly the default agents: ${checked[*]}"
