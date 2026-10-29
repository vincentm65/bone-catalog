-- Desktop presentation of the context dashboard. The TUI keeps drawing
-- `lines`; this tree is the same information with pointer actions. Tabs,
-- buttons, hints and sizes are the desktop library's; the category colors
-- are the Context* groups ui.lua derives from the colorscheme.
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
  local node = { text = value, hl = hl or "Normal", size = S.size.body }
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
  return text(value, hl or "MdBold", { font = "mono", size = S.size.caption, width = w or 56, text_align = "right",
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

-- A group's foreground as a fill. Context* groups only have one; without
-- the style module (or a hex color) the bars fall back to block glyphs.
local function fill(hl)
  return S.alpha and S.alpha(hl, "ff", "fg") or nil
end

-- The share of one row: a thin track, filled `share` of the way.
local function row_bar(share, hl)
  local color = fill(hl)
  if not color then
    local cells = math.max(share > 0 and 1 or 0, math.min(24, math.floor(share * 24 + 0.5)))
    return { text = string.rep("█", cells), hl = hl, font = "mono", size = S.size.small, width = 96, shrink = 0 }
  end
  return {
    width = 96, height = 6, shrink = 0, bg = "Selection", radius = 3, overflow = "hidden", direction = "row",
    share > 0 and { width = string.format("%.2f%%", math.max(2, math.min(100, share * 100))), bg = color, radius = 3 } or nil,
  }
end

-- The whole context as one bar, each category its share of it.
local function meter(rows, total, kinds)
  local bar = { direction = "row", height = 10, radius = 5, overflow = "hidden", bg = "Selection", gap = 2 }
  local glyphs = { direction = "row", flex_wrap = true }
  for _, row in ipairs(rows or {}) do
    if row.bytes > 0 and total > 0 then
      local kind = kinds[row.key] or {}
      local color = fill(kind.hl or "Normal")
      if color then
        bar[#bar + 1] = { grow = row.bytes / total, width = 0, bg = color, tooltip = kind.short }
      end
      glyphs[#glyphs + 1] = { text = string.rep("█", math.max(1, math.floor(row.bytes / total * 36 + 0.5))),
        hl = kind.hl or "Normal", font = "mono", size = S.size.caption }
    end
  end
  if #bar > 0 then return bar end
  if #glyphs > 0 then return glyphs end
  return small("empty")
end

function M.build(api)
  local mode = api.mode
  local header = {
    direction = "row", align = "center", gap = S.space.md,
    W.title("Context"),
    W.segmented({ "Current", "Last request" }, mode == "request" and 2 or 1, function(i)
      api.set_mode(i == 2 and "request" or "current")
    end),
    { grow = 1 },
    W.icon_button("↻", "Refresh", api.refresh),
    W.icon_button("✕", "Close", api.close),
  }

  local body = { id = "context:body", direction = "column", gap = S.space.xl, grow = 1, height = 0, overflow = "scroll" }
  local function add(node) body[#body + 1] = node end

  if api.failure then
    add(W.note(api.failure, { 0, 0 }, "ErrorMsg"))
    add(W.note("Try /plugins reload context, then press Refresh.", { 0, 0 }))
  elseif api.loading or not api.data then
    add(W.note("Loading context…", { 0, 0 }))
  else
    local data = api.data
    local d = data[mode]
    local who = table.concat({
      data.title or data.session_id or "",
      (data.provider or "") .. (data.model and ("/" .. data.model) or ""),
    }, " · ")
    if not d then
      add(W.note("No request observed yet. Send a message, then press Refresh. Current shows this conversation's estimate.", { 0, 0 }))
    else
      local total = api.tokens(d.bytes)
      local capacity = api.capacity()
      local limit = tonumber(data.compact_limit) or 0
      local summary = {
        direction = "column", gap = S.space.sm,
        {
          direction = "row", gap = S.space.md, align = "center", flex_wrap = true,
          text("≈ " .. api.num(total) .. " tokens", "Normal", { bold = true, size = S.size.lead }),
          small(mode == "current" and "estimated current context" or ("last request · " .. api.ago(data.request_at))),
          { grow = 1 },
          W.pill(data.calibrated and "CALIBRATED" or "UNCALIBRATED",
            { hl = data.calibrated and "Dim" or "WarningMsg", bg = "Selection" }),
        },
      }
      if who ~= " · " and who ~= "" then summary[#summary + 1] = small(who) end
      if capacity > 0 then
        summary[#summary + 1] = text(api.pct(total / capacity) .. " of the " .. api.num(capacity) .. " window · "
          .. (total > capacity and (api.num(total - capacity) .. " over") or (api.num(capacity - total) .. " free")),
          total > capacity and "WarningMsg" or "Normal", { size = S.size.caption })
      elseif limit > 0 then
        summary[#summary + 1] = text(api.pct(total / limit) .. " of the " .. api.num(limit) .. " compaction limit · "
          .. (total >= limit and "compacts on the next turn" or (api.num(limit - total) .. " to go")),
          total >= limit and "WarningMsg" or "Normal", { size = S.size.caption })
      end
      summary[#summary + 1] = meter(d.rows, d.bytes or 0, api.kinds)
      local legend = { direction = "row", gap = S.space.lg, row_gap = S.space.xs, flex_wrap = true }
      for _, row in ipairs(d.rows or {}) do
        if row.bytes > 0 then
          local kind = api.kinds[row.key] or {}
          legend[#legend + 1] = {
            direction = "row", gap = S.space.sm, align = "center",
            { text = "■", hl = kind.hl or "Normal", size = S.size.small },
            small((kind.short or row.key) .. " " .. api.num(api.tokens(row.bytes))),
          }
        end
      end
      if #legend > 0 then summary[#summary + 1] = legend end
      local facts = {}
      if limit > 0 and capacity > 0 then
        facts[#facts + 1] = "compacts at " .. api.num(limit) .. (total >= limit and " · due on the next turn"
          or string.format(" · %.0f%% there, %s to go", total / limit * 100, api.num(limit - total)))
      end
      if mode == "current" then
        facts[#facts + 1] = string.format("%d active / %d stored messages%s", d.messages or 0, d.stored_messages or 0,
          (d.summarized or 0) > 0 and (" · " .. d.summarized .. " summarized") or "")
      elseif data.request_at then
        facts[#facts + 1] = "observed " .. os.date("%H:%M:%S", data.request_at) .. ", after context hooks"
      end
      if data.usage then
        local u = data.usage
        local input = tonumber(u.context_tokens or u.input_tokens) or 0
        local cached = tonumber(u.cached_tokens) or 0
        facts[#facts + 1] = "provider counted " .. api.num(input) .. " input on the last call"
          .. (cached > 0 and string.format(" · %s cached (%.0f%%)", api.num(cached), input > 0 and cached / input * 100 or 0) or "")
      end
      if #facts > 0 then summary[#summary + 1] = small(table.concat(facts, " · ")) end
      if capacity == 0 then
        summary[#summary + 1] = small("Set a context window in /config → Context to see how full it is.")
      end
      add(summary)

      local breakdown = {}
      for _, row in ipairs(d.rows or {}) do
        if row.bytes > 0 then
          local share = d.bytes > 0 and row.bytes / d.bytes or 0
          local kind = api.kinds[row.key] or {}
          breakdown[#breakdown + 1] = {
            direction = "row", gap = S.space.md, align = "center",
            { text = "■", hl = kind.hl or "Normal", size = S.size.small },
            text(row.label or kind.short or row.key, "Normal", { size = S.size.caption, grow = 1, width = 0,
              wrap = false, text_overflow = "ellipsis" }),
            small(row.count > 1 and ("×" .. row.count) or "", nil, { width = 40, text_align = "right", shrink = 0 }),
            figure(api.num(api.tokens(row.bytes))),
            figure(api.pct(share), "Dim", 44),
            row_bar(share, kind.hl or "Normal"),
          }
        end
      end
      if #breakdown == 0 then breakdown[1] = small("empty") end
      add(section("Breakdown", data.calibrated and string.format("%.2f bytes/token", data.bytes_per_token) or "4 bytes/token", breakdown))
      if (d.image_count or 0) > 0 then
        add(small("Images count 85 + 170 tokens per 512px tile; provider billing may differ."))
      end

      local schemas, schema_bytes = {}, 0
      for _, t in ipairs(d.tools or {}) do
        if t.definitions > 0 then
          schemas[#schemas + 1] = t
          schema_bytes = schema_bytes + t.definitions
        end
      end
      table.sort(schemas, function(a, b)
        return a.definitions == b.definitions and a.name < b.name or a.definitions > b.definitions
      end)
      local schema_rows = {}
      if #schemas == 0 then
        schema_rows[1] = small(data.request and "No tool schemas were offered in the last observed request."
          or "Tool schemas are unknown until this conversation makes a model request.")
      else
        for _, t in ipairs(schemas) do
          local share = schema_bytes > 0 and t.definitions / schema_bytes or 0
          schema_rows[#schema_rows + 1] = {
            direction = "row", gap = S.space.md, align = "center",
            text(t.name, "ToolName", { font = "mono", size = S.size.small, grow = 1, width = 0,
              wrap = false, text_overflow = "ellipsis" }),
            figure(api.num(api.tokens(t.definitions))),
            figure(api.pct(share), "Dim", 44),
            row_bar(share, (api.kinds.definitions or {}).hl or "ToolArgs"),
          }
        end
      end
      add(section("Tool schemas", #schemas > 0 and (#schemas .. " tools · ≈ " .. api.num(api.tokens(schema_bytes)) .. " tokens") or nil, schema_rows))

      if #(d.tools or {}) > 0 then
        local shown_tools = math.min(15, #d.tools)
        local function head(label) return small(label, nil, { width = 56, text_align = "right", shrink = 0 }) end
        local cost_rows = {
          {
            direction = "row", gap = S.space.md,
            small("tool", nil, { grow = 1 }), head("total"), head("schema"), head("args"), head("results"),
            { width = 96, shrink = 0 },
          },
        }
        for i = 1, shown_tools do
          local t = d.tools[i]
          local function part(v) return figure(v > 0 and api.num(api.tokens(v)) or "·", "Dim") end
          local top = t.results >= t.calls and t.results >= t.definitions and "results"
            or (t.calls >= t.definitions and "calls" or "definitions")
          cost_rows[#cost_rows + 1] = {
            direction = "row", gap = S.space.md, align = "center",
            text(t.name, "ToolName", { font = "mono", size = S.size.small, grow = 1, width = 0,
              wrap = false, text_overflow = "ellipsis" }),
            figure(api.num(api.tokens(t.bytes))),
            part(t.definitions), part(t.calls), part(t.results),
            row_bar((d.bytes or 0) > 0 and t.bytes / d.bytes or 0, (api.kinds[top] or {}).hl or "Normal"),
          }
        end
        if #d.tools > shown_tools then
          cost_rows[#cost_rows + 1] = small("… " .. (#d.tools - shown_tools) .. " more, included in the totals")
        end
        add(section("Tool costs", "top " .. shown_tools, cost_rows))
      end

      if #(d.largest or {}) > 0 then
        local largest = {}
        for _, m in ipairs(d.largest) do
          local who_m = m.role .. (m.name and (" · " .. m.name) or "")
          local key = ({ tool = "results", system = "system", user = "user", assistant = "assistant" })[m.role] or "user"
          largest[#largest + 1] = {
            direction = "column", gap = S.space.xs,
            {
              direction = "row", gap = S.space.md, align = "center",
              figure(api.num(api.tokens(m.bytes))),
              figure(d.bytes > 0 and api.pct(m.bytes / d.bytes) or "", "Dim", 44),
              small("#" .. tostring(m.index), nil, { width = 40, shrink = 0 }),
              text(who_m, (api.kinds[key] or {}).hl or "Normal", { size = S.size.caption }),
            },
            (m.preview and m.preview ~= "") and small(m.preview, nil, { padding = { 0, 0, 0, 164 },
              wrap = false, text_overflow = "ellipsis" }) or nil,
          }
        end
        add(section("Largest messages", nil, largest))
      end

      local notes = mode == "current" and data.notes or {
        "The exact messages and tools of the last observed request; token counts are estimates.",
        "A request hook with a still lower priority may change it after observation.",
        "Text reasoning is counted as potential replay; opaque reasoning and provider framing are excluded.",
      }
      local note_rows = {}
      for _, note in ipairs(notes or {}) do note_rows[#note_rows + 1] = small("· " .. note) end
      if #note_rows > 0 then add(section("Notes", nil, note_rows)) end
    end
  end

  return {
    direction = "column", gap = S.space.md, grow = 1,
    header,
    W.divider({ margin = { 0, 0, 0, 0 } }),
    body,
    W.hints("tab switch · r refresh · ↑↓ scroll · q close", { 0, 0 }),
  }
end

return M
