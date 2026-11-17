-- Subagents in the terminal chat. A background call returns at once, so its
-- row would read done while the agent still works: it shows as running,
-- timed by the agent, until the agent's turn ends. It wraps the standard
-- tool view (bone.ui.views). The plugin's own messages (an agent's report,
-- a message between agents or chats) are queued with source "agent", and
-- Bone draws those as a short report itself.
local agents = require("bone.agents")

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- ---- the agent's row ---------------------------------------------------------

-- Only views that exist are wrapped: with none (the bare library) the
-- chat is plain text drawn by bone, and stays so.
local base_tool = bone.ui.views.tool
if base_tool then bone.ui.views.tool = function(item, ctx)
  local a = item.name == "subagent" and item.done and agents.for_call(item.id)
  if a and a.started_at then
    item = copy(item)
    if a.status == "running" then
      -- Drawn as the call still running: its mark, "running" and a clock.
      item.done, item.duration_ms, item.started_at = false, nil, a.started_at
    elseif a.finished_at then
      item.duration_ms = a.finished_at - a.started_at
    end
  end
  return base_tool(item, ctx)
end end
