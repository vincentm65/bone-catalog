-- What every terminal pane does the same way, whichever module draws it (the
-- multiplexer's panes, bone.ui.terminal's panels): the cursor's cell, a
-- mouse report's bytes, and the keys that scroll back instead of typing.
local M = {}

--- `line` with the cell at `col` drawn as the cursor.
function M.with_cursor(line, col)
  local out, x, done = {}, 1, false
  for _, item in ipairs(line) do
    local text, hl = item[1], item[2]
    local w = bone.text.width(text)
    if not done and col < x + w then
      local before, cell, after, cx = "", nil, "", x
      for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if cell then after = after .. ch
        elseif cx + bone.text.width(ch) > col then cell = ch
        else before = before .. ch end
        cx = cx + bone.text.width(ch)
      end
      if before ~= "" then out[#out + 1] = { before, hl } end
      out[#out + 1] = { cell or " ", "TermCursor" }
      if after ~= "" then out[#out + 1] = { after, hl } end
      done = true
    else
      out[#out + 1] = item
    end
    x = x + w
  end
  if not done then
    out[#out + 1] = { string.rep(" ", math.max(0, col - x)) }
    out[#out + 1] = { " ", "TermCursor" }
  end
  return out
end

-- A value of xterm's UTF-8 mouse encoding (LuaJIT has no utf8 library).
local function utf8(n)
  return n < 128 and string.char(n) or string.char(192 + math.floor(n / 64), 128 + n % 64)
end

--- xterm's report of a mouse action at `col`, `row` of screen `s` (nil when
--- the program does not ask for the mouse).
function M.mouse(s, action, button, col, row)
  local mode = s and s.mouse
  if mode == nil or mode == "none" then return nil end
  if action == "up" and mode == "press" then return nil end
  if action == "drag" and mode ~= "button_motion" and mode ~= "any_motion" then return nil end
  local code
  if action == "wheel" then code = button == "up" and 64 or 65
  else
    code = ({ left = 0, middle = 1, right = 2 })[button or "left"]
    if not code then return nil end
    if action == "up" then code = 3 elseif action == "drag" then code = code + 32 end
  end
  if s.mouse_encoding == "sgr" then
    return string.format("\27[<%d;%d;%d%s", code, col, row, action == "up" and "m" or "M")
  end
  if s.mouse_encoding == "utf8" then return "\27[M" .. utf8(32 + code) .. utf8(32 + col) .. utf8(32 + row) end
  -- The legacy encoding stops at its printable range; programs that need
  -- more ask for SGR.
  return "\27[M" .. string.char(32 + code, 32 + math.min(223, col), 32 + math.min(223, row))
end

--- Scroll terminal `t` ({ screen, scroll }) back or forth when `key` is one
--- that does: the wheel, shift+page keys, ctrl+home/end, and the plain page
--- keys once it is scrolled back. Every other key is the program's. True
--- when it scrolled.
function M.scroll(t, key)
  local s = t.screen
  local max, page = s and s.max or 0, math.max(1, (s and #s.lines or 24) - 1)
  local by = key == "wheelup" and 3 or key == "wheeldown" and -3
    or (key == "shift+pageup" or (key == "pageup" and t.scroll > 0)) and page
    or (key == "shift+pagedown" or (key == "pagedown" and t.scroll > 0)) and -page
    or (key == "ctrl+home" and max > 0) and max
    or key == "ctrl+end" and -max
  if not by then return false end
  t.scroll = math.max(0, math.min(max, t.scroll + by))
  return true
end

--- Text pasted into a program: line breaks typed as enter, as terminals paste
--- them, and bracketed when it asks, without a bracket of the text's own
--- (which would end the paste early and run the rest).
function M.paste(s, text)
  text = text:gsub("\r?\n", "\r")
  if s and s.bracketed_paste then
    text = "\27[200~" .. text:gsub("\27%[20[01]~", "") .. "\27[201~"
  end
  return text
end

-- ---- the desktop app: a screen on a grid of cells, and selecting in it ----

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function codepoint(ch)
  local b1, b2, b3, b4 = ch:byte(1, 4)
  b2, b3, b4 = b2 or 0x80, b3 or 0x80, b4 or 0x80
  if b1 < 0x80 then return b1 end
  if b1 < 0xE0 then return (b1 % 0x20) * 0x40 + b2 % 0x40 end
  if b1 < 0xF0 then return (b1 % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + b3 % 0x40 end
  return (b1 % 0x08) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + b4 % 0x40
end

-- Characters a monospace font draws one cell wide: Latin, Greek, Cyrillic,
-- punctuation, box drawing and blocks. Any other one (wide, an icon, an
-- emoji, one from a fallback font) is placed in its cells on its own, so a
-- glyph that is not exactly as wide cannot move the rest of the line.
local function regular(ch)
  if #ch == 1 then return true end
  local cp = codepoint(ch)
  return cp < 0x530 or (cp >= 0x2000 and cp < 0x2070) or (cp >= 0x2500 and cp < 0x25A0)
end

local function char_width(ch)
  if #ch == 1 then return 1 end
  return bone.text.width(ch)
end

--- A line's characters by column: cells[col] is the character there, "" for
--- the second cell of a wide one.
function M.cells(line)
  local cells = {}
  for _, item in ipairs(line or {}) do
    for ch in (item[1] or ""):gmatch(CHAR) do
      local w = char_width(ch)
      if w == 0 and #cells > 0 then
        local i = #cells
        while i > 1 and cells[i] == "" do i = i - 1 end
        cells[i] = cells[i] .. ch
      else
        cells[#cells + 1] = ch
        for _ = 2, w do cells[#cells + 1] = "" end
      end
    end
  end
  return cells
end

-- A selection is t.sel = { a = { line, col }, b = { line, col }, unit = 1 | 2
-- | 3 (characters, words, lines) } on terminal t ({ screen, scroll }). A line
-- is a screen row minus the scroll, so it stays on its text while scrolling.
local WORD_STOP = "^[%s\"'`()%[%]{}<>|,;]$"

local function word_edge(t, line, col, dir)
  local cells = M.cells(t.screen and t.screen.lines[line + t.scroll])
  while col > 1 and cells[col] == "" do col = col - 1 end
  local ch = cells[col]
  if not ch or ch:match(WORD_STOP) then return col end
  while true do
    local n = col + dir
    while cells[n] == "" do n = n + dir end
    local c = cells[n]
    if not c or c:match(WORD_STOP) then break end
    col = n
  end
  if dir > 0 then while cells[col + 1] == "" do col = col + 1 end end
  return col
end

--- The selection's first and last cell, in order: l1, c1, l2, c2.
function M.sel_range(t)
  local s = t.sel
  if not s then return end
  local a, b = s.a, s.b
  if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then a, b = b, a end
  local l1, c1, l2, c2 = a[1], a[2], b[1], b[2]
  if s.unit == 2 then
    c1, c2 = word_edge(t, l1, c1, -1), word_edge(t, l2, c2, 1)
  elseif s.unit == 3 then
    c1, c2 = 1, math.huge
  end
  return l1, c1, l2, c2
end

--- The selected text: each line's cells, trailing blanks dropped (nil when
--- there is none).
function M.sel_text(t)
  local l1, c1, l2, c2 = M.sel_range(t)
  if not l1 or not t.screen then return nil end
  local out = {}
  for line = l1, l2 do
    local cells = M.cells(t.screen.lines[line + t.scroll])
    local from, to = line == l1 and c1 or 1, line == l2 and math.min(c2, #cells) or #cells
    local parts = {}
    for col = from, to do parts[#parts + 1] = cells[col] end
    out[#out + 1] = (table.concat(parts):gsub("%s+$", ""))
  end
  local text = table.concat(out, "\n")
  return text ~= "" and text or nil
end

--- Start a selection at a press (unit from how many presses came quickly at
--- that cell), or end one at the release: copied when it holds text.
local last_press
function M.sel_start(t, line, col)
  local now = bone.now and bone.now() or os.time() * 1000
  local p, unit = last_press, 1
  if p and p.t == t and now - p.time < 400 and p.line == line and p.col == col then unit = p.unit % 3 + 1 end
  last_press = { t = t, time = now, line = line, col = col, unit = unit }
  t.sel = { a = { line, col }, b = { line, col }, unit = unit }
end

function M.sel_finish(t)
  local s = t.sel
  if not s then return end
  local click = s.unit == 1 and s.a[1] == s.b[1] and s.a[2] == s.b[2]
  local text = not click and M.sel_text(t)
  if text then
    if bone.clipboard then bone.clipboard.copy(text) end
  else
    t.sel = nil
  end
end

-- A group's background, following links (nil when it has none).
local function group_bg(name)
  local g, n = bone.hl.get(name), 0
  while g and not g.bg and g.link and n < 8 do g, n = bone.hl.get(g.link), n + 1 end
  return g and g.bg
end

-- "@term/<fg>/<bg>/<flags>" (bone's terminal screens) drawn in reverse: a
-- group with the colors swapped, the defaults being Normal's.
local reversed = {}
local function reverse_group(fg, bg, flags, normal)
  local name = "@termrev/" .. fg .. "/" .. bg .. "/" .. flags
  local key = tostring(normal.fg) .. tostring(normal.bg)
  if reversed[name] ~= key then
    local function value(c, default) return c == "-" and default or tonumber(c) or c end
    bone.hl.set(name, {
      fg = value(bg, normal.bg or "#000000"), bg = value(fg, normal.fg or "#eeeeee"),
      bold = flags:find("b") and true or nil, italic = flags:find("i") and true or nil,
      underline = flags:find("u") and true or nil,
    })
    reversed[name] = key
  end
  return name
end

--- What drawing rows needs: the cell, the font size and the colors.
function M.look(cell, size, cols)
  local sel = bone.hl.get("TextSelection")
  return {
    cw = cell.w, ch = cell.h, cols = cols, size = size,
    normal = bone.hl.get("Normal") or {},
    selection = sel and sel.bg and "TextSelection" or "#2a3f55",
  }
end

-- A run of cells with one look, as a box exactly that many cells wide.
local function segment(seg, look)
  local width = seg.cols * look.cw
  local text = table.concat(seg.parts)
  local hl, bg = seg.hl ~= "Normal" and seg.hl or nil, nil
  local fg, b, flags = seg.hl:match("^@term/([^/]*)/([^/]*)/(%a*)$")
  if fg and flags:find("r") then
    hl = reverse_group(fg, b, flags, look.normal)
    bg = hl
  elseif fg and b ~= "-" then
    bg = seg.hl
  elseif not fg and hl and group_bg(hl) then
    bg = hl
  end
  if seg.sel then bg = look.selection end
  local span = { text = text, hl = hl }
  if seg.cur then
    bg, span.color = look.normal.fg or "#eeeeee", look.normal.bg or "#161616"
  end
  if not bg and not text:find("[^ ]") then
    return { width = width, height = look.ch, shrink = 0 }
  end
  return {
    width = width, height = look.ch, shrink = 0, bg = bg, line_height = look.ch,
    font = "mono", size = look.size, wrap = false, spans = { span },
  }
end

--- One screen row as a node: runs of cells, each exactly as wide as its
--- cells, with the selection (`sel` = { sel_range() }) and the cursor's column.
function M.row_node(row, line, sel, cursor, look)
  local kids, seg, col = { direction = "row", height = look.ch, shrink = 0 }, nil, 1
  local l1, c1, l2, c2 = sel[1], sel[2], sel[3], sel[4]
  local selected = l1 and line >= l1 and line <= l2
  local function in_sel(c)
    return selected and (line > l1 or c >= c1) and (line < l2 or c <= c2)
  end
  local function flush()
    if seg then kids[#kids + 1] = segment(seg, look) end
    seg = nil
  end
  local function add(ch, w, hl, lone)
    local s, cur = in_sel(col), cursor == col
    local key = hl .. (s and "|s" or "")
    if lone or cur or not seg or seg.lone or seg.cur or seg.key ~= key then
      flush()
      seg = { key = key, hl = hl, sel = s, cur = cur, lone = lone, parts = {}, cols = 0 }
    end
    seg.parts[#seg.parts + 1] = ch
    seg.cols = seg.cols + w
    col = col + w
  end
  for _, item in ipairs(row or {}) do
    local hl = item[2] or "Normal"
    for ch in (item[1] or ""):gmatch(CHAR) do
      local w = char_width(ch)
      if w == 0 and seg then
        seg.parts[#seg.parts + 1] = ch
      elseif col <= look.cols then
        w = math.max(w, 1)
        add(ch, w, hl, not regular(ch) or w > 1)
      end
    end
  end
  -- The selection and the cursor reach past the end of the text.
  local to = cursor or 0
  if selected then to = math.max(to, line < l2 and look.cols or math.min(c2, look.cols)) end
  while col <= to do add(" ", 1, "Normal", false) end
  flush()
  return kids
end

return M
