-- The changes between two versions of the same text, as the diff widget's
-- rows. Used by the editor to show what has been done to the file since it
-- was read, without anyone running Git.
--
-- The comparison is the usual one: the longest run of lines both versions
-- share, with the lines only one of them has marked. Long stretches that
-- match are folded away, and a stretch too big to compare cell by cell is
-- counted instead of shown.

local M = {}

--- Unchanged lines kept on each side of a change.
M.KEEP = 3
--- The biggest pair of changed regions it compares line by line.
M.CELLS = 400 * 400
--- The most rows it hands back.
M.MAX_ROWS = 900

--- Where the two versions stop agreeing at the start, and at the end.
local function edges(a, b)
  local an, bn = #a, #b
  local head = 0
  while head < an and head < bn and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < an - head and tail < bn - head and a[an - tail] == b[bn - tail] do
    tail = tail + 1
  end
  return head, tail
end

--- Which lines a and b share, as a walk: "d" both, "u" only a, "l" only b.
local function walk(a, b, an, bn)
  local prev, here = {}, {}
  local from = {}
  for j = 0, bn do prev[j] = 0 end
  for i = 1, an do
    here[0] = 0
    local row = {}
    for j = 1, bn do
      if a[i] == b[j] then
        here[j] = prev[j - 1] + 1
        row[j] = "d"
      elseif prev[j] >= here[j - 1] then
        here[j] = prev[j]
        row[j] = "u"
      else
        here[j] = here[j - 1]
        row[j] = "l"
      end
    end
    from[i] = row
    prev, here = here, prev
  end
  return from
end

--- The lines that changed, oldest first: { { sign, a, b }, ... } where a and
--- b are the line numbers in the old and new version (0 when there is none).
local function changes(a, b)
  local head, tail = edges(a, b)
  local old, fresh = {}, {}
  for i = head + 1, #a - tail do old[#old + 1] = a[i] end
  for j = head + 1, #b - tail do fresh[#fresh + 1] = b[j] end
  local an, bn = #old, #fresh

  if an * bn > M.CELLS then
    -- Too big to line up exactly; count it instead.
    local out = {}
    for i = 1, an do out[#out + 1] = { sign = "-", a = head + i, b = 0 } end
    for j = 1, bn do out[#out + 1] = { sign = "+", a = 0, b = head + j } end
    return out, head, tail, true
  end

  local from = walk(old, fresh, an, bn)
  local i, j = an, bn
  local out = {}
  while i > 0 or j > 0 do
    local step = i > 0 and j > 0 and from[i][j] or (i > 0 and "u" or "l")
    if step == "d" then
      out[#out + 1] = { sign = " ", a = head + i, b = head + j, text = old[i] }
      i, j = i - 1, j - 1
    elseif step == "u" then
      out[#out + 1] = { sign = "-", a = head + i, b = 0, text = old[i] }
      i = i - 1
    else
      out[#out + 1] = { sign = "+", a = 0, b = head + j, text = fresh[j] }
      j = j - 1
    end
  end
  local back = {}
  for k = #out, 1, -1 do back[#back + 1] = out[k] end
  return back, head, tail, false
end

--- The diff widget's rows for the two versions: unchanged stretches folded,
--- an overflow row when there are too many changes to show.
function M.rows(a, b)
  local out, head, tail, rough = changes(a or {}, b or {})
  local rows, folded, held = {}, 0, 0
  local function keep(row)
    if held >= M.MAX_ROWS then return false end
    rows[#rows + 1] = row
    held = held + 1
    return true
  end
  for index, row in ipairs(out) do
    if row.sign == " " then
      local before, after = out[index - 1], out[index + 1]
      local edge = (not before or before.sign ~= " ") or (not after or after.sign ~= " ")
      if edge then folded = 0 end
      if folded < M.KEEP then
        keep({ sign = " ", text = row.text, old = row.a, new = row.b })
        folded = folded + 1
      elseif folded == M.KEEP then
        keep({ separator = true })
        folded = folded + 1
      end
    else
      if not keep({ sign = row.sign, text = row.text, old = row.a, new = row.b }) then
        rows[#rows + 1] = { text = "… and more changes than this can show" }
        return rows
      end
    end
  end
  if tail > 0 and #rows > 0 and held < M.MAX_ROWS then
    keep({ text = string.format("%d unchanged line%s at the end", tail, tail == 1 and "" or "s") })
  end
  if rough then
    rows[#rows + 1] = { text = "the changed part is too big to show line by line" }
  end
  if head > 0 and #rows > 0 then
    table.insert(rows, 1, { text = string.format("%d unchanged line%s at the top", head, head == 1 and "" or "s") })
  end
  return rows
end

--- How the two versions differ, in words: "no changes", or "3 added, 1
--- removed".
function M.summary(a, b)
  a, b = a or {}, b or {}
  local head, tail = edges(a, b)
  local removed = #a - head - tail
  local added = #b - head - tail
  if removed == 0 and added == 0 then return "no changes" end
  local parts = {}
  if added > 0 then parts[#parts + 1] = added .. " added" end
  if removed > 0 then parts[#parts + 1] = removed .. " removed" end
  return table.concat(parts, ", ")
end

return M
