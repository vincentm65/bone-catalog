-- Quick open: every file under the folder, found by a few letters of its
-- path. The list comes from ripgrep (what .gitignore keeps out stays out),
-- else Git, else find, read again when it is older than ten seconds or
-- the agent wrote something (shown as it was while that runs); the letters match in
-- order, anywhere in the path, and a match in the name, at the start of a
-- word or in one run counts for more. The files opened last come first, and
-- survive a restart (bone.state).

local M = {}

M.LIMIT = 200000 -- the most files listed
M.SHOWN = 200    -- the most results kept
M.RECENT = 50

local lists = {} -- a folder -> { at, files = { rel… }, lower = { … } }
local recent = nil

local function load_recent()
  if recent then return recent end
  local ok, saved = pcall(bone.state.load, "files-recent")
  recent = (ok and type(saved) == "table" and type(saved.paths) == "table") and saved.paths or {}
  return recent
end

--- The files opened, newest first (absolute paths).
function M.recent() return load_recent() end

--- `path` was opened: it heads the recent list.
function M.opened(path)
  local list = load_recent()
  for i = #list, 1, -1 do if list[i] == path then table.remove(list, i) end end
  table.insert(list, 1, path)
  while #list > M.RECENT do table.remove(list) end
  pcall(bone.state.save, "files-recent", { paths = list })
end

--- A path that went away (renamed, deleted) leaves the list.
function M.forget(path)
  local list = load_recent()
  local prefix = path .. "/"
  for i = #list, 1, -1 do
    if list[i] == path or list[i]:sub(1, #prefix) == prefix then table.remove(list, i) end
  end
  pcall(bone.state.save, "files-recent", { paths = list })
end

local LIST = 'if command -v rg >/dev/null 2>&1; then rg --files --hidden --no-messages -g "!.git"; '
  .. 'elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files -co --exclude-standard; '
  .. 'else find . -type f -not -path "*/.git/*" 2>/dev/null | sed "s|^\\./||"; fi | head -n ' .. M.LIMIT

--- The files under `root`, read in the background: `done()` once they are
--- there. A listing younger than a minute is used as it is.
function M.load(root, done, force)
  local held = lists[root]
  -- A listing a few seconds old is used as it is; an older one is shown
  -- while it is read again.
  if held and not force and (held.loading or os.time() - held.at < 10) then
    if not held.loading then done() end
    return held
  end
  local entry = held or { at = 0, files = {}, lower = {} }
  entry.loading = true
  lists[root] = entry
  bone.job.start(LIST, { name = "files: list", cwd = root, timeout = 20000, buffer = true,
    on_exit = function(r)
      local files, lower = {}, {}
      for line in ((r and r.stdout) or ""):gmatch("[^\n]+") do
        local rel = line:gsub("^%./", "")
        files[#files + 1] = rel
        lower[#lower + 1] = rel:lower()
      end
      table.sort(files)
      for i, f in ipairs(files) do lower[i] = f:lower() end
      entry.files, entry.lower, entry.at, entry.loading = files, lower, os.time(), false
      entry.cut = #files >= M.LIMIT
      done()
    end })
  return entry
end

function M.listing(root) return lists[root] end

--- After a file was made, renamed or deleted, the next quick open reads the
--- folder again.
function M.stale(root) if lists[root] then lists[root].at = 0 end end

local function boundary(s, i)
  if i == 1 then return true end
  local p = s:sub(i - 1, i - 1)
  return p == "/" or p == "_" or p == "-" or p == "." or p == " "
    or (s:sub(i, i):match("%u") and p:match("%l")) and true or false
end

--- How well `query` (lower case) matches `path`: a score and the matched
--- byte positions, or nil when its letters are not all there in order.
local function score(query, path, low)
  local n, m = #query, #low
  if n == 0 then return 0, {} end
  if n > m then return nil end
  local base_at = (low:match("^.*()/") or 0) + 1
  -- First a quick check that every letter is there.
  local at, first = 1, {}
  for i = 1, n do
    at = low:find(query:sub(i, i), at, true)
    if not at then return nil end
    first[i] = at
    at = at + 1
  end
  -- Then the better places for them: greedy from the end of the name back,
  -- preferring the name, the starts of words, and runs.
  local pos = {}
  local total = 0
  local j = m
  for i = n, 1, -1 do
    local ch = query:sub(i, i)
    local best, best_s
    local k = j
    -- No further back than the earliest place this letter can be: the
    -- letters before it still fit there.
    while k >= first[i] do
      if low:sub(k, k) == ch then
        local s = 1
        if k >= base_at then s = s + 2 end
        if boundary(path, k) then s = s + 3 end
        if pos[i + 1] and pos[i + 1] == k + 1 then s = s + 4 end
        if not best or s > best_s then best, best_s = k, s end
        if s >= 9 then break end
      end
      k = k - 1
    end
    if not best then return nil end
    pos[i] = best
    total = total + best_s
    j = best - 1
  end
  -- Shorter paths, and a query that is the whole name, rank higher; a file
  -- under a hidden folder lower.
  total = total - m * 0.02
  if low:sub(1, 1) == "." or low:find("/.", 1, true) then total = total - 4 end
  local name = low:sub(base_at)
  if name == query then total = total + 20
  elseif name:sub(1, n) == query then total = total + 8 end
  return total, pos
end

--- The best files for `query`, best first: { { rel, pos, score } }. With no
--- query the recent files under the folder, then the rest by name.
function M.results(root, query)
  local entry = lists[root]
  local out = {}
  local prefix = root == "/" and "/" or (root .. "/")
  local recent_rank = {}
  for i, p in ipairs(load_recent()) do
    if p:sub(1, #prefix) == prefix then recent_rank[p:sub(#prefix + 1)] = i end
  end
  query = tostring(query or ""):lower():gsub("%s+", "")
  if query == "" then
    local seen = {}
    local ranked = {}
    for rel, i in pairs(recent_rank) do ranked[#ranked + 1] = { rel = rel, i = i } end
    table.sort(ranked, function(a, b) return a.i < b.i end)
    for _, r in ipairs(ranked) do
      out[#out + 1] = { rel = r.rel, pos = {}, recent = true }
      seen[r.rel] = true
    end
    for _, rel in ipairs(entry and entry.files or {}) do
      if #out >= M.SHOWN then break end
      if not seen[rel] then out[#out + 1] = { rel = rel, pos = {} } end
    end
    return out
  end
  if not entry then return out end
  local files, lower = entry.files, entry.lower
  for i = 1, #files do
    local s, pos = score(query, files[i], lower[i])
    if s then
      local r = recent_rank[files[i]]
      if r then s = s + 6 - r * 0.1 end
      out[#out + 1] = { rel = files[i], pos = pos, score = s, recent = r ~= nil }
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return #a.rel < #b.rel
  end)
  while #out > M.SHOWN do table.remove(out) end
  return out
end

--- "path:42" means the file at line 42.
function M.split_line(query)
  local q, line = tostring(query or ""):match("^(.-):(%d+)$")
  if q then return q, tonumber(line) end
  return query, nil
end

return M
