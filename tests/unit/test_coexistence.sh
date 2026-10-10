#!/usr/bin/env bash
# ============================================================
# Coexistence (acfs-ioo3.16): Incus next to podman and Docker.
#
# Runs scripts/lib/coexistence.sh against stub incus, podman, docker, ip,
# iptables, nft and sudo (through ACFS_COEX_SYSTEM_BIN_PREFIX with
# ACFS_COEX_SYSTEM_BIN_ONLY=1, so the runner's real tools stay out of it),
# and /etc under a test root (ACFS_COEX_ROOT). Nothing here reaches the
# host's firewall, networks or containers.
#
# Run with: bash scripts/tests/run_gate.sh -- bash tests/unit/test_coexistence.sh
# ============================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
COEX_SH="$REPO_ROOT/scripts/lib/coexistence.sh"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '  got: %s\n' "$2"
    return 0
}
check() { # check <name> <condition...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name" "${OUT:-}"; fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
lacks() { [[ "$OUT" != *"$1"* ]]; }

ROOT="$(mktemp -d)"
SYSBIN="$ROOT/sysbin"
STATE="$ROOT/state"
cleanup() {
    find "$ROOT" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$ROOT" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
    rmdir "$ROOT" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$SYSBIN" "$STATE" "$ROOT/etc/docker"
chmod 700 "$ROOT" "$SYSBIN"
for tool in python3 timeout; do
    real="$(command -v "$tool")" && ln -s "$real" "$SYSBIN/$tool"
done

# ------------------------------------------------------------
# Stubs: each answers from files in $STUB_STATE.
# ------------------------------------------------------------
cat > "$SYSBIN/incus" <<'EOF'
#!/usr/bin/env bash
printf 'incus %s\n' "$*" >> "$STUB_STATE/calls"
case "$1 $2" in
    "network list")
        case "$*" in
            *"-c n46"*) cat "$STUB_STATE/incus-n46" 2>/dev/null ;;
            *"-c ntm"*) cat "$STUB_STATE/incus-ntm" 2>/dev/null ;;
        esac ;;
    "exec "*)
        # exec <instance> -- sh -c <script> probe <flow> <args...>
        # exec-exit: incus itself fails (a stopped instance); rc-<flow>: the
        # probe exits with that code; fail: listed flows exit 1 (refused).
        [[ ! -s "$STUB_STATE/exec-exit" ]] || exit "$(cat "$STUB_STATE/exec-exit")"
        shift 2; [[ "$1" == -- ]] && shift
        printf '%s' "$3" > "$STUB_STATE/probe-script"
        shift 4
        printf 'flow %s\n' "$*" >> "$STUB_STATE/flows"
        [[ ! -s "$STUB_STATE/rc-$1" ]] || exit "$(cat "$STUB_STATE/rc-$1")"
        ! grep -qxF -- "$*" "$STUB_STATE/fail" 2>/dev/null ;;
esac
EOF
cat > "$SYSBIN/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >> "$STUB_STATE/calls"
case "$1" in
    info) printf 'netavark\n' ;;
    network)
        case "$2" in
            ls) cat "$STUB_STATE/podman-networks" 2>/dev/null ;;
            inspect)
                name="${*: -1}"
                case "$*" in
                    *NetworkInterface*) cat "$STUB_STATE/podman-iface-$name" 2>/dev/null ;;
                    *Subnets*) cat "$STUB_STATE/podman-subnets-$name" 2>/dev/null ;;
                esac ;;
        esac ;;
    run)
        # run --rm --pull=never <image> sh -c <script> probe <flow> <args...>
        shift 8
        printf 'podman-flow %s\n' "$*" >> "$STUB_STATE/flows"
        ! grep -qxF -- "$*" "$STUB_STATE/fail" 2>/dev/null ;;
esac
EOF
cat > "$SYSBIN/ip" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -4) cat "$STUB_STATE/routes4" 2>/dev/null ;;
    -6) cat "$STUB_STATE/routes6" 2>/dev/null ;;
