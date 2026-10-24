#!/usr/bin/env bats
#
# acfs-htdm: network.ssh_keepalive's generated install and verify scripts,
# run against a fixture /etc/ssh with fake sshd and systemctl. The install
# runs on every default install, so it changes sshd only when that is safe:
# a positive value the user set stays, an edit sshd -t rejects is undone, and
# a rerun changes nothing. Where it can't (no SSH server, a config sshd
# already rejects, the user's drop-in with 0), it exits 1 with the reason,
# which the install records as a skipped tool.

load 'test_helper'

setup() {
    common_setup
    FIX="$BATS_TEST_TMPDIR/root"
    BIN="$BATS_TEST_TMPDIR/bin"
    CALLS="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$FIX/etc/ssh" "$BIN"
    : > "$CALLS"

    # sshd -t -f FILE: SSHD_REJECT=all rejects every config, SSHD_REJECT=new
    # rejects one that sets the keepalive (in FILE or a drop-in it includes),
    # each with SSHD_REASON on stderr. SSHD_PRIVSEP names a privilege
    # separation directory that must exist, as sshd -t as root needs.
    cat > "$BIN/sshd" <<'STUB'
#!/bin/bash
printf 'sshd %s\n' "$*" >> "$CALLS"
[[ "$1 $2" == "-t -f" ]] || exit 2
if [[ -n "${SSHD_PRIVSEP:-}" && ! -d "$SSHD_PRIVSEP" ]]; then
    printf 'Missing privilege separation directory: %s\n' "$SSHD_PRIVSEP" >&2
    exit 255
fi
reject() { printf '%s\nsecond line\n' "${SSHD_REASON:-bad config}" >&2; exit 255; }
case "${SSHD_REJECT:-}" in
    all) reject ;;
    new) cat "$3" "$(dirname "$3")"/sshd_config.d/*.conf 2>/dev/null | grep -qi '^ClientAliveInterval 60' && reject ;;
esac
exit 0
STUB
    printf '#!/bin/bash\nprintf "systemctl %%s\\n" "$*" >> "$CALLS"\n' > "$BIN/systemctl"
    chmod +x "$BIN/sshd" "$BIN/systemctl"
}

teardown() {
    common_teardown
}

# The Nth heredoc of acfs_generated_install_network_ssh_keepalive (1 the
# install, 2 the verify), pointed at the fixture: its /etc/ssh, and only the
# fake sshd.
module_script() {
    local script
    script="$(awk -v want="$1" "
        /<<'INSTALL_NETWORK_SSH_KEEPALIVE'\$/ { n++; on = (n == want); next }
        on && /^INSTALL_NETWORK_SSH_KEEPALIVE\$/ { exit }
        on" "$PROJECT_ROOT/scripts/generated/install_network.sh")"
    [[ -n "$script" ]] || return 1
    script="${script//\/etc\/ssh/$FIX/etc/ssh}"
    script="${script//\/run\/sshd/$FIX/run/sshd}"
    # The test isn't root, so /run/sshd is made without its root owner: that
    # is the one part of it this test can't check.
    script="${script//-o root -g root /}"
    script="${script//\/usr\/sbin\/sshd/$BIN/sshd}"
    script="${script//\/usr\/bin\/sshd/$BIN/sshd}"
    printf '%s\n' "$script"
}

# Both run as run_as_root_shell runs them: under set -euo pipefail.
run_install() {
    local script
    script="$(module_script 1)" || fail "the install script was not found in install_network.sh"
    run env PATH="$BIN:/usr/bin:/bin" CALLS="$CALLS" SSHD_REJECT="${SSHD_REJECT:-}" \
        SSHD_REASON="${SSHD_REASON:-}" SSHD_PRIVSEP="${SSHD_PRIVSEP:-}" bash -c "set -euo pipefail; $script"
}

run_verify() {
    local script
    script="$(module_script 2)" || fail "the verify script was not found in install_network.sh"
    run env PATH="$BIN:/usr/bin:/bin" CALLS="$CALLS" SSHD_REJECT="${SSHD_REJECT:-}" bash -c "set -euo pipefail; $script"
}

ubuntu_config() {
    mkdir -p "$FIX/etc/ssh/sshd_config.d"
    printf 'Include %s/etc/ssh/sshd_config.d/*.conf\n\n#ClientAliveInterval 0\nPermitRootLogin prohibit-password\n' "$FIX" \
        > "$FIX/etc/ssh/sshd_config"
}

reloads() {
    grep -c '^systemctl reload' "$CALLS" || true
}

@test "no SSH server: exits 1 naming openssh-server, and writes nothing" {
    rmdir "$FIX/etc/ssh"
    run_install
    assert_failure
    assert_output --partial "install openssh-server first; skipped"
    [[ ! -e "$FIX/etc/ssh" ]] || fail "something was written: $(ls -A "$FIX/etc/ssh")"
    [[ "$(reloads)" -eq 0 ]] || fail "sshd was reloaded"
}

@test "a drop-in directory: the keepalive goes in 60-acfs-keepalive.conf, sshd_config stays" {
    ubuntu_config
    cp "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before"
    run_install
    assert_success
    local dropin="$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf"
    grep -qx 'ClientAliveInterval 60' "$dropin" || fail "no ClientAliveInterval 60 in the drop-in"
    grep -qx 'ClientAliveCountMax 3' "$dropin" || fail "no ClientAliveCountMax 3 in the drop-in"
    [[ "$(stat -c %a "$dropin")" == 644 ]] || fail "the drop-in is $(stat -c %a "$dropin")"
    cmp -s "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before" || fail "sshd_config changed"
    [[ ! -e "$FIX/etc/ssh/sshd_config.acfs.bak" ]] || fail "a backup was made for an unchanged sshd_config"
    [[ "$(reloads)" -eq 1 ]] || fail "expected one reload, got $(reloads)"
    grep -qx 'systemctl reload ssh' "$CALLS" || fail "sshd was not reloaded"
    ! grep -q '^systemctl restart' "$CALLS" || fail "sshd was restarted"
    run_verify
    assert_success
}

@test "a rerun changes nothing and doesn't reload again" {
    ubuntu_config
    run_install
    assert_success
    cp "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" "$BATS_TEST_TMPDIR/dropin.before"
    run_install
    assert_success
    cmp -s "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" "$BATS_TEST_TMPDIR/dropin.before" \
        || fail "the drop-in changed on a rerun"
    [[ "$(reloads)" -eq 1 ]] || fail "a rerun reloaded sshd again ($(reloads) reloads)"
}

@test "the user's own ClientAliveInterval stays, in sshd_config or a drop-in" {
    printf 'PermitRootLogin no\nclientaliveinterval 30\n' > "$FIX/etc/ssh/sshd_config"
    cp "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before"
    run_install
    assert_success
    cmp -s "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before" || fail "the user's sshd_config changed"

    ubuntu_config
    printf 'ClientAliveInterval 120\n' > "$FIX/etc/ssh/sshd_config.d/10-mine.conf"
    run_install
    assert_success
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "a drop-in was added over the user's own"
    [[ "$(reloads)" -eq 0 ]] || fail "sshd was reloaded"
    run_verify
    assert_success
}

@test "no drop-in directory: the lines go before the first Match block, after a backup" {
    printf 'PermitRootLogin no\n\nMatch User deploy\n    ForceCommand /bin/false\n' > "$FIX/etc/ssh/sshd_config"
    chmod 0640 "$FIX/etc/ssh/sshd_config"
    cp -p "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before"
    run_install
    assert_success
    cmp -s "$FIX/etc/ssh/sshd_config.acfs.bak" "$BATS_TEST_TMPDIR/before" || fail "the backup isn't the original"
    local interval match
    interval="$(grep -n '^ClientAliveInterval 60$' "$FIX/etc/ssh/sshd_config" | cut -d: -f1)"
    match="$(grep -n '^Match User deploy$' "$FIX/etc/ssh/sshd_config" | cut -d: -f1)"
    [[ -n "$interval" && -n "$match" && "$interval" -lt "$match" ]] \
        || fail "ClientAliveInterval at line '$interval', Match at '$match'"
    grep -qx 'ClientAliveCountMax 3' "$FIX/etc/ssh/sshd_config" || fail "no ClientAliveCountMax 3"
    [[ "$(stat -c %a "$FIX/etc/ssh/sshd_config")" == 640 ]] || fail "the mode changed"
    [[ -z "$(compgen -G "$FIX/etc/ssh/sshd_config.acfs.??????")" ]] || fail "a temp copy is left"
    run_verify
    assert_success
    cp "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/after"
    run_install
    assert_success
    cmp -s "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/after" || fail "a rerun changed sshd_config"
}

@test "an edit sshd -t rejects is undone, and fails: the drop-in" {
    ubuntu_config
    SSHD_REJECT=new run_install
    assert_failure
    assert_output --partial "sshd -t rejected the keepalive drop-in"
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "the rejected drop-in is still there"
    [[ "$(reloads)" -eq 0 ]] || fail "sshd was reloaded"
}

@test "a drop-in that can't be written leaves nothing behind, and fails" {
    ubuntu_config
    mkdir "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf"
    run_install
    assert_failure
    assert_output --partial "could not write"
    [[ -d "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "the blocking directory went"
    [[ "$(reloads)" -eq 0 ]] || fail "sshd was reloaded"
}

@test "an edit sshd -t rejects is undone, and fails: sshd_config" {
    printf 'PermitRootLogin no\n' > "$FIX/etc/ssh/sshd_config"
    cp "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before"
    SSHD_REJECT=new run_install
    assert_failure
    assert_output --partial "sshd -t rejected the edited config"
    cmp -s "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before" || fail "sshd_config changed"
    [[ -z "$(compgen -G "$FIX/etc/ssh/sshd_config.acfs.??????")" ]] || fail "a temp copy is left"
    [[ "$(reloads)" -eq 0 ]] || fail "sshd was reloaded"
}

@test "a config sshd already rejects is left as it is, and exits 1 with the reason" {
    ubuntu_config
    cp "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before"
    SSHD_REJECT=all run_install
    assert_failure
    assert_output --partial "sshd -t rejects the current"
    cmp -s "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before" || fail "sshd_config changed"
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "a drop-in was written"
    [[ "$(reloads)" -eq 0 ]] || fail "sshd was reloaded"
}

@test "a skip names sshd -t's reason, its first line only" {
    ubuntu_config
    SSHD_REJECT=all SSHD_REASON="sshd: no hostkeys available -- exiting." run_install
    assert_failure
    assert_output --partial "(sshd: no hostkeys available -- exiting.); left as it is"
    refute_output --partial "second line"
}

@test "a missing /run/sshd (24.04 before the first SSH login) is made as the unit makes it, then the keepalive applies" {
    ubuntu_config
    mkdir -p "$FIX/run"
    SSHD_PRIVSEP="$FIX/run/sshd" run_install
    assert_success
    [[ -d "$FIX/run/sshd" && "$(stat -c %a "$FIX/run/sshd")" == 755 ]] || fail "/run/sshd is not a 0755 directory"
    grep -qx 'ClientAliveInterval 60' "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" || fail "the keepalive was not applied"
}

@test "a link at /run/sshd is never replaced: the run is a skip with sshd's reason" {
    ubuntu_config
    mkdir -p "$FIX/run"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$FIX/run/sshd"
    SSHD_PRIVSEP="$FIX/run/sshd" run_install
    assert_failure
    assert_output --partial "Missing privilege separation directory: $FIX/run/sshd"
    [[ -L "$FIX/run/sshd" && "$(readlink "$FIX/run/sshd")" == "$BATS_TEST_TMPDIR/elsewhere" ]] || fail "the link changed"
    [[ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]] || fail "the link's target was made"
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "a drop-in was written"
}

@test "only /run/sshd is made: another missing directory is a skip with its reason" {
    ubuntu_config
    SSHD_PRIVSEP="$FIX/var/empty" run_install
    assert_failure
    assert_output --partial "Missing privilege separation directory: $FIX/var/empty"
    [[ ! -e "$FIX/var/empty" ]] || fail "a directory other than /run/sshd was made"
}

@test "sshd_config without sshd: exits 1 naming openssh-server" {
    ubuntu_config
    rm -f "$BIN/sshd"
    run_install
    assert_failure
    assert_output --partial "sshd is not installed: install openssh-server first; skipped"
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "a drop-in was written"
}

@test "ClientAliveInterval 0 in sshd_config is replaced there, so it can't be read first" {
    ubuntu_config
    printf 'ClientAliveInterval 0\n' >> "$FIX/etc/ssh/sshd_config"
    run_install
    assert_success
    ! grep -qi '^ClientAliveInterval 0' "$FIX/etc/ssh/sshd_config" || fail "the 0 is still in sshd_config"
    grep -qx 'ClientAliveInterval 60' "$FIX/etc/ssh/sshd_config" || fail "no ClientAliveInterval 60 in sshd_config"
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "a drop-in was written behind the 0"
    [[ -f "$FIX/etc/ssh/sshd_config.acfs.bak" ]] || fail "no backup"
    run_verify
    assert_success
}

@test "the user's drop-in with ClientAliveInterval 0 is left, and exits 1 with the reason" {
    ubuntu_config
    printf 'ClientAliveInterval 0\n' > "$FIX/etc/ssh/sshd_config.d/10-mine.conf"
    cp "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before"
    run_install
    assert_failure
    assert_output --partial "sets ClientAliveInterval 0; left as it is"
    cmp -s "$FIX/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/before" || fail "sshd_config changed"
    [[ ! -e "$FIX/etc/ssh/sshd_config.d/60-acfs-keepalive.conf" ]] || fail "a drop-in was written behind the 0"
}

@test "verify fails with no keepalive, and with only a 0" {
    ubuntu_config
    run_verify
    assert_failure
    printf 'ClientAliveInterval 0\n' > "$FIX/etc/ssh/sshd_config.d/10-mine.conf"
    run_verify
    assert_failure
}
