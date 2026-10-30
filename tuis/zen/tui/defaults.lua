-- Zen: a minimal, modern TUI library.
--
--   * One centred reading column (at most 92 cells) with air on both sides.
--   * No labels, boxes or badges: your messages sit right-aligned on a soft
--     pill, replies are plain typography on the canvas.
--   * Tool calls collapse to one quiet line per stretch; click it (or ctrl+t)
--     to unfold the steps.
--   * One accent colour, used only for what is alive right now.
--
-- Self-contained: it does not load bone.ui.setup().

bone.ui.clear()
bone.colorscheme("black")

local MEASURE = 92

local c = {
  bg = "#0c0c0e", raised = "#17171a", line = "#232327",
  text = "#e4e4e7", soft = "#a1a1aa", faint = "#52525b", ghost = "#3f3f46",
  accent = "#8ab4ff", red = "#f87171", green = "#86efac",
}

local function hl(name, fg, bg, attrs)
  local spec = { fg = fg, bg = bg or c.bg }
  for k, v in pairs(attrs or {}) do spec[k] = v end
  bone.hl.set(name, spec)
end

hl("Normal", c.text)
hl("Dim", c.faint)
hl("Accent", c.accent)
hl("UserPrompt", c.accent)
hl("UserMessage", c.text, c.raised)
hl("Reasoning", c.faint, nil, { italic = true })
hl("ToolName", c.soft)
hl("ToolArgs", c.faint)
hl("ToolPath", c.soft)
hl("ToolSummary", c.faint)
hl("ToolOutput", c.faint)
hl("ToolGutter", c.ghost)
hl("ToolRunning", c.accent)
hl("ToolError", c.red)
hl("Notice", c.soft)
hl("ErrorMsg", c.red)
hl("WarningMsg", c.soft)
hl("WinSeparator", c.bg)
hl("StatusLine", c.soft)
hl("StatusLineDim", c.faint)
hl("Selection", c.text, "#26324a")
hl("Placeholder", c.ghost)
hl("InputBackground", c.text)
hl("InputText", c.text)
hl("PopupBorder", c.line)
hl("PopupTitle", c.soft, nil, { bold = true })
hl("PanelTitle", c.faint)
hl("PanelTitleFocus", c.accent)
hl("MdHeading", c.text, nil, { bold = true })
hl("MdBold", c.text, nil, { bold = true })
hl("MdItalic", c.soft, nil, { italic = true })
hl("MdCode", c.accent)
hl("MdCodeBlock", c.soft)
hl("MdQuote", c.soft, nil, { italic = true })
hl("MdBullet", c.faint)
hl("MdLink", c.accent, nil, { underline = true })
hl("MdTable", c.soft)
hl("MdTableHeader", c.text, nil, { bold = true })
hl("DiffAdd", c.green)
hl("Success", c.green)
hl("DiffDelete", c.red)
hl("ShellProgram", c.soft)
hl("ShellPath", c.soft)
hl("ShellFlag", c.faint)
hl("ShellString", c.soft)
hl("ShellVariable", c.soft)
hl("ShellComment", c.ghost)
hl("ShellOperator", c.faint)
hl("ZRule", c.line)
hl("ZPill", c.text, c.raised)
hl("ZPillEdge", c.raised)
hl("ZHint", c.ghost)
hl("ZLive", c.accent, nil, { bold = true })
hl("ZBarDim", c.line)
hl("ZHuge", c.text, nil, { bold = true })

bone.ui.spinner = { frames = { "·", "•", "●", "•" }, interval = 160 }

-- ---- options and keys ------------------------------------------------------

bone.o.define("queue_mode", "next", {
  desc = "what enter does during a turn: steer or next",
  choices = { "steer", "next" },
})
bone.o.define("tool_detail", "summary", {
  desc = "steps: summary (click to unfold) or full",
  choices = { "summary", "rows", "full" },
  on_change = function() bone.ui.refresh() end,
})

local function map(keys, context)
  for key, action in pairs(keys) do bone.keymap.set(key, action, { context = context }) end
end

map({
  ["f1"] = "/help",
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
    bone.o.tool_detail = bone.o.tool_detail == "summary" and "full" or "summary"
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
  return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60))
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

