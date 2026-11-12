-- Subagents in the desktop chat: the same two touches as tui.lua. A
-- background call's card shows as running until its agent finishes, and
-- the plugin's own messages are a small left-aligned report (a click shows
-- all of it) rather than a bubble you typed. Both wrap bone.ui.views.
local agents = require("bone.agents")
local md = require("bone.desktop.markdown")
local style = require("bone.nodes.style")

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

-- ---- reports -----------------------------------------------------------------

local opened = {}

local function plain(text)
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = { { line, "Dim" } } end
  return out
end

local function report(item)
  local s = bone.chat.session()
  local key = (s and s.session_id or "") .. ":" .. tostring(item.index)
  local head, body = trim(item.text):match("^([^\n]*)\n?(.*)$")
  head = trim(head):gsub(":$", "")
  local node = { direction = "column", padding = { 0, 4 }, margin = { 10, 4 } }
  node[#node + 1] = md.text({ { "◆ ", "Accent" }, { head, "Dim" } }, { size = md.small_size })
  local paras = md.nodes(trim(body), "ToolOutput", { size = md.small_size, indent = 12 })
  for i, para in ipairs(paras) do
    if not opened[key] and i > PREVIEW then
      node[#node + 1] = md.text({ { "⋮ +" .. (#paras - PREVIEW) .. " more", "Dim" } },
        { size = md.small_size, indent = 12 })
      break
    end
    node[#node + 1] = para
  end
  return {
    node = style.finish(node),
    lines = plain(item.text),
    click = function()
      opened[key] = not opened[key]
      bone.chat.redraw(item.index)
    end,
  }
end

local base_user = views.user
if base_user then views.user = function(item, ctx)
  if is_report(item) then return report(item) end
  return base_user(item, ctx)
end end
