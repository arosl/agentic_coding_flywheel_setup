#!/usr/bin/env bash
# ============================================================
# acfs machine: the entry command for a swarm machine (acfs-ioo3.4,
# plan 4.2 item 5, 4.6, 4.7.5)
#
#   acfs machine up [--target incus|vps] [--replace] [<remote>:]<name> [<launcher options>]
#   acfs machine verify [<name>] [--read-only] [--json] [--timeout SEC]
#
# `up` creates (or resumes) a machine through scripts/providers/incus.sh,
# the launcher, which installs this checkout's committed HEAD in it; every
# option it doesn't know goes to the launcher (--ssh-key, --jump, --vm,
# --acl, the sizes). With --replace it rebuilds a machine on its own state
# and data volumes: stop the old instance (the quiesce), snapshot both
# volumes, export its root (--instance-only), take its volumes off it,
# rename it <name>-old, launch <name> anew with the lease copied from the
# old one, take the lease from the old one, verify, and keep the old
# instance, the snapshots and the export as the rollback. The steps are
# journalled, so a re-run continues where one stopped.
#
# `verify` is the authenticated login checklist: for each configured tool
# the stored login's file and mode first, then one small authenticated
# request with a timeout, telling an invalid login from a network failure
# from an exhausted quota, never printing credential data. A tool that
# isn't configured reports "not configured", never a false pass and never
# a forced login. It may make paid requests, so it is not the doctor;
# --read-only runs only the local parts. With <name> it runs inside that
# Incus instance, as the target user.
#
# Progress and the report go to stderr and stdout respectively; --json
# makes stdout a JSON array.
# ============================================================
set -euo pipefail

# Empty when this script is streamed into a machine (bash -s), where only
# verify runs and nothing needs the path.
MACHINE_SCRIPT="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
MACHINE_SCRIPT_DIR="${MACHINE_SCRIPT:+$(dirname "$MACHINE_SCRIPT")}"
# The launcher lives in a checkout, beside this file's parent; an installed
# copy under ~/.acfs/scripts/lib has none.
MACHINE_LAUNCHER="${ACFS_MACHINE_LAUNCHER:-${MACHINE_SCRIPT_DIR:-.}/../providers/incus.sh}"
MACHINE_STATE_DIR="${ACFS_MACHINE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acfs/machine}"
MACHINE_TARGET_USER="${ACFS_MACHINE_USER:-ubuntu}"
MACHINE_VERIFY_TIMEOUT="${ACFS_VERIFY_TIMEOUT:-90}"
MACHINE_VERIFY_PROMPT="reply with ok"
# The guest API socket that marks an Incus instance, and the SSH host key
# candidates (the state layer's first); both overridable for the tests.
MACHINE_GUEST_SOCK="${ACFS_MACHINE_GUEST_SOCK:-/dev/incus/sock}"
MACHINE_HOST_KEYS="${ACFS_VERIFY_HOST_KEYS:-/etc/ssh/acfs-host-keys/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub}"
# The device names the launcher gives a machine's own volumes.
MACHINE_VOLUME_DEVICES=(state-home state-ssh-host state-tailscale state-acfs data)

machine_usage() {
    cat <<'EOF'
Usage: acfs machine up [--target incus|vps] [--replace] [<remote>:]<name> [<launcher options>]
       acfs machine verify [<name>] [--read-only] [--json] [--timeout SEC]

up       Create the swarm machine <name> as an unprivileged Incus container
         through scripts/providers/incus.sh and install ACFS in it; a re-run
         resumes an unfinished install. Options the launcher knows pass
         through: --ssh-key FILE, --jump HOST, --vm, --acl NAME, --root-size,
         --state-size, --data-size. It runs from a checkout of the
         repository, whose committed HEAD is what gets installed.
  --target incus   The default: an Incus container (or VM with --vm).
  --target vps     Not created here: a VPS comes from its provider. Prints
                   where the install one-liner and the provider guides are.
  --replace        Rebuild <name> on its own volumes: stop it, snapshot its
                   state and data volumes (acfs-replace-<stamp>), export its
                   root, detach the volumes, rename it <name>-old, launch
                   <name> anew with the same lease, take the lease from
                   <name>-old, verify, and keep <name>-old stopped, the
                   snapshots and the export as the rollback. Journalled
                   under ~/.local/state/acfs/machine, with the export in its
                   exports/; re-run to continue after a failure.

verify   The authenticated login checklist: per configured tool its stored
         login (file, mode), then one small authenticated request with a
         timeout, distinguishing an invalid login, a network failure and an
         exhausted quota. Credential data is never printed. A tool that is
         not configured says so; nothing forces a login.
  <name>           Run the checklist inside the Incus instance <name>, as
                   the target user (this script is streamed in, so the
                   machine's ACFS needn't be current), plus the host-side
                   checks (the lease key, the SSH entry).
  --read-only      Only the local, unpaid parts: files and modes, the host
                   key, the lease, the credential search, the tool lists.
  --json           A JSON array of {check, status, detail} on stdout.
  --timeout SEC    Per request (default 90).

Exit status: 0 when nothing failed, 1 when a check failed, 2 on usage.
EOF
}

