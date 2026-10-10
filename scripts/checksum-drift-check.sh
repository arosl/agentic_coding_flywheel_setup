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
# Usage: scripts/checksum-drift-check.sh [--report FILE]
#   --report FILE   read a saved `security.sh --verify --json` report
#                   instead of running one
#
# Prints a Markdown report on stdout (a CI step summary takes it as is).
# Exit: 0 no drift; 1 drift (a changed installer, a fetch error or an
# incomplete entry); 2 the check itself failed.
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECURITY_SH="${ACFS_DRIFT_SECURITY_SH:-$ROOT/scripts/lib/security.sh}"
SCHEMA="acfs.installer-checksum-verification.v1"

die() {
    printf 'checksum drift check: %s\n' "$*" >&2
    exit 2
}

report_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) [[ $# -ge 2 ]] || die "--report needs a file"; report_file="$2"; shift 2 ;;
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

jq -e '[.mismatches, .errors, .skipped] | all(length == 0)' <<<"$report" >/dev/null && exit 0
exit 1
