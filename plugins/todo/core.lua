-- todo: a checklist the model rewrites in full. Nothing is stored: the list
-- is the latest todo call in a chat's own history, so it cannot reach
-- another chat.
local MARK = { pending = "[ ]", in_progress = "[>]", completed = "[x]" }
-- Tool results without a todo update before the list is mentioned again.
local STALE_AFTER = 8

-- Per session, in memory only: { open = n, active = text, since = calls }.
-- Lost on restart, which only means no reminder until the next todo call.
local live = {}

-- After an interrupt with items open, the next user message carries a
-- reminder, but only in what the model is sent: it is never stored, so it
-- is not on screen. Once added it stays on that message in every request,
-- unchanged, so the request prefix and prompt cache hold. Memory only: after
-- a restart it drops off and the cache rebuilds once from that message.
local interrupted = {} -- session -> true until its next turn starts
local notes = {} -- session -> { { text, nth, line } }, nth: which user message with that text

local function reminder(s, ask)
  return ("[todo: %d open%s. %s]"):format(
    s.open, s.active and (', in progress "' .. s.active .. '"') or "", ask)
end

bone.tool.register({
  name = "todo",
  description = "Track multi-step work as a checklist the user can see. Send the whole list every time,"
    .. " with exactly one item in_progress while working. Mark each item completed as soon as it is done,"
    .. " and finish or clear the list before your final answer. Skip it for simple tasks.",
  parameters = {
    type = "object",
    properties = {
      title = { type = "string", description = "A short title for this checklist. Send it with each update." },
      items = {
        type = "array",
        items = {
          type = "object",
          properties = {
            text = { type = "string" },
            status = { type = "string", enum = { "pending", "in_progress", "completed" } },
          },
          required = { "text", "status" },
        },
      },
    },
    required = { "items" },
  },
  needs_approval = false,
  run = function(args)
    if type(args.items) ~= "table" then return nil, "items must be a list" end
    if args.title ~= nil and (type(args.title) ~= "string" or args.title:match("^%s*$")) then
      return nil, "title must be a non-empty string"
    end
    local out, open = {}, 0
    for i, it in ipairs(args.items) do
      if type(it) ~= "table" or type(it.text) ~= "string" or it.text:match("^%s*$") or not MARK[it.status] then
        return nil, "item " .. i .. " needs text and a status: pending, in_progress or completed"
      end
      out[i] = MARK[it.status] .. " " .. it.text
      if it.status ~= "completed" then open = open + 1 end
    end
    if #out == 0 then return "list cleared" end
    if open > 0 then out[#out + 1] = open .. " open; mark each completed as you finish it." end
    return table.concat(out, "\n")
  end,
})

-- Remind a model that has gone quiet on its list, by appending one line to an
-- ordinary tool result. The line is stored with that result, so the request
-- prefix (and the provider's prompt cache) is never rewritten.
bone.hook("tool_result", function(ev)
  local sid = ev.session_id
  if ev.name == "todo" then
    if ev.is_error then return end
    local items = type(ev.arguments) == "table" and ev.arguments.items
    local open, active = 0, nil
    for _, it in ipairs(type(items) == "table" and items or {}) do
      if type(it) == "table" and it.status ~= "completed" then
        open = open + 1
        if it.status == "in_progress" and type(it.text) == "string" then active = active or it.text end
      end
    end
    live[sid] = open > 0 and { open = open, active = active, since = 0 } or nil
    return
  end
  local s = live[sid]
  if not s then return end
  s.since = s.since + 1
  if s.since < STALE_AFTER or ev.is_error or type(ev.output) ~= "string" then return end
  s.since = 0
  return { output = ev.output .. "\n\n" .. reminder(s, "Mark finished items completed.") }
end)

bone.hook("turn_end", function(ev)
  if live[ev.session_id] and ev.outcome and ev.outcome.status == "cancelled" then
    interrupted[ev.session_id] = true
  end
end)

-- Last, so the text is final when it is matched in context.
bone.hook("turn_start", function(ev)
  local sid = ev.session_id
  if not interrupted[sid] then return end
  interrupted[sid] = nil
  local s = live[sid]
  if not s or type(ev.text) ~= "string" then return end
  local list = notes[sid] or {}
  list[#list + 1] = { text = ev.text,
    line = reminder(s, "You were interrupted: update the list if the plan changed, or clear it.") }
  notes[sid] = list
end, { priority = -100 })

-- Copy a dense list into a fresh array. A hook's event is turned back into
-- JSON by length, and on Windows a list that lives in the hash part has
-- length 0, so it comes back as {"1": ...} where a message needs a sequence.
local function sequence(t)
  if type(t) ~= "table" then return t end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return t end
    if k > n then n = k end
  end
  local out = {}
  for i = 1, n do
    if t[i] == nil then return t end
    out[i] = t[i]
  end
  return out
end

local function repack(m)
  if type(m) ~= "table" then return m end
  if m.tool_calls ~= nil then m.tool_calls = sequence(m.tool_calls) end
  if m.images ~= nil then m.images = sequence(m.images) end
  local rs = m.reasoning_state
  if type(rs) == "table" and rs.items ~= nil then rs.items = sequence(rs.items) end
  return m
end

bone.hook("context", function(ev)
  if type(ev.messages) ~= "table" then return end
  -- Always, not only when a reminder is added: registering this hook sends
  -- the messages back on every model call, including after the first tool.
  local messages = sequence(ev.messages)
  for i, m in ipairs(messages) do messages[i] = repack(m) end
  ev.messages = messages
  local list = notes[ev.session_id]
  if not list then return end
  local count, last = {}, nil
  for _, m in ipairs(messages) do
    if m.role == "user" and type(m.content) == "string" then
      count[m.content] = (count[m.content] or 0) + 1
      last = m.content
    end
  end
  -- A new note belongs to the newest user message; if that is not it (the
  -- turn failed before saving it), drop it.
  for i = #list, 1, -1 do
    local n = list[i]
    if not n.nth then
      if n.text == last then n.nth = count[last] else table.remove(list, i) end
    end
  end
  if #list == 0 then notes[ev.session_id] = nil return end
  local seen, changed = {}, false
  for _, m in ipairs(messages) do
    if m.role == "user" and type(m.content) == "string" then
      local text = m.content
      seen[text] = (seen[text] or 0) + 1
      for _, n in ipairs(list) do
        if n.text == text and n.nth == seen[text] then
          m.content, changed = m.content .. "\n\n" .. n.line, true
        end
      end
    end
  end
  if changed then return { messages = ev.messages } end
end)
