local ACTIVE_REGION = "toolstrip_active"
local MIN_GAP = 300 -- model time shorter than this (ms) draws no segment, as in the GUI
local dirty, cached = true, nil
local pending, asks = {}, {}
local turn_segments -- below, with the inline bars
local selected, selected_label, selected_seg, selected_turn = nil, nil, nil, nil
local hits, displayed_turn = {}, nil

local groups = {
  model = "ToolStripModel", read = "ToolStripRead", command = "ToolStripCommand",
  edit = "ToolStripEdit", fail = "ToolStripFail", live = "ToolStripLive", wait = "ToolStripWait",
  agent = "ToolStripAgent", answer = "ToolStripAnswer",
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
define("ToolStripAgent", { fg = "#6b6a68" })
define("ToolStripAnswer", { fg = "#cfcdc9" })
define("ToolStripLabel", { link = "StatusLineDim" })
define("ToolStripLiveDim", { fg = "#8a6640" })
define("ToolStripWaitDim", { fg = "#44708f" })
define("ToolStripSelected", { link = "ToolStripRead", bold = true, underline = true })
for kind, group in pairs(groups) do
  local name = "ToolStripSelected" .. kind:gsub("^%l", string.upper)
  selected_groups[kind] = name
  define(name, { link = group, bold = true, underline = true })
end

local function mark()
  dirty = true
end

local function id_of(v)
  return v == nil and nil or tostring(v)
end

local function secs(ms)
  ms = math.max(0, ms or 0)
  if ms < 1000 then return string.format("%dms", math.floor(ms)) end
  if ms < 10000 then return string.format("%.1fs", ms / 1000) end
  return bone.util.duration(ms / 1000)
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

-- Whether a finished call failed, by session and call id: an error, or a
-- shell command whose output ends in a non-zero exit code. A live call is
-- told by its `tool/finished`; one from history reads its output once.
local failed = {}

local function exit_code(output)
  return type(output) == "string" and tonumber(output:match("%[exit code: (%-?%d+)%]%s*$")) or nil
end

local function call_failed(sid, call)
  if call.is_error then return true end
  if not call.done or call.name ~= "shell" then return false end
  local key = sid .. ":" .. tostring(call.id or call.index)
  if failed[key] == nil then
    local full = bone.chat.item(call.index, { full = true, session = sid })
    local code = exit_code(full and full.output)
    failed[key] = code ~= nil and code ~= 0
  end
  return failed[key]
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
  -- A question still open when its turn ends will not be answered.
  if sid then
    pending[sid] = nil
    for ask, owner in pairs(asks) do
      if owner == sid then asks[ask] = nil end
    end
  end
  mark()
end)
bone.on("ready", function()
  for _, s in ipairs(bone.chat.sessions()) do start_clock(s.session_id) end
end)
bone.on("tool/started", mark)
bone.on("tool/finished", function(ev)
  if ev.session_id and ev.call_id then
    local code = exit_code(ev.output)
    failed[ev.session_id .. ":" .. id_of(ev.call_id)] = ev.is_error == true or (code ~= nil and code ~= 0)
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

local KINDS = { shell = "command", edit_file = "edit", write_file = "edit", subagent = "agent" }

local agents
local function kind_of(sid, call)
  if agents == nil then
    local ok, module = pcall(require, "bone.agents")
    agents = ok and module or false
  end
  if agents and agents.for_call and agents.for_call(call.id) then return "agent" end
  if call_failed(sid, call) then return "fail" end
  return KINDS[tostring(call.name or ""):lower()] or "read"
end

-- The model's time between calls ("model", dots), or a finished turn's
-- answer after its last call ("answer").
local function add_model(out, start, finish, live, key, scroll, kind)
  local duration = math.max(0, (finish or start or 0) - (start or 0))
  if duration > 0 or #out == 0 then
    out[#out + 1] = {
      kind = kind or "model", duration = duration, start = start, finish = finish, live = live,
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
    displayed_turn, selected, selected_label, selected_seg, selected_turn = key, nil, nil, nil, nil
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

-- The segments `source` (turn_segments) as `cells` columns of blocks from
-- column `col`: a running turn's as wide as they ran, a finished turn's in
-- equal shares. `pulse` false draws live segments in their dim color.
-- Returns the spans and the drawn segments, each with its columns
-- (`from`, `to`) for clicks.
local function draw_bar(source, running, cells, col, pulse)
  local now = bone.now()
  local list = {}
  for i, from in ipairs(source) do
    local seg = {}
    for k, v in pairs(from) do seg[k] = v end
    if seg.live then seg.duration = math.max(0, now - seg.start) end
    list[i] = seg
  end
  compact(list, math.min(#list, cells))
  local total = 0
  for _, seg in ipairs(list) do
    seg.weight = running and math.max(seg.duration, 1) or 1
    total = total + seg.weight
  end
  -- Each edge is rounded from the time before it, not each width on its
  -- own: as the turn grows the edges only drift left, where per-segment
  -- rounding would hand a cell back and forth between neighbours.
  local edge, acc = 0, 0
  for i, seg in ipairs(list) do
    acc = acc + seg.weight
    local to = i == #list and cells or math.floor(acc / total * cells + 0.5)
    to = math.min(math.max(to, edge + 1), cells - (#list - i))
    seg.width, edge = math.max(1, to - edge), to
  end
  local spans = {}
  for _, seg in ipairs(list) do
    -- A wait grows while you read: it takes at most half the bar.
    if seg.kind == "wait" then seg.width = math.min(seg.width, math.max(1, math.floor(cells / 2))) end
    local group
    if seg.key == selected then
      group = selected_groups[seg.base_kind or seg.kind] or "ToolStripSelected"
    elseif seg.kind == "wait" then
      group = pulse == false and "ToolStripWaitDim" or "ToolStripWait"
    elseif seg.live then
      group = pulse == false and "ToolStripLiveDim" or "ToolStripLive"
    else
      group = groups[seg.kind] or "ToolStripRead"
    end
    -- Thinking is compact square braille blocks; every tool and the answer
    -- a solid block colored by its kind.
    spans[#spans + 1] = { string.rep(seg.kind == "model" and "⣿" or "█", seg.width), group }
    seg.from, seg.to = col, col + seg.width - 1
    col = seg.to + 1
  end
  return spans, list
end

local function lines_count(s)
  if not s or s == "" then return 0 end
  return select(2, tostring(s):gsub("\n", "")) + 1
end

-- What a call's label says it did, by tool name (the GUI's words).
local LABELS = {
  read_file = "Read", write_file = "Wrote", edit_file = "Edited", shell = "Ran",
  grep = "Searched", rg = "Searched", glob = "Listed", list_files = "Listed",
  web_search = "Searched the web", web_fetch = "Fetched", subagent = "Agent",
}
local ARGS = { "path", "file_path", "command", "pattern", "query", "url", "task", "prompt" }

-- What segment `seg` did, `{ what, extra }`; its time is added when drawn,
-- so a running call's keeps counting.
local function label_for(seg)
  local call = seg.call
  if not call then return { what = seg.kind == "answer" and "Answer" or "Thinking" } end
  local args = type(call.arguments) == "table" and call.arguments or {}
  local arg
  for _, k in ipairs(ARGS) do
    if type(args[k]) == "string" and args[k] ~= "" then arg = args[k]; break end
  end
  if not arg then
    for _, value in pairs(args) do
      if type(value) == "string" then arg = value; break end
    end
  end
  arg = arg and tostring(arg):gsub("%s+", " ") or ""
  -- Paths relative to the chat's folder.
  local s = bone.chat.session()
  local cwd = ((s and s.cwd) or ""):gsub("/$", "") .. "/"
  if #cwd > 1 and arg:sub(1, #cwd) == cwd then arg = arg:sub(#cwd + 1) end
  local name = tostring(call.name or "tool")
  local out = { what = (LABELS[name] or name) .. (arg ~= "" and " " .. arg or "") }
  if seg.base_kind == "command" or (seg.base_kind == "fail" and name == "shell") then
    local full = call.done and bone.chat.item(call.index, { full = true }) or call
    local code = exit_code(full.output)
    out.extra = code and ("exit " .. code) or (call.is_error and "failed") or nil
  elseif seg.base_kind == "edit" then
    out.extra = string.format("+%d −%d", lines_count(args.new_string or args.content), lines_count(args.old_string))
  elseif seg.base_kind == "fail" then
    out.extra = "failed"
  end
  return out
end

-- The latest turn's bar, above the prompt, running or finished; it moves
-- into the chat under its message once the next message is sent.
local function render_active(ctx)
  if bone.o.tool_strip == false then return nil end
  local session = bone.chat.session()
  local turn = current_turn(session)
  if not turn then return nil end
  if dirty then build() end
  if not cached then return nil end
  local now = bone.now()
  local first = cached.segments[1]
  local total = cached.running and first and first.start and now - first.start or cached.duration
  local right = " " .. bone.util.duration(math.max(0, total or 0) / 1000)
  if bone.settings.get("toolstrip.label") ~= false and selected and selected_label then
    -- The selected segment as it is now: a running call's time grows.
    local seg = selected_seg
    for _, s in ipairs(cached.segments) do
      if s.key == selected then seg = s; break end
    end
    local ms = seg.live and now - seg.start or seg.duration
    local parts = { selected_label.what }
    if selected_label.extra then parts[#parts + 1] = selected_label.extra end
    parts[#parts + 1] = secs(ms)
    -- "4.2s of 12s" when it is this bar's segment, else an earlier turn's.
    local of = selected_turn == cached.turn.index and " of" or " ·"
    right = " " .. table.concat(parts, " · ") .. of .. right
  end
  local right_width = bone.strwidth(right)
  if right_width > math.max(0, ctx.width - 3) then
    right = bone.text.truncate(right, math.max(0, ctx.width - 3))
    right_width = bone.strwidth(right)
  end
  local cells = math.max(1, ctx.width - 2 - right_width)
  local pulse = math.floor(now / 600) % 2 == 0
  local spans, list = draw_bar(cached.segments, cached.running, cells, 3, pulse)
  hits = list
  local line = { { "  ", "Dim" } }
  local live = false
  for i, span in ipairs(spans) do
    line[#line + 1] = span
    live = live or list[i].live == true
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
-- Their click targets are kept by chat and item index: another chat's item
-- with the same index is not this bar.
local open_turns, base_views, view_hits = {}, {}, {}

local function hit_key(index)
  local s = bone.chat.session()
  return (s and s.session_id or "") .. ":" .. tostring(index)
end

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
  local sid = s.session_id
  local calls = bone.chat.items({ kind = "tool", turn = turn.index, session = sid }) or {}
  local now = bone.now()
  local clock = clock_for(sid, turn)
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

  local out, at, previous = {}, start, nil
  for i, call in ipairs(calls) do
    local ran = tonumber(call.started_at)
    local began = ran and ran - (tonumber(call.generation_ms) or 0) or at
    if began - at >= MIN_GAP then
      add_model(out, at, began, false, "model:" .. tostring(turn.index) .. ":" .. i,
        previous and previous + 1 or turn.first)
    end
    local duration = tonumber(call.duration_ms) or (not call.done and math.max(0, now - (ran or began)) or 0)
    local finish = (ran or began) + duration
    local base = kind_of(sid, call)
    local waiting = not call.done and (pending[sid] or 0) > 0
    out[#out + 1] = {
      call = call, kind = waiting and "wait" or base, base_kind = base,
      duration = math.max(0, finish - began), start = began, finish = finish,
      live = not call.done, key = "call:" .. tostring(call.id or call.index),
      scroll_index = call.index, previous = previous,
    }
    at = math.max(at, finish)
    previous = call.index
  end
  -- After the last call the model is thinking, or, once the turn is over,
  -- it was writing its answer.
  local tail = running and "model" or "answer"
  if not running and stop < at then stop = at end
  if stop - at >= MIN_GAP then
    add_model(out, at, stop, running, "model:" .. tostring(turn.index) .. ":tail",
      previous and previous + 1 or turn.first, tail)
  elseif #out == 0 then
    add_model(out, start, stop, running, "model:" .. tostring(turn.index) .. ":only", turn.first, tail)
  end
  return out, math.max(0, stop - start), running
end

-- An earlier turn's bar, under its message or in its folded row; the latest
-- turn's is above the prompt, so these are never running.
local function bar_line(s, turn, width, item_index)
  width = math.max(1, tonumber(width) or 1)
  local source, total, running = turn_segments(s, turn)
  if not source or #source == 0 then return nil end
  if width < 8 then return { { bone.text.truncate("·", width), "Dim" } } end
  -- The time right-aligned in a column wide enough for any ("10m 05s"),
  -- so every earlier turn's bar ends at the same column.
  local time = bone.util.duration(total / 1000)
  local right = " " .. string.rep(" ", math.max(0, 7 - bone.strwidth(time))) .. time
  local cells = math.max(1, width - 2 - bone.strwidth(right))
  local spans, list = draw_bar(source, running, cells, 3)
  view_hits[hit_key(item_index)] = { turn = turn, line = nil, segments = list }
  local line = { { "  ", "Dim" } }
  for _, span in ipairs(spans) do line[#line + 1] = span end
  line[#line + 1] = { right, "Dim" }
  return line
end

local function folded_line(item, ctx)
  local s = bone.chat.session()
  local turn = turn_for_item(s, item)
  if not turn then return nil end
  local text = ((item.text or ""):match("^%s*([^\n]*)") or ""):gsub("%s+", " ")
  -- The message padded to one width, so every folded row's bar starts at
  -- the same column whatever its message's length.
  local room = math.max(8, math.floor(ctx.width * 0.30))
  text = bone.text.truncate(text, room)
  local prefix = "› " .. text .. string.rep(" ", math.max(0, room - bone.strwidth(text))) .. " "
  local remaining = ctx.width - bone.strwidth(prefix)
  local bar = remaining >= 8 and bar_line(s, turn, remaining + 2, item.index) or nil
  if not bar then return { { { bone.text.truncate(prefix, ctx.width), "Dim" } } } end
  local hit = view_hits[hit_key(item.index)]
  hit.line, hit.folded = 1, true
  -- The prefix takes the place of the bar's two-column indent.
  local shift = bone.strwidth(prefix) - 2
  for _, seg in ipairs(hit.segments) do seg.from, seg.to = seg.from + shift, seg.to + shift end
  local line = { { prefix, "Dim" } }
  for i = 2, #bar do line[#line + 1] = bar[i] end
  return { line }
end

local function install_inline_views()
  for _, kind in ipairs({ "user", "assistant", "reasoning", "notice", "tool" }) do
    base_views[kind] = bone.ui.views[kind]
  end
  bone.ui.views.user = function(item, ctx)
    view_hits[hit_key(item.index)] = nil
    if folded(item) then return folded_line(item, ctx) end
    local view = base_views.user
    local out = view and (view(item, ctx) or {}) or { { item.text or "" } }
    if bone.o.tool_strip ~= false then
      local s = bone.chat.session()
      local turn = turn_for_item(s, item)
      -- The latest turn's bar is the one above the prompt.
      if s and turn and turn.index < (tonumber(s.turns) or 0) then
        local bar = bar_line(s, turn, ctx.width, item.index)
        if bar then
          out[#out + 1] = bar
          view_hits[hit_key(item.index)].line = #out
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
local function pick(seg, turn)
  local before = selected_turn
  if seg then
    selected, selected_label, selected_seg, selected_turn = seg.key, label_for(seg), seg, turn
  else
    selected, selected_label, selected_seg, selected_turn = nil, nil, nil, nil
  end
  if before and before ~= selected_turn then redraw_turn(before) end
end
bone.on("mouse", function(ev)
  if ev.action ~= "down" or ev.button ~= "left" or not ev.index then return end
  local hit = view_hits[hit_key(ev.index)]
  if not hit or not hit.line or ev.line ~= hit.line then return end
  local chosen
  for _, seg in ipairs(hit.segments or {}) do
    if ev.col >= seg.from and ev.col <= seg.to then chosen = seg; break end
  end
  local key, n = turn_key(hit.turn), hit.turn.index
  local s = bone.chat.session()
  if hit.folded then
    open_turns[key] = true
    if chosen then
      -- A segment opens the turn at its item, as the GUI's does.
      pick(chosen, n)
      redraw_turn(n, true)
      bone.chat.scroll_to(chosen.call and chosen.call.index or chosen.scroll_index or hit.turn.first, "center")
      return true
    end
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
