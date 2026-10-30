-- Run from the catalog root: luajit tests/todo_test.lua
local tools, chats, events = {}, {}, {}
local current, panel
bone = {
  tool = { register = function(spec) tools[spec.name] = spec end },
  hook = function() end,
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
    panel = { spec = spec, hidden = false, title = spec.title }
    function panel:is_open() return true end
    function panel:show() self.hidden = false end
    function panel:hide() self.hidden = true end
    function panel:update(u) if u.title ~= nil then self.title = u.title end end
    return panel
  end } },
}
for _, f in ipairs({ "todo/core", "todo/ui" }) do dofile("plugins/" .. f .. ".lua") end

-- todo: validates, stores nothing.
local todo = tools.todo.run
assert(todo({ items = { { text = "a", status = "completed" }, { text = "b", status = "in_progress" } } }) == "[x] a\n[>] b\n1 open; mark each completed as you finish it.")
assert(not todo({ items = { { text = "a", status = "done" } } }))
assert(todo({ items = {} }) == "list cleared")
assert(todo({ title = "Parser fixes", items = { { text = "fix", status = "pending" } } }) == "[ ] fix\n1 open; mark each completed as you finish it.")
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
-- Opening a chat syncs both before and after its history arrives, without
-- needing a tool event or /todo. Switching back restores a hidden drawer.
current = "loading"; events["chat/shown"]()
assert(not panel, "empty loading chat must not open a drawer")
chats.loading = { call({ { text = "loaded", status = "pending" } }) }
events["chat/shown"]()
assert(panel and not panel.hidden, "loaded history must open the drawer")
current = "empty"; events["chat/shown"]()
assert(panel.hidden, "switching to an empty chat must hide the drawer")
current = "loading"; events["chat/shown"]()
assert(not panel.hidden, "switching back must restore the drawer")
chats.loading[1].arguments.items[1].status = "completed"
events["chat/shown"]()
assert(panel.hidden, "a completed list must stay hidden on chat/shown")

chats.A = { call({ { text = "old", status = "pending" } }), call({ { text = "new", status = "in_progress" } }), call({}, { is_error = true }) }
chats.A[2].arguments.title = "Parser fixes"
current = "A"; events["tool/finished"]()
-- One view for both frontends: the list as a checklist, the title the panel's.
local view = panel.spec.view()
assert(panel.spec.dock == "bottom" and not panel.spec.render and not panel.spec.node)
assert(panel.title == "Todo 0/1 — Parser fixes")
assert(view.kind == "checklist" and view.items[1].text == "new" and view.items[1].state == "active")
chats.A[2].arguments.items[2] = { text = "finished", status = "completed" }
view = panel.spec.view()
assert(view.items[2].text == "finished" and view.items[2].state == "done")
current = "B"; assert(panel.spec.view() == nil and panel.hidden)
events["turn/finished"]({ session_id = "B" }); assert(panel.hidden)
current = "A"; events["/todo"](); assert(not panel.hidden)
-- Completion never resurrects the older unfinished list, including on draw/switch.
chats.A[2].arguments.items[1].status = "completed"
assert(panel.spec.view() == nil and panel.hidden)
events["tool/finished"](); assert(panel.hidden)
events["/todo"](); assert(panel.hidden)
chats.A[#chats.A + 1] = call({ { text = "next", status = "pending" } })
events["tool/finished"](); assert(not panel.hidden)
assert(panel.title == "Todo 0/1" and panel.spec.view().items[1].state == "todo")
chats.A[#chats.A + 1] = call({})
events["tool/finished"](); assert(panel.hidden)

-- The list survives any number of later tool calls (no window limit).
chats.A[#chats.A + 1] = call({ { text = "long-lived", status = "in_progress" } })
events["tool/finished"](); assert(not panel.hidden)
for _ = 1, 8 do chats.A[#chats.A + 1] = { done = true, name = "other", arguments = {} } end
events["tool/finished"]()
assert(not panel.hidden and panel.title == "Todo 0/1", "list lost after later tool calls")
-- A running call does not replace the previous list until it finishes.
chats.A[#chats.A + 1] = running({ { text = "not yet", status = "pending" } })
events["tool/finished"]()
assert(panel.spec.view().items[1].text == "long-lived", "running call shown")
chats.A[#chats.A].done = true
events["tool/finished"]()
assert(panel.spec.view().items[1].text == "not yet", "finished call not shown")

print("todo: validation, per-chat isolation, title, completion hide, reopen, history window and running calls passed")
