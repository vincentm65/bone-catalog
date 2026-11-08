-- The files panel as a terminal draws it: lines of the plugin's own, not the
-- shared elements, so a row can hold more than one color, the open file can
-- sit beside the tree, and the editor can show a selection. Every color comes
-- from the colorscheme: the groups here are default links to its own, and the
-- ones that mix two (a word's color on the selection) are made from the
-- scheme's colors as it stands, again whenever it changes. The elements view
-- stays in ui.lua, behind the tui_look setting.
--
-- ui.lua owns the state and the keys; `app` (M.setup) is the same bridge the
-- desktop's look gets.

local M = {}

local text = require("files.text")
local syntax = require("files.syntax")
local kinds = require("files.kinds")

local app

-- ---- colors ------------------------------------------------------------------

-- The panel's own groups, each a link to one every scheme has.
local LINKS = {
  FilesTSelect = "Selection",    -- the selection, and the row the keys are on
  FilesTLine = "UserMessage",    -- the caret's line, a row of a list without the keys
  FilesTMatch = "DiffAdd",       -- what find found
  FilesTFlash = "DiffAdd",       -- lines the agent just wrote
  FilesTAdded = "Success",       -- change bars
  FilesTChanged = "Accent",
  FilesTRemoved = "ErrorMsg",
  FilesTDir = "ToolPath",        -- a folder's name
  FilesTSep = "WinSeparator",
  FilesTCard = "InputBackground", -- an overlay's ground
  FilesTBorder = "PopupBorder",
  FilesTTitle = "PopupTitle",
}
for name, link in pairs(LINKS) do bone.hl.set(name, { link = link, default = true }) end

local function resolve(name, depth)
  local g = bone.hl.get(name) or {}
  if g.link and (depth or 0) < 8 then
    local base = resolve(g.link, (depth or 0) + 1)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(g) do if k ~= "link" then out[k] = v end end
    return out
  end
  return g
end

local made, signature = {}, nil

--- The groups made from two are made again when the scheme changes.
local function check_scheme()
  local n, s, a = resolve("Normal"), resolve("FilesTSelect"), resolve("Accent")
  local key = table.concat({ tostring(n.fg), tostring(n.bg), tostring(s.bg), tostring(a.fg), tostring(resolve("FilesTLine").bg) }, "|")
  if key ~= signature then
    signature = key
    made = {}
    M.dirty = true
  end
end

--- A group with `fg`'s color (and weight) on `bg`'s background.
local function on(fg, bg)
  if not bg then return fg end
  local name = "FilesTX_" .. fg .. "_" .. bg
  if not made[name] then
    local f, b = resolve(fg), resolve(bg)
    local spec = { fg = f.fg, bg = b.bg, bold = f.bold, italic = f.italic, underline = f.underline,
      strikethrough = f.strikethrough }
    -- A scheme with no background for it: the colors turned round.
    if not b.bg then spec.reverse = true end
    bone.hl.set(name, spec)
    made[name] = true
  end
  return name
end

--- The caret: the scheme's accent as the ground of the cell it is on.
local function caret_group()
  local name = "FilesTXCaret"
  if not made[name] then
    local n, a = resolve("Normal"), resolve("Accent")
    bone.hl.set(name, { fg = n.bg or "black", bg = a.fg or "white", bold = true })
    made[name] = true
  end
  return name
end

local function bold(group)
  local name = "FilesTXBold_" .. group
  if not made[name] then
    local g = resolve(group)
    local spec = {}
    for k, v in pairs(g) do spec[k] = v end
    spec.bold = true
    bone.hl.set(name, spec)
    made[name] = true
  end
  return name
end

-- ---- lines -------------------------------------------------------------------

local function ascii(s) return not s:find("[\128-\255\t]") end

--- How many cells `s` takes.
local function width(s)
  if ascii(s) then return #s end
  return bone.text.width((s:gsub("\t", "    ")))
end

--- `s` cut to `cells` cells.
local function cut(s, cells)
  if cells <= 0 then return "" end
  s = s:gsub("\t", "    ")
  if ascii(s) then return s:sub(1, cells) end
  local out, used = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local w = bone.text.width(ch)
    if used + w > cells then break end
    out[#out + 1] = ch
    used = used + w
  end
  return table.concat(out)
end

--- A row being made, `cells` wide.
local function row(cells)
  return { spans = {}, used = 0, cells = cells, hits = {} }
end

--- Put `s` on the row in `group`; it stops at the row's end. `hit`: what a
--- press on it does (the column inside it is passed).
local function put(r, s, group, hit)
  if not s or s == "" or r.used >= r.cells then return r end
  s = tostring(s):gsub("\t", "    ")
  local w = width(s)
  if r.used + w > r.cells then
    s = cut(s, r.cells - r.used)
    w = width(s)
  end
  if hit then r.hits[#r.hits + 1] = { from = r.used, to = r.used + w, run = hit } end
  r.spans[#r.spans + 1] = { s, group or "Normal" }
  r.used = r.used + w
  return r
end

--- Spaces to `col` (or the end) in `group`.
local function pad(r, col, group)
  col = math.min(col or r.cells, r.cells)
  if col > r.used then put(r, string.rep(" ", col - r.used), group) end
  return r
end

--- `right` (a list of { text, group }) at the row's right end, after spaces.
local function right(r, list, ground)
  local w = 0
  for _, s in ipairs(list) do w = w + width(s[1]) end
  if r.used + w + 1 > r.cells then return r end
  pad(r, r.cells - w, ground)
  for _, s in ipairs(list) do put(r, s[1], s[2] or ground, s[3]) end
  return r
end

--- Two columns' rows side by side, a bar between them.
local function beside(left, right_rows, height, lw, rw)
  local out = {}
  for i = 1, height do
    local a = left[i] or pad(row(lw), lw)
    local b = right_rows[i] or pad(row(rw), rw)
    local r = row(lw + 1 + rw)
    for _, s in ipairs(a.spans) do r.spans[#r.spans + 1] = s end
    for _, h in ipairs(a.hits) do r.hits[#r.hits + 1] = h end
    r.used = lw
    put(r, "│", "FilesTSep")
    local base = r.used
    for _, s in ipairs(b.spans) do r.spans[#r.spans + 1] = s end
    for _, h in ipairs(b.hits) do r.hits[#r.hits + 1] = { from = h.from + base, to = h.to + base, run = h.run, x0 = base } end
    r.used = lw + 1 + rw
    r.tree_i, r.tree_x = b.tree_i, base
    out[i] = r
  end
  return out
end

-- ---- pieces ------------------------------------------------------------------

local function crumbs(r, s)
  local root, home = s.listing.root, s.home
  local parts = {}
  local rest = root
  local drive = root:match("^%a:/")
  if home ~= "" and (root == home or root:sub(1, #home + 1) == home .. "/") then
    parts[1] = { "~", home }
    rest = root:sub(#home + 2)
  elseif drive then
    -- A Windows drive: C: is the first crumb, C:/ its path.
    parts[1] = { drive:sub(1, 2), drive }
    rest = root:sub(#drive + 1)
  else
    parts[1] = { "/", "/" }
    rest = root:gsub("^/+", "")
  end
  local at = parts[1][2]
  for part in tostring(rest):gmatch("[^/]+") do
    at = (at:sub(-1) == "/" and at or at .. "/") .. part
    parts[#parts + 1] = { part, at }
  end
  local first = math.max(1, #parts - 3)
  put(r, " ")
  if first > 1 then put(r, "… › ", "Dim") end
  for i = first, #parts do
    local p = parts[i]
    local last = i == #parts
    put(r, p[1], last and bold("Normal") or "Dim", (not last) and function() app.crumb(p[2]) end or nil)
    if not last then put(r, " › ", "Dim") end
  end
end

local function header(s, cells)
  local r = row(cells)
  crumbs(r, s)
  local tail = {}
  if s.listing.git_state == "loading" then tail[#tail + 1] = { "git… ", "Dim" } end
  if s.following then tail[#tail + 1] = { "◉ following ", "Accent" } end
  if s.keys_here == false then tail[#tail + 1] = { "keys: prompt ", "Dim" } end
  local note = s.listing.error or s.listing.note
  if note and #tail == 0 then
    local room = cells - r.used - 3
    if room > 10 then tail[#tail + 1] = { cut(note, room) .. " ", s.listing.error and "ErrorMsg" or "Dim" } end
  end
  right(r, tail)
  return r
end

local function hints(cells, list)
  local r = row(cells)
  put(r, " ")
  for i, h in ipairs(list) do
    if r.used + width(h[1]) + width(h[2]) + 3 > cells then break end
    if i > 1 then put(r, "  ") end
    put(r, h[1], "Accent")
    put(r, " " .. h[2], "Dim")
  end
  return r
end

--- A choice of a few, the chosen one lit: tabs, the editor's views.
local function segments(r, names, current, pick, counts)
  for i, name in ipairs(names) do
    local label = " " .. name .. ((counts and counts[i] and counts[i] > 0) and (" " .. counts[i]) or "") .. " "
    put(r, label, i == current and on("Accent", "FilesTSelect") or "Dim", function() pick(i) end)
  end
end

-- ---- the tree, the search, what changed ---------------------------------------

--- The first row shown of a list `count` long: kept where the wheel left it,
--- unless the selection moved (then it follows, just into view).
local function scroll_into(top, selected, height, count, follow)
  top = top or 1
  if follow ~= false then
    if selected < top then top = selected end
    if selected > top + height - 1 then top = selected - height + 1 end
  end
  return math.max(1, math.min(top, math.max(1, count - height + 1)))
end

--- Whether the list follows its selection this frame: it does unless it was
--- scrolled by the wheel and the selection has not moved since.
local function follows(holder, key, selected)
  local last = holder["tlast_" .. key]
  holder["tlast_" .. key] = selected
  if last ~= selected then holder.tscrolled = false end
  return not holder.tscrolled
end

local function sign_group(sign)
  if sign == "?" or sign == "A" then return "Success" end
  if sign == "D" then return "ErrorMsg" end
  return "WarningMsg"
end

local function tree_rows(s, cells, height, focused, narrow)
  local out = {}
  local rows = s.listing.rows
  if #rows == 0 then
    out[1] = put(row(cells), "  " .. (s.listing.error or (s.listing.filter ~= "" and "Nothing here holds that." or "This folder is empty.")), "Dim")
    return out
  end
  local L = s.listing
  L.ttop = scroll_into(L.ttop, L.selected, height, #rows, follows(L, "tree", L.selected))
  for i = L.ttop, math.min(#rows, L.ttop + height - 1) do
    local rw = rows[i]
    local on_it = i == L.selected
    local ground = on_it and (focused and "FilesTSelect" or "FilesTLine") or nil
    local function g(name) return on(name, ground) end
    local r = row(cells)
    put(r, string.rep("  ", rw.depth + 0) .. " ", g("Normal"), function() app.click_row(i) end)
    if rw.type == "dir" then
      local open = L.open[rw.path] or rw.unfolded
      put(r, open and "▾ " or "▸ ", g("Dim"), function() app.click_row(i) end)
    else
      put(r, "  ", g("Normal"))
    end
    local name_group = rw.ignored and "Dim" or (rw.type == "dir" and "FilesTDir" or (rw.name:sub(1, 1) == "." and "Dim" or "Normal"))
    if rw.hit then
      local a, b = rw.hit[1], rw.hit[2]
      put(r, rw.name:sub(1, a - 1), g(name_group), function() app.click_row(i) end)
      put(r, rw.name:sub(a, b), on(bold(name_group), "FilesTMatch"), function() app.click_row(i) end)
      put(r, rw.name:sub(b + 1), g(name_group), function() app.click_row(i) end)
    else
      put(r, rw.name, g(name_group), function() app.click_row(i) end)
    end
    local b = app.badges(rw.path)
    local tail = {}
    if b.mark then tail[#tail + 1] = { "● ", g("WarningMsg") } end
    if b.sign then tail[#tail + 1] = { (b.sign == "?" and "U" or b.sign) .. " ", g(sign_group(b.sign)) }
    elseif b.inside then tail[#tail + 1] = { "· ", g("Dim") } end
    if not narrow and rw.type == "file" then
      local size = app.size_of(rw.size)
      if size then tail[#tail + 1] = { string.format("%8s ", size), g("Dim") } end
    end
    right(r, tail, ground)
    pad(r, cells, ground)
    r.tree_i = i
    out[#out + 1] = r
  end
  return out
end

local function marked(snippet, term, ground)
  local spans = {}
  if term == "" then return { { snippet, on("Normal", ground) } } end
  local hay = term:match("%u") and snippet or snippet:lower()
  local needle = term:match("%u") and term or term:lower()
  local at = 1
  while true do
    local a, b = hay:find(needle, at, true)
    if not a then break end
    if a > at then spans[#spans + 1] = { snippet:sub(at, a - 1), on("Normal", ground) } end
    spans[#spans + 1] = { snippet:sub(a, b), on(bold("Normal"), "FilesTMatch") }
    at = b + 1
  end
  if at <= #snippet then spans[#spans + 1] = { snippet:sub(at), on("Normal", ground) } end
  return spans
end

local function search_rows(s, cells, height, focused)
  local out = {}
  local L = s.listing
  local q = row(cells)
  put(q, " ⌕ ", "Accent")
  put(q, L.query, "Normal")
  if focused then put(q, " ", caret_group()) end
  if L.query == "" then put(q, " Search in " .. s.leaf, "Dim") end
  out[1] = q
  local state
  if L.search_state == "loading" then state = "Searching…"
  elseif s.search_error then state = s.search_error
  elseif L.search_state == "done" then
    local files, n = {}, 0
    for _, h in ipairs(s.hits) do if not files[h.name] then files[h.name] = true n = n + 1 end end
    state = #s.hits .. (#s.hits == 1 and " result" or " results") .. " in " .. n .. (n == 1 and " file" or " files")
  elseif L.search_state == "empty" then state = s.search_note or "No results."
  else state = "Text inside the files · lowercase matches any case" end
  out[2] = put(row(cells), "   " .. state, s.search_error and "ErrorMsg" or "Dim")
  -- The hits under their file.
  local items, at_hit, last = {}, {}, nil
  for i, h in ipairs(s.hits) do
    if h.name ~= last then items[#items + 1] = { file = h.name } last = h.name end
    items[#items + 1] = { hit = i }
    at_hit[i] = #items
  end
  local room = height - 2
  if #items == 0 or room <= 0 then return out end
  L.htop = scroll_into(L.htop, at_hit[L.hit_selected] or 1, room, #items, follows(L, "hit", L.hit_selected))
  for n = L.htop, math.min(#items, L.htop + room - 1) do
    local it = items[n]
    local r = row(cells)
    if it.file then
      local dir, leaf = it.file:match("^(.*/)([^/]+)$")
      put(r, " ")
      put(r, leaf or it.file, bold("Normal"))
      if dir then put(r, "  " .. dir, "Dim") end
    else
      local h = s.hits[it.hit]
      local sel = it.hit == L.hit_selected
      local ground = sel and (focused and "FilesTSelect" or "FilesTLine") or nil
      put(r, string.format("   %5s  ", tostring(h.line or "")), on("Dim", ground), function() app.open_hit(it.hit) end)
      for _, sp in ipairs(marked((h.text or ""):gsub("^%s+", ""), L.query, ground)) do
        put(r, sp[1], sp[2], function() app.open_hit(it.hit) end)
      end
      pad(r, cells, ground)
    end
    out[#out + 1] = r
  end
  return out
end

local function changed_rows(s, cells, height, focused)
  local out = {}
  local list = app.changed_items()
  if #list == 0 then
    out[1] = put(row(cells), "  " .. list.empty, "Dim")
    return out
  end
  local L = s.listing
  L.ctop = scroll_into(L.ctop, L.changed_selected, height, #list, follows(L, "changed", L.changed_selected))
  for i = L.ctop, math.min(#list, L.ctop + height - 1) do
    local it = list[i]
    local sel = i == L.changed_selected
    local ground = sel and (focused and "FilesTSelect" or "FilesTLine") or nil
    local r = row(cells)
    local dir, leaf = it.rel:match("^(.*/)([^/]+)$")
    put(r, " ", on("Normal", ground))
    put(r, leaf or it.rel, on("Normal", ground), function() app.open_changed(i) end)
    if dir then put(r, "  " .. dir, on("Dim", ground), function() app.open_changed(i) end) end
    local tail = {}
    if it.written then tail[#tail + 1] = { (it.detail or "") .. " ● ", on("WarningMsg", ground) } end
    if it.sign then tail[#tail + 1] = { (it.sign == "?" and "U" or it.sign) .. " ", on(sign_group(it.sign), ground) } end
    right(r, tail, ground)
    pad(r, cells, ground)
    out[#out + 1] = r
  end
  return out
end

local TABS = { "Files", "Search", "Changed" }

local function side_column(s, cells, height, narrow)
  local focused = s.keys_here ~= false and not s.doc_focused
  local out = {}
  local tabs = row(cells)
  put(tabs, " ")
  segments(tabs, TABS, s.tab, function(i) app.tab(i) end, { 0, 0, app.changed_count() })
  out[1] = tabs
  local filtering = s.tab == 1 and (s.listing.filter ~= "" or s.listing.filter_typing)
  local body_h = height - 2 - (filtering and 1 or 0)
  local body
  if s.tab == 2 then body = search_rows(s, cells, body_h, focused)
  elseif s.tab == 3 then body = changed_rows(s, cells, body_h, focused)
  else body = tree_rows(s, cells, body_h, focused, narrow) end
  for i = 1, body_h do out[#out + 1] = body[i] or pad(row(cells), cells) end
  if filtering then
    local f = row(cells)
    put(f, " ≡ ", "Accent")
    put(f, s.listing.filter, "Normal")
    if s.listing.filter_typing then put(f, " ", caret_group()) end
    if s.listing.filter == "" then put(f, " names that hold…", "Dim") end
    out[#out + 1] = f
  end
  local keys
  if not focused then keys = { { "tab", "the tree" } }
  elseif s.tab == 2 then keys = { { "↑↓", "results" }, { "enter", "open" }, { "esc", "back" } }
  elseif s.doc then keys = { { "↑↓", "move" }, { "←→", "fold" }, { "tab", "the file" }, { "esc", "close file" }, { "p", "go to" } }
  else keys = { { "↑↓", "move" }, { "←→", "fold" }, { "enter", "open" }, { "p", "go to file" }, { "f", "filter" }, { "/", "search" }, { "a", "new" }, { "q", "close" } } end
  out[#out + 1] = hints(cells, keys)
  return out
end

-- ---- the open file -------------------------------------------------------------

local function tab_strip(s, cells)
  if #s.docs < 2 then return nil end
  local r = row(cells)
  put(r, " ")
  for i, t in ipairs(s.docs) do
    local path = t.kind == "edit" and t.ed.path or t.path
    local name = path:match("[^/]+$") or path
    local cur = i == s.doc_at
    local dirty = t.kind == "edit" and t.ed.dirty
    local g = cur and on(bold("Normal"), "FilesTSelect") or "Dim"
    put(r, " " .. name .. (dirty and " ●" or "") .. " ", g, function() app.tab_click(i) end)
    put(r, " ")
  end
  return r
end

local function doc_bar(s, cells)
  local r = row(cells)
  local editing = s.doc == "edit"
  local path = editing and s.editor.path or s.preview.path
  local rel = s.relative(path)
  local dir, leaf = rel:match("^(.*/)([^/]+)$")
  put(r, " ")
  if dir then put(r, dir, "Dim") end
  put(r, leaf or rel, bold("Normal"))
  if editing and s.editor.dirty then put(r, " ●", "Dim") end
  local b = app.badges(path)
  if b.mark then put(r, "  edited", "WarningMsg") end
  if b.sign then put(r, "  " .. (b.sign == "?" and "untracked" or ("git " .. b.sign)), sign_group(b.sign)) end
  local tail = {}
  if editing then
    local e = s.editor
    if e.saving then tail[#tail + 1] = { "Saving…  ", "Dim" }
    elseif e.status then tail[#tail + 1] = { cut(e.status, 28) .. "  ", "Dim" } end
    tail[#tail + 1] = { "Ln " .. e.line .. ", Col " .. (e.col + 1) .. "  ", "Dim" }
    local names, modes = { "Edit", "Changes" }, { "buffer", "changes" }
    local lower = (leaf or rel):lower()
    if (syntax.lang(leaf or rel) or {}).markdown or lower:match("%.html?$") then
      names[3], modes[3] = "Split", "split"
      names[4], modes[4] = "Preview", lower:match("%.html?$") and "html" or "markdown"
    end
    for i, m in ipairs(modes) do
      tail[#tail + 1] = { " " .. names[i] .. " ", e.shown == m and on("Accent", "FilesTSelect") or "Dim", function() app.mode(m) end }
    end
  else
    local size = app.size_of(app.size_at(path))
    if size then tail[#tail + 1] = { size .. " ", "Dim" } end
  end
  right(r, tail)
  return r
end

--- The syntax runs of a line from byte a to b, cut where paints start and
--- stop, each piece with its paint's ground.
local function painted(line, runs, a, b, paints)
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
      local hl = (runs[ri] and runs[ri][1] <= s0) and runs[ri][3] or "Normal"
      local ground
      for _, p in ipairs(paints) do if p[1] <= s0 and p[2] >= e0 then ground = p[3] end end
      out[#out + 1] = { line:sub(s0 + 1, e0), hl, ground, s0 }
    end
  end
  return out
end

local function columns_of(line, from, to)
  local n, at = 0, from
  while at < to do
    local nx = text.next_offset(line, at)
    if nx <= at then break end
    n = n + (line:sub(at + 1, at + 1) == "\t" and 4 or bone.text.width(line:sub(at + 1, nx)))
    at = nx
  end
  return n
end

local function offset_at(line, from, col)
  local n, at = 0, from
  while at < #line do
    local nx = text.next_offset(line, at)
    if nx <= at then break end
    local w = line:sub(at + 1, at + 1) == "\t" and 4 or bone.text.width(line:sub(at + 1, nx))
    if n + w / 2 > col then break end
    n, at = n + w, nx
  end
  return at
end

local function editor_rows(s, cells, height)
  local e = s.editor
  local focused = s.doc_focused and s.keys_here ~= false
  local out = {}
  local digits = math.max(3, #tostring(#e.lines))
  local gutter = digits + 2
  local room = math.max(4, cells - gutter - 1)
  local caret_col = columns_of(e.lines[e.line] or "", 0, e.col)
  e.tshift = e.tshift or 0
  if caret_col < e.tshift then e.tshift = math.max(0, caret_col - 4) end
  if caret_col >= e.tshift + room then e.tshift = caret_col - math.floor(room * 0.7) end
  local shift = e.tshift
  e.ttop = scroll_into(e.ttop, e.line, height, #e.lines, follows(e, "line", e.line .. ":" .. e.col))
  local lang = syntax.lang(e.path:match("[^/]+$") or "")
  local s1, c1, s2, c2
  if e.anchor and not (e.anchor.line == e.line and e.anchor.col == e.col) then
    local al, ac = e.anchor.line, e.anchor.col
    if al < e.line or (al == e.line and ac < e.col) then s1, c1, s2, c2 = al, ac, e.line, e.col
    else s1, c1, s2, c2 = e.line, e.col, al, ac end
  end
  local by_line = {}
  local cur_hit = e.find and e.find.at
  for n, h in ipairs(app.find_hits() or {}) do
    local l = by_line[h[1]] or {}
    l[#l + 1] = { h[2], h[3], n == cur_hit and "FilesTSelect" or "FilesTMatch" }
    by_line[h[1]] = l
  end
  local ba, bb = app.brackets()
  local marks = app.marks() or {}
  local flash = e.flash
  M.editor_geom = { top = e.ttop, gutter = gutter, shift = shift, room = room }
  for i = e.ttop, math.min(#e.lines, e.ttop + height - 1) do
    local line = e.lines[i] or ""
    local cur = i == e.line
    local ground = (flash and flash[i]) and "FilesTFlash" or ((cur and not s1) and "FilesTLine" or nil)
    local r = row(cells)
    local m = marks[i]
    put(r, string.format("%" .. digits .. "d", i), on(cur and "Normal" or "Dim", ground))
    local bar = m == "add" and { "▎", "FilesTAdded" } or m == "mod" and { "▎", "FilesTChanged" }
      or (marks.del and marks.del[i]) and { "▸", "FilesTRemoved" } or { " ", "Normal" }
    put(r, bar[1], on(bar[2], ground))
    put(r, " ", on("Normal", ground))
    local a = offset_at(line, 0, shift)
    local b = offset_at(line, a, room)
    local paints = {}
    for _, h in ipairs(by_line[i] or {}) do paints[#paints + 1] = h end
    if ba and ba[1] == i then paints[#paints + 1] = { ba[2], ba[2] + 1, "FilesTSelect" } end
    if bb and bb[1] == i then paints[#paints + 1] = { bb[2], bb[2] + 1, "FilesTSelect" } end
    if s1 and i >= s1 and i <= s2 then
      local from = (i == s1) and c1 or 0
      local to = (i == s2) and c2 or #line
      if to > from then paints[#paints + 1] = { from, to, "FilesTSelect" } end
    end
    local caret = cur and focused and math.max(a, math.min(e.col, b)) or nil
    for _, piece in ipairs(painted(line, syntax.runs(line, lang), a, b, paints)) do
      local ptext, hl, pg, p0 = piece[1], piece[2], piece[3] or ground, piece[4]
      if caret and caret >= p0 and caret < p0 + #ptext then
        -- The caret on a character of this piece: that cell lit.
        local k = caret - p0
        local nx = text.next_offset(ptext, k)
        put(r, ptext:sub(1, k), on(hl, pg))
        put(r, ptext:sub(k + 1, nx), caret_group())
        put(r, ptext:sub(nx + 1), on(hl, pg))
        caret = nil
      else
        put(r, ptext, on(hl, pg))
      end
    end
    -- At the end of the line, the caret is a cell after it.
    if caret then put(r, " ", caret_group()) end
    local eol = s1 and i >= s1 and i < s2
    if eol then put(r, " ", "FilesTSelect") end
    pad(r, cells, ground)
    out[#out + 1] = r
  end
  return out
end

local function diff_rows(s, cells, height)
  local out = {}
  local rows = app.editor_changes() or {}
  if #rows == 0 then
    out[1] = put(row(cells), "  No changes since the file was opened.", "Dim")
    return out
  end
  local e = s.editor
  e.dtop = math.max(1, math.min(e.dtop or 1, math.max(1, #rows - height + 1)))
  for i = e.dtop, math.min(#rows, e.dtop + height - 1) do
    local d = rows[i]
    local r = row(cells)
    if d.separator then put(r, "   ⋯", "Dim")
    elseif not d.sign then put(r, "   " .. tostring(d.text or ""), "Dim")
    else
      local ground = d.sign == "+" and "DiffAdd" or d.sign == "-" and "DiffDelete" or nil
      local function num(n) return (tonumber(n) or 0) > 0 and tostring(n) or "" end
      put(r, string.format("%5s %5s ", num(d.old), num(d.new)), on("Dim", ground))
      put(r, (d.sign == " " and " " or d.sign) .. " ", on(d.sign == "+" and "Success" or d.sign == "-" and "ErrorMsg" or "Dim", ground))
      put(r, tostring(d.text or ""), on("Normal", ground))
      pad(r, cells, ground)
    end
    out[#out + 1] = r
  end
  return out
end

--- Markdown (or a page as Markdown) as lines: headings bold, code on its
--- ground, quotes and lists marked, long lines wrapped.
local function prose_rows(body, cells, height, top)
  local lines = {}
  local in_code = false
  for raw in (body .. "\n"):gmatch("(.-)\n") do
    if raw:match("^```") then
      in_code = not in_code
    elseif in_code then
      lines[#lines + 1] = { { "  " .. raw, "MdCodeBlock" } }
    else
      local h, rest = raw:match("^(#+)%s+(.*)$")
      if h then
        lines[#lines + 1] = { { rest:gsub("%*%*", ""), "MdHeading" } }
      elseif raw:match("^>%s?") then
        for _, w in ipairs(bone.text.wrap({ { raw:gsub("^>%s?", ""), "MdQuote" } }, cells - 4)) do
          local l = { { "  ▍ ", "Dim" } }
          for _, sp in ipairs(w) do l[#l + 1] = sp end
          lines[#lines + 1] = l
        end
      elseif raw:match("^%s*$") then
        lines[#lines + 1] = { { "", "Normal" } }
      else
        -- Links as their words, in the link color; bold and code marks go.
        local spans = {}
        local s = raw:gsub("%*%*(.-)%*%*", "%1"):gsub("`([^`]+)`", "%1")
        local at = 1
        while true do
          local a, b, label = s:find("%[([^%]]*)%]%([^%)]*%)", at)
          if not a then break end
          if a > at then spans[#spans + 1] = { s:sub(at, a - 1), "Normal" } end
          spans[#spans + 1] = { label, "MdLink" }
          at = b + 1
        end
        if at <= #s then spans[#spans + 1] = { s:sub(at), "Normal" } end
        local bullet = s:match("^%s*[-*]%s") or s:match("^%s*%d+%.%s")
        for k, w in ipairs(bone.text.wrap(spans, cells - 2, bullet and { rest = "   " } or nil)) do
          local l = { { " ", "Normal" } }
          for _, sp in ipairs(w) do l[#l + 1] = sp end
          lines[#lines + 1] = l
        end
      end
    end
  end
  local out = {}
  top = math.max(1, math.min(top or 1, math.max(1, #lines - height + 1)))
  for i = top, math.min(#lines, top + height - 1) do
    local r = row(cells)
    for _, sp in ipairs(lines[i]) do put(r, sp[1], sp[2]) end
    out[#out + 1] = r
  end
  return out, top, #lines
end

local function preview_rows(s, cells, height)
  local p = s.preview
  local out = {}
  if p.loading and p.kind == "pdf" and not p.body then
    out[1] = put(row(cells), "  Reading the PDF…", "Dim")
    return out
  end
  if p.error then
    out[1] = put(row(cells), "  " .. p.error, "ErrorMsg")
    return out
  end
  if p.kind == "gif" or p.kind == "video" or p.kind == "model" then
    for _, w in ipairs(app.act.media_words()) do out[#out + 1] = put(row(cells), "  " .. w, "Dim") end
    return out
  end
  if p.kind == "image" then
    out[1] = put(row(cells), "  " .. tostring(p.detail or "A picture") .. " · o opens it in the desktop's viewer", "Dim")
    return out
  end
  if (p.kind == "markdown" or p.kind == "html") and (p.body or p.raw) then
    local body = p.kind == "html" and p.raw and require("files.html").to_markdown(require("files.html").parse(p.raw)) or p.body
    local rows
    rows, p.ttop = prose_rows(body, cells, height, p.ttop)
    return rows
  end
  local lines = text.split(p.body or "")
  local lang = syntax.lang(p.name or "")
  p.ttop = math.max(1, math.min(p.ttop or 1, math.max(1, #lines - height + 1)))
  local digits = math.max(3, #tostring(#lines))
  for i = p.ttop, math.min(#lines, p.ttop + height - 1) do
    local line = lines[i] or ""
    local r = row(cells)
    put(r, string.format("%" .. digits .. "d  ", i), "Dim")
    for _, piece in ipairs(painted(line, syntax.runs(line, lang), 0, #line, {})) do put(r, piece[1], piece[2]) end
    out[#out + 1] = r
  end
  return out
end

local function doc_column(s, cells, height)
  local out = {}
  local strip = tab_strip(s, cells)
  if strip then out[#out + 1] = strip end
  out[#out + 1] = doc_bar(s, cells)
  local e = s.editor
  local function banner(msg, group)
    out[#out + 1] = put(row(cells), " " .. cut(msg, cells - 2), group)
  end
  if s.doc == "edit" then
    if e.conflict then banner("Changed on disk · ctrl+o keeps yours · ctrl+r takes theirs · ctrl+g shows the difference", "WarningMsg")
    elseif e.error then banner(e.error, "ErrorMsg") end
    if e.confirm then banner(e.status or "Unsaved changes", "WarningMsg") end
    if e.go then
      local r = row(cells)
      put(r, " Go to line ", "Accent")
      put(r, e.go.value, "Normal")
      put(r, " ", caret_group())
      put(r, "   enter goes · esc leaves", "Dim")
      out[#out + 1] = r
    elseif e.find and e.find.open then
      local hits = app.find_hits() or {}
      local r = row(cells)
      put(r, " ⌕ ", "Accent")
      put(r, e.find.term or "", "Normal")
      if e.find.typing then put(r, " ", caret_group()) end
      right(r, { { ((e.find.term or "") == "" and "" or ((e.find.at or 0) .. " of " .. #hits)) .. "  enter next · ↑ before · esc  ", "Dim" } })
      out[#out + 1] = r
    end
  elseif s.preview.stale then
    banner(s.preview.stale == "gone" and "The file is no longer on disk." or "Changed on disk since it was read · v reads it again", "WarningMsg")
  end
  local focused = s.doc_focused and s.keys_here ~= false
  local body_h = height - #out - 1
  local body
  if s.doc == "edit" then
    if e.shown == "changes" then body = diff_rows(s, cells, body_h)
    elseif e.shown == "markdown" or e.shown == "html" then
      local whole = text.join(e.lines, e.trailing)
      if e.shown == "html" then whole = require("files.html").to_markdown(require("files.html").parse(whole)) end
      body, e.ptop = prose_rows(whole, cells, body_h, e.ptop)
    elseif e.shown == "split" then
      local lw = math.floor((cells - 1) / 2)
      local left = editor_rows(s, lw, body_h)
      local whole = text.join(e.lines, e.trailing)
      if not (syntax.lang(e.path:match("[^/]+$") or "") or {}).markdown then
        whole = require("files.html").to_markdown(require("files.html").parse(whole))
      end
      local right_rows = prose_rows(whole, cells - lw - 1, body_h, e.ptop)
      body = beside(left, right_rows, body_h, lw, cells - lw - 1)
    else
      body = editor_rows(s, cells, body_h)
    end
  else
    body = preview_rows(s, cells, body_h)
  end
  M.doc_body_top = #out
  for i = 1, body_h do out[#out + 1] = body[i] or pad(row(cells), cells) end
  local keys
  if not focused then keys = { { "tab", "the file" } }
  elseif s.doc == "edit" and (e.shown == "buffer" or e.shown == "split") then
    keys = { { "ctrl+s", "save" }, { "ctrl+f", "find" }, { "ctrl+l", "line" }, { "ctrl+k", "chat" }, { "ctrl+g", "changes" }, { "ctrl+w", "close" }, { "esc", "files" } }
  elseif s.doc == "edit" then keys = { { "e", "edit" }, { "↑↓", "scroll" }, { "esc", "files" } }
  else keys = { { "↑↓", "scroll" }, { "o", "open outside" }, { "e", "edit" }, { "ctrl+w", "close" }, { "esc", "files" } } end
  out[#out + 1] = hints(cells, keys)
  return out
end

-- ---- over the panel ----------------------------------------------------------------

--- `card` (rows of `w` cells) laid over `rows` at (top, left).
local function overlay(rows, card, top, left, total)
  for k, c in ipairs(card) do
    local i = top + k
    local base = rows[i]
    if base then
      -- What is under the card is left of it, the card, then what is right of it.
      local r = row(total)
      local used = 0
      for _, sp in ipairs(base.spans) do
        if used >= left then break end
        local w = width(sp[1])
        if used + w <= left then put(r, sp[1], sp[2]) used = used + w
        else put(r, cut(sp[1], left - used), sp[2]) used = left end
      end
      pad(r, left)
      local base_at = r.used
      for _, sp in ipairs(c.spans) do put(r, sp[1], sp[2]) end
      for _, h in ipairs(c.hits) do r.hits[#r.hits + 1] = { from = h.from + base_at, to = h.to + base_at, run = h.run } end
      pad(r, total)
      rows[i] = r
    end
  end
end

local function card_rows(title, w, body)
  local out = {}
  local top = row(w)
  put(top, "╭─ ", "FilesTBorder")
  put(top, title, "FilesTTitle")
  put(top, " " .. string.rep("─", math.max(0, w - width(title) - 5)), "FilesTBorder")
  put(top, "╮", "FilesTBorder")
  out[1] = top
  for _, b in ipairs(body) do
    local r = row(w)
    put(r, "│ ", "FilesTBorder")
    for _, sp in ipairs(b.spans) do
      -- A span already on a ground of its own (a chosen row) keeps it.
      local g = tostring(sp[2])
      put(r, sp[1], g:match("^FilesTX") and g or on(g, "FilesTCard"), sp[3])
    end
    pad(r, w - 1, "FilesTCard")
    put(r, "│", "FilesTBorder")
    out[#out + 1] = r
  end
  local bottom = row(w)
  put(bottom, "╰" .. string.rep("─", w - 2) .. "╯", "FilesTBorder")
  out[#out + 1] = bottom
  return out
end

local function quick_card(s, W, H)
  local list, held = app.quick_results()
  local w = math.min(W - 4, 72)
  local body = {}
  body[1] = { spans = { { "⌕ ", "Accent" }, { s.quick_q, "Normal" }, { " ", caret_group() },
    { (held and held.loading) and "  reading…" or (held and ("  " .. #held.files .. " files") or ""), "Dim" } } }
  body[2] = { spans = { { "", "Normal" } } }
  local room = math.max(3, math.min(#list, H - 8))
  local top = math.max(1, math.min(s.quick_sel - math.floor(room / 2), math.max(1, #list - room + 1)))
  if #list == 0 then body[#body + 1] = { spans = { { (held and held.loading) and "Reading the folder…" or "No file matches that.", "Dim" } } } end
  for i = top, math.min(#list, top + room - 1) do
    local hit = list[i]
    local dir, leaf = hit.rel:match("^(.*/)([^/]+)$")
    local sel = i == s.quick_sel
    local g = sel and "FilesTSelect" or "FilesTCard"
    local spans = { { sel and "› " or "  ", on("Accent", g) }, { leaf or hit.rel, on(bold("Normal"), g), function() app.act.quick_pick(i) end } }
    if dir then spans[#spans + 1] = { "  " .. dir, on("Dim", g), function() app.act.quick_pick(i) end } end
    if hit.recent then spans[#spans + 1] = { "  recent", on("Dim", g) } end
    body[#body + 1] = { spans = spans }
  end
  body[#body + 1] = { spans = { { "", "Normal" } } }
  body[#body + 1] = { spans = { { "↑↓", "Accent" }, { " choose  ", "Dim" }, { "enter", "Accent" }, { " open  ", "Dim" }, { "name:42", "Accent" }, { " at a line  ", "Dim" }, { "esc", "Accent" }, { " close", "Dim" } } }
  -- Rows of spans with their presses, as card_rows wants them.
  local rows_ = {}
  for _, b in ipairs(body) do
    local r = row(w - 3)
    for _, sp in ipairs(b.spans) do put(r, sp[1], sp[2], sp[3]) end
    rows_[#rows_ + 1] = { spans = r.spans, hits = r.hits }
  end
  local card = {}
  for _, rr in ipairs(card_rows("Go to file", w, rows_)) do card[#card + 1] = rr end
  -- card_rows dropped the presses: put them back, past the border.
  for k, rr in ipairs(rows_) do
    local c = card[k + 1]
    if c then for _, h in ipairs(rr.hits) do c.hits[#c.hits + 1] = { from = h.from + 2, to = h.to + 2, run = h.run } end end
  end
  return card, w
end

local function ask_card(s, W)
  local a = s.ask
  local w = math.min(W - 4, 60)
  local body = {}
  if a.confirm then
    body[1] = { spans = { { a.detail or "", "Normal" } } }
    body[2] = { spans = { { "", "Normal" } } }
    body[3] = { spans = { { "y", "Accent" }, { " " .. (a.button or "yes"):lower() .. "   ", "Dim" }, { "any other key", "Accent" }, { " leaves it", "Dim" } } }
  else
    body[1] = { spans = { { a.value, "Normal" }, { " ", caret_group() } } }
    if a.error then body[2] = { spans = { { a.error, "ErrorMsg" } } } end
    body[#body + 1] = { spans = { { "enter", "Accent" }, { " makes it   ", "Dim" }, { "esc", "Accent" }, { " leaves it", "Dim" } } }
  end
  return card_rows(a.title, w, body), w
end

local function menu_card(m, W)
  local w = 34
  local body = {}
  for i, it in ipairs(m.items) do
    if it.separator then body[#body + 1] = { spans = { { string.rep("─", w - 4), "FilesTBorder" } } }
    else
      local sel = m.at == i
      local g = sel and "FilesTSelect" or "FilesTCard"
      local label = it.label
      local key = it.key or ""
      local gap = math.max(1, w - 4 - width(label) - width(key))
      body[#body + 1] = { spans = { { label, on(it.danger and "ErrorMsg" or (it.off and "Dim" or "Normal"), g) },
        { string.rep(" ", gap), on("Normal", g) }, { key, on("Dim", g) } }, run = (not it.off) and it.run or nil }
    end
  end
  local card = card_rows("", w, body)
  for k, b in ipairs(body) do
    if b.run then
      local run = b.run
      card[k + 1].hits[#card[k + 1].hits + 1] = { from = 1, to = w - 1, run = function() app.act.menu_close() run() end }
    end
  end
  return card, w
end

-- ---- the panel -----------------------------------------------------------------------

local cache = { key = nil, lines = nil, rows = nil }

function M.setup(a) app = a end

--- Something changed: the next frame draws it.
function M.invalidate() cache.key = nil end

--- The panel's lines: ctx is { width, height, focused }.
function M.render(ctx)
  check_scheme()
  app.focused(ctx and ctx.focused)
  local W, H = math.max(20, tonumber(ctx and ctx.width) or 60), math.max(6, tonumber(ctx and ctx.height) or 30)
  local key = tostring(app.generation()) .. ":" .. W .. "x" .. H .. ":" .. tostring(ctx and ctx.focused) .. ":" .. tostring(signature)
  if cache.key == key and not M.dirty then return cache.lines end
  M.dirty = false
  local s = app.state()
  local rows = { header(s, W) }
  local body_h = H - 1
  -- The file beside the tree when there is room; one of them when not.
  local wide = W >= 90
  local body
  if s.doc and wide then
    local sw = math.max(24, math.min(40, math.floor(W * 0.3)))
    local dw = W - sw - 1
    local doc = doc_column(s, dw, body_h)
    local side = side_column(s, sw, body_h, true)
    body = beside(doc, side, body_h, dw, sw)
    M.layout = { split = true, doc_w = dw, side_x = dw + 1, side_w = sw }
  elseif s.doc and s.doc_focused then
    body = doc_column(s, W, body_h)
    M.layout = { split = false, doc_w = W, doc_only = true }
  else
    body = side_column(s, W, body_h, W < 50)
    M.layout = { split = false, side_x = 0, side_w = W, side_only = true }
  end
  for i = 1, body_h do rows[#rows + 1] = body[i] or pad(row(W), W) end
  -- What stands over it.
  if s.quick_on then
    local card, w = quick_card(s, W, H)
    overlay(rows, card, 1, math.floor((W - w) / 2), W)
  elseif s.ask then
    local card, w = ask_card(s, W)
    overlay(rows, card, 3, math.floor((W - w) / 2), W)
  elseif s.menu then
    local card, w = menu_card(s.menu, W)
    local top = math.max(1, math.min(H - #card - 1, (s.menu.top or 2)))
    local left = math.max(0, math.min(W - w - 1, s.menu.left or 2))
    overlay(rows, card, top - 1, left, W)
  end
  local lines = {}
  for i, r in ipairs(rows) do lines[i] = r.spans end
  cache.key, cache.lines, cache.rows = key, lines, rows
  return lines
end

--- A press at panel row `line` (from 1) and column `col` (from 1): true when
--- something took it.
function M.press(line, col)
  local r = cache.rows and cache.rows[line]
  if not r then return false end
  local x = col - 1
  for k = #r.hits, 1, -1 do
    local h = r.hits[k]
    if x >= h.from and x < h.to then
      h.run(x - h.from)
      return true
    end
  end
  return false
end

--- The tree's row under panel row `line`, column `col`, or nil.
function M.tree_at(line, col)
  local r = cache.rows and cache.rows[line]
  if not r or not r.tree_i then return nil end
  if (col - 1) < (r.tree_x or 0) then return nil end
  return r.tree_i
end

--- The editor's line and byte under panel row `line`, column `col`, or nil.
function M.editor_at(line, col, editor)
  local g = M.editor_geom
  local lay = M.layout
  if not g or not lay or not editor then return nil end
  local x = col - 1
  if lay.split and x >= lay.doc_w then return nil end
  if lay.side_only then return nil end
  local body_line = line - 1 - (M.doc_body_top or 2)
  if body_line < 1 then return nil end
  local li = g.top + body_line - 1
  if li > #editor.lines then li = #editor.lines end
  local tx = x - g.gutter - 1
  if tx < 0 then tx = 0 end
  local l = editor.lines[li] or ""
  local a = offset_at(l, 0, g.shift)
  return li, offset_at(l, a, tx)
end

return M
