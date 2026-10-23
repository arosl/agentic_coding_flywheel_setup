#!/usr/bin/env python3
"""Mock model APIs for the nhm rehearsal sandbox (acfs-9hkh.31.1).

Claude Code and Codex in the sandbox talk to this server instead of a real
account: the Anthropic Messages API (POST /v1/messages, streamed or not,
and /v1/messages/count_tokens) and the OpenAI Responses API (POST
/v1/responses, streamed or not; GET /v1/models). The wire shapes are those
that exp.3 (Codex) and exp.4 (Claude Code) proved against the real CLIs.

It listens on 127.0.0.1 only. --port 0 (the default) takes a free port;
--ready FILE receives {"port", "pid", "url"} once it listens. Any API key
is accepted, and none is ever logged: --log FILE gets one JSON line per
request with the path, model, stream flag and the whole last user text,
never a header; for the Messages API also each message's role and block
types (shape), and the tool calls asked for or results read.

Replies: --script FILE is a JSON list, one entry per turn in order, each a
string (the reply text) or {"text": ..., "delay": seconds}; after the last
entry the default reply repeats. Without a script: "mock reply N". A
reply is streamed over --reply-delay seconds (default 1.5; a script
entry's own "delay" wins), as a real API takes a while, so herdr sees the
agent working before the turn ends. Unscripted, a prompt with the word
"slow" takes about 8 seconds, and one with the word "fast" is answered at
once, a turn that can end before herdr sees it start. The tools' own helper requests,
a compaction (Claude Code's /compact, Codex's checkpoint) and a session
title, are answered at once and never consume a turn. They are known by
their prompts' wording (COMPACTION, TITLE), so a prompt that only asks
for a summary is an ordinary turn.

Tool calls (acfs-9hkh.94): each line of the prompt that reads
'mock-tool: {"name": ..., "input": {...}}', at the start of the line,
adds that call to the turn's reply, so the CLI runs the tool: a tool_use
block with stop reason tool_use (Messages API; Claude Code's Write or
Bash), or a function_call item whose arguments are the input (Responses
API; Codex 0.162's exec_command takes {"cmd": ...}). The request that
carries the tools' results gets a short closing text and takes no turn.
A helper request never calls a tool.

Pointing the CLIs at it (as exp.3 and exp.4 did):
- Claude Code: ANTHROPIC_BASE_URL=<url> and any ANTHROPIC_API_KEY.
- Codex: a provider in $CODEX_HOME/config.toml (Codex 0.162 reads no base
  URL from the environment for this):
      model = "mock-model"
      model_provider = "mock"
      [model_providers.mock]
      name = "mock"
      base_url = "<url>/v1"
      wire_api = "responses"
      requires_openai_auth = false
      supports_websockets = false

Usage: mock_anthropic.py [--port N] [--ready FILE] [--log FILE] [--script FILE]
                         [--reply-delay SECONDS]
"""

import argparse
import json
import os
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLY_SECONDS = 1.5
SLOW_SECONDS = 8.0
# The helper requests' wording, lowercased, as Claude Code 2.1 and Codex
# 0.162 send it.
COMPACTION = ("your task is to create a detailed summary of the conversation so far",
              "you are performing a context checkpoint compaction")
TITLE = ("generate a concise, single-line task title",
         "write the title in the predominant language of the session")


# A prompt line that asks for a tool call. Only at a line's start, so a
# prompt that quotes one (nhm's CASS excerpt of an earlier session) asks
# for nothing.
TOOL_LINE = re.compile(r"^mock-tool: (\{.*\})[ \t]*$", re.M)


def says(text, word):
    """Whether text holds word as a whole word."""
    return re.search(rf"\b{word}\b", text) is not None


def is_helper(text):
    """Whether text is a tool's own helper request (a compaction or a title)."""
    lower = text.lower()
    return any(p in lower for p in COMPACTION + TITLE)


