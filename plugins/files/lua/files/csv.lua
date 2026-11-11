-- A table kept as text: values with a comma (or a semicolon, a tab, a bar)
-- between them, a row a line, a value in double quotes when it holds one of
-- those itself (a quote in it written twice). Read into rows of strings and
-- written back the same way: a value that was in quotes stays in quotes, so
-- a file changed in one cell differs in one cell.

local M = {}

local CANDIDATES = { ",", ";", "\t", "|" }

--- `body` as rows: each a list of strings; row.q[c] is true for a value
--- that was written in quotes.
function M.parse(body, delim)
  delim = delim or ","
  local rows, row = {}, {}
  local n = #body
  if n == 0 then return rows end
  local stop = "[" .. delim:gsub("%p", "%%%0") .. "\n]"
  local i = 1
  while true do
    local value, quoted
    if body:sub(i, i) == '"' then
      -- In quotes: to the quote that is not written twice.
      quoted = true
      local parts, j = {}, i + 1
      while true do
        local k = body:find('"', j, true)
        if not k then
          parts[#parts + 1] = body:sub(j)
          j = n + 1
          break
        end
        parts[#parts + 1] = body:sub(j, k - 1)
        if body:sub(k + 1, k + 1) == '"' then
          parts[#parts + 1] = '"'
          j = k + 2
        else
          j = k + 1
          break
        end
      end
      -- Anything between the closing quote and the next separator is kept.
      local k = body:find(stop, j) or (n + 1)
      value = table.concat(parts) .. body:sub(j, k - 1)
      i = k
    else
      local k = body:find(stop, i) or (n + 1)
      value = body:sub(i, k - 1)
      i = k
    end
    row[#row + 1] = (value:gsub("\r$", ""))
    if quoted then
      row.q = row.q or {}
      row.q[#row] = true
    end
    if i > n then
      rows[#rows + 1] = row
      break
    end
    if body:sub(i, i) == "\n" then
      rows[#rows + 1] = row
      row = {}
      i = i + 1
      -- A last line that ends with a newline is not one more, empty row.
      if i > n then break end
    else
      i = i + 1
      if i > n then
        -- A separator at the very end: one more, empty value.
        row[#row + 1] = ""
        rows[#rows + 1] = row
        break
      end
    end
  end
  return rows
end

local function written(value, delim, keep_quotes)
  value = tostring(value or "")
  if keep_quotes or value:find(delim, 1, true) or value:find('["\n\r]') or value:match("^%s") or value:match("%s$") then
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

--- The rows as text again (no newline after the last).
function M.serialize(rows, delim)
  delim = delim or ","
  local lines = {}
  for r, row in ipairs(rows) do
    local cells = {}
    for c = 1, #row do cells[c] = written(row[c], delim, row.q and row.q[c] and row[c] ~= "") end
    lines[r] = table.concat(cells, delim)
  end
  return table.concat(lines, "\n")
end

--- What separates the values of `body`: the candidate that cuts its first
--- lines into the same number of columns, more than one (the name's
--- extension breaks a tie: .tsv is tabs).
function M.detect(body, name)
  local head = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    head[#head + 1] = line
    if #head >= 25 then break end
  end
  local sample = table.concat(head, "\n")
  local lower = tostring(name or ""):lower()
  local best, best_score = nil, 0
  for _, d in ipairs(CANDIDATES) do
    local rows = M.parse(sample, d)
    local counts, lines = {}, 0
    for _, row in ipairs(rows) do
      if not (#row == 1 and row[1] == "") then
        counts[#row] = (counts[#row] or 0) + 1
        lines = lines + 1
      end
    end
    local cols, agree = 1, 0
    for n, c in pairs(counts) do
      if c > agree or (c == agree and n > cols) then cols, agree = n, c end
    end
    -- Columns that agree across the lines, and more of them, win.
    local score = cols > 1 and (agree / math.max(1, lines)) * 100 + math.min(cols, 50) or 0
    if (d == "\t" and (lower:match("%.tsv$") or lower:match("%.tab$"))) then score = score + 1000 end
    if score > best_score then best, best_score = d, score end
  end
  return best or ((lower:match("%.tsv$") or lower:match("%.tab$")) and "\t" or ",")
end

--- The number a value is, or nil: 12, -3.5, 1e6, 1,234.50, $12, 45%.
function M.number(value)
  local s = tostring(value or ""):match("^%s*(.-)%s*$")
  if s == "" then return nil end
  local n = tonumber(s)
  if n then return n end
  s = s:gsub("^([%-%+]?)[%$€£¥]", "%1"):gsub("%%$", "")
  if s:match("^[%-%+]?%d%d?%d?,%d%d%d") then s = s:gsub(",", "") end
  return tonumber(s)
end

--- The most columns any row has.
function M.columns(rows)
  local n = 0
  for _, row in ipairs(rows) do if #row > n then n = #row end end
  return n
end

--- The name of column `c` as a sheet letters it: A, B … Z, AA.
function M.letter(c)
  local out = ""
  while c > 0 do
    local k = (c - 1) % 26
    out = string.char(65 + k) .. out
    c = math.floor((c - 1) / 26)
  end
  return out
end

--- Order `rows[from..]` by column `c`: numbers by size before words by
--- letters, empty values last; `desc` the other way round (empty still
--- last). Rows that compare equal keep their order.
function M.sort(rows, c, desc, from)
  from = from or 1
  local part = {}
  for i = from, #rows do part[#part + 1] = { row = rows[i], at = i } end
  local function key(row)
    local v = row[c] or ""
    if v:match("^%s*$") then return 3, 0, "" end
    local n = M.number(v)
    if n then return 1, n, "" end
    return 2, 0, v:lower()
  end
  table.sort(part, function(x, y)
    local xk, xn, xs = key(x.row)
    local yk, yn, ys = key(y.row)
    if (xk == 3) ~= (yk == 3) then return yk == 3 end
    if xk ~= yk then
      if desc then return xk > yk end
      return xk < yk
    end
    if xn ~= yn then
      if desc then return xn > yn end
      return xn < yn
    end
    if xs ~= ys then
      if desc then return xs > ys end
      return xs < ys
    end
    return x.at < y.at
  end)
  for k, p in ipairs(part) do rows[from + k - 1] = p.row end
end

--- What column `c` of `rows` (the indexes in `which`) adds up to:
--- { filled, numbers, sum, min, max }.
function M.stats(rows, which, c)
  local out = { filled = 0, numbers = 0, sum = 0 }
  for _, i in ipairs(which) do
    local v = rows[i] and rows[i][c] or ""
    if not v:match("^%s*$") then
      out.filled = out.filled + 1
      local n = M.number(v)
      if n then
        out.numbers = out.numbers + 1
        out.sum = out.sum + n
        if not out.min or n < out.min then out.min = n end
        if not out.max or n > out.max then out.max = n end
      end
    end
  end
  return out
end

return M