machine_err() { printf 'acfs machine: %s\n' "$*" >&2; }
machine_note() { printf '%s\n' "$*" >&2; }
machine_die() { machine_err "$*"; exit "${2:-1}"; }
machine_usage_die() { machine_err "$*"; echo "Run 'acfs machine --help' for usage." >&2; exit 2; }

machine_require() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || machine_die "$cmd is required for this" 2
    done
}

# incus never reads the inherited stdin (it would block on a pipe).
machine_incus() {
    incus "$@" </dev/null
}

# ------------------------------------------------------------------
# up
# ------------------------------------------------------------------

# <remote>:<name> -> the two parts, validated like the launcher does.
machine_split_target() {
    local target="$1"
    MACHINE_REMOTE=""
    MACHINE_NAME="$target"
    if [[ "$target" == *:* ]]; then
        MACHINE_REMOTE="${target%%:*}"
        MACHINE_NAME="${target#*:}"
        [[ -n "$MACHINE_REMOTE" ]] || machine_usage_die "empty remote in '$target'"
    fi
    [[ "$MACHINE_NAME" =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || machine_usage_die "invalid machine name '$MACHINE_NAME': letters, digits and dashes, starting with a letter and not ending with a dash"
}

machine_qualified() {
    printf '%s%s\n' "${MACHINE_REMOTE:+$MACHINE_REMOTE:}" "$1"
}

machine_require_launcher() {
    [[ -f "$MACHINE_LAUNCHER" ]] \
        || machine_die "the launcher scripts/providers/incus.sh isn't beside this script: 'acfs machine up' runs from a checkout of the repository (it installs that checkout's committed HEAD), so run it there, or set ACFS_MACHINE_LAUNCHER to the launcher's path" 2
}

machine_explain_vps() {
    cat >&2 <<'EOF'
acfs machine up --target vps: a VPS is created by its provider, not here.
Create the VM at your provider, then install ACFS in it with the one-liner
from README.md ("Quick Start"); scripts/providers/hetzner.md, contabo.md
and ovh.md walk through each provider, and hetzner-cloud-init.yml does the
install at first boot. Afterwards, inside the VPS: acfs machine verify
EOF
    exit 2
}

# The instance's `incus list` JSON object, or nothing when it doesn't exist.
machine_instance_json() {
    local name="$1" args=(list)
    [[ -z "$MACHINE_REMOTE" ]] || args+=("$MACHINE_REMOTE:")
    args+=("^${name}\$" -f json)
    machine_incus "${args[@]}" | jq -c --arg name "$name" '.[] | select(.name == $name)'
}

# --- The replace journal: KEY=1 lines, one per finished step ----------
machine_journal_file() {
    printf '%s/%s.replace\n' "$MACHINE_STATE_DIR" "${MACHINE_REMOTE:+$MACHINE_REMOTE--}$MACHINE_NAME"
}

machine_journal_has() {
    local file
    file="$(machine_journal_file)"
    [[ -f "$file" ]] && grep -qx -- "$1=1" "$file"
}

machine_journal_mark() {
    local file
    file="$(machine_journal_file)"
    mkdir -p "$MACHINE_STATE_DIR"
    chmod 0700 "$MACHINE_STATE_DIR"
    machine_journal_has "$1" || printf '%s=1\n' "$1" >>"$file"
}

# A journal left by an earlier run must still describe the instances: after
# the rename, <name>-old exists; after the launch, <name> exists too. A
# rollback by hand (the old instance renamed back) leaves a journal that
# would otherwise skip every step and call the rolled-back machine replaced.
machine_replace_check_journal() {
    local file
    file="$(machine_journal_file)"
    [[ -f "$file" ]] || return 0
    if machine_journal_has renamed && [[ -z "$(machine_instance_json "$MACHINE_NAME-old")" ]]; then
        machine_die "the replace journal $file says $(machine_qualified "$MACHINE_NAME") was renamed to $(machine_qualified "$MACHINE_NAME-old"), but no such instance exists (rolled back by hand?). Remove the journal and re-run to start the replace over" 2
    fi
    if machine_journal_has launched && [[ -z "$(machine_instance_json "$MACHINE_NAME")" ]]; then
        machine_die "the replace journal $file says $(machine_qualified "$MACHINE_NAME") was launched, but no such instance exists. Remove the journal and re-run to start the replace over" 2
    fi
    machine_note "replace: continuing from the journal $file"
}

# Step 1 of --replace: the old instance must be one the launcher made and
# installed, so its volumes carry a login worth keeping.
machine_replace_preflight() {
    local json old_json
    if machine_journal_has renamed; then
        return 0
    fi
    json="$(machine_instance_json "$MACHINE_NAME")"
    [[ -n "$json" ]] || machine_die "no instance $(machine_qualified "$MACHINE_NAME") to replace; 'acfs machine up $MACHINE_NAME' creates one" 2
    jq -e '.config["user.acfs.installed"] != null' <<<"$json" >/dev/null \
        || machine_die "$(machine_qualified "$MACHINE_NAME") carries no user.acfs.installed, so the launcher never finished an install there; --replace rebuilds only an installed machine" 2
    [[ "$(jq -r '.type' <<<"$json")" == "container" ]] \
        || machine_die "$(machine_qualified "$MACHINE_NAME") is a VM: a VM has no state volume to rebuild on; --replace is for containers" 2
    old_json="$(machine_instance_json "$MACHINE_NAME-old")"
    [[ -z "$old_json" ]] \
        || machine_die "$(machine_qualified "$MACHINE_NAME-old") exists already: an earlier replace's rollback. Delete it (incus delete $(machine_qualified "$MACHINE_NAME-old")) when you no longer need it, then re-run" 2
}

# The replace's UTC stamp, which names its snapshots and export: kept in the
# journal (stamp=...), so a resumed run uses the same one.
machine_replace_stamp() {
    local file stamp
    file="$(machine_journal_file)"
    stamp="$(sed -n 's/^stamp=//p' "$file" 2>/dev/null | tail -n 1)"
    if [[ ! "$stamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
        stamp="$(date -u +%Y%m%d-%H%M%S)"
        mkdir -p "$MACHINE_STATE_DIR"
        chmod 0700 "$MACHINE_STATE_DIR"
        printf 'stamp=%s\n' "$stamp" >>"$file"
    fi
    printf '%s\n' "$stamp"
}

# A clean shutdown is the quiesce: every agent, service and tailscaled
# stops, so the snapshots and the export that follow are consistent.
machine_replace_stop() {
    machine_journal_has stopped && return 0
    local json
    json="$(machine_instance_json "$MACHINE_NAME")"
    if [[ "$(jq -r '.status' <<<"$json")" == "Running" ]]; then
        machine_note "replace: stopping $(machine_qualified "$MACHINE_NAME") (a clean shutdown quiesces every writer)"
        machine_incus stop "$(machine_qualified "$MACHINE_NAME")" || machine_die "incus stop failed" 1
    fi
    machine_journal_mark stopped
}

# The pool and the two volumes, from the old instance's own devices (the
# launcher's state-home and data), so nothing is guessed from the name.
machine_replace_volumes() {
    local devices
    devices="$(machine_incus query "$(machine_qualified "/1.0/instances/$MACHINE_NAME")" | jq -c '.devices')"
    MACHINE_POOL="$(jq -r '.["state-home"].pool // empty' <<<"$devices")"
    MACHINE_STATE_VOLUME="$(jq -r '.["state-home"].source // empty | split("/")[0]' <<<"$devices")"
    MACHINE_DATA_VOLUME="$(jq -r '.data.source // empty' <<<"$devices")"
    [[ -n "$MACHINE_POOL" && -n "$MACHINE_STATE_VOLUME" && -n "$MACHINE_DATA_VOLUME" ]] \
        || machine_die "$(machine_qualified "$MACHINE_NAME") has no state-home and data devices with a pool and a source (the launcher's); can't tell which volumes to snapshot" 2
}

# The volumes as they were at the stop: the logins' rollback point. A
# snapshot an interrupted run already made is kept, not made again.
machine_replace_snapshot() {
    machine_journal_has snapshotted && return 0
    local stamp volume snapshot
    stamp="$(machine_replace_stamp)"
    snapshot="acfs-replace-$stamp"
    machine_replace_volumes
    for volume in "$MACHINE_STATE_VOLUME" "$MACHINE_DATA_VOLUME"; do
        if machine_incus storage volume snapshot show "$(machine_qualified "$MACHINE_POOL")" "$volume" "$snapshot" >/dev/null 2>&1; then
            continue
        fi
        machine_note "replace: snapshotting $volume on pool $MACHINE_POOL as $snapshot"
        machine_incus storage volume snapshot create "$(machine_qualified "$MACHINE_POOL")" "$volume" "$snapshot" >/dev/null \
            || machine_die "could not snapshot $volume; re-run 'acfs machine up --replace $(machine_qualified "$MACHINE_NAME")' to continue" 1
    done
    machine_journal_mark snapshotted
}

# The old root alone (Incus leaves custom volumes out of an export), owner
# only, written beside the journal and published by rename.
machine_replace_export_file() {
    printf '%s/exports/%s-%s.tar.gz\n' "$MACHINE_STATE_DIR" "${MACHINE_REMOTE:+$MACHINE_REMOTE--}$MACHINE_NAME" "$(machine_replace_stamp)"
}

machine_replace_export() {
    machine_journal_has exported && return 0
    local file
    file="$(machine_replace_export_file)"
    if [[ ! -f "$file" ]]; then
        (umask 077; mkdir -p "$(dirname "$file")")
        machine_note "replace: exporting the root of $(machine_qualified "$MACHINE_NAME") to $file"
        rm -f -- "$file.part"
        (umask 077; machine_incus export "$(machine_qualified "$MACHINE_NAME")" "$file.part" --instance-only >/dev/null) \
            || machine_die "incus export failed; re-run 'acfs machine up --replace $(machine_qualified "$MACHINE_NAME")' to continue" 1
        mv -f -- "$file.part" "$file"
    fi
    machine_journal_mark exported
}

# The volumes stay; only the old instance's devices for them go, so the new
# instance can mount them alone (one volume, one running instance).
machine_replace_detach() {
    machine_journal_has detached && return 0
    local device present
    present="$(machine_incus query "$(machine_qualified "/1.0/instances/$MACHINE_NAME")" | jq -r '.devices | keys[]')"
    for device in "${MACHINE_VOLUME_DEVICES[@]}"; do
        grep -qx -- "$device" <<<"$present" || continue
        machine_note "replace: detaching $device from $(machine_qualified "$MACHINE_NAME")"
        machine_incus config device remove "$(machine_qualified "$MACHINE_NAME")" "$device" >/dev/null \
            || machine_die "could not remove the device $device" 1
    done
    machine_journal_mark detached
}

machine_replace_rename() {
    machine_journal_has renamed && return 0
    machine_note "replace: renaming $(machine_qualified "$MACHINE_NAME") to $(machine_qualified "$MACHINE_NAME-old")"
    machine_incus rename "$(machine_qualified "$MACHINE_NAME")" "$(machine_qualified "$MACHINE_NAME-old")" \
        || machine_die "incus rename failed" 1
    machine_journal_mark renamed
}

# The launcher finds the volumes by the machine's name and reuses them, and
# --lease-from copies the old instance's lease, so the volume's lease check
# passes on first boot. The launcher resumes its own install on a re-run.
machine_replace_launch() {
    machine_journal_has launched && return 0
    machine_note "replace: launching $(machine_qualified "$MACHINE_NAME") on its existing volumes"
    bash "$MACHINE_LAUNCHER" "$(machine_qualified "$MACHINE_NAME")" --lease-from "$MACHINE_NAME-old" "$@" \
        || machine_die "the launcher failed; fix the cause and re-run 'acfs machine up --replace $(machine_qualified "$MACHINE_NAME")' to continue" 1
    machine_journal_mark launched
}

# The lease moves only now that the new instance holds it: without its key
# the old root can't start its user manager against the volume again.
machine_replace_lease() {
    machine_journal_has lease-moved && return 0
    machine_note "replace: taking the lease from $(machine_qualified "$MACHINE_NAME-old")"
    machine_incus config unset "$(machine_qualified "$MACHINE_NAME-old")" user.acfs.lease \
        || machine_die "could not unset user.acfs.lease on $(machine_qualified "$MACHINE_NAME-old"); re-run 'acfs machine up --replace $(machine_qualified "$MACHINE_NAME")' to continue" 1
    machine_journal_mark lease-moved
}

machine_replace_verify() {
    machine_journal_has verified && return 0
    local old new
    old="$(machine_qualified "$MACHINE_NAME-old")"
    new="$(machine_qualified "$MACHINE_NAME")"
    machine_note "replace: verifying $new"
    machine_verify_in_instance "$MACHINE_NAME" \
        || machine_die "verify found a failure in the new $new; the old instance is still $old, stopped. Fix the cause and re-run to verify again, or roll back: incus stop $new; incus config set $old user.acfs.lease \"\$(incus config get $new user.acfs.lease)\"; incus rename $new $new-failed; incus rename $old $new; re-attach the volumes with the launcher's device names; rm $(machine_journal_file). The snapshots acfs-replace-$(machine_replace_stamp) and the export $(machine_replace_export_file) are kept" 1
    machine_journal_mark verified
}

machine_up() {
    local target_kind=incus replace="" target="" launcher_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ -n "${2:-}" ]] || machine_usage_die "--target needs incus or vps"
                target_kind="$2"
                shift 2
                ;;
            --target=*) target_kind="${1#*=}"; shift ;;
            --replace) replace=1; shift ;;
            -h|--help) machine_usage; exit 0 ;;
            --)
                shift
                launcher_args+=("$@")
                break
                ;;
            -*)
                # The launcher's own options and their values pass through.
                launcher_args+=("$1")
                shift
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                else
                    launcher_args+=("$1")
                fi
                shift
                ;;
        esac
    done
    case "$target_kind" in
        incus) ;;
        vps) machine_explain_vps ;;
        *) machine_usage_die "--target must be incus or vps, not '$target_kind'" ;;
    esac
    [[ -n "$target" ]] || machine_usage_die "up needs the machine's name"
    machine_split_target "$target"
    machine_require_launcher
    if [[ "$(uname -s)" == "Darwin" ]]; then
        machine_note "On macOS the Incus server is Colima's; start it first (colima start --runtime incus) if 'incus info' fails. Starting it from here is acfs-ioo3.13."
    fi

    if [[ -z "$replace" ]]; then
        exec bash "$MACHINE_LAUNCHER" "$target" "${launcher_args[@]}"
    fi

    machine_require incus jq
    machine_replace_check_journal
    machine_replace_preflight
    machine_replace_stop
    machine_replace_snapshot
    machine_replace_export
    machine_replace_detach
    machine_replace_rename
    machine_replace_launch "${launcher_args[@]}"
    machine_replace_lease
    machine_replace_verify
    local stamp export_file
    stamp="$(machine_replace_stamp)"
    export_file="$(machine_replace_export_file)"
    rm -f -- "$(machine_journal_file)"
    machine_note "replace: done. Kept as the rollback: $(machine_qualified "$MACHINE_NAME-old"), stopped and without the lease; the volume snapshots acfs-replace-$stamp; the root's export $export_file. Delete them when satisfied: incus delete $(machine_qualified "$MACHINE_NAME-old")"
}

