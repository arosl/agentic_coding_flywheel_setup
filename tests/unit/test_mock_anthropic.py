"""tests/vm/lib/mock_anthropic.py (acfs-9hkh.31.1): the mock answers the
Anthropic Messages and OpenAI Responses APIs in the shapes Claude Code and
Codex read, plays its script in order, listens on 127.0.0.1 only, and never
logs a key.

Usage: python3 -m unittest tests/unit/test_mock_anthropic.py
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

MOCK = Path(__file__).resolve().parents[1] / "vm" / "lib" / "mock_anthropic.py"
KEY = "sk-" + "ant-" + "not-a-real-key-0123456789"


class Mock:
    """The mock in a subprocess, on a free port, with a ready file."""

    def __init__(self, script=None):
        self.dir = tempfile.TemporaryDirectory(prefix="acfs-mock-anthropic.")
        d = Path(self.dir.name)
        self.ready, self.log = d / "ready.json", d / "requests.jsonl"
        args = [sys.executable, "-I", str(MOCK), "--ready", str(self.ready), "--log", str(self.log)]
        if script is not None:
            (d / "script.json").write_text(json.dumps(script), encoding="utf-8")
            args += ["--script", str(d / "script.json")]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            if self.ready.exists():
                break
            time.sleep(0.05)
        info = json.loads(self.ready.read_text(encoding="utf-8"))
        self.url, self.pid = info["url"], info["pid"]

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)
        self.proc.stderr.close()
        self.dir.cleanup()

    def post(self, path, body, headers=None):
        req = urllib.request.Request(self.url + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"content-type": "application/json", **(headers or {})})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.headers.get("content-type"), resp.read().decode()

    def records(self):
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]


def events(sse):
    out = []
    for block in sse.strip().split("\n\n"):
        lines = dict(line.split(": ", 1) for line in block.splitlines())
        out.append((lines["event"], json.loads(lines["data"])))
    return out


def user(text):
    return {"model": "claude-opus-5-5", "max_tokens": 64, "messages": [{"role": "user", "content": text}]}


class MessagesAPI(unittest.TestCase):
    def setUp(self):
        self.mock = Mock()
        self.addCleanup(self.mock.close)

    def test_ready_file_and_loopback(self):
        self.assertTrue(self.mock.url.startswith("http://127.0.0.1:"))
        self.assertEqual(self.mock.pid, self.mock.proc.pid)

    def test_non_streamed(self):
        ctype, body = self.mock.post("/v1/messages", user("hello"))
        msg = json.loads(body)
        self.assertEqual(ctype, "application/json")
        self.assertEqual((msg["type"], msg["role"], msg["stop_reason"]), ("message", "assistant", "end_turn"))
        self.assertEqual(msg["content"], [{"type": "text", "text": "mock reply 1"}])

    def test_streamed_event_order(self):
        ctype, body = self.mock.post("/v1/messages?beta=true", {**user("hello"), "stream": True})
        names = [name for name, _ in events(body)]
        self.assertEqual(ctype, "text/event-stream")
        self.assertEqual(names[:2], ["message_start", "content_block_start"])
        self.assertEqual(names[-3:], ["content_block_stop", "message_delta", "message_stop"])
        text = "".join(d["delta"]["text"] for n, d in events(body) if n == "content_block_delta")
        self.assertEqual(text, "mock reply 1")

    def test_count_tokens_and_summary(self):
        _, body = self.mock.post("/v1/messages/count_tokens", user("hello"))
        self.assertEqual(json.loads(body), {"input_tokens": 42})
        # Claude Code's compaction wording (acfs-t9w9); a prompt that only
        # asks for a summary is an ordinary turn.
        _, body = self.mock.post("/v1/messages", user("Your task is to create a detailed summary of the conversation so far."))
        self.assertIn("<summary>", json.loads(body)["content"][0]["text"])
        _, body = self.mock.post("/v1/messages", user("Please summarize the conversation"))
        self.assertEqual(json.loads(body)["content"][0]["text"], "mock reply 1")

    def test_unknown_path_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.mock.post("/v1/complete", user("x"))
        e.exception.close()
        self.assertEqual(e.exception.code, 404)

    def test_log_has_no_key(self):
        self.mock.post("/v1/messages", user("hello"), headers={"x-api-key": KEY, "authorization": "Bearer " + KEY})
        log = self.mock.log.read_text(encoding="utf-8")
        self.assertNotIn("not-a-real-key", log)
        rec = self.mock.records()[-1]
        self.assertEqual((rec["path"], rec["model"], rec["user_text"]), ("/v1/messages", "claude-opus-5-5", "hello"))


class ToolCalls(unittest.TestCase):
    """A 'mock-tool:' prompt line makes the reply a tool call (acfs-9hkh.94)."""

    WRITE = {"name": "Write", "input": {"file_path": "/tmp/x.md", "content": "hi"}}

    def setUp(self):
        self.mock = Mock()
        self.addCleanup(self.mock.close)

    def prompt(self, *lines):
        return "Do the step.\n" + "\n".join("mock-tool: " + json.dumps(c) for c in lines)

    def test_a_tool_line_streams_a_tool_use(self):
        _, body = self.mock.post("/v1/messages", {**user(self.prompt(self.WRITE)), "stream": True})
        evs = events(body)
        starts = [d for n, d in evs if n == "content_block_start"]
        self.assertEqual([s["content_block"]["type"] for s in starts], ["text", "tool_use"])
        use = starts[1]["content_block"]
        self.assertEqual((use["name"], use["input"], starts[1]["index"]), ("Write", {}, 1))
        self.assertTrue(use["id"].startswith("toolu_"))
        partial = [d["delta"]["partial_json"] for n, d in evs
                   if n == "content_block_delta" and d["delta"]["type"] == "input_json_delta"]
        self.assertEqual([json.loads(p) for p in partial], [self.WRITE["input"]])
        stop = [d["delta"]["stop_reason"] for n, d in evs if n == "message_delta"]
        self.assertEqual(stop, ["tool_use"])
        self.assertEqual(self.mock.records()[-1]["tool_calls"], ["Write"])

    def test_non_streamed_and_two_calls(self):
        bash = {"name": "Bash", "input": {"command": "true", "description": "nothing"}}
        _, body = self.mock.post("/v1/messages", user(self.prompt(self.WRITE, bash)))
        msg = json.loads(body)
        self.assertEqual(msg["stop_reason"], "tool_use")
        self.assertEqual([(c["type"], c.get("name")) for c in msg["content"]],
                         [("text", None), ("tool_use", "Write"), ("tool_use", "Bash")])

    def test_the_tool_results_close_the_turn_and_take_none(self):
        _, body = self.mock.post("/v1/messages", user(self.prompt(self.WRITE)))
        use = json.loads(body)["content"][1]
        follow = {"model": "claude-opus-5-5", "max_tokens": 64, "messages": [
            {"role": "user", "content": self.prompt(self.WRITE)},
            {"role": "assistant", "content": [use]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": use["id"], "content": "ok"},
                                         {"type": "text", "text": "<system-reminder>x</system-reminder>"}]}]}
        _, body = self.mock.post("/v1/messages", follow)
        msg = json.loads(body)
        self.assertEqual((msg["stop_reason"], msg["content"]),
                         ("end_turn", [{"type": "text", "text": "mock: read 1 tool result(s)"}]))
        self.assertEqual(self.mock.records()[-1]["tool_results"], 1)
        _, body = self.mock.post("/v1/messages", user("next"))
        self.assertEqual(json.loads(body)["content"][0]["text"], "mock reply 2")

    def test_claude_codes_trailing_system_message_is_passed_over(self):
        # Claude Code 2.1.309 sends a system message after the user's.
        sysmsg = {"role": "system", "content": [{"type": "text", "text": "reminder"}]}
        body = user(self.prompt(self.WRITE))
        body["messages"].append(sysmsg)
        _, out = self.mock.post("/v1/messages", body)
        use = json.loads(out)["content"][1]
        self.assertEqual(use["name"], "Write")
        follow = {**body, "messages": body["messages"] + [
            {"role": "assistant", "content": [use]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": use["id"], "content": "ok"}]},
            sysmsg]}
        _, out = self.mock.post("/v1/messages", follow)
        self.assertEqual(json.loads(out)["stop_reason"], "end_turn")
        self.assertEqual(self.mock.records()[-1]["shape"][-3:],
                         [["assistant", ["tool_use"]], ["user", ["tool_result"]], ["system", ["text"]]])

    def test_the_shell_alias_is_claude_codes_bash(self):
        _, body = self.mock.post("/v1/messages", user(self.prompt({"name": "shell", "input": {"cmd": "true"}},
                                                                  {"name": "shell", "input": {"no": "cmd"}})))
        uses = [c for c in json.loads(body)["content"] if c["type"] == "tool_use"]
        self.assertEqual([(u["name"], u["input"]["command"]) for u in uses], [("Bash", "true")])

    def test_a_context_line_reports_a_full_context(self):
        body = {**user("Do the step.\nmock-context: 990000\nmock-tool: " + json.dumps(self.WRITE)), "stream": True}
        _, out = self.mock.post("/v1/messages", body)
        evs = events(out)
        start = [d["message"]["usage"]["input_tokens"] for n, d in evs if n == "message_start"]
        delta = [d["usage"]["input_tokens"] for n, d in evs if n == "message_delta"]
        self.assertEqual((start, delta), ([990000], [990000]))
        self.assertEqual(self.mock.records()[-1]["context_tokens"], 990000)
        _, out = self.mock.post("/v1/messages", {**user("next"), "stream": True})
        start = [d["message"]["usage"]["input_tokens"] for n, d in events(out) if n == "message_start"]
        self.assertEqual(start, [42])

    def test_a_compaction_mid_turn_is_answered_as_a_compaction(self):
        # Claude Code 2.1.309 compacts between a tool call and its result:
        # the last user message carries the result and the compaction text.
        _, body = self.mock.post("/v1/messages", user(self.prompt(self.WRITE)))
        use = json.loads(body)["content"][1]
        compact = {"model": "claude-opus-5-5", "max_tokens": 64, "messages": [
            {"role": "user", "content": self.prompt(self.WRITE)},
            {"role": "assistant", "content": [use]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": use["id"], "content": "ok"},
                {"type": "text", "text": "CRITICAL: Respond with TEXT ONLY.\n\nYour task is to create a detailed "
                                         "summary of the conversation so far. mock-context: 990000"}]}]}
        _, body = self.mock.post("/v1/messages", compact)
        msg = json.loads(body)
        self.assertIn("<summary>", msg["content"][0]["text"])
        self.assertEqual((msg["stop_reason"], msg["usage"]["input_tokens"]), ("end_turn", 42))

    def test_a_quoted_tool_line_is_no_call(self):
        quoted = "CASS: earlier sessions:\n- [s.jsonl:1] (claude) mock-tool: " + json.dumps(self.WRITE)
        _, body = self.mock.post("/v1/messages", user(quoted))
        msg = json.loads(body)
        self.assertEqual((msg["stop_reason"], len(msg["content"])), ("end_turn", 1))

    def test_a_helper_request_never_calls_a_tool(self):
        title = "Generate a concise, single-line task title of at most 36 characters.\n\nUser prompt:\n"
        _, body = self.mock.post("/v1/messages", user(title + self.prompt(self.WRITE)))
        msg = json.loads(body)
        self.assertEqual((msg["stop_reason"], msg["content"][0]["text"]), ("end_turn", "Mock task"))


class ResponsesAPI(unittest.TestCase):
    def setUp(self):
        self.mock = Mock()
        self.addCleanup(self.mock.close)

    def body(self, text, stream):
        return {"model": "gpt-mock", "stream": stream,
                "input": [{"role": "user", "content": [{"type": "input_text", "text": text}]}]}

    def test_streamed(self):
        ctype, body = self.mock.post("/v1/responses", self.body("hello one", True))
        evs = events(body)
        self.assertEqual(ctype, "text/event-stream")
        self.assertEqual(evs[0][0], "response.created")
        self.assertEqual(evs[-1][0], "response.completed")
        done = [d for n, d in evs if n == "response.output_item.done"][0]
        self.assertEqual(done["item"]["content"][0], {"type": "output_text", "text": "mock reply 1", "annotations": []})

    def test_non_streamed_and_models(self):
        _, body = self.mock.post("/v1/responses", self.body("hello", False))
        resp = json.loads(body)
        self.assertEqual((resp["object"], resp["status"]), ("response", "completed"))
        with urllib.request.urlopen(self.mock.url + "/v1/models", timeout=10) as r:
            self.assertEqual(json.loads(r.read())["data"][0]["id"], "mock-model")

    def test_a_tool_line_is_a_function_call(self):
        call = {"name": "exec_command", "input": {"cmd": "true"}}
        _, body = self.mock.post("/v1/responses", self.body("Run it.\nmock-tool: " + json.dumps(call), True))
        evs = events(body)
        done = [d["item"] for n, d in evs if n == "response.output_item.done"]
        self.assertEqual([i["type"] for i in done], ["message", "function_call"])
        fc = done[1]
        self.assertEqual((fc["name"], json.loads(fc["arguments"])), ("exec_command", {"cmd": "true"}))
        self.assertTrue(fc["call_id"].startswith("call_"))
        args = [d["arguments"] for n, d in evs if n == "response.function_call_arguments.done"]
        self.assertEqual(args, [fc["arguments"]])
        self.assertEqual(self.mock.records()[-1]["tool_calls"], ["exec_command"])
        # Codex sends the call and its output back after the user's message.
        follow = self.body("Run it.\nmock-tool: " + json.dumps(call), False)
        follow["input"] += [fc, {"type": "function_call_output", "call_id": fc["call_id"], "output": "ok"}]
        _, body = self.mock.post("/v1/responses", follow)
        out = json.loads(body)["output"]
        self.assertEqual([i["type"] for i in out], ["message"])
        self.assertEqual(out[0]["content"][0]["text"], "mock: read 1 tool result(s)")
        self.assertEqual(self.mock.records()[-1]["tool_results"], 1)
        _, body = self.mock.post("/v1/responses", self.body("next", False))
        self.assertEqual(json.loads(body)["output"][0]["content"][0]["text"], "mock reply 2")

    def test_the_shell_alias_is_codexs_exec_command(self):
        call = {"name": "shell", "input": {"cmd": "true"}}
        _, body = self.mock.post("/v1/responses", self.body("mock-tool: " + json.dumps(call), False))
        fc = json.loads(body)["output"][1]
        self.assertEqual((fc["name"], json.loads(fc["arguments"])), ("exec_command", {"cmd": "true"}))

    def test_title_helper_takes_no_turn(self):
        self.mock.post("/v1/responses", self.body("Generate a concise, single-line task title of at most 36 characters", False))
        _, body = self.mock.post("/v1/responses", self.body("work", False))
        self.assertEqual(json.loads(body)["output"][0]["content"][0]["text"], "mock reply 1")


class Script(unittest.TestCase):
    def test_turns_in_order_then_default(self):
        mock = Mock(script=["first", {"text": "second, slowly", "delay": 0.2}])
        self.addCleanup(mock.close)
        texts = []
        start = time.monotonic()
        for _ in range(3):
            _, body = mock.post("/v1/messages", user("go"))
            texts.append(json.loads(body)["content"][0]["text"])
        self.assertEqual(texts, ["first", "second, slowly", "mock reply 3"])
        self.assertGreaterEqual(time.monotonic() - start, 0.2)

    def test_a_bad_script_refuses_to_start(self):
        with tempfile.TemporaryDirectory() as d:
            bad = Path(d) / "s.json"
            bad.write_text('{"not": "a list"}', encoding="utf-8")
            res = subprocess.run([sys.executable, "-I", str(MOCK), "--script", str(bad)], capture_output=True, text=True,
                                 timeout=10)
        self.assertEqual(res.returncode, 2)
        self.assertIn("JSON list", res.stderr)


if __name__ == "__main__":
    unittest.main()
