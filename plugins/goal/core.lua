-- goal: keep a session working toward an objective, turn after turn, until
-- the model says it is done (and the check passes), says it is blocked, or a
-- continuation turn makes no progress. One hook (turn_end), no tools and no
-- prompt changes: all a goal adds is short messages at the end of its chat,
-- so other sessions are untouched and the prompt cache is never broken.
local NAME = "goal"
local FILE = bone.config_dir and (bone.config_dir .. "/state/core/" .. NAME .. ".json")
local CHECK_TIMEOUT = 10 * 60000

local START = [[Goal: %s

Work on this until it is fully done, across as many turns as it takes: after each turn you will be told to continue. The user is away, so never ask questions, wait for input, or use ask_user or any other tool that waits for the user; when unsure, pick the option that is easiest to reverse and say which you picked. When the goal is done and verified, end your reply with <goal>done</goal>. If only the user can unblock it, end with <goal>blocked: why</goal>.]]
local CONTINUE = "Continue the goal: %s\nEnd with <goal>done</goal> once it is done and verified."

-- This core process. Goals outlive a reload, which keeps their turns going,
-- but not a restart, after which no turn is left to continue them.
local PID = (function()
  local ok, r = pcall(bone.system, "echo $PPID")
  return ok and r and r.code == 0 and r.stdout:match("%d+") or nil
end)()

-- Running goals by session. The file holds exactly these and is removed when
-- none are left; goals that ended stay in memory for the TUI to report.
local goals, ended = {}, {}
local function save()
  if next(goals) then
    bone.state.save(NAME, goals)
  elseif FILE then
    os.remove(FILE)
  end
end
for sid, g in pairs(bone.state.load(NAME) or {}) do
  if g.pid == PID then goals[sid] = g end
end
save()

local function stop(sid, status, reason)
  local g = goals[sid]
  if not g then return end
  goals[sid] = nil
  g.status, g.reason, g.ended_at = status, reason, os.time()
  ended[sid] = g
  save()
end

local function check(g)
  local r = bone.system(g.check, { cwd = g.cwd, timeout = CHECK_TIMEOUT })
  if not r then return nil end
  if r.timed_out then return { ok = false, code = "timeout", output = "" } end
  local out = ((r.stdout or "") .. "\n" .. (r.stderr or "")):gsub("^%s+", ""):gsub("%s+$", "")
  if #out > 1500 then out = "…" .. out:sub(-1500) end
  return { ok = r.code == 0, code = r.code, output = out }
end

bone.hook("turn_end", function(ev)
  local sid = ev.session_id
  local g = goals[sid]
  if not g then return end
  local status = ev.outcome and ev.outcome.status
  if status == "cancelled" then return stop(sid, "stopped", "stopped by you") end
  if status ~= "completed" then return stop(sid, "stopped", "the turn failed") end

  -- This turn's messages: its tool calls, its last reply, and whether it was
  -- one of ours (a user's own message may well need no tools).
  local s = bone.session.snapshot(sid)
  local messages = s and s.messages or {}
  local calls, reply, ours = 0, nil, false
  for i = math.min(g.seen, #messages) + 1, #messages do
    local m = messages[i]
    calls = calls + #(m.tool_calls or {})
    if m.role == "assistant" and type(m.content) == "string" and m.content:find("%S") then reply = m.content end
    if m.role == "user" and type(m.content) == "string" and m.content:sub(1, 18) == "Continue the goal:" then ours = true end
  end
  g = goals[sid] -- the snapshot waited: the goal may have been stopped
  if not g then return end
  g.turns, g.seen = g.turns + 1, #messages
  local tag
  for t in (reply or ""):gmatch("<goal>%s*(.-)%s*</goal>") do tag = t end

  local note
  if tag and tag:match("^blocked") then
    return stop(sid, "blocked", tag:match("^blocked:?%s*(.*)$"))
  elseif tag == "done" then
    if not g.check then return stop(sid, "done") end
    local r = check(g)
    g = goals[sid]
    if not g then return end
    g.check_ok = r and r.ok
    if r and r.ok then return stop(sid, "done") end
    note = r and ("Not done: `%s` failed (exit %s)%s"):format(g.check, tostring(r.code),
      r.output ~= "" and (":\n```\n" .. r.output .. "\n```") or ".")
  elseif ours and calls == 0 then
    return stop(sid, "stopped", "a turn made no progress")
  end
  save()
  -- The user's own queued messages go first; the turn after them continues.
  if #(bone.queue.list(sid) or {}) == 0 then
    bone.queue.add(sid, CONTINUE:format(g.text) .. (note and ("\n\n" .. note) or ""), "next")
  end
end)

-- RPCs for the TUI; each takes args.session_id (default: the caller's).
local function sid_of(args, ctx) return (args or {}).session_id or ctx.session_id end
local function view(g, sid)
  if not g then return nil end
  local out = { session_id = sid, status = "running" }
  for k, v in pairs(g) do out[k] = v end
  return out
end

-- A session's running goal, else the last one that ended (since loading).
bone.rpc.register("goal.get", function(args, ctx)
  local sid = sid_of(args, ctx)
  return view(goals[sid] or ended[sid], sid)
end)

bone.rpc.register("goal.list", function()
  local out = {}
  for sid in pairs(goals) do out[#out + 1] = sid end
  return out
end)

-- { text, check? }. A chat with no session yet gets one.
bone.rpc.register("goal.set", function(args, ctx)
  args = args or {}
  assert(type(args.text) == "string" and args.text:find("%S"), "goal: no objective")
  local sid, cwd = sid_of(args, ctx), ctx.cwd
  if sid then
    assert(not goals[sid], "goal: this chat already has a running goal; /goal stop first")
  else
    local info = bone.session.create({ cwd = cwd, title = args.text })
    sid = assert(info and info.session_id, "goal: could not create a session")
  end
  local s = bone.session.snapshot(sid)
  goals[sid] = { text = args.text, check = args.check, cwd = s.info.cwd or cwd, pid = PID,
    turns = 0, seen = #s.messages, started_at = os.time() }
  ended[sid] = nil
  save()
  bone.queue.add(sid, START:format(args.text), "next")
  return view(goals[sid], sid)
end)

-- A turn already running finishes; none follows.
bone.rpc.register("goal.stop", function(args, ctx)
  local sid = sid_of(args, ctx)
  stop(sid, "stopped", "stopped by you")
  return view(ended[sid], sid)
end)
