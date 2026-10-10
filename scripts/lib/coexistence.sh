#!/usr/bin/env bash
# ============================================================
# ACFS coexistence: Incus next to the host's podman and Docker.
#
# The swarm container shares the host with podman deployments, and Docker
# may be opted in (acfs-ioo3.16, plan 4.4). Each stack owns firewall rules,
# bridges, subnets and subordinate id ranges; this checks they don't collide.
#
#   check     read-only; one line per finding, for the doctor:
#             <pass|warn|fail|skip>\t<id>\t<label>\t<details>\t<fix>
#     - the firewall backend (iptables nf_tables or legacy, nft, podman's
#       network backend, Docker);
#     - overlapping subnets among Incus networks, podman networks and the
#       host's routes, VPN and tailnet routes included;
#     - subordinate uid/gid ranges shared by two owners;
#     - Docker's FORWARD policy DROP, which cuts Incus bridges off unless
#       DOCKER-USER accepts them (Incus docs, "Prevent connectivity issues
#       with Incus and Docker"); reading it needs root, so this tries
#       sudo -n and skips without it.
#   traffic   flows from both stacks, run on request because they start
#             probes inside instances: DNS, outbound HTTPS, the host API and
#             SSH flows of plan 3.1, and a private destination that must be
#             refused; IPv4 and IPv6. --save and --compare record the result
#             before and after an authorized firewall or service restart.
#
# Usage:
#   coexistence.sh check
#   coexistence.sh traffic --instance [<remote>:]<name> [--api HOST:PORT]
#       [--ssh HOST:PORT] [--deny HOST:PORT] [--podman-image IMAGE]
#       [--dns NAME] [--https URL] [--save FILE] [--compare FILE]
#
# The podman image must already be local (no pull) and carry sh, getent and
# curl. IPv6 failures are warnings: many hosts have no IPv6 route.
# Tests only: ACFS_COEX_ROOT prefixes /etc, and ACFS_COEX_SYSTEM_BIN_PREFIX
# names a directory of stub tools (honoured only when owned by this user and
# not group- or world-writable); ACFS_COEX_SYSTEM_BIN_ONLY=1 looks nowhere else.
# ============================================================

set -euo pipefail

COEX_ROOT="${ACFS_COEX_ROOT:-}"
COEX_DNS_DEFAULT="cloudflare.com"
COEX_HTTPS_DEFAULT="https://cloudflare.com"

_coex_note() { printf '[coexistence] %s\n' "$*" >&2; }
_coex_die() { _coex_note "$*"; exit 2; }

# --- System tools, from fixed directories (as service_protection.sh does) ---

_coex_bin_prefix_trusted() {
    local dir="${ACFS_COEX_SYSTEM_BIN_PREFIX:-}" perms=""
    [[ -n "$dir" && "$dir" == /* && -d "$dir" && -O "$dir" ]] || return 1
    [[ -x /usr/bin/stat ]] || return 1
    perms="$(/usr/bin/stat -c '%a' "$dir" 2>/dev/null || true)"
    [[ "$perms" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$perms & 8#022) == 0 ))
}

_coex_bin() {
    local name="$1" dir=""
    local -a dirs=()
    if _coex_bin_prefix_trusted; then
        dirs+=("$ACFS_COEX_SYSTEM_BIN_PREFIX")
        # Tests only: a tool missing from the stubs counts as not installed.
        [[ "${ACFS_COEX_SYSTEM_BIN_ONLY:-0}" == 1 ]] || dirs+=(/usr/local/bin /usr/bin /bin /usr/sbin /sbin)
    else
        dirs+=(/usr/local/bin /usr/bin /bin /usr/sbin /sbin)
    fi
    for dir in "${dirs[@]}"; do
        if [[ -x "$dir/$name" && ! -d "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

# Run a tool by name with a time limit; stdin is closed so a tool inside a
# read loop can't eat the loop's input.
_coex_run() {
    local bin="" timeout_bin=""
    bin="$(_coex_bin "$1")" || return 127
    shift
    if timeout_bin="$(_coex_bin timeout)"; then
        "$timeout_bin" 20 "$bin" "$@" </dev/null
    else
        "$bin" "$@" </dev/null
    fi
}

# The same as root: directly when root, else sudo -n (never prompts).
_coex_run_root() {
    local bin=""
    bin="$(_coex_bin "$1")" || return 127
    shift
    if [[ "$(id -u)" == 0 ]]; then
        _coex_run "$(basename "$bin")" "$@"
    elif _coex_run sudo -n true >/dev/null 2>&1; then
        _coex_run sudo -n "$bin" "$@"
    else
        return 126
    fi
}

_coex_emit() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}"
}

# ============================================================
# check
# ============================================================

# Incus's managed networks: "<name>\t<cidr>" per address (IPv4 and IPv6).
_coex_incus_subnets() {
    local name="" v4="" v6="" cidr=""
    while IFS=, read -r name v4 v6; do
        [[ -n "$name" ]] || continue
        for cidr in $v4 $v6; do
            [[ "$cidr" == */* ]] && printf 'incus network %s\t%s\n' "$name" "$cidr"
        done
    done < <(_coex_run incus network list --format csv -c n46 2>/dev/null || true)
    return 0
}

