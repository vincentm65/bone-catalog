-- Desktop presentation. Show the prediction in the composer's native input:
-- as its placeholder while empty, and as ghost text after a matching prefix.
-- Tab and Escape still go through bone.ui.actions, so the suggestion never
-- takes focus or adds controls above the composer.
local core = require("prompt_suggestions")
core.install()

local function prompt_focused()
  local keymap = bone.keymap
  if type(keymap) == "table" and type(keymap.current) == "function" and keymap.current() == "popup" then
    return false
  end
  local panel = bone.ui and bone.ui.panel
  if type(panel) == "table" and type(panel.focused) == "function" and panel.focused() then
    return false
  end
  if type(bone.gui.focused) == "function" and bone.gui.focused() then return false end
  return true
end

local function visible_ctx()
  local ctx = bone.prompt.info()
  ctx.focused = prompt_focused()
  return ctx
end

core.on_change = function()
  if type(bone.gui.invalidate) == "function" then bone.gui.invalidate() end
end

local prompt, previous_placeholder, previous_highlight, previous_complete, previous_dismiss
local placeholder, highlight, complete, dismiss

-- Preserve the final UI supplied by the user's ui.lua or gui.lua. Install
-- again at ready because user config runs after plugins and may replace it.
local function decorate()
  prompt = bone.ui.prompt or {}
  bone.ui.prompt = prompt
  if not placeholder or prompt.placeholder ~= placeholder then
    local old = prompt.placeholder
    previous_placeholder = old
    placeholder = function(ctx)
      local current = visible_ctx()
      if current.text == "" and core.suffix(current) then
        return { { core.suggestion(), "Placeholder" } }
      end
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
      ctx.focused = true -- action is routed to the prompt, not a focused node
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
      -- Slash-menu and other UI handlers keep their precedence.
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
  core.on_change = nil
  if prompt and prompt.placeholder == placeholder then prompt.placeholder = previous_placeholder end
  if bone.ui.prompt_highlight == highlight then bone.ui.prompt_highlight = previous_highlight end
  if bone.ui.actions.complete == complete then bone.ui.actions.complete = previous_complete end
  if bone.ui.actions.dismiss == dismiss then bone.ui.actions.dismiss = previous_dismiss end
end)
