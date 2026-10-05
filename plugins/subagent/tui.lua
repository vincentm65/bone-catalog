-- /agents shows configured subagents in a small region directly below the
-- prompt, so their availability stays visible while the chat is in use.
local visible = false
local lines = {}
local region_name = "agents"

local function install_region()
  bone.ui.regions[region_name] = {
    size = "auto",
    max = 5,
    render = function()
      return visible and lines or {}
    end,
  }
  local layout = bone.ui.layout
  if type(layout) ~= "table" then
    return
  end
  for _, name in ipairs(layout) do
    if name == region_name then
      return
    end
  end
  local updated, inserted = {}, false
  for _, name in ipairs(layout) do
    updated[#updated + 1] = name
    if name == "prompt" then
      updated[#updated + 1] = region_name
      inserted = true
    end
  end
  if not inserted then
    updated[#updated + 1] = region_name
  end
  bone.ui.layout = updated
end

local function refresh()
  bone.rpc.call("subagent/list", {}, function(list, err)
    if err then
      lines = { { { "  subagent: " .. tostring(err), "ErrorMsg" } } }
    else
      lines = {}
      if #(list or {}) > 0 then
        lines[#lines + 1] = {
          { "  configured agents", "Accent" },
          { ("  %d"):format(#list), "Dim" },
        }
        for _, item in ipairs(list) do
          lines[#lines + 1] = {
            { "  " .. item.name, "Accent" },
            { "  " .. tostring(item.provider or "current"), "Dim" },
          }
        end
      else
        lines[1] = { { "  no subagents configured in core.lua", "Dim" } }
      end
    end
    bone.ui.refresh()
  end)
end

install_region()
bone.cmd.create("agents", function()
  install_region()
  visible = not visible
  if visible then
    refresh()
  else
    bone.ui.refresh()
  end
end, { desc = "show configured subagents below the prompt" })
