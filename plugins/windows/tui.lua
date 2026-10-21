-- Tiled chat windows: several sessions on screen at once, split, resized,
-- moved and focused with the keyboard or the mouse. A window can show a
-- terminal instead (bone.ui.terminal): a `panel:<id>` leaf in its place.
--
-- The layout's "chat" leaf becomes a tree of windows, each with its own copy
-- of the rows under the chat (prompt, statusline…). The focused window has
-- the bare leaves (the chat on screen); others have `prompt:<session id>` and
-- so on. Focusing a window shows its session, so only leaf names change.

local PREFIX = bone.settings.get("windows.prefix")
if type(PREFIX) ~= "string" or PREFIX == "" then PREFIX = "alt+w" end
local MIN = 10 -- the fewest cells a resize leaves a window, either way
local STEP = 4 -- cells per keyboard resize
local DEFAULT = { "top", { cols = { "left", "chat", "right" }, sep = "│" }, "divider", "above_prompt", "prompt", "statusline" }

local st = bone.plugin.state()
bone.hl.set("WinBarActive", { link = "StatusLine", reverse = true })
bone.hl.set("WinDrop", { fg = "#3d7eff", bg = "#3d7eff" })

-- wins[id] = { id, chat, sid } (the chat's number, and its session once it
-- has one) or, for a terminal, { id, term = panel id }. The
-- focused window is always a chat; a terminal window has the keyboard when
-- its panel does (see here()). Tree nodes: { win = id, w } or { dir = "cols" |
-- "rows", w, kids }. `w` is a share of the parent split.
local wins, root, focused = {}, nil, nil
local seq, zoomed, switching, started = 0, false, false, false
local last, broadcast, clicked, resizing -- the window focused before; send to all; the last title click
-- The layout without windows, the one last assigned, and each split by its
-- path in the assigned layout (for separators from bone.ui.geometry).
local base, applied, splits, below = nil, nil, {}, {}
local HSEP = { size = 1, render = function() return { { { fill = "─", hl = "WinSeparator" } } } end }
local unread = {} -- sessions whose turn ended while their window was in the background
local drag -- { kind = "cols" | "rows" | "move", ... } while the mouse holds something
local drop_ids, drop_key = {}, nil -- the outline shown while a window is dragged

local function current_sid()
  local s = bone.chat.session()
  return s and s.session_id
end

local function count()
  local n = 0
  for _ in pairs(wins) do n = n + 1 end
  return n
end

-- The window showing session `sid` (or with `key` = sid).
local function win_of(sid, key)
  for id, w in pairs(wins) do
    if sid and w[key or "sid"] == sid then return id end
  end
end

local function term_win(pid)
  for id, w in pairs(wins) do
    if pid and w.term == pid then return id end
  end
end

-- The window with the keyboard: a terminal's, else the focused chat's.
local function here()
  return term_win(bone.ui.panel.focused()) or focused
end

