-- Desktop usage dashboard. Keyboard filtering stays in ui.lua; clicks here
-- call the same activate() path as Tab/Enter and the terminal's mouse hits.
-- Controls, cards, hints and sizes are the desktop library's; the heat
-- colors are the UsageHeat* groups ui.lua derives from the colorscheme.
local M = {}

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

local function text(value, hl, extra)
  local node = { text = tostring(value), hl = hl or "Normal", size = S.size.body }
  for k, v in pairs(extra or {}) do node[k] = v end
  return node
end
local function small(value, hl, extra)
  extra = extra or {}
  extra.size = extra.size or S.size.small
  return text(value, hl or "Dim", extra)
end
-- A number in a column of numbers: right-aligned at a fixed width.
local function figure(value, hl, w)
  return text(value, hl or "UsageValue", { font = "mono", size = S.size.caption, width = w or 64, text_align = "right",
    wrap = false, shrink = 0 })
end

-- A section: a small capital label (and what is on its right), then rows.
local function section(title, right, children)
  local col = {
    direction = "column", gap = S.space.sm,
    {
      direction = "row", align = "center", gap = S.space.md,
      { text = title:upper(), hl = "Dim", bold = true, size = S.size.micro, grow = 1 },
      right and right ~= "" and small(right) or nil,
    },
  }
  for _, child in ipairs(children) do col[#col + 1] = child end
  return col
end

local function heat_name(v, maxv)
  v = tonumber(v) or 0
  if v <= 0 or not maxv or maxv <= 0 then return "UsageHeat0" end
  return "UsageHeat" .. math.max(1, math.min(4, math.ceil(math.sqrt(v / maxv) * 4)))
end

-- A group's foreground as a fill: UsageHeat* and Accent only have one.
-- Without the style module (or a hex color) cells fall back to glyphs.
local function fill(hl)
  return S.alpha and S.alpha(hl, "ff", "fg") or nil
end

-- One heat cell: a small square of the level's color.
local function cell(hl, click)
  local color = fill(hl)
  local node = color and { width = 11, height = 11, radius = 2, bg = color, shrink = 0 }
    or { text = "■", hl = hl, size = S.size.small }
  if click then W.press(node, click, "button", false) end
  return node
end

local function card(metric, scope)
  local delta = metric[3]
  return W.surface({
    gap = S.space.xs, padding = { 8, 12 }, radius = S.radius.md, grow = 1,
    small(scope and (scope .. " · " .. metric[1]) or metric[1]),
    {
      direction = "row", gap = S.space.sm, align = "center",
      text(metric[2], "UsageValue", { bold = true, size = S.size.lead }),
      delta and small(delta, tostring(delta):find("▲", 1, true) and "Notice" or "Dim") or nil,
    },
    metric[4] and small(metric[4]) or nil,
  })
end

-- A filter chip: a pill that removes its filter.
local function chip(label, click)
  return W.press(W.pill(label, { size = S.size.small }), click, "button")
end

function M.build(ctx, api)
  local st = api.st
  local r = st.span or api.span(st.period, st.custom)
  local names, current = {}, 0
  for i, p in ipairs(api.periods) do
    names[i] = api.titles[p]
    if not st.custom and st.period == p then current = i end
  end
  local header = {
    direction = "column", gap = S.space.sm,
    {
      direction = "row", align = "center", gap = S.space.md,
      W.title("Usage"),
      small(r.label or "", "Normal", { grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" }),
      small(st.loading and "loading…" or (st.updated and ("updated " .. os.date("%H:%M", st.updated)) or "")),
      W.icon_button("↻", "Refresh", function() api.load(true) end),
    },
    {
      direction = "row", gap = S.space.md, align = "center", flex_wrap = true,
      W.segmented(names, current, function(i) api.activate({ period = api.periods[i] }) end),
      W.button(st.custom and r.label or "Dates", function() api.activate({ dates = true }) end, st.custom and true or false,
        false, { size = S.size.caption, padding = { 4, 12 } }),
    },
  }
  local chips = { direction = "row", gap = S.space.sm, flex_wrap = true }
  if st.custom then chips[#chips + 1] = chip(r.label .. " ×", function() api.activate({ remove = "range" }) end) end
  if st.filters.model then
    local m = st.filters.model
    chips[#chips + 1] = chip(m[1] .. "/" .. m[2] .. " ×", function() api.activate({ remove = "model" }) end)
  end
  if st.filters.session then
    chips[#chips + 1] = chip(st.filters.session[2] .. " ×", function() api.activate({ remove = "session" }) end)
  end
  if st.custom or next(st.filters) then
    chips[#chips + 1] = W.link("Clear all", function() api.activate({ remove = "clear" }) end)
  end
  if #chips > 0 then header[#header + 1] = chips end
  if st.input then
    header[#header + 1] = W.field("Dates", st.input,
      { editing = true, on = true, hint = "YYYY-MM-DD..YYYY-MM-DD · enter apply · esc cancel" })
  elseif st.note then
    header[#header + 1] = W.note(st.note, { 0, 0 }, "ErrorMsg")
  end

  local body = { id = "usage:body", direction = "column", gap = S.space.xl, grow = 1, height = 0, overflow = "scroll" }
  local function add(node) body[#body + 1] = node end
  if st.err then
    add(W.note("error: " .. st.err, { 0, 0 }, "ErrorMsg"))
  elseif not st.data then
    add(W.note("loading…", { 0, 0 }))
  else
    local d = st.data
    if d.conversation then
      add(small("Current: this chat, all time (unfiltered) · All: " .. (d.filtered and "filtered chats" or "all chats")
        .. ", selected period"))
    end
    local list = api.metrics(d, r)
    local now = d.conversation and api.metrics(d.conversation, { bucket = "day" })
    local cards = { direction = "row", gap = S.space.md, flex_wrap = true }
    for i, metric in ipairs(list) do
      local col = { direction = "column", gap = S.space.sm, grow = 1 }
      if now then col[#col + 1] = card(now[i], "Current") end
      col[#col + 1] = card(metric, now and "All" or nil)
      cards[#cards + 1] = col
    end
    add(cards)

    local buckets = api.buckets(r, d.series_first)
    local maxv, total, peak, active = 0, 0, nil, 0
    for _, b in ipairs(buckets) do
      local s = d.series[b.key]
      b.v = s and (tonumber(s[1]) or 0) or 0
      total = total + b.v
      if b.v > 0 then active = active + 1 end
      if b.v > maxv then maxv, peak = b.v, b end
    end
    local now_key = r.bucket == "hour" and os.date("%H") or (r.bucket == "day" and api.ymd(os.time())) or nil
    local right = peak and string.format("peak %s on %s · avg %s", api.num(maxv), peak.label, api.num(total / math.max(active, 1)))
    local columns
    if maxv == 0 then
      columns = small("no model calls in this period")
    else
      columns = { direction = "row", gap = S.space.xs, align = "end", overflow = "scroll", height = 150 }
      for _, b in ipairs(buckets) do
        local h = math.max(b.v > 0 and 3 or 1, math.floor(116 * b.v / maxv))
        local hl = b.key == now_key and "Accent" or heat_name(b.v, maxv)
        local color = fill(hl)
        columns[#columns + 1] = W.press({
          direction = "column", justify = "end", align = "center", gap = S.space.xs, width = 32, shrink = 0,
          radius = S.radius.sm, padding = { 2, 0 }, tooltip = b.label .. " · " .. api.num(b.v),
          color and { width = 20, height = h, bg = color, radius = 3 }
            or { text = "▇", hl = hl, font = "mono", size = math.max(12, math.min(64, 12 + math.floor(h / 2))) },
          small(b.label, nil, { size = S.size.micro, wrap = false }),
        }, function() api.activate({ range = api.bucket_range(r, b.key) }) end, "button")
      end
    end
    add(section("Tokens per " .. r.bucket, right, { columns }))

    local model_rows = {}
    if #d.models == 0 then
      model_rows[1] = small("none")
    else
      local total_m = 0
      for _, m in ipairs(d.models) do total_m = total_m + (tonumber(m[4]) or 0) + (tonumber(m[5]) or 0) end
      for _, m in ipairs(d.models) do
        local tok = (tonumber(m[4]) or 0) + (tonumber(m[5]) or 0)
        local cache = api.pct(m[6], m[4])
        local picked = st.filters.model and st.filters.model[1] == m[1] and st.filters.model[2] == m[2] or false
        local row = W.entry(picked, {
          {
            direction = "row", gap = S.space.md, align = "center",
            text(m[1] .. " / " .. m[2], "Normal", { size = S.size.caption, grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" }),
            figure(api.num(m[3]) .. " req", "Dim", 72),
            figure(api.num(m[4]) .. " in", "Normal", 80),
            figure(api.num(m[5]) .. " out", "Normal", 80),
            figure(cache and string.format("%.0f%% cache", cache) or "-", "Dim", 88),
            figure(total_m > 0 and string.format("%.0f%%", tok / total_m * 100) or "", "Dim", 44),
          },
        }, function() api.activate({ model = { m[1], m[2] } }) end)
        row.padding = { 4, 8 }
        model_rows[#model_rows + 1] = row
      end
    end
    add(section("Models", nil, model_rows))

    local calls, fails = 0, 0
    for _, t in ipairs(d.tools) do
      calls, fails = calls + (tonumber(t[2]) or 0), fails + (tonumber(t[3]) or 0)
    end
    local tool_rows = {}
    if d.model_filter then tool_rows[#tool_rows + 1] = small("unfiltered by model (not attributable)") end
    if #d.tools == 0 then
      tool_rows[#tool_rows + 1] = small("no tool calls in this period")
    else
      local limit = (ctx and ctx.width or 0) >= 900 and 14 or 10
      for i, t in ipairs(d.tools) do
        if i > limit then
          tool_rows[#tool_rows + 1] = small("… " .. (#d.tools - limit) .. " more")
          break
        end
        local c, f = tonumber(t[2]) or 0, tonumber(t[3]) or 0
        local rate = c > 0 and f * 100 / c or 0
        tool_rows[#tool_rows + 1] = {
          direction = "row", gap = S.space.md, align = "center", padding = { 0, 8 },
          text(t[1], "ToolName", { font = "mono", size = S.size.small, grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" }),
          figure(api.num(c), "Normal"),
          figure(f > 0 and string.format("%.1f%% failed", rate) or "-", rate >= 10 and "ErrorMsg" or (f > 0 and "Notice" or "Dim"), 96),
          figure(t[4] and (api.num(t[4]) .. "ch") or "-", "Dim", 72),
        }
      end
    end
    add(section("Tools", calls > 0 and string.format("%s calls · %s failed", api.num(calls), api.num(fails)) or nil, tool_rows))

    local grid, punch_max = {}, 0
    for _, row in ipairs(d.punch) do
      local mon0 = ((tonumber(row[1]) or 0) + 6) % 7
      local key = mon0 * 24 + (tonumber(row[2]) or 0)
      grid[key] = tonumber(row[3]) or 0
      punch_max = math.max(punch_max, grid[key])
    end
    local by_hour, best = {}, nil
    for hr = 0, 23 do
      local s = 0
      for wd = 0, 6 do s = s + (grid[wd * 24 + hr] or 0) end
      by_hour[hr] = s
      if s > 0 and (not best or s > by_hour[best]) then best = hr end
    end
    local punch_rows = {}
    if punch_max == 0 then
      punch_rows[1] = small("no activity")
    else
      for wd = 0, 6 do
        local line = { direction = "row", gap = 3, align = "center" }
        line[#line + 1] = small(api.weekdays[wd + 1], nil, { size = S.size.micro, width = 36, shrink = 0 })
        for hr = 0, 23 do line[#line + 1] = cell(heat_name(grid[wd * 24 + hr], punch_max)) end
        punch_rows[#punch_rows + 1] = line
      end
    end
    add(section("Hours", best and string.format("busiest %02d:00-%02d:00", best, (best + 1) % 24) or nil, punch_rows))

    local weeks = 26
    if ctx and ctx.width and ctx.width > 0 then
      weeks = math.max(8, math.min(53, math.floor((ctx.width - 80) / 14)))
    end
    local start = api.noon_plus(api.monday(os.time()), -7 * (weeks - 1))
    local today = api.ymd(os.time())
    local keys, day_max = {}, 0
    for i = 0, weeks * 7 - 1 do
      keys[i] = api.ymd(api.noon_plus(start, i))
      day_max = math.max(day_max, d.daily[keys[i]] or 0)
    end
    local streak, best_streak, active_days = api.streaks(d.daily)
    local cal = {}
    for wd = 0, 6 do
      local line = { direction = "row", gap = 3, align = "center" }
      line[#line + 1] = small((wd % 2 == 0) and api.weekdays[wd + 1] or "", nil, { size = S.size.micro, width = 36, shrink = 0 })
      for wk = 0, weeks - 1 do
        local k = keys[wk * 7 + wd]
        if k > today then
          line[#line + 1] = { width = 11, height = 11, shrink = 0 }
        else
          line[#line + 1] = cell(heat_name(d.daily[k], day_max), function()
            api.activate({ range = { from = api.parse_date(k), to = api.midnight(api.parse_date(k), -1) } })
          end)
        end
      end
      cal[#cal + 1] = line
    end
    local legend = { direction = "row", gap = 3, align = "center", margin = { 4, 0, 0, 0 } }
    legend[#legend + 1] = small("less", nil, { size = S.size.micro, margin = { 0, 4, 0, 0 } })
    for i = 0, 4 do legend[#legend + 1] = cell("UsageHeat" .. i) end
    legend[#legend + 1] = small("more", nil, { size = S.size.micro, margin = { 0, 0, 0, 4 } })
    cal[#cal + 1] = legend
    add(section("Activity · all time", string.format("streak %dd · best %dd · %d day%s", streak, best_streak, active_days, active_days == 1 and "" or "s"), cal))

    local session_rows = {}
    if #d.sessions == 0 then
      session_rows[1] = small("none")
    else
      for _, s in ipairs(d.sessions) do
        local picked = st.filters.session and s[5] and st.filters.session[1] == s[5] or false
        local dir = (s[2] and s[2] ~= "") and (tostring(s[2]):match("[^/]+$") or "") or ""
        local row = W.entry(picked, {
          {
            direction = "row", gap = S.space.md, align = "center",
            figure(api.num(s[3])),
            figure(api.num(s[4]) .. "r", "Dim", 48),
            text(s[1] or "", "Normal", { size = S.size.caption, grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" }),
            dir ~= "" and small(dir, nil, { font = "mono", wrap = false, shrink = 0 }) or nil,
          },
        }, s[5] and function() api.activate({ session = { s[5], s[1] } }) end or nil)
        row.padding = { 4, 8 }
        session_rows[#session_rows + 1] = row
      end
    end
    add(section("Busiest sessions", nil, session_rows))
  end

  return {
    direction = "column", gap = S.space.md, grow = 1,
    header,
    W.divider({ margin = { 0, 0, 0, 0 } }),
    body,
    W.hints("←→ period · t dates · c clear · r refresh · ↑↓ scroll · q close · click a bar, day, model or session to filter", { 0, 0 }),
  }
end

return M
