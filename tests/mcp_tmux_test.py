#!/usr/bin/env python3
"""Test the real /mcp popup and MCP calls in the chat, in an isolated tmux server.

Run: BONE_BIN=/path/to/bone3 python3 tests/mcp_tmux_test.py
A small stdio MCP server and a scripted provider stand in for the outside
world. Screen captures are kept in the temporary config directory.
"""
from pathlib import Path
import json, os, shlex, shutil, socket, subprocess, sys, tempfile, time

root = Path(__file__).resolve().parents[1]
binary = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not binary:
    raise SystemExit("set BONE_BIN to a Bone 3 executable")
config = Path(tempfile.mkdtemp(prefix="bone-mcp-tmux-"))
shutil.copytree(root / "plugins" / "mcp", config / "plugins" / "mcp")
(config / "settings.json").write_text(json.dumps({
    "setup": {"skipped": True}, "update": {"check": False}, "tui": {"tool_detail": "rows"}}))
sockpath = str(config / "bone.sock")
name = "bone-mcp-test-" + str(os.getpid())
serial, events, screens, client = 0, [], [], None

(config / "fake_server.py").write_text(r'''
import json, sys
LONG = "It does one small thing and says so at some length. " * 10
def tool(name, props, required=(), read_only=False):
    t = {"name": name, "description": name.replace("_", " ").capitalize() + ". " + LONG,
         "inputSchema": {"type": "object", "properties": props, "required": list(required)}}
    if read_only:
        t["annotations"] = {"readOnlyHint": True}
    return t
TOOLS = [
    tool("create_issue", {"title": {"type": "string"}, "body": {"type": "string"}, "labels": {"type": "array"}}, ["title"]),
    tool("list_issues", {"state": {"type": "string", "enum": ["open", "closed"]}}, read_only=True),
    tool("search_code", {"query": {"type": "string"}}, ["query"], read_only=True),
] + [tool("tool_%02d" % i, {"x": {"type": "string"}}) for i in range(1, 22)]
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
        out = {"content": [{"type": "text", "text": "created issue #7\nhttps://example.test/issues/7"}]}
    else:
        out = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": id, "result": out}) + "\n")
    sys.stdout.flush()
''')
(config / "mcp.json").write_text(json.dumps({"mcpServers": {
    "tracker": {"command": sys.executable, "args": [str(config / "fake_server.py")]},
    "broken": {"command": "/nonexistent/mcp-server"},
}}))
# One turn: look a tool up, then call it.
(config / "core.lua").write_text('''
bone.provider.register("mcp_test", { complete = function(req)
  local results = 0
  for _, m in ipairs(req.messages) do
    if m.role == "tool" then results = results + 1 end
  end
  if results == 0 then
    return { content = "", tool_calls = { { id = "c1", name = "mcp_search", arguments = { query = "create issue" } } } }
  elseif results == 1 then
    return { content = "", tool_calls = { { id = "c2", name = "mcp_call", arguments = { server = "tracker",
      tool = "create_issue", arguments = { title = "Crash on start", labels = { "bug", "p1" } } } } } }
  end
  return { content = "Filed it." }
end })
bone.config.providers.test = { type = "mcp_test", model = "local" }
bone.config.provider = "test"
''')


def tmux(*args):
    return subprocess.check_output(["tmux", "-L", name, *args], text=True)


def screen():
    return tmux("capture-pane", "-p", "-N", "-t", name + ":0.0")


