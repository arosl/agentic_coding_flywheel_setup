#!/usr/bin/env bash
# ============================================================
# acfs state: the persistent state layer (acfs-ioo3.3, plan 4.7)
#
# A swarm machine keeps its logins and sessions on one custom volume,
# acfs-state-<name>, which the launcher mounts by sub-path:
#   home/            -> /home/ubuntu, whole
#   root/ssh-host/   -> /etc/ssh/acfs-host-keys (HostKey drop-in)
#   root/tailscale/  -> /var/lib/tailscale
#   .acfs/           -> /etc/acfs/state (lease, lock, journal)
# On a VPS the same paths are plain directories and the same commands
# apply. ROWS below is the export manifest: which paths are logins and
# sessions (exported by default), which are cache (--with-cache), and
# which are root rows, with each row's mode policy.
#
# Subcommands:
#   export <name> [<file>]   lock, quiesce every writer (or refuse),
#                            snapshot the volume when asked, stream
#                            tar | age to a 0600 file, publish atomically
#   import <name> <file>     validate, stage on the volume, translate
#                            owners per row, swap in (journalled,
#                            resumable), write the lease
#   repair                   fix modes and owners per row
#   doctor [--json]          read-only report for acfs doctor
#   lease new|check|status|reclaim
#   setup-guest              install the lease unit and the sshd
#                            HostKey drop-in (the installer runs it)
#   manifest [--json]        print the rows
#
# Nothing here prints file contents, so no secret reaches the output.
# ============================================================

set -euo pipefail

STATE_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
STATE_SCHEMA=1

# --- Paths (overridable, so the tests run against a fixture) --------

state_default_user() {
    if [[ -n "${ACFS_STATE_USER:-}" ]]; then
        printf '%s\n' "$ACFS_STATE_USER"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    elif [[ "$(id -u)" -ne 0 ]]; then
        id -un
    else
        printf 'ubuntu\n'
    fi
}

STATE_USER="$(state_default_user)"
STATE_HOME="${ACFS_STATE_HOME:-/home/$STATE_USER}"
STATE_META="${ACFS_STATE_META:-/etc/acfs/state}"
STATE_SSH_DIR="${ACFS_STATE_SSH_DIR:-/etc/ssh/acfs-host-keys}"
STATE_TS_DIR="${ACFS_STATE_TS_DIR:-/var/lib/tailscale}"
STATE_ETC_SSH="${ACFS_STATE_ETC_SSH:-/etc/ssh}"
STATE_SSHD_DROPIN="${ACFS_STATE_SSHD_DROPIN:-$STATE_ETC_SSH/sshd_config.d/10-acfs-host-keys.conf}"
STATE_GUEST_SOCK="${ACFS_STATE_GUEST_SOCK:-/dev/incus/sock}"
STATE_SYSTEMD_DIR="${ACFS_STATE_SYSTEMD_DIR:-/etc/systemd/system}"
STATE_LIBEXEC="${ACFS_STATE_LIBEXEC:-/usr/local/lib/acfs/state_layer.sh}"
STATE_OUT_DIR="${ACFS_STATE_OUT_DIR:-$STATE_HOME/acfs-state}"
STATE_LEASE_UNIT="acfs-state-lease.service"

# Processes that write login or session state. Export and import
# refuse while one of them still runs as the user after the quiesce.
STATE_WRITERS=(claude codex agy gemini pi herdr am mcp-agent-mail cass cm atuin)

# --- The export manifest (plan 4.7.1) -------------------------------
# id|class|base|path|policy|markers
#   class:   login (exported by default), cache (--with-cache), root
#   base:    home, ssh-host or tailscale; path is relative to it, and
#            empty for a whole root row
#   policy:  private: no group or other access, except *.pub at 0644
#            (hooks keep their execute bits); asis: left as it is
#   markers: comma-separated files that mean "a login is here"
ROWS=(
    "claude-json|login|home|.claude.json|private|.claude.json"
    "claude|login|home|.claude|private|.claude/.credentials.json"
    "anthropic|login|home|.config/anthropic|private|"
    "codex|login|home|.codex|private|.codex/auth.json"
    "gemini|login|home|.gemini|private|.gemini/oauth_creds.json,.gemini/antigravity-cli/antigravity-oauth-token"
    "pi|login|home|.pi|private|.pi/agent/auth.json"
    "gh|login|home|.config/gh|private|.config/gh/hosts.yml"
    "agent-mail-repo|login|home|.mcp_agent_mail_git_mailbox_repo|private|"
    "agent-mail-config|login|home|.config/mcp-agent-mail|private|.config/mcp-agent-mail/config.env"
    "herdr|login|home|.config/herdr|private|"
    "incus-client|login|home|.config/incus|private|.config/incus/client.key"
    "ssh-user|login|home|.ssh|private|"
    "atuin|login|home|.local/share/atuin|private|"
    "cass-memory|login|home|.cass-memory|private|"
    "oracle|login|home|.oracle|private|"
    "omp|login|home|.omp|private|"
    "supabase|login|home|.supabase|private|"
    "grok|login|home|.grok|private|"
    "cursor|login|home|.cursor|private|"
    "systemd-user|login|home|.config/systemd/user|asis|"
    "dotfiles|login|home|dotfiles|asis|"
    "gitconfig|login|home|.gitconfig|asis|"
    "zshenv|login|home|.zshenv|asis|"
    "zshrc|login|home|.zshrc|asis|"
    "zprofile|login|home|.zprofile|asis|"
    "bashrc|login|home|.bashrc|asis|"
    "profile|login|home|.profile|asis|"
    "cass|cache|home|.local/share/coding-agent-search|private|"
    "ssh-host|root|ssh-host||private|"
    "tailscale|root|tailscale||private|"
)

# Home entries that are toolchains, caches or shell litter, not state a
# rebuild would lose: never reported as unknown.
STATE_KNOWN_NONSTATE=(
    .acfs .bun .cache .cargo .rustup .npm .nvm .go .local .config .oh-my-zsh
    .bash_history .bash_logout .zsh_history .zcompdump .lesshst .wget-hsts
    .viminfo .python_history .node_repl_history .sudo_as_admin_successful
    .vscode-server .docker .duckdb .p10k.zsh .tmux.conf .zshrc.local
    .bashrc.d .acfs-import-
    .config/btop .config/htop .config/nvim .config/fish .config/lsd .config/bat
    .config/direnv .config/atuin .config/zsh .config/uv .config/go
    .local/share/nvim .local/share/zsh .local/share/zoxide .local/share/man
    .local/share/applications .local/share/fonts .local/share/bash-completion
    .local/share/direnv .local/share/uv .local/share/mise .local/share/pnpm
)

# --- Helpers ---------------------------------------------------------

state_err() { printf 'acfs state: %s\n' "$*" >&2; }
state_info() { printf '%s\n' "$*" >&2; }
state_die() { state_err "$*"; exit 1; }
state_usage_die() { state_err "$*"; echo "Run 'acfs state --help' for usage." >&2; exit 2; }

state_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

state_usage() {
    cat <<'USAGE'
Usage: acfs state <command> [options]

The persistent state layer: logins and sessions on the machine's state
volume, and moving them between machines.

Commands:
  export <name> [<file>]  Export logins and sessions to an age-encrypted
                          archive (default ~/acfs-state/<name>-<UTC>.tar.age)
      --recipient R       age recipient public key (repeatable; one of
                          these two is required)
      --recipients-file F age recipients file
      --with-cache        also export cache rows (cass's index)
      --move              a move, not a backup: this machine gives up the
                          login, stays quiesced and is fenced
      --snapshot-pool P   on Incus, snapshot acfs-state-<name> in pool P
                          first (through the user's incus remote)
      --snapshot-remote R the incus remote for --snapshot-pool (default host)
      --dry-run           list what would be exported; change nothing
  import <name> <file>    Import an archive into this machine
      --identity F        age identity file (otherwise age asks on the tty)
      --replace           replace a login this machine already holds
      --resume            finish an interrupted import
      --dry-run           validate the archive; change nothing
  repair [--dry-run]      Fix modes and owners per row
  doctor [--json]         Read-only report (acfs doctor runs it)
  lease new               Print a new lease token
  lease check             Compare the volume's lease with the instance's
                          (the lease unit runs it at boot)
  lease status            Show the lease state
  lease reclaim           Make this instance hold the volume's lease again
                          (after a --move export you take back)
  setup-guest             Install the lease unit and the sshd HostKey
                          drop-in (the installer runs it in a container)
  manifest [--json]       Print the export manifest's rows

export, import, repair, lease check/reclaim and setup-guest need root;
run them with sudo.
USAGE
}

state_require_root() {
    [[ "${ACFS_STATE_ALLOW_NONROOT:-}" == "1" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] && return 0
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- env ACFS_STATE_USER="$STATE_USER" bash "$STATE_SCRIPT" "$@"
    fi
    state_die "this command needs root; run it with sudo"
}

state_has_arg() {
    local want="$1" arg
    shift
    for arg in "$@"; do
        [[ "$arg" == "$want" ]] && return 0
    done
    return 1
}

state_need() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || state_die "$cmd is required and not installed"
    done
}

state_uid() { id -u "$STATE_USER"; }
state_gid() { id -g "$STATE_USER"; }

# The directory a row's base names.
state_base_dir() {
    case "$1" in
        home) printf '%s\n' "$STATE_HOME" ;;
        ssh-host) printf '%s\n' "$STATE_SSH_DIR" ;;
        tailscale) printf '%s\n' "$STATE_TS_DIR" ;;
        *) return 1 ;;
    esac
}

