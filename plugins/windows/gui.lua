-- Tiled chat windows in the desktop app: the tree (lua/windows/tree.lua)
-- drawn as nodes in place of the window's one chat (the library window's
-- `area`). Each window has a title bar and its own chat; the focused one has
-- the composer, the others their unsent text, a click away from typing.

local ok, window = pcall(require, "bone.nodes.window")
if not ok or type(window.area) ~= "function" or type(window.column) ~= "function" then
  bone.notify("windows: this GUI library has no chat area to tile (bone.nodes.window.area)", "warn")
  return
end
local style = require("bone.nodes.style")
local drop = require("windows.drop")
local has_widgets, widgets = pcall(require, "bone.nodes.widgets")
local has_terminal, terminal = pcall(require, "bone.terminal")
if not has_terminal then terminal = nil end

local MIN = 180 -- the fewest pixels a resize leaves a window, either way
local BAR = 28 -- a window's title bar
local SEP = 7 -- the handle between two windows

local W
local held, drag -- pressed title id; { id, zone } after it actually moves
local fe = { state = bone.plugin.state(), min = MIN, step = 48, rows_step = 48 }

function fe.apply() bone.gui.invalidate() end
function fe.on_new(id)
  local w = W.wins[id]
  if w.panel then w.release = window.embed(w.panel) end
end
function fe.on_forget(_, w) if w.release then w.release() end end
function fe.rects()
  local out = {}
  for id in pairs(W.wins) do
    local r = bone.gui.rect("wm:" .. id)
    if r then out[id] = { x = r.x, y = r.y, width = r.w, height = r.h } end
  end
  return out
end

local tree = require("windows.tree")
W = tree.new(fe)

-- Any node panel can join the tree; terminals use this same attachment hook.
local previous_attach = window.attach_panel
local function attach(id)
  if not W.root then return previous_attach and previous_attach(id) end
  local panel = bone.ui.panel.get(id)
  assert(window.embed and window.panel and panel and bone.gui.panel_node(id), "windows: panel needs GUI node content")
  assert(panel:info().focusable, "windows: panel must be focusable")
  local existing = W.panel_win(id)
  if existing then return W.focus(existing) end
  W.split("cols", nil, nil, id)
end
window.attach_panel = attach
local passthrough = terminal and terminal.passthrough[tree.PREFIX]
if terminal then terminal.passthrough[tree.PREFIX] = true end
-- The term plugin's tabs and splits when it is loaded, else one terminal.
W.keys.t = function()
  local ok, mux = pcall(require, "term.mux")
  if ok and type(mux) == "table" and mux.is_active and mux.is_active() then return mux.open() end
  if terminal then terminal.open() end
end
W.sub.term = W.keys.t
W.bind()

function fe.shutdown()
  if window.attach_panel == attach then window.attach_panel = previous_attach end
  if terminal then terminal.passthrough[tree.PREFIX] = passthrough end
end

-- ---- drawing -------------------------------------------------------------

-- The handle before kid `i` of `split`: drag it to move the line.
local function handle(split, i)
  local cols = split.dir == "cols"
  return {
    [cols and "width" or "height"] = SEP, cursor = cols and "col-resize" or "row-resize",
    direction = cols and "row" or "column", justify = "center",
    hover = { bg = style.hover() },
    { [cols and "width" or "height"] = 1, bg = style.alpha("PromptBorder", "ff") or style.hover() },
    on_drag = function(pos)
      local r = W.bounds(split.kids[i - 1])
      if r then W.resize(split, i - 1, i, (cols and pos.x - r.x or pos.y - r.y) - SEP / 2) end
    end,
    on_release = W.save,
  }
end

local function mark(l)
  if l.running then
    if has_widgets and widgets.spinner then return widgets.spinner(12) end
    return { text = "●", hl = "Accent", size = style.size.small }
  end
  if l.unread then return { text = "•", hl = "Accent", size = style.size.caption } end
end