def tool_calls(text):
    """The tool calls a prompt asks for, one per 'mock-tool: {json}' line
    with a name and an input object; any other line is no call."""
    calls = []
    for m in TOOL_LINE.finditer(text):
        try:
            call = json.loads(m.group(1))
        except ValueError:
            continue
        if isinstance(call, dict) and isinstance(call.get("name"), str) and isinstance(call.get("input"), dict):
            calls.append({"name": call["name"], "input": call["input"]})
    return calls


class State:
    """The script, the turn counter and the reply delay, shared by the
    handler threads."""

    def __init__(self, script, log, delay):
        self.script = script
        self.log = log
        self.delay = delay
        self.turn = 0
        self.lock = threading.Lock()

    def record(self, rec):
        if not self.log:
            return
        rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = json.dumps(rec, ensure_ascii=False) + "\n"
        with self.lock, open(self.log, "a", encoding="utf-8") as fh:
            fh.write(line)

    def reply(self, text):
        """The reply text and its streaming delay for a request whose last
        user text is text."""
        lower = text.lower()
        if any(p in lower for p in COMPACTION):
            return "<summary>mock compaction summary: the user asked for nothing else.</summary>", 0.0
        if any(p in lower for p in TITLE):
            return "Mock task", 0.0
        with self.lock:
            self.turn += 1
            n = self.turn
        if n <= len(self.script):
            entry = self.script[n - 1]
            if isinstance(entry, str):
                return entry, self.delay
            return str(entry.get("text", "")), float(entry.get("delay", self.delay))
        if says(lower, "slow"):
            return f"mock reply {n}", SLOW_SECONDS
        if says(lower, "fast"):
            return f"mock reply {n}", 0.0
        return f"mock reply {n}", self.delay


def anthropic_user_text(body):
    for msg in reversed(body.get("messages") or []):
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            return content
        texts = [c.get("text", "") for c in content or [] if isinstance(c, dict) and c.get("type") == "text"]
        if texts:
            return texts[-1]
    return ""


def anthropic_last_user(body):
    """The last message, when it is the user's: all its text, and how many
    tool results it carries (Claude Code's answer to a tool call). The
    system messages Claude Code 2.1 puts after it are passed over."""
    for msg in reversed(body.get("messages") or []):
        if not isinstance(msg, dict) or msg.get("role") == "system":
            continue
        if msg.get("role") != "user":
            return "", 0
        content = msg.get("content")
        if isinstance(content, str):
            return content, 0
        blocks = [c for c in content or [] if isinstance(c, dict)]
        text = "\n".join(c.get("text", "") for c in blocks if c.get("type") == "text")
        return text, sum(1 for c in blocks if c.get("type") == "tool_result")
    return "", 0


def responses_last_user(body):
    """The input's last turn: the last user message's text, and how many
    function call outputs follow it (Codex's answer to a tool call)."""
    inp = body.get("input")
    if isinstance(inp, str):
        return inp, 0
    results = 0
    for item in reversed(inp or []):
        if not isinstance(item, dict):
            continue
        if item.get("type") == "function_call_output":
            results += 1
        elif item.get("role") == "user":
            texts = [c["text"] for c in item.get("content") or [] if isinstance(c, dict) and c.get("text")]
            return "\n".join(texts), results
    return "", results


def responses_user_text(body):
    inp = body.get("input")
    if isinstance(inp, str):
        return inp
    text = ""
    for item in inp or []:
        if isinstance(item, dict) and item.get("role") == "user":
            for c in item.get("content") or []:
                if isinstance(c, dict) and c.get("text"):
                    text = c["text"]
    return text


