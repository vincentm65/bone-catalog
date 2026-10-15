-- Codex App: the standard UI dressed like the Codex desktop app. Surfaces,
-- text and diffs use the app's dark palette; links, code and the accent are
-- bone's own "black" palette.
--
-- Everything that works is the standard UI's (keys, the tray, tool
-- summaries, menus, the statusline). On top:
--
--   * The sidebar (lua/bone/ui/sessions.lua): the standard conversation
--     sidebar drawn like Codex's, open from the start. ctrl+b folds it,
--     ctrl+o moves into it.
--   * A top bar: sidebar toggle, the thread title, the diff pill (/diff),
--     the branch and the terminal toggle (ctrl+]).
--   * A narrow centered thread; your messages in right-aligned bubbles with
--     "Worked for 1m 12s" and a hairline under each.
--   * The composer as a filled card: changes on top, then the text, then
--     + (paste an attachment), Full access, the model (/provider), the
--     reasoning effort (click to cycle) and send / stop. Folder and branch
--     sit under it.
--   * "What will you build?" on an empty thread.

bone.builtin("tui/defaults.lua")

local c = {
  bg = "#181818", side = "#131313", card = "#242424", bubble = "#2d2d2d", active = "#262626", select = "#2d2d2d",
  rule = "#2c2c2e",
  fg = "#ffffff", text = "#e3e4e6", muted = "#b6b6b6", dim = "#8b8b8b", faint = "#6d6d6d",
  accent = "#7aa2f7", path = "#7dcfff", good = "#9ece6a", warn = "#e8a33d", err = "#f7768e",
  add = "#92c374", del = "#da8c7c", add_bg = "#1e2b1d", del_bg = "#341d18",
  send = "#ececec", send_idle = "#4a4a4a", ink = "#181818",
}
bone.ui.codex_colors = { side = c.side, active = c.active, select = c.select, fg = c.text, muted = c.muted,
  dim = c.faint, icon = c.dim, accent = c.accent }

local function hl(name, fg, bg, attrs)
  local spec = { fg = fg, bg = bg or c.bg }
  for k, v in pairs(attrs or {}) do spec[k] = v end
  bone.hl.set(name, spec)
end

hl("Normal", c.text)
hl("Dim", c.dim)
hl("Accent", c.accent)
hl("UserPrompt", c.accent, c.bubble)
hl("UserMessage", c.fg, c.bubble)
hl("Reasoning", c.dim, nil, { italic = true })
hl("ToolName", c.muted)
hl("ToolArgs", c.dim)
hl("ToolPath", c.path)
hl("ToolSummary", c.dim)
hl("ToolOutput", c.dim)
hl("ToolGutter", c.rule)
hl("ToolRunning", c.dim)
hl("ToolError", c.err)
hl("DiffAdd", c.add, c.add_bg)
hl("DiffDelete", c.del, c.del_bg)
hl("ShellProgram", c.good)
hl("ShellPath", c.path)
hl("ShellFlag", c.accent)
hl("ShellString", c.good)
hl("ShellVariable", c.path)
hl("ShellComment", c.faint)
hl("ShellOperator", c.dim)
hl("MdHeading", c.fg, nil, { bold = true })
hl("MdBold", c.fg, nil, { bold = true })
hl("MdItalic", c.text, nil, { italic = true })
hl("MdCode", c.path, c.bubble)
hl("MdCodeBlock", c.muted, c.card)
hl("MdQuote", c.dim, nil, { italic = true })
hl("MdBullet", c.faint)
hl("MdLink", c.accent, nil, { underline = true })
hl("MdTable", c.text)
hl("MdTableHeader", c.fg, nil, { bold = true })
hl("Notice", c.warn)
hl("ErrorMsg", c.err)
hl("WarningMsg", c.warn)
hl("WinSeparator", c.rule)
hl("StatusLine", c.dim)
hl("StatusLineDim", c.faint)
hl("Selection", c.fg, "#2a3350")
hl("Placeholder", c.faint, c.card)
hl("InputBackground", c.fg, c.card)
hl("InputText", c.fg, c.card)
hl("PopupBorder", c.rule, c.card)
hl("PopupTitle", c.fg, c.card, { bold = true })
hl("PanelTitle", c.muted, nil, { bold = true })
hl("PanelTitleFocus", c.fg, nil, { bold = true })

