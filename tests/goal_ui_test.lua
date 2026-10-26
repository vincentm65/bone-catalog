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
assert(type(panel.spec.render) == "function" and type(panel.spec.node) == "function")
local lines = panel.spec.render({ width = 80 })
assert(lines[1][1][1] == "◎ " and lines[1][1][2] == "Accent")
assert(lines[1][2][1] == "make tests pass" and lines[1][2][2] == "Normal")
assert(lines[1][3][1] == "  turn 7  1m" and lines[1][3][2] == "Dim")
assert(lines[1][4][1] == "  check ✗" and lines[1][4][2] == "ErrorMsg")
assert(tui.clocks.refresh == 1 and tui.clocks.invalidate == 0)
-- A desktop build of the same band does not require the GUI when the
-- capability is off, and does not arm the terminal clock a second time.
local node = panel.spec.node()
assert(node[1].text == "◎ " and node[1].hl == "Accent")
assert(node[2].text == "make tests pass" and node[2].hl == "Normal")
assert(node[3].text == "  turn 7  1m" and node[3].hl == "Dim")
assert(node[4].text == "  check ✗" and node[4].hl == "ErrorMsg")
assert(tui.clocks.refresh == 2 and tui.clocks.invalidate == 0)

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
node = panel.spec.node()
assert(node[3].text == "  turn 7  1m")
assert(gui.clocks.invalidate == 1 and gui.clocks.ms == 30000 and gui.clocks.refresh == 0)
lines = panel.spec.render({ width = 40 })
assert(lines[1][1][1] == "◎ ")
assert(gui.clocks.refresh == 0 and gui.clocks.invalidate == 2)
assert(gui.commands.goal and gui.commands.goal.spec.desc:find("/goal", 1, true))

print("goal: terminal band, desktop node, 30s redraw and completion hide passed")