esac
EOF
cat > "$SYSBIN/iptables" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    -V) printf 'iptables v1.8.10 (nf_tables)\n' ;;
    "-S FORWARD") cat "$STUB_STATE/forward" ;;
    "-S DOCKER-USER") cat "$STUB_STATE/docker-user" 2>/dev/null ;;
esac
EOF
cat > "$SYSBIN/sudo" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$STUB_STATE/no-sudo" ]] || exit 1
[[ "$1" == -n ]] && shift
printf 'sudo %s\n' "$*" >> "$STUB_STATE/calls"
"$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$SYSBIN/nft"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SYSBIN/docker"
chmod 755 "$SYSBIN"/incus "$SYSBIN"/podman "$SYSBIN"/ip "$SYSBIN"/iptables "$SYSBIN"/sudo "$SYSBIN"/nft "$SYSBIN"/docker

export STUB_STATE="$STATE"
export ACFS_COEX_SYSTEM_BIN_PREFIX="$SYSBIN"
export ACFS_COEX_SYSTEM_BIN_ONLY=1
export ACFS_COEX_ROOT="$ROOT"

run() { OUT="$(bash "$COEX_SH" "$@" 2>&1)"; RC=$?; }
reset_state() {
    find "$STATE" -mindepth 1 -type f -exec rm -f {} + 2>/dev/null
    rm -f "$ROOT/etc/subuid" "$ROOT/etc/subgid" "$ROOT/etc/docker/daemon.json"
    printf 'incusbr0,10.220.52.1/24,fd42:1::1/64\n' > "$STATE/incus-n46"
    printf 'incusbr0,bridge,YES\neth0,physical,NO\n' > "$STATE/incus-ntm"
    printf 'podman\n' > "$STATE/podman-networks"
    printf 'podman0\n' > "$STATE/podman-iface-podman"
    printf '10.88.0.0/16 \n' > "$STATE/podman-subnets-podman"
    printf '%s\n' 'default via 192.168.1.1 dev eth0 proto dhcp' \
        '10.88.0.0/16 dev podman0 proto kernel scope link src 10.88.0.1' \
        '10.220.52.0/24 dev incusbr0 proto kernel scope link src 10.220.52.1' \
        '192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.20' \
        'local 192.168.1.20 dev eth0 table local proto kernel scope host src 192.168.1.20' \
        '100.64.0.0/10 dev tailscale0 table 52' > "$STATE/routes4"
    printf '%s\n' 'fe80::/64 dev eth0 proto kernel metric 256' \
        'fd42:1::/64 dev incusbr0 proto kernel metric 256' \
        'multicast ff00::/8 dev eth0 table local proto kernel metric 256' > "$STATE/routes6"
    printf '%s\n' '-P INPUT ACCEPT' '-P FORWARD DROP' '-P OUTPUT ACCEPT' '-N DOCKER-USER' > "$STATE/forward"
    printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j RETURN' > "$STATE/docker-user"
}
line_for() { grep -F "	$1	" <<<"$OUT" | head -1; }

# ------------------------------------------------------------
# check: firewall backend
# ------------------------------------------------------------
reset_state
run check
OUT_ALL="$OUT"
OUT="$(line_for coexist.firewall)"
check "firewall: reports iptables, nft, podman's backend and Docker" \
    has $'pass\tcoexist.firewall\tFirewall backend\tiptables: nf_tables; nft: present; podman: netavark; docker: present'
OUT="$OUT_ALL"
check "check: exits 0" test "$RC" -eq 0
if [[ "$(id -u)" != 0 ]]; then
    check "firewall: podman's backend is read as root, never rootless" \
        grep -q '^sudo .*/podman info' "$STATE/calls"
    check "check: sudo -n is probed once per run" test "$(grep -c '^sudo true$' "$STATE/calls")" -eq 1

    reset_state
    touch "$STATE/no-sudo"
    run check
    OUT="$(line_for coexist.firewall)"
    check "firewall: without root, podman's backend is unknown" has "podman: unknown (needs root)"
    OUT="$(cat "$STATE/calls" 2>/dev/null)"
    check "firewall: ... and podman never runs as the user" lacks "podman info"
