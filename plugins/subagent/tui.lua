-- Show live subagent tool calls in a small region directly below the prompt.
-- The region follows the old Bone jobs pane: it appears while agents run and
-- disappears again when the last call finishes.
local visible = true
local running = {}
local order = {}
local region_name = "agents"

local function install_region()
  bone.ui.regions[region_name] = {
    size = "auto",
    max = 6,
    render = function(ctx)
      if not visible or #order == 0 then
        return {}
      end

      local width = (ctx and tonumber(ctx.width)) or 80
      local out = {
        {
          { "  Agents (" .. #order .. ")", "Accent" },
          { "  running", "Dim" },
        },
      }
      for _, id in ipairs(order) do
        local item = running[id]
        if item then
          local task = (item.prompt or "working"):gsub("%s+", " ")
          local prefix = "  ◑ " .. item.name .. "  "
          local suffix = "  running"
          local room = math.max(width - #prefix - #suffix, 1)
          out[#out + 1] = {
            { prefix, "Accent" },
            { bone.text.truncate(task, room), "Dim" },
            { suffix, "Dim" },
          }
        end
      end
      return out
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

local function remove(id)
  if not running[id] then
    return false
  end
  running[id] = nil
  for i, current in ipairs(order) do
    if current == id then
      table.remove(order, i)
      break
    end
  end
  return true
end

local function arguments(call)
  if type(call and call.arguments) == "table" then
    return call.arguments
  end
  if type(call and call.arguments) == "string" then
    local ok, decoded = pcall(bone.json.decode, call.arguments)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return {}
end

local function redraw()
  if visible then
    bone.ui.refresh()
  end
end

install_region()

bone.on("tool/started", function(ev)
  local call = ev and ev.call
  if not call or call.name ~= "subagent" or not call.id then
    return
  end
  local args = arguments(call)
  running[call.id] = {
    name = tostring(args.name or "default"),
    prompt = tostring(args.prompt or "working"),
    started_at = ev.started_at,
  }
  for _, id in ipairs(order) do
    if id == call.id then
      redraw()
      return
    end
  end
  order[#order + 1] = call.id
  redraw()
end)

bone.on("tool/finished", function(ev)
  if ev and ev.call_id and remove(ev.call_id) then
    redraw()
  end
end)

bone.cmd.create("agents", function()
  install_region()
  visible = not visible
  bone.ui.refresh()
end, { desc = "show or hide running subagents below the prompt" })
