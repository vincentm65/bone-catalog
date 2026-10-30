-- Tiled chat windows in the TUI: the tree (lua/windows/tree.lua) drawn as
-- layout leaves. A window can show a terminal instead (bone.ui.terminal): a
-- `panel:<id>` leaf in its place.
--
-- The layout's "chat" leaf becomes a tree of windows, each with its own copy
-- of the rows under the chat (prompt, statusline…). The focused window has
-- the bare leaves (the chat on screen); others have `prompt:<session id>` and
-- so on. Focusing a window shows its session, so only leaf names change.

local drop = require("windows.drop")
local MIN = 10 -- the fewest cells a resize leaves a window, either way
local DEFAULT = { "top", { cols = { "left", "chat", "right" }, sep = "│" }, "divider", "above_prompt", "prompt", "statusline" }

-- Under the colorscheme: a scheme or config that sets them wins. A drop
-- zone is blank cells in the accent's color.
bone.hl.set("WinBarActive", { link = "StatusLine", reverse = true, default = true })
bone.hl.set("WinDrop", { link = "Accent", reverse = true, default = true })

local ok, terminal = pcall(require, "bone.ui.terminal")
if not ok then terminal = nil end

-- The layout without windows, the one last assigned, and each split by its
-- path in the assigned layout (for separators from bone.ui.geometry).
local base, applied, splits, below = nil, nil, {}, {}
local HSEP = { size = 1, render = function() return { { { fill = "─", hl = "WinSeparator" } } } end }
local drag -- { kind = "cols" | "rows" | "move", ... } while the mouse holds something
local drop_ids, drop_key = {}, nil -- the outline shown while a window is dragged
local clicked -- the last title click

local W, bar
local fe = { state = bone.plugin.state(), min = MIN, step = 4, rows_step = 2 }

