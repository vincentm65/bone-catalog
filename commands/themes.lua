local menu = require("ui.menu")

local M = {}

function M.list()
  local ok, names = pcall(function() return bone.theme.list() end)
  if not ok then return nil, tostring(names) end
  return names
end

function M.apply(name)
  local ok, err = pcall(function() bone.theme.load(name) end)
  if not ok then return false, tostring(err) end
  return true, "Theme applied: " .. name
end

local function available_message(names)
  if #names == 0 then
    return "No themes installed. Install one from /catalog first."
  end
  return "Available themes: " .. table.concat(names, ", ")
end

if not bone._themes_command_registered then
  bone._themes_command_registered = true
  bone.command.register("themes", {
    description = "Pick or apply an installed color theme",
    handler = function(arg, ctx)
      local names, list_err = M.list()
      if not names then
        ctx.ui.notify("Could not list themes: " .. list_err, "error")
        return { submit = false }
      end

      local name = tostring(arg or ""):match("^%s*apply%s+(%S+)")
        or tostring(arg or ""):match("^%s*(%S+)")
      if name then
        local ok, message = M.apply(name)
        if not ok then message = message .. ". " .. available_message(names) end
        ctx.ui.notify(message, ok and "info" or "error")
        return { submit = false }
      end

      if #names == 0 then
        ctx.ui.notify(available_message(names), "info")
        return { submit = false }
      end

      local result = menu.select(ctx, {
        question = "Choose a theme",
        options = names,
      })
      menu.clear(ctx)
      if not result or result.cancelled then return { submit = false } end

      local ok, message = M.apply(result.value)
      ctx.ui.notify(message, ok and "info" or "error")
      return { submit = false }
    end,
  })
end

return M