# ------------------------------------------------------------------
# verify
# ------------------------------------------------------------------

MACHINE_VERIFY_JSON=""
MACHINE_VERIFY_READ_ONLY=""
MACHINE_VERIFY_FAILED=0
MACHINE_VERIFY_ROWS=()
# The file a request's output is captured in; removed on exit too, so an
# interrupted request leaves no tool output behind.
MACHINE_CAPTURE_FILE=""
trap '[[ -z "$MACHINE_CAPTURE_FILE" ]] || rm -f -- "$MACHINE_CAPTURE_FILE"' EXIT

# record <check> <status> <detail>: status is ok, fail, not-configured or
# skip. The detail never carries file contents or command output beyond
# the verdict machine_request distilled from it.
machine_record() {
    local check="$1" status="$2" detail="$3"
    [[ "$status" != fail ]] || MACHINE_VERIFY_FAILED=1
    MACHINE_VERIFY_ROWS+=("$check"$'\t'"$status"$'\t'"$detail")
    [[ -n "$MACHINE_VERIFY_JSON" ]] || printf '%-16s %-15s %s\n' "$check" "$status" "$detail" >&2
}

machine_print_json() {
    local row check status detail first=1
    printf '['
    for row in "${MACHINE_VERIFY_ROWS[@]}"; do
        IFS=$'\t' read -r check status detail <<<"$row"
        ((first)) || printf ','
        first=0
        jq -cn --arg c "$check" --arg s "$status" --arg d "$detail" '{check: $c, status: $s, detail: $d}'
    done
    printf ']\n'
}

