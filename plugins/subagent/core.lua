-- Sub-agents run in sessions of their own, owned by the tool call that
-- started them: they use the same tools, clients show them live, and their
-- transcripts can be opened like any session.
--
-- Every agent the main chat starts works in the background: the call
-- returns at once. The agents a chat starts in one turn answer together, in
-- one message (source "result") sent when the last of them is done; it
-- starts a turn for an idle chat, or joins the running one. The chat draws
-- no row for that message: each agent's own row shows how it went.
--
-- The model names its agents (`name`, made unique per task). `to` messages
-- one by name, or `main`, the chat the task started in: a busy agent reads
-- it before its next step, an idle one takes it as more work and answers
-- again. Messages are sent as "From <name>:" with source "agent".
-- list = true shows who can be messaged (other chats too with
-- cross_session on). Agents started by agents, and messages from one agent
-- to an idle one, wait for the answer: an agent has no user to answer
-- meanwhile.
-- `provider` / `model` pick what the agent runs on; an unknown provider, or
-- one that fails, falls back to the agent's defaults.
--
-- Optional agent setups, in core.lua (or /subagents):
--   bone.config.subagents.reviewer = {
--     description = "reviews a diff for bugs",  -- shown to the model
--     system = "You review code ...",           -- put before the system prompt
--     provider = "fast",                        -- a bone.config.providers entry
--     model = "model-id",                      -- optional model override
--     tools = { "read_file", "shell" },         -- allowed tools (default: all)
--   }
bone.config.subagents = bone.config.subagents or {}

local ROLE = "You are a sub-agent: another agent gave you one task. "
  .. "Work on it with your tools, then reply with only what the other agent "
  .. "needs (findings, file paths, conclusions), briefly. It cannot see your "
  .. "tool calls, only your final reply."

-- children: session id -> { spec, depth, parent, root, task, name,
-- override?, note?, group?, last? } (false for sessions that are not
-- agents). group: the answers its current turn belongs to.
-- chats: top-level session id -> { cwd, last } for each chat this core ran
-- a turn in. busy: session ids with a turn running. turns: how many turns
-- each session started, to group what one turn starts. last: os.time() of
-- the latest turn start or end.
local children, chats, active, busy, turns = {}, {}, {}, {}, {}
-- Answers still being collected: "<chat>:<turn>" -> { to, pending, done }.
local groups = {}
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end
local function setting(key) return bone.settings.get("subagent." .. key) end
local function text(value)
  if type(value) == "string" and value:match("%S") then return value end
end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function integer(key, default)
  local value = setting(key)
  if type(value) ~= "number" or value ~= value or value == math.huge then return default end
  return math.max(0, math.floor(value))
end
local function max_depth()
  local limit = integer("max_depth", 2)
  return setting("allow_nested") == false and math.min(limit, 1) or limit
