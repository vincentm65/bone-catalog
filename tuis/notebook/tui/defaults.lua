-- Notebook: a self-contained TUI library that treats a session as a
-- computational notebook printed on paper.
--
--   * Every exchange is a numbered cell: `In [n]:` / `Out[n]:` hang in a
--     left margin and all text shares one column to the right of it.
--   * Tool calls are an execution log: aligned columns for status, verb,
--     target, a detail figure and a right-aligned duration.
--   * A live inspector column (F3) shows the kernel: model, context gauge,
--     output sparkline, per-cell outcomes, a tool histogram and touched files.
--   * Day paper or night ink (F2), remembered across restarts.
--
-- Like Aurora it does not load bone.ui.setup(); everything drawn is here.

bone.ui.clear()
bone.colorscheme("black")

local unpack = table.unpack or unpack
local M = 10 -- margin width: "Out[123]: " and every body row starts here

-- ---- paper -----------------------------------------------------------------

local palettes = {
  day = {
    paper = "#f3eee2", paper2 = "#e8e1cf", paper3 = "#d9cfb6",
    ink = "#2d2a24", ink2 = "#6b6455", ink3 = "#a39a85", rule = "#cfc5ad",
    blue = "#2c5d9e", red = "#b5452b", green = "#3f7a3a", amber = "#9a6a12",
    violet = "#6b4f9e", add = "#dcebd2", del = "#f2d8cf",
  },
  night = {
    paper = "#191815", paper2 = "#23211d", paper3 = "#36332b",
    ink = "#e8e1cf", ink2 = "#a59d8a", ink3 = "#6d675a", rule = "#38352e",
    blue = "#7fa9e0", red = "#e8866b", green = "#9cc48a", amber = "#e0b45e",
    violet = "#b39ddb", add = "#1f2d1d", del = "#3a221c",
  },
}

local saved_paper = bone.settings.get("tui.notebook_paper")
local paper_name = palettes[saved_paper] and saved_paper or "day"

local function hl(name, fg, bg, attrs)
  local spec = { fg = fg, bg = bg }
  for k, v in pairs(attrs or {}) do spec[k] = v end
  bone.hl.set(name, spec)
end

local function apply_paper()
  local c = palettes[paper_name]
  local P, P2 = c.paper, c.paper2
  -- Base and the groups stock code (help, pickers, plugins) relies on.
  hl("Normal", c.ink, P)
  hl("Dim", c.ink3, P)
  hl("Accent", c.red, P, { bold = true })
  hl("UserPrompt", c.blue, P, { bold = true })
  hl("UserMessage", c.ink, P2)
  hl("AssistantText", c.ink, P)
  hl("Reasoning", c.ink3, P, { italic = true })
  hl("ToolName", c.ink, P, { bold = true })
  hl("ToolArgs", c.ink2, P)
  hl("ToolPath", c.blue, P)
  hl("ToolSummary", c.ink3, P)
  hl("ToolOutput", c.ink2, P)
  hl("ToolGutter", c.rule, P)
  hl("ToolRunning", c.amber, P, { bold = true })
  hl("ToolError", c.red, P)
  hl("Notice", c.amber, P)
  hl("ErrorMsg", c.red, P, { bold = true })
  hl("WarningMsg", c.amber, P)
  hl("WinSeparator", c.rule, P)
  hl("StatusLine", c.ink, P2)
  hl("StatusLineDim", c.ink3, P2)
  hl("Selection", c.ink, c.paper3)
  hl("Placeholder", c.ink3, P, { italic = true })
  hl("InputBackground", c.ink, P)
  hl("InputText", c.ink, P)
  hl("PromptBorder", c.rule, P)
  hl("PopupBorder", c.rule, P)
  hl("PopupTitle", c.red, P, { bold = true })
  hl("PanelTitle", c.ink2, P2)
  hl("PanelTitleFocus", c.red, P2, { bold = true })
  hl("MdHeading", c.ink, P, { bold = true })
  hl("MdBold", c.ink, P, { bold = true })
  hl("MdItalic", c.ink, P, { italic = true })
  hl("MdCode", c.violet, P)
  hl("MdCodeBlock", c.ink, P2)
  hl("MdQuote", c.ink2, P, { italic = true })
  hl("MdBullet", c.red, P)
  hl("MdLink", c.blue, P, { underline = true })
  hl("MdTable", c.ink, P)
  hl("MdTableHeader", c.ink, P, { bold = true })
  hl("DiffAdd", c.green, c.add)
  hl("Success", c.green)
  hl("DiffDelete", c.red, c.del)
  hl("ShellProgram", c.ink, P, { bold = true })
  hl("ShellPath", c.blue, P)
  hl("ShellFlag", c.violet, P)
  hl("ShellString", c.green, P)
  hl("ShellVariable", c.amber, P)
  hl("ShellComment", c.ink3, P, { italic = true })
  hl("ShellOperator", c.ink3, P)

  -- Notebook's own groups.
  hl("InLabel", c.blue, P, { bold = true })
  hl("OutLabel", c.red, P, { bold = true })
  hl("InCell", c.ink, P2)
  hl("InCellEdge", c.blue, P2)
  hl("Margin", c.ink3, P)
  hl("MarginWarm", c.amber, P)
  hl("Rule", c.rule, P)
  hl("Heading", c.ink, P, { bold = true })
  hl("HeadingRule", c.red, P)
  hl("CodeBand", c.ink, P2)
  hl("CodeLang", c.ink3, P2, { italic = true })
  hl("Stripe", c.ink, P2)
  hl("LogOk", c.green, P)
  hl("LogFail", c.red, P, { bold = true })
  hl("LogRun", c.amber, P, { bold = true })
  hl("LogVerb", c.ink, P, { bold = true })
  hl("LogTarget", c.ink2, P)
  hl("LogFigure", c.violet, P)
  hl("LogTime", c.ink3, P)
  hl("LogAdd", c.green, P)
  hl("LogDel", c.red, P)
  hl("Footnote", c.ink3, P, { italic = true })
  hl("Mast", c.ink, P2, { bold = true })
  hl("MastDim", c.ink3, P2)
  hl("MastBusy", c.red, P2, { bold = true })
  hl("MastIdle", c.green, P2)
  hl("InspHead", c.red, P, { bold = true })
  hl("InspText", c.ink, P)
  hl("InspDim", c.ink3, P)
  hl("InspBar", c.blue, P)
  hl("InspBarHot", c.red, P)
  hl("InspEmpty", c.rule, P)
  hl("InspSpark", c.violet, P)
  hl("FileEdit", c.amber, P, { bold = true })
  hl("FileWrite", c.green, P, { bold = true })
  hl("FileRead", c.ink3, P)
  hl("SuggestName", c.blue, P, { bold = true })
  hl("SuggestDesc", c.ink2, P)
  hl("SuggestSel", c.ink, c.paper3, { bold = true })
  hl("SuggestSelDesc", c.ink2, c.paper3)
