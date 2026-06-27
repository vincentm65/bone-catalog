local menu = require("ui.menu")

local palettes = {
  nord = {
    user_msg = "#E5E9F0", user_msg_bg = "#2E3440", status_text = "#4C566A",
    input_border = "#4C566A", system_msg = "#E5E9F0", approval_safe = "#A3BE8C",
    approval_danger = "#BF616A", tool_call = "#88C0D0", tool_error = "#BF616A",
    diff_removed = "#BF616A", diff_added = "#A3BE8C", thinking = "#88C0D0",
    tab_active = "#88C0D0",
  },
  solarized = {
    user_msg = "#EEE8D5", user_msg_bg = "#002B36", status_text = "#586E75",
    input_border = "#586E75", system_msg = "#EEE8D5", approval_safe = "#859900",
    approval_danger = "#DC322F", tool_call = "#2AA198", tool_error = "#DC322F",
    diff_removed = "#DC322F", diff_added = "#859900", thinking = "#2AA198",
    tab_active = "#2AA198",
  },
  tokyo_night = {
    user_msg = "#C0CAF5", user_msg_bg = "#1A1B26", status_text = "#565F89",
    input_border = "#565F89", system_msg = "#C0CAF5", approval_safe = "#9ECE6A",
    approval_danger = "#F7768E", tool_call = "#7DCFFF", tool_error = "#F7768E",
    diff_removed = "#F7768E", diff_added = "#9ECE6A", thinking = "#7DCFFF",
    tab_active = "#BB9AF7",
  },
  catppuccin = {
    user_msg = "#CDD6F4", user_msg_bg = "#1E1E2E", status_text = "#6C7086",
    input_border = "#6C7086", system_msg = "#CDD6F4", approval_safe = "#A6E3A1",
    approval_danger = "#F38BA8", tool_call = "#89DCEB", tool_error = "#F38BA8",
    diff_removed = "#F38BA8", diff_added = "#A6E3A1", thinking = "#89DCEB",
    tab_active = "#F5C2E7",
  },
}

local names = { "catppuccin", "nord", "solarized", "tokyo_night", "default" }
local M = {}

local function reset()
  local seen = {}
  for _, pal in pairs(palettes) do
    for k in pairs(pal) do
      if not seen[k] then bone.api.ui.set_highlight(k, nil); seen[k] = true end
    end
  end
  M.current = nil
end

function M.apply(name)
  local pal = palettes[name]
  if not pal then return false end
  for k, v in pairs(pal) do bone.api.ui.set_highlight(k, v) end
  M.current = name
  return true
end

local function save(ctx, name)
  local path = ctx.config_dir .. "/init.lua"
  local ok, content = pcall(ctx.read_file, path)
  if not ok then content = "" end

  -- Strip any prior theme-apply line — catches both `commands.themes` and the
  -- legacy `themes` module path, with or without the `-- bone theme` marker.
  content = content:gsub("\n?[^\n]*themes[^\n]*%.apply[^\n]*", "")
  content = content:gsub("\n*$", "\n")
  if name then content = content .. 'require("commands.themes").apply("' .. name .. '") -- bone theme\n' end

  if not ok then return pcall(ctx.write_file, path, content) end
  return ctx.tools.call("edit_file", { path = path, mode = "rewrite", content = content }, { approval = "danger" }).ok
end

local function set(ctx, name)
  if name == "default" then
    reset()
    local saved = save(ctx)
    return saved, saved and "Theme reset to default" or "Theme reset for this session, but failed to save"
  end
  if not M.apply(name) then
    return false, "Unknown theme: " .. tostring(name) .. ". Available: " .. table.concat(names, ", ")
  end
  local saved = save(ctx, name)
  return saved, saved and ("Theme applied: " .. name) or ("Theme applied for this session, but failed to save: " .. name)
end

if not bone._themes_command_registered then
  bone._themes_command_registered = true
  bone.register_command("themes", {
    description = "Pick or apply a color theme",
    handler = function(arg, ctx)
      local text = tostring(arg or "")
      local name = text:match("^%s*apply%s+(%S+)") or text:match("^%s*(%S+)")

      if name then
        local ok, msg = set(ctx, name)
        ctx.ui.notify(msg, ok and "info" or "error")
        return { submit = false }
      end

      -- Live preview: cursor starts on the active theme, themes swap as you
      -- scroll, Enter persists + closes, Esc reverts to the original.
      local original = M.current
      local start = 1
      for i, n in ipairs(names) do
        if n == (original or "default") then start = i; break end
      end

      local result = menu.select(ctx, {
        question = "Theme  (Enter to apply, Esc to cancel)",
        options = names,
        default = start,
        on_change = function(value)
          if value == "default" then reset() else M.apply(value) end
        end,
      })
      menu.clear(ctx)

      if not result or result.cancelled then
        if original then M.apply(original) else reset() end
        return { submit = false }
      end

      local ok, msg = set(ctx, result.value)
      ctx.ui.notify(msg, ok and "info" or "error")
      return { submit = false }
    end,
  })
end

return M
