-- /goal: start a goal, see it in a band under the chat, stop it. The core
-- half runs the loop; this half asks it (goal.* RPCs) only about sessions
-- with a goal, and overrides nothing shared.
local alive, panel = true, nil
local goals = {} -- session_id -> the goal as last fetched

local function current() return (bone.api.session() or {}).session_id end
local function notify(msg, level) bone.notify("goal: " .. tostring(msg), level) end
-- Quiet unless `loud`: without the core half a background call just fails.
local function call(name, args, cb, loud)
  local s = bone.chat.session()
  bone.request("lua/call", { name = name, args = args, cwd = s and s.cwd or nil }, function(r, err)
    if not alive then return end
    if err then return loud and notify(err, "error") end
    if cb then cb(r) end
  end)
end

local function elapsed(g)
  local s = math.max(0, (g.ended_at or os.time()) - g.started_at)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  return ("%dh%02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
end

local function band(ctx)
  local g = goals[current()]
  if not g or g.status ~= "running" then return nil end
  bone.ui.refresh_in(30000)
  local stats = { { "  turn " .. (g.turns + 1) .. "  " .. elapsed(g), "Dim" } }
  if g.check_ok == false then stats[2] = { "  check ✗", "ErrorMsg" } end
  local used = 2
  for _, s in ipairs(stats) do used = used + bone.text.width(s[1]) end
  local line = { { "◎ ", "Accent" }, { bone.text.truncate((g.text:gsub("%s+", " ")), math.max(8, ctx.width - used)), "Normal" } }
  for _, s in ipairs(stats) do line[#line + 1] = s end
  return { bone.text.clip(line, ctx.width) }
end

local function sync()
  local g = alive and goals[current()]
  if not (g and g.status == "running") then
    if panel then panel:hide() end
  elseif panel and panel:is_open() then
    panel:show()
  else
    panel = bone.ui.panel.open({ id = "goal", dock = "bottom", title = false, focusable = false, render = band })
  end
end

-- Refresh one session's goal; when it has just ended, say how.
local function fetch(sid, cb)
  call("goal.get", { session_id = sid }, function(g)
    local before = goals[sid]
    goals[sid] = g
    if before and before.status == "running" and g and g.status ~= "running" then
      local how = g.status == "done" and "done ✓" or (g.status .. (g.reason and (" (" .. g.reason .. ")") or ""))
      notify(how .. " after " .. g.turns .. " turns, " .. elapsed(g) .. ": " .. g.text, g.status ~= "done" and "error" or nil)
    end
    sync()
    if cb then cb(g) end
  end, cb ~= nil)
end

-- Which sessions have a running goal (also ones another client started).
local function refresh()
  call("goal.list", {}, function(list)
    for _, sid in ipairs(list or {}) do
      if not goals[sid] then fetch(sid) end
    end
    sync()
  end)
end

bone.cmd.create("goal", function(c)
  local args = (c.args or ""):match("^%s*(.-)%s*$")
  local sid = current()
  if args == "" or args == "stop" then
    if not sid then return notify("no goal in this chat") end
    return fetch(sid, function(g)
      if not g then return notify("no goal in this chat; start one with /goal <objective>") end
      if args == "stop" then
        if g.status ~= "running" then return notify("the goal already ended") end
        return call("goal.stop", { session_id = sid }, function() fetch(sid) end, true)
      end
      notify(g.status .. (g.reason and (" (" .. g.reason .. ")") or "") .. " · turn " .. g.turns
        .. " · " .. elapsed(g) .. (g.check and (" · check `" .. g.check .. "`") or "") .. ": " .. g.text)
    end)
  end
  -- "--check cmd" (or --check "cmd with spaces") anywhere in the objective.
  local check
  args = args:gsub('%-%-check%s+"([^"]*)"', function(v) check = v; return "" end, 1)
  args = args:gsub("%-%-check%s+'([^']*)'", function(v) check = check or v; return "" end, 1)
  args = args:gsub("%-%-check%s+(%S+)", function(v) check = check or v; return "" end, 1)
  local text = args:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if text == "" then return notify('usage: /goal <objective> [--check "cmd"]', "error") end
  call("goal.set", { session_id = sid, text = text, check = check }, function(g)
    goals[g.session_id] = g
    if g.session_id ~= current() then bone.api.open_session(g.session_id) end
    sync()
  end, true)
end, {
  desc = 'work on an objective until it is done: /goal <objective> [--check "cmd"], /goal, /goal stop',
  complete = function(ctx)
    if (ctx.args or ""):find("%s") then return {} end
    return { { value = "stop", desc = "stop the goal (the running turn finishes)" } }
  end,
})

bone.on("ready", refresh)
bone.on("chat/shown", function() refresh(); sync() end)
bone.on("turn/finished", function(ev)
  local g = goals[ev.session_id]
  if g and g.status == "running" then fetch(ev.session_id) end
end)

bone.plugin.on_shutdown(function()
  alive = false
  if panel then panel:close() end
end)
