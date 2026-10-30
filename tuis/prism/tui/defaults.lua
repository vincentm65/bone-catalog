-- Prism: a vivid, animated TUI library.
--
--   * A 48-step colour wheel (pink → violet → indigo → sky → teal → amber)
--     drives everything; text and borders are painted per character from it.
--   * Motion: a flowing logo and wave in the header, the prompt's border
--     shimmering while a turn runs, a light sweeping across "thinking",
--     shimmer bars on running tools, a breathing cursor on streaming replies.
--   * Your messages are cards with gradient borders; replies hang off a
--     vertical gradient spine; each tool has its own colour chip.
--   * F4 cycles motion: full, calm (slower, only while running), still.
--
-- Self-contained: it does not load bone.ui.setup().

bone.ui.clear()
bone.colorscheme("black")

local BG, BG2, BG3 = "#0d0b1a", "#161329", "#211d3a"
local TEXT, SOFT, FAINT = "#ece8ff", "#a9a3c9", "#5f5888"

local function hl(name, fg, bg, attrs)
  local spec = { fg = fg, bg = bg or BG }
  for k, v in pairs(attrs or {}) do spec[k] = v end
  bone.hl.set(name, spec)
end

-- ---- the colour wheel ------------------------------------------------------

local STOPS = { "#ff6ac1", "#c084fc", "#818cf8", "#38bdf8", "#2dd4bf", "#a3e635", "#fbbf24", "#fb7185" }
local N = 48

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end
local function mix(a, b, t)
  local ar, ag, ab = rgb(a)
  local br, bg, bb = rgb(b)
  return string.format("#%02x%02x%02x",
    math.floor(ar + (br - ar) * t + 0.5), math.floor(ag + (bg - ag) * t + 0.5), math.floor(ab + (bb - ab) * t + 0.5))
end

