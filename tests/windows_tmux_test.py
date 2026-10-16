#!/usr/bin/env python3
"""Real Windows Lua-reload regression; requires tmux, never submits a prompt.
Run: BONE_BIN=/path/to/bone python3 tests/windows_tmux_test.py
Only a disposable config/project and uniquely named tmux session are used.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
binary = os.environ.get("BONE_BIN") or shutil.which("bone")
if not binary:
    raise SystemExit("set BONE_BIN to a Bone executable")
binary = str(Path(binary).resolve())
name = "bone-windows-test-" + str(os.getpid())
requests = []
BROKEN = "WINDOWS_TEST_REJECT_READY"


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        requests.append(self.path)
        self.send_error(500, "No model calls allowed")

    def log_message(self, *args):
        pass


def tmux(*args):
    return subprocess.check_output(["tmux", *args], text=True)


def wait_report(tag, predicate=lambda r: True):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if tag == "probe":
            tmux("send-keys", "-t", name, "F7")
        try:
            r = json.loads(report_file.read_text())
            if r["tag"] == tag and predicate(r):
                # Do not let a config/ready/callback error become a false pass.
                for line in r["log"]:
                    if BROKEN not in line:
                        assert not any(s in line.lower() for s in (
                            "error", "failed", "stack traceback", "tui.lua:", "runtime/",
                        )), line
                return r
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError("waiting for report " + tag + "\n" +
                         tmux("capture-pane", "-p", "-N", "-t", name + ":0.0"))


def probe(predicate=lambda r: True):
    report_file.unlink(missing_ok=True)
    return wait_report("probe", predicate)


def preserved(before, after):
    for key in ("state", "chats", "layout", "current", "prompt", "drafts"):
        assert before[key] == after[key], (key, before[key], after[key])


def leaves(node):
    if "kids" not in node:
        return [node]
    return [leaf for kid in node["kids"] for leaf in leaves(kid)]


server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="bone-windows-tmux-") as raw:
        base = Path(raw)
        config, project = base / "config", base / "project"
        project.mkdir()
        shutil.copytree(ROOT / "plugins/windows", config / "plugins/windows")
        (config / "core.lua").write_text(
            f'bone.config.providers.test = {{ base_url = "http://127.0.0.1:{server.server_port}/v1", model = "local" }}\n'
            'bone.config.provider = "test"\n'
        )
        (config / "settings.json").write_text(json.dumps({
            "setup": {"skipped": True}, "update": {"check": False},
        }))
        report_file = base / "report.json"
        source = '''
local generation = GENERATION
local function report(tag)
  -- Snapshot BEFORE opening background buffers: chat/shown can change focus.
  local r = bone.json.decode(bone.json.encode({
    tag = tag, generation = generation, state = bone.plugin.state("windows"),
    chats = bone.chat.sessions(), layout = bone.ui.layout,
    current = bone.chat.session().chat, prompt = bone.prompt.get(), log = bone.api.log(1000),
  }))
  r.drafts = {}
  for i = 0, #r.chats - 1 do
    bone.api.open_session(tostring(i))
    r.drafts[tostring(i)] = bone.prompt.get()
  end
  bone.api.open_session(tostring(r.current))
  local f = assert(io.open(REPORT, "w"))
  f:write(bone.json.encode(r))
  f:close()
end
bone.cmd.create("windows-test", function(c)
  if c.args == "setup" then
    bone.cmd("win vsplit")
    bone.cmd("win vsplit") -- unequal sibling weights: 1, .5, .5
    bone.cmd("win split")  -- nested rows inside columns
    bone.cmd("win rotate") -- nontrivial buffer order, including chat zero
    for i = 0, #bone.chat.sessions() - 1 do
      bone.api.open_session(tostring(i))
      bone.prompt.set("unsent draft " .. i .. "\\nprivate buffer " .. i)
    end
    bone.cmd("win zoom")
  elseif c.args == "only" then
    bone.cmd("win only")
  end
  report(c.args)
end)
bone.keymap.set("f6", function() bone.cmd("windows-test setup") end)
bone.keymap.set("f7", function() report("probe") end)
bone.keymap.set("f8", function() bone.cmd("windows-test only") end)
bone.on("ready", function()
  bone.defer(150, function() report(generation) end)
end)
'''.replace("REPORT", json.dumps(str(report_file)))

        def reload(tag, broken=False):
            # A real file-watcher reload, not /plugins reload or a Rust hook.
            text = source.replace("GENERATION", json.dumps(tag)) + "\n-- " + tag + "\n"
            if broken:
                text += f'bone.on("ready", function() error("{BROKEN}") end)\n'
            (config / "tui.lua").write_text(text)

        reload("initial")
        launch = shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), binary])
        try:
            tmux("new-session", "-d", "-s", name, "-x", "120", "-y", "40", "-c", str(project), launch)
            initial = wait_report("initial")
            assert len(initial["chats"]) == 1 and initial["current"] == 0, initial
            tmux("send-keys", "-t", name, "F6")
            before = wait_report("setup")
            tree = before["state"]["tree"]
            windows = leaves(tree)
            assert tree["dir"] == "cols" and tree["kids"][-1]["dir"] == "rows", tree
            assert [w["chat"] for w in windows] == [1, 2, 3, 0], windows
            assert tree["kids"][0]["w"] != tree["kids"][1]["w"], tree
            assert len(before["chats"]) == 4 and before["current"] == 3, before
            assert [w["chat"] for w in windows if w.get("zoom")] == [3], windows
            assert [w["chat"] for w in windows if w.get("focus")] == [3], windows
            assert "wm_bar:" not in json.dumps(before["layout"]), "not zoomed"
            assert before["drafts"] == {str(i): f"unsent draft {i}\nprivate buffer {i}" for i in range(4)}

            reload("zoom-reload")
            preserved(before, wait_report("zoom-reload"))
            # Rejected ready handlers must not allocate buffers or activate windows.
            reload("rejected", broken=True)
            rejected = probe(lambda r: any(BROKEN in line and "reload failed" in line for line in r["log"]))
            assert rejected["generation"] == "zoom-reload", rejected
            preserved(before, rejected)
            reload("recovered")
            preserved(before, wait_report("recovered"))

            tmux("send-keys", "-t", name, "F8")
            only = wait_report("only")
            assert not only["state"].get("tree"), only
            assert len(only["chats"]) == 4 and only["current"] == 3, only
            reload("only-reload")
            preserved(only, wait_report("only-reload"))
            assert not requests, requests
            assert not list((config / "sessions").rglob("*.json")), "saved an unsent chat"
            print("windows real TUI passed: zoom/tree/order/weights/focus/buffer count/drafts (chat0), rejected ready/recovery, /win only; zero model calls")
        finally:
            subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
finally:
    server.shutdown()
    server.server_close()