# Incus's managed bridge names, one per line.
_coex_incus_bridges() {
    local name="" type="" managed=""
    while IFS=, read -r name type managed; do
        [[ "$type" == bridge && "${managed^^}" == YES ]] && printf '%s\n' "$name"
    done < <(_coex_run incus network list --format csv -c ntm 2>/dev/null || true)
    return 0
}

# Rootful podman's networks (as root, or through sudo -n): "<owner>\t<cidr>"
# per subnet, plus "iface\t<interface>" lines. Rootless networks live in the
# user's own network namespace and never meet the host's routes, so they are
# left out. Without root, a rootful bridge still shows up among the routes.
_coex_podman_subnets() {
    local name="" iface="" subnets="" cidr=""
    while read -r name; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        iface="$(_coex_run_root podman network inspect --format '{{.NetworkInterface}}' "$name" 2>/dev/null || true)"
        subnets="$(_coex_run_root podman network inspect --format '{{range .Subnets}}{{.Subnet}} {{end}}' "$name" 2>/dev/null || true)"
        [[ -z "$iface" ]] || printf 'iface\t%s\n' "$iface"
        for cidr in $subnets; do
            [[ "$cidr" == */* ]] && printf 'podman network %s\t%s\n' "$name" "$cidr"
        done
    done < <(_coex_run_root podman network ls --format '{{.Name}}' 2>/dev/null || true)
    return 0
}

# The host's routes in every table (VPN and tailnet ones included), except
# those on the bridges listed in $1 (one name per line), which duplicate
# the networks themselves, and the local, link-local and multicast ones.
_coex_route_subnets() {
    local skip_ifaces="$1" family="" dest="" dev="" line=""
    for family in -4 -6; do
        while read -r line; do
            read -r dest _ <<<"$line"
            [[ "$dest" == */* || "$dest" =~ ^[0-9a-fA-F.:]+$ ]] || continue
            dev="$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$line")"
            [[ -n "$dev" && "$dev" != lo ]] || continue
            if [[ -n "$skip_ifaces" ]] && grep -qxF -- "$dev" <<<"$skip_ifaces"; then
                continue
            fi
            if [[ "$dest" != */* && "$family" == -4 ]]; then
                dest+="/32"
            elif [[ "$dest" != */* ]]; then
                dest+="/128"
            fi
            printf 'route via %s\t%s\n' "$dev" "$dest"
        done < <(_coex_run ip "$family" -o route show table all 2>/dev/null \
            | grep -vE '^(local|broadcast|multicast|anycast|unreachable|prohibit|blackhole|throw|nat) ' || true)
    done
    return 0
}

# Pairs of overlapping networks with different owners, from "<owner>\t<cidr>"
# lines on stdin: "<owner a> <cidr a> overlaps <owner b> <cidr b>" per line.
_coex_overlaps() {
    local python=""
    python="$(_coex_bin python3)" || return 2
    "$python" -I -c '
import ipaddress, sys
nets = []
for line in sys.stdin:
    owner, _, cidr = line.rstrip("\n").partition("\t")
    try:
        net = ipaddress.ip_network(cidr.strip(), strict=False)
    except ValueError:
        continue
    if net.is_link_local or net.is_multicast or net.is_loopback or net.prefixlen == 0:
        continue
    if (owner, net) not in nets:
        nets.append((owner, net))
seen = set()
for i, (oa, na) in enumerate(nets):
    for ob, nb in nets[i + 1:]:
        if oa == ob or na.version != nb.version or not na.overlaps(nb):
            continue
        key = tuple(sorted([(oa, str(na)), (ob, str(nb))]))
        if key in seen:
            continue
        seen.add(key)
        print(f"{oa} {na} overlaps {ob} {nb}")
'
}