-- A window's rows: its title bar, then a terminal, or a chat with the rows
-- from under the base layout's chat (another keeps the built-ins and gap).
local function rows_of(id)
  local w, bar = wins[id], "wm_bar:" .. id
  if w.term then return { bar, "panel:" .. w.term } end
  local at = id == focused and "" or ":" .. w.chat
  local out = { bar, "chat" .. at }
  for _, e in ipairs(below) do
    local name = type(e) == "table" and e[1] or e
    if at == "" or name == "divider" or name == "prompt" or name == "statusline" then
      out[#out + 1] = at == "" and e or name .. at
    elseif name == "input_gap" then -- blank: its [↓ End] is the focused chat's
      out[#out + 1] = { "wm_gap:" .. id, size = 1 }
    end
  end
  return out
end

-- The focused window shows whatever chat is on screen.
local function sync()
  local w, s = focused and wins[focused], bone.chat.session()
  if w then w.sid, w.chat = s.session_id, s.chat end
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
  local n = locate(node, function(n) return n.win and not wins[n.win].term end)
  return n and n.win
end

-- Terminals are not saved: their programs end with bone.
local function encode(node)
  if node.win then
    local win = wins[node.win]
    if win.term then return nil end
    local chat = bone.chat.session({ session = tostring(win.chat) })
    return { sid = chat and chat.session_id or win.sid, chat = win.chat, w = node.w,
      focus = node.win == focused or nil, zoom = node.win == zoomed or nil }
  end
  local kids = {}
  for _, k in ipairs(node.kids) do kids[#kids + 1] = encode(k) end
  if #kids <= 1 then
    if kids[1] then kids[1].w = node.w end
    return kids[1]
  end
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
  if node.win then return { rows = rows_of(node.win), size = size } end
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
local shown -- the tree drawn: root, or a zoomed terminal window alone
local function subst(node, path)
  local name = type(node) == "table" and node[1] or node
  if name == "chat" then
    return build(shown, type(node) == "table" and node.size or nil, path)
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

local function has(n, pat)
  if type(n) ~= "table" then return n:find(pat) ~= nil end
  for _, c in ipairs(n.rows or n.cols or n) do
    if has(c, pat) then return true end
  end
end

local function apply()
  if not root then return end
  for name in pairs(bone.ui.regions) do
    if name:find("^wm_hsep:") then bone.ui.regions[name] = nil end
  end
  -- Someone else changed the layout: put windows in it, unless it was built on ours (nesting them).
  if bone.ui.layout ~= applied and not has(bone.ui.layout or {}, "^wm_bar:") then base = bone.ui.layout end
  splits = {}
  local zoomed_term = zoomed and wins[zoomed] and wins[zoomed].term
  if count() <= 1 or (zoomed and not zoomed_term) then
    applied = base
  else
    shown = zoomed_term and leaf(zoomed) or root
    local rows, at = base or DEFAULT, 0
    repeat at = at + 1 until at >= #rows or has(rows[at], "^chat$")
    below = { unpack(rows, at + 1) }
    applied = {}
    for i = 1, at do applied[i] = subst(rows[i], { i }) end
  end
  -- A terminal not in the layout would dock: hide it while zoomed away.
  for id, w in pairs(wins) do
    local hide = zoomed and zoomed ~= id or false
    if w.term and (w.hidden or false) ~= hide then
      w.hidden = hide
      bone.ui.panel.update(w.term, { hidden = hide })
    end
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
    local bar, bottom = by["wm_bar:" .. id], 0
    for _, e in ipairs(bar and rows_of(id) or {}) do
      local l = by[type(e) == "table" and e[1] or e]
      if l then bottom = math.max(bottom, l.y + l.height) end
    end
    if bar then out[id] = { x = bar.x, y = bar.y, width = bar.width, height = bottom - bar.y } end
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
  local me = r[here()]
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
    if id ~= here() and gap >= 0 and off then
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
local ok, terminal = pcall(require, "bone.ui.terminal")
if not ok then terminal = nil end

-- A window for session `sid` (nil: a new chat) or terminal panel `term`;
-- `chat` if its chat is already open.
local function new_win(sid, term, chat)
  seq = seq + 1
  local id = seq
  wins[id] = { id = id, sid = sid, term = term, chat = chat or not term and bone.chat.open(sid) or nil }
  bone.ui.regions["wm_bar:" .. id] = { size = 1, render = function(ctx) return bar(id, ctx) end }
  return id
end

-- A forgotten terminal window's program stops (its panel closes).
local function forget(id)
  local term = wins[id].term
  wins[id] = nil
  bone.ui.regions["wm_bar:" .. id] = nil
  if term then bone.ui.panel.close(term) end
end

local function focus(id)
  local w = wins[id]
  if not w then return end
  if w.term then return bone.ui.panel.focus(w.term) end
  if term_win(bone.ui.panel.focused()) then bone.ui.panel.focus(nil) end
  if id == focused then return end
  sync()
  last, focused = focused, id
  switching = true
  bone.api.open_session(tostring(w.chat))
  switching = false
  apply()
end

-- Split window `at` (default: the one with the keyboard, and then the new
-- window takes focus) along `dir` with a new one showing `sid` (nil: a new
-- chat), or terminal panel `term` (which takes the keyboard when it opens).
local function split(dir, sid, at, term)
  sync()
  if sid and win_of(sid) then return at or focus(win_of(sid)) end
  zoomed = false
  local node, parent, i = leaf(at or here())
  local new = { win = new_win(sid, term), w = 1 }
  if parent and parent.dir == dir then
    node.w = node.w / 2
    new.w = node.w
    table.insert(parent.kids, i + 1, new)
  else
    local s = { dir = dir, w = node.w, kids = { node, new } }
    node.w = 1
    if parent then parent.kids[i] = s else root = s end
  end
  if term then return apply() end
  if not at then return focus(new.win) end
  apply()
end

local function close(id)
  id = id or here()
  if count() <= 1 or not wins[id] then return end
  -- The last chat window stays: the prompt sends to it.
  local chats = 0
  for _, w in pairs(wins) do chats = chats + (w.term and 0 or 1) end
  if chats <= 1 and not wins[id].term then return end
  if zoomed == id then zoomed = false end
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
    focus(first_win(heir) or first_win(root))
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

-- Swap two windows; the focused id stays, so focus follows that chat.
local function exchange(a, b)
  if not a or not b or a == b then return end
  local na, nb = leaf(a), leaf(b)
  if not na or not nb then return end
  na.win, nb.win = nb.win, na.win
  apply()
end

local function swap(other)
  exchange(here(), other)
end

-- Lift a window out of the tree without forgetting it. Collapses like close().
local function take(id)
  local node, parent, i = leaf(id)
  if not node or not parent then return end
  table.remove(parent.kids, i)
  if #parent.kids == 1 then
    local only = parent.kids[1]
    only.w = parent.w
    local _, gp, gi = locate(root, function(n) return n == parent end)
    if gp then gp.kids[gi] = only else root = only end
    if gp and only.dir == gp.dir then
      table.remove(gp.kids, gi)
      for k = #only.kids, 1, -1 do
        only.kids[k].w = only.kids[k].w * only.w / #only.kids
        table.insert(gp.kids, gi, only.kids[k])
      end
    end
  end
  return node
end

-- Put `node` on `side` of `target` ("left"|"right"|"up"|"down"), taking half
-- of the target. Left and up insert before it; right and down, after.
local function graft(node, target, side)
  local dir = (side == "left" or side == "right") and "cols" or "rows"
  local before = side == "left" or side == "up"
  local at, parent, i = leaf(target)
  if not at then return end
  if parent and parent.dir == dir then
    at.w = at.w / 2
    node.w = at.w
    table.insert(parent.kids, before and i or i + 1, node)
  else
    node.w = 1
    local s = { dir = dir, w = at.w, kids = before and { node, at } or { at, node } }
    at.w = 1
    if parent then parent.kids[i] = s else root = s end
  end
end

-- Move `id` onto `target`: no side swaps them, a side splits `target` in half.
local function move_to(id, target, side)
  if not side then return exchange(id, target) end
  if id == target or not wins[id] or not wins[target] then return end
  local node = take(id)
  if not node then return end
  if not leaf(target) then
    if root then
      node.w = 1
      root = { dir = "cols", w = 1, kids = { root, node } }
    else
      root = node
    end
    return apply()
  end
  graft(node, target, side)
  apply()
end

local function equalize(node)
  node = node or root
  node.w = 1
  for _, k in ipairs(node.kids or {}) do equalize(k) end
  if node == root then apply() end
end

local function zoom()
  zoomed = not zoomed and here()
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
  local child = leaf(here())
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
  local mine = id == here()
  local s = w.chat and bone.chat.session({ session = tostring(w.chat) })
  local sid = s and s.session_id
  local name = sid and (s.title or "[untitled]") or "new chat"
  if w.term then
    local job = terminal and terminal.job(w.term)
    local st = job and job:status()
    name = "terminal" .. (st and " · " .. st.cmd or "")
  end
  local hl = mine and "WinBarActive" or "Dim"
  local mark = s and s.running and ctx.spinner .. " " or unread[sid] and "• " or ""
  local title = bone.text.truncate(mark .. name, math.max(ctx.width - 10, 1))
  return { {
    { " ⠿ ", hl }, { title, hl }, { " ", hl },
    { fill = mine and " " or "─", hl = mine and hl or "WinSeparator" }, { " ✕ ", hl },
  } }
end

-- ---- drop preview ---------------------------------------------------------

-- Where a drag over window `id` would land. The band is a fifth of the
-- shorter side (Zed's drop_target_size). The nearest edge in that band
-- splits, unless that half is under MIN cells, and the rest swaps. The
-- caller passes nothing for the dragged window itself. `rect` is the
-- outline: the whole window, or the half the dragged window will take.
local function drop_zone(id, x, y)
  local r = rects()[id]
  if not r or r.width < 1 or r.height < 1 then return end
  local band = math.min(r.width, r.height) * 0.2
  local rx, ry = x - r.x, y - r.y
  local side
  if rx < band or rx >= r.width - band or ry < band or ry >= r.height - band then
    local best, dist
    for _, s in ipairs({ { "up", ry }, { "right", r.width - rx }, { "down", r.height - ry }, { "left", rx } }) do
      if not dist or s[2] < dist then best, dist = s[1], s[2] end
    end
    local along = (best == "left" or best == "right") and r.width or r.height
    if math.floor(along / 2) >= MIN then side = best end
  end
  local rect = { x = r.x, y = r.y, width = r.width, height = r.height }
  if side == "left" or side == "right" then
    rect.width = math.floor(r.width / 2)
    if side == "right" then rect.x = r.x + r.width - rect.width end
  elseif side == "up" or side == "down" then
    rect.height = math.floor(r.height / 2)
    if side == "down" then rect.y = r.y + r.height - rect.height end
  end
  return { id = id, side = side, rect = rect }
end

local function drop_hide()
  drop_key = nil
  for _, id in ipairs(drop_ids) do bone.ui.close(id) end
  drop_ids = {}
end

-- A 1-cell outline. A filled window would clear the transcript under it.
local function drop_show(z)
  local key = z and (z.id .. ":" .. (z.side or "swap"))
  if key == drop_key then return end
  drop_hide()
  drop_key = key
  if not z then return end
  local r = z.rect
  local function strip(x, y, w, h)
    if w < 1 or h < 1 then return end
    local lines = {}
    for i = 1, h do lines[i] = { { fill = " ", hl = "WinDrop" } } end
    drop_ids[#drop_ids + 1] = bone.ui.win({
      anchor = "screen", row = y, col = x, width = w, height = h, z = 30, lines = lines,
    })
  end
  strip(r.x, r.y, r.width, 1)
  if r.height > 1 then strip(r.x, r.y + r.height - 1, r.width, 1) end
  if r.height > 2 then
    strip(r.x, r.y + 1, 1, r.height - 2)
    if r.width > 1 then strip(r.x + r.width - 1, r.y + 1, 1, r.height - 2) end
  end
end

-- ---- mouse ---------------------------------------------------------------

local function on_mouse(ev)
  if count() <= 1 or zoomed then return end
  if drag and ev.action == "drag" then
    if drag.kind == "move" then
      local id = win_at(ev.x, ev.y)
      drag.target = id
      drag.zone = id and id ~= drag.id and drop_zone(id, ev.x, ev.y) or nil
      drop_show(drag.zone)
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
    local kind, id, was = drag.kind, drag.id, drag.was
    -- Release is the landing spot. A drag event usually already outlined it.
    local zone = drag.zone
    if kind == "move" and ev.x then
      local over = win_at(ev.x, ev.y)
      zone = over and over ~= id and drop_zone(over, ev.x, ev.y) or nil
    end
    drag = nil
    drop_hide()
    if kind == "move" then
      if zone and zone.side then
        move_to(id, zone.id, zone.side)
      elseif zone then
        exchange(id, zone.id)
      elseif was then
        -- A click on the focused window's title changes its session.
        local c = clicked
        bone.defer(350, function() if clicked == c then pick() end end)
      end
    end
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
  id = win_of(tonumber(region:match("^%a+:(%d+)$")), "chat")
  if id and id ~= focused then
    focus(id)
    return true
  end
end

-- ---- startup and following the chat on screen ----------------------------

local function restore(t, reloading)
  local function walk(n)
    if n.kids then
      local kids = {}
      for _, k in ipairs(n.kids) do kids[#kids + 1] = walk(k) end
      return { dir = n.dir, w = n.w or 1, kids = kids }
    end
    -- Buffer numbers survive a Lua reload, including chats with no session
    -- yet. They are process-local, so never trust them on a fresh start.
    local existing = reloading and n.chat ~= nil and bone.chat.session({ session = tostring(n.chat) })
    local chat = existing and existing.chat or (n.focus and bone.chat.session().chat)
    local id = new_win(n.sid, nil, chat)
    if n.focus then focused = id end
    if n.zoom then zoomed = id end
    return { win = id, w = n.w or 1 }
  end
  root = walk(t)
  focused = focused or first_win(root)
  -- Show the focused window's session unless a chat was already chosen.
  local want, s = wins[focused].sid, bone.chat.session()
  if not reloading and want and s and s.new and s.items == 0 then
    switching = true
    bone.api.open_session(want)
    switching = false
  end
  sync()
end

local function start(ev)
  if started then return end
  started = true
  -- A reload validates ready handlers before accepting the new Lua state.
  -- Defer activation so a rejected candidate cannot create/switch chats.
  bone.defer(0, function()
    base = bone.ui.layout
    applied = base
    if type(st.tree) == "table" then
      restore(st.tree, ev and ev.reload)
    else
      root = { win = new_win(current_sid(), nil, bone.chat.session().chat), w = 1 }
      focused = root.win
    end
    apply()
  end)
end

-- Another way of changing the chat (ctrl+o, a click on a sub-agent, ctrl+n)
-- changes what the focused window shows, or focuses the window that has it.
bone.on("chat/shown", function(ev)
  if switching or not root or not wins[focused] then return end
  local other = win_of(ev.chat, "chat")
  if other and other ~= focused then
    focused = other
  else
    wins[focused].sid, wins[focused].chat = ev.session_id, ev.chat
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

-- A terminal window opens beside the one with the keyboard; its program
-- ending (its panel closing) closes the window.
local function open_term(opts)
  local n = 1
  while bone.ui.panel.get("term" .. n) or term_win("term" .. n) do n = n + 1 end
  split("cols", nil, nil, "term" .. n)
  return terminal.open({ id = "term" .. n }, opts)
end

bone.on("panel/closed", function(ev)
  local id = root and term_win(ev.id)
  if id then close(id) end
end)

-- /term and ctrl+] open a terminal window rather than a docked one. An
-- explicit panel spec is left alone.
local term_open = terminal and terminal.open
if terminal then
  terminal.open = function(spec, opts)
    if spec ~= nil or not root then return term_open(spec, opts) end
    return open_term(opts)
  end
end

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
  if terminal then
    terminal.open = term_open
    terminal.passthrough[PREFIX] = nil
  end
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
    if id == here() then return focus(ids[i % #ids + 1]) end
  end
end

local keys = {
  t = function() if terminal then open_term() end end,
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
local DESC = {
  t = "open a terminal in a new window", v = "split right", s = "split below", p = "pick what this window shows", q = "close the window",
  o = "close every other window", w = "focus the next window", [";"] = "focus the previous window",
  h = "focus left", j = "focus down", k = "focus up", l = "focus right",
  left = "focus left", down = "focus down", up = "focus up", right = "focus right",
  H = "swap with the window left", J = "swap with the window below",
  K = "swap with the window above", L = "swap with the window right",
  ["<"] = "narrower (repeat without the prefix)", [">"] = "wider (repeat without the prefix)",
  ["-"] = "shorter (repeat without the prefix)", ["+"] = "taller (repeat without the prefix)",
  ["="] = "make every window the same size", z = "zoom the window, and back",
  r = "rotate the windows", b = "send messages to every window, or not",
}
-- Also while a panel has the keyboard; a terminal lets the prefix through.
local function map(key)
  local f = function() if root then keys[key]() end end
  bone.keymap.set(PREFIX .. " " .. key, f, { desc = DESC[key] })
  bone.keymap.set(PREFIX .. " " .. key, f, { context = "panel" })
end
if terminal then terminal.passthrough[PREFIX] = true end
for key in pairs(keys) do map(key) end

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
end

local SUB = {
  term = keys.t, vsplit = function() split("cols") end, split = function() split("rows") end,
  pick = pick, close = function() close() end, only = only,
  next = cycle, equal = function() equalize() end, zoom = zoom, rotate = rotate,
  broadcast = keys.b,
}
bone.cmd.create("win", function(c)
  local f = SUB[(c.args or ""):match("^%s*(%S*)")]
  if not f then
    return bone.notify("/win term|vsplit|split|pick|close|only|next|equal|zoom|rotate|broadcast  (keys: " .. PREFIX .. " then t v s p q o w ; h j k l H J K L < > + - = z r b)")
  end
  if root then f() end
end, { desc = "Tiled chat windows: split, close, focus, zoom" })