# The archive prefix of a base.
state_base_arc() {
    case "$1" in
        home) printf 'home\n' ;;
        ssh-host) printf 'root/ssh-host\n' ;;
        tailscale) printf 'root/tailscale\n' ;;
        *) return 1 ;;
    esac
}

state_row_target() {
    local base="$1" path="$2" dir
    dir="$(state_base_dir "$base")"
    if [[ -n "$path" ]]; then printf '%s/%s\n' "$dir" "$path"; else printf '%s\n' "$dir"; fi
}

state_in_container() {
    local virt=""
    virt="$(systemd-detect-virt -c 2>/dev/null || true)"
    [[ -n "$virt" && "$virt" != "none" ]]
}

# --- The python helper: tar create, validate and extract -------------
# Python's tarfile streams through a pipe, so the archive never exists
# in plaintext on disk; members are checked by name, type and link
# target before anything is written, and every file's sha256 is checked
# against manifest.json, which is the archive's last member.

STATE_PY=$(cat <<'PY'
import hashlib, io, json, os, posixpath, stat, sys, tarfile

PREFIXES = ("home", "root/ssh-host", "root/tailscale")
ARC = {"home": "home", "ssh-host": "root/ssh-host", "tailscale": "root/tailscale"}
# Where each archive prefix lands on this machine.
BASES = json.loads(os.environ.get("ACFS_STATE_BASES", "{}"))
# This machine's own rows: an archive's rows are trusted only where they
# name one of these by id with the same base and path.
LOCAL_ROWS = {r["id"]: r for r in json.loads(os.environ.get("ACFS_STATE_ROWS", "[]"))}

class Refuse(Exception):
    pass

def under(name, prefix):
    return name == prefix or name.startswith(prefix + "/")

def path_under(path, base):
    t = posixpath.normpath(path)
    return t == base or t.startswith(base.rstrip("/") + "/")

def link_escapes(arcname, target, row_arc, base_dir):
    if target.startswith("/"):
        return not path_under(target, base_dir)
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(arcname), target))
    return not under(resolved, row_arc)

def trusted_rows(manifest):
    rows, seen = [], set()
    for r in manifest.get("rows", []):
        rid = r.get("id")
        local = LOCAL_ROWS.get(rid)
        if local is None:
            raise Refuse("row %r is not in this machine's manifest" % rid)
        if r.get("base") != local["base"] or r.get("path") != local["path"]:
            raise Refuse("row %r names a different path than this machine's" % rid)
        if rid in seen:
            raise Refuse("row %r appears twice" % rid)
        seen.add(rid)
        row = {k: local[k] for k in ("id", "class", "base", "path", "policy", "markers")}
        row["present"] = bool(r.get("present"))
        rows.append(row)
    return rows

def source_base(manifest, prefix):
    base = (manifest.get("source") or {}).get("bases", {}).get(prefix)
    if not isinstance(base, str) or not base.startswith("/"):
        raise Refuse("manifest.json has no source path for %s" % prefix)
    return base

def create(spec_path, manifest_out):
    spec = json.load(open(spec_path))
    out = tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT)
    files, skipped = [], []
    for row in spec["rows"]:
        base_dir, rel, arc = row["base_dir"], row["path"], row["arc"]
        top = os.path.join(base_dir, rel) if rel else base_dir
        row["present"] = os.path.lexists(top)
        if not row["present"]:
            continue
        # Parents before children; os.walk lists a symlinked directory
        # among dirs without descending into it.
        paths = [top]
        if os.path.isdir(top) and not os.path.islink(top):
            for d, dirs, names in os.walk(top):
                if d == top and not rel:
                    dirs[:] = [x for x in dirs if not x.startswith(".acfs-import-")]
                    names = [x for x in names if not x.startswith(".acfs-import-")]
                dirs.sort()
                paths.extend(os.path.join(d, n) for n in dirs + sorted(names))
        for p in paths:
            relp = os.path.relpath(p, base_dir)
            name = arc if relp == "." else arc + "/" + relp
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                if link_escapes(name, os.readlink(p), arc, base_dir):
                    skipped.append({"path": name, "why": "symlink leaves its row"})
                    continue
            elif not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
                skipped.append({"path": name, "why": "not a file, directory or symlink"})
                continue
            ti = out.gettarinfo(p, arcname=name)
            ti.uname = ti.gname = ""
            if ti.isreg():
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    class R:
                        def read(self, n=-1):
                            b = f.read(n)
                            h.update(b)
                            return b
                    out.addfile(ti, R())
                files.append({"path": name, "sha256": h.hexdigest(), "size": ti.size,
                              "mode": "%04o" % (ti.mode & 0o7777)})
            else:
                out.addfile(ti)
    manifest = dict(spec["meta"])
    manifest.setdefault("source", {})["bases"] = {r["arc"]: r["base_dir"] for r in spec["rows"]}
    manifest["rows"] = [{k: r[k] for k in ("id", "class", "base", "path", "policy", "markers", "present")}
                        for r in spec["rows"]]
    manifest["files"] = files
    manifest["skipped"] = skipped
    data = json.dumps(manifest, indent=1, sort_keys=True).encode()
    ti = tarfile.TarInfo("manifest.json")
    ti.size, ti.mode = len(data), 0o600
    out.addfile(ti, io.BytesIO(data))
    out.close()
    with open(manifest_out, "w") as f:
        json.dump({"skipped": skipped, "files": len(files),
                   "rows": [r["id"] for r in spec["rows"] if r["present"]]}, f)

def check_abs_links(manifest, abs_links):
    for name, target, arcroot in abs_links:
        if not path_under(target, source_base(manifest, arcroot)):
            raise Refuse("symlink leaves its row: %r" % name)

def rebase(manifest, target, arcroot):
    # An absolute link into the source's home points into this one's.
    src = source_base(manifest, arcroot).rstrip("/")
    t = posixpath.normpath(target)
    return BASES[arcroot].rstrip("/") + t[len(src):]

def check_member(m, seen, links, abs_links):
    name = m.name
    if name == "manifest.json":
        if not m.isreg():
            raise Refuse("manifest.json is not a file")
        return
    if not name or name.startswith("/") or "\\" in name or "\0" in name:
        raise Refuse("member has an absolute or odd name: %r" % name)
    if posixpath.normpath(name) != name or ".." in name.split("/"):
        raise Refuse("member name is not normalized: %r" % name)
    if not any(under(name, p) for p in PREFIXES):
        raise Refuse("member outside home/ and root/: %r" % name)
    if name in seen:
        raise Refuse("member appears twice: %r" % name)
    parent = posixpath.dirname(name)
    while parent:
        if parent in links:
            raise Refuse("member under a symlink member: %r" % name)
        parent = posixpath.dirname(parent)
    if m.issym():
        arcroot = next(p for p in PREFIXES if under(name, p))
        if m.linkname.startswith("/"):
            # Checked against the source's own paths, which manifest.json
            # (the last member) records.
            abs_links.append((name, m.linkname, arcroot))
        elif link_escapes(name, m.linkname, arcroot, ""):
            raise Refuse("symlink leaves its row: %r" % name)
        links.add(name)
    elif m.islnk():
        if seen.get(m.linkname) != "reg":
            raise Refuse("hardlink to a member that is not an earlier file: %r" % name)
    elif not (m.isreg() or m.isdir()):
        raise Refuse("member is not a file, directory or link: %r" % name)
    seen[name] = "reg" if m.isreg() else "other"

def rows_cover(rows, name):
    for r in rows:
        if not r["present"]:
            continue
        root = ARC[r["base"]] + ("/" + r["path"] if r["path"] else "")
        if under(name, root):
            return True
    return False

