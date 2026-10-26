-- ask_user, desktop half: a modal window of nodes. The shared queue and
-- answers live in ui.lua. This file is loaded only by the GUI.
--
-- Click an option to choose it (or to toggle it, for several). The keys
-- match the terminal: ↑↓ move, enter sends, 1-9 pick while the answer is
-- empty, space toggles a multi-select, esc cancels. The text field is your
-- own answer; click it to type. Enter prefers that text, as the terminal does.
--
-- The built-in question card only understands plain string options, and it
-- listens for the same ask/requested events. While this plugin is loaded its
-- card is left out of the window for questions we are handling, so it cannot
-- answer them. On shutdown the card comes back. Other questions (an approval)
-- still use that card. We do not register a second ask/requested handler.

local ask = package.loaded["ask_user.ui"]
if not ask then
  error("ask_user: ui.lua must be loaded before gui.lua")
end
if not (bone.has_capability and bone.has_capability("gui.nodes")) then
  return
end

local INPUT_ID = "ask_user:input"
local MAX_OPTIONS = 8

local style = { size = { small = 12, body = 14, lead = 17, caption = 13 }, radius = { lg = 10, md = 8 } }
local ok_style, real_style = pcall(require, "bone.nodes.style")
if ok_style and type(real_style) == "table" and type(real_style.size) == "table" then
  style = real_style
end

local popup_id
local overlays = package.loaded["bone.nodes.overlays"]
local previous_nodes = overlays and overlays.nodes
local wrapped_nodes

local function builtin_ask_id(node)
  if type(node) ~= "table" or node.z ~= 10 or node.block_input ~= true then
    return nil
  end
  local n = 0
  for k in pairs(node) do
    if type(k) == "number" and k > n then
      n = k
    end
  end
  for i = 1, n do
    local child = node[i]
    if type(child) == "table" and type(child.id) == "string" then
      local id = child.id:match("^ask:(.+)$")
      if id then
        return id
      end
    end
  end
end

