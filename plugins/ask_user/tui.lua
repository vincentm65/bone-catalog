-- ask_user, TUI half: questions are asked in the input field, like the
-- first bone. While one is open the field becomes the question: the prompt
-- is swapped out of the layout for a region drawn in the prompt's own style
-- (background, border, padding, prefix) holding the question, its options,
-- an input row and the keys. Typing still goes into the (hidden) prompt, so
-- editing works as usual; the region draws its text and cursor. The draft
-- you had in the prompt comes back afterwards.
--
--   ↑↓ move · enter choose · 1-9 pick · space toggle (multi) · esc cancel
--
-- Typed text is the answer for text questions, and a custom answer for
-- choice questions that allow one. Questions arriving while one is open
-- wait their turn.

local REGION = "ask_user"
local CONTEXT = "ask_user"
local MAX_OPTIONS = 8 -- option rows shown at once; the list scrolls
local MAX_INPUT = 4 -- input rows shown at once
local GUARD_MS = 250 -- keys this soon after a question appears are ignored

local queue = {} -- ask/requested events; the first is on screen
local cur -- the open question: { ev, q, opts, sel, checked, opened, style, saved }

-- Helpers ---------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copy(t)
  if type(t) ~= "table" then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = copy(v)
  end
  return out
end

local function utf8_chars(s)
  local out = {}
  for ch in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = ch
  end
  return out
end

