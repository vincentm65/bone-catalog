-- Tiled chat windows: several sessions on screen at once, split, resized,
-- moved and focused with the keyboard or the mouse.
--
-- The layout's "chat" leaf becomes a tree of windows. The focused window is
-- the real "chat" leaf (the prompt, scrolling and selection belong to it);
-- every other window is a `chat:<session id>` leaf that Rust draws from its
-- own cache. Focusing a window shows its session, so the tree never moves
-- for a focus change, only leaf names do.

local PREFIX = bone.settings.get("windows.prefix")
if type(PREFIX) ~= "string" or PREFIX == "" then PREFIX = "alt+w" end
local MIN = 10 -- the fewest cells a resize leaves a window, either way
local STEP = 4 -- cells per keyboard resize
local DEFAULT = { "top", { cols = { "left", "chat", "right" }, sep = "│" }, "divider", "above_prompt", "prompt", "statusline" }

local st = bone.plugin.state()
bone.hl.set("WinBarActive", { link = "StatusLine", reverse = true })

-- wins[id] = { id, sid }. Tree nodes: { win = id, w } or { dir = "cols" |
-- "rows", w, kids }. `w` is a share of the parent split.
local wins, root, focused = {}, nil, nil
local seq, zoomed, switching, started = 0, false, false, false
local last, broadcast, clicked, resizing -- the window focused before; send to all; the last title click
-- The layout without windows, the one last assigned, and each split by its
-- path in the assigned layout (for separators from bone.ui.geometry).
local base, applied, splits = nil, nil, {}
local HSEP = { size = 1, render = function() return { { { fill = "─", hl = "WinSeparator" } } } end }
local unread = {} -- sessions whose turn ended while their window was in the background
local drag -- { kind = "cols" | "rows" | "move", ... } while the mouse holds something

local function current_sid()
  local s = bone.chat.session()
  return s and s.session_id
end

local function count()
  local n = 0
  for _ in pairs(wins) do n = n + 1 end
  return n
end

local function win_of(sid)
  for id, w in pairs(wins) do
    if w.sid == sid then return id end
  end
end

-- The focused window shows whatever chat is on screen.
local function sync()
  local w = focused and wins[focused]
  if w then w.sid = current_sid() end
end

-- ---- tree ----------------------------------------------------------------

-- The node matching `pred`, its parent and its index there.
local function locate(node, pred, parent, i)
  if pred(node) then return node, parent, i end
  for j, k in ipairs(node.kids or {}) do
    local a, b, c = locate(k, pred, node, j)
    if a then return a, b, c end
  end
end

local function leaf(id)
  return locate(root, function(n) return n.win == id end)
end

local function each_win(node, f)
  if node.win then return f(node.win) end
  for _, k in ipairs(node.kids) do each_win(k, f) end
end

local function first_win(node)
  while not node.win do node = node.kids[1] end
  return node.win
end

local function encode(node)
  if node.win then
    return { sid = wins[node.win].sid, w = node.w, focus = node.win == focused or nil }
  end
  local kids = {}
  for i, k in ipairs(node.kids) do kids[i] = encode(k) end
  return { dir = node.dir, w = node.w, kids = kids }
end

local function save()
  if not root then return end
  sync()
  st.tree = count() > 1 and encode(root) or nil
end

-- ---- layout --------------------------------------------------------------

local function size_of(parent, i)
  if i == #parent.kids then return "fill" end
  local sum = 0
  for _, k in ipairs(parent.kids) do sum = sum + k.w end
  return math.max(1, math.floor(100 * parent.kids[i].w / sum + 0.5)) .. "%"
end

