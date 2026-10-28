local ACTIVE_REGION = "toolstrip_active"
local dirty, cached = true, nil
local pending, asks, failures = {}, {}, {}
local turn_segments -- below, with the inline bars
local selected, selected_label, hits, displayed_turn = nil, nil, {}, nil

local groups = {
  model = "ToolStripModel", read = "ToolStripRead", command = "ToolStripCommand",
  edit = "ToolStripEdit", fail = "ToolStripFail", live = "ToolStripLive", wait = "ToolStripWait",
  agent = "ToolStripAgent",
}
local selected_groups = {}

-- bone.hl.get resolves any name (to Normal when undefined), so ask
-- bone.hl.names what the colorscheme or config already defines.
local defined = {}
for _, name in ipairs(bone.hl.names()) do defined[name] = true end
local function define(name, spec)
  if not defined[name] then bone.hl.set(name, spec) end
end

-- The same colors as the GUI's strip (runtime/lua/bone/nodes/toolstrip.lua).
define("ToolStripModel", { link = "Dim" })
define("ToolStripRead", { fg = "#3b3b3a" })
define("ToolStripCommand", { fg = "#6b6a68" })
define("ToolStripEdit", { fg = "#60ae81" })
define("ToolStripFail", { fg = "#db7369" })
define("ToolStripLive", { fg = "#ffb46a" })
define("ToolStripWait", { fg = "#7cc4ff" })
define("ToolStripLabel", { link = "StatusLineDim" })
define("ToolStripLiveDim", { fg = "#8a6640" })
define("ToolStripWaitDim", { fg = "#44708f" })
define("ToolStripSelected", { link = "ToolStripRead", bold = true, underline = true })
for kind, group in pairs(groups) do
  local name = "ToolStripSelected" .. kind:gsub("^%l", string.upper)
  selected_groups[kind] = name
  define(name, { link = group, bold = true, underline = true })
end

define("ToolStripAgent", { fg = "#6b6a68" })
define("ToolStripSelectedAgent", { link = "ToolStripAgent", bold = true, underline = true })
selected_groups.agent = "ToolStripSelectedAgent"

local function mark()
  dirty = true
end

local function id_of(v)
  return v == nil and nil or tostring(v)
end

-- Turn `n` of chat `s` (bone.chat.session()), or nil. It reads only that
-- turn's messages and calls: bone.chat.turns() would make a chat view
-- depend on every item, so each streamed word would draw every view again,
-- and each of those would build every turn again.
local function turn_of(s, n)
  n = tonumber(n)
  if not s or not n or n < 1 then return nil end
  local sid = s.session_id
  local user = bone.chat.items({ kind = "user", turn = n, session = sid })[1]
  if not user then return nil end
  local last = s.items
  if n < (s.turns or 0) then
    local after = bone.chat.items({ kind = "user", turn = n + 1, session = sid })[1]
    last = after and after.index - 1 or last
  end
  return {
    index = n, first = user.index, last = last, text = user.text,
    running = n == s.turns and s.running == true,
  }
end

-- The turn chat item `item` belongs to: views get no `turn`, so ask for the
-- item itself (a query that depends on that item alone).
local function turn_number(item)
  if not item then return nil end
  if item.turn then return tonumber(item.turn) end
  local found = item.index and bone.chat.items({ from = item.index, to = item.index })[1]
  return found and tonumber(found.turn)
end

local function current_turn(s)
  return s and turn_of(s, s.turns), s and s.session_id
end

-- Each turn's clock, { started, finished }, by session and turn number,
-- saved so a bar keeps the model's time before its first call and after its
-- last across restarts. Turns timed before the plugin saved its own come
-- from the turn footers' record (bone.timing), where there is one. A saved
-- clock counts only for a turn with the same message: truncated history
-- can reuse a number.
local clocks, footers, active = {}, {}, {}

local function load(name)
  local ok, saved = pcall(bone.state.load, name)
  return ok and type(saved) == "table" and saved or {}