end
apply_paper()

bone.ui.spinner = { frames = { "◴", "◷", "◶", "◵" }, interval = 150 }

-- ---- options and keys ------------------------------------------------------

bone.o.define("queue_mode", "next", {
  desc = "what enter does during a turn: steer or next",
  choices = { "steer", "next" },
})
bone.o.define("tool_detail", "rows", {
  desc = "execution log: summary, rows or full (ctrl+t)",
  choices = { "summary", "rows", "full" },
  on_change = function() bone.ui.refresh() end,
})
local saved_detail = bone.settings.get("tui.tool_detail")
if saved_detail == "summary" or saved_detail == "rows" or saved_detail == "full" then
  bone.o.tool_detail = saved_detail
end
local next_detail = { summary = "rows", rows = "full", full = "summary" }

local inspector_on = true
local apply_layout -- defined with the regions below

bone.o.define("notebook_paper", paper_name, {
  desc = "notebook colours: day paper or night ink (F2)",
  choices = { "day", "night" },
  on_change = function(v) paper_name = v; apply_paper(); bone.ui.refresh() end,
})
bone.o.define("notebook_inspector", true, {
  desc = "show the inspector column when it fits (F3)",
  on_change = function(v) inspector_on = v; apply_layout() end,
})

local function remember(key, value)
  pcall(bone.settings.set, key, value)
end

local function map(keys, context)
  for key, action in pairs(keys) do
    bone.keymap.set(key, action, { context = context })
  end
end