-- Yours: right-aligned on a pill, wrapped at two thirds of the column.
views.user = function(item, ctx)
  local out = { {} }
  if ctx.prev then out[#out + 1] = {} end
  local room = math.max(math.floor(ctx.width * 0.68), 16)
  local rows = {}
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(rows, bone.text.wrap({ { line, "ZPill" } }, room - 4))
  end
  local widest = 0
  for _, r in ipairs(rows) do
    local w = 0
    for _, s in ipairs(r) do w = w + bone.text.width(s[1]) end
    r.w = w
    widest = math.max(widest, w)
  end
  for _, r in ipairs(rows) do
    local line = { { fill = " ", hl = "Normal" }, { "▐", "ZPillEdge" }, { " ", "ZPill" } }
    append(line, r)
    line[#line + 1] = { string.rep(" ", widest - r.w) .. " ", "ZPill" }
    line[#line + 1] = { "▌", "ZPillEdge" }
    out[#out + 1] = line
  end
  if #(item.images or {}) > 0 then
    out[#out + 1] = { { fill = " ", hl = "Normal" }, { #item.images .. " image" .. (#item.images > 1 and "s" or "") .. "  ", "ZHint" } }
  end
  return out
end

views.assistant = function(item, ctx)
  local text = trim(item.text)
  if text == "" and not item.streaming then return nil end
  local out = { {} }
  if text == "" then
    out[#out + 1] = { { ctx.spinner or "•", "ZLive" } }
    if not bone.chat.item(item.index + 1) then out[#out + 1] = {} end
    return out
  end
  append(out, bone.ui.markdown(text, ctx.width, ""))
  if item.streaming then
    local last = out[#out]
    last[#last + 1] = { " ●", "ZLive" }
  end
  if not bone.chat.item(item.index + 1) then out[#out + 1] = {} end
  return out
end

views.reasoning = function(item, ctx)
  if not bone.o.show_reasoning or trim(item.text) == "" then return nil end
  local out = { {} }
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "Reasoning" } }, ctx.width))
  end
  return out
end

views.notice = function(item, ctx)
  local out = { {} }
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, item.error and "ErrorMsg" or "Notice" } }, ctx.width))
  end
  return out
end

views.queued = function(item, ctx)
  local out = { {} }
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "ZHint" } }, ctx.width - 2, { first = { { fill = " ", hl = "Normal" } } }))
  end
  out[#out + 1] = { { fill = " ", hl = "Normal" }, { item.mode == "steer" and "queued · steers" or "queued · next", "ZHint" } }
  return out
end

-- ---- steps -----------------------------------------------------------------

local NOUN = { read_file = "read", write_file = "write", edit_file = "edit", shell = "run", subagent = "agent" }

local function failed(t)
  if not t.done then return false end
  if t.is_error then return true end
  if t.name == "shell" then
    local code = tonumber((t.output or ""):gsub("%s+$", ""):match("%[exit code: (%-?%d+)%]$"))
    return code ~= nil and code ~= 0
  end
  return false
end

local function step_text(t)
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

local open = {} -- item key of a stretch's first step -> unfolded

local function first_of_stretch(item)
  local i = item.index - 1
  local before = bone.chat.item(i)
  while before and before.kind == "reasoning" do
    i = i - 1
    before = bone.chat.item(i)
  end
  return not (before and before.kind == "tool")
end

-- The first step of a stretch draws the whole stretch: one quiet line, and
-- the steps under it when unfolded. Failures always unfold.
views.tool = function(item, ctx)
  if not first_of_stretch(item) then return nil end
  local steps = {}
  for _, t in ipairs(bone.chat.items({ around = item.index, from = item.index, kind = { "tool", "reasoning" }, full = true })) do
    if t.kind == "tool" then steps[#steps + 1] = t end
  end
  if #steps == 0 then steps = { item } end
  local running, ms, bad, kinds, seen = false, 0, 0, {}, {}
  for _, t in ipairs(steps) do
    running = running or not t.done
    ms = ms + elapsed(t)
    if failed(t) then bad = bad + 1 end
    local n = NOUN[t.name] or t.name
    if not seen[n] then seen[n] = true; kinds[#kinds + 1] = n end
  end
  if running then bone.chat.refresh_in(200) end
  local unfolded = open[item.key] or bone.o.tool_detail ~= "summary" or bad > 0

  local out = { {} }
  local head = {}
  if running then
    head[#head + 1] = { (ctx.spinner or "•") .. " ", "ZLive" }
    head[#head + 1] = { step_text(steps[#steps]) ~= "" and bone.text.truncate(step_text(steps[#steps]), ctx.width - 24) or "working", "ToolName" }
  else
    head[#head + 1] = { bad > 0 and "✕ " or "○ ", bad > 0 and "ToolError" or "ZHint" }
    head[#head + 1] = { #steps .. (#steps == 1 and " step" or " steps"), "ToolSummary" }
    head[#head + 1] = { "  " .. table.concat(kinds, ", "), "ZHint" }
  end
  head[#head + 1] = { fill = " ", hl = "Normal" }
  head[#head + 1] = { secs(ms) .. (running and "" or (unfolded and "  ⌃" or "  ⌄")), "ZHint" }
  out[#out + 1] = head

  if unfolded then
    for _, t in ipairs(steps) do
      local bad_step = failed(t)
      local row = {
        { "  ", "Normal" },
        { (not t.done and (ctx.spinner or "•")) or (bad_step and "✕") or "·", (not t.done and "ZLive") or (bad_step and "ToolError") or "ZHint" },
        { " " .. string.format("%-6s", NOUN[t.name] or t.name), "ToolSummary" },
        { bone.text.truncate(step_text(t), math.max(ctx.width - 20, 8)), "ToolArgs" },
        { fill = " ", hl = "Normal" },
        { secs(elapsed(t)), "ZHint" },
      }
      out[#out + 1] = row
      if bad_step or bone.o.tool_detail == "full" then
        local body = (t.output or t.live or ""):gsub("\n?%[exit code: %-?%d+%]%s*$", "")
        local lines = split_lines(trim(body))
        local max = bone.o.tool_detail == "full" and 12 or 4
        for i = 1, math.min(#lines, max) do
          out[#out + 1] = { { "         ", "Normal" }, { bone.text.truncate(lines[i], ctx.width - 10), bad_step and "ToolError" or "ToolOutput" } }
        end
        if #lines > max then out[#out + 1] = { { "         ", "Normal" }, { "+" .. (#lines - max) .. " lines", "ZHint" } } end
      end
    end
  end
  return out
end

-- Click a stretch's line to fold or unfold it.
bone.on("mouse", function(ev)
  if ev.action ~= "down" or ev.button ~= "left" or not ev.index then return end
  local it = bone.chat.item(ev.index)
  if not it or it.kind ~= "tool" or (ev.line or 1) > 2 then return end
  open[it.key] = not open[it.key]
  bone.chat.redraw(ev.index)
  return true
end)

-- ---- frame -----------------------------------------------------------------

bone.ui.regions.zl = { size = 1, render = function() return {} end }
bone.ui.regions.zr = { size = 1, render = function() return {} end }
bone.ui.regions.ztop = { size = 1, render = function() return {} end }

-- A thin line under the prompt: a sliding bar while a turn runs, otherwise
-- the model and how full the context is.
bone.ui.regions.zstatus = {
  size = 1,
  render = function(ctx)
    local s = bone.chat.session() or {}
    if s.running then
      bone.ui.refresh_in(60)
      local w = math.min(ctx.width, 24)
      local pos = math.floor(bone.now() / 45) % (w + 6) - 6
      local bar = {}
      for i = 0, w - 1 do
        local lit = i >= pos and i < pos + 6
        bar[#bar + 1] = { "━", lit and "ZLive" or "ZBarDim" }
      end
      local elapsed_ms = s.turn and s.turn.elapsed_ms or 0
      bar[#bar + 1] = { "  " .. secs(elapsed_ms), "ZHint" }
      bar[#bar + 1] = { fill = " ", hl = "Normal" }
      bar[#bar + 1] = { "ctrl+c to stop", "ZHint" }
      return { bar }
    end
    local ctx_tokens = 0
    local last = bone.chat.items({ kind = "assistant", last = 1 })[1]
    if last and last.usage then ctx_tokens = last.usage.input or 0 end
    local left = model_name() or "no model"
    if ctx_tokens > 0 then left = left .. "  ·  " .. tokens(ctx_tokens) .. " context" end
    return { { { left, "ZHint" }, { fill = " ", hl = "Normal" }, { "/ commands  ·  F1 help", "ZHint" } } }
  end,
}

bone.ui.regions.chat_empty = {
  render = function(ctx)
    local s = bone.chat.session()
    if bone.api.session() or (s and (s.items or 0) > 0) then return {} end
    local L = {}
    local hour = tonumber(os.date("%H")) or 12
    local greet = hour < 5 and "Late one." or hour < 12 and "Good morning." or hour < 18 and "Good afternoon." or "Good evening."
    L[#L + 1] = { { greet, "ZHuge" } }
    L[#L + 1] = { { " ", "Normal" } }
    L[#L + 1] = { { "What are we making?", "Dim" } }
    return L
  end,
}

bone.ui.prompt = {
  prefix = function(ctx)
    return { { ctx.running and "· " or "› ", ctx.running and "ZHint" or "ZLive" } }
  end,
  placeholder = { { "Ask anything", "Placeholder" } },
  border = { style = "single", hl = "ZRule", sides = "b" },
  padding = { rows = 0, cols = 0 },
  min = 1,
  max = 10,
}

bone.ui.prompt_highlight = function(ctx)
  local s, e = ctx.text:find("^/%S+")
  return { highlights = s and { { row = 0, from = s - 1, to = e, hl = "ZLive" } } or {} }
end

bone.ui.suggestions = function(ctx)
  local lines = {}
  for i, it in ipairs(ctx.items) do
    local sel = i == ctx.selected
    lines[i] = {
      { (sel and "› " or "  ") .. "/" .. it.name, sel and "ZLive" or "ToolSummary" },
      { "   " .. (it.desc or ""), sel and "Normal" or "ZHint" },
    }
  end
  return lines
end

bone.ui.title = function()
  local s = bone.chat.session()
  local t = s and not s.new and s.title and trim(s.title) or ""
  return t ~= "" and t or "zen"
end

-- Centre a column of at most MEASURE cells between two filling gutters.
local function apply_layout(width)
  local measure = width and math.max(math.min(width - 4, MEASURE), 20) or MEASURE
  bone.ui.layout = {
    "ztop",
    { cols = {
      { "zl", size = "fill" },
      { rows = { "chat", "above_prompt", "prompt", "zstatus" }, size = measure },
      { "zr", size = "fill" },
    } },
  }
end
apply_layout()
bone.on("resize", function(ev) apply_layout(ev.width) end)

-- ---- stock behaviour -------------------------------------------------------

function bone.ui.help(topic)
  local help = require("bone.help")
  return topic and topic:match("%S") and help.topic(topic) or help.open()
end
function bone.ui.sessions()
  return require("bone.ui.sessions").open()
end
function bone.ui.health()
  local mark = { ok = { "· ", "ZHint" }, warn = { "! ", "Notice" }, error = { "✕ ", "ErrorMsg" } }
  local function section(out, title, items)
    out[#out + 1] = { { title, "MdHeading" } }
    for _, it in ipairs(items or {}) do
      out[#out + 1] = { mark[it.status] or mark.warn, { it.name .. "  ", "Normal" }, { tostring(it.message), "Dim" } }
    end
    out[#out + 1] = {}
  end
  local tui = bone.api.health()
  for _, it in ipairs(bone._run_health()) do tui[#tui + 1] = it end
  local lines = {}
  section(lines, "Interface", tui)
  local pager = bone.ui.pager(lines, { title = "Health" })
  bone.request("health/check", {}, function(core, err)
    local all = {}
    section(all, "Interface", tui)
    section(all, "Core", err and { { name = "core", status = "error", message = err } } or core)
    pager:set(all)
  end)
end

bone.on("ready", function()
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
