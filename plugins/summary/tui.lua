local summary = require("summary")
local original = bone.ui.views.assistant
local base = original or function(item, ctx)
  return bone.text.wrap({ { item.text or "", "Normal" } }, ctx.width)
end

local function add(out, rows)
  for _, row in ipairs(rows or {}) do
    out[#out + 1] = row
  end
end

local function summary_lines(item, width)
  local text = summary.get(item)
  local out = {}
  local first = true
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local prefix = first and "  Summary: " or "           "
    out[#out + 1] = { { prefix .. bone.text.truncate(line, math.max(width - #prefix, 1)), "Dim" } }
    first = false
  end
  if first then
    out[#out + 1] = { { "  Summary: preparing…", "Dim" } }
  end
  out[#out + 1] = { { summary.is_expanded(item) and "  click to collapse" or "  click to expand full answer", "StatusLineDim" } }
  return out
end

bone.ui.views.assistant = function(item, ctx)
  -- The view under this one draws nothing while its turn is folded: then
  -- neither does the summary.
  local full = base(item, ctx)
  if not full or not tostring(item.text or ""):match("%S") then
    return full
  end
  local out = summary_lines(item, ctx.width)
  if summary.is_expanded(item) then
    out[#out + 1] = { { "  Full answer", "Accent" } }
    add(out, full)
  end
  return out
end

bone.plugin.on_shutdown(function()
  if bone.ui.views.assistant then
    bone.ui.views.assistant = original
  end
end)
