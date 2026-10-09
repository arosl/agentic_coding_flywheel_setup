#!/usr/bin/env python3
"""Explicitly adopt observed native agents after an unconfirmed ACFS launch.

This is not evidence that the original spawn succeeded. The operator approves
one exact observed topology: the agents in the herdr workspace that carries
this launch's label. This command never starts agents, and never stops,
interrupts, renames or sends input to one. Existing results are never replaced.
"""
import argparse
from collections import Counter
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

SCHEMA = "acfs.swarm-launch.v2"
RECOVERY_SCHEMA = "acfs.swarm-launch-recovery.v2"
LIMIT = 1024 * 1024
# The same identifier rules as swarm_launch.sh.
HERDR_ID = r"[A-Za-z0-9][A-Za-z0-9_:.-]{0,63}"
TERMINAL_ID = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"
HERDR_NAME = r"[a-z][a-z0-9_-]{0,31}"
MAIL_NAME = r"[A-Za-z][A-Za-z0-9_-]{0,63}"
PROFILES = ("balanced", "codex-heavy", "review-heavy", "docs-heavy")
WORKLOADS = ("light", "standard", "heavy")


class RecoveryError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise RecoveryError(message)


def encode(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=True, indent=2,
                       allow_nan=False) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse(data):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, "Duplicate JSON field.")
            result[key] = value
        return result
    try:
        require(len(data) <= LIMIT, "Input exceeds 1 MiB.")
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(RecoveryError("Invalid JSON number.")))
        pending, count = [(value, 0)], 0
        while pending:
            item, depth = pending.pop()
            count += 1
            require(depth <= 32 and count <= 50000, "JSON input is too complex.")
            if isinstance(item, dict):
                pending.extend((v, depth + 1) for v in item.values())
                pending.extend((k, depth + 1) for k in item)
            elif isinstance(item, list):
                pending.extend((v, depth + 1) for v in item)
            elif isinstance(item, float):
                require(math.isfinite(item), "Invalid JSON number.")
            elif isinstance(item, str):
                require(not any(0xD800 <= ord(c) <= 0xDFFF for c in item), "Invalid JSON Unicode.")
        return value
    except (ValueError, UnicodeError, RecursionError):
        raise RecoveryError("Invalid JSON input.") from None


def clean_path(value):
    require(isinstance(value, str) and os.path.isabs(value)
            and not any(ord(c) < 32 or ord(c) == 127 for c in value), "Invalid absolute path.")
    path = Path(os.path.abspath(value))
    require(str(path) == value, "Path must be canonical and absolute.")
    return path


def directory(path):
    for part in [*reversed(path.parents), path]:
        require(stat.S_ISDIR(part.lstat().st_mode), "Directory contains a symlink or non-directory.")
    return path


@contextmanager
def locked_parent(receipt):
    parent = directory(receipt.parent)
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(info.st_uid == os.geteuid() and info.st_mode & 0o022 == 0,
                "Receipt parent must be owned by this user and not writable by others.")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RecoveryError("Another launch or recovery holds this receipt directory.") from None
        require(os.path.samestat(parent.stat(), info), "Receipt parent changed.")
        yield fd, info
    finally:
        os.close(fd)


def read_private(fd, name):
    handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    with os.fdopen(handle, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                and info.st_uid == os.geteuid() and info.st_mode & 0o077 == 0,
                "Intent must be an owned, private, single-link regular file.")
        data = stream.read(LIMIT + 1)
    require(len(data) <= LIMIT, "Intent exceeds 1 MiB.")
    return data, info


def no_result(fd, name):
    try:
        os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise RecoveryError("A result path already exists. Preserve it and use ordinary launch reconciliation; recovery will not replace it.")