# The mode of a file, four octal digits.
machine_mode() {
    stat -c '%04a' "$1" 2>/dev/null || stat -f '%OLp' "$1" 2>/dev/null
}

# A login file must exist and be private: no group or other bits.
machine_login_file() {
    local check="$1" file="$2" mode
    [[ -e "$file" ]] || return 1
    mode="$(machine_mode "$file")"
    if [[ "$mode" =~ ^0?[0-7]00$ ]]; then
        MACHINE_LOGIN_DETAIL="login stored, mode $mode"
        return 0
    fi
    machine_record "$check" fail "login stored but mode $mode allows group or other access; run: acfs state repair"
    return 2
}

# Runs a request under the timeout, capturing output to a file nobody
# prints, and classifies the result: ok, or fail with one of invalid
# login, network, quota or the exit status.
machine_request() {
    local check="$1" tag="$2"
    shift 2
    local out rc=0
    out="$(mktemp "${TMPDIR:-/tmp}/acfs-verify.XXXXXX")"
    MACHINE_CAPTURE_FILE="$out"
    timeout "$MACHINE_VERIFY_TIMEOUT" "$@" >"$out" 2>&1 </dev/null || rc=$?
    local verdict
    if ((rc == 0)); then
        verdict="ok"
    elif ((rc == 124)); then
        verdict="fail: no answer within ${MACHINE_VERIFY_TIMEOUT}s (network, or a prompt waiting for input)"
    elif grep -qiE 'rate.?limit|usage limit|quota|too many requests|429|insufficient_quota|out of credits' "$out"; then
        verdict="fail: quota or rate limit exhausted (exit $rc)"
    elif grep -qiE 'not logged in|please (log|sign) in|login required|unauthori[sz]ed|invalid (api )?key|invalid.*token|expired|401|403|authentication' "$out"; then
        verdict="fail: the login is invalid or expired (exit $rc)"
    elif grep -qiE 'ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN|could not resolve|network is unreachable|connection (refused|reset|timed out)|fetch failed|dns' "$out"; then
        verdict="fail: network failure (exit $rc)"
    else
        verdict="fail: exit $rc ($(wc -l <"$out" | tr -d ' ') lines of output, not shown)"
    fi
    rm -f -- "$out"
    MACHINE_CAPTURE_FILE=""
    if [[ "$verdict" == ok ]]; then
        machine_record "$check" ok "$MACHINE_LOGIN_DETAIL; $tag answered"
    else
        machine_record "$check" fail "$MACHINE_LOGIN_DETAIL; $tag: ${verdict#fail: }"
    fi
}