coex_check_firewall() {
    local iptables="" ipt_backend="absent" nft="absent" podman="absent" docker="absent"
    if iptables="$(_coex_run iptables -V 2>/dev/null)"; then
        case "$iptables" in
            *nf_tables*) ipt_backend="nf_tables" ;;
            *legacy*) ipt_backend="legacy" ;;
            *) ipt_backend="unknown" ;;
        esac
    fi
    _coex_bin nft >/dev/null && nft="present"
    if _coex_bin podman >/dev/null; then
        podman="$(_coex_run podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
        [[ "$podman" =~ ^[a-z]+$ ]] || podman="unknown"
    fi
    _coex_bin docker >/dev/null && docker="present"
    _coex_emit pass coexist.firewall "Firewall backend" \
        "iptables: $ipt_backend; nft: $nft; podman: $podman; docker: $docker"
}

coex_check_subnets() {
    local entries="" podman="" ifaces="" overlaps="" rc=0
    entries="$(_coex_incus_subnets)"
    podman="$(_coex_podman_subnets)"
    ifaces="$(_coex_incus_bridges; grep $'^iface\t' <<<"$podman" | cut -f2 || true)"
    entries+=$'\n'"$(grep -v $'^iface\t' <<<"$podman" || true)"
    entries+=$'\n'"$(_coex_route_subnets "$ifaces")"
    overlaps="$(grep -v '^$' <<<"$entries" | _coex_overlaps)" || rc=$?
    if (( rc == 2 )); then
        _coex_emit skip coexist.subnets "Subnet overlap" "python3 not found"
    elif [[ -n "$overlaps" ]]; then
        _coex_emit warn coexist.subnets "Subnet overlap" "$(paste -sd ';' <<<"$overlaps" | sed 's/;/; /g')" \
            "Move one side to a free range: incus network set <name> ipv4.address=<cidr>, or podman network create --subnet"
    else
        _coex_emit pass coexist.subnets "Subnet overlap" "Incus, podman and the host's routes use disjoint ranges"
    fi
}

# Owners whose ranges in $1 (an /etc/subuid-style file) overlap.
_coex_subid_overlaps() {
    local file="$1"
    [[ -r "$file" ]] || return 0
    awk -F: '
        NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 {
            n++; owner[n] = $1; start[n] = $2 + 0; end[n] = $2 + $3 - 1
        }
        END {
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
                if (owner[i] != owner[j] && start[i] <= end[j] && start[j] <= end[i])
                    printf "%s %d-%d and %s %d-%d\n", owner[i], start[i], end[i], owner[j], start[j], end[j]
        }' "$file"
}

coex_check_subids() {
    local kind="" found="" all=""
    for kind in subuid subgid; do
        found="$(_coex_subid_overlaps "$COEX_ROOT/etc/$kind")"
        [[ -z "$found" ]] || all+="${all:+; }/etc/$kind: $(paste -sd ';' <<<"$found" | sed 's/;/; /g')"
    done
    if [[ ! -r "$COEX_ROOT/etc/subuid" && ! -r "$COEX_ROOT/etc/subgid" ]]; then
        _coex_emit skip coexist.subids "Subordinate id ranges" "no /etc/subuid or /etc/subgid"
    elif [[ -n "$all" ]]; then
        _coex_emit warn coexist.subids "Subordinate id ranges" "shared ranges: $all" \
            "Give each owner its own range in /etc/subuid and /etc/subgid (usermod --add-subuids/--add-subgids), then restart the stack that moved"
    else
        _coex_emit pass coexist.subids "Subordinate id ranges" "every owner's range is its own"
    fi
}

