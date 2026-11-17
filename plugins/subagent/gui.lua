-- Subagents in the desktop chat, as in tui.lua: a background call's card
-- shows as running until its agent finishes. It wraps bone.ui.views.tool.
-- The plugin's own messages (source "agent") are drawn by Bone as a report.
local agents = require("bone.agents")

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local views = bone.ui.views

-- ---- the agent's card --------------------------------------------------------

-- Only views that exist are wrapped: with none (the bare library) the
-- chat is drawn plainly by bone, and stays so.
local base_tool = views.tool
if base_tool then views.tool = function(item, ctx)
  local a = item.name == "subagent" and item.done and agents.for_call(item.id)
  if a and a.started_at then
    item = copy(item)
    if a.status == "running" then
      item.done, item.duration_ms, item.started_at = false, nil, a.started_at
      bone.chat.refresh_in(1000)
    elseif a.finished_at then
      item.duration_ms = a.finished_at - a.started_at
    end
  end
  return base_tool(item, ctx)
end end

-- An agent's turn ending changes its card: draw the chat again.
bone.on("turn/finished", function(ev)
  if agents.get(ev.session_id) then bone.chat.redraw() end
end)
