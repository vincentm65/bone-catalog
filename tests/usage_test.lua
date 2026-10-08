-- Run from catalog root: luajit tests/usage_test.lua
local commands, requests, popup, updates = {}, {}, nil, 0
local now = 1791374400
local session = { session_id = "current-chat" }
local real_time, real_date = os.time, os.date
os.time = function(t) return t and real_time(t) or now end
os.date = function(fmt, t) return real_date(fmt, t or now) end
local handlers, next_handler = {}, 0
local function fire(name, ev)
  local copy = {}
  for id, h in pairs(handlers) do if h.name == name then copy[id] = h.fn end end
  for _, fn in pairs(copy) do fn(ev) end
end
bone = {
  on = function(name, fn) next_handler = next_handler + 1; handlers[next_handler] = { name = name, fn = fn }; return next_handler end,
  off = function(id) handlers[id] = nil end,
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
    popup = function(spec) if popup then fire("panel/closed", { id = 1 }) end; popup = spec; return 1 end,
    update = function() updates = updates + 1 end,
    close = function(id) fire("panel/closed", { id = id }) end,
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
    if requests[i].params.sql:find("FROM usage WHERE at >=", 1, true) and requests[i].params.sql:find("count(DISTINCT nullif", 1, true) then
      rows = { { 40, 10000, 2000, 4000, 10, 7 } }
    end
    local sql = requests[i].params.sql
    if sql:find("GROUP BY provider, model", 1, true) then rows = { { "provider", "model", 4, 1000, 200, 400 } } end
    if sql:find("AS k,", 1, true) then
      local fmt = sql:find("strftime('%H'", 1, true) and "%H" or (sql:find("strftime('%Y-%m'", 1, true) and "%Y-%m" or "%Y-%m-%d")
      rows = { { os.date(fmt), 1200, 4 } }
    end
    if sql:find("u.tokens, u.calls", 1, true) then rows = { { "Busy chat", "/tmp", 1200, 4, "busy-id" }, { "Busy chat", "/tmp", 1000, 3, "other-id" } } end
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
assert(initial:find("Current: this chat, all time", 1, true))
assert(initial:find("All: all chats, selected period", 1, true))
local wide = text(render(180, 40))
assert(wide:find("Turns/Sessions", 1, true))
assert(wide:find("├", 1, true) and wide:find("┤", 1, true), "stacked scopes have a divider")
assert(wide:find("1.2k", 1, true) and wide:find("12k", 1, true))
assert(wide:find("33.3% failed", 1, true) and wide:find("40% of input", 1, true))
assert(wide:find("±0%", 1, true), "All retains previous-period comparisons")
assert(wide:find("2 req/turn", 1, true) and wide:find("4 req avg", 1, true))
for _, w in ipairs({ 40, 60, 80, 120, 180 }) do
  local lines = render(w, 40)
  for i = 5, math.min(9, #lines) do
    local n = 0
    for _, span in ipairs(lines[i]) do n = n + bone.text.width(span[1]) end
    assert(n <= w, "stacked cards must fit the viewport")
  end
end
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
assert(text(render()):find("Current: this chat, all time", 1, true))
-- With no current chat, retain the global dashboard and never query sessionless usage.
session = nil
first = #requests + 1
commands.stats({ args = "week" })
assert(#requests - first + 1 == 8)
finish(first)
assert(not text(render()):find("Current: this chat", 1, true))
assert(not text(render()):find("├", 1, true), "single-scope cards need no divider")
-- Clicks and keyboard actions share filtering, with scoped cache invalidation.
local function state()
  for i = 1, 30 do local name, value = debug.getupvalue(popup.lines, i); if name == "st" then return value end end
end
local function click(predicate, w)
  render(w or 140, 100)
  for row, targets in pairs(state().visible) do
    for _, v in ipairs(targets) do
      if predicate(v.action) then
        fire("mouse", { popup = 1, popup_focused = true, popup_row = row, popup_col = v.x, button = "left", action = "down" })
        return v
      end
    end
  end
  error("click target not found")
end
for _, choose in ipairs({
  function(a) return a.period == "month" end,
  function(a) return a.model end,
  function(a) return a.session and a.session[1] == "busy-id" end,
  function(a) return a.range end,
}) do
  first = #requests + 1
  click(choose)
  finish(first)
end
assert(state().filters.model and state().filters.session and state().custom)
assert(text(render(140, 100)):find("unfiltered by model", 1, true))
for i = first, #requests do
  local req = requests[i].params
  assert(req.params[3] == "busy-id")
  assert(req.sql:find("FROM tool_calls", 1, true) or (req.params[4] == "provider" and req.params[5] == "model"))
end
first = #requests + 1
popup.on_key("c"); finish(first)
assert(not state().custom and not next(state().filters))
render(80, 12)
for _ = 1, #state().targets do
  popup.on_key("tab"); render(80, 12)
  if state().focus.action.model then break end
end
assert(state().focus.action.model and state().scroll > 0)
first = #requests + 1
popup.on_key("enter"); finish(first)
assert(state().filters.model)
popup.on_key("q")
assert(not next(handlers))
print("usage dashboard tests passed")
