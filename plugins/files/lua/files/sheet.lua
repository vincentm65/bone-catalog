-- A CSV file as a table to look at and to change: a cell under the keys,
-- values edited in place, rows and columns put in and taken out, the rows
-- ordered by a column, shown only when they hold a word, and what a column
-- of numbers adds up to. The table is a way of looking at the editor's own
-- text: every change is written back into the buffer as CSV (files.csv), so
-- saving, undo, the changes against Git and the check before overwriting are
-- the editor's, unchanged.
--
-- M.of(e) gives the table of editor `e`; M.key(e, key, env) is its keys.
-- Nothing here draws: files.tlook and files.look do, from the same state.

local csv = require("files.csv")
local text = require("files.text")
local buffer = require("files.buffer")

local M = {}

--- Past this the table is not made (the text is still there to edit).
M.MAX_BYTES = 4 * 1024 * 1024
M.PAGE = 20

--- Whether a file of this name opens as a table.
function M.is(name)
  local lower = tostring(name or ""):lower()
  return lower:match("%.csv$") ~= nil or lower:match("%.tsv$") ~= nil or lower:match("%.tab$") ~= nil
    or lower:match("%.psv$") ~= nil
end

--- The rows shown: every data row, or with a filter those that hold it.
local function refilter(t)
  local view = {}
  local first = t.header and 2 or 1
  local needle = (t.filter or ""):lower()
  for i = first, #t.rows do
    if needle == "" then
      view[#view + 1] = i
    else
      for _, v in ipairs(t.rows[i]) do
        if v:lower():find(needle, 1, true) then
          view[#view + 1] = i
          break
        end
      end
    end
  end
  t.view = view
  t.r = math.max(t.header and 0 or 1, math.min(t.r or 1, math.max(#view, t.header and 0 or 1)))
  if #view == 0 and not t.header then t.r = 1 end
  t.c = math.max(1, math.min(t.c or 1, math.max(1, t.cols)))
end

--- The editor's table, read again from its text whenever the text moved.
function M.of(e)
  local t = e.sheet
  if t and t.version == e.version then return t end
  local old = t or {}
  local body = text.join(e.lines, false)
  t = { version = e.version, r = old.r, c = old.c, top = old.top or 1, left = old.left or 1, filter = old.filter or "",
    header = old.header, sorted = old.sorted, edit = nil, filtering = old.filtering }
  if #body > M.MAX_BYTES then
    t.too_big, t.rows, t.cols, t.view, t.delim = true, {}, 0, {}, ","
    e.sheet = t
    return t
  end
  t.delim = old.delim or csv.detect(body, e.path)
  t.rows = csv.parse(body, t.delim)
  t.cols = csv.columns(t.rows)
  -- The first row names the columns unless it looks like the rest: a row
  -- with a number in it, over rows of numbers in the same place, is data.
  if t.header == nil then
    t.header = #t.rows > 1
    if t.header then
      for c, v in ipairs(t.rows[1]) do
        if csv.number(v) and csv.number(t.rows[2][c] or "") then t.header = false break end
      end
    end
  end
  if t.r == nil then t.r = (#t.rows > (t.header and 1 or 0)) and 1 or (t.header and 0 or 1) end
  refilter(t)
  e.sheet = t
  return t
end

--- The row of `t.rows` under the keys (the header's is 1), or nil.
function M.row_at(t, r)
  r = r or t.r
  if r == 0 then return t.header and 1 or nil end
  return t.view[r]
end

function M.value(t, r, c)
  local i = M.row_at(t, r)
  return i and t.rows[i] and t.rows[i][c or t.c] or ""
end

--- The table written back into the editor's text, as one step to take back.
local function commit(e, t, env)
  buffer.remember(e, nil)
  local lines = text.split(csv.serialize(t.rows, t.delim))
  e.lines = lines
  e.line, e.col, e.anchor = math.min(e.line or 1, #lines), 0, nil
  buffer.touched(e)
  t.version = e.version
  t.cols = csv.columns(t.rows)
  t.chars = nil -- the widths the desktop measured
  refilter(t)
  if env and env.changed then env.changed() end
end

local function set(t, i, c, value)
  local row = t.rows[i]
  if not row then return end
  for k = #row + 1, c do row[k] = "" end
  row[c] = value
  if row.q then row.q[c] = nil end
end

--- Put `value` in the cell under the keys.
function M.put(e, value, env)
  local t = M.of(e)
  local i = M.row_at(t)
  if not i then
    -- An empty table: its first row.
    t.rows[#t.rows + 1] = {}
    i = #t.rows
  end
  if (t.rows[i][t.c] or "") == value then return end
  set(t, i, t.c, value)
  commit(e, t, env)
end

--- A block of text (tabs between values, a line a row: what a sheet
--- copies) put in from the cell under the keys on.
function M.paste(e, block, env)
  local t = M.of(e)
  block = tostring(block or ""):gsub("\r\n", "\n"):gsub("\n$", "")
  if not block:find("[\t\n]") then return M.put(e, block, env) end
  local r = t.r
  for line in (block .. "\n"):gmatch("(.-)\n") do
    local i = M.row_at(t, r)
    if not i then
      t.rows[#t.rows + 1] = {}
      i = #t.rows
      t.view[#t.view + 1] = i
    end
    local c = t.c
    for value in (line .. "\t"):gmatch("(.-)\t") do
      set(t, i, c, value)
      c = c + 1
    end
    r = r + 1
  end
  commit(e, t, env)
end

local function move(t, dr, dc)
  local low = t.header and 0 or 1
  t.r = math.max(low, math.min(math.max(#t.view, low), t.r + dr))
  t.c = math.max(1, math.min(math.max(1, t.cols), t.c + dc))
end
M.move = move

--- Put the keys on a cell (a press): view row `r` (0: the header), column `c`.
function M.go(e, r, c)
  local t = M.of(e)
  t.edit = nil
  t.r, t.c = r, c
  move(t, 0, 0)
end

local function begin_edit(t, value)
  t.edit = { value = value }
end

--- The table's keys. `env`: changed(), note(text), copy(text),
--- paste(fn(text)), undo(), redo(). True when the key was the table's.
function M.key(e, k, env)
  local t = M.of(e)
  if t.too_big then return false end
  local lower = k:lower()

  -- A value being typed.
  if t.edit then
    local ed = t.edit
    if k == "esc" then
      t.edit = nil
    elseif k == "enter" or k == "down" or k == "up" or k == "tab" or lower == "shift+tab" or k == "backtab" then
      t.edit = nil
      M.put(e, ed.value, env)
      t = M.of(e)
      if k == "enter" or k == "down" then move(t, 1, 0)
      elseif k == "up" then move(t, -1, 0)
      elseif k == "tab" then move(t, 0, 1)
      else move(t, 0, -1) end
    else
      local v = bone.text.edit(ed.value, k == "space" and " " or k)
      if v then ed.value = v end
    end
    return true
  end

  -- The word the rows must hold.
  if t.filtering then
    if k == "esc" then
      t.filtering, t.filter = false, ""
    elseif k == "enter" or k == "down" then
      t.filtering = false
    else
      local v = bone.text.edit(t.filter, k == "space" and " " or k)
      if not v then return true end
      t.filter = v
    end
    t.r = 1
    refilter(t)
    return true
  end

  if k == "up" then move(t, -1, 0)
  elseif k == "down" then move(t, 1, 0)
  elseif k == "left" then move(t, 0, -1)
  elseif k == "right" then move(t, 0, 1)
  elseif k == "tab" then
    if t.c >= t.cols then t.c = 1 move(t, 1, 0) else move(t, 0, 1) end
  elseif lower == "shift+tab" or k == "backtab" then
    if t.c <= 1 then t.c = t.cols move(t, -1, 0) else move(t, 0, -1) end
  elseif k == "home" then t.c = 1
  elseif k == "end" then t.c = math.max(1, t.cols)
  elseif lower == "ctrl+home" then t.r, t.c = t.header and 0 or 1, 1 move(t, 0, 0)
  elseif lower == "ctrl+end" then t.r, t.c = #t.view, math.max(1, t.cols) move(t, 0, 0)
  elseif k == "pageup" then move(t, -M.PAGE, 0)
  elseif k == "pagedown" then move(t, M.PAGE, 0)
  elseif k == "enter" or k == "i" or k == "f2" then
    begin_edit(t, M.value(t))
  elseif k == "c" then
    begin_edit(t, "")
  elseif k == "delete" or k == "x" then
    M.put(e, "", env)
  elseif k == "o" or k == "O" then
    -- A row under (or over) the one the keys are on.
    local i = M.row_at(t) or #t.rows
    if k == "O" and t.r == 0 then return true end
    local at = (k == "o") and (i + 1) or i
    local row = {}
    for c = 1, t.cols do row[c] = "" end
    table.insert(t.rows, at, row)
    local filtered = t.filter ~= ""
    if filtered then t.filter = "" end
    commit(e, t, env)
    t = M.of(e)
    for r, idx in ipairs(t.view) do if idx == at then t.r = r break end end
    if env.note then env.note(filtered and "Row added · the filter was cleared to show it" or "Row added") end
  elseif k == "D" then
    local i = M.row_at(t)
    if i and not (t.r == 0) then
      table.remove(t.rows, i)
      commit(e, t, env)
      if env.note then env.note("Row removed · u takes it back") end
    end
  elseif k == "A" then
    -- A column after the one the keys are on.
    local at = t.c + 1
    for _, row in ipairs(t.rows) do
      for c = #row + 1, t.c do row[c] = "" end
      table.insert(row, at, "")
      if row.q then
        local q = {}
        for c, v in pairs(row.q) do q[c >= at and c + 1 or c] = v end
        row.q = q
      end
    end
    commit(e, t, env)
    t = M.of(e)
    t.c = at
    if env.note then env.note("Column added") end
  elseif k == "X" then
    if t.cols > 0 then
      local at = t.c
      for _, row in ipairs(t.rows) do
        if #row >= at then table.remove(row, at) end
        if row.q then
          local q = {}
          for c, v in pairs(row.q) do if c ~= at then q[c > at and c - 1 or c] = v end end
          row.q = q
        end
      end
      commit(e, t, env)
      if env.note then env.note("Column removed · u takes it back") end
    end
  elseif k == "s" then
    -- Order the rows by this column; again turns it round.
    local desc = t.sorted and t.sorted.c == t.c and not t.sorted.desc
    csv.sort(t.rows, t.c, desc, t.header and 2 or 1)
    t.sorted = { c = t.c, desc = desc }
    commit(e, t, env)
    if env.note then env.note("Sorted by " .. M.name(t, t.c) .. (desc and ", the largest first" or "") .. " · u takes it back") end
  elseif k == "H" then
    t.header = not t.header
    if t.header and t.r == 1 then t.r = 1 end
    refilter(t)
    if env.note then env.note(t.header and "The first row names the columns" or "The first row is data") end
  elseif k == "f" or k == "/" then
    t.filtering = true
  elseif k == "y" then
    if env.copy then env.copy(M.value(t)) end
  elseif k == "Y" then
    local i = M.row_at(t)
    if i and env.copy then env.copy(table.concat(t.rows[i], "\t")) end
  elseif k == "p" or lower == "ctrl+v" then
    if env.paste then env.paste(function(v) if v and v ~= "" then M.paste(e, v, env) end end) end
  elseif lower == "ctrl+c" then
    if env.copy then env.copy(M.value(t)) end
  elseif k == "u" or lower == "ctrl+z" then
    if env.undo then env.undo() end
  elseif lower == "ctrl+y" or lower == "ctrl+r" or lower == "ctrl+shift+z" then
    if env.redo then env.redo() end
  elseif k == "esc" and t.filter ~= "" then
    t.filter = ""
    refilter(t)
  elseif #k == 1 and k:match("[%d%-%+%.=%$%(]") then
    -- A digit (or a sign) starts a new value, as a sheet takes numbers.
    begin_edit(t, k)
  else
    return false
  end
  return true
end

--- What column `c` is called: its name in the first row, or its letter.
function M.name(t, c)
  if t.header and t.rows[1] and (t.rows[1][c] or "") ~= "" then return t.rows[1][c] end
  return csv.letter(c)
end

--- What stands under the table: where the keys are, how much is shown, and
--- what the column adds up to when it holds numbers.
function M.status(t)
  local parts = {}
  local total = #t.rows - (t.header and 1 or 0)
  parts[#parts + 1] = (t.r == 0 and "header" or ("row " .. t.r)) .. " · " .. M.name(t, t.c)
  parts[#parts + 1] = (t.filter ~= "" and (#t.view .. " of " .. total) or tostring(total)) .. (total == 1 and " row" or " rows")
    .. " × " .. t.cols
  local st = csv.stats(t.rows, t.view, t.c)
  if st.numbers > 0 then
    local function n(v) return (string.format("%.6g", v)) end
    parts[#parts + 1] = "sum " .. n(st.sum) .. " · avg " .. n(st.sum / st.numbers) .. " · min " .. n(st.min) .. " · max " .. n(st.max)
      .. (st.numbers < st.filled and (" (" .. st.numbers .. " of " .. st.filled .. " are numbers)") or "")
  elseif st.filled > 0 then
    parts[#parts + 1] = st.filled .. " filled"
  end
  return table.concat(parts, "   ")
end

--- How wide each column from `left` is drawn, in cells, for the rows
--- `from`..`to` of the view (and the header): the widest value, between 4
--- and 28.
function M.widths(t, from, to, width_of)
  local out = {}
  for c = 1, t.cols do
    local w = math.max(4, width_of(M.name(t, c)))
    for r = from, to do
      local i = t.view[r]
      if i then w = math.max(w, width_of((t.rows[i][c] or ""):gsub("\n", "⏎"))) end
    end
    out[c] = math.min(28, w)
  end
  return out
end

return M
