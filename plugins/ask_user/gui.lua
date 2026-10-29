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

-- The desktop library's widgets and sizes. Without them (an older bone) the
-- same calls make bare nodes: the layout and presses stay, the look does not.
local has_w, W = pcall(require, "bone.nodes.widgets")
local has_s, S = pcall(require, "bone.nodes.style")
if not (has_w and has_s and type(W.list) == "function" and bone.gui and bone.gui.scroll_item) then
  S = { size = {}, radius = {}, space = { xs = 2, sm = 4, md = 8, lg = 12, xl = 16 } }
  local function press(node, click, role)
    node.on_click, node.cursor, node.role = click, "pointer", role or "button"
    return node
  end
  local function choices(names, current, pick)
    local row = { direction = "row", gap = 12 }
    for i, name in ipairs(names) do
      row[i] = press({ text = name, hl = i == current and "Normal" or "Dim", selected = i == current },
        function() pick(i) end, "option")
    end
    return row
  end
  W = {
    press = press,
    title = function(text) return { text = text, bold = true } end,
    note = function(text, _, hl) return { text = text, hl = hl or "Dim" } end,
    pill = function(text, o) return { text = text, hl = (o or {}).hl or "Accent" } end,
    divider = function() return { height = 1 } end,
    hints = function(text) return { text = text, hl = "Dim" } end,
    button = function(label, click, primary, _, o)
      local node = press({ text = label, hl = primary and "Accent" or "Normal" }, click)
      for k, v in pairs(o or {}) do node[k] = v end
      return node
    end,
    checkbox = function(on) return { text = on and "☑" or "☐", hl = on and "Accent" or "Dim", role = "checkbox", selected = on } end,
    link = function(text, click) return press({ text = text, hl = "Accent" }, click, "link") end,
    icon_button = function(glyph, label, click) return press({ text = glyph, label = label }, click) end,
    segmented = choices,
    tabs = choices,
    surface = function(o) return o or {} end,
    entry = function(on, children, click)
      local node = { direction = "column", bg = on and "Selection" or nil, selected = on }
      for _, c in ipairs(children) do node[#node + 1] = c end
      return click and press(node, click, "option") or node
    end,
    list = function(list_id, items, _, opts)
      local col = { id = list_id, direction = "column", grow = 1, overflow = "scroll" }
      for i, item in ipairs(items) do col[i] = item end
      if not (opts and opts.footer) then return col end
      return { direction = "column", grow = 1, col, opts.footer }
    end,
    field = function(label, value, o)
      o = o or {}
      local node = { text = label .. ": " .. value .. (o.editing and "▏" or "") }
      return o.click and press(node, o.click) or node
    end,
  }
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
  local head = { direction = "row", gap = S.space.md, align = "center" }
  if multi then
    head[#head + 1] = W.checkbox(cur.checked[i] and true or false)
  end
  head[#head + 1] = {
    spans = {
      { text = i <= 9 and (tostring(i) .. "  ") or "", hl = "Dim" },
      { text = o.label, hl = "Normal", bold = on or nil },
    },
    size = S.size.body, grow = 1, width = 0,
  }
  local children = { head }
  if o.desc and o.desc ~= "" then
    children[2] = { text = o.desc, hl = "Dim", size = S.size.small, margin = { 2, 0, 0, multi and 26 or 0 } }
  end
  local row = W.entry(on, children, function()
    ask.activate(i)
  end)
  row.id, row.focusable = "ask_user:opt:" .. i, false
  row.role = multi and "checkbox" or "option"
  row.selected = multi and (cur.checked[i] and true or false) or on
  return row
end

-- "↑ 3 more": a press that brings the hidden options into view.
local function more(text, sel)
  return W.press({ text = text, hl = "Dim", size = S.size.small, focusable = false, padding = { 2, 12 } }, function()
    if ask.cur then
      ask.cur.sel = sel
      ask.refresh()
    end
  end)
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
    gap = S.space.md,
    grow = 1,
    overflow = "scroll",
    -- The card is as tall as the question and no wider than a dialog;
    -- longer than the window, it scrolls.
    fit = true,
    max_width = 600,
    on_key = on_key,
    { text = count, hl = "Dim", size = S.size.small },
    { text = q.text or "Question", bold = true, size = S.size.lead, wrap = true, selectable = true },
  }
  if #opts > 0 then
    local first = math.max(1, math.min(cur.sel - math.floor(MAX_OPTIONS / 2), #opts - MAX_OPTIONS + 1))
    local last = math.min(#opts, first + MAX_OPTIONS - 1)
    local list = { direction = "column" }
    if first > 1 then
      list[#list + 1] = more(string.format("↑ %d more", first - 1), first - 1)
    end
    for i = first, last do
      list[#list + 1] = option_row(cur, i, opts[i])
    end
    if last < #opts then
      list[#list + 1] = more(string.format("↓ %d more", #opts - last), last + 1)
    end
    root[#root + 1] = list
  end
  -- The library's field look around a live text input.
  root[#root + 1] = {
    id = INPUT_ID,
    bg = "InputBackground",
    border = 1,
    border_color = field_focused() and "Accent" or "PromptBorder",
    radius = S.radius.lg,
    padding = { 6, 12 },
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
  local keys = W.hints(hint, { 0, 0 })
  keys.grow, keys.width = 1, 0
  root[#root + 1] = {
    direction = "row",
    gap = S.space.md,
    align = "center",
    keys,
    W.button("Cancel", function()
      ask.cancel()
    end, false, false, { id = "ask_user:cancel", focusable = false }),
    W.button("Answer", function()
      ask.submit()
    end, true, false, { id = "ask_user:submit", focusable = false }),
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
