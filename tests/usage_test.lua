-- Run from catalog root: luajit tests/usage_test.lua
local commands, requests, popup, updates = {}, {}, nil, 0
local now = 1791374400
local session = { session_id = "current-chat" }
local real_time, real_date = os.time, os.date
os.time = function(t) return t and real_time(t) or now end
os.date = function(fmt, t) return real_date(fmt, t or now) end
bone = {
  chat = { session = function() return session end },
  cmd = { create = function(name, fn) commands[name] = fn end },
  hl = { get = function() return {} end, set = function() end },
  text = {
    width = function(s) return #(s:gsub("[\128-\191]", "")) end,
    truncate = function(s, w) return s:sub(1, w) end,
  },
  request = function(method, params, callback)
    assert(method == "store/query")
    requests[#requests + 1] = { params = params, callback = callback }
  end,
  ui = {
    popup = function(spec) popup = spec; return 1 end,
    update = function() updates = updates + 1 end,
    close = function() end,
  },
  notify = function(text) error(text) end,
}
dofile("plugins/usage/tui.lua")
assert(commands.usage == commands.stats)
commands.usage({ args = "week" })
assert(#requests == 9)
local sessions_sql, conversation_sql
for _, req in ipairs(requests) do
  if req.params.sql:find("u.tokens, u.calls", 1, true) then sessions_sql = req.params.sql end
  if req.params.sql:find("FROM usage WHERE session_id = ?1", 1, true) then
    conversation_sql = req.params.sql
    assert(#req.params.params == 1 and req.params.params[1] == "current-chat")
  end
end
assert(sessions_sql)
if arg[1] == "--sql" then print(sessions_sql); return end
assert(conversation_sql)
if arg[1] == "--conversation-sql" then print(conversation_sql); return end

local function daily_count(first)
  local n = 0
  for i = first or 1, #requests do
    if requests[i].params.sql:find("AS d,", 1, true) then n = n + 1 end
  end
  return n
end
local function finish(first, err)
  -- Reverse order to exercise asynchronous completion.
  for i = #requests, first or 1, -1 do
    local rows = requests[i].params.sql == conversation_sql and { { 4, 1000, 200, 400, 2, 1, 3, 1 } } or {}
    requests[i].callback({ rows = rows }, err)
  end
end
local builds = 0
for i = 1, 30 do
  local name, fn = debug.getupvalue(popup.lines, i)
  if not name then break end
  if name == "body" then
    debug.setupvalue(popup.lines, i, function(...)
      builds = builds + 1
      return fn(...)
    end)
    break
  end
end
local function render(w, h) return popup.lines({ width = w or 80, height = h or 24 }) end
local function text(lines)
  local out = {}
  for _, line in ipairs(lines) do
    for _, span in ipairs(line) do out[#out + 1] = span[1] end
  end
  return table.concat(out, "\n")
end
assert(text(render()):find("loading", 1, true))
assert(builds == 0)
finish()
local initial = text(render())
assert(builds == 1 and initial:find("Tokens", 1, true))
assert(initial:find("Current conversation", 1, true))
assert(text(render(140, 40)):find("User turns", 1, true))
render(); builds = 1 -- Return to the initial viewport for the cache checks.
for _ = 1, 100 do popup.on_key("j"); render(); popup.on_key("k"); render() end
assert(builds == 1, "scroll must not rebuild the dashboard")
popup.on_key("home")
assert(text(render()) == initial, "cached lines must not accumulate mutations")
popup.on_key("t"); render(); popup.on_key("esc"); render()
assert(builds == 1, "date entry must not rebuild sections")
render(140); assert(builds == 2)
render(140, 40); assert(builds == 3)
render(140, 40); assert(builds == 3)
now = now + 3600
render(140, 40); assert(builds == 4, "time-dependent highlights must expire")

local first = #requests + 1
popup.on_key("3")
assert(#requests - first + 1 == 8 and daily_count(first) == 0, "period switches reuse activity")
finish(first); render(140, 40); assert(builds == 5)
first = #requests + 1
popup.on_key("r")
assert(#requests - first + 1 == 9 and daily_count(first) == 1, "refresh reloads activity")
finish(first); render(140, 40); assert(builds == 6)

now = now + 86400
first = #requests + 1
popup.on_key("4")
assert(daily_count(first) == 1, "activity expires on a new local day")
finish(first); render(140, 40); assert(builds == 7)

-- Superseded loads cannot replace the current data or trigger redraws.
first = #requests + 1
popup.on_key("2")
local last = #requests
popup.on_key("5")
local before = updates
for i = first, last do requests[i].callback(nil, { message = "stale" }) end
assert(updates == before)
finish(last + 1)
assert(daily_count(last + 1) == 0)
assert(#requests - last == 7, "all-time has no previous-period query")
assert(not text(render()):find("stale", 1, true))

first = #requests + 1
popup.on_key("r")
finish(first, { message = "query failed" })
assert(text(render()):find("query failed", 1, true))
first = #requests + 1
popup.on_key("r")
assert(daily_count(first) == 1)
finish(first)
assert(not text(render()):find("query failed", 1, true))

-- Reopening starts fresh, rather than sharing stale activity across popups.
first = #requests + 1
commands.stats({ args = "today" })
assert(#requests - first + 1 == 9 and daily_count(first) == 1)
finish(first)
assert(text(render()):find("Current conversation", 1, true))
-- With no current chat, retain the global dashboard and never query sessionless usage.
session = nil
first = #requests + 1
commands.stats({ args = "week" })
assert(#requests - first + 1 == 8)
finish(first)
assert(not text(render()):find("Current conversation", 1, true))
print("usage dashboard tests passed")
