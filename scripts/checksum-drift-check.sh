#!/usr/bin/env bash
# ============================================================
# ACFS checksum drift check (report only; acfs-2iq)
#
# Compares checksums.yaml with what each pinned installer URL serves now,
# through `security.sh --verify --json`, so a stale pin is reported before
# a user's install fails on it. Pins name main-branch scripts that change
# often. It never writes checksums.yaml: the fix is the canonical refresh
# in AGENTS.md ("Verified Installer Checksum Discipline"), reviewed by hand.
# Upstream's scripts/checksum-monitor-local.sh publishes the refresh to
# upstream's repository instead; the fork does not run it.
#
# Usage: scripts/checksum-drift-check.sh [--report FILE] [--file-beads]
#   --report FILE   read a saved `security.sh --verify --json` report
#                   instead of running one
#   --file-beads    also raise each changed installer as a P1 bead in the
#                   local br queue (acfs-gwuy): one bead per installer while
#                   it is not closed, with a comment when the served hash
#                   moves again. Fetch errors and incomplete entries are
#                   reported, not filed: they are often transient.
#
# Prints a Markdown report on stdout (a CI step summary takes it as is),
# and one line per filed bead or comment on stderr.
# Exit: 0 no drift; 1 drift (a changed installer, a fetch error or an
# incomplete entry); 2 the check itself failed, or a bead could not be filed.
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECURITY_SH="${ACFS_DRIFT_SECURITY_SH:-$ROOT/scripts/lib/security.sh}"
BR="${ACFS_DRIFT_BR:-br}"
SCHEMA="acfs.installer-checksum-verification.v1"

die() {
    printf 'checksum drift check: %s\n' "$*" >&2
    exit 2
}

# Raise each changed installer in br. A bead's title starts with a fixed
# prefix per installer, so a rerun finds the bead that is still open (or in
# progress) and only comments on it when the served hash is new to it.
file_beads() {
    local name url expected actual prefix id shown desc
    command -v "$BR" >/dev/null 2>&1 || die "br not found in PATH (--file-beads)"
    while IFS=$'\t' read -r name url expected actual; do
        prefix="Checksum drift: ${name}'s pinned installer changed upstream"
        id="$("$BR" list --title-contains "$prefix" --limit 0 --json \
            | jq -r --arg p "$prefix" '[.issues[] | select(.title | startswith($p))][0].id // empty')" \
            || die "br list failed for $name"
        if [[ -n "$id" ]]; then
            shown="$("$BR" show "$id" --json)" || die "br show failed for $id"
            if jq -e --arg h "$actual" 'tostring | contains($h)' <<<"$shown" >/dev/null; then
                printf 'bead %s already names %s serving %s\n' "$id" "$name" "${actual:0:8}" >&2
                continue
            fi
            "$BR" comments add "$id" "Checksum drift check: $name now serves $actual (pinned $expected), as of $(jq -r .timestamp <<<"$report")." >/dev/null \
                || die "br comments add failed for $id"
            printf 'bead %s: commented, %s now serves %s\n' "$id" "$name" "${actual:0:8}" >&2
            continue
        fi
        desc="$(printf '%s\n' \
            "The checksum drift check found that $name's pinned installer changed upstream, so every fresh install skips it until the pin is refreshed." \
            "" \
            "- URL: $url" \
            "- Pinned: $expected" \
            "- Served: $actual" \
            "- As of: $(jq -r .timestamp <<<"$report")" \
            "" \
            "Fix: the canonical refresh in AGENTS.md (\"Verified Installer Checksum Discipline\"). Find the upstream commit whose raw installer hashes to the served value, review the installer diff from the pinned one, and have another agent run check_other_agents_work, since this changes checksums.yaml.")"
        id="$("$BR" create --title "$prefix (now ${actual:0:8})" --type bug --priority 1 \
            --description "$desc" --json | jq -r '.id // empty')" || die "br create failed for $name"
        [[ -n "$id" ]] || die "br create returned no id for $name"
        printf 'bead %s: filed, %s serves %s\n' "$id" "$name" "${actual:0:8}" >&2
    done < <(jq -r '.mismatches[] | [.name, .url, .expected, .actual] | @tsv' <<<"$report")
}

report_file=""
file_beads_wanted=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) [[ $# -ge 2 ]] || die "--report needs a file"; report_file="$2"; shift 2 ;;
        --file-beads) file_beads_wanted=true; shift ;;
        -h|--help) sed -n '3,/^# =====/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
command -v jq >/dev/null 2>&1 || die "jq not found in PATH"

if [[ -n "$report_file" ]]; then
    report="$(cat "$report_file")" || die "cannot read $report_file"
else
    # security.sh exits 1 on drift, which the report itself says; its
    # progress goes to stderr, the CI log.
    report="$("$SECURITY_SH" --verify --json)" || true
fi
jq -e --arg schema "$SCHEMA" '
    .schema == $schema
    and ([.timestamp, .checksumsYamlSha256] | all(type == "string"))
    and ([.matches, .mismatches, .errors, .skipped] | all(type == "array"))' \
    <<<"$report" >/dev/null 2>&1 \
    || die "no valid report from security.sh --verify --json"

# One table cell: a pipe escaped, line breaks as spaces.
jq -r '
    def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
    def row(f): "| " + (map(cell) | join(" | ")) + " |";
    (.matches | length) as $ok
    | (.mismatches | length) as $changed
    | (.errors | length) as $failed
    | (.skipped | length) as $incomplete
    | ($ok + $changed + $failed + $incomplete) as $total
    | "## Installer checksum drift",
      "",
      "As of \(.timestamp), against checksums.yaml \(.checksumsYamlSha256[:12]).",
      "",
      (if $changed + $failed + $incomplete == 0 then
          "No drift: all \($total) pinned installers match checksums.yaml."
       else
          "\($total) pinned installers: \($ok) match, \($changed) changed upstream, \($failed) could not be fetched, \($incomplete) incomplete.",
          (if $changed > 0 then
              "", "### Changed upstream", "",
              "| Installer | URL | Pinned | Now |", "|---|---|---|---|",
              (.mismatches[] | [.name, .url, .expected, .actual] | row(.))
           else empty end),
          (if $failed > 0 then
              "", "### Could not be fetched", "",
              "| Installer | URL | Error |", "|---|---|---|",
              (.errors[] | [.name, .url, .error] | row(.))
           else empty end),
          (if $incomplete > 0 then
              "", "### Incomplete entries", "",
              "| Installer | URL | Reason |", "|---|---|---|",
              (.skipped[] | [.name, .url, .reason] | row(.))
           else empty end),
          "",
          "To fix: run the canonical refresh in AGENTS.md (\"Verified Installer Checksum Discipline\"):",
          "`./scripts/lib/security.sh --update-checksums` to a candidate file, then review its diff",
          "against checksums.yaml before replacing it. A fetch error can be a transient outage: run this check again first."
       end)' <<<"$report"

[[ "$file_beads_wanted" == true ]] && file_beads

jq -e '[.mismatches, .errors, .skipped] | all(length == 0)' <<<"$report" >/dev/null && exit 0
exit 1
