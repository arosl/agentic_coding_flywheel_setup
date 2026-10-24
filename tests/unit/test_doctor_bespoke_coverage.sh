#!/usr/bin/env bash
# ============================================================
# The doctor's bespoke checks cover what its manifest checks skip
#
# _is_bespoke_covered skips every cli.modern.* manifest check as covered by
# check_shell and check_core_tools, so each binary a required cli.modern
# check names needs a bespoke check_command (acfs-5mkj: bc and age;
# acfs-n3uo: jq, from upstream's #474). This reads only the generated
# doctor_checks.sh and doctor.sh, so it runs anywhere, CI's runners
# included; tests/unit/test_doctor_generated.sh runs the doctor itself and
# needs an installed host.
#
# Run with: bash tests/unit/test_doctor_bespoke_coverage.sh
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/vm/lib/test_harness.sh
source "$REPO_ROOT/tests/vm/lib/test_harness.sh"

# _is_bespoke_covered skips every cli.modern.* manifest check as covered by
# check_shell and check_core_tools. A binary that a required cli.modern check
# names, and no bespoke check_command names, is never checked (acfs-5mkj: bc
# and age weren't).
test_cli_modern_binaries_have_bespoke_checks() {
    harness_section "Test: cli.modern's required binaries have bespoke doctor checks"

    local checks_file="$REPO_ROOT/scripts/generated/doctor_checks.sh"
    local doctor_file="$REPO_ROOT/scripts/lib/doctor.sh"
    local re_command_v='^command -v ([^[:space:]]+)$'
    local re_first_word='^([^[:space:]|&;]+)( [^|&;]*)?$'
    local line="" id="" desc="" cmd="" req_flag="" run_as="" bin=""
    local checked=0 missing=0

    while IFS= read -r line; do
        line="${line#*\"}"
        line="${line%\"*}"
        IFS=$'\t' read -r id desc cmd req_flag run_as <<< "$line"
        [[ "$req_flag" == "required" ]] || continue
        if [[ "$cmd" =~ $re_command_v ]] || [[ "$cmd" =~ $re_first_word ]]; then
            bin="${BASH_REMATCH[1]}"
        else
            harness_fail "$id: can't tell which binary '$cmd' checks"
            missing=$((missing + 1))
            continue
        fi
        checked=$((checked + 1))
        if ! grep -Eq "check_(optional_)?command \"[^\"]+\" \"[^\"]*\" \"$bin\"" "$doctor_file"; then
            harness_fail "$id ($cmd): no bespoke check_command names $bin, and the doctor skips $id"
            missing=$((missing + 1))
        fi
    done < <(grep -E $'^[[:space:]]+"cli\\.modern\\.[0-9]+\t' "$checks_file")

    if [[ "$checked" -eq 0 ]]; then
        harness_fail "no required cli.modern checks found in $checks_file"
    elif [[ "$missing" -eq 0 ]]; then
        harness_pass "all $checked required cli.modern binaries have a bespoke doctor check"
    fi
}

main() {
    harness_init "Doctor Bespoke Coverage Tests"
    test_cli_modern_binaries_have_bespoke_checks
    harness_summary
}

main "$@"
