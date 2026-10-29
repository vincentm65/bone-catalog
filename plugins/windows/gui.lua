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
W.keys.t = function() if terminal then terminal.open() end end
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

local function bar(id)
  local l = W.label(id) or { name = "" }
  local mine = id == W.here()
  return {
    id = "wm:bar:" .. id,
    direction = "row", align = "center", gap = style.space.md, height = BAR,
    padding = { 0, style.space.sm, 0, style.space.lg },
    bg = mine and "Selection" or nil, cursor = drag and drag.id == id and "grabbing" or "grab",
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
    mark(l),
    { text = l.name, hl = mine and "Normal" or "Dim", bold = mine, size = style.size.caption,
      grow = 1, wrap = false, overflow = "hidden" },
    close(id),
  }
end

local function draw(node, parent, ctx, width, height)
  local cols = parent and parent.dir == "cols"
  local out
  if node.win then
    local id = node.win
    out = {
      id = "wm:" .. id, direction = "column", overflow = "hidden",
      bar(id),
      W.wins[id].panel and window.panel(W.wins[id].panel, {
        width = width, height = math.max(0, height - BAR), cell = ctx.cell,
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

local plain = window.area
local function tiled(ctx)
  if not W.root or W.count() <= 1 or W.zoomed or (held and not W.wins[held]) then
    held, drag = nil, nil
  end
  if drag and drag.zone and not W.wins[drag.zone.id] then drag.zone = nil end
  if not W.root or (W.count() == 1 and not W.wins[W.root.win].panel) then return plain(ctx) end
  local shown = W.zoomed and W.leaf(W.zoomed) or W.root
  local tree = draw(shown, nil, ctx, ctx.width, ctx.height)
  local out = { id = "wm:area", grow = 1, direction = "column", tree }
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
