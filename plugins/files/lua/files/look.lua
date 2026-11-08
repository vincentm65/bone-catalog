-- The files panel as the desktop draws it: its own nodes, not the shared
-- elements, so it can look the part. A header of breadcrumbs; the tree,
-- the search and the changed files in one column; and when a file is open,
-- the file itself in the room beside them, the column narrowing to the
-- right. Every color is a highlight group (or a tint of one), so the
-- colorscheme still decides how it looks; the sizes are this file's own, so
-- it looks the same whatever library draws the window.
--
-- ui.lua owns the state and what the keys do; it gives this module `app`
-- (M.setup), which says what there is to draw and what a press does.

local M = {}

local text = require("files.text")
local kinds = require("files.kinds")
local syntax = require("files.syntax")
local media = require("files.media")
local mesh = require("files.mesh")

local app
local menu_card -- below: the tree and the editor draw it inside their own box

local SIZE = { text = 13, small = 12, micro = 11, code = 13, crumb = 13 }
local ROW = 26      -- a row of the tree, the search, the changed files
local INDENT = 14   -- a level of the tree
local SIDE = 280    -- the column beside an open file
local LINE = 21     -- a line of the editor
local CODE_PAD = 14 -- the editor's room left of the text
local BAR = 8       -- the change bar's slot between the numbers and the text

-- ---- colors ----------------------------------------------------------------

local function rgb(c)
  local r, g, b = tostring(c or ""):match("^#(%x%x)(%x%x)(%x%x)")
  if not r then return nil end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function dark()
  local r, g, b = rgb((bone.hl.get("Normal") or {}).bg)
  if not r then return true end
  return (0.299 * r + 0.587 * g + 0.114 * b) < 128
end

--- Group `name`'s foreground with alpha `aa`, or `fallback`.
local function fg(name, aa, fallback)
  local c = (bone.hl.get(name) or {}).fg
  if rgb(c) then return c:sub(1, 7) .. (aa or "") end
  return fallback or name
end

--- A tint of the text color over what is under it.
local function tint(aa)
  return (dark() and "#ffffff" or "#000000") .. aa
end

local C = {}
local function colors()
  C.hover = tint("0b")
  C.line = tint("12")
  C.soft = tint("10")
  C.chip = tint("0d")
  C.current = tint("07")
  C.selected = fg("Accent", "40", tint("20"))
  C.selected_quiet = tint("16")
  C.accent = fg("Accent", "", "Accent")
  C.folder = fg("Accent", "d8", "Accent")
  C.folder_back = fg("Accent", "80", "Accent")
  C.dim = fg("Dim", "", "Dim")
  C.faint = fg("Dim", "90", "Dim")
  C.gutter = fg("Dim", "80", "Dim")
  C.warn = fg("WarningMsg", "", "WarningMsg")
  C.good = fg("Success", "", "Success")
  C.bad = fg("ErrorMsg", "", "ErrorMsg")
  C.warn_bg = fg("WarningMsg", "1c", tint("10"))
  C.bad_bg = fg("ErrorMsg", "1c", tint("10"))
  C.add_bg = fg("Success", "1e", tint("10"))
  C.del_bg = fg("ErrorMsg", "1e", tint("10"))
  C.match_bg = fg("Accent", "38", tint("20"))
  C.sel = fg("Accent", "4a", tint("26"))
  C.sel_quiet = tint("1a")
  C.find_bg = fg("WarningMsg", "40", tint("20"))
  C.find_now = fg("WarningMsg", "80", tint("30"))
  C.bracket = tint("26")
  C.flash = fg("Accent", "2a", tint("14"))
  C.bar_add = fg("Success", "d0", "Success")
  C.bar_mod = fg("Accent", "c0", "Accent")
  C.bar_del = fg("ErrorMsg", "d0", "ErrorMsg")
  C.card = (bone.hl.get("NormalFloat") or {}).bg or (bone.hl.get("Normal") or {}).bg or (dark() and "#1c1c1e" or "#ffffff")
  C.scrim = dark() and "#00000070" or "#00000030"
  C.ignored = fg("Dim", "70", "Dim")
  -- Text on the accent: dark on a light accent, white on a dark one.
  local ar, ag, ab = rgb(C.accent)
  C.on_accent = (ar and (0.299 * ar + 0.587 * ag + 0.114 * ab) > 150) and "#101012" or "#ffffff"
end

-- ---- drawn glyphs ----------------------------------------------------------

local function canvas(w, h, draw, o)
  local node = { width = w, height = h, shrink = 0, role = "none", canvas = { fps = 0, draw = draw } }
  for k, v in pairs(o or {}) do node[k] = v end
  return node
end

