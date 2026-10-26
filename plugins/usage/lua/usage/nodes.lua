-- Desktop usage dashboard. Keyboard filtering stays in ui.lua; clicks here
-- call the same activate() path as Tab/Enter and the terminal's mouse hits.
local M = {}

local widgets, style

local function libs()
  if widgets ~= nil then return widgets or nil, style or nil end
  local ok, w = pcall(require, "bone.nodes.widgets")
  widgets = ok and w or false
  local ok2, s = pcall(require, "bone.nodes.style")
  style = ok2 and s or false
  return widgets or nil, style or nil
end

local function size(name, fallback)
  local _, s = libs()
  return (s and s.size and s.size[name]) or fallback
end

local function text(value, hl, extra)
  local node = { text = tostring(value), hl = hl or "Normal", size = size("body", 14) }
  for k, v in pairs(extra or {}) do node[k] = v end
  return node
end

local function button(label, click, primary)
  local w = libs()
  if w and w.button then return w.button(label, click, primary) end
  return {
    text = label, hl = primary and "Accent" or "Normal", bg = primary and "TextSelection" or "Selection",
    padding = { 6, 12 }, radius = 8, cursor = "pointer", role = "button", on_click = click,
  }
end

local function chip(label, click)
  return {
    text = label, hl = "Accent", bg = "TextSelection", radius = 8, padding = { 4, 8 },
    size = size("small", 12), cursor = "pointer", role = "button", on_click = click,
  }
end

