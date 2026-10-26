-- Desktop presentation of the context dashboard. The TUI keeps drawing
-- `lines`; this tree is the same information with pointer actions.
local M = {}

local widgets, popups, style

local function libs()
  if widgets ~= nil then return widgets or nil, popups or nil, style or nil end
  local ok, w = pcall(require, "bone.nodes.widgets")
  widgets = ok and w or false
  local ok2, p = pcall(require, "bone.nodes.popups")
  popups = ok2 and p or false
  local ok3, s = pcall(require, "bone.nodes.style")
  style = ok3 and s or false
  return widgets or nil, popups or nil, style or nil
end

local function size(name, fallback)
  local _, _, s = libs()
  return (s and s.size and s.size[name]) or fallback
end

local function button(label, click, primary)
  local w = libs()
  if w and w.button then return w.button(label, click, primary) end
  return {
    text = label, hl = primary and "Accent" or "Normal", bg = primary and "TextSelection" or "Selection",
    padding = { 6, 12 }, radius = 8, cursor = "pointer", role = "button", on_click = click,
  }
end

local function text(value, hl, extra)
  local node = { text = value, hl = hl or "Normal", size = size("body", 14) }
  for k, v in pairs(extra or {}) do node[k] = v end
  return node
end

local function section(title, right, children)
  local head = {
    direction = "row", align = "center", gap = 8,
    text(title, "MdHeading", { bold = true, size = size("lead", 17), grow = 1 }),
  }
  if right and right ~= "" then head[#head + 1] = text(right, "Dim", { size = size("small", 12) }) end
  local col = { direction = "column", gap = 4, head }
  for _, child in ipairs(children) do col[#col + 1] = child end
  return col
end

local function row_bar(share, hl)
  local cells = math.max(share > 0 and 1 or 0, math.min(24, math.floor(share * 24 + 0.5)))
  if cells == 0 then return text("", "Dim") end
  return { text = string.rep("█", cells), hl = hl, font = "mono", size = size("small", 12) }
end

function M.build(api)
  local mode = api.mode
  local header = {
    direction = "row", align = "center", gap = 8, flex_wrap = true,
    text("Context", "Normal", { bold = true, size = size("title", 20) }),
  }
  local function tab(label, next_mode)
    local on = mode == next_mode
    header[#header + 1] = {
      text = label, bold = on, hl = on and "Accent" or "Dim", bg = on and "Selection" or nil,
      padding = { 6, 12 }, radius = 8, size = size("body", 14), selected = on,
      cursor = "pointer", role = "button", on_click = function() api.set_mode(next_mode) end,
    }
  end
  tab("Current", "current")
  tab("Last request", "request")
  header[#header + 1] = { grow = 1 }
  header[#header + 1] = button("Refresh", api.refresh)
  header[#header + 1] = button("Close", api.close)

  local body = { id = "context:body", direction = "column", gap = 14, grow = 1, overflow = "scroll" }
  local function add(node) body[#body + 1] = node end

  if api.failure then
    add(text(api.failure, "ErrorMsg"))
    add(text("Try /plugins reload context, then press Refresh.", "Dim", { size = size("small", 12) }))
  elseif api.loading or not api.data then
    add(text("Loading context…", "Dim"))
  else
    local data = api.data
    local d = data[mode]
    local who = table.concat({
      data.title or data.session_id or "",
      (data.provider or "") .. (data.model and ("/" .. data.model) or ""),
    }, " · ")
    if who ~= " · " and who ~= "" then add(text(who, "Dim", { size = size("small", 12) })) end
    if not d then
      add(text("No request observed yet. Send a message, then press Refresh.", "Dim"))
      add(text("Current shows this conversation's estimate.", "Dim", { size = size("small", 12) }))
    else
      local total = api.tokens(d.bytes)
      local capacity = api.capacity()
      local limit = tonumber(data.compact_limit) or 0
      local summary = {
        direction = "column", gap = 4,
        {
          direction = "row", gap = 8, align = "center", flex_wrap = true,
          text("≈ " .. api.num(total) .. " tokens", "Accent", { bold = true, size = size("lead", 17) }),
          text(mode == "current" and "estimated current context" or ("last request · " .. api.ago(data.request_at)), "Dim"),
          text(data.calibrated and "calibrated" or "uncalibrated", data.calibrated and "Dim" or "WarningMsg"),
        },
      }
      if capacity > 0 then
        summary[#summary + 1] = text(api.pct(total / capacity) .. " of the " .. api.num(capacity) .. " window · "
          .. (total > capacity and (api.num(total - capacity) .. " over") or (api.num(capacity - total) .. " free")),
          total > capacity and "WarningMsg" or "Normal")
      elseif limit > 0 then
        summary[#summary + 1] = text(api.pct(total / limit) .. " of the " .. api.num(limit) .. " compaction limit · "
          .. (total >= limit and "compacts on the next turn" or (api.num(limit - total) .. " to go")),
          total >= limit and "WarningMsg" or "Normal")
      end
      local meter = { direction = "row", gap = 0, align = "center", flex_wrap = true }
      if (d.bytes or 0) > 0 then
        for _, row in ipairs(d.rows or {}) do
          if row.bytes > 0 then
            local n = math.max(1, math.floor(row.bytes / d.bytes * 36 + 0.5))
            meter[#meter + 1] = { text = string.rep("█", n), hl = (api.kinds[row.key] or {}).hl or "Normal", font = "mono", size = size("caption", 13) }
          end
        end
      end
      if #meter == 0 then meter[1] = text("empty", "Dim") end
      summary[#summary + 1] = meter
      local legend = { direction = "row", gap = 10, flex_wrap = true }
      for _, row in ipairs(d.rows or {}) do
        if row.bytes > 0 then
          local kind = api.kinds[row.key] or {}
          legend[#legend + 1] = {
            direction = "row", gap = 4, align = "center",
            { text = "■", hl = kind.hl or "Normal" },
            text((kind.short or row.key) .. " " .. api.num(api.tokens(row.bytes)), "Dim", { size = size("small", 12) }),
          }
        end
      end
      if #legend > 0 then summary[#summary + 1] = legend end
      if limit > 0 and capacity > 0 then
        summary[#summary + 1] = text("compacts at " .. api.num(limit) .. (total >= limit and " · due on the next turn"
          or string.format(" · %.0f%% there, %s to go", total / limit * 100, api.num(limit - total))), "Dim", { size = size("small", 12) })
      end
      if mode == "current" then
        summary[#summary + 1] = text(string.format("%d active / %d stored messages%s", d.messages or 0, d.stored_messages or 0,
          (d.summarized or 0) > 0 and (" · " .. d.summarized .. " summarized") or ""), "Dim", { size = size("small", 12) })
      elseif data.request_at then
        summary[#summary + 1] = text("Observed " .. os.date("%H:%M:%S", data.request_at) .. ", after context hooks", "Dim", { size = size("small", 12) })
      end
      if data.usage then
        local u = data.usage
        local input = tonumber(u.context_tokens or u.input_tokens) or 0
        local cached = tonumber(u.cached_tokens) or 0
        summary[#summary + 1] = text("Provider counted " .. api.num(input) .. " input on the last call"
          .. (cached > 0 and string.format(" · %s cached (%.0f%%)", api.num(cached), input > 0 and cached / input * 100 or 0) or ""),
          "Dim", { size = size("small", 12) })
      end
      if capacity == 0 then
        summary[#summary + 1] = text("Set a context window in /config → Context to see how full it is.", "Dim", { size = size("small", 12) })
      end
      add(summary)

      local breakdown = {}
      local shown = 0
      for _, row in ipairs(d.rows or {}) do
        if row.bytes > 0 then
          shown = shown + 1
          local share = d.bytes > 0 and row.bytes / d.bytes or 0
          local kind = api.kinds[row.key] or {}
          breakdown[#breakdown + 1] = {
            direction = "row", gap = 8, align = "center",
            { text = "■", hl = kind.hl or "Normal" },
            text(row.label or kind.short or row.key, "Normal", { grow = 1 }),
            text(row.count > 1 and ("×" .. row.count) or "", "Dim", { size = size("small", 12) }),
            text(api.num(api.tokens(row.bytes)), "MdBold", { font = "mono" }),
            text(api.pct(share), "Dim", { size = size("small", 12) }),
            row_bar(share, kind.hl or "Normal"),
          }
        end
      end
      if shown == 0 then breakdown[1] = text("empty", "Dim") end
      add(section("Breakdown", data.calibrated and string.format("%.2f bytes/token", data.bytes_per_token) or "4 bytes/token", breakdown))
      if (d.image_count or 0) > 0 then
        add(text("Images count 85 + 170 tokens per 512px tile; provider billing may differ.", "Dim", { size = size("small", 12) }))
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
        local note = data.request and "No tool schemas were offered in the last observed request."
          or "Tool schemas are unknown until this conversation makes a model request."
        schema_rows[1] = text(note, "Dim", { size = size("small", 12) })
      else
        schema_rows[1] = text("Estimated tokens · share of all tool schemas", "Dim", { size = size("small", 12) })
        for _, t in ipairs(schemas) do
          schema_rows[#schema_rows + 1] = {
            direction = "row", gap = 8, align = "center",
            text(t.name, "ToolName", { grow = 1 }),
            text(api.num(api.tokens(t.definitions)), "MdBold", { font = "mono" }),
            text(api.pct(schema_bytes > 0 and t.definitions / schema_bytes or 0), "Dim", { size = size("small", 12) }),
            row_bar(schema_bytes > 0 and t.definitions / schema_bytes or 0, (api.kinds.definitions or {}).hl or "ToolArgs"),
          }
        end
      end
      add(section("Tool schemas", #schemas > 0 and (#schemas .. " tools · ≈ " .. api.num(api.tokens(schema_bytes)) .. " tokens") or nil, schema_rows))

      if #(d.tools or {}) > 0 then
        local shown_tools = math.min(15, #d.tools)
        local cost_rows = {
          {
            direction = "row", gap = 8,
            text("tool", "Dim", { grow = 1, size = size("small", 12) }),
            text("total", "Dim", { size = size("small", 12) }),
            text("schema", "Dim", { size = size("small", 12) }),
            text("args", "Dim", { size = size("small", 12) }),
            text("results", "Dim", { size = size("small", 12) }),
          },
        }
        for i = 1, shown_tools do
          local t = d.tools[i]
          local function part(v)
            return text(v > 0 and api.num(api.tokens(v)) or "·", "Dim", { font = "mono", size = size("small", 12) })
          end
          local top = t.results >= t.calls and t.results >= t.definitions and "results"
            or (t.calls >= t.definitions and "calls" or "definitions")
          cost_rows[#cost_rows + 1] = {
            direction = "row", gap = 8, align = "center",
            text(t.name, "ToolName", { grow = 1 }),
            text(api.num(api.tokens(t.bytes)), "MdBold", { font = "mono" }),
            part(t.definitions), part(t.calls), part(t.results),
            row_bar((d.bytes or 0) > 0 and t.bytes / d.bytes or 0, (api.kinds[top] or {}).hl or "Normal"),
          }
        end
        if #d.tools > shown_tools then
          cost_rows[#cost_rows + 1] = text("… " .. (#d.tools - shown_tools) .. " more, included in the totals", "Dim", { size = size("small", 12) })
        end
        add(section("Tool costs", "top " .. shown_tools, cost_rows))
      end

      if #(d.largest or {}) > 0 then
        local largest = {}
        for _, m in ipairs(d.largest) do
          local who_m = m.role .. (m.name and (" · " .. m.name) or "")
          local key = ({ tool = "results", system = "system", user = "user", assistant = "assistant" })[m.role] or "user"
          largest[#largest + 1] = {
            direction = "column", gap = 2, padding = { 4, 0 },
            {
              direction = "row", gap = 8, align = "center", flex_wrap = true,
              text(api.num(api.tokens(m.bytes)), "MdBold", { font = "mono" }),
              text(d.bytes > 0 and api.pct(m.bytes / d.bytes) or "", "Dim", { size = size("small", 12) }),
              text("#" .. tostring(m.index), "Dim", { size = size("small", 12) }),
              text(who_m, (api.kinds[key] or {}).hl or "Normal"),
            },
            (m.preview and m.preview ~= "") and text(m.preview, "Dim", { size = size("small", 12) }) or nil,
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
      for _, note in ipairs(notes or {}) do
        note_rows[#note_rows + 1] = text("· " .. note, "Dim", { size = size("small", 12) })
      end
      if #note_rows > 0 then add(section("Notes", nil, note_rows)) end
    end
  end

  return {
    direction = "column", gap = 10, grow = 1,
    header,
    -- PromptBorder has no background, so it cannot be a fill.
    { height = 1, border = { 1, 0, 0, 0 }, border_color = "PromptBorder" },
    body,
    text("Click Current or Last request · Refresh reloads · scroll the page · q closes", "Dim", { size = size("small", 12) }),
  }
end

return M
