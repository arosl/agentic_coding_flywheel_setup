#!/usr/bin/env bash
# ============================================================
# Run the CI workflows' test steps locally (acfs-t4rm)
#
# The fork's push-triggered workflows (swarm launch, entrypoint,
# herdr agents, fleet probe, ...) used to run only in CI, so they
# went red while every local gate passed. This runner reads each
# workflow under .github/workflows that runs on a push to main and
# executes its jobs' run: steps in order, the way the runner would:
# bash --noprofile --norc -eo pipefail, from the checkout (or the
# step's working-directory), with the workflow, job and step env,
# a fresh HOME and RUNNER_TEMP per job, and CI=true.
#
# It never runs what doesn't belong on a development host, and says
# so for each step it skips:
#   - workflows that test the deployed site, or apps/web, which the
#     gate runs on its own under the browser lock;
#   - jobs in a container: or with a job-level if:;
#   - steps that need root or a package manager (sudo, apt-get, pip
#     install), a container engine, or a browser install;
#   - steps that would run install.sh or acfs update on this host;
#   - steps that install a tool (cargo install, curl | bash), and the
#     rest of that job, which uses it;
#   - steps with an if: other than always()/success(), or with a
#     ${{ }} expression it can't fill in.
# uses: steps (checkout, setup-bun, setup-shellcheck) are skipped:
# run it from a gate worktree after bun install, with shellcheck
# 0.9.0 first on PATH. yamllint, which CI pip-installs, runs through
# uvx when it isn't installed.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<'USAGE'
Usage: bash scripts/tests/run_ci_workflows_locally.sh [options]

Runs the run: steps of every workflow that CI runs on a push to main.

Options:
  --root DIR        Repository to run in (default: this checkout)
  --since REF       Only workflows whose push paths match a file changed
                    between REF and HEAD (default: every push workflow)
  --workflow FILE   Only this workflow file name (repeatable)
  --list            Print the plan (run or skip, and why); run nothing
  --log-dir DIR     Keep each step's output here (default: a temp dir)
  -h, --help        Show this help

Exit status: 0 when no step failed, 1 when a step failed, 2 on bad usage.
Run it in a gate worktree at the SHA you push, after
'bun install --frozen-lockfile', with shellcheck 0.9.0 first on PATH.
USAGE
}

ROOT="$REPO_ROOT"
SINCE=""
LIST_ONLY=false
LOG_DIR=""
WORKFLOWS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --since) SINCE="${2:?--since needs a git ref}"; shift 2 ;;
        --workflow) WORKFLOWS+=("${2:?--workflow needs a file name}"); shift 2 ;;
        --list) LIST_ONLY=true; shift ;;
        --log-dir) LOG_DIR="${2:?--log-dir needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$ROOT" && pwd)"
BUN_CACHE="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
for tool in python3 jq git timeout; do
    command -v "$tool" >/dev/null 2>&1 || { echo "run_ci_workflows_locally: $tool is required" >&2; exit 2; }
done

CHANGED_FILE=""
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acfs-ci-local.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT
if [[ -n "$SINCE" ]]; then
    CHANGED_FILE="$WORK_DIR/changed"
    git -C "$ROOT" diff --name-only "$SINCE" HEAD -- >"$CHANGED_FILE"
fi
# CI pip-installs yamllint; here uvx runs it, from the caller's uv cache,
# when it isn't installed.
SHIM_DIR="$WORK_DIR/shims"
mkdir -p -- "$SHIM_DIR"
if ! command -v yamllint >/dev/null 2>&1 && command -v uvx >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\nUV_CACHE_DIR=%q exec %q yamllint "$@"\n' \
        "${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}" "$(command -v uvx)" >"$SHIM_DIR/yamllint"
    chmod +x -- "$SHIM_DIR/yamllint"
fi
# Logs outlive the run when a step failed, so a FAIL's log path stays readable.
DEFAULT_LOGS=false
if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acfs-ci-local-logs.XXXXXX")"
    DEFAULT_LOGS=true
fi
mkdir -p -- "$LOG_DIR"

