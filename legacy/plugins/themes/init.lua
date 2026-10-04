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

function M.preview(name)
  local ok, err = pcall(function() bone.theme.preview(name) end)
  if not ok then return false, tostring(err) end
  return true
end

local function available_message(names)
  if #names == 0 then
    return "No themes installed. Install one from /catalog first."
  end
  return "Available themes: " .. table.concat(names, ", ")
end

local THEME_USAGE = "Usage: /themes [apply <name>|<name>]"

local function parse_theme_arg(arg)
  local value = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return nil end

  local applied = value:match("^apply%s+(%S+)$")
  if applied then return applied end

  local direct = value:match("^(%S+)$")
  if direct and direct ~= "apply" then return direct end
  return nil, THEME_USAGE
end

if not bone._themes_command_registered then
  bone._themes_command_registered = true
  bone.command.register("themes", {
    description = "Pick or apply an installed color theme",
    handler = function(arg, ctx)
      local name, arg_err = parse_theme_arg(arg)
      if arg_err then
        ctx.ui.notify(arg_err, "error")
        return { submit = false }
      end

      local names, list_err = M.list()
      if not names then
        ctx.ui.notify("Could not list themes: " .. list_err, "error")
        return { submit = false }
      end

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

      local original = bone.settings.get("theme.name")
      local start = 1
      for i, candidate in ipairs(names) do
        if candidate == original then start = i; break end
      end

      local preview_err
      local select_ok, result = pcall(menu.select, ctx, {
        question = "Choose a theme  (Enter to apply, Esc to cancel)",
        options = names,
        default = start,
        on_change = function(value)
          local ok, err = M.preview(value)
          if not ok then preview_err = err end
        end,
      })
      local clear_ok, clear_err = pcall(menu.clear, ctx)

      local function restore(message)
        local ok, err = M.preview(nil)
        if not ok then message = message .. "; could not restore configured theme: " .. err end
        if not clear_ok then message = message .. "; could not clear picker: " .. tostring(clear_err) end
        return message
      end

      if not select_ok then
        ctx.ui.notify(restore("Theme picker failed: " .. tostring(result)), "error")
        return { submit = false }
      end
      if not result or result.cancelled then
        local message = preview_err and ("Could not preview theme: " .. preview_err) or nil
        if message or not clear_ok then
          ctx.ui.notify(restore(message or "Theme picker cleanup failed"), "error")
        else
          local ok, err = M.preview(nil)
          if not ok then ctx.ui.notify("Could not restore configured theme: " .. err, "error") end
        end
        return { submit = false }
      end

      local ok, message = M.apply(result.value)
      if not ok then message = restore(message .. ". " .. available_message(names)) end
      if ok and not clear_ok then
        ok = false
        message = message .. "; could not clear picker: " .. tostring(clear_err)
      end
      ctx.ui.notify(message, ok and "info" or "error")
      return { submit = false }
    end,
  })
end

return M
