#!/usr/bin/env bash
# ============================================================
# user_container_tmp_policy (scripts/lib/user.sh, acfs-ioo3.7) and
# acfs.zshrc's TMPDIR block, against stub systemd-detect-virt,
# systemctl and findmnt
#
# Proves that in an LXC container the installer masks tmp.mount, makes
# the agents' TMPDIR on the data volume and writes it to
# ~/.config/environment.d; that it does nothing on a VPS, a VM or in
# Docker; that a rerun changes nothing; and that zsh exports what the
# file says only when it names an existing absolute directory.
#
# Safe by construction: every run goes through in_stub_env, which puts
# a stub sudo first on PATH and passes it as SUDO, and a preflight
# aborts before any scenario if sudo, systemctl, systemd-detect-virt
# or findmnt would resolve outside the stubs. (A first version passed
# SUDO="", which user.sh turns into a real sudo; sudo's secure_path
# then skipped the stub systemctl and masked the host's tmp.mount.)
# It refuses to run as root.
#
# Usage: bash tests/unit/test_container_tmp_policy.sh
# ============================================================

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "FATAL: run this test as an unprivileged user; as root the policy's commands would act on the host" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfs-container-tmp-policy-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

STUBS="$WORK/stubs"
CALLS="$WORK/calls"
mkdir -p "$STUBS"
cat > "$STUBS/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_VIRT:-none}"
[[ "${STUB_VIRT:-none}" != none ]]
EOF
cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_CALLS"
case "$1" in
    is-enabled) echo "${STUB_UNIT_STATE:-static}"; [[ "${STUB_UNIT_STATE:-static}" == enabled ]] ;;
    mask) exit "${STUB_MASK_RC:-0}" ;;
    *) exit 1 ;;