local wheel = {}
for i = 0, N - 1 do
  local pos = i / N * #STOPS
  local k = math.floor(pos)
  wheel[i + 1] = mix(STOPS[k + 1], STOPS[(k + 1) % #STOPS + 1], pos - k)
end
for i, col in ipairs(wheel) do
  hl("Px" .. i, col, BG, { bold = true })          -- colour on the canvas
  hl("Pf" .. i, mix(col, BG, 0.55), BG)            -- the same, faded
  hl("Pc" .. i, BG, col, { bold = true })          -- a chip: canvas on colour
  hl("Pk" .. i, col, BG2)                          -- on raised cards
end

local function wrap_i(i) return (math.floor(i) % N) + 1 end

-- Motion: "full" animates always, "calm" only while running and slower,
-- "still" never.
local motion = "full"
local function phase(speed)
  if motion == "still" then return 0 end
  return bone.now() / (motion == "calm" and speed * 2 or speed)
end
local function animate(ms, running)
  if motion == "full" or (motion == "calm" and running) then bone.ui.refresh_in(motion == "calm" and ms * 2 or ms) end
end

-- Text painted along the wheel: `from` is the starting colour, `step` how
-- far each character moves, `kind` the group family (Px, Pf, Pc, Pk).
local function grad(text, from, step, kind)
  local out, i = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = { ch, (kind or "Px") .. wrap_i(from + i * (step or 1)) }
    i = i + 1
  end
  return out
end

-- Each tool gets a fixed place on the wheel.
local TOOL_HUE = { shell = 30, read_file = 18, edit_file = 2, write_file = 24, subagent = 10 }
local function hue_of(name)
  if TOOL_HUE[name] then return TOOL_HUE[name] end
  local h = 0
  for i = 1, #(name or "") do h = h + name:byte(i) * 7 end
  return h % N
end

-- ---- named groups ----------------------------------------------------------

hl("Normal", TEXT)
hl("Dim", FAINT)
hl("Accent", wheel[1], BG, { bold = true })
hl("UserPrompt", wheel[1], BG, { bold = true })
hl("UserMessage", TEXT, BG2)
hl("Reasoning", FAINT, BG, { italic = true })
hl("ToolName", TEXT, BG, { bold = true })
hl("ToolArgs", SOFT)
hl("ToolPath", wheel[20])
hl("ToolSummary", FAINT)
hl("ToolOutput", SOFT)
hl("ToolGutter", BG3)
hl("ToolRunning", wheel[38], BG, { bold = true })
hl("ToolError", wheel[44], BG, { bold = true })
hl("Notice", wheel[38])
hl("ErrorMsg", wheel[44], BG, { bold = true })
hl("WarningMsg", wheel[38])
hl("WinSeparator", BG3)
hl("StatusLine", TEXT, BG2)
hl("StatusLineDim", FAINT, BG2)
hl("Selection", TEXT, "#3b2f6b")
hl("Placeholder", FAINT, BG, { italic = true })
hl("InputBackground", TEXT)
hl("InputText", TEXT)
hl("PromptBorder", wheel[12])
hl("PopupBorder", wheel[8])
hl("PopupTitle", wheel[1], BG, { bold = true })
hl("PanelTitle", SOFT, BG2)
hl("PanelTitleFocus", wheel[1], BG2, { bold = true })
hl("MdHeading", wheel[6], BG, { bold = true })
hl("MdBold", "#ffffff", BG, { bold = true })
hl("MdItalic", "#d8ccff", BG, { italic = true })
hl("MdCode", wheel[24], BG2)
hl("MdCodeBlock", "#d6f5ff", BG2)
hl("MdQuote", SOFT, BG, { italic = true })
hl("MdBullet", wheel[1])
hl("MdLink", wheel[20], BG, { underline = true })
hl("MdTable", TEXT)
hl("MdTableHeader", wheel[12], BG, { bold = true })
hl("DiffAdd", "#bbf7d0", "#13322a")
hl("Success", "#bbf7d0")
hl("DiffDelete", "#fecdd3", "#3a1630")
hl("ShellProgram", wheel[24], BG, { bold = true })
hl("ShellPath", wheel[18])
hl("ShellFlag", wheel[8])
hl("ShellString", wheel[30])
hl("ShellVariable", wheel[36])
hl("ShellComment", FAINT, BG, { italic = true })
hl("ShellOperator", wheel[1])
hl("PSoft", SOFT)
hl("PFaint", FAINT)
hl("PCard", TEXT, BG2)
hl("PBand", TEXT, BG2)
hl("PBandDim", FAINT, BG2)
hl("PWhite", "#ffffff", BG, { bold = true })

bone.ui.spinner = { frames = { "◜", "◠", "◝", "◞", "◡", "◟" }, interval = 90 }

-- ---- options and keys ------------------------------------------------------

bone.o.define("queue_mode", "next", {
  desc = "what enter does during a turn: steer or next",
  choices = { "steer", "next" },
})
bone.o.define("tool_detail", "rows", {
  desc = "tool calls: summary, rows or full (ctrl+t)",
  choices = { "summary", "rows", "full" },
  on_change = function() bone.ui.refresh() end,
})
local next_detail = { summary = "rows", rows = "full", full = "summary" }
local next_motion = { full = "calm", calm = "still", still = "full" }
bone.o.define("prism_motion", "full", {
  desc = "animation: full, calm (only while running) or still (F4)",
  choices = { "full", "calm", "still" },
  on_change = function(v) motion = v; bone.ui.refresh() end,
})

local function map(keys, context)
  for key, action in pairs(keys) do bone.keymap.set(key, action, { context = context }) end
end

map({
  ["f1"] = "/help",
  ["f4"] = function()
    bone.o.prism_motion = next_motion[motion] or "full"
    pcall(bone.settings.set, "tui.prism_motion", bone.o.prism_motion)
    bone.notify("motion: " .. motion)
    bone.ui.refresh()
  end,
  ["enter"] = "submit",
  ["alt+enter"] = "newline",
  ["shift+enter"] = "newline",
  ["ctrl+j"] = "newline",
  ["tab"] = "complete",
  ["esc"] = "dismiss",
  ["ctrl+c"] = "interrupt",
  ["ctrl+d"] = "quit_if_empty",
  ["ctrl+o"] = "sessions",
  ["ctrl+n"] = "new_session",
  ["ctrl+p"] = "focus_next",
  ["ctrl+t"] = function()
    bone.o.tool_detail = next_detail[bone.o.tool_detail] or "rows"
    pcall(bone.settings.set, "tui.tool_detail", bone.o.tool_detail)
  end,
  ["ctrl+r"] = function() bone.o.apply("show_reasoning!") end,
  ["ctrl+v"] = "paste_clipboard",
  ["alt+v"] = "paste_clipboard",
  ["left"] = "left", ["right"] = "right", ["up"] = "up", ["down"] = "down",
  ["ctrl+left"] = "word_left", ["ctrl+right"] = "word_right",
  ["alt+left"] = "word_left", ["alt+right"] = "word_right",
  ["home"] = "line_start", ["end"] = "line_end",
  ["ctrl+a"] = "line_start", ["ctrl+e"] = "line_end",
  ["backspace"] = "backspace", ["ctrl+h"] = "backspace", ["delete"] = "delete",
  ["ctrl+w"] = "delete_word", ["alt+backspace"] = "delete_word",
  ["ctrl+u"] = "delete_to_start", ["ctrl+k"] = "delete_to_end",
  ["pageup"] = "page_up", ["pagedown"] = "page_down",
  ["wheelup"] = "scroll_up", ["wheeldown"] = "scroll_down",
  ["shift+up"] = "scroll_up", ["shift+down"] = "scroll_down",
  ["ctrl+home"] = "scroll_top", ["ctrl+end"] = "scroll_bottom",
}, "main")
map({ ["ctrl+c"] = "interrupt" }, "popup")
map({
  ["esc"] = "dismiss", ["ctrl+c"] = "interrupt", ["tab"] = "focus_next",
  ["shift+tab"] = "focus_prev", ["up"] = "up", ["down"] = "down",
  ["pageup"] = "page_up", ["pagedown"] = "page_down",
  ["home"] = "scroll_top", ["end"] = "scroll_bottom",
  ["wheelup"] = "scroll_up", ["wheeldown"] = "scroll_down",
}, "panel")

require("bone.commands")
require("bone.menu")

-- ---- helpers ---------------------------------------------------------------

local function append(out, rows)
  for _, row in ipairs(rows or {}) do out[#out + 1] = row end
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_lines(text)
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

local function width_of(spans)
  local w = 0
  for _, s in ipairs(spans) do if s[1] then w = w + bone.text.width(s[1]) end end
  return w
end

local function tokens(n)
  n = tonumber(n) or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

local function secs(ms)
  if not ms then return "" end
  local s = ms / 1000
  if s < 60 then return string.format("%.1fs", s) end
  return string.format("%dm%02ds", math.floor(s / 60), math.floor(s % 60))
end

local function args_of(item)
  if type(item.arguments) == "table" and next(item.arguments) ~= nil then return item.arguments end
  if type(item.raw_arguments) == "string" and item.raw_arguments ~= "" then
    local ok, v = pcall(bone.json.decode, item.raw_arguments)
    if ok and type(v) == "table" then return v end
  end
  return {}
end

local function short(p)
  if type(p) ~= "string" then return "" end
  local s = bone.api.session()
  local cwd = s and s.cwd
  if cwd and p:sub(1, #cwd + 1) == cwd .. "/" then return p:sub(#cwd + 2) end
  local home = os.getenv("HOME") or ""
  if home ~= "" and p:sub(1, #home) == home then return "~" .. p:sub(#home + 1) end
  return p
end

local function model_name()
  local p = bone.settings.get("provider")
  return p and bone.settings.get("providers." .. p .. ".model") or nil
end

-- ---- the conversation ------------------------------------------------------

local views = bone.ui.views

-- A horizontal gradient edge: corners, a title, and a run of `ch`.
local function edge(width, left, right, from, title, flow)
  local line = grad(left, from + flow, 1)
  local used = 1
  if title then
    append(line, grad("─ ", from + flow + 1, 1))
    line[#line + 1] = { title, "PWhite" }
    line[#line + 1] = { " ", "Normal" }
    used = used + 3 + bone.text.width(title)
  end
  local run = math.max(width - used - 1, 0)
  for i = 0, run - 1 do
    line[#line + 1] = { "─", "Px" .. wrap_i(from + flow + (used + i) * 0.5) }
  end
  append(line, grad(right, from + flow + (used + run) * 0.5, 1))
  return line
end

-- Yours: a raised card framed in a gradient that starts where the wheel
-- left off for this message.
views.user = function(item, ctx)
  local out = { {} }
  if ctx.prev then out[#out + 1] = {} end
  local from = (item.index * 5) % N
  local inner = ctx.width - 4
  out[#out + 1] = edge(ctx.width, "╭", "╮", from, "you", 0)
  local rows = {}
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(rows, bone.text.wrap({ { line, "PCard" } }, inner, { pad = "PCard" }))
  end
  for r, row in ipairs(rows) do
    local line = { { "│", "Px" .. wrap_i(from + r) }, { " ", "PCard" } }
    append(line, row)
    line[#line + 1] = { string.rep(" ", math.max(inner - width_of(row), 0)) .. " ", "PCard" }
    line[#line + 1] = { "│", "Px" .. wrap_i(from + ctx.width * 0.5 + r) }
    out[#out + 1] = line
  end
  out[#out + 1] = edge(ctx.width, "╰", "╯", from + #rows, nil, 0)
  return out
end

-- Headings in a reply get painted along the wheel.
local function paint_headings(lines, from)
  for _, line in ipairs(lines) do
    local out, changed = {}, false
    for _, span in ipairs(line) do
      if span[2] == "MdHeading" then
        append(out, grad(span[1], from, 1))
        changed = true
      else
        out[#out + 1] = span
      end
    end
    if changed then
      for i = #line, 1, -1 do line[i] = nil end
      for i, s in ipairs(out) do line[i] = s end
    end
  end
  return lines
end

-- Replies hang off a vertical gradient spine; it flows while streaming and
-- ends in a breathing cursor.
views.assistant = function(item, ctx)
  local text = trim(item.text)
  if text == "" and not item.streaming then return nil end
  local out = { {} }
  local flow = item.streaming and phase(70) or 0
  if item.streaming then bone.chat.refresh_in(motion == "still" and 400 or 90) end
  local from = (item.index * 3) % N
  local body = text == "" and { { { "…", "PFaint" } } } or paint_headings(bone.ui.markdown(text, ctx.width - 3, ""), from)
  for r, line in ipairs(body) do
    local row = { { "▎", "Px" .. wrap_i(from + r - flow) }, { "  ", "Normal" } }
    append(row, line)
    out[#out + 1] = row
  end
  if item.streaming then
    local last = out[#out]
    local beat = math.floor(phase(60)) % N + 1
    last[#last + 1] = { " █", "Px" .. beat }
  elseif item.usage and (item.usage.output or 0) > 0 then
    local tag = " " .. tokens(item.usage.output) .. " tok "
    out[#out + 1] = { { "▎", "Pf" .. wrap_i(from + #body + 1) }, { fill = " ", hl = "Normal" }, { tag, "PFaint" } }
  end
  return out
end

views.reasoning = function(item, ctx)
  if not bone.o.show_reasoning or trim(item.text) == "" then return nil end
  local out = { {} }
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "Reasoning" } }, ctx.width, {
      first = { { "  ✧ ", "Pf" .. wrap_i(8) } }, rest = { { "    ", "Normal" } },
    }))
  end
  return out
end

views.notice = function(item, ctx)
  local out = { {} }
  local chip = item.error and { " ! ", "Pc" .. wrap_i(43) } or { " i ", "Pc" .. wrap_i(37) }
  for i, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, item.error and "ErrorMsg" or "Notice" } }, ctx.width, {
      first = { i == 1 and chip or { "   ", "Normal" }, { " ", "Normal" } }, rest = { { "    ", "Normal" } },
    }))
  end
  return out
end

views.queued = function(item, ctx)
  local out = { {} }
  local first = { { " queued ", "Pc" .. wrap_i(12) }, { " ", "Normal" } }
  for i, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "PSoft" } }, ctx.width, {
      first = i == 1 and first or { { "         ", "Normal" } }, rest = { { "         ", "Normal" } },
    }))
  end
  return out
end

-- ---- tools as chips --------------------------------------------------------

local LABEL = { read_file = "read", write_file = "write", edit_file = "edit", shell = "shell", subagent = "agent" }

local function exit_code(out)
  return tonumber((out or ""):gsub("%s+$", ""):match("%[exit code: (%-?%d+)%]$"))
end

local function failed(t)
  if not t.done then return false end
  if t.is_error then return true end
  if t.name ~= "shell" then return false end
  local code = exit_code(t.output)
  return code ~= nil and code ~= 0
end

local function target(t)
  local a = args_of(t)
  if t.name == "shell" then return (a.command or ""):gsub("%s+", " ") end
  if t.name == "subagent" then return (a.task or a.name or ""):gsub("%s+", " ") end
  for _, k in ipairs({ "path", "query", "url", "pattern", "name" }) do
    if type(a[k]) == "string" then return short(a[k]) end
  end
  return ""
end

local function elapsed(t)
  return t.duration_ms or (t.started_at and (bone.now() - t.started_at)) or 0
end

local function first_of_stretch(item)
  local i = item.index - 1
  local before = bone.chat.item(i)
  while before and before.kind == "reasoning" do
    i = i - 1
    before = bone.chat.item(i)
  end
  return not (before and before.kind == "tool")
end

-- A light running along a bar while the call is alive.
local function shimmer(n, hue)
  local out = {}
  local pos = phase(40) % (n + 8)
  for i = 0, n - 1 do
    local d = math.abs(i - pos)
    out[#out + 1] = { d < 1.5 and "━" or "─", d < 3 and ("Px" .. wrap_i(hue + i)) or ("Pf" .. wrap_i(hue + i)) }
  end
  return out
end

local function chip_row(t, ctx)
  local hue = hue_of(t.name)
  local label = " " .. (LABEL[t.name] or t.name) .. " "
  local row = { { "  ", "Normal" }, { label, "Pc" .. wrap_i(hue) }, { " ", "Normal" } }
  local tgt = target(t)
  local tail
  if not t.done then
    bone.chat.refresh_in(motion == "still" and 500 or 80)
    tail = shimmer(10, hue)
    tail[#tail + 1] = { " " .. secs(elapsed(t)) .. " ", "PSoft" }
  elseif failed(t) then
    tail = { { " ✕ " .. secs(elapsed(t)) .. " ", "ToolError" } }
  else
    tail = { { " ✓ ", "Px" .. wrap_i(hue) }, { secs(elapsed(t)) .. " ", "PFaint" } }
  end
  local room = math.max(ctx.width - width_of(row) - width_of(tail) - 2, 6)
  if t.name == "shell" and bone.text.width(tgt) <= room then
    append(row, bone.text.shell(tgt))
  else
    row[#row + 1] = { bone.text.truncate(tgt, room), "PSoft" }
  end
  row[#row + 1] = { fill = " ", hl = "Normal" }
  append(row, tail)
  return row
end

local function output_rows(t, ctx, max)
  local out = {}
  local hue = hue_of(t.name)
  if t.name == "edit_file" and t.done and not t.is_error then
    local a = args_of(t)
    local edits = type(a.edits) == "table" and a.edits or (type(a.old_string) == "string" and { a } or {})
    for _, e in ipairs(edits) do
      for _, l in ipairs(split_lines(e.old_string or "")) do
        out[#out + 1] = { { "    ┊ ", "Pf" .. wrap_i(hue) }, { bone.text.truncate("- " .. l, ctx.width - 7), "DiffDelete" }, { fill = " ", hl = "DiffDelete" } }
      end
      for _, l in ipairs(split_lines(e.new_string or "")) do
        out[#out + 1] = { { "    ┊ ", "Pf" .. wrap_i(hue) }, { bone.text.truncate("+ " .. l, ctx.width - 7), "DiffAdd" }, { fill = " ", hl = "DiffAdd" } }
      end
    end
  else
    local text = (t.output or t.live or ""):gsub("\n?%[exit code: %-?%d+%]%s*$", "")
    for _, l in ipairs(split_lines(trim(text))) do
      out[#out + 1] = { { "    ┊ ", "Pf" .. wrap_i(hue) }, { bone.text.truncate(l, ctx.width - 7), failed(t) and "ToolError" or "ToolOutput" } }
    end
  end
  if #out > max then
    local more = #out - max
    for i = #out, max + 1, -1 do out[i] = nil end
    out[#out + 1] = { { "    ╰ ", "Pf" .. wrap_i(hue) }, { "+" .. more .. " more · ctrl+t", "PFaint" } }
  end
  return out
end

views.tool = function(item, ctx)
  local detail = bone.o.tool_detail
  local first = first_of_stretch(item)
  local out = first and { {} } or {}
  if detail == "summary" and not failed(item) then
    if not first then return nil end
    local row = { { "  ", "Normal" } }
    local running, ms, counts, order = false, 0, {}, {}
    for _, t in ipairs(bone.chat.items({ around = item.index, from = item.index, kind = { "tool", "reasoning" }, full = true })) do
      if t.kind == "tool" then
        running = running or not t.done
        ms = ms + elapsed(t)
        if not counts[t.name] then counts[t.name] = 0; order[#order + 1] = t.name end
        counts[t.name] = counts[t.name] + 1
      end
    end
    for _, name in ipairs(order) do
      local label = " " .. (LABEL[name] or name) .. (counts[name] > 1 and (" ×" .. counts[name]) or "") .. " "
      row[#row + 1] = { label, "Pc" .. wrap_i(hue_of(name)) }
      row[#row + 1] = { " ", "Normal" }
    end
    row[#row + 1] = { fill = " ", hl = "Normal" }
    if running then
      bone.chat.refresh_in(motion == "still" and 500 or 80)
      append(row, shimmer(10, 20))
      row[#row + 1] = { " ", "Normal" }
    end
    row[#row + 1] = { secs(ms) .. " ", "PFaint" }
    out[#out + 1] = row
    return out
  end
  out[#out + 1] = chip_row(item, ctx)
  local max = detail == "full" and 30 or ((failed(item) or item.name == "edit_file") and 6 or 0)
  if not item.done and detail ~= "summary" then max = math.max(max, 3) end
  if max > 0 then append(out, output_rows(item, ctx, max)) end
  return out
end

-- ---- header, thinking light, prompt, status --------------------------------

local WAVE = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "▆", "▅", "▄", "▃", "▂" }

bone.ui.regions.crown = {
  size = 1,
  render = function(ctx)
    local s = bone.chat.session() or {}
    animate(120, s.running)
    local t = phase(s.running and 50 or 140)
    local line = { { " ", "Normal" } }
    append(line, grad("◆ prism", -t, 1.5))
    local title = (not s.new and s.title and trim(s.title) ~= "") and trim(s.title) or "new conversation"
    line[#line + 1] = { "   " .. bone.text.truncate(title, math.max(ctx.width - 44, 8)), "PSoft" }
    line[#line + 1] = { fill = " ", hl = "Normal" }
    -- A wave that rolls faster while a turn runs.
    local n = math.min(24, math.max(ctx.width - 60, 0))
    for i = 0, n - 1 do
      local k = math.floor(i * 0.7 + t * (s.running and 0.6 or 0.25)) % #WAVE + 1
      line[#line + 1] = { WAVE[k], (s.running and "Px" or "Pf") .. wrap_i(i * 2 - t) }
    end
    line[#line + 1] = { " ", "Normal" }
    return { line }
  end,
}

-- While a turn runs and nothing is streaming: "thinking" with a light
-- sweeping across it.
bone.ui.regions.thinking = {
  size = "auto",
  max = 1,
  render = function(ctx)
    local s = bone.chat.session()
    if not (s and s.running) then return nil end
    local streaming = bone.chat.count({ running = true }) > 0
    local last = bone.chat.items({ last = 1 })[1]
    if streaming and last and last.kind == "assistant" then return nil end
    bone.ui.refresh_in(motion == "still" and 400 or 60)
    local word = "thinking"
    local pos = (phase(70) % (#word + 10)) - 3
    local line = { { "  ", "Normal" }, { (ctx.spinner or "◜") .. " ", "Px" .. wrap_i(phase(40)) } }
    for i = 1, #word do
      local d = math.abs(i - pos)
      line[#line + 1] = { word:sub(i, i), d < 1.5 and "PWhite" or (d < 3.5 and ("Px" .. wrap_i(i * 2 + phase(60))) or "PFaint") }
    end
    line[#line + 1] = { "  " .. secs(s.turn and s.turn.elapsed_ms or 0), "PFaint" }
    return { line }
  end,
}

local function prompt_edge(width, top, running)
  local flow = running and phase(35) or phase(400)
  local line = {}
  local l, r = top and "╭" or "╰", top and "╮" or "╯"
  line[1] = { l, "Px" .. wrap_i(-flow) }
  for i = 1, width - 2 do
    line[#line + 1] = { "─", (running and "Px" or "Pf") .. wrap_i(i * 0.6 - flow) }
  end
  line[#line + 1] = { r, "Px" .. wrap_i((width - 1) * 0.6 - flow) }
  return line
end

bone.ui.prompt = {
  prefix = function(ctx)
    return { { " ❯ ", ctx.running and ("Px" .. wrap_i(phase(50))) or "Accent" } }
  end,
  placeholder = { { "Say something bright…", "Placeholder" } },
  border = { style = "rounded", hl = "PromptBorder", sides = "lr" },
  padding = { rows = 0, cols = 1 },
  min = 1,
  max = 8,
  top = function(ctx) return prompt_edge(ctx.width, true, ctx.running) end,
  bottom = function(ctx) return prompt_edge(ctx.width, false, ctx.running) end,
}

bone.ui.prompt_highlight = function(ctx)
  local s, e = ctx.text:find("^/%S+")
  return { highlights = s and { { row = 0, from = s - 1, to = e, hl = "Px" .. wrap_i(6) } } or {} }
end

-- Pills on a band.
bone.ui.statusline = function(ctx)
  local s = ctx.session or {}
  local last = bone.chat.items({ kind = "assistant", last = 1 })[1]
  local ctx_tokens = last and last.usage and last.usage.input or 0
  local turns = (bone.chat.session() or {}).turns or 0
  local line = { { " ", "PBand" } }
  local function pill(text, hue)
    line[#line + 1] = { " " .. text .. " ", "Pc" .. wrap_i(hue) }
    line[#line + 1] = { " ", "PBand" }
  end
  pill(s.running and ((ctx.spinner or "◜") .. " live") or "● ready", s.running and wrap_i(phase(60)) or 28)
  pill(model_name() or "no model", 6)
  if ctx_tokens > 0 then pill(tokens(ctx_tokens) .. " ctx", 18) end
  if turns > 0 then pill(turns .. (turns == 1 and " turn" or " turns"), 36) end
  line[#line + 1] = { fill = " ", hl = "PBand" }
  line[#line + 1] = { (ctx.popup and (ctx.popup .. "  ") or "") .. "ctrl+t detail · F4 motion · F1 help ", "PBandDim" }
  return line
end

-- The empty screen: a big flowing wordmark.
local LOGO = {
  "█▀█ █▀█ █ █▀▀ █▀▄▀█",
  "█▀▀ █▀▄ █ ▄▄█ █ ▀ █",
}
bone.ui.regions.chat_empty = {
  render = function(ctx)
    local s = bone.chat.session()
    if bone.api.session() or (s and (s.items or 0) > 0) then return {} end
    animate(90, false)
    local t = phase(90)
    local L = {}
    for r, row in ipairs(LOGO) do
      local line, i = {}, 0
      for ch in row:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        line[#line + 1] = { ch, ch == " " and "Normal" or ("Px" .. wrap_i(i * 0.9 + r * 2 - t)) }
        i = i + 1
      end
      L[#L + 1] = line
    end
    L[#L + 1] = {}
    L[#L + 1] = { { "every reply, in full colour", "PSoft" } }
    L[#L + 1] = {}
    L[#L + 1] = { { " ctrl+o ", "Pc" .. wrap_i(6) }, { " sessions   ", "PFaint" }, { " ctrl+t ", "Pc" .. wrap_i(20) },
                  { " detail   ", "PFaint" }, { " F4 ", "Pc" .. wrap_i(36) }, { " motion", "PFaint" } }
    return L
  end,
}

bone.ui.suggestions = function(ctx)
  local lines = {}
  for i, it in ipairs(ctx.items) do
    local sel = i == ctx.selected
    local line = { { "  ", "Normal" } }
    if sel then
      append(line, grad("/" .. it.name, phase(80), 1))
    else
      line[#line + 1] = { "/" .. it.name, "PSoft" }
    end
    line[#line + 1] = { "  " .. (it.desc or ""), sel and "Normal" or "PFaint" }
    lines[i] = line
  end
  return lines
end

bone.ui.title = function()
  local s = bone.chat.session()
  local t = s and not s.new and s.title and trim(s.title) or ""
  return "◆ " .. (t ~= "" and t or "prism")
end

bone.ui.layout = { "crown", "chat", "thinking", "above_prompt", "prompt", "statusline" }

-- ---- stock behaviour -------------------------------------------------------

function bone.ui.help(topic)
  local help = require("bone.help")
  return topic and topic:match("%S") and help.topic(topic) or help.open()
end
function bone.ui.sessions()
  return require("bone.ui.sessions").open()
end
function bone.ui.health()
  local mark = { ok = { " ✓ ", "Pc" .. wrap_i(28) }, warn = { " ! ", "Pc" .. wrap_i(37) }, error = { " ✕ ", "Pc" .. wrap_i(43) } }
  local function section(out, title, items)
    out[#out + 1] = grad(title, 4, 1)
    for _, it in ipairs(items or {}) do
      out[#out + 1] = { mark[it.status] or mark.warn, { " " .. it.name .. "  ", "Normal" }, { tostring(it.message), "Dim" } }
    end
    out[#out + 1] = {}
  end
  local tui = bone.api.health()
  for _, it in ipairs(bone._run_health()) do tui[#tui + 1] = it end
  local lines = {}
  section(lines, "Prism TUI", tui)
  local pager = bone.ui.pager(lines, { title = "Health" })
  bone.request("health/check", {}, function(core, err)
    local all = {}
    section(all, "Prism TUI", tui)
    section(all, "Core", err and { { name = "core", status = "error", message = err } } or core)
    pager:set(all)
  end)
end

bone.on("ready", function()
  local saved = bone.settings.get("tui.prism_motion")
  if next_motion[saved] then bone.o.prism_motion = saved end
  local detail = bone.settings.get("tui.tool_detail")
  if next_detail[detail] then bone.o.tool_detail = detail end
  if bone.settings.get("setup.skipped") then return end
  bone.model.list(function(list)
    if list and #list > 0 then return end
    bone.request("health/check", {}, function(items)
      for _, it in ipairs(items or {}) do
        if it.name == "provider" and it.status == "error" then
          require("bone.setup").open({ first_run = true })
          return
        end
      end
    end)
  end)
end)
