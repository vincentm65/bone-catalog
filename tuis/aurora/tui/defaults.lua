-- Aurora: a self-contained, bare-first TUI library.
-- This file intentionally does not load bone.ui.setup() or any stock view.
-- Everything visible here belongs to this library.

bone.ui.clear()
bone.colorscheme("black")

-- A deep blue canvas with lavender, mint and coral accents.
local colors = {
  canvas = "#0b1020",
  panel = "#111a31",
  panel_alt = "#151f3b",
  ink = "#dbe4ff",
  muted = "#8794b8",
  quiet = "#566486",
  lavender = "#b8a1ff",
  mint = "#67e8c4",
  coral = "#ff8fa3",
  gold = "#f6ca7b",
  blue = "#7dcfff",
  line = "#263252",
}

local function hl(name, fg, bg, attrs)
  local spec = { fg = fg, bg = bg }
  for key, value in pairs(attrs or {}) do spec[key] = value end
  bone.hl.set(name, spec)
end

hl("Normal", colors.ink, colors.canvas)
hl("Dim", colors.quiet, colors.canvas)
hl("Accent", colors.lavender, colors.canvas, { bold = true })
hl("TopBar", colors.lavender, colors.canvas, { bold = true })
hl("TopBarDim", colors.muted, colors.canvas)
hl("StatusLine", colors.ink, colors.canvas, { bold = true })
hl("StatusLineDim", colors.quiet, colors.canvas)
hl("WinSeparator", colors.line, colors.canvas)
hl("PromptBorder", colors.lavender, colors.canvas)
hl("PromptEdge", colors.line, colors.canvas)
hl("InputBackground", colors.ink, colors.panel_alt)
hl("InputText", colors.ink, colors.canvas)
hl("PromptMark", colors.mint, colors.canvas, { bold = true })
hl("UserMessage", colors.ink, colors.canvas)
hl("UserRule", colors.mint, colors.canvas)
hl("UserBadge", colors.mint, colors.canvas, { bold = true })
hl("AssistantRule", colors.lavender, colors.canvas)
hl("AssistantBadge", colors.lavender, colors.canvas, { bold = true })
hl("AssistantText", colors.ink, colors.canvas)
hl("Reasoning", colors.quiet, colors.canvas, { italic = true })
hl("ToolName", colors.blue, colors.canvas, { bold = true })
hl("ToolArgs", colors.muted, colors.canvas)
hl("ToolPath", colors.mint, colors.canvas)
hl("ToolSummary", colors.quiet, colors.canvas)
hl("ToolOutput", colors.muted, colors.canvas)
hl("ToolGutter", colors.line, colors.canvas)
hl("ToolRunning", colors.gold, colors.canvas, { bold = true })
hl("ToolError", colors.coral, colors.canvas)
hl("Notice", colors.gold, colors.canvas)
hl("ErrorMsg", colors.coral, colors.canvas)
hl("WarningMsg", colors.gold, colors.canvas)
hl("Selection", colors.ink, colors.panel_alt)
hl("SuggestName", colors.lavender, colors.panel)
hl("SuggestDesc", colors.muted, colors.panel)
hl("SuggestSel", colors.mint, colors.panel_alt, { bold = true })
hl("SuggestSelDesc", colors.ink, colors.panel_alt)
hl("SuggestFill", colors.panel, colors.panel)
hl("SuggestSelFill", colors.panel_alt, colors.panel_alt)
hl("PromptCommand", colors.mint, colors.canvas, { bold = true })
hl("Placeholder", colors.quiet, colors.canvas)
hl("PopupBorder", colors.line, colors.canvas)
hl("PopupTitle", colors.lavender, colors.canvas, { bold = true })
hl("MdHeading", colors.lavender, colors.canvas, { bold = true })
hl("MdBold", colors.ink, colors.canvas, { bold = true })
hl("MdItalic", colors.ink, colors.canvas, { italic = true })
hl("MdCode", colors.mint, colors.canvas)
hl("MdCodeBlock", colors.muted, colors.panel)
hl("MdQuote", colors.muted, colors.canvas, { italic = true })
hl("MdBullet", colors.mint, colors.canvas)
hl("MdLink", colors.blue, colors.canvas, { underline = true })
hl("DiffAdd", colors.mint, "#102b2b")
hl("Success", colors.mint)
hl("DiffDelete", colors.coral, "#321d2c")
hl("ShellProgram", colors.mint, colors.canvas, { bold = true })
hl("ShellPath", colors.blue, colors.canvas)
hl("ShellFlag", colors.lavender, colors.canvas)
hl("ShellString", colors.mint, colors.canvas)
hl("ShellVariable", colors.blue, colors.canvas)
hl("ShellComment", colors.quiet, colors.canvas)
hl("ShellOperator", colors.muted, colors.canvas)

