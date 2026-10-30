-- Run from the catalog root: luajit tests/goal_ui_test.lua
local function boot(gui_on)
  local panel, requests, events, commands, notes, shutdown = nil, {}, {}, {}, {}, nil
  local clocks = { refresh = 0, invalidate = 0 }
  bone = {
    api = { session = function() return { session_id = "s1" } end, open_session = function() end },
    chat = { session = function() return { cwd = "/tmp", session_id = "s1" } end },
    notify = function(text, level) notes[#notes + 1] = { text, level } end,
    request = function(method, params, cb) requests[#requests + 1] = { method = method, params = params, cb = cb } end,
    cmd = { create = function(name, fn, spec) commands[name] = { fn = fn, spec = spec } end },
    on = function(name, fn) events[name] = fn end,
    plugin = { on_shutdown = function(fn) shutdown = fn end },
    has_capability = function(name) return gui_on and name == "gui.nodes" end,
    gui = { invalidate = function(ms) clocks.invalidate = clocks.invalidate + 1; clocks.ms = ms end },
    ui = {
      refresh_in = function() clocks.refresh = clocks.refresh + 1 end,
      panel = { open = function(spec)
        panel = { spec = spec, hidden = false, open = true }
        function panel:is_open() return self.open end
        function panel:show() self.hidden = false end
        function panel:hide() self.hidden = true end
        function panel:close() self.open = false end
        function panel:update() end
        return panel
      end },
    },
    text = {
      width = function(s) return #s end,
      truncate = function(s, n) assert(n >= 8); return s end,
      clip = function(line) return line end,
    },
  }
  dofile("plugins/goal/ui.lua")
  return {
    requests = requests, events = events, commands = commands, notes = notes, clocks = clocks,
    panel = function() return panel end, shutdown = function() return shutdown end,
  }
end

local function show(env, goal)
  env.events.ready()
  local list = env.requests[#env.requests]
  assert(list.method == "lua/call" and list.params.name == "goal.list")
  list.cb({ "s1" })
  local get = env.requests[#env.requests]
  assert(get.params.name == "goal.get" and get.params.args.session_id == "s1")
  get.cb(goal)
  return env.panel()
end

local now = os.time()
local goal = {
  session_id = "s1", status = "running", text = "make tests pass", turns = 6,
  started_at = now - 90, check_ok = false,
}

local tui = boot(false)
local panel = show(tui, goal)
assert(panel and not panel.hidden)
assert(panel.spec.dock == "bottom" and panel.spec.title == false and panel.spec.focusable == false)
assert(panel.spec.size == nil)
assert(type(panel.spec.view) == "function" and not panel.spec.render and not panel.spec.node)
-- One band for both frontends: the goal on one line, cut to fit.
local band = panel.spec.view()
assert(band.kind == "row")
assert(band[1].text == "◎" and band[1].tone == "accent")
assert(band[2].text == "make tests pass" and band[2].truncate)
assert(band[3].text == "turn 7 · 1m" and band[3].tone == "dim")
assert(band[4].text == "check ✗" and band[4].tone == "error")
assert(tui.clocks.refresh == 1 and tui.clocks.invalidate == 0)

tui.events["turn/finished"]({ session_id = "s1" })
local again = tui.requests[#tui.requests]
assert(again.params.name == "goal.get")
again.cb({ session_id = "s1", status = "done", text = "make tests pass", turns = 7, started_at = now - 90, ended_at = now })
assert(panel.hidden)
assert(tui.notes[1][1]:find("done", 1, true))
tui.shutdown()()
assert(not panel.open)

local gui = boot(true)
panel = show(gui, goal)
assert(panel.spec.size == 1)
assert(gui.clocks.refresh == 0 and gui.clocks.invalidate == 0)
band = panel.spec.view()
assert(band[3].text == "turn 7 · 1m")
assert(gui.clocks.invalidate == 1 and gui.clocks.ms == 30000 and gui.clocks.refresh == 0)
assert(gui.commands.goal and gui.commands.goal.spec.desc:find("/goal", 1, true))

print("goal: one band view, 30s redraw in each frontend and completion hide passed")