-- Drop the built-in card for a question this plugin is handling. Everything
-- else the overlay draws (a toast, an image, an approval) stays.
local function filter_nodes(list)
  if type(previous_nodes) ~= "function" then
    return list
  end
  local raw = previous_nodes(list)
  if type(raw) ~= "table" then
    return raw
  end
  local n = 0
  for k in pairs(raw) do
    if type(k) == "number" and k > n then
      n = k
    end
  end
  local out = {}
  for i = 1, n do
    local node = raw[i]
    local id = builtin_ask_id(node)
    if node ~= nil and not (id and ask.handling(id)) then
      out[#out + 1] = node
    end
  end
  return out
end

if type(previous_nodes) == "function" then
  wrapped_nodes = function(ctx)
    return filter_nodes(ctx)
  end
  overlays.nodes = wrapped_nodes
end

local function refresh()
  if bone.gui and bone.gui.invalidate then
    bone.gui.invalidate()
  end
end

local function field_focused()
  return bone.gui and bone.gui.focused and bone.gui.focused() == INPUT_ID
end

local NAMED = {
  enter = true, esc = true, space = true, tab = true, backspace = true, delete = true,
  up = true, down = true, left = true, right = true, home = true, ["end"] = true,
  pageup = true, pagedown = true, insert = true,
}

local function on_key(k)
  if not ask.cur or type(k) ~= "string" then
    return false
  end
  if k == "up" or k == "down" then
    if not ask.move(k == "up" and -1 or 1) and field_focused() then
      return false
    end
    return true
  end
  if k == "enter" then
    ask.submit_key()
    return true
  end
  if k == "esc" then
    ask.cancel_key()
    return true
  end
  if k == "space" then
    if field_focused() then
      return false
    end
    if not ask.toggle_space() then
      ask.insert(" ")
    end
    return true
  end
  if k == "backspace" then
    if field_focused() then
      return false
    end
    ask.backspace()
    return true
  end
  local n = k:match("^[1-9]$")
  if n and not field_focused() then
    if not ask.pick_key(tonumber(n)) then
      ask.insert(k)
    end
    return true
  end
  if field_focused() or k:find("+", 1, true) or NAMED[k] then
    return false
  end
  ask.insert(k)
  return true
end

local function option_row(cur, i, o)
  local multi = cur.q.type == "multi_select"
  local on = i == cur.sel
  local head = { direction = "row", gap = 8, align = "center" }
  if multi then
    head[#head + 1] = {
      text = cur.checked[i] and "☑" or "☐",
      hl = cur.checked[i] and "Accent" or "Dim",
      role = "checkbox",
      selected = cur.checked[i] and true or false,
    }
  end
  head[#head + 1] = {
    text = (i <= 9 and (tostring(i) .. ". ") or "") .. o.label,
    bold = on,
    grow = 1,
    wrap = true,
  }
  local row = {
    id = "ask_user:opt:" .. i,
    direction = "column",
    gap = 2,
    padding = { 6, 10 },
    radius = style.radius.md,
    bg = on and "Selection" or nil,
    cursor = "pointer",
    role = multi and "checkbox" or "option",
    selected = multi and (cur.checked[i] and true or false) or on,
    focusable = false,
    on_click = function()
      ask.activate(i)
    end,
    head,
  }
  if o.desc and o.desc ~= "" then
    row[#row + 1] = { text = o.desc, hl = "Dim", size = style.size.small, wrap = true }
  end
  return row
end

local function node()
  local cur = ask.cur
  if not cur then
    return { text = "" }
  end
  local q, opts = cur.q, cur.opts
  local total = tonumber(q.total) or 1
  local count = total > 1 and string.format("Question %d of %d", q.index or 1, total) or "Question"
  local placeholder = #opts == 0 and "Type your answer" or "or type your own answer"
  local root = {
    id = "ask_user:dialog",
    autofocus = true,
    focus = {},
    role = "dialog",
    label = q.text or "Question",
    direction = "column",
    gap = 10,
    grow = 1,
    overflow = "scroll",
    on_key = on_key,
    { text = count, hl = "Dim", size = style.size.small },
    { text = q.text or "Question", bold = true, size = style.size.lead, wrap = true, selectable = true },
  }
  if #opts > 0 then
    local first = math.max(1, math.min(cur.sel - math.floor(MAX_OPTIONS / 2), #opts - MAX_OPTIONS + 1))
    local last = math.min(#opts, first + MAX_OPTIONS - 1)
    local list = { direction = "column", gap = 4 }
    if first > 1 then
      list[#list + 1] = {
        text = string.format("↑ %d more", first - 1),
        hl = "Dim",
        size = style.size.small,
        cursor = "pointer",
        focusable = false,
        on_click = function()
          if ask.cur then
            ask.cur.sel = first - 1
            ask.refresh()
          end
        end,
      }
    end
    for i = first, last do
      list[#list + 1] = option_row(cur, i, opts[i])
    end
    if last < #opts then
      list[#list + 1] = {
        text = string.format("↓ %d more", #opts - last),
        hl = "Dim",
        size = style.size.small,
        cursor = "pointer",
        focusable = false,
        on_click = function()
          if ask.cur then
            ask.cur.sel = last + 1
            ask.refresh()
          end
        end,
      }
    end
    root[#root + 1] = list
  end
  root[#root + 1] = {
    id = INPUT_ID,
    bg = "InputBackground",
    radius = style.radius.lg,
    padding = { 8, 12 },
    on_key = on_key,
    text_input = {
      placeholder = placeholder,
      value = cur.text or "",
      on_change = function(text)
        if ask.cur then
          ask.cur.text = text
        end
      end,
      on_submit = function(text)
        if ask.cur then
          ask.cur.text = text
        end
        ask.submit_key()
      end,
    },
  }
  local hint = #opts == 0 and "enter send · esc cancel"
    or (q.type == "multi_select" and "↑↓ move · space toggle · enter confirm · esc cancel"
      or "↑↓ move · enter choose · 1-9 pick · esc cancel")
  root[#root + 1] = { text = hint .. " · click an option", hl = "Dim", size = style.size.small, wrap = true }
  root[#root + 1] = {
    direction = "row",
    gap = 8,
    justify = "end",
    {
      id = "ask_user:cancel",
      text = "Cancel",
      cursor = "pointer",
      role = "button",
      focusable = false,
      padding = { 7, 14 },
      radius = style.radius.lg,
      bg = "InputBackground",
      on_click = function()
        ask.cancel()
      end,
    },
    {
      id = "ask_user:submit",
      text = "Answer",
      bold = true,
      cursor = "pointer",
      role = "button",
      focusable = false,
      padding = { 7, 14 },
      radius = style.radius.lg,
      bg = "Selection",
      on_click = function()
        ask.submit()
      end,
    },
  }
  return root
end

local function show()
  if not popup_id or not bone.ui.is_open(popup_id) then
    popup_id = bone.ui.popup({
      width = 64,
      height = 26,
      on_key = on_key,
      node = function()
        return node()
      end,
    })
  end
  refresh()
end

local function hide_popup()
  if popup_id and bone.ui.is_open(popup_id) then
    bone.ui.close(popup_id)
  end
  popup_id = nil
end

ask.attach({
  show = show,
  hide = function()
    hide_popup()
  end,
  shutdown = function()
    hide_popup()
    if overlays and overlays.nodes == wrapped_nodes and previous_nodes then
      overlays.nodes = previous_nodes
    end
  end,
  text = function()
    return ask.cur and ask.cur.text or ""
  end,
  refresh = refresh,
  snapshot = function(cur)
    return { text = cur.text or "" }
  end,
})
