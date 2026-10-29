-- Run from catalog root: luajit tests/term_test.lua
package.path = "plugins/term/lua/?.lua;" .. package.path
local panels, events, jobs, commands, keys, notices, shutdowns = {}, {}, {}, {}, {}, {}, {}
local focused, owner, next_event = nil, "term", 0
local fail_start, fail_open, fail_close
local function width(text)
  local n = 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + (ch == "界" and 2 or 1) end
  return n
end
bone = {
  text = { width = width }, hl = { set = function() end },
  chat = { session = function() return { cwd = "/project space" } end },
  notify = function(text) notices[#notices + 1] = text end,
  on = function(name, fn)
    next_event = next_event + 1
    events[next_event] = { name = name, fn = fn, owner = owner }
    return next_event
  end,
  off = function(id) events[id] = nil end,
  cmd = { create = function(name, fn, opts) commands[name] = { fn = fn, opts = opts, owner = owner } end },
  keymap = { set = function(key, fn, opts) keys[key] = { fn = fn, opts = opts, owner = owner } end },
  plugin = { on_shutdown = function(fn) shutdowns[#shutdowns + 1] = fn end },
  ui = { panel = {} },
  job = { start = function(cmd, opts)
    if fail_start then error("start failed") end
    local job = { cmd = cmd, opts = opts, owner = owner, writes = {}, cancelled = 0 }
    function job:write(bytes) self.writes[#self.writes + 1] = bytes end
    function job:cancel()
      self.cancelled = self.cancelled + 1
      -- Exercise a synchronous late exit during cancellation.
      self.opts.on_exit({ code = 99, cmd = "cancelled" })
    end
    function job:screen(size)
      if self.evicted then return nil end
      size = size or { width = 80, height = 24, scroll = 0 }
      size.scroll = size.scroll or 0
      self.size = size
      return { lines = { { { "a界z", "Normal" } }, {} }, cursor = { 1, 2 },
        scroll = size.scroll, max = 100, app_cursor = true, bracketed_paste = true,
        mouse = "press_release", mouse_encoding = "sgr" }
    end
    jobs[#jobs + 1] = job
    return job
  end },
}
local panel = bone.ui.panel
function panel.get(id) return panels[id] end
function panel.focus(id) focused = id end
function panel.focused() return focused end
function panel.open(spec)
  if fail_open then error("invalid panel") end
  assert(not panels[spec.id])
  local p = { id = spec.id, spec = spec, owner = owner }
  function p:show() self.spec.hidden = false end
  function p:focus() focused = self.id end
  panels[p.id] = p
  if spec.focus then focused = p.id end
  return p
end
function panel.close(id)
  local p = panels[id]
  if not p then return false end
  panels[id] = nil
  if focused == id then focused = nil end
  if fail_close then error("close failed after removing panel") end
  p.spec.on_close(p)
  return true
end
local function load()
  owner = "term"
  dofile("plugins/term/tui.lua") -- the desktop app loads gui.lua, which adds nothing
  return require("bone.ui.terminal")
end
local function command(args) return commands.term.fn({ args = args }) end
local function paste(text, context)
  for _, ev in pairs(events) do if ev.name == "paste" then ev.fn({ text = text, context = context or "panel" }) end end
end
local function mouse(ev)
  for _, handler in pairs(events) do
    if handler.name == "mouse" and handler.fn(ev) then return true end
  end
end
-- A dependency may require the module before term loads. It must stay inert,
-- then activate when term's own tui.lua runs (and register paste as term).
-- The desktop half (gui.lua) intentionally registers nothing.
owner = "windows"
local preloaded = require("bone.ui.terminal")
assert(preloaded.open() == nil and #jobs == 0 and next_event == 0)
local term = load()
assert(term == preloaded)
local old_setup = term.setup
assert(commands.term.owner == "term" and commands.term.opts.aliases[1] == "terminal")
assert(commands.term.opts.desc ~= "")
for _, key in ipairs({ "ctrl+]", "ctrl+5" }) do
  assert(keys[key].owner == "term" and keys[key].opts.desc ~= "")
end
assert(next_event == 2 and events[1].owner == "term" and events[2].owner == "term")
term.setup(); assert(next_event == 2)
local old_paste = events[1].fn
command("close"); assert(notices[#notices] == "no terminal is open")
local encode = term.encode
assert(encode("ctrl+c") == "\3" and encode("ctrl+@") == "\0")
assert(encode("ctrl+]") == "\29" and encode("alt+x") == "\27x")
for key, byte in pairs({ ["4"] = 28, ["5"] = 29, ["6"] = 30, ["7"] = 31 }) do
  assert(encode("ctrl+" .. key) == string.char(byte))
end
assert(encode("up") == "\27[A" and encode("up", true) == "\27OA")
assert(encode("ctrl+shift+left") == "\27[1;6D")
assert(encode("f1") == "\27OP" and encode("alt+f5") == "\27[15;3~")
assert(encode("shift+tab") == "\27[Z" and encode("ctrl+backspace") == "\8")
assert(encode("é") == "é" and encode("super") == nil)
local p = keys["ctrl+]"].fn()
local j = jobs[1]
assert(p.id == "term1" and p.spec.dock == "bottom" and p.spec.size == 0.4)
assert(type(j.cmd) == "table" and j.opts.cwd == "/project space")
assert(j.opts.pty.width == 80 and j.opts.pty.height == 24)
local lines = p.spec.render({ width = 30, height = 8, focused = true })
assert(j.size.width == 30 and j.size.height == 8)
assert(lines[1][1][1] == "a" and lines[1][2][1] == "界" and lines[1][2][2] == "TermCursor")
assert(p.spec.on_key("up") and j.writes[#j.writes] == "\27OA")
assert(p.spec.on_key("esc") and j.writes[#j.writes] == "\27")
local writes = #j.writes
assert(p.spec.on_key("shift+pageup")); p.spec.render({ width = 30, height = 8 })
assert(j.size.scroll == 1 and #j.writes == writes)
assert(p.spec.on_key("shift+pagedown")); p.spec.render({ width = 30, height = 8 })
assert(j.size.scroll == 0)
assert(mouse({ panel = p.id, panel_row = 2, panel_col = 3, action = "down", button = "left" }))
assert(j.writes[#j.writes] == "\27[<0;3;2M")
assert(mouse({ panel = p.id, panel_row = 2, panel_col = 3, action = "up", button = "left" }))
assert(j.writes[#j.writes] == "\27[<3;3;2m")
writes = #j.writes
term.passthrough["alt+w"] = true
assert(p.spec.on_key("alt+w") == false)
assert(p.spec.on_key("ctrl+]") and focused == nil and #j.writes == writes)
paste("ignored"); assert(#j.writes == writes)
assert(keys["ctrl+5"].fn() == p and focused == p.id)
paste("two\nlines"); assert(j.writes[#j.writes] == "\27[200~two\nlines\27[201~")
writes = #j.writes
paste("private popup text", "popup"); paste("prompt text", "main")
assert(#j.writes == writes, "paste must follow effective focus, not the panel under a popup")
assert(p.spec.on_key("ctrl+5") and focused == nil)
p.spec.hidden = true
assert(term.toggle() == p and not p.spec.hidden)
-- Explicit duplicate ids must not cancel an existing job.
assert(not pcall(term.open, { id = p.id }))
assert(j.cancelled == 0 and term.job(p.id) == j)
assert(command(" close ") and j.cancelled == 1 and term.job(p.id) == nil)
assert(p.spec.on_key("x") == false and #p.spec.render({ width = 30, height = 8 }) == 0)
-- A closed panel's callbacks must not touch the next terminal with its id.
local p2 = command(" printf output ")
local j2 = jobs[2]
assert(p2.id == p.id and j2.cmd == "printf output")
p.spec.on_close(p); j.opts.on_exit({ code = 2, cmd = "stale" })
assert(j2.cancelled == 0 and panels[p2.id] == p2)
j2.opts.on_exit({ code = 0 }); assert(panels[p2.id] == p2)
j2.opts.on_exit({ code = 7, cmd = "printf" }); assert(notices[#notices] == "printf exited with 7")
j2.opts.on_exit({ error = "PTY failed" }); assert(notices[#notices] == "PTY failed")
local shell = term.open({ id = "shell", focus = false, dock = "right" }, { cwd = "/other" })
assert(jobs[3].opts.cwd == "/other" and not shell.spec.focus and shell.spec.dock == "right")
jobs[3].opts.on_exit({ code = 0 }); assert(not panels.shell and jobs[3].cancelled == 1)
-- Starting/opening errors leave neither a tracked job nor a panel.
fail_start = true; assert(not pcall(term.open)); fail_start = false
fail_open = true; assert(not pcall(term.open)); fail_open = false
assert(jobs[4].cancelled == 1 and term.job("term2") == nil)
-- Unloading a dependency that first required term can evict its cache entry.
package.loaded["bone.ui.terminal"] = nil
assert(require("bone.ui.terminal") == term and term.setup == old_setup)
assert(term.job(p2.id) == j2 and next_event == 2)
-- A windows-like wrapper keeps the same table/open trampoline across reload.
local original_open, wrapper_calls = term.open, 0
term.open = function(spec, opts) wrapper_calls = wrapper_calls + 1; return original_open(spec, opts) end
owner = "windows"
local foreign = term.open({ id = "foreign", on_close = function() error("user close error") end })
local foreign_job = jobs[5]
assert(foreign.owner == "windows" and foreign_job.owner == "windows")
assert(next_event == 2) -- handlers were not lazily registered as windows.
local old_shutdown = shutdowns[1]
old_shutdown()
assert(next(panels) == nil and next(events) == nil and term.job(foreign.id) == nil)
assert(j2.cancelled == 1 and foreign_job.cancelled == 1)
local n = #jobs
assert(term.open() == nil and #jobs == n)
old_paste({ text = "late" }); foreign_job.opts.on_exit({ error = "late" })
assert(notices[#notices] == "PTY failed")
old_shutdown(); assert(foreign_job.cancelled == 1)
assert(package.loaded["bone.ui.terminal"] == nil) -- Also evicted if preloaded by another owner.
local reloaded = load()
assert(reloaded == term and term.passthrough["alt+w"])
local fresh = term.open({ id = "foreign" })
assert(wrapper_calls >= 3 and panels.foreign == fresh)
assert(next_event == 4 and events[3].owner == "term" and events[4].owner == "term")
-- Old-generation callbacks and shutdown cannot cancel a new same-id terminal.
old_shutdown(); old_setup(); old_paste({ text = "late" }); foreign.spec.on_close(foreign)
assert(panels.foreign == fresh and jobs[#jobs].cancelled == 0)
fail_close = true
shutdowns[2]()
fail_close = false
assert(next(events) == nil and next(panels) == nil and jobs[#jobs].cancelled == 1)
-- close_all is also usable without unloading; it must keep paste active and
-- allow subsequent opens, while cancelling every terminal in its snapshot.
load()
local a = term.open({ id = "a" })
local ja = term.job(a.id)
local b = term.open({ id = "b", on_close = function() error("bad close") end })
local jb = term.job(b.id)
term.close_all()
assert(next(panels) == nil and ja.cancelled == 1 and jb.cancelled == 1 and events[5])
assert(term.toggle().id == "term1")
-- Keep the final visible screen when Bone evicts a finished job. Cursor
-- decoration must not mutate the retained screen or leak into blurred renders.
local retained = command("printf history")
local retained_job = term.job(retained.id)
function retained_job:screen(size)
  if self.evicted then return nil end
  size = size or { width = 30, height = 2 }
  local h, scroll, lines = size.height or 2, size.scroll or 0, {}
  local max = math.max(0, 6 - h)
  scroll = math.min(scroll, max)
  for i = 1, h do lines[i] = { { "line" .. (6 - h - scroll + i), "Normal" } } end
  return { lines = lines, scroll = scroll, max = max, cursor = { 1, 1 } }
end
retained_job.opts.on_exit({ code = 0 })
retained_job.evicted = true
local final = retained.spec.render({ width = 30, height = 2, focused = true })
assert(final[1][1][2] == "TermCursor")
local blurred = retained.spec.render({ width = 30, height = 2 })
assert(blurred[1][1][1] == "line5" and blurred[2][1][1] == "line6")
assert(blurred[1][1][2] == "Normal", "cached screen must not retain cursor decoration")
local resized = retained.spec.render({ width = 30, height = 6 })
assert(resized[1][1][1] == "line5" and resized[2][1][1] == "line6")
shutdowns[3]()
assert(next(panels) == nil and next(events) == nil)
print("term tests passed: registration/keys/encoding/cursor/scroll/paste/errors/close/unload/reload/windows wrapper/stale callbacks")