# A tool with a login file and a one-shot command. $4.. is the request.
machine_check_tool() {
    local check="$1" file="$2" tag="$3"
    shift 3
    MACHINE_LOGIN_DETAIL=""
    if ! command -v "$1" >/dev/null 2>&1; then
        machine_record "$check" not-configured "$1 isn't installed"
        return 0
    fi
    machine_login_file "$check" "$file" || { [[ $? -eq 2 ]] || machine_record "$check" not-configured "no login stored ($file)"; return 0; }
    if [[ -n "$MACHINE_VERIFY_READ_ONLY" ]]; then
        machine_record "$check" ok "$MACHINE_LOGIN_DETAIL; request skipped (--read-only)"
        return 0
    fi
    machine_request "$check" "$tag" "$@"
}

machine_check_claude() {
    machine_check_tool claude "$HOME/.claude/.credentials.json" "claude -p" \
        claude -p "$MACHINE_VERIFY_PROMPT" --output-format text
}

machine_check_codex() {
    local check=codex file="$HOME/.codex/auth.json"
    MACHINE_LOGIN_DETAIL=""
    command -v codex >/dev/null 2>&1 || { machine_record "$check" not-configured "codex isn't installed"; return 0; }
    machine_login_file "$check" "$file" || { [[ $? -eq 2 ]] || machine_record "$check" not-configured "no login stored ($file)"; return 0; }
    if [[ -n "$MACHINE_VERIFY_READ_ONLY" ]]; then
        machine_record "$check" ok "$MACHINE_LOGIN_DETAIL; request skipped (--read-only)"
        return 0
    fi
    # Two calls: the stored login's status, then one small request.
    if ! timeout "$MACHINE_VERIFY_TIMEOUT" codex login status >/dev/null 2>&1 </dev/null; then
        machine_record "$check" fail "$MACHINE_LOGIN_DETAIL; codex login status says not logged in"
        return 0
    fi
    machine_request "$check" "codex exec" codex exec --skip-git-repo-check "$MACHINE_VERIFY_PROMPT"
}

