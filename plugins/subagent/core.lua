-- Sub-agents run in sessions of their own, owned by the tool call that
-- started them: they use the same tools, clients show them live, and their
-- transcripts can be opened like any session. Several subagent calls in one
-- reply run at the same time.
--
-- Each answer ends with the agent's handle ([agent 1a2b3c4d]). Passing it
-- back as `session` continues that agent when it is idle, or slips the
-- message into its turn when it is still working; agents working for the
-- same top-level session can message each other the same way.
-- `background` returns at once and delivers the answer as a message.
-- `provider` / `model` pick what the agent runs on; an unknown provider, or
-- one that fails, falls back to the agent's defaults.
--
-- Optional named agents, in core.lua:
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

-- children: session id -> { spec, depth, parent, root, task, override?,
-- note?, notify? } (false for sessions that are not agents).
-- busy: session ids with a turn running.
local children, active, busy = {}, {}, {}
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
-- The short name an agent goes by in answers: the end of its session id.
local function handle(id) return id:sub(-8) end
local function tool_list(value)
  if not text(value) or value:match("^%s*%*%s*$") then return nil end
  if value:match("^%s*none%s*$") or value:match("^%s*%[%]%s*$") then return {} end
  local list = {}
  for name in value:gmatch("[^,%s]+") do list[#list + 1] = name end
  return list
end
-- A per-call provider/model (c.override) wins over the named agent's and the
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
-- A child from before a restart: the owner (and named agent) is in the
-- session header, so its role, whitelist and depth survive the registry.
function child_of(id)
  local c = children[id]
  if c == nil and id then
    local ok, info = pcall(bone.session.info, id)
    local o = ok and type(info) == "table" and info.owner
    if o then
      local p = child_of(o.session_id)
      c = {
        spec = (agents() or {})[o.name] or {}, depth = (p and p.depth or 0) + 1,
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
      for name in pairs(list) do
        if type(name) == "string" and not seen[name] then
          seen[name] = true
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

-- The agent `name` names for `root` (a handle or a full session id).
local function find(name, root)
  name = trim(name):gsub("^agent%s+", "")
  for id, c in pairs(children) do
    if c and c.root == root and (id == name or handle(id) == name) then return id, c end
  end
  if #name > 8 then
    local c = child_of(name)
    if c and c.root == root then return name, c end
  end
end

local function roster(all)
  local names = {}
  for name, spec in pairs(all) do
    names[#names + 1] = "- " .. name .. (text(spec.description) and (": " .. spec.description) or "")
  end
  table.sort(names)
  return #names > 0 and ("\n\nNamed sub-agents (pass as name):\n" .. table.concat(names, "\n")) or ""
end

-- The other agents working for the same top-level session as `id`.
local function peers(id, c)
  local out = {}
  for other, o in pairs(children) do
    if o and other ~= id and o.root == c.root then
      out[#out + 1] = "- " .. handle(other) .. ": " .. (o.task or "agent")
    end
  end
  table.sort(out)
  return out
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

-- An agent's answer for the model: its text (or what it did before it
-- failed), any fallback note, and its handle for follow-ups.
local function answer(id, c, status, message, body)
  body = trim(body or "")
  local tail = (c and c.note and ("\n\n(" .. c.note .. ")") or "") .. "\n\n[agent " .. handle(id) .. "]"
  if c then c.note = nil end
  if status == "failed" or status == "cancelled" then
    local head = status == "failed" and ("the sub-agent failed: " .. tostring(message))
      or "the sub-agent was cancelled"
    if body ~= "" then head = head .. "\n\nIts work so far:\n" .. body end
    return nil, head .. tail
  end
  return (body ~= "" and body or "(the sub-agent gave no answer)") .. tail
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
  local others = c and peers(ev.session_id, c) or {}
  local tools = {}
  for _, t in ipairs(ev.tools or {}) do
    -- Too deep to start agents, a child still messages the others.
    if allowed(spec, t.name) and (t.name ~= "subagent" or not deep or #others > 0) then
      if t.name == "subagent" then
        local names = providers()
        t.description = t.description .. roster(all)
          .. (#names > 0 and ("\n\nProviders: " .. table.concat(names, ", ") .. ".") or "")
        if #others > 0 then
          t.description = t.description .. "\n\nOther agents on this task (pass the handle as "
            .. "session to message one):\n" .. table.concat(others, "\n")
        end
        if deep then
          t.description = t.description .. "\n\nYou cannot start new sub-agents: "
            .. "use session to message the agents above."
        end
        t.parameters.properties.name = next(all) and not deep and {
          type = "string", description = "A named sub-agent, if any are listed.",
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
  local what = c.override.provider or c.override.model
  c.override = nil
  local fallback = spec_for(c).provider or bone.config.provider
  if not fallback then return end
  c.note = what .. " failed (" .. tostring(ev.error):sub(1, 120) .. "); used " .. fallback
  return { retry = 0, provider = fallback }
end)

-- Also enforce whitelists on calls, not just advertised tool definitions.
bone.hook("tool_call", function(ev)
  local c = child_of(ev.session_id)
  if c and not allowed(spec_for(c), ev.name) then
    return { deny = "tool " .. ev.name .. " is not allowed for this sub-agent" }
  end
end)

-- A cancelled wait returns before a started child stops: its slot is kept
-- until that turn ends. One whose child never began a turn is freed by the
-- parent's turn_end, or the slot would leak.
bone.hook("turn_start", function(ev)
  busy[ev.session_id] = true
  for _, reservation in pairs(active) do
    if reservation.child == ev.session_id then reservation.started = true end
  end
end)

bone.hook("turn_end", function(ev)
  busy[ev.session_id] = nil
  for token, reservation in pairs(active) do
    if reservation.child == ev.session_id
      or (not reservation.started and reservation.parent == ev.session_id) then
      active[token] = nil
    end
  end
  -- A background agent's answer goes to whoever started this turn.
  local c = children[ev.session_id]
  if c and c.notify then
    local to = c.notify
    c.notify = nil
    local outcome = ev.outcome or {}
    local report, err = answer(ev.session_id, c, outcome.status, outcome.message, last_reply(ev.session_id))
    pcall(bone.queue.add, to, "Background sub-agent (" .. (c.task or "agent") .. ") "
      .. (report and "finished" or "stopped") .. ":\n\n" .. (report or err), "steer")
  end
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

-- Run a turn on agent `id` (made by `make` when it is new), in a slot.
local function turn(nested, parent, background, make, body)
  local token, err = reserve(nested, parent)
  if not token then return nil, err end
  local id
  local ok, r
  ok, r, err = pcall(function()
    local made_err
    id, made_err = make()
    if not id then return nil, made_err end
    if not active[token] then return nil, "the sub-agent was cancelled" end
    active[token].child = id
    if background then
      children[id].notify = parent
      bone.queue.add(id, body)
      if active[token] then active[token].started = true end
      return { background = true }
    end
    return bone.session.run(id, body)
  end)
  local reservation = active[token]
  -- nil without an error means the wait was cancelled, not that the child
  -- finished; a background child keeps its slot until its turn ends.
  local keep = ok and ((r and r.background) or (not r and not err and reservation and reservation.started))
  if not keep then active[token] = nil end
  if not ok then
    if id and children[id] then children[id].notify = nil end
    return nil, tostring(r)
  end
  if not r then return nil, err or "the sub-agent was cancelled" end
  local c = children[id]
  if r.background then
    return "Started in the background; its answer will arrive as a message.\n\n[agent " .. handle(id) .. "]"
  end
  local status = r.outcome and r.outcome.status
  return answer(id, c, status, r.outcome and r.outcome.message, r.text)
end

-- A message to an agent that already exists.
local function message(args, ctx, caller, over, note)
  local root = caller and caller.root or ctx.session_id
  local id, target = find(args.session, root)
  if not id then return nil, "no agent " .. trim(args.session) .. " working on this task" end
  if id == ctx.session_id then return nil, "an agent cannot message itself" end
  local body = args.prompt
  if target.parent ~= ctx.session_id then
    body = "Message from " .. (caller and ("agent " .. handle(ctx.session_id) .. " (" .. (caller.task or "agent") .. ")")
      or "the main agent") .. "; to reply, message it back with the subagent tool:\n\n" .. body
  end
  if busy[id] then
    local ok, err = pcall(bone.queue.add, id, body, "steer")
    if not ok then return nil, tostring(err) end
    return "Delivered: agent " .. handle(id) .. " is still working and reads it before its next step."
  end
  if over or note then target.override, target.note = over, note end
  return turn(caller ~= nil, ctx.session_id, args.background == true, function() return id end, body)
end

bone.tool.register({
  name = "subagent",
  description = "Hand a self-contained task to a sub-agent. It works in a session of its own "
    .. "with the same tools and returns only its final answer, so it saves your context for "
    .. "broad searches, reviews and independent pieces of work. It cannot see this "
    .. "conversation: put everything it needs in prompt. Several calls in one reply run at "
    .. "the same time. Each answer ends with [agent <handle>]: pass the handle as session to "
    .. "follow up with that agent, or to message one that is still working. background "
    .. "returns at once and the answer arrives later as a message. Set provider or model only "
    .. "when the user asks for them.",
  parameters = {
    type = "object",
    properties = {
      task = { type = "string", description = "A few words saying what it does, shown to the user." },
      prompt = { type = "string", description = "The full task, with all the context it needs, or the message for session." },
      name = { type = "string", description = "A named sub-agent, if any are listed." },
      session = { type = "string", description = "An existing agent's handle: continue it or message it instead of starting a new one." },
      background = { type = "boolean", description = "Return at once; the answer arrives as a message when it is done." },
      provider = { type = "string", description = "Only when the user asks: one of the providers listed." },
      model = { type = "string", description = "Only when the user asks: a model ID for that provider." },
    },
    required = { "task", "prompt" },
  },
  parallel = true,
  needs_approval = false,
  run = function(args, ctx)
    -- Before the session exists: a child with no turn would show forever.
    if not text(args.prompt) then return nil, "subagent needs a prompt with the full task" end
    local caller = child_of(ctx.session_id)
    if caller and not allowed(spec_for(caller), "subagent") then
      return nil, "tool subagent is not allowed for this sub-agent"
    end
    local over, note = requested(args)
    if text(args.session) then return message(args, ctx, caller, over, note) end
    local name = text(args.name)
    local all, err = agents()
    if not all then return nil, err end
    if name and not all[name] then return nil, "no sub-agent named " .. name end
    local spec = copy((name and all[name]) or {})
    local level = depth(ctx.session_id) + 1
    if level > max_depth() then
      return nil, "sub-agents cannot start more sub-agents this deep"
    end
    return turn(caller ~= nil, ctx.session_id, args.background == true, function()
      local info, create_err = bone.session.create({
        title = args.task or name or "sub-agent",
        owner = { session_id = ctx.session_id, call_id = ctx.call_id, name = name or "agent" },
      })
      if not info then return nil, create_err end
      children[info.session_id] = {
        spec = spec, depth = level, parent = ctx.session_id,
        root = caller and caller.root or ctx.session_id,
        task = args.task or name or "sub-agent", override = over, note = note,
      }
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