def verify(manifest_out):
    tf = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
    seen, links, abs_links, hashes, manifest, after = {}, set(), [], {}, None, False
    for m in tf:
        if after:
            raise Refuse("member after manifest.json: %r" % m.name)
        check_member(m, seen, links, abs_links)
        if m.name == "manifest.json":
            manifest = json.load(tf.extractfile(m))
            after = True
            continue
        if m.isreg():
            h = hashlib.sha256()
            f = tf.extractfile(m)
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
            hashes[m.name] = h.hexdigest()
    if manifest is None:
        raise Refuse("no manifest.json")
    if manifest.get("schema") != 1:
        raise Refuse("unknown manifest schema %r" % manifest.get("schema"))
    manifest["rows"] = trusted_rows(manifest)
    for name in seen:
        if not rows_cover(manifest["rows"], name):
            raise Refuse("member not under a manifest row: %r" % name)
    check_abs_links(manifest, abs_links)
    listed = {f["path"]: f["sha256"] for f in manifest.get("files", [])}
    if listed != hashes:
        bad = sorted(set(listed) ^ set(hashes)) or sorted(k for k in listed if listed[k] != hashes.get(k))
        raise Refuse("archive files do not match manifest.json (%d differ, first %r)" % (len(bad), bad[0]))
    with open(manifest_out, "w") as f:
        json.dump(manifest, f)

def extract(dest, manifest_path):
    manifest = json.load(open(manifest_path))
    listed = {f["path"]: f["sha256"] for f in manifest.get("files", [])}
    tf = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
    seen, links, dirs = {}, set(), []
    for m in tf:
        abs_links = []
        check_member(m, seen, links, abs_links)
        check_abs_links(manifest, abs_links)
        if m.name == "manifest.json":
            continue
        if not rows_cover(manifest["rows"], m.name):
            raise Refuse("member not under a manifest row: %r" % m.name)
        path = os.path.join(dest, m.name)
        parent = os.path.dirname(path)
        p = parent
        while p != dest and p.startswith(dest + "/"):
            if os.path.islink(p):
                raise Refuse("staging path crosses a symlink: %r" % m.name)
            p = os.path.dirname(p)
        os.makedirs(parent, mode=0o700, exist_ok=True)
        mode = m.mode & 0o777
        if m.isdir():
            os.makedirs(path, mode=0o700, exist_ok=True)
            dirs.append((path, mode, m.mtime))
        elif m.issym():
            target = m.linkname
            if target.startswith("/"):
                target = rebase(manifest, target, next(p for p in PREFIXES if under(m.name, p)))
            os.symlink(target, path)
        elif m.islnk():
            os.link(os.path.join(dest, m.linkname), path, follow_symlinks=False)
        else:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            h = hashlib.sha256()
            src = tf.extractfile(m)
            with os.fdopen(fd, "wb") as f:
                for b in iter(lambda: src.read(1 << 20), b""):
                    h.update(b)
                    f.write(b)
                os.fchmod(f.fileno(), mode)
            if listed.get(m.name) != h.hexdigest():
                raise Refuse("file changed between the two reads: %r" % m.name)
            os.utime(path, (m.mtime, m.mtime))
    for path, mode, mtime in sorted(dirs, key=lambda d: -d[0].count("/")):
        os.chmod(path, mode)
        os.utime(path, (mtime, mtime))

def drain():
    # Read to the end, so age never fails on a closed pipe.
    while sys.stdin.buffer.read(1 << 20):
        pass

try:
    cmd = sys.argv[1]
    if cmd == "create":
        create(sys.argv[2], sys.argv[3])
    elif cmd == "verify":
        verify(sys.argv[2])
        drain()
    elif cmd == "extract":
        extract(sys.argv[2], sys.argv[3])
        drain()
    else:
        raise Refuse("unknown helper command %r" % cmd)
except Refuse as e:
    print("acfs state: refused: %s" % e, file=sys.stderr)
    sys.exit(3)
except (tarfile.TarError, OSError, ValueError, KeyError) as e:
    print("acfs state: archive error: %s" % e, file=sys.stderr)
    sys.exit(4)
PY
)

state_py() {
    ACFS_STATE_BASES="$(jq -cn --arg h "$STATE_HOME" --arg s "$STATE_SSH_DIR" --arg t "$STATE_TS_DIR" \
        '{"home": $h, "root/ssh-host": $s, "root/tailscale": $t}')" \
        ACFS_STATE_ROWS="$(state_rows_json true)" \
        python3 -I -c "$STATE_PY" "$@"
}

# --- Modes -----------------------------------------------------------

# Print the paths under a private row that have group or other access
# (a *.pub file may be 0644), one per line, as "<mode> <path>".
state_mode_problems() {
    local target="$1"
    [[ -e "$target" || -L "$target" ]] || return 0
    find "$target" \( -type f -o -type d \) \
        \( \( -name '*.pub' -type f -perm /0133 \) -o \( ! \( -name '*.pub' -type f \) -perm /0077 \) \) \
        -printf '%m %p\n' 2>/dev/null || true
}

state_owner_problems() {
    local target="$1" uid="$2"
    [[ -e "$target" || -L "$target" ]] || return 0
    find "$target" ! -uid "$uid" -printf '%U %p\n' 2>/dev/null || true
}

state_fix_modes() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    find "$target" -type d -exec chmod go-rwx {} +
    find "$target" -type f ! -name '*.pub' -exec chmod go-rwx {} +
    find "$target" -type f -name '*.pub' -exec chmod u+rw,go-wx,go+r {} +
}

state_owner_for_base() {
    if [[ "$1" == "home" ]]; then
        printf '%s:%s\n' "$(state_uid)" "$(state_gid)"
    else
        printf '0:0\n'
    fi
}

# --- Lock and quiesce ------------------------------------------------

STATE_LOCK_FD=""
state_lock() {
    mkdir -p "$STATE_META"
    chmod 0700 "$STATE_META"
    exec {STATE_LOCK_FD}>>"$STATE_META/lock"
    flock -n "$STATE_LOCK_FD" || state_die "another acfs state export or import holds $STATE_META/lock"
}

STATE_STOPPED=()
STATE_KEEP_STOPPED=false

state_writer_units() {
    printf 'user@%s.service\n' "$(state_uid)"
    printf 'tailscaled.service\n'
}

state_restart_writers() {
    local unit
    [[ "$STATE_KEEP_STOPPED" == "true" ]] && return 0
    for unit in "${STATE_STOPPED[@]}"; do
        systemctl start "$unit" >/dev/null 2>&1 || state_err "could not restart $unit; start it with: sudo systemctl start $unit"
    done
    STATE_STOPPED=()
}

state_running_writers() {
    local name pids alt
    for name in "${STATE_WRITERS[@]}"; do
        pids="$(pgrep -u "$STATE_USER" -x "$name" 2>/dev/null | tr '\n' ' ' || true)"
        [[ -n "${pids// /}" ]] && printf '%s (pid %s)\n' "$name" "${pids% }"
    done
    # Tools that run under an interpreter carry its name (node, bun).
    alt="$(IFS='|'; echo "${STATE_WRITERS[*]}")"
    pids="$(pgrep -u "$STATE_USER" -f -- "^[^ ]*(node|bun|deno|python3?)( -[^ ]*)* [^ ]*/($alt)( |\$)" 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "${pids// /}" ]] && printf 'a writer under an interpreter (pid %s)\n' "${pids% }"
    return 0
}

# The address an SSH client connected from, from this process's
# environment or its nearest ancestor's (sudo drops SSH_CONNECTION).
state_ssh_client() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        printf '%s\n' "${SSH_CONNECTION%% *}"
        return 0
    fi
    local pid="$PPID" i conn
    for ((i = 0; i < 20; i++)); do
        [[ "$pid" -gt 1 && -r "/proc/$pid/environ" ]] || return 0
        conn="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -1)"
        if [[ -n "$conn" ]]; then
            printf '%s\n' "${conn%% *}"
            return 0
        fi
        pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
    done
}

state_is_tailscale_addr() {
    local ip="$1" a b
    if [[ "$ip" == *:* ]]; then
        [[ "${ip,,}" == fd7a:115c:a1e0:* ]]
        return
    fi
    IFS=. read -r a b _ _ <<<"$ip"
    [[ "$a" == 100 && "$b" =~ ^[0-9]+$ && "$b" -ge 64 && "$b" -le 127 ]]
}

