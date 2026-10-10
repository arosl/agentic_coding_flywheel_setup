#!/usr/bin/env bash
# ============================================================
# scripts/lib/machine.sh (acfs machine up|verify) against STUBS
#
# A stub incus, a stub launcher and stub tool CLIs (claude, codex, gh, am,
# tailscale, herdr, br, cm, curl, sudo, ssh, ssh-keygen) on PATH, and a
# throwaway HOME with login files. Proves what `up` passes to the launcher,
# the order and the resumability of --replace, and what `verify` reports
# for each tool state, without a real Incus, a real login or a paid
# request. The `acfs machine` route in doctor.sh is checked too.
#
# Usage: bash tests/unit/test_machine.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACHINE="$ROOT/scripts/lib/machine.sh"
DOCTOR="$ROOT/scripts/lib/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-machine.XXXXXX")"
# KEEP_WORK=1 keeps the cases' out/err files for a look after a failure.
trap '[[ -n "${KEEP_WORK:-}" ]] && echo "kept: $WORK" || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# ------------------------------------------------------------
# Stubs. Each logs "<argv>" to $STUB_DIR/calls-<name> and answers from
# files under $STUB_DIR or from STUB_* variables.
# ------------------------------------------------------------
mkdir -p "$WORK/bin"

cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_DIR/calls-incus"
# An instance exists when $STUB_DIR/inst-<name>.json does; remotes are stripped.
case "$1" in
    list)
        # list [remote:] ^name$ -f json
        pat="$2"; [[ "$pat" == ^* ]] || pat="$3"
        name="${pat#^}"; name="${name%\$}"
        if [[ -f "$STUB_DIR/inst-$name.json" ]]; then printf '[%s]\n' "$(cat "$STUB_DIR/inst-$name.json")"; else echo '[]'; fi
        ;;
    query)
        name="${2##*/}"
        cat "$STUB_DIR/devices-$name.json"
        ;;
    stop)
        name="${2#*:}"
        jq '.status = "Stopped"' "$STUB_DIR/inst-$name.json" >"$STUB_DIR/inst-$name.json.new" && mv "$STUB_DIR/inst-$name.json.new" "$STUB_DIR/inst-$name.json"
        ;;
    rename)
        old="${2#*:}"; new="${3#*:}"
        jq --arg n "$new" '.name = $n' "$STUB_DIR/inst-$old.json" >"$STUB_DIR/inst-$new.json"
        rm -f "$STUB_DIR/inst-$old.json"
        [[ ! -f "$STUB_DIR/devices-$old.json" ]] || mv "$STUB_DIR/devices-$old.json" "$STUB_DIR/devices-$new.json"
        [[ ! -f "$STUB_DIR/lease-$old" ]] || mv "$STUB_DIR/lease-$old" "$STUB_DIR/lease-$new"
        ;;
    config)
        case "$2" in
            device)
                # config device remove <inst> <device>
                name="${4#*:}"
                jq --arg d "$5" 'del(.devices[$d])' "$STUB_DIR/devices-$name.json" >"$STUB_DIR/devices-$name.json.new" && mv "$STUB_DIR/devices-$name.json.new" "$STUB_DIR/devices-$name.json"
                ;;
            get)
                name="${3#*:}"
                [[ -f "$STUB_DIR/lease-$name" ]] && cat "$STUB_DIR/lease-$name" || echo
                ;;
        esac
        ;;
    exec)
        # exec <inst> [--env X] -- <command...>
        shift
        while [[ "$1" != "--" ]]; do shift; done
        shift
        case "$1" in
            # runuser -u ubuntu -- bash -s -- verify ...: the script arrives on
            # stdin; its first line is kept as proof.
            runuser)
                head -n 1 >"$STUB_DIR/streamed-script"
                cat "$STUB_DIR/guest-report.json"
                exit "${STUB_GUEST_EXIT:-0}"
                ;;
        esac
        ;;
esac
STUB

