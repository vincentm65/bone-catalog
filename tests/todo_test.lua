-- Run from the catalog root: luajit tests/todo_test.lua
local tools, chats, events = {}, {}, {}
local current, panel
local highlights = {}
bone = {
  hl = { set = function(name, spec) highlights[name] = spec end },
  tool = { register = function(spec) tools[spec.name] = spec end },
  chat = {
    items = function() return chats[current] end,
  },
  cmd = { create = function(name, fn) events["/" .. name] = fn end },
  on = function(name, fn) events[name] = fn end,
  defer = function(_, fn) fn() end,
  ui = { panel = { open = function(spec)
    panel = { spec = spec, hidden = false }
    function panel:is_open() return true end
    function panel:show() self.hidden = false end
    function panel:hide() self.hidden = true end
    return panel
  end } },
}
for _, f in ipairs({ "todo/core", "todo/tui" }) do dofile("plugins/" .. f .. ".lua") end

-- todo: validates, stores nothing.
local todo = tools.todo.run
assert(todo({ items = { { text = "a", status = "completed" }, { text = "b", status = "in_progress" } } }) == "[x] a\n[>] b")
assert(not todo({ items = { { text = "a", status = "done" } } }))
assert(todo({ items = {} }) == "list cleared")
assert(todo({ title = "Parser fixes", items = { { text = "fix", status = "pending" } } }) == "[ ] fix")
assert(not todo({ title = " ", items = {} }))
assert(not todo({ title = 42, items = {} }))

-- The panel shows only the on-screen chat's latest list, and hides for a
-- chat without one.
local function call(items, opts)
  local c = { done = true, arguments = { items = items } }
  for k, v in pairs(opts or {}) do c[k] = v end
  return c
end
chats.A = { call({ { text = "old", status = "pending" } }), call({ { text = "new", status = "in_progress" } }), call({}, { is_error = true }) }
chats.A[2].arguments.title = "Parser fixes"
current = "A"; events["tool/finished"]()
local lines = panel.spec.render()
assert(panel.spec.dock == "bottom" and panel.spec.title == false)
assert(lines[1][1][1] == "" and lines[2][1][1] == "Todo 0/1 — Parser fixes")
assert(lines[3][1][1] == "▸ " and lines[3][2][1] == "new" and lines[3][2][2] == "TodoActive")
assert(highlights.TodoCheck.fg == "green" and highlights.TodoDone.strikethrough)
chats.A[2].arguments.items[2] = { text = "finished", status = "completed" }
lines = panel.spec.render()
assert(lines[4][1][1] == "✓ " and lines[4][1][2] == "TodoCheck")
assert(lines[4][2][1] == "finished" and lines[4][2][2] == "TodoDone")
assert(lines[4][3].hl == "Normal", "strikethrough must not extend through row padding")
current = "B"; assert(#panel.spec.render() == 0 and panel.hidden)
events["turn/finished"]({ session_id = "B" }); assert(panel.hidden)
current = "A"; events["/todo"](); assert(not panel.hidden)
-- Completion never resurrects the older unfinished list, including on render/switch.
chats.A[2].arguments.items[1].status = "completed"
assert(#panel.spec.render() == 0 and panel.hidden)
events["tool/finished"](); assert(panel.hidden)
events["/todo"](); assert(panel.hidden)
chats.A[#chats.A + 1] = call({ { text = "next", status = "pending" } })
events["tool/finished"](); assert(not panel.hidden)
assert(panel.spec.render()[2][1][1] == "Todo 0/1")
chats.A[#chats.A + 1] = call({})
events["tool/finished"](); assert(panel.hidden)

print("todo: validation, per-chat isolation, title, spacing, completion hide and reopen passed")