-- A window's rows: its title bar, then a terminal, or a chat with the rows
-- from under the base layout's chat (another keeps the built-ins and gap).
local function rows_of(id)
  local w, name = W.wins[id], "wm_bar:" .. id
  if w.panel then return { name, "panel:" .. w.panel } end
  local at = id == W.chatwin and "" or ":" .. w.chat
  local out = { name, "chat" .. at }
  for _, e in ipairs(below) do
    local leaf = type(e) == "table" and e[1] or e
    if at == "" or leaf == "divider" or leaf == "prompt" or leaf == "statusline" then
      out[#out + 1] = at == "" and e or leaf .. at
    elseif leaf == "input_gap" then -- blank: its [↓ End] is the focused chat's
      out[#out + 1] = { "wm_gap:" .. id, size = 1 }
    end
  end
  return out
end

-- ---- layout --------------------------------------------------------------

local function size_of(parent, i)
  if i == #parent.kids then return "fill" end
  return math.max(1, math.floor(100 * parent.kids[i].w / W.weight(parent) + 0.5)) .. "%"
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
local shown -- the tree drawn: the root, or a zoomed terminal window alone
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

function fe.apply()
  for name in pairs(bone.ui.regions) do
    if name:find("^wm_hsep:") then bone.ui.regions[name] = nil end
  end
  -- Someone else changed the layout: put windows in it, unless it was built on ours (nesting them).
  if bone.ui.layout ~= applied and not has(bone.ui.layout or {}, "^wm_bar:") then base = bone.ui.layout end
  splits = {}
  local zoomed = W.zoomed
  local zoomed_term = zoomed and W.wins[zoomed] and W.wins[zoomed].panel
  if (W.count() == 1 and not W.wins[W.root.win].panel) or (zoomed and not zoomed_term) then
    applied = base
  else
    shown = zoomed_term and W.leaf(zoomed) or W.root
    local rows, at = base or DEFAULT, 0
    repeat at = at + 1 until at >= #rows or has(rows[at], "^chat$")
    below = { unpack(rows, at + 1) }
    applied = {}
    for i = 1, at do applied[i] = subst(rows[i], { i }) end
  end
  bone.ui.layout = applied
end

function fe.start()
  base = bone.ui.layout
  applied = base
end

function fe.on_new(id)
  bone.ui.regions["wm_bar:" .. id] = { size = 1, render = function(ctx) return bar(id, ctx) end }
end

function fe.on_forget(id)
  bone.ui.regions["wm_bar:" .. id] = nil
end

-- Each window's rectangle from the last frame, by id, in cells.
function fe.rects()
  local by = {}
  for _, l in ipairs(bone.ui.geometry().leaves) do by[l.name] = l end
  local out = {}
  for id in pairs(W.wins) do
    local top, bottom = by["wm_bar:" .. id], 0
    for _, e in ipairs(top and rows_of(id) or {}) do
      local l = by[type(e) == "table" and e[1] or e]
      if l then bottom = math.max(bottom, l.y + l.height) end
    end
    if top then out[id] = { x = top.x, y = top.y, width = top.width, height = bottom - top.y } end
  end
  return out
end

-- Open content before inserting it: failed jobs leave the tree untouched.
local term_open = terminal and terminal.open
local function open_term(opts)
  local panel = term_open({ title = "terminal" }, opts)
  if panel then W.split("cols", nil, nil, panel.id) end
  return panel
end

-- /term and ctrl+] open a terminal window rather than a docked one. An
-- explicit panel spec is left alone.
function fe.shutdown()
  if terminal then
    terminal.open = term_open
    terminal.passthrough[require("windows.tree").PREFIX] = nil
  end
  if W.root and bone.ui.layout == applied then bone.ui.layout = base end
end

W = require("windows.tree").new(fe)

if terminal then
  terminal.open = function(spec, opts)
    if spec ~= nil or not W.root then return term_open(spec, opts) end
    return open_term(opts)
  end
  -- The prefix works inside a terminal.
  terminal.passthrough[require("windows.tree").PREFIX] = true
end
W.keys.t = function() if terminal then open_term() end end
W.sub.term = W.keys.t
W.bind()

-- ---- the bar on each window ----------------------------------------------

bar = function(id, ctx)
  local l = W.label(id)
  if not l then return {} end
  local mine = id == W.here()
  local hl = mine and "WinBarActive" or "Dim"
  local mark = l.running and ctx.spinner .. " " or l.unread and "• " or ""
  local title = bone.text.truncate(mark .. l.name, math.max(ctx.width - 10, 1))
  return { {
    { " ⠿ ", hl }, { title, hl }, { " ", hl },
    { fill = mine and " " or "─", hl = mine and hl or "WinSeparator" }, { " ✕ ", hl },
  } }
end

-- ---- drop preview ---------------------------------------------------------

local function drop_zone(id, x, y)
  return drop.zone(id, fe.rects()[id], x, y, MIN)
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
  if drag and ev.action == "drag" then
    if drag.kind == "move" then
      local id = W.win_at(ev.x, ev.y)
      drag.target = id
      drag.zone = id and id ~= drag.id and drop_zone(id, ev.x, ev.y) or nil
      drop_show(drag.zone)
    else
      local at = drag.kind == "cols" and ev.x or ev.y
      if at ~= drag.last then
        W.resize(drag.split, drag.i - 1, drag.i, at - drag.last, true)
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
      local over = W.win_at(ev.x, ev.y)
      zone = over and over ~= id and drop_zone(over, ev.x, ev.y) or nil
    end
    drag = nil
    drop_hide()
    if kind == "move" then
      if zone and zone.side then
        W.move_to(id, zone.id, zone.side)
      elseif zone then
        W.exchange(id, zone.id)
      elseif was then
        -- A click on the focused window's title changes its session.
        local c = clicked
        bone.defer(350, function() if clicked == c then W.pick() end end)
      end
    end
    return true
  end
  local id = tonumber((ev.region or ""):match("^wm_bar:(%d+)$"))
  if id and ev.action == "down" and ev.button == "middle" then
    W.close(id)
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
    local r = fe.rects()[id]
    if r and ev.col > r.width - 3 then
      W.close(id)
      return true
    end
    local now = bone.now()
    if clicked and clicked.id == id and now - clicked.at < 350 then
      clicked = nil
      W.zoom()
      return true
    end
    clicked = { id = id, at = now }
    if not W.zoomed and W.count() > 1 then drag = { kind = "move", id = id, was = id == W.here() } end
    W.focus(id)
    return true
  end
  local key, i = region:match("^wm_hsep:(.*):(%d+)$")
  if key and splits[key] then
    drag = { kind = "rows", split = splits[key], i = tonumber(i), last = ev.y }
    return true
  end
  -- A click in another window focuses it.
  id = W.win_of(tonumber(region:match("^%a+:(%d+)$")), "chat")
  if id and id ~= W.here() then
    W.focus(id)
    return true
  end
end

bone.on("mouse", on_mouse)