fi

# ------------------------------------------------------------
# check: subnets
# ------------------------------------------------------------
OUT="$OUT_ALL"
OUT="$(line_for coexist.subnets)"
check "subnets: disjoint ranges pass; the bridges' own routes and link-local ones don't count" \
    has $'pass\tcoexist.subnets'

reset_state
printf 'incusbr0,10.88.0.1/24,\n' > "$STATE/incus-n46"
run check
OUT="$(line_for coexist.subnets)"
check "subnets: an Incus network inside podman's range warns, naming both" \
    has "incus network incusbr0 10.88.0.0/24 overlaps podman network podman 10.88.0.0/16"
check "subnets: the warning is a warn with a fix" has $'warn\tcoexist.subnets'
check "subnets: podman's own route on podman0 is not a third party" lacks "route via podman0"
OUT="$(cat "$STATE/calls")"
if [[ "$(id -u)" != 0 ]]; then
    check "subnets: podman's networks are root's (rootless ones never meet the host)" \
        grep -q '^sudo .*/podman network ls' "$STATE/calls"
fi

if [[ "$(id -u)" != 0 ]]; then
    touch "$STATE/no-sudo"
    run check
    OUT="$(line_for coexist.subnets)"
    check "subnets: without sudo, a rootful podman0 is still caught as a route" has "route via podman0 10.88.0.0/16"
fi

reset_state
printf '10.0.0.0/8 dev wg0 proto static\n' >> "$STATE/routes4"
run check
OUT="$(line_for coexist.subnets)"
check "subnets: a VPN route covering the Incus bridge warns" has "route via wg0 10.0.0.0/8"
check "subnets: ... and also podman's range" has "podman network podman 10.88.0.0/16"

reset_state
printf '100.100.0.0/16 dev wg0\n' >> "$STATE/routes4"
run check
OUT="$(line_for coexist.subnets)"
check "subnets: a route inside the tailnet's range warns" has "100.64.0.0/10"

reset_state
printf 'incusbr0,10.220.52.1/24,fd42:1::1/64\n' > "$STATE/incus-n46"
printf 'fd42::/16 dev wg6\n' >> "$STATE/routes6"
run check
OUT="$(line_for coexist.subnets)"
check "subnets: IPv6 overlaps are found too" has "incus network incusbr0 fd42:1::/64"

# ------------------------------------------------------------
# check: subordinate ids
# ------------------------------------------------------------
reset_state
run check
OUT="$(line_for coexist.subids)"
check "subids: no files skips" has $'skip\tcoexist.subids'

printf 'root:1000000:1000000000\nubuntu:100000:65536\n' > "$ROOT/etc/subuid"
cp "$ROOT/etc/subuid" "$ROOT/etc/subgid"
run check
OUT="$(line_for coexist.subids)"
check "subids: disjoint ranges pass" has $'pass\tcoexist.subids'

printf 'alice:1500000:65536\n' >> "$ROOT/etc/subuid"
run check
OUT="$(line_for coexist.subids)"
check "subids: a range inside root's warns, naming both owners" \
    has "/etc/subuid: root 1000000-1000999999 and alice 1500000-1565535"
check "subids: /etc/subgid is clean, so only subuid is named" lacks "/etc/subgid:"

# ------------------------------------------------------------
# check: Docker's FORWARD DROP (acfs-31uo)
# ------------------------------------------------------------
reset_state
run check
OUT="$(line_for coexist.docker_forward)"
check "docker: FORWARD DROP without a DOCKER-USER accept warns" has $'warn\tcoexist.docker_forward'
check "docker: the fix names Incus's documented rules for the bridge" \
    has "sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT; sudo iptables -I DOCKER-USER -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