hl("CodexBubble", c.fg, c.bubble)
hl("CodexMuted", c.dim)
hl("CodexRule", c.rule)
hl("CodexHero", c.fg, nil, { bold = true })
hl("CodexChip", c.text, c.card)
hl("CodexTop", c.dim)
hl("CodexTopTitle", c.fg, nil, { bold = true })
hl("CodexPill", c.muted, c.card)
hl("CodexPillAdd", c.add, c.card)
hl("CodexPillDel", c.del, c.card)
hl("Composer", c.fg, c.card)
hl("ComposerDim", c.dim, c.card)
hl("ComposerText", c.muted, c.card)
hl("ComposerWarn", c.warn, c.card)
hl("ComposerAdd", c.add, c.card)
hl("ComposerDel", c.del, c.card)
hl("ComposerSend", c.ink, c.send, { bold = true })
hl("ComposerSendIdle", c.card, c.send_idle, { bold = true })

bone.ui.spinner = { frames = { "◜", "◠", "◝", "◞", "◡", "◟" }, interval = 100 }

local sidebar = require("bone.ui.sessions")
local function toggle_terminal()
  local ok, terminal = pcall(require, "bone.ui.terminal")
  if ok then return terminal.toggle() end
  bone.notify("install and load the term plugin for terminal panels", "error")
end

-- ---- helpers ---------------------------------------------------------------

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_lines(text)
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

local function width_of(items)
  local n = 0
  for _, it in ipairs(items) do n = n + bone.text.width(type(it) == "string" and it or it[1] or "") end
  return n
end

local function secs(ms)
  local s = math.floor((ms or 0) / 1000)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m " .. (s % 60) .. "s" end
  return math.floor(s / 3600) .. "h " .. math.floor(s % 3600 / 60) .. "m"
end

local function cwd()
  local s = bone.chat.session()
  return (s and s.cwd) or os.getenv("PWD") or ""
end

local function folder() return cwd():match("([^/]+)/*$") or "~" end

local function title_of()
  local s = bone.chat.session()
  local t = s and not s.new and s.title and trim(s.title) or ""
  return t ~= "" and t or "New thread"
end

local function has_diff() return bone.cmd.find("diff") ~= nil end