# The launcher: records its arguments; on success it "creates" the
# instance as installed and running, with a lease.
cat >"$WORK/bin/launcher" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_DIR/calls-launcher"
printf '%s\n' "$@" >"$STUB_DIR/launcher.args"
[[ -z "${STUB_LAUNCH_EXIT:-}" ]] || exit "$STUB_LAUNCH_EXIT"
name="${1#*:}"
printf '{"name":"%s","status":"Running","type":"container","config":{"user.acfs.installed":"abc","user.acfs.lease":"ffffffffffffffffffffffffffffffff"}}\n' "$name" >"$STUB_DIR/inst-$name.json"
printf 'ffffffffffffffffffffffffffffffff\n' >"$STUB_DIR/lease-$name"
echo "launcher stdout: the attach block"
STUB

# Tool CLIs: exit STUB_<TOOL>_EXIT (default 0) after printing STUB_<TOOL>_OUT.
for tool in claude codex agy gemini pi gh am cm br; do
    upper="$(tr '[:lower:]' '[:upper:]' <<<"$tool")"
    cat >"$WORK/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$STUB_DIR/calls-$tool"
[[ -z "\${STUB_${upper}_SLEEP:-}" ]] || sleep "\$STUB_${upper}_SLEEP"
printf '%s\n' "\${STUB_${upper}_OUT:-ok}"
exit "\${STUB_${upper}_EXIT:-0}"
STUB
done
cat >"$WORK/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-tailscale"
[[ -z "${STUB_TAILSCALE_DOWN:-}" ]] || exit 1
printf '{"Self":{"HostName":"%s"}}\n' "${STUB_TAILSCALE_HOST:-devbox}"
STUB
cat >"$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-herdr"
[[ -z "${STUB_HERDR_DOWN:-}" ]] || exit 1
echo '{"result":{"workspaces":[{"id":"w1"},{"id":"w2"}]}}'
STUB
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-curl"
[[ -z "${STUB_CURL_EXIT:-}" ]] || exit "$STUB_CURL_EXIT"
echo '{"status":"ok"}'
STUB
cat >"$WORK/bin/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-ssh-keygen"
printf '256 %s host (ED25519)\n' "${STUB_HOST_FP:-SHA256:hostfingerprint}"
STUB
cat >"$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-ssh"
exit "${STUB_SSH_EXIT:-0}"
STUB
# sudo -n <command>: `true` passes unless STUB_NO_SUDO; `test -e <path>`
# looks under $STUB_ROOTFS; `acfs state lease status` prints a fixture.
cat >"$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls-sudo"
[[ "$1" == -n ]] && shift
[[ -z "${STUB_NO_SUDO:-}" ]] || exit 1
case "$1" in
    true) exit 0 ;;
    test) [[ -e "$STUB_ROOTFS$3" ]] ;;
    acfs) printf 'volume lease:   set\ninstance lease: set\nmatch: %s\n' "${STUB_LEASE_MATCH:-yes}" ;;