# Docker's FORWARD DROP against Incus's bridges (acfs-31uo).
coex_check_docker_forward() {
    local bridges="" forward="" docker_user="" bridge="" missing="" fix="" rc=0
    _coex_bin docker >/dev/null || return 0
    _coex_bin incus >/dev/null || return 0
    if grep -qsE '"ip-forward-no-drop"[[:space:]]*:[[:space:]]*true' "$COEX_ROOT/etc/docker/daemon.json"; then
        _coex_emit pass coexist.docker_forward "Docker and Incus forwarding" "Docker's ip-forward-no-drop is set"
        return 0
    fi
    forward="$(_coex_run_root iptables -S FORWARD 2>/dev/null)" || rc=$?
    if (( rc == 126 )); then
        _coex_emit skip coexist.docker_forward "Docker and Incus forwarding" "reading FORWARD needs root" \
            "sudo iptables -S FORWARD; sudo iptables -S DOCKER-USER"
        return 0
    elif (( rc != 0 )); then
        _coex_emit skip coexist.docker_forward "Docker and Incus forwarding" "iptables -S FORWARD failed"
        return 0
    fi
    if ! grep -qx -- '-P FORWARD DROP' <<<"$forward"; then
        _coex_emit pass coexist.docker_forward "Docker and Incus forwarding" "FORWARD policy is not DROP"
        return 0
    fi
    docker_user="$(_coex_run_root iptables -S DOCKER-USER 2>/dev/null || true)"
    bridges="$(_coex_incus_bridges)"
    while read -r bridge; do
        [[ -n "$bridge" ]] || continue
        if ! grep -qE -- "^-A DOCKER-USER -i $bridge( |.* )-j ACCEPT$" <<<"$docker_user"; then
            missing+="${missing:+, }$bridge"
            fix+="${fix:+; }sudo iptables -I DOCKER-USER -i $bridge -j ACCEPT; sudo iptables -I DOCKER-USER -o $bridge -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        fi
    done <<<"$bridges"
    if [[ -n "$missing" ]]; then
        _coex_emit warn coexist.docker_forward "Docker and Incus forwarding" \
            "Docker set FORWARD to DROP, and DOCKER-USER doesn't accept $missing, so its instances have no network" \
            "Set \"ip-forward-no-drop\": true in /etc/docker/daemon.json and restart Docker, or (and make it persistent): $fix"
    else
        _coex_emit pass coexist.docker_forward "Docker and Incus forwarding" "DOCKER-USER accepts every Incus bridge"
    fi
}

coex_check() {
    coex_check_firewall
    coex_check_subnets
    coex_check_subids
    coex_check_docker_forward
}

# ============================================================
# traffic
# ============================================================

# Runs inside an instance or a podman container: $1 is the flow, the rest
# its arguments. Values arrive as argv, never pasted into the script.
read -r -d '' COEX_PROBE <<'EOF' || true
flow=$1; shift
case $flow in
    dns4) getent ahostsv4 "$1" >/dev/null ;;
    dns6) getent ahostsv6 "$1" | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ { f = 1 } END { exit !f }' ;;
    https4) curl -4 -sS -o /dev/null --max-time 10 "$1" ;;
    https6) curl -6 -sS -o /dev/null --max-time 10 "$1" ;;
    tcp) timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" ;;
    *) exit 64 ;;
esac
EOF

_coex_valid_hostport() {
    local re='^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):[0-9]{1,5}$'
    [[ "$1" =~ $re ]]
}

_coex_split_hostport() {
    local value="$1" host="" port=""
    port="${value##*:}"
    host="${value%:*}"
    host="${host#[}"; host="${host%]}"
    printf '%s %s\n' "$host" "$port"
}

# Result lines: <PASS|FAIL|WARN|SKIP> <stack>.<flow>: <detail>
_coex_flow() {
    local stack="$1" flow="$2" expect="$3" label="$4"
    shift 4
    local status="" ok=false
    "$@" </dev/null >/dev/null 2>&1 && ok=true
    if [[ "$expect" == refused ]]; then
        if [[ "$ok" == true ]]; then status=FAIL; label+=" (reached; it must be refused)"; else status=PASS; label+=" (refused)"; fi
    elif [[ "$ok" == true ]]; then
        status=PASS
    elif [[ "$flow" == *6 ]]; then
        status=WARN; label+=" (failed; no IPv6 route?)"
    else
        status=FAIL; label+=" (failed)"
    fi
    printf '%s %s.%s: %s\n' "$status" "$stack" "$flow" "$label"
}