# The plan: one JSON object per line, from the workflow YAML.
plan_workflows() {
    python3 -I -B - "$ROOT" "$CHANGED_FILE" "${WORKFLOWS[@]}" <<'PY'
import json, re, sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
changed_file = sys.argv[2]
only = set(sys.argv[3:])
changed = None
if changed_file:
    changed = [l for l in Path(changed_file).read_text().splitlines() if l]

EXCLUDED = {
    "production-smoke.yml": "tests the deployed site",
    "playwright.yml": "apps/web: the gate runs it under the browser lock",
    "website.yml": "apps/web: the gate runs it under the browser lock",
}
STEP_DENY = [
    (re.compile(r"\bsudo\b|\bapt(-get)?\s|\bpip3?\s+install\b"), "needs root or a package manager"),
    (re.compile(r"\b(docker|podman|incus)\b"), "needs a container engine"),
    (re.compile(r"playwright\s+install"), "installs browsers"),
    (re.compile(r"(^|[\s;&|(])acfs\s+update\b|(^|[\s;&|(])(\S*/)?acfs-update(\s|$)"), "runs acfs update on this host"),
]
TOOL_INSTALL = re.compile(r"\b(cargo|go)\s+install\b|\bbun\s+(install|add)\s+(-g|--global)\b|\bcurl\b[^\n|]*\|\s*(ba)?sh\b")

def runs_installer(script):
    """True when a command in the script executes install.sh (bash -n and
    shellcheck only read it)."""
    for command in re.split(r"[;&|\n()]+", script):
        words = command.split()
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words.pop(0)
        if not words:
            continue
        if re.search(r"(^|/)install\.sh$", words[0]):
            return True
        if words[0] in ("bash", "sh", "sudo", "exec"):
            args = words[1:]
            if "-n" in args[: next((i for i, a in enumerate(args) if not a.startswith("-")), len(args))]:
                continue
            first = next((a for a in args if not a.startswith("-")), "")
            if re.search(r"(^|/)install\.sh$", first):
                return True
    return False

def glob_re(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif pattern.startswith("**", i):
            out += ".*"; i += 2
        elif pattern[i] == "*":
            out += "[^/]*"; i += 1
        elif pattern[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile(out + r"\Z")

def push_trigger(doc):
    on = doc.get(True, doc.get("on"))
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {k: None for k in on}
    if not isinstance(on, dict) or "push" not in on:
        return None
    push = on["push"] or {}
    branches = push.get("branches")
    if branches is None and ("tags" in push or "tags-ignore" in push):
        return None
    if branches is not None and not any(glob_re(b).match("main") for b in branches):
        return None
    return push

def paths_match(push):
    if changed is None:
        return True
    paths, ignore = push.get("paths"), push.get("paths-ignore")
    for f in changed:
        if paths is not None:
            hit = False
            for p in paths:
                neg = p.startswith("!")
                if glob_re(p[1:] if neg else p).match(f):
                    hit = not neg
            if hit:
                return True
        elif ignore is not None:
            if not any(glob_re(p).match(f) for p in ignore):
                return True
        else:
            return True
    return False

EXPR = re.compile(r"\$\{\{\s*([^}]*?)\s*\}\}")

def fill(text, ctx):
    """Fill the ${{ }} expressions we know; None when one is left."""
    missing = []
    def sub(m):
        key = m.group(1)
        if key in ctx:
            return str(ctx[key])
        missing.append(key)
        return m.group(0)
    filled = EXPR.sub(sub, str(text))
    return (None, missing[0]) if missing else (filled, None)

def emit(**rec):
    print(json.dumps(rec))

for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
    wf = path.name
    if only and wf not in only:
        continue
    doc = yaml.safe_load(path.read_text()) or {}
    push = push_trigger(doc)
    if push is None:
        if only:
            emit(kind="skip-workflow", wf=wf, reason="not run on a push to main")
        continue
    if wf in EXCLUDED:
        emit(kind="skip-workflow", wf=wf, reason=EXCLUDED[wf])
        continue
    if not paths_match(push):
        emit(kind="skip-workflow", wf=wf, reason="no changed file matches its paths")
        continue
    wf_env = doc.get("env") or {}
    wf_cwd = (((doc.get("defaults") or {}).get("run") or {}).get("working-directory"))
    for job_id, job in (doc.get("jobs") or {}).items():
        job_name = str(job.get("name") or job_id)
        base = {"wf": wf, "job": job_id}
        if "container" in job:
            emit(kind="skip-job", reason="runs in a container", **base); continue
        if "if" in job:
            emit(kind="skip-job", reason=f"job if: {job['if']}", **base); continue
        if "uses" in job:
            emit(kind="skip-job", reason="calls a reusable workflow", **base); continue
        ctx = {"github.workspace": str(root), "github.sha": "LOCAL",
               "github.run_id": "0", "github.run_attempt": "1",
               "github.ref": "refs/heads/main", "github.event_name": "push",
               "runner.os": "Linux"}
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        if isinstance(matrix, dict):
            for k, v in matrix.items():
                if isinstance(v, list) and v and not isinstance(v[0], (dict, list)):
                    ctx[f"matrix.{k}"] = v[0]
        try:
            timeout = int(job.get("timeout-minutes") or 30)
        except (TypeError, ValueError):
            timeout = 30
        job_env = job.get("env") or {}
        job_cwd = (((job.get("defaults") or {}).get("run") or {}).get("working-directory")) or wf_cwd
        emit(kind="job", name=job_name, timeout=timeout, **base)
        installed_by = None
        for i, step in enumerate(job.get("steps") or [], 1):
            name = str(step.get("name") or step.get("uses") or step.get("run", "")[:60]).strip()
            srec = dict(base, kind="skip", step=i, name=name)
            if installed_by:
                emit(reason=f"step {installed_by} installs a tool the job then uses", **srec); continue
            if TOOL_INSTALL.search(str(step.get("run", ""))):
                installed_by = i
                emit(reason="installs a tool on this host", **srec); continue
            if "uses" in step:
                emit(reason=f"uses: {step['uses']}", **srec); continue
            cond = str(step.get("if", "success()")).strip()
            cond = EXPR.sub(lambda m: m.group(1), cond)
            if cond not in ("always()", "success()"):
                emit(reason=f"if: {cond}", **srec); continue
            shell = step.get("shell", "bash")
            if shell not in ("bash", "sh"):
                emit(reason=f"shell: {shell}", **srec); continue
            script, missing = fill(step.get("run", ""), ctx)
            if script is None:
                emit(reason=f"needs ${{{{ {missing} }}}}", **srec); continue
            deny = next((why for rx, why in STEP_DENY if rx.search(script)), None)
            if deny is None and runs_installer(script):
                deny = "runs install.sh on this host"
            if deny:
                emit(reason=deny, **srec); continue
            env, bad = {}, None
            for src in (wf_env, job_env, step.get("env") or {}):
                for k, v in src.items():
                    val, missing = fill(v, ctx)
                    if val is None:
                        bad = missing
                    else:
                        env[k] = val
            if bad:
                emit(reason=f"env needs ${{{{ {bad} }}}}", **srec); continue
            cwd = step.get("working-directory") or job_cwd or "."
            emit(kind="run", step=i, name=name, script=script, env=env, cwd=str(cwd),
                 always=(cond == "always()"), **base)
PY
}

PLAN="$WORK_DIR/plan.jsonl"
plan_workflows >"$PLAN"

pass=0 fail=0 skip=0
failed_steps=()
job_key="" job_failed=false job_home="" job_tmp="" job_timeout=30

start_job() {
    job_key="$1"
    job_timeout="$2"
    job_failed=false
    job_home="$(mktemp -d "$WORK_DIR/home.XXXXXX")"
    job_tmp="$(mktemp -d "$WORK_DIR/runner.XXXXXX")"
    : >"$job_tmp/GITHUB_ENV"
    : >"$job_tmp/GITHUB_OUTPUT"
    : >"$job_tmp/GITHUB_PATH"
    : >"$job_tmp/GITHUB_STEP_SUMMARY"
}

run_step() {
    local rec="$1" label="$2"
    local script cwd log
    script="$job_tmp/step.sh"
    jq -r '.script' <<<"$rec" >"$script"
    cwd="$(jq -r '.cwd' <<<"$rec")"
    [[ "$cwd" == /* ]] || cwd="$ROOT/$cwd"
    log="$LOG_DIR/$(jq -r '"\(.wf)__\(.job)__\(.step)"' <<<"$rec").log"

    # A fresh HOME per job, as on a runner; bun keeps the caller's package cache.
    local -a env_args=(
        "HOME=$job_home" "BUN_INSTALL_CACHE_DIR=$BUN_CACHE" "CI=true" "GITHUB_ACTIONS=true"
        "GITHUB_WORKSPACE=$ROOT" "GITHUB_SHA=LOCAL" "GITHUB_REF=refs/heads/main"
        "GITHUB_EVENT_NAME=push" "GITHUB_RUN_ID=0" "GITHUB_RUN_ATTEMPT=1"
        "RUNNER_TEMP=$job_tmp" "RUNNER_OS=Linux"
        "GITHUB_ENV=$job_tmp/GITHUB_ENV" "GITHUB_OUTPUT=$job_tmp/GITHUB_OUTPUT"
        "GITHUB_PATH=$job_tmp/GITHUB_PATH" "GITHUB_STEP_SUMMARY=$job_tmp/GITHUB_STEP_SUMMARY"
    )
    # Values a step wrote to GITHUB_ENV (KEY=VALUE lines), then the step's own env.
    local line
    while IFS= read -r line; do
        if [[ "$line" == *=* && "$line" != *'<<'* ]]; then
            env_args+=("$line")
        fi
    done <"$job_tmp/GITHUB_ENV"
    while IFS= read -r -d '' line; do
        env_args+=("$line")
    done < <(jq -j '.env | to_entries[] | "\(.key)=\(.value)\u0000"' <<<"$rec")
    local path_add="" dir
    while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
            path_add="$dir:$path_add"
        fi
    done <"$job_tmp/GITHUB_PATH"
    env_args+=("PATH=${path_add}${PATH}:$SHIM_DIR")

    local status=0
    (cd "$cwd" && env "${env_args[@]}" timeout "$((job_timeout * 60))" \
        bash --noprofile --norc -eo pipefail "$script") >"$log" 2>&1 </dev/null || status=$?
    if [[ $status -eq 0 ]]; then
        echo "PASS  $label"
        pass=$((pass + 1))
    else
        local why="exit $status"
        [[ $status -eq 127 ]] && why="exit 127, a command is missing here"
        [[ $status -eq 124 ]] && why="timed out after ${job_timeout} min"
        echo "FAIL  $label ($why; log $log)"
        tail -n 25 -- "$log" | sed 's/^/      | /'
        fail=$((fail + 1))
        failed_steps+=("$label")
        job_failed=true
    fi
}

while IFS= read -r rec; do
    kind="$(jq -r '.kind' <<<"$rec")"
    wf="$(jq -r '.wf' <<<"$rec")"
    case "$kind" in
        skip-workflow)
            echo "SKIP  $wf: $(jq -r '.reason' <<<"$rec")"
            skip=$((skip + 1))
            continue ;;
        skip-job)
            echo "SKIP  $wf › $(jq -r '.job' <<<"$rec"): $(jq -r '.reason' <<<"$rec")"
            skip=$((skip + 1))
            continue ;;
        job)
            $LIST_ONLY || start_job "$wf/$(jq -r '.job' <<<"$rec")" "$(jq -r '.timeout' <<<"$rec")"
            continue ;;
    esac
    label="$wf › $(jq -r '.job' <<<"$rec") › $(jq -r '.name' <<<"$rec")"
    if [[ "$kind" == "skip" ]]; then
        echo "SKIP  $label: $(jq -r '.reason' <<<"$rec")"
        skip=$((skip + 1))
    elif $LIST_ONLY; then
        echo "RUN   $label"
    elif $job_failed && [[ "$(jq -r '.always' <<<"$rec")" != "true" ]]; then
        echo "SKIP  $label: an earlier step in the job failed"
        skip=$((skip + 1))
    else
        run_step "$rec" "$label"
    fi
done <"$PLAN"

if $DEFAULT_LOGS && [[ $fail -eq 0 ]]; then
    rm -rf -- "$LOG_DIR"
fi
$LIST_ONLY && exit 0
echo
echo "run_ci_workflows_locally: $pass passed, $fail failed, $skip skipped"
if [[ $fail -gt 0 ]]; then
    printf '  failed: %s\n' "${failed_steps[@]}"
    exit 1
fi
exit 0
