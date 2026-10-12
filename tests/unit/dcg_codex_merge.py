#!/usr/bin/env python3
"""dcg's installer's Codex step, for the codex-dcg tests (acfs-9hkh.81).

A copy of configure_codex's two Python parts in the dcg installer that
checksums.yaml pins (arosl/destructive_command_guard install.sh): the
"already" test and the merge. ACFS's `nhm_hooks.sh codex-dcg` must leave
Codex's hooks.json so that dcg's installer, run again by the next
`acfs update`, finds it "already" there and moves nothing.

Usage: dcg_codex_merge.py check HOOKS_FILE DCG_PATH   prints already|merge
       dcg_codex_merge.py merge HOOKS_FILE DCG_PATH   merges as dcg does
"""
import json
import os
import shlex
import sys


def is_dcg_command(cmd):
    if not isinstance(cmd, str) or not cmd:
        return False
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        return False
    if not tokens:
        return False
    name = os.path.basename(tokens[0])
    if name.endswith(".exe"):
        name = name[:-4]
    return name == "dcg"


def check(config, dcg_path):
    dcg_commands = []
    first_bash_hook_command = None
    first_bash_matcher_seen = False
    for entry in config.get("hooks", {}).get("PreToolUse", []):
        if not isinstance(entry, dict) or entry.get("matcher") != "Bash":
            continue
        hooks = entry.get("hooks", [])
        if not first_bash_matcher_seen:
            first_bash_matcher_seen = True
            first_hook = hooks[0] if hooks else None
            if isinstance(first_hook, dict):
                first_bash_hook_command = first_hook.get("command")
        for hook in hooks:
            if isinstance(hook, dict) and is_dcg_command(hook.get("command")):
                dcg_commands.append(hook.get("command"))
    if dcg_commands == [dcg_path] and first_bash_hook_command == dcg_path:
        return "already"
    return "merge"


def merge(config, dcg_path):
    config.setdefault("hooks", {}).setdefault("PreToolUse", [])
    bash_hooks = []
    new_pre_tool_use = []
    dcg_seen = False
    for entry in config["hooks"]["PreToolUse"]:
        if not isinstance(entry, dict):
            new_pre_tool_use.append(entry)
        elif entry.get("matcher") == "Bash":
            for hook in entry.get("hooks", []):
                if isinstance(hook, dict) and "command" in hook:
                    if not is_dcg_command(str(hook.get("command", ""))):
                        bash_hooks.append(hook)
                    else:
                        dcg_seen = True
                else:
                    bash_hooks.append(hook)
        else:
            new_pre_tool_use.append(entry)
    dcg_hook = {"type": "command", "command": dcg_path}
    if dcg_seen or not any(is_dcg_command(h.get("command", "")) for h in bash_hooks if isinstance(h, dict)):
        bash_hooks.insert(0, dcg_hook)
    if bash_hooks:
        new_pre_tool_use.insert(0, {"matcher": "Bash", "hooks": bash_hooks})
    config["hooks"]["PreToolUse"] = new_pre_tool_use
    return config


def main():
    verb, hooks_file, dcg_path = sys.argv[1:4]
    with open(hooks_file, encoding="utf-8") as f:
        config = json.load(f)
    if verb == "check":
        print(check(config, dcg_path))
    elif verb == "merge":
        # The installer merges only when its check says so.
        if check(config, dcg_path) == "merge":
            with open(hooks_file, "w", encoding="utf-8") as f:
                json.dump(merge(config, dcg_path), f, indent=2)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
