-- context: what fills the conversation's context, estimated without model
-- calls. /context shows the current conversation, /context request the last
-- model request observed. Tab or 1/2 switches · r refreshes · ↑↓ scroll · q closes.

local alive, window, serial = true, nil, 0
local data, failure, loading, scroll, max_scroll, page = nil, nil, false, 0, 0, 1
local mode = "current"

-- Each category's color: the foreground of a theme group, so it follows
-- colorschemes. Only the foreground: groups such as DiffAdd carry a
-- background that would box every swatch, bar and label in grey.
local KINDS = {
  { "system", "System", "ContextSystem", "ToolPath" },
  { "summary", "Summary", "ContextSummary", "MdQuote" },
  { "user", "User", "ContextUser", "UserPrompt" },
  { "assistant", "Assistant", "ContextAssistant", "DiffAdd" },
  { "reasoning", "Reasoning", "ContextReasoning", "Reasoning" },
  { "calls", "Tool calls", "ContextCalls", "Notice" },
  { "results", "Tool results", "ContextResults", "DiffDelete" },
  { "definitions", "Tool schemas", "ContextDefinitions", "ToolArgs" },
  { "images", "Images", "ContextImages", "MdCode" },
}
local KIND = {}
for _, k in ipairs(KINDS) do KIND[k[1]] = { short = k[2], hl = k[3] } end
local function foreground(name)
  for _ = 1, 10 do
    local g = bone.hl.get(name) or {}
    if g.fg or not g.link then return g.fg end
    name = g.link
  end
end
-- Run on each frame so a colorscheme change is picked up; a group is set
-- only when its color changes, since setting colors redraws the chat.
local applied = {}
local function colors()
  for _, k in ipairs(KINDS) do
    local fg = foreground(k[4]) or false
    if applied[k[3]] ~= fg then
      applied[k[3]] = fg
      bone.hl.set(k[3], fg and { fg = fg } or { link = "Normal" })
    end
  end
end
colors()

local function current() return (bone.api.session() or {}).session_id end
local function width(s) return bone.text.width(s) end
local function pad(s, w)
  s = tostring(s or "")
  local n = width(s)
  if n > w then return bone.text.truncate(s, w) end
  return s .. string.rep(" ", w - n)
end
local function lpad(s, w)
  s = tostring(s or "")
  return string.rep(" ", math.max(w - width(s), 0)) .. s
end
local function tokens(bytes) return math.floor((bytes or 0) / (data and data.bytes_per_token or 4) + 0.5) end
-- 48.2k, 1.2M; exact below a thousand.
local function num(v)
  v = tonumber(v) or 0
  for _, u in ipairs({ { 1e6, "M" }, { 1e3, "k" } }) do
    if v >= u[1] then
      local x = v / u[1]
      return (x >= 100 and string.format("%.0f", x) or string.format("%.1f", x)):gsub("%.0$", "") .. u[2]
    end
  end
  return tostring(math.floor(v + 0.5))
end
-- A share as a percentage; "<1%" rather than a misleading 0%.
local function pct(f)
  if f > 0 and f < 0.005 then return "<1%" end
  return string.format("%.0f%%", f * 100)
end
local function ago(t)
  local s = os.time() - (t or 0)
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

