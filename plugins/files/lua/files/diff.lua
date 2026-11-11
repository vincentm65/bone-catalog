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
  -- A few of the lines both share stay in the comparison, so a change at
  -- either end of the changed part has its lines around it too.
  head, tail = math.max(0, head - M.KEEP), math.max(0, tail - M.KEEP)
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

--- Inside each run of changed lines, the ones taken out first and the ones
--- put in after them, as a patch reads.
local function removals_first(out)
  local sorted, del, add = {}, {}, {}
  local function flush()
    for _, r in ipairs(del) do sorted[#sorted + 1] = r end
    for _, r in ipairs(add) do sorted[#sorted + 1] = r end
    del, add = {}, {}
  end
  for _, r in ipairs(out) do
    if r.sign == "-" then del[#del + 1] = r
    elseif r.sign == "+" then add[#add + 1] = r
    else
      flush()
      sorted[#sorted + 1] = r
    end
  end
  flush()
  return sorted
end

local function continuation(byte) return byte and byte >= 128 and byte <= 191 end

--- Where two versions of one line differ: the bytes from..to of each that
--- are its own (what is before and after is shared), or nil when they share
--- too little for that to say anything.
function M.span(old, new)
  if old == new or old == "" or new == "" then return nil end
  local on, nn = #old, #new
  local p = 0
  while p < on and p < nn and old:byte(p + 1) == new:byte(p + 1) do p = p + 1 end
  -- Never inside a character.
  while p > 0 and (continuation(old:byte(p + 1)) or continuation(new:byte(p + 1))) do p = p - 1 end
  local q = 0
  while q < on - p and q < nn - p and old:byte(on - q) == new:byte(nn - q) do q = q + 1 end
  while q > 0 and (continuation(old:byte(on - q + 1)) or continuation(new:byte(nn - q + 1))) do q = q - 1 end
  -- Indentation alone is not something shared worth showing.
  local shared = #(old:sub(1, p):gsub("^%s+", "")) + #(old:sub(on - q + 1):gsub("%s+$", ""))
  if shared < 3 or shared * 3 < math.min(on, nn) then return nil end
  return { p + 1, on - q }, { p + 1, nn - q }
end

--- A run of as many lines put in as taken out is the same lines changed:
--- each pair is marked with the part of it that differs (row.span).
local function mark_spans(out)
  local i, n = 1, #out
  while i <= n do
    if out[i].sign == "-" then
      local d0 = i
      while i <= n and out[i].sign == "-" do i = i + 1 end
      local a0 = i
      while i <= n and out[i].sign == "+" do i = i + 1 end
      local dels, adds = a0 - d0, i - a0
      if dels == adds and dels <= 40 then
        for k = 0, dels - 1 do
          local d, a = out[d0 + k], out[a0 + k]
          if d.text and a.text then d.span, a.span = M.span(d.text, a.text) end
        end
      end
    else
      i = i + 1
    end
  end
end

--- "3 added, 1 removed" for a walk of changes.
local function words(out)
  local added, removed = 0, 0
  for _, r in ipairs(out) do
    if r.sign == "+" then added = added + 1 elseif r.sign == "-" then removed = removed + 1 end
  end
  if removed == 0 and added == 0 then return "no changes" end
  local parts = {}
  if added > 0 then parts[#parts + 1] = added .. " added" end
  if removed > 0 then parts[#parts + 1] = removed .. " removed" end
  return table.concat(parts, ", ")
end

--- The diff widget's rows for the two versions: the lines taken out and put
--- in, M.KEEP unchanged lines on each side of them, the rest folded (a
--- separator row between two changes, a count at the top and the end), and
--- an overflow row when there are too many changes to show.
function M.rows(a, b)
  local out, head, tail, rough = changes(a or {}, b or {})
  out = removals_first(out)
  mark_spans(out)
  local n = #out
  -- How far each unchanged line is from the nearest change.
  local near, last, any = {}, nil, false
  for i = 1, n do
    if out[i].sign ~= " " then last, any = i, true end
    near[i] = last and (i - last) or math.huge
  end
  if not any then return {}, "no changes" end
  last = nil
  for i = n, 1, -1 do
    if out[i].sign ~= " " then last = i end
    if last then near[i] = math.min(near[i], last - i) end
  end
  local rows, held, gap, over = {}, 0, 0, false
  for i = 1, n do
    local row = out[i]
    if row.sign ~= " " or near[i] <= M.KEEP then
      if gap > 0 then
        if #rows == 0 then
          head = head + gap
        elseif gap == 1 then
          -- One line is not worth folding: a fold takes a row too.
          local one = out[i - 1]
          rows[#rows + 1] = { sign = " ", text = one.text, old = one.a, new = one.b }
          held = held + 1
        else
          rows[#rows + 1] = { separator = true, count = gap }
        end
        gap = 0
      end
      if held >= M.MAX_ROWS then
        rows[#rows + 1] = { text = "… and more changes than this can show" }
        over = true
        break
      end
      rows[#rows + 1] = { sign = row.sign, text = row.text, old = row.a, new = row.b, span = row.span }
      held = held + 1
    else
      gap = gap + 1
    end
  end
  tail = tail + gap
  if tail > 0 and not over then
    rows[#rows + 1] = { text = string.format("%d unchanged line%s at the end", tail, tail == 1 and "" or "s") }
  end
  if rough then
    rows[#rows + 1] = { text = "the changed part is too big to show line by line" }
  end
  if head > 0 then
    table.insert(rows, 1, { text = string.format("%d unchanged line%s at the top", head, head == 1 and "" or "s") })
  end
  return rows, words(out)
end

--- How the two versions differ, in words: "no changes", or "3 added, 1
--- removed" — the lines that really went and came, not the size of the part
--- they sit in.
function M.summary(a, b)
  return words((changes(a or {}, b or {})))
end

return M