end

local function clocks_of(sid)
  if not clocks[sid] then
    clocks[sid] = load("toolstrip-clock." .. sid).turns or {}
    footers[sid] = load("standard-turn-timing." .. sid).turns or {}
  end
  return clocks[sid]
end

local function clock_for(sid, turn)
  local a = active[sid]
  if a and a.turn == turn.index then return a end
  local key = tostring(turn.index)
  for _, saved in ipairs({ clocks_of(sid)[key] or false, footers[sid][key] or false }) do
    if saved and saved.started and saved.text == turn.text then return saved end
  end
end

-- The running turn of session `sid` starts its clock (once; on a restart
-- mid-turn, from how long the core says it has run).
local function start_clock(sid)
  local s = sid and bone.chat.session({ session = sid })
  if not s or not s.running or not s.turn then return end
  local a = active[sid]
  if a and a.id == s.turn.id then return end
  local user = bone.chat.items({ session = sid, kind = "user", last = 1 })[1]
  if not user then return end
  active[sid] = {
    id = s.turn.id, turn = tonumber(user.turn), text = user.text,
    started = bone.now() - (tonumber(s.turn.elapsed_ms) or 0),
  }
end

bone.on("turn/started", function(ev)
  start_clock(ev.session_id)
  mark()
end)
bone.on("turn/finished", function(ev)
  local sid, a = ev.session_id, active[ev.session_id]
  if a and (a.id == nil or a.id == ev.turn_id) then
    local saved = clocks_of(sid)
    saved[tostring(a.turn)] = { text = a.text, started = a.started, finished = bone.now() }
    pcall(bone.state.save, "toolstrip-clock." .. sid, { turns = saved })
    active[sid] = nil
  end
  mark()
end)
bone.on("ready", function()
  for _, s in ipairs(bone.chat.sessions()) do start_clock(s.session_id) end
end)
bone.on("tool/started", mark)
bone.on("tool/finished", function(ev)
  if ev.call_id and ev.is_error then failures[id_of(ev.call_id)] = true end
  if ev.call_id and type(ev.output) == "string" then
    local code = tonumber(ev.output:match("%[exit code: (%-?%d+)%]"))
    if code and code ~= 0 then failures[id_of(ev.call_id)] = true end
  end
  mark()
end)
bone.on("ask/requested", function(ev)
  if ev.session_id then
    pending[ev.session_id] = (pending[ev.session_id] or 0) + 1
    if ev.ask_id then asks[id_of(ev.ask_id)] = ev.session_id end
  end
  mark()
end)
bone.on("ask/resolved", function(ev)
  local sid = ev.ask_id and asks[id_of(ev.ask_id)]
  if sid then pending[sid] = math.max(0, (pending[sid] or 1) - 1) end
  if ev.ask_id then asks[id_of(ev.ask_id)] = nil end
  mark()
end)
bone.on("chat/shown", function(ev)
  start_clock(ev.session_id)
  mark()
end)

local function kind_of(call, agents)
  local name = tostring(call.name or ""):lower()
  if agents and agents.for_call and agents.for_call(call.id) then return "agent" end
  if call.is_error or failures[id_of(call.id)] then return "fail" end
  if name == "shell" then return "command" end
  if name == "edit_file" or name == "write_file" then return "edit" end
  if name == "read_file" or name == "rg" or name == "ls" or name == "find"
      or name:match("search") or name:match("list") or name:match("find") or name:match("query")
      or name:match("glob") or name:match("grep") or name:match("ripgrep") or name:match("tree")
      or name:match("scan") or name:match("walk") or name:match("files?") then
    return "read"
  end
  return "read"
end

local function add_model(out, start, finish, live, key, scroll)
  local duration = math.max(0, (finish or start or 0) - (start or 0))
  if duration > 0 or #out == 0 then
    out[#out + 1] = {
      kind = "model", duration = duration, start = start, finish = finish, live = live,
      key = key, scroll_index = scroll,
    }
  end
