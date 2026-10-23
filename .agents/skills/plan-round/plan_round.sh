#!/usr/bin/env bash
# ============================================================
# One plan-review round through apr, with ChatGPT Pro only when Oracle answers
#
# A plan keeps an apr workflow beside it (<plan-dir>/.apr). Each round:
#   start N    renders apr's round-N prompt, with the brief and the plan
#              inlined, to .apr/round_N.bundle.md: the prompt the round's
#              reviewers get. Oracle attaches each document after the prompt,
#              as "### File: <name>", and leaves the "<contents of ... will be
#              included by oracle>" slots of apr's default prompt empty, so
#              the prompt must name each file itself: a workflow without a
#              template of its own gets one written that names this round's
#              documents, and a template that misses one is refused. If an
#              Oracle host answers (oracle, below), start also runs
#              `apr run N --wait` in the background: a ChatGPT Pro review that
#              lands as round_N.gpt-pro.md once it finishes. The agent never
#              waits on it.
#   collect N  concatenates the reviews saved so far, round_N.<reviewer>.md in
#              the workflow's rounds directory, into round_N.md, the file
#              `apr robot integrate N`, diff and stats read. It never writes
#              over a round_N.md it did not write. Then `apr backfill --force`
#              rebuilds the workflow's metrics from every round_N.md: apr
#              records metrics only for the rounds it runs itself, so without
#              it `apr robot stats` finds none for a collected round.
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
# The line that starts the template start writes into a workflow. Everything
# from it to the end of the file is start's, and start rewrites it.
PLAN_ROUND_TEMPLATE_MARKER="# plan_round.sh's template: start rewrites it each round, from this line to the end of the file."
# What apr's default prompt holds where Oracle was once meant to fill in a file.
PLAN_ROUND_EMPTY_SLOT="will be included by oracle>"

plan_round_usage() {
    cat <<'EOF'
Usage: plan_round.sh [-C <plan-dir>] start <N>
       plan_round.sh [-C <plan-dir>] collect <N>
       plan_round.sh oracle

start    Render round N's bundle to .apr/round_N.bundle.md for the reviewers,
         writing the workflow a template that names each document if it has
         none, and start apr's own ChatGPT Pro review in the background if
         Oracle answers.
collect  Concatenate the round's reviews (round_N.<reviewer>.md) into
         round_N.md for `apr robot integrate N`, then rebuild apr's metrics
         from every round_N.md for `apr robot stats`.
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

# apr's render of round N, from its [SYSTEM] line on: Oracle prints a banner
# before the bundle.
plan_round_render() {
    local round="$1" rendered
    rendered="$(apr run "$round" --render </dev/null)" || plan_round_die "apr run $round --render failed"
    if ! grep -qx '\[SYSTEM\]' <<<"$rendered" || ! grep -qx '\[USER\]' <<<"$rendered"; then
        plan_round_die "apr's render has no [SYSTEM] and [USER] lines; not a bundle"
    fi
    sed -n '/^\[SYSTEM\]$/,$p' <<<"$rendered"
}

# The files a bundle attaches, in order: Oracle's "### File: <name>"
# headings. A document's own lines carry a line-number prefix in the bundle,
# so such a heading is always Oracle's.
plan_round_attached_files() {
    sed -n 's/^### File: //p' <<<"$1"
}

# Prints what keeps a bundle's prompt (its [USER] text, up to the first
# attached file) from naming each attached file, and returns 1. Returns 0 if
# the prompt names them all.
plan_round_unnamed() {
    local bundle="$1" prompt file
    prompt="$(awk '/^### File: / { exit } seen { print } /^\[USER\]$/ { seen = 1 }' <<<"$bundle")"
    if grep -qF -- "$PLAN_ROUND_EMPTY_SLOT" <<<"$prompt"; then
        echo "keeps apr's empty \"<contents of ... $PLAN_ROUND_EMPTY_SLOT\" slots"
        return 1
    fi
    while IFS= read -r file; do
        if ! grep -qwF -- "$file" <<<"$prompt"; then
            echo "does not name $file"
            return 1
        fi
    done < <(plan_round_attached_files "$bundle")
}

# Whether the workflow has a template that start did not write.
plan_round_has_hand_template() {
    awk -v marker="$PLAN_ROUND_TEMPLATE_MARKER" '
        $0 == marker { exit }
        /^template(_with_impl)?:/ { found = 1 }
        END { exit !found }' "$1"
}

# Prints the workflow with start's template for this round in place of the
# one start wrote before: apr's own revision prompt, naming the README, the
# implementation (when the round attaches one) and the spec as the bundle
# attaches them, in apr's order.
plan_round_with_template() {
    local workflow_file="$1" bundle="$2" readme spec impl=""
    local -a files=()
    mapfile -t files < <(plan_round_attached_files "$bundle")
    case "${#files[@]}" in
        2) readme="${files[0]}" spec="${files[1]}" ;;
        3) readme="${files[0]}" impl="${files[1]}" spec="${files[2]}" ;;
        *) plan_round_die "apr's render attaches ${#files[@]} file(s); expected the README, maybe an implementation, and the spec" ;;
    esac
    {
        awk -v marker="$PLAN_ROUND_TEMPLATE_MARKER" '$0 == marker { exit } { print }' "$workflow_file"
        printf '%s\n' \
            "$PLAN_ROUND_TEMPLATE_MARKER" \
            "# It names each document Oracle attaches after the prompt (as \"### File:" \
            "# <name>\"). To write your own template, delete these lines and add one" \
            "# that names each attached file." \
            "template: |"
        {
            printf '%s\n' \
                "This plan's documents are attached after this prompt, each under a" \
                '"### File: <name>" heading.' \
                "" \
                "First, read the README, \`$readme\`." \
                "" \
                "---"
            if [[ -n "$impl" ]]; then
                printf '%s\n' \
                    "" \
                    "And \`$impl\` is a document detailing the implementation; you should" \
                    "also keep the implementation in mind as you think about the" \
                    "specification, since ultimately the specification needs to be" \
                    "translated into code eventually!" \
                    "" \
                    "---"
            fi
            printf '%s\n' \
                "" \
                "NOW: Carefully review this entire plan, \`$spec\`, for me and come up" \
                "with your best revisions in terms of better architecture, new features," \
                "changed features, etc. to make it better, more robust/reliable, more" \
                "performant, more compelling/useful, etc." \
                "" \
                "For each proposed change, give me your detailed analysis and" \
                "rationale/justification for why it would make the project better along" \
                "with the git-diff style change versus the original plan, \`$spec\`."
        } | sed 's/^./  &/'
    }
}