# ACFS installs agy as agy-locked (its model guard) and gives interactive
# shells an alias, which a non-interactive check doesn't have.
machine_check_agy() {
    local bin
    bin="$(command -v agy 2>/dev/null || command -v agy-locked 2>/dev/null || echo agy)"
    machine_check_tool agy "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" "agy -p" \
        "$bin" -p "$MACHINE_VERIFY_PROMPT" --output-format text --print-timeout "${MACHINE_VERIFY_TIMEOUT}s"
}

machine_check_gemini() {
    machine_check_tool gemini "$HOME/.gemini/oauth_creds.json" "gemini -p" \
        gemini -p "$MACHINE_VERIFY_PROMPT"
}

# pi's non-interactive form isn't pinned down here, so pi gets the stored
# login check only, unless ACFS_VERIFY_PI_CMD names the request.
machine_check_pi() {
    local check=pi file="$HOME/.pi/agent/auth.json"
    MACHINE_LOGIN_DETAIL=""
    command -v pi >/dev/null 2>&1 || { machine_record "$check" not-configured "pi isn't installed"; return 0; }
    machine_login_file "$check" "$file" || { [[ $? -eq 2 ]] || machine_record "$check" not-configured "no login stored ($file)"; return 0; }
    if [[ -n "$MACHINE_VERIFY_READ_ONLY" || -z "${ACFS_VERIFY_PI_CMD:-}" ]]; then
        machine_record "$check" ok "$MACHINE_LOGIN_DETAIL; no request made (set ACFS_VERIFY_PI_CMD to pi's one-shot command to make one)"
        return 0
    fi
    # shellcheck disable=SC2086
    machine_request "$check" "pi" $ACFS_VERIFY_PI_CMD
}

machine_check_gh() {
    local check=gh file="$HOME/.config/gh/hosts.yml"
    MACHINE_LOGIN_DETAIL=""
    command -v gh >/dev/null 2>&1 || { machine_record "$check" not-configured "gh isn't installed"; return 0; }
    machine_login_file "$check" "$file" || { [[ $? -eq 2 ]] || machine_record "$check" not-configured "no login stored ($file)"; return 0; }
    # gh auth status is a read, not a paid request, so --read-only runs it.
    machine_request "$check" "gh auth status" gh auth status
}

# Agent Mail: the server's health endpoint, then an authenticated read of
# the agent list with the token from config.env, which am reads itself.
machine_check_agent_mail() {
    local check=agent-mail file="$HOME/.config/mcp-agent-mail/config.env"
    MACHINE_LOGIN_DETAIL=""
    command -v am >/dev/null 2>&1 || { machine_record "$check" not-configured "am isn't installed"; return 0; }
    machine_login_file "$check" "$file" || { [[ $? -eq 2 ]] || machine_record "$check" not-configured "no config stored ($file)"; return 0; }
    if ! timeout 10 curl -fsS --max-time 5 "http://127.0.0.1:${ACFS_AGENT_MAIL_PORT:-8765}/health" >/dev/null 2>&1 </dev/null; then
        machine_record "$check" fail "$MACHINE_LOGIN_DETAIL; the server doesn't answer on 127.0.0.1:${ACFS_AGENT_MAIL_PORT:-8765}/health (acfs services status)"
        return 0
    fi
    machine_request "$check" "am agents list" am agents list --json
}