local function circle(cx, cy, r, steps)
  local pts = {}
  for k = 0, steps - 1 do
    local a = k / steps * math.pi * 2
    pts[#pts + 1] = { cx + math.cos(a) * r, cy + math.sin(a) * r }
  end
  return pts
end

--- A disclosure chevron: pointing right, or down when open.
local function chevron(open, color)
  return canvas(12, 12, function()
    local pts = open and { { 3, 4.5 }, { 6, 7.5 }, { 9, 4.5 } } or { { 4.5, 3 }, { 7.5, 6 }, { 4.5, 9 } }
    return { bone.gui.draw.polyline({ points = pts, color = color or C.faint, width = 1.6 }) }
  end)
end

local function folder_icon()
  return canvas(16, 13, function()
    local d = bone.gui.draw
    return {
      d.rect({ x = 0.5, y = 0.5, w = 6.5, h = 4, radius = 1.5, fill = C.folder_back }),
      d.rect({ x = 0.5, y = 2.5, w = 15, h = 10, radius = 2.5, fill = C.folder }),
    }
  end)
end

local KIND_COLOR = {
  code = "Accent", markdown = "Normal", html = "WarningMsg", image = "Success", pdf = "ErrorMsg",
}

--- A page with a folded corner, in the color of what the file is.
local function file_icon(name)
  local kind = kinds.of(name)
  local color = fg(KIND_COLOR[kind] or "Dim", "d0", "Dim")
  return canvas(16, 15, function()
    local d = bone.gui.draw
    return {
      d.polyline({ points = { { 3, 0.75 }, { 9.5, 0.75 }, { 13.25, 4.5 }, { 13.25, 14.25 }, { 3, 14.25 } },
        closed = true, color = color, width = 1.25, fill = fg(KIND_COLOR[kind] or "Dim", "18", tint("08")) }),
      d.polyline({ points = { { 9.5, 0.75 }, { 9.5, 4.5 }, { 13.25, 4.5 } }, color = color, width = 1.1 }),
    }
  end)
end

local function magnifier(color)
  return canvas(14, 14, function()
    local d = bone.gui.draw
    return {
      d.polyline({ points = circle(6, 6, 4.25, 20), closed = true, color = color or C.dim, width = 1.5 }),
      d.line({ x1 = 9.2, y1 = 9.2, x2 = 12.8, y2 = 12.8, color = color or C.dim, width = 1.6 }),
    }
  end)
end

local function cross(color)
  return canvas(12, 12, function()
    local d = bone.gui.draw
    return {
      d.line({ x1 = 2.5, y1 = 2.5, x2 = 9.5, y2 = 9.5, color = color or C.dim, width = 1.5 }),
      d.line({ x1 = 9.5, y1 = 2.5, x2 = 2.5, y2 = 9.5, color = color or C.dim, width = 1.5 }),
    }
  end)
end

--- A speech bubble: "add to chat".
local function bubble(color)
  return canvas(14, 14, function()
    local d = bone.gui.draw
    return {
      d.rect({ x = 1, y = 1.5, w = 12, h = 8.5, radius = 3, stroke = color or C.dim, width = 1.3 }),
      d.polyline({ points = { { 4, 10 }, { 3.5, 13 }, { 7, 10 } }, color = color or C.dim, width = 1.3 }),
    }
  end)
end

--- Three shortening lines: a filter.
local function funnel(color)
  return canvas(14, 14, function()
    local d = bone.gui.draw
    local c = color or C.faint
    return {
      d.line({ x1 = 1.5, y1 = 3.5, x2 = 12.5, y2 = 3.5, color = c, width = 1.4 }),
      d.line({ x1 = 3.5, y1 = 7, x2 = 10.5, y2 = 7, color = c, width = 1.4 }),
      d.line({ x1 = 5.5, y1 = 10.5, x2 = 8.5, y2 = 10.5, color = c, width = 1.4 }),
    }
  end)
end

local function arrow(up, color)
  return canvas(12, 12, function()
    local pts = up and { { 3, 7.5 }, { 6, 4.5 }, { 9, 7.5 } } or { { 3, 4.5 }, { 6, 7.5 }, { 9, 4.5 } }
    return { bone.gui.draw.polyline({ points = pts, color = color or C.dim, width = 1.5 }) }
  end)
end

local function plus_minus(plus, color)
  return canvas(12, 12, function()
    local d = bone.gui.draw
    local out = { d.line({ x1 = 2.5, y1 = 6, x2 = 9.5, y2 = 6, color = color or C.dim, width = 1.5 }) }
    if plus then out[2] = d.line({ x1 = 6, y1 = 2.5, x2 = 6, y2 = 9.5, color = color or C.dim, width = 1.5 }) end
    return out
  end)
end

--- An eye: following the agent.
local function eye(color)
  return canvas(16, 12, function()
    local d = bone.gui.draw
    local c = color or C.dim
    local top, bottom = {}, {}
    for k = 0, 12 do
      local t = k / 12
      local x = 1.5 + t * 13
      local h = math.sin(t * math.pi) * 4.2
      top[#top + 1] = { x, 6 - h }
      bottom[#bottom + 1] = { x, 6 + h }
    end
    return {
      d.polyline({ points = top, color = c, width = 1.3 }),
      d.polyline({ points = bottom, color = c, width = 1.3 }),
      d.polyline({ points = circle(8, 6, 2, 12), closed = true, color = c, width = 1.3, fill = c }),
    }
  end)
end

-- ---- small pieces ----------------------------------------------------------

local function press(node, click, label)
  node.on_click = click
  node.cursor = "pointer"
  node.role = node.role or "button"
  node.label = node.label or label
  node.transition = node.transition or 80
  if node.hover == nil then node.hover = { bg = C.hover } end
  return node
end

--- A borderless square button holding a glyph.
local function icon_button(glyph, label, click)
  return press({ width = 26, height = 26, radius = 7, shrink = 0, direction = "row",
    align = "center", justify = "center", tooltip = label, glyph }, click, label)
end

--- A small rounded chip: a count, a Git letter.
local function chip(label, color, bg)
  return { text = label, size = SIZE.micro, bold = true, color = color or C.dim, bg = bg or C.chip,
    radius = 5, padding = { 1, 6 }, wrap = false, shrink = 0 }
end

--- How long `t` seconds is: 1:05, or 1:02:05.
local function clock(t)
  t = math.max(0, math.floor(tonumber(t) or 0))
  local h, m, sec = math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%d:%02d", m, sec)
end

--- The keys of a pane, quiet, in one line under it.
-- The keys are a press of "?" in the header away, not a strip under every pane.
local keys_shown = false

local function hints(list, always)
  if not (keys_shown or always) then return nil end
  local row = { direction = "row", gap = 12, align = "center", padding = { 6, 4, 0, 4 }, flex_wrap = true, row_gap = 4 }
  for _, h in ipairs(list) do
    row[#row + 1] = { direction = "row", gap = 5, align = "center",
      { text = h[1], font = "mono", size = SIZE.micro, color = C.dim, bg = C.chip, radius = 4, padding = { 1, 5 }, wrap = false },
      { text = h[2], size = SIZE.micro, color = C.faint, wrap = false },
    }
  end
  return row
end

--- A switch between a few views in one rounded track.
local function segmented(names, current, pick, o)
  o = o or {}
  -- Flat: the names alone, the chosen one in the text's own color, no track.
  local flat = o.flat
  local row = { direction = "row", gap = flat and 14 or 2, padding = flat and { 0, 2 } or 2, radius = 8,
    bg = (not flat) and C.chip or nil, align = "center", align_self = o.align or "stretch" }
  for i, name in ipairs(names) do
    local on = i == current
    local seg = { direction = "row", gap = 5, align = "center", justify = "center",
      grow = (o.fill and not flat) and 1 or 0, padding = flat and { 4, 0 } or { 3, o.pad or 10 }, radius = 6,
      bg = (on and not flat) and C.soft or nil, shadow = (on and not flat) and { blur = 3, dy = 1, color = "#00000040" } or nil,
      role = "option", selected = on,
      { text = name, size = o.size or SIZE.small, bold = on, color = (not on) and C.dim or nil,
        hl = on and "Normal" or nil, wrap = false },
    }
    if o.counts and o.counts[i] and o.counts[i] > 0 then
      seg[#seg + 1] = { text = tostring(o.counts[i]), size = SIZE.micro, color = C.faint, wrap = false }
    end
    press(seg, function() if not on then pick(i) end end, name)
    if flat then seg.hover = { color = "Normal" } end
    row[#row + 1] = seg
  end
  return row
end

-- ---- the header: where the folder is ---------------------------------------

local function crumbs(root, home)
  local out = {}
  local rest = root
  local drive = root:match("^%a:/")
  if home ~= "" and home ~= "/" and (root == home or root:sub(1, #home + 1) == home .. "/") then
    out[1] = { label = "~", path = home }
    rest = root:sub(#home + 2)
  elseif drive then
    -- A Windows drive: C: is the first crumb, C:/ its path.
    out[1] = { label = drive:sub(1, 2), path = drive }
    rest = root:sub(#drive + 1)
  else
    out[1] = { label = "/", path = "/" }
    rest = root:gsub("^/+", "")
  end
  local at = out[1].path
  for part in tostring(rest):gmatch("[^/]+") do
    at = (at:sub(-1) == "/" and at or at .. "/") .. part
    out[#out + 1] = { label = part, path = at }
  end
  return out
end

local function header(s)
  local row = { direction = "row", align = "center", gap = 4, height = 34, padding = { 0, 6, 0, 10 }, shrink = 0 }
  local trail = crumbs(s.listing.root, s.home)
  -- A deep folder keeps its last few steps: the start is a press away.
  local first = math.max(1, #trail - 1)
  if first > 1 then
    local up = press({ text = "…", size = SIZE.crumb, color = C.dim, padding = { 2, 4 }, radius = 5 },
      function() app.crumb(trail[first - 1].path) end, "up")
    up.tooltip = s.listing.root .. "  ·  up a folder"
    row[#row + 1] = up
    row[#row + 1] = { text = "›", size = SIZE.crumb, color = C.faint }
  end
  for i = first, #trail do
    local last = i == #trail
    local c = trail[i]
    local node = { text = c.label, size = SIZE.crumb, wrap = false, padding = { 2, 5 }, radius = 5,
      bold = last, hl = last and "Normal" or nil, color = (not last) and C.dim or nil,
      text_overflow = "ellipsis", shrink = last and 1 or 0 }
    if not last then
      press(node, function() app.crumb(c.path) end, c.label)
      node.hover = { bg = C.hover, color = "Normal" }
    end
    row[#row + 1] = node
    if not last then row[#row + 1] = { text = "›", size = SIZE.crumb, color = C.faint } end
  end
  if s.listing.git_state == "loading" then
    row[#row + 1] = { text = "·  git…", size = SIZE.micro, color = C.faint, wrap = false }
  end
  row[#row + 1] = { grow = 1 }
  local note = s.listing.error or s.listing.note
  if note then
    row[#row + 1] = { text = note, size = SIZE.small, color = s.listing.error and C.bad or C.dim,
      wrap = false, text_overflow = "ellipsis", shrink = 1, max_width = 420 }
  end
  if s.listing.hidden then row[#row + 1] = chip("hidden shown") end
  if s.keys_here == false then row[#row + 1] = chip("keys: prompt") end
  row[#row + 1] = press({ direction = "row", align = "center", gap = 6, height = 26, padding = { 0, 9 }, radius = 7,
    bg = C.chip, shrink = 0, tooltip = "Go to a file by a few letters of its path (ctrl+p)",
    magnifier(C.dim), { text = "Go to file", size = SIZE.small, color = C.dim, wrap = false },
    { text = "ctrl+p", size = SIZE.micro, font = "mono", color = C.faint, wrap = false } },
    function() app.act.quick_open() end, "Go to file")
  local on = s.following
  row[#row + 1] = press({ direction = "row", align = "center", gap = 6, height = 26, padding = { 0, 9 }, radius = 7,
    bg = on and C.selected or nil, shrink = 0,
    tooltip = on and "Following the agent: each file it writes opens here (F)" or "Follow the agent: open each file it writes (F)",
    eye(on and C.accent or C.dim), { text = "Follow", size = SIZE.small, color = on and C.accent or C.dim, wrap = false } },
    function() app.act.toggle_follow() end, "Follow the agent")
  local q = icon_button({ text = "?", size = SIZE.small, bold = keys_shown, color = keys_shown and C.accent or C.faint },
    keys_shown and "Hide the keys" or "Show the keys", function()
      keys_shown = not keys_shown
      pcall(bone.gui.invalidate, 0)
    end)
  row[#row + 1] = q
  row[#row + 1] = icon_button(cross(), "Close the files panel", function() app.close_panel() end)
  return row
end

-- ---- the tree --------------------------------------------------------------

local function sign_color(sign)
  if sign == "?" or sign == "A" then return C.good end
  if sign == "D" then return C.bad end
  return C.warn
end

--- What a row says at its right end: this session's write, Git's letter,
--- and (where there is room) the size.
local function row_marks(row, path, size, narrow)
  local b = app.badges(path)
  if b.mark then
    row[#row + 1] = { width = 6, height = 6, radius = 3, bg = C.warn, shrink = 0,
      tooltip = (b.mark.writes or 1) > 1 and ("edited ×" .. b.mark.writes .. " this session") or "edited this session" }
  end
  if b.sign then
    row[#row + 1] = { text = b.sign == "?" and "U" or b.sign, font = "mono", size = SIZE.micro, bold = true,
      color = sign_color(b.sign), wrap = false, shrink = 0, width = 12, text_align = "center",
      tooltip = b.sign == "?" and "not tracked by Git" or ("Git: " .. b.sign) }
  elseif b.inside then
    row[#row + 1] = { width = 5, height = 5, radius = 3, bg = C.faint, shrink = 0, margin = { 0, 4, 0, 3 },
      tooltip = "changes inside" }
  end
  if size and not narrow then
    row[#row + 1] = { text = size, size = SIZE.micro, color = C.faint, wrap = false, shrink = 0,
      width = 56, text_align = "right" }
  end
end

--- A name with the filter's letters marked.
local function name_spans(r)
  if not r.hit then return nil end
  local a, b = r.hit[1], r.hit[2]
  local out = {}
  if a > 1 then out[#out + 1] = { text = r.name:sub(1, a - 1) } end
  out[#out + 1] = { text = r.name:sub(a, b), bg = C.match_bg, bold = true }
  if b < #r.name then out[#out + 1] = { text = r.name:sub(b + 1) } end
  return out
end

local function tree_row(s, i, narrow, focused)
  local r = s.listing.rows[i]
  if not r then return { height = ROW } end
  local on = i == s.listing.selected
  local open = r.type == "dir" and (s.listing.open[r.path] or r.unfolded)
  local quiet = r.ignored or r.name:sub(1, 1) == "."
  local spans = name_spans(r)
  local node = {
    direction = "row", align = "center", gap = 6, height = ROW, radius = 7,
    padding = { 0, 8, 0, 4 + r.depth * INDENT },
    bg = on and (focused and C.selected or C.selected_quiet) or nil,
    role = "option", selected = on, opacity = r.ignored and 0.55 or nil,
    r.type == "dir" and chevron(open, on and focused and C.accent or nil) or { width = 12, shrink = 0 },
    r.type == "dir" and folder_icon() or file_icon(r.name),
    { text = (not spans) and r.name or nil, spans = spans, size = SIZE.text, hl = "Normal", wrap = false,
      text_overflow = "ellipsis", grow = 1, width = 0, color = quiet and C.dim or nil },
  }
  if r.ignored then node.tooltip = "kept out by .gitignore" end
  row_marks(node, r.path, r.type == "file" and app.size_of(r.size) or nil, narrow)
  press(node, function() app.click_row(i) end, r.name)
  node.on_secondary = function(p)
    local info = bone.gui.scroll_info and bone.gui.scroll_info("files:tree")
    local offset = info and info.offset or 0
    app.act.tree_menu(i, (i - 1) * (ROW + 1) - offset + (p and p.y or 0), (p and p.x or 0) + 4)
  end
  if on then node.hover = { bg = node.bg } end
  return node
end

--- The folder the top of the list is inside, pinned over it while its own
--- row is scrolled away, as a Finder list keeps its group's head.
--- The row of the folder to pin over the tree, scrolled `offset` pixels.
local function sticky_row(rows, offset)
  if (offset or 0) < ROW then return nil end
  local first = math.floor(offset / (ROW + 1)) + 2
  local r = rows[first]
  if not r or r.depth == 0 then return nil end
  for k = first - 1, 1, -1 do
    if rows[k].type == "dir" and rows[k].depth == r.depth - 1 then return k end
  end
  return nil
end

local pinned = nil -- the row pinned when the tree was last drawn

local function sticky(s, narrow, focused)
  local info = bone.gui.scroll_info and bone.gui.scroll_info("files:tree")
  local j = sticky_row(s.listing.rows, info and info.offset)
  pinned = j
  if not j then return nil end
  local head = tree_row(s, j, narrow, focused)
  head.bg = C.card
  head.radius = 0
  head.on_secondary = nil
  head.shadow = { blur = 6, dy = 2, color = "#00000055" }
  return { position = "absolute", top = 0, left = 0, right = 0, z = 5, head }
end

local function tree(s, narrow, focused)
  local rows = s.listing.rows
  if #rows == 0 then
    return { padding = { 16, 12 }, grow = 1, { text = s.listing.error
      or (s.listing.filter ~= "" and ("No name in this folder holds “" .. s.listing.filter .. "”"))
      or "This folder is empty.", size = SIZE.small, color = C.dim } }
  end
  app.scroll_to("files:tree", s.listing.selected, s.listing.root .. "|" .. s.listing.filter)
  local list = {
    id = "files:tree", grow = 1,
    -- Scrolling moves which folder is pinned at the top: drawn again only
    -- when that changes, once the scroll has moved.
    on_scroll = function()
      bone.defer(20, function()
        local info = bone.gui.scroll_info and bone.gui.scroll_info("files:tree")
        if sticky_row(rows, info and info.offset) ~= pinned then pcall(bone.gui.invalidate, 0) end
      end)
    end,
    list = { count = #rows, estimate = ROW, gap = 1,
      key = "files:tree:" .. s.listing.root .. (s.listing.hidden and ":h" or "") .. ":" .. s.listing.filter,
      item = function(i) return tree_row(s, i, narrow, focused) end },
  }
  local box = { direction = "column", grow = 1, list }
  box[#box + 1] = sticky(s, narrow, focused)
  if s.menu and s.menu.where == "tree" then box[#box + 1] = menu_card(s.menu, s.side_width, s.room_h) end
  if s.listing.truncated then
    box[#box + 1] = { text = "The list stops here: open fewer folders to see the rest.", size = SIZE.micro, color = C.faint, padding = { 6, 8 } }
  end
  return box
end

-- ---- the search ------------------------------------------------------------

--- `snippet` with the term colored where it matches.
local function marked(snippet, term)
  local spans = {}
  if term == "" then return { { text = snippet } } end
  local hay = term:match("%u") and snippet or snippet:lower()
  local needle = term:match("%u") and term or term:lower()
  local at = 1
  while true do
    local s, e = hay:find(needle, at, true)
    if not s then break end
    if s > at then spans[#spans + 1] = { text = snippet:sub(at, s - 1) } end
    spans[#spans + 1] = { text = snippet:sub(s, e), bg = C.match_bg, bold = true }
    at = e + 1
  end
  if at <= #snippet then spans[#spans + 1] = { text = snippet:sub(at) } end
  return spans
end

local function search(s, narrow, focused)
  local col = { direction = "column", grow = 1, gap = 6 }
  local field = {
    direction = "row", align = "center", gap = 8, height = 32, padding = { 0, 10 }, radius = 8, shrink = 0,
    bg = C.chip, border = 1, border_color = C.line,
    magnifier(),
    { id = "files:search", grow = 1, width = 0, size = SIZE.text,
      text_input = { value = s.listing.query, placeholder = "Search in " .. s.leaf, focus = true,
        on_change = function(t) app.search_typed(t) end },
      on_key = function(k) return app.search_nav(k) end },
  }
  if s.listing.query ~= "" then
    field[#field + 1] = icon_button(cross(C.faint), "Clear", function() app.search_typed("") end)
  end
  col[#col + 1] = field
  local state
  if s.listing.search_state == "loading" then
    state = "Searching…"
  elseif s.search_error then
    state = s.search_error
  elseif s.listing.search_state == "done" then
    local files = {}
    for _, h in ipairs(s.hits) do files[h.name] = true end
    local n = 0
    for _ in pairs(files) do n = n + 1 end
    state = #s.hits .. (#s.hits == 1 and " result" or " results") .. " in " .. n .. (n == 1 and " file" or " files")
    if s.search_note then state = state .. " · " .. s.search_note end
  elseif s.listing.search_state == "empty" then
    state = s.search_note or "No results."
  else
    state = "Text inside the files · lowercase matches any case"
  end
  col[#col + 1] = { text = state, size = SIZE.micro, color = s.search_error and C.bad or C.faint, padding = { 0, 4 } }

  -- The hits under their file, like an editor's search.
  local items, at_hit, last = {}, {}, nil
  for i, h in ipairs(s.hits) do
    if h.name ~= last then
      items[#items + 1] = { file = h.name, path = h.path }
      last = h.name
    end
    items[#items + 1] = { hit = i }
    at_hit[i] = #items
  end
  if #items == 0 then return col end
  app.scroll_to("files:hits", at_hit[s.listing.hit_selected], s.listing.query)
  local term = s.listing.query
  col[#col + 1] = {
    id = "files:hits", grow = 1,
    list = { count = #items, estimate = ROW, key = "files:hits:" .. term, item = function(n)
      local it = items[n]
      if it.file then
        local dir, leaf = it.file:match("^(.*/)([^/]+)$")
        return { direction = "row", align = "center", gap = 6, height = ROW, padding = { 4, 6, 0, 4 },
          file_icon(it.file),
          { text = leaf or it.file, size = SIZE.small, bold = true, hl = "Normal", wrap = false, shrink = 0 },
          dir and { text = dir, size = SIZE.micro, color = C.faint, wrap = false, text_overflow = "ellipsis", grow = 1, width = 0 } or { grow = 1 },
        }
      end
      local h = s.hits[it.hit]
      local on = it.hit == s.listing.hit_selected
      local node = { direction = "row", align = "center", gap = 8, height = 24, radius = 6,
        padding = { 0, 8, 0, 26 }, role = "option", selected = on,
        bg = on and (focused and C.selected or C.selected_quiet) or nil,
        { text = tostring(h.line or ""), font = "mono", size = SIZE.micro, color = C.faint, width = 30,
          text_align = "right", shrink = 0, wrap = false },
        { spans = marked((h.text or ""):gsub("^%s+", ""), term), font = "mono", size = SIZE.small, hl = "Normal",
          wrap = false, text_overflow = "ellipsis", grow = 1, width = 0 },
      }
      return press(node, function() app.open_hit(it.hit) end, h.name .. ":" .. tostring(h.line))
    end },
  }
  return col
end

-- ---- what changed ----------------------------------------------------------

local function changed(s, narrow, focused)
  local list = app.changed_items()
  if #list == 0 then
    return { padding = { 16, 12 }, { text = list.empty, size = SIZE.small, color = C.dim } }
  end
  app.scroll_to("files:changed", s.listing.changed_selected, "changed")
  return {
    id = "files:changed", grow = 1,
    list = { count = #list, estimate = ROW, gap = 1, key = "files:changed", item = function(i)
      local it = list[i]
      local on = i == s.listing.changed_selected
      local dir, leaf = it.rel:match("^(.*/)([^/]+)$")
      local node = { direction = "row", align = "center", gap = 7, height = ROW, radius = 7, padding = { 0, 8 },
        role = "option", selected = on, bg = on and (focused and C.selected or C.selected_quiet) or nil,
        file_icon(it.rel),
        { text = leaf or it.rel, size = SIZE.text, hl = "Normal", wrap = false, shrink = 0 },
        { text = dir or "", size = SIZE.micro, color = C.faint, wrap = false, text_overflow = "ellipsis", grow = 1, width = 0 },
      }
      if it.written then
        node[#node + 1] = { text = it.detail, size = SIZE.micro, color = C.faint, wrap = false, shrink = 0 }
        node[#node + 1] = { width = 6, height = 6, radius = 3, bg = C.warn, shrink = 0, tooltip = "written this session" }
      end
      if it.sign then
        node[#node + 1] = { text = it.sign == "?" and "U" or it.sign, font = "mono", size = SIZE.micro, bold = true,
          color = sign_color(it.sign), width = 12, text_align = "center", shrink = 0 }
      end
      return press(node, function() app.open_changed(i) end, it.rel)
    end },
  }
end

-- ---- the column of files ---------------------------------------------------

local TABS = { "Files", "Search", "Changed" }

local function side_column(s, width, narrow)
  local focused = s.keys_here ~= false and not s.doc_focused
  local col = { direction = "column", gap = 8, padding = { 4, 8, 8, 8 }, shrink = 0 }
  if narrow then col.width = width else col.grow = 1 end
  col[#col + 1] = segmented(TABS, s.tab, function(i) app.tab(i) end,
    { flat = true, align = "start", counts = { 0, 0, app.changed_count() }, size = SIZE.small })
  s.side_width = width
  if s.tab == 2 then
    col[#col + 1] = search(s, narrow, focused)
  elseif s.tab == 3 then
    col[#col + 1] = changed(s, narrow, focused)
  else
    col[#col + 1] = tree(s, narrow, focused)
  end
  if focused then
    local keys
    if s.tab == 2 then
      keys = { { "↑↓", "results" }, { "enter", "open" }, { "esc", "back" } }
    elseif narrow then
      keys = { { "↑↓", "move" }, { "←→", "fold" }, { "tab", "editor" }, { "esc", "close file" } }
    else
      keys = { { "↑↓", "move" }, { "←→", "fold" }, { "enter", "open" }, { "ctrl+p", "go to file" },
        { "/", "search" }, { "a", "new" }, { "R", "rename" }, { "right click", "more" } }
    end
    col[#col + 1] = hints(keys)
  end
  return col
end

-- ---- the open file ---------------------------------------------------------

--- The monospace advance at size `size`, from the window's own cell.
local function advance(size)
  local info = (bone.gui.window_info and bone.gui.window_info()) or {}
  local cell = info.cell or {}
  local base = tonumber(bone.o and bone.o.font_size) or 14
  local w = tonumber(cell.w) or (size * 0.6)
  return w * size / math.max(base, 1)
end

--- The screen columns of `line` up to byte `to` (a tab is four).
local function columns_of(line, from, to)
  local n, at = 0, from
  while at < to do
    local next = text.next_offset(line, at)
    if next <= at then break end
    n = n + (line:sub(at + 1, at + 1) == "\t" and 4 or 1)
    at = next
  end
  return n
end

--- The byte offset in `line`, from byte `from`, nearest screen column `col`.
local function offset_at(line, from, col)
  local n, at = 0, from
  while at < #line do
    local w = line:sub(at + 1, at + 1) == "\t" and 4 or 1
    if n + w / 2 > col then break end
    local next = text.next_offset(line, at)
    if next <= at then break end
    n, at = n + w, next
  end
  return at
end

local function spans(line, runs, a, b)
  local out = {}
  for _, r in ipairs(runs) do
    local s0, e0 = math.max(r[1], a), math.min(r[2], b)
    if e0 > s0 then out[#out + 1] = { text = (line:sub(s0 + 1, e0):gsub("\t", "    ")), hl = r[3] } end
  end
  return out
end

--- The syntax runs of a line cut at every place a paint starts or stops, each
--- piece with the paint's background: the selection, the find's matches,
--- the bracket pair. `paints` is { { from, to, bg } } in bytes; later ones
--- win.
local function painted(line, runs, a, b, paints)
  if #paints == 0 then return spans(line, runs, a, b) end
  local cuts = { [a] = true, [b] = true }
  for _, r in ipairs(runs) do cuts[r[1]] = true cuts[r[2]] = true end
  for _, p in ipairs(paints) do cuts[p[1]] = true cuts[p[2]] = true end
  local order = {}
  for c in pairs(cuts) do if c >= a and c <= b then order[#order + 1] = c end end
  table.sort(order)
  local out = {}
  local ri = 1
  for k = 1, #order - 1 do
    local s0, e0 = order[k], order[k + 1]
    if e0 > s0 then
      while runs[ri] and runs[ri][2] <= s0 do ri = ri + 1 end
      local hl = runs[ri] and runs[ri][1] <= s0 and runs[ri][3] or nil
      local bg
      for _, p in ipairs(paints) do if p[1] <= s0 and p[2] >= e0 then bg = p[3] end end
      out[#out + 1] = { text = (line:sub(s0 + 1, e0):gsub("\t", "    ")), hl = hl, bg = bg }
    end
  end
  return out
end

-- A press in the editor, for the drag that may follow: where the line was in
-- the window, and how far the list was scrolled then.
local drag = nil

--- The pieces of `line` that fit `room` columns, as byte ranges { a, b }:
--- broken after a space when there is one in the last part of the row, else
--- at the column (a tab is four).
local function pieces(line, room)
  if #line == 0 then return { { 0, 0 } } end
  local out = {}
  local a, col, at, space = 0, 0, 0, nil
  while at < #line do
    local ch = line:sub(at + 1, at + 1)
    local w = ch == "\t" and 4 or 1
    if col + w > room and at > a then
      local cut = at
      if space and space > a and (space - a) > room * 0.4 then cut = space end
      out[#out + 1] = { a, cut }
      a, space = cut, nil
      col = columns_of(line, a, at)
    else
      if ch == " " then space = at + 1 end
      local nxt = text.next_offset(line, at)
      if nxt <= at then break end
      col, at = col + w, nxt
    end
  end
  out[#out + 1] = { a, #line }
  return out
end

--- How many rows each line takes when wrapped at `room`, and the rows
--- before each: kept until the text or the room changes.
local function wrapped(e, room)
  local key = tostring(e.version or 0) .. ":" .. room .. ":" .. #e.lines
  local w = e.wrapped
  if w and w.key == key then return w end
  local before, rows = {}, 0
  for i, line in ipairs(e.lines) do
    before[i] = rows
    -- A line shorter than the room is one row, without walking it.
    if #line <= room and not line:find("\t", 1, true) then rows = rows + 1 else rows = rows + #pieces(line, room) end
  end
  w = { key = key, before = before, rows = rows }
  e.wrapped = w
  return w
end

--- Whether a file wraps when nothing said: prose does, code does not.
local function wraps_by_default(path)
  local ext = (tostring(path):match("%.(%w+)$") or ""):lower()
  return ext == "md" or ext == "markdown" or ext == "txt" or ext == "rst" or ext == "org" or ext == "tex" or ext == ""
end

local function editor_lines(s, width)
  local e = s.editor
  local focused = s.doc_focused and s.keys_here ~= false
  local cw = advance(SIZE.code)
  local digits = math.max(3, #tostring(#e.lines))
  local gutter = digits * advance(SIZE.small) + 16
  local room = math.max(8, math.floor((width - gutter - CODE_PAD - 24) / cw))
  if e.wrap == nil then e.wrap = wraps_by_default(e.path) end
  local wrap = e.wrap
  -- Without wrap every line is cut at the same column, so the text stays
  -- lined up: the view slides right when the caret is past what fits.
  local shift = 0
  if not wrap then
    local caret_col = columns_of(e.lines[e.line] or "", 0, e.col)
    if caret_col + 2 > room then shift = caret_col - math.floor(room * 0.6) end
  end
  local W = wrap and wrapped(e, room) or nil
  local lang = syntax.lang(e.path:match("[^/]+$") or "")
  -- While a drag selects, the view only steps to keep the caret in it: a
  -- jump to the middle would run the selection away.
  app.scroll_to("files:editor", e.line, e.path, (drag and not drag.done) and "nearest" or nil)
  -- What is painted over the text.
  local s1, c1, s2, c2
  if e.anchor and not (e.anchor.line == e.line and e.anchor.col == e.col) then
    local al, ac = e.anchor.line, e.anchor.col
    if al < e.line or (al == e.line and ac < e.col) then s1, c1, s2, c2 = al, ac, e.line, e.col
    else s1, c1, s2, c2 = e.line, e.col, al, ac end
  end
  local hits = app.find_hits()
  local by_line = {}
  local current = e.find and e.find.at
  for n, h in ipairs(hits or {}) do
    local l = by_line[h[1]] or {}
    l[#l + 1] = { h[2], h[3], n == current and C.find_now or C.find_bg }
    by_line[h[1]] = l
  end
  local ba, bb = app.brackets()
  local marks = app.marks() or {}
  local flash = e.flash
  local sel_bg = focused and C.sel or C.sel_quiet

  --- The rows of line `i`: byte ranges, one when not wrapping.
  local function rows_of(line)
    if wrap then return pieces(line, room) end
    local a = offset_at(line, 0, shift)
    return { { a, offset_at(line, a, room) } }
  end

  -- Where the text starts in the list, and the line, its row and the byte
  -- under a point in it (x and y from the list's own top left).
  local text_x = (gutter - 10) + BAR + CODE_PAD
  local function line_at(y)
    local info = bone.gui.scroll_info and bone.gui.scroll_info("files:editor")
    local offset = info and info.offset or 0
    local row = math.max(0, math.floor((y - 6 + offset) / LINE))
    if not W then return math.max(1, math.min(#e.lines, row + 1)), 1, info end
    -- The last line with no more rows before it than `row`.
    local lo, hi = 1, #e.lines
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if W.before[mid] <= row then lo = mid else hi = mid - 1 end
    end
    return lo, row - W.before[lo] + 1, info
  end
  local function col_at(line, x, r)
    local rows = rows_of(line)
    local piece = rows[math.max(1, math.min(#rows, r or 1))]
    local at = offset_at(line, piece[1], math.max(0, x - text_x) / cw)
    -- Not past the end of the row (its last byte goes to the next row).
    if r and r < #rows and at >= piece[2] then at = text.prev_offset(line, piece[2]) end
    return math.min(at, piece[2])
  end

  local list = {
    id = "files:editor", grow = 1, padding = { 6, 0 }, cursor = "text",
    -- The pointer is the list's, not a line's: a line scrolled away takes
    -- nothing with it. A press puts the caret, a drag selects (past the top
    -- or the bottom the view follows), a double click takes a word.
    on_press = function(p)
      local x, y = p and p.x or 0, p and p.y or 0
      local li, r = line_at(y)
      local at = app.act.press_at
      drag = { line = li, col = col_at(e.lines[li] or "", x, r),
        ox = at and (at[1] - x), oy = at and (at[2] - y) }
      app.caret(li, drag.col)
    end,
    on_drag = function(q)
      if not drag or not drag.ox or not q then return end
      local x, y = q.x - drag.ox, q.y - drag.oy
      local info = bone.gui.scroll_info and bone.gui.scroll_info("files:editor")
      local view = info and info.viewport or 0
      -- Past an edge the line is the one at the edge: the timer below takes
      -- the selection on from there, a line at a time.
      local li, r = line_at(view > 0 and math.max(0, math.min(y, view - 7)) or math.max(0, y))
      local from = drag
      app.edit(function(ed)
        if not ed.anchor then ed.anchor = { line = from.line, col = from.col } end
        ed.line, ed.col = li, col_at(ed.lines[li] or "", x, r)
      end)
      drag.dir = (view > 0 and y < 4) and -1 or (view > 0 and y > view - 4) and 1 or 0
      drag.x = x
      if drag.dir ~= 0 and not drag.ticking then
        drag.ticking = true
        local held = drag
        local function tick()
          if drag ~= held or held.done or held.dir == 0 or app.act.button_down == false then
            held.ticking = false
            return
          end
          app.edit(function(ed)
            if not ed.anchor then ed.anchor = { line = held.line, col = held.col } end
            ed.line = math.max(1, math.min(#ed.lines, ed.line + held.dir))
            ed.col = col_at(ed.lines[ed.line] or "", held.x, held.dir > 0 and 1000000 or 1)
          end)
          bone.defer(45, tick)
        end
        bone.defer(45, tick)
      end
    end,
    on_release = function()
      if drag then drag.done, drag.dir = true, 0 end
    end,
    on_double_click = function(p)
      local li, r = line_at(p and p.y or 0)
      local col = col_at(e.lines[li] or "", p and p.x or 0, r)
      app.edit(function(ed) require("files.buffer").select_word(ed, li, col) end)
    end,
    on_secondary = function(p)
      local y = p and p.y or 0
      app.act.editor_menu(y, (p and p.x or 0))
    end,
    list = { count = #e.lines, estimate = LINE, key = "files:editor:" .. e.path .. (wrap and (":w" .. room) or ""),
      item = function(i)
      local line = e.lines[i] or ""
      local cur = i == e.line
      local runs = syntax.runs(line, lang)
      local paints = {}
      for _, h in ipairs(by_line[i] or {}) do paints[#paints + 1] = h end
      if ba and ba[1] == i then paints[#paints + 1] = { ba[2], ba[2] + 1, C.bracket } end
      if bb and bb[1] == i then paints[#paints + 1] = { bb[2], bb[2] + 1, C.bracket } end
      local eol = false
      if s1 and i >= s1 and i <= s2 then
        local from = (i == s1) and c1 or 0
        local to = (i == s2) and c2 or #line
        if to > from then paints[#paints + 1] = { from, to, sel_bg } end
        eol = i < s2
      end
      local rows = rows_of(line)
      -- The row the caret is in: a caret at the end of a row is at the start
      -- of the next one, but for the last.
      local caret_row
      if cur then
        caret_row = #rows
        for k, piece in ipairs(rows) do
          if e.col < piece[2] or k == #rows then caret_row = k break end
        end
      end
      local text_col = { direction = "column", grow = 1, width = 0 }
      for k, piece in ipairs(rows) do
        local a, b = piece[1], piece[2]
        local row = { direction = "row", align = "center", height = LINE, overflow = "hidden",
          padding = { 0, 0, 0, CODE_PAD } }
        if k == caret_row then
          local c = math.max(a, math.min(e.col, b))
          row[#row + 1] = { spans = painted(line, runs, a, c, paints), font = "mono", size = SIZE.code, wrap = false, shrink = 0 }
          row[#row + 1] = { width = 2, height = LINE - 4, radius = 1, shrink = 0,
            bg = focused and C.accent or C.faint, margin = { 0, -1, 0, -1 } }
          row[#row + 1] = { spans = painted(line, runs, c, b, paints), font = "mono", size = SIZE.code, wrap = false, shrink = 0 }
        else
          row[#row + 1] = { spans = painted(line, runs, a, b, paints), font = "mono", size = SIZE.code, wrap = false, shrink = 0 }
        end
        -- A selection that runs on past the end of the line shows the newline.
        if eol and k == #rows then row[#row + 1] = { width = math.floor(cw * 0.7), height = LINE - 2, bg = sel_bg, shrink = 0 } end
        text_col[#text_col + 1] = row
      end
      local height = #rows * LINE
      -- The change bar: Git's view of this line, at the edge of the gutter,
      -- in a slot of BAR pixels on every line so the text starts in one place.
      local m = marks[i]
      local bar = { width = BAR, height = height, shrink = 0, direction = "row" }
      if m == "add" or m == "mod" then
        bar[1] = { width = 3, height = height, radius = 1, margin = { 0, 0, 0, 3 }, bg = m == "add" and C.bar_add or C.bar_mod,
          tooltip = m == "add" and "added since the last commit" or "changed since the last commit" }
      elseif marks.del and marks.del[i] then
        bar.tooltip = "lines removed above"
        bar[1] = canvas(7, LINE, function()
          return { bone.gui.draw.polyline({ points = { { 1, -3 }, { 7, 0 }, { 1, 3 } }, closed = true,
            color = C.bar_del, fill = C.bar_del, width = 1 }) }
        end)
      end
      local bg = (flash and flash[i]) and C.flash or (cur and not s1) and C.current or nil
      return { direction = "row", height = height, bg = bg, transition = 400, align = "start",
        { text = tostring(i), font = "mono", size = SIZE.small, width = gutter - 10, height = LINE, shrink = 0,
          text_align = "right", color = (not cur) and C.gutter or nil, hl = cur and "Normal" or nil, padding = { 0, 2, 0, 0 } },
        bar,
        text_col,
      }
    end },
  }
  local box = { direction = "column", grow = 1, list }
  if s.menu and s.menu.where == "editor" then box[#box + 1] = menu_card(s.menu, width, s.room_h) end
  return box
end

--- `rows` with each run of changed lines as removals, then additions.
local function removals_first(rows)
  local out, run = {}, nil
  local function flush()
    if not run then return end
    for _, r in ipairs(run.del) do out[#out + 1] = r end
    for _, r in ipairs(run.add) do out[#out + 1] = r end
    run = nil
  end
  for _, r in ipairs(rows or {}) do
    if r.sign == "+" or r.sign == "-" then
      run = run or { add = {}, del = {} }
      local into = r.sign == "+" and run.add or run.del
      into[#into + 1] = r
    else
      flush()
      out[#out + 1] = r
    end
  end
  flush()
  return out
end

local function diff_view(rows)
  rows = removals_first(rows)
  if not rows or #rows == 0 then
    return { padding = { 20, 16 }, { text = "No changes since the file was opened.", size = SIZE.small, color = C.dim } }
  end
  return {
    id = "files:diff", grow = 1, padding = { 6, 0 },
    list = { count = #rows, estimate = LINE, key = "files:diff", item = function(i)
      local r = rows[i]
      if r.separator then
        return { height = LINE, padding = { 0, 16 }, { text = "⋯", size = SIZE.small, color = C.faint } }
      end
      if not r.sign then
        return { height = LINE, padding = { 0, 16 }, { text = tostring(r.text or ""), size = SIZE.micro, color = C.faint, wrap = false } }
      end
      local bg = r.sign == "+" and C.add_bg or r.sign == "-" and C.del_bg or nil
      local mark = r.sign == "+" and C.good or r.sign == "-" and C.bad or C.faint
      local function num(n) return (tonumber(n) or 0) > 0 and tostring(n) or "" end
      return { direction = "row", align = "center", height = LINE, bg = bg, padding = { 0, 12 }, gap = 8,
        { text = num(r.old), font = "mono", size = SIZE.micro, color = C.faint, width = 30, text_align = "right", shrink = 0 },
        { text = num(r.new), font = "mono", size = SIZE.micro, color = C.faint, width = 30, text_align = "right", shrink = 0 },
        { text = r.sign == " " and "" or r.sign, font = "mono", size = SIZE.code, color = mark, width = 10, shrink = 0 },
        { text = (tostring(r.text or ""):gsub("\t", "    ")), font = "mono", size = SIZE.code, hl = "Normal",
          wrap = false, grow = 1, width = 0, overflow = "hidden" },
      }
    end },
  }
end

local function markdown_view(body)
  local ok, md = pcall(require, "bone.desktop.markdown")
  local node = { direction = "column", padding = { 14, 20 }, gap = 2 }
  if ok and md and md.nodes then
    for _, n in ipairs(md.nodes(body) or {}) do node[#node + 1] = n end
  else
    node[#node + 1] = { text = body, size = SIZE.text, selectable = true }
  end
  return { id = "files:md", grow = 1, overflow = "scroll", direction = "column", node }
end

local function banner(message, tone, buttons)
  local row = { direction = "row", align = "center", gap = 8, padding = { 7, 12 }, radius = 8, shrink = 0,
    bg = tone == "error" and C.bad_bg or C.warn_bg,
    { text = message, size = SIZE.small, color = tone == "error" and C.bad or C.warn, grow = 1, width = 0 },
  }
  for _, b in ipairs(buttons or {}) do
    row[#row + 1] = press({ text = b[1], size = SIZE.small, bold = true, hl = "Normal", padding = { 3, 10 },
      radius = 6, bg = C.soft, wrap = false, shrink = 0 }, b[2], b[1])
  end
  return row
end

--- The bar over an open file: its path, whether it is saved, its views.
--- The open files, as tabs over the file: the shown one raised, a dot for
--- unsaved work (a cross in its place under the pointer, and on the shown one).
local function tab_strip(s)
  if #s.docs < 2 then return nil end
  local row = { direction = "row", gap = 2, height = 30, shrink = 0, overflow = "scroll",
    scrollbar = { show = "hidden" }, padding = { 0, 2 } }
  for i, t in ipairs(s.docs) do
    local path = t.kind == "edit" and t.ed.path or t.path
    local name = path:match("[^/]+$") or path
    local on = i == s.doc_at
    local dirty = t.kind == "edit" and t.ed.dirty
    local close = { width = 16, height = 16, radius = 4, shrink = 0, direction = "row", align = "center", justify = "center",
      opacity = (on or dirty) and 1 or 0, hover = { bg = C.hover, opacity = 1 }, transition = 80,
      dirty and not on and { width = 7, height = 7, radius = 4, bg = C.dim } or cross(C.faint) }
    press(close, function() app.tab_close(i) end, "Close " .. name)
    close.hover = { bg = C.hover, opacity = 1 }
    local tab = { direction = "row", align = "center", gap = 6, height = 28, padding = { 0, 6, 0, 10 }, radius = 7,
      shrink = 0, bg = on and C.soft or nil, shadow = on and { blur = 3, dy = 1, color = "#00000035" } or nil,
      role = "option", selected = on, tooltip = s.relative(path),
      file_icon(name),
      { text = name, size = SIZE.small, bold = on, hl = on and "Normal" or nil, color = (not on) and C.dim or nil, wrap = false },
      dirty and on and { width = 7, height = 7, radius = 4, bg = C.dim, shrink = 0 } or nil,
      close }
    press(tab, function() app.tab_click(i) end, name)
    tab.on_middle = function() app.tab_close(i) end
    if on then tab.hover = { bg = C.soft } end
    row[#row + 1] = tab
  end
  return row
end

local function small_button(content, click, tip)
  local node = { direction = "row", align = "center", justify = "center", gap = 5, height = 24, padding = { 0, 8 },
    radius = 6, bg = C.chip, shrink = 0, tooltip = tip }
  for i, c in ipairs(content) do node[i] = c end
  return press(node, click, tip)
end

--- Zoom for a picture or a PDF: − 100% +, and Fit.
local function zoom_controls(p)
  local z = p.zoom
  local label
  if z == "width" then label = "Width"
  elseif type(z) == "number" then label = math.floor(z * (p.kind == "image" and 100 or 100) + 0.5) .. "%"
  else label = "Fit" end
  return { direction = "row", align = "center", gap = 2, padding = 2, radius = 8, bg = C.chip, shrink = 0,
    press({ width = 24, height = 22, radius = 6, direction = "row", align = "center", justify = "center", plus_minus(false) },
      function() app.act.zoom(-1) end, "Zoom out (−)"),
    press({ text = label, size = SIZE.micro, font = "mono", color = C.dim, width = 44, text_align = "center",
      height = 22, radius = 6, padding = { 4, 0 } },
      function() app.act.zoom_set(z == nil and (p.kind == "image" and 1 or "width") or nil) end,
      z == nil and "Actual size (1)" or "Fit (0)"),
    press({ width = 24, height = 22, radius = 6, direction = "row", align = "center", justify = "center", plus_minus(true) },
      function() app.act.zoom(1) end, "Zoom in (+)"),
  }
end

local function doc_bar(s)
  local editing = s.doc == "edit"
  local path = editing and s.editor.path or s.preview.path
  local rel = s.relative(path)
  local dir, leaf = rel:match("^(.*/)([^/]+)$")
  local row = { direction = "row", align = "center", gap = 7, height = 34, padding = { 0, 4, 0, 6 }, shrink = 0,
    file_icon(path:match("[^/]+$") or path),
    dir and { text = dir, size = SIZE.small, color = C.faint, wrap = false, text_overflow = "ellipsis", shrink = 1 } or nil,
    { text = leaf or rel, size = SIZE.text, bold = true, hl = "Normal", wrap = false, shrink = 0 },
  }
  if editing and s.editor.dirty then
    row[#row + 1] = { width = 7, height = 7, radius = 4, bg = C.dim, shrink = 0, tooltip = "unsaved changes · ctrl+s saves" }
  end
  local b = app.badges(path)
  if b.mark then row[#row + 1] = chip("edited", C.warn) end
  if b.sign then row[#row + 1] = chip(b.sign == "?" and "untracked" or ("git " .. b.sign), sign_color(b.sign)) end
  row[#row + 1] = { grow = 1 }
  if editing then
    local e = s.editor
    if e.saving then
      row[#row + 1] = { text = "Saving…", size = SIZE.micro, color = C.faint, wrap = false }
    elseif e.status then
      row[#row + 1] = { text = e.status, size = SIZE.micro, color = C.faint, wrap = false,
        text_overflow = "ellipsis", shrink = 1, max_width = 260 }
    end
    -- Where the caret is, once it has moved from the top.
    local selecting = e.anchor and not (e.anchor.line == e.line and e.anchor.col == e.col)
    if selecting or e.line ~= 1 or e.col ~= 0 then
      local where = "Ln " .. e.line .. ", Col " .. (e.col + 1)
      if selecting then
        local lines = math.abs(e.line - e.anchor.line) + 1
        where = where .. (lines > 1 and (" · " .. lines .. " lines") or " · selected")
      end
      row[#row + 1] = press({ text = where, size = SIZE.micro, color = C.faint, wrap = false, shrink = 0, font = "mono",
        padding = { 2, 5 }, radius = 5 }, function() app.act.go_open() end, "Go to line (ctrl+l)")
    end
    local wraps = e.wrap
    if wraps == nil then wraps = wraps_by_default(e.path) end
    local wrap_node = press({ text = "Wrap", size = SIZE.micro, color = wraps and C.accent or C.faint, wrap = false, shrink = 0,
      padding = { 3, 6 }, radius = 6,
      tooltip = wraps and "Long lines wrap (alt+z)" or "Long lines run on (alt+z)" },
      function() app.act.toggle_wrap() end, "Wrap long lines")
    wrap_node.hover = { bg = C.hover, color = wraps and C.accent or "Normal" }
    row[#row + 1] = wrap_node
    row[#row + 1] = icon_button(bubble(C.faint), "Name the file (or the selected lines) in the message (ctrl+k)",
      function() app.act.editor_to_chat() end)
    local names, modes = { "Edit", "Changes" }, { "buffer", "changes" }
    local lower_name = (leaf or rel):lower()
    local is_html = lower_name:match("%.html?$") or lower_name:match("%.xhtml$")
    if syntax.lang(leaf or rel) and syntax.lang(leaf or rel).markdown then
      names[3], modes[3] = "Split", "split"
      names[4], modes[4] = "Preview", "markdown"
    elseif is_html then
      names[3], modes[3] = "Split", "split"
      names[4], modes[4] = "Preview", "html"
      row[#row + 1] = small_button({ { text = "Open in browser", size = SIZE.micro, color = C.dim, wrap = false } },
        function() app.open_externally() end, "The page in the desktop's browser, with its styles and scripts")
    end
    local current = 1
    for i, m in ipairs(modes) do if e.shown == m then current = i end end
    -- Edit and Changes only when there is something to compare (or a page to read).
    if #names > 2 or b.sign or b.mark or e.dirty or current ~= 1 then
      row[#row + 1] = segmented(names, current, function(i) app.mode(modes[i]) end, { size = SIZE.micro, pad = 8 })
    end
  else
    local p = s.preview
    if (p.kind == "image" or p.kind == "gif") and p.width and p.height then
      row[#row + 1] = { text = ((p.name or ""):match("%.(%w+)$") or ""):upper() .. "  " .. p.width .. " × " .. p.height
        .. ((p.anim and #p.anim.frames > 1) and ("  ·  " .. #p.anim.frames .. " frames") or ""),
        size = SIZE.micro, color = C.faint, wrap = false, shrink = 0 }
    elseif p.kind == "video" and p.info then
      local i = p.info
      row[#row + 1] = { text = tostring(i.codec or ""):upper() .. "  " .. tostring(i.width) .. " × " .. tostring(i.height)
        .. "  ·  " .. clock(i.duration) .. (i.fps and string.format("  ·  %.0f fps", i.fps) or "") .. (i.audio and "  ·  sound" or ""),
        size = SIZE.micro, color = C.faint, wrap = false, shrink = 1, text_overflow = "ellipsis" }
    end
    local size = app.size_of(app.size_at(path))
    if size then row[#row + 1] = { text = size, size = SIZE.micro, color = C.faint, wrap = false } end
    local pages = p.kind == "pdf" and p.pdf_view ~= "text" and p.pages and #p.pages > 0
    if pages then
      local info = bone.gui.scroll_info and bone.gui.scroll_info("files:pages")
      local now = 1
      if info and p.page_h and p.page_h > 0 then now = math.max(1, math.min(#p.pages, math.floor((info.offset + p.page_h * 0.4) / p.page_h) + 1)) end
      p.page_shown = now
      row[#row + 1] = { direction = "row", align = "center", gap = 4, shrink = 0,
        { id = "files:page", width = 34, height = 22, radius = 5, bg = C.chip, border = 1, border_color = C.line,
          size = SIZE.micro, padding = { 0, 4 },
          text_input = { value = tostring(now), select = true,
            on_submit = function(t) app.pdf_page(tonumber(t)) end },
          on_key = function(k)
            if k == "esc" then app.give_keys() return true end
            if k == "enter" then app.pdf_page(tonumber(bone.gui.input_text("files:page") or "")) return true end
            return false
          end },
        { text = "of " .. #p.pages .. ((not p.pages_ended) and "+" or ""), size = SIZE.micro, color = C.faint, wrap = false } }
    end
    if p.kind == "image" or p.kind == "gif" or pages then row[#row + 1] = zoom_controls(p) end
    if p.kind == "pdf" and p.pages_state and p.pages_state ~= "failed" then
      local text_view = p.pdf_view == "text"
      row[#row + 1] = segmented({ "Pages", "Text" }, text_view and 2 or 1,
        function(i) app.pdf_view(i == 2 and "text" or "pages") end, { size = SIZE.micro, pad = 8 })
    end
    row[#row + 1] = small_button({ bubble(C.dim) }, function() app.act.to_chat(path) end, "Name this file in the message (ctrl+k)")
    row[#row + 1] = press({ text = "Open outside", size = SIZE.small, hl = "Normal", padding = { 3, 10 },
      radius = 6, bg = C.chip, wrap = false, shrink = 0 }, function() app.open_externally() end, "Open with the desktop's app")
  end
  return row
end

--- Find in the file: the field, how many, the one before and after.
local function find_bar(s)
  local f = s.editor.find
  local hits = app.find_hits() or {}
  local term = f.term or ""
  local count = term == "" and "" or (#hits == 0 and "No results" or ((f.at or 0) .. " of " .. #hits .. (#hits >= 20000 and "+" or "")))
  return { direction = "row", align = "center", gap = 6, height = 34, padding = { 0, 6, 0, 10 }, radius = 8, shrink = 0,
    bg = C.chip, border = 1, border_color = C.line,
    magnifier(C.dim),
    { id = "files:find", grow = 1, width = 0, size = SIZE.text,
      text_input = { value = term, placeholder = "Find in " .. (s.editor.path:match("[^/]+$") or "the file"), focus = true, select = true,
        on_change = function(t) app.act.find_typed(t) end,
        on_submit = function() app.act.find_step(1) end },
      on_key = function(k)
        if k == "esc" then app.act.find_close() app.give_keys() return true end
        if k == "enter" then app.act.find_step(1) return true end
        if k == "shift+enter" or k == "up" then app.act.find_step(-1) return true end
        if k == "down" then app.act.find_step(1) return true end
        return false
      end },
    { text = count, size = SIZE.micro, color = (#hits == 0 and term ~= "") and C.bad or C.faint, wrap = false, shrink = 0 },
    icon_button(arrow(true), "The one before (shift+enter)", function() app.act.find_step(-1) end),
    icon_button(arrow(false), "The next (enter)", function() app.act.find_step(1) end),
    icon_button(cross(C.faint), "Close (esc)", function() app.act.find_close() app.give_keys() end),
  }
end

local function goto_bar(s)
  return { direction = "row", align = "center", gap = 8, height = 34, padding = { 0, 6, 0, 12 }, radius = 8, shrink = 0,
    bg = C.chip, border = 1, border_color = C.accent,
    { text = "Go to line", size = SIZE.small, color = C.dim, wrap = false, shrink = 0 },
    { id = "files:goto", grow = 1, width = 0, size = SIZE.text,
      text_input = { value = "", placeholder = "1–" .. #s.editor.lines .. "   (line:column works too)", focus = true,
        on_submit = function(t) app.act.go_to(t) app.give_keys() end },
      on_key = function(k)
        if k == "esc" then app.act.go_to(nil) app.give_keys() return true end
        if k == "enter" then app.act.go_to(bone.gui.input_text("files:goto")) app.give_keys() return true end
        return false
      end },
    icon_button(cross(C.faint), "Close (esc)", function() app.act.go_to(nil) app.give_keys() end),
  }
end

--- A PDF's pages, drawn: each a sheet on the dark, as wide as the zoom says
--- (fitted: the column's width up to 760 pixels), drawn twenty at a time as
--- the list nears its end. Wider than the column, a drag (or shift and the
--- wheel) moves it sideways; a drag moves it up and down too.
local function pdf_pages(p, width)
  if p.pages_state == "rendering" then
    return { grow = 1, direction = "column", align = "center", justify = "center", gap = 8,
      { text = "Drawing the pages…", size = SIZE.small, color = C.dim } }
  end
  local pages = p.pages
  local avail = math.max(120, width - 24)
  local fit = math.max(120, math.min(width - 72, 760))
  local room
  if p.zoom == "width" then room = math.max(120, width - 40)
  elseif type(p.zoom) == "number" then room = math.max(120, math.min(4000, fit * p.zoom))
  else room = fit end
  p.fit_scale = 1
  local wide = room > avail
  local pan = wide and math.max(-(room - avail) / 2 - 20, math.min((room - avail) / 2 + 20, p.pdf_pan or 0)) or 0
  p.pdf_pan = pan
  local function fitted(pg)
    local w, h = tonumber(pg.width) or 0, tonumber(pg.height) or 0
    if w <= 0 or h <= 0 then return math.floor(room), math.floor(room * 1.294) end
    local k = room / w
    return math.floor(w * k), math.floor(h * k)
  end
  local _, first_h = fitted(pages[1])
  p.page_h = first_h + 16
  local more = not p.pages_ended
  local count = #pages + (more and 1 or 0)
  return {
    id = "files:pages", grow = 1, bg = C.chip, cursor = wide and "grab" or nil,
    -- The page field says which page is in view: drawn again when that changes.
    on_scroll = function(dy, mods)
      if wide and mods and mods.shift then
        p.pdf_pan = pan + (dy or 0) * 40
        pcall(bone.gui.invalidate, 0)
        return
      end
      bone.defer(20, function()
        local info = bone.gui.scroll_info and bone.gui.scroll_info("files:pages")
        if info and p.page_h and p.page_h > 0 then
          local now = math.floor((info.offset + p.page_h * 0.4) / p.page_h) + 1
          if now ~= p.page_shown then pcall(bone.gui.invalidate, 0) end
        end
      end)
    end,
    on_press = function() p.drag_last = nil end,
    on_drag = function(q)
      if not q then return end
      local last = p.drag_last
      p.drag_last = { q.x, q.y }
      if not last then return end
      local dx, dy = q.x - last[1], q.y - last[2]
      if wide and dx ~= 0 then p.pdf_pan = (p.pdf_pan or 0) + dx end
      if dy ~= 0 then
        local info = bone.gui.scroll_info and bone.gui.scroll_info("files:pages")
        if info then pcall(bone.gui.scroll, "files:pages", math.max(0, math.min(info.max or 0, info.offset - dy))) end
      end
      pcall(bone.gui.invalidate, 0)
    end,
    list = { count = count, estimate = first_h + 16, key = "files:pages:" .. tostring(p.path) .. ":" .. tostring(p.zoom),
      item = function(i)
        -- Near the end of what is drawn: the next twenty.
        if more and i >= #pages - 2 then bone.defer(0, function() app.act.more_pages() end) end
        local pg = pages[i]
        if not pg then
          return { direction = "row", justify = "center", padding = { 10, 0, 24, 0 },
            { text = p.pages_more and ("Drawing pages " .. (#pages + 1) .. "–" .. (#pages + 20) .. "…") or "More pages…",
              size = SIZE.small, color = C.dim } }
        end
        local w, h = fitted(pg)
        local sheet = { role = "image", label = "page " .. i, width = w, height = h, radius = 3, overflow = "hidden",
          shrink = 0, bg = "#ffffff", shadow = { blur = 10, dy = 3, color = "#00000060" },
          image = { path = pg.path, fit = "contain", width = pg.width, height = pg.height } }
        sheet.on_double_click = function() app.act.zoom_set(p.zoom == nil and "width" or nil) end
        local row = { direction = "row", justify = wide and "start" or "center", overflow = "hidden",
          padding = { i == 1 and 16 or 0, 0, 16, 0 }, sheet }
        if wide then sheet.margin = { 0, 0, 0, math.floor((avail - w) / 2 + pan) } end
        return row
      end },
  }
end

--- A picture, fitted or zoomed, on a checkerboard where it is see-through.
--- Drag pans it; ctrl and the wheel zoom; a double click is fit or actual size.
local function picture(p, width, height, anim)
  local W, H = math.max(80, math.floor(width - 2)), math.max(80, math.floor(height))
  local w, h = tonumber(p.width) or 0, tonumber(p.height) or 0
  if w <= 0 or h <= 0 then
    local node = { role = "image", label = p.name, radius = 8, width = math.floor(W * 0.8), aspect_ratio = 1,
      image = { path = p.path, fit = "contain" } }
    return { grow = 1, direction = "column", align = "center", justify = "center", node }
  end
  local fit = math.min(1, (W - 32) / w, (H - 32) / h)
  p.fit_scale = fit
  local k = type(p.zoom) == "number" and p.zoom or fit
  local iw, ih = w * k, h * k
  local pan = p.pan or { 0, 0 }
  -- Pan no further than keeps the picture on screen.
  local mx, my = math.max(0, (iw - W) / 2 + 24), math.max(0, (ih - H) / 2 + 24)
  pan[1], pan[2] = math.max(-mx, math.min(mx, pan[1])), math.max(-my, math.min(my, pan[2]))
  p.pan = pan
  local x, y = (W - iw) / 2 + pan[1], (H - ih) / 2 + pan[2]
  local alpha = p.alpha or anim ~= nil
  local check_a, check_b = tint("10"), tint("1c")
  -- A moving picture is drawn again each frame; its time starts at the
  -- first frame drawn after it was set going.
  local playing = anim and anim.playing and #anim.frames > 1 and not anim.decoding
  local node = { width = W, height = H, shrink = 0, role = "image", label = p.name, overflow = "hidden",
    cursor = (iw > W or ih > H) and "grab" or "zoom-in",
    canvas = { fps = playing and 30 or 0, draw = function(ctx)
      local path = p.path
      if anim and #anim.frames > 0 then
        local i = anim.shown or 1
        if playing then
          local now = (ctx and ctx.time or 0) * 1000
          if not anim.t0 then anim.t0 = now - (anim.at_ms or 0) end
          anim.at_ms = now - anim.t0
          i = media.frame_at(anim, anim.at_ms) or 1
          anim.shown = i
        end
        path = anim.frames[math.min(i, #anim.frames)].path
      end
      local d = bone.gui.draw
      local out = {}
      if alpha then
        local x0, y0 = math.max(0, x), math.max(0, y)
        local x1, y1 = math.min(W, x + iw), math.min(H, y + ih)
        out[#out + 1] = d.rect({ x = x0, y = y0, w = x1 - x0, h = y1 - y0, fill = check_a })
        local sq = 10
        local gx = math.floor((x0 - x) / sq)
        local gy = math.floor((y0 - y) / sq)
        local n = 0
        for row = gy, math.ceil((y1 - y) / sq) do
          for col = gx, math.ceil((x1 - x) / sq) do
            if (row + col) % 2 == 0 then
              local rx, ry = x + col * sq, y + row * sq
              local cx0, cy0 = math.max(rx, x0), math.max(ry, y0)
              local cx1, cy1 = math.min(rx + sq, x1), math.min(ry + sq, y1)
              if cx1 > cx0 and cy1 > cy0 then
                out[#out + 1] = d.rect({ x = cx0, y = cy0, w = cx1 - cx0, h = cy1 - cy0, fill = check_b })
                n = n + 1
                if n > 9000 then break end
              end
            end
          end
          if n > 9000 then break end
        end
      end
      out[#out + 1] = d.image({ x = x, y = y, w = iw, h = ih, path = path })
      return out
    end } }
  node.on_press = function() p.drag_last = nil end
  node.on_drag = function(q)
    if not q then return end
    if p.drag_last and (iw > W or ih > H) then
      pan[1] = pan[1] + (q.x - p.drag_last[1])
      pan[2] = pan[2] + (q.y - p.drag_last[2])
      p.pan = pan
      pcall(bone.gui.invalidate, 0)
    end
    p.drag_last = { q.x, q.y }
  end
  node.on_scroll = function(dy, mods)
    if mods and (mods.ctrl or mods.super) then
      app.act.zoom(dy > 0 and 1 or -1)
    elseif iw > W or ih > H then
      pan[2] = pan[2] + (dy or 0) * 40
      pan[1] = pan[1] + ((mods and mods.dx) or 0) * 40
      p.pan = pan
      pcall(bone.gui.invalidate, 0)
    end
  end
  node.on_double_click = function() if type(p.zoom) == "number" then app.act.zoom_set(nil) else app.act.zoom_set(1) end end
  return { grow = 1, direction = "column", align = "center", justify = "center", node }
end



-- ---- an HTML page ------------------------------------------------------------------

local HTML_WIDTH = 720 -- the reading column
local BODY = 15        -- the body text's size
local html_memo = { key = nil, doc = nil, web = {}, allow = {}, toc = {} }

--- The page read once per version of its text.
local function html_doc(body, key)
  if html_memo.key == key then return html_memo.doc end
  local doc = require("files.html").parse(body)
  html_memo.key, html_memo.doc = key, doc
  return doc
end

local function is_remote(src)
  return tostring(src or ""):match("^https?://") ~= nil or tostring(src or ""):match("^//") ~= nil
end

local function web_file(url)
  local P = require("files.platform")
  return P.cache("web", (bone.sha256(url) or tostring(#url)):sub(1, 24))
end

--- A picture's file, from a page's `src`: beside the page, absolute, a
--- file:// URL, a data: URL written to the cache, or one from the web once
--- fetched (when the page was let to). nil when there is none yet.
local function picture_file(src, base, page)
  src = tostring(src or "")
  if src == "" then return nil end
  local mime, b64 = src:match("^data:image/(%w+);base64,(.+)$")
  if mime then
    local P = require("files.platform")
    local dir = P.cache("html")
    local name = (bone.sha256(b64) or tostring(#b64)):sub(1, 24) .. "." .. (mime == "jpeg" and "jpg" or mime)
    local path = dir .. "/" .. name
    local f = io.open(path, "rb")
    if f then f:close() return path end
    pcall(bone.fs.mkdir, P.cache())
    pcall(bone.fs.mkdir, dir)
    local ok, data = pcall(function()
      local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
      local map = {}
      for i = 1, 64 do map[chars:sub(i, i)] = i - 1 end
      local out, acc, bits = {}, 0, 0
      for ch in b64:gsub("[^%w+/]", ""):gmatch(".") do
        acc = acc * 64 + map[ch]
        bits = bits + 6
        if bits >= 8 then
          bits = bits - 8
          out[#out + 1] = string.char(math.floor(acc / 2 ^ bits) % 256)
          acc = acc % 2 ^ bits
        end
      end
      return table.concat(out)
    end)
    if not ok then return nil end
    local w = io.open(path, "wb")
    if not w then return nil end
    w:write(data)
    w:close()
    return path
  end
  if is_remote(src) then
    if not (page and html_memo.allow[page]) then return nil end
    return html_memo.web[src]
  end
  if src:match("^%a[%w+.-]*:") and not src:match("^file:") then return nil end
  local path = src:gsub("^file://", ""):gsub("[?#].*$", ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  local P = require("files.platform")
  if P.windows then path = path:gsub("^/(%a:[/\\])", "%1") end
  if not P.is_absolute(path) then path = P.resolve(path, base) end
  return path
end

local function drawable(path)
  if not path then return false end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  if not (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp") then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

--- Every picture on the page that is on the web.
local function remote_pictures(doc)
  local out, seen = {}, {}
  local function add(src) if is_remote(src) and not seen[src] then seen[src] = true out[#out + 1] = src end end
  local function walk(blocks)
    for _, b in ipairs(blocks or {}) do
      if b.kind == "image" then add(b.src) end
      for _, sp in ipairs(b.spans or {}) do if sp.image then add(sp.image.src) end end
      if b.blocks then walk(b.blocks) end
      for _, it in ipairs(b.items or {}) do walk(it.blocks) end
      for _, r in ipairs(b.rows or {}) do for _, c in ipairs(r.cells) do
        for _, sp in ipairs(c.spans or {}) do if sp.image then add(sp.image.src) end end end end
    end
  end
  walk(doc.blocks)
  return out
end

--- Fetch the page's pictures from the web (it asked), into the cache.
local function fetch_pictures(page, list)
  html_memo.allow[page] = true
  html_memo.fetching = (html_memo.fetching or 0) + #list
  pcall(bone.gui.invalidate, 0)
  local P = require("files.platform")
  pcall(bone.fs.mkdir, P.cache())
  pcall(bone.fs.mkdir, P.cache("web"))
  for _, url in ipairs(list) do
    local full = url:match("^//") and ("https:" .. url) or url
    local file = web_file(url)
    local function landed()
      -- The kind from the bytes, so the window can draw it.
      local f = io.open(file, "rb")
      local head = f and f:read(16) or ""
      if f then f:close() end
      local ext = head:sub(1, 8) == "\137PNG\r\n\26\n" and "png" or head:sub(1, 2) == "\255\216" and "jpg"
        or (head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP") and "webp" or nil
      if ext then
        local named = file .. "." .. ext
        os.rename(file, named)
        html_memo.web[url] = named
      end
    end
    local held
    for _, ext in ipairs({ "png", "jpg", "webp" }) do
      local f = io.open(file .. "." .. ext, "rb")
      if f then f:close() held = file .. "." .. ext break end
    end
    if held then
      html_memo.web[url] = held
      html_memo.fetching = html_memo.fetching - 1
    else
      bone.job.start("curl -sSfL --max-time 20 --max-filesize 20000000 -A 'bone-files' -o " .. P.quoted(file) .. " " .. P.quoted(full),
        { name = "files: page picture", timeout = 25000, buffer = true, on_exit = function(r)
          if r and r.code == 0 then landed() end
          html_memo.fetching = math.max(0, (html_memo.fetching or 1) - 1)
          pcall(bone.gui.invalidate, 0)
        end })
    end
  end
  pcall(bone.gui.invalidate, 0)
end

local CODE_EXT = { lua = "lua", javascript = "js", js = "js", typescript = "ts", ts = "ts", tsx = "tsx", jsx = "jsx",
  python = "py", py = "py", rust = "rs", rs = "rs", go = "go", c = "c", cpp = "cpp", ["c++"] = "cpp", java = "java",
  kotlin = "kt", swift = "swift", ruby = "rb", rb = "rb", php = "php", sh = "sh", bash = "sh", shell = "sh", zsh = "sh",
  console = "sh", html = "html", xml = "xml", css = "css", json = "json", yaml = "yaml", yml = "yaml", toml = "toml",
  sql = "sql", markdown = "md", md = "md", csharp = "cs", cs = "cs", scala = "scala", perl = "pl" }

local function html_spans(spans, base_hl)
  local out = {}
  for _, sp in ipairs(spans or {}) do
    if not sp.image then
      local node = { text = sp.text, hl = base_hl, bold = sp.bold or nil, italic = sp.italic or nil,
        strike = sp.strike or nil }
      if sp.code then
        node.bg = sp.kbd and C.soft or C.chip
        node.hl = "Normal"
        node.text = "\194\160" .. sp.text .. "\194\160"
        if sp.kbd then node.bold = true end
      end
      if sp.mark then node.bg = C.find_bg end
      if sp.link then node.color = C.accent node.link = true node.hl = nil end
      if sp.underline then node.link = true end
      out[#out + 1] = node
    end
  end
  return out
end

--- A paragraph. Plain prose is one text that wraps and can be selected; one
--- with links or small pictures in it is laid word by word, so a link takes
--- its own press and a picture sits in the line.
local function html_para(spans, o)
  local flow = false
  for _, sp in ipairs(spans) do if sp.link or sp.image or sp.small then flow = true break end end
  local size = o.size or BODY
  local lh = math.floor(size * 1.6)
  if not flow then
    return { spans = html_spans(spans, o.hl or "Normal"), size = size, bold = o.bold, line_height = lh,
      selectable = true, color = o.color, text_align = o.align }
  end
  local row = { direction = "row", flex_wrap = true, align = "center", row_gap = math.floor(size * 0.45),
    justify = o.align == "center" and "center" or nil }
  for _, sp in ipairs(spans) do
    if sp.image then
      local im = sp.image
      local path = picture_file(im.src, o.base, o.page)
      if drawable(path) then
        local iw, ih = require("files.image").size(path)
        iw, ih = iw or im.width or 20, ih or im.height or 20
        local h = math.min(im.height or math.floor(size * 1.3), 64)
        local w = math.floor(h * iw / math.max(ih, 1))
        if im.width and not im.height then w = im.width h = math.floor(w * ih / math.max(iw, 1)) end
        row[#row + 1] = { width = w, height = h, shrink = 0, radius = 3, overflow = "hidden", margin = { 0, 4, 0, 0 },
          role = "image", label = im.alt or "picture", tooltip = im.alt, image = { path = path, fit = "contain", width = iw, height = ih } }
      else
        row[#row + 1] = { text = "[" .. (im.alt or "picture") .. "]", size = size * 0.85, color = C.faint, wrap = false,
          margin = { 0, 4, 0, 0 } }
      end
    else
      -- A space that starts this run belongs after the word before it.
      if sp.text:match("^%s") and #row > 0 then
        local prev = row[#row].spans
        local last = prev and prev[#prev]
        if last and not last.text:match("%s$") then last.text = last.text .. " " end
      end
      for piece in sp.text:gmatch("%S+%s*") do
        local one = html_spans({ { text = piece, bold = sp.bold, italic = sp.italic, code = sp.code, link = sp.link,
          strike = sp.strike, mark = sp.mark, underline = sp.underline, kbd = sp.kbd } }, o.hl or "Normal")
        local node = { spans = one, size = sp.small and math.floor(size * 0.8) or size, bold = o.bold, wrap = false,
          color = o.color }
        if sp.link then
          local href = sp.link
          press(node, function() app.act.open_link(href, o.base) end, href)
          node.tooltip = href
          node.hover = { opacity = 0.72 }
        end
        row[#row + 1] = node
      end
    end
  end
  return row
end

local html_blocks -- below: lists and quotes hold blocks of their own

--- A column's cells right-aligned: when most of them are numbers.
local function numeric_columns(rows, cols)
  local out = {}
  for c = 1, cols do
    local n, nums = 0, 0
    for _, r in ipairs(rows) do
      local cell = r.cells[c]
      if cell and not cell.head then
        local t = ""
        for _, sp in ipairs(cell.spans) do t = t .. (sp.text or "") end
        t = t:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then
          n = n + 1
          if t:match("^[%$€£¥%-+]?[%d][%d,. ]*%%?[kKmMbB]?$") then nums = nums + 1 end
        end
      end
    end
    out[c] = n > 0 and nums / n >= 0.6
  end
  return out
end

local function html_block(b, o)
  local base, width = o.base, o.width
  if b.kind == "heading" then
    local size = ({ 28, 22, 18, 16, 15, 14 })[b.level] or 14
    local node = html_para(b.spans, { size = size, bold = true, hl = "Normal", base = base, page = o.page })
    return { direction = "column", padding = { b.level <= 2 and 20 or 14, 0, 4, 0 }, node,
      b.level <= 2 and { height = 1, bg = C.line, margin = { 10, 0, 2, 0 } } or nil }
  elseif b.kind == "para" then
    if b.caption then
      return { direction = "column", padding = { 0, 0, 10, 0 },
        html_para(b.spans, { base = base, page = o.page, size = 12.5, color = C.faint, align = "center" }) }
    end
    return { direction = "column", padding = { o.tight and 2 or 6, 0, o.tight and 2 or 6, 0 },
      html_para(b.spans, { base = base, page = o.page, color = o.color }) }
  elseif b.kind == "list" then
    local col = { direction = "column", gap = 2, padding = { 4, 0, 6, 0 } }
    for i, item in ipairs(b.items) do
      local mark = b.ordered and ((b.start + i - 1) .. ".") or ((o.depth or 0) % 2 == 0 and "•" or "◦")
      local inner = html_blocks(item.blocks, { base = base, page = o.page, width = width - 28, depth = (o.depth or 0) + 1, tight = true })
      local content = { direction = "column", grow = 1, width = 0 }
      for _, n in ipairs(inner) do content[#content + 1] = n end
      col[#col + 1] = { direction = "row", align = "start",
        { text = mark, size = BODY, color = b.ordered and C.dim or C.faint, width = 28, text_align = b.ordered and "right" or "center",
          shrink = 0, padding = { 2, b.ordered and 8 or 0, 0, 0 }, line_height = math.floor(BODY * 1.6) },
        content }
    end
    return col
  elseif b.kind == "quote" then
    local inner = html_blocks(b.blocks, { base = base, page = o.page, width = width - 24, color = (not b.plain) and C.dim or nil,
      depth = o.depth, tight = true })
    local content = { direction = "column", grow = 1, width = 0 }
    for _, n in ipairs(inner) do content[#content + 1] = n end
    if b.plain then
      return { direction = "row", padding = { 0, 0, 4, 22 }, content }
    end
    return { direction = "row", margin = { 8, 0, 8, 0 }, padding = { 6, 14, 6, 0 }, radius = { 0, 8, 8, 0 }, bg = tint("05"),
      { width = 3, radius = 2, bg = C.accent, opacity = 0.7, shrink = 0, margin = { 0, 14, 0, 0 } }, content }
  elseif b.kind == "code" then
    local lang = b.lang and b.lang:lower()
    local L = syntax.lang("x." .. (CODE_EXT[lang or ""] or lang or "txt"))
    local lines = text.split(b.text)
    local body = { direction = "column", padding = { 10, 14, 12, 14 } }
    for _, line in ipairs(lines) do
      body[#body + 1] = { spans = spans(line, syntax.runs(line, L), 0, #line), font = "mono", size = 12.5, wrap = false,
        hl = "Normal", line_height = 19 }
    end
    local copied = b.copied and os.time() - b.copied < 3
    local bar = { direction = "row", align = "center", height = 28, padding = { 0, 6, 0, 12 }, border = { 0, 0, 1, 0 },
      border_color = C.line,
      { text = lang or "code", size = 11, color = C.faint, wrap = false },
      { grow = 1 },
      press({ text = copied and "Copied" or "Copy", size = 11, color = copied and C.good or C.dim, padding = { 2, 8 }, radius = 5,
        wrap = false }, function()
          require("files.clip").copy(b.text, function() end)
          b.copied = os.time()
          pcall(bone.gui.invalidate, 0)
          bone.defer(3100, function() pcall(bone.gui.invalidate, 0) end)
        end, "Copy the code") }
    return { direction = "column", margin = { 10, 0, 10, 0 }, radius = 9, bg = C.chip, border = 1, border_color = C.line,
      overflow = "hidden", bar, { direction = "row", overflow = "scroll", scrollbar = { show = "hover" }, body } }
  elseif b.kind == "rule" then
    return { height = 1, bg = C.line, margin = { 18, 0, 18, 0 } }
  elseif b.kind == "image" then
    local path = picture_file(b.src, base, o.page)
    if drawable(path) then
      local iw, ih = require("files.image").size(path)
      iw, ih = iw or b.width or 400, ih or b.height or 300
      -- The size the page asks for, else its own, never wider than the column.
      local want = b.width or iw
      local w = math.min(width, want)
      local h = math.floor(w * ih / math.max(iw, 1))
      local node = { width = w, height = h, radius = 8, overflow = "hidden", shrink = 0, role = "image",
        label = b.alt or "picture", image = { path = path, fit = "contain", width = iw, height = ih },
        tooltip = (b.title or b.alt or "") .. "  ·  opens it", shadow = { blur = 12, dy = 3, color = "#00000050" } }
      press(node, function() app.act.open_link(b.src, base) end, b.alt or "picture")
      node.hover = { opacity = 0.92 }
      local col = { direction = "column", align = "center", gap = 8, padding = { 12, 0, 12, 0 }, node }
      if b.alt and b.alt ~= "" and w >= 200 then col[#col + 1] = { text = b.alt, size = 12.5, color = C.faint, text_align = "center" } end
      return col
    end
    local label = b.alt and b.alt ~= "" and b.alt or (tostring(b.src or ""):match("[^/]+$") or "picture")
    local remote = is_remote(b.src)
    local box = { direction = "row", align = "center", gap = 8, padding = { 8, 12 }, radius = 7, bg = C.chip,
      border = 1, border_color = C.line, align_self = "start", margin = { 6, 0, 6, 0 },
      { text = "▢", size = 14, color = C.faint },
      { text = label, size = 13, color = C.dim, wrap = false, text_overflow = "ellipsis", shrink = 1 },
      { text = remote and "on the web" or "not drawn here", size = 11, color = C.faint, wrap = false } }
    if b.src then press(box, function() app.act.open_link(b.src, base) end, tostring(b.src)) end
    return box
  elseif b.kind == "embed" then
    local src = tostring(b.src or "")
    local name = src:match("[^/?#]+") and (src:match("([^/]+)[?#]?[^/]*$") or src) or b.tag
    local what = ({ video = "Video", audio = "Sound", iframe = "Embedded page", embed = "Embedded", object = "Embedded" })[b.tag] or "Embedded"
    local local_file = src ~= "" and not src:match("^%a[%w+.-]*:") and not src:match("^//")
    local action = (b.tag == "video" or b.tag == "audio") and local_file and "Open it in the panel" or "Open it in the browser"
    local box = { direction = "row", align = "center", gap = 12, padding = { 12, 14 }, radius = 9, bg = C.chip,
      border = 1, border_color = C.line, margin = { 10, 0, 10, 0 },
      { width = 34, height = 34, radius = 17, bg = C.soft, shrink = 0, direction = "row", align = "center", justify = "center",
        canvas(14, 14, function()
          local d = bone.gui.draw
          return { d.polyline({ points = { { 4, 2.5 }, { 12, 7 }, { 4, 11.5 } }, closed = true, fill = C.dim, color = C.dim, width = 1 }) }
        end) },
      { direction = "column", grow = 1, width = 0, gap = 2,
        { text = b.title or what, size = 13.5, bold = true, hl = "Normal", wrap = false, text_overflow = "ellipsis" },
        { text = (src ~= "" and (name .. "  ·  ") or "") .. action, size = 11.5, color = C.faint, wrap = false, text_overflow = "ellipsis" } } }
    if src ~= "" then press(box, function() app.act.open_link(src, base) end, action) end
    return box
  elseif b.kind == "table" then
    local cols = 0
    for _, r in ipairs(b.rows) do cols = math.max(cols, #r.cells) end
    -- Each column as wide as its longest cell asks, within reason; a column
    -- of numbers to the right.
    local weight = {}
    for c = 1, cols do weight[c] = 4 end
    for _, r in ipairs(b.rows) do
      for c, cell in ipairs(r.cells) do
        local n = 0
        for _, sp in ipairs(cell.spans) do n = n + #(sp.text or "") end
        weight[c] = math.max(weight[c], math.min(n, 40))
      end
    end
    local numeric = numeric_columns(b.rows, cols)
    local tbl = { direction = "column", radius = 9, border = 1, border_color = C.line, overflow = "hidden" }
    local body_row = 0
    for _, r in ipairs(b.rows) do
      local head = r.cells[1] and r.cells[1].head
      if not head then body_row = body_row + 1 end
      local row = { direction = "row", bg = head and C.soft or (body_row % 2 == 0 and tint("04") or nil),
        border = { 0, 0, 1, 0 }, border_color = head and C.line or tint("08") }
      for c = 1, cols do
        local cell = r.cells[c]
        local align = cell and cell.align
        align = (align == "right" or align == "center") and align or (numeric[c] and not head and "right" or nil)
        row[#row + 1] = { direction = "column", grow = weight[c], width = 0, padding = { 8, 12 },
          cell and { spans = html_spans(cell.spans, "Normal"), size = 13.5, bold = head or nil, selectable = true,
            text_align = align, color = head and C.dim or nil } or nil }
      end
      tbl[#tbl + 1] = row
    end
    local out = { direction = "column", margin = { 10, 0, 10, 0 }, gap = 6 }
    out[#out + 1] = tbl
    if b.caption and b.caption ~= "" then out[#out + 1] = { text = b.caption, size = 12.5, color = C.faint, text_align = "center" } end
    return out
  end
  return nil
end

html_blocks = function(blocks, o)
  local out = {}
  for _, b in ipairs(blocks) do
    local n = html_block(b, o)
    if n then out[#out + 1] = n end
  end
  return out
end

local function plain(spans)
  local t = {}
  for _, sp in ipairs(spans or {}) do t[#t + 1] = sp.text or "" end
  return (table.concat(t):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

--- An HTML page drawn: its blocks in a column the width of a page, each
--- block an entry of a list (so a link to #somewhere, or the contents, can go
--- there). `page` names the page (it keeps its place while you type),
--- `version` its text.
local function html_view(body, page, version, base, width)
  local doc = html_doc(body, page .. ":" .. tostring(version))
  local col_w = math.max(240, math.min(HTML_WIDTH, width - 64))
  local items = {}
  local first_heading
  for _, b in ipairs(doc.blocks) do
    if b.kind == "heading" then first_heading = plain(b.spans) break end
  end
  -- The page's title, over it, unless the first heading says the same.
  if doc.title and doc.title ~= "" and doc.title ~= first_heading then items[#items + 1] = { page_title = doc.title } end
  local remote = remote_pictures(doc)
  if #remote > 0 and not html_memo.allow[page] then items[#items + 1] = { web = remote } end
  for _, b in ipairs(doc.blocks) do items[#items + 1] = b end
  html_memo.ids = {}
  local headings = {}
  for i, b in ipairs(items) do
    if b.id then html_memo.ids[b.id] = i end
    if b.kind == "heading" and b.level <= 3 then headings[#headings + 1] = { i = i, level = b.level, text = plain(b.spans) } end
  end
  html_memo.base = base
  -- Another page starts at its top (the list is the same one for every page).
  if html_memo.shown_page ~= page then
    html_memo.shown_page = page
    bone.defer(0, function() pcall(bone.gui.scroll, "files:html", "top") end)
  end
  if #items == 0 then
    return { padding = { 20, 16 }, { text = "Nothing on this page to show.", size = SIZE.small, color = C.dim } }
  end
  local list = {
    id = "files:html", grow = 1,
    -- The page's own name, not its version: typing keeps the place.
    list = { count = #items, estimate = 60, key = "files:html:" .. page, item = function(i)
      local b = items[i]
      local inner
      if b.page_title then
        inner = { text = b.page_title, size = 12, color = C.faint, padding = { 26, 0, 0, 0 }, wrap = false, text_overflow = "ellipsis" }
      elseif b.web then
        local fetching = (html_memo.fetching or 0) > 0
        inner = { direction = "row", align = "center", gap = 10, padding = { 8, 12 }, radius = 8, bg = C.chip, margin = { 18, 0, 0, 0 },
          border = 1, border_color = C.line,
          { text = #b.web .. (#b.web == 1 and " picture on this page is" or " pictures on this page are") .. " on the web.",
            size = 12.5, color = C.dim, grow = 1, width = 0 },
          press({ text = fetching and "Fetching…" or "Show them", size = 12, bold = true, color = C.on_accent, bg = C.accent,
            padding = { 4, 12 }, radius = 6, wrap = false, hover = { opacity = 0.9 } },
            function() fetch_pictures(page, b.web) end, "Fetch them from the web, this page only") }
      else
        inner = html_block(b, { base = base, page = page, width = col_w })
      end
      return { direction = "row", justify = "center", padding = { i == 1 and 6 or 0, 32, i == #items and 48 or 0, 32 },
        { direction = "column", width = col_w, shrink = 1, inner } }
    end },
  }
  local box = { direction = "column", grow = 1, list }
  -- The contents of a page with headings enough: a button, and the list of them.
  if #headings >= 3 then
    local open = html_memo.toc[page]
    box[#box + 1] = { position = "absolute", top = 10, right = 14, z = 8,
      press({ direction = "row", align = "center", gap = 6, padding = { 4, 10 }, radius = 7, bg = open and C.selected or C.card,
        border = 1, border_color = C.line, shadow = { blur = 8, dy = 2, color = "#00000040" },
        { text = "≡", size = 14, color = open and C.accent or C.dim },
        { text = "Contents", size = 12, color = open and C.accent or C.dim, wrap = false } },
        function() html_memo.toc[page] = not open pcall(bone.gui.invalidate, 0) end, "The headings of the page") }
    if open then
      -- As tall as its headings (thirty at most): a box that scrolls needs a
      -- height of its own, and this one has none to give.
      local card = { position = "absolute", top = 44, right = 14, z = 9, width = 280,
        direction = "column", padding = 6, radius = 10, bg = C.card, border = 1, border_color = C.line,
        shadow = { { blur = 24, dy = 8, color = "#00000066" } } }
      for n, h in ipairs(headings) do
        if n > 30 then break end
        local row = { direction = "row", align = "center", height = 28, padding = { 0, 10, 0, 10 + (h.level - 1) * 14 }, radius = 6,
          { text = h.text, size = h.level == 1 and 13 or 12.5, bold = h.level == 1 or nil, hl = "Normal", wrap = false,
            text_overflow = "ellipsis", grow = 1, width = 0, color = h.level > 2 and C.dim or nil } }
        press(row, function()
          -- Again once the rows on the way have been measured: the first goes
          -- by their estimated heights.
          pcall(bone.gui.scroll_item, "files:html", h.i, "top")
          bone.defer(80, function() pcall(bone.gui.scroll_item, "files:html", h.i, "top") end)
          bone.defer(240, function() pcall(bone.gui.scroll_item, "files:html", h.i, "top") end)
          html_memo.toc[page] = false
          pcall(bone.gui.invalidate, 0)
        end, h.text)
        card[#card + 1] = row
      end
      box[#box + 1] = card
    end
  end
  return box
end

--- Where a link on the page goes, for ui.lua (an anchor here: the entry).
function M.html_anchor(id) return html_memo.ids and html_memo.ids[id] end

-- ---- GIFs, videos, models ---------------------------------------------------------


local function play_glyph(playing, color)
  return canvas(14, 14, function()
    local d = bone.gui.draw
    local c = color or C.dim
    if playing then
      return { d.rect({ x = 3, y = 2.5, w = 3, h = 9, radius = 1, fill = c }), d.rect({ x = 8.5, y = 2.5, w = 3, h = 9, radius = 1, fill = c }) }
    end
    return { d.polyline({ points = { { 4, 2.5 }, { 12, 7 }, { 4, 11.5 } }, closed = true, fill = c, color = c, width = 1 }) }
  end)
end

local function gif_view(p, width, height)
  local a = p.anim
  if not a then return { padding = { 20, 16 }, { text = "Reading the GIF…", size = SIZE.small, color = C.dim } } end
  if #a.frames == 0 then
    return { grow = 1, direction = "column", align = "center", justify = "center",
      { text = "Reading the GIF…", size = SIZE.small, color = C.dim } }
  end
  local col = { direction = "column", grow = 1 }
  col[#col + 1] = picture(p, width, height - 44, a)
  col[#col + 1] = { direction = "row", align = "center", gap = 10, height = 40, padding = { 0, 14 }, shrink = 0,
    press({ width = 28, height = 28, radius = 14, direction = "row", align = "center", justify = "center", bg = C.chip,
      play_glyph(a.playing, C.dim) }, function()
      if a.playing then a.playing = false else a.playing, a.t0 = true, nil end
      pcall(bone.gui.invalidate, 0)
    end, a.playing and "Pause (space)" or "Play (space)"),
    { text = (a.decoding and ("Reading… " .. #a.frames .. " frames") or (#a.frames .. " frames · " .. string.format("%.1f s", a.total / 1000))),
      size = SIZE.micro, color = C.faint, wrap = false },
    { grow = 1 },
    { text = "space plays · + − zoom", size = SIZE.micro, color = C.faint, wrap = false },
  }
  return col
end

--- What there is to do without ffmpeg: install it, fetch it, or open the
--- video in the desktop's player.
local function need_ffmpeg(p)
  local col = { direction = "column", gap = 12, padding = { 22, 24 }, align = "start", width = "100%" }
  col[#col + 1] = { text = "Videos need ffmpeg", size = 16, bold = true, hl = "Normal" }
  col[#col + 1] = { text = "The panel reads a video with ffmpeg: its length and size, a picture from it, a row of them along it, and a short silent preview to play. It is not on this computer yet.",
    size = SIZE.small, color = C.dim }
  local buttons = { direction = "row", gap = 8, flex_wrap = true, row_gap = 8 }
  local function button(label, run, primary, tip)
    return press({ text = label, size = SIZE.small, bold = primary, color = primary and C.on_accent or nil,
      hl = (not primary) and "Normal" or nil, padding = { 6, 14 }, radius = 7, bg = primary and C.accent or C.chip,
      hover = primary and { opacity = 0.9 } or nil, tooltip = tip, wrap = false }, run, label)
  end
  if p.install then
    buttons[#buttons + 1] = button("Install", function() media.install(p) end, true, "Runs " .. p.install .. " in a terminal")
  end
  local f = p.fetch
  if not f or f.state == "failed" then
    buttons[#buttons + 1] = button("Download it for the panel", function() media.offer_fetch(p) end, not p.install,
      "A build of ffmpeg for this system, kept with the plugin; nothing else on the computer changes")
  end
  buttons[#buttons + 1] = button("Open in player", function() media.open_player(p.path) end, false, "The desktop's own player, with sound")
  col[#col + 1] = buttons
  if p.install then
    col[#col + 1] = { direction = "row", gap = 6, align = "center",
      { text = p.install, font = "mono", size = SIZE.micro, color = C.dim, bg = C.chip, radius = 5, padding = { 3, 8 } },
      { text = p.installing and "running in a terminal — then" or "in a terminal", size = SIZE.micro, color = C.faint } ,
      p.installing and press({ text = "Check again", size = SIZE.micro, color = C.accent, padding = { 3, 8 }, radius = 5 },
        function() media.check_again(p) end, "Look for ffmpeg again") or nil }
  end
  if p.check_note then col[#col + 1] = { text = p.check_note, size = SIZE.micro, color = C.warn } end
  if f and f.state == "asking" then
    col[#col + 1] = { text = "Asking which build to get…", size = SIZE.small, color = C.dim }
  elseif f and f.state == "offered" then
    local plan = f.plan
    local mb = math.floor((plan.size or 0) / 1048576 + 0.5)
    col[#col + 1] = { direction = "column", gap = 8, padding = { 12, 14 }, radius = 9, bg = C.chip, border = 1, border_color = C.line,
      { text = "Download " .. mb .. " MB from " .. tostring(plan.from) .. "?", size = SIZE.small, bold = true, hl = "Normal" },
      { text = "It is checked against its SHA-256 and kept in " .. require("files.ffmpeg").bin_dir() .. ", for this panel only.",
        size = SIZE.micro, color = C.dim },
      { direction = "row", gap = 8,
        button("Download", function() media.fetch(p) end, true),
        button("Cancel", function() p.fetch = nil pcall(bone.gui.invalidate, 0) end, false) } }
  elseif f and f.state == "fetching" then
    local total = (f.plan and f.plan.size) or 1
    local frac = math.max(0, math.min(1, (f.bytes or 0) / total))
    col[#col + 1] = { direction = "column", gap = 6, width = "100%",
      { text = string.format("Downloading… %d of %d MB", math.floor((f.bytes or 0) / 1048576), math.floor(total / 1048576)),
        size = SIZE.small, color = C.dim },
      { height = 6, radius = 3, bg = C.chip, width = "100%",
        { height = 6, radius = 3, bg = C.accent, width = string.format("%.1f%%", frac * 100) } } }
  elseif f and f.state == "failed" then
    col[#col + 1] = { text = "Could not get it: " .. tostring(f.why), size = SIZE.small, color = C.bad }
  end
  return { grow = 1, direction = "column", justify = "center", col }
end

local function video_view(p, width, height)
  if p.need_ffmpeg then return need_ffmpeg(p) end
  if p.error then return { padding = { 20, 16 }, { text = p.error, size = SIZE.small, color = C.dim } } end
  local info = p.info
  if not info then return { padding = { 20, 16 }, { text = "Reading the video…", size = SIZE.small, color = C.dim } } end
  local W = math.max(120, math.floor(width - 24))
  local thumbs_h = (p.thumbs and #p.thumbs > 0) and 64 or 0
  local H = math.max(120, math.floor(height - 56 - thumbs_h - 12))
  local vw, vh = tonumber(info.width) or 16, tonumber(info.height) or 9
  local k = math.min(W / vw, H / vh)
  local iw, ih = vw * k, vh * k
  local x0, y0 = (W - iw) / 2, (H - ih) / 2
  local dur = info.duration or 0
  local playing = p.playing and p.clip and not p.buffering
  local stage = { width = W, height = H, shrink = 0, radius = 8, overflow = "hidden", bg = "#000000", role = "image",
    label = p.name, cursor = "pointer",
    canvas = { fps = playing and media.FPS or 0, draw = function(ctx)
      local d = bone.gui.draw
      local out = {}
      local frame, pos = nil, p.position or 0
      if p.clip then frame, pos = media.tick(p, ctx and ctx.time or 0) end
      local pic = frame or p.poster
      if pic then out[#out + 1] = d.image({ x = x0, y = y0, w = iw, h = ih, path = pic }) end
      -- The position, along the bottom.
      if dur > 0 then
        out[#out + 1] = d.rect({ x = 0, y = H - 4, w = W, h = 4, fill = "#ffffff30" })
        out[#out + 1] = d.rect({ x = 0, y = H - 4, w = W * math.min(1, (pos or 0) / dur), h = 4, fill = C.accent })
      end
      if not p.playing then
        out[#out + 1] = d.circle({ x = W / 2, y = H / 2, r = 30, fill = "#00000088" })
        out[#out + 1] = d.polyline({ points = { { W / 2 - 9, H / 2 - 14 }, { W / 2 + 15, H / 2 }, { W / 2 - 9, H / 2 + 14 } },
          closed = true, fill = "#ffffff", color = "#ffffff", width = 1 })
      elseif p.buffering then
        out[#out + 1] = d.text({ x = W / 2, y = H / 2, text = "Making the preview…", size = 13, color = "#ffffffcc", align = "center" })
      end
      return out
    end } }
  stage.on_click = function()
    if p.playing then media.pause(p) else media.play(p) end
  end
  stage.on_double_click = function() media.open_player(p.path) end
  -- The bar under it: play, where it is, and the player.
  local bar = { direction = "row", align = "center", gap = 10, height = 40, padding = { 0, 4 }, shrink = 0,
    press({ width = 30, height = 30, radius = 15, direction = "row", align = "center", justify = "center", bg = C.chip,
      play_glyph(p.playing, C.dim) }, function() if p.playing then media.pause(p) else media.play(p) end end,
      p.playing and "Pause (space)" or "Play the preview (space)"),
    { text = clock(p.position) .. " / " .. clock(dur), font = "mono", size = SIZE.micro, color = C.dim, wrap = false },
    { text = "silent preview, " .. media.FPS .. " fps", size = SIZE.micro, color = C.faint, wrap = false },
    { grow = 1 },
    press({ direction = "row", align = "center", gap = 6, padding = { 5, 12 }, radius = 7, bg = C.accent, hover = { opacity = 0.9 },
      play_glyph(false, C.on_accent), { text = "Open in player", size = SIZE.small, bold = true, color = C.on_accent, wrap = false } },
      function() media.open_player(p.path) end, "Play it with sound in the desktop's player (o)"),
  }
  local col = { direction = "column", grow = 1, align = "center", padding = { 12, 12, 8, 12 }, gap = 8, stage, bar }
  if thumbs_h > 0 then
    local strip = { direction = "row", gap = 4, height = thumbs_h, width = W, overflow = "hidden", shrink = 0 }
    local tw = math.floor((W - 4 * (#p.thumbs - 1)) / #p.thumbs)
    for _, t in ipairs(p.thumbs) do
      local thumb = { width = tw, height = thumbs_h, radius = 5, overflow = "hidden", shrink = 0, bg = "#000000",
        image = { path = t.path, fit = "cover" }, tooltip = clock(t.at), opacity = 0.85, hover = { opacity = 1 } }
      press(thumb, function() media.play(p, t.at) end, "Play from " .. clock(t.at))
      thumb.hover = { opacity = 1 }
      strip[#strip + 1] = thumb
    end
    col[#col + 1] = strip
  elseif p.making_thumbs then
    col[#col + 1] = { text = "Making the pictures along it…", size = SIZE.micro, color = C.faint }
  end
  return col
end

local function model_view(p, width, height)
  if p.error then return { padding = { 20, 16 }, { text = p.error, size = SIZE.small, color = C.dim } } end
  local m = p.model
  if not m then return { padding = { 20, 16 }, { text = "Reading the model…", size = SIZE.small, color = C.dim } } end
  local W, H = math.max(120, math.floor(width - 20)), math.max(120, math.floor(height - 48))
  local v = p.view
  local r, g, b = rgb(C.accent)
  local color = { 205, 210, 222 }
  if r then color = { math.floor(r * 0.35 + 205 * 0.65), math.floor(g * 0.35 + 210 * 0.65), math.floor(b * 0.35 + 222 * 0.65) } end
  local node = { width = W, height = H, shrink = 0, role = "image", label = p.name, overflow = "hidden", cursor = "grab",
    radius = 8, gradient = { angle = 180, stops = { tint("0e"), tint("04") } },
    canvas = { fps = 0, draw = function()
      return mesh.draw(m, W, H, v.yaw, v.pitch, v.zoom, color, p.wire)
    end } }
  node.on_press = function() p.drag_last = nil end
  node.on_drag = function(q)
    if not q then return end
    local last = p.drag_last
    p.drag_last = { q.x, q.y }
    if not last then return end
    v.yaw = v.yaw + (q.x - last[1]) * 0.01
    v.pitch = math.max(-1.5, math.min(1.5, v.pitch + (q.y - last[2]) * 0.01))
    pcall(bone.gui.invalidate, 0)
  end
  node.on_scroll = function(dy)
    v.zoom = math.max(0.2, math.min(8, v.zoom * (dy and dy > 0 and 1.12 or 1 / 1.12)))
    pcall(bone.gui.invalidate, 0)
  end
  node.on_double_click = function()
    p.view = { yaw = -0.7, pitch = 0.45, zoom = 1 }
    pcall(bone.gui.invalidate, 0)
  end
  local bar = { direction = "row", align = "center", gap = 10, height = 40, padding = { 0, 8 }, shrink = 0,
    segmented({ "Shaded", "Wire" }, p.wire and 2 or 1, function(i) p.wire = i == 2 pcall(bone.gui.invalidate, 0) end,
      { size = SIZE.micro, pad = 8 }),
    { text = string.format("%s triangles%s · %.4g × %.4g × %.4g", tostring(m.count), m.thinned and (" (" .. #m.tris .. " drawn)") or "",
      m.size[1], m.size[2], m.size[3]), size = SIZE.micro, color = C.faint, wrap = false, text_overflow = "ellipsis", shrink = 1 },
    { grow = 1 },
    { text = "drag turns · wheel zooms · double click resets", size = SIZE.micro, color = C.faint, wrap = false },
  }
  return { direction = "column", grow = 1, align = "center", padding = { 10, 10, 4, 10 }, gap = 4, node, bar }
end

local function preview_body(s, width, height)
  local p = s.preview
  if p.loading and not (p.pdf_view ~= "text" and p.pages_state) then
    return { padding = { 20, 16 }, { text = "Reading the PDF…", size = SIZE.small, color = C.dim } }
  end
  if p.error then
    return { padding = { 20, 16 }, { text = p.error, size = SIZE.small, color = C.dim } }
  end
  if p.kind == "image" then return picture(p, width - 20, height) end
  if p.kind == "gif" then return gif_view(p, width - 20, height) end
  if p.kind == "video" then return video_view(p, width, height) end
  if p.kind == "model" then return model_view(p, width, height) end
  if p.kind == "pdf" and p.pdf_view ~= "text" and p.pages_state and p.pages_state ~= "failed" then
    return pdf_pages(p, width)
  end
  if p.kind == "markdown" and p.body then return markdown_view(p.body) end
  if p.kind == "html" and p.raw then
    return html_view(p.raw, p.path, tostring(p.hash), (p.path:match("^(.*)/") or "."), width)
  end
  local lines = text.split(p.body or "")
  local lang = syntax.lang(p.name or "")
  return {
    id = "files:preview", grow = 1, padding = { 6, 0 },
    list = { count = #lines, estimate = LINE, key = "files:preview:" .. tostring(p.path), item = function(i)
      local line = lines[i] or ""
      return { direction = "row", height = LINE,
        { text = tostring(i), font = "mono", size = SIZE.small, width = 48, text_align = "right", color = C.gutter, shrink = 0, padding = { 0, 4, 0, 0 } },
        { spans = spans(line, syntax.runs(line, lang), 0, #line), font = "mono", size = SIZE.code, wrap = false,
          padding = { 0, 0, 0, CODE_PAD }, grow = 1, width = 0, overflow = "hidden" },
      }
    end },
  }
end

local function doc_column(s, width, height)
  local col = { direction = "column", grow = 1, width = 0, gap = 6, padding = { 4, 8, 8, 10 } }
  local strip = tab_strip(s)
  col[#col + 1] = strip
  col[#col + 1] = doc_bar(s)
  local e = s.editor
  local used = 34 + 6 + (strip and 36 or 0) + 12
  if s.doc == "edit" then
    if e.conflict then
      col[#col + 1] = banner("Changed on disk while it was open.", "warning", {
        { "Show changes", function() app.mode("changes") end },
        { "Keep mine", function() app.save(true) end },
        { "Use theirs", function() app.reload_editor() end },
      })
      used = used + 40
    elseif e.error then
      col[#col + 1] = banner(e.error, "error")
      used = used + 40
    end
    if e.confirm then col[#col + 1] = banner(e.status or "Unsaved changes.", "warning") used = used + 40 end
    if e.go then
      col[#col + 1] = goto_bar(s)
      used = used + 40
    elseif e.find and e.find.open and (e.shown == "buffer" or e.shown == "split") then
      col[#col + 1] = find_bar(s)
      used = used + 40
    end
  elseif s.preview.stale then
    col[#col + 1] = banner(s.preview.stale == "gone" and "The file is no longer on disk." or "Changed on disk since it was read.",
      "warning", s.preview.stale ~= "gone" and { { "Read again", function() app.reread() end } } or nil)
    used = used + 40
  end
  local surface = { direction = "column", grow = 1, overflow = "hidden" }
  local focused = s.doc_focused and s.keys_here ~= false
  local hint_h = (focused and keys_shown) and 24 or 0
  s.room_h = height - used - hint_h - 40
  if s.doc == "edit" then
    if e.shown == "changes" then
      surface[#surface + 1] = diff_view(app.editor_changes())
    elseif e.shown == "markdown" then
      surface[#surface + 1] = markdown_view(text.join(e.lines, e.trailing))
    elseif e.shown == "html" then
      surface[#surface + 1] = html_view(text.join(e.lines, e.trailing), e.path, e.version or 0,
        (e.path:match("^(.*)/") or "."), width - 18)
    elseif e.shown == "split" then
      -- The text and what it reads as, side by side, the right one following.
      local half = math.floor((width - 18) / 2)
      local is_md = (syntax.lang(e.path:match("[^/]+$") or "") or {}).markdown
      local right = is_md and markdown_view(text.join(e.lines, e.trailing))
        or html_view(text.join(e.lines, e.trailing), e.path, e.version or 0, (e.path:match("^(.*)/") or "."), half)
      surface[#surface + 1] = { direction = "row", grow = 1,
        { direction = "column", width = half, shrink = 0, editor_lines(s, half) },
        { width = 1, bg = C.line, shrink = 0 },
        { direction = "column", grow = 1, width = 0, right } }
    else
      surface[#surface + 1] = editor_lines(s, width - 18)
    end
  else
    surface[#surface + 1] = preview_body(s, width - 18, height - used - hint_h - 40)
  end
  col[#col + 1] = surface
  if focused then
    if s.doc == "edit" then
      col[#col + 1] = hints({ { "ctrl+s", "save" }, { "ctrl+f", "find" }, { "ctrl+l", "line" }, { "ctrl+k", "add to chat" },
        { "ctrl+c", "copy" }, { "right click", "more" }, { "ctrl+w", "close" }, { "esc", "files" } })
    else
      local p = s.preview
      local pdf = p.kind == "pdf" and p.pages_state
      col[#col + 1] = hints(pdf and { { "t", p.pdf_view == "text" and "pages" or "text" }, { "+ −", "zoom" }, { "g", "page" },
          { "o", "open outside" }, { "esc", "files" } }
        or p.kind == "image" and { { "+ −", "zoom" }, { "0", "fit" }, { "1", "actual size" }, { "drag", "pan" },
          { "o", "open outside" }, { "esc", "files" } }
        or p.kind == "gif" and { { "space", "play · pause" }, { "+ −", "zoom" }, { "0", "fit" }, { "o", "open outside" }, { "esc", "files" } }
        or p.kind == "video" and { { "space", "play · pause" }, { "o", "open in player" }, { "esc", "files" } }
        or p.kind == "model" and { { "drag", "turn" }, { "←→↑↓", "turn" }, { "+ −", "zoom" }, { "0", "reset" }, { "w", "wire" }, { "esc", "files" } }
        or { { "o", "open outside" }, { "e", "edit" }, { "ctrl+k", "add to chat" }, { "esc", "files" } })
    end
  end
  return col
end

-- ---- over the panel: quick open, a name, a menu ----------------------------------

local function card(o)
  local node = { direction = "column", bg = C.card, radius = 12, border = 1, border_color = C.line,
    shadow = { { blur = 28, dy = 10, color = "#00000066" }, { blur = 3, dy = 1, color = "#00000033" } },
    overflow = "hidden", position = "absolute", z = 20 }
  for k, v in pairs(o or {}) do node[k] = v end
  return node
end

local function scrim(close)
  return { position = "absolute", top = 0, left = 0, right = 0, bottom = 0, z = 19, bg = C.scrim,
    on_click = close, on_secondary = close, role = "none", transition = 120 }
end

--- `text` with the bytes at `pos` (a set of positions) in bold accent.
local function lit(text_, pos, base)
  local spans, run, on = {}, "", false
  local set = {}
  for _, p in ipairs(pos or {}) do set[p] = true end
  for i = 1, #text_ do
    local now = set[i] or false
    if now ~= on and run ~= "" then
      spans[#spans + 1] = on and { text = run, bold = true, color = C.accent } or { text = run, color = base }
      run = ""
    end
    on = now
    run = run .. text_:sub(i, i)
  end
  if run ~= "" then spans[#spans + 1] = on and { text = run, bold = true, color = C.accent } or { text = run, color = base } end
  return spans
end

local function quick_card(s, W, H)
  local list, held = app.quick_results()
  local w = math.min(620, W - 40)
  local col = card({ top = 44, left = math.floor((W - w) / 2), width = w, max_height = math.floor(H * 0.7) })
  col[#col + 1] = { direction = "row", align = "center", gap = 10, height = 46, padding = { 0, 14 }, shrink = 0,
    magnifier(C.dim),
    { id = "files:quick", grow = 1, width = 0, size = 15,
      text_input = { value = s.quick_q, placeholder = "Go to file…", focus = true,
        on_change = function(t) app.act.quick_typed(t) end },
      on_key = function(k) return app.act.quick_key(k) end },
    { text = (held and held.loading) and "reading…" or (held and (#held.files .. " files") or ""), size = SIZE.micro,
      color = C.faint, wrap = false, shrink = 0 },
  }
  col[#col + 1] = { height = 1, bg = C.line, shrink = 0 }
  if #list == 0 then
    col[#col + 1] = { padding = { 16, 16 }, { text = (held and held.loading) and "Reading the folder…" or "No file matches that.",
      size = SIZE.small, color = C.dim } }
  else
    app.scroll_to("files:quicklist", s.quick_sel, "q:" .. s.quick_q)
    local q_rel = s.quick_q
    col[#col + 1] = { id = "files:quicklist", height = math.min(#list, 11) * 34 + 8, padding = { 4, 6 }, shrink = 1,
      list = { count = #list, estimate = 34, key = "files:quick:" .. q_rel, item = function(i)
        local hit = list[i]
        local on = i == s.quick_sel
        local dir, leaf = hit.rel:match("^(.*/)([^/]+)$")
        local base = #(dir or "")
        local leaf_pos, dir_pos = {}, {}
        for _, p in ipairs(hit.pos or {}) do
          if p > base then leaf_pos[#leaf_pos + 1] = p - base else dir_pos[#dir_pos + 1] = p end
        end
        local row = { direction = "row", align = "center", gap = 9, height = 34, padding = { 0, 10 }, radius = 7,
          bg = on and C.selected or nil, role = "option", selected = on,
          file_icon(leaf or hit.rel),
          { spans = lit(leaf or hit.rel, leaf_pos), size = SIZE.text, hl = "Normal", wrap = false, shrink = 0 },
          dir and { spans = lit(dir, dir_pos, C.faint), size = SIZE.small, color = C.faint, wrap = false,
            text_overflow = "ellipsis", grow = 1, width = 0 } or { grow = 1 },
          hit.recent and { text = "recent", size = SIZE.micro, color = C.faint, wrap = false, shrink = 0 } or nil,
        }
        return press(row, function() app.act.quick_pick(i) end, hit.rel)
      end } }
  end
  col[#col + 1] = { height = 1, bg = C.line, shrink = 0 }
  col[#col + 1] = { padding = { 0, 8, 6, 8 }, shrink = 0,
    hints({ { "↑↓", "choose" }, { "enter", "open" }, { "name:42", "at a line" }, { "esc", "close" } }, true) }
  return { scrim(function() app.act.quick_close() end), col }
end

local function confirm_card(a, W)
  local w = math.min(420, W - 40)
  local col = card({ top = 70, left = math.floor((W - w) / 2), width = w, padding = { 16, 18 }, gap = 8 })
  col.id, col.focusable, col.autofocus = "files:confirm", true, true
  col.on_key = function(k)
    if k == "y" or k == "Y" then app.act.answer("") app.give_keys() return true end
    app.act.cancel_ask()
    app.give_keys()
    return true
  end
  col[#col + 1] = { text = a.title, size = SIZE.text, bold = true, hl = "Normal" }
  if a.detail then col[#col + 1] = { text = a.detail, size = SIZE.small, color = C.dim } end
  col[#col + 1] = { direction = "row", gap = 8, justify = "end", margin = { 6, 0, 0, 0 },
    { text = "y deletes · any other key leaves it", size = SIZE.micro, color = C.faint, grow = 1, wrap = false,
      align_self = "center" },
    press({ text = "Cancel", size = SIZE.small, hl = "Normal", padding = { 4, 12 }, radius = 6, bg = C.chip },
      function() app.act.cancel_ask() app.give_keys() end, "Cancel"),
    press({ text = a.button or "OK", size = SIZE.small, bold = true, color = "#ffffff", padding = { 4, 14 }, radius = 6,
      bg = C.bad, hover = { opacity = 0.9 } }, function() app.act.answer("") app.give_keys() end, a.button or "OK"),
  }
  return { scrim(function() app.act.cancel_ask() app.give_keys() end), col }
end

local function ask_card(s, W)
  local a = s.ask
  if a.confirm then return confirm_card(a, W) end
  local w = math.min(420, W - 40)
  local col = card({ top = 70, left = math.floor((W - w) / 2), width = w, padding = { 14, 16 }, gap = 10 })
  col[#col + 1] = { text = a.title, size = SIZE.text, bold = true, hl = "Normal" }
  col[#col + 1] = { id = "files:ask", height = 32, padding = { 0, 10 }, radius = 7, bg = C.chip, border = 1,
    border_color = a.error and C.bad or C.accent, size = SIZE.text,
    text_input = { value = a.value, focus = true, select = true,
      on_change = function(t) a.value, a.error = t, nil end,
      on_submit = function(t) app.act.answer(t) end },
    on_key = function(k)
      if k == "esc" then app.act.cancel_ask() app.give_keys() return true end
      if k == "enter" then
        local v = bone.gui.input_text("files:ask") or a.value
        app.act.answer(v)
        if not (app.state().ask) then app.give_keys() end
        return true
      end
      return false
    end }
  if a.error then col[#col + 1] = { text = a.error, size = SIZE.small, color = C.bad } end
  col[#col + 1] = { direction = "row", gap = 8, justify = "end",
    press({ text = "Cancel", size = SIZE.small, hl = "Normal", padding = { 4, 12 }, radius = 6, bg = C.chip },
      function() app.act.cancel_ask() app.give_keys() end, "Cancel"),
    press({ text = "OK", size = SIZE.small, bold = true, color = C.on_accent, padding = { 4, 16 }, radius = 6, bg = C.accent,
      hover = { opacity = 0.9 } }, function() app.act.answer(a.value) app.give_keys() end, "OK"),
  }
  return { scrim(function() app.act.cancel_ask() app.give_keys() end), col }
end

--- A menu, at (top, left) in the box it is drawn in.
menu_card = function(m, room_w, room_h)
  local w = 236
  local h = 12
  for _, it in ipairs(m.items) do h = h + (it.separator and 9 or 26) end
  local top = m.top or 0
  if room_h and top + h > room_h - 4 then top = math.max(4, top - h) end
  local left = math.max(4, math.min(m.left or 0, (room_w or 400) - w - 4))
  local col = card({ top = top, left = left, width = w, padding = 6, radius = 9, z = 30 })
  for i, it in ipairs(m.items) do
    if it.separator then
      col[#col + 1] = { height = 1, bg = C.line, margin = { 4, 6 }, shrink = 0 }
    else
      local on = m.at == i
      local row = { direction = "row", align = "center", height = 26, padding = { 0, 10 }, radius = 6,
        bg = on and C.selected or nil, opacity = it.off and 0.45 or nil,
        { text = it.label, size = SIZE.small, color = it.danger and C.bad or nil, hl = (not it.danger) and "Normal" or nil,
          grow = 1, width = 0, wrap = false },
        it.key and { text = it.key, size = SIZE.micro, color = C.faint, font = "mono", wrap = false, shrink = 0 } or nil,
      }
      if it.off then
        row.role = "option"
      else
        press(row, function() app.act.menu_close() if it.run then it.run() end end, it.label)
        row.hover = { bg = C.selected }
      end
      col[#col + 1] = row
    end
  end
  return { position = "absolute", top = 0, left = 0, right = 0, bottom = 0, z = 29,
    on_click = function() app.act.menu_close() end, on_secondary = function() app.act.menu_close() end, col }
end

-- ---- files named in the chat ---------------------------------------------------------

--- The files a reply names, as a row of chips under it: each opens the file
--- in the panel (at its line). `refs` is { { path, label, line, end_line, dir } }.
function M.ref_chips(refs, open)
  colors()
  local row = { direction = "row", flex_wrap = true, gap = 6, row_gap = 6, align = "center", margin = { 2, 4, 6, 4 } }
  for _, r in ipairs(refs) do
    local name = r.label
    local chip = { direction = "row", align = "center", gap = 6, height = 24, padding = { 0, 9, 0, 7 }, radius = 7,
      bg = C.chip, border = 1, border_color = C.line, tooltip = r.path .. (r.line and (" · line " .. r.line) or "") .. "\nopens it in the files panel",
      r.dir and folder_icon() or file_icon(r.path:match("[^/]+$") or r.path),
      { text = name, size = SIZE.small, hl = "Normal", wrap = false },
      r.line and { text = ":" .. r.line .. (r.end_line and r.end_line ~= r.line and ("–" .. r.end_line) or ""), size = SIZE.small,
        font = "mono", color = C.faint, wrap = false } or nil }
    press(chip, function() open(r) end, "Open " .. name .. " in the files panel")
    chip.hover = { bg = C.soft, border_color = C.accent }
    row[#row + 1] = chip
  end
  return row
end

-- ---- the panel ---------------------------------------------------------------

function M.setup(a)
  app = a
end

--- The panel's node: ctx is { width, height, focused } in pixels.
function M.view(ctx)
  colors()
  app.focused(ctx and ctx.focused)
  local s = app.state()
  local W, H = tonumber(ctx and ctx.width) or 800, tonumber(ctx and ctx.height) or 600
  local root = { direction = "column", grow = 1, gap = 0 }
  root[#root + 1] = header(s)
  root[#root + 1] = { height = 1, bg = C.line, shrink = 0 }
  local body = { direction = "row", grow = 1, gap = 0 }
  -- Room under the header, for what has to fit (a menu, a picture).
  s.room_h = H - 120
  if s.doc then
    local side = math.min(SIDE, math.floor(W * 0.34))
    body[#body + 1] = doc_column(s, W - side - 1, H - 36)
    body[#body + 1] = { width = 1, bg = C.line, shrink = 0 }
    s.room_h = H - 120
    body[#body + 1] = side_column(s, side, true)
  else
    body[#body + 1] = side_column(s, W, false)
  end
  root[#root + 1] = body
  if s.quick_on then
    for _, n in ipairs(quick_card(s, W, H)) do root[#root + 1] = n end
  elseif s.ask then
    for _, n in ipairs(ask_card(s, W)) do root[#root + 1] = n end
  end
  return root
end

return M