check "docker: the fix also offers ip-forward-no-drop" has '"ip-forward-no-drop": true'
check "docker: an unmanaged interface is not named" lacks "-i eth0"

printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -i incusbr0 -j ACCEPT' \
    '-A DOCKER-USER -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' '-A DOCKER-USER -j RETURN' > "$STATE/docker-user"
run check
OUT="$(line_for coexist.docker_forward)"
check "docker: DOCKER-USER accepting the bridge passes" has $'pass\tcoexist.docker_forward'

reset_state
printf 'incus.br,bridge,YES\n' > "$STATE/incus-ntm"
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -i incusXbr -j ACCEPT' > "$STATE/docker-user"
run check
OUT="$(line_for coexist.docker_forward)"
check "docker: a bridge name is matched exactly, not as a regex" has "doesn't accept incus.br"

reset_state
printf '{ "ip-forward-no-drop": true }\n' > "$ROOT/etc/docker/daemon.json"
run check
OUT="$(line_for coexist.docker_forward)"
check "docker: ip-forward-no-drop passes without reading iptables" has "ip-forward-no-drop is set"

reset_state
printf '%s\n' '-P FORWARD ACCEPT' > "$STATE/forward"
run check
OUT="$(line_for coexist.docker_forward)"
check "docker: FORWARD ACCEPT passes" has "FORWARD policy is not DROP"

if [[ "$(id -u)" != 0 ]]; then
    reset_state
    touch "$STATE/no-sudo"
    run check
    OUT="$(line_for coexist.docker_forward)"
    check "docker: without root or sudo -n it skips and says how to look" has $'skip\tcoexist.docker_forward\tDocker and Incus forwarding\treading FORWARD needs root'
fi

reset_state
rm -f "$SYSBIN/docker"
run check
check "docker: absent, the check stays silent" lacks "coexist.docker_forward"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SYSBIN/docker"; chmod 755 "$SYSBIN/docker"

# ------------------------------------------------------------
# traffic
# ------------------------------------------------------------
reset_state
run traffic --instance acfs-tests:devbox --api 10.220.52.1:8443 --ssh 10.221.0.5:22 --deny 192.168.1.1:22
check "traffic: a reachable private destination fails the run" test "$RC" -eq 1
check "traffic: ... and names the flow" has "FAIL incus.deny: private destination 192.168.1.1:22 (reached; it must be refused)"
check "traffic: DNS IPv4 passes" has "PASS incus.dns4: DNS cloudflare.com (IPv4)"
check "traffic: the API flow passes" has "PASS incus.api: Incus API 10.220.52.1:8443"
check "traffic: the SSH flow passes" has "PASS incus.ssh: SSH 10.221.0.5:22"
check "traffic: no podman image skips podman" has "SKIP podman: no --podman-image"
OUT="$(cat "$STATE/flows")"
check "traffic: host and port reach the probe as arguments" has "flow tcp 10.220.52.1 8443"
OUT="$(cat "$STATE/probe-script")"
check "traffic: the probe script carries no caller value" lacks "cloudflare.com"
OUT="$(cat "$STATE/calls")"
check "traffic: the instance is reached with incus exec" has "incus exec acfs-tests:devbox -- sh -c"

reset_state
printf '%s\n' 'tcp 192.168.1.1 22' 'https6 https://cloudflare.com' > "$STATE/fail"
run traffic --instance devbox --deny 192.168.1.1:22 --save "$ROOT/before.txt"
check "traffic: a refused destination passes, and an IPv6 failure only warns" test "$RC" -eq 0
check "traffic: refused is reported" has "PASS incus.deny: private destination 192.168.1.1:22 (refused)"
check "traffic: the IPv6 failure is a warning" has "WARN incus.https6"
check "traffic: --save writes the result" test -s "$ROOT/before.txt"

