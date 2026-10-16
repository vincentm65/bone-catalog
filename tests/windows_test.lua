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
local function load(saved, reloading)
  local vm = { state = copy(saved or {}), events = {}, timers = {}, commands = {}, shutdowns = {} }
  local bone = {
    settings = { get = function() end }, hl = { set = function() end },
    plugin = { state = function() return vm.state end, on_shutdown = function(fn) vm.shutdowns[#vm.shutdowns + 1] = fn end },
    on = function(name, fn)
      vm.events[name] = vm.events[name] or {}
      table.insert(vm.events[name], fn)
    end,
    defer = function(_, fn) vm.timers[#vm.timers + 1] = fn end,
    keymap = { set = function() end, context = function() end },
    cmd = { create = function(name, fn) vm.commands[name] = fn end },
    ui = { layout = { "chat", "input_gap", "prompt", "statusline" }, regions = {}, panel = {
      focused = function() end, close = function() end,
    } },
    chat = {}, api = {},
  }
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
  local env = setmetatable({ bone = bone, require = function() error("no terminal in this test") end }, { __index = _G })
  setfenv(assert(loadfile(root .. "/tui.lua")), env)()
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
