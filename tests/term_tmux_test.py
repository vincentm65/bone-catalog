#!/usr/bin/env python3
"""Isolated Unix PTY test: BONE_BIN=/path/to/bone python3 tests/term_tmux_test.py.
Requires tmux. Uses a temporary config/project and traps every model call.
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
    raise SystemExit("set BONE_BIN to a Bone 3.0.3 executable")
binary = str(Path(binary).resolve())
name = "bone-term-test-" + str(os.getpid())
requests = []


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        requests.append(self.path)
        self.send_error(500, "No model calls allowed")

    def log_message(self, *args):
        pass


def tmux(*args):
    return subprocess.check_output(["tmux", *args], text=True)


def screen():
    return tmux("capture-pane", "-p", "-N", "-t", name + ":0.0")


def wait(text, absent=False):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        snapshot = screen()
        if (text not in snapshot) if absent else (text in snapshot):
            return snapshot
        time.sleep(0.1)
    raise AssertionError("waiting for " + repr(text) + "\n" + screen())


def send(text):
    tmux("send-keys", "-t", name, "-l", text)


def command(text):
    send(text)
    tmux("send-keys", "-t", name, "Enter")


# The legacy Ctrl+] byte is parsed by crossterm as ctrl+5; CSI-u spells the
# distinct ctrl+] key. Exercise both actual input paths, not just Lua callbacks.
def toggle(kitty=False):
    send("\x1b[93;5u" if kitty else "\x1d")
    time.sleep(0.15)


server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="bone-term-tmux-") as raw:
        base = Path(raw)
        config, project = base / "config", base / "project space"
        project.mkdir()
        shutil.copytree(ROOT / "plugins/term", config / "plugins/term")
        # A dependency first requiring term owns its package.loaded entry.
        reader = config / "plugins/aaa-term-reader"
        reader.mkdir()
        (reader / "manifest.json").write_text(json.dumps({"capabilities": ["ui"]}))
        (reader / "tui.lua").write_text('local term = require("bone.ui.terminal")\n')
        # Windows is installed only in this disposable config and initially off.
        shutil.copytree(ROOT / "plugins/windows", config / "plugins/windows")
        (config / "core.lua").write_text(
            f'bone.config.providers.test = {{ base_url = "http://127.0.0.1:{server.server_port}/v1", model = "local" }}\n'
            'bone.config.provider = "test"\n'
        )
        (config / "settings.json").write_text(json.dumps({
            "setup": {"skipped": True}, "update": {"check": False},
            "plugins": {"disabled": ["windows"]},
        }))
        report_file = config / "term-report.txt"
        # A test-only command inspects ownership and shutdown without entering
        # chat/model input. Retain the module reference just like windows does.
        (config / "tui.lua").write_text('''
bone.o.autoreload = false
local term = require("bone.ui.terminal")
local jobs = {}
term.passthrough.f8 = true
bone.keymap.set("f8", function()
  local id
  id = bone.ui.popup({ lines = { "PASTE_POPUP" }, keys = { esc = function() bone.ui.close(id) end } })
end, { context = "panel" })
bone.cmd.create("term-test-require", function()
  assert(package.loaded["bone.ui.terminal"] == nil, "dependency must evict the module cache")
  assert(require("bone.ui.terminal") == term)
  assert(term.job("term1") == jobs[#jobs], "cache eviction lost the live job")
  bone.notify("TERM_REQUIRE_OK")
end)
bone.cmd.create("term-test-retire", function(c)
  local n = 0
  local function next_job()
    n = n + 1
    if n > 40 then return bone.notify("RETIRE_COMPLETE " .. c.args) end
    bone.job.start({ "/bin/true" }, { on_exit = next_job })
  end
  next_job()
end)
bone.on("panel/opened", function(ev)
  local job = term.job(ev.id)
  if job then jobs[#jobs + 1] = job end
end)
bone.cmd.create("term-test-report", function(c)
  local keys, running = 0, 0
  for _, k in ipairs(bone.keymap.list()) do
    if (k.keys == "ctrl+]" or k.keys == "ctrl+5") and k.plugin == "term" and k.desc ~= "" then
      keys = keys + 1
    end
  end
  for _, job in ipairs(jobs) do
    if job:running() then running = running + 1 end
  end
  local f = assert(io.open(''' + json.dumps(str(report_file)) + ''', "w"))
  f:write(c.args .. " keys=" .. keys .. " panels=" .. #bone.ui.panel.list() .. " running=" .. running)
  f:close()
end)
''')

        def report(tag, expected):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                command("/term-test-report " + tag)
                time.sleep(0.2)
                if report_file.exists() and report_file.read_text() == tag + " " + expected:
                    return
            actual = report_file.read_text() if report_file.exists() else "missing"
            raise AssertionError("report: " + actual + " expected " + expected + "\n" + screen())

        launch = shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), "SHELL=/bin/sh", binary])
        try:
            tmux("new-session", "-d", "-s", name, "-x", "120", "-y", "40", "-c", str(project), launch)
            wait("Message bone")
            report("loaded", "keys=2 panels=0 running=0")
            command("/terminal printf 'COMMAND_%s\\n' OUTPUT")
            wait("COMMAND_OUTPUT")
            toggle()
            report("output", "keys=2 panels=1 running=0")
            command("/term-test-retire")
            wait("RETIRE_COMPLETE")
            wait("COMMAND_OUTPUT")
            tmux("resize-window", "-t", name, "-x", "100", "-y", "35")
            wait("COMMAND_OUTPUT")
            tmux("resize-window", "-t", name, "-x", "120", "-y", "40")
            command("/term close")
            wait("COMMAND_OUTPUT", absent=True)
            report("closed", "keys=2 panels=0 running=0")

            # ctrl+5 opens a shell; ctrl+] escapes/refocuses it.
            toggle()
            command("printf 'LIVE_%s\\n' OUTPUT")
            wait("LIVE_OUTPUT")
            command("printf 'CWD_%s\\n' \"$PWD\"")
            wait("CWD_" + str(project))
            # Esc must reach the PTY program, not close/focus the prompt.
            command("stty -echo -icanon min 1 time 0; printf 'ESC_%s\\n' READY; byte=$(dd bs=1 count=1 2>/dev/null | od -An -tu1); stty echo icanon; printf 'ESC_BYTE_%s\\n' \"$(echo $byte)\"")
            wait("ESC_READY")
            tmux("send-keys", "-t", name, "Escape")
            wait("ESC_BYTE_27")
            # A popup keeps underlying panel focus, but must not paste into it.
            leaked = project / "paste-leaked"
            command("stty -echo -icanon min 1 time 0; printf 'PASTE_%s\\n' READY; dd bs=1 count=1 of=paste-leaked 2>/dev/null; stty echo icanon; printf 'PASTE_%s\\n' FINISHED")
            wait("PASTE_READY")
            tmux("send-keys", "-t", name, "F8")
            wait("PASTE_POPUP")
            send("\x1b[200~PRIVATE_POPUP_TEXT\x1b[201~")
            time.sleep(0.3)
            assert not leaked.exists() or leaked.stat().st_size == 0, "popup paste reached the shell"
            tmux("send-keys", "-t", name, "Escape")
            wait("PASTE_POPUP", absent=True)
            send("Q")
            wait("PASTE_FINISHED")
            assert leaked.read_bytes() == b"Q"
            # Legacy control punctuation must arrive as control bytes, not digits.
            for byte in (28, 30, 31):
                command("stty -echo -icanon -isig min 1 time 0; printf 'CTRL_%s_READY\\n' " + str(byte) + "; byte=$(dd bs=1 count=1 2>/dev/null | od -An -tu1); stty echo icanon isig; printf 'CTRL_BYTE_%s\\n' \"$(echo $byte)\"")
                wait("CTRL_" + str(byte) + "_READY")
                send(chr(byte))
                wait("CTRL_BYTE_" + str(byte))
            toggle(kitty=True)
            report("escaped", "keys=2 panels=1 running=1")
            command("/plugins unload aaa-term-reader")
            wait("aaa-term-reader: tui unloaded")
            command("/term-test-require")
            wait("TERM_REQUIRE_OK")
            toggle(kitty=True)
            command("printf 'REFOCUSED_%s\\n' OUTPUT")
            wait("REFOCUSED_OUTPUT")
            command("exit")
            wait("REFOCUSED_OUTPUT", absent=True)
            report("exit", "keys=2 panels=0 running=0")

            # Reload while an interactive terminal is open, then reuse its id.
            command("/term")
            command("printf 'BEFORE_%s\\n' RELOAD")
            wait("BEFORE_RELOAD")
            toggle()
            command("/plugins reload term")
            wait("term: tui reloaded")
            wait("BEFORE_RELOAD", absent=True)
            report("reloaded", "keys=2 panels=0 running=0")
            toggle(kitty=True)
            command("printf 'AFTER_%s\\n' RELOAD")
            wait("AFTER_RELOAD")
            toggle()
            command("/plugins unload term")
            wait("term: tui unloaded")
            wait("AFTER_RELOAD", absent=True)
            report("unloaded", "keys=0 panels=0 running=0")
            command("/plugins load term")
            wait("term: tui loaded")
            report("loaded-again", "keys=2 panels=0 running=0")

            # Existing windows captures/wraps terminal.open. Reloading term
            # must close its split and preserve the wrapper's module reference.
            command("/plugins load windows")
            wait("windows: tui loaded")
            command("/term")
            command("printf 'WINDOW_%s\\n' BEFORE")
            wait("WINDOW_BEFORE")
            toggle()
            command("/plugins reload term")
            wait("WINDOW_BEFORE", absent=True)
            report("window-reload", "keys=2 panels=0 running=0")
            command("/term")
            command("printf 'WINDOW_%s\\n' AFTER")
            wait("WINDOW_AFTER")
            toggle()
            command("/plugins unload term")
            wait("WINDOW_AFTER", absent=True)
            report("window-unload", "keys=0 panels=0 running=0")
            time.sleep(0.3)
            assert not requests, requests
            assert not list((config / "sessions").rglob("*.json")), "terminal created a saved chat session"
            print("term live TUI passed: keys/alias/output retention/cwd/esc/popup paste/control bytes/cache eviction/close/shell exit/reload/unload/windows wrapper; zero model calls")
        finally:
            subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
finally:
    server.shutdown()
    server.server_close()