printf '%s\n' 'tcp 192.168.1.1 22' 'https6 https://cloudflare.com' 'https4 https://cloudflare.com' > "$STATE/fail"
run traffic --instance devbox --deny 192.168.1.1:22 --compare "$ROOT/before.txt"
check "traffic: --compare reports a flow that stopped passing" has "CHANGED incus.https4 PASS -> FAIL"
check "traffic: ... and fails the run" test "$RC" -eq 1
check "traffic: unchanged flows aren't listed" lacks "CHANGED incus.dns4"

reset_state
run traffic --podman-image localhost/probe:latest
check "traffic: podman flows run in a container with --pull=never" test "$RC" -eq 0
OUT="$(cat "$STATE/calls")"
check "traffic: ... never pulling" has "podman run --rm --pull=never localhost/probe:latest sh -c"
OUT="$(cat "$STATE/flows")"
check "traffic: podman runs DNS and HTTPS flows" has "podman-flow https4 https://cloudflare.com"
check "traffic: podman runs no ACL flows" lacks "podman-flow tcp"

# The deny flow fails closed (SunnyRabbit's review, finding 1)
reset_state
printf '1\n' > "$STATE/exec-exit"
run traffic --instance devbox --deny 192.168.1.1:22
check "traffic: a stopped instance fails the run" test "$RC" -eq 1
check "traffic: ... at the ready preflight" has "FAIL incus.ready: the probe can't run"
check "traffic: ... and never reports the destination as refused" lacks "PASS incus.deny"

reset_state
printf '3\n' > "$STATE/rc-ready"
run traffic --instance devbox --deny 192.168.1.1:22
check "traffic: an instance missing a tool fails the stack" has "FAIL incus.ready"
check "traffic: ... and runs none of its flows" lacks "incus.dns4"

reset_state
printf '3\n' > "$STATE/rc-tcp"
run traffic --instance devbox --deny 192.168.1.1:22
check "traffic: a tcp probe error is not a refusal" has "FAIL incus.deny: private destination 192.168.1.1:22 (probe error, exit 3: not tested)"
check "traffic: ... and fails the run" test "$RC" -eq 1
OUT="$(cat "$STATE/flows")"
check "traffic: the incus preflight asks for getent, curl, timeout and bash" has "flow ready getent curl timeout bash"
OUT="$(cat "$STATE/probe-script")"
check "traffic: the probe maps only refused or timed out to 1" has '1|124) exit 1'

reset_state
run traffic --instance devbox --api 'evil;rm:22'
check "traffic: a bad HOST:PORT is refused before anything runs" test "$RC" -eq 2
check "traffic: ... with nothing executed" test ! -e "$STATE/flows"
run traffic --instance devbox --dns 'a b'
check "traffic: a bad DNS name is refused" test "$RC" -eq 2
run traffic
check "traffic: neither --instance nor --podman-image is refused" test "$RC" -eq 2

# ------------------------------------------------------------
# The doctor's check_coexistence maps the lines onto its own check calls
# ------------------------------------------------------------
reset_state
DOCTOR_HOME="$ROOT/home"
mkdir -p "$DOCTOR_HOME/.acfs/scripts/lib"
cp "$COEX_SH" "$DOCTOR_HOME/.acfs/scripts/lib/coexistence.sh"
doctor_fn="$ROOT/check_coexistence.sh"
sed -n '/^check_coexistence() {$/,/^}$/p' "$REPO_ROOT/scripts/lib/doctor.sh" > "$doctor_fn"
check "doctor: check_coexistence exists" test -s "$doctor_fn"
OUT="$(
    doctor_binary_exists() { [[ "$1" == incus ]]; }
    doctor_runtime_home() { printf '%s\n' "$DOCTOR_HOME"; }
    check() { printf 'CHECK %s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}"; }
    # shellcheck source=/dev/null
    source "$doctor_fn"
    check_coexistence
)"
check "doctor: each finding becomes a check" has "CHECK coexist.firewall|Firewall backend|pass|iptables: nf_tables"
check "doctor: a warning keeps its fix" has "CHECK coexist.docker_forward|Docker and Incus forwarding|warn|"
check "doctor: ... with Incus's documented rules" has "sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT"
OUT="$(
    doctor_binary_exists() { return 1; }
    check() { printf 'CHECK %s\n' "$1"; }
    # shellcheck source=/dev/null
    source "$doctor_fn"
    check_coexistence
)"
check "doctor: without Incus it says nothing (check_incus already reports it)" test -z "$OUT"

