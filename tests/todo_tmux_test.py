#!/usr/bin/env python3
"""Test the real todo drawer in an isolated tmux session.

Run: BONE_BIN=/path/to/bone3 python3 tests/todo_tmux_test.py
Uses a scripted local provider and keeps screen captures in its temp config.
"""
from pathlib import Path
import json, os, shlex, shutil, socket, subprocess, tempfile, time

root = Path(__file__).resolve().parents[1]
binary = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not binary:
    raise SystemExit("set BONE_BIN to a Bone 3 executable")
config = Path(tempfile.mkdtemp(prefix="bone-todo-tmux-"))
shutil.copytree(root / "plugins" / "todo", config / "plugins" / "todo")
(config / "settings.json").write_text(json.dumps({"setup": {"skipped": True}}))
sockpath = str(config / "bone.sock")
name = "bone-todo-test-" + str(os.getpid())
serial, events, screens, client = 0, [], [], None


def tmux(*args):
    return subprocess.check_output(["tmux", *args], text=True)


def screen():
    return tmux("capture-pane", "-p", "-N", "-t", name + ":0.0")


def drawer():
    """The todo drawer: its title row and the marked item rows under it.

    Empty when the drawer is hidden, which is what the per-chat checks assert.
    """
    lines = [line.rstrip() for line in screen().splitlines()]
    marks = ("\u2713", "\u25b8", "\u00b7")  # completed, in progress, pending
    for i, line in enumerate(lines):
        if line.startswith("Todo ") and i + 1 < len(lines) and lines[i + 1].startswith(marks):
            block = [line]
            for following in lines[i + 1:]:
                if following.startswith(marks):
                    block.append(following)
                else:
                    break
            return "\n".join(block)
    return ""


def wait(predicate, label, timeout=15):
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


def type_line(text):
    tmux("send-keys", "-t", name + ":0.0", "-l", text)
    tmux("send-keys", "-t", name + ":0.0", "Enter")


# The server runs the turns, so its provider has to be registered before it starts.
(config / "core.lua").write_text('''
bone.provider.register("todo_test", { complete = function(req)
  bone.sleep(200)
  if req.messages[#req.messages].role ~= "tool" then
    local complete = req.messages[#req.messages].content == "complete the checklist"
    return { content = "", tool_calls = { { id = "t1", name = "todo", arguments = {
      title = "Parser fixes", items = {
      { text = "inspect the parser", status = "completed" },
      { text = "fix the parser", status = complete and "completed" or "in_progress" } } } } } }
  end
  return { content = "fixed and verified" }
end })
bone.config.providers.test = { type = "todo_test", model = "local" }
bone.config.provider = "test"
''')

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
    call("initialize", {"protocol_version": 0, "client_name": "todo-tmux-test"})
    a = call("session/create")["session_id"]
    b = call("session/create")["session_id"]
    # The TUI loads tui.lua itself, for the two chats created above.
    (config / "tui.lua").write_text('''
bone.cmd.create("test_a", function() bone.api.open_session(%s) end)
bone.cmd.create("test_b", function() bone.api.open_session(%s) end)
''' % (json.dumps(a), json.dumps(b)))
    tmux("new-session", "-d", "-s", name, "-x", "120", "-y", "40", "-c", str(config),
         shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), binary, "--connect", sockpath, "--resume", a]))
    wait(lambda: "Message bone" in screen(), "TUI startup")

    # A turn that calls todo shows the drawer for this chat only.
    type_line("keep a checklist for this")
    wait(lambda: "Todo 1/2" in drawer() and "fix the parser" in drawer() and "✓" in drawer(),
         "A's drawer")
    assert "Parser fixes" in drawer(), drawer()
    lines = screen().splitlines()
    heading = next(i for i, line in enumerate(lines) if line.startswith("Todo 1/2"))
    assert heading > 0 and not lines[heading - 1].strip(), "missing spacer above heading"
    screens.append("A: list from the chat's own todo call\n" + screen())
    assert "Lua error" not in screen()

    # Another chat has no list: the drawer hides, and returning restores it.
    tmux("send-keys", "-t", name + ":0.0", "-l", "/test_b")
    tmux("send-keys", "-t", name + ":0.0", "Enter")
    wait(lambda: drawer() == "", "B has no drawer")
    screens.append("B: drawer hidden\n" + screen())
    tmux("send-keys", "-t", name + ":0.0", "-l", "/test_a")
    tmux("send-keys", "-t", name + ":0.0", "Enter")
    wait(lambda: "Todo 1/2" in drawer(), "A's drawer again after switching back")

    # A successful all-completed call removes the drawer, not the history.
    type_line("complete the checklist")
    wait(lambda: drawer() == "" and "list cleared" not in screen(), "drawer hidden on completion")
    type_line("/todo")
    time.sleep(0.3)
    assert drawer() == "", "completed list reopened"
    type_line("/test_b")
    time.sleep(0.3)
    type_line("/test_a")
    time.sleep(0.3)
    assert drawer() == "", "older unfinished list resurrected"
    screens.append("A: completed drawer hidden\n" + screen())
    # A new unfinished list opens the drawer again.
    type_line("start a new checklist")
    wait(lambda: "Todo 1/2" in drawer(), "new checklist shown")
    assert "Lua error" not in screen(), screen()
    print("PASS: tmux todo title, spacing, completion hide, per-chat isolation, reopen")
finally:
    (config / "tmux-screens.txt").write_text("\n\n".join(screens))
    print("Artifacts:", config)
    subprocess.run(["tmux", "kill-session", "-t", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
