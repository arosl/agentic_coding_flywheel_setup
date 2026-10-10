"""A herdr socket for tests: agent.list, pane.process_info and agent.prompt.

Delivery talks to herdr only through its socket (acfs-qzc), so tests serve one
on a short path and point HERDR_SOCKET_PATH at it. Each agent row is what
herdr's agent.list reports; `mode` changes how agent.prompt answers.
"""
import json
import os
from pathlib import Path
import shutil
import socketserver
import tempfile
import threading

PROMPT_MODES = ("ok", "blocked", "not_found", "unknown_error", "disconnect", "garbage",
                "wrong_id", "wrong_pane", "oversize", "session_changed")


def agent_row(pane_id, cwd, agent="claude", status="idle", terminal_id=None, session=None):
    workspace = pane_id.split(":", 1)[0]
    return {"pane_id": pane_id, "workspace_id": workspace, "tab_id": workspace + ":t" + pane_id.rsplit(":p", 1)[1],
            "agent": agent, "agent_status": status, "cwd": str(cwd), "name": None,
            "terminal_id": terminal_id or "term_" + pane_id.replace(":", "_"),
            "agent_session": None if session is None else
            {"agent": agent, "kind": "id", "source": "herdr:" + agent, "value": session}}


class HerdrStub:
    def __init__(self, agents=()):
        # AF_UNIX paths are short (108 bytes), and TMPDIR can be long.
        self.dir = Path(tempfile.mkdtemp(prefix="hs", dir="/tmp" if os.path.isdir("/tmp") else None))
        self.path = self.dir / "herdr.sock"
        self.agents = {row["pane_id"]: row for row in agents}
        self.processes = {}
        self.mode = "ok"
        self.pane_modes = {}  # pane_id -> mode, overriding `mode` for that target
        self.calls = []
        stub = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                line = self.rfile.readline()
                request = json.loads(line)
                stub.calls.append((request["method"], request["params"]))
                reply = stub.answer(request)
                if reply is not None:
                    self.wfile.write(reply)

        self.server = socketserver.ThreadingUnixStreamServer(str(self.path), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def env(self, base=None):
        return dict(base if base is not None else os.environ, HERDR_SOCKET_PATH=str(self.path))

    def prompts(self):
        return [params for method, params in self.calls if method == "agent.prompt"]

    def answer(self, request):
        method, params, rid = request["method"], request["params"], request["id"]
        if method == "agent.list":
            return self.reply(rid, {"type": "agent_list", "agents": list(self.agents.values())})
        if method == "pane.process_info":
            row = self.agents.get(params["pane_id"])
            if row is None:
                return self.error(rid, "pane_not_found")
            processes = self.processes.get(params["pane_id"], [{"name": row["agent"], "argv": [row["agent"]], "pid": 4242}])
            return self.reply(rid, {"type": "process_info", "process_info": {
                "pane_id": params["pane_id"], "shell_pid": 4200, "foreground_processes": processes}})
        assert method == "agent.prompt", method
        assert set(params) == {"target", "text"}, params
        row = self.agents.get(params["target"])
        mode = self.pane_modes.get(params["target"], self.mode)
        if mode == "disconnect":
            return None
        if mode == "garbage":
            return b"not json\n"
        if mode == "oversize":
            return b"x" * (1024 * 1024 + 2)
        if mode == "blocked":
            return self.error(rid, "agent_blocked")
        if mode == "not_found" or row is None:
            return self.error(rid, "agent_not_found")
        if mode == "unknown_error":
            return self.error(rid, "internal_error")
        agent = dict(row)
        if mode == "wrong_id":
            rid = "someone-else"
        if mode == "wrong_pane":
            agent["pane_id"] = row["workspace_id"] + ":p99"
        if mode == "session_changed":
            # Another agent restarted in the same terminal: same pane and terminal.
            agent["agent_session"] = {"agent": row["agent"], "kind": "id", "source": "herdr:" + row["agent"],
                                      "value": "restarted-session"}
        return self.reply(rid, {"type": "agent_prompted", "agent": agent})

    @staticmethod
    def reply(rid, result):
        return (json.dumps({"id": rid, "result": result}) + "\n").encode()

    @staticmethod
    def error(rid, code):
        return (json.dumps({"id": rid, "error": {"code": code, "message": code.replace("_", " ")}}) + "\n").encode()
