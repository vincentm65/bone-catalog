-- idle_compact: compact the chat you were last using once it has been idle
-- a while and its context is large, so the next message starts from a
-- summary instead of re-sending (and re-caching) the whole conversation.
--
-- Only one chat is ever a candidate: the one your last message went to.
-- Chats you left for another one are never compacted, and a chat is
-- compacted at most once per idle stretch.

local CHECK_MS = 60 * 1000

local state = bone.plugin.state()
-- The chat your last message went to: { session_id, chat, at, done }. `at` is
-- when it last had activity (your message, or a turn ending); `done` once
-- it has been compacted since.
local alive, pending = true, {}

local function setting(key, default)
  return tonumber(bone.settings.get("idle_compact." .. key)) or default
end

local function touch()
  local s = bone.chat.session() or {}
  state.last = { session_id = s.session_id, chat = s.chat, at = os.time() }
end

-- The context the session's last turn sent, in tokens (as the statusline's
-- "curr"), or nil.
local function context_tokens(sid, cb)
  bone.request("store/query", {
    sql = "SELECT coalesce(context_tokens, input_tokens) FROM usage WHERE session_id = ?1 AND source = 'turn' ORDER BY rowid DESC LIMIT 1",
    params = { sid },
  }, function(res, err)
    local row = not err and res and res.rows and res.rows[1]
    cb(row and tonumber(row[1]))
  end)
end

local function idle(l)
  if not (l and l.session_id) or l.done then
    return
  end
  if os.time() - l.at < setting("minutes", 45) * 60 then
    return
  end
  -- Closed chats are left alone, and a running one is not idle.
  local s = bone.chat.session({ session = l.session_id })
  if s and not s.running and not s.starting then
    return s
  end
end

local function check()
  local l = state.last
  if not idle(l) or pending[l.session_id] then
    return
  end
  pending[l.session_id] = true
  context_tokens(l.session_id, function(tokens)
    pending[l.session_id] = nil
    if not alive or state.last ~= l or not tokens or tokens < setting("threshold", 50000) then
      return
    end
    local s = idle(l) -- The usage query may have outlived activity or a closed chat.
    if not s then return end
    local at = l.at
    pending[l.session_id] = { last = l, at = at }
    bone.request("session/compact", { session_id = l.session_id }, function(r, err)
      pending[l.session_id] = nil
      if not alive then return end
      if err then
        return bone.notify("idle_compact: " .. (type(err) == "table" and err.message or tostring(err)), "error")
      end
      if state.last == l and l.at == at then l.done = true end
      bone.notify(string.format("idle_compact: compacted %s (%s → %s tokens)", s.title or "chat",
        bone.util.tokens(r.tokens_before or tokens), bone.util.tokens(r.tokens_after or 0)))
    end)
  end)
end

local function loop()
  if not alive then
    return
  end
  check()
  bone.defer(CHECK_MS, loop)
end

-- Your message makes its chat the candidate. A new chat has no session
-- until its first turn starts; keep its chat number independently of focus.
bone.on("submit", touch)

bone.on("turn/started", function(ev)
  local l = state.last
  if l and not l.session_id and l.chat ~= nil then
    local s = bone.chat.session({ session = tostring(l.chat) })
    if s and s.session_id == ev.session_id then l.session_id = ev.session_id end
  end
end)

-- A turn ending is activity too: the idle time counts from the reply.
bone.on("turn/finished", function(ev)
  local l = state.last
  if l and l.session_id == ev.session_id then
    l.at, l.done = os.time(), nil
  end
end)

-- Compacted some other way (by hand, or over the limit): nothing to do
-- until the chat is used again.
bone.on("session/compacted", function(ev)
  local l = state.last
  if l and l.session_id == ev.session_id then
    local p = pending[ev.session_id]
    -- Our compaction may finish after this chat has become active again.
    if type(p) == "table" and (p.last ~= l or p.at ~= l.at) then return end
    l.done = true
  end
end)

bone.defer(CHECK_MS, loop)

bone.plugin.on_shutdown(function()
  alive = false
end)