# A helper that outlives the limit (acfs-wwk0): the findings it printed stay,
# and a warning says the rest timed out instead of vanishing.
SLOW_HOME="$ROOT/slow-home"
mkdir -p "$SLOW_HOME/.acfs/scripts/lib"
cat > "$SLOW_HOME/.acfs/scripts/lib/coexistence.sh" <<'EOF'
printf 'pass\tcoexist.firewall\tFirewall backend\tiptables: nf_tables\t\n'
sleep 10
printf 'pass\tcoexist.subnets\tSubnets\tno overlap\t\n'
EOF
OUT="$(
    doctor_binary_exists() { [[ "$1" == incus ]]; }
    doctor_runtime_home() { printf '%s\n' "$SLOW_HOME"; }
    check() { printf 'CHECK %s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}"; }
    # shellcheck source=/dev/null
    source "$doctor_fn"
    ACFS_DOCTOR_COEXISTENCE_TIMEOUT=1 check_coexistence
)"
check "doctor: a timed-out helper keeps the findings it printed" has "CHECK coexist.firewall|Firewall backend|pass|iptables: nf_tables"
check "doctor: ... never shows the ones it didn't reach" lacks "coexist.subnets"
check "doctor: ... and warns that the rest timed out" has "CHECK coexist|Container coexistence|warn|timed out after 1s"
# An override that isn't a positive whole number of seconds ('abc' made
# timeout exit 125 with nothing shown; 0 disabled the limit) falls back to 60.
FAST_HOME="$ROOT/fast-home"
mkdir -p "$FAST_HOME/.acfs/scripts/lib"
printf '%s\n' "printf 'pass\\tcoexist.firewall\\tFirewall backend\\tiptables: nf_tables\\t\\n'" \
    > "$FAST_HOME/.acfs/scripts/lib/coexistence.sh"
for bad in abc 0; do
    OUT="$(
        doctor_binary_exists() { [[ "$1" == incus ]]; }
        doctor_runtime_home() { printf '%s\n' "$FAST_HOME"; }
        check() { printf 'CHECK %s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}"; }
        # shellcheck source=/dev/null
        source "$doctor_fn"
        ACFS_DOCTOR_COEXISTENCE_TIMEOUT="$bad" check_coexistence
    )"
    check "doctor: a limit of '$bad' still runs the check" has "CHECK coexist.firewall|Firewall backend|pass|"
done
# The doctor discards the helper's stderr, so the timeout stub records the
# limit it was given in a file.
LIMIT_LOG="$ROOT/coexistence-limit.log"
(
    doctor_binary_exists() { [[ "$1" == incus ]]; }
    doctor_runtime_home() { printf '%s\n' "$FAST_HOME"; }
    check() { :; }
    timeout() { printf '%s\n' "$1" > "$LIMIT_LOG"; shift; "$@"; }
    # shellcheck source=/dev/null
    source "$doctor_fn"
    ACFS_DOCTOR_COEXISTENCE_TIMEOUT=0 check_coexistence
)
OUT="$(cat "$LIMIT_LOG" 2>/dev/null)"
check "doctor: a limit of 0 falls back to 60s instead of disabling it" test "$OUT" = 60

# ------------------------------------------------------------
printf '\nTests passed: %s\nTests failed: %s\n' "$TESTS_PASSED" "$TESTS_FAILED"
(( TESTS_FAILED == 0 ))
