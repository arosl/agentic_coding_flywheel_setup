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
        _, body = self.mock.post("/v1/messages", user("Please summarize the conversation"))
        self.assertIn("<summary>", json.loads(body)["content"][0]["text"])

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
