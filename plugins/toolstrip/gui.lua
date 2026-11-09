-- The toolstrip plugin in the desktop app: each turn's tool strip under
-- your message, and every finished turn but the last folded to one row
-- (your message, its strip, how long it took). A click on a folded row opens
-- the turn, a click on a segment opens it at that call; an open turn's
-- strip has "Fold" while it is not the last. `bone.o.fold_turns = false`
-- keeps every turn open; `bone.o.tool_strip = false` hides the strips. The
-- standard GUI draws a plain chat; this wraps its views (bone.ui.views).
local strip = require("toolstrip.strip")
local style = require("bone.nodes.style")

if not pcall(bone.o.info, "fold_turns") or not bone.o.info("fold_turns") then
  bone.o.define("fold_turns", true, {
    desc = "fold each finished turn but the last into one row",
    on_change = function() bone.chat.redraw() end,
  })
end
bone.o.tool_strip = true
bone.o.fold_turns = true

local open = {} -- "session:turn" -> true, for folded turns opened by hand

local function turn_key(n)
  local s = bone.chat.session()
  return (s and s.session_id or "") .. ":" .. tostring(n)
end

-- Turn `n` of the chat being drawn, and whether it is the last.
local function turn_of(n)
  local s = bone.chat.session()
  return strip.turn(s, n), s and n == s.turns
end

-- Whether `item` belongs to a folded turn: any but the last, except the one
-- just before a running turn when a steer cut it short (it ends in a call,
-- not an answer, and is still going).
local function folded(item)
  if strip.off() or not bone.o.fold_turns or not item.turn or item.turn == 0 then return false end
  local s = bone.chat.session()
  if not s or item.turn >= (s.turns or 0) then return false end
  if s.running and item.turn == s.turns - 1 then
    local next = bone.chat.items({ kind = "user", turn = s.turns })[1]
    local tail = next and bone.chat.item(next.index - 1)
    if tail and tail.kind ~= "assistant" and tail.kind ~= "notice" then return false end
  end
  return not open[turn_key(item.turn)]
end

-- Open (`on`) or fold turn `n` of the chat on screen; the view stays put.
local function open_turn(n, on)
  open[turn_key(n)] = on or nil
  bone.chat.redraw()
  bone.chat.scroll(0)
end

local function open_at(n)
  return function(seg)
    open_turn(n, true)
    bone.defer(60, function() bone.chat.scroll_to(seg.index, "center") end)
  end
end

local function duration(total)
  return {
    width = 52, text = total and strip.secs(total) or "", hl = "Dim", font = "mono",
    size = style.size.micro, wrap = false, text_align = "right",
  }
end

-- A folded turn's row, for its user message `item`.
local function fold_row(item)
  local bar, total = strip.bar(bone.chat.session(), turn_of(item.turn), open_at(item.turn),
    "turn:" .. item.turn, function() bone.chat.redraw(item.index) end)
  if not strip.enabled() then bar = nil end
  local text = ((item.text or ""):match("^%s*([^\n]*)") or ""):gsub("%s+", " ")
  if text == "" and item.images and #item.images > 0 then text = "[Image]" end
  return {
    node = style.finish({
      direction = "row", align = "center", gap = 14, padding = { 6, 10 }, margin = { 1, 0, 1, 0 },
      radius = style.radius.md, hover = { bg = style.hover() }, transition = style.motion.base,
      cursor = "pointer", role = "button", label = "Open: " .. text,
      on_click = function() open_turn(item.turn, true) end,
      { width = "34%", text = text, hl = "Dim", size = style.size.caption, wrap = false, text_overflow = "ellipsis" },
      bar or { grow = 1 },
      duration(total),
    }),
    lines = { { { text, "Dim" } } },
  }
end

-- An open turn's strip, under its user message `item`; nil when there is
-- nothing to draw.
local function turn_header(item)
  local turn, last = turn_of(item.turn)
  if not turn or not strip.enabled() then return nil end
  if turn.running then bone.chat.refresh_in(1000) end
  local foldable = bone.o.fold_turns and not last
  local function fold_turn() open_turn(item.turn, false) end
  local bar, total = strip.bar(bone.chat.session(), turn, foldable and fold_turn or nil,
    "turn:" .. item.turn, function() bone.chat.redraw(item.index) end)
  if not bar or ((turn.tools or 0) == 0 and not total) then return nil end
  local fold = foldable and style.finish({
    text = "Fold", hl = "Dim", size = style.size.small, wrap = false, cursor = "pointer", role = "button",
    padding = { 2, 6 }, radius = style.radius.sm, hover = { bg = style.hover() },
    on_click = fold_turn,
  }) or nil
  return style.finish({
    direction = "row", align = "center", gap = 14, padding = { 0, 10 }, margin = { 2, 0, 6, 0 },
    bar, duration(total), fold,
  })
end

-- ---- the views ---------------------------------------------------------------

strip.setup()
local views = bone.ui.views
local user = views.user
views.user = function(item, ctx)
  if folded(item) then return fold_row(item) end
  local view = user and user(item, ctx)
  local header = view and turn_header(item)
  if header then view.node = { direction = "column", view.node, header } end
  return view
end
-- A folded turn shows only its row (drawn by its user message).
for _, kind in ipairs({ "assistant", "reasoning", "notice", "tool" }) do
  local view = views[kind]
  if view then
    views[kind] = function(item, ctx)
      if folded(item) then return nil end
      return view(item, ctx)
    end
  end
end
-- The turn that was last folds once another starts (or, cut short by a
-- steer, once the one after it finishes); the open turn's strip grows.
for _, ev in ipairs({ "turn/started", "turn/steered", "turn/finished" }) do
  bone.on(ev, function() bone.chat.redraw() end)
end
for _, ev in ipairs({ "tool/started", "tool/finished", "ask/requested" }) do
  bone.on(ev, function(e)
    local s = bone.chat.session()
    if not s or s.session_id ~= e.session_id then return end
    local t = strip.turn(s, s.turns)
    if t then bone.chat.redraw(t.first) end
  end)
end
bone.chat.redraw()