end
local child_of
local function depth(id) local c = child_of(id) return c and c.depth or 0 end
-- How a chat is told apart in lists: the end of its session id.
local function handle(id) return id:sub(-8) end
local function tool_list(value)
  if not text(value) or value:match("^%s*%*%s*$") then return nil end
  if value:match("^%s*none%s*$") or value:match("^%s*%[%]%s*$") then return {} end
  local list = {}
  for name in value:gmatch("[^,%s]+") do list[#list + 1] = name end
  return list
end
-- A per-call provider/model (c.override) wins over the agent setup's and the
-- defaults; a provider without a model uses that provider's own model.
local function spec_for(c)
  local spec = c and c.spec or {}
  local over = c and c.override or {}
  return {
    system = text(spec.system) or text(setting("system")) or ROLE,
    provider = over.provider or text(spec.provider) or text(setting("provider")),
    model = over.model or (not over.provider and (text(spec.model) or text(setting("model")))) or nil,
    tools = spec.tools or tool_list(setting("tools")),
  }
end
local function allowed(spec, name)
  if not spec.tools then return true end
  for _, tool in ipairs(spec.tools) do
    if tool == name or tool == "*" then return true end
  end
  return false
end
local function agents()
  local out = {}
  for name, spec in pairs(bone.config.subagents) do out[name] = spec end
  local saved = setting("agents")
  if saved ~= nil and type(saved) ~= "table" then
    return nil, "subagent.agents must be an object; edit it with /subagents"
  end
  for name, spec in pairs(saved or {}) do out[name] = spec end
  for name, spec in pairs(out) do
    if type(name) ~= "string" or name == "" or type(spec) ~= "table" then
      return nil, "subagent.agents must map names to agent objects"
    end
    for _, key in ipairs({ "description", "system", "provider", "model" }) do
      if spec[key] ~= nil and type(spec[key]) ~= "string" then
        return nil, "invalid " .. key .. " for subagent " .. name
      end
    end
    if spec.tools ~= nil then
      if type(spec.tools) ~= "table" then return nil, "invalid tools for subagent " .. name end
      local count = 0
      for k, tool in pairs(spec.tools) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or not text(tool) then
          return nil, "tools for subagent " .. name .. " must be a list of names"
        end
      end
      if count ~= #spec.tools then return nil, "tools for subagent " .. name .. " must be a dense list" end
    end
  end
  return out
end
-- A child from before a restart: the owner (and its name) is in the session
-- header, so its role, whitelist and depth survive the registry.
function child_of(id)
  local c = children[id]
  if c == nil and id then
    local ok, info = pcall(bone.session.info, id)
    local o = ok and type(info) == "table" and info.owner
    if o then
      local p = child_of(o.session_id)
      c = {
        spec = {}, depth = (p and p.depth or 0) + 1, name = o.name or handle(id),
        parent = o.session_id, root = p and p.root or o.session_id, task = info.title,
      }
    end
    children[id] = c or false
  end
  return c or nil
end

-- Providers the model may ask for: core.lua's and settings.json's.
local function providers()
  local names, seen = {}, {}
  for _, list in ipairs({ bone.config.providers, bone.settings.get("providers") }) do
    if type(list) == "table" then
      for name, entry in pairs(list) do
        if type(name) == "string" and not seen[name] then
          seen[name] = entry
          names[#names + 1] = name
        end
      end
    end
  end
  table.sort(names)
  return names, seen
end

-- The provider/model a call asked for, or nil and why it fell back.
local function requested(args)
  local provider, model = text(args.provider), text(args.model)
  if not provider and not model then return nil end
  if provider and not select(2, providers())[provider] then
    return nil, "provider " .. provider .. " isn't configured; used the default"
  end
  return { provider = provider, model = model }
end

-- What a new agent's session runs on, so it reports its own model: its
-- provider and model, the provider's own model when only that is set.
local function pin(spec)
  local provider, model = spec.provider, spec.model
  if not model and provider then
    local entry = select(2, providers())[provider]
    model = type(entry) == "table" and text(entry.model) or nil
  end
  if not model then return nil end
  return { provider = provider, model = model }
end

-- The agent called `name` on task `root`.
local function find(name, root)
  name = trim(name)
  for id, c in pairs(children) do
    if c and c.root == root and (c.name == name or id == name) then return id, c end
  end
  if #name > 8 then
    local c = child_of(name)
    if c and c.root == root then return name, c end
  end
end

-- Names given out but not yet on a child (its session is being made):
-- "<root>:<name>" -> true, so calls in one reply never share one.
local claimed = {}

-- A name no other agent on task `root` has: the wanted one, or it with -2,
-- -3, ... Letters, digits, - and _ only; "main" is the chat's. The caller
-- frees the claim once the child holds the name.
local function unique(wanted, root)
  local base = (wanted or ""):gsub("%s+", "-"):gsub("[^%w_-]", ""):sub(1, 24)
  if base == "" or base == "main" then base = "agent" end
  local name, n = base, 1
  while find(name, root) or claimed[root .. ":" .. name] do
    n = n + 1
    name = base .. "-" .. n
  end
  claimed[root .. ":" .. name] = true
  return name
end

local function roster(all)
  local names = {}
  for name, spec in pairs(all) do
    names[#names + 1] = "- " .. name .. (text(spec.description) and (": " .. spec.description) or "")
  end
  table.sort(names)
  return #names > 0 and ("\n\nAgent setups the user made (pass as agent):\n" .. table.concat(names, "\n")) or ""
end

local function title_of(id)
  local ok, info = pcall(bone.session.info, id)
  return ok and type(info) == "table" and text(info.title) or "untitled"
end

-- Busy first, then the most recent; at most `max`, and how many were left out.
local function newest(list, max)
  table.sort(list, function(a, b)
    if busy[a.id] ~= busy[b.id] then return busy[a.id] == true end
    if (a.last or 0) ~= (b.last or 0) then return (a.last or 0) > (b.last or 0) end
    return a.id < b.id
  end)
  local out = {}
  for i = 1, math.min(#list, max) do out[i] = list[i] end
  return out, #list - #out
end

local function line(id, name, label)
  return "  " .. name .. "  " .. (busy[id] and "busy" or "idle") .. (label and ("  " .. label) or "")
end

-- Who `id` can message: agents on its task, main (for an agent), and other
-- recent chats (for a chat, when subagent.cross_session is on).
local function listing(id, c)
  local max, root = integer("list_max", 10), c and c.root or id
  local out, agents_on, more = {}, {}, 0
  for other, o in pairs(children) do
    if o and other ~= id and o.root == root then
      agents_on[#agents_on + 1] = { id = other, last = o.last, name = o.name, label = o.task }
    end
  end
  agents_on, more = newest(agents_on, max)
  out[#out + 1] = "Agents on this task:"
  for _, a in ipairs(agents_on) do out[#out + 1] = line(a.id, a.name, a.label) end
  if #agents_on == 0 then out[#out + 1] = "  (none)" end
  if more > 0 then out[#out + 1] = "  +" .. more .. " older agents not shown" end
  if c then
    out[#out + 1] = "The chat this task started in:"
    out[#out + 1] = line(root, "main", '"' .. title_of(root) .. '"')
  elseif setting("cross_session") == true then
    local since, others = os.time() - 60 * integer("list_window_minutes", 30), {}
    local older = 0
    for other, chat in pairs(chats) do
      if other ~= id then
        if busy[other] or (chat.last or 0) >= since then
          others[#others + 1] = { id = other, last = chat.last, cwd = chat.cwd }
        else
          older = older + 1
        end
      end
    end
    others, more = newest(others, max)
    out[#out + 1] = "Other chats:"
    for _, o in ipairs(others) do
      out[#out + 1] = line(o.id, handle(o.id), '"' .. title_of(o.id) .. '"' .. (o.cwd and ("  " .. o.cwd) or ""))
    end
    if #others == 0 then out[#out + 1] = "  (none recent)" end
    if more + older > 0 then out[#out + 1] = "  +" .. (more + older) .. " older chats not shown" end
  end
  out[#out + 1] = "Pass a name as to (with the message as prompt) to message it."
  return table.concat(out, "\n")
end

-- A chat `name` names that `id` may message: main (for an agent), or
-- another chat by handle when subagent.cross_session is on.
local function find_chat(name, id, c)
  name = trim(name)
  if c then
    if name == "main" or c.root == name or handle(c.root) == name then return c.root end
    return nil
  end
  if setting("cross_session") ~= true then return nil end
  for other in pairs(chats) do
    if other ~= id and (other == name or handle(other) == name) then return other end
  end
  if #name > 8 and name ~= id and not child_of(name) then
    local ok, info = pcall(bone.session.info, name)
    if ok and type(info) == "table" and not info.owner then return name end
  end
end

-- The final reply of the turn that just ended, if it wrote one.
local function last_reply(id)
  local ok, messages = pcall(bone.session.messages, id)
  if not ok or type(messages) ~= "table" then return "" end
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m.role == "user" then return "" end
    if m.role == "assistant" and text(m.content) then return m.content end
  end
  return ""
end

-- An agent's answer for the model, headed by its name: its text (or what it
-- did before it failed) and any fallback note. Returns it and whether it
-- went wrong.
local function answer(name, c, status, message, body)
  body = trim(body or "")
  local note = c and c.note and ("\n\n(" .. c.note .. ")") or ""
  if c then c.note = nil end
  if status == "failed" or status == "cancelled" then
    local head = status == "failed" and (name .. " failed: " .. tostring(message)) or (name .. " was stopped")
    if body ~= "" then head = head .. "\n\nIts work so far:\n" .. body end
    return head .. note, true
  end
  return name .. " finished:\n\n" .. (body ~= "" and body or "(no answer)") .. note, false
end

-- The answers chat `to` collects in its current turn.
local function group_of(to)
  local key = to .. ":" .. (turns[to] or 0)
  local g = groups[key]
  if not g or g.sent then
    g = { to = to, key = key, pending = {}, order = {}, done = {} }
    groups[key] = g
  end
  return g
end

-- Send a group's answers once none is pending: one message, so a chat
-- hears from all the agents it started in a turn at once.
local function settle(g)
  if g.sent or next(g.pending) then return end
  g.sent = true
  groups[g.key] = nil
  if #g.done == 0 then return end
  pcall(bone.queue.add, g.to, table.concat(g.done, "\n\n"), "steer", nil, "result")
end

bone.hook("system", function(ev)
  local c = child_of(ev.session_id)
  if c then return { prompt = spec_for(c).system .. "\n\n" .. (ev.prompt or "") } end
end)

bone.hook("request", function(ev)
  local c = child_of(ev.session_id)
  -- Defaults apply only to child sessions, never to their owner.
  local spec = c and spec_for(c) or {}
  local all, err = agents()
  if not all then return { deny = err } end
  local deep = depth(ev.session_id) >= max_depth()
  -- Too deep to start agents, an agent still messages the others and main,
  -- and a chat other chats when that is on.
  local talks = c ~= nil or setting("cross_session") == true
  local tools = {}
  for _, t in ipairs(ev.tools or {}) do
    if allowed(spec, t.name) and (t.name ~= "subagent" or not deep or talks) then
      if t.name == "subagent" then
        -- Nothing here changes from turn to turn, so the provider's
        -- prompt cache keeps the tool definitions: who is running is
        -- asked for with list instead.
        local names = providers()
        t.description = t.description .. roster(all)
          .. (#names > 0 and ("\n\nProviders: " .. table.concat(names, ", ") .. ".") or "")
        if c then
          t.description = t.description .. "\n\nYou are the sub-agent " .. (c.name or "agent")
            .. ". Agents you start, and idle ones you message, answer in the call itself. "
            .. "to = \"main\" messages the chat this task started in; list = true shows the other agents."
        end
        if deep then
          t.description = t.description .. "\n\nYou cannot start new sub-agents: "
            .. "use to to message the ones list shows."
        end
        t.parameters.properties.agent = next(all) and not deep and {
          type = "string", description = "One of the agent setups listed, if it fits the task.",
        } or nil
      end
      tools[#tools + 1] = t
    end
  end
  return { tools = tools, provider = spec.provider, model = spec.model }
end)

-- A provider or model the call asked for failed: fall back to the agent's
-- defaults for this call and the rest of its work.
bone.hook("request_error", function(ev)
  local c = child_of(ev.session_id)
  if not (c and c.override) then return end
  local o = c.override
  local what = o.model and ((o.provider and (o.provider .. "/") or "") .. o.model) or o.provider
  c.override = nil
  local fallback = spec_for(c).provider or bone.config.provider
  if not fallback then return end
  local why = tostring(ev.error)
  if #why > 160 then why = why:sub(1, 160):gsub("%s*%S*$", "") .. "…" end
  c.note = what .. " failed (" .. why .. "); used " .. fallback
  return { retry = 0, provider = fallback }
end)

-- Also enforce whitelists on calls, not just advertised tool definitions.
bone.hook("tool_call", function(ev)
  local c = child_of(ev.session_id)
  if c and not allowed(spec_for(c), ev.name) then
    return { deny = "tool " .. ev.name .. " is not allowed for this sub-agent" }
  end
end)

bone.hook("turn_start", function(ev)
  busy[ev.session_id] = true
  turns[ev.session_id] = (turns[ev.session_id] or 0) + 1
  local c = child_of(ev.session_id)
  if c then
    c.last = os.time()
  else
    chats[ev.session_id] = { cwd = ev.cwd, last = os.time() }
  end
  for _, reservation in pairs(active) do
    if reservation.child == ev.session_id then reservation.started = true end
  end
end)

-- An agent's turn ending frees its slot and adds its answer to its group.
bone.hook("turn_end", function(ev)
  busy[ev.session_id] = nil
  local seen = children[ev.session_id] or chats[ev.session_id]
  if seen then seen.last = os.time() end
  for token, reservation in pairs(active) do
    if reservation.child == ev.session_id
      or (not reservation.started and reservation.parent == ev.session_id) then
      active[token] = nil
    end
  end
  local c = children[ev.session_id]
  local g = c and c.group
  if not g then return end
  c.group = nil
  local outcome = ev.outcome or {}
  g.done[#g.done + 1] = answer(c.name, c, outcome.status, outcome.message, last_reply(ev.session_id))
  g.pending[ev.session_id] = nil
  settle(g)
end)

-- Wait for a free slot. A nested call fails instead: its parent holds a
-- slot, so waiting there could deadlock.
local function reserve(nested, parent)
  while true do
    local count, cap = 0, integer("max_concurrent", 8)
    for _ in pairs(active) do count = count + 1 end
    if cap == 0 or count < cap then break end
    if nested then return nil, "maximum concurrent sub-agents reached; finish an existing task before delegating again" end
    if not bone.sleep(250) then return nil, "the sub-agent was cancelled" end
  end
  local token = {}
  active[token] = { parent = parent }
  return token
end

-- Run a turn on agent `id` (made by `make` when it is new), in a slot. From
-- an agent it waits and returns the answer; from a chat it returns at once,
-- and the answer joins the chat's group.
local function turn(nested, parent, make, body)
  local token, err = reserve(nested, parent)
  if not token then return nil, err end
  local id, c
  local ok, r
  ok, r, err = pcall(function()
    local made_err
    id, made_err = make()
    if not id then return nil, made_err end
    if not active[token] then return nil, "the sub-agent was cancelled" end
    active[token].child = id
    c = children[id]
    if nested then return bone.session.run(id, body) end
    local g = group_of(parent)
    g.pending[id] = true
    c.group = g
    bone.queue.add(id, body)
    if active[token] then active[token].started = true end
    return { background = true }
  end)
  if not ok or not r or not r.background then active[token] = nil end
  if not ok or not r then
    -- It never started: its group no longer waits on it.
    local g = c and c.group
    if g then
      c.group, g.pending[id] = nil, nil
      settle(g)
    end
    if not ok then return nil, tostring(r) end
    return nil, err or "the sub-agent was cancelled"
  end
  if r.background then
    return "Started " .. c.name .. ". Its answer arrives in a message together with those of the "
      .. "other agents you start this turn, once all are done. Message it meanwhile with to = \""
      .. c.name .. "\"."
  end
  local head, failed = answer(c.name, c, r.outcome and r.outcome.status, r.outcome and r.outcome.message, r.text)
  if failed then return nil, head end
  return head
end

-- Who a message is from: an agent's name, or another chat.
local function from(ctx, caller)
  if caller then return "From " .. caller.name .. ":\n\n" end
  return "From chat " .. handle(ctx.session_id) .. ' ("' .. title_of(ctx.session_id) .. '"):\n\n'
end

-- A message to an agent or chat that already exists.
local function message(args, ctx, caller, over, note)
  local root = caller and caller.root or ctx.session_id
  local id, target = find(args.to, root)
  if not id then
    -- A chat is never run and waited on: the message joins its queue.
    local chat = find_chat(args.to, ctx.session_id, caller)
    if chat == ctx.session_id then return nil, "you are main" end
    if not chat then
      return nil, "no agent or chat " .. trim(args.to) .. " you can message (list = true shows them)"
    end
    local ok, err = pcall(bone.queue.add, chat, from(ctx, caller) .. args.prompt, "steer", nil, "agent")
    if not ok then return nil, tostring(err) end
    return "Delivered to " .. (caller and "main" or ("chat " .. handle(chat)))
      .. (busy[chat] and ", which reads it before its next step." or ", which starts a turn for it.")
  end
  if id == ctx.session_id then return nil, "an agent cannot message itself" end
  local body = args.prompt
  if target.parent ~= ctx.session_id then body = from(ctx, caller) .. body end
  if busy[id] then
    local ok, err = pcall(bone.queue.add, id, body, "steer", nil, "agent")
    if not ok then return nil, tostring(err) end
    return "Delivered: " .. target.name .. " is still working and reads it before its next step."
  end
  if over or note then target.override, target.note = over, note end
  return turn(caller ~= nil, ctx.session_id, function() return id end, body)
end

bone.tool.register({
  name = "subagent",
  description = "Hand a self-contained task to a sub-agent. It works in a session of its own "
    .. "with the same tools, so it saves your context for broad searches, reviews and "
    .. "independent pieces of work. It cannot see this conversation: put everything it needs "
    .. "in prompt. Give it a short name. The call returns at once and the agent works in the "
    .. "background; several can run at the same time. The agents you start in one turn answer "
    .. "together, in one message, when the last is done: keep working meanwhile, or end your "
    .. "turn if there is nothing else to do. Messages from agents start with \"From <name>:\". "
    .. "To message an agent, pass its name as to with the message as prompt: a busy one reads "
    .. "it before its next step, an idle one takes it as more work and answers again. "
    .. "list = true shows who you can message. Set provider or model only when the user asks "
    .. "for them. Before calling, tell the user in one line what you are dispatching and why; "
    .. "when the answers arrive, sum up what came back.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "A short name for a new agent (letters, digits, -), shown to the user; use it as to." },
      task = { type = "string", description = "A few words saying what a new agent does, shown to the user." },
      prompt = { type = "string", description = "The full task, with all the context it needs, or the message for to." },
      to = { type = "string", description = "An agent's name, main, or a chat from list: message it instead of starting an agent." },
      list = { type = "boolean", description = "Only show the agents and chats you can message." },
      provider = { type = "string", description = "Only when the user asks: one of the providers listed." },
      model = { type = "string", description = "Only when the user asks: a model ID for that provider." },
    },
    -- No required list: an empty Lua table would go out as {} (not []).
  },
  parallel = true,
  needs_approval = false,
  run = function(args, ctx)
    local caller = child_of(ctx.session_id)
    if args.list == true then return listing(ctx.session_id, caller) end
    -- Before the session exists: a child with no turn would show forever.
    if not text(args.prompt) then return nil, "subagent needs a prompt with the full task" end
    if caller and not allowed(spec_for(caller), "subagent") then
      return nil, "tool subagent is not allowed for this sub-agent"
    end
    local over, note = requested(args)
    if text(args.to) then return message(args, ctx, caller, over, note) end
    local setup = text(args.agent)
    local all, err = agents()
    if not all then return nil, err end
    if setup and not all[setup] then return nil, "no agent setup named " .. setup end
    local spec = copy((setup and all[setup]) or {})
    local level = depth(ctx.session_id) + 1
    if level > max_depth() then
      return nil, "sub-agents cannot start more sub-agents this deep"
    end
    local root = caller and caller.root or ctx.session_id
    return turn(caller ~= nil, ctx.session_id, function()
      local name = unique(text(args.name) or setup, root)
      local c = {
        spec = spec, depth = level, parent = ctx.session_id, root = root, name = name,
        task = text(args.task) or name, override = over, note = note,
      }
      local ok, info, create_err = pcall(bone.session.create, {
        title = c.task, model = pin(spec_for(c)),
        owner = { session_id = ctx.session_id, call_id = ctx.call_id, name = name },
      })
      if ok and info then children[info.session_id] = c end
      claimed[root .. ":" .. name] = nil
      if not ok then error(info, 0) end
      if not info then return nil, create_err end
      return info.session_id
    end, args.prompt)
  end,
})

bone.rpc.register("subagent/list", function()
  local out = {}
  local all, err = agents()
  if not all then error(err) end
  for name, spec in pairs(all) do
    local effective = spec_for({ spec = spec })
    out[#out + 1] = {
      name = name, provider = effective.provider, model = effective.model,
      description = spec.description,
    }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end)
