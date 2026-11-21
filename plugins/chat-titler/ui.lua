-- chat-titler, UI half: after each completed turn, ask the core half for a
-- title and set it. Every window runs this for every chat; the core half
-- claims each turn, so only one window's call reaches the model.

local noticed = {} -- message -> when it was last shown (errors repeat each turn)

local function setting(key)
  return bone.settings.get("chat-titler." .. key)
end

-- Progress only; real failures still report at error level.
local function dbg(fmt, ...)
  if setting("debug") == true then
    bone.notify("titler: " .. string.format(fmt, ...))
  end
end

local function fail(msg)
  msg = "titler: " .. tostring(msg)
  local now = os.time()
  if noticed[msg] and now - noticed[msg] < 600 then return end
  noticed[msg] = now
  bone.notify(msg, "error")
end

local function title(sid, turn_id, row)
  local args = { session_id = sid, turn_id = turn_id }
  if row then
    -- The index knows whether the chat was ever renamed (session/set),
    -- even after a compaction rewrote its first message.
    args.indexed = true
    if type(row[1]) == "string" then args.renamed = row[1] end
  end
  bone.request("lua/call", { name = "chat-titler.title", args = args }, function(r, err)
    if err then
      if tostring(err):find("no function chat-titler.title", 1, true) then
        return fail("the core half is not loaded: /plugins reload chat-titler")
      end
      return fail(err)
    end
    if type(r) ~= "table" then return end
    if r.skip then return dbg("%s: %s", sid:sub(-8), r.skip) end
    if type(r.title) ~= "string" or r.title == "" then return end
    bone.request("session/set", { session_id = sid, title = r.title }, function(_, serr)
      if serr then return fail("could not set the title: " .. tostring(serr)) end
      dbg("titled %s: %s", sid:sub(-8), r.title)
    end)
  end)
end

bone.on("turn/finished", function(ev)
  local sid = ev and ev.session_id
  if type(sid) ~= "string" then return end
  -- bone.settings.get gives only saved values, so default in code.
  if setting("auto") == false then return end
  local outcome = ev.outcome
  local status = type(outcome) == "table" and outcome.status or outcome
  if status ~= "completed" then return end
  bone.request("store/query", {
    sql = "SELECT renamed, owner IS NOT NULL FROM sessions WHERE id = ?1",
    params = { sid },
  }, function(res, err)
    local row = not err and type(res) == "table" and type(res.rows) == "table" and res.rows[1] or nil
    -- A sub-agent: the subagent tool names it.
    if row and (row[2] == 1 or row[2] == true) then return end
    title(sid, ev.turn_id, row)
  end)
end)