-- Options as { label, value, desc }, from strings or { label, value, description }.
local function options(q)
  local out = {}
  for _, o in ipairs(type(q.options) == "table" and q.options or {}) do
    if type(o) == "table" then
      local label = tostring(o.label or o.value or "")
      out[#out + 1] = { label = label, value = o.value and tostring(o.value) or label, desc = o.description }
    else
      out[#out + 1] = { label = tostring(o), value = tostring(o) }
    end
  end
  return out
end

-- Style: look like the prompt ---------------------------------------------------

local BORDERS = {
  rounded = "╭╮╰╯─│",
  single = "┌┐└┘─│",
  double = "╔╗╚╝═║",
  thick = "┏┓┗┛━┃",
  ascii = "++++-|",
}

local function resolved(group)
  local h, n = bone.hl.get(group), 0
  while h and h.link and n < 5 do
    h, n = bone.hl.get(h.link), n + 1
  end
  return h or {}
end

-- The prompt's text of a line value: a string, a list of spans, or a function.
local function line_text(v)
  if type(v) == "function" then
    local ok, r = pcall(v, { width = 80, text = "", lines = { "" }, empty = true, focused = true })
    v = ok and r or nil
  end
  if type(v) == "string" then
    return v
  end
  local s = ""
  for _, sp in ipairs(type(v) == "table" and v or {}) do
    s = s .. (type(sp) == "table" and tostring(sp[1] or "") or tostring(sp))
  end
  return s
end

-- What the prompt looks like: background group, border, padding, prefix.
local function prompt_style(p)
  p = type(p) == "table" and p or {}
  local s = { bg = p.background, pad_rows = 0, pad_cols = 0 }
  local pad = p.padding
  if type(pad) == "number" then
    s.pad_cols = pad
  elseif type(pad) == "table" then
    s.pad_rows, s.pad_cols = pad[1] or 0, pad[2] or 0
  end
  s.prefix = p.prefix ~= nil and line_text(p.prefix) or "> "
  local b = p.border
  if b then
    local style = type(b) == "table" and b.style or (type(b) == "string" and b) or "rounded"
    local c = utf8_chars(type(b) == "table" and b.chars or BORDERS[style] or BORDERS.rounded)
    local sides = type(b) == "table" and b.sides or "tblr"
    s.border = {
      tl = c[1], tr = c[2], bl = c[3], br = c[4], h = c[5], v = c[6],
      hl = type(b) == "table" and b.hl or "PromptBorder",
      top = sides:find("t") ~= nil,
      bottom = sides:find("b") ~= nil,
      left = sides:find("l") ~= nil,
      right = sides:find("r") ~= nil,
    }
  end
  return s
end

-- Text groups with the prompt's background under them, so every cell sits
-- on the same band.
local GROUPS = { "Normal", "Dim", "Accent", "MdBold", "Placeholder", "UserPrompt" }

local function setup_groups(bg_group)
  local bg = bg_group and resolved(bg_group).bg
  for _, g in ipairs(GROUPS) do
    local spec = copy(resolved(g))
    spec.link = nil
    spec.bg = bg or spec.bg
    bone.hl.set("AskUser" .. g, spec)
  end
  local cursor = copy(resolved("AskUserNormal"))
  cursor.reverse = true
  bone.hl.set("AskUserCursor", cursor)
end

local function hl(g)
  return "AskUser" .. g
end

-- The layout with the region in the prompt's place (searching splits).
local function with_region(layout)
  local function swap(list)
    for i, e in ipairs(list) do
      if (type(e) == "table" and e[1] or e) == "prompt" then
        list[i] = REGION
        return true
      end
      if type(e) == "table" and ((e.rows and swap(e.rows)) or (e.cols and swap(e.cols))) then
        return true
      end
    end
  end
  local out = copy(layout)
  if type(out) ~= "table" or not swap(out) then
    return nil
  end
  return out
end

-- Drawing -----------------------------------------------------------------------

local function placeholder(q, opts)
  if #opts == 0 then
    return "Type your answer"
  end
  return "or type your own answer"
end

-- Whether the field shows an input row: text questions and custom answers,
-- and any typed text (so nothing typed is invisible).
local function wants_input(q, opts, text)
  return #opts == 0 or q.allow_custom or text ~= ""
end

local function hints(q, opts)
  if #opts == 0 then
    return { { "enter", "send" }, { "esc", "cancel" } }
  end
  local h = { { "↑↓", "move" } }
  if q.type == "multi_select" then
    h[#h + 1] = { "space", "toggle" }
    h[#h + 1] = { "enter", "confirm" }
  else
    h[#h + 1] = { "enter", "choose" }
  end
  if #opts > 1 then
    h[#h + 1] = { "1-" .. math.min(#opts, 9), q.type == "multi_select" and "toggle" or "pick" }
  end
  h[#h + 1] = { "esc", "cancel" }
  return h
end

-- The prompt's text as rows of spans with a drawn cursor, scrolled so the
-- cursor's row and column stay in view.
local function input_rows(width)
  local info = bone.prompt.info()
  local lines = info.lines or { info.text or "" }
  local crow, ccol = info.cursor and info.cursor.row or 0, info.cursor and info.cursor.col or 0
  local first = math.max(0, crow - MAX_INPUT + 1)
  local out = {}
  for r = first, math.min(#lines - 1, first + MAX_INPUT - 1) do
    local chars = utf8_chars(lines[r + 1] or "")
    local from = 1
    if r == crow and ccol + 1 > width then
      from = ccol - width + 2
    end
    local before, at, after = {}, nil, {}
    for i = from, math.min(#chars, from + width - 1) do
      if r == crow and i == ccol + 1 then
        at = chars[i]
      elseif r == crow and i > ccol + 1 then
        after[#after + 1] = chars[i]
      else
        before[#before + 1] = chars[i]
      end
    end
    local spans = { { table.concat(before), hl("Normal") } }
    if r == crow then
      spans[#spans + 1] = { at or " ", hl("Cursor") }
      spans[#spans + 1] = { table.concat(after), hl("Normal") }
    end
    out[#out + 1] = spans
  end
  return out
end

local function render(ctx)
  if not cur then
    return nil
  end
  local s, q, opts = cur.style, cur.q, cur.opts
  local b = s.border
  local w = ctx.width
  local inner = w - (b and b.left and 1 or 0) - (b and b.right and 1 or 0) - 2 * s.pad_cols
  local out = {}

  -- One row of the field: sides, padding, the spans, then the band to the edge.
  local function row(spans)
    local l = {}
    if b and b.left then
      l[#l + 1] = { b.v, b.hl }
    end
    l[#l + 1] = { string.rep(" ", s.pad_cols), hl("Normal") }
    for _, sp in ipairs(spans or {}) do
      l[#l + 1] = sp
    end
    l[#l + 1] = { fill = " ", hl = hl("Normal") }
    if b and b.right then
      l[#l + 1] = { b.v, b.hl }
    end
    out[#out + 1] = l
  end

  local function edge(left, right, title)
    local l = {}
    if b.left then
      l[#l + 1] = { left .. b.h, b.hl }
    end
    if title then
      l[#l + 1] = { " ? ", hl("Accent") }
      l[#l + 1] = { title .. " ", b.hl }
    end
    l[#l + 1] = { fill = b.h, hl = b.hl }
    if b.right then
      l[#l + 1] = { right, b.hl }
    end
    out[#out + 1] = l
  end

  local count = (tonumber(q.total) or 1) > 1 and string.format("Question %d of %d", q.index or 1, q.total) or "Question"
  if b and b.top then
    edge(b.tl, b.tr, count)
  end
  for _ = 1, s.pad_rows do
    row()
  end
  if not (b and b.top) then
    row({ { "? ", hl("Accent") }, { count, hl("Dim") } })
  end

  for _, l in ipairs(bone.text.wrap({ { q.text or "Question", hl("MdBold") } }, math.max(inner, 10))) do
    row(l)
  end

  if #opts > 0 then
    row()
    local multi = q.type == "multi_select"
    local first = math.max(1, math.min(cur.sel - math.floor(MAX_OPTIONS / 2), #opts - MAX_OPTIONS + 1))
    local last = math.min(#opts, first + MAX_OPTIONS - 1)
    if first > 1 then
      row({ { string.format("  ↑ %d more", first - 1), hl("Dim") } })
    end
    for i = first, last do
      local o, on = opts[i], i == cur.sel
      local spans = {
        { on and "› " or "  ", hl("Accent") },
        { (i <= 9 and tostring(i) or " ") .. ". ", hl("Dim") },
      }
      if multi then
        spans[#spans + 1] = { cur.checked[i] and "[x] " or "[ ] ", cur.checked[i] and hl("Accent") or hl("Dim") }
      end
      local used = 5 + (multi and 4 or 0)
      local label = bone.text.truncate(o.label, math.max(inner - used, 4))
      spans[#spans + 1] = { label, on and hl("MdBold") or hl("Normal") }
      used = used + bone.text.width(label)
      if o.desc and o.desc ~= "" and inner - used > 8 then
        spans[#spans + 1] = { bone.text.truncate("  " .. o.desc, inner - used), hl("Dim") }
      end
      row(spans)
    end
    if last < #opts then
      row({ { string.format("  ↓ %d more", #opts - last), hl("Dim") } })
    end
  end

  local text = bone.prompt.get()
  if wants_input(q, opts, text) then
    row()
    local prefix = { s.prefix, hl("UserPrompt") }
    local pw = bone.text.width(s.prefix)
    if text == "" then
      row({ prefix, { " ", hl("Cursor") }, { placeholder(q, opts), hl("Placeholder") } })
    else
      for i, spans in ipairs(input_rows(math.max(inner - pw - 1, 4))) do
        table.insert(spans, 1, i == 1 and prefix or { string.rep(" ", pw), hl("Normal") })
        row(spans)
      end
      if #opts > 0 and not q.allow_custom then
        row({ { string.rep(" ", pw) .. "this question takes no typed answer · ctrl+u clears", hl("Dim") } })
      end
    end
  end

  row()
  local spans = {}
  for i, h in ipairs(hints(q, opts)) do
    spans[#spans + 1] = { (i > 1 and "   " or "") .. h[1], hl("Accent") }
    spans[#spans + 1] = { " " .. h[2], hl("Dim") }
  end
  row(spans)
  for _ = 1, s.pad_rows do
    row()
  end
  if b and b.bottom then
    edge(b.bl, b.br)
  end
  return out
end

-- Opening, answering, closing ---------------------------------------------------

local open_next

-- Undo what opening changed: only what is still ours, so a config that
-- changed the layout meanwhile keeps its change.
local function restore(saved)
  if saved.our_layout and bone.ui.layout == saved.our_layout then
    bone.ui.layout = saved.layout
  end
  bone.prompt.set(saved.draft or "")
end

local function close()
  if not cur then
    return
  end
  local saved = cur.saved
  cur = nil
  restore(saved)
  bone.keymap.clear()
  table.remove(queue, 1)
  open_next()
end

local function respond(answer)
  bone.request("ask/respond", { ask_id = cur.ev.ask_id, answer = answer }, function(_, err)
    if err then
      bone.notify("ask_user: " .. (type(err) == "table" and err.message or tostring(err)), "error")
    end
  end)
  close()
end

function open_next()
  local ev = queue[1]
  if cur or not ev then
    return
  end
  local style = prompt_style(bone.ui.prompt)
  setup_groups(style.bg)
  local saved = { layout = bone.ui.layout, draft = bone.prompt.get() }
  saved.our_layout = with_region(bone.ui.layout)
  cur = {
    ev = ev,
    q = ev.question,
    opts = options(ev.question),
    sel = 1,
    checked = {},
    opened = bone.now(),
    style = style,
    saved = saved,
  }
  if saved.our_layout then
    bone.ui.layout = saved.our_layout
  end
  bone.prompt.set("")
  bone.keymap.focus(CONTEXT)
end

local function submit()
  local q, opts = cur.q, cur.opts
  local text = trim(bone.prompt.get())
  if #opts == 0 then
    if text ~= "" then
      respond({ value = text })
    end
    return
  end
  if text ~= "" then
    if q.allow_custom then
      return respond({ value = text, custom = true })
    end
    return bone.notify("ask_user: pick one of the options (this question takes no typed answer)", "error")
  end
  if q.type == "multi_select" then
    local values, labels = {}, {}
    for i, o in ipairs(opts) do
      if cur.checked[i] then
        values[#values + 1], labels[#labels + 1] = o.value, o.label
      end
    end
    if #values == 0 then
      local o = opts[cur.sel]
      values, labels = { o.value }, { o.label }
    end
    return respond({ values = values, labels = labels })
  end
  local o = opts[cur.sel]
  respond({ value = o.value, label = o.label, index = cur.sel })
end

-- Keys: a context over the prompt. Unmapped keys type into the prompt; a
-- callback returning false lets its key through too.

local function active()
  return cur and bone.now() - cur.opened >= GUARD_MS
end

local function prompt_empty()
  return trim(bone.prompt.get()) == ""
end

local function toggle(i)
  cur.checked[i] = not cur.checked[i] or nil
  cur.sel = i
end

bone.keymap.context(CONTEXT, { fallback = { "main" }, priority = 20 })

local function map(key, fn)
  bone.keymap.set(key, function()
    if not cur then
      return false
    end
    return fn()
  end, { context = CONTEXT })
end

map("up", function()
  if #cur.opts == 0 then
    return false
  end
  cur.sel = math.max(1, cur.sel - 1)
end)
map("down", function()
  if #cur.opts == 0 then
    return false
  end
  cur.sel = math.min(#cur.opts, cur.sel + 1)
end)
map("enter", function()
  if active() then
    submit()
  end
end)
map("esc", function()
  if active() then
    respond("cancelled")
  end
end)
map("space", function()
  if cur.q.type ~= "multi_select" or #cur.opts == 0 or not prompt_empty() then
    return false
  end
  toggle(cur.sel)
end)
for n = 1, 9 do
  map(tostring(n), function()
    if n > #cur.opts or not prompt_empty() then
      return false
    end
    if not active() then
      return
    end
    if cur.q.type == "multi_select" then
      toggle(n)
    else
      cur.sel = n
      submit()
    end
  end)
end

-- Events ------------------------------------------------------------------------

bone.ui.regions[REGION] = { size = "auto", max = 40, render = render }

bone.on("ask/requested", function(ev)
  local q = ev.question
  if type(q) ~= "table" or q.kind ~= "ask_user" then
    return
  end
  queue[#queue + 1] = ev
  open_next()
end)

bone.on("ask/resolved", function(ev)
  if cur and cur.ev.ask_id == ev.ask_id then
    return close()
  end
  for i = #queue, 2, -1 do
    if queue[i].ask_id == ev.ask_id then
      table.remove(queue, i)
    end
  end
end)

-- A reload while a question is open: put everything back as it was and
-- keep the questions, which the fresh state shows again.
local state = bone.plugin.state()
if type(state.pending) == "table" and (os.time() - (state.saved_at or 0)) <= 5 then
  for _, ev in ipairs(state.pending) do
    queue[#queue + 1] = ev
  end
  bone.defer(0, open_next)
end
state.pending, state.saved_at = nil, nil

bone.plugin.on_shutdown(function()
  if #queue > 0 then
    state.pending, state.saved_at = copy(queue), os.time()
  end
  if cur then
    local saved = cur.saved
    cur = nil
    restore(saved)
  end
  bone.ui.regions[REGION] = nil
end)
