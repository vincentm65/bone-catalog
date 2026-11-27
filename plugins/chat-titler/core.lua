-- chat-titler, core half: asks the model for a chat's title.
--
-- Every open TUI and GUI window hears every turn/finished, and each one's
-- ui.lua calls "chat-titler.title". The first call for a turn claims it, so
-- one title call is made per turn however many windows are open. The core
-- cannot set a title itself: the result goes back to the window that called,
-- which sets it with session/set.

local TITLE_CHARS = 80 -- crates/bone-core/src/session.rs TITLE_CHARS
local STALE_S = 180    -- a call still "busy" after this is presumed lost
local KEEP = 500       -- titles remembered (to tell ours from a hand rename)

local state = bone.state.load("chat-titler")
state.named = type(state.named) == "table" and state.named or {}

local claimed = {} -- sid -> the last turn_id a call claimed
local busy = {}    -- sid -> { at } while a call runs

local function setting(key, default)
  local v = bone.settings.get("chat-titler." .. key)
  if v == nil then return default end
  return v
end

local function text_setting(key)
  local v = setting(key, "")
  if type(v) ~= "string" or v:match("^%s*$") then return nil end
  return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function remember(sid, title)
  state.named[sid] = { title = title, at = os.time() }
  local all = {}
  for id, e in pairs(state.named) do all[#all + 1] = { id = id, at = tonumber(e.at) or 0 } end
  if #all > KEEP then
    table.sort(all, function(a, b) return a.at > b.at end)
    for i = KEEP + 1, #all do state.named[all[i].id] = nil end
  end
  bone.state.save("chat-titler", state)
end

-- UTF-8 ----------------------------------------------------------------------
-- LuaJIT has no utf8 library. Every cut here is on a character boundary: a
-- cut through a character makes invalid UTF-8, and the request carrying it
-- then fails to encode.

local function char_len(c)
  if c < 0x80 then return 1 elseif c >= 0xF0 then return 4 elseif c >= 0xE0 then return 3 elseif c >= 0xC0 then return 2 end
  return 1
end

-- The first n characters of s, and whether anything was cut.
local function take(s, n)
  local i, count, len = 1, 0, #s
  while i <= len do
    if count == n then return s:sub(1, i - 1), true end
    i = i + char_len(s:byte(i))
    count = count + 1
  end
  return s, false
end

local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- Rust's char::is_whitespace, as UTF-8 sequences past ASCII.
local WIDE_SPACE = {
  "\194\133", "\194\160", "\225\154\128", "\226\128\168", "\226\128\169",
  "\226\128\175", "\226\129\159", "\227\128\128",
}
for c = 0x80, 0x8A do WIDE_SPACE[#WIDE_SPACE + 1] = "\226\128" .. string.char(c) end

local function strip_space(s, at_start)
  while true do
    local before = s
    if at_start then s = s:gsub("^%s+", "") else s = s:gsub("%s+$", "") end
    for _, w in ipairs(WIDE_SPACE) do
      if at_start and s:sub(1, #w) == w then s = s:sub(#w + 1)
      elseif not at_start and #s >= #w and s:sub(-#w) == w then s = s:sub(1, -#w - 1) end
    end
    if s == before then return s end
  end
end

local function trim(s) return strip_space(strip_space(s, true), false) end

-- Who named the chat --------------------------------------------------------

-- The title the core gives a chat by itself (session.rs title_of): the first
-- non-blank line of its first user message, else that message's first image
-- name, cut at 80 characters with "…". Only for when the index cannot say
-- whether the chat was renamed: after a compaction the transcript no longer
-- starts with that message.
local function derived_title(messages)
  for _, m in ipairs(messages or {}) do
    if m.role == "user" then
      local line
      local content = m.content or ""
      local from = 1
      while from <= #content + 1 do
        local nl = content:find("\n", from, true)
        local l = trim(content:sub(from, (nl or #content + 1) - 1))
        if l ~= "" then line = l break end
        if not nl then break end
        from = nl + 1
      end
      line = line or (m.images and m.images[1] and m.images[1].name)
      if not line then return nil end
      local cut, more = take(line, TITLE_CHARS)
      return more and (cut .. "…") or cut
    end
  end
  return nil
end

-- "auto" (still the core's own title), "ours" (we set it), or "hand".
local function whose(sid, info, messages, args)
  local named = state.named[sid] and state.named[sid].title
  local now = info.title
  if args.indexed then
    -- The index's `renamed`: the last title set with session/set, if any.
    if args.renamed == nil then return "auto" end
    if args.renamed == named and now == named then return "ours" end
    return "hand"
  end
  if now == nil or now == derived_title(messages) then return "auto" end
  if named ~= nil and now == named then return "ours" end
  return "hand"
end

-- The model call -----------------------------------------------------------

local function clip(s, n)
  local cut, more = take(trim(s or ""), n)
  return more and (cut .. " […]") or cut
end

-- The opening request, the user's latest ones and the latest reply, from
-- the user's own messages (not agent reports or job notices).
local function excerpt(messages)
  local users, reply = {}, nil
  for _, m in ipairs(messages) do
    if m.role == "user" and not m.source then
      local text = trim(m.content or "")
      if text == "" and m.images and m.images[1] then text = "[image: " .. tostring(m.images[1].name) .. "]" end
      if text ~= "" then users[#users + 1] = text end
    elseif m.role == "assistant" and trim(m.content or "") ~= "" then
      reply = m.content
    end
  end
  if #users == 0 then
    -- Started by an agent or a job: use what there is.
    for _, m in ipairs(messages) do
      if m.role == "user" and trim(m.content or "") ~= "" then users[1] = trim(m.content) break end
    end
  end
  if #users == 0 then return nil end
  local parts = { "User: " .. clip(users[1], 1200) }
  local first_later = math.max(2, #users - 2)
  if first_later > 2 then parts[#parts + 1] = "[…]" end
  for i = first_later, #users do parts[#parts + 1] = "User: " .. clip(users[i], 400) end
  if reply then parts[#parts + 1] = "Assistant: " .. clip(reply, 600) end
  return table.concat(parts, "\n\n")
end

local function pick_provider(snap)
  local provider, model = text_setting("provider"), text_setting("model")
  if not provider and snap.model and snap.model.provider then
    provider = snap.model.provider
    model = model or snap.model.model
  end
  local entry
  for _, e in ipairs(bone.model.list() or {}) do
    if (provider and e.name == provider) or (not provider and e.current) then entry = e end
  end
  if not entry then
    error(provider and ("no provider " .. provider) or "no provider in use", 0)
  end
  local options = {}
  if model then options.model = model end
  -- A reasoning model thinks before it names: keep that short. Only where
  -- the entry already sends an effort, so a model without one gets none.
  local effort = text_setting("effort") or (setting("effort", nil) == nil and "low" or nil)
  local own = entry.reasoning_effort
  if effort and type(own) == "string" and own ~= "" and own ~= "default" then
    options.reasoning_effort = effort
  end
  return entry.name, next(options) and options or nil
end

local function max_chars()
  local n = math.floor(tonumber(setting("max_chars", 48)) or 48)
  return math.max(10, math.min(80, n))
end

local SYSTEM = "You write titles for chat conversations. Reply with the title only: "
  .. "2 to 6 words naming the main task or topic, in sentence case (capitalize the "
  .. "first word and proper names only), in the language the user writes in. "
  .. "No quotes, no emoji, no trailing period, no explanation."

local function prompt(conversation, current, max)
  local ask = "<conversation>\n" .. conversation .. "\n</conversation>\n\n"
  if current then
    ask = ask .. "The chat is titled \"" .. current .. "\". If that still names the "
      .. "conversation's main task, reply with it unchanged; otherwise reply with a better one. "
  end
  return {
    { role = "system", content = SYSTEM },
    { role = "user", content = ask .. "Title (at most " .. max .. " characters):" },
  }
end

local QUOTES = { '"', "'", "`", "“", "”", "‘", "’", "«", "»", "「", "」", "*", "_" }

-- The reply as a title: its first line, without a label, markdown, quotes or
-- a closing period, cut at a word to the length setting.
local function clean(text, max)
  text = tostring(text or "")
  text = text:gsub("<think>.-</think>", ""):gsub("^.*</think>", "")
  local line
  for l in text:gmatch("[^\r\n]+") do
    l = trim(l)
    if l ~= "" then line = l break end
  end
  if not line then return "" end
  line = line:gsub("^#+%s*", ""):gsub("^[%-%*]%s+", "")
  line = line:gsub("^[Tt][Ii][Tt][Ll][Ee]%s*:%s*", "")
  for _ = 1, 3 do
    local before = line
    for _, q in ipairs(QUOTES) do
      if line:sub(1, #q) == q then line = line:sub(#q + 1) end
      if #line >= #q and line:sub(-#q) == q then line = line:sub(1, -#q - 1) end
    end
    line = trim(line)
    if line == before then break end
  end
  line = line:gsub("[%.,;:]+$", ""):gsub("%s+", " ")
  line = trim(line)
  if chars(line) <= max then return line end
  local cut = take(line, max - 1)
  local at_word = cut:match("^(.*%S)%s+%S*$")
  if at_word and chars(at_word) >= max / 2 then cut = at_word end
  return trim(cut):gsub("[%.,;:%-]+$", "") .. "…"
end

local function name_chat(sid, args)
  local snap = bone.session.snapshot(sid)
  local info = snap and snap.info
  if not info then return { skip = "no such chat" } end
  if info.owner then return { skip = "a sub-agent (its tool names it)" } end
  local who = whose(sid, info, snap.messages, args)
  if who == "hand" then return { skip = "titled by hand" } end
  if who == "ours" and setting("retitle", false) ~= true then return { skip = "already titled" } end
  local conversation = excerpt(snap.messages or {})
  if not conversation then return { skip = "no user message yet" } end
  local provider, options = pick_provider(snap)
  local max = max_chars()
  local result, err = bone.model.complete({
    provider = provider,
    options = options,
    messages = prompt(conversation, who == "ours" and info.title or nil, max),
  })
  if not result then error("model error: " .. tostring(err), 0) end
  local title = clean(result.content, max)
  if title == "" then return { skip = "the model gave no title" } end
  -- Renamed while the model ran: that rename wins.
  local now = bone.session.info(sid)
  if not now or now.title ~= info.title then return { skip = "renamed meanwhile" } end
  if title == info.title then return { skip = "unchanged" } end
  -- An incognito chat's title is not kept on disk.
  if not now.incognito then remember(sid, title) end
  return { title = title, provider = provider, model = options and options.model }
end

bone.rpc.register("chat-titler.title", function(args)
  local sid = args and args.session_id
  if type(sid) ~= "string" or sid == "" then error("chat-titler.title needs a session_id", 0) end
  local turn = tonumber(args.turn_id)
  if turn then
    if claimed[sid] and claimed[sid] >= turn then return { skip = "claimed" } end
  end
  local running = busy[sid]
  if running and os.time() - running.at < STALE_S then return { skip = "busy" } end
  -- Nothing above waits, so two calls cannot both get here for one turn.
  if turn then claimed[sid] = turn end
  local mine = { at = os.time() }
  busy[sid] = mine
  local ok, r = pcall(name_chat, sid, args)
  if busy[sid] == mine then busy[sid] = nil end
  if not ok then error(r, 0) end
  return r
end)

-- For tests.
return { clean = clean, derived_title = derived_title, take = take, excerpt = excerpt }