# Refuse before stopping anything when the stop would kill this command
# or cut the session it runs in.
state_quiesce_preflight() {
    local cgroup_file="${ACFS_STATE_PROC_SELF_CGROUP:-/proc/self/cgroup}" client
    if grep -q "/user@$(state_uid)\.service/" "$cgroup_file" 2>/dev/null; then
        state_die "this runs inside $STATE_USER's user manager (a herdr pane or a user unit), which the quiesce stops. Run it from outside: 'incus exec <name> -- sudo acfs state ...' on the host, or a plain SSH login"
    fi
    client="$(state_ssh_client)"
    if [[ -n "$client" ]] && state_is_tailscale_addr "$client" \
        && systemctl is-active --quiet tailscaled.service 2>/dev/null; then
        state_die "this SSH session comes over Tailscale, which the quiesce stops. Run it over another path: 'incus exec <name> -- sudo acfs state ...' on the host"
    fi
}

# Stop every registered writer, or refuse and restart what was stopped.
state_quiesce() {
    local unit running
    state_quiesce_preflight
    while IFS= read -r unit; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            state_info "Stopping $unit"
            systemctl stop "$unit" || { state_restart_writers; state_die "could not stop $unit"; }
            STATE_STOPPED+=("$unit")
        fi
    done < <(state_writer_units)
    running="$(state_running_writers)"
    if [[ -n "$running" ]]; then
        state_restart_writers
        state_err "writers still run as $STATE_USER, so the copy would not be consistent:"
        printf '  %s\n' "$running" >&2
        state_die "stop them (or close their sessions) and run this again; there is no --force"
    fi
}

# --- Lease -----------------------------------------------------------

state_lease_new() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    echo
}

# The instance's user.acfs.lease from the guest API: prints it and
# returns 0, prints nothing and returns 0 when the key is unset (404) or
# there is no guest API, and returns 2 when the guest API doesn't answer
# after the retries (at boot the socket can be slow to come up).
state_lease_instance() {
    [[ -S "$STATE_GUEST_SOCK" ]] || return 0
    local tries="${ACFS_STATE_GUEST_RETRIES:-15}" delay="${ACFS_STATE_GUEST_DELAY:-2}" i out code
    for ((i = 1; i <= tries; i++)); do
        out="$(curl -sS --max-time 5 --unix-socket "$STATE_GUEST_SOCK" -w '\n%{http_code}' \
            http://custom.socket/1.0/config/user.acfs.lease 2>/dev/null || true)"
        code="${out##*$'\n'}"
        case "$code" in
            200) printf '%s' "${out%$'\n'*}" | tr -d '[:space:]'; return 0 ;;
            404) return 0 ;;
        esac
        [[ "$i" -lt "$tries" ]] && sleep "$delay"
    done
    state_err "lease: the guest API at $STATE_GUEST_SOCK did not answer (last status '${code:-none}')"
    return 2
}

# The instance's lease, or die: a container must not write a lease the
# next boot's check would refuse.
state_lease_instance_required() {
    local inst rc=0
    inst="$(state_lease_instance)" || rc=$?
    [[ "$rc" -eq 0 ]] || state_die "cannot read this instance's user.acfs.lease, so the lease is left as it is"
    if [[ -S "$STATE_GUEST_SOCK" && -z "$inst" ]]; then
        state_die "this instance has no user.acfs.lease; set one on the host (incus config set <name> user.acfs.lease <token>) or relaunch it with the launcher"
    fi
    if [[ -z "$inst" ]]; then
        inst="vps:$(state_lease_new)"
    fi
    printf '%s\n' "$inst"
}

state_lease_volume() {
    [[ -f "$STATE_META/lease" ]] || return 0
    tr -d '[:space:]' <"$STATE_META/lease"
}

state_write_lease() {
    local value="$1" tmp
    mkdir -p "$STATE_META"
    chmod 0700 "$STATE_META"
    tmp="$(mktemp "$STATE_META/.lease.XXXXXX")"
    printf '%s\n' "$value" >"$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_META/lease"
}

# Exit 0 when this instance may run the user manager, 1 when not.
state_lease_check() {
    local vol inst rc=0
    vol="$(state_lease_volume)"
    inst="$(state_lease_instance)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        state_err "lease: refusing to start the user manager without an answer from the guest API; once it answers: sudo systemctl restart $STATE_LEASE_UNIT"
        return 1
    fi
    if [[ "$vol" == fenced:* ]]; then
        state_err "lease: the state volume was moved away by a --move export (${vol#fenced:}); the user manager stays stopped. Take it back from the host with: incus exec <name> -- sudo acfs state lease reclaim"
        return 1
    fi
    if [[ -z "$vol" && -z "$inst" ]]; then
        echo "lease: none on the volume or the instance (no state layer, or a VPS)"
        return 0
    fi
    if [[ -z "$vol" ]]; then
        state_write_lease "$inst"
        echo "lease: first claim, the volume now holds this instance's lease"
        return 0
    fi
    if [[ -z "$inst" ]]; then
        state_err "lease: the state volume holds a lease, and this instance has no user.acfs.lease; another instance owns this volume"
        return 1
    fi
    if [[ "$vol" != "$inst" ]]; then
        state_err "lease: the state volume's lease differs from this instance's user.acfs.lease; another instance holds this volume"
        return 1
    fi
    echo "lease: this instance holds the state volume"
}

state_cmd_lease() {
    local sub="${1:-}"
    case "$sub" in
        new) state_lease_new ;;
        check) state_require_root lease check; state_lease_check ;;
        status)
            state_require_root lease status
            local vol inst
            vol="$(state_lease_volume)"; inst="$(state_lease_instance)" || inst=""
            printf 'volume lease:   %s\n' "$([[ -z "$vol" ]] && echo none || { [[ "$vol" == fenced:* ]] && echo fenced || echo set; })"
            printf 'instance lease: %s\n' "$([[ -n "$inst" ]] && echo set || echo none)"
            if [[ -n "$vol" && "$vol" == "$inst" ]]; then echo "match: yes"; else echo "match: no"; fi
            ;;
        reclaim)
            state_require_root lease reclaim
            local inst
            inst="$(state_lease_instance_required)"
            state_write_lease "$inst"
            echo "lease: this machine holds the state volume again; start it with: sudo systemctl restart $STATE_LEASE_UNIT && sudo systemctl start user@$(state_uid).service"
            ;;
        *) state_usage_die "lease needs new, check, status or reclaim" ;;
    esac
}

# --- Tool versions (recorded in the manifest, compared on import) ----

state_tool_versions_json() {
    local tool v json="{}"
    for tool in claude codex agy gemini pi gh herdr am tailscale; do
        v="$(runuser -u "$STATE_USER" -- env PATH="$STATE_HOME/.local/bin:$STATE_HOME/.bun/bin:$STATE_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
            timeout 10 "$tool" --version 2>/dev/null </dev/null | head -1 || true)"
        [[ -n "$v" ]] && json="$(jq -c --arg k "$tool" --arg v "$v" '. + {($k): $v}' <<<"$json")"
    done
    printf '%s\n' "$json"
}

# --- Rows as JSON for the helper -------------------------------------

state_rows_json() {
    local with_cache="$1" row id class base path policy markers dir arc tbase out="[]"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        [[ "$class" == "cache" && "$with_cache" != "true" ]] && continue
        dir="$(state_base_dir "$base")"
        arc="$(state_base_arc "$base")"
        tbase="$dir"
        out="$(jq -c --arg id "$id" --arg class "$class" --arg base "$base" --arg path "$path" \
            --arg policy "$policy" --arg markers "$markers" --arg dir "$dir" --arg arc "$arc" --arg tbase "$tbase" \
            '. + [{id:$id, class:$class, base:$base, path:$path, policy:$policy,
                   markers:($markers | split(",") | map(select(. != ""))),
                   base_dir:$dir, arc:$arc, target_base:$tbase}]' <<<"$out")"
    done
    printf '%s\n' "$out"
}

# --- export ----------------------------------------------------------

