-- Run from the catalog root: luajit tests/task_loop_test.lua
-- Exercise both plugin halves against the same persistent-state interface.
package.path = "plugins/task_loop/lua/?.lua;" .. package.path

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

local files, hooks, queued, commands, events = {}, {}, {}, {}, {}
local tool, panel, current, prompt, notice
local prefs = {}
bone = {
  sha256 = function(id) return "hash_" .. id end,
  state = {
    load = function(name, opts)
      assert(opts.shared == true)
      return copy(files[name] or {})
    end,
    save = function(name, value, opts)
      assert(opts.shared == true)
      files[name] = copy(value)
    end,
  },
  tool = { register = function(spec) tool = spec end },
  hook = function(name, fn) hooks[name] = fn end,
  queue = { add = function(id, text, mode)
    queued[#queued + 1] = { session_id = id, text = text, mode = mode }
  end },
  chat = { session = function() return current and { session_id = current } end },
  plugin = { state = function() return prefs end, save_state = function() end },
  cmd = { create = function(name, fn) commands[name] = fn end },
  on = function(name, fn) events[name] = fn end,
  notify = function(text) notice = text end,
  prompt = { set = function(text) prompt = text end },
  ui = { panel = {
    open = function(spec)
      panel = { spec = spec, top = 0, hidden = false }
      function panel:info() return { top = self.top, height = 8, hidden = self.hidden } end
      function panel:is_open() return true end
      function panel:scroll(by) self.top = math.max(0, self.top + by) end
      function panel:update(opts) self.spec.title = opts.title end
      function panel:show() self.hidden = false end
      function panel:hide() self.hidden = true end
      function panel:focus() end
      return panel
    end,
    focus = function() end,
  } },
}
setmetatable(bone.cmd, { __call = function(_, text)
  local name, args = text:match("^(%S+)%s*(.*)$")
  commands[name]({ args = args })
end })

local store = require("task_loop.state")
local function run(id, action, extra)
  local args = copy(extra or {})
  args.action = action
  local result, err = tool.run(args, { session_id = id })
  assert(result, err)
  return result
end
local function context(id)
  local ev = { session_id = id, messages = { { role = "system", content = "base" } } }
  hooks.context(ev)
  return ev.messages
end
local function end_turn(id, status)
  hooks.turn_end({ session_id = id, outcome = { status = status } })
end
local function draw()
  local rows = panel.spec.render({ focused = false })
  local out = {}
  for _, row in ipairs(rows) do
    for _, span in ipairs(row) do out[#out + 1] = span[1] or "" end
  end
  return table.concat(out, "\n")
end

-- An unowned legacy list cannot silently become any session's task loop.
files.task_loop = { active = true, tasks = { { text = "legacy task", done = false } } }
dofile("plugins/task_loop/core.lua")
assert(run("A", "status") == "no tasks")
assert(#context("A") == 1)
end_turn("A", "completed")
assert(#queued == 0)
local result, err = tool.run({ action = "write", tasks = { "orphan" } }, {})
assert(result == nil and err:find("requires a session", 1, true))

run("A", "write", { tasks = { "A first", "A second" } })
run("B", "write", { tasks = { "B first", "B second" }, session_id = "A" })
assert(context("A")[2].content:find("A first", 1, true))
assert(not context("A")[2].content:find("B first", 1, true))
assert(context("B")[2].content:find("B first", 1, true))
assert(#context("child") == 1 and #context("fork") == 1)

-- Mutations and turn continuations only use the calling session's state.
run("A", "advance")
assert(store.load("A").tasks[1].done)
assert(not store.load("B").tasks[1].done)
run("A", "stop")
assert(not store.load("A").active and store.load("B").active)
assert(#context("A") == 1)
end_turn("A", "completed")
end_turn("B", "cancelled")
end_turn("B", "failed")
assert(#queued == 0)
end_turn("B", "completed")
assert(#queued == 1 and queued[1].session_id == "B" and queued[1].mode == "next")
run("A", "resume")
run("A", "complete", { index = 2 })
assert(not store.load("A").active)
run("A", "resume")
assert(not store.load("A").active, "a completed list must not resume")
run("A", "clear")
assert(run("A", "status") == "no tasks" and store.load("B").active)

-- A fresh core reads the persisted list without an in-memory global cache.
run("A", "write", { tasks = { "A visible", "A remaining" } })
dofile("plugins/task_loop/core.lua")
assert(run("A", "status"):find("A visible", 1, true))
assert(run("B", "status"):find("B first", 1, true))

current = "A"
dofile("plugins/task_loop/tui.lua")
commands.tasks({ args = "" })
assert(draw():find("A visible", 1, true) and not draw():find("B first", 1, true))
assert(panel.spec.title == "Tasks 2/2")
panel.top = 8
current = "B"
assert(draw():find("B first", 1, true) and not draw():find("A visible", 1, true))
assert(panel.top == 0 and panel.spec.title == "Tasks 2/2")
commands.task({ args = "B manual" })
assert(#store.load("B").tasks == 3 and #store.load("A").tasks == 2)
assert(draw():find("B manual", 1, true))

-- Switch immediately before editing, without an intervening render.
current = "A"
panel.spec.keys.enter()
assert(store.load("A").tasks[1].done and not store.load("B").tasks[1].done)
assert(panel.spec.title == "Tasks 1/2")

-- Real tool/finished payloads have no name field; background results stay
-- in their owning session, while foreground results refresh the sidebar.
run("B", "advance")
events["tool/finished"]({ session_id = "B", call_id = "background", output = "done" })
assert(draw():find("A visible", 1, true) and not draw():find("B first", 1, true))
run("A", "advance")
events["tool/finished"]({ session_id = "A", call_id = "foreground", output = "done" })
assert(panel.spec.title == "Tasks 0/2" and not store.load("A").active)

-- UI edits reload the core's state instead of overwriting newer tasks.
run("A", "write", { tasks = { "fresh from core" } })
commands.task({ args = "fresh from UI" })
assert(#store.load("A").tasks == 2 and store.load("A").tasks[1].text == "fresh from core")
assert(store.load("A").active)
panel.spec.keys.enter() -- selected UI item
panel.spec.keys.up()
panel.spec.keys.enter() -- final unfinished item stops the loop
assert(not store.load("A").active)
panel.spec.keys.x()
assert(#store.load("A").tasks == 0 and #store.load("B").tasks == 3)
current = "B"
panel.spec.keys.s()
assert(prompt == "B first")
panel.spec.keys.d()
assert(#store.load("B").tasks == 2 and #store.load("A").tasks == 0)

-- Unsaved new chats have no generic/default state, and showing/hiding a
-- sidebar cannot write stale tasks or change another session's active flag.
current = nil
assert(not draw():find("B manual", 1, true))
commands.task({ args = "unsaved" })
assert(notice:find("create this session", 1, true))
assert(#store.load("B").tasks == 2)
commands.tasks({ args = "" })
commands.tasks({ args = "" })
assert(files.task_loop.tasks[1].text == "legacy task" and files.task_loop.active)
assert(files["task_loop.hash_default"] == nil)
print("task_loop: session isolation, continuation, persistence and sidebar tests passed")
