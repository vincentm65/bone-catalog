-- Sub-agents run in sessions of their own, owned by the tool call that
-- started them: they use the same tools, clients show them live, and their
-- transcripts can be opened like any session. Several subagent calls in one
-- reply run at the same time.
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

local children, active = {}, {}
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
local function integer(key, default)
  local value = setting(key)
  if type(value) ~= "number" or value ~= value or value == math.huge then return default end
  return math.max(0, math.floor(value))
end
local function max_depth()
  local limit = integer("max_depth", 2)
  return setting("allow_nested") == false and math.min(limit, 1) or limit
end
local function depth(id) return children[id] and children[id].depth or 0 end
local function tool_list(value)
  if not text(value) or value:match("^%s*%*%s*$") then return nil end
  if value:match("^%s*none%s*$") or value:match("^%s*%[%]%s*$") then return {} end
  local list = {}
  for name in value:gmatch("[^,%s]+") do list[#list + 1] = name end
  return list
end
local function spec_for(c)
  local spec = c and c.spec or {}
  return {
    system = text(spec.system) or text(setting("system")) or ROLE,
    provider = text(spec.provider) or text(setting("provider")),
    model = text(spec.model) or text(setting("model")),
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
local function roster(all)
  local names = {}
  for name, spec in pairs(all) do
    names[#names + 1] = "- " .. name .. (text(spec.description) and (": " .. spec.description) or "")
  end
  table.sort(names)
  return #names > 0 and ("\n\nNamed sub-agents (pass as name):\n" .. table.concat(names, "\n")) or ""
end

bone.hook("system", function(ev)
  local c = children[ev.session_id]
  if c then return { prompt = spec_for(c).system .. "\n\n" .. (ev.prompt or "") } end
end)

bone.hook("request", function(ev)
  local c = children[ev.session_id]
  -- Defaults apply only to child sessions, never to their owner.
  local spec = c and spec_for(c) or {}
  local all, err = agents()
  if not all then return { deny = err } end
  local deep = depth(ev.session_id) >= max_depth()
  local tools = {}
  for _, t in ipairs(ev.tools or {}) do
    if allowed(spec, t.name) and (t.name ~= "subagent" or not deep) then
      if t.name == "subagent" then
        t.description = t.description .. roster(all)
        t.parameters.properties.name = next(all) and {
          type = "string", description = "A named sub-agent, if any are listed.",
        } or nil
      end
      tools[#tools + 1] = t
    end
  end
  return { tools = tools, provider = spec.provider, model = spec.model }
end)

-- Also enforce whitelists on calls, not just advertised tool definitions.
bone.hook("tool_call", function(ev)
  local c = children[ev.session_id]
  if c and not allowed(spec_for(c), ev.name) then
    return { deny = "tool " .. ev.name .. " is not allowed for this sub-agent" }
  end
end)

-- A cancelled wait returns before the child stops; retain its slot until turn_end.
bone.hook("turn_end", function(ev)
  for token, reservation in pairs(active) do
    if reservation.child == ev.session_id
      or (not reservation.child and reservation.parent == ev.session_id) then
      active[token] = nil
    end
  end
end)

bone.tool.register({
  name = "subagent",
  description = "Hand a self-contained task to a sub-agent. It works in a session of its own "
    .. "with the same tools and returns only its final answer, so it saves your context for "
    .. "broad searches, reviews and independent pieces of work. It cannot see this "
    .. "conversation: put everything it needs in prompt. Several calls in one reply run at "
    .. "the same time.",
  parameters = {
    type = "object",
    properties = {
      task = { type = "string", description = "A few words saying what it does, shown to the user." },
      prompt = { type = "string", description = "The full task, with all the context it needs." },
      name = { type = "string", description = "A named sub-agent, if any are listed." },
    },
    required = { "task", "prompt" },
  },
  parallel = true,
  needs_approval = false,
  run = function(args, ctx)
    local name = args.name
    if name == "" then
      name = nil
    end
    local all, err = agents()
    if not all then return nil, err end
    if name and not all[name] then return nil, "no sub-agent named " .. name end
    local parent = children[ctx.session_id]
    if parent and not allowed(spec_for(parent), "subagent") then
      return nil, "tool subagent is not allowed for this sub-agent"
    end
    local spec = copy((name and all[name]) or {})
    local level = depth(ctx.session_id) + 1
    if level > max_depth() then
      return nil, "sub-agents cannot start more sub-agents this deep"
    end
    local count = 0
    for _ in pairs(active) do count = count + 1 end
    local cap = integer("max_concurrent", 8)
    if cap > 0 and count >= cap then
      return nil, "maximum concurrent sub-agents reached; finish an existing task before delegating again"
    end
    local token = {}
    active[token] = { parent = ctx.session_id }
    local ok, r
    ok, r, err = pcall(function()
      local info, create_err = bone.session.create({
        title = args.task or name or "sub-agent",
        owner = { session_id = ctx.session_id, call_id = ctx.call_id, name = name or "agent" },
      })
      if not info then return nil, create_err end
      if not active[token] then return nil, "the sub-agent was cancelled" end
      active[token].child = info.session_id
      children[info.session_id] = { spec = spec, depth = level }
      return bone.session.run(info.session_id, args.prompt or "")
    end)
    local reservation = active[token]
    -- nil without an error means the wait was cancelled, not that the child finished.
    if not (ok and not r and not err and reservation and reservation.child) then
      active[token] = nil
    end
    if not ok then return nil, tostring(r) end
    if not r then return nil, err or "the sub-agent failed" end
    local status = r.outcome and r.outcome.status
    if status == "failed" then
      return nil, "the sub-agent failed: " .. tostring(r.outcome.message)
    elseif status == "cancelled" then
      return nil, "the sub-agent was cancelled"
    end
    local text = (r.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or "(the sub-agent gave no answer)"
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