def wait(predicate, label, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(label + "\n" + screen())


def call(method, params=None):
    global serial
    serial += 1
    client.sendall((json.dumps({"jsonrpc": "2.0", "id": serial, "method": method,
                                "params": params or {}}) + "\n").encode())
    while True:
        line = reader.readline()
        assert line, "server closed"
        message = json.loads(line)
        if message.get("id") == serial:
            assert "error" not in message, message
            return message["result"]
        events.append(message)


def keys(*names):
    for key in names:
        tmux("send-keys", "-t", name + ":0.0", key)
        time.sleep(0.08)


def type_text(text):
    tmux("send-keys", "-t", name + ":0.0", "-l", text)


def keep(label):
    screens.append(label + "\n" + screen())
    assert "Lua error" not in screen(), screen()


def row(text):
    """The first screen line holding `text` ('' when there is none)."""
    return next((line for line in screen().splitlines() if text in line), "")


(errfile := open(config / "server.err", "w"))
server = subprocess.Popen([binary, "--headless", "--listen", sockpath],
                          env=dict(os.environ, BONE_CONFIG_DIR=str(config)),
                          stdout=subprocess.DEVNULL, stderr=errfile)
try:
    wait(lambda: Path(sockpath).exists(), "server socket")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    client.connect(sockpath)
    reader = client.makefile("rb")
    call("initialize", {"protocol_version": 0, "client_name": "mcp-tmux-test"})
    session = call("session/create")["session_id"]
    tmux("new-session", "-d", "-s", name, "-x", "120", "-y", "40", "-c", str(config),
         shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), binary, "--connect", sockpath, "--resume", session]))
    wait(lambda: "Message bone" in screen(), "TUI startup")

    # A server that cannot start says so without being asked.
    wait(lambda: "mcp: broken failed" in screen(), "the failure message", timeout=60)
    keep("a server failed")

    # A turn through the two tools: each call reads as what it did.
    type_text("file the crash")
    keys("Enter")
    wait(lambda: "Filed it." in screen(), "the turn")
    assert row("tracker › create_issue"), screen()
    assert 'labels=[2] title=Crash on start' in row("tracker › create_issue"), row("tracker › create_issue")
    assert "created issue #7" in screen(), screen()
    assert row("mcp_search create issue"), screen()
    keep("calls in the chat")

    # /mcp: the servers, what the tools cost, and how they are loaded.
    type_text("/mcp")
    keys("Enter")
    wait(lambda: "MCP servers" in screen() and "✕ broken" in screen(), "the popup")
    wait(lambda: "Tools load on demand (auto)" in screen(), "the loading line")
    assert "cannot run /nonexistent/mcp-server" in screen() and "● tracker" in screen(), screen()
    # The broken server is first; its neighbour has the tools.
    keys("Down")
    wait(lambda: "Tools  24" in screen(), "the tracker's tools")
    assert "… and 14 more · enter shows them all" in screen(), screen()
    keep("servers")
    keys("Enter")
    wait(lambda: "space on/off · p pin" in screen(), "the tools view")
    assert "● create_issue" in screen() and "Arguments  3" in screen(), screen()
    assert "↓ 10 more" in screen(), screen()
    keep("tools")

    # Off and back on; pinned.
    keys("Space")
    wait(lambda: "● create_issue" not in screen() and "[off]" in screen(), "create_issue off")
    assert "1 off" in screen(), screen()
    keys("Space")
    wait(lambda: "● create_issue" in screen() and "1 off" not in screen(), "create_issue on")
    keys("p")
    wait(lambda: "1 pinned" in screen() and "[pinned]" in row("● create_issue"), "create_issue pinned")
    keep("pinned")
    keys("p")
    wait(lambda: "1 pinned" not in screen(), "create_issue unpinned")

    # The list scrolls under the selection, which stays off its edges.
    for _ in range(16):
        keys("Down")
    wait(lambda: "tool_14" in screen() and "↑ 4 more" in screen(), "the list scrolled")
    for _ in range(7):
        keys("Down")
    wait(lambda: "tool_21" in screen() and "↓" not in row("more") and "↑ 10 more" in screen(), "the end of the list")
    keep("scrolled")

    # A filter, typed.
    keys("/")
    type_text("issue")
    wait(lambda: "Filter: issue" in screen() and "tool_21" not in screen(), "the filter")
    assert "● create_issue" in screen() and "● list_issues" in screen(), screen()
    keep("filtered")
    keys("Enter", "Escape")
    wait(lambda: "Filter" not in row("Filter:") and "tool_01" in screen(), "the filter cleared")
    keys("Escape")
    wait(lambda: "enter tools · a add" in screen(), "back to the servers")

    # How tools are loaded, changed from here.
    keys("l")
    wait(lambda: "Tools load on demand (on)" in screen(), "on")
    keys("l")
    wait(lambda: "Every tool is loaded (off)" in screen(), "off")
    keys("l")
    wait(lambda: "Tools load on demand (auto)" in screen(), "auto")
    keep("loading modes")

    # Adding a command asks for its environment too.
    keys("a")
    type_text("extra")
    keys("Enter")
    type_text("/nonexistent/extra-server --flag")
    keys("Enter")
    wait(lambda: "Environment for it" in screen(), "the environment step")
    type_text("API_KEY=abc def MODE=fast")
    keys("Enter")
    wait(lambda: "added extra" in screen(), "the server added")
    added = json.loads((config / "mcp.json").read_text())["mcpServers"]["extra"]
    assert added == {"command": "/nonexistent/extra-server", "args": ["--flag"],
                     "env": {"API_KEY": "abc def", "MODE": "fast"}}, added
    keep("added")
    keys("Escape")
    wait(lambda: "MCP servers" not in screen(), "the popup closed")
    print("PASS: tmux /mcp servers, tools, on/off, pin, scrolling, filter, loading modes, add with environment, chat calls, failure message")
finally:
    (config / "tmux-screens.txt").write_text("\n\n".join(screens))
    print("Artifacts:", config)
    subprocess.run(["tmux", "-L", name, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if client:
        try:
            call("shutdown")
        except Exception:
            pass
        client.close()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
    errfile.close()
