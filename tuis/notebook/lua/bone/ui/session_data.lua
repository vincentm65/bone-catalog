-- Session data for a custom session browser, kept apart from how it is drawn.
-- Shared verbatim by the notebook, zen and prism libraries.
--
--   local D = require("bone.ui.session_data")
--   local feed = D.open(function() ... end)   -- called whenever data changes
--   feed.sessions  -- { session_id, title, cwd, created_at, at, tokens, turns,
--                  --   tools, tool_errors, live, archived, current }
--   feed.jobs()    -- running background shells and sub-agents
--   feed.days      -- { [day number] = user messages } for the last 35 days
--   feed.loading, feed.stats_loading
--   feed:close()
--   D.archive_current(id), D.cancel(job), D.ago(at), D.tokens(n)

local M = {}
local agents = require("bone.agents")

local live, touched = {}, {}
local shells = {}
local archived = bone.state.load("sessions-archived")
local feed -- the open one, if any

function M.tokens(n)
  n = tonumber(n) or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

function M.ago(at)
  if not at or at <= 0 then return "" end
  local age = math.max(0, os.time() - at)
  if age < 60 then return "now" end
  if age < 3600 then return math.floor(age / 60) .. "m" end
  if age < 86400 then return math.floor(age / 3600) .. "h" end
  if age < 7 * 86400 then return math.floor(age / 86400) .. "d" end
  return os.date(os.date("%Y", at) == os.date("%Y") and "%b %d" or "%b %d %Y", at)
end

function M.archive_current(id)
  id = id or (bone.chat.session() or {}).session_id
  if not id then return end
  archived[id] = true
  bone.state.save("sessions-archived", archived)
  if feed then feed:rebuild() end
end

function M.cancel(job)
  if job.shell then
    bone.request("process/cancel", { session_id = job.session_id, id = job.shell.id })
  else
    bone.request("turn/cancel", { session_id = job.session_id })
  end
end

local Feed = {}
Feed.__index = Feed

function Feed:changed()
  if self.closed then return end
  self:rebuild()
  if self.on_change then pcall(self.on_change) end
end

-- Merge the session list with its stats and live state.
function Feed:rebuild()
  local current = (bone.chat.session() or {}).session_id
  for _, s in ipairs(bone.chat.sessions()) do
    if s.session_id and s.running then live[s.session_id] = true end
  end
  local out = {}
  for _, s in ipairs(self.list) do
    local st = self.stats[s.session_id] or {}
    local id = s.session_id
    out[#out + 1] = {
      session_id = id,
      title = (s.title and s.title:gsub("%s+", " ")) or "untitled",
      cwd = s.cwd or "",
      created_at = s.created_at or 0,
      at = math.max(touched[id] or 0, st.at or 0, s.created_at or 0),
      tokens = st.tokens or 0,
      turns = st.turns or 0,
      tools = st.tools or 0,
      tool_errors = st.errors or 0,
      live = live[id] or false,
      archived = archived[id] or false,
      current = id == current,
    }
  end
  table.sort(out, function(a, b)
    if a.live ~= b.live then return a.live end
    if a.at ~= b.at then return a.at > b.at end
    return a.session_id < b.session_id
  end)
  self.sessions = out
end

function Feed:jobs()
  local out = {}
  for _, p in pairs(shells) do
    out[#out + 1] = { key = "shell:" .. p.id, shell = p, session_id = p.session_id,
      title = p.command or p.id, detail = p.tail or "", started = math.floor((p.started_at_ms or 0) / 1000) }
  end
  for _, a in ipairs(agents.list()) do
    if live[a.id] then
      touched[a.id] = touched[a.id] or os.time()
      out[#out + 1] = { key = "agent:" .. a.id, session_id = a.id, agent = true,
        title = a.name .. " · " .. (a.title or "sub-agent"), detail = "running", started = touched[a.id] }
    end
  end
  table.sort(out, function(a, b) return (a.started or 0) < (b.started or 0) end)
  return out
end