plan_round_start() {
    local round="$1" workflow="$2" rounds_dir="$3"
    local bundle=".apr/round_$round.bundle.md" workflow_file=".apr/workflows/$workflow.yaml" rendered problem
    rendered="$(plan_round_render "$round")"
    if plan_round_has_hand_template "$workflow_file"; then
        if ! problem="$(plan_round_unnamed "$rendered")"; then
            plan_round_die "the template in $PWD/$workflow_file $problem; name each attached file in it (Oracle adds each after the prompt as \"### File: <name>\"), or delete it, and start writes one that does"
        fi
    else
        # Rewritten every round, not only when it misses a file: a round that
        # attaches no implementation must not be told about one.
        plan_round_with_template "$workflow_file" "$rendered" >"$workflow_file.tmp"
        if cmp -s -- "$workflow_file.tmp" "$workflow_file"; then
            rm -f -- "$workflow_file.tmp"
        else
            mv -- "$workflow_file.tmp" "$workflow_file"
            echo "template: $PWD/$workflow_file now names this round's documents"
            rendered="$(plan_round_render "$round")"
        fi
        if ! problem="$(plan_round_unnamed "$rendered")"; then
            plan_round_die "the prompt apr renders from start's template $problem"
        fi
    fi
    printf '%s\n' "$rendered" >"$bundle"
    mkdir -p "$rounds_dir"
    echo "bundle: $PWD/$bundle"
    echo "reviews: each reviewer writes $PWD/$rounds_dir/round_$round.<reviewer>.md"
    if plan_round_oracle; then
        nohup bash "$PLAN_ROUND_SELF" -C "$PWD" _gpt-pro "$round" \
            >"$rounds_dir/round_$round.gpt-pro.log" 2>&1 </dev/null &
        echo "gpt-pro: apr run $round started (log $PWD/$rounds_dir/round_$round.gpt-pro.log)"
    fi
}

# Whether a round_N.md is one collect wrote; apr's review has no marker.
plan_round_collected() {
    [[ "$(head -n 1 -- "$1")" == "$PLAN_ROUND_MARKER" ]]
}

# apr writes its review to round_N.md itself, so it is moved aside to
# round_N.gpt-pro.md, and the round collected again with it. --wait keeps apr
# in the foreground until Oracle has written the review: without it, apr
# returns while Oracle runs on, and the move finds nothing.
plan_round_gpt_pro() {
    local round="$1" workflow="$2" rounds_dir="$3" review="$3/round_$1.md" rc=0
    apr run "$round" --wait </dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "gpt-pro: apr run $round --wait failed (exit $rc); the round goes on without it"
        return "$rc"
    fi
    if [[ -f "$review" ]] && ! plan_round_collected "$review"; then
        mv -- "$review" "$rounds_dir/round_$round.gpt-pro.md"
    fi
    plan_round_collect "$round" "$workflow" "$rounds_dir"
}

# Rebuilds the workflow's metrics from every round_N.md. Without --force,
# backfill refuses once metrics exist, so it would cover only the first
# collected round. A failure costs only the convergence signal, so it is
# reported and the collected round stands.
plan_round_backfill() {
    local workflow="$1" out rc=0
    out="$(apr backfill "$workflow" --force </dev/null 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "metrics: apr backfill $workflow --force failed (exit $rc), so apr robot stats may not count this round:"
        printf '%s\n' "$out" | tail -n 3 | sed 's/^/  /'
        return 0
    fi
    echo "metrics: apr backfill rebuilt $workflow's metrics from every round_N.md, for apr robot stats"
    if ! command -v bc >/dev/null 2>&1; then
        echo "metrics: bc is not installed, so every convergence signal of apr robot stats stays 0.0; install bc"
    fi
}

plan_round_collect() {
    local round="$1" workflow="$2" rounds_dir="$3" review reviewer collected="$3/round_$1.md"
    local -a reviews=()
    if [[ -f "$collected" ]] && ! plan_round_collected "$collected"; then
        plan_round_die "$PWD/$collected is not one collect wrote (its first line is not $PLAN_ROUND_MARKER), so collect leaves it: move it to round_$round.gpt-pro.md if it is ChatGPT Pro's review, or to round_$round.<reviewer>.md if another reviewer's, and collect again"
    fi
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
    } >"$collected.tmp"
    mv -- "$collected.tmp" "$collected"
    echo "collected ${#reviews[@]} review(s) into $PWD/$collected"
    plan_round_backfill "$workflow"
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
        collect) plan_round_collect "$round" "$workflow" "$rounds_dir" ;;
        _gpt-pro) plan_round_gpt_pro "$round" "$workflow" "$rounds_dir" ;;
    esac
}

plan_round_main "$@"
