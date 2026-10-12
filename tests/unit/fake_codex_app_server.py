#!/usr/bin/env python3
"""A stand-in for `codex app-server` on stdio, for the hook-trust tests.

It answers initialize, hooks/list and config/batchWrite as Codex 0.162.1
does (ACFS evidence exp.3 and exp.6), for the user layer only:
$CODEX_HOME/hooks.json. A hook's key is
"<realpath of hooks.json>:<event label>:<group>:<handler>", its
currentHash a SHA-256 of the handler, and its trustStatus comes from the
trust that config/batchWrite recorded in $CODEX_HOME/fake-trust.json.
Every request is appended to $CODEX_HOME/fake-requests.jsonl.

FAKE_CODEX_FAIL=1 makes it exit at once; FAKE_CODEX_DROP_WRITE=1 makes
batchWrite answer ok and record nothing.
"""
import hashlib
import json
import os
import sys

LABELS = {"PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use", "SessionStart": "session_start",
          "PostCompact": "post_compact", "PreCompact": "pre_compact", "Stop": "stop",
          "UserPromptSubmit": "user_prompt_submit", "SessionEnd": "session_end"}

if sys.argv[1:2] != ["app-server"] or os.environ.get("FAKE_CODEX_FAIL") == "1":
    sys.exit(1)
home = os.environ["CODEX_HOME"]
hooks_path = os.path.realpath(os.path.join(home, "hooks.json"))
trust_path = os.path.join(home, "fake-trust.json")


def trust():
    try:
        with open(trust_path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def hooks():
    try:
        with open(hooks_path, encoding="utf-8") as f:
            doc = json.load(f)
    except FileNotFoundError:
        return []
    known = trust()
    out = []
    for event, groups in doc.get("hooks", {}).items():
        for gi, group in enumerate(groups):
            for hi, h in enumerate(group.get("hooks", [])):
                if h.get("type") != "command":
                    continue
                key = f"{hooks_path}:{LABELS[event]}:{gi}:{hi}"
                digest = "sha256:" + hashlib.sha256(json.dumps(h, sort_keys=True).encode()).hexdigest()
                stored = known.get(key, {}).get("trusted_hash")
                status = "trusted" if stored == digest else ("modified" if stored else "untrusted")
                out.append({"key": key, "eventName": event[0].lower() + event[1:], "currentHash": digest,
                            "trustStatus": status})
    return out


for line in sys.stdin:
    msg = json.loads(line)
    with open(os.path.join(home, "fake-requests.jsonl"), "a", encoding="utf-8") as log:
        log.write(json.dumps(msg) + "\n")
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:
        continue
    if method == "initialize":
        result = {"userAgent": "fake"}
    elif method == "hooks/list":
        result = {"data": [{"cwd": msg["params"]["cwds"][0], "hooks": hooks(), "errors": []}]}
    elif method == "config/batchWrite":
        if os.environ.get("FAKE_CODEX_DROP_WRITE") != "1":
            known = trust()
            for edit in msg["params"]["edits"]:
                assert edit["keyPath"] == "hooks.state" and edit["mergeStrategy"] == "upsert"
                known.update(edit["value"])
            with open(trust_path, "w", encoding="utf-8") as f:
                json.dump(known, f)
        result = {"status": "ok"}
    else:
        print(json.dumps({"id": rid, "error": {"code": -32601, "message": "unknown method " + str(method)}}), flush=True)
        continue
    print(json.dumps({"id": rid, "result": result}), flush=True)