coex_traffic() {
    local instance="" api="" ssh="" deny="" image="" dns="$COEX_DNS_DEFAULT" https="$COEX_HTTPS_DEFAULT"
    local save="" compare="" results="" host="" port="" stack="" incus_bin="" podman_bin=""
    local -a run=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --instance|--api|--ssh|--deny|--podman-image|--dns|--https|--save|--compare)
                [[ $# -ge 2 ]] || _coex_die "$1 needs a value"
                case "$1" in
                    --instance) instance="$2" ;; --api) api="$2" ;; --ssh) ssh="$2" ;;
                    --deny) deny="$2" ;; --podman-image) image="$2" ;; --dns) dns="$2" ;;
                    --https) https="$2" ;; --save) save="$2" ;; --compare) compare="$2" ;;
                esac
                shift 2 ;;
            *) _coex_die "unknown traffic option: $1" ;;
        esac
    done
    [[ -n "$instance" || -n "$image" ]] || _coex_die "traffic needs --instance and/or --podman-image"
    [[ -z "$instance" || "$instance" =~ ^([A-Za-z0-9._-]+:)?[A-Za-z0-9-]+$ ]] || _coex_die "invalid instance: $instance"
    [[ -z "$image" || "$image" =~ ^[A-Za-z0-9./:@_-]+$ ]] || _coex_die "invalid image: $image"
    [[ "$dns" =~ ^[A-Za-z0-9.-]+$ ]] || _coex_die "invalid DNS name: $dns"
    local url_re='^https://[A-Za-z0-9./:_~%?=&-]+$'
    [[ "$https" =~ $url_re ]] || _coex_die "invalid HTTPS URL: $https"
    for host in "$api" "$ssh" "$deny"; do
        [[ -z "$host" ]] || _coex_valid_hostport "$host" || _coex_die "invalid HOST:PORT: $host"
    done
    [[ -z "$compare" || -r "$compare" ]] || _coex_die "cannot read $compare"

    for stack in incus podman; do
        if [[ "$stack" == incus ]]; then
            [[ -n "$instance" ]] || { results+="SKIP incus: no --instance"$'\n'; continue; }
            incus_bin="$(_coex_bin incus)" || { results+="SKIP incus: incus not installed"$'\n'; continue; }
            run=("$incus_bin" exec "$instance" -- sh -c "$COEX_PROBE" probe)
        else
            [[ -n "$image" ]] || { results+="SKIP podman: no --podman-image"$'\n'; continue; }
            podman_bin="$(_coex_bin podman)" || { results+="SKIP podman: podman not installed"$'\n'; continue; }
            run=("$podman_bin" run --rm --pull=never "$image" sh -c "$COEX_PROBE" probe)
        fi
        results+="$(_coex_flow "$stack" dns4 ok "DNS $dns (IPv4)" "${run[@]}" dns4 "$dns")"$'\n'
        results+="$(_coex_flow "$stack" dns6 ok "DNS $dns (IPv6)" "${run[@]}" dns6 "$dns")"$'\n'
        results+="$(_coex_flow "$stack" https4 ok "HTTPS $https (IPv4)" "${run[@]}" https4 "$https")"$'\n'
        results+="$(_coex_flow "$stack" https6 ok "HTTPS $https (IPv6)" "${run[@]}" https6 "$https")"$'\n'
        # The host API, SSH and the refused destination are the swarm
        # container's ACL flows (plan 3.1); podman's containers have none.
        [[ "$stack" == incus ]] || continue
        if [[ -n "$api" ]]; then
            read -r host port <<<"$(_coex_split_hostport "$api")"
            results+="$(_coex_flow "$stack" api ok "Incus API $api" "${run[@]}" tcp "$host" "$port")"$'\n'
        fi
        if [[ -n "$ssh" ]]; then
            read -r host port <<<"$(_coex_split_hostport "$ssh")"
            results+="$(_coex_flow "$stack" ssh ok "SSH $ssh" "${run[@]}" tcp "$host" "$port")"$'\n'
        fi
        if [[ -n "$deny" ]]; then
            read -r host port <<<"$(_coex_split_hostport "$deny")"
            results+="$(_coex_flow "$stack" deny refused "private destination $deny" "${run[@]}" tcp "$host" "$port")"$'\n'
        fi
    done

    printf '%s' "$results"
    if [[ -n "$save" ]]; then
        printf '%s' "$results" > "$save" || _coex_die "cannot write $save"
        _coex_note "saved to $save"
    fi
    if [[ -n "$compare" ]]; then
        _coex_compare "$compare" "$results" || return 1
    fi
    ! grep -q '^FAIL ' <<<"$results"
}

# Changes since a saved run; returns 1 when a flow that passed no longer does.
_coex_compare() {
    local before_file="$1" after="$2" key="" was="" now="" regressed=false
    while read -r now key _; do
        [[ "$key" == *: ]] || continue
        was="$(awk -v k="$key" '$2 == k { print $1; exit }' "$before_file")"
        [[ -n "$was" && "$was" != "$now" ]] || continue
        printf 'CHANGED %s %s -> %s\n' "${key%:}" "$was" "$now"
        [[ "$was" != PASS ]] || regressed=true
    done <<<"$after"
    [[ "$regressed" == false ]]
}

# ============================================================

coex_main() {
    local cmd="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$cmd" in
        check) coex_check "$@" ;;
        traffic) coex_traffic "$@" ;;
        -h|--help|help) sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *) _coex_die "usage: coexistence.sh check | traffic --instance [<remote>:]<name> [--api HOST:PORT] [--ssh HOST:PORT] [--deny HOST:PORT] [--podman-image IMAGE] [--dns NAME] [--https URL] [--save FILE] [--compare FILE]" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    coex_main "$@"
fi
