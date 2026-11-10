#!/usr/bin/env python3
"""Exercise the `mcp` core half through real Bone 3 RPC.

Run: BONE_BIN=/path/to/bone3 python3 tests/mcp_runtime_test.py
A small stdio MCP server (written to the temporary config directory) and a
scripted Lua provider stand in for the outside world; no network calls.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not BINARY:
    raise SystemExit("set BONE_BIN to a Bone 3 executable")

# Enough description that the definitions pass the 2000-token default.
FAKE_SERVER = r'''
import json, sys

LONG = "This tool does one small thing and says so at length. " * 12
def tool(name, props, required=(), extra=None, read_only=False):
    schema = {"type": "object", "properties": props, "required": list(required)}
    schema.update(extra or {})
    t = {"name": name, "description": name + ": " + LONG, "inputSchema": schema}
    if read_only:
        t["annotations"] = {"readOnlyHint": True}
    return t

TOOLS = [
    tool("echo", {"text": {"type": "string"}}, ["text"], read_only=True),
    tool("add", {"a": {"type": "integer"}, "b": {"type": "integer"}}, ["a", "b"], {"additionalProperties": False}),
    tool("big", {}),
    tool("fail", {}),
    tool("hidden", {}),
    tool("create_issue", {"title": {"type": "string"}, "labels": {"type": "array"}}, ["title"]),
    tool("list_issues", {"state": {"type": "string", "enum": ["open", "closed"]}}),
] + [tool("filler_%d" % i, {"x": {"type": "string"}}) for i in range(8)]

def result(name, args):
    if name == "echo":
        return {"content": [{"type": "text", "text": "echo: " + str(args.get("text"))}]}
    if name == "add":
        return {"content": [{"type": "text", "text": str(args["a"] + args["b"])}]}
    if name == "big":
        return {"content": [{"type": "text", "text": "START" + "é" * 60000 + "END"}]}
    if name == "fail":
        return {"content": [{"type": "text", "text": "boom"}], "isError": True}
    return {"content": [{"type": "text", "text": name + " ran with " + json.dumps(args, sort_keys=True)}]}

for line in sys.stdin:
    msg = json.loads(line)
    method, id = msg.get("method"), msg.get("id")
    if id is None:
        continue
    if method == "initialize":
        out = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif method == "tools/list":
        out = {"tools": TOOLS}
    elif method == "tools/call":
        out = result(msg["params"]["name"], msg["params"].get("arguments") or {})
    else:
        out = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": id, "result": out}) + "\n")
    sys.stdout.flush()
'''

# The user's text is the tool call to make; the reply after a result ends the
# turn. Each request's tool list is kept for the test to read.
CONFIG = r'''
local requests = {}
bone.provider.register("mcp_test", { complete = function(req)
  local names, search, empty = {}, nil, 0
  for _, t in ipairs(req.tools or {}) do
    names[#names + 1] = t.name
    if t.name == "mcp_search" then search = t.description end
    -- A list that lost its items on the way would be sent as an object,
    -- unless the core marked it as a list.
    local required = t.parameters and t.parameters.required
    if type(required) == "table" and next(required) == nil and getmetatable(required) == nil then empty = empty + 1 end
  end
  requests[#requests + 1] = { tools = names, search = search, empty = empty }
  local last = req.messages[#req.messages]
  if last.role == "tool" then return { content = "done" } end
  local call = bone.json.decode(last.content)
  return { content = "", tool_calls = { { id = "call_" .. #requests, name = call.name, arguments = call.arguments or {} } } }
end })
bone.rpc.register("test.requests", function() return requests end)
-- What this core can do: start a server when a plugin says, keep empty lists.
bone.rpc.register("test.core", function()
  return { start = bone.mcp.start ~= nil, lists = bone.json.encode(bone.json.decode("[]")) == "[]" }
end)
bone.config.providers.test = { type = "mcp_test", model = "local" }
bone.config.provider = "test"
'''


class Server:
    def __init__(self, config: Path):
        self.process = subprocess.Popen(
            [BINARY, "--headless"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            env=dict(os.environ, BONE_CONFIG_DIR=str(config), TMPDIR=str(config / "tmp")),
        )
        self.incoming: queue.Queue = queue.Queue()
        self.events: list[dict] = []
        self.serial = 0

        def read():
            for line in self.process.stdout:
                self.incoming.put(json.loads(line))
            self.incoming.put(None)

        threading.Thread(target=read, daemon=True).start()
        self.call("initialize", {"protocol_version": 0, "client_name": "mcp-test"})

    def receive(self, timeout=20):
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

    def lua(self, name, args=None):
        return self.call("lua/call", {"name": name, "args": args or {}})

    def drain(self, seconds: float):
        while True:
            try:
                self.events.append(self.receive(seconds))
            except queue.Empty:
                return

    def wait(self, predicate, what, timeout=20.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            self.drain(0.05)
        raise AssertionError(f"timed out waiting for {what}; saw {[e.get('method') for e in self.events]}")

    def run(self, name, arguments, session=None):
        """One turn in which the model calls `name`: (result text, is_error, session)."""
        session = session or self.call("session/create")["session_id"]
        before = len([e for e in self.events if e.get("method") == "turn/finished"
                      and e["params"]["session_id"] == session])
        self.call("turn/start", {"session_id": session, "text": json.dumps({"name": name, "arguments": arguments})})
        self.wait(lambda: len([e for e in self.events if e.get("method") == "turn/finished"
                               and e["params"]["session_id"] == session]) > before, "the turn to finish")
        history = self.call("session/messages", {"session_id": session})["messages"]
        results = [m for m in history if m["role"] == "tool"]
        assert results, history
        return results[-1]["content"], bool(results[-1].get("is_error")), session

    def last_request(self):
        return self.lua("test.requests")[-1]

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


def fake_names(request):
    return sorted(n for n in request["tools"] if n.startswith("fake_"))


with tempfile.TemporaryDirectory(prefix="bone-mcp-test-") as raw:
    config = Path(raw)
    (config / "tmp").mkdir()
    shutil.copytree(ROOT / "plugins" / "mcp", config / "plugins" / "mcp")
    (config / "fake_server.py").write_text(FAKE_SERVER)
    (config / "core.lua").write_text(CONFIG)
    (config / "mcp.json").write_text(json.dumps({"mcpServers": {
        # Its own options are honored, and a bad entry does not take the file down.
        "fake": {"command": sys.executable, "args": [str(config / "fake_server.py")],
                 "tools": {"deny": ["hidden"]}, "timeout": 5000},
        "bad name!": {"command": "true"},
        "off": {"command": "true", "disabled": True},
    }}))

    server = Server(config)
    try:
        listed = server.call("mcp/list")
        assert [s["name"] for s in listed] == ["fake"], listed
        core = server.lua("test.core")
        health = {h["name"]: h for h in server.call("health/check")}
        assert health["mcp tools"]["status"] == "warn" and "bad name!" in health["mcp tools"]["message"], health

        # On demand by default: the definitions are large, so the model gets
        # the two tools and an index of names in their place.
        text, failed, first = server.run("mcp_search", {"query": "add numbers"})
        assert not failed, text
        request = server.last_request()
        assert fake_names(request) == [], request
        assert "mcp_search" in request["tools"] and "mcp_call" in request["tools"], request
        assert "- fake: add, big, create_issue, echo, fail, filler_0" in request["search"], request["search"]
        assert "hidden" not in request["search"], request["search"]
        assert text.startswith("[fake] add\nadd: This tool does"), text
        assert '"required":["a","b"]' in text.replace(" ", "") and "mcp_call" in text, text

        # Names give exactly those tools; words rank; nothing lists everything.
        text, failed, _ = server.run("mcp_search", {"query": "fake/echo, create_issue"})
        assert not failed and text.count("arguments: {") == 2 and "[fake] echo" in text and "[fake] create_issue" in text, text
        text, _, _ = server.run("mcp_search", {"query": "issues", "limit": 1})
        assert text.startswith("[fake] create_issue") and "Also matching:\n- [fake] list_issues" in text, text
        text, _, _ = server.run("mcp_search", {"query": ""})
        assert text.count("\n- [fake] ") + 1 == 14 and "hidden" not in text, text
        # An empty `required` does not come out as an object: it stays a
        # list, or is dropped by a core that cannot tell the two apart.
        text, _, _ = server.run("mcp_search", {"query": "big"})
        schema = {"type": "object", "properties": {}, **({"required": []} if core["lists"] else {})}
        assert json.loads(text.split("arguments: ")[1].split("\n")[0]) == schema, text
        text, _, _ = server.run("mcp_search", {"query": "zzzz"})
        assert text.startswith('No MCP tool matches "zzzz". Servers: fake (14 tools)'), text

        # Calls: as asked, by another spelling, and with the arguments beside the name.
        assert server.run("mcp_call", {"server": "fake", "tool": "add", "arguments": {"a": 2, "b": 3}}, first)[:2] == ("5", False)
        assert server.run("mcp_call", {"tool": "fake_echo", "arguments": {"text": "hi"}})[:2] == ("echo: hi", False)
        assert server.run("mcp_call", {"server": "fake", "tool": "echo", "text": "flat"})[:2] == ("echo: flat", False)
        assert server.run("mcp_call", {"server": "fake", "tool": "filler_1"})[0] == "filler_1 ran with {}"
        # Nor does an empty list among the arguments: it arrives as one, or
        # is left out by a core that cannot tell it from an empty object.
        text, _, _ = server.run("mcp_call", {"server": "fake", "tool": "create_issue",
                                              "arguments": {"title": "x", "labels": []}})
        sent = '{"labels": [], "title": "x"}' if core["lists"] else '{"title": "x"}'
        assert text == "create_issue ran with " + sent, text
        text, _, _ = server.run("mcp_call", {"server": "fake", "tool": "create_issue",
                                              "arguments": json.dumps({"title": "x", "labels": []})})
        assert text == "create_issue ran with " + sent, text

        # A wrong call says what is wrong, with the schema the first time only.
        text, failed, session = server.run("mcp_call", {"server": "fake", "tool": "add", "arguments": {"a": 2}})
        assert failed and text.startswith("[fake] add: missing argument b\n\n[fake] add takes: {"), text
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "add", "arguments": {"a": "2", "b": 3}}, session)
        assert failed and text == "[fake] add: argument a must be integer, not string", text
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "add", "arguments": {"a": 1, "b": 2, "c": 3}}, session)
        assert failed and text == "[fake] add: unknown argument c (it takes: a, b)", text
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "fail"})
        assert failed and text.startswith("boom\n\n[fake] fail takes: {"), text
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "ad"})
        assert failed and text.startswith("No MCP tool named ad on fake. Close: [fake] add"), text
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "hidden"})
        assert failed and text.startswith("No MCP tool named hidden"), text

        # A long result: its ends, cut on whole characters, the rest in a file.
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "big"})
        assert not failed and text.startswith("START") and text.endswith("END"), text[:80]
        assert len(text.encode()) < 41000 and "the output is 120008 bytes" in text, len(text.encode())
        spilled = list((config / "tmp").glob("bone-mcp-*.txt"))
        assert len(spilled) == 1 and str(spilled[0]) in text, spilled
        assert spilled[0].read_text() == "START" + "é" * 60000 + "END"

        # /mcp reads sizes and states, and sets them: a pinned tool keeps its
        # own definition, one turned off reaches the model in no form.
        info = server.lua("mcp.info")
        assert info["mode"] == "auto" and info["on_demand"] is True and info["above"] == 2000, info
        assert info["tokens"] > 2000 and info["sent"] < info["tokens"] / 3, info
        tools = {t["name"]: t for t in info["servers"]["fake"]["tools"]}
        assert len(tools) == 14 and tools["echo"]["read_only"] is True and tools["echo"]["state"] == "on", tools
        assert tools["add"]["args"] == [{"name": "a", "type": "integer", "required": True},
                                        {"name": "b", "type": "integer", "required": True}], tools["add"]
        assert tools["list_issues"]["args"] == [{"name": "state", "type": "one of 2"}], tools["list_issues"]
        server.lua("mcp.set", {"server": "fake", "tool": "echo", "state": "pin"})
        info = server.lua("mcp.set", {"server": "fake", "tool": "big", "state": "off"})
        states = {t["name"]: t["state"] for t in info["servers"]["fake"]["tools"]}
        assert states["echo"] == "pin" and states["big"] == "off" and states["add"] == "on", states
        text, failed, _ = server.run("fake_echo", {"text": "pinned"})
        assert (text, failed) == ("echo: pinned", False)
        request = server.last_request()
        assert fake_names(request) == ["fake_echo"] and "mcp_call" in request["tools"], request
        assert "- fake: add, create_issue, fail, filler_0" in request["search"], request["search"]
        text, failed, _ = server.run("mcp_call", {"server": "fake", "tool": "big"})
        assert failed and text == "big is turned off for the fake server (the user can turn it on in /mcp).", text
        text, failed, _ = server.run("fake_big", {})
        assert failed and text == "big is turned off for the fake server (the user can turn it on in /mcp).", text
        text, _, _ = server.run("mcp_search", {"query": "echo"})
        assert "(already loaded: call it as fake_echo)" in text, text

        # Off: every definition is sent as before, and long results are still cut.
        server.lua("mcp.set", {"server": "fake", "tool": "big", "state": "on"})
        server.call("settings/set", {"path": "mcp.on_demand", "value": "off"})
        text, failed, _ = server.run("fake_big", {})
        assert not failed and "the output is 120008 bytes" in text and text.endswith("END"), text[-200:]
        request = server.last_request()
        assert len(fake_names(request)) == 14 and "fake_hidden" not in request["tools"], request
        assert request["empty"] == 0, request
        assert "mcp_search" not in request["tools"] and "mcp_call" not in request["tools"], request
        assert server.lua("mcp.info")["on_demand"] is False

        # Auto under the limit loads everything; on does not ask the size.
        server.call("settings/set", {"path": "mcp.on_demand", "value": "auto"})
        server.call("settings/set", {"path": "mcp.on_demand_above", "value": 100000})
        server.run("fake_echo", {"text": "x"})
        assert len(fake_names(server.last_request())) == 14, server.last_request()
        server.call("settings/set", {"path": "mcp.on_demand", "value": "on"})
        server.run("mcp_search", {"query": "echo"})
        assert fake_names(server.last_request()) == ["fake_echo"], server.last_request()
    finally:
        server.close()

    # What was learned and set outlasts the core: the index is there before
    # the server has answered, and the tool states are kept.
    saved = json.loads((config / "state" / "core" / "mcp-policy.json").read_text())
    assert saved == {"fake": {"echo": "pin"}}, saved
    remembered = json.loads((config / "state" / "core" / "mcp-tools.json").read_text())
    assert remembered["fake"]["add"]["parameters"]["required"] == ["a", "b"], remembered["fake"]["add"]

    # A lazy server whose tools are remembered waits for its first call, where
    # the core leaves that to the plugin. A pinned tool needs it up at once.
    lazy = {"mcpServers": {"fake": {"command": sys.executable, "args": [str(config / "fake_server.py")], "lazy": True}}}
    (config / "mcp.json").write_text(json.dumps(lazy))
    state = lambda server: server.call("mcp/list")[0]["state"]
    server = Server(config)
    try:
        assert state(server) == "idle"
        server.run("mcp_search", {"query": "add"})
        assert state(server) == "ready"
        assert fake_names(server.last_request()) == ["fake_echo"], server.last_request()
        server.lua("mcp.set", {"server": "fake", "tool": "echo", "state": "on"})
    finally:
        server.close()
    if core["start"]:
        server = Server(config)
        try:
            text, failed, _ = server.run("mcp_search", {"query": "add"})
            assert not failed and text.startswith("[fake] add\n") and '"required":["a","b"]' in text.replace(" ", ""), text
            request = server.last_request()
            assert fake_names(request) == [] and "- fake: add, big, create_issue" in request["search"], request
            assert state(server) == "idle"
            assert server.run("mcp_call", {"server": "fake", "tool": "add", "arguments": {"a": 4, "b": 5}})[:2] == ("9", False)
            assert state(server) == "ready"
            # Loading every definition needs the servers up again.
        finally:
            server.close()
        server = Server(config)
        try:
            server.call("settings/set", {"path": "mcp.on_demand", "value": "off"})
            assert state(server) == "idle"
            server.run("fake_add", {"a": 1, "b": 1})
            assert state(server) == "ready" and len(fake_names(server.last_request())) == 15, server.last_request()
        finally:
            server.close()

    # Without servers the plugin adds nothing to a request.
    (config / "mcp.json").write_text(json.dumps({"mcpServers": {}}))
    server = Server(config)
    try:
        session = server.call("session/create")["session_id"]
        server.call("turn/start", {"session_id": session, "text": json.dumps({"name": "read_file", "arguments": {"path": "/nonexistent"}})})
        server.wait(lambda: any(e.get("method") == "turn/finished" for e in server.events), "the turn to finish")
        request = server.last_request()
        assert "mcp_search" not in request["tools"] and "mcp_call" not in request["tools"], request
        assert "mcp tools" not in {h["name"] for h in server.call("health/check")}
    finally:
        server.close()

print("mcp: on-demand tools, search, calls, argument checks, long results, tool states and settings passed")
