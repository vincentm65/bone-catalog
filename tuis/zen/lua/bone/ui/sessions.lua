-- Zen's session browser: a floating palette instead of a sidebar.
--
-- Type to fuzzy-match titles and folders (matched letters light up), arrows
-- to move, enter to open, tab for background work, esc to close. Running
-- sessions float to the top with a live dot.
local D = require("bone.ui.session_data")
local M = {}

local win, feed
local st

M.archive_current = D.archive_current

local function project(cwd)
  return (cwd or ""):match("([^/]+)/*$") or "~"
end

local function chars(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
  return out
end

-- Subsequence match: every query character in order. Returns a score
-- (lower is better) and the matched positions, or nil.
local function fuzzy(text, q)
  if q == "" then return 0, {} end
  local t, qc = chars(text:lower()), chars(q:lower())
  local hits, j, gaps, last = {}, 1, 0, 0
  for i = 1, #t do
    if t[i] == qc[j] then
      hits[i] = true
      if last > 0 then gaps = gaps + (i - last - 1) end
      last, j = i, j + 1
      if j > #qc then return gaps + (next(hits) or 0) * 0.1, hits end
    end
  end
  return nil
end

local function results()
  if st.page == "jobs" then return feed:jobs() end
  local out = {}
  for _, s in ipairs(feed.sessions) do
    if not s.archived or s.live or st.query ~= "" then
      local score, hits = fuzzy(s.title, st.query)
      local pscore = not score and fuzzy(project(s.cwd), st.query)
      if score or pscore then
        out[#out + 1] = { s = s, score = score or (pscore + 100), hits = score and hits or {} }
      end
    end
  end
  if st.query ~= "" then
    table.sort(out, function(a, b)
      if a.score ~= b.score then return a.score < b.score end
      return a.s.at > b.s.at
    end)
  end
  return out
end

local function close()
  if win then bone.ui.close(win) end
  win = nil
  if feed then feed:close() end
end

local function draw(ctx)
  local W = ctx.width
  local rows = results()
  st.rows = rows
  st.selected = math.max(1, math.min(st.selected, math.max(#rows, 1)))
  local L = {}
  local function line(spans)
    spans[#spans + 1] = { fill = " ", hl = "ZPal" }
    L[#L + 1] = spans
  end
  line({})
  -- The query line.
  if st.page == "jobs" then
    line({ { "   Background", "ZPalText" }, { "   tab sessions", "ZPalHint" } })
  else
    line({ { "   ", "ZPal" }, { st.query == "" and "Search sessions" or st.query, st.query == "" and "ZPalHint" or "ZPalText" },
           { "▏", "ZPalLive" }, { fill = " ", hl = "ZPal" },
           { #feed:jobs() > 0 and (#feed:jobs() .. " running · tab   ") or "", "ZPalHint" } })
  end
  line({ { "   " .. string.rep("─", W - 6), "ZPalRule" } })

  local list_h = ctx.height - 5
  if st.selected < st.top + 1 then st.top = st.selected - 1 end
  if st.selected > st.top + list_h then st.top = st.selected - list_h end
  st.top = math.max(0, math.min(st.top, math.max(#rows - list_h, 0)))

  if #rows == 0 then
    line({})
    line({ { "   " .. ((feed.loading and "…") or (st.page == "jobs" and "Nothing running.") or "No matches."), "ZPalHint" } })
  end
  for i = st.top + 1, math.min(#rows, st.top + list_h) do
    local sel = i == st.selected
    local bg = sel and "ZPalSel" or "ZPal"
    local r = rows[i]
    local spans = { { sel and " › " or "   ", sel and "ZPalSelLive" or bg } }
    if st.page == "jobs" then
      spans[#spans + 1] = { st.spinner .. " ", sel and "ZPalSelLive" or "ZPalLive" }
      spans[#spans + 1] = { bone.text.truncate(r.title, W - 20), sel and "ZPalSelText" or "ZPalText" }
      spans[#spans + 1] = { fill = " ", hl = bg }
      spans[#spans + 1] = { bone.util.duration(os.time() - (r.started or os.time())) .. "   ", sel and "ZPalSelHint" or "ZPalHint" }
    else
      local s = r.s
      local dot = s.live and { st.spinner .. " ", sel and "ZPalSelLive" or "ZPalLive" }
        or (s.current and { "● ", sel and "ZPalSelText" or "ZPalHint" }) or { "  ", bg }
      spans[#spans + 1] = dot
      local right = project(s.cwd) .. "   " .. string.format("%4s", D.ago(s.at)) .. "   "
      local room = W - 5 - bone.text.width(right) - 2
      local title = chars(bone.text.truncate(s.title, room))
      for k, ch in ipairs(title) do
        local lit = r.hits[k]
        spans[#spans + 1] = { ch, lit and (sel and "ZPalSelLive" or "ZPalLive") or (sel and "ZPalSelText" or "ZPalText") }
      end
      spans[#spans + 1] = { fill = " ", hl = bg }
      spans[#spans + 1] = { right, sel and "ZPalSelHint" or "ZPalHint" }
    end
    spans[#spans + 1] = { "", bg }
    L[#L + 1] = spans
  end
  while #L < ctx.height - 1 do line({}) end
  local count = #rows .. (st.page == "jobs" and " running" or (#rows == 1 and " session" or " sessions"))
  line({ { "   " .. count, "ZPalHint" }, { fill = " ", hl = "ZPal" },
         { (st.page == "jobs" and "x stop   " or "") .. "↵ open   esc close   ", "ZPalHint" } })
  local live = #feed:jobs() > 0
  for _, s in ipairs(feed.sessions) do live = live or s.live end
  if live then bone.ui.refresh_in(160) end
  return L
end

local function choose()
  local r = st.rows[st.selected]
  if not r then return end
  local id = st.page == "jobs" and r.session_id or r.s.session_id
  close()
  bone.api.open_session(id)
end

local function setup_colors()
  bone.hl.set("ZPal", { fg = "#e4e4e7", bg = "#141417" })
  bone.hl.set("ZPalText", { fg = "#d4d4d8", bg = "#141417" })
  bone.hl.set("ZPalHint", { fg = "#52525b", bg = "#141417" })
  bone.hl.set("ZPalRule", { fg = "#232327", bg = "#141417" })
  bone.hl.set("ZPalLive", { fg = "#8ab4ff", bg = "#141417", bold = true })
  bone.hl.set("ZPalSel", { fg = "#ffffff", bg = "#1f1f24" })
  bone.hl.set("ZPalSelText", { fg = "#ffffff", bg = "#1f1f24" })
  bone.hl.set("ZPalSelHint", { fg = "#71717a", bg = "#1f1f24" })
  bone.hl.set("ZPalSelLive", { fg = "#8ab4ff", bg = "#1f1f24", bold = true })
end

function M.open()
  if win and bone.ui.is_open(win) then close() return end
  setup_colors()
  st = { query = "", selected = 1, top = 0, page = "sessions", rows = {}, spinner = "•" }
  feed = D.open(function()
    if not st.landed and not feed.loading then
      st.landed = true
      for i, r in ipairs(results()) do if r.s and r.s.current then st.selected = i end end
    end
  end)
  local function move(d) st.selected = st.selected + d end
  win = bone.ui.win({
    lines = function(ctx)
      st.spinner = bone.ui.spinner and bone.ui.spinner.frames
        and bone.ui.spinner.frames[math.floor(bone.now() / 160) % #bone.ui.spinner.frames + 1] or "•"
      return draw(ctx)
    end,
    width = 76, height = 20, focus = true, z = 10,
    keys = {
      esc = close,
      ["ctrl+o"] = close,
      enter = choose,
      up = function() move(-1) end, down = function() move(1) end,
      ["ctrl+p"] = function() move(-1) end, ["ctrl+n"] = function() move(1) end,
      pageup = function() move(-10) end, pagedown = function() move(10) end,
      wheelup = function() move(-1) end, wheeldown = function() move(1) end,
      tab = function()
        st.page = st.page == "jobs" and "sessions" or "jobs"
        st.selected, st.top = 1, 0
      end,
    },
    on_key = function(key)
      if st.page == "jobs" then
        if key == "x" and st.rows[st.selected] then D.cancel(st.rows[st.selected]); return true end
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