-- Use painted rectangles, not the estimated flex boxes: a sidebar or a
-- docked panel can shift/shrink the chat area. Pointer drags are in window
-- coordinates, whereas press/release positions are relative to the title.
local function drop_at(id, x, y)
  if W.zoomed then return end
  for other in pairs(W.wins) do
    if other ~= id then
      local r = bone.gui.rect("wm:" .. other)
      local z = r and drop.zone(other, { x = r.x, y = r.y, width = r.w, height = r.h }, x, y, MIN, SEP)
      if z then return z end
    end
  end
end

-- The library's glyph button where it has one.
local function close(id)
  local click = function() W.close(id) end
  if has_widgets and widgets.icon_button then
    return widgets.icon_button("✕", "Close the window", click, { size = style.size.small })
  end
  return {
    text = "✕", hl = "Dim", size = style.size.small, padding = { 2, 6, 2, 6 }, radius = style.radius.md,
    cursor = "pointer", role = "button", label = "Close the window", hover = { bg = style.hover() },
    on_click = click,
  }
end

-- A window's title: no fill. The focused one has its name in the text's own
-- color, an accent mark and an accent rule under it; the others are quiet.
local function bar(id)
  local l = W.label(id) or { name = "" }
  local mine = id == W.here()
  local x = close(id)
  local closer = { direction = "row", align = "center", opacity = mine and 0.75 or 0, hover = { opacity = 1 },
    transition = 90, shrink = 0, x }
  return {
    id = "wm:bar:" .. id,
    direction = "row", align = "center", gap = style.space.sm, height = BAR,
    padding = { 0, style.space.xs or 2, 0, style.space.md },
    cursor = drag and drag.id == id and "grabbing" or "grab",
    hover = { bg = style.hover() },
    on_press = function() held, drag = id, nil; W.focus(id) end,
    on_drag = function(pos)
      if held ~= id or W.zoomed or not W.wins[id] then return end
      drag = { id = id, zone = drop_at(id, pos.x, pos.y) }
      bone.gui.invalidate()
    end,
    on_release = function(pos)
      if held ~= id then return end
      held = nil
      if not drag or drag.id ~= id then return end
      local r = bone.gui.rect("wm:bar:" .. id)
      local z = r and drop_at(id, r.x + pos.x, r.y + pos.y)
      drag = nil
      if z then W.move_to(id, z.id, z.side) end
      bone.gui.invalidate()
    end,
    on_double_click = W.zoom,
    on_secondary = W.pick,
    mark(l) or (mine and { width = 6, height = 6, radius = 3, bg = style.alpha("Accent", "ff"), shrink = 0 }) or nil,
    { text = l.name, hl = mine and "Normal" or "Dim", bold = mine, size = style.size.caption,
      grow = 1, wrap = false, overflow = "hidden", text_overflow = "ellipsis" },
    closer,
  }
end

--- The rule under a title: the accent on the focused window, a hairline elsewhere.
local function rule(id)
  local mine = id == W.here()
  return { height = 1, shrink = 0, bg = mine and style.alpha("Accent", "ff") or (style.alpha("PromptBorder", "ff") or style.hover()),
    opacity = mine and 0.55 or 0.6 }
end

