local menu = require("ui.menu")

local themes = {
  nord = {
    palette = {
      bg = "#0B0F14",
      fg = "#E5E9F0",
      muted = "#4C566A",
      subtle = "#3B4252",
      border = "#4C566A",
      accent = "#88C0D0",
      good = "#A3BE8C",
      warn = "#EBCB8B",
      error = "#BF616A",
      selection = "#3B4252",
    },
    tab_active = "#88C0D0",
  },
  solarized = {
    palette = {
      bg = "#001014",
      fg = "#EEE8D5",
      muted = "#586E75",
      subtle = "#073642",
      border = "#586E75",
      accent = "#2AA198",
      good = "#859900",
      warn = "#B58900",
      error = "#DC322F",
      selection = "#073642",
    },
    tab_active = "#2AA198",
  },
  tokyo_night = {
    palette = {
      bg = "#080912",
      fg = "#C0CAF5",
      muted = "#565F89",
      subtle = "#24283B",
      border = "#565F89",
      accent = "#7DCFFF",
      good = "#9ECE6A",
      warn = "#E0AF68",
      error = "#F7768E",
      selection = "#283457",
    },
    tab_active = "#BB9AF7",
  },
  catppuccin = {
    palette = {
      bg = "#0B0A12",
      fg = "#CDD6F4",
      muted = "#6C7086",
      subtle = "#313244",
      border = "#6C7086",
      accent = "#89DCEB",
      good = "#A6E3A1",
      warn = "#F9E2AF",
      error = "#F38BA8",
      selection = "#313244",
    },
    tab_active = "#F5C2E7",
  },
}

local names = { "catppuccin", "nord", "solarized", "tokyo_night", "default" }
local M = {}

local function highlights(theme)
  local p = theme.palette
  return {
    bg = p.bg,
    user_msg = p.fg,
    user_msg_bg = p.selection,
    status_text = p.muted,
    input_border = p.border,
    system_msg = p.fg,
    approval_safe = p.good,
    approval_danger = p.error,
    tool_call = p.accent,
    tool_error = p.error,
    thinking = p.accent,
    tab_active = theme.tab_active or p.accent,
  }
end

local function reset()
  local seen = {}
  for _, theme in pairs(themes) do
    for k in pairs(highlights(theme)) do
      if not seen[k] then bone.api.ui.set_highlight(k, nil); seen[k] = true end
    end
  end
  M.current = nil
end

function M.apply(name)
  local theme = themes[name]
  if not theme then return false end
  for k, v in pairs(highlights(theme)) do bone.api.ui.set_highlight(k, v) end
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
