#!/usr/bin/env python3
"""Exercise `todo` through real Bone 3 RPC.

Run: BONE_BIN=/path/to/bone3 python3 tests/todo_runtime_test.py
A local scripted Lua provider stands in for the model. Only chat history is
persisted, and no network calls are made.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not BINARY:
    raise SystemExit("set BONE_BIN to a Bone 3 executable")

CONFIG = r'''
bone.provider.register("todo_test", { complete = function(req)
  local last = req.messages[#req.messages]
  if last.role == "tool" then return { content = "turn done for " .. req.session_id } end
  return { content = "", tool_calls = { { id = "todo_1", name = "todo", arguments = {
    title = "Checklist for " .. req.session_id,
    items = { { text = "step for " .. req.session_id, status = "in_progress" } } } } } }
end })
bone.config.providers.test = { type = "todo_test", model = "local" }
bone.config.provider = "test"
'''


class Server:
    def __init__(self, config: Path):
        self.process = subprocess.Popen(
            [BINARY, "--headless"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            env=dict(os.environ, BONE_CONFIG_DIR=str(config)),
        )
        self.incoming: queue.Queue = queue.Queue()
        self.events: list[dict] = []
        self.serial = 0

        def read():
            for line in self.process.stdout:
                self.incoming.put(json.loads(line))
            self.incoming.put(None)

        threading.Thread(target=read, daemon=True).start()
        self.call("initialize", {"protocol_version": 0, "client_name": "todo-test"})

    def receive(self, timeout=15):
        message = self.incoming.get(timeout=timeout)
        assert message is not None, self.process.stderr.read()
        return message

    def try_call(self, method, params=None):
        self.serial += 1
        self.process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": self.serial, "method": method, "params": params or {},
        }) + "\n")
        self.process.stdin.flush()
        while True:
            message = self.receive()
            if message.get("id") == self.serial:
                return message.get("result"), message.get("error")
            self.events.append(message)

    def call(self, method, params=None):
        result, error = self.try_call(method, params)
        assert not error, error
        return result

    def drain(self, seconds: float):
        """Collect events until the server has been quiet for `seconds`."""
        while True:
            try:
                self.events.append(self.receive(seconds))
            except queue.Empty:
                return

    def turns(self, session):
        started = [e["params"] for e in self.events if e.get("method") == "turn/started"]
        return [p for p in started if p["session_id"] == session]

    def finished(self, session):
        return [e for e in self.events
                if e.get("method") == "turn/finished" and e["params"]["session_id"] == session]

    def wait(self, predicate, what, timeout=15.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            self.drain(0.05)
        seen = [e.get("method") for e in self.events]
        raise AssertionError(f"timed out waiting for {what}; saw {seen}")

    def close(self):
        if self.process.poll() is None:
            try:
                self.call("shutdown")
                self.process.wait(timeout=5)
            finally:
                if self.process.poll() is None:
                    self.process.kill()
                    self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def messages(server, session):
    return server.call("session/messages", {"session_id": session})["messages"]


def calls(msg_list, name):
    """Tool calls by name, with `arguments` parsed from its JSON string."""
    out = []
    for m in msg_list:
        for c in m.get("tool_calls") or []:
            if c["name"] != name:
                continue
            args = c.get("arguments")
            out.append(json.loads(args) if isinstance(args, str) else (args or {}))
    return out


with tempfile.TemporaryDirectory(prefix="bone-todo-test-") as raw:
    config = Path(raw)
    shutil.copytree(ROOT / "plugins" / "todo", config / "plugins" / "todo")
    (config / "core.lua").write_text(CONFIG)

    server = Server(config)
    try:
        a = server.call("session/create")["session_id"]
        b = server.call("session/create")["session_id"]
        histories = {}
        for session in (a, b):
            text = "keep a checklist for " + session
            server.call("turn/start", {"session_id": session, "text": text})
            server.wait(lambda: server.finished(session), "the checklist turn to finish")
            assert len(server.turns(session)) == 1, server.turns(session)
            assert server.turns(session)[0]["text"] == text
            history = messages(server, session)
            assert calls(history, "todo") == [{
                "title": "Checklist for " + session,
                "items": [{"text": "step for " + session, "status": "in_progress"}],
            }], history
            assert any(m["role"] == "user" and m["content"] == text for m in history), history
            results = [m for m in history if m["role"] == "tool"]
            assert len(results) == 1 and results[0]["call_id"] == "todo_1", results
            assert not results[0].get("is_error", False), results
            assert results[0]["content"] == "[>] step for " + session, results
            assert history[-1]["role"] == "assistant"
            assert history[-1]["content"] == "turn done for " + session, history
            histories[session] = history

        # Both the calls and their results stay in the chat that made them.
        assert b not in json.dumps(histories[a]) and a not in json.dumps(histories[b])
        server.drain(0.3)
        assert len(server.turns(a)) == len(server.turns(b)) == 1
        assert messages(server, a) == histories[a]
        assert messages(server, b) == histories[b]
        assert not (config / "state").exists() or not list((config / "state").rglob("*.json")), \
            list((config / "state").rglob("*.json"))
    finally:
        server.close()

    # The drawer can reconstruct each checklist from persisted chat history.
    server = Server(config)
    try:
        for session in (a, b):
            assert messages(server, session) == histories[session]
            assert not server.turns(session), "restart unexpectedly started a turn"
        assert not (config / "state").exists() or not list((config / "state").rglob("*.json")), \
            list((config / "state").rglob("*.json"))
    finally:
        server.close()

print("todo: real turns, tool results, per-chat isolation, no state files and persisted history passed")