local function build(node, size, path)
  if node.win then
    local w, id = wins[node.win], node.win
    local body = id == focused and "chat"
      or w.sid and "chat:" .. w.sid
      or { "wm_empty:" .. id, size = "fill" }
    return { rows = { "wm_bar:" .. id, body }, size = size }
  end
  local key = table.concat(path, ".")
  splits[key] = node
  local kids = {}
  for i, k in ipairs(node.kids) do
    -- Stacked windows get a line between them, to drag.
    if node.dir == "rows" and i > 1 then
      kids[#kids + 1] = "wm_hsep:" .. key .. ":" .. i
      bone.ui.regions[kids[#kids]] = HSEP
    end
    local p = { unpack(path) }
    p[#p + 1] = #kids + 1
    kids[#kids + 1] = build(k, size_of(node, i), p)
  end
  return { [node.dir] = kids, sep = node.dir == "cols" and "│" or nil, size = size }
end

-- A copy of `node` with the tree in place of its "chat" leaf.
local function subst(node, path)
  local name = type(node) == "table" and node[1] or node
  if name == "chat" then
    return build(root, type(node) == "table" and node.size or nil, path)
  end
  if type(node) ~= "table" then return node end
  local copy = {}
  for k, v in pairs(node) do copy[k] = v end
  for _, key in ipairs({ "rows", "cols" }) do
    if node[key] then
      copy[key] = {}
      for i, c in ipairs(node[key]) do
        local p = { unpack(path) }
        p[#p + 1] = i
        copy[key][i] = subst(c, p)
      end
    end
  end
  return copy
end

local function apply()
  if not root then return end
  for name in pairs(bone.ui.regions) do
    if name:find("^wm_hsep:") then bone.ui.regions[name] = nil end
  end
  -- Someone else changed the layout: that is the one to put windows in.
  if bone.ui.layout ~= applied then base = bone.ui.layout end
  splits = {}
  if count() <= 1 or zoomed then
    applied = base
  else
    applied = {}
    for i, entry in ipairs(base or DEFAULT) do applied[i] = subst(entry, { i }) end
  end
  bone.ui.layout = applied
  save()
end

-- ---- geometry ------------------------------------------------------------

-- Each window's rectangle from the last frame, by id.
local function rects()
  local by = {}
  for _, l in ipairs(bone.ui.geometry().leaves) do by[l.name] = l end
  local out = {}
  for id, w in pairs(wins) do
    local bar = by["wm_bar:" .. id]
    if bar then
      local body = by[id == focused and "chat" or w.sid and "chat:" .. w.sid or "wm_empty:" .. id]
      out[id] = { x = bar.x, y = bar.y, width = bar.width, height = 1 + (body and body.height or 0) }
    end
  end
  return out
end

local function union(node, r)
  local x0, y0, x1, y1
  each_win(node, function(id)
    local o = r[id]
    if o then
      x0, y0 = math.min(x0 or o.x, o.x), math.min(y0 or o.y, o.y)
      x1, y1 = math.max(x1 or 0, o.x + o.width), math.max(y1 or 0, o.y + o.height)
    end
  end)
  if x0 then return { x = x0, y = y0, width = x1 - x0, height = y1 - y0 } end
end

-- The window at a screen cell.
local function win_at(x, y)
  for id, o in pairs(rects()) do
    if x >= o.x and x < o.x + o.width and y >= o.y and y < o.y + o.height then return id end
  end
end

-- The nearest window in direction h/j/k/l from the focused one.
local function neighbor(dir)
  local r = rects()
  local me = r[focused]
  if not me then return end
  local best, score
  for id, o in pairs(r) do
    local gap, off
    if dir == "h" or dir == "l" then
      gap = dir == "h" and me.x - (o.x + o.width) or o.x - (me.x + me.width)
      off = o.y < me.y + me.height and o.y + o.height > me.y and math.abs(o.y - me.y)
    else
      gap = dir == "k" and me.y - (o.y + o.height) or o.y - (me.y + me.height)
      off = o.x < me.x + me.width and o.x + o.width > me.x and math.abs(o.x - me.x)
    end
    if id ~= focused and gap >= 0 and off then
      local s = gap * 10000 + off
      if not score or s < score then best, score = id, s end
    end
  end
  return best
end

-- Move `cells` of room from kid j to kid i of `split` (negative: back).
local function nudge(split, i, j, cells)
  local box = union(split, rects())
  if not box then return end
  local px = split.dir == "cols" and box.width or box.height
  local sum = 0
  for _, k in ipairs(split.kids) do sum = sum + k.w end
  local per = sum / math.max(px, 1)
  local a, b = split.kids[i], split.kids[j]
  local dw = math.max(math.min(cells * per, b.w - MIN * per), -(a.w - MIN * per))
  if dw ~= 0 then
    a.w, b.w = a.w + dw, b.w - dw
    apply()
  end
end

-- ---- windows -------------------------------------------------------------

local bar, pick -- the bar renderer and the session picker, below

local function new_win(sid)
  seq = seq + 1
  local id = seq
  wins[id] = { id = id, sid = sid }
  bone.ui.regions["wm_bar:" .. id] = { size = 1, render = function(ctx) return bar(id, ctx) end }
  bone.ui.regions["wm_empty:" .. id] = {
    render = function(ctx)
      local out = {}
      for _ = 1, math.floor((ctx.height - 1) / 2) do out[#out + 1] = "" end
      out[#out + 1] = { "%=", { "new chat · click or " .. PREFIX .. " w to focus", "Dim" }, "%=" }
      return out
    end,
  }
  return id
end

local function forget(id)
  wins[id] = nil
  bone.ui.regions["wm_bar:" .. id] = nil
  bone.ui.regions["wm_empty:" .. id] = nil
end

local function focus(id)
  if not wins[id] or id == focused then return end
  sync()
  last, focused = focused, id
  switching = true
  local sid = wins[id].sid
  if sid then bone.api.open_session(sid) else bone.action("new_session") end
  switching = false
  apply()
end

-- Split window `at` (default: the focused one, and then the new window takes
-- focus) along `dir` with a new one showing `sid` (nil: a new chat).
local function split(dir, sid, at)
  sync()
  if sid and win_of(sid) then return at or focus(win_of(sid)) end
  zoomed = false
  local node, parent, i = leaf(at or focused)
  local new = { win = new_win(sid), w = 1 }
  if parent and parent.dir == dir then
    node.w = node.w / 2
    new.w = node.w
    table.insert(parent.kids, i + 1, new)
  else
    local s = { dir = dir, w = node.w, kids = { node, new } }
    node.w = 1
    if parent then parent.kids[i] = s else root = s end
  end
  if not at then return focus(new.win) end
  bone.chat.open(sid)
  apply()
end

local function close(id)
  id = id or focused
  if count() <= 1 or not wins[id] then return end
  local _, parent, i = leaf(id)
  table.remove(parent.kids, i)
  local heir = parent.kids[math.min(i, #parent.kids)]
  if #parent.kids == 1 then
    local only = parent.kids[1]
    only.w = parent.w
    local _, gp, gi = locate(root, function(n) return n == parent end)
    if gp then gp.kids[gi] = only else root = only end
    -- A split left inside one of the same direction joins it.
    if gp and only.dir == gp.dir then
      table.remove(gp.kids, gi)
      for k = #only.kids, 1, -1 do
        only.kids[k].w = only.kids[k].w * only.w / #only.kids
        table.insert(gp.kids, gi, only.kids[k])
      end
    end
  end
  local was = id == focused
  forget(id)
  if was then
    focused = nil
    focus(first_win(heir))
  end
  apply()
end

local function only()
  sync()
  for id in pairs(wins) do
    if id ~= focused then forget(id) end
  end
  root = { win = focused, w = 1 }
  zoomed = false
  apply()
end

-- Swap the focused window with another; focus stays with the moved chat.
local function swap(other)
  if not other or other == focused then return end
  local a, b = leaf(focused), leaf(other)
  a.win, b.win = b.win, a.win
  apply()
end

local function equalize(node)
  node = node or root
  node.w = 1
  for _, k in ipairs(node.kids or {}) do equalize(k) end
  if node == root then apply() end
end

local function zoom()
  zoomed = not zoomed
  apply()
end

-- Every window moves one place along; focus stays with its chat.
local function rotate()
  local nodes = {}
  locate(root, function(n) nodes[#nodes + 1] = n.win and n or nil end)
  local first = nodes[1].win
  for i = 1, #nodes - 1 do nodes[i].win = nodes[i + 1].win end
  nodes[#nodes].win = first
  apply()
end

-- Grow the focused window by `cells` along "cols" or "rows".
local function grow(dir, cells)
  local child = leaf(focused)
  while true do
    local _, parent, i = locate(root, function(n) return n == child end)
    if not parent then return end
    if parent.dir == dir and #parent.kids > 1 then
      if i < #parent.kids then return nudge(parent, i, i + 1, cells) end
      return nudge(parent, i, i - 1, cells)
    end
    child = parent
  end
end

-- ---- the bar on each window ----------------------------------------------

bar = function(id, ctx)
  local w = wins[id]
  if not w then return {} end
  local mine = id == focused
  local sid = mine and current_sid() or w.sid
  local s = sid and bone.chat.session({ session = sid })
  local name = sid and (s and s.title or "[untitled]") or "new chat"
  local hl = mine and "WinBarActive" or "Dim"
  if drag and drag.kind == "move" and drag.target == id and drag.id ~= id then hl = "Selection" end
  local mark = s and s.running and ctx.spinner .. " " or unread[sid] and "• " or ""
  local title = bone.text.truncate(mark .. name, math.max(ctx.width - 10, 1))
  return { {
    { " ⠿ ", hl }, { title, hl }, { " ", hl },
    { fill = mine and " " or "─", hl = mine and hl or "WinSeparator" }, { " ✕ ", hl },
  } }
end

-- ---- mouse ---------------------------------------------------------------

local function on_mouse(ev)
  if count() <= 1 or zoomed then return end
  if drag and ev.action == "drag" then
    if drag.kind == "move" then
      drag.target = win_at(ev.x, ev.y)
    else
      local at = drag.kind == "cols" and ev.x or ev.y
      if at ~= drag.last then
        nudge(drag.split, drag.i - 1, drag.i, at - drag.last)
        drag.last = at
      end
    end
    return true
  end
  if drag and ev.action == "up" then
    local t = drag.kind == "move" and (drag.target or drag.id)
    -- A click on the focused window's title changes its session.
    if t and t ~= drag.id then
      swap(t)
    elseif t and drag.was then
      local c = clicked
      bone.defer(350, function() if clicked == c then pick() end end)
    end
    drag = nil
    return true
  end
  local id = tonumber((ev.region or ""):match("^wm_bar:(%d+)$"))
  if id and ev.action == "down" and ev.button == "middle" then
    close(id)
    return true
  end
  if ev.action ~= "down" or ev.button ~= "left" then return end
  -- A column separator.
  for _, s in ipairs(bone.ui.geometry().seps) do
    if ev.x == s.x and ev.y >= s.y and ev.y < s.y + s.height then
      local key = table.concat(s.path, ".", 1, #s.path - 1)
      local node = splits[key]
      if node then
        drag = { kind = "cols", split = node, i = s.path[#s.path], last = ev.x }
        return true
      end
    end
  end
  local region = ev.region or ""
  if id then
    local r = rects()[id]
    if r and ev.col > r.width - 3 then
      close(id)
      return true
    end
    local now = bone.now()
    if clicked and clicked.id == id and now - clicked.at < 350 then
      clicked = nil
      zoom()
      return true
    end
    clicked = { id = id, at = now }
    drag = { kind = "move", id = id, was = id == focused }
    focus(id)
    return true
  end
  local key, i = region:match("^wm_hsep:(.*):(%d+)$")
  if key and splits[key] then
    drag = { kind = "rows", split = splits[key], i = tonumber(i), last = ev.y }
    return true
  end
  -- A click in another window focuses it.
  local sid = region:match("^chat:(.+)$")
  id = sid and win_of(sid) or tonumber(region:match("^wm_empty:(%d+)$"))
  if id and id ~= focused then
    focus(id)
    return true
  end
end

-- ---- startup and following the chat on screen ----------------------------

local function restore(t)
  local function walk(n)
    if n.kids then
      local kids = {}
      for _, k in ipairs(n.kids) do kids[#kids + 1] = walk(k) end
      return { dir = n.dir, w = n.w or 1, kids = kids }
    end
    local id = new_win(n.sid)
    if n.focus then focused = id end
    if n.sid and not n.focus then bone.chat.open(n.sid) end
    return { win = id, w = n.w or 1 }
  end
  root = walk(t)
  focused = focused or first_win(root)
  -- Show the focused window's session unless a chat was already chosen.
  local want, s = wins[focused].sid, bone.chat.session()
  if want and s and s.new and s.items == 0 then
    switching = true
    bone.api.open_session(want)
    switching = false
  end
end

local function start()
  if started then return end
  started = true
  base = bone.ui.layout
  applied = base
  if type(st.tree) == "table" then
    restore(st.tree)
  else
    root = { win = new_win(current_sid()), w = 1 }
    focused = root.win
  end
  apply()
end

-- Another way of changing the chat (ctrl+o, a click on a sub-agent, ctrl+n)
-- changes what the focused window shows, or focuses the window that has it.
bone.on("chat/shown", function(ev)
  if switching or not root or not wins[focused] then return end
  local other = ev.session_id and win_of(ev.session_id)
  if other and other ~= focused then
    focused = other
  else
    wins[focused].sid = ev.session_id
  end
  apply()
end)

-- A new chat gets its session id with its first turn.
bone.on("turn/started", function(ev)
  if focused and wins[focused] and ev.session_id == current_sid() then
    wins[focused].sid = ev.session_id
    save()
  end
end)

bone.on("turn/finished", function(ev)
  if ev.session_id ~= current_sid() then unread[ev.session_id] = true end
end)
bone.on("chat/shown", function(ev) unread[ev.session_id or ""] = nil end)

bone.on("session/deleted", function(ev)
  if root and win_of(ev.session_id) then close(win_of(ev.session_id)) end
end)

-- Optionally watch each sub-agent in a window under its owner's.
bone.on("session/created", function(ev)
  local o = ev.owner
  if root and o and bone.settings.get("windows.subagents") then
    split("rows", ev.session_id, win_of(o.session_id) or focused)
  end
end)

-- Broadcast: a message sent in the focused window also goes to every other.
bone.on("submit", function(ev)
  if not broadcast or not root then return end
  for id, w in pairs(wins) do
    if id ~= focused and w.sid then
      bone.request("queue/add", { session_id = w.sid, text = ev.text, mode = "next" }, function() end)
    end
  end
end)

bone.on("mouse", on_mouse)
bone.on("ready", start)
bone.defer(0, start) -- loaded after startup (/plugins load windows)

bone.plugin.on_shutdown(function()
  save()
  if root and bone.ui.layout == applied then bone.ui.layout = base end
  for id in pairs(wins) do forget(id) end
end)

-- ---- keys and the command ------------------------------------------------

-- Change what the focused window shows.
function pick()
  bone.request("session/list", {}, function(list, err)
    if err then return bone.notify(tostring(err), "error") end
    local items = { { new = true } }
    for _, s in ipairs(list or {}) do
      if not s.owner then items[#items + 1] = s end
    end
    bone.ui.select(items, {
      prompt = "Show in this window",
      format = function(s)
        if s.new then return "+ new chat" end
        return (s.title or "[untitled]") .. (win_of(s.session_id) and "  · open" or "")
      end,
      on_choice = function(s)
        if s and s.new then bone.action("new_session") elseif s then bone.api.open_session(s.session_id) end
      end,
    })
  end)
end

local function step(dir)
  return function() focus(neighbor(dir)) end
end

local function move(dir)
  return function() swap(neighbor(dir)) end
end

local function cycle()
  local ids = {}
  each_win(root, function(id) ids[#ids + 1] = id end)
  for i, id in ipairs(ids) do
    if id == focused then return focus(ids[i % #ids + 1]) end
  end
end

local keys = {
  v = function() split("cols") end,
  s = function() split("rows") end,
  p = pick,
  q = function() close() end,
  o = only,
  w = cycle,
  h = step("h"), j = step("j"), k = step("k"), l = step("l"),
  left = step("h"), down = step("j"), up = step("k"), right = step("l"),
  H = move("h"), J = move("j"), K = move("k"), L = move("l"),
  [">"] = function() grow("cols", STEP) end,
  ["<"] = function() grow("cols", -STEP) end,
  ["+"] = function() grow("rows", 2) end,
  ["-"] = function() grow("rows", -2) end,
  ["="] = function() equalize() end,
  z = zoom,
  r = rotate,
  [";"] = function() focus(last) end,
  b = function()
    broadcast = not broadcast
    bone.notify(broadcast and "windows: sending to every window" or "windows: sending to the focused window")
  end,
}
for key, f in pairs(keys) do
  bone.keymap.set(PREFIX .. " " .. key, function() if root then f() end end)
end

-- After a resize, < > + - keep resizing for a second without the prefix.
bone.keymap.context("wm_resize", { fallback = { "main" } })
for _, key in ipairs({ "<", ">", "+", "-" }) do
  local f = keys[key]
  keys[key] = function()
    f()
    local at = bone.now()
    resizing = at
    bone.keymap.focus("wm_resize")
    bone.defer(1000, function() if resizing == at then bone.keymap.clear() end end)
  end
  bone.keymap.set(key, keys[key], { context = "wm_resize" })
  bone.keymap.set(PREFIX .. " " .. key, function() if root then keys[key]() end end)
end

local SUB = {
  vsplit = function() split("cols") end, split = function() split("rows") end,
  pick = pick, close = function() close() end, only = only,
  next = cycle, equal = function() equalize() end, zoom = zoom, rotate = rotate,
  broadcast = keys.b,
}
bone.cmd.create("win", function(c)
  local f = SUB[(c.args or ""):match("^%s*(%S*)")]
  if not f then
    return bone.notify("/win vsplit|split|pick|close|only|next|equal|zoom|rotate|broadcast  (keys: " .. PREFIX .. " then v s p q o w ; h j k l H J K L < > + - = z r b)")
  end
  if root then f() end
end, { desc = "Tiled chat windows: split, close, focus, zoom" })
