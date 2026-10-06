#!/usr/bin/env python3
"""Exercise concurrent task loops and persistence through real Bone 3 RPC.

Run: BONE_BIN=/path/to/bone3 python3 tests/task_loop_runtime_test.py
The test uses a local scripted Lua provider; no model/network calls are made.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not BINARY:
    raise SystemExit("set BONE_BIN to a Bone 3 executable")

CONFIG = r'''
bone.rpc.register("task_loop_test.run", function(args, ctx)
  local result, err = bone._run_tool("task_loop", args, ctx)
  if not result then error(err) end
  return result
end)
bone.provider.register("task_loop_test", { complete = function(req)
  -- Let the other session run while this provider waits.
  bone.sleep(20)
  local state = require("task_loop.state").load(req.session_id)
  local first = state.tasks[1]
  local own = first and first.text:sub(1, 1)
  local foreign = own == "A" and "B task" or "A task"
  local loop
  for _, message in ipairs(req.messages) do
    if message.role == "system" and message.content:find("Task loop:\n", 1, true) then
      loop = message.content
      assert(not loop:find(foreign, 1, true), "foreign checklist in context")
      for _, task in ipairs(state.tasks) do
        assert(loop:find(task.text, 1, true), "missing own checklist item")
      end
    end
  end
  if state.active then assert(loop, "active session missing loop context") end
  if req.messages[#req.messages].role ~= "tool" then
    return { content = "", tool_calls = {
      { id = "advance", name = "task_loop", arguments = { action = "advance" } }
    } }
  end
  return { content = "verified " .. req.session_id }
end })
bone.config.providers.test = { type = "task_loop_test", model = "local" }
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
        self.call("initialize", {"protocol_version": 0, "client_name": "task-loop-test"})

    def receive(self):
        message = self.incoming.get(timeout=10)
        assert message is not None, self.process.stderr.read()
        return message

    def call(self, method, params=None):
        self.serial += 1
        self.process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": self.serial, "method": method, "params": params or {},
        }) + "\n")
        self.process.stdin.flush()
        while True:
            message = self.receive()
            if message.get("id") == self.serial:
                assert "error" not in message, message
                return message["result"]
            self.events.append(message)

    def tool(self, session, action, **args):
        return self.call("lua/call", {
            "name": "task_loop_test.run", "session_id": session,
            "args": dict(args, action=action),
        })

    def close(self):
        if self.process.poll() is None:
            try:
                self.call("shutdown")
                self.process.wait(timeout=5)
            finally:
                if self.process.poll() is None:
                    self.process.kill()
                    self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()


with tempfile.TemporaryDirectory(prefix="bone-task-loop-test-") as raw:
    config = Path(raw)
    shutil.copytree(ROOT / "plugins/task_loop", config / "plugins/task_loop")
    (config / "core.lua").write_text(CONFIG)
    legacy = config / "state/shared/task_loop.json"
    legacy.parent.mkdir(parents=True)
    legacy.write_text(json.dumps({"active": True, "tasks": [{"text": "unowned legacy task"}]}))

    def state(session):
        key = hashlib.sha256(session.encode()).hexdigest()
        return json.loads((config / f"state/shared/task_loop.{key}.json").read_text())

    server = Server(config)
    try:
        a = server.call("session/create")["session_id"]
        b = server.call("session/create")["session_id"]
        assert server.tool(a, "status") == "no tasks"
        assert server.tool(b, "status") == "no tasks"
        server.tool(a, "write", tasks=["A task 1", "A task 2"])
        server.tool(b, "write", tasks=["B task 1", "B task 2"])
        server.call("turn/start", {"session_id": a, "text": "verify A"})
        server.call("turn/start", {"session_id": b, "text": "verify B"})

        def finished():
            return [ev for ev in server.events if ev.get("method") == "turn/finished"]

        while len(finished()) < 4:
            server.events.append(server.receive())
        assert all(ev["params"]["outcome"]["status"] == "completed" for ev in finished()), finished()
        for session in (a, b):
            assert sum(ev["params"]["session_id"] == session for ev in finished()) == 2
            assert all(t["done"] for t in state(session)["tasks"])
            assert not state(session)["active"]
        starts = [ev["params"] for ev in server.events if ev.get("method") == "turn/started"]
        followups = [ev for ev in starts if ev["text"].startswith("Continue the task loop")]
        assert sorted(ev["session_id"] for ev in followups) == sorted([a, b])

        # Stopping/clearing B cannot change A, and forks do not inherit tasks.
        server.tool(a, "write", tasks=["A saved for restart"])
        server.tool(a, "stop")
        server.tool(b, "clear")
        assert state(a)["tasks"][0]["text"] == "A saved for restart"
        assert not state(a)["active"]
        child = server.call("session/fork", {"session_id": a})["session_id"]
        assert server.tool(child, "status") == "no tasks"
    finally:
        server.close()

    server = Server(config)
    try:
        assert "A saved for restart" in server.tool(a, "status")
        assert server.tool(b, "status") == "no tasks"
        assert server.tool(child, "status") == "no tasks"
        assert not state(a)["active"]
        server.tool(a, "resume")
        assert state(a)["active"] and not state(b)["active"]
        assert json.loads(legacy.read_text())["tasks"][0]["text"] == "unowned legacy task"
    finally:
        server.close()

print("task_loop: real concurrent turns, isolated context/continuations, forks and restart passed")