local function draw(node, parent, ctx, width, height)
  local cols = parent and parent.dir == "cols"
  local out
  if node.win then
    local id = node.win
    out = {
      id = "wm:" .. id, direction = "column", overflow = "hidden",
      bar(id),
      rule(id),
      W.wins[id].panel and window.panel(W.wins[id].panel, {
        width = width, height = math.max(0, height - BAR - 1), cell = ctx.cell,
      }) or window.column(ctx, {
        chat = W.wins[id].chat, width = width, on_focus = function() W.focus(id) end,
      }),
    }
  else
    local across = node.dir == "cols"
    local room = math.max(0, (across and width or height) - SEP * (#node.kids - 1))
    out = { direction = across and "row" or "column" }
    for i, k in ipairs(node.kids) do
      if i > 1 then out[#out + 1] = handle(node, i) end
      local size = room * k.w / W.weight(node)
      out[#out + 1] = draw(k, node, ctx, across and size or width, across and height or size)
    end
  end
  if parent then
    out[cols and "width" or "height"] = 0
    out.grow = node.w
  else
    out.grow = 1
  end
  return out
end

-- The tabs over the windows, once there are two: each a layout. The shown
-- one is bright, underlined in the accent; a click shows one, a middle click
-- closes it, + opens one.
local TABS = 30
local function tab_bar()
  local row = { direction = "row", align = "end", gap = style.space.xs or 2, height = TABS, shrink = 0,
    padding = { 0, style.space.md, 0, style.space.sm } }
  for i = 1, #W.tabs do
    local l = W.tab_label(i) or { name = "" }
    local on = i == W.tab_index()
    local label = i .. "  " .. (l.name ~= "" and l.name or "new chat") .. (l.count > 1 and ("  ·" .. l.count) or "")
    local tab = {
      direction = "column", shrink = 0, cursor = "pointer", radius = style.radius.md, max_width = 240,
      hover = not on and { bg = style.hover() } or nil, role = "option", selected = on, label = "Tab " .. i,
      { direction = "row", align = "center", gap = style.space.sm, height = TABS - 3, padding = { 0, style.space.md, 0, style.space.md },
        (l.running and has_widgets and widgets.spinner and widgets.spinner(10)) or (l.unread and { text = "•", hl = "Accent", size = style.size.caption }) or nil,
        { text = label, hl = on and "Normal" or "Dim", bold = on, size = style.size.caption, wrap = false,
          text_overflow = "ellipsis", shrink = 1 } },
      { height = 2, radius = 1, bg = on and style.alpha("Accent", "ff") or nil, margin = { 0, style.space.sm, 0, style.space.sm } },
    }
    tab.on_click = function() W.tab_go(i) end
    tab.on_middle = function() W.tab_go(i) W.tab_close() end
    row[#row + 1] = tab
  end
  row[#row + 1] = {
    text = "+", hl = "Dim", size = style.size.small, padding = { 3, 8, 3, 8 }, radius = style.radius.md,
    cursor = "pointer", role = "button", label = "A new tab (" .. tree.PREFIX .. " c)", tooltip = "A new tab (" .. tree.PREFIX .. " c)",
    hover = { bg = style.hover() }, margin = { 0, 0, 4, 0 },
    on_click = function() W.tab_new() end,
  }
  return {
    direction = "column", shrink = 0,
    row,
    { height = 1, bg = style.alpha("PromptBorder", "ff") or style.hover(), opacity = 0.6 },
  }
end

local plain = window.area
local function tiled(ctx)
  if not W.root or W.count() <= 1 or W.zoomed or (held and not W.wins[held]) then
    held, drag = nil, nil
  end
  if drag and drag.zone and not W.wins[drag.zone.id] then drag.zone = nil end
  local tabbed = W.root and #W.tabs > 1
  if not W.root or (W.count() == 1 and not W.wins[W.root.win].panel and not tabbed) then return plain(ctx) end
  local shown = W.zoomed and W.leaf(W.zoomed) or W.root
  local tree = draw(shown, nil, ctx, ctx.width, ctx.height - (tabbed and (TABS + 1) or 0))
  local out = { id = "wm:area", grow = 1, direction = "column" }
  if tabbed then out[#out + 1] = tab_bar() end
  out[#out + 1] = tree
  local z, origin = drag and drag.zone, bone.gui.rect("wm:area")
  if z and origin and not W.zoomed then
    local r = z.rect
    -- A paint-only overlay: it must not steal capture from the title or
    -- change the tree paths beneath it while the pointer is held.
    out[#out + 1] = {
      id = "wm:drop", position = "absolute", z = 20,
      left = r.x - origin.x, top = r.y - origin.y, width = r.width, height = r.height,
      border = 2, border_color = "Accent", bg = style.alpha("Accent", "18"), radius = style.radius.md,
    }
  end
  return out
end

window.area = tiled
bone.plugin.on_shutdown(function()
  if window.area == tiled then window.area = plain end
  bone.gui.invalidate()
end)

fe.apply()