end

local function build()
  dirty = false
  cached = nil
  local session = bone.chat.session()
  local turn, sid = current_turn(session)
  if not turn or not sid then return end
  if turn.running then start_clock(sid) end
  local key = sid .. ":" .. tostring(turn.index)
  if displayed_turn ~= key then
    displayed_turn, selected, selected_label = key, nil, nil
  end
  local segments, total, running = turn_segments(session, turn)
  if not segments then return end
  cached = { segments = segments, duration = total, running = running, turn = turn }
end

local function merge(a, b)
  local kind
  if a.kind == "wait" or b.kind == "wait" then kind = "wait"
  elseif a.kind == "model" then kind = b.kind
  elseif b.kind == "model" then kind = a.kind
  else kind = a.kind end
  return {
    kind = kind, base_kind = a.base_kind or b.base_kind, call = a.call or b.call,
    duration = a.duration + b.duration, start = a.start, finish = b.finish,
    live = a.live or b.live, key = a.key .. "+" .. b.key,
    scroll_index = a.scroll_index or b.scroll_index, previous = a.previous,
  }
end

local function compact(list, count)
  while #list > count do
    local at
    for i = 1, #list - 1 do
      if list[i].kind == "model" and list[i + 1].kind == "model" then at = i; break end
    end
    if not at then
      local best
      for i, seg in ipairs(list) do
        if seg.call and (not best or seg.duration < list[best].duration) then best = i end
      end
      at = best or 1
      if at == #list then at = at - 1 end
      if at > 1 and list[at - 1].call and not list[at + 1].call then at = at - 1 end
    end
    list[at] = merge(list[at], list[at + 1])
    table.remove(list, at + 1)
  end
end