esac
EOF
cat > "$STUBS/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_TMP_FSTYPE:-ext4}"
EOF
# sudo without privileges: records the call, drops sudo's own options
# and runs the command through PATH, so it reaches the stubs above.
cat > "$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$STUB_CALLS"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
chmod +x "$STUBS"/*

ME="$(id -un)"
ENV_REL=".config/environment.d/60-acfs-tmpdir.conf"

# in_stub_env [env assignments...] -- <command...>: the only way this
# test runs anything that sources user.sh. Later assignments win, so a
# caller can't put a real sudo back on PATH.
in_stub_env() {
    local assignments=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
        assignments+=("$1")
        shift
    done
    shift
    env "${assignments[@]}" PATH="$STUBS:$PATH" STUB_CALLS="$CALLS" SUDO="${STUB_SUDO-$STUBS/sudo}" "$@"
}

# Preflight: abort before any scenario unless every privileged name
# resolves to a stub, with SUDO as the scenarios pass it and with SUDO
# empty (user.sh then picks "sudo" from PATH).
preflight() {
    local label="$1" resolved="" name=""
    shift
    resolved="$(in_stub_env "$@" -- bash -c '
        source "$1" >/dev/null 2>&1
        printf "SUDO=%s\n" "$(type -P "${SUDO:-sudo}")"
        for name in sudo systemctl systemd-detect-virt findmnt; do
            printf "%s=%s\n" "$name" "$(type -P "$name")"
        done
    ' _ "$ROOT/scripts/lib/user.sh")"
    while IFS='=' read -r name path; do
        if [[ "$path" != "$STUBS/"* ]]; then
            echo "FATAL: preflight ($label): $name resolves to '$path', outside the stubs; refusing to run" >&2
            exit 2
        fi
    done <<< "$resolved"
}
preflight "stub SUDO"
STUB_SUDO="" preflight "empty SUDO"
echo "Preflight: sudo, systemctl, systemd-detect-virt and findmnt are stubs"

# run_policy <name> [env assignments...]: runs the policy with the home
# and data dir under $WORK/<name>; output in $WORK/<name>.out, exit
# code in $WORK/<name>.rc.
run_policy() {
    local name="$1"
    shift
    mkdir -p "$WORK/$name/home" "$WORK/$name/data"
    : > "$CALLS"
    local rc=0
    in_stub_env "$@" -- bash -c 'source "$1"; user_container_tmp_policy "$2" "$3" "$4"' _ \
        "$ROOT/scripts/lib/user.sh" "$ME" "$WORK/$name/home" "$WORK/$name/data/tmp" \
        > "$WORK/$name.out" 2>&1 || rc=$?
    echo "$rc" > "$WORK/$name.rc"
}

rc_is() { [[ "$(cat "$WORK/$1.rc")" == "$2" ]]; }
out_has() { grep -qF -- "$2" "$WORK/$1.out"; }
no_calls() { [[ ! -s "$CALLS" ]]; }
called() { grep -qxF -- "$1" "$CALLS"; }
not_called() { ! grep -qxF -- "$1" "$CALLS"; }
env_file_is() {
    [[ -f "$WORK/$1/home/$ENV_REL" ]] && grep -qxF -- "TMPDIR=$WORK/$1/data/tmp" "$WORK/$1/home/$ENV_REL"
}
no_env_file() { [[ ! -e "$WORK/$1/home/$ENV_REL" ]]; }
mode_is() { [[ "$(stat -c '%a' -- "$1")" == "$2" ]]; }

echo "Outside an LXC container nothing changes"
for virt in none docker wsl; do
    run_policy "virt-$virt" STUB_VIRT="$virt"
    check "$virt: returns 0" rc_is "virt-$virt" 0
    check "$virt: no systemctl call" no_calls
    check "$virt: no environment.d file" no_env_file "virt-$virt"
    check "$virt: no TMPDIR made" test ! -e "$WORK/virt-$virt/data/tmp"
done

echo "In an LXC container"
run_policy lxc STUB_VIRT=lxc
check "returns 0" rc_is lxc 0
check "masks tmp.mount" called "systemctl mask tmp.mount"
check "makes the TMPDIR" test -d "$WORK/lxc/data/tmp"
check "the TMPDIR is 755" mode_is "$WORK/lxc/data/tmp" 755
check "writes TMPDIR to environment.d" env_file_is lxc
check "masks through the stub sudo" called "sudo systemctl mask tmp.mount"
check "the mask is the only sudo call" test "$(grep -c '^sudo ' "$CALLS")" -eq 1
check "reloads the user manager" called "systemctl --user daemon-reload"
check "leaves no temp file next to it" bash -c '[[ -z "$(find "$1" -name ".acfs-tmpdir.*")" ]]' _ "$WORK/lxc/home/.config/environment.d"
check "no tmpfs warning on a disk /tmp" bash -c '! grep -q "is a tmpfs" "$1"' _ "$WORK/lxc.out"

echo "A rerun changes nothing"
inode_before="$(stat -c '%i %Y' -- "$WORK/lxc/home/$ENV_REL")"
: > "$CALLS"
rerun_rc=0
in_stub_env STUB_VIRT=lxc STUB_UNIT_STATE=masked -- \
    bash -c 'source "$1"; user_container_tmp_policy "$2" "$3" "$4"' _ \
    "$ROOT/scripts/lib/user.sh" "$ME" "$WORK/lxc/home" "$WORK/lxc/data/tmp" > "$WORK/rerun.out" 2>&1 \
    || rerun_rc=$?
echo "$rerun_rc" > "$WORK/rerun.rc"
check "returns 0" rc_is rerun 0
check "does not mask again" not_called "systemctl mask tmp.mount"
check "says it is already masked" out_has rerun "already masked"
check "keeps the environment.d file as it was" test "$inode_before" == "$(stat -c '%i %Y' -- "$WORK/lxc/home/$ENV_REL")"

echo "Regression: an empty SUDO still reaches only the stubs"
# The first version's bug: SUDO="" made user.sh use "sudo". The stub
# sudo logs the call and the stub systemctl logs the mask after it; a
# real sudo would have skipped the stub systemctl (secure_path).
STUB_SUDO="" run_policy emptysudo STUB_VIRT=lxc
check "returns 0" rc_is emptysudo 0
check "the mask went through the stub sudo" called "sudo systemctl mask tmp.mount"
check "and reached the stub systemctl" called "systemctl mask tmp.mount"
check "the mask is the only sudo call" test "$(grep -c '^sudo ' "$CALLS")" -eq 1

echo "A failed mask warns and still sets TMPDIR"
run_policy maskfail STUB_VIRT=lxc STUB_MASK_RC=1
check "returns 0" rc_is maskfail 0
check "warns" out_has maskfail "Could not mask tmp.mount"
check "writes TMPDIR to environment.d" env_file_is maskfail

echo "A tmpfs /tmp right now gets a warning"
run_policy tmpfs STUB_VIRT=lxc STUB_TMP_FSTYPE=tmpfs
check "returns 0" rc_is tmpfs 0
check "warns that /tmp is a tmpfs until the restart" out_has tmpfs "/tmp is a tmpfs right now"

echo "A symlinked TMPDIR is left alone"
mkdir -p "$WORK/symlink/data" "$WORK/elsewhere"
ln -s "$WORK/elsewhere" "$WORK/symlink/data/tmp"
run_policy symlink STUB_VIRT=lxc
check "returns 0" rc_is symlink 0
check "says why" out_has symlink "is a symlink; TMPDIR stays unchanged"
check "no environment.d file" no_env_file symlink
check "the link is untouched" test "$(readlink "$WORK/symlink/data/tmp")" == "$WORK/elsewhere"

echo "Without its arguments it returns 1"
args_rc=0
in_stub_env STUB_VIRT=lxc -- bash -c 'source "$1"; user_container_tmp_policy "" ""' _ \
    "$ROOT/scripts/lib/user.sh" > /dev/null 2>&1 || args_rc=$?
check "returns 1" test "$args_rc" -eq 1

echo "A TMPDIR path that is a file is left alone"
mkdir -p "$WORK/isfile/data"
echo keep > "$WORK/isfile/data/tmp"
run_policy isfile STUB_VIRT=lxc
check "returns 0" rc_is isfile 0
check "warns" out_has isfile "TMPDIR stays unchanged"
check "no environment.d file" no_env_file isfile
check "the file is untouched" grep -qx keep "$WORK/isfile/data/tmp"

echo "An existing TMPDIR keeps its mode"
mkdir -p "$WORK/existing/data/tmp"
chmod 700 "$WORK/existing/data/tmp"
run_policy existing STUB_VIRT=lxc
check "returns 0" rc_is existing 0
check "mode stays 700" mode_is "$WORK/existing/data/tmp" 700
check "writes TMPDIR to environment.d" env_file_is existing

GENERATOR=/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
if [[ -x "$GENERATOR" ]]; then
    echo "systemd's environment.d generator reads the file"
    check "the generator yields TMPDIR" bash -c \
        'XDG_CONFIG_HOME="$1/.config" "$2" | grep -qxF "TMPDIR=$3"' _ \
        "$WORK/lxc/home" "$GENERATOR" "$WORK/lxc/data/tmp"
else
    echo "  skip systemd's environment.d generator: not installed"
fi

echo "acfs.zshrc's TMPDIR block"
BLOCK="$WORK/zshrc_block"
sed -n '/^# --- TMPDIR in a container ---$/,/^fi$/p' "$ROOT/acfs/zsh/acfs.zshrc" > "$BLOCK"
check "the block is found" grep -q 'environment.d/60-acfs-tmpdir.conf' "$BLOCK"
zhome="$WORK/zhome"
mkdir -p "$zhome/.config/environment.d" "$WORK/ztmp"
shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh) || echo "  skip zsh: not installed (bash runs the block)"
# zsh_tmpdir <shell> <file content>: TMPDIR after sourcing the block
zsh_tmpdir() {
    printf '%s\n' "$2" > "$zhome/.config/environment.d/60-acfs-tmpdir.conf"
    if [[ "$1" == zsh ]]; then
        HOME="$zhome" TMPDIR=/before zsh -f -c 'source "$1"; print -r -- "$TMPDIR"' _ "$BLOCK"
    else
        HOME="$zhome" TMPDIR=/before bash -c 'source "$1"; printf "%s\n" "$TMPDIR"' _ "$BLOCK"
    fi
}
for sh in "${shells[@]}"; do
    check "$sh: exports an existing directory" test "$(zsh_tmpdir "$sh" "# c"$'\n'"TMPDIR=$WORK/ztmp")" == "$WORK/ztmp"
    check "$sh: reads a quoted value, as doctor does" test "$(zsh_tmpdir "$sh" "TMPDIR=\"$WORK/ztmp\"")" == "$WORK/ztmp"
    check "$sh: keeps TMPDIR for a missing directory" test "$(zsh_tmpdir "$sh" "TMPDIR=$WORK/missing")" == /before
    check "$sh: keeps TMPDIR for a relative path" test "$(zsh_tmpdir "$sh" "TMPDIR=ztmp")" == /before
    check "$sh: ignores other variables" test "$(zsh_tmpdir "$sh" "PATH=$WORK/ztmp")" == /before
done
rm -f "$zhome/.config/environment.d/60-acfs-tmpdir.conf"
check "no file: TMPDIR unchanged" test "$(HOME="$zhome" TMPDIR=/before bash -c 'source "$1"; printf "%s\n" "$TMPDIR"' _ "$BLOCK")" == /before

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