bone.ui.spinner = {
  frames = { "◒", "◓", "◑", "◐" },
  interval = 140,
}

bone.o.define("queue_mode", "next", {
  desc = "what enter does during a turn: steer or next",
  choices = { "steer", "next" },
})
bone.o.define("tool_detail", "summary", {
  desc = "tool calls: summary, rows, full",
  choices = { "summary", "rows", "full" },
  on_change = function() bone.ui.refresh() end,
})
local next_detail = { summary = "rows", rows = "full", full = "summary" }

local function map(keys, context)
  for key, action in pairs(keys) do
    bone.keymap.set(key, action, { context = context })
  end
end

-- The bare keymap, expanded with a few Aurora conveniences.
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
    bone.o.tool_detail = next_detail[bone.o.tool_detail] or "rows"
    bone.settings.set("tui.tool_detail", bone.o.tool_detail)
  end,
  ["ctrl+r"] = function()
    bone.o.apply("show_reasoning!")
    bone.settings.set("tui.show_reasoning", bone.o.show_reasoning)
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

-- Commands remain fully available, but Aurora owns how command entry looks.
require("bone.commands")
require("bone.menu")

local function append(out, rows)
  for _, row in ipairs(rows or {}) do out[#out + 1] = row end
end

local function split_lines(text)
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then out[#out] = nil end
  return out
end

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function wrapped(text, width, first, rest, group)
  local out = {}
  for i, line in ipairs(split_lines(text)) do
    local head = i == 1 and first or rest
    append(out, bone.text.wrap({ { line, group } }, math.max(width - bone.text.width(head[1][1]), 1), {
      first = head,
      rest = rest,
      pad = group,
    }))
  end
  return out
end

-- The transcript is intentionally open: a small colored label and a quiet
-- gutter give each turn shape without painting large rectangles of spaces.
bone.ui.views.user = function(item, ctx)
  local out = {}
  if ctx.prev then out[#out + 1] = {} end
  out[#out + 1] = { { "  ▌ ", "UserRule" }, { "YOU", "UserBadge" } }
  local first = { { "  │ ", "UserRule" } }
  local rest = { { "  │ ", "UserRule" } }
  for _, line in ipairs(split_lines(item.text)) do
    append(out, bone.text.wrap({ { line, "UserMessage" } }, math.max(ctx.width - 4, 1), {
      first = first, rest = rest,
    }))
  end
  return out
end

bone.ui.views.assistant = function(item, ctx)
  local out = {}
  if ctx.prev then out[#out + 1] = {} end
  local mark = item.streaming and (ctx.spinner or "◒") or "✦"
  out[#out + 1] = { { "  " .. mark .. " ", "AssistantRule" }, { "ASSISTANT", "AssistantBadge" } }
  local text = trim(item.text)
  if text == "" then
    out[#out + 1] = { { "    composing…", "Dim" } }
  else
    local md = bone.ui.markdown(text, math.max(ctx.width - 4, 1), "    ")
    append(out, md)
    if item.streaming then out[#out + 1] = { { "    ▍", "AssistantRule" } } end
  end
  return out
end

bone.ui.views.reasoning = function(item, ctx)
  if not bone.o.show_reasoning or trim(item.text) == "" then return nil end
  local out = { {} }
  for _, line in ipairs(split_lines(trim(item.text))) do
    append(out, bone.text.wrap({ { line, "Reasoning" } }, math.max(ctx.width - 4, 1), {
      first = { { "  · ", "Reasoning" } }, rest = { { "    ", "Reasoning" } },
    }))
  end
  return out
end

bone.ui.views.notice = function(item, ctx)
  local group = item.error and "ErrorMsg" or "Notice"
  local out = ctx.prev and { {} } or {}
  append(out, wrapped(item.text, ctx.width, { { "  ! ", group } }, { { "    ", group } }, group))
  return out
end

bone.ui.views.queued = function(item, ctx)
  local out = { {} }
  local mode = item.mode == "steer" and "steer" or "next turn"
  append(out, wrapped(item.text, ctx.width, { { "  ◦ ", "ToolSummary" } }, { { "    ", "ToolSummary" } }, "ToolSummary"))
  out[#out + 1] = { { "    queued for " .. mode, "StatusLineDim" } }
  return out
end

local function tool_args(item)
  if item.arguments and type(item.arguments) == "table" then
    local ok, encoded = pcall(bone.json.encode, item.arguments)
    if ok then return encoded end
  end
  return item.raw_arguments or ""
end

local function tool_output(item)
  return item.output or item.live or ""
end

-- Summary mode is a timeline, not a list of identical tool rows. A contiguous
-- run becomes one readable activity line; ctrl+t still exposes every call.
local function tool_foldable(item)
  return item.name ~= "edit_file" and item.name ~= "subagent"
end

local function tool_arg(item, key)
  local args = type(item.arguments) == "table" and item.arguments or {}
  return type(args[key]) == "string" and trim(args[key]) or nil
end

local function plural(n, word)
  return tostring(n) .. " " .. word .. (n == 1 and "" or "s")
end

local function activity_summary(calls)
  local order, seen = {}, {}
  local function bump(key, phrase, unique)
    local entry = seen[key]
    if not entry then
      entry = { phrase = phrase, n = 0, unique = {} }
      seen[key] = entry
      order[#order + 1] = entry
    end
    if unique then
      if not entry.unique[unique] then
        entry.unique[unique] = true
        entry.n = entry.n + 1
      end
    else
      entry.n = entry.n + 1
    end
  end
  for _, call in ipairs(calls) do
    if call.name == "read_file" then
      bump("read", function(n) return "read " .. plural(n, "file") end, tool_arg(call, "path") or call.id)
    elseif call.name == "write_file" then
      bump("write", function(n) return "wrote " .. plural(n, "file") end, tool_arg(call, "path") or call.id)
    elseif call.name == "shell" then
      bump("shell", function(n) return "ran " .. plural(n, "command") end)
    else
      bump("tool:" .. (call.name or "tool"), function(n)
        return "called " .. (call.name or "tool") .. (n > 1 and " " .. n .. " times" or "")
      end)
    end
  end
  local parts = {}
  for _, entry in ipairs(order) do parts[#parts + 1] = entry.phrase(entry.n) end
  local failed = 0
  local running = false
  for _, call in ipairs(calls) do
    failed = failed + (call.done and call.is_error and 1 or 0)
    running = running or not call.done
  end
  local text = table.concat(parts, ", ")
  text = text:sub(1, 1):upper() .. text:sub(2)
  if failed > 0 then text = text .. " · " .. failed .. " failed" end
  return text, running, failed
end

local function activity_view(item, ctx)
  if not tool_foldable(item) then return false end
  local before = bone.chat.item(item.index - 1)
  while before and before.kind == "reasoning" do
    before = bone.chat.item(before.index - 1)
  end
  if before and before.kind == "tool" and tool_foldable(before) then return nil end
  local calls = {}
  for _, call in ipairs(bone.chat.items({ around = item.index, from = item.index, kind = { "tool", "reasoning" } })) do
    if call.kind == "tool" then
      if not tool_foldable(call) then break end
      calls[#calls + 1] = call
    end
  end
  local text, running, failed = activity_summary(calls)
  local marker = running and (ctx.spinner or "◒") or failed > 0 and "✕" or "◆"
  local marker_hl = running and "ToolRunning" or failed > 0 and "ToolError" or "ToolPath"
  local out = {}
  if ctx.prev then out[#out + 1] = {} end
  out[#out + 1] = {
    { "  " .. marker .. " ", marker_hl },
    { "ACTIVITY", "ToolName" },
    { "  " .. text, "ToolArgs" },
    { "  ·  ctrl+t", "ToolSummary" },
  }
  if running then bone.chat.refresh_in(300) end
  return out
end

bone.ui.views.tool = function(item, ctx)
  if bone.o.tool_detail == "summary" then
    local folded = activity_view(item, ctx)
    if folded ~= false then return folded end
  end
  local out = { {} }
  local state, state_hl
  if not item.done then state, state_hl = (ctx.spinner or "◒") .. " running", "ToolRunning"
  elseif item.is_error then state, state_hl = "✕ failed", "ToolError"
  else state, state_hl = "✓ done", "ToolPath" end
  local args = trim(tool_args(item))
  local title = { { "  " .. state .. " ", state_hl }, { item.name or "tool", "ToolName" } }
  if args ~= "" then title[#title + 1] = { "  " .. bone.text.truncate(args, math.max(ctx.width - 30, 8)), "ToolArgs" } end
  out[#out + 1] = title

  local output = trim(tool_output(item))
  if bone.o.tool_detail ~= "summary" or item.is_error then
    local max_lines = bone.o.tool_detail == "full" and 12 or 4
    local lines = split_lines(output)
    if #lines > max_lines then
      lines = { unpack(lines, 1, max_lines) }
      lines[#lines + 1] = "… " .. (#split_lines(output) - max_lines) .. " more lines · ctrl+t to expand"
    end
    local output_hl = item.is_error and "ToolError" or "ToolOutput"
    for _, line in ipairs(lines) do
      append(out, bone.text.wrap({ { line, output_hl } }, math.max(ctx.width - 10, 1), {
        first = { { "    ├─ ", "ToolGutter" } },
        rest = { { "         ", "ToolGutter" } },
      }))
    end
  end
  return out
end

-- The header is a small dashboard rather than decoration: identity, live state,
-- and the two token measures that matter while working stay visible.
local hud = bone._aurora_hud or { total = { input = 0, output = 0, cached = 0, curr = 0 } }
bone._aurora_hud = hud

local function hud_session_id()
  return (bone.chat.session() or {}).session_id
end

local function load_hud_total(session_id, legacy)
  session_id = session_id or hud_session_id()
  local key = session_id or ""
  hud.total_session = key
  hud.total = { input = 0, output = 0, cached = 0, curr = 0 }
  if key == "" then
    bone.ui.refresh()
    return
  end
  local context = legacy and "input_tokens" or "coalesce(context_tokens, input_tokens)"
  bone.request("store/query", {
    sql = "SELECT coalesce(sum(input_tokens), 0), coalesce(sum(output_tokens), 0), coalesce(sum(cached_tokens), 0), (SELECT " .. context .. " FROM usage WHERE session_id = ?1 AND source = 'turn' ORDER BY rowid DESC LIMIT 1) FROM usage WHERE session_id = ?1",
    params = { session_id },
  }, function(res)
    if hud.total_session ~= key then return end
    local row = res and res.rows and res.rows[1]
    if not row and not legacy then return load_hud_total(session_id, true) end
    if row then
      hud.total = {
        input = tonumber(row[1]) or 0,
        output = tonumber(row[2]) or 0,
        cached = tonumber(row[3]) or 0,
        curr = tonumber(row[4]) or 0,
      }
    end
    bone.ui.refresh()
  end)
end

local function load_hud_model()
  bone.model.list(function(list)
    for _, model in ipairs(list or {}) do
      if model.current then
        hud.provider = model.name
        hud.model = model.model
        break
      end
    end
    bone.ui.refresh()
  end)
end

if hud.events then
  for _, id in ipairs(hud.events) do bone.off(id) end
end
load_hud_model()
load_hud_total()
hud.events = {}
for _, event in ipairs({ "turn/finished", "message/completed", "session/compacted" }) do
  hud.events[#hud.events + 1] = bone.on(event, function(ev)
    if ev.session_id == hud_session_id() then load_hud_total() end
  end)
end
hud.events[#hud.events + 1] = bone.on("settings/changed", function(ev)
  if ev.path == "provider" or tostring(ev.path):match("^providers%.") then
    load_hud_model()
  end
end)

local function hud_tokens(n)
  return n and n > 0 and bone.util.tokens(n) or "—"
end

bone.ui.regions.top = {
  size = 2,
  render = function(ctx)
    local session = bone.chat.session()
    if session and session.running then bone.ui.refresh_in(1000) end
    local id = session and session.session_id
    if (id or "") ~= (hud.total_session or "") then
      load_hud_total(id)
      load_hud_model()
    end
    local title = session and session.title and trim(session.title) or "new conversation"
    title = title:gsub("^%[", ""):gsub("%]$", "")
    local state = session and session.running and ((ctx.spinner or "◒") .. " thinking") or "ready"
    local identity = hud.provider and hud.model and (hud.provider .. " / " .. hud.model)
      or hud.model or "model loading"
    local total = hud.total or {}
    local cache = total.input and total.input > 0
      and string.format("%.0f%%", (total.cached or 0) / total.input * 100) or "—"
    local metrics = "CTX " .. hud_tokens(total.curr) .. "  ·  SPENT " .. hud_tokens((total.input or 0) + (total.output or 0)) .. "  ·  CACHE " .. cache
    return {
      { { "  ✦ AURORA", "TopBar" }, { "  ·  ", "TopBarDim" }, { bone.text.truncate(title, math.max(ctx.width - 34, 8)), "TopBarDim" }, "%=", { state .. "  ", session and session.running and "Accent" or "TopBarDim" } },
      { { "  MODEL  ", "TopBarDim" }, { bone.text.truncate(identity, math.max(ctx.width - bone.text.width(metrics) - 12, 8)), "Accent" }, "%=", { metrics .. "  ", "TopBarDim" } },
    }
  end,
}

bone.ui.regions.welcome = {
  size = "auto",
  max = 7,
  render = function(ctx)
    local chat = bone.chat.session()
    if (chat and chat.items and chat.items > 0) or bone.api.session() then return nil end
    local lead = string.rep(" ", math.max(2, math.floor((ctx.width - 56) / 2)))
    return {
      {},
      { { lead .. "·  AURORA / NEW SPACE", "TopBarDim" } },
      { { lead .. "  A calm place to think, build, and ship.", "Accent" } },
      { { lead .. "  Start with a message, or press / for commands.", "Dim" } },
      {},
      { { lead .. "  ctrl+o sessions   ctrl+t detail   ctrl+r reasoning   F1 help", "Dim" } },
    }
  end,
}

bone.ui.prompt = {
  prefix = { { "  › ", "PromptMark" } },
  continuation = { { "    ", "InputText" } },
  placeholder = { { "Ask anything…  ·  / for commands", "Placeholder" } },
  padding = { rows = 0, cols = 0 },
  min = 1,
  max = 8,
  bottom = function(ctx)
    local note = ctx.running and ((ctx.spinner or "◒") .. " working · esc interrupts") or "enter send · alt+enter new line · ↑ history"
    return { { "  " .. note .. "  ", ctx.running and "Accent" or "StatusLineDim" } }
  end,
}

bone.ui.divider = function()
  return { { fill = "·", hl = "WinSeparator" } }
end

bone.ui.statusline = function(ctx)
  local session = ctx.session
  local running = session and session.running
  local detail = bone.o.tool_detail or "summary"
  local mode = running and ((ctx.spinner or "◒") .. " LIVE") or (session and "IDLE" or "NEW")
  local hint = ctx.popup and ("  " .. ctx.popup) or ("  " .. detail .. " tools · ctrl+t detail")
  return {
    { "  " .. mode, running and "Accent" or "StatusLineDim" },
    "%=",
    { hint .. "  ·  /help  ·  ctrl+o sessions  ", "StatusLineDim" },
  }
end

bone.ui.layout = { "top", "welcome", "chat", "divider", "above_prompt", "prompt", "statusline" }

-- The command palette is a compact two-column card with its own palette. Keep
-- every cell explicit so it never inherits the terminal's stock menu colors.
bone.ui.prompt_highlight = function(ctx)
  local s, e = ctx.text:find("^/%S+")
  return { highlights = s and { { row = 0, from = s - 1, to = e, hl = "PromptCommand" } } or {} }
end

bone.ui.suggestions = function(ctx)
  local name_width = 0
  for _, item in ipairs(ctx.items) do
    name_width = math.max(name_width, bone.text.width("/" .. tostring(item.name or "")))
  end
  name_width = math.min(name_width, math.max(ctx.width - 4, 1))
  local desc_width = math.max(ctx.width - name_width - 4, 0)
  local desc_text_width = math.max(desc_width - 2, 0)
  local lines = {}
  for i, item in ipairs(ctx.items) do
    local selected = i == ctx.selected
    local name_hl = selected and "SuggestSel" or "SuggestName"
    local desc_hl = selected and "SuggestSelDesc" or "SuggestDesc"
    local fill_hl = selected and "SuggestSelFill" or "SuggestFill"
    local name = "/" .. tostring(item.name or "")
    local desc = tostring(item.desc or "")
    name = bone.text.truncate(name, name_width)
    desc = desc_text_width > 0 and bone.text.truncate(desc, desc_text_width) or ""
    local name_pad = string.rep(" ", math.max(0, name_width - bone.text.width(name)))
    local desc_pad = string.rep(" ", math.max(0, desc_text_width - bone.text.width(desc)))
    lines[i] = {
      { selected and "› " or "  ", name_hl },
      { name .. name_pad, name_hl },
      { desc_text_width > 0 and ("  " .. desc .. desc_pad) or "", desc_hl },
      { fill = " ", hl = fill_hl },
    }
  end
  return lines
end

-- Keep the helpful bare-library command behavior without importing its UI.
function bone.ui.help(topic)
  local help = require("bone.help")
  return topic and topic:match("%S") and help.topic(topic) or help.open()
end
function bone.ui.sessions()
  return require("bone.ui.sessions").open()
end

local mark = { ok = { "✓ ", "DiffAdd" }, warn = { "! ", "WarningMsg" }, error = { "✕ ", "ErrorMsg" } }
local function health_section(out, title, items)
  out[#out + 1] = { { title, "Accent" } }
  for _, item in ipairs(items or {}) do
    local m = mark[item.status] or mark.warn
    out[#out + 1] = { { m[1], m[2] }, { item.name .. "  ", "Normal" }, { tostring(item.message), "Dim" } }
  end
  out[#out + 1] = {}
end
function bone.ui.health()
  local tui = bone.api.health()
  for _, item in ipairs(bone._run_health()) do tui[#tui + 1] = item end
  local lines = {}
  health_section(lines, "Aurora TUI", tui)
  lines[#lines + 1] = { { "Core: checking…", "Dim" } }
  local pager = bone.ui.pager(lines, { title = "Health · Aurora" })
  bone.request("health/check", {}, function(core, err)
    local all = {}
    health_section(all, "Aurora TUI", tui)
    health_section(all, "Core", err and { { name = "core", status = "error", message = err } } or core)
    pager:set(all)
  end)
end

-- If a slash command is typed, run it instead of sending it as chat text.
local old_submit = bone.ui.actions.submit
bone.ui.actions.submit = function()
  local text = bone.prompt.get()
  local line = text:match("^%s*/(%S.*)$")
  if line and bone.cmd.find(line:match("^%S+")) then
    bone.prompt.history_add(text)
    bone.prompt.set("")
    bone.cmd(line)
    return true
  end
  return old_submit and old_submit() or false
end

bone.on("ready", function()
  if bone.settings.get("setup.skipped") then return end
  bone.model.list(function(list)
    if list and #list > 0 then return end
    bone.request("health/check", {}, function(items)
      for _, item in ipairs(items or {}) do
        if item.name == "provider" and item.status == "error" then
          require("bone.setup").open({ first_run = true })
          return
        end
      end
    end)
  end)
end)
