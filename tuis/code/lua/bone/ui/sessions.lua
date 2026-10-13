-- Code's session browser: VS Code's Quick Open, dropped from the top.
--
-- Type to filter; rows are grouped like "recently opened" with the group
-- label on the right; ↑↓ / ctrl+n ctrl+p move, enter opens, tab shows
-- background processes (x stops one), esc closes.
local D = require("bone.ui.session_data")
local M = {}

local win, feed
local st

M.archive_current = D.archive_current

local function project(cwd)
  return (cwd or ""):match("([^/]+)/*$") or "~"
end

local function close()
  if win then bone.ui.close(win) end
  win = nil
  if feed then feed:close() end
end

local function matches(s, q)
  if q == "" then return true end
  local hay = (s.title .. " " .. s.cwd):lower()
  for word in q:lower():gmatch("%S+") do
    if not hay:find(word, 1, true) then return false end
  end
  return true
end

local function rows()
  if st.page == "procs" then
    local out = {}
    for _, j in ipairs(feed:jobs()) do out[#out + 1] = { job = j, group = "running" } end
    return out
  end
  local out = {}
  local hour = os.time() - 3600
  for _, s in ipairs(feed.sessions) do
    if matches(s, st.query) and (not s.archived or s.live or st.query ~= "") then
      local group = s.live and "running" or (s.at >= hour and "recently opened") or "other sessions"
      out[#out + 1] = { s = s, group = group }
    end
  end
  return out
end

local function draw(ctx)
  local W = ctx.width
  local list = rows()
  st.rows = list
  st.selected = math.max(1, math.min(st.selected, math.max(#list, 1)))
  local L = {}
  local function framed(spans, bg)
    local line = { { "│", "VQBorder" } }
    for _, s in ipairs(spans) do line[#line + 1] = s end
    line[#line + 1] = { fill = " ", hl = bg or "VQ" }
    line[#line + 1] = { "│", "VQBorder" }
    L[#L + 1] = line
  end
  L[1] = { { "╭", "VQBorder" }, { fill = "─", hl = "VQBorder" }, { "╮", "VQBorder" } }
  -- The input box, with its own focus border.
  framed({ { " ", "VQ" }, { "┌", "VQInputBorder" }, { string.rep("─", W - 6), "VQInputBorder" }, { "┐", "VQInputBorder" } })
  local text = st.page == "procs" and "% " or st.query
  local shown = text ~= "" and text or "Search sessions by name or folder"
  local inner = W - 8
  framed({ { " ", "VQ" }, { "│", "VQInputBorder" }, { " ", "VQInput" },
           { bone.text.truncate(shown, inner - 1), text ~= "" and "VQInputText" or "VQInputHint" },
           { "▏", "VQCursor" },
           { string.rep(" ", math.max(inner - bone.text.width(bone.text.truncate(shown, inner - 1)), 0)), "VQInput" },
           { "│", "VQInputBorder" } })
  framed({ { " ", "VQ" }, { "└", "VQInputBorder" }, { string.rep("─", W - 6), "VQInputBorder" }, { "┘", "VQInputBorder" } })

  local list_h = ctx.height - 6
  if st.selected < st.top + 1 then st.top = st.selected - 1 end
  if st.selected > st.top + list_h then st.top = st.selected - list_h end
  st.top = math.max(0, math.min(st.top, math.max(#list - list_h, 0)))
  if #list == 0 then
    framed({ { "  " .. (feed.loading and "Loading…" or (st.page == "procs" and "No running processes" or "No matching sessions")), "VQHint" } })
  end
  local prev_group
  for i = st.top + 1, math.min(#list, st.top + list_h) do
    local r = list[i]
    local sel = i == st.selected
    local bg = sel and "VQSel" or "VQ"
    local label = r.group ~= prev_group and r.group or ""
    if r.group ~= prev_group and prev_group then
      L[#L + 1] = { { "│", "VQBorder" }, { " ", "VQ" }, { fill = "─", hl = "VQRule" }, { " ", "VQ" }, { "│", "VQBorder" } }
    end
    prev_group = r.group
    local spans
    if r.job then
      local j = r.job
      spans = { { "  " .. st.spinner .. " ", sel and "VQSelIcon" or "VQIconRun" }, { bone.text.truncate(j.title, W - 30), sel and "VQSelText" or "VQText" },
                { "  " .. (j.shell and "terminal" or "agent"), sel and "VQSelDesc" or "VQDesc" } }
    else
      local s = r.s
      local icon = s.live and st.spinner or "◈"
      spans = { { "  " .. icon .. " ", sel and "VQSelIcon" or (s.live and "VQIconRun" or "VQIcon") } }
      local right = label ~= "" and label or ""
      local desc = "  " .. project(s.cwd) .. " · " .. D.ago(s.at) .. (s.tokens > 0 and (" · " .. D.tokens(s.tokens) .. " tokens") or "")
      local room = W - 8 - bone.text.width(right) - 2
      local title = bone.text.truncate(s.title, math.max(math.floor(room * 0.65), 10))
      spans[#spans + 1] = { title, sel and "VQSelText" or (s.current and "VQCurrent" or "VQText") }
      spans[#spans + 1] = { bone.text.truncate(desc, math.max(room - bone.text.width(title), 0)), sel and "VQSelDesc" or "VQDesc" }
      spans[#spans + 1] = { fill = " ", hl = bg }
      spans[#spans + 1] = { right .. " ", sel and "VQSelDesc" or "VQGroup" }
    end
    framed(spans, bg)
  end
  while #L < ctx.height - 1 do framed({}) end
  L[#L + 1] = { { "╰", "VQBorder" }, { fill = "─", hl = "VQBorder" }, { "╯", "VQBorder" } }
  local live = #feed:jobs() > 0
  for _, s in ipairs(feed.sessions) do live = live or s.live end
  if live then bone.ui.refresh_in(150) end
  return L
end

local function choose()
  local r = st.rows[st.selected]
  if not r then return end
  local id = r.job and r.job.session_id or r.s.session_id
  close()
  bone.api.open_session(id)
end

local function colors()
  local bg, sel = "#252526", "#04395e"
  bone.hl.set("VQ", { fg = "#cccccc", bg = bg })
  bone.hl.set("VQBorder", { fg = "#454545", bg = "#1f1f1f" })
  bone.hl.set("VQRule", { fg = "#3c3c3c", bg = bg })
  bone.hl.set("VQInput", { fg = "#cccccc", bg = "#313131" })
  bone.hl.set("VQInputBorder", { fg = "#0078d4", bg = bg })
  bone.hl.set("VQInputText", { fg = "#cccccc", bg = "#313131" })
  bone.hl.set("VQInputHint", { fg = "#8b8b8b", bg = "#313131" })
  bone.hl.set("VQCursor", { fg = "#aeafad", bg = "#313131" })
  bone.hl.set("VQText", { fg = "#cccccc", bg = bg })
  bone.hl.set("VQCurrent", { fg = "#4daafc", bg = bg })
  bone.hl.set("VQDesc", { fg = "#8b8b8b", bg = bg })
  bone.hl.set("VQGroup", { fg = "#8b8b8b", bg = bg })
  bone.hl.set("VQHint", { fg = "#8b8b8b", bg = bg })
  bone.hl.set("VQIcon", { fg = "#b180d7", bg = bg })
  bone.hl.set("VQIconRun", { fg = "#73c991", bg = bg })
  bone.hl.set("VQSel", { fg = "#ffffff", bg = sel })
  bone.hl.set("VQSelText", { fg = "#ffffff", bg = sel, bold = true })
  bone.hl.set("VQSelDesc", { fg = "#cccccc", bg = sel })
  bone.hl.set("VQSelIcon", { fg = "#ffffff", bg = sel })
end

function M.open()
  if win and bone.ui.is_open(win) then close() return end
  colors()
  st = { query = "", selected = 1, top = 0, page = "sessions", rows = {}, spinner = "◐" }
  feed = D.open(function()
    if not st.landed and not feed.loading then
      st.landed = true
      for i, r in ipairs(rows()) do if r.s and r.s.current then st.selected = i end end
    end
  end)
  local function move(d) st.selected = st.selected + d end
  win = bone.ui.win({
    lines = function(ctx)
      local frames = (bone.ui.spinner and bone.ui.spinner.frames) or { "◐" }
      st.spinner = frames[math.floor(bone.now() / 110) % #frames + 1]
      return draw(ctx)
    end,
    width = 84, height = 18, row = 1, focus = true, z = 10,
    keys = {
      esc = close, ["ctrl+o"] = close, ["ctrl+p"] = function() move(-1) end,
      enter = choose,
      up = function() move(-1) end, down = function() move(1) end,
      ["ctrl+n"] = function() move(1) end,
      pageup = function() move(-10) end, pagedown = function() move(10) end,
      wheelup = function() move(-1) end, wheeldown = function() move(1) end,
      tab = function()
        st.page = st.page == "procs" and "sessions" or "procs"
        st.selected, st.top = 1, 0
      end,
    },
    on_key = function(key)
      if st.page == "procs" then
        if key == "x" and st.rows[st.selected] then D.cancel(st.rows[st.selected].job); return true end
        return false
      end
      if key == "backspace" then
        st.query = st.query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
      elseif key == "ctrl+u" then
        st.query = ""
      elseif key == "space" then
        st.query = st.query .. " "
      elseif key:match("^[%z\1-\127\194-\244][\128-\191]*$") then
        st.query = st.query .. key
      else
        return false
      end
      st.selected, st.top = 1, 0
      return true
    end,
  })
end

return M
