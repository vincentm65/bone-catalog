-- Desktop presentation. The composer does not read bone.ui.prompt or
-- bone.ui.prompt_highlight, so the prediction is a row above it. Tab and
-- Escape still go through bone.ui.actions; the row's controls are pointer
-- only and do not take keyboard focus (that would swallow editing keys).
local core = require("prompt_suggestions")
core.install()

local SLOT = "prompt-suggestions"

local function nodes_ok()
  return type(bone.has_capability) == "function" and bone.has_capability("gui.nodes")
      and type(bone.gui) == "table" and type(bone.gui.slots) == "table"
      and type(bone.gui.slots.add) == "function" and type(bone.gui.slots.remove) == "function"
end

if not nodes_ok() then return end

core.on_change = function()
  if type(bone.gui.invalidate) == "function" then bone.gui.invalidate() end
end

local previous_complete, previous_dismiss
local complete, dismiss

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

local function control(label, tooltip, click)
  return {
    text = label, label = label, tooltip = tooltip, role = "button",
    hl = "Accent", size = 12, padding = { 2, 8 }, radius = 6,
    cursor = "pointer", focusable = false, on_click = click,
    hover = { bg = "Selection" },
  }
end

local function suggesting()
  return {
    direction = "row", align = "center", gap = 8, focusable = false,
    padding = { 2, 12, 4, 12 },
    { text = "Suggesting a next prompt…", hl = "Dim", size = 12, grow = 1, wrap = false },
    control("Dismiss", "Cancel the prediction (Esc)", function()
      if core.pending() then core.clear() end
    end),
  }
end

local function row(ctx, rest)
  local typed = ctx.text
  local spans = typed ~= "" and {
    { text = typed, hl = "Dim" }, { text = rest, hl = "Placeholder" },
  } or { { text = core.suggestion(), hl = "Placeholder" } }
  return {
    direction = "row", align = "center", gap = 8, focusable = false,
    padding = { 2, 12, 4, 12 },
    tooltip = "Tab accepts the suggestion · Esc dismisses it",
    { text = "Suggestion", hl = "Dim", size = 12, wrap = false },
    { grow = 1, wrap = false, text_overflow = "ellipsis", spans = spans, size = 13 },
    control("Accept", "Put the suggestion in the prompt (Tab)", function()
      local info = bone.prompt.info()
      info.focused = true
      if core.suffix(info) then core.accept() end
    end),
    control("Dismiss", "Dismiss the suggestion (Esc)", function()
      if core.pending() then core.clear() end
    end),
  }
end

-- Same acceptance rules as the terminal, except there is no ghost text:
-- a matching prefix is visible in this row, so Tab accepts it.
local function decorate()
  if bone.ui.actions.complete ~= complete then
    local old = bone.ui.actions.complete
    previous_complete = old
    complete = function()
      local ctx = bone.prompt.info()
      ctx.focused = true -- action is routed to the prompt, not a focused node
      if not core.suffix(ctx) then return old and old() or false end
      return core.accept()
    end
    bone.ui.actions.complete = complete
  end
  if bone.ui.actions.dismiss ~= dismiss then
    local old = bone.ui.actions.dismiss
    previous_dismiss = old
    dismiss = function()
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

bone.gui.slots.add("composer.above", {
  id = SLOT,
  node = function(slot_ctx)
    -- Background composers (another tiled chat) are not the prompt on screen.
    if type(slot_ctx) == "table" and slot_ctx.chat then return nil end
    local ctx = visible_ctx()
    local rest = core.suffix(ctx)
    if rest then return row(ctx, rest) end
    if ctx.text == "" and core.pending() and core.allows(ctx) then return suggesting() end
  end,
})

bone.plugin.on_shutdown(function()
  core.on_change = nil
  bone.gui.slots.remove("composer.above", SLOT)
  if bone.ui.actions.complete == complete then bone.ui.actions.complete = previous_complete end
  if bone.ui.actions.dismiss == dismiss then bone.ui.actions.dismiss = previous_dismiss end
end)
