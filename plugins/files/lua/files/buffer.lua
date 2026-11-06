-- What the editor does to its buffer: the caret and the selection, typing and
-- deleting over a selection, pasting several lines, the indentation the file
-- already uses, moving by word, the bracket that matches the one at the caret,
-- and finding text. Each function takes the editor table `e`:
--
--   e.lines (strings), e.line (from 1), e.col (a byte offset), e.anchor (the
--   other end of the selection: { line, col }, or nil), e.undo, e.redo,
--   e.version (counts the edits, so what is drawn from the text can be kept).
--
-- ui.lua owns the editor; this only changes it.

local text = require("files.text")

local M = {}

M.UNDO_MAX = 200

-- ---- undo --------------------------------------------------------------------

local function snapshot(e)
  local lines = {}
  for i, line in ipairs(e.lines) do lines[i] = line end
  return { lines = lines, line = e.line, col = e.col }
end

--- Keep the buffer as it is, so the next edit can be taken back. A run of the
--- same edit on one line (typing a word, backspacing) is one step.
function M.remember(e, kind, row)
  if kind and e.undo_kind == kind and e.undo_row == row then return end
  e.undo[#e.undo + 1] = snapshot(e)
  while #e.undo > M.UNDO_MAX do table.remove(e.undo, 1) end
  e.redo = {}
  e.undo_kind, e.undo_row = kind, row
end

local function touched(e)
  e.dirty = true
  e.version = (e.version or 0) + 1
end
M.touched = touched

local function step(e, from, to)
  local s = table.remove(from)
  if not s then return false end
  to[#to + 1] = snapshot(e)
  e.lines, e.line, e.col = s.lines, s.line, s.col
  e.anchor, e.undo_kind = nil, nil
  e.version = (e.version or 0) + 1
  return true
end

function M.undo(e) return step(e, e.undo, e.redo) end
function M.redo(e) return step(e, e.redo, e.undo) end

-- ---- the selection -------------------------------------------------------------

local function before(l1, c1, l2, c2)
  return l1 < l2 or (l1 == l2 and c1 < c2)
end

--- The selection, start first: l1, c1, l2, c2; nil when nothing is selected.
function M.range(e)
  local a = e.anchor
  if not a then return nil end
  if a.line == e.line and a.col == e.col then return nil end
  if before(a.line, a.col, e.line, e.col) then return a.line, a.col, e.line, e.col end
  return e.line, e.col, a.line, a.col
end

function M.has(e) return M.range(e) ~= nil end

function M.clear(e) e.anchor = nil end

--- The text from (l1, c1) to (l2, c2).
function M.slice(e, l1, c1, l2, c2)
  if l1 == l2 then return (e.lines[l1] or ""):sub(c1 + 1, c2) end
  local out = { (e.lines[l1] or ""):sub(c1 + 1) }
  for i = l1 + 1, l2 - 1 do out[#out + 1] = e.lines[i] or "" end
  out[#out + 1] = (e.lines[l2] or ""):sub(1, c2)
  return table.concat(out, "\n")
end

--- What is selected, or nil.
function M.selected(e)
  local l1, c1, l2, c2 = M.range(e)
  if not l1 then return nil end
  return M.slice(e, l1, c1, l2, c2)
end

function M.select_all(e)
  e.anchor = { line = 1, col = 0 }
  e.line = #e.lines
  e.col = #(e.lines[e.line] or "")
end

--- Start a selection at the caret, unless one is being made already.
local function hold(e, extend)
  if extend then
    if not e.anchor then e.anchor = { line = e.line, col = e.col } end
  else
    e.anchor = nil
  end
end

-- ---- changing the text ---------------------------------------------------------

--- Take out the text from (l1, c1) to (l2, c2); the caret goes where it was.
local function cut(e, l1, c1, l2, c2)
  local head = (e.lines[l1] or ""):sub(1, c1)
  local tail = (e.lines[l2] or ""):sub(c2 + 1)
  for _ = l1 + 1, l2 do table.remove(e.lines, l1 + 1) end
  e.lines[l1] = head .. tail
  e.line, e.col = l1, c1
end

--- Delete the selection, as one step of undo. False when there is none.
function M.delete_selection(e)
  local l1, c1, l2, c2 = M.range(e)
  e.anchor = nil
  if not l1 then return false end
  M.remember(e, nil)
  cut(e, l1, c1, l2, c2)
  touched(e)
  return true
end

--- Put `str` at the caret, over the selection; a newline in it splits the
--- line (a paste of several lines). One run of typing is one step of undo.
function M.insert(e, str)
  str = tostring(str or ""):gsub("\r\n?", "\n")
  local l1, c1, l2, c2 = M.range(e)
  if l1 then
    M.remember(e, nil)
    cut(e, l1, c1, l2, c2)
  else
    M.remember(e, str:find("\n", 1, true) and "paste" or "insert", e.line)
  end
  e.anchor = nil
  local line = e.lines[e.line] or ""
  local head, tail = line:sub(1, e.col), line:sub(e.col + 1)
  if not str:find("\n", 1, true) then
    e.lines[e.line] = head .. str .. tail
    e.col = e.col + #str
  else
    local parts = {}
    for piece in (str .. "\n"):gmatch("(.-)\n") do parts[#parts + 1] = piece end
    e.lines[e.line] = head .. parts[1]
    for i = 2, #parts do table.insert(e.lines, e.line + i - 1, parts[i]) end
    e.line = e.line + #parts - 1
    e.col = #parts[#parts]
    e.lines[e.line] = parts[#parts] .. tail
    e.undo_kind = nil
  end
  touched(e)
end

-- ---- indentation ----------------------------------------------------------------

--- The indentation this file uses: a tab, or two or four spaces (what most of
--- its indented lines are a multiple of). Read once per file.
function M.unit(e)
  if e.unit then return e.unit end
  local tabs, spaces, two, four = 0, 0, 0, 0
  for i = 1, math.min(#e.lines, 2000) do
    local lead = (e.lines[i] or ""):match("^[ \t]+")
    if lead and (e.lines[i] or ""):match("%S") then
      if lead:sub(1, 1) == "\t" then
        tabs = tabs + 1
      else
        spaces = spaces + 1
        if #lead % 4 == 0 then four = four + 1 end
        if #lead % 2 == 0 then two = two + 1 end
      end
    end
  end
  local unit
  if tabs > spaces then
    unit = "\t"
  elseif spaces > 0 and four >= two * 0.9 and four > 0 then
    unit = "    "
  elseif spaces > 0 then
    unit = "  "
  else
    local ext = (e.path or ""):match("%.(%w+)$") or ""
    unit = ({ py = "    ", rs = "    ", go = "\t", c = "    ", h = "    ", cpp = "    ",
      java = "    ", cs = "    ", swift = "    ", kt = "    ", php = "    ", makefile = "\t" })[ext:lower()] or "  "
  end
  e.unit = unit
  return unit
end

-- What ends a line after which the next is indented one more step.
local OPENS = { "[%(%[{]%s*$", "%f[%w]then%s*$", "%f[%w]do%s*$", "%f[%w]else%s*$",
  "%f[%w]repeat%s*$", "%f[%w]function%s*%b()%s*$", "function%s*[%w_.:]*%s*%b()%s*$",
  ":%s*$", "=>%s*$", "%->%s*$" }

local function opens(line, path)
  local code = line:gsub("%s+$", "")
  if code == "" then return false end
  for _, pat in ipairs(OPENS) do
    if code:find(pat) then
      -- A colon opens a block in Python and YAML; elsewhere it is mostly a label.
      if pat == ":%s*$" then
        local ext = (path or ""):match("%.(%w+)$") or ""
        return ext == "py" or ext == "yaml" or ext == "yml" or ext == "nim"
      end
      return true
    end
  end
  return false
end

--- Enter: a new line indented as this one, one step more after a line that
--- opens a block, and between a pair of brackets the closing one on a line of
--- its own.
function M.newline(e)
  if M.has(e) then M.delete_selection(e) end
  M.remember(e, "split", e.line)
  local line = e.lines[e.line] or ""
  local head, tail = line:sub(1, e.col), line:sub(e.col + 1)
  local indent = text.leading(head)
  local more = opens(head, e.path)
  local unit = M.unit(e)
  local closing = tail:match("^%s*([%)%]}])")
  e.lines[e.line] = head:gsub("[ \t]+$", "")
  if more and closing then
    table.insert(e.lines, e.line + 1, indent .. unit)
    table.insert(e.lines, e.line + 2, indent .. (tail:gsub("^%s+", "")))
    e.line, e.col = e.line + 1, #indent + #unit
  else
    local start = indent .. (more and unit or "")
    table.insert(e.lines, e.line + 1, start .. (tail:gsub("^[ \t]+", "")))
    e.line, e.col = e.line + 1, #start
  end
  touched(e)
end

--- A closing bracket typed on a line of nothing but indentation steps it back.
function M.type_char(e, ch)
  if ch:match("^[%)%]}]$") and not M.has(e) then
    local line = e.lines[e.line] or ""
    local unit = M.unit(e)
    if line:sub(1, e.col):match("^[ \t]+$") and e.col >= #unit and line:sub(e.col - #unit + 1, e.col) == unit then
      M.remember(e, nil)
      e.lines[e.line] = line:sub(1, e.col - #unit) .. line:sub(e.col + 1)
      e.col = e.col - #unit
    end
  end
  M.insert(e, ch)
end

--- Tab and shift+tab: the selected lines (or the caret's) one step in or out;
--- tab with nothing selected puts one step of indentation at the caret.
function M.indent(e, out)
  local unit = M.unit(e)
  local l1, c1, l2, c2 = M.range(e)
  if not l1 and not out then
    M.insert(e, unit == "\t" and "\t" or string.rep(" ", #unit - (e.col % #unit)))
    return
  end
  l1, l2 = l1 or e.line, l2 or e.line
  if l2 > l1 and c2 == 0 then l2 = l2 - 1 end
  M.remember(e, nil)
  local anchor = e.anchor
  for i = l1, l2 do
    local line = e.lines[i] or ""
    local moved = 0
    if out then
      if line:sub(1, #unit) == unit then
        e.lines[i], moved = line:sub(#unit + 1), -#unit
      else
        local lead = line:match("^[ \t]*")
        local n = math.min(#lead, #unit)
        e.lines[i], moved = line:sub(n + 1), -n
      end
    elseif line:match("%S") then
      e.lines[i], moved = unit .. line, #unit
    end
    if i == e.line then e.col = math.max(0, e.col + moved) end
    if anchor and i == anchor.line then anchor.col = math.max(0, anchor.col + moved) end
  end
  touched(e)
end

-- ---- deleting -------------------------------------------------------------------

function M.backspace(e)
  if M.delete_selection(e) then return end
  local row = e.line
  local line = e.lines[row] or ""
  if e.col > 0 then
    M.remember(e, "delete", row)
    -- In the indentation, a step of it at a time.
    local unit = M.unit(e)
    local from
    if unit ~= "\t" and line:sub(1, e.col):match("^ +$") then
      local back = (e.col % #unit == 0) and #unit or (e.col % #unit)
      from = e.col - back
    else
      from = text.prev_offset(line, e.col)
    end
    e.lines[row] = line:sub(1, from) .. line:sub(e.col + 1)
    e.col = from
    touched(e)
  elseif row > 1 then
    M.remember(e, "join", row)
    local previous = e.lines[row - 1]
    e.lines[row - 1] = previous .. line
    table.remove(e.lines, row)
    e.line, e.col = row - 1, #previous
    touched(e)
  end
end

function M.delete(e)
  if M.delete_selection(e) then return end
  local row = e.line
  local line = e.lines[row] or ""
  if e.col < #line then
    M.remember(e, "delete", row)
    e.lines[row] = line:sub(1, e.col) .. line:sub(text.next_offset(line, e.col) + 1)
    touched(e)
  elseif row < #e.lines then
    M.remember(e, "join", row)
    e.lines[row] = line .. e.lines[row + 1]
    table.remove(e.lines, row + 1)
    touched(e)
  end
end

--- Delete back to the start of the word (ctrl+backspace).
function M.backspace_word(e)
  if M.has(e) then return M.delete_selection(e) end
  local l, c = e.line, e.col
  M.word(e, -1, false)
  if e.line == l and e.col == c then return end
  e.anchor = { line = l, col = c }
  M.delete_selection(e)
end

-- ---- moving ---------------------------------------------------------------------

function M.move(e, rows, cols, extend)
  hold(e, extend)
  e.undo_kind = nil
  if rows ~= 0 then
    e.goal = e.goal or text.chars(e.lines[e.line] or "", e.col)
    e.line = math.max(1, math.min(#e.lines, e.line + rows))
    e.col = text.after(e.lines[e.line] or "", e.goal)
    return
  end
  e.goal = nil
  local line = e.lines[e.line] or ""
  if cols < 0 then
    if e.col == 0 and e.line > 1 then
      e.line = e.line - 1
      e.col = #(e.lines[e.line] or "")
    else
      e.col = text.prev_offset(line, e.col)
    end
  elseif cols > 0 then
    if e.col >= #line and e.line < #e.lines then
      e.line, e.col = e.line + 1, 0
    else
      e.col = text.next_offset(line, e.col)
    end
  end
end

--- A selection collapsing to one of its ends, as left and right do.
function M.collapse(e, to_end)
  local l1, c1, l2, c2 = M.range(e)
  e.anchor = nil
  if not l1 then return false end
  if to_end then e.line, e.col = l2, c2 else e.line, e.col = l1, c1 end
  return true
end

local function kind_of(ch)
  if ch == "" then return "end" end
  if ch:match("[%w_]") or ch:byte() >= 128 then return "word" end
  if ch:match("%s") then return "space" end
  return "mark"
end

--- By a word: ctrl+left and ctrl+right.
function M.word(e, dir, extend)
  hold(e, extend)
  e.goal, e.undo_kind = nil, nil
  local line = e.lines[e.line] or ""
  if dir < 0 then
    if e.col == 0 then return M.move(e, 0, -1, extend) end
    local at = e.col
    while at > 0 and kind_of(line:sub(at, at)) == "space" do at = at - 1 end
    local k = kind_of(line:sub(at, at))
    while at > 0 and kind_of(line:sub(at, at)) == k do at = at - 1 end
    e.col = at
  else
    if e.col >= #line then return M.move(e, 0, 1, extend) end
    local at = e.col + 1
    local k = kind_of(line:sub(at, at))
    while at <= #line and kind_of(line:sub(at, at)) == k do at = at + 1 end
    while at <= #line and kind_of(line:sub(at, at)) == "space" do at = at + 1 end
    e.col = at - 1
  end
end

--- Home: the line's first character, then (again) its very start.
function M.home(e, extend)
  hold(e, extend)
  e.goal, e.undo_kind = nil, nil
  local line = e.lines[e.line] or ""
  local first = #(line:match("^[ \t]*"))
  e.col = (e.col == first) and 0 or first
end

function M.line_end(e, extend)
  hold(e, extend)
  e.goal, e.undo_kind = nil, nil
  e.col = #(e.lines[e.line] or "")
end

function M.edge(e, top, extend)
  hold(e, extend)
  e.goal, e.undo_kind = nil, nil
  if top then e.line, e.col = 1, 0 else e.line = #e.lines e.col = #(e.lines[e.line] or "") end
end

--- Put the caret at (line, col); with `extend` the selection follows it.
function M.place(e, line, col, extend)
  if extend then hold(e, true) else e.anchor = nil end
  e.line = math.max(1, math.min(#e.lines, line))
  e.col = math.max(0, math.min(#(e.lines[e.line] or ""), col))
  e.goal, e.undo_kind = nil, nil
end

--- The word under (line, col), selected (a double click).
function M.select_word(e, line, col)
  local s = e.lines[line] or ""
  local at = math.min(col, #s)
  local k = kind_of(s:sub(at + 1, at + 1))
  if k == "end" or k == "space" then
    if at > 0 then k = kind_of(s:sub(at, at)) end
  end
  local a, b = at, at
  while a > 0 and kind_of(s:sub(a, a)) == k do a = a - 1 end
  while b < #s and kind_of(s:sub(b + 1, b + 1)) == k do b = b + 1 end
  e.anchor = { line = line, col = a }
  e.line, e.col = line, b
end

function M.select_line(e, line)
  e.anchor = { line = line, col = 0 }
  if line < #e.lines then e.line, e.col = line + 1, 0 else e.line, e.col = line, #(e.lines[line] or "") end
end

-- ---- the matching bracket ---------------------------------------------------------

local PAIR = { ["("] = ")", ["["] = "]", ["{"] = "}", [")"] = "(", ["]"] = "[", ["}"] = "{" }
local OPEN = { ["("] = true, ["["] = true, ["{"] = true }

--- The bracket at the caret (or just before it) and the one that matches it:
--- { line, col } twice (byte offsets from 0), or nil. Brackets in strings are
--- counted as any other; it looks no further than 3000 lines.
function M.brackets(e)
  if e.bracket_key == tostring(e.version) .. ":" .. e.line .. ":" .. e.col then return e.bracket_a, e.bracket_b end
  e.bracket_key = tostring(e.version) .. ":" .. e.line .. ":" .. e.col
  e.bracket_a, e.bracket_b = nil, nil
  local line = e.lines[e.line] or ""
  local at
  local ch = line:sub(e.col + 1, e.col + 1)
  if PAIR[ch] then at = e.col else
    ch = line:sub(e.col, e.col)
    if PAIR[ch] and e.col > 0 then at = e.col - 1 else return nil end
  end
  local want, forward = PAIR[ch], OPEN[ch]
  local depth = 0
  local l, c = e.line, at
  local steps = 0
  while true do
    local s = e.lines[l] or ""
    if forward then
      local from = (l == e.line) and c + 2 or 1
      for i = from, #s do
        local x = s:sub(i, i)
        if x == ch then depth = depth + 1 elseif x == want then
          if depth == 0 then e.bracket_a, e.bracket_b = { e.line, at }, { l, i - 1 } return e.bracket_a, e.bracket_b end
          depth = depth - 1
        end
      end
      l = l + 1
      if l > #e.lines then return nil end
    else
      local from = (l == e.line) and c or #s
      for i = from, 1, -1 do
        local x = s:sub(i, i)
        if x == ch then depth = depth + 1 elseif x == want then
          if depth == 0 then e.bracket_a, e.bracket_b = { e.line, at }, { l, i - 1 } return e.bracket_a, e.bracket_b end
          depth = depth - 1
        end
      end
      l = l - 1
      if l < 1 then return nil end
    end
    steps = steps + 1
    if steps > 3000 then return nil end
  end
end

-- ---- finding ------------------------------------------------------------------------

--- Every place `term` is in the buffer: { { line, from, to } } (bytes, from 0,
--- `to` past the end). Lower case matches any case, a capital exactly. Kept
--- until the buffer or the term changes; 20000 at most.
function M.find_all(e, term)
  local f = e.find
  if not f then return {} end
  if f.key == tostring(e.version) .. "\0" .. term then return f.hits end
  f.key = tostring(e.version) .. "\0" .. term
  local hits = {}
  if term ~= "" then
    local exact = term:match("%u") ~= nil
    local needle = exact and term or term:lower()
    for i, line in ipairs(e.lines) do
      local hay = exact and line or line:lower()
      local at = 1
      while true do
        local s, t = hay:find(needle, at, true)
        if not s then break end
        hits[#hits + 1] = { i, s - 1, t }
        if #hits >= 20000 then break end
        at = t + 1
      end
      if #hits >= 20000 then break end
    end
  end
  f.hits = hits
  return hits
end

--- Go to the next place (or with `dir` -1 the one before) from the caret, and
--- select it. `from_here` counts the place the caret is on (while typing the term).
function M.find_step(e, dir, from_here)
  local f = e.find
  if not f then return nil end
  local hits = M.find_all(e, f.term or "")
  if #hits == 0 then f.at = 0 return nil end
  local l1, c1 = M.range(e)
  local line, col = l1 or e.line, c1 or e.col
  local pick
  if dir >= 0 then
    for i, h in ipairs(hits) do
      if h[1] > line or (h[1] == line and (h[2] > col or (from_here and h[2] == col))) then pick = i break end
    end
    pick = pick or 1
  else
    for i = #hits, 1, -1 do
      local h = hits[i]
      if h[1] < line or (h[1] == line and h[2] < col) then pick = i break end
    end
    pick = pick or #hits
  end
  local h = hits[pick]
  f.at = pick
  e.anchor = { line = h[1], col = h[2] }
  e.line, e.col = h[1], h[3]
  e.goal = nil
  return pick
end

return M
