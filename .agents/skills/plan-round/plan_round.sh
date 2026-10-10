#!/usr/bin/env bash
# ============================================================
# One plan-review round through apr, with ChatGPT Pro only when Oracle answers
#
# A plan keeps an apr workflow beside it (<plan-dir>/.apr). Each round:
#   start N    renders apr's round-N prompt, with the brief and the plan
#              inlined, to .apr/round_N.bundle.md: the prompt the round's
#              reviewers get. If an Oracle host answers (oracle, below), it
#              also starts `apr run N` in the background: a ChatGPT Pro review
#              that lands as round_N.gpt-pro.md once it finishes. Nothing ever
#              waits on it.
#   collect N  concatenates the reviews saved so far, round_N.<reviewer>.md in
#              the workflow's rounds directory, into round_N.md, the file
#              `apr robot integrate N`, diff and stats read.
#   oracle     says whether the Oracle host in $ORACLE_REMOTE_HOST (with
#              $ORACLE_REMOTE_TOKEN, as `oracle serve` printed them) answers
#              its /health check: exit 0 if it does, 1 with the reason if not.
#
# Usage: plan_round.sh [-C <plan-dir>] start|collect <N>
#        plan_round.sh oracle
# ============================================================

set -euo pipefail

PLAN_ROUND_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# The first line of a file collect writes; a round_N.md without it is apr's.
PLAN_ROUND_MARKER="<!-- collected by plan_round.sh -->"

plan_round_usage() {
    cat <<'EOF'
Usage: plan_round.sh [-C <plan-dir>] start <N>
       plan_round.sh [-C <plan-dir>] collect <N>
       plan_round.sh oracle

start    Render round N's bundle to .apr/round_N.bundle.md for the reviewers,
         and start apr's own ChatGPT Pro review in the background if Oracle
         answers.
collect  Concatenate the round's reviews (round_N.<reviewer>.md) into
         round_N.md for `apr robot integrate N`.
oracle   Exit 0 if the Oracle host in $ORACLE_REMOTE_HOST answers, 1 if not.

-C       The plan directory, which holds .apr (default: the current one).
EOF
}

plan_round_die() {
    printf 'plan_round: %s\n' "$*" >&2
    exit 2
}

# Prints why ChatGPT Pro is skipped and returns 1, or prints the host and
# returns 0.
plan_round_oracle() {
    local host="${ORACLE_REMOTE_HOST:-}" token="${ORACLE_REMOTE_TOKEN:-}" body
    if [[ -z "$host" ]]; then
        echo "gpt-pro: skipped (ORACLE_REMOTE_HOST is not set)"
        return 1
    fi
    if [[ -z "$token" ]]; then
        echo "gpt-pro: skipped (ORACLE_REMOTE_TOKEN is not set for $host)"
        return 1
    fi
    if ! body="$(curl -sS --max-time 5 -H "Authorization: Bearer $token" "http://$host/health" 2>&1)"; then
        echo "gpt-pro: skipped ($host does not answer: ${body##*: })"
        return 1
    fi
    if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$body"; then
        echo "gpt-pro: skipped ($host answers, but its /health is not ok: ${body:0:200})"
        return 1
    fi
    echo "gpt-pro: $host answers"
}

# The workflow's name and rounds directory, from apr's config.
plan_round_workflow() {
    [[ -f .apr/config.yaml ]] || return 0
    awk '$1 == "default_workflow:" { gsub(/"/, "", $2); print $2; exit }' .apr/config.yaml
}

plan_round_rounds_dir() {
    local workflow="$1" dir=""
    if [[ -f ".apr/workflows/$workflow.yaml" ]]; then
        dir="$(awk '$1 == "output_dir:" { gsub(/"/, "", $2); print $2; exit }' ".apr/workflows/$workflow.yaml")"
    fi
    printf '%s\n' "${dir:-.apr/rounds/$workflow}"
}

