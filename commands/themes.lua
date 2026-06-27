-- themes — built-in color palettes for bone's TUI renderer.
--
-- Uses bone.api.ui.set_highlight() for runtime color swaps. No Rust changes.
--
-- Usage:
--   -- Interactive: /themes
--   -- Apply by name: /themes apply <nord|solarized|tokyo_night|catppuccin>

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

local HIGHLIGHTS = {
  "user_msg", "user_msg_bg", "status_text", "input_border", "system_msg",
  "approval_safe", "approval_danger", "tool_call", "tool_error",
  "diff_removed", "diff_added", "thinking", "tab_active",
}

local function apply_palette(ctx, name)
  local pal = palettes[name]
  if not pal then
    ctx.ui.notify("Unknown theme: " .. name, "error")
    return false
  end
  for _, field in ipairs(HIGHLIGHTS) do
    bone.api.ui.set_highlight(field, pal[field])
  end
  ctx.ui.notify("Theme applied: " .. name, "info")
  return true
end

bone.register_command("themes", {
  description = "Apply built-in color palettes (nord, solarized, tokyo_night, catppuccin)",
  handler = function(arg, ctx)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do
      words[#words + 1] = w
    end

    -- Direct apply: /themes apply <name> or /themes <name>
    if #words >= 2 and words[1] == "apply" then
      return apply_palette(ctx, words[2]) and { submit = false }
    elseif #words >= 1 and palettes[words[1]] then
      return apply_palette(ctx, words[1]) and { submit = false }
    end

    -- Interactive picker — stays open so user can swap themes live.
    -- Enter selects a theme and re-shows; Esc closes and keeps last applied.
    -- Cursor position persists across selections.
    local names = {}
    for name in pairs(palettes) do
      names[#names + 1] = name
    end
    table.sort(names)

    local sel = 1
    while true do
      local result = menu.select(ctx, {
        question = "Select a color theme (Esc to close)",
        options = names,
        default = sel,
      })
      if not result or result.cancelled then
        menu.clear(ctx)
        return { submit = false }
      end
      sel = result.selected or sel
      apply_palette(ctx, result.value)
    end
  end,
})
