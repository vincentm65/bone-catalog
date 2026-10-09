-- Run from the catalog root: luajit tests/todo_test.lua
local tools, chats, events = {}, {}, {}
local current, panel
local highlights = {}
bone = {
  hl = { set = function(name, spec) highlights[name] = spec end },
  tool = { register = function(spec) tools[spec.name] = spec end },
  chat = {
    items = function(opts)
      local out = {}
      for _, c in ipairs(chats[current] or {}) do
        local kind = c.kind or "tool"
        local name = c.name or "todo"
        local kind_ok = (not opts or not opts.kind) or kind == opts.kind
        local name_ok = (not opts or not opts.name) or name == opts.name
        if kind_ok and name_ok then out[#out + 1] = c end
      end
      if opts and opts.last then
        local n, cut = #out, math.max(0, #out - opts.last)
        local tail = {}
        for i = cut + 1, n do tail[#tail + 1] = out[i] end
        out = tail
      end
      return out
    end,
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
-- A call that has started but not finished: the drawer keeps the previous list.
local function running(items)
  return { done = false, arguments = { items = items } }
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

-- The list survives any number of later tool calls (no window limit).
chats.A[#chats.A + 1] = call({ { text = "long-lived", status = "in_progress" } })
events["tool/finished"](); assert(not panel.hidden)
for _ = 1, 8 do chats.A[#chats.A + 1] = { done = true, name = "other", arguments = {} } end
events["tool/finished"]()
assert(not panel.hidden and panel.spec.render()[2][1][1] == "Todo 0/1", "list lost after later tool calls")
-- A running call does not replace the previous list until it finishes.
chats.A[#chats.A + 1] = running({ { text = "not yet", status = "pending" } })
events["tool/finished"]()
assert(panel.spec.render()[2][1][1] == "Todo 0/1", "running call shown")
assert(panel.spec.render()[3][2][1] == "long-lived", "running call shown")
chats.A[#chats.A].done = true
events["tool/finished"]()
assert(panel.spec.render()[3][2][1] == "not yet", "finished call not shown")

print("todo: validation, per-chat isolation, title, spacing, completion hide, reopen, history window and running calls passed")