-- A line builder: add(text, hl) appends, merging runs of the same group.
local function builder()
  local l = {}
  return l, function(text, hl)
    if text == "" then return end
    hl = hl or "Normal"
    local last = l[#l]
    if last and last[2] == hl then last[1] = last[1] .. text else l[#l + 1] = { text, hl } end
  end
end
local function line(text, hl) return { { text, hl or "Normal" } } end
-- Indented text wrapped to w, as lines.
local function para(text, hl, w)
  local out = {}
  for _, wrapped in ipairs(bone.text.wrap({ { text, hl or "Dim" } }, math.max(w - 2, 1))) do
    table.insert(wrapped, 1, { "  ", "Normal" })
    out[#out + 1] = wrapped
  end
  return out
end

local function title(text, w, right)
  local l, add = builder()
  add(" " .. text .. " ", "MdHeading")
  local tail = right and (" " .. right .. " ") or ""
  if width(text) + 3 + width(tail) > w then tail = "" end
  add(string.rep("─", math.max(w - width(text) - 2 - width(tail), 0)), "WinSeparator")
  add(tail, "Dim")
  return l
end

local PARTS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }
local function bar(frac, w)
  local cells = math.max(0, math.min(1, frac)) * w
  local full = math.floor(cells)
  local rest = math.floor((cells - full) * 8 + 0.5)
  if rest == 8 then full, rest = full + 1, 0 end
  local s = string.rep("█", full)
  if rest > 0 and full < w then s = s .. PARTS[rest]
  elseif full == 0 and frac > 0 then s = PARTS[1] end
  return s
end

-- The meter: one cell row split by category (largest remainder), scaled to
-- `scale` tokens (the context window, else the compaction limit) when known,
-- with `mark` (the compaction threshold) drawn as ┃.
local function meter(d, w, scale, mark)
  local total = tokens(d.bytes)
  local filled = scale > 0 and math.min(w, math.floor(total / scale * w + 0.5)) or w
  local parts, given = {}, 0
  for _, row in ipairs(d.rows) do
    if row.bytes > 0 and d.bytes > 0 then
      local exact = row.bytes / d.bytes * filled
      parts[#parts + 1] = { hl = KIND[row.key].hl, cells = math.floor(exact), rest = exact % 1 }
      given = given + math.floor(exact)
    end
  end
  local order = {}
  for i = 1, #parts do order[i] = parts[i] end
  table.sort(order, function(a, b) return a.rest > b.rest end)
  for i = 1, math.min(filled - given, #order) do order[i].cells = order[i].cells + 1 end
  local cells = {}
  for _, p in ipairs(parts) do
    for _ = 1, p.cells do cells[#cells + 1] = { "█", p.hl } end
  end
  while #cells < w do cells[#cells + 1] = { "░", "WinSeparator" } end
  if scale > 0 and mark and mark > 0 and mark < scale then
    local at = math.max(1, math.min(w, math.floor(mark / scale * w + 0.5)))
    cells[at] = { "┃", "WarningMsg" }
  end
  local l, add = builder()
  add("  ")
  for _, c in ipairs(cells) do add(c[1], c[2]) end
  return l
end

-- "■ System 3.1k  ■ User 2k …", wrapped to w.
local function legend(d, w)
  local out, l, add, used = {}, nil, nil, 0
  for _, row in ipairs(d.rows) do
    if row.bytes > 0 then
      local text = KIND[row.key].short .. " " .. num(tokens(row.bytes))
      if not l or used + width(text) + 4 > w then
        l, add = builder()
        out[#out + 1] = l
        add("  ")
        used = 2
      end
      add("■ ", KIND[row.key].hl)
      add(text .. "   ", "Dim")
      used = used + width(text) + 5
    end
  end
  return out
end

local function close()
  serial = serial + 1
  if window then bone.ui.close(window); window = nil end
end
bone.plugin.on_shutdown(function() alive = false; close() end)

local function load()
  if not window or not bone.ui.is_open(window) then return end
  serial = serial + 1
  local token, origin = serial, current()
  data, failure, loading = nil, nil, true
  if not origin then failure, loading = "No conversation selected yet.", false; return end
  bone.rpc.call("context.get", { session_id = origin }, function(result, err)
    if not alive or token ~= serial or current() ~= origin or not window or not bone.ui.is_open(window) then return end
    data, loading = result, false
    failure = err and (type(err) == "table" and err.message or tostring(err)) or nil
    bone.ui.update(window, {})
  end)
end

local function body(full)
  local w = math.min(full - 2, 110)
  if failure then return { line("  " .. failure, "ErrorMsg"), line("  Try /plugins reload context, then press r.", "Dim") } end
  if loading or not data then return { line("  Loading context…", "Dim") } end
  local d = data[mode]
  if not d then
    return { line("  No request observed yet. Send a message, then press r.", "Dim"),
      line("  Tab shows the current conversation's estimate.", "Dim") }
  end
  local out = {}
  local function add(l) out[#out + 1] = type(l) == "string" and line(l) or l end
  local total = tokens(d.bytes)
  local capacity = tonumber(bone.settings.get("context.window_tokens")) or 0
  local limit = tonumber(data.compact_limit) or 0

  -- Summary: the total, the meter and where it stands.
  add("")
  local l, put = builder()
  put("  ≈ ", "Dim")
  put(num(total) .. " tokens", "Accent")
  put(mode == "current" and "  estimated current context" or ("  last request · " .. ago(data.request_at)), "Dim")
  put(data.calibrated and "  · calibrated" or "  · uncalibrated", data.calibrated and "Dim" or "WarningMsg")
  add(l)
  if capacity > 0 then
    l, put = builder()
    put("  " .. pct(total / capacity), total > capacity and "WarningMsg" or "MdBold")
    put(" of the " .. num(capacity) .. " window · " .. (total > capacity and (num(total - capacity) .. " over") or (num(capacity - total) .. " free")), "Dim")
    add(l)
  elseif limit > 0 then
    -- No window set: the compaction limit is the ceiling that matters.
    l, put = builder()
    put("  " .. pct(total / limit), total >= limit and "WarningMsg" or "MdBold")
    put(" of the " .. num(limit) .. " compaction limit · "
      .. (total >= limit and "compacts on the next turn" or (num(limit - total) .. " to go")), "Dim")
    add(l)
  end
  add("")
  add(meter(d, math.max(w - 2, 10), capacity > 0 and capacity or limit, capacity > 0 and limit or nil))
  for _, row in ipairs(legend(d, w)) do add(row) end
  add("")
  if limit > 0 and capacity > 0 then
    l, put = builder()
    put(capacity > 0 and "  ┃ " or "  ", "WarningMsg")
    put("compacts at " .. num(limit), "Normal")
    put(total >= limit and " · due on the next turn" or string.format(" · %.0f%% there, %s to go", total / limit * 100, num(limit - total)), "Dim")
    add(l)
  end
  if mode == "current" then
    add(line(string.format("  %d active / %d stored messages%s", d.messages, d.stored_messages,
      d.summarized > 0 and (" · " .. d.summarized .. " summarized") or ""), "Dim"))
  else
    add(line("  Observed " .. os.date("%H:%M:%S", data.request_at) .. ", after context hooks", "Dim"))
  end
  if data.usage then
    local u = data.usage
    local input = tonumber(u.context_tokens or u.input_tokens) or 0
    local cached = tonumber(u.cached_tokens) or 0
    add(line("  Provider counted " .. num(input) .. " input on the last call"
      .. (cached > 0 and string.format(" · %s cached (%.0f%%)", num(cached), input > 0 and cached / input * 100 or 0) or ""), "Dim"))
  end
  if capacity == 0 then
    for _, row in ipairs(para("Set a context window in /config → Context to see how full it is.", "Dim", w)) do add(row) end
  end

  -- Breakdown by category.
  add("")
  add(title("Breakdown", w, data.calibrated and string.format("%.2f bytes/token", data.bytes_per_token) or "4 bytes/token"))
  local longest = 0
  for _, row in ipairs(d.rows) do
    if row.bytes > 0 then longest = math.max(longest, width(row.label) + 2) end
  end
  local label_w = math.max(12, math.min(longest, w - 34))
  local bar_w = math.min(30, w - label_w - 28)
  if bar_w < 4 then label_w, bar_w = math.max(12, math.min(30, w - 26)), 0 end
  local shown = 0
  for _, row in ipairs(d.rows) do
    if row.bytes > 0 then
      shown = shown + 1
      local share = d.bytes > 0 and row.bytes / d.bytes or 0
      l, put = builder()
      put("  ■ ", KIND[row.key].hl)
      put(pad(row.label, label_w))
      put(lpad(row.count > 1 and ("×" .. row.count) or "", 6), "Dim")
      put(lpad(num(tokens(row.bytes)), 8), "MdBold")
      put(lpad(pct(share), 6), "Dim")
      if bar_w > 0 then put("  " .. bar(share, bar_w), KIND[row.key].hl) end
      add(l)
    end
  end
  if shown == 0 then add(line("  empty", "Dim")) end
  if d.image_count > 0 then
    for _, row in ipairs(para("Images count 85 + 170 tokens per 512px tile; provider billing may differ.", "Dim", w)) do add(row) end
  end

  -- Every offered tool's schema cost, even when it has never been called.
  -- Keep this separate from the capped activity ranking below: large results
  -- should not hide tools that take up space on every request.
  local schemas, schema_bytes = {}, 0
  for _, t in ipairs(d.tools) do
    if t.definitions > 0 then
      schemas[#schemas + 1] = t
      schema_bytes = schema_bytes + t.definitions
    end
  end
  table.sort(schemas, function(a, b)
    return a.definitions == b.definitions and a.name < b.name or a.definitions > b.definitions
  end)
  add("")
  add(title("Tool schemas", w, #schemas > 0 and (#schemas .. " tools · ≈ " .. num(tokens(schema_bytes)) .. " tokens") or nil))
  if #schemas == 0 then
    local note = data.request and "No tool schemas were offered in the last observed request."
      or "Tool schemas are unknown until this conversation makes a model request."
    for _, row in ipairs(para(note, "Dim", w)) do add(row) end
  else
    add(line("  Estimated tokens · share of all tool schemas", "Dim"))
    local name_w = 8
    for _, t in ipairs(schemas) do name_w = math.max(name_w, width(t.name) + 2) end
    name_w = math.min(name_w, 42, math.max(w - 20, 8))
    local schema_bar = math.min(20, w - name_w - 18)
    for _, t in ipairs(schemas) do
      local long = width(t.name) > name_w
      if long then
        for _, row in ipairs(para(t.name, "ToolName", w)) do add(row) end
      end
      l, put = builder()
      put("  " .. pad(long and "" or t.name, name_w), "ToolName")
      put(lpad(num(tokens(t.definitions)), 8), "MdBold")
      put(lpad(pct(t.definitions / schema_bytes), 6), "Dim")
      if schema_bar >= 4 then put("  " .. bar(t.definitions / schema_bytes, schema_bar), KIND.definitions.hl) end
      add(l)
    end
  end

  -- Per-tool costs: total, its parts, and a bar of the tool's share colored
  -- by the part that dominates it.
  if #d.tools > 0 then
    add("")
    add(title("Tool costs", w, "top " .. math.min(15, #d.tools)))
    local shown_tools = math.min(15, #d.tools)
    local name_w = 8
    for i = 1, shown_tools do name_w = math.max(name_w, width(d.tools[i].name) + 2) end
    name_w = math.min(name_w, 26, math.max(w - 12, 8))
    local split = w - 2 - name_w - 8 >= 26
    local tool_bar = split and math.min(20, w - 2 - name_w - 34 - 2) or 0
    l, put = builder()
    put("  " .. pad("", name_w) .. lpad("total", 8), "Dim")
    if split then put(lpad("schema", 9) .. lpad("args", 8) .. lpad("results", 9), "Dim") end
    add(l)
    for i = 1, shown_tools do
      local t = d.tools[i]
      l, put = builder()
      put("  " .. pad(t.name, name_w), "ToolName")
      put(lpad(num(tokens(t.bytes)), 8), "MdBold")
      if split then
        local function part(v, cw) put(lpad(v > 0 and num(tokens(v)) or "·", cw), "Dim") end
        part(t.definitions, 9); part(t.calls, 8); part(t.results, 9)
        if tool_bar >= 4 and d.bytes > 0 then
          local top = t.results >= t.calls and t.results >= t.definitions and "results"
            or (t.calls >= t.definitions and "calls" or "definitions")
          put("  " .. bar(t.bytes / d.bytes, tool_bar), KIND[top].hl)
        end
      end
      add(l)
    end
    if #d.tools > shown_tools then add(line("  … " .. (#d.tools - shown_tools) .. " more, included in the totals", "Dim")) end
  end

  -- The heaviest messages, with a glimpse of each in the current view.
  if #d.largest > 0 then
    add("")
    add(title("Largest messages", w))
    local who_w = 9
    for _, m in ipairs(d.largest) do who_w = math.max(who_w, width(m.role .. (m.name and (" · " .. m.name) or "")) + 2) end
    who_w = math.min(who_w, 24)
    for _, m in ipairs(d.largest) do
      l, put = builder()
      put(lpad(num(tokens(m.bytes)), 8), "MdBold")
      put(lpad(d.bytes > 0 and pct(m.bytes / d.bytes) or "", 5), "Dim")
      put(lpad("#" .. m.index, 6), "Dim")
      local who = m.role .. (m.name and (" · " .. m.name) or "")
      local kind = KIND[({ tool = "results", system = "system", user = "user", assistant = "assistant" })[m.role] or "user"]
      put("  " .. pad(who, who_w), kind.hl)
      local room = w - 21 - who_w
      if m.preview and m.preview ~= "" and room >= 12 then put(bone.text.truncate(m.preview, room), "Dim") end
      add(l)
    end
  end

  add("")
  add(title("Notes", w))
  local notes = mode == "current" and data.notes or {
    "The exact messages and tools of the last observed request; token counts are estimates.",
    "A request hook with a still lower priority may change it after observation.",
    "Text reasoning is counted as potential replay; opaque reasoning and provider framing are excluded.",
  }
  for _, note in ipairs(notes) do
    for i, wrapped in ipairs(bone.text.wrap({ { note, "Dim" } }, math.max(w - 4, 1))) do
      table.insert(wrapped, 1, { i == 1 and "  · " or "    ", "Dim" })
      out[#out + 1] = wrapped
    end
  end
  return out
end

local function header(w)
  local l, add = builder()
  add(" Context ", "PopupTitle")
  add("  ")
  add(" Current ", mode == "current" and "SettingsTabCurrent" or "SettingsTab")
  add(" ")
  add(" Last request ", mode == "request" and "SettingsTabCurrent" or "SettingsTab")
  if data then
    local who = table.concat({ data.title or data.session_id, (data.provider or "") .. (data.model and ("/" .. data.model) or "") }, " · ")
    local room = w - 39
    if room > 8 then add("  " .. lpad(bone.text.truncate(who, room), room) .. " ", "Dim") end
  end
  return l
end

local function open(request)
  close()
  mode, scroll = request and "request" or "current", 0
  local cached, cached_width, cached_data, cached_status, cached_mode
  window = bone.ui.popup({ anchor = "screen", row = 0, col = 0, width = 10000, height = 10000,
    lines = function(ctx)
      colors()
      local w, height = ctx.width, ctx.height
      local status = tostring(loading) .. tostring(failure) .. tostring(bone.settings.get("context.window_tokens"))
      if not cached or cached_width ~= w or cached_data ~= data or cached_status ~= status or cached_mode ~= mode then
        cached, cached_width, cached_data, cached_status, cached_mode = body(w), w, data, status, mode
      end
      page = math.max(1, height - 4)
      max_scroll = math.max(0, #cached - page)
      scroll = math.max(0, math.min(scroll, max_scroll))
      local out = { header(w), { { fill = "─", hl = "WinSeparator" } } }
      for i = 1, page do out[#out + 1] = cached[scroll + i] or {} end
      out[#out + 1] = { { fill = "─", hl = "WinSeparator" } }
      local more = max_scroll > 0 and string.format("  %d%%", math.floor(scroll / max_scroll * 100 + 0.5)) or ""
      out[#out + 1] = line(" tab/1/2 view · r refresh · ↑↓ scroll · q close" .. more, "Dim")
      return out
    end,
    on_key = function(key)
      if key == "q" or key == "esc" or key == "ctrl+c" then close()
      elseif key == "r" then load()
      elseif key == "tab" or key == "shift+tab" or key == "left" or key == "right" or key == "h" or key == "l" then
        mode, scroll = mode == "current" and "request" or "current", 0
      elseif key == "1" or key == "2" then
        mode, scroll = key == "1" and "current" or "request", 0
      elseif key == "j" or key == "down" or key == "wheeldown" then scroll = math.min(max_scroll, scroll + (key == "wheeldown" and 3 or 1))
      elseif key == "k" or key == "up" or key == "wheelup" then scroll = math.max(0, scroll - (key == "wheelup" and 3 or 1))
      elseif key == "pagedown" or key == "space" then scroll = math.min(max_scroll, scroll + page)
      elseif key == "pageup" then scroll = math.max(0, scroll - page)
      elseif key == "home" or key == "g" then scroll = 0
      elseif key == "end" or key == "G" then scroll = max_scroll
      else return false end
      return true
    end,
  })
  load()
end
for _, event in ipairs({ "chat/shown", "message/completed", "turn/finished", "session/compacted", "session/updated" }) do
  bone.on(event, function(ev)
    if event == "chat/shown" or ev.session_id == current() then load() end
  end)
end
bone.cmd.create("context", function(c)
  local arg = (c.args or ""):match("^%s*(.-)%s*$")
  if arg ~= "" and arg ~= "request" then bone.notify("Usage: /context [request]", "error"); return end
  open(arg == "request")
end, { desc = "show what fills the conversation's context", complete = function()
  return { { value = "request", desc = "inspect the last observed model request" } }
end })