state_cmd_export() {
    local name="" file="" with_cache=false move=false dry_run=false
    local snap_pool="" snap_remote="host"
    local -a recipients=() recipient_files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --recipient) [[ $# -ge 2 ]] || state_usage_die "--recipient needs a value"; recipients+=("$2"); shift 2 ;;
            --recipients-file) [[ $# -ge 2 ]] || state_usage_die "--recipients-file needs a value"; recipient_files+=("$2"); shift 2 ;;
            --with-cache) with_cache=true; shift ;;
            --move) move=true; shift ;;
            --snapshot-pool) [[ $# -ge 2 ]] || state_usage_die "--snapshot-pool needs a value"; snap_pool="$2"; shift 2 ;;
            --snapshot-remote) [[ $# -ge 2 ]] || state_usage_die "--snapshot-remote needs a value"; snap_remote="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) state_usage; return 0 ;;
            -*) state_usage_die "unknown export option: $1" ;;
            *) if [[ -z "$name" ]]; then name="$1"; elif [[ -z "$file" ]]; then file="$1"; else state_usage_die "export takes <name> [<file>]"; fi; shift ;;
        esac
    done
    [[ -n "$name" ]] || state_usage_die "export needs the machine's name"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || state_usage_die "machine name must be letters, digits and dashes: $name"

    if [[ "$dry_run" == "true" ]]; then
        state_export_dry_run "$with_cache"
        return 0
    fi

    # Encrypted to a recipient's public key only (the operator, 2026-10-10).
    if [[ ${#recipients[@]} -eq 0 && ${#recipient_files[@]} -eq 0 ]]; then
        state_usage_die "export needs --recipient or --recipients-file (an age public key): the archive holds logins"
    fi
    state_need age python3 jq flock

    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if [[ -z "$file" ]]; then
        install -d -m 0700 -o "$(state_uid)" -g "$(state_gid)" "$STATE_OUT_DIR"
        file="$STATE_OUT_DIR/$name-$stamp.tar.age"
    fi
    [[ -e "$file" || -L "$file" ]] && state_die "refusing to overwrite $file"
    local out_dir
    out_dir="$(dirname "$file")"
    [[ -d "$out_dir" ]] || state_die "no such directory: $out_dir"

    state_lock
    # Asked before the quiesce: running the tools may write their state.
    local tools
    tools="$(state_tool_versions_json)"
    trap 'state_restart_writers' EXIT
    state_quiesce

    # The snapshot is the rollback point; the archive is read from the
    # quiesced volume itself, which the guest can see and the snapshot
    # it can't.
    if [[ -n "$snap_pool" ]]; then
        local snap="acfs-export-$stamp"
        state_info "Snapshotting $snap_remote:acfs-state-$name as $snap"
        runuser -u "$STATE_USER" -- incus storage volume snapshot create "$snap_remote:$snap_pool" "acfs-state-$name" "$snap" \
            || state_die "could not snapshot acfs-state-$name; nothing was exported"
    elif state_in_container; then
        state_info "No volume snapshot (pass --snapshot-pool to take one); the copy is taken from the quiesced volume"
    fi

    local prev_lease="" archive_id
    archive_id="$name-$stamp"
    if [[ "$move" == "true" ]]; then
        prev_lease="$(state_lease_volume)"
        state_write_lease "fenced:$archive_id"
        STATE_KEEP_STOPPED=true
    fi

    local work spec summary partial
    work="$(mktemp -d "$STATE_META/.export.XXXXXX")"
    spec="$work/spec.json"
    summary="$work/summary.json"
    jq -n --argjson rows "$(state_rows_json "$with_cache")" \
        --argjson tools "$tools" \
        --arg created "$(state_now)" --arg name "$name" --arg id "$archive_id" \
        --arg kind "$([[ "$move" == "true" ]] && echo move || echo backup)" \
        --arg host "$(hostname 2>/dev/null || echo unknown)" \
        --arg version "$(cat "$STATE_HOME/.acfs/VERSION" 2>/dev/null || echo unknown)" \
        --argjson with_cache "$with_cache" --argjson fenced "$move" \
        --argjson uid "$(state_uid)" --argjson gid "$(state_gid)" \
        '{rows: $rows, meta: {schema: 1, id: $id, created_at: $created, kind: $kind, fenced: $fenced,
          with_cache: $with_cache, acfs_version: $version, tools: $tools,
          source: {name: $name, hostname: $host, uid: $uid, gid: $gid}}}' >"$spec"

    partial="$out_dir/.$(basename "$file").partial.$$"
    local -a age_args=()
    local r
    for r in "${recipients[@]}"; do age_args+=(-r "$r"); done
    for r in "${recipient_files[@]}"; do age_args+=(-R "$r"); done
    state_info "Writing the archive"
    if ! (umask 077; state_py create "$spec" "$summary" | age "${age_args[@]}" -o "$partial"); then
        [[ -f "$partial" ]] && rm -f -- "$partial"
        if [[ "$move" == "true" ]]; then
            if [[ -n "$prev_lease" ]]; then state_write_lease "$prev_lease"; else rm -f -- "$STATE_META/lease"; fi
            STATE_KEEP_STOPPED=false
        fi
        state_die "export failed; no archive was written"
    fi
    chmod 0600 "$partial"
    chown "$(state_uid):$(state_gid)" "$partial"
    if ! ln -T -- "$partial" "$file" 2>/dev/null; then
        rm -f -- "$partial"
        state_die "refusing to overwrite $file"
    fi
    rm -f -- "$partial"

    local skipped
    skipped="$(jq -r '.skipped[] | "  \(.path): \(.why)"' "$summary")"
    if [[ -n "$skipped" ]]; then
        state_info "Left out (not state this layer can carry):"
        printf '%s\n' "$skipped" >&2
    fi
    echo "Exported $(jq -r '.rows | length' "$summary") rows, $(jq -r '.files' "$summary") files to $file"
    echo "sha256: $(sha256sum "$file" | cut -d' ' -f1)"
    if [[ "$move" == "true" ]]; then
        echo "This is a move: this machine is fenced. Its user manager and tailscaled stay stopped and the lease unit refuses them at boot."
        echo "Import the archive on the new machine; to take the login back here instead: sudo acfs state lease reclaim"
    fi
    echo "Move it with scp; never commit it, mail it or upload it."
}

state_export_dry_run() {
    local with_cache="$1" row id class base path policy markers target
    echo "Rows that an export would carry:"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        [[ "$class" == "cache" && "$with_cache" != "true" ]] && continue
        target="$(state_row_target "$base" "$path")"
        if [[ -e "$target" || -L "$target" ]]; then
            printf '  %-18s %-6s %s\n' "$id" "$class" "$target"
        else
            printf '  %-18s %-6s %s (absent)\n' "$id" "$class" "$target"
        fi
    done
    local unknown
    unknown="$(state_unknown_entries)"
    if [[ -n "$unknown" ]]; then
        echo "Not in the manifest (kept on the volume, not exported; add a row if it is a tool's state):"
        sed 's/^/  /' <<<"$unknown"
    fi
}

# --- import ----------------------------------------------------------

state_journal() {
    printf '%s %s\n' "$(state_now)" "$*" >>"$STATE_META/journal"
}

state_journal_has() {
    [[ -f "$STATE_META/journal" ]] && grep -qxF -- "$1" < <(cut -d' ' -f2- "$STATE_META/journal")
}

# The id of a staged import that has no "done" line.
state_pending_import() {
    [[ -f "$STATE_META/journal" ]] || return 0
    local id
    id="$(awk '$3=="staged"{last=$2} $3=="done" && $2==last {last=""} END{print last}' "$STATE_META/journal")"
    printf '%s' "$id"
}

state_age_decrypt() {
    local file="$1" identity="$2"
    if [[ -n "$identity" ]]; then age -d -i "$identity" "$file"; else age -d "$file"; fi
}

state_cmd_import() {
    local name="" file="" identity="" replace=false resume=false dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --identity) [[ $# -ge 2 ]] || state_usage_die "--identity needs a value"; identity="$2"; shift 2 ;;
            --replace) replace=true; shift ;;
            --resume) resume=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) state_usage; return 0 ;;
            -*) state_usage_die "unknown import option: $1" ;;
            *) if [[ -z "$name" ]]; then name="$1"; elif [[ -z "$file" ]]; then file="$1"; else state_usage_die "import takes <name> <file>"; fi; shift ;;
        esac
    done
    [[ -n "$name" ]] || state_usage_die "import needs the machine's name"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || state_usage_die "machine name must be letters, digits and dashes: $name"
    state_need python3 jq flock

    state_lock
    # Read the instance's lease now: an import that couldn't write it at
    # the end would leave a volume the next boot refuses.
    [[ "$dry_run" == "true" ]] || state_lease_instance_required >/dev/null
    local pending
    pending="$(state_pending_import)"
    if [[ "$resume" == "true" ]]; then
        [[ -n "$pending" ]] || state_die "no interrupted import to resume"
        trap 'state_restart_writers' EXIT
        state_quiesce
        state_import_swap "$pending"
        state_import_finish "$pending"
        return 0
    fi
    [[ -z "$pending" ]] || state_die "import $pending was interrupted; finish it with: sudo acfs state import $name --resume"
    [[ -n "$file" ]] || state_usage_die "import needs <file>"
    [[ -f "$file" ]] || state_die "no such file: $file"
    state_need age

    local id work manifest
    id="import-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    work="$STATE_META/$id"
    mkdir -m 0700 "$work"
    manifest="$work/manifest.json"
    state_info "Validating the archive"
    set +e
    state_age_decrypt "$file" "$identity" | state_py verify "$manifest"
    local -a rcs=("${PIPESTATUS[@]}")
    set -e
    [[ "${rcs[0]}" -eq 0 ]] || state_die "age could not decrypt $file; nothing was changed"
    [[ "${rcs[1]}" -eq 0 ]] || state_die "the archive failed validation; nothing was changed"

    local kind fenced
    kind="$(jq -r '.kind' "$manifest")"
    fenced="$(jq -r '.fenced' "$manifest")"
    if [[ "$kind" == "move" && "$fenced" != "true" ]]; then
        state_die "a move archive whose source is not fenced; export again with --move on the source"
    fi
    local source_name
    source_name="$(jq -r '.source.name // ""' "$manifest")"
    if [[ -n "$source_name" && "$source_name" != "$name" ]]; then
        state_info "note: the archive was exported from $source_name, and this machine is $name"
    fi
    state_import_tool_warnings "$manifest"

    # A login this machine holds is replaced only on --replace.
    local held
    held="$(state_import_held_logins "$manifest")"
    if [[ -n "$held" && "$replace" != "true" ]]; then
        state_err "this machine already holds a login:"
        sed 's/^/  /' <<<"$held" >&2
        state_die "pass --replace to replace it (the old copy is kept on the volume)"
    fi
    if [[ "$dry_run" == "true" ]]; then
        echo "The archive is valid: $(jq -r '.kind' "$manifest") $(jq -r '.id' "$manifest"), $(jq -r '[.rows[] | select(.present)] | length' "$manifest") rows, $(jq -r '.files | length' "$manifest") files"
        return 0
    fi

    trap 'state_restart_writers' EXIT
    state_quiesce

    # Stage on the volume: everything under the home's staging dir, then
    # the root rows copied into their own mounts, so every swap is a
    # rename within one mount.
    local hstage
    hstage="$STATE_HOME/.acfs-import-$id"
    mkdir -m 0700 "$hstage"
    chown 0:0 "$hstage"
    state_info "Extracting into $hstage"
    set +e
    state_age_decrypt "$file" "$identity" | state_py extract "$hstage/x" "$manifest"
    rcs=("${PIPESTATUS[@]}")
    set -e
    if [[ "${rcs[0]}" -ne 0 || "${rcs[1]}" -ne 0 ]]; then
        state_die "extraction failed; the machine is unchanged (staging left at $hstage)"
    fi
    local base dir arc stage
    for base in home ssh-host tailscale; do
        dir="$(state_base_dir "$base")"
        arc="$(state_base_arc "$base")"
        stage="$dir/.acfs-import-$id"
        [[ -e "$hstage/x/$arc" ]] || continue
        if [[ "$base" == "home" ]]; then
            mv "$hstage/x/home" "$hstage/new"
        else
            mkdir -p "$dir"
            mkdir -m 0700 "$stage"
            cp -a "$hstage/x/$arc" "$stage/new"
        fi
        chown -R -h "$(state_owner_for_base "$base")" "$( [[ "$base" == "home" ]] && echo "$hstage/new" || echo "$stage/new")"
    done
    # The root rows' extracted copies are in their own mounts now; this
    # copy would only leave a second set of host keys in the home.
    rm -rf -- "$hstage/x"
    chown 0:0 "$hstage"
    state_import_apply_modes "$id" "$manifest"
    jq -r '.rows[] | select(.present) | "\(.base):\(.path)"' "$manifest" >"$work/rows"
    state_journal "$id staged"
    state_import_swap "$id"
    state_import_finish "$id"
}