# Tailscale: configured when its state exists; the node name must be the
# one recorded, so a rebuilt machine kept its identity.
machine_check_tailscale() {
    local check=tailscale name
    command -v tailscale >/dev/null 2>&1 || { machine_record "$check" not-configured "tailscale isn't installed"; return 0; }
    if ! name="$(timeout 10 tailscale status --json 2>/dev/null </dev/null | jq -r '.Self.HostName // empty' 2>/dev/null)" || [[ -z "$name" ]]; then
        machine_record "$check" not-configured "tailscaled isn't running or isn't logged in (a sidecar container carries the tailnet instead, when used)"
        return 0
    fi
    machine_baseline tailscale.hostname "$name" "node name" "$check"
}

# The SSH host identity: the ed25519 fingerprint must be the recorded one.
machine_check_host_key() {
    local check=ssh-host-key key fp
    # shellcheck disable=SC2086
    for key in $MACHINE_HOST_KEYS; do
        [[ -r "$key" ]] && break
    done
    [[ -r "$key" ]] || { machine_record "$check" not-configured "no readable ssh_host_ed25519_key.pub"; return 0; }
    fp="$(ssh-keygen -l -f "$key" 2>/dev/null | awk '{print $2}')"
    [[ -n "$fp" ]] || { machine_record "$check" fail "ssh-keygen can't read $key"; return 0; }
    machine_baseline ssh.host_key "$fp" "fingerprint" "$check"
}