esac
STUB
chmod +x "$WORK"/bin/*

CASE=""
RC=0

# new_case <name>: a fresh stub state, HOME and state dir.
new_case() {
    CASE="$WORK/case-$1"
    mkdir -p "$CASE/home/.ssh" "$CASE/state" "$CASE/rootfs"
    : >"$CASE/calls-incus"
}

# A login file with a mode, under the case's HOME.
login_file() {
    mkdir -p "$(dirname "$CASE/home/$1")"
    printf 'SECRET-%s\n' "$1" >"$CASE/home/$1"
    chmod "${2:-0600}" "$CASE/home/$1"
}

# run_machine [--no-tools] <args...>: runs machine.sh with the stubs first on
# PATH (or, with --no-tools, with only incus and the launcher), HOME in
# the case, and the launcher pointed at the stub.
run_machine() {
    local path="$WORK/bin:$PATH"
    if [[ "${1:-}" == --no-tools ]]; then
        # Only what machine.sh itself needs, so a real gh, ssh or tailscale
        # on this host isn't found either.
        shift
        mkdir -p "$CASE/bin-min"
        ln -sf "$WORK/bin/incus" "$CASE/bin-min/incus"
        ln -sf "$WORK/bin/ssh-keygen" "$CASE/bin-min/ssh-keygen"
        local b
        for b in bash sh jq timeout stat sed awk grep cat tr wc mkdir chmod rm mktemp head tail cut sort uname readlink dirname date ls env; do
            command -v "$b" >/dev/null 2>&1 && ln -sf "$(command -v "$b")" "$CASE/bin-min/$b"
        done
        path="$CASE/bin-min"
    fi
    set +e
    PATH="$path" STUB_DIR="$CASE" STUB_ROOTFS="$CASE/rootfs" HOME="$CASE/home" \
        XDG_STATE_HOME="$CASE/home/.local/state" ACFS_MACHINE_STATE_DIR="$CASE/state" \
        ACFS_MACHINE_LAUNCHER="${LAUNCHER_OVERRIDE:-$WORK/bin/launcher}" \
        ACFS_VERIFY_HOST_KEYS="$CASE/host_key.pub" ACFS_MACHINE_GUEST_SOCK="$CASE/guest.sock" \
        ACFS_VERIFY_PROJECT="$CASE/project" \
        bash "$MACHINE" "$@" >"$CASE/out" 2>"$CASE/err"
    RC=$?
    set -e
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
err_has() { grep -q -- "$1" "$CASE/err"; }
err_lacks() { ! grep -q -- "$1" "$CASE/err"; }
out_has() { grep -q -- "$1" "$CASE/out"; }
incus_called() { grep -q -- "$1" "$CASE/calls-incus"; }
incus_not_called() { ! grep -q -- "$1" "$CASE/calls-incus"; }
only_lists() { [[ "$(cut -d' ' -f1 "$CASE/calls-incus" | sort -u)" == list ]]; }
launcher_args_are() { [[ "$(tr '\n' ' ' <"$CASE/launcher.args")" == "$1 " ]]; }
no_launch() { [[ ! -e "$CASE/calls-launcher" ]]; }
# The report line for a check: "<check> <status> <detail>" on stderr.
status_of() { awk -v c="$1" '$1 == c {print $2; exit}' "$CASE/err"; }
status_is() { [[ "$(status_of "$1")" == "$2" ]]; }
both_ok() { status_is "$1" ok && status_is "$2" ok; }
detail_has() { grep -E -- "^$1 +[a-z-]+ +.*$2" "$CASE/err" >/dev/null; }
tool_called() { [[ -s "$CASE/calls-$1" ]]; }
tool_not_called() { [[ ! -s "$CASE/calls-$1" ]]; }
call_line() { grep -n -- "$1" "$CASE/calls-incus" | head -n 1 | cut -d: -f1; }
called_before() { [[ -n "$(call_line "$1")" && -n "$(call_line "$2")" && "$(call_line "$1")" -lt "$(call_line "$2")" ]]; }
replace_order() { called_before '^stop dev$' '^config device remove' && called_before '^config device remove' '^rename dev dev-old$'; }
# The launcher stub runs after incus rename when the rename is logged and the launcher was called at all.
launched_after_rename() { [[ -n "$(call_line '^rename dev dev-old$')" && -s "$CASE/calls-launcher" ]]; }
# No credential text may appear in either stream.
no_secret_printed() { ! grep -q 'SECRET-' "$CASE/out" "$CASE/err"; }

instance_json() { # <name> <status> <type> <installed: 1|"">
    local installed='"user.acfs.installed":"abc",'
    [[ -n "$4" ]] || installed=""
    printf '{"name":"%s","status":"%s","type":"%s","config":{%s"user.acfs.provider":"incus"}}' "$1" "$2" "$3" "$installed"
}

# An installed, running container with the launcher's devices and a lease.
installed_machine() {
    instance_json dev Running container 1 >"$CASE/inst-dev.json"
    echo '{"devices":{"root":{"type":"disk"},"eth0":{"type":"nic"},"state-home":{"type":"disk","source":"acfs-state-dev/home"},"state-ssh-host":{"type":"disk"},"state-tailscale":{"type":"disk"},"state-acfs":{"type":"disk"},"data":{"type":"disk","source":"dev-data"}}}' >"$CASE/devices-dev.json"
    printf '0123456789abcdef0123456789abcdef\n' >"$CASE/lease-dev"
    echo '[{"check":"claude","status":"ok","detail":"login stored, mode 0600; claude -p answered"},{"check":"lease","status":"ok","detail":"this instance holds its state volume"}]' >"$CASE/guest-report.json"
}

echo "== up: the launcher gets the name and every option machine.sh doesn't own"
new_case up
run_machine up dev --ssh-key "$WORK/k.pub" --jump box --root-size 100GiB
check "exits 0" rc_is 0
check "the launcher runs with the name first and the options as given" launcher_args_are "dev --ssh-key $WORK/k.pub --jump box --root-size 100GiB"
check "the launcher's stdout is the command's stdout" out_has 'launcher stdout: the attach block'
check "no incus call of its own" bash -c '[[ ! -s "$1" ]]' _ "$CASE/calls-incus"
new_case up-remote
run_machine up far:dev --ssh-key k --vm
check "a remote-qualified name reaches the launcher as given" launcher_args_are "far:dev --ssh-key k --vm"
new_case up-dashdash
run_machine up dev -- --ssh-key k
check "arguments after -- go to the launcher" launcher_args_are "dev --ssh-key k"

echo "== up: refusals"
new_case up-vps
run_machine up --target vps dev
check "--target vps: exits 2" rc_is 2
check "--target vps: points at the one-liner and the provider guides" err_has 'scripts/providers/hetzner.md'
check "--target vps: points at verify afterwards" err_has 'acfs machine verify'
check "--target vps: launches nothing" no_launch
new_case up-target-bogus
run_machine up --target bogus dev
check "--target bogus: exits 2" rc_is 2
new_case up-noname
run_machine up --vm
check "no name: exits 2" rc_is 2
check "no name: says so" err_has 'up needs the machine'
new_case up-badname
run_machine up 1dev
check "a name starting with a digit: exits 2" rc_is 2
new_case up-no-launcher
LAUNCHER_OVERRIDE="$CASE/nowhere/incus.sh" run_machine up dev --ssh-key k
check "no launcher beside the script: exits 2" rc_is 2
check "no launcher beside the script: says to run from a checkout" err_has 'runs from a checkout of the repository'
new_case usage
run_machine
check "no subcommand: exits 2" rc_is 2
run_machine --help
check "--help: exits 0" rc_is 0
check "--help: prints the usage" out_has 'acfs machine up'
run_machine bogus
check "unknown subcommand: exits 2" rc_is 2

echo "== up --replace: stop, detach the launcher's devices, rename, launch with the lease, verify"
new_case replace
installed_machine
run_machine up --replace dev --ssh-key k
check "exits 0" rc_is 0
check "stops the old instance" incus_called '^stop dev$'
check "removes the state-home device" incus_called '^config device remove dev state-home$'
check "removes the data device" incus_called '^config device remove dev data$'
check "removes the other state devices" bash -c 'grep -c "^config device remove dev state-" "$1" | grep -qx 4' _ "$CASE/calls-incus"
check "leaves root and the NIC alone" incus_not_called 'device remove dev root\|device remove dev eth0'
check "renames the old instance to dev-old" incus_called '^rename dev dev-old$'
check "stops before detaching, detaches before renaming" replace_order
check "launches dev with the lease copied from dev-old and the user's options" launcher_args_are "dev --lease-from dev-old --ssh-key k"
check "launches after the rename" launched_after_rename
check "verifies the new instance inside" incus_called '^exec dev --env HOME=/home/ubuntu -- runuser -u ubuntu -- bash -s -- verify --json --timeout 90$'
check "reports the guest checks" both_ok claude lease
check "reports the new instance's lease key" status_is instance-lease ok
check "keeps the old instance as the rollback and says so" err_has 'dev-old is kept stopped as the rollback'
check "removes the journal when done" bash -c '[[ ! -e "$1/dev.replace" ]]' _ "$CASE/state"
check "the old instance still exists, stopped" bash -c 'jq -e ".status == \"Stopped\"" "$1/inst-dev-old.json" >/dev/null' _ "$CASE"
check "prints no secret" no_secret_printed

echo "== up --replace: a failed launch leaves a journal, and a re-run continues after the rename"
new_case replace-resume
installed_machine
export STUB_LAUNCH_EXIT=3
run_machine up --replace dev --ssh-key k
unset STUB_LAUNCH_EXIT
check "exits 1" rc_is 1
check "says to re-run to continue" err_has "re-run 'acfs machine up --replace dev' to continue"
check "the journal records stop, detach and rename" bash -c 'grep -qx stopped=1 "$1" && grep -qx detached=1 "$1" && grep -qx renamed=1 "$1" && ! grep -q launched "$1"' _ "$CASE/state/dev.replace"
: >"$CASE/calls-incus"
rm -f "$CASE/calls-launcher"
run_machine up --replace dev --ssh-key k
check "the re-run exits 0" rc_is 0
check "the re-run stops nothing and renames nothing" incus_not_called '^stop \|^rename '
check "the re-run launches again with the lease" launcher_args_are "dev --lease-from dev-old --ssh-key k"
check "the re-run removes the journal" bash -c '[[ ! -e "$1/dev.replace" ]]' _ "$CASE/state"

echo "== up --replace: a failed verify keeps the journal and names the rollback"
new_case replace-verify-fails
installed_machine
echo '[{"check":"claude","status":"fail","detail":"login stored, mode 0600; claude -p: the login is invalid or expired (exit 1)"}]' >"$CASE/guest-report.json"
run_machine up --replace dev --ssh-key k
check "exits 1" rc_is 1
check "names the old instance as the rollback" err_has 'the old instance is still dev-old, stopped'
check "the journal keeps launched, not verified" bash -c 'grep -qx launched=1 "$1" && ! grep -q verified "$1"' _ "$CASE/state/dev.replace"

echo "== up --replace: preflight refusals touch nothing"
new_case replace-absent
run_machine up --replace dev --ssh-key k
check "no instance: exits 2" rc_is 2
check "no instance: says up creates one" err_has "'acfs machine up dev' creates one"
check "no instance: only lists" only_lists
new_case replace-uninstalled
instance_json dev Running container "" >"$CASE/inst-dev.json"
run_machine up --replace dev --ssh-key k
check "no finished install: exits 2" rc_is 2
check "no finished install: says so" err_has 'carries no user.acfs.installed'
check "no finished install: only lists" only_lists
new_case replace-vm
instance_json dev Running virtual-machine 1 >"$CASE/inst-dev.json"
run_machine up --replace dev --ssh-key k
check "a VM: exits 2" rc_is 2
check "a VM: says it has no state volume" err_has 'is a VM: a VM has no state volume'
new_case replace-old-exists
installed_machine
instance_json dev-old Stopped container 1 >"$CASE/inst-dev-old.json"
run_machine up --replace dev --ssh-key k
check "dev-old exists: exits 2" rc_is 2
check "dev-old exists: says to delete the earlier rollback" err_has "dev-old exists already: an earlier replace's rollback"
check "dev-old exists: only lists" only_lists
check "dev-old exists: launches nothing" no_launch

# ------------------------------------------------------------
# verify, locally (no name): the checklist against the stubs
# ------------------------------------------------------------
all_logins() {
    login_file .claude/.credentials.json
    login_file .codex/auth.json
    login_file .gemini/antigravity-cli/antigravity-oauth-token
    login_file .gemini/oauth_creds.json
    login_file .pi/agent/auth.json
    login_file .config/gh/hosts.yml
    login_file .config/mcp-agent-mail/config.env
    printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
    mkdir -p "$CASE/project/.beads"
}

echo "== verify: every tool configured and answering"
new_case verify-all
all_logins
run_machine verify
check "exits 0" rc_is 0
for tool in claude codex agy gemini pi gh agent-mail tailscale ssh-host-key herdr beads cm; do
    check "$tool: ok" status_is "$tool" ok
done
check "claude is asked with -p and the text format" grep -qx -- '-p reply with ok --output-format text' "$CASE/calls-claude"
check "codex: login status, then one exec" bash -c 'grep -qx "login status" "$1" && grep -q "^exec --skip-git-repo-check reply with ok$" "$1"' _ "$CASE/calls-codex"
check "agy: one print-mode request with a time limit" grep -q -- '^-p reply with ok --output-format text --print-timeout 90s$' "$CASE/calls-agy"
check "pi: no request without ACFS_VERIFY_PI_CMD" bash -c '[[ ! -s "$1" ]]' _ "$CASE/calls-pi"
check "pi: says why" detail_has pi 'no request made'
check "gh: auth status" grep -qx 'auth status' "$CASE/calls-gh"
check "agent-mail: health first, then an authenticated list" bash -c 'grep -q "8765/health" "$1" && grep -qx "agents list --json" "$2"' _ "$CASE/calls-curl" "$CASE/calls-am"
check "tailscale: the node name is recorded on the first run" detail_has tailscale 'node name recorded'
check "ssh-host-key: the fingerprint is recorded on the first run" detail_has ssh-host-key 'fingerprint recorded'
check "herdr: counts the workspaces" detail_has herdr '2 workspace'
check "beads: br ready in the project" detail_has beads 'br ready answers'
check "lease: skipped without the guest API" status_is lease skip
check "credentials-outside: none under /root" status_is credentials-outside ok
check "says nothing failed" err_has 'verify: nothing failed'
check "prints no secret" no_secret_printed

echo "== verify: the second run compares against the recorded baseline"
run_machine verify
check "tailscale unchanged" detail_has tailscale 'unchanged since first recorded'
check "ssh-host-key unchanged" detail_has ssh-host-key 'unchanged since first recorded'
export STUB_TAILSCALE_HOST=other STUB_HOST_FP=SHA256:changed
run_machine verify
unset STUB_TAILSCALE_HOST STUB_HOST_FP
check "a changed node name fails" status_is tailscale fail
check "a changed host key fails" status_is ssh-host-key fail
check "and names the baseline file to edit" detail_has ssh-host-key 'remove the ssh.host_key line'
check "exits 1" rc_is 1

echo "== verify: not configured is a distinct result, never a forced login"
new_case verify-none
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
run_machine verify
check "exits 0 (nothing failed)" rc_is 0
for tool in claude codex agy gemini pi gh agent-mail; do
    check "$tool: not-configured without its login file" status_is "$tool" not-configured
done
check "no tool is asked anything" bash -c '! ls "$1"/calls-claude "$1"/calls-codex "$1"/calls-agy "$1"/calls-gemini "$1"/calls-am >/dev/null 2>&1' _ "$CASE"
check "beads: skip without a .beads" status_is beads skip
new_case verify-no-tools
all_logins
run_machine --no-tools verify
check "without the CLIs installed: exits 0" rc_is 0
check "claude: not-configured when the CLI is missing" detail_has claude "isn't installed"
check "tailscale: not-configured when the CLI is missing" detail_has tailscale "isn't installed"

echo "== verify: failures are classified without printing output"
new_case verify-classify
all_logins
export STUB_CLAUDE_EXIT=1 STUB_CLAUDE_OUT='Error: rate limit reached, try again later'
export STUB_CODEX_EXIT=1 STUB_CODEX_OUT='Not logged in. Run codex login.'
export STUB_AGY_EXIT=1 STUB_AGY_OUT='getaddrinfo ENOTFOUND api.example'
export STUB_GEMINI_EXIT=7 STUB_GEMINI_OUT='something else went wrong'
export STUB_GH_EXIT=1 STUB_GH_OUT='You are not logged into any GitHub hosts'
run_machine verify
unset STUB_CLAUDE_EXIT STUB_CLAUDE_OUT STUB_CODEX_EXIT STUB_CODEX_OUT STUB_AGY_EXIT STUB_AGY_OUT STUB_GEMINI_EXIT STUB_GEMINI_OUT STUB_GH_EXIT STUB_GH_OUT
check "exits 1" rc_is 1
check "claude: quota" detail_has claude 'quota or rate limit exhausted'
check "codex: login status failing is an invalid login" detail_has codex 'not logged in'
check "agy: network" detail_has agy 'network failure'
check "gemini: an unclassified failure names the exit and hides the output" detail_has gemini 'exit 7 \(1 lines of output, not shown\)'
check "gh: invalid login" detail_has gh 'invalid or expired'
check "the tools' output never reaches the report" bash -c '! grep -q "rate limit reached\|something else went wrong\|ENOTFOUND api" "$1" "$2"' _ "$CASE/out" "$CASE/err"
check "prints no secret" no_secret_printed

echo "== verify: a request that hangs is cut off by the timeout"
new_case verify-timeout
login_file .claude/.credentials.json
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
export STUB_CLAUDE_SLEEP=5
run_machine verify --timeout 1
unset STUB_CLAUDE_SLEEP
check "exits 1" rc_is 1
check "claude: no answer within 1s" detail_has claude 'no answer within 1s'

echo "== verify: a login file others can read fails before any request"
new_case verify-mode
login_file .claude/.credentials.json 0644
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
run_machine verify
check "exits 1" rc_is 1
check "claude: names the mode and acfs state repair" detail_has claude 'mode 0644 allows group or other access; run: acfs state repair'
check "claude is not asked" tool_not_called claude

echo "== verify --read-only: stored logins only, no paid request"
new_case verify-read-only
all_logins
export STUB_CLAUDE_EXIT=1 STUB_CODEX_EXIT=1 STUB_AGY_EXIT=1 STUB_GEMINI_EXIT=1
run_machine verify --read-only
unset STUB_CLAUDE_EXIT STUB_CODEX_EXIT STUB_AGY_EXIT STUB_GEMINI_EXIT
check "exits 0 although the agents would fail" rc_is 0
check "claude: ok, request skipped" detail_has claude 'request skipped \(--read-only\)'
check "no agent CLI is asked" bash -c '! ls "$1"/calls-claude "$1"/calls-codex "$1"/calls-agy "$1"/calls-gemini >/dev/null 2>&1' _ "$CASE"
check "gh auth status still runs (a read)" tool_called gh

echo "== verify: the lease and the credential search need the guest API and sudo"
new_case verify-lease
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$CASE/guest.sock"
run_machine verify
check "lease: ok when sudo acfs state lease status matches" status_is lease ok
check "asks acfs state lease status through sudo -n" grep -qx -- '-n acfs state lease status' "$CASE/calls-sudo"
export STUB_LEASE_MATCH=no
run_machine verify
unset STUB_LEASE_MATCH
check "lease: fail when they don't match" status_is lease fail
mkdir -p "$CASE/rootfs/root/.codex"
printf 'SECRET-root\n' >"$CASE/rootfs/root/.codex/auth.json"
run_machine verify
check "credentials-outside: fail, naming the path only" detail_has credentials-outside '/root/.codex/auth.json \(a rebuild loses them\)'
check "prints no secret" no_secret_printed
export STUB_NO_SUDO=1
run_machine verify
unset STUB_NO_SUDO
check "lease: skip without passwordless sudo" status_is lease skip
check "credentials-outside: skip without passwordless sudo" status_is credentials-outside skip

echo "== verify --json"
new_case verify-json
login_file .claude/.credentials.json
printf 'ssh-ed25519 AAAA host\n' >"$CASE/host_key.pub"
run_machine verify --json
check "exits 0" rc_is 0
check "stdout is a JSON array of checks" bash -c 'jq -e "type == \"array\" and (map(select(.check == \"claude\" and .status == \"ok\")) | length) == 1" "$1" >/dev/null' _ "$CASE/out"
check "every row has check, status and detail" bash -c 'jq -e "all(has(\"check\") and has(\"status\") and has(\"detail\"))" "$1" >/dev/null' _ "$CASE/out"
check "no table on stderr" err_lacks 'login stored'

echo "== verify <name>: host-side checks, then the checklist inside the instance"
new_case verify-named
installed_machine
printf 'Host dev\n    HostName 192.0.2.20\n' >"$CASE/home/.ssh/config"
run_machine verify dev
check "exits 0" rc_is 0
check "instance-lease: ok" status_is instance-lease ok
check "ssh-entry: ok through the entry" status_is ssh-entry ok
check "ssh runs in batch mode against dev" grep -q -- '-o BatchMode=yes -o ConnectTimeout=10 dev true' "$CASE/calls-ssh"
check "runs the guest checklist as the target user with the timeout" incus_called '^exec dev --env HOME=/home/ubuntu -- runuser -u ubuntu -- bash -s -- verify --json --timeout 90$'
check "streams this very script in on stdin" grep -qx '#!/usr/bin/env bash' "$CASE/streamed-script"
check "merges the guest report" both_ok claude lease
run_machine verify dev --read-only --timeout 30
check "--read-only and --timeout reach the guest" incus_called 'bash -s -- verify --json --read-only --timeout 30$'
rm -f "$CASE/home/.ssh/config"
run_machine verify dev
check "ssh-entry: not-configured without a Host entry" status_is ssh-entry not-configured
new_case verify-named-stopped
installed_machine
jq '.status = "Stopped"' "$CASE/inst-dev.json" >"$CASE/x" && mv "$CASE/x" "$CASE/inst-dev.json"
run_machine verify dev
check "a stopped instance: exits 1" rc_is 1
check "a stopped instance: says so" err_has "dev isn't running"
new_case verify-named-absent
run_machine verify dev
check "no such instance: exits 2" rc_is 2
new_case verify-named-guest-fails
installed_machine
echo '[{"check":"codex","status":"fail","detail":"login stored, mode 0600; codex login status says not logged in"}]' >"$CASE/guest-report.json"
export STUB_GUEST_EXIT=1
run_machine verify dev
unset STUB_GUEST_EXIT
check "a failing guest check: exits 1" rc_is 1
check "a failing guest check: is reported as such" status_is codex fail

echo "== acfs machine routes to machine.sh (doctor.sh's main)"
[[ "$(tail -n 1 "$DOCTOR")" == 'main "$@"' ]] || { echo "doctor.sh no longer ends in 'main \"\$@\"'" >&2; exit 1; }
mkdir -p "$WORK/route/lib"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$ROUTE_CALLS"\n' >"$WORK/route/lib/machine.sh"
: >"$WORK/route/calls"
ROUTE_CALLS="$WORK/route/calls" STUB_LIB_DIR="$WORK/route/lib" HOME="$WORK/route/home" \
bash -c '
    set +e
    # shellcheck disable=SC1090
    source <(sed "\$d" "$1") >/dev/null 2>&1
    shift
    _acfs_doctor_find_lib_script() { printf "%s\n" "$STUB_LIB_DIR/$1"; }
    _acfs_doctor_exec_bash_script() { local s="$1"; shift; bash "$s" "$@"; exit $?; }
    doctor_binary_path() { return 1; }
    main machine "$@"
' _ "$DOCTOR" verify dev --read-only >/dev/null 2>&1 || true
check "acfs machine verify dev --read-only reaches machine.sh unchanged" test "$(cat "$WORK/route/calls")" = "verify dev --read-only"

echo
echo "acfs machine (stubs): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