def validate_request(intent, receipt):
    require(isinstance(intent, dict) and intent.get("schema") == SCHEMA,
            "A saved launch intent is required. Recovery never invents a launch request.")
    request = intent.get("request")
    require(isinstance(request, dict) and set(request) == {
        "repo", "session", "agents", "receipt", "profile", "workload", "accept_warnings"},
        "Invalid saved launch request.")
    require(request["receipt"] == str(receipt), "Intent belongs to a different receipt path.")
    directory(clean_path(request["repo"]))
    require(isinstance(request["session"], str)
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", request["session"])
            and request["profile"] in PROFILES and request["workload"] in WORKLOADS
            and type(request["accept_warnings"]) is bool, "Invalid saved launch options.")
    agents = request["agents"]
    require(isinstance(agents, list) and 1 <= len(agents) <= 32
            and all(isinstance(a, dict) and set(a) == {"agent_name", "agent_type"}
                and isinstance(a["agent_name"], str)
                and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", a["agent_name"])
                and a["agent_type"] in ("claude", "codex") for a in agents)
            and len({a["agent_name"].lower() for a in agents}) == len(agents),
            "Invalid saved native-agent identities.")
    return request


def run(argv, repo, timeout):
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(argv, cwd=repo, stdin=subprocess.DEVNULL,
            stdout=out, stderr=err, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                require(time.monotonic() < deadline, "Pane observation timed out.")
                require(os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size <= LIMIT,
                        "Pane observation exceeds 1 MiB.")
                time.sleep(0.02)
            require(os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size <= LIMIT,
                    "Pane observation exceeds 1 MiB.")
            out.seek(0)
            require(process.returncode == 0, "Unable to observe the launch's herdr workspace.")
            return out.read(LIMIT + 1)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def workspace_label(request):
    # Must match swarm_launch.sh: the label carries the intent's review hash.
    return "swarm-" + request["session"] + "-" + digest(encode({"schema": SCHEMA, "request": request}))[:12]


def herdr_result(herdr, args, request, timeout):
    value = parse(run([herdr, *args], request["repo"], timeout))
    require(isinstance(value, dict) and isinstance(value.get("result"), dict), "Unrecognized herdr observation.")
    return value["result"]


def observe(request, timeout):
    """The launch's agents, keyed by pane. Names are reported, never trusted:
    herdr can drop an agent's name (acfs-i7p); the tab label keeps the Agent
    Mail name spawn gave it."""
    found = shutil.which("herdr")
    require(found is not None, "herdr is unavailable.")
    herdr = os.path.abspath(found)
    label = workspace_label(request)
    workspaces = herdr_result(herdr, ["workspace", "list"], request, timeout).get("workspaces")
    require(isinstance(workspaces, list), "Unrecognized herdr observation.")
    matches = [w for w in workspaces if isinstance(w, dict) and w.get("label") == label]
    require(len(matches) == 1 and isinstance(matches[0].get("workspace_id"), str)
            and re.fullmatch(HERDR_ID, matches[0]["workspace_id"]),
            "Exactly one herdr workspace must carry this launch's label (" + label + ").")
    workspace_id = matches[0]["workspace_id"]
    tabs = herdr_result(herdr, ["tab", "list", "--workspace", workspace_id], request, timeout).get("tabs")
    agents = herdr_result(herdr, ["agent", "list"], request, timeout).get("agents")
    require(isinstance(tabs, list) and isinstance(agents, list), "Unrecognized herdr observation.")
    labels = {t.get("tab_id"): t.get("label") for t in tabs if isinstance(t, dict)}
    rows = [a for a in agents if isinstance(a, dict) and a.get("workspace_id") == workspace_id]
    require(len(rows) == len(request["agents"]), "Observed agent count does not match the saved launch.")
    observed = []
    for row in rows:
        require(row.get("agent") in ("claude", "codex")
                and all(isinstance(row.get(k), str) and re.fullmatch(HERDR_ID, row[k]) for k in ("pane_id", "tab_id"))
                and re.fullmatch(r".*:t[0-9A-Za-z]{1,12}", row["tab_id"])
                and isinstance(row.get("terminal_id"), str) and re.fullmatch(TERMINAL_ID, row["terminal_id"]),
                "Every observed agent must be a live native agent in the launch workspace.")
        mail_name = labels.get(row["tab_id"])
        require(isinstance(mail_name, str) and re.fullmatch(MAIL_NAME, mail_name)
                and re.fullmatch(HERDR_NAME, mail_name.lower()),
                "An agent's tab no longer carries its Agent Mail name; recovery will not guess it.")
        require(row.get("name") in (None, "", "-", mail_name.lower()),
                "An agent's herdr name differs from its tab's Agent Mail name; recovery will not guess.")
        current, repo = clean_path(row.get("cwd")).resolve(strict=True), Path(request["repo"])
        require(current == repo or repo in current.parents, "A native agent is outside the saved repository.")
        info = herdr_result(herdr, ["pane", "process-info", "--pane", row["pane_id"]], request, timeout).get("process_info")
        require(isinstance(info, dict) and info.get("pane_id") == row["pane_id"]
                and type(info.get("shell_pid")) is int and info["shell_pid"] > 0
                and isinstance(info.get("foreground_processes"), list)
                and any(isinstance(p, dict) and p.get("name") == row["agent"] for p in info["foreground_processes"]),
                "An observed pane is not running the native agent it reports.")
        observed.append({"agent_type": row["agent"], "agent_mail_name": mail_name, "herdr_name": mail_name.lower(),
            "workspace_id": workspace_id, "workspace_label": label, "tab_id": row["tab_id"],
            "pane_id": row["pane_id"], "terminal_id": row["terminal_id"], "shell_pid": info["shell_pid"],
            "launched_state": "blocked" if row.get("agent_status") == "blocked" else "ready",
            # herdr counts tabs past 9 with letters (w1:t9, w1:tA, ...); base 36
            # orders those the way herdr created them.
            "order": int(row["tab_id"].rsplit(":t", 1)[1], 36)})
    for key in ("pane_id", "tab_id", "terminal_id", "shell_pid", "herdr_name", "order"):
        require(len({o[key] for o in observed}) == len(observed), "Observed agents are not distinct.")
    require(Counter(o["agent_type"] for o in observed)
            == Counter(a["agent_type"] for a in request["agents"]), "Observed native-agent mix changed.")
    # Sequential start made tab creation order the slot order.
    ordered = sorted(observed, key=lambda o: o["order"])
    by_type = {kind: iter([o for o in ordered if o["agent_type"] == kind]) for kind in ("claude", "codex")}
    targets = []
    for slot, agent in enumerate(request["agents"], 1):
        target = next(by_type[agent["agent_type"]]).copy()
        target.pop("order")
        targets.append({**target, "slot": slot, "agent_name": agent["agent_name"]})
    return targets


def identity(targets):
    """What approval binds: everything but the volatile launch state."""
    return [{k: v for k, v in t.items() if k != "launched_state"} for t in targets]


def publish(fd, name, value):
    # O_EXCL is intentional. Even a partial result from an interrupted writer
    # remains evidence; no recovery path truncates, replaces, or deletes it.
    handle = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=fd)
    with os.fdopen(handle, "wb") as stream:
        stream.write(encode(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.fsync(fd)


def main(arguments=None):
    parser = argparse.ArgumentParser(prog="acfs swarm launch --recover", allow_abbrev=False,
        description="Recover an unconfirmed launch by explicitly adopting its observed native panes. "
                    "Preview first. Never launches agents, sends work, or replaces an existing result.")
    parser.add_argument("--receipt", required=True, help="Existing private launch intent, not its result")
    parser.add_argument("--adopt", action="store_true", help="Create the missing result for the exact reviewed topology")
    parser.add_argument("--expect-sha256", help="Recovery digest from this command's preview, not the original launch digest")
    parser.add_argument("--timeout", type=int, choices=range(1, 31), default=10, metavar="1..30")
    args = parser.parse_args(arguments)
    require(not args.adopt or args.expect_sha256 is not None, "Preview recovery first, then use --adopt --expect-sha256.")
    receipt = clean_path(os.path.abspath(args.receipt))
    result_name = receipt.name + ".result.json"
    with locked_parent(receipt) as (fd, parent_info):
        raw, intent_info = read_private(fd, receipt.name)
        request = validate_request(parse(raw), receipt)
        no_result(fd, result_name)
        targets = observe(request, args.timeout)
        approval = {"schema": RECOVERY_SCHEMA, "intent_sha256": digest(raw),
            "request": request, "targets": identity(targets),
            "policy_sha256": digest(Path(__file__).read_bytes())}
        review_hash = digest(encode(approval))
        require(args.expect_sha256 is None or args.expect_sha256 == review_hash,
                "Recovery request or native pane identities changed; preview recovery again.")
        report = {"schema": RECOVERY_SCHEMA, "status": "preview", "receipt": str(receipt),
            "review_sha256": review_hash, "targets": targets, "starts_agents": False,
            "work_dispatched": False, "agent_mail_registered": True,
            "original_launch_verified": False, "result_created": False,
            "note": "Approval adopts these current native agents, not proof of the original spawn. "
                    "Agent Mail names are read from each agent's tab label, where spawn put them."}
        if not args.adopt:
            report["adopt_command"] = shlex.join(["acfs", "swarm", "launch", "--recover",
                "--receipt", str(receipt), "--timeout", str(args.timeout),
                "--adopt", "--expect-sha256", review_hash])
        else:
            targets = observe(request, args.timeout)
            require(identity(targets) == approval["targets"], "Native agent identities changed during recovery.")
            current, current_info = read_private(fd, receipt.name)
            require(current == raw and os.path.samestat(current_info, intent_info), "Launch intent changed during recovery.")
            directory(receipt.parent)
            require(os.path.samestat(receipt.parent.stat(), parent_info), "Receipt parent changed during recovery.")
            no_result(fd, result_name)
            publish(fd, result_name, {"schema": SCHEMA, "request": request, "targets": targets,
                "recovery": {"schema": RECOVERY_SCHEMA, "review_sha256": review_hash,
                    "intent_sha256": digest(raw), "original_launch_verified": False,
                    "adopted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}})
            report.update(status="ready", result_created=True)
            try:
                require(identity(observe(request, args.timeout)) == approval["targets"],
                        "Native agents changed after result publication.")
            except (RecoveryError, OSError, UnicodeError) as exc:
                report.update(status="unconfirmed", error=str(exc) if isinstance(exc, RecoveryError)
                              else "Unable to recheck native agents. Preserve the published result.")
        report["recovery"] = "Preserve the launch intent and result. Use ordinary launch reconciliation " \
                             "before preparing work. Never remove receipts to force a duplicate launch."
    print(encode(report).decode(), end="")
    return 1 if report["status"] == "unconfirmed" else 0


def cli(arguments=None):
    try:
        return main(arguments)
    except (RecoveryError, OSError, UnicodeError) as exc:
        print(encode({"schema": RECOVERY_SCHEMA, "status": "error", "starts_agents": False,
            "work_dispatched": False, "error": str(exc) if isinstance(exc, RecoveryError)
            else "Recovery unavailable. Preserve the intent and any result; no agent was started."}).decode(), end="")
        return 2
    except KeyboardInterrupt:
        print(encode({"schema": RECOVERY_SCHEMA, "status": "interrupted", "starts_agents": False,
            "work_dispatched": False, "error": "Recovery interrupted. Preserve the intent and any result."}).decode(), end="")
        return 130


if __name__ == "__main__":
    def cancelled(signum, frame):
        raise KeyboardInterrupt
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cancelled)
    sys.exit(cli())
