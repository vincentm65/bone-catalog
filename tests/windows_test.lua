-- Run from catalog root: luajit tests/windows_test.lua [plugins/windows]
local root = arg[1] or "plugins/windows"
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end
local buffers, current, opens = {}, 0, 0
local function reset()
  buffers, current, opens = { [0] = { chat = 0, new = true, items = 0, draft = "draft zero" } }, 0, 0
end
local function total()
  local n = 0
  for _ in pairs(buffers) do n = n + 1 end
  return n
end
local function load(saved, reloading, frontend, with_terminal)
  local vm = { state = copy(saved or {}), events = {}, timers = {}, commands = {}, shutdowns = {}, rects = {}, keys = {}, panels = {} }
  local window = { embedded = {}, area = function() return { plain = true } end, column = function(_, opts) return { chat = opts.chat } end,
    panel = function(id, ctx) return { panel = id, width = ctx.width, height = ctx.height } end }
  function window.embed(id)
    local owner = {}
    window.embedded[id] = owner
    return function() if window.embedded[id] == owner then window.embedded[id] = nil end end
  end
  vm.window = window
  local modules = {
    ["bone.nodes.window"] = window,
    ["bone.nodes.style"] = { size = {}, radius = {}, alpha = function() return "#4488ff18" end, hover = function() end },
  }
  local bone = {
    settings = { get = function() end }, hl = { set = function() end },
    plugin = { state = function() return vm.state end, on_shutdown = function(fn) vm.shutdowns[#vm.shutdowns + 1] = fn end },
    on = function(name, fn)
      vm.events[name] = vm.events[name] or {}
      table.insert(vm.events[name], fn)
    end,
    defer = function(_, fn) vm.timers[#vm.timers + 1] = fn end,
    keymap = { set = function(key, fn, opts) vm.keys[(opts and opts.context or "main") .. ":" .. key] = fn end,
      context = function() end, focus = function() end, clear = function() end },
    cmd = { create = function(name, fn) vm.commands[name] = fn end },
    ui = { layout = { "chat", "input_gap", "prompt", "statusline" }, regions = {}, panel = {
      focused = function() end, close = function() end,
    } },
    chat = {}, api = {},
    now = function() return 0 end,
    gui = { invalidate = function() end, rect = function(id) return vm.rects[id] end,
      panel_node = function(id) return vm.panels[id] ~= nil end },
  }
  local focused
  function bone.ui.panel.focused() return focused end
  function bone.ui.panel.focus(id)
    if id then
      local p = assert(vm.panels[id], "missing panel")
      assert(not p.hidden and p.focusable, "panel cannot take focus")
    end
    if focused == id then return end
    focused = id
    for _, fn in ipairs(vm.events["focus/changed"] or {}) do fn({ panel = id, context = id and "panel" or "main" }) end
  end
  function bone.ui.panel.get(id) return vm.panels[id] end
  function bone.ui.panel.open(p)
    local focus = p.focus == true
    p.focusable = p.focusable ~= false
    function p:info() return self end
    function p:show() self.hidden = false end
    function p:focus() bone.ui.panel.focus(self.id) end
    vm.panels[p.id] = p
    if focus then p:focus() end
    return p
  end
  function bone.ui.panel.update(id, spec)
    for k, v in pairs(spec) do vm.panels[id][k] = v end
    if vm.panels[id].hidden and focused == id then bone.ui.panel.focus(nil) end
  end
  function bone.ui.panel.close(id)
    if not vm.panels[id] then return false end
    vm.panels[id] = nil
    if focused == id then bone.ui.panel.focus(nil) end
    for _, fn in ipairs(vm.events["panel/closed"] or {}) do fn({ id = id }) end
    return true
  end
  if with_terminal then
    local last
    local terminal = { passthrough = {} }
    terminal.open = function(spec, opts)
      if vm.fail_open then error("terminal failed to open") end
      local n = 1
      while vm.panels["term" .. n] do n = n + 1 end
      local id = spec and spec.id or "term" .. n
      local panel = bone.ui.panel.open({ id = id, cmd = opts and opts.cmd or "shell", hidden = false, focus = true })
      last = id
      if not spec and window.attach_panel then window.attach_panel(id) end
      return panel
    end
    terminal.toggle = function()
      local panel = vm.panels[last]
      if not panel then return terminal.open() end
      panel:show(); panel:focus()
      return panel
    end
    terminal.job = function(id)
      return vm.panels[id] and { status = function() return { cmd = vm.panels[id].cmd } end }
    end
    modules["bone.terminal"], modules["bone.ui.terminal"], vm.terminal = terminal, terminal, terminal
  end
  vm.view = function() return window.area({ width = 1000, height = 700 }) end
  function bone.chat.session(opts)
    return buffers[opts and tonumber(opts.session) or current]
  end
  function bone.chat.open(sid)
    opens = opens + 1
    if sid then
      for chat, s in pairs(buffers) do if s.session_id == sid then return chat end end
    end
    local chat = total()
    buffers[chat] = { chat = chat, session_id = sid, new = sid == nil, items = sid and 2 or 0, draft = "" }
    return chat
  end
  function bone.api.open_session(id)
    local chat = tonumber(id)
    if not chat then chat = bone.chat.open(id) end
    current = chat
    for _, fn in ipairs(vm.events["chat/shown"] or {}) do fn({chat = chat, session_id = buffers[chat].session_id}) end
  end
  vm.bone = bone
  -- The plugin's own modules (lua/), each loaded once; no terminal.
  local env, loaded = nil, {}
  env = setmetatable({ bone = bone, require = function(name)
    if modules[name] then return modules[name] end
    if loaded[name] == nil then
      local chunk = loadfile(root .. "/lua/" .. name:gsub("%.", "/") .. ".lua")
      if not chunk then error("no " .. name .. " in this test") end
      loaded[name] = setfenv(chunk, env)()
    end
    return loaded[name]
  end }, { __index = _G })
  setfenv(assert(loadfile(root .. "/" .. (frontend or "tui") .. ".lua")), env)()
  for _, fn in ipairs(vm.events.ready or {}) do fn({ reload = reloading or nil }) end
  return vm
end
local function settle(vm)
  while #vm.timers > 0 do table.remove(vm.timers, 1)() end
end
local function command(vm, args) vm.commands.win({args = args}) end
local function bars(node)
  if type(node) == "string" then return node:match("^wm_bar:") and 1 or 0 end
  local n = 0
  for _, child in ipairs(node.rows or node.cols or node) do n = n + bars(child) end
  return n
end
local function reload(vm)
  local next_vm = load(vm.state, true)
  -- Like Rust: validate the new state before retiring the old one, then
  -- run the new state's deferred callbacks only if the reload was accepted.
  for _, fn in ipairs(vm.shutdowns) do fn() end
  settle(next_vm)
  return next_vm
end

reset()
local vm = load()
settle(vm)
assert(total() == 1 and opens == 0, "initial chat zero must be reused")
command(vm, "vsplit")
buffers[current].draft = "draft one"
command(vm, "split")
buffers[current].draft = "draft two"
command(vm, "next")
assert(current == 0 and total() == 3)
command(vm, "zoom")
assert(bars(vm.bone.ui.layout) == 0, "zoom hides the split tree")
local before = opens
for _ = 1, 3 do
  vm = reload(vm)
  assert(bars(vm.bone.ui.layout) == 0, "Lua reload must preserve zoom instead of reopening side windows")
  assert(total() == 3 and opens == before, "reload must reuse blank chat buffers, not allocate replacements")
  assert(current == 0 and buffers[0].draft == "draft zero" and buffers[1].draft == "draft one" and buffers[2].draft == "draft two")
end
command(vm, "zoom")
assert(bars(vm.bone.ui.layout) == 3, "unzoom restores all the original windows")
command(vm, "rotate")
local saved = copy(vm.state)
vm = reload(vm)
assert(bars(vm.bone.ui.layout) == 3 and total() == 3 and opens == before)
assert(vm.state.tree.dir == saved.tree.dir and vm.state.tree.kids[1].chat == saved.tree.kids[1].chat, "preserve window order")

-- Background blank chats can gain a session without becoming focused.
buffers[1].session_id, buffers[1].new = "background-session", false
vm = reload(vm)
local function find(node, chat)
  if node.chat == chat then return node end
  for _, kid in ipairs(node.kids or {}) do local found = find(kid, chat); if found then return found end end
end
assert(find(vm.state.tree, 1).sid == "background-session", "refresh session identity from the existing buffer")

-- A candidate that later fails ready must not allocate or switch chats.
local rejected = load(vm.state, true)
assert(opens == before and current == 0, "candidate loading must not change Rust-owned chats before acceptance")
rejected.timers = {}
assert(bars(vm.bone.ui.layout) == 3 and total() == 3)

-- Only closes the tree for good, including on subsequent reloads.
command(vm, "only")
assert(vm.state.tree == nil)
vm = reload(vm)
assert(vm.state.tree == nil and bars(vm.bone.ui.layout) == 0 and total() == 3)

-- On a fresh process, saved numeric buffer IDs must never be reused.
reset()
buffers[1] = {chat = 1, new = true, items = 0, draft = "unrelated process draft"}
local restart = load(saved, false)
settle(restart)
assert(total() == 4, "restart must create the two nonfocused blank chats rather than trust stale chat numbers")
assert(buffers[1].draft == "unrelated process draft" and not find(restart.state.tree, 1))

-- Legacy saved layouts still restore, preserving unequal split sizes.
reset()
local legacy = load({ tree = {dir = "cols", w = 1, kids = {
  {sid = "saved-session", w = 3}, {w = 1, focus = true},
}} })
settle(legacy)
assert(bars(legacy.bone.ui.layout) == 2 and legacy.state.tree.kids[1].w == 3 and legacy.state.tree.kids[2].w == 1)
vm = reload(legacy)
assert(vm.state.tree.kids[1].w == 3 and vm.state.tree.kids[2].w == 1 and current == 0)
print("windows: reload preserves zoom, blank buffers, drafts, focus, order and sizes; failed candidates and restarts are safe")

-- GUI event positions: drag is window-relative; release is title-relative.
local function node_with(node, id)
  if node.id == id then return node end
  for _, child in ipairs(node) do
    local found = node_with(child, id)
    if found then return found end
  end
end
local function gui_pair()
  reset()
  local g = load(nil, false, "gui")
  settle(g)
  command(g, "vsplit")
  local view = g.view()
  local a, b = view[1][1].id, view[1][3].id
  -- Deliberately offset from the window origin, as with an open sidebar.
  g.rects["wm:area"] = { x = 100, y = 40, w = 1000, h = 700 }
  g.rects[a] = { x = 100, y = 40, w = 496, h = 700 }
  g.rects[b] = { x = 603, y = 40, w = 497, h = 700 }
  g.rects[a:gsub("wm:", "wm:bar:")] = { x = 100, y = 40, w = 496, h = 28 }
  local title_id = a:gsub("wm:", "wm:bar:")
  local function title() return assert(node_with(g.view(), title_id)) end
  return g, title
end
local function leaves(node)
  if node.chat then return { node.chat } end
  local out = {}
  for _, k in ipairs(node.kids or {}) do
    for _, chat in ipairs(leaves(k)) do out[#out + 1] = chat end
  end
  return out
end

local g, title = gui_pair()
title().on_press()
assert(current == 0, "pressing an inactive title focuses it")
title().on_release({ x = 750, y = 300 })
assert(leaves(g.state.tree)[1] == 0, "clicking must not swap")
title().on_drag({ x = 850, y = 350 })
assert(not node_with(g.view(), "wm:drop"), "a stale drag after release is ignored")
title().on_press()
title().on_drag({ x = 850, y = 350 })
local preview = assert(node_with(g.view(), "wm:drop"))
assert(preview.left == 503 and preview.top == 0 and preview.width == 497 and preview.height == 700,
  "center preview uses painted geometry relative to the area")
assert(leaves(g.state.tree)[1] == 0, "preview must not mutate the tree")
-- Rebuild between callbacks, as real focus/invalidation does.
title().on_release({ x = 750, y = 310 })
assert(leaves(g.state.tree)[1] == 1 and leaves(g.state.tree)[2] == 0, "center swaps")
assert(current == 0 and buffers[0].draft == "draft zero", "moving keeps focus and drafts with the chat")
assert(not node_with(g.view(), "wm:drop"), "release removes preview")

for _, case in ipairs({
  { "left", 605, 350, "cols", 0 },
  { "right", 1098, 350, "cols", 1 },
  { "up", 850, 42, "rows", 0 },
  { "down", 850, 738, "rows", 1 },
}) do
  g, title = gui_pair()
  title().on_press()
  title().on_drag({ x = case[2], y = case[3] })
  preview = assert(node_with(g.view(), "wm:drop"))
  assert((case[4] == "cols" and preview.width == 245) or
    (case[4] == "rows" and preview.height == 346), case[1] .. " half preview excludes the separator")
  title().on_release({ x = case[2] - 100, y = case[3] - 40 })
  assert(g.state.tree.dir == case[4] and leaves(g.state.tree)[1] == case[5], case[1] .. " edge moves into a split")
  assert(not node_with(g.view(), "wm:drop") and current == 0)
end

for _, pos in ipairs({ { x = 200, y = 300 }, { x = 600, y = 300 }, { x = -10, y = 300 } }) do
  g, title = gui_pair()
  title().on_press()
  title().on_drag({ x = 850, y = 350 })
  title().on_release({ x = pos.x - 100, y = pos.y - 40 })
  assert(leaves(g.state.tree)[1] == 0 and not node_with(g.view(), "wm:drop"),
    "release on source, divider or outside cancels, even after a valid preview")
end

g, title = gui_pair()
local target = g.rects[g.view()[1][3].id]
target.w = 360
title().on_press()
title().on_drag({ x = 605, y = 350 })
assert(node_with(g.view(), "wm:drop").width == 360, "too-small edge previews a swap")
title().on_release({ x = 505, y = 310 })
assert(leaves(g.state.tree)[1] == 1, "too-small edge swaps instead of splitting")

g, title = gui_pair()
title().on_press()
command(g, "zoom")
title().on_drag({ x = 850, y = 350 })
title().on_release({ x = 750, y = 310 })
assert(not node_with(g.view(), "wm:drop") and leaves(g.state.tree)[1] == 0, "zoom disables pane dragging")
-- Interrupting a drag must not leave a preview whose title no longer exists.
g, title = gui_pair()
command(g, "split")
title().on_press()
title().on_drag({ x = 850, y = 350 })
local stale = title()
command(g, "close")
assert(not node_with(g.view(), "wm:drop"), "closing the captured source removes its preview")
stale.on_drag({ x = 850, y = 350 })
assert(not node_with(g.view(), "wm:drop"), "a removed source cannot restart dragging")

-- Resizing uses painted subtree bounds, not the larger ctx estimate.
g, title = gui_pair()
local view = g.view()
local a, b = g.rects[view[1][1].id], g.rects[view[1][3].id]
a.w, b.x, b.w = 346.5, 453.5, 346.5
local divider = view[1][2]
divider.on_drag({ x = 450, y = 350 })
divider.on_release()
assert(math.abs(g.state.tree.kids[1].w - 1) < 0.001, "resizing at the measured midpoint must not jump")
divider.on_drag({ x = 500, y = 350 })
divider.on_release()
assert(g.state.tree.kids[1].w > 1 and g.state.tree.kids[2].w < 1, "divider drag resizes and persists weights")
print("windows GUI: title dragging previews and moves all edges, swaps centers, respects minimums, cancels safely and keeps focus/drafts; resize uses measured bounds")

-- The GUI adds the same terminal window key/command as the TUI. The runtime
-- owns ctrl+]/ctrl+5 and /term; all of them go through this open trampoline.
reset()
g = load(nil, false, "gui", true)
settle(g)
local tkey = assert(g.keys["main:alt+w t"])
assert(g.keys["panel:alt+w t"], "terminal prefix binding exists in panel context too")
tkey()
assert(g.panels.term1 and g.bone.ui.panel.focused() == "term1" and g.window.embedded.term1,
  "prefix then t opens and focuses an embedded terminal")
assert(total() == 1 and current == 0, "terminal panes do not allocate or switch chat buffers")
local term_view = g.view()[1][3]
assert(term_view[2].panel == "term1" and term_view[2].height == 672,
  "terminal content fills its pane below the title")
assert(g.terminal.passthrough["alt+w"], "window prefix is available inside the terminal")
command(g, "zoom")
assert(g.view()[1][2].panel == "term1", "zoomed terminal renders instead of the chat")
g.bone.ui.panel.focus(nil)
assert(g.view()[1][3], "terminal escape returns to a visible chat even from terminal zoom")
command(g, "zoom")
assert(g.panels.term1.hidden, "zooming another pane hides the terminal")
g.terminal.toggle()
assert(not g.panels.term1.hidden and g.bone.ui.panel.focused() == "term1" and g.view()[1][3],
  "shortcut refocus reveals the terminal even when zoomed away")
g.bone.ui.panel.focus(nil)
g.terminal.open(nil, { cmd = "cat" })
assert(g.panels.term2.cmd == "cat" and g.window.embedded.term2,
  "/term command opens a tiled terminal using the panel attachment hook")
command(g, "close")
assert(not g.panels.term2 and not g.window.embedded.term2, "closing the terminal removes its panel and placement")
g.keys["panel:alt+w t"]()
assert(g.panels.term2, "prefix then t works from inside another terminal")
command(g, "only")
assert(g.panels.term2 and not g.panels.term1 and g.window.embedded.term2,
  "only keeps the active terminal, not the last chat")
assert(g.view()[1][2].panel == "term2", "a terminal can be the sole pane")
g.bone.ui.panel.focus(nil)
assert(g.view()[1][3] and current == 0 and total() == 1,
  "escaping a sole terminal restores the existing chat without allocating a buffer")
command(g, "only")
assert(not next(g.panels) and not next(g.window.embedded), "only from chat closes the other content")
assert(buffers[0].draft == "draft zero", "terminal keys preserve the chat draft")
g.window.embedded.foreign = true
g.fail_open = true
local ok = pcall(tkey)
assert(not ok and not next(g.panels) and not g.window.embedded.term1 and g.view().plain,
  "failed terminal start rolls back its pane and placement")
for _, fn in ipairs(g.shutdowns) do fn() end
assert(not g.terminal.passthrough["alt+w"] and not g.window.embedded.term1, "shutdown restores the terminal prefix and placements")
assert(g.window.embedded.foreign, "cleanup leaves other plugins' embedded panels alone")
print("windows GUI: terminal key/command parity, embedded rendering, zoom/refocus, close and shutdown")

-- Flattening preserves a subtree's share even when child weights are unequal.
reset()
local nested = load({ tree = { dir = "cols", w = 1, kids = {
  { sid = "a", w = 2, focus = true },
  { dir = "rows", w = 6, kids = {
    { dir = "cols", w = 1, kids = { { sid = "b", w = 3 }, { sid = "c", w = 1 } } },
    { sid = "d", w = 1 },
  } },
} } }, false, "gui")
settle(nested)
local title = node_with(nested.view(), "wm:bar:4")
title[#title].on_click()
local kids = nested.state.tree.kids
assert(kids[1].w == 2 and kids[2].w == 4.5 and kids[3].w == 1.5, "collapse preserves normalized shares")

-- Repeated keys before repaint accumulate instead of rereading stale widths.
local repeated = gui_pair()
repeated.keys["main:alt+w >"]()
repeated.keys["main:alt+w >"]()
assert(math.abs(repeated.state.tree.kids[2].w - (1 + 192 / 993)) < 1e-9)

-- Mouse and keyboard use the same measured pair, even below both minima.
local cramped = gui_pair()
cramped.rects["wm:1"].w, cramped.rects["wm:2"].w = 80, 40
for _, key in ipairs({ ">", "<", ">", "<" }) do
  cramped.keys["main:alt+w " .. key]()
  local k = cramped.state.tree.kids
  assert(k[1].w == 1 and k[2].w == 1, "cramped keyboard resize has positive, conserved weights")
end
local divider = cramped.view()[1][2]
divider.on_drag({ x = 2000, y = 40 })
assert(cramped.state.tree.kids[1].w == 1 and cramped.state.tree.kids[2].w == 1,
  "cramped mouse resize uses the same minimum")

-- Panel content is generic: no terminal module, job or extra chat required.
reset()
local generic = load(nil, false, "gui")
settle(generic)
local panel = generic.bone.ui.panel.open({ id = "browser", title = "Browser fixture" })
generic.window.attach_panel(panel.id)
assert(total() == 1 and generic.bone.ui.panel.focused() == panel.id and generic.window.embedded.browser)
assert(generic.view()[1][3][2].panel == panel.id, "generic panel uses the tiled frame")
generic.bone.ui.panel.focus(nil)
command(generic, "zoom")
assert(panel.hidden)
command(generic, "next")
assert(not panel.hidden and generic.bone.ui.panel.focused() == panel.id, "keyboard reveals a zoomed-away panel before focusing")
command(generic, "only")
assert(generic.view()[1][2].panel == panel.id and generic.state.tree == nil, "only keeps the active generic content")
generic.bone.ui.panel.close(panel.id)
assert(not generic.window.embedded.browser and generic.view().plain and total() == 1,
  "external sole-panel close returns to the existing chat")
local rejected = generic.bone.ui.panel.open({ id = "unfocusable", focusable = false })
assert(not pcall(generic.window.attach_panel, rejected.id) and not generic.window.embedded.unfocusable and generic.view().plain,
  "invalid attachment is rejected before mutating the tree")
local inherited = function() end
generic.window.attach_panel = inherited
for _, fn in ipairs(generic.shutdowns) do fn() end
assert(generic.window.attach_panel == inherited, "shutdown does not overwrite a newer manager")
print("windows: nested weights, cramped shared resize, generic panel lifecycle and hidden focus")

-- A sole panel still has a title and close button in the terminal frontend.
reset()
local tui = load(nil, false, "tui", true)
settle(tui)
tui.keys["main:alt+w t"]()
command(tui, "only")
assert(tui.panels.term1 and bars(tui.bone.ui.layout) == 1)
tui.events.mouse[1]({ region = "wm_bar:2", action = "down", button = "middle" })
assert(not tui.panels.term1 and bars(tui.bone.ui.layout) == 0 and total() == 1,
  "middle-click closes the sole panel and restores the existing chat")