state_import_tool_warnings() {
    local manifest="$1" tool want have
    while IFS=$'\t' read -r tool want; do
        [[ -n "$tool" ]] || continue
        have="$(runuser -u "$STATE_USER" -- env PATH="$STATE_HOME/.local/bin:$STATE_HOME/.bun/bin:$STATE_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
            timeout 10 "$tool" --version 2>/dev/null </dev/null | head -1 || true)"
        if [[ -z "$have" ]]; then
            state_info "note: $tool is not installed here (the archive has $want)"
        elif [[ "$have" != "$want" ]]; then
            state_info "note: $tool differs: archive $want, here $have; check its login after the import"
        fi
    done < <(jq -r '.tools // {} | to_entries[] | "\(.key)\t\(.value)"' "$manifest")
}

state_import_held_logins() {
    # Only rows with markers hold a login; a fresh machine's own SSH host
    # keys are not one.
    local manifest="$1" base path markers marker dir
    while IFS='|' read -r base path markers; do
        dir="$(state_base_dir "$base")" || continue
        for marker in ${markers//,/ }; do
            [[ -e "$dir/$marker" ]] && printf '%s\n' "$dir/$marker"
        done
    done < <(jq -r '.rows[] | select(.present) | "\(.base)|\(.path)|\(.markers | join(","))"' "$manifest")
    return 0
}

state_import_apply_modes() {
    local id="$1" manifest="$2" base path policy new
    while IFS='|' read -r base path policy; do
        [[ "$policy" == "private" ]] || continue
        if [[ "$base" == "home" ]]; then new="$STATE_HOME/.acfs-import-$id/new"; else new="$(state_base_dir "$base")/.acfs-import-$id/new"; fi
        state_fix_modes "${new}${path:+/$path}"
    done < <(jq -r '.rows[] | select(.present) | "\(.base)|\(.path)|\(.policy)"' "$manifest")
}

# mkdir -p for a home row's parents, owned by the user.
state_make_parents() {
    local base="$1" rel="$2" dir parent="" part
    dir="$(state_base_dir "$base")"
    IFS='/' read -r -a parts <<<"$(dirname "$rel")"
    for part in "${parts[@]}"; do
        [[ "$part" == "." || -z "$part" ]] && continue
        parent="${parent:+$parent/}$part"
        if [[ ! -d "$dir/$parent" ]]; then
            mkdir -m 0700 "$dir/$parent"
            chown "$(state_owner_for_base "$base")" "$dir/$parent"
        fi
    done
}

# Swap each staged row into place. Each step is a rename within one
# mount, recorded in the journal, and safe to run again.
state_import_swap() {
    local id="$1" row base path dir stage entry
    [[ -f "$STATE_META/$id/rows" ]] || state_die "import $id has no row list; it cannot be resumed"
    while IFS= read -r row; do
        base="${row%%:*}"
        path="${row#*:}"
        dir="$(state_base_dir "$base")"
        stage="$dir/.acfs-import-$id"
        state_journal_has "$id moved-new $row" && continue
        if ! state_journal_has "$id moved-old $row"; then
            if [[ -n "$path" ]]; then
                if [[ -e "$dir/$path" || -L "$dir/$path" ]]; then
                    mkdir -p "$stage/old/$(dirname "$path")"
                    mv -T -- "$dir/$path" "$stage/old/$path"
                fi
            else
                mkdir -p "$stage/old"
                while IFS= read -r -d '' entry; do
                    mv -- "$entry" "$stage/old/"
                done < <(find "$dir" -mindepth 1 -maxdepth 1 ! -name '.acfs-import-*' -print0)
            fi
            state_journal "$id moved-old $row"
        fi
        if [[ -n "$path" ]]; then
            if [[ -e "$stage/new/$path" || -L "$stage/new/$path" ]]; then
                state_make_parents "$base" "$path"
                mv -T -- "$stage/new/$path" "$dir/$path"
            fi
            [[ "$row" == "home:.ssh" ]] && state_merge_authorized_keys "$stage/old/.ssh/authorized_keys" "$dir/.ssh/authorized_keys"
        else
            while IFS= read -r -d '' entry; do
                mv -- "$entry" "$dir/"
            done < <(find "$stage/new" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        fi
        state_journal "$id moved-new $row"
    done <"$STATE_META/$id/rows"
}

# The keys this machine was launched with keep working after an import
# brings the source's ~/.ssh: the result holds both sets, this
# machine's first. Running it again changes nothing.
state_merge_authorized_keys() {
    local old="$1" new="$2" tmp
    [[ -f "$old" ]] || return 0
    tmp="$(mktemp "$(dirname "$new")/.authorized_keys.XXXXXX")"
    if [[ -f "$new" ]]; then
        awk 'NF && !seen[$0]++' "$old" "$new" >"$tmp"
    else
        awk 'NF && !seen[$0]++' "$old" >"$tmp"
    fi
    chmod 0600 "$tmp"
    chown "$(state_uid):$(state_gid)" "$tmp"
    mv -f "$tmp" "$new"
}

state_import_finish() {
    local id="$1"
    state_write_lease "$(state_lease_instance_required)"
    # New host keys from the archive: point sshd at the ones now there.
    if grep -qx 'ssh-host:' "$STATE_META/$id/rows" && [[ -d "$STATE_SSH_DIR" ]]; then
        state_setup_ssh_host_keys
    fi
    state_journal "$id done"
    echo "Imported $(wc -l <"$STATE_META/$id/rows") rows; this machine holds the lease."
    echo "The replaced copies are kept under .acfs-import-$id/old in $STATE_HOME and each root row; remove them once 'acfs machine verify' passes."
}

# --- repair ----------------------------------------------------------

state_cmd_repair() {
    local dry_run=false
    [[ "${1:-}" == "--dry-run" ]] && dry_run=true
    [[ "$dry_run" == "true" ]] || state_require_root repair
    local row id class base path policy markers target owner uid problems changed=0
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        target="$(state_row_target "$base" "$path")"
        [[ -e "$target" ]] || continue
        if [[ "$base" == "home" ]]; then uid="$(state_uid)"; else uid=0; fi
        owner="$(state_owner_for_base "$base")"
        problems="$(state_owner_problems "$target" "$uid")"
        if [[ -n "$problems" ]]; then
            changed=$((changed + $(wc -l <<<"$problems")))
            printf '%s: owner -> %s (%d paths)\n' "$id" "$owner" "$(wc -l <<<"$problems")"
            [[ "$dry_run" == "true" ]] || chown -R -h "$owner" "$target"
        fi
        [[ "$policy" == "private" ]] || continue
        problems="$(state_mode_problems "$target")"
        if [[ -n "$problems" ]]; then
            changed=$((changed + $(wc -l <<<"$problems")))
            printf '%s: no group or other access (%d paths)\n' "$id" "$(wc -l <<<"$problems")"
            [[ "$dry_run" == "true" ]] || state_fix_modes "$target"
        fi
    done
    if [[ "$changed" -eq 0 ]]; then
        echo "Every row's modes and owners are right."
    elif [[ "$dry_run" == "true" ]]; then
        echo "Run without --dry-run (with sudo) to fix them."
    fi
}

# --- doctor ----------------------------------------------------------

# Top-level home entries, and entries of .config and .local/share,
# that no row covers and that are not toolchains or caches.
state_unknown_entries() {
    [[ -d "$STATE_HOME" ]] || return 0
    local -A covered=()
    local row id class base path policy markers entry rel known k
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        [[ "$base" == "home" ]] && covered["$path"]=1
    done
    for entry in "$STATE_HOME"/.[!.]* "$STATE_HOME"/.config/* "$STATE_HOME"/.local/share/*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        rel="${entry#"$STATE_HOME"/}"
        [[ -n "${covered[$rel]:-}" ]] && continue
        known=false
        # A known name, or that name with a suffix (.zcompdump-<host>)
        for k in "${STATE_KNOWN_NONSTATE[@]}"; do
            [[ "$rel" == "$k" || "$rel" == "$k"[-.]* || ( "$k" == *- && "$rel" == "$k"* ) ]] && known=true
        done
        # A directory with a row below it (.config/systemd)
        for k in "${!covered[@]}"; do
            [[ "$k" == "$rel"/* ]] && known=true
        done
        [[ "$known" == "true" ]] && continue
        printf '%s\n' "$rel"
    done
}

STATE_DOCTOR_ITEMS="[]"
state_doctor_item() {
    STATE_DOCTOR_ITEMS="$(jq -c --arg id "$1" --arg label "$2" --arg status "$3" --arg details "$4" --arg fix "${5:-}" \
        '. + [{id:$id, label:$label, status:$status, details:$details, fix:$fix}]' <<<"$STATE_DOCTOR_ITEMS")"
}

state_cmd_doctor() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true
    local layer=false container=false
    [[ -d "$STATE_META" ]] && layer=true
    state_in_container && container=true

    # The layer itself: in a container, the home and the root rows are
    # mounts of the state volume.
    if [[ "$layer" == "true" ]]; then
        local d not_mounted=()
        if [[ "$container" == "true" ]]; then
            for d in "$STATE_HOME" "$STATE_SSH_DIR" "$STATE_META"; do
                mountpoint -q "$d" 2>/dev/null || not_mounted+=("$d")
            done
            # Tailscale may run in a sidecar instead; its row matters
            # only where its state directory exists.
            if [[ -d "$STATE_TS_DIR" ]] && ! mountpoint -q "$STATE_TS_DIR" 2>/dev/null; then
                not_mounted+=("$STATE_TS_DIR")
            fi
        fi
        if [[ ${#not_mounted[@]} -eq 0 ]]; then
            state_doctor_item state.layer "State layer" pass "$([[ "$container" == "true" ]] && echo "home, root rows and lease are on the state volume" || echo "state directories present (VPS: plain directories)")"
        else
            state_doctor_item state.layer "State layer" fail "not mounts of the state volume: ${not_mounted[*]}; their contents are lost on a rebuild" \
                "recreate the machine with the launcher, which mounts acfs-state-<name>"
        fi
    elif [[ "$container" == "true" ]]; then
        state_doctor_item state.layer "State layer" warn "no state volume ($STATE_META is missing): logins are lost when the container is rebuilt" \
            "launch the machine with scripts/providers/incus.sh, which attaches acfs-state-<name>"
    else
        state_doctor_item state.layer "State layer" skip "not a container and no $STATE_META; the rows are plain directories in the home"
    fi

    # Modes and owners of the home rows (root rows need root to read).
    local row id class base path policy markers target bad=() uid
    uid="$(state_uid 2>/dev/null || echo -1)"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        # Cache rows hold no login and are too big to walk on every run.
        [[ "$base" == "home" && "$class" != "cache" ]] || continue
        target="$(state_row_target "$base" "$path")"
        [[ -e "$target" ]] || continue
        if [[ "$policy" == "private" && -n "$(state_mode_problems "$target" | head -1)" ]]; then bad+=("$id"); continue; fi
        [[ -n "$(state_owner_problems "$target" "$uid" | head -1)" ]] && bad+=("$id")
    done
    if [[ ${#bad[@]} -eq 0 ]]; then
        state_doctor_item state.modes "State modes" pass "login rows have no group or other access and belong to $STATE_USER"
    else
        state_doctor_item state.modes "State modes" warn "group or other access, or a foreign owner, in: ${bad[*]}" "sudo acfs state repair"
    fi

    # Credentials that sit on another filesystem than the home.
    local marker dev_home dev off=()
    dev_home="$(stat -c %d "$STATE_HOME" 2>/dev/null || echo "")"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        [[ "$base" == "home" ]] || continue
        for marker in ${markers//,/ }; do
            [[ -f "$STATE_HOME/$marker" ]] || continue
            dev="$(stat -c %d "$STATE_HOME/$marker" 2>/dev/null || echo "")"
            [[ -n "$dev_home" && "$dev" != "$dev_home" ]] && off+=("$marker")
        done
    done
    if [[ ${#off[@]} -gt 0 ]]; then
        state_doctor_item state.credentials "Credentials on the volume" fail "on another filesystem than the home: ${off[*]}" \
            "move them back under the home (no mount may cover them)"
    elif [[ "$layer" == "true" ]]; then
        state_doctor_item state.credentials "Credentials on the volume" pass "every login file is on the home's filesystem"
    fi

    local unknown
    unknown="$(state_unknown_entries | tr '\n' ' ')"
    if [[ -n "${unknown// /}" ]]; then
        state_doctor_item state.unknown "State manifest coverage" warn "not in the export manifest: ${unknown% }. They stay on the volume, but acfs state export leaves them out" \
            "add a row to ROWS in scripts/lib/state_layer.sh if one is a tool's login or sessions"
    else
        state_doctor_item state.unknown "State manifest coverage" pass "every dot-directory in the home is in the manifest or known"
    fi

    # The lease, through its unit's last result (the lease is root's).
    if [[ "$container" == "true" && -S "$STATE_GUEST_SOCK" && "$layer" == "true" ]]; then
        local load active result
        load="$(systemctl show -p LoadState --value "$STATE_LEASE_UNIT" 2>/dev/null || true)"
        active="$(systemctl show -p ActiveState --value "$STATE_LEASE_UNIT" 2>/dev/null || true)"
        result="$(systemctl show -p Result --value "$STATE_LEASE_UNIT" 2>/dev/null || true)"
        if [[ "$active" == "active" && "$result" == "success" ]]; then
            state_doctor_item state.lease "State lease" pass "this instance holds the state volume's lease"
            # acfs update refreshes ~/.acfs, not the unit's root-owned copy.
            if [[ -f "$STATE_LIBEXEC" ]] && ! cmp -s "$STATE_SCRIPT" "$STATE_LIBEXEC"; then
                state_doctor_item state.lease_script "State lease script" warn "the lease unit runs an older copy at $STATE_LIBEXEC" "sudo acfs state setup-guest"
            fi
        elif [[ "$load" != "loaded" ]]; then
            state_doctor_item state.lease "State lease" warn "$STATE_LEASE_UNIT is not installed or never ran" "sudo acfs state setup-guest"
        else
            state_doctor_item state.lease "State lease" fail "$STATE_LEASE_UNIT is $active ($result): another instance may hold this volume" "sudo acfs state lease status"
        fi
    else
        state_doctor_item state.lease "State lease" skip "no guest API or no state volume"
    fi

    # SSH host keys on the volume.
    if [[ "$layer" == "true" && "$container" == "true" ]]; then
        if [[ -f "$STATE_SSHD_DROPIN" ]] && grep -q "^HostKey $STATE_SSH_DIR/" "$STATE_SSHD_DROPIN" 2>/dev/null; then
            state_doctor_item state.ssh_host_keys "SSH host keys" pass "sshd reads its host keys from $STATE_SSH_DIR"
        else
            state_doctor_item state.ssh_host_keys "SSH host keys" warn "sshd does not use the host keys on the state volume, so a rebuild changes the machine's SSH identity" "sudo acfs state setup-guest"
        fi
    else
        state_doctor_item state.ssh_host_keys "SSH host keys" skip "no state volume in a container"
    fi

    if [[ "$json" == "true" ]]; then
        jq '.' <<<"$STATE_DOCTOR_ITEMS"
    else
        jq -r '.[] | "\(.status | ascii_upcase | .[0:4])  \(.label): \(.details)\(if .fix != "" then "\n      fix: \(.fix)" else "" end)"' <<<"$STATE_DOCTOR_ITEMS"
    fi
}

# --- setup-guest -----------------------------------------------------

state_write_if_changed() {
    local path="$1" content="$2" mode="$3" tmp
    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
        return 1
    fi
    mkdir -p "$(dirname "$path")"
    tmp="$(mktemp "$(dirname "$path")/.acfs-state.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
}

# SSH host keys on the volume: seed them from /etc/ssh once, then point
# sshd's HostKey at them. A drop-in sshd rejects is set aside with a
# warning and sshd keeps its own keys, so this never fails an install.
state_setup_ssh_host_keys() {
    chmod 0700 "$STATE_SSH_DIR"
    local key seeded=false
    if ! compgen -G "$STATE_SSH_DIR/ssh_host_*_key" >/dev/null; then
        for key in "$STATE_ETC_SSH"/ssh_host_*_key; do
            [[ -f "$key" ]] || continue
            cp -p -- "$key" "$STATE_SSH_DIR/"
            [[ -f "$key.pub" ]] && cp -p -- "$key.pub" "$STATE_SSH_DIR/"
            seeded=true
        done
        if [[ "$seeded" != "true" ]]; then
            state_err "warning: no SSH host keys in $STATE_ETC_SSH to seed $STATE_SSH_DIR from; sshd keeps its own"
            return 0
        fi
    fi
    chown -R 0:0 "$STATE_SSH_DIR"
    state_fix_modes "$STATE_SSH_DIR"
    local conf="# ACFS state layer (acfs-ioo3.3): the host keys live on the state volume,
# so a rebuilt machine keeps its SSH identity."
    for key in "$STATE_SSH_DIR"/ssh_host_*_key; do
        conf+=$'\n'"HostKey $key"
    done
    if state_write_if_changed "$STATE_SSHD_DROPIN" "$conf" 0644; then
        # sshd -t needs its privilege separation directory, which a
        # socket-activated ssh creates only on the first connection.
        [[ -d /run/sshd ]] || mkdir -p /run/sshd 2>/dev/null || true
        local why=""
        if ! why="$(sshd -t 2>&1)"; then
            mv -f "$STATE_SSHD_DROPIN" "$STATE_SSHD_DROPIN.rejected"
            state_err "warning: sshd -t rejected the HostKey drop-in, set aside at $STATE_SSHD_DROPIN.rejected; sshd keeps its own keys. sshd said: ${why:-nothing}"
            return 0
        fi
        systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service 2>/dev/null || true
    fi
    echo "sshd uses the host keys in $STATE_SSH_DIR"
}

state_cmd_setup_guest() {
    state_require_root setup-guest
    if [[ ! -d "$STATE_META" ]]; then
        echo "No state volume ($STATE_META is missing); nothing to set up."
        return 0
    fi
    local uid changed=false
    uid="$(state_uid)"

    # The lease unit, from a root-owned copy of this script, so nothing
    # in the user's home runs as root at boot.
    if [[ -S "$STATE_GUEST_SOCK" ]]; then
        mkdir -p "$(dirname "$STATE_LIBEXEC")"
        if ! cmp -s "$STATE_SCRIPT" "$STATE_LIBEXEC" 2>/dev/null; then
            install -m 0755 "$STATE_SCRIPT" "$STATE_LIBEXEC"
            chown 0:0 "$STATE_LIBEXEC"
            changed=true
        fi
        local unit dropin
        unit="[Unit]
Description=ACFS state volume lease: one running machine per state volume (acfs-ioo3.3)
After=local-fs.target
Before=user@$uid.service tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=ACFS_STATE_USER=$STATE_USER
ExecStart=/bin/bash $STATE_LIBEXEC lease check

[Install]
WantedBy=multi-user.target"
        dropin="[Unit]
# The user manager and tailscaled start only when this instance holds
# the state volume's lease (acfs-state-lease.service).
Requires=$STATE_LEASE_UNIT
After=$STATE_LEASE_UNIT"
        state_write_if_changed "$STATE_SYSTEMD_DIR/$STATE_LEASE_UNIT" "$unit" 0644 && changed=true
        state_write_if_changed "$STATE_SYSTEMD_DIR/user@$uid.service.d/10-acfs-lease.conf" "$dropin" 0644 && changed=true
        state_write_if_changed "$STATE_SYSTEMD_DIR/tailscaled.service.d/10-acfs-lease.conf" "$dropin" 0644 && changed=true
        if [[ "$changed" == "true" ]]; then
            systemctl daemon-reload
        fi
        systemctl enable "$STATE_LEASE_UNIT" >/dev/null 2>&1 || state_die "could not enable $STATE_LEASE_UNIT"
        echo "Lease unit installed: $STATE_LEASE_UNIT"
    else
        echo "No guest API ($STATE_GUEST_SOCK); the lease unit is for Incus containers only."
    fi

    if [[ -d "$STATE_SSH_DIR" ]]; then
        state_setup_ssh_host_keys
    fi
    if [[ -d "$STATE_TS_DIR" ]]; then
        chown 0:0 "$STATE_TS_DIR"
        chmod 0700 "$STATE_TS_DIR"
    fi
}

state_cmd_manifest() {
    local row id class base path policy markers
    if [[ "${1:-}" == "--json" ]]; then
        state_rows_json true | jq '[.[] | {id, class, base, path, policy, markers}]'
        return 0
    fi
    printf '%-18s %-6s %-10s %-8s %s\n' ID CLASS BASE POLICY PATH
    for row in "${ROWS[@]}"; do
        IFS='|' read -r id class base path policy markers <<<"$row"
        printf '%-18s %-6s %-10s %-8s %s\n' "$id" "$class" "$base" "$policy" "${path:-(whole)}"
    done
}

main() {
    local cmd="${1:-}"
    # export and import need root, except an export's --dry-run, which
    # reads only the home.
    case "$cmd" in
        export) state_has_arg --dry-run "$@" || state_require_root "$@" ;;
        import) state_require_root "$@" ;;
    esac
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        export) state_cmd_export "$@" ;;
        import) state_cmd_import "$@" ;;
        repair) state_cmd_repair "$@" ;;
        doctor) state_cmd_doctor "$@" ;;
        lease) state_cmd_lease "$@" ;;
        setup-guest) state_cmd_setup_guest "$@" ;;
        manifest) state_cmd_manifest "$@" ;;
        ""|-h|--help|help) state_usage ;;
        *) state_usage_die "unknown command: $cmd" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