plan_round_start() {
    local round="$1" workflow="$2" rounds_dir="$3"
    local bundle=".apr/round_$round.bundle.md" rendered
    rendered="$(apr run "$round" --render </dev/null)" || plan_round_die "apr run $round --render failed"
    # Oracle prints a banner before the bundle, which starts at [SYSTEM].
    if ! grep -qx '\[SYSTEM\]' <<<"$rendered"; then
        plan_round_die "apr's render has no [SYSTEM] line; not a bundle"
    fi
    sed -n '/^\[SYSTEM\]$/,$p' <<<"$rendered" >"$bundle"
    mkdir -p "$rounds_dir"
    echo "bundle: $PWD/$bundle"
    echo "reviews: each reviewer writes $PWD/$rounds_dir/round_$round.<reviewer>.md"
    if plan_round_oracle; then
        nohup bash "$PLAN_ROUND_SELF" -C "$PWD" _gpt-pro "$round" \
            >"$rounds_dir/round_$round.gpt-pro.log" 2>&1 </dev/null &
        echo "gpt-pro: apr run $round started (log $PWD/$rounds_dir/round_$round.gpt-pro.log)"
    fi
}

# apr writes its review to round_N.md itself, so it is moved aside to
# round_N.gpt-pro.md, and the round collected again with it.
plan_round_gpt_pro() {
    local round="$1" rounds_dir="$2"
    apr run "$round" </dev/null
    if [[ -f "$rounds_dir/round_$round.md" ]] && [[ "$(head -n 1 "$rounds_dir/round_$round.md")" != "$PLAN_ROUND_MARKER" ]]; then
        mv -- "$rounds_dir/round_$round.md" "$rounds_dir/round_$round.gpt-pro.md"
    fi
    plan_round_collect "$round" "$rounds_dir"
}

plan_round_collect() {
    local round="$1" rounds_dir="$2" review reviewer
    local -a reviews=()
    for review in "$rounds_dir/round_$round".*.md; do
        [[ -f "$review" ]] && reviews+=("$review")
    done
    if [[ "${#reviews[@]}" -eq 0 ]]; then
        plan_round_die "no reviews in $rounds_dir (round_$round.<reviewer>.md)"
    fi
    {
        echo "$PLAN_ROUND_MARKER"
        echo "# Round $round reviews"
        for review in "${reviews[@]}"; do
            reviewer="${review##*/round_"$round".}"
            reviewer="${reviewer%.md}"
            printf '\n## Reviewer: %s\n\n' "$reviewer"
            cat -- "$review"
        done
    } >"$rounds_dir/round_$round.md.tmp"
    mv -- "$rounds_dir/round_$round.md.tmp" "$rounds_dir/round_$round.md"
    echo "collected ${#reviews[@]} review(s) into $PWD/$rounds_dir/round_$round.md"
    if [[ -f "$rounds_dir/round_$round.gpt-pro.log" && ! -f "$rounds_dir/round_$round.gpt-pro.md" ]]; then
        echo "gpt-pro: still running or failed (see round_$round.gpt-pro.log); not waited for"
    fi
}

plan_round_main() {
    local plan_dir="." command round workflow rounds_dir
    if [[ "${1:-}" == "-C" ]]; then
        [[ $# -ge 2 ]] || plan_round_die "-C needs a directory"
        plan_dir="$2"
        shift 2
    fi
    command="${1:-}"
    case "$command" in
        oracle)
            plan_round_oracle
            return
            ;;
        start | collect | _gpt-pro) ;;
        -h | --help)
            plan_round_usage
            return 0
            ;;
        *)
            plan_round_usage >&2
            exit 2
            ;;
    esac
    round="${2:-}"
    [[ "$round" =~ ^[1-9][0-9]*$ ]] || plan_round_die "$command needs a round number"
    cd -- "$plan_dir" || plan_round_die "no plan directory $plan_dir"
    workflow="$(plan_round_workflow)"
    [[ -n "$workflow" ]] || plan_round_die "no apr workflow in $PWD/.apr (run apr setup there)"
    rounds_dir="$(plan_round_rounds_dir "$workflow")"
    case "$command" in
        start) plan_round_start "$round" "$workflow" "$rounds_dir" ;;
        collect) plan_round_collect "$round" "$rounds_dir" ;;
        _gpt-pro) plan_round_gpt_pro "$round" "$rounds_dir" ;;
    esac
}

plan_round_main "$@"