local function section(title, right, children)
  local head = {
    direction = "row", align = "center", gap = 8,
    text(title, "MdHeading", { bold = true, size = size("lead", 17), grow = 1 }),
  }
  if right and right ~= "" then head[#head + 1] = text(right, "Dim", { size = size("small", 12) }) end
  local col = { direction = "column", gap = 6, head }
  for _, child in ipairs(children) do col[#col + 1] = child end
  return col
end

local function heat_name(v, maxv)
  v = tonumber(v) or 0
  if v <= 0 or not maxv or maxv <= 0 then return "UsageHeat0" end
  return "UsageHeat" .. math.max(1, math.min(4, math.ceil(math.sqrt(v / maxv) * 4)))
end

local function card(metric, scope)
  local delta = metric[3]
  return {
    direction = "column", gap = 2, padding = 10, radius = 8, bg = "Panel", border = 1, border_color = "PromptBorder", grow = 1,
    text(scope and (scope .. " · " .. metric[1]) or metric[1], "Dim", { size = size("small", 12) }),
    {
      direction = "row", gap = 6, align = "center",
      text(metric[2], "UsageValue", { bold = true, size = size("lead", 17) }),
      delta and text(delta, tostring(delta):find("▲", 1, true) and "Notice" or "Dim", { size = size("small", 12) }) or nil,
    },
    metric[4] and text(metric[4], "Dim", { size = size("small", 12) }) or nil,
  }
end

function M.build(ctx, api)
  local w = libs()
  local st = api.st
  local r = st.span or api.span(st.period, st.custom)
  local header = {
    direction = "column", gap = 8,
    {
      direction = "row", align = "center", gap = 8,
      text("Usage", "Accent", { bold = true, size = size("title", 20) }),
      text(r.label or "", "Normal", { grow = 1 }),
      text(st.loading and "loading…" or (st.updated and ("updated " .. os.date("%H:%M", st.updated)) or ""), "Dim", { size = size("small", 12) }),
    },
  }
  local periods = { direction = "row", gap = 6, flex_wrap = true }
  if w and w.segmented then
    local names, current = {}, 0
    for i, p in ipairs(api.periods) do
      names[i] = i .. " " .. api.titles[p]
      if not st.custom and st.period == p then current = i end
    end
    periods = w.segmented(names, current, function(i) api.activate({ period = api.periods[i] }) end)
  else
    for i, p in ipairs(api.periods) do
      local on = not st.custom and st.period == p
      periods[#periods + 1] = {
        text = i .. " " .. api.titles[p], bold = on, hl = on and "Accent" or "Dim",
        bg = on and "Selection" or nil, padding = { 4, 10 }, radius = 8, size = size("caption", 13),
        cursor = "pointer", role = "button", selected = on,
        on_click = function() api.activate({ period = p }) end,
      }
    end
  end
  header[#header + 1] = {
    direction = "row", gap = 8, align = "center", flex_wrap = true,
    periods,
    button(st.custom and r.label or "Dates", function() api.activate({ dates = true }) end, st.custom and true or false),
    button("Refresh", function() api.load(true) end),
  }
  local chips = { direction = "row", gap = 8, flex_wrap = true }
  if st.custom then chips[#chips + 1] = chip(r.label .. " ×", function() api.activate({ remove = "range" }) end) end
  if st.filters.model then
    local m = st.filters.model
    chips[#chips + 1] = chip(m[1] .. "/" .. m[2] .. " ×", function() api.activate({ remove = "model" }) end)
  end
  if st.filters.session then
    chips[#chips + 1] = chip(st.filters.session[2] .. " ×", function() api.activate({ remove = "session" }) end)
  end
  if st.custom or next(st.filters) then
    chips[#chips + 1] = chip("Clear all", function() api.activate({ remove = "clear" }) end)
  end
  if #chips > 0 then header[#header + 1] = chips end
  if st.input then
    header[#header + 1] = text("Dates " .. st.input .. "▏   YYYY-MM-DD..YYYY-MM-DD · enter apply · esc cancel", "Accent")
  elseif st.note then
    header[#header + 1] = text(st.note, "ErrorMsg")
  end

  local body = { id = "usage:body", direction = "column", gap = 16, grow = 1, overflow = "scroll" }
  local function add(node) body[#body + 1] = node end
  if st.err then
    add(text("error: " .. st.err, "ErrorMsg"))
  elseif not st.data then
    add(text("loading…", "Dim"))
  else
    local d = st.data
    if d.conversation then
      add(text("Current: this chat, all time (unfiltered)", "Dim", { size = size("small", 12) }))
      add(text(d.filtered and "All: filtered chats, selected period" or "All: all chats, selected period", "Dim", { size = size("small", 12) }))
    end
    local list = api.metrics(d, r)
    local current = d.conversation and api.metrics(d.conversation, { bucket = "day" })
    local cards = { direction = "row", gap = 8, flex_wrap = true }
    for i, metric in ipairs(list) do
      local col = { direction = "column", gap = 6, grow = 1 }
      if current then col[#col + 1] = card(current[i], "Current") end
      col[#col + 1] = card(metric, current and "All" or nil)
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
    local columns = { direction = "row", gap = 4, align = "end", overflow = "scroll", height = 150 }
    if maxv == 0 then
      columns = text("no model calls in this period", "Dim")
    else
      for _, b in ipairs(buckets) do
        local h = math.max(b.v > 0 and 4 or 2, math.floor(120 * b.v / maxv))
        columns[#columns + 1] = {
          direction = "column", justify = "end", align = "center", gap = 4, width = 36,
          cursor = "pointer", role = "button",
          on_click = function() api.activate({ range = api.bucket_range(r, b.key) }) end,
          -- UsageHeat* and Accent are foreground groups; a bg bar would not paint.
          { text = "▇", hl = b.key == now_key and "Accent" or heat_name(b.v, maxv),
            font = "mono", size = math.max(12, math.min(64, 12 + math.floor(h / 2))) },
          text(b.label, "Dim", { size = size("micro", 11) }),
        }
      end
    end
    add(section("Tokens per " .. r.bucket, right, { columns }))

    local model_rows = {}
    if #d.models == 0 then
      model_rows[1] = text("none", "Dim")
    else
      local total_m = 0
      for _, m in ipairs(d.models) do total_m = total_m + (tonumber(m[4]) or 0) + (tonumber(m[5]) or 0) end
      for _, m in ipairs(d.models) do
        local tok = (tonumber(m[4]) or 0) + (tonumber(m[5]) or 0)
        local cache = api.pct(m[6], m[4])
        local picked = st.filters.model and st.filters.model[1] == m[1] and st.filters.model[2] == m[2]
        model_rows[#model_rows + 1] = {
          direction = "row", gap = 8, align = "center", padding = { 4, 6 }, radius = 8,
          bg = picked and "Selection" or nil, cursor = "pointer", role = "button",
          on_click = function() api.activate({ model = { m[1], m[2] } }) end,
          text(m[1] .. " / " .. m[2], "Normal", { grow = 1 }),
          text(api.num(m[3]) .. " req", "Dim", { size = size("small", 12) }),
          text(api.num(m[4]) .. " in", "Normal", { size = size("small", 12) }),
          text(api.num(m[5]) .. " out", "Normal", { size = size("small", 12) }),
          text(cache and string.format("%.0f%% cache", cache) or "-", "Dim", { size = size("small", 12) }),
          text(total_m > 0 and string.format("%.0f%%", tok / total_m * 100) or "", "Dim", { size = size("small", 12) }),
        }
      end
    end
    add(section("Models", nil, model_rows))

    local calls, fails = 0, 0
    for _, t in ipairs(d.tools) do
      calls, fails = calls + (tonumber(t[2]) or 0), fails + (tonumber(t[3]) or 0)
    end
    local tool_rows = {}
    if d.model_filter then tool_rows[#tool_rows + 1] = text("unfiltered by model (not attributable)", "Dim", { size = size("small", 12) }) end
    if #d.tools == 0 then
      tool_rows[#tool_rows + 1] = text("no tool calls in this period", "Dim")
    else
      local limit = (ctx and ctx.width or 0) >= 900 and 14 or 10
      for i, t in ipairs(d.tools) do
        if i > limit then
          tool_rows[#tool_rows + 1] = text("… " .. (#d.tools - limit) .. " more", "Dim", { size = size("small", 12) })
          break
        end
        local c, f = tonumber(t[2]) or 0, tonumber(t[3]) or 0
        local rate = c > 0 and f * 100 / c or 0
        tool_rows[#tool_rows + 1] = {
          direction = "row", gap = 8, align = "center",
          text(t[1], "Normal", { grow = 1 }),
          text(api.num(c), "Normal", { font = "mono", size = size("small", 12) }),
          text(f > 0 and string.format("%.1f%% failed", rate) or "-", rate >= 10 and "ErrorMsg" or (f > 0 and "Notice" or "Dim"), { size = size("small", 12) }),
          text(t[4] and (api.num(t[4]) .. "ch") or "-", "Dim", { size = size("small", 12) }),
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
      punch_rows[1] = text("no activity", "Dim")
    else
      for wd = 0, 6 do
        local line = { direction = "row", gap = 2, align = "center" }
        line[#line + 1] = text(api.weekdays[wd + 1], "Dim", { size = size("micro", 11), width = 36 })
        for hr = 0, 23 do
          line[#line + 1] = { text = "■", hl = heat_name(grid[wd * 24 + hr], punch_max), size = size("small", 12) }
        end
        punch_rows[#punch_rows + 1] = line
      end
    end
    add(section("Hours", best and string.format("busiest %02d:00-%02d:00", best, (best + 1) % 24) or nil, punch_rows))

    local weeks = 26
    if ctx and ctx.width and ctx.width > 0 then
      weeks = math.max(8, math.min(53, math.floor((ctx.width - 80) / 16)))
    end
    local start = api.noon_plus(api.monday(os.time()), -7 * (weeks - 1))
    local today = api.ymd(os.time())
    local keys, day_max = {}, 0
    for i = 0, weeks * 7 - 1 do
      keys[i] = api.ymd(api.noon_plus(start, i))
      day_max = math.max(day_max, d.daily[keys[i]] or 0)
    end
    local cur, best_streak, active_days = api.streaks(d.daily)
    local cal = {}
    for wd = 0, 6 do
      local line = { direction = "row", gap = 3, align = "center" }
      line[#line + 1] = text((wd % 2 == 0) and api.weekdays[wd + 1] or "", "Dim", { size = size("micro", 11), width = 36 })
      for wk = 0, weeks - 1 do
        local k = keys[wk * 7 + wd]
        if k > today then
          line[#line + 1] = { text = "·", hl = "WinSeparator", size = size("micro", 11) }
        else
          line[#line + 1] = {
            text = "■", hl = heat_name(d.daily[k], day_max), size = size("small", 12),
            cursor = "pointer", role = "button",
            on_click = function()
              api.activate({ range = { from = api.parse_date(k), to = api.midnight(api.parse_date(k), -1) } })
            end,
          }
        end
      end
      cal[#cal + 1] = line
    end
    local legend = { direction = "row", gap = 2, align = "center" }
    legend[#legend + 1] = text("less", "Dim", { size = size("micro", 11) })
    for i = 0, 4 do legend[#legend + 1] = { text = "■", hl = "UsageHeat" .. i, size = size("small", 12) } end
    legend[#legend + 1] = text("more", "Dim", { size = size("micro", 11) })
    cal[#cal + 1] = legend
    add(section("Activity · all time", string.format("streak %dd · best %dd · %d day%s", cur, best_streak, active_days, active_days == 1 and "" or "s"), cal))

    local session_rows = {}
    if #d.sessions == 0 then
      session_rows[1] = text("none", "Dim")
    else
      for _, s in ipairs(d.sessions) do
        local picked = st.filters.session and s[5] and st.filters.session[1] == s[5]
        local label = (s[1] or "") .. ((s[2] and s[2] ~= "") and ("  " .. (tostring(s[2]):match("[^/]+$") or "")) or "")
        session_rows[#session_rows + 1] = {
          direction = "row", gap = 8, align = "center", padding = { 4, 6 }, radius = 8,
          bg = picked and "Selection" or nil,
          cursor = s[5] and "pointer" or nil, role = s[5] and "button" or nil,
          on_click = s[5] and function() api.activate({ session = { s[5], s[1] } }) end or nil,
          text(api.num(s[3]), "UsageValue", { font = "mono" }),
          text(api.num(s[4]) .. "r", "Dim", { size = size("small", 12) }),
          text(label, "Normal", { grow = 1 }),
        }
      end
    end
    add(section("Busiest sessions", nil, session_rows))
  end

  local hints = "Click a period, model, chart bucket, calendar day or session to filter · chips remove a filter · c clears · t dates · r refresh · q close"
  return {
    direction = "column", gap = 10, grow = 1,
    header,
    -- PromptBorder has no background, so it cannot be a fill.
    { height = 1, border = { 1, 0, 0, 0 }, border_color = "PromptBorder" },
    body,
    text(hints, "Dim", { size = size("small", 12) }),
  }
end

return M