map({
  ["f1"] = "/help",
  ["f2"] = function()
    bone.o.notebook_paper = paper_name == "day" and "night" or "day"
    remember("tui.notebook_paper", bone.o.notebook_paper)
  end,
  ["f3"] = function()
    bone.o.notebook_inspector = not inspector_on
    remember("tui.notebook_inspector", bone.o.notebook_inspector)
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
    remember("tui.tool_detail", bone.o.tool_detail)
  end,
  ["ctrl+r"] = function()
    bone.o.apply("show_reasoning!")
    remember("tui.show_reasoning", bone.o.show_reasoning)
  end,
  ["ctrl+v"] = "paste_clipboard",
  ["super+v"] = "paste_clipboard",
  ["alt+v"] = "paste_clipboard",
  ["left"] = "left",
  ["right"] = "right",
  ["up"] = "up",
  ["down"] = "down",
  ["ctrl+left"] = "word_left",
  ["ctrl+right"] = "word_right",
  ["alt+left"] = "word_left",
  ["alt+right"] = "word_right",
  ["home"] = "line_start",
  ["end"] = "line_end",
  ["ctrl+a"] = "line_start",
  ["ctrl+e"] = "line_end",
  ["backspace"] = "backspace",
  ["ctrl+h"] = "backspace",
  ["delete"] = "delete",
  ["ctrl+w"] = "delete_word",
  ["alt+backspace"] = "delete_word",
  ["ctrl+u"] = "delete_to_start",
  ["ctrl+k"] = "delete_to_end",
  ["pageup"] = "page_up",
  ["pagedown"] = "page_down",
  ["wheelup"] = "scroll_up",
  ["wheeldown"] = "scroll_down",
  ["shift+up"] = "scroll_up",
  ["shift+down"] = "scroll_down",
  ["ctrl+home"] = "scroll_top",
  ["ctrl+end"] = "scroll_bottom",
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

-- ---- small helpers ---------------------------------------------------------

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

local function pad_right(s, n)
  local w = bone.text.width(s)
  if w >= n then return bone.text.truncate(s, n) end
  return s .. string.rep(" ", n - w)
end

local function pad_left(s, n)
  local w = bone.text.width(s)
  return w >= n and s or (string.rep(" ", n - w) .. s)
end

local function tokens(n)
  n = tonumber(n) or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e4 then return string.format("%.0fk", n / 1e3) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

local function clock(ms)
  local s = math.max(0, math.floor((ms or 0) / 1000))
  if s < 60 then return s .. "s" end
  if s < 3600 then return string.format("%d:%02d", math.floor(s / 60), s % 60) end
  return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

local function seconds(ms)
  if not ms then return "" end
  if ms < 60000 then return string.format("%.1fs", ms / 1000) end
  return clock(ms)
end

local home = os.getenv("HOME") or ""
local function short_path(p, cwd)
  if type(p) ~= "string" then return "" end
  if cwd and cwd ~= "" and p:sub(1, #cwd + 1) == cwd .. "/" then return p:sub(#cwd + 2) end
  if home ~= "" and p:sub(1, #home) == home then return "~" .. p:sub(#home + 1) end
  return p
end

local function chat_cwd()
  local s = bone.api.session()
  return s and s.cwd or nil
end

-- The margin: a label right-aligned into M-1 columns, then a space.
local function margin(label, group)
  return { pad_left(label or "", M - 1) .. " ", group or "Margin" }
end
local BLANK = { string.rep(" ", M), "Normal" }

local function cell_no(item)
  local full = bone.chat.item(item.index)
  return full and full.turn or 0
end

-- ---- markdown, typeset -----------------------------------------------------

local function spans_of(spans, base)
  local out = {}
  for _, s in ipairs(spans or {}) do
    if s.code then out[#out + 1] = { s.text, "MdCode" }
    elseif s.link then
      out[#out + 1] = { s.text, "MdLink" }
      if s.link ~= s.text then out[#out + 1] = { " ‹" .. s.link .. "›", "Footnote" } end
    elseif s.bold then out[#out + 1] = { s.text, "MdBold" }
    elseif s.italic then out[#out + 1] = { s.text, "MdItalic" }
    else out[#out + 1] = { s.text, base } end
  end
  return out
end

local function plain_of(spans)
  local t = {}
  for _, s in ipairs(spans or {}) do t[#t + 1] = s.text end
  return table.concat(t)
end

-- A table as a ledger: bold header, a hairline, striped rows.
local function ledger(b, width, first, rest)
  local out, w = {}, {}
  local avail = width - M
  for _, row in ipairs(b.rows) do
    for c, cell in ipairs(row) do w[c] = math.max(w[c] or 1, bone.text.width(plain_of(cell))) end
  end
  local gap = 2
  local total = (#w - 1) * gap
  for _, n in ipairs(w) do total = total + n end
  if #w * 3 + (#w - 1) * gap > avail then
    -- Too narrow for columns: one "header: value" line per cell.
    local head = b.header and b.rows[1] or {}
    for i, row in ipairs(b.rows) do
      if not (b.header and i == 1) then
        for c, cell in ipairs(row) do
          local label = head[c] and (plain_of(head[c]) .. ": ") or ""
          local line = { #out == 0 and first or rest, { label, "MdTableHeader" } }
          append(line, spans_of(cell, "MdTable"))
          out[#out + 1] = line
        end
        out[#out + 1] = { rest }
      end
    end
    return out
  end
  while total > avail do
    local widest = 1
    for c = 2, #w do if w[c] > w[widest] then widest = c end end
    w[widest], total = w[widest] - 1, total - 1
  end
  local stripe = false
  for i, row in ipairs(b.rows) do
    local header = b.header and i == 1
    local group = header and "MdTableHeader" or (stripe and "Stripe" or "MdTable")
    local line = { #out == 0 and first or rest }
    for c = 1, #w do
      local text = bone.text.truncate(plain_of(row[c] or {}), w[c])
      local align = b.align and b.align[c]
      local cellw = w[c]
      text = (align == "right") and pad_left(text, cellw) or pad_right(text, cellw)
      line[#line + 1] = { text, group }
      if c < #w then line[#line + 1] = { string.rep(" ", gap), group } end
    end
    out[#out + 1] = line
    if header then
      out[#out + 1] = { rest, { string.rep("─", math.min(total, avail)), "Rule" } }
    else
      stripe = not stripe
    end
  end
  return out
end

-- Body text in the notebook column. `first` is the margin span of the first
-- row; `rest` the one after it (usually blank).
local function typeset(text, width, first, rest)
  local out = {}
  local function lead() return #out == 0 and first or rest end
  for _, b in ipairs(bone.markdown.parse(text)) do
    if b.kind == "blank" then
      if #out > 0 then out[#out + 1] = {} end
    elseif b.kind == "heading" then
      local spans = spans_of(b.spans, "Heading")
      for _, s in ipairs(spans) do if s[2] == "Heading" and b.level <= 2 then s[1] = s[1]:upper() end end
      append(out, bone.text.wrap(spans, width, { first = { lead() }, rest = { rest } }))
      if b.level <= 2 then
        local n = math.min(bone.text.width(plain_of(b.spans)), width - M)
        out[#out + 1] = { rest, { string.rep(b.level == 1 and "━" or "─", math.max(n, 3)), "HeadingRule" } }
      end
    elseif b.kind == "rule" then
      out[#out + 1] = { lead(), { "·  ·  ·", "Rule" } }
    elseif b.kind == "quote" then
      append(out, bone.text.wrap(spans_of(b.spans, "MdQuote"), width, {
        first = { lead(), { "┃ ", "HeadingRule" } }, rest = { rest, { "┃ ", "HeadingRule" } },
      }))
    elseif b.kind == "item" then
      local indent = string.rep(" ", b.indent or 0)
      local bullet = b.ordered and (b.marker .. " ") or "– "
      append(out, bone.text.wrap(spans_of(b.spans, "Normal"), width, {
        first = { lead(), { indent, "Normal" }, { bullet, "MdBullet" } },
        rest = { rest, { indent .. string.rep(" ", bone.text.width(bullet)), "Normal" } },
      }))
    elseif b.kind == "code" then
      local tag = (b.lang and b.lang ~= "") and (" " .. b.lang .. " ") or " "
      out[#out + 1] = { lead(), { fill = " ", hl = "CodeBand" }, { tag, "CodeLang" }, { " ", "Normal" } }
      for _, l in ipairs(b.lines) do
        append(out, bone.text.wrap({ { l, "CodeBand" } }, width, {
          first = { rest, { "  ", "CodeBand" } }, rest = { rest, { "  ", "CodeBand" } }, pad = "CodeBand",
        }))
      end
      out[#out + 1] = { rest, { fill = " ", hl = "CodeBand" } }
    elseif b.kind == "table" then
      append(out, ledger(b, width, lead(), rest))
    else
      local indent = string.rep(" ", b.indent or 0)
      append(out, bone.text.wrap(spans_of(b.spans, "Normal"), width, {
        first = { lead(), { indent, "Normal" } }, rest = { rest, { indent, "Normal" } },
      }))
    end
  end
  while #out > 0 and next(out[#out]) == nil do out[#out] = nil end
  return out
end

-- ---- cells -----------------------------------------------------------------

local views = bone.ui.views

-- In [n]: the message on a tinted band with a blue edge.
views.user = function(item, ctx)
  local out = {}
  if ctx.prev then out[#out + 1] = {} end
  local n = cell_no(item)
  local label = margin("In [" .. n .. "]:", "InLabel")
  local edge = { "▌", "InCellEdge" }
  local lines = split_lines(trim(item.text))
  if #lines == 0 then lines = { "" } end
  for i, line in ipairs(lines) do
    append(out, bone.text.wrap({ { line, "InCell" } }, ctx.width, {
      first = { (i == 1 and #out == (ctx.prev and 1 or 0)) and label or BLANK, edge, { " ", "InCell" } },
      rest = { BLANK, edge, { " ", "InCell" } },
      pad = "InCell",
    }))
  end
  for _, img in ipairs(item.images or {}) do
    local name = type(img) == "table" and (img.name or img.id) or tostring(img)
    out[#out + 1] = { BLANK, edge, { " ⧉ " .. tostring(name), "Footnote" }, { fill = " ", hl = "InCell" } }
  end
  return out
end

-- Out[n]: typeset markdown; only the first reply of a cell carries the label.
views.assistant = function(item, ctx)
  local text = trim(item.text)
  if text == "" and not item.streaming then return nil end
  local n = cell_no(item)
  local first_reply = true
  for _, a in ipairs(bone.chat.items({ kind = "assistant", turn = n, first = 1 })) do
    first_reply = a.index == item.index
  end
  local label
  if item.streaming then
    label = margin((ctx.spinner or "◴") .. " Out[" .. n .. "]:", "OutLabel")
  else
    label = first_reply and margin("Out[" .. n .. "]:", "OutLabel") or BLANK
  end
  local out = { {} }
  if text == "" then
    out[#out + 1] = { label, { "…", "Footnote" } }
    return out
  end
  append(out, typeset(text, ctx.width, label, BLANK))
  if item.streaming then
    local last = out[#out]
    last[#last + 1] = { " ▍", "OutLabel" }
  elseif item.usage and (item.usage.output or 0) > 0 then
    out[#out + 1] = {
      BLANK, { fill = " ", hl = "Normal" },
      { "context " .. tokens(item.usage.input) .. " · wrote " .. tokens(item.usage.output) .. " tok ", "Footnote" },
    }
  end
  return out
end

views.reasoning = function(item, ctx)
  if not bone.o.show_reasoning or trim(item.text) == "" then return nil end
  local out = { {} }
  local first = margin(item.streaming and ((ctx.spinner or "◴") .. " think") or "think", "Margin")
  for i, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "Reasoning" } }, ctx.width, {
      first = { i == 1 and first or BLANK }, rest = { BLANK },
    }))
  end
  return out
end

views.notice = function(item, ctx)
  local group = item.error and "ErrorMsg" or "Notice"
  local out = { {} }
  for i, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, item.error and "ToolError" or "Notice" } }, ctx.width, {
      first = { i == 1 and margin(item.error and "error" or "note", group) or BLANK }, rest = { BLANK },
    }))
  end
  return out
end

-- In [*]: Jupyter's mark for a cell waiting to run.
views.queued = function(item, ctx)
  local out = { {} }
  local first = margin("In [*]:", "Margin")
  for i, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "Footnote" } }, ctx.width, {
      first = { i == 1 and first or BLANK }, rest = { BLANK },
    }))
  end
  out[#out + 1] = { BLANK, { item.mode == "steer" and "↳ joins the running cell" or "↳ runs as the next cell", "Margin" } }
  return out
end

-- ---- the execution log ---------------------------------------------------

local VERBS = {
  shell = "shell", read_file = "read", write_file = "write", edit_file = "edit",
  subagent = "agent", web_search = "search", web_fetch = "fetch",
}

-- Live calls can arrive before `arguments` is decoded; fall back to the raw JSON.
local function args_of(item)
  if type(item.arguments) == "table" and next(item.arguments) ~= nil then return item.arguments end
  if type(item.raw_arguments) == "string" and item.raw_arguments ~= "" then
    local ok, decoded = pcall(bone.json.decode, item.raw_arguments)
    if ok and type(decoded) == "table" then return decoded end
  end
  return {}
end

local function count_lines(s)
  if type(s) ~= "string" or s == "" then return 0 end
  local _, n = s:gsub("\n", "")
  return n + (s:sub(-1) == "\n" and 0 or 1)
end

local function exit_code(out)
  local code = (out or ""):gsub("%s+$", ""):match("%[exit code: (%-?%d+)%]$")
  return tonumber(code)
end

-- What a call was aimed at, and a short figure about it.
local function target_of(item, cwd)
  local a = args_of(item)
  local name = item.name
  if name == "shell" then
    local cmd = (a.command or a.cmd or ""):gsub("%s+", " ")
    local code = item.done and exit_code(item.output)
    return cmd, (code and code ~= 0) and ("exit " .. code) or nil
  elseif name == "edit_file" then
    local edits = type(a.edits) == "table" and a.edits or (type(a.old_string) == "string" and { a } or {})
    local del, add = 0, 0
    for _, e in ipairs(edits) do
      del, add = del + count_lines(e.old_string), add + count_lines(e.new_string)
    end
    return short_path(a.path, cwd), { del = del, add = add }
  elseif name == "write_file" then
    return short_path(a.path, cwd), { add = count_lines(a.content) }
  elseif name == "read_file" then
    local fig
    if a.offset or a.limit then
      local from = tonumber(a.offset) or 1
      fig = a.limit and ("L" .. from .. "–" .. (from + tonumber(a.limit) - 1)) or ("from L" .. from)
    end
    return short_path(a.path, cwd), fig
  elseif name == "subagent" then
    return trim((a.task or a.name or ""):gsub("%s+", " ")), a.name
  end
  for _, key in ipairs({ "path", "query", "url", "pattern", "task", "name" }) do
    if type(a[key]) == "string" and a[key] ~= "" then return short_path(a[key], cwd) end
  end
  for _, v in pairs(a) do
    if type(v) == "string" then return (v:gsub("%s+", " ")) end
  end
  return ""
end

local function status_of(item, ctx)
  if not item.done then return (ctx.spinner or "◴"), "LogRun" end
  if item.is_error then return "✕", "LogFail" end
  local code = item.name == "shell" and exit_code(item.output)
  if code and code ~= 0 then return "✕", "LogFail" end
  return "✓", "LogOk"
end

local function elapsed_of(item)
  if item.duration_ms then return item.duration_ms end
  if item.started_at then return bone.now() - item.started_at end
  return nil
end

-- One aligned row: │ ✓ verb   target ……… figure   time
local function log_row(item, ctx, lead)
  local cwd = chat_cwd()
  local mark, mark_hl = status_of(item, ctx)
  local verb = VERBS[item.name] or item.name or "tool"
  local target, fig = target_of(item, cwd)
  local fig_spans = {}
  if type(fig) == "table" then
    if fig.del and fig.del > 0 then fig_spans[#fig_spans + 1] = { "−" .. fig.del .. " ", "LogDel" } end
    if fig.add and fig.add > 0 then fig_spans[#fig_spans + 1] = { "+" .. fig.add, "LogAdd" } end
  elseif type(fig) == "string" then
    fig_spans[1] = { fig, item.done and exit_code(item.output) and "LogFail" or "LogFigure" }
  end
  local time = pad_left(seconds(elapsed_of(item)), 7)
  if not item.done then bone.chat.refresh_in(250) end
  local figw = 0
  for _, s in ipairs(fig_spans) do figw = figw + bone.text.width(s[1]) end
  local fixed = M + 2 + 8 + 2 + (figw > 0 and figw + 2 or 0) + bone.text.width(time)
  local room = math.max(ctx.width - fixed, 6)
  local target_hl = item.name == "shell" and "ShellProgram" or "LogTarget"
  local row = { lead, { mark .. " ", mark_hl }, { pad_right(verb, 8), "LogVerb" }, { "  ", "Normal" } }
  if item.name == "shell" and bone.text.width(target) <= room then
    append(row, bone.text.shell(target))
  else
    row[#row + 1] = { bone.text.truncate(target, room), item.name == "shell" and "ToolArgs" or target_hl }
  end
  row[#row + 1] = { fill = " ", hl = "Normal" }
  if figw > 0 then append(row, fig_spans); row[#row + 1] = { "  ", "Normal" } end
  row[#row + 1] = { time .. " ", "LogTime" }
  return row
end

-- Output under a row, hung off a hairline in the target column.
local function log_body(item, ctx, max)
  local out = {}
  local hang = { BLANK, { "  ╎ ", "Rule" } }
  local text
  if item.name == "edit_file" and item.done and not item.is_error then
    local a = args_of(item)
    local edits = type(a.edits) == "table" and a.edits or (type(a.old_string) == "string" and { a } or {})
    for _, e in ipairs(edits) do
      for _, l in ipairs(split_lines(e.old_string or "")) do
        out[#out + 1] = { BLANK, { "  ╎ ", "Rule" }, { bone.text.truncate("- " .. l, ctx.width - M - 4), "DiffDelete" }, { fill = " ", hl = "DiffDelete" } }
      end
      for _, l in ipairs(split_lines(e.new_string or "")) do
        out[#out + 1] = { BLANK, { "  ╎ ", "Rule" }, { bone.text.truncate("+ " .. l, ctx.width - M - 4), "DiffAdd" }, { fill = " ", hl = "DiffAdd" } }
      end
    end
  else
    text = item.output or item.live or ""
    if item.name == "shell" then text = text:gsub("\n?%[exit code: %-?%d+%]%s*$", "") end
    local group = (item.is_error and "ToolError") or "ToolOutput"
    for _, l in ipairs(split_lines(trim(text))) do
      out[#out + 1] = { BLANK, { "  ╎ ", "Rule" }, { bone.text.truncate(l, ctx.width - M - 4), group } }
    end
  end
  if #out > max then
    local hidden = #out - max
    local keep = {}
    for i = 1, max do keep[i] = out[i] end
    keep[#keep + 1] = { BLANK, { "  ╵ ", "Rule" }, { "+" .. hidden .. " more · ctrl+t", "Footnote" } }
    out = keep
  end
  return out
end

-- Whether this call opens a run of calls (reasoning between calls does not
-- break a run).
local function run_start(item)
  local i = item.index - 1
  local before = bone.chat.item(i)
  while before and before.kind == "reasoning" do
    i = i - 1
    before = bone.chat.item(i)
  end
  return not (before and before.kind == "tool")
end

local function failed(t)
  return t.done and (t.is_error or (t.name == "shell" and (exit_code(t.output) or 0) ~= 0))
end

views.tool = function(item, ctx)
  local detail = bone.o.tool_detail
  local first = run_start(item)
  local out = {}
  if first then out[#out + 1] = {} end
  local lead = first and margin("exec", "Margin") or BLANK

  if detail == "summary" and not failed(item) then
    if not first then return nil end
    -- One line for the whole run: verbs with counts, and the run's time.
    local run = {}
    for _, t in ipairs(bone.chat.items({ around = item.index, from = item.index, kind = { "tool", "reasoning" }, full = true })) do
      if t.kind == "tool" then run[#run + 1] = t end
    end
    local order, seen, running, ms, bad = {}, {}, false, 0, 0
    for _, t in ipairs(run) do
      local v = VERBS[t.name] or t.name
      if not seen[v] then seen[v] = 0; order[#order + 1] = v end
      seen[v] = seen[v] + 1
      running = running or not t.done
      ms = ms + (elapsed_of(t) or 0)
      if failed(t) then bad = bad + 1 end
    end
    if running then bone.chat.refresh_in(250) end
    local row = { lead, running and { (ctx.spinner or "◴") .. " ", "LogRun" } or { "✓ ", bad > 0 and "LogFail" or "LogOk" } }
    for i, v in ipairs(order) do
      if i > 1 then row[#row + 1] = { " · ", "Rule" } end
      row[#row + 1] = { v, "LogVerb" }
      if seen[v] > 1 then row[#row + 1] = { " ×" .. seen[v], "LogFigure" } end
    end
    if bad > 0 then row[#row + 1] = { "   " .. bad .. " failed ↓", "LogFail" } end
    row[#row + 1] = { fill = " ", hl = "Normal" }
    row[#row + 1] = { pad_left(seconds(ms), 7) .. " ", "LogTime" }
    out[#out + 1] = row
    return out
  end

  if detail == "summary" and not first then
    -- A failure inside a summarised run still gets its own row.
    out[#out + 1] = {}
  end
  out[#out + 1] = log_row(item, ctx, lead)
  local max = (detail == "full") and 40 or ((failed(item) or item.name == "edit_file") and 6 or 0)
  if not item.done and detail ~= "summary" then max = math.max(max, 3) end
  if max > 0 then append(out, log_body(item, ctx, max)) end
  return out
end

-- ---- masthead, inspector, prompt -------------------------------------------

local function model_name()
  local provider = bone.settings.get("provider")
  if not provider then return nil, nil end
  return bone.settings.get("providers." .. provider .. ".model"), provider
end

local function session_title()
  local s = bone.chat.session()
  local t = s and not s.new and s.title and trim(s.title) or ""
  return t ~= "" and t or "Untitled notebook"
end

bone.ui.regions.masthead = {
  size = 1,
  render = function(ctx)
    local s = bone.chat.session()
    local running = s and s.running
    if running then bone.ui.refresh_in(500) end
    local state
    if running then
      local ms = s.turn and s.turn.elapsed_ms or 0
      state = { " " .. (ctx.spinner or "◴") .. " running " .. clock(ms) .. " ", "MastBusy" }
    else
      state = { " ○ idle ", "MastIdle" }
    end
    local cwd = short_path(chat_cwd() or (s and s.cwd) or "", nil)
    local room = math.max(ctx.width - 40 - bone.text.width(cwd), 10)
    return {
      { { " ▍notebook ", "Mast" }, { "  ", "MastDim" }, { bone.text.truncate(session_title(), room), "Mast" },
        { fill = " ", hl = "MastDim" }, { cwd .. "  ", "MastDim" }, state },
    }
  end,
}

-- Everything the inspector shows, rebuilt only when the chat changes.
local insp_cache = { key = nil, data = nil }
local function inspect()
  local s = bone.chat.session() or {}
  local tick = s.running and math.floor(bone.now() / 1000) or 0
  local key = tostring(s.session_id) .. ":" .. tostring(s.items) .. ":" .. tostring(s.running) .. ":" .. tick
  if insp_cache.key == key then return insp_cache.data end
  local d = { spark = {}, out_total = 0, ctx_tokens = 0, tools = {}, tool_order = {}, files = {}, calls = 0, fails = 0, cells = {} }
  for _, a in ipairs(bone.chat.items({ kind = "assistant" })) do
    if a.usage then
      d.spark[#d.spark + 1] = a.usage.output or 0
      d.out_total = d.out_total + (a.usage.output or 0)
      d.ctx_tokens = a.usage.input or d.ctx_tokens
    end
  end
  local cwd = chat_cwd()
  local seen_file = {}
  local tools = bone.chat.items({ kind = "tool" })
  for i = #tools, 1, -1 do
    local t = tools[i]
    local a = args_of(t)
    if type(a.path) == "string" and (t.name == "read_file" or t.name == "edit_file" or t.name == "write_file") then
      local p = short_path(a.path, cwd)
      local kind = t.name == "edit_file" and "E" or t.name == "write_file" and "W" or "R"
      local f = seen_file[p]
      if not f then
        f = { path = p, kind = kind }
        seen_file[p] = f
        d.files[#d.files + 1] = f
      elseif kind ~= "R" and f.kind == "R" then
        f.kind = kind
      end
    end
  end
  for _, t in ipairs(tools) do
    local v = VERBS[t.name] or t.name
    if not d.tools[v] then d.tools[v] = 0; d.tool_order[#d.tool_order + 1] = v end
    d.tools[v] = d.tools[v] + 1
    d.calls = d.calls + 1
    if t.done and t.is_error then d.fails = d.fails + 1 end
  end
  table.sort(d.tool_order, function(x, y) return d.tools[x] > d.tools[y] end)
  for _, turn in ipairs(bone.chat.turns()) do
    d.cells[#d.cells + 1] = turn.running and "run"
      or (turn.outcome == "failed" or (turn.tool_errors or 0) > 0) and "bad"
      or turn.outcome == "cancelled" and "cut" or "ok"
  end
  insp_cache.key, insp_cache.data = key, d
  return d
end

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

bone.ui.regions.inspector = {
  render = function(ctx)
    local w = ctx.width - 2
    if w < 12 then return nil end
    local s = bone.chat.session() or {}
    local d = inspect()
    local L = {}
    local function line(spans) local l = { { " ", "Normal" } }; append(l, spans); L[#L + 1] = l end
    local function head(t) if #L > 0 then L[#L + 1] = {} end; line({ { t, "InspHead" } }) end

    head("KERNEL")
    if s.running then
      line({ { (ctx.spinner or "◴") .. " busy  ", "LogRun" }, { clock(s.turn and s.turn.elapsed_ms or 0), "InspText" } })
    else
      line({ { "○ idle", "LogOk" } })
    end
    local model, provider = model_name()
    if model then line({ { bone.text.truncate(model, w), "InspText" } }) end
    if provider then line({ { bone.text.truncate("via " .. provider, w), "InspDim" } }) end

    head("CONTEXT")
    local limit = tonumber(bone.settings.get("compact.limit"))
    if limit and limit > 0 then
      local frac = math.min(d.ctx_tokens / limit, 1)
      local barw = math.max(w - 5, 4)
      local fullc = math.floor(frac * barw + 0.5)
      line({ { string.rep("▰", fullc), frac > 0.8 and "InspBarHot" or "InspBar" }, { string.rep("▱", barw - fullc), "InspEmpty" },
             { pad_left(math.floor(frac * 100) .. "%", 5), "InspText" } })
      line({ { tokens(d.ctx_tokens) .. " of " .. tokens(limit) .. " before compact", "InspDim" } })
    else
      line({ { tokens(d.ctx_tokens) .. " tokens in context", "InspText" } })
    end

    head("OUTPUT")
    if #d.spark > 0 then
      local from = math.max(1, #d.spark - w + 1)
      local hi = 1
      for i = from, #d.spark do hi = math.max(hi, d.spark[i]) end
      local bars = {}
      for i = from, #d.spark do
        bars[#bars + 1] = SPARK[math.max(1, math.ceil(d.spark[i] / hi * #SPARK))]
      end
      line({ { table.concat(bars), "InspSpark" } })
      line({ { tokens(d.out_total) .. " tok over " .. #d.spark .. " replies", "InspDim" } })
    else
      line({ { "nothing written yet", "InspDim" } })
    end

    head("CELLS")
    if #d.cells > 0 then
      local glyph = { ok = { "■", "LogOk" }, bad = { "■", "LogFail" }, cut = { "□", "InspDim" }, run = { "▣", "LogRun" } }
      local from = math.max(1, #d.cells - w + 1)
      local row = {}
      for i = from, #d.cells do row[#row + 1] = glyph[d.cells[i]] end
      line(row)
    end
    line({ { #d.cells .. " cells · " .. d.calls .. " calls", "InspText" },
           d.fails > 0 and { " · " .. d.fails .. " failed", "LogFail" } or { "", "Normal" } })

    if #d.tool_order > 0 then
      head("TOOLS")
      local top = d.tools[d.tool_order[1]]
      local barw = math.max(w - 8 - 5, 3)
      for i = 1, math.min(#d.tool_order, 6) do
        local v = d.tool_order[i]
        local n = d.tools[v]
        local fill = math.max(1, math.floor(n / top * barw + 0.5))
        line({ { pad_right(v, 8), "InspText" }, { string.rep("█", fill), "InspBar" },
               { string.rep(" ", barw - fill), "Normal" }, { pad_left(tostring(n), 5), "InspDim" } })
      end
    end

    if #d.files > 0 then
      head("FILES")
      local kinds = { E = "FileEdit", W = "FileWrite", R = "FileRead" }
      local room = math.max(ctx.height - #L - 1, 1)
      for i = 1, math.min(#d.files, room) do
        local f = d.files[i]
        local base = f.path:match("([^/]+)$") or f.path
        local dir = f.path:sub(1, #f.path - #base):gsub("/$", "")
        local bw = math.min(bone.text.width(base), w - 2)
        local spans = { { f.kind .. " ", kinds[f.kind] }, { bone.text.truncate(base, w - 2), "InspText" } }
        if dir ~= "" and w - 2 - bw > 4 then spans[#spans + 1] = { " " .. bone.text.truncate(dir, w - 3 - bw), "InspDim" } end
        line(spans)
      end
    end
    return L
  end,
}

-- The title page of an empty notebook. Rust centres each line, so every
-- line is padded to one width to keep the block's left edge straight.
bone.ui.regions.chat_empty = {
  render = function()
    local s = bone.chat.session()
    if bone.api.session() or (s and (s.items or 0) > 0) then return {} end
    local model = model_name()
    local cwd = short_path(chat_cwd() or (s and s.cwd) or os.getenv("PWD") or "", nil)
    local W = 44
    local function row(spans)
      local used = 0
      for _, sp in ipairs(spans) do used = used + bone.text.width(sp[1]) end
      spans[#spans + 1] = { string.rep(" ", math.max(W - used, 0)), "Normal" }
      return spans
    end
    local L = {
      row({ { "UNTITLED NOTEBOOK", "Heading" } }),
      row({ { string.rep("━", 17), "HeadingRule" } }),
      row({ { bone.text.truncate(cwd, W), "Footnote" } }),
    }
    if model then L[#L + 1] = row({ { "kernel · " .. model, "Footnote" } }) end
    L[#L + 1] = row({})
    L[#L + 1] = row({ { "In [1]: ", "InLabel" }, { "is waiting below.", "Normal" } })
    L[#L + 1] = row({})
    local keys = {
      { "ctrl+t", "execution log: summary / rows / full" }, { "ctrl+r", "show reasoning" },
      { "ctrl+o", "sessions" }, { "F2", "day / night paper" }, { "F3", "inspector" }, { "F1", "help" },
    }
    for _, k in ipairs(keys) do
      L[#L + 1] = row({ { pad_right(k[1], 8), "LogVerb" }, { k[2], "Margin" } })
    end
    if bone.settings.get("setup.skipped") then
      L[#L + 1] = row({})
      L[#L + 1] = row({ { "No model provider configured · /setup", "Notice" } })
    end
    return L
  end,
}

bone.ui.prompt = {
  prefix = function(ctx)
    if ctx.running then return { margin("In [*]:", "InLabel") } end
    local s = bone.chat.session()
    return { margin("In [" .. ((s and s.turns or 0) + 1) .. "]:", "InLabel") }
  end,
  continuation = { BLANK },
  placeholder = { { "Write a cell…", "Placeholder" } },
  border = { style = "single", hl = "Rule", sides = "t" },
  padding = { rows = 0, cols = 0 },
  min = 1,
  max = 8,
  top = function(ctx)
    local note
    if ctx.running then
      note = " " .. (ctx.spinner or "◴") .. " running · enter queues (" .. bone.o.queue_mode .. ") · ctrl+c interrupts "
      return { { string.rep("─", M - 1), "Rule" }, { fill = "─", hl = "Rule" }, { note, "LogRun" }, { "──", "Rule" } }
    end
    note = " enter run · alt+enter newline · / commands "
    return { { fill = "─", hl = "Rule" }, { note, "Margin" }, { "──", "Rule" } }
  end,
}

bone.ui.prompt_highlight = function(ctx)
  local s, e = ctx.text:find("^/%S+")
  return { highlights = s and { { row = 0, from = s - 1, to = e, hl = "SuggestName" } } or {} }
end

-- Only shown when the inspector is off or does not fit.
bone.ui.statusline = function(ctx)
  local d = inspect()
  local model = model_name()
  local s = bone.chat.session() or {}
  local left = s.running and { " " .. (ctx.spinner or "◴") .. " busy ", "MastBusy" } or { " ○ idle ", "MastIdle" }
  local mid = (model or "no model") .. " · ctx " .. tokens(d.ctx_tokens) .. " · " .. #d.cells .. " cells · " .. d.calls .. " calls"
  local right = ctx.popup and (" " .. ctx.popup .. " ") or " F3 inspector "
  return { left, { " " .. mid, "StatusLineDim" }, { fill = " ", hl = "StatusLine" }, { right, "StatusLineDim" } }
end

bone.ui.title = function()
  return "notebook · " .. session_title()
end

-- / menu as an index: blue names, a column of descriptions.
bone.ui.suggestions = function(ctx)
  local lines = {}
  local namew = 0
  for _, it in ipairs(ctx.items) do namew = math.max(namew, bone.text.width(it.name) + 1) end
  namew = math.min(namew, 22)
  for i, it in ipairs(ctx.items) do
    local sel = i == ctx.selected
    lines[i] = {
      { sel and pad_left("▸ ", M) or BLANK[1], sel and "SuggestSel" or "Normal" },
      { pad_right("/" .. it.name, namew + 2), sel and "SuggestSel" or "SuggestName" },
      { it.desc or "", sel and "SuggestSelDesc" or "SuggestDesc" },
      { fill = " ", hl = sel and "SuggestSel" or "Normal" },
    }
  end
  return lines
end

-- The inspector needs room; below 100 columns the statusline sums it up.
local last_width
apply_layout = function(width)
  width = width or last_width or 120
  last_width = width
  if inspector_on and width >= 100 then
    bone.ui.layout = {
      "masthead",
      { cols = { "chat", { "inspector", size = width >= 140 and 38 or 32 } }, sep = "│" },
      "above_prompt", "prompt",
    }
  else
    bone.ui.layout = { "masthead", "chat", "above_prompt", "prompt", "statusline" }
  end
end
apply_layout()
bone.on("resize", function(ev) apply_layout(ev.width) end)
-- Saved choices may arrive after this file runs; pick them up once ready.
local function restore_saved()
  local paper = bone.settings.get("tui.notebook_paper")
  if palettes[paper] and paper ~= paper_name then bone.o.notebook_paper = paper end
  local insp = bone.settings.get("tui.notebook_inspector") ~= false
  if insp ~= inspector_on then bone.o.notebook_inspector = insp end
  local detail = bone.settings.get("tui.tool_detail")
  if next_detail[detail] and detail ~= bone.o.tool_detail then bone.o.tool_detail = detail end
end
bone.on("ready", function()
  restore_saved()
  bone.defer(500, restore_saved)
  local g = bone.ui.geometry and bone.ui.geometry()
  local widest = 0
  for _, leaf in ipairs((g and g.leaves) or {}) do widest = math.max(widest, (leaf.x or 0) + (leaf.width or 0)) end
  if widest > 0 then apply_layout(widest) end
end)

-- ---- stock behaviour ---------------------------------------------------------

function bone.ui.help(topic)
  local help = require("bone.help")
  return topic and topic:match("%S") and help.topic(topic) or help.open()
end
function bone.ui.sessions()
  return require("bone.ui.sessions").open()
end

local mark = { ok = { "✓ ", "LogOk" }, warn = { "! ", "WarningMsg" }, error = { "✕ ", "LogFail" } }
local function health_section(out, title, items)
  out[#out + 1] = { { title, "Heading" } }
  for _, it in ipairs(items or {}) do
    local m = mark[it.status] or mark.warn
    out[#out + 1] = { m, { it.name .. "  ", "Normal" }, { tostring(it.message), "Dim" } }
  end
  out[#out + 1] = {}
end
function bone.ui.health()
  local tui = bone.api.health()
  for _, it in ipairs(bone._run_health()) do tui[#tui + 1] = it end
  local lines = {}
  health_section(lines, "Notebook TUI", tui)
  lines[#lines + 1] = { { "Core: checking…", "Dim" } }
  local pager = bone.ui.pager(lines, { title = "Health · Notebook" })
  bone.request("health/check", {}, function(core, err)
    local all = {}
    health_section(all, "Notebook TUI", tui)
    health_section(all, "Core", err and { { name = "core", status = "error", message = err } } or core)
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
