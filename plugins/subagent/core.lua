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
--     tools = { "read_file", "shell" },         -- allowed tools (default: all)
--   }
bone.config.subagents = bone.config.subagents or {}

-- Sub-agents may start sub-agents this many levels deep.
local MAX_DEPTH = 2
local ROLE = "You are a sub-agent: another agent gave you one task. "
  .. "Work on it with your tools, then reply with only what the other agent "
  .. "needs (findings, file paths, conclusions), briefly. It cannot see your "
  .. "tool calls, only your final reply."

-- Sessions this plugin started: id -> { spec, depth }.
local children = {}

local function depth(session_id)
  local c = children[session_id]
  return c and c.depth or 0
end

local function allowed(spec, name)
  if not spec.tools then
    return true
  end
  for _, t in ipairs(spec.tools) do
    if t == name then
      return true
    end
  end
  return false
end

-- The named agents, for the tool description.
local function roster()
  local names = {}
  for name, spec in pairs(bone.config.subagents) do
    names[#names + 1] = "- " .. name .. (spec.description and (": " .. spec.description) or "")
  end
  table.sort(names)
  if #names == 0 then
    return ""
  end
  return "\n\nNamed sub-agents (pass as name):\n" .. table.concat(names, "\n")
end

bone.hook("system", function(ev)
  local c = children[ev.session_id]
  if c then
    return { prompt = (c.spec.system or ROLE) .. "\n\n" .. (ev.prompt or "") }
  end
end)

bone.hook("request", function(ev)
  local c = children[ev.session_id]
  local spec = c and c.spec or {}
  local deep = depth(ev.session_id) >= MAX_DEPTH
  local tools = {}
  for _, t in ipairs(ev.tools or {}) do
    if t.name == "subagent" then
      if not deep then
        t.description = t.description .. roster()
        tools[#tools + 1] = t
      end
    elseif allowed(spec, t.name) then
      tools[#tools + 1] = t
    end
  end
  return { tools = tools, provider = spec.provider }
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
    if name and not bone.config.subagents[name] then
      return nil, "no sub-agent named " .. name
    end
    local spec = (name and bone.config.subagents[name]) or {}
    local level = depth(ctx.session_id) + 1
    if level > MAX_DEPTH then
      return nil, "sub-agents cannot start more sub-agents this deep"
    end
    local info, err = bone.session.create({
      title = args.task or name or "sub-agent",
      owner = { session_id = ctx.session_id, call_id = ctx.call_id, name = name or "agent" },
    })
    if not info then
      return nil, err
    end
    children[info.session_id] = { spec = spec, depth = level }
    local r
    r, err = bone.session.run(info.session_id, args.prompt or "")
    if not r then
      return nil, err or "the sub-agent failed"
    end
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
  for name, spec in pairs(bone.config.subagents) do
    out[#out + 1] = { name = name, provider = spec.provider, description = spec.description }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end)