# A value that must not change between runs: the first run records it
# under ~/.acfs/state, later runs compare.
machine_baseline() {
    local key="$1" value="$2" what="$3" check="$4" file recorded
    file="$MACHINE_STATE_DIR/baseline"
    mkdir -p "$MACHINE_STATE_DIR"
    chmod 0700 "$MACHINE_STATE_DIR"
    recorded=""
    if [[ -f "$file" ]]; then
        recorded="$(sed -n "s/^$key=//p" "$file" | tail -n 1)"
    fi
    if [[ -z "$recorded" ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$file"
        machine_record "$check" ok "$what recorded for later runs to compare"
    elif [[ "$recorded" == "$value" ]]; then
        machine_record "$check" ok "$what unchanged since first recorded"
    else
        machine_record "$check" fail "$what changed since it was recorded ($file); if this machine was rebuilt on purpose, remove the $key line there"
    fi
}

# herdr: the server answers and its workspaces are listed. Resuming a
# session per agent kind needs a pane, so it stays out of the checklist.
machine_check_herdr() {
    local check=herdr n
    command -v herdr >/dev/null 2>&1 || { machine_record "$check" not-configured "herdr isn't installed"; return 0; }
    if ! n="$(timeout 20 herdr workspace list 2>/dev/null </dev/null | jq -r '.result.workspaces | length' 2>/dev/null)"; then
        machine_record "$check" fail "herdr workspace list didn't answer (is herdr's server running?)"
        return 0
    fi
    machine_record "$check" ok "server answers; $n workspace(s)"
}

machine_check_beads() {
    local check=beads dir="${ACFS_VERIFY_PROJECT:-$PWD}"
    command -v br >/dev/null 2>&1 || { machine_record "$check" not-configured "br isn't installed"; return 0; }
    [[ -d "$dir/.beads" ]] || { machine_record "$check" skip "no .beads in $dir (set ACFS_VERIFY_PROJECT)"; return 0; }
    if (cd "$dir" && timeout 30 br ready --json >/dev/null 2>&1 </dev/null); then
        machine_record "$check" ok "br ready answers in $dir"
    else
        machine_record "$check" fail "br ready fails in $dir"
    fi
}

machine_check_cm() {
    local check=cm
    command -v cm >/dev/null 2>&1 || { machine_record "$check" not-configured "cm isn't installed"; return 0; }
    if [[ -n "$(timeout 30 cm context "verify the machine" --json 2>/dev/null </dev/null)" ]]; then
        machine_record "$check" ok "cm context answers"
    else
        machine_record "$check" fail "cm context gave no answer"
    fi
}

# The lease: this instance must hold its state volume (acfs state).
machine_check_lease() {
    local check=lease out
    [[ -S "$MACHINE_GUEST_SOCK" ]] || { machine_record "$check" skip "not an Incus instance (a VPS keeps its lease as a record)"; return 0; }
    if ! sudo -n true 2>/dev/null; then
        machine_record "$check" skip "needs sudo without a password to read /etc/acfs/state"
        return 0
    fi
    out="$(timeout 30 sudo -n acfs state lease status 2>/dev/null </dev/null || true)"
    if grep -qx 'match: yes' <<<"$out"; then
        machine_record "$check" ok "this instance holds its state volume"
    else
        machine_record "$check" fail "the volume's lease and this instance's user.acfs.lease don't match (sudo acfs state lease status)"
    fi
}

# No credential outside the state volume: root's home and /etc must hold
# none of the known login files. Paths are reported, never contents.
machine_check_credential_search() {
    local check=credentials-outside found=() f
    if ! sudo -n true 2>/dev/null; then
        machine_record "$check" skip "needs sudo without a password to look under /root"
        return 0
    fi
    for f in /root/.claude/.credentials.json /root/.claude.json /root/.codex/auth.json \
        /root/.gemini/oauth_creds.json /root/.pi/agent/auth.json /root/.config/gh/hosts.yml \
        /root/.config/mcp-agent-mail/config.env /etc/acfs/config.env; do
        sudo -n test -e "$f" 2>/dev/null && found+=("$f")
    done
    if ((${#found[@]} == 0)); then
        machine_record "$check" ok "none of the known login files is under /root or /etc"
    else
        machine_record "$check" fail "login files outside the user's home: ${found[*]} (a rebuild loses them)"
    fi
}

machine_verify_local() {
    machine_require jq
    machine_check_claude
    machine_check_codex
    machine_check_agy
    machine_check_gemini
    machine_check_pi
    machine_check_gh
    machine_check_agent_mail
    machine_check_tailscale
    machine_check_host_key
    machine_check_herdr
    machine_check_beads
    machine_check_cm
    machine_check_lease
    machine_check_credential_search
}

# Host side, for an instance: the lease key is set, and the SSH entry the
# launcher printed still logs in without a host-key warning.
machine_verify_host_side() {
    local name="$1" lease
    lease="$(machine_incus config get "$(machine_qualified "$name")" user.acfs.lease 2>/dev/null || true)"
    if [[ "$lease" =~ ^[0-9a-f]{32}$ ]]; then
        machine_record instance-lease ok "user.acfs.lease is set on $(machine_qualified "$name")"
    else
        machine_record instance-lease fail "user.acfs.lease isn't a 32-hex-digit token on $(machine_qualified "$name")"
    fi
    if ! grep -qsE "^Host[[:space:]]+$name([[:space:]]|$)" "$HOME/.ssh/config"; then
        machine_record ssh-entry not-configured "no Host $name in ~/.ssh/config here (the launcher prints the entry)"
    elif timeout "$MACHINE_VERIFY_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" true </dev/null >/dev/null 2>&1; then
        machine_record ssh-entry ok "ssh $name logs in with no host-key warning"
    else
        machine_record ssh-entry fail "ssh $name fails: a changed host key, a changed address or no key here (re-run the launcher to print the entry again)"
    fi
}

# Inside the instance, as the target user: this very script is streamed in
# on stdin (bash -s), so the machine's ACFS needn't have it installed yet,
# and the report comes back as JSON and is merged into ours.
machine_verify_in_instance() {
    local name="$1" json row args=(verify --json) out rc=0
    [[ -z "$MACHINE_VERIFY_READ_ONLY" ]] || args+=(--read-only)
    args+=(--timeout "$MACHINE_VERIFY_TIMEOUT")
    machine_require incus jq
    [[ -r "$MACHINE_SCRIPT" ]] || machine_die "this script can't read itself to stream it into the instance (run it from a file)" 1
    json="$(machine_instance_json "$name")"
    [[ -n "$json" ]] || machine_die "no instance $(machine_qualified "$name")" 2
    [[ "$(jq -r '.status' <<<"$json")" == "Running" ]] || machine_die "$(machine_qualified "$name") isn't running" 1
    machine_verify_host_side "$name"
    # The one incus call that reads its stdin: the script itself.
    out="$(incus exec "$(machine_qualified "$name")" --env HOME="/home/$MACHINE_TARGET_USER" -- \
        runuser -u "$MACHINE_TARGET_USER" -- bash -s -- "${args[@]}" <"$MACHINE_SCRIPT" 2>/dev/null)" || rc=$?
    if ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
        machine_record guest-checklist fail "the checklist inside $(machine_qualified "$name") gave no report (exit $rc)"
        return 1
    fi
    while IFS=$'\t' read -r check status detail; do
        [[ -n "$check" ]] || continue
        machine_record "$check" "$status" "$detail"
    done < <(jq -r '.[] | [.check, .status, .detail] | @tsv' <<<"$out")
    ((MACHINE_VERIFY_FAILED == 0))
}

machine_verify() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) MACHINE_VERIFY_JSON=1; shift ;;
            --read-only) MACHINE_VERIFY_READ_ONLY=1; shift ;;
            --timeout)
                [[ "${2:-}" =~ ^[0-9]+$ ]] || machine_usage_die "--timeout needs a number of seconds"
                MACHINE_VERIFY_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help) machine_usage; exit 0 ;;
            -*) machine_usage_die "unknown option: $1" ;;
            *)
                [[ -z "$name" ]] || machine_usage_die "one machine name only (got '$name' and '$1')"
                name="$1"
                shift
                ;;
        esac
    done
    machine_require timeout
    if [[ -n "$name" ]]; then
        machine_split_target "$name"
        machine_verify_in_instance "$MACHINE_NAME" || true
    else
        machine_verify_local
    fi
    [[ -z "$MACHINE_VERIFY_JSON" ]] || machine_print_json
    if ((MACHINE_VERIFY_FAILED)); then
        machine_note "verify: a check failed"
        return 1
    fi
    machine_note "verify: nothing failed"
}

machine_main() {
    case "${1:-}" in
        up) shift; machine_up "$@" ;;
        verify) shift; machine_verify "$@" ;;
        -h|--help|help|"") machine_usage; [[ -n "${1:-}" ]] || exit 2 ;;
        *) machine_usage_die "unknown subcommand: $1" ;;
    esac
}

machine_main "$@"