def words(text):
    parts = text.split(" ")
    return [w + (" " if i < len(parts) - 1 else "") for i, w in enumerate(parts)]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None  # set by serve()

    def log_message(self, *_):
        pass

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _not_found(self):
        self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "mock: no such endpoint"}})

    def _stream(self):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

    def _event(self, name, data):
        self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    def _body(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            return {}
        return body if isinstance(body, dict) else {}

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        self.state.record({"method": "GET", "path": path})
        if path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "mock-model", "object": "model"}], "models": []})
            return
        self._not_found()

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        body = self._body()
        if path.endswith("/v1/messages/count_tokens"):
            self.state.record({"method": "POST", "path": path, "model": body.get("model")})
            self._json(200, {"input_tokens": 42})
        elif path.endswith("/v1/messages"):
            self._messages(path, body)
        elif path.endswith("/v1/responses"):
            self._responses(path, body)
        else:
            self.state.record({"method": "POST", "path": path})
            self._not_found()

    # The Anthropic Messages API (exp.4).
    def _messages(self, path, body):
        text = anthropic_user_text(body)
        last_text, results = anthropic_last_user(body)
        calls = [] if results or is_helper(text) else tool_calls(last_text)
        rec = {"method": "POST", "path": path, "model": body.get("model"), "stream": body.get("stream"),
               "n_messages": len(body.get("messages") or []), "user_text": text,
               # Each message's role and block types, never their text.
               "shape": [[m.get("role"), "text" if isinstance(m.get("content"), str) else
                          [c.get("type") for c in m.get("content") or [] if isinstance(c, dict)]]
                         for m in body.get("messages") or [] if isinstance(m, dict)]}
        if calls:
            rec["tool_calls"] = [c["name"] for c in calls]
        if results:
            rec["tool_results"] = results
        self.state.record(rec)
        if results:
            # The tools ran: close the turn they belong to.
            reply, delay = f"mock: read {results} tool result(s)", self.state.delay
        else:
            reply, delay = self.state.reply(text)
        uses = [{"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:24], **c} for c in calls]
        stop = "tool_use" if uses else "end_turn"
        msg_id = "msg_" + uuid.uuid4().hex[:24]
        model = body.get("model") or "claude-mock"
        usage = {"input_tokens": 42, "output_tokens": 8, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        if not body.get("stream"):
            time.sleep(delay)
            self._json(200, {"id": msg_id, "type": "message", "role": "assistant", "model": model,
                             "content": [{"type": "text", "text": reply}, *uses], "stop_reason": stop,
                             "stop_sequence": None, "usage": usage})
            return
        self._stream()
        self._event("message_start", {"type": "message_start", "message": {
            "id": msg_id, "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None, "usage": {**usage, "output_tokens": 1}}})
        self._event("content_block_start", {"type": "content_block_start", "index": 0,
                                            "content_block": {"type": "text", "text": ""}})
        parts = words(reply)
        for w in parts:
            if delay:
                time.sleep(delay / len(parts))
                self._event("ping", {"type": "ping"})
            self._event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                                "delta": {"type": "text_delta", "text": w}})
        self._event("content_block_stop", {"type": "content_block_stop", "index": 0})
        for i, use in enumerate(uses, 1):
            self._event("content_block_start", {"type": "content_block_start", "index": i,
                                                "content_block": {**use, "input": {}}})
            self._event("content_block_delta", {"type": "content_block_delta", "index": i,
                                                "delta": {"type": "input_json_delta",
                                                          "partial_json": json.dumps(use["input"])}})
            self._event("content_block_stop", {"type": "content_block_stop", "index": i})
        self._event("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                      "usage": {"output_tokens": 8}})
        self._event("message_stop", {"type": "message_stop"})

    # The OpenAI Responses API (exp.3).
    def _responses(self, path, body):
        text = responses_user_text(body)
        last_text, results = responses_last_user(body)
        calls = [] if results or is_helper(text) else tool_calls(last_text)
        rec = {"method": "POST", "path": path, "model": body.get("model"), "stream": body.get("stream"),
               "user_text": text,
               # The tools Codex offers and its input items' types, never their text.
               "tools": [t.get("name") or t.get("type") for t in body.get("tools") or [] if isinstance(t, dict)],
               "shape": [i.get("type") or i.get("role") for i in body.get("input") or [] if isinstance(i, dict)]}
        if calls:
            rec["tool_calls"] = [c["name"] for c in calls]
        if results:
            rec["tool_results"] = results
        self.state.record(rec)
        if results:
            # The tools ran: close the turn they belong to.
            reply, delay = f"mock: read {results} tool result(s)", self.state.delay
        else:
            reply, delay = self.state.reply(text)
        rid = "resp_" + uuid.uuid4().hex[:24]
        item_id = "msg_" + uuid.uuid4().hex[:24]
        item = {"type": "message", "role": "assistant", "id": item_id, "status": "completed",
                "content": [{"type": "output_text", "text": reply, "annotations": []}]}
        fcalls = [{"type": "function_call", "id": "fc_" + uuid.uuid4().hex[:24], "call_id": "call_" + uuid.uuid4().hex[:24],
                   "name": c["name"], "arguments": json.dumps(c["input"]), "status": "completed"} for c in calls]
        usage = {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                 "output_tokens": 5, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 15}
        if not body.get("stream"):
            time.sleep(delay)
            self._json(200, {"id": rid, "object": "response", "status": "completed", "model": body.get("model"),
                             "output": [item, *fcalls], "usage": usage})
            return
        self._stream()
        self._event("response.created", {"type": "response.created", "response": {"id": rid}})
        self._event("response.output_item.added", {"type": "response.output_item.added", "output_index": 0,
                                                   "item": {**item, "content": [], "status": "in_progress"}})
        parts = words(reply)
        for w in parts:
            if delay:
                time.sleep(delay / len(parts))
            self._event("response.output_text.delta", {"type": "response.output_text.delta", "output_index": 0,
                                                       "content_index": 0, "item_id": item_id, "delta": w})
        self._event("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item})
        for i, fc in enumerate(fcalls, 1):
            self._event("response.output_item.added", {"type": "response.output_item.added", "output_index": i,
                                                       "item": {**fc, "arguments": "", "status": "in_progress"}})
            self._event("response.function_call_arguments.delta", {
                "type": "response.function_call_arguments.delta", "output_index": i, "item_id": fc["id"],
                "delta": fc["arguments"]})
            self._event("response.function_call_arguments.done", {
                "type": "response.function_call_arguments.done", "output_index": i, "item_id": fc["id"],
                "arguments": fc["arguments"]})
            self._event("response.output_item.done", {"type": "response.output_item.done", "output_index": i, "item": fc})
        self._event("response.completed", {"type": "response.completed", "response": {"id": rid, "usage": usage}})


def load_script(path):
    if not path:
        return []
    with open(path, encoding="utf-8") as fh:
        script = json.load(fh)
    if not isinstance(script, list) or not all(isinstance(e, (str, dict)) for e in script):
        raise ValueError(f"{path}: the script is a JSON list of strings or {{text, delay}} objects")
    return script


def serve(port, ready, log, script, delay):
    Handler.state = State(script, log, delay)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    if ready:
        info = {"port": server.server_address[1], "pid": os.getpid(), "url": f"http://127.0.0.1:{server.server_address[1]}"}
        tmp = ready + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(info, fh)
        os.replace(tmp, ready)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main(argv=None):
    p = argparse.ArgumentParser(description="Mock Anthropic Messages and OpenAI Responses APIs on 127.0.0.1.")
    p.add_argument("--port", type=int, default=0, help="the port; 0 (the default) takes a free one")
    p.add_argument("--ready", help="write {port, pid, url} here once listening")
    p.add_argument("--log", help="append one JSON line per request here (no headers)")
    p.add_argument("--script", help="a JSON list of replies, one per turn")
    p.add_argument("--reply-delay", type=float, default=REPLY_SECONDS,
                   help=f"seconds a reply takes (default {REPLY_SECONDS}); 'slow' takes {SLOW_SECONDS:g}, 'fast' none")
    args = p.parse_args(argv)
    if not 0 <= args.reply_delay <= 60:
        p.error("--reply-delay takes 0 to 60 seconds")
    try:
        script = load_script(args.script)
    except (OSError, ValueError) as e:
        print(f"mock_anthropic: {e}", file=sys.stderr)
        return 2
    serve(args.port, args.ready, args.log, script, args.reply_delay)
    return 0


if __name__ == "__main__":
    sys.exit(main())
