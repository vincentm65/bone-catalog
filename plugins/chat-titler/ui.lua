-- chat-titler: replace the core's first-message title with a real one,
-- after the chat's first completed turn.

local pending = {}   -- sid -> debounce timer seq, waiting to generate
local seqs = {}      -- sid -> turn counter, invalidates stale timers
local mine = {}      -- sid -> the last title we set
local busy = {}      -- sid -> a generation is in flight

local TITLE_CHARS = 80 -- crates/bone-core/src/session.rs TITLE_CHARS

-- Progress only; real failures still report at error level.
local function dbg(fmt, ...)
  if bone.settings.get("chat-titler.debug") == true then
    bone.notify("titler: " .. string.format(fmt, ...))
  end
end

local function fail(fmt, ...)
  bone.notify("titler: " .. string.format(fmt, ...), "error")
end

-- The title the core gives a session by itself: the first non-empty line of
-- its first user message, cut at 80 chars. Anything else was set by hand.
local function derived_title(messages)
  for _, m in ipairs(messages or {}) do
    if m.role == "user" then
      for l in (m.content or ""):gmatch("[^\r\n]+") do
        local t = l:match("^%s*(.-)%s*$")
        if t ~= "" then
          local stop = utf8 and utf8.offset(t, TITLE_CHARS + 1)
          if stop then return t:sub(1, stop - 1) .. "…" end
          return t
        end
      end
    end
  end
  return nil
end

local function ours_to_name(title, messages)
  if title == nil or title == "" or title == "[untitled]" or title == "[new session]" then
    return true
  end
  return title == derived_title(messages)
end

local function clean(text)
  text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub('^["“”\']', ""):gsub('["“”\']$', "")
  text = text:gsub("^Title:%s*", "")
  text = text:gsub("%s+", " ")
  local max = tonumber(bone.settings.get("chat-titler.max_chars")) or 48
  if #text > max then
    text = text:sub(1, max)
    text = text:sub(1, text:find(" $") or #text)
  end
  return text
end

-- The chat's own model, unless the settings name one: model/list marks the
-- session's selected provider with `current`, and its model is the session's.
local function resolve_model(sid, cb)
  local provider = bone.settings.get("chat-titler.provider")
  local model = bone.settings.get("chat-titler.model")
  if provider ~= nil and provider ~= "" then
    return cb(provider, model ~= "" and model or nil)
  end
  if model ~= nil and model ~= "" then
    return cb(nil, model)
  end
  bone.request("model/list", { session_id = sid }, function(list)
    for _, p in ipairs(list or {}) do
      if p.current then return cb(p.name, p.model) end
    end
    cb(nil, nil)
  end)
end

local function generate(sid)
  if busy[sid] then return end
  busy[sid] = true
  bone.chat.messages(sid, function(messages, err)
    if err or not messages then
      busy[sid] = nil
      return fail("no transcript: %s", tostring(err))
    end
    local first, reply
    for _, m in ipairs(messages) do
      if m.role == "user" and not first then
        first = (m.content or ""):gsub("^%s+", ""):gsub("%s+$", "")
      elseif m.role == "assistant" and first then
        reply = (m.content or ""):gsub("^%s+", ""):gsub("%s+$", "")
        break
      end
    end
    if not first or first == "" then
      busy[sid] = nil
      return dbg("no user message")
    end
    -- Re-check the title now that we know what the core derived: a chat the
    -- user renamed by hand is left alone.
    local session = bone.chat.session({ session = sid })
    local title_now = session and session.title
    if not ours_to_name(title_now, messages) then
      busy[sid] = nil
      return dbg("skipped: titled by hand (%s)", tostring(title_now))
    end
    resolve_model(sid, function(provider, model)
      local prompt = {
        { role = "system",
          content = "You name conversations. Reply with only a short title for the exchange below: a few words describing the task, lowercase unless a name is involved, no quotes, no punctuation at the end." },
        { role = "user", content = first:sub(1, 700) },
      }
      if reply and reply ~= "" then
        prompt[#prompt + 1] = { role = "assistant", content = reply:sub(1, 300) }
      end
      bone.model.complete({
        provider = provider,
        messages = prompt,
        options = model and { model = model } or nil,
      }, nil, function(result, model_err)
        busy[sid] = nil
        if model_err then return fail("model error: %s", tostring(model_err)) end
        local title = clean(result and result.content or "")
        if title == "" then return dbg("model returned nothing") end
        bone.request("session/set", { session_id = sid, title = title }, function(_, rerr)
          if rerr then return fail("rename failed: %s", tostring(rerr)) end
          mine[sid] = title
          dbg("titled: %s", title)
        end)
      end)
    end)
  end)
end

bone.on("turn/started", function(ev)
  local sid = ev and ev.session_id
  if sid then seqs[sid] = (seqs[sid] or 0) + 1 end
end)

bone.on("turn/finished", function(ev)
  local sid = ev and ev.session_id
  dbg("turn/finished sid=%s outcome=%s", tostring(sid),
    tostring(ev and ev.outcome and (ev.outcome.status or ev.outcome)))
  if not sid then return end
  -- bone.settings.get gives only saved values, so default in code.
  if bone.settings.get("chat-titler.auto") == false then return end
  local status = ev and ev.outcome and (ev.outcome.status or ev.outcome)
  if status ~= "completed" then return end
  if not bone.settings.get("chat-titler.retitle") and mine[sid] then return end
  local session = bone.chat.session({ session = sid })
  if not session then return dbg("no such chat here: %s", sid) end
  if not bone.settings.get("chat-titler.retitle") and session.turns and session.turns > 1 then
    return dbg("skipped: %d turns already", session.turns)
  end
  local mine_turns = seqs[sid]
  pending[sid] = (pending[sid] or 0) + 1
  local mygen = pending[sid]
  bone.defer(2000, function()
    if pending[sid] ~= mygen then return end
    pending[sid] = nil
    if seqs[sid] ~= mine_turns then return dbg("skipped: a new turn started") end
    local now = bone.chat.session({ session = sid })
    if not now or now.running then return dbg("skipped: running or gone") end
    generate(sid)
  end)
  dbg("scheduled in 2s")
end)
