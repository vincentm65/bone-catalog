-- Code: a TUI library dressed as Visual Studio Code (Dark Modern).
--
--   * Title bar with a command center, an activity bar, an Explorer side bar
--     (open chats, the files this chat touched as a decorated tree, and an
--     outline of its turns), editor tabs and breadcrumbs.
--   * The conversation reads like the Copilot Chat view: avatars, "Ran
--     terminal command" / "Read file" tool lines, highlighted code blocks.
--   * A bottom panel (alt+j) with PROBLEMS, OUTPUT and TERMINAL tabs.
--   * The blue status bar: git branch, problems, the prompt's Ln/Col, model.
--   * ctrl+p / ctrl+o: a Quick Open picker for sessions.
--
-- Self-contained: it does not load bone.ui.setup().

bone.ui.clear()
bone.colorscheme("black")

local c = {
  editor = "#1f1f1f", side = "#181818", border = "#2b2b2b", tab_off = "#181818",
  text = "#cccccc", bright = "#ffffff", dim = "#9d9d9d", faint = "#6e7681",
  blue = "#0078d4", status = "#007acc", link = "#4daafc", sel = "#04395e",
  hover = "#2a2d2e", input = "#313131", widget = "#252526",
  kw = "#569cd6", str = "#ce9178", fn = "#dcdcaa", ty = "#4ec9b0",
  com = "#6a9955", num = "#b5cea8", var = "#9cdcfe", purple = "#c586c0",
  pre = "#d7ba7d", red = "#f14c4c", yellow = "#e2c08d", green = "#73c991", warn = "#cca700",
}

local function hl(name, fg, bg, attrs)
  local spec = { fg = fg, bg = bg or c.editor }
  for k, v in pairs(attrs or {}) do spec[k] = v end
  bone.hl.set(name, spec)
end

hl("Normal", c.text)
hl("Dim", c.faint)
hl("Accent", c.link)
hl("UserPrompt", c.link)
hl("UserMessage", c.text, c.widget)
hl("Reasoning", c.faint, nil, { italic = true })
hl("ToolName", c.text)
hl("ToolArgs", c.dim)
hl("ToolPath", c.link)
hl("ToolSummary", c.dim)
hl("ToolOutput", c.dim)
hl("ToolGutter", c.border)
hl("ToolRunning", c.link)
hl("ToolError", c.red)
hl("Notice", c.link)
hl("ErrorMsg", c.red)
hl("WarningMsg", c.warn)
hl("WinSeparator", c.border, c.side)
hl("StatusLine", c.bright, c.status)
hl("StatusLineDim", c.bright, c.status)
hl("Selection", c.bright, "#264f78")
hl("Placeholder", c.faint, c.input)
hl("InputBackground", c.text, c.input)
hl("InputText", c.text, c.input)
hl("PopupBorder", c.border, c.widget)
hl("PopupTitle", c.text, c.widget, { bold = true })
hl("PanelTitle", c.dim, c.side)
hl("PanelTitleFocus", c.text, c.side, { bold = true })
hl("MdHeading", c.bright, nil, { bold = true })
hl("MdBold", c.bright, nil, { bold = true })
hl("MdItalic", c.text, nil, { italic = true })
hl("MdCode", c.pre, "#2b2b2b")
hl("MdCodeBlock", c.text, c.side)
hl("MdQuote", c.dim, nil, { italic = true })
hl("MdBullet", c.text)
hl("MdLink", c.link, nil, { underline = true })
hl("MdTable", c.text)
hl("MdTableHeader", c.bright, nil, { bold = true })
hl("DiffAdd", c.green, "#1b3a28")
hl("DiffDelete", c.red, "#3f1d1d")
hl("ShellProgram", c.fn)
hl("ShellPath", c.str)
hl("ShellFlag", c.var)
hl("ShellString", c.str)
hl("ShellVariable", c.var)
hl("ShellComment", c.com)
hl("ShellOperator", c.text)

-- Chrome.
hl("VTitle", c.dim, c.side)
hl("VTitleMenu", c.text, c.side)
hl("VCenter", c.dim, "#2a2a2a")
hl("VCenterText", c.text, "#2a2a2a")
hl("VAct", c.faint, c.side)
hl("VActOn", c.bright, c.side)
hl("VActBar", c.blue, c.side)
hl("VSide", c.text, c.side)
hl("VSideDim", c.dim, c.side)
hl("VSideHead", c.text, c.side, { bold = true })
hl("VSideSel", c.bright, "#37373d")
hl("VFolder", c.text, c.side)
hl("VFileMod", c.yellow, c.side)
hl("VFileNew", c.green, c.side)
hl("VFileRead", c.text, c.side)
hl("VIconTs", c.link, c.side)
hl("VIconMd", c.ty, c.side)
hl("VIconRs", "#dea584", c.side)
hl("VIconLua", "#51a0cf", c.side)
hl("VIconCfg", c.warn, c.side)
hl("VIconAny", c.dim, c.side)
hl("VTabOn", c.bright, c.editor)
hl("VTabOnTop", c.blue, c.editor)
hl("VTabOff", c.faint, c.tab_off)
hl("VTabBar", c.faint, c.tab_off)
hl("VTabDot", c.bright, c.editor)
hl("VCrumb", c.dim)
hl("VCrumbSep", c.faint)
hl("VStatus", c.bright, c.status)
hl("VStatusBusy", c.bright, "#16825d")
hl("VStatusRemote", c.bright, "#16825d")
hl("VPanelTab", c.faint, c.editor)
hl("VPanelTabOn", c.text, c.editor)
hl("VPanelTabLine", c.blue, c.editor)
hl("VPanelErr", c.red)
hl("VPanelWarn", c.warn)
hl("VInputBorder", c.blue, c.editor)
hl("VInputEdge", c.faint, c.editor)
hl("VInputChip", c.text, c.input)
hl("VInputHint", c.faint, c.input)
-- Chat view.
hl("VAvatarYou", c.bright, c.blue, { bold = true })
hl("VAvatarBot", c.bright, "#6f42c1", { bold = true })
hl("VName", c.bright, nil, { bold = true })
hl("VModel", c.faint)
hl("VToolOk", c.green)
hl("VToolTxt", c.dim)
hl("VToolFile", c.link)
hl("VInline", c.pre, "#2b2b2b")
hl("VCodeHead", c.dim, c.widget)
hl("VCode", c.text, c.side)
hl("VCodeNum", "#5a5a5a", c.side)
hl("VKw", c.kw, c.side)
hl("VCtl", c.purple, c.side)
hl("VStr", c.str, c.side)
hl("VFn", c.fn, c.side)
hl("VTy", c.ty, c.side)
hl("VCom", c.com, c.side, { italic = true })
hl("VNum", c.num, c.side)
hl("VVar", c.var, c.side)
hl("VUserBand", c.text, c.widget)