function Feed:refresh_list()
  bone.request("session/list", {}, function(list, err)
    if self.closed then return end
    self.loading = false
    if err then
      bone.notify("cannot list sessions: " .. tostring(err), "error")
    else
      self.list = {}
      for _, s in ipairs(list or {}) do
        if s.owner then agents.add(s) else self.list[#self.list + 1] = s end
      end
    end
    self:changed()
  end)
end

function Feed:refresh_stats()
  -- Aggregate each table on its own: joining them first multiplies totals.
  bone.request("store/query", { sql = [[
    SELECT s.id, s.updated_at, coalesce(u.tokens, 0), coalesce(m.turns, 0),
           coalesce(t.calls, 0), coalesce(t.errors, 0)
    FROM sessions s
    LEFT JOIN (SELECT session_id, sum(input_tokens + output_tokens) AS tokens
               FROM usage GROUP BY session_id) u ON u.session_id = s.id
    LEFT JOIN (SELECT session_id, count(*) AS turns FROM messages
               WHERE role = 'user' GROUP BY session_id) m ON m.session_id = s.id
    LEFT JOIN (SELECT session_id, count(*) AS calls, sum(coalesce(is_error, 0)) AS errors
               FROM tool_calls GROUP BY session_id) t ON t.session_id = s.id
  ]] }, function(res, err)
    if self.closed then return end
    self.stats_loading = false
    if not err and res then
      for _, r in ipairs(res.rows or {}) do
        self.stats[r[1]] = { at = r[2], tokens = r[3], turns = r[4], tools = r[5], errors = r[6] }
      end
    end
    self:changed()
  end)
  local since = os.time() - 35 * 86400
  bone.request("store/query", { sql = string.format([[
    SELECT at / 86400, count(*) FROM messages
    WHERE role = 'user' AND at >= %d GROUP BY at / 86400
  ]], since) }, function(res, err)
    if self.closed or err or not res then return end
    self.days = {}
    for _, r in ipairs(res.rows or {}) do self.days[tonumber(r[1])] = tonumber(r[2]) end
    self:changed()
  end)
end

function Feed:close()
  self.closed = true
  if feed == self then feed = nil end
end

function M.open(on_change)
  if feed then feed:close() end
  local f = setmetatable({ list = {}, stats = {}, sessions = {}, days = {}, loading = true,
    stats_loading = true, on_change = on_change }, Feed)
  feed = f
  f:refresh_list()
  f:refresh_stats()
  bone.request("processes/list", {}, function(res, err)
    if err or not res then return end
    shells = {}
    for _, p in ipairs(res.processes or {}) do
      if p.running and p.terminal then shells[p.id] = p end
    end
    f:changed()
  end)
  bone.request("session/active", {}, function(ids, err)
    if err then return end
    for _, id in ipairs(ids or {}) do live[id] = true end
    f:changed()
  end)
  return f
end

local function turn_changed(ev, running)
  local id = ev.session_id
  if not id then return end
  live[id], touched[id] = running, os.time()
  if running and archived[id] then
    archived[id] = nil
    bone.state.save("sessions-archived", archived)
  end
  if feed then
    if running then feed:refresh_list() end
    feed:refresh_stats()
    feed:changed()
  end
end
bone.on("turn/started", function(ev) turn_changed(ev, true) end)
bone.on("turn/finished", function(ev) turn_changed(ev, false) end)
bone.on("session/created", function() if feed then feed:refresh_list() end end)
bone.on("session/updated", function() if feed then feed:refresh_list() end end)
bone.on("session/deleted", function(ev)
  live[ev.session_id], touched[ev.session_id] = nil, nil
  for id, p in pairs(shells) do
    if p.session_id == ev.session_id then shells[id] = nil end
  end
  if feed then feed:refresh_list() end
end)
bone.on("process/changed", function(ev)
  local p = ev.process or {}
  if p.running and p.terminal then
    shells[p.id] = p
  elseif shells[p.id] then
    shells[p.id] = nil
  else
    return
  end
  if feed then feed:changed() end
end)
bone.on("chat/shown", function() if feed then feed:changed() end end)

return M