-- Clickable spans: { text, group, fn }. Lays them out from column 1 and
-- records where each fn sits.
local function lay(spans, hits)
  local out, x = {}, 0
  for _, s in ipairs(spans) do
    if s.fill then
      out[#out + 1] = s
    else
      out[#out + 1] = { s[1], s[2] }
      local sw = bone.text.width(s[1])
      if s[3] then hits[#hits + 1] = { from = x + 1, to = x + sw, run = s[3] } end
      x = x + sw
    end
  end
  return out, x
end

local function hit(hits, col)
  for _, h in ipairs(hits) do
    if col >= h.from and col <= h.to then h.run(); return true end
  end
end

-- ---- model and effort ----------------------------------------------------------

local current = {}
local function refresh_model()
  bone.model.list(function(list)
    for _, e in ipairs(list or {}) do
      if e.current then current = { name = e.name, model = e.model } end
    end
  end)
end

local function provider() return current.name or bone.settings.get("provider") end

local function effort()
  local p = provider()
  return p and bone.settings.get("providers." .. p .. ".reasoning_effort") or nil
end

local EFFORTS = { "low", "medium", "high" }
local function cycle_effort()
  local p = provider()
  if not p then return end
  local now, nxt = effort(), EFFORTS[1]
  for i, e in ipairs(EFFORTS) do if e == now then nxt = EFFORTS[i % #EFFORTS + 1] end end
  bone.settings.set("providers." .. p .. ".reasoning_effort", nxt)
end

-- ---- git ---------------------------------------------------------------------

local git = { branch = nil, files = 0, add = 0, del = 0 }

local function refresh_git()
  bone.system([[
    git rev-parse --git-dir >/dev/null 2>&1 || exit 3
    printf 'branch %s\n' "$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)"
    git diff HEAD --shortstat 2>/dev/null || git diff --shortstat
    printf 'untracked %s\n' "$(git ls-files -o --exclude-standard | wc -l)"
  ]], { cwd = cwd(), timeout = 4000 }, function(r)
    git = { branch = nil, files = 0, add = 0, del = 0 }
    if not r or r.code ~= 0 then return end
    local out = r.stdout or ""
    git.branch = out:match("branch (%S+)")
    git.files = (tonumber(out:match("(%d+) files? changed")) or 0) + (tonumber(out:match("untracked (%d+)")) or 0)
    git.add = tonumber(out:match("(%d+) insertion")) or 0
    git.del = tonumber(out:match("(%d+) deletion")) or 0
  end)
end

local function open_diff() if has_diff() then bone.cmd("diff") end end

-- ---- turn timing -------------------------------------------------------------

-- "Worked for 1m 12s" per session and turn number, kept across restarts.
local times = bone.state.load("codex-app-turn-times")
local started = {}

bone.on("turn/started", function(ev)
  if ev.session_id then started[ev.session_id] = bone.now() end
end)
bone.on("turn/finished", function(ev)
  local at = ev.session_id and started[ev.session_id]
  if not at then return end
  started[ev.session_id] = nil
  times[ev.session_id .. ":" .. #bone.chat.turns({ session = ev.session_id })] = bone.now() - at
  bone.state.save("codex-app-turn-times", times)
  bone.chat.redraw()
end)

-- ---- your messages -------------------------------------------------------------

bone.ui.views.user = function(item, ctx)
  local w = ctx.width
  local inner = math.max(10, math.floor(w * 0.72) - 4)
  local rows = {}
  for _, l in ipairs(split_lines(trim(item.text))) do
    if l == "" then rows[#rows + 1] = {} end
    for _, r in ipairs(bone.text.wrap({ { l, "CodexBubble" } }, inner)) do rows[#rows + 1] = r end
  end
  for _, image in ipairs(item.images or {}) do
    rows[#rows + 1] = { { ("[Image: %s · %d×%d]"):format(image.name, image.width, image.height), "CodexBubble" } }
  end
  local bw = 0
  for _, r in ipairs(rows) do bw = math.max(bw, width_of(r)) end
  local lead = { string.rep(" ", math.max(0, w - bw - 4)), "Normal" }
  local out = { {} }
  for _, r in ipairs(rows) do
    local line = { lead, { "  ", "CodexBubble" } }
    for _, s in ipairs(r) do line[#line + 1] = s end
    line[#line + 1] = { string.rep(" ", bw - width_of(r) + 2), "CodexBubble" }
    out[#out + 1] = line
  end

  local s = bone.chat.session() or {}
  for n, t in ipairs(bone.chat.turns()) do
    if t.first == item.index then
      local label
      if t.running then
        label = "Working for " .. secs(s.turn and s.turn.elapsed_ms)
        bone.chat.refresh_in(1000)
      elseif s.session_id and times[s.session_id .. ":" .. n] then
        label = "Worked for " .. secs(times[s.session_id .. ":" .. n])
      end
      if label then
        out[#out + 1] = {}
        out[#out + 1] = { { label, "CodexMuted" } }
        out[#out + 1] = { { fill = "─", hl = "CodexRule" } }
      end
      break
    end
  end
  return out
end

-- ---- top bar -------------------------------------------------------------------

local top_hits = {}
bone.ui.regions.topbar = {
  size = 1,
  render = function(ctx)
    top_hits = {}
    local right = {}
    if git.add + git.del > 0 then
      right[#right + 1] = { " +" .. git.add, "CodexPillAdd", open_diff }
      right[#right + 1] = { " -" .. git.del .. " ", "CodexPillDel", open_diff }
      right[#right + 1] = { "   ", "CodexTop" }
    end
    if git.branch then right[#right + 1] = { "⑂ " .. git.branch .. "   ", "CodexTop" } end
    right[#right + 1] = { "⊟", "CodexTop", toggle_terminal }
    right[#right + 1] = { "  ", "CodexTop" }
    local rw = width_of(right)
    local left = {
      { "  ", "CodexTop" },
      { "◧", "CodexTop", function() sidebar.toggle() end },
      { "   ", "CodexTop" },
    }
    local room = ctx.width - width_of(left) - rw - 6
    left[#left + 1] = { bone.text.truncate(title_of(), math.max(room, 4)), "CodexTopTitle" }
    left[#left + 1] = { "  ···", "CodexTop" }
    local spans = left
    spans[#spans + 1] = { string.rep(" ", math.max(1, ctx.width - width_of(left) - rw)), "CodexTop" }
    for _, r in ipairs(right) do spans[#spans + 1] = r end
    local line = lay(spans, top_hits)
    return { line }
  end,
}

-- ---- the composer ------------------------------------------------------------

local chip_hits, head_hits = {}, {}

bone.ui.prompt = {
  prefix = { { " ", "Composer" } },
  continuation = { { " ", "Composer" } },
  placeholder = { { "Ask bone anything, / for commands", "Placeholder" } },
  background = "Composer",
  padding = 2,
  min = 2,
  top = function(ctx)
    head_hits = {}
    if git.files == 0 then return { { " ", "Composer" } } end
    local spans = {
      { "   ", "Composer" },
      { "± " .. git.files .. (git.files == 1 and " file" or " files") .. " changed", "ComposerText" },
      { (git.add + git.del > 0) and ("  +" .. git.add) or "", "ComposerAdd" },
      { (git.add + git.del > 0) and (" -" .. git.del) or "", "ComposerDel" },
      { fill = " ", hl = "Composer" },
    }
    if has_diff() then spans[#spans + 1] = { "Review ›", "ComposerDim", open_diff } end
    spans[#spans + 1] = { "   ", "Composer" }
    local line = lay(spans, {})
    -- Its position from the right edge.
    if has_diff() then head_hits = { { from = ctx.width - 10, to = ctx.width - 3, run = open_diff } } end
    return line
  end,
  bottom = function(ctx)
    chip_hits = {}
    local e = effort()
    local send = ctx.running and { " ■ ", "ComposerSend", function() bone.action("interrupt") end }
      or { " ↑ ", ctx.empty and "ComposerSendIdle" or "ComposerSend", function() bone.action("submit") end }
    local left = {
      { "   ", "Composer" },
      { "+", "ComposerText", function() bone.action("paste_clipboard") end },
      { "   ", "Composer" },
      { "⚠ Full access", "ComposerWarn", function() bone.notify("bone runs tools without asking (approvals are a bone.ask customization)") end },
    }
    local right = {
      { bone.text.truncate(current.model or "model", 24) .. " ⌄", "ComposerText", function() require("bone.config").open("providers") end },
      { "   ", "Composer" },
      { (e and (e:gsub("^%l", string.upper)) or "Auto") .. " ⌄", "ComposerText", cycle_effort },
      { "   ", "Composer" },
      send,
      { "  ", "Composer" },
    }
    local w = ctx.width
    if width_of(left) + width_of(right) >= w then left = { left[1], left[2] } end
    if width_of(left) + width_of(right) >= w then right = { send, { "  ", "Composer" } } end
    local spans = {}
    for _, s in ipairs(left) do spans[#spans + 1] = s end
    spans[#spans + 1] = { string.rep(" ", math.max(0, w - width_of(left) - width_of(right))), "Composer" }
    for _, s in ipairs(right) do spans[#spans + 1] = s end
    local line = lay(spans, chip_hits)
    return line
  end,
}

-- Folder and branch under the composer, where Codex shows Local and the branch.
bone.ui.regions.composer_meta = {
  size = 1,
  render = function()
    return { { { "   ▭ " .. folder(), "CodexMuted" }, { fill = " ", hl = "Normal" },
               { git.branch and ("⑂ " .. git.branch .. "   ") or "", "CodexMuted" } } }
  end,
}

-- ---- empty thread --------------------------------------------------------------

local stock_empty = bone.ui.regions.chat_empty
bone.ui.regions.chat_empty = {
  render = function(ctx)
    if bone.settings.get("setup.skipped") then return stock_empty.render(ctx) end
    if bone.api.session() or (bone.chat.session() or {}).items > 0 then return {} end
    return {
      { { "What will you build?", "CodexHero" } },
      {},
      { { " ▭ " .. folder() .. " ", "CodexChip" } },
    }
  end,
}

-- ---- layout ------------------------------------------------------------------------

-- The thread and composer sit between two margins that keep them about COL
-- wide; the margins follow the room the side panels leave.
local COL = 96
local margin = 1
local applied_layout

bone.ui.layout = {
  "topbar",
  "top",
  { cols = { { "pad_l", size = margin },
             { rows = { "chat", "input_gap", "above_prompt", "prompt", { "composer_meta", size = 1 },
                        "attachments", "tray" } },
             { "pad_r", size = margin } } },
  "statusline",
}

-- Resize the margins in whatever layout is current, in place: plugins swap
-- regions in and out of it (ask_user puts its question where the prompt
-- was) and expect their table to stay.
local function apply()
  local function walk(list)
    for _, e in ipairs(list or {}) do
      if type(e) == "table" then
        if e[1] == "pad_l" or e[1] == "pad_r" then e.size = margin end
        walk(e.rows)
        walk(e.cols)
      end
    end
  end
  walk(bone.ui.layout)
  applied_layout = bone.ui.layout
end

-- The middle column's width: the prompt, or whatever stands in for it.
local MIDDLE = { pad_l = true, pad_r = true, prompt = true, ask_user = true }

local function pad()
  local room = 0
  for _, l in ipairs(bone.ui.geometry().leaves or {}) do
    if MIDDLE[l.name] then room = room + l.width end
  end
  local want = room > 0 and math.max(1, math.floor((room - COL) / 2)) or margin
  -- ask_user can restore an older layout with stale sizes after a resize.
  if want ~= margin or bone.ui.layout ~= applied_layout then
    margin = want
    bone.defer(0, function() apply(); bone.ui.refresh_in(0) end)
  end
  return {}
end
bone.ui.regions.pad_l = { render = pad }
bone.ui.regions.pad_r = { render = function() return {} end }

-- ---- keys, clicks, events ----------------------------------------------------------

bone.keymap.set("ctrl+b", function() sidebar.toggle() end)
bone.keymap.set("ctrl+d", function()
  if has_diff() then return bone.cmd("diff") end
  bone.action("quit_if_empty")
end)

local function leaf_height(name)
  for _, l in ipairs(bone.ui.geometry().leaves or {}) do
    if l.name == name then return l.height end
  end
end

bone.on("mouse", function(ev)
  if ev.action ~= "down" or ev.button ~= "left" then return end
  local row, col = ev.row or 0, ev.col or 0
  if ev.region == "topbar" then
    return hit(top_hits, col)
  elseif ev.region == "prompt" and row == leaf_height("prompt") then
    return hit(chip_hits, col)
  elseif ev.region == "prompt" and row == 1 then
    return hit(head_hits, col)
  end
end)

local function refresh_all()
  refresh_git()
  refresh_model()
end
bone.on("ready", function()
  refresh_all()
  sidebar.open({ focus = false })
end)
bone.on("chat/shown", refresh_all)
bone.on("turn/finished", refresh_all)
bone.on("tool/finished", refresh_git)
bone.on("settings/changed", refresh_model)