bone.ui.spinner = { frames = { "◐", "◓", "◑", "◒" }, interval = 110 }

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

local explorer_on, panel_on, panel_tab = true, false, "problems"
local apply_layout

local function map(keys, context)
  for key, action in pairs(keys) do bone.keymap.set(key, action, { context = context }) end
end

map({
  ["f1"] = "/help",
  ["ctrl+b"] = function() explorer_on = not explorer_on; apply_layout() end,
  ["alt+j"] = function() panel_on = not panel_on; apply_layout() end,
  ["alt+l"] = function()
    panel_tab = ({ problems = "output", output = "terminal", terminal = "problems" })[panel_tab]
    if not panel_on then panel_on = true; apply_layout() end
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
  ["ctrl+p"] = "sessions",
  ["ctrl+n"] = "new_session",
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

local function cwd()
  local s = bone.api.session()
  return (s and s.cwd) or os.getenv("PWD") or ""
end

local function rel(p)
  if type(p) ~= "string" then return "" end
  local d = cwd()
  if d ~= "" and p:sub(1, #d + 1) == d .. "/" then return p:sub(#d + 2) end
  return p
end

local function base(p) return (p or ""):match("([^/]+)$") or p or "" end

local function model_name()
  local p = bone.settings.get("provider")
  return p and bone.settings.get("providers." .. p .. ".model") or nil
end

local function title_of()
  local s = bone.chat.session()
  local t = s and not s.new and s.title and trim(s.title) or ""
  return t ~= "" and t or "New Chat"
end

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

-- ---- syntax colouring for code blocks ---------------------------------------

local KW = {}
for w in ("fn let mut const static pub use mod struct enum impl trait type where as ref move async await "
  .. "local function end then do in not and or var def class import from export default new this self "
  .. "interface extends implements package func go defer chan map true false nil null None True False Some Ok Err"):gmatch("%S+") do
  KW[w] = "VKw"
end
for w in ("if else elseif elif for while loop return break continue match switch case try catch finally throw yield"):gmatch("%S+") do
  KW[w] = "VCtl"
end

local function highlight(line, lang)
  local out, i, n = {}, 1, #line
  local comment = (lang == "lua" or lang == "sql") and "%-%-" or ((lang == "python" or lang == "sh" or lang == "bash"
    or lang == "toml" or lang == "yaml" or lang == "shell") and "#" or "//")
  while i <= n do
    local rest = line:sub(i)
    local s, e = rest:find("^" .. comment)
    if s then out[#out + 1] = { rest, "VCom" }; break end
    local q = rest:match("^([\"'`])")
    if q then
      local close = rest:find(q, 2, true)
      local stop = close or #rest
      out[#out + 1] = { rest:sub(1, stop), "VStr" }
      i = i + stop
    elseif rest:match("^%d") then
      local num = rest:match("^[%d%.xXa-fA-F_]+")
      out[#out + 1] = { num, "VNum" }
      i = i + #num
    elseif rest:match("^[%a_]") then
      local word = rest:match("^[%w_]+")
      local after = rest:sub(#word + 1, #word + 1)
      local group = KW[word] or (after == "(" and "VFn") or (word:match("^%u%l") and "VTy")
        or (after == "!" and "VFn") or "VVar"
      out[#out + 1] = { word, group }
      i = i + #word
    else
      local sym = rest:match("^[^%w_\"'`%d]+") or rest:sub(1, 1)
      local cut = sym:find(comment) or (#sym + 1)
      sym = sym:sub(1, math.max(cut - 1, 1))
      out[#out + 1] = { sym, "VCode" }
      i = i + #sym
    end
  end
  return out
end

-- Markdown in the chat view: VS Code's rendering, with code in a widget.
local function spans_of(spans, base_group)
  local out = {}
  for _, s in ipairs(spans or {}) do
    if s.code then out[#out + 1] = { s.text, "VInline" }
    elseif s.link then out[#out + 1] = { s.text, "MdLink" }
    elseif s.bold then out[#out + 1] = { s.text, "MdBold" }
    elseif s.italic then out[#out + 1] = { s.text, "MdItalic" }
    else out[#out + 1] = { s.text, base_group } end
  end
  return out
end

local IND = "  "
local function markdown(text, width)
  local out = {}
  for _, b in ipairs(bone.markdown.parse(text)) do
    if b.kind == "blank" then
      if #out > 0 then out[#out + 1] = {} end
    elseif b.kind == "heading" then
      append(out, bone.text.wrap(spans_of(b.spans, "MdHeading"), width, { first = IND, rest = IND }))
    elseif b.kind == "code" then
      local lang = (b.lang or ""):lower()
      out[#out + 1] = { { IND, "Normal" }, { " " .. (lang ~= "" and lang or "text"), "VCodeHead" },
                        { fill = " ", hl = "VCodeHead" }, { "⧉  ", "VCodeHead" } }
      local numw = #tostring(#b.lines)
      for k, l in ipairs(b.lines) do
        local row = { { IND, "Normal" }, { " " .. string.rep(" ", numw - #tostring(k)) .. k .. "  ", "VCodeNum" } }
        append(row, bone.text.clip(highlight(l, lang), width - #IND - numw - 4))
        row[#row + 1] = { fill = " ", hl = "VCode" }
        out[#out + 1] = row
      end
    elseif b.kind == "quote" then
      append(out, bone.text.wrap(spans_of(b.spans, "MdQuote"), width, {
        first = { { IND, "Normal" }, { "▌ ", "VToolTxt" } }, rest = { { IND, "Normal" }, { "▌ ", "VToolTxt" } } }))
    elseif b.kind == "item" then
      local lead = IND .. string.rep(" ", b.indent or 0)
      local bullet = b.ordered and (b.marker .. " ") or "• "
      append(out, bone.text.wrap(spans_of(b.spans, "Normal"), width, {
        first = { { lead, "Normal" }, { bullet, "MdBullet" } }, rest = lead .. string.rep(" ", bone.text.width(bullet)) }))
    elseif b.kind == "rule" then
      out[#out + 1] = { { IND, "Normal" }, { string.rep("─", math.max(width - 4, 1)), "ToolGutter" } }
    elseif b.kind == "table" then
      local rows = {}
      for r, row in ipairs(b.rows) do
        local cells = {}
        for _, cell in ipairs(row) do
          local t = {}
          for _, s in ipairs(cell) do t[#t + 1] = s.text end
          cells[#cells + 1] = table.concat(t)
        end
        rows[r] = cells
      end
      local w = {}
      for _, row in ipairs(rows) do for k, v in ipairs(row) do w[k] = math.max(w[k] or 0, bone.text.width(v)) end end
      for r, row in ipairs(rows) do
        local line = { { IND, "Normal" } }
        for k, v in ipairs(row) do
          line[#line + 1] = { "│ ", "ToolGutter" }
          line[#line + 1] = { v .. string.rep(" ", (w[k] or 0) - bone.text.width(v)) .. " ", (b.header and r == 1) and "MdTableHeader" or "Normal" }
        end
        line[#line + 1] = { "│", "ToolGutter" }
        out[#out + 1] = line
        if b.header and r == 1 then
          local sep = { { IND, "Normal" } }
          for k = 1, #row do sep[#sep + 1] = { (k == 1 and "├" or "┼") .. string.rep("─", (w[k] or 0) + 2), "ToolGutter" } end
          sep[#sep + 1] = { "┤", "ToolGutter" }
          out[#out + 1] = sep
        end
      end
    else
      append(out, bone.text.wrap(spans_of(b.spans, "Normal"), width, { first = IND .. string.rep(" ", b.indent or 0), rest = IND }))
    end
  end
  while #out > 0 and next(out[#out]) == nil do out[#out] = nil end
  return out
end

-- ---- the chat view -----------------------------------------------------------

local views = bone.ui.views
local USER = os.getenv("USER") or "you"

views.user = function(item, ctx)
  local out = { {} }
  out[#out + 1] = { { " " .. USER:sub(1, 1):upper() .. " ", "VAvatarYou" }, { " " .. USER, "VName" } }
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "VUserBand" } }, ctx.width - 1, {
      first = { { IND, "Normal" }, { " ", "VUserBand" } }, rest = { { IND, "Normal" }, { " ", "VUserBand" } }, pad = "VUserBand" }))
  end
  for _, img in ipairs(item.images or {}) do
    out[#out + 1] = { { IND, "Normal" }, { "🖼 " .. tostring(type(img) == "table" and (img.name or img.id) or img), "VToolFile" } }
  end
  return out
end

-- The first reply after a request (or after tool lines) carries the bot row.
-- Finished reasoning is hidden unless show_reasoning is on.
local function shown_reasoning(r)
  return bone.o.show_reasoning or r.streaming
end

local function needs_header(item)
  local i = item.index - 1
  local before = bone.chat.item(i)
  while before and before.kind == "reasoning" and not shown_reasoning(before) do
    i = i - 1
    before = bone.chat.item(i)
  end
  return not before or before.kind == "user" or before.kind == "notice"
end

local function bot_row()
  return { { " ◈ ", "VAvatarBot" }, { " bone", "VName" }, { "  " .. (model_name() or ""), "VModel" } }
end

views.assistant = function(item, ctx)
  local text = trim(item.text)
  if text == "" and not item.streaming then return nil end
  local out = { {} }
  if needs_header(item) then out[#out + 1] = bot_row() end
  if text == "" then
    out[#out + 1] = { { IND .. (ctx.spinner or "◐") .. " Working…", "VToolTxt" } }
    return out
  end
  append(out, markdown(text, ctx.width - 1))
  if item.streaming then
    local last = out[#out]
    last[#last + 1] = { " ▋", "Accent" }
  end
  return out
end

views.reasoning = function(item, ctx)
  local text = trim(item.text)
  if text == "" or not shown_reasoning(item) then return nil end
  local out = { {} }
  if needs_header(item) then out[#out + 1] = bot_row() end
  if not bone.o.show_reasoning then
    out[#out + 1] = { { IND .. (ctx.spinner or "◐") .. " Thinking…", "VToolTxt" } }
    return out
  end
  out[#out + 1] = { { IND .. "⌄ Thinking", "VToolTxt" } }
  for _, l in ipairs(split_lines(text)) do
    append(out, bone.text.wrap({ { l, "Reasoning" } }, ctx.width, { first = IND .. "│ ", rest = IND .. "│ " }))
  end
  return out
end

views.notice = function(item, ctx)
  local out = { {} }
  local icon = item.error and { IND .. "⊗ ", "ErrorMsg" } or { IND .. "ⓘ ", "Notice" }
  for i, l in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { l, item.error and "ErrorMsg" or "ToolArgs" } }, ctx.width, {
      first = { i == 1 and icon or { IND .. "  ", "Normal" } }, rest = IND .. "  " }))
  end
  return out
end

views.queued = function(item, ctx)
  local out = { {} }
  append(out, bone.text.wrap({ { trim(item.text), "ToolArgs" } }, ctx.width, {
    first = { { IND .. "⏱ queued · ", "VModel" } }, rest = IND .. "  " }))
  return out
end

-- Tool lines in Copilot Chat's voice.
local function describe(t)
  local a = args_of(t)
  if t.name == "shell" then
    return { { "Ran terminal command ", "VToolTxt" }, { " " .. (a.command or ""):gsub("%s+", " ") .. " ", "VInline" } }
  elseif t.name == "read_file" then
    local where = ""
    if a.offset or a.limit then
      local from = tonumber(a.offset) or 1
      where = a.limit and (", lines " .. from .. " to " .. (from + tonumber(a.limit) - 1)) or (", from line " .. from)
    end
    return { { "Read ", "VToolTxt" }, { base(a.path), "VToolFile" }, { where, "VToolTxt" } }
  elseif t.name == "edit_file" then
    local edits = type(a.edits) == "table" and a.edits or (type(a.old_string) == "string" and { a } or {})
    local add, del = 0, 0
    for _, e in ipairs(edits) do
      del = del + #split_lines(e.old_string or "")
      add = add + #split_lines(e.new_string or "")
    end
    return { { "Edited ", "VToolTxt" }, { base(a.path), "VToolFile" }, { "  +" .. add, "DiffAdd" }, { " -" .. del, "DiffDelete" } }
  elseif t.name == "write_file" then
    return { { "Created ", "VToolTxt" }, { base(a.path), "VToolFile" } }
  elseif t.name == "subagent" then
    return { { "Delegated to ", "VToolTxt" }, { a.name or "agent", "VToolFile" }, { "  " .. (a.task or ""):gsub("%s+", " "), "VToolTxt" } }
  end
  local target = a.path or a.query or a.url or a.pattern
  return { { "Used ", "VToolTxt" }, { t.name, "VToolFile" }, { target and ("  " .. rel(target)) or "", "VToolTxt" } }
end

local function first_tool(item)
  local i = item.index - 1
  local before = bone.chat.item(i)
  while before and before.kind == "reasoning" do i = i - 1; before = bone.chat.item(i) end
  return not (before and before.kind == "tool")
end

views.tool = function(item, ctx)
  local first = first_tool(item)
  local out = first and { {} } or {}
  if first and needs_header(item) then out[#out + 1] = bot_row() end
  local detail = bone.o.tool_detail
  if detail == "summary" and not failed(item) then
    if not first then return nil end
    local n, running, bad = 0, false, 0
    for _, t in ipairs(bone.chat.items({ around = item.index, from = item.index, kind = { "tool", "reasoning" }, full = true })) do
      if t.kind == "tool" then
        n = n + 1
        running = running or not t.done
        if failed(t) then bad = bad + 1 end
      end
    end
    if running then bone.chat.refresh_in(200) end
    out[#out + 1] = { { IND .. (running and ((ctx.spinner or "◐") .. " ") or "› "), running and "Accent" or "VToolTxt" },
                      { "Used " .. n .. (n == 1 and " tool" or " tools"), "VToolTxt" },
                      { bad > 0 and ("  " .. bad .. " failed") or "", "ErrorMsg" } }
    return out
  end
  local mark
  if not item.done then
    bone.chat.refresh_in(200)
    mark = { IND .. (ctx.spinner or "◐") .. " ", "Accent" }
  elseif failed(item) then
    mark = { IND .. "✕ ", "ErrorMsg" }
  else
    mark = { IND .. "✓ ", "VToolOk" }
  end
  local row = { mark }
  append(row, describe(item))
  out[#out + 1] = bone.text.clip(row, ctx.width)
  if failed(item) or detail == "full" then
    local text = (item.output or item.live or ""):gsub("\n?%[exit code: %-?%d+%]%s*$", "")
    local lines = split_lines(trim(text))
    local max = detail == "full" and 14 or 4
    out[#out + 1] = { { IND .. "  ┌", "ToolGutter" }, { fill = "─", hl = "ToolGutter" } }
    for i = 1, math.min(#lines, max) do
      out[#out + 1] = { { IND .. "  │ ", "ToolGutter" }, { bone.text.truncate(lines[i], ctx.width - 8), failed(item) and "ErrorMsg" or "ToolOutput" } }
    end
    if #lines > max then out[#out + 1] = { { IND .. "  │ ", "ToolGutter" }, { "… " .. (#lines - max) .. " more lines (ctrl+t)", "VModel" } } end
    out[#out + 1] = { { IND .. "  └", "ToolGutter" }, { fill = "─", hl = "ToolGutter" } }
  end
  return out
end

-- ---- workspace data (cached per chat state) -----------------------------------

local ws = { key = nil }
local function workspace()
  local s = bone.chat.session() or {}
  local key = tostring(s.session_id) .. ":" .. tostring(s.items) .. ":" .. tostring(s.running)
  if ws.key == key then return ws end
  ws = { key = key, files = {}, order = {}, problems = {}, last_out = nil, last_shell = nil, turns = {} }
  local tools = bone.chat.items({ kind = "tool", full = true })
  for _, t in ipairs(tools) do
    local a = args_of(t)
    if type(a.path) == "string" and (t.name == "read_file" or t.name == "edit_file" or t.name == "write_file") then
      local p = rel(a.path)
      local mark = t.name == "edit_file" and "M" or t.name == "write_file" and "U" or ""
      local f = ws.files[p]
      if not f then
        f = { path = p, mark = mark }
        ws.files[p] = f
        ws.order[#ws.order + 1] = p
      elseif mark == "M" or (mark == "U" and f.mark == "") then
        f.mark = mark
      end
    end
    if failed(t) then ws.problems[#ws.problems + 1] = t end
  end
  ws.last = tools[#tools]
  for i = #tools, 1, -1 do
    if tools[i].name == "shell" then ws.last_shell = tools[i]; break end
  end
  for _, turn in ipairs(bone.chat.turns()) do ws.turns[#ws.turns + 1] = turn end
  return ws
end

local function full_item(t)
  return t and bone.chat.item(t.index, { full = true }) or nil
end

-- ---- chrome: title bar, activity bar, explorer, tabs ---------------------------

bone.ui.regions.titlebar = {
  size = 1,
  render = function(ctx)
    local center = " ⌕ " .. bone.text.truncate(base(cwd()) .. " — " .. title_of(), math.min(56, ctx.width - 50)) .. " "
    local left = { { " ◈  ", "VActBar" }, { "File  Edit  Selection  View  Go  Run  Terminal  Help", "VTitleMenu" } }
    local lw = 4 + 52
    local cw = bone.text.width(center)
    local gap = math.max(math.floor((ctx.width - cw) / 2) - lw, 1)
    if lw + cw + 12 > ctx.width then left = { { " ◈  ", "VActBar" } }; gap = math.max(math.floor((ctx.width - cw) / 2) - 4, 1) end
    local line = left
    line[#line + 1] = { string.rep(" ", gap), "VTitle" }
    line[#line + 1] = { center, "VCenterText" }
    line[#line + 1] = { fill = " ", hl = "VTitle" }
    line[#line + 1] = { "─  □  ✕  ", "VTitle" }
    return { line }
  end,
}

local ACTIVITY = {
  { icon = "⎘", tip = "explorer", run = function() explorer_on = not explorer_on; apply_layout() end },
  { icon = "⌕", tip = "sessions", run = function() bone.cmd("sessions") end },
  { icon = "⑂", tip = "diff", run = function() if bone.cmd.find("diff") then bone.cmd("diff") end end },
  { icon = "▷", tip = "panel", run = function() panel_on = not panel_on; apply_layout() end },
  { icon = "✚", tip = "new chat", run = function() bone.action("new_session") end },
}

bone.ui.regions.activity = {
  size = 3,
  render = function(ctx)
    local L = {}
    for i, a in ipairs(ACTIVITY) do
      local on = (i == 1 and explorer_on) or (i == 4 and panel_on)
      L[#L + 1] = { { on and "▌" or " ", "VActBar" }, { a.icon, on and "VActOn" or "VAct" }, { " ", "VAct" } }
      L[#L + 1] = { { "   ", "VAct" } }
    end
    while #L < ctx.height - 2 do L[#L + 1] = { { "   ", "VAct" } } end
    L[#L + 1] = { { " ◉ ", "VAct" } }
    L[#L + 1] = { { " ⚙ ", "VAct" } }
    return L
  end,
}

local function file_icon(name)
  local ext = name:match("%.([%w]+)$") or ""
  local map = { rs = { "◆", "VIconRs" }, lua = { "☾", "VIconLua" }, md = { "M", "VIconMd" }, ts = { "T", "VIconTs" },
    js = { "J", "VIconCfg" }, py = { "P", "VIconLua" }, toml = { "⚙", "VIconCfg" }, json = { "{", "VIconCfg" },
    yaml = { "⚙", "VIconCfg" }, sh = { "$", "VIconMd" } }
  return map[ext] or { "≡", "VIconAny" }
end

local outline_hits = {}
local tabs_hits = {}

-- Files as a tree, folders with a single child folded together as VS Code does.
local function tree_rows(paths, width, out)
  local root = { dirs = {}, files = {}, order = {} }
  for _, p in ipairs(paths) do
    local node = root
    local parts = {}
    for part in p:gmatch("[^/]+") do parts[#parts + 1] = part end
    for k = 1, #parts - 1 do
      local d = parts[k]
      if not node.dirs[d] then node.dirs[d] = { dirs = {}, files = {}, order = {} }; node.order[#node.order + 1] = d end
      node = node.dirs[d]
    end
    node.files[#node.files + 1] = p
  end
  local function walk(node, depth)
    table.sort(node.order)
    for _, d in ipairs(node.order) do
      local child, name = node.dirs[d], d
      while #child.order == 1 and #child.files == 0 do
        name = name .. "/" .. child.order[1]
        child = child.dirs[child.order[1]]
      end
      out[#out + 1] = { { string.rep("  ", depth) .. " ⌄ ", "VSideDim" }, { bone.text.truncate(name, width - depth * 2 - 4), "VFolder" }, { fill = " ", hl = "VSide" } }
      walk(child, depth + 1)
    end
    table.sort(node.files)
    for _, p in ipairs(node.files) do
      local f = ws.files[p]
      local icon = file_icon(base(p))
      local group = f.mark == "M" and "VFileMod" or f.mark == "U" and "VFileNew" or "VFileRead"
      out[#out + 1] = { { string.rep("  ", depth) .. "   ", "VSide" }, { icon[1] .. " ", icon[2] },
                        { bone.text.truncate(base(p), width - depth * 2 - 8), group }, { fill = " ", hl = "VSide" },
                        { f.mark ~= "" and (f.mark .. " ") or "", group } }
    end
  end
  walk(root, 0)
end

bone.ui.regions.explorer = {
  size = 32,
  render = function(ctx)
    local w = ctx.width
    local L = {}
    local function line(spans) spans[#spans + 1] = { fill = " ", hl = "VSide" }; L[#L + 1] = spans; return #L end
    local data = workspace()
    line({ { "  EXPLORER", "VSideDim" }, { fill = " ", hl = "VSide" }, { "···  ", "VSideDim" } })
    line({ { "⌄ ", "VSideDim" }, { "OPEN EDITORS", "VSideHead" } })
    local on_screen = (bone.chat.session() or {}).session_id
    for _, s in ipairs(bone.chat.sessions()) do
      local current = s.current or (s.session_id and s.session_id == on_screen)
      local t = (not s.new and s.title and trim(s.title) ~= "") and trim(s.title) or "New Chat"
      line({ { s.running and ("   " .. (ctx.spinner or "◐") .. " ") or "   ◈ ", s.running and "VFileNew" or "VIconTs" },
             { bone.text.truncate(t, w - 8), current and "VSideHead" or "VSide" } })
    end
    line({ { "⌄ ", "VSideDim" }, { base(cwd()):upper(), "VSideHead" } })
    if #data.order == 0 then
      line({ { "   No files touched yet.", "VSideDim" } })
    else
      local rows = {}
      tree_rows(data.order, w, rows)
      for _, r in ipairs(rows) do L[#L + 1] = r end
    end
    line({ { "⌄ ", "VSideDim" }, { "OUTLINE", "VSideHead" } })
    outline_hits = {}
    if #data.turns == 0 then line({ { "   No symbols.", "VSideDim" } }) end
    for k, turn in ipairs(data.turns) do
      local icon = turn.running and { "   " .. (ctx.spinner or "◐") .. " ", "VFileNew" }
        or ((turn.tool_errors or 0) > 0 or turn.outcome == "failed") and { "   ⊗ ", "VPanelErr" } or { "   ◇ ", "VIconMd" }
      local n = line({ icon, { bone.text.truncate(((turn.text or ""):gsub("%s+", " ")), w - 12), "VSide" },
                       { fill = " ", hl = "VSide" }, { (turn.tools or 0) > 0 and (turn.tools .. " ") or "", "VSideDim" } })
      outline_hits[n] = turn.first or turn.index
      if #L >= ctx.height - 1 then break end
    end
    while #L < ctx.height do L[#L + 1] = { { fill = " ", hl = "VSide" } } end
    return L
  end,
}

bone.ui.regions.tabs = {
  size = 1,
  render = function(ctx)
    local line, x = {}, 0
    tabs_hits = {}
    local on_screen = (bone.chat.session() or {}).session_id
    for _, s in ipairs(bone.chat.sessions()) do
      local current = s.current or (s.session_id and s.session_id == on_screen) or (s.new and not on_screen)
      local t = (not s.new and s.title and trim(s.title) ~= "") and trim(s.title) or "New Chat"
      local label = " ◈ " .. bone.text.truncate(t, 22) .. (s.running and "  ●" or "  ×") .. " "
      local wdt = bone.text.width(label)
      if x + wdt > ctx.width then break end
      line[#line + 1] = { label, current and "VTabOn" or "VTabOff" }
      line[#line + 1] = { "│", "VTabBar" }
      tabs_hits[#tabs_hits + 1] = { from = x + 1, to = x + wdt, id = s.session_id }
      x = x + wdt + 1
    end
    line[#line + 1] = { fill = " ", hl = "VTabBar" }
    return { line }
  end,
}

bone.ui.regions.crumbs = {
  size = 1,
  render = function()
    local turns = (bone.chat.session() or {}).turns or 0
    local line = { { "  " .. base(cwd()), "VCrumb" }, { " › ", "VCrumbSep" }, { "chats", "VCrumb" }, { " › ", "VCrumbSep" },
                   { "◈ ", "VIconTs" }, { title_of(), "VCrumb" } }
    if turns > 0 then
      line[#line + 1] = { " › ", "VCrumbSep" }
      line[#line + 1] = { "◇ turn " .. turns, "VCrumb" }
    end
    return { line }
  end,
}

-- ---- bottom panel ------------------------------------------------------------

local PANEL_TABS = { { "problems", "PROBLEMS" }, { "output", "OUTPUT" }, { "terminal", "TERMINAL" } }
local panel_tab_hits = {}

bone.ui.regions.bottompanel = {
  size = 10,
  render = function(ctx)
    local data = workspace()
    local L = { { { " ", "Normal" } } }
    local head, x = { { "  ", "Normal" } }, 2
    local under = { { "  ", "Normal" } }
    panel_tab_hits = {}
    for _, t in ipairs(PANEL_TABS) do
      local label = t[2]
      if t[1] == "problems" and #data.problems > 0 then label = label .. "  " .. #data.problems end
      local on = panel_tab == t[1]
      head[#head + 1] = { label, on and "VPanelTabOn" or "VPanelTab" }
      head[#head + 1] = { "    ", "Normal" }
      under[#under + 1] = { string.rep(on and "─" or " ", bone.text.width(label)), "VPanelTabLine" }
      under[#under + 1] = { "    ", "Normal" }
      panel_tab_hits[#panel_tab_hits + 1] = { from = x + 1, to = x + bone.text.width(label), tab = t[1] }
      x = x + bone.text.width(label) + 4
    end
    head[#head + 1] = { fill = " ", hl = "Normal" }
    head[#head + 1] = { "⌃  ✕  ", "VPanelTab" }
    L[1] = head
    L[2] = under
    local body = {}
    if panel_tab == "problems" then
      if #data.problems == 0 then body[1] = { { "  No problems have been detected in the workspace.", "Dim" } } end
      for _, t in ipairs(data.problems) do
        local f = full_item(t) or t
        local msg
        if t.name == "shell" and exit_code(f.output) then
          msg = "exited with code " .. exit_code(f.output) .. "  ·  " .. (args_of(f).command or ""):gsub("%s+", " ")
        else
          msg = trim((f.output or ""):gsub("\n?%[exit code: %-?%d+%]%s*$", "")):match("[^\n]*$") or ""
        end
        body[#body + 1] = { { "  ⊗ ", "VPanelErr" }, { (t.name or "tool") .. "  ", "Normal" },
                            { bone.text.truncate(msg, ctx.width - 20), "Dim" } }
      end
    elseif panel_tab == "output" then
      local f = full_item(data.last)
      if not f then body[1] = { { "  No output yet.", "Dim" } }
      else
        body[1] = { { "  [" .. (f.name or "tool") .. "] ", "VModel" }, { secs(f.duration_ms), "VModel" } }
        for _, l in ipairs(split_lines(trim(f.output or f.live or ""))) do body[#body + 1] = { { "  " .. l, "ToolOutput" } } end
      end
    else
      local f = full_item(data.last_shell)
      local prompt = { { "  " .. USER .. "@bone ", "VFileNew" }, { base(cwd()), "VToolFile" }, { " $ ", "Normal" } }
      if f then
        local row = { unpack(prompt) }
        append(row, bone.text.shell(args_of(f).command or ""))
        body[1] = row
        local text = (f.output or f.live or ""):gsub("\n?%[exit code: %-?%d+%]%s*$", "")
        for _, l in ipairs(split_lines(trim(text))) do body[#body + 1] = { { "  " .. l, "Normal" } } end
      end
      local last = { unpack(prompt) }
      last[#last + 1] = { "▋", "Normal" }
      body[#body + 1] = last
    end
    local room = ctx.height - 2
    local from = math.max(1, #body - room + 1)
    for i = from, #body do L[#L + 1] = bone.text.clip(body[i], ctx.width) end
    return L
  end,
}

-- ---- prompt and status bar --------------------------------------------------------

bone.ui.prompt = {
  prefix = { { " ", "InputText" } },
  placeholder = { { "Ask bone, or type / for commands", "Placeholder" } },
  border = { style = "rounded", hl = "VInputBorder" },
  background = "InputBackground",
  padding = { rows = 0, cols = 0 },
  min = 2,
  max = 8,
  bottom = function(ctx)
    return { { "─ ", "VInputBorder" }, { " @ Add Context ", "VInputChip" }, { " ", "VInputBorder" },
             { " ◈ " .. (model_name() or "model") .. " ⌄ ", "VInputChip" }, { fill = "─", hl = "VInputBorder" },
             { ctx.running and (" ■ " .. secs(ctx.elapsed and ctx.elapsed * 1000 or 0) .. " ") or " ▷ ", ctx.running and "VInputChip" or "VInputChip" },
             { "─", "VInputBorder" } }
  end,
}

bone.on("focus/changed", function(ev)
  local focused = not ev.popup and not ev.panel
  bone.hl.set("VInputBorder", { fg = focused and c.blue or c.border, bg = c.editor })
end)

bone.ui.prompt_highlight = function(ctx)
  local s, e = ctx.text:find("^/%S+")
  local hls = {}
  if s then hls[#hls + 1] = { row = 0, from = s - 1, to = e, hl = "Accent" } end
  for a, b in ctx.text:gmatch("()@%w+()") do hls[#hls + 1] = { row = 0, from = a - 1, to = b - 1, hl = "Accent" } end
  return { highlights = hls }
end

local git = { branch = nil, dirty = 0 }
local function refresh_git()
  bone.system("git rev-parse --abbrev-ref HEAD", { cwd = cwd(), timeout = 2000 }, function(r)
    git.branch = r and r.code == 0 and trim(r.stdout) or nil
  end)
  bone.system("git status --porcelain", { cwd = cwd(), timeout = 2000 }, function(r)
    local n = 0
    if r and r.code == 0 then for _ in r.stdout:gmatch("[^\n]+") do n = n + 1 end end
    git.dirty = n
  end)
end

bone.ui.statusline = function(ctx)
  local data = workspace()
  local s = bone.chat.session() or {}
  local line = { { " ⟩⟨ ", "VStatusRemote" }, { " ", "VStatus" } }
  if git.branch then line[#line + 1] = { "⑂ " .. git.branch .. (git.dirty > 0 and "*" or "") .. "   ", "VStatus" } end
  line[#line + 1] = { "⊗ " .. #data.problems .. "  ⚠ 0   ", "VStatus" }
  if s.running then
    line[#line + 1] = { (ctx.spinner or "◐") .. " bone: working " .. secs(s.turn and s.turn.elapsed_ms or 0), "VStatus" }
  end
  line[#line + 1] = { fill = " ", hl = "VStatus" }
  local cur = bone.prompt.cursor()
  line[#line + 1] = { "Ln " .. (cur.row + 1) .. ", Col " .. (cur.col + 1) .. "   ", "VStatus" }
  local last = bone.chat.items({ kind = "assistant", last = 1 })[1]
  if last and last.usage then line[#line + 1] = { tokens(last.usage.input) .. " ctx   ", "VStatus" } end
  line[#line + 1] = { "UTF-8   { } Markdown   ", "VStatus" }
  line[#line + 1] = { "◈ " .. (model_name() or "no model") .. "  ", "VStatus" }
  line[#line + 1] = { (ctx.popup and (ctx.popup .. "  ") or "") .. "🔔 ", "VStatus" }
  return line
end

bone.ui.title = function() return title_of() .. " — bone — Visual Studio Code" end

bone.ui.suggestions = function(ctx)
  local lines = {}
  for i, it in ipairs(ctx.items) do
    local sel = i == ctx.selected
    local bg = sel and "VSideSel" or "VSide"
    lines[i] = { { sel and " ▸ " or "   ", bg }, { "/" .. it.name, sel and "VTabOn" or "VToolFile" },
                 { "  " .. (it.desc or ""), bg }, { fill = " ", hl = bg } }
  end
  return lines
end

bone.ui.regions.chat_empty = {
  render = function()
    local s = bone.chat.session()
    if bone.api.session() or (s and (s.items or 0) > 0) then return {} end
    return {
      { { "◈", "VIconTs" } },
      {},
      { { "Ask bone", "VName" } },
      { { "bone is powered by " .. (model_name() or "your model") .. ". Review its changes before you ship.", "Dim" } },
      {},
      { { "Show All Commands    ", "Dim" }, { " F1     ", "VInline" } },
      { { "Go to Session        ", "Dim" }, { " Ctrl+P ", "VInline" } },
      { { "Toggle Side Bar      ", "Dim" }, { " Ctrl+B ", "VInline" } },
      { { "Toggle Panel         ", "Dim" }, { " Alt+J  ", "VInline" } },
      { { "New Chat             ", "Dim" }, { " Ctrl+N ", "VInline" } },
    }
  end,
}

apply_layout = function()
  local editor = { "tabs", "crumbs", "chat" }
  if panel_on then editor[#editor + 1] = "bottompanel" end
  editor[#editor + 1] = "above_prompt"
  editor[#editor + 1] = "prompt"
  local cols = { { "activity", size = 3 } }
  if explorer_on then cols[#cols + 1] = { "explorer", size = 32 } end
  cols[#cols + 1] = { rows = editor }
  bone.ui.layout = { "titlebar", { cols = cols, sep = "│" }, "statusline" }
end
apply_layout()

-- Clicks: activity icons, outline entries, editor tabs, panel tabs.
bone.on("mouse", function(ev)
  if ev.action ~= "down" or ev.button ~= "left" then return end
  if ev.region == "activity" then
    local a = ACTIVITY[math.floor(((ev.row or 1) + 1) / 2)]
    if a and (ev.row or 1) % 2 == 1 then a.run(); return true end
  elseif ev.region == "explorer" then
    local idx = outline_hits[ev.row or 0]
    if idx then bone.chat.scroll_to(idx, "top"); return true end
  elseif ev.region == "tabs" then
    for _, h in ipairs(tabs_hits) do
      if (ev.col or 0) >= h.from and (ev.col or 0) <= h.to and h.id then bone.api.open_session(h.id); return true end
    end
  elseif ev.region == "bottompanel" and (ev.row or 0) <= 2 then
    for _, h in ipairs(panel_tab_hits) do
      if (ev.col or 0) >= h.from and (ev.col or 0) <= h.to then panel_tab = h.tab; return true end
    end
  elseif ev.region == "titlebar" then
    bone.cmd("sessions")
    return true
  end
end)

-- ---- stock behaviour ---------------------------------------------------------

function bone.ui.help(topic)
  local help = require("bone.help")
  return topic and topic:match("%S") and help.topic(topic) or help.open()
end
function bone.ui.sessions()
  return require("bone.ui.sessions").open()
end
function bone.ui.health()
  local mark = { ok = { "  ✓ ", "VToolOk" }, warn = { "  ⚠ ", "WarningMsg" }, error = { "  ⊗ ", "ErrorMsg" } }
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
  section(lines, "TUI", tui)
  local pager = bone.ui.pager(lines, { title = "Health" })
  bone.request("health/check", {}, function(core, err)
    local all = {}
    section(all, "TUI", tui)
    section(all, "Core", err and { { name = "core", status = "error", message = err } } or core)
    pager:set(all)
  end)
end

bone.on("chat/shown", refresh_git)
bone.on("turn/finished", refresh_git)
bone.on("ready", function()
  refresh_git()
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