local function layout_segments(width, right_width, now)
  if dirty then build() end
  if not cached then return {}, 0 end
  local list = {}
  for i, source in ipairs(cached.segments) do
    local seg = {}
    for k, v in pairs(source) do seg[k] = v end
    if seg.live then seg.duration = math.max(0, now - seg.start) end
    list[i] = seg
  end
  local cells = math.max(1, width - 2 - right_width)
  compact(list, math.min(#list, cells))
  local gap = 0
  local usable = math.max(#list, cells - gap * (#list - 1))
  local total = 0
  for _, seg in ipairs(list) do
    seg.weight = seg.duration
    total = total + seg.weight
  end
  if total <= 0 then total = #list end
  -- Each edge is rounded from the time before it, not each width on its
  -- own: as the turn grows the edges only drift left, where per-segment
  -- rounding would hand a cell back and forth between neighbours.
  local widths, used, acc, edge = {}, 0, 0, 0
  for i, seg in ipairs(list) do
    acc = acc + (seg.weight > 0 and seg.weight or 1)
    local to = i == #list and usable or math.floor(acc / total * usable + 0.5)
    to = math.min(math.max(to, edge + 1), usable - (#list - i))
    widths[i], edge = math.max(1, to - edge), to
    used = used + widths[i]
  end
  for i, seg in ipairs(list) do
    if seg.kind == "wait" then
      local max_wait = math.max(1, math.floor(usable / 2))
      if widths[i] > max_wait then
        used = used - widths[i] + max_wait
        widths[i] = max_wait
      end
    end
  end
  local col = 3
  hits = {}
  for i, seg in ipairs(list) do
    seg.width = widths[i]
    seg.from, seg.to = col, col + widths[i] - 1
    hits[#hits + 1] = seg
    col = seg.to + 1 + gap
  end
  return list, gap
end

local function lines_count(s)
  if not s or s == "" then return 0 end
  return select(2, tostring(s):gsub("\n", "")) + 1
end

local function label_for(seg)
  local call = seg.call
  if not call then return "model" end
  local full = bone.chat.item(call.index, { full = true }) or call
  local args = full.arguments or call.arguments or {}
  local arg = type(args) == "table" and (args.path or args.command) or nil
  if not arg and type(args) == "table" then
    for _, value in pairs(args) do
      if type(value) == "string" then arg = value; break end
    end
  end
  arg = arg and tostring(arg):gsub("%s+", " ") or ""
  local text = tostring(call.name or "tool") .. (arg ~= "" and " " .. arg or "")
  local output = type(full.output) == "string" and full.output or ""
  local code = output:match("%[exit code: (%-?%d+)%]")
  if seg.base_kind == "command" then
    text = text .. " · exit " .. (code or (full.is_error and "?" or "0"))
  elseif seg.base_kind == "edit" then
    local added = type(args) == "table" and lines_count(args.new_string) or 0
    local removed = type(args) == "table" and lines_count(args.old_string) or 0
    text = text .. string.format(" · +%d −%d", added, removed)
  elseif full.is_error or failures[id_of(call.id)] then
    text = text .. " · exit " .. (code or "?")
  end
  return text
end

local function glyph(seg)
  -- Thinking uses compact square braille blocks; every tool is a solid block
  -- colored by its kind above.
  if seg.kind == "model" then return string.rep("⣿", seg.width) end
  return string.rep("█", seg.width)
end

-- The live bar above the prompt; finished turns keep theirs under the user
-- message instead.
local function render_active(ctx)
  if bone.o.tool_strip == false then return nil end
  local session = bone.chat.session()
  local turn = current_turn(session)
  if not turn then return nil end
  local running = turn.running == true or (session and session.running == true)
  if not running then return nil end
  if dirty then build() end
  if not cached then return nil end
  local now = bone.now()
  local label_enabled = bone.settings.get("toolstrip.label") ~= false
  local right = label_enabled and selected and selected_label or ""
  right = right or ""
  local right_width = bone.strwidth(right)
  if right_width > math.max(0, ctx.width - 3) then
    right = bone.text.truncate(right, math.max(0, ctx.width - 3))
    right_width = bone.strwidth(right)
  end
  local list, gap = layout_segments(ctx.width, right_width, now)
  local pulse = math.floor(now / 600) % 2 == 0
  local line = { { "  ", "Dim" } }
  local live = false
  for i, seg in ipairs(list) do
    local group
    if seg.live or seg.kind == "wait" then
      live = true
      group = seg.kind == "wait" and (pulse and "ToolStripWait" or "ToolStripWaitDim")
        or (pulse and "ToolStripLive" or "ToolStripLiveDim")
    else
      group = groups[seg.kind] or "ToolStripRead"
    end
    if seg.key == selected then group = selected_groups[seg.base_kind or seg.kind] or "ToolStripSelected" end
    line[#line + 1] = { glyph(seg), group }
  end
  line[#line + 1] = "%="
  if right ~= "" then line[#line + 1] = { right, "ToolStripLabel" } end
  if live then bone.ui.refresh_in(600) end
  return { line }
end

bone.ui.regions[ACTIVE_REGION] = { size = "auto", max = 1, render = render_active }

local function layout_list(layout)
  return type(layout) == "table" and (layout.rows or layout.cols or (layout[1] and layout)) or nil
end

local function has_region(list, wanted)
  for _, entry in ipairs(list or {}) do
    local name = type(entry) == "table" and entry[1] or entry
    if name == wanted then return true end
    local children = type(entry) == "table" and (entry.rows or entry.cols)
    if children and has_region(children, wanted) then return true end
  end
  return false
end

local function place_before(list, target, wanted)
  for i, entry in ipairs(list or {}) do
    local name = type(entry) == "table" and entry[1] or entry
    if name == target then
      table.insert(list, i, wanted)
      return true
    end
    local children = type(entry) == "table" and (entry.rows or entry.cols)
    if children and place_before(children, target, wanted) then return true end
  end
  return false
end

local function remove_layout(list)
  for i = #list, 1, -1 do
    local entry = list[i]
    local name = type(entry) == "table" and entry[1] or entry
    if name == ACTIVE_REGION then
      table.remove(list, i)
    else
      local children = type(entry) == "table" and (entry.rows or entry.cols)
      if children then remove_layout(children) end
    end
  end
end

local function install_active_layout()
  local layout = bone.ui.layout
  if type(layout) ~= "table" then
    layout = { "chat", "prompt" }
    bone.ui.layout = layout
  end
  local list = layout_list(layout)
  if has_region(list, ACTIVE_REGION) then return end
  if place_before(list, "prompt", ACTIVE_REGION) then return end
  if place_before(list, "statusline", ACTIVE_REGION) then return end
  table.insert(list, ACTIVE_REGION)
end

-- Inline bars are deliberately fixed-width: chat lines do not use `%=` or
-- fill items, so a malformed bar can never turn into a full-screen region.
local open_turns, base_views, view_hits = {}, {}, {}

local function turn_key(turn)
  local s = bone.chat.session()
  return (s and s.session_id or "") .. ":" .. tostring(turn and turn.index or "")
end

local function turn_for_item(s, item)
  return turn_of(s, turn_number(item))
end

local function folded(item)
  if bone.o.fold_turns == false then return false end
  local s = bone.chat.session()
  local n = s and turn_number(item)
  if not n then return false end
  return n < (tonumber(s.turns) or 0) and not open_turns[turn_key({ index = n })]
end

turn_segments = function(s, turn)
  if not s or not turn or not turn.first or not turn.last then return nil end
  local calls = bone.chat.items({ kind = "tool", turn = turn.index, session = s.session_id }) or {}
  local now = bone.now()
  local clock = clock_for(s.session_id, turn)
  local first_at, last_at
  for _, call in ipairs(calls) do
    local ran = tonumber(call.started_at)
    local began = ran and ran - (tonumber(call.generation_ms) or 0)
    if began then first_at = first_at and math.min(first_at, began) or began end
    if ran then
      local finish = ran + (tonumber(call.duration_ms) or 0)
      last_at = last_at and math.max(last_at, finish) or finish
    end
  end
  -- Only the turn running now is live: the session running says nothing
  -- about the turns before it.
  local running = turn.running == true
  local start = clock and clock.started
  if running and not start and s.turn then
    start = now - (tonumber(s.turn.elapsed_ms) or 0)
  end
  -- A clock that starts after the first call is not this turn's.
  if not start or (first_at and start > first_at) then start = first_at or now end
  local stop = running and now or (clock and clock.finished) or last_at or start
  if stop < start then stop = start end

  local agents
  local ok, module = pcall(require, "bone.agents")
  if ok then agents = module end
  local out, at, previous = {}, start, nil
  for i, call in ipairs(calls) do
    local ran = tonumber(call.started_at)
    local began = ran and ran - (tonumber(call.generation_ms) or 0) or at
    if began > at then
      add_model(out, at, began, false, "model:" .. tostring(turn.index) .. ":" .. i,
        previous and previous + 1 or turn.first)
    end
    local duration = tonumber(call.duration_ms) or (not call.done and math.max(0, now - (ran or began)) or 0)
    local finish = (ran or began) + duration
    local base = kind_of(call, agents)
    local waiting = not call.done and (pending[s.session_id] or 0) > 0
    out[#out + 1] = {
      call = call, kind = waiting and "wait" or base, base_kind = base,
      duration = math.max(0, finish - began), start = began, finish = finish,
      live = not call.done, key = "call:" .. tostring(call.id or call.index),
      scroll_index = call.index, previous = previous,
    }
    at = math.max(at, finish)
    previous = call.index
  end
  if not running and stop < at then stop = at end
  if stop > at then
    add_model(out, at, stop, running, "model:" .. tostring(turn.index) .. ":tail",
      previous and previous + 1 or turn.first)
  elseif #out == 0 then
    add_model(out, start, stop, running, "model:" .. tostring(turn.index) .. ":only", turn.first)
  end
  return out, math.max(0, stop - start), running
end

local function bar_line(s, turn, width, item_index)
  width = math.max(1, tonumber(width) or 1)
  local source, total, running = turn_segments(s, turn)
  if not source or #source == 0 then return nil end
  if width < 8 then return { { bone.text.truncate("·", width), "Dim" } } end

  local duration = bone.util.duration(total / 1000)
  local right = " " .. duration
  local right_width = bone.strwidth(right)
  local cells = math.max(1, width - 2 - right_width)
  local list = {}
  for i, source_seg in ipairs(source) do
    local seg = {}
    for k, v in pairs(source_seg) do seg[k] = v end
    if seg.live then seg.duration = math.max(0, bone.now() - seg.start) end
    list[i] = seg
  end
  compact(list, math.min(#list, cells))
  local sum = 0
  for _, seg in ipairs(list) do sum = sum + math.max(seg.duration, 1) end
  sum = math.max(sum, 1)

  local spans, mapped, edge, acc = {}, {}, 0, 0
  for i, seg in ipairs(list) do
    acc = acc + math.max(seg.duration, 1)
    local to = i == #list and cells or math.floor(acc / sum * cells + 0.5)
    to = math.min(math.max(to, edge + 1), cells - (#list - i))
    seg.width = math.max(1, to - edge)
    edge = to
    local group
    if seg.live or seg.kind == "wait" then
      group = seg.kind == "wait" and "ToolStripWait" or "ToolStripLive"
    else
      group = groups[seg.kind] or "ToolStripRead"
    end
    if seg.key == selected then
      group = selected_groups[seg.base_kind or seg.kind] or "ToolStripSelected"
    end
    local text = seg.kind == "model" and string.rep("⣿", seg.width) or string.rep("█", seg.width)
    spans[#spans + 1] = { text, group }
    mapped[#mapped + 1] = { from = 3 + edge - seg.width, to = 2 + edge, segment = seg }
  end

  view_hits[item_index] = { turn = turn, line = nil, segments = mapped }
  local line = { { "  ", "Dim" } }
  for _, span in ipairs(spans) do line[#line + 1] = span end
  line[#line + 1] = { right, "Dim" }
  if running then bone.chat.refresh_in(600) end
  return line
end

local function folded_line(item, ctx)
  local s = bone.chat.session()
  local turn = turn_for_item(s, item)
  if not turn then return nil end
  local text = ((item.text or ""):match("^%s*([^\n]*)") or ""):gsub("%s+", " ")
  text = bone.text.truncate(text, math.max(8, math.floor(ctx.width * 0.30)))
  local prefix = "› " .. text .. " "
  local remaining = ctx.width - bone.strwidth(prefix)
  local bar = remaining >= 8 and bar_line(s, turn, remaining + 2, item.index) or nil
  if not bar then return { { { bone.text.truncate(prefix, ctx.width), "Dim" } } } end
  local hit = view_hits[item.index]
  hit.line, hit.folded = 1, true
  -- The prefix takes the place of the bar's two-column indent.
  local shift = bone.strwidth(prefix) - 2
  for _, m in ipairs(hit.segments) do m.from, m.to = m.from + shift, m.to + shift end
  local line = { { prefix, "Dim" } }
  for i = 2, #bar do line[#line + 1] = bar[i] end
  return { line }
end

local function install_inline_views()
  for _, kind in ipairs({ "user", "assistant", "reasoning", "notice", "tool" }) do
    base_views[kind] = bone.ui.views[kind]
  end
  bone.ui.views.user = function(item, ctx)
    view_hits[item.index] = nil
    if folded(item) then return folded_line(item, ctx) end
    local view = base_views.user
    local out = view and (view(item, ctx) or {}) or { { item.text or "" } }
    if bone.o.tool_strip ~= false then
      local s = bone.chat.session()
      local turn = turn_for_item(s, item)
      if s and turn then
        local bar = bar_line(s, turn, ctx.width, item.index)
        if bar then
          out[#out + 1] = bar
          view_hits[item.index].line = #out
        end
      end
    end
    return out
  end
  for _, kind in ipairs({ "assistant", "reasoning", "notice", "tool" }) do
    bone.ui.views[kind] = function(item, ctx)
      if folded(item) then return nil end
      local view = base_views[kind]
      return view and view(item, ctx) or nil
    end
  end
end

install_inline_views()

-- Draw turn `n` again: all its items (`whole`, it opens or folds), else its
-- message, which carries the bar. Views read their own turn's calls, so a
-- call starting or finishing draws only that turn again by itself.
local function redraw_turn(n, whole)
  local turn = turn_of(bone.chat.session(), n)
  if not turn then return end
  for i = turn.first, whole and turn.last or turn.first do bone.chat.redraw(i) end
end

-- A turn starting folds the one before it, and one finishing stops its
-- clock: those two turns are drawn again, not the whole transcript.
local function redraw_recent()
  local s = bone.chat.session()
  if not s or not s.turns then return end
  redraw_turn(s.turns - 1, true)
  redraw_turn(s.turns, true)
end
bone.on("turn/started", redraw_recent)
bone.on("turn/finished", redraw_recent)

-- The bar showing the selected segment, drawn again when it changes.
local selected_turn
local function pick(seg, turn)
  local before = selected_turn
  if seg then
    selected, selected_label, selected_turn = seg.key, label_for(seg), turn
  else
    selected, selected_label, selected_turn = nil, nil, nil
  end
  if before and before ~= selected_turn then redraw_turn(before) end
end
bone.on("mouse", function(ev)
  if ev.action ~= "down" or ev.button ~= "left" or not ev.index then return end
  local hit = view_hits[ev.index]
  if not hit or not hit.line or ev.line ~= hit.line then return end
  local chosen
  for _, segment in ipairs(hit.segments or {}) do
    if ev.col >= segment.from and ev.col <= segment.to then chosen = segment.segment; break end
  end
  local key, n = turn_key(hit.turn), hit.turn.index
  local s = bone.chat.session()
  if hit.folded then
    open_turns[key] = true
    if chosen then pick(chosen, n) end
  elseif bone.o.fold_turns ~= false and s and n < (tonumber(s.turns) or 0) then
    -- An earlier turn's bar folds it again, wherever it is clicked.
    open_turns[key] = nil
  elseif chosen and selected == chosen.key then
    pick(nil)
  elseif chosen then
    pick(chosen, n)
  end
  -- Stop following the end without moving: the chat then holds the row at
  -- the top while the turn opens or folds below it, so the clicked row
  -- stays put instead of the view staying at the bottom.
  bone.chat.scroll(0)
  redraw_turn(n, true)
  return true
end)

remove_layout(layout_list(bone.ui.layout) or {})
install_active_layout()

bone.on("mouse", function(ev)
  if ev.region ~= ACTIVE_REGION then return end
  if ev.action ~= "down" or ev.button ~= "left" then return end
  local hit
  for _, seg in ipairs(hits) do
    if ev.col >= seg.from and ev.col <= seg.to then hit = seg; break end
  end
  local n = cached and cached.turn and cached.turn.index
  if not hit or selected == hit.key then
    pick(nil)
    redraw_turn(n)
    return true
  end
  pick(hit, n)
  redraw_turn(n)
  if hit.call then
    bone.chat.scroll_to(hit.call.index, "center")
  else
    bone.chat.scroll_to(hit.scroll_index or 1, "center")
  end
  return true
end)

bone.plugin.on_shutdown(function()
  for kind, view in pairs(base_views) do bone.ui.views[kind] = view end
  remove_layout(layout_list(bone.ui.layout) or {})
  bone.ui.regions[ACTIVE_REGION] = nil
end)
