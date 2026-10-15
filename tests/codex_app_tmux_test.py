#!/usr/bin/env python3
"""Live codex-app margin regression (tmux, disposable config, zero model calls).
Run: BONE_BIN=/path/to/bone python3 tests/codex_app_tmux_test.py
A test-only command reproduces ask_user's deep-copy/swap/saved-table restore;
all layout rendering, geometry and margin updates come from the real library.
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
binary = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not binary:
    raise SystemExit("set BONE_BIN to a Bone executable")
binary = str(Path(binary).resolve())
name = "bone-codex-app-test-" + str(os.getpid())
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


def key(value):
    tmux("send-keys", "-t", name, value)


def command(value):
    tmux("send-keys", "-t", name, "-l", value)
    key("Enter")


server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="bone-codex-app-tmux-") as raw:
        base = Path(raw)
        config, project = base / "config", base / "project"
        project.mkdir()
        library = ROOT / "tuis/codex-app"
        shutil.copytree(library, config / "libraries/codex-app")
        (config / "library").write_text("codex-app\n")
        (config / "core.lua").write_text(
            f'bone.config.providers.test = {{ base_url = "http://127.0.0.1:{server.server_port}/v1", model = "local" }}\n'
            'bone.config.provider = "test"\n'
        )
        (config / "settings.json").write_text(json.dumps({
            "setup": {"skipped": True}, "update": {"check": False},
        }))
        report_file = config / "codex-report.json"
        (config / "tui.lua").write_text('''
bone.o.autoreload = false
local saved, question, phase, serial = nil, nil, "prompt", 0
local restored = false
local function find(list, name)
  for _, e in ipairs(list or {}) do
    if type(e) == "table" then
      if e[1] == name then return e end
      local found = find(e.rows, name) or find(e.cols, name)
      if found then return found end
    elseif e == name then return e end
  end
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end
local function swap(list)
  for i, e in ipairs(list or {}) do
    if (type(e) == "table" and e[1] or e) == "prompt" then
      list[i] = "ask_user"
      return true
    end
    if type(e) == "table" and (swap(e.rows) or swap(e.cols)) then return true end
  end
  return false
end
bone.ui.regions.ask_user = { size = 4, render = function()
  return { "CODEX_ASK_TEST", "Resize while the composer is replaced.", "F7 restores the actual saved layout." }
end }
bone.ui.regions.codex_test_extra = { size = 1, render = function() return { "CODEX_EXTRA_TEST" } end }
bone.cmd.create("codex-test-ask", function()
  assert(phase == "prompt", "question already open")
  saved = bone.ui.layout
  question = copy(saved)
  assert(swap(question), "real codex-app prompt missing")
  local function extra(list)
    for _, e in ipairs(list or {}) do
      if type(e) == "table" then
        if e.rows and find(e.rows, "ask_user") then
          e.rows[#e.rows + 1] = { "codex_test_extra", size = 1 }
          return true
        end
        if extra(e.rows) or extra(e.cols) then return true end
      end
    end
    return false
  end
  assert(extra(question))
  bone.ui.layout = question
  phase, restored = "question", false
end)
bone.keymap.set("f7", function()
  assert(phase == "question" and bone.ui.layout == question, "question layout was rebuilt")
  bone.ui.layout = saved -- Deliberately NOT a fresh copy or rebuilt layout.
  restored = bone.ui.layout == saved
  phase = "prompt"
  bone.ui.refresh_in(0)
end)
bone.keymap.set("f6", function()
  serial = serial + 1
  local layout = bone.ui.layout
  local report = {
    serial = serial, phase = phase, layout = tostring(layout),
    question_identity = layout == question, restored_identity = restored and layout == saved,
    prompt = find(layout, "prompt") ~= nil, ask = find(layout, "ask_user") ~= nil,
    extra = find(layout, "codex_test_extra") ~= nil,
    left = find(layout, "pad_l").size, right = find(layout, "pad_r").size,
    saved_left = saved and find(saved, "pad_l").size or -1,
    saved_right = saved and find(saved, "pad_r").size or -1,
    geometry = bone.ui.geometry(), logs = bone.api.log(1000), library = bone.library.info(),
  }
  local f = assert(io.open(''' + json.dumps(str(report_file)) + ''', "w"))
  f:write(bone.json.encode(report))
  f:close()
end)
''')

        def report():
            previous = json.loads(report_file.read_text())["serial"] if report_file.exists() else 0
            key("F6")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    data = json.loads(report_file.read_text())
                    if data["serial"] > previous:
                        return data
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(0.05)
            raise AssertionError("test report missing (Lua error?)\n" + screen())

        def settled(width, phase):
            deadline = time.monotonic() + 15
            last = None
            while time.monotonic() < deadline:
                last = report()
                leaves = {leaf["name"]: leaf for leaf in last["geometry"]["leaves"]}
                middle = "ask_user" if phase == "question" else "prompt"
                if last["phase"] == phase and all(n in leaves for n in ("pad_l", middle, "pad_r")):
                    left, center, right = (leaves[n] for n in ("pad_l", middle, "pad_r"))
                    room = left["width"] + center["width"] + right["width"]
                    want = max(1, (room - 96) // 2)
                    # x + width also detects a stale last-frame geometry report.
                    if (right["x"] + right["width"] == width
                            and left["width"] == right["width"] == want
                            and last["left"] == last["right"] == want):
                        assert center["x"] == left["x"] + want, last
                        assert right["x"] == center["x"] + center["width"], last
                        assert last["prompt"] == (phase == "prompt"), last
                        assert last["ask"] == (phase == "question"), last
                        assert last["extra"] == (phase == "question"), last
                        assert not any("error" in line.lower() or "stack traceback" in line.lower()
                                       for line in last["logs"]), last["logs"]
                        if phase == "question":
                            assert last["question_identity"], last
                        return last, want
                time.sleep(0.1)
            raise AssertionError("margins did not settle: " + repr(last) + "\n" + screen())

        def resize(width, height):
            tmux("resize-window", "-t", name, "-x", str(width), "-y", str(height))

        launch = shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), binary])
        try:
            tmux("new-session", "-d", "-s", name, "-x", "190", "-y", "42", "-c", str(project), launch)
            tmux("set-option", "-w", "-t", name, "window-size", "manual")
            deadline = time.monotonic() + 15
            while "Full access" not in screen() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert "Full access" in screen(), screen()
            initial, wide = settled(190, "prompt")
            assert wide > 1, initial
            assert initial["library"]["active"] == "codex-app", initial["library"]
            # The real sidebar reserves room; do not mistake terminal width for
            # the middle column's available width when checking the margins.
            assert next(leaf for leaf in initial["geometry"]["leaves"] if leaf["name"] == "pad_l")["x"] > 0, initial
            for width, height in ((140, 32), (210, 44)):
                before, old_margin = settled(190 if width == 140 else 95, "prompt")
                command("/codex-test-ask")
                asking, _ = settled(190 if width == 140 else 95, "question")
                assert "CODEX_ASK_TEST" in screen() and "CODEX_EXTRA_TEST" in screen(), screen()
                resize(width, height)
                resized, new_margin = settled(width, "question")
                assert resized["layout"] == asking["layout"], resized
                assert new_margin != old_margin, (old_margin, new_margin)
                assert resized["saved_left"] == resized["saved_right"] == old_margin, resized
                key("F7")
                restored, margin = settled(width, "prompt")
                assert restored["restored_identity"] and restored["layout"] == before["layout"], restored
                assert margin == new_margin, restored
                assert "CODEX_ASK_TEST" not in screen(), screen()
                if width == 140:
                    resize(95, 26)
                    narrow, margin = settled(95, "prompt")
                    assert margin == 1, narrow
            # A later frame must remain correct too, with no delayed Lua errors.
            time.sleep(0.3)
            settled(210, "prompt")
            assert not requests, requests
            assert not list((config / "sessions").rglob("*.json")), "test created a saved chat session"
            for source in library.rglob("*"):
                if source.is_file():
                    assert source.read_bytes() == (config / "libraries/codex-app" / source.relative_to(library)).read_bytes()
            print("codex-app live TUI passed: real library/sidebar, ask_user-style swap, shrink/grow while asking, actual saved-layout restore, narrow margins; no Lua errors or model calls")
        finally:
            subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
finally:
    server.shutdown()
    server.server_close()
