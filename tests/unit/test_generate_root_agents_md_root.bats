#!/usr/bin/env bats
#
# acfs-evgn: scripts/generate-root-agents-md.sh (flywheel-update-agents-md)
# run as root for another user runs nothing of theirs. Its PATH holds only
# the system's directories, and the run goes on as the user through
# runuser with a clean environment, so their own run probes their tools
# and writes in their home. Only deploy --root writes as root: root takes
# the guide's text from the user's --dry-run on stdout, never reading their
# files, and creates /AGENTS.md, or its .acfs-new candidate, only where
# nothing is.
#
# A test can't be root, so it runs a copy of the script in which root is
# FAKE_ROOT=1 (the env -i of the user's run clears it), ROOT_PATH starts
# with a fake runuser that logs its arguments and runs the rest, and
# ROOT_AGENTS_MD is in the test's dir. The user's ubs is a stub that
# records whether it ran in the root run.

load 'test_helper'

setup() {
    FIX="$BATS_TEST_TMPDIR"
    HOMEFIX="$FIX/home/u"
    FAKEBIN="$FIX/fakebin"
    ME="$(id -un)"
    mkdir -p "$HOMEFIX/.local/bin" "$FAKEBIN" "$FIX/rootfs"
    GEN="$FIX/gen.sh"
    sed -e 's/\$EUID -eq 0/${FAKE_ROOT:-0} -eq 1/g' \
        -e 's/\$EUID -ne 0/${FAKE_ROOT:-0} -ne 1/g' \
        -e "s|^ROOT_PATH=.*|ROOT_PATH=\"$FAKEBIN:/usr/bin:/bin\"|" \
        -e "s|^ROOT_AGENTS_MD=.*|ROOT_AGENTS_MD=\"$FIX/rootfs/AGENTS.md\"|" \
        "$PROJECT_ROOT/scripts/generate-root-agents-md.sh" > "$GEN"
    grep -q "^ROOT_PATH=\"$FAKEBIN" "$GEN" || fail "the copy has no ROOT_PATH line"
    grep -q "^ROOT_AGENTS_MD=\"$FIX/rootfs" "$GEN" || fail "the copy has no ROOT_AGENTS_MD line"
    cat > "$FAKEBIN/runuser" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$RUNUSER_LOG"
[[ "$1" == -u && "$3" == -- ]] || exit 99
shift 3
exec "$@"
EOF
    cat > "$HOMEFIX/.local/bin/ubs" <<EOF
#!/bin/bash
printf 'FAKE_ROOT=%s\n' "\${FAKE_ROOT:-}" >> "$FIX/ubs-ran"
echo "ubs 7.8.9"
EOF
    chmod 755 "$FAKEBIN/runuser" "$HOMEFIX/.local/bin/ubs"
    export RUNUSER_LOG="$FIX/runuser.log"
}

# as_root ARGS...: the copy as root, for user $ME with home $HOMEFIX.
as_root() {
    run env FAKE_ROOT=1 ACFS_TARGET_USER="$ME" ACFS_TARGET_HOME="$HOMEFIX" \
        PATH="/usr/bin:/bin" bash "$GEN" "$@"
}

@test "as root, a generate runs as the user, through runuser with a clean environment, and root probes no tool" {
    as_root
    assert_success
    grep -qxF -- "-u $ME -- /usr/bin/env -i HOME=$HOMEFIX USER=$ME LOGNAME=$ME PATH=/usr/local/bin:/usr/bin:/bin ACFS_TARGET_USER=$ME ACFS_TARGET_HOME=$HOMEFIX bash $GEN" "$RUNUSER_LOG" \
        || fail "runuser got: $(cat "$RUNUSER_LOG")"
    grep -qF '| `ubs` | 7.8.9 |' "$HOMEFIX/.acfs/docs/flywheel-agent-guide.md" || fail "the user's run didn't probe ubs"
    run grep -c 'FAKE_ROOT=1' "$FIX/ubs-ran"
    [[ "$output" == 0 ]] || fail "root ran the user's ubs"
}

