-- Notebook's session browser: a table of contents.
--
-- Sessions are entries with dotted leaders running out to their cell count,
-- grouped like a journal (Today, Yesterday, This week…) or by project
-- (ctrl+g). A second page, Kernels, lists background shells and sub-agents.
local D = require("bone.ui.session_data")
local M = {}

local panel, feed
local st -- per-open state

M.archive_current = D.archive_current

local function pad_left(s, n)
  local w = bone.text.width(s)
  return w >= n and s or (string.rep(" ", n - w) .. s)
end

local function short(p)
  local home = os.getenv("HOME") or ""
  if home ~= "" and p:sub(1, #home) == home then return "~" .. p:sub(#home + 1) end
  return p
end

local function project(cwd)
  return (cwd or ""):match("([^/]+)/*$") or "~"
end

local function day_group(at)
  local now = os.date("*t")
  local midnight = os.time({ year = now.year, month = now.month, day = now.day, hour = 0 })
  if at >= midnight then return 1, "TODAY" end
  if at >= midnight - 86400 then return 2, "YESTERDAY" end
  if at >= midnight - 6 * 86400 then return 3, "THIS WEEK" end
  if at >= midnight - 30 * 86400 then return 4, "THIS MONTH" end
  return 5, "EARLIER"
end

-- The entries shown, in order, with their section headings.
local function entries()
  local q = st.query:lower()
  local list = {}
  for _, s in ipairs(feed.sessions) do
    if (s.title .. " " .. s.cwd):lower():find(q, 1, true) then list[#list + 1] = s end
  end
  local sections, order = {}, {}
  for _, s in ipairs(list) do
    local key, label, rank
    if s.archived and not s.live then
      key, label, rank = "archived", "ARCHIVED", 99
    elseif st.group == "project" then
      key, label, rank = s.cwd, project(s.cwd):upper(), 0
    else
      rank, label = day_group(s.at)
      key = label
      if s.live then key, label, rank = "running", "RUNNING", 0 end
    end
    if not sections[key] then
      sections[key] = { label = label, rank = rank, items = {}, at = s.at, cwd = s.cwd }
      order[#order + 1] = sections[key]
    end
    local sec = sections[key]
    sec.items[#sec.items + 1] = s
    sec.at = math.max(sec.at, s.at)
  end
  table.sort(order, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.at > b.at
  end)
  return order
end

local function build(width)
  local L, hits, items = {}, {}, {}
  local function line(spans) L[#L + 1] = spans; return #L end
  line({})
  line({ { "  CONTENTS", "Heading" }, { fill = " ", hl = "Normal" },
         { "contents", st.page == "contents" and "OutLabel" or "Margin" },
         { "  ", "Normal" },
         { "kernels" .. (#feed:jobs() > 0 and (" " .. #feed:jobs()) or ""), st.page == "kernels" and "OutLabel" or "Margin" },
         { "  ", "Normal" } })
  line({ { "  ", "Normal" }, { "━━━━━━━━", "HeadingRule" } })
  if st.page == "kernels" then
    line({})
    line({ { "  ↵ open · x stop · tab contents · esc", "Footnote" } })
    line({})
    local jobs = feed:jobs()
    if #jobs == 0 then line({ { "  The kernels are idle.", "Margin" } }) end
    for _, j in ipairs(jobs) do
      items[#items + 1] = j
      local sel = #items == st.selected
      local band = sel and "Selection" or "Normal"
      local a = line({ { "  ", band }, { st.spinner .. " ", "LogRun" }, { j.shell and "shell  " or "agent  ", "LogVerb" },
                       { bone.text.truncate(j.title, width - 18), band }, { fill = " ", hl = band },
                       { bone.util.duration(os.time() - (j.started or os.time())) .. "  ", "LogTime" } })
      local b = line({ { "      " .. bone.text.truncate(j.detail or "", width - 8), "Footnote" }, { fill = " ", hl = band } })
      hits[a], hits[b] = #items, #items
    end
    return L, hits, items
  end

  line({})
  line({ { "  Index › ", "Margin" }, { st.query ~= "" and st.query or "", "InLabel" }, { st.focused and "▏" or "", "InLabel" } })
  line({ { "  ctrl+g ", "LogVerb" }, { st.group == "project" and "by project" or "by date", "Footnote" },
         { " · tab kernels · ↵ open", "Footnote" } })
  if feed.loading then line({}); line({ { "  Reading the shelf…", "Margin" } }) end
  local secs = entries()
  if not feed.loading and #secs == 0 then
    line({})
    line({ { st.query == "" and "  No notebooks yet." or "  Nothing in the index matches.", "Margin" } })
  end
  for _, sec in ipairs(secs) do
    line({})
    local head = { { "  " .. sec.label, "InLabel" } }
    if st.group == "project" and sec.cwd and sec.rank ~= 99 then
      head[#head + 1] = { "  " .. bone.text.truncate(short(sec.cwd), math.max(width - #sec.label - 6, 4)), "Footnote" }
    end
    line(head)
    for _, s in ipairs(sec.items) do
      items[#items + 1] = s
      local sel = #items == st.selected and st.focused
      local band = sel and "Selection" or "Normal"
      local mark = s.live and { st.spinner .. " ", "LogRun" } or (s.current and { "▸ ", "OutLabel" } or { "  ", band })
      local page = s.turns > 0 and tostring(s.turns) or "–"
      local room = width - 4 - 2 - #page - 3
      local title = bone.text.truncate(s.title, room)
      local dots = math.max(room - bone.text.width(title), 0)
      local a = line({ { "  ", band }, mark, { title, sel and "SuggestSel" or "Normal" },
                       { " " .. string.rep("·", math.max(dots, 1)) .. " ", sel and "SuggestSelDesc" or "Rule" },
                       { pad_left(page, #page), sel and "SuggestSel" or "OutLabel" }, { " ", band } })
      local meta = {}
      if st.group ~= "project" then meta[#meta + 1] = project(s.cwd) end
      if s.tokens > 0 then meta[#meta + 1] = D.tokens(s.tokens) .. " tok" end
      if s.tools > 0 then meta[#meta + 1] = s.tools .. " calls" .. (s.tool_errors > 0 and (" (" .. s.tool_errors .. " failed)") or "") end
      local b = line({ { "      " .. table.concat(meta, " · "), sel and "SuggestSelDesc" or "Footnote" },
                       { fill = " ", hl = band }, { D.ago(s.at) .. "  ", sel and "SuggestSelDesc" or "Footnote" } })
      hits[a], hits[b] = #items, #items
    end
  end
  return L, hits, items
end

local function reveal()
  local info = panel:info()
  local first = st.lines_of[st.selected]
  if not first or not info.height or info.height == 0 then return end
  local top = info.top
  if first - 1 < top then top = first - 1
  elseif first + 1 > top + info.height then top = first + 1 - info.height end
  if top ~= info.top then panel:scroll(top - info.top) end
end

local function render(ctx)
  st.spinner, st.focused = ctx.spinner or "◴", ctx.focused
  local L, hits, items = build(ctx.width)
  st.hits, st.items, st.lines_of = hits, items, {}
  for line, i in pairs(hits) do
    if not st.lines_of[i] or line < st.lines_of[i] then st.lines_of[i] = line end
  end
  if st.selected > #items then st.selected = math.max(#items, 1) end
  local running = false
  for _, s in ipairs(feed.sessions) do running = running or s.live end
  bone.ui.refresh_in((running or #feed:jobs() > 0) and 150 or 30000)
  while #L < ctx.height do L[#L + 1] = {} end
  return L
end

local function choose(i)
  local it = st.items[i]
  if not it then return end
  bone.ui.panel.focus(nil)
  bone.api.open_session(it.session_id)
end

local function move(d)
  st.selected = math.max(1, math.min(#st.items, st.selected + d))
  reveal()
end

local function switch_page()
  st.page = st.page == "contents" and "kernels" or "contents"
  st.selected = 1
  panel:scroll("top")
end

function M.open()
  if panel and panel:is_open() then
    if bone.ui.panel.focused() == "sessions" then panel:close() else panel:focus() end
    return
  end
  st = { query = "", selected = 1, page = "contents", group = "date", hits = {}, items = {}, lines_of = {}, spinner = "◴" }
  feed = D.open(function()
    -- Land on the chat on screen the first time the list arrives.
    if st.initial == nil and not feed.loading then
      st.initial = true
      for i, it in ipairs(st.items) do if it.current then st.selected = i end end
    end
  end)
  panel = bone.ui.panel.open({
    id = "sessions", dock = "left", size = 50, full_height = true, focus = true,
    render = render,
    keys = {
      esc = function() bone.ui.panel.focus(nil) end,
      ["ctrl+o"] = function() panel:close() end,
      tab = switch_page, ["shift+tab"] = switch_page,
      ["ctrl+g"] = function() st.group = st.group == "date" and "project" or "date"; panel:scroll("top") end,
      enter = function() choose(st.selected) end,
      up = function() move(-1) end, down = function() move(1) end,
      pageup = function() move(-8) end, pagedown = function() move(8) end,
      home = function() move(-#st.items) end, ["end"] = function() move(#st.items) end,
    },
    on_key = function(key)
      if st.page == "kernels" then
        if key == "x" and st.items[st.selected] then D.cancel(st.items[st.selected]); return true end
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
      st.selected = 1
      panel:scroll("top")
      return true
    end,
    on_close = function() if feed then feed:close() end end,
  })
end

bone.on("mouse", function(ev)
  if not panel or not panel:is_open() or ev.panel ~= "sessions" then return end
  if ev.button == "left" and ev.action == "down" then
    local i = st.hits[ev.panel_line]
    if i then choose(i) elseif ev.panel_line == 2 then switch_page() end
    return true
  end
end)

return M
