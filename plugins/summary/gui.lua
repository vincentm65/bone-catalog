local summary = require("summary")
local original = bone.ui.views.assistant
local md = require("bone.desktop.markdown")
local base = original or function(item)
  return { node = md.nodes(item.text or ""), lines = { { { item.text or "", "Normal" } } } }
end

local function summary_lines(item, width)
  local text = summary.get(item)
  local out = {}
  local first = true
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local prefix = first and "Summary: " or "         "
    out[#out + 1] = { { prefix .. bone.text.truncate(line, math.max(width - #prefix, 1)), "Dim" } }
    first = false
  end
  out[#out + 1] = { { summary.is_expanded(item) and "click to collapse" or "click to expand full answer", "StatusLineDim" } }
  return out
end

local function toggle(item)
  summary.toggle(item)
  bone.chat.redraw(item.index)
end

local function summary_node(item)
  return {
    direction = "column",
    margin = { 0, 4 },
    md.text({ { "Summary", "Accent" } }, { size = md.small_size }),
    md.text({ { summary.get(item), "Dim" } }, { size = md.small_size }),
    {
      text = summary.is_expanded(item) and "Click to collapse" or "Click to expand full answer",
      hl = "StatusLineDim",
      size = md.small_size,
      cursor = "pointer",
      role = "button",
      on_click = function() toggle(item) end,
    },
  }
end

bone.ui.views.assistant = function(item, ctx)
  -- The view under this one draws nothing while its turn is folded: then
  -- neither does the summary.
  local full = base(item, ctx)
  if not full or not tostring(item.text or ""):match("%S") then
    return full
  end
  local lines = summary_lines(item, ctx.width)
  local summary_view = summary_node(item)
  if not summary.is_expanded(item) then
    return { node = summary_view, lines = lines }
  end

  lines[#lines + 1] = {}
  for _, line in ipairs(full.lines or {}) do
    lines[#lines + 1] = line
  end
  return {
    node = { direction = "column", summary_view, full.node },
    lines = lines,
  }
end

bone.plugin.on_shutdown(function()
  if bone.ui.views.assistant then
    bone.ui.views.assistant = original
  end
end)