@test "as root, deploy --root writes the user's --dry-run text, and reads nothing at their canonical name" {
    mkdir -p "$HOMEFIX/.acfs/docs"
    printf 'SECRET\n' > "$FIX/secret"
    chmod 0444 "$FIX/secret"
    ln -s "$FIX/secret" "$HOMEFIX/.acfs/docs/flywheel-agent-guide.md"

    as_root deploy --root
    assert_success
    assert_output --partial "Status:      created"
    [[ -f "$FIX/rootfs/AGENTS.md" ]] || fail "AGENTS.md was not made"
    grep -qF '| `ubs` | 7.8.9 |' "$FIX/rootfs/AGENTS.md" || fail "not the user's generated guide"
    run grep -c SECRET "$FIX/rootfs/AGENTS.md"
    [[ "$output" == 0 ]] || fail "root copied the file at the canonical name"
    [[ "$(cat "$FIX/secret")" == SECRET ]] || fail "the secret changed"
    grep -qF -- "--dry-run" "$RUNUSER_LOG" || fail "root didn't take the text from the user's --dry-run"
    run grep -c 'FAKE_ROOT=1' "$FIX/ubs-ran"
    [[ "$output" == 0 ]] || fail "root ran the user's ubs"
}

@test "as root, deploy --root leaves an existing different file and writes the candidate; a link at the name isn't followed" {
    printf 'my own rules\n' > "$FIX/rootfs/AGENTS.md"
    as_root deploy --root
    [[ "$status" -eq 3 ]] || fail "status $status: $output"
    [[ "$(cat "$FIX/rootfs/AGENTS.md")" == "my own rules" ]] || fail "the existing file changed"
    grep -qF '| `ubs` | 7.8.9 |' "$FIX/rootfs/AGENTS.md.acfs-new" || fail "no candidate"

    rm -f "$FIX/rootfs/AGENTS.md" "$FIX/rootfs/AGENTS.md.acfs-new"
    ln -s "$FIX/victim" "$FIX/rootfs/AGENTS.md"
    as_root deploy --root
    [[ "$status" -eq 3 ]] || fail "status $status: $output"
    [[ ! -e "$FIX/victim" ]] || fail "root wrote through the dangling link"
    [[ -L "$FIX/rootfs/AGENTS.md" ]] || fail "the link changed"

    rm -f "$FIX/rootfs/AGENTS.md.acfs-new"
    ln -s "$FIX/victim2" "$FIX/rootfs/AGENTS.md.acfs-new"
    printf 'my own rules\n' > "$FIX/victim"
    rm -f "$FIX/rootfs/AGENTS.md"
    printf 'my own rules\n' > "$FIX/rootfs/AGENTS.md"
    as_root deploy --root
    [[ "$status" -eq 3 ]] || fail "status $status: $output"
    [[ ! -e "$FIX/victim2" ]] || fail "root wrote through a link at the candidate's name"
}

@test "as root, other deploy targets are the user's run" {
    as_root deploy --codex-global
    assert_success
    grep -qF -- "-u $ME -- /usr/bin/env -i" "$RUNUSER_LOG" || fail "no runuser"
    grep -qF "bash $GEN deploy --codex-global" "$RUNUSER_LOG" || fail "runuser got: $(cat "$RUNUSER_LOG")"
    [[ -f "$HOMEFIX/.codex/AGENTS.md" ]] || fail "the user's run didn't deploy"
}

@test "the user's own run is unchanged: no runuser, and their tools are probed" {
    run env ACFS_TARGET_HOME="$HOMEFIX" PATH="/usr/bin:/bin" bash "$GEN"
    assert_success
    [[ ! -e "$RUNUSER_LOG" ]] || fail "a user's own run called runuser"
    grep -qF '| `ubs` | 7.8.9 |' "$HOMEFIX/.acfs/docs/flywheel-agent-guide.md" || fail "ubs wasn't probed"
}
