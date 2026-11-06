-- The editor's change bars: each line of the buffer against the file as Git
-- has it (HEAD), as an editor's gutter shows them — added, changed, or a
-- line removed after it. HEAD's text is asked of Git once per file (a plugin
-- job); the comparison is a Myers diff of the two, kept until the buffer
-- changes, so typing costs a comparison of the lines around what changed.

local M = {}

M.MAX_D = 4000 -- past this many differences the file is marked as all new

local function quoted(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end

--- Ask Git for `path` as HEAD has it, into e.head: a list of lines, or false
--- when Git has no such file (new, untracked, not a repository). `done()`
--- after, when it came.
function M.fetch(e, done)
  if e.head ~= nil or e.head_asked then return end
  e.head_asked = true
  local path = e.path
  local dir, name = path:match("^(.*)/([^/]+)$")
  if not dir then return end
  -- Not in HEAD: a file Git does not track yet (and does not ignore) is all
  -- new, as Git sees it (exit 7); anything else (no repository) has no bars.
  local q = quoted(name)
  bone.job.start("git --no-pager show HEAD:./" .. q .. " 2>/dev/null || { "
    .. "git rev-parse --is-inside-work-tree >/dev/null 2>&1 "
    .. "&& ! git ls-files --error-unmatch -- " .. q .. " >/dev/null 2>&1 "
    .. "&& ! git check-ignore -q -- " .. q .. " && exit 7; exit 1; }", {
    name = "files: git head", cwd = dir ~= "" and dir or "/", timeout = 6000, buffer = true,
    on_exit = function(r)
      if e.path ~= path then return end
      if r and r.code == 0 then
        local lines = {}
        local body = (r.stdout or ""):gsub("\r\n", "\n")
        for line in (body .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        if body:sub(-1) == "\n" then lines[#lines] = nil end
        e.head = lines
      elseif r and r.code == 7 then
        e.head = {}
      else
        e.head = false
      end
      e.marks_key = nil
      if done then done() end
    end })
end

--- Forget HEAD's text (after a save, a commit may follow; after a reload).
function M.refresh(e)
  e.head, e.head_asked, e.marks_key = nil, nil, nil
end

-- Myers' O(ND) diff of a[a0+1..a1] against b[b0+1..b1], as marks on b's
-- lines: marks[j] = "add" for a line only b has, marks.del[j] for a line of
-- a's taken out just above b's line j. False past MAX_D differences.
local function myers(a, b, a0, a1, b0, b1, marks)
  local n, m = a1 - a0, b1 - b0
  if n + m == 0 then return true end
  local v = { [1] = 0 }
  local trace = {}
  local limit = math.min(n + m, M.MAX_D)
  local found
  for d = 0, limit do
    local snap = {}
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[k - 1] or -1) < (v[k + 1] or -1)) then
        x = v[k + 1] or 0
      else
        x = (v[k - 1] or 0) + 1
      end
      local y = x - k
      while x < n and y < m and a[a0 + x + 1] == b[b0 + y + 1] do x, y = x + 1, y + 1 end
      v[k], snap[k] = x, x
      if x >= n and y >= m then found = d break end
    end
    trace[d] = snap
    if found then break end
  end
  if not found then return false end
  local x, y = n, m
  for d = found, 1, -1 do
    local prev = trace[d - 1]
    local k = x - y
    local pk
    if k == -d or (k ~= d and (prev[k - 1] or -1) < (prev[k + 1] or -1)) then pk = k + 1 else pk = k - 1 end
    local px = prev[pk] or 0
    local py = px - pk
    while x > px and y > py and (x - px) + (y - py) > 1 do x, y = x - 1, y - 1 end
    if x == px then
      marks[b0 + y] = "add"          -- b's line y came in
    else
      marks.del = marks.del or {}
      marks.del[b0 + y + 1] = true   -- a's line x went, above b's line y+1
    end
    x, y = px, py
  end
  return true
end

--- The marks for the buffer: marks[line] = "add" | "mod", marks.del[line] =
--- true where lines were taken out just above `line`. nil while HEAD's text
--- is not known, or outside a repository; a file Git does not track yet is
--- all added.
function M.marks(e)
  if not e.head then return nil end
  local key = tostring(e.version or 0)
  if e.marks_key == key then return e.marks end
  e.marks_key = key
  local a, b = e.head, e.lines
  local an, bn = #a, #b
  local head = 0
  while head < an and head < bn and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < an - head and tail < bn - head and a[an - tail] == b[bn - tail] do tail = tail + 1 end
  local marks = {}
  if not myers(a, b, head, an - tail, head, bn - tail, marks) then
    for i = head + 1, bn - tail do marks[i] = "mod" end
  end
  -- A line added where one was taken out is a changed line.
  if marks.del then
    for at in pairs(marks.del) do
      local i = at
      local changed = false
      while marks[i] == "add" do marks[i] = "mod" changed = true i = i + 1 end
      if changed then marks.del[at] = nil end
    end
    if next(marks.del) == nil then marks.del = nil end
  end
  e.marks = marks
  return marks
end

return M
