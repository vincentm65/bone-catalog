-- Terminal prompt decoration only. Generation and cancellation live in
-- lua/prompt_suggestions.lua (loaded from ui.lua). This file must not run
-- in the GUI: it wraps bone.ui.prompt, which the desktop composer ignores.
local core = require("prompt_suggestions")
core.install()

local prompt, previous_placeholder, previous_highlight, previous_complete, previous_dismiss
local placeholder, highlight, complete, dismiss

-- Preserve the final UI supplied by the user's tui.lua or library. Install
-- again at ready because user config runs after plugins and may replace it.
local function decorate()
  prompt = bone.ui.prompt or {}
  bone.ui.prompt = prompt
  if not placeholder or prompt.placeholder ~= placeholder then
    local old = prompt.placeholder
    previous_placeholder = old
    placeholder = function(ctx)
      if core.suffix(ctx) then return { { core.suggestion(), "Placeholder" } } end
      if type(old) == "function" then return old(ctx) end
      return old or {}
    end
    prompt.placeholder = placeholder
  end
  if not highlight or bone.ui.prompt_highlight ~= highlight then
    local old = bone.ui.prompt_highlight
    previous_highlight = old
    highlight = function(ctx)
      local original = old and old(ctx) or {}
      local marks = {}
      for key, value in pairs(original) do marks[key] = value end
      local rest = core.suffix(ctx)
      if rest and not marks.ghost then
        marks.ghost, marks.ghost_hl = rest, "Placeholder"
      end
      return marks
    end
    bone.ui.prompt_highlight = highlight
  end
  if not complete or bone.ui.actions.complete ~= complete then
    local old = bone.ui.actions.complete
    previous_complete = old
    complete = function()
      local ctx = bone.prompt.info()
      ctx.focused = true -- action is routed to the prompt, not popup/panel Tab
      local rest = core.suffix(ctx)
      local visible = ctx.text == ""
      if rest and not visible and bone.ui.prompt_highlight then
        local marks = bone.ui.prompt_highlight(ctx) or {}
        visible = marks.ghost == rest
      end
      if rest and visible then return core.accept() end
      return old and old() or false
    end
    bone.ui.actions.complete = complete
  end
  if not dismiss or bone.ui.actions.dismiss ~= dismiss then
    local old = bone.ui.actions.dismiss
    previous_dismiss = old
    dismiss = function()
      -- Slash-menu dismissal and other UI handlers keep their precedence.
      if old and old() then return true end
      if core.pending() then
        core.clear()
        return true
      end
      return false
    end
    bone.ui.actions.dismiss = dismiss
  end
end

decorate()
bone.on("ready", decorate)

bone.plugin.on_shutdown(function()
  if prompt and prompt.placeholder == placeholder then prompt.placeholder = previous_placeholder end
  if bone.ui.prompt_highlight == highlight then bone.ui.prompt_highlight = previous_highlight end
  if bone.ui.actions.complete == complete then bone.ui.actions.complete = previous_complete end
  if bone.ui.actions.dismiss == dismiss then bone.ui.actions.dismiss = previous_dismiss end
end)
