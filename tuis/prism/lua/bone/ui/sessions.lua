-- Prism's session browser: a glowing sidebar.
--
--   * An animated wordmark and a 35-day activity chart (your messages per day).
--   * Each project gets its own colour; every session card carries it as a
--     side bar and a chip, so a glance shows which work belongs together.
--   * A token meter per card, scaled to your biggest session.
--   * The selected card's bar flows; running sessions shimmer.
local D = require("bone.ui.session_data")
local M = {}

local panel, feed
local st
local N = 48

M.archive_current = D.archive_current

local function wrap_i(i) return (math.floor(i) % N) + 1 end

local function phase(speed)
  local motion = bone.o.get and bone.o.get("prism_motion") or "full"
  if motion == "still" then return 0 end
  return bone.now() / (motion == "calm" and speed * 2 or speed)
end

local function grad(text, from, step, kind)
  local out, i = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = { ch, (kind or "Px") .. wrap_i(from + i * (step or 1)) }
    i = i + 1
  end
  return out
end

local function project(cwd)
  return (cwd or ""):match("([^/]+)/*$") or "~"
end

local function hue(name)
  local h = 0
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 9973 end
  return (h * 7) % N
end

local SPARK = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function build(width)
  local L, hits, items = {}, {}, {}
  local function line(spans) L[#L + 1] = spans; return #L end
  local t = phase(90)

  line({})
  local head = { { "  ", "Normal" } }
  for _, s in ipairs(grad("◆ sessions", -t, 1.4)) do head[#head + 1] = s end
  head[#head + 1] = { fill = " ", hl = "Normal" }
  local njobs = #feed:jobs()
  head[#head + 1] = { " chats ", st.page == "chats" and ("Pc" .. wrap_i(4)) or "PFaint" }
  head[#head + 1] = { " ", "Normal" }
  head[#head + 1] = { " live" .. (njobs > 0 and (" " .. njobs) or "") .. " ", st.page == "live" and ("Pc" .. wrap_i(30)) or "PFaint" }
  head[#head + 1] = { "  ", "Normal" }
  line(head)
  line({})

  -- 35 days of activity, newest on the right, coloured along the wheel.
  local today = math.floor(os.time() / 86400)
  local days, hi, total = {}, 1, 0
  for d = today - 34, today do
    local n = feed.days[d] or 0
    days[#days + 1] = n
    hi, total = math.max(hi, n), total + n
  end
  local strip = { { "  ", "Normal" } }
  for i, n in ipairs(days) do
    local k = n == 0 and 1 or math.max(2, math.ceil(n / hi * 8) + 1)
    strip[#strip + 1] = { n == 0 and "·" or SPARK[k], n == 0 and "PFaint" or ("Px" .. wrap_i(i * 1.2 - t * 0.3)) }
  end
  line(strip)
  line({ { "  35 days · " .. total .. " messages", "PFaint" } })
  line({})

  if st.page == "live" then
    local jobs = feed:jobs()
    if #jobs == 0 then line({ { "  nothing running", "PFaint" } }) end
    for _, j in ipairs(jobs) do
      items[#items + 1] = j
      local sel = #items == st.selected
      local h = j.shell and 30 or 10
      local a = line({ { " ", "Normal" }, { sel and "┃" or "│", "Px" .. wrap_i(h - t) }, { " ", "Normal" },
                       { j.shell and " shell " or " agent ", "Pc" .. wrap_i(h) }, { " " .. bone.text.truncate(j.title, width - 14), sel and "PWhite" or "Normal" } })
      local bar = { { " ", "Normal" }, { sel and "┃" or "│", "Px" .. wrap_i(h + 1 - t) }, { " ", "Normal" } }
      local pos = phase(40) % 22
      for i = 0, 15 do
        bar[#bar + 1] = { math.abs(i - pos) < 2 and "━" or "─", math.abs(i - pos) < 3 and ("Px" .. wrap_i(h + i)) or ("Pf" .. wrap_i(h + i)) }
      end
      bar[#bar + 1] = { "  " .. bone.util.duration(os.time() - (j.started or os.time())), "PSoft" }
      local b = line(bar)
      line({})
      hits[a], hits[b] = #items, #items
    end
    line({ { "  ↵ open · x stop · tab chats", "PFaint" } })
    return L, hits, items
  end

  line({ { "  ⌕ ", "Px" .. wrap_i(6 - t) }, { st.query ~= "" and st.query or "search", st.query ~= "" and "PWhite" or "PFaint" },
         { st.focused and "▎" or "", "Px" .. wrap_i(t) } })
  line({})
  local maxtok = 1
  for _, s in ipairs(feed.sessions) do maxtok = math.max(maxtok, s.tokens) end
  local q = st.query:lower()
  local shown = 0
  for _, s in ipairs(feed.sessions) do
    if (s.title .. " " .. s.cwd):lower():find(q, 1, true) and (not s.archived or s.live or q ~= "") then
      shown = shown + 1
      items[#items + 1] = s
      local sel = #items == st.selected and st.focused
      local h = hue(s.cwd)
      local flow = sel and t or 0
      local edge = sel and "┃" or "▎"
      local mark = s.live and { (st.spinner or "◜") .. " ", "Px" .. wrap_i(t) } or (s.current and { "● ", "Px" .. wrap_i(h) } or { "", "Normal" })
      local room = width - 6 - bone.text.width(mark[1])
      local title = { { " ", "Normal" }, { edge, "Px" .. wrap_i(h - flow) }, { "  ", "Normal" }, mark }
      if sel then
        for _, g in ipairs(grad(bone.text.truncate(s.title, room), h - t, 0.6)) do title[#title + 1] = g end
      else
        title[#title + 1] = { bone.text.truncate(s.title, room), "Normal" }
      end
      local a = line(title)
      -- Project chip, token meter, age.
      local meter_w = 8
      local fill = s.tokens > 0 and math.max(1, math.floor(s.tokens / maxtok * meter_w + 0.5)) or 0
      local meta = { { " ", "Normal" }, { edge, "Px" .. wrap_i(h + 2 - flow) }, { "  ", "Normal" },
                     { " " .. bone.text.truncate(project(s.cwd), 14) .. " ", "Pc" .. wrap_i(h) }, { " ", "Normal" } }
      for i = 1, meter_w do
        meta[#meta + 1] = { i <= fill and "▰" or "▱", i <= fill and ("Px" .. wrap_i(h + i)) or "PFaint" }
      end
      meta[#meta + 1] = { " " .. D.tokens(s.tokens), "PSoft" }
      meta[#meta + 1] = { fill = " ", hl = "Normal" }
      meta[#meta + 1] = { (s.turns > 0 and (s.turns .. "↺ ") or "") .. D.ago(s.at) .. "  ", "PFaint" }
      local b = line(meta)
      line({})
      hits[a], hits[b] = #items, #items
    end
  end
  if shown == 0 then
    line({ { "  " .. (feed.loading and "loading…" or (q == "" and "no sessions yet" or "no matches")), "PFaint" } })
  end
  line({ { "  ↵ open · tab live · esc back", "PFaint" } })
  return L, hits, items
end

local function reveal()
  local info = panel:info()
  local first = st.lines_of[st.selected]
  if not first or not info.height or info.height == 0 then return end
  local top = info.top
  if first - 1 < top then top = first - 1
  elseif first + 2 > top + info.height then top = first + 2 - info.height end
  if top ~= info.top then panel:scroll(top - info.top) end
end

local function render(ctx)
  st.spinner, st.focused = ctx.spinner, ctx.focused
  local L, hits, items = build(ctx.width)
  st.hits, st.items, st.lines_of = hits, items, {}
  for line, i in pairs(hits) do
    if not st.lines_of[i] or line < st.lines_of[i] then st.lines_of[i] = line end
  end
  if st.selected > #items then st.selected = math.max(#items, 1) end
  local motion = bone.o.get and bone.o.get("prism_motion") or "full"
  if motion ~= "still" then bone.ui.refresh_in(motion == "calm" and 200 or 90) end
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
  st.page = st.page == "chats" and "live" or "chats"
  st.selected = 1
  panel:scroll("top")
end

function M.open()
  if panel and panel:is_open() then
    if bone.ui.panel.focused() == "sessions" then panel:close() else panel:focus() end
    return
  end
  st = { query = "", selected = 1, page = "chats", hits = {}, items = {}, lines_of = {} }
  feed = D.open(function()
    if not st.landed and not feed.loading then
      st.landed = true
      for i, s in ipairs(feed.sessions) do if s.current then st.selected = i end end
    end
  end)
  panel = bone.ui.panel.open({
    id = "sessions", dock = "left", size = 46, full_height = true, focus = true,
    render = render,
    keys = {
      esc = function() bone.ui.panel.focus(nil) end,
      ["ctrl+o"] = function() panel:close() end,
      tab = switch_page, ["shift+tab"] = switch_page,
      enter = function() choose(st.selected) end,
      up = function() move(-1) end, down = function() move(1) end,
      pageup = function() move(-6) end, pagedown = function() move(6) end,
      home = function() move(-#st.items) end, ["end"] = function() move(#st.items) end,
    },
    on_key = function(key)
      if st.page == "live" then
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
