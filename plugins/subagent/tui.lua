-- Subagents in the terminal chat. A background call returns at once, so its
-- row would read done while the agent still works: it shows as running,
-- timed by the agent, until the agent's turn ends. The plugin's own
-- messages (an agent's report, a message between agents or chats) are
-- drawn as a short report rather than as something you typed; a click or
-- ctrl+t shows all of it. Both wrap the standard views (bone.ui.views).
local agents = require("bone.agents")

local OPENINGS = { "Background sub-agent (", "Message from agent ", "Message from chat " }
local PREVIEW = 3

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function is_report(item)
  local text = item.text or ""
  for _, opening in ipairs(OPENINGS) do
    if text:sub(1, #opening) == opening then return true end
  end
  return false
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- ---- the agent's row ---------------------------------------------------------

local base_tool = bone.ui.views.tool
bone.ui.views.tool = function(item, ctx)
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
end

-- ---- reports -----------------------------------------------------------------

local opened = {}
local function key(item)
  local s = bone.chat.session()
  return (s and s.session_id or "") .. ":" .. tostring(item.index)
end

local function append(out, rows)
  for _, row in ipairs(rows) do out[#out + 1] = row end
  return out
end

local function report(item, ctx)
  local full = bone.o.tool_detail == "full"
  if opened[key(item)] then full = not full end
  local head, body = trim(item.text):match("^([^\n]*)\n?(.*)$")
  head = trim(head):gsub(":$", "")
  local out = { {} }
  append(out, bone.text.wrap({ { head, "Dim" } }, ctx.width,
    { first = { { "  ◆ ", "Accent" } }, rest = { { "    ", "Dim" } } }))
  local rows = bone.ui.markdown(trim(body), math.max(ctx.width - 8, 1))
  local shown = full and #rows or math.min(#rows, PREVIEW)
  while shown > 0 and #rows[shown] == 0 do shown = shown - 1 end
  local lines = {}
  for i = 1, shown do lines[#lines + 1] = rows[i] end
  if shown < #rows then
    lines[#lines + 1] = { { "⋮ +" .. (#rows - shown) .. " lines (click or ctrl+t)", "ToolSummary" } }
  end
  for i, line in ipairs(lines) do
    local row = { { i == #lines and "    ╰ " or "    │ ", "ToolGutter" } }
    for _, span in ipairs(line) do row[#row + 1] = span end
    out[#out + 1] = row
  end
  return out
end

local base_user = bone.ui.views.user
bone.ui.views.user = function(item, ctx)
  if is_report(item) then return report(item, ctx) end
  return base_user(item, ctx)
end

-- A click (without a drag) opens or folds a report.
local press
bone.on("mouse", function(ev)
  local down = press
  press = ev.action == "down" and ev.button == "left" and not ev.popup and not ev.panel and ev or nil
  if ev.action ~= "up" or ev.button ~= "left" or not down or not ev.index
      or down.x ~= ev.x or down.y ~= ev.y or down.index ~= ev.index then
    return
  end
  local item = bone.chat.item(ev.index)
  if item and item.kind == "user" and is_report(item) then
    opened[key(item)] = not opened[key(item)]
    bone.chat.redraw(ev.index)
    return true
  end
end)
