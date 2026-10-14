-- The conversation sidebar (ctrl+o), drawn like the Codex app's: New
-- thread, Search, Diff, Processes and Plugins at the top, then threads in
-- collapsible categories (Running, Pinned, then by date or by project
-- folder, Archived), and Settings at the bottom. ctrl+b folds it into an
-- icon rail. The data, search, Processes page and keys are the standard
-- sidebar's.
local M = {}
local panel, state
local live, touched, versions, unread = {}, {}, {}, {}
local shells = {}
local agents = require("bone.agents")
local empty_row = {}
local archived = bone.state.load("sessions-archived")
local prefs = bone.state.load("codex-app-sidebar")
prefs.closed = prefs.closed or { Archived = true }
prefs.pinned = prefs.pinned or {}
prefs.group = prefs.group or "date"
local WIDTH, RAIL = 34, 5
local SHOWN = 8

local function save() bone.state.save("codex-app-sidebar", prefs) end

local function ago(at)
  if not at or at <= 0 then return "" end
  local age = math.max(0, os.time() - at)
  if age < 60 then return "now" end
  if age < 3600 then return math.floor(age / 60) .. "m" end
  if age < 86400 then return math.floor(age / 3600) .. "h" end
  if age < 7 * 86400 then return math.floor(age / 86400) .. "d" end
  if age < 35 * 86400 then return math.floor(age / (7 * 86400)) .. "w" end
  return os.date("%b %d", at)
end

local function activity(s)
  local meta = state.stats[s.session_id]
  return math.max(touched[s.session_id] or 0, meta and meta.at or s.created_at or 0)
end

local function base(p) return (p or ""):match("([^/]+)/*$") or "~" end

-- Local midnight, today and the days before.
local function midnight(days_ago)
  local t = os.date("*t")
  t.hour, t.min, t.sec = 0, 0, 0
  return os.time(t) - (days_ago or 0) * 86400
end

local function day_bucket(at)
  if at >= midnight(0) then return "Today" end
  if at >= midnight(1) then return "Yesterday" end
  if at >= midnight(7) then return "Previous 7 days" end
  return "Older"
end

function M.archive_current(id)
  id = id or (bone.chat.session() or {}).session_id
  if not id then return end
  archived[id] = true
  bone.state.save("sessions-archived", archived)
  if state then state.filter_dirty = true end
end

local function jobs()
  local out = {}
  for _, p in pairs(shells) do
    out[#out + 1] = { key = "shell:" .. p.id, shell = p, session_id = p.session_id,
      title = "$ " .. (p.command or p.id), detail = p.tail or "", started = math.floor((p.started_at_ms or 0) / 1000) }
  end
  for _, a in ipairs(agents.list()) do
    local id = a.id
    if live[id] then
      touched[id] = touched[id] or os.time()
      out[#out + 1] = { key = "agent:" .. id, session_id = id, title = a.name .. " · " .. (a.title or "sub-agent"),
        detail = "running", started = touched[id] }
    end
  end
  for _, j in ipairs(out) do j.chat = agents.top(j.session_id) end
  table.sort(out, function(a, b)
    if a.chat ~= b.chat then return a.chat < b.chat end
    if a.started ~= b.started then return a.started < b.started end
    return a.key < b.key
  end)
  return out
end

-- ---- what the top rows do --------------------------------------------------

local function has_diff() return bone.cmd.find("diff") ~= nil end

local function nav()
  local out = {
    { "✎", "New thread", "ctrl+n", function() bone.ui.panel.focus(nil); bone.action("new_session") end },
    { "⌕", "Search", "ctrl+o", function() M.expand(); panel:focus() end, search = true },
  }
  if has_diff() then
    out[#out + 1] = { "±", "Diff", "ctrl+d", function() bone.cmd("diff") end }
  end
  out[#out + 1] = { "◷", "Processes", "tab", function() M.expand(); M.switch_page() end, processes = true }
  out[#out + 1] = { "⧉", "Plugins", "", function() bone.cmd("catalog") end }
  return out
end

-- ---- rows ----------------------------------------------------------------------

local function begin_rows()
  state.lines, state.hits, state.descriptors, state.rows, state.visible_rows, state.actions = {}, {}, {}, {}, {}, {}
end

local function append(kind, index, action)
  local line = #state.rows + 1
  state.rows[line] = empty_row
  state.descriptors[line] = { kind, index }
  if action then state.actions[line] = action end
  return line
end

local function head_rows()
  append("top", nil, function() M.collapse() end)
  for i, n in ipairs(nav()) do append("nav", i, n[4]) end
  append("blank")
end

local function filter_running()
  local key = state.items[state.selected] and state.items[state.selected].key
  local titles = {}
  for _, s in ipairs(state.all) do titles[s.session_id] = s.title end
  for _, s in ipairs(bone.chat.sessions()) do
    if s.session_id then titles[s.session_id] = titles[s.session_id] or s.title end
  end
  state.filter_dirty = false
  state.items = jobs()
  begin_rows()
  state.running, state.titles = #state.items > 0, titles
  head_rows()
  append("section", { name = "Processes" })
  if #state.items == 0 then append("status") end
  local previous
  for i, j in ipairs(state.items) do
    if j.key == key then state.selected = i end
    if j.chat ~= previous then
      append("chat", i)
      previous = j.chat
    end
    local line = append("job", i)
    state.lines[i], state.hits[line] = line, i
  end
  state.selected = math.min(math.max(1, state.selected), #state.items)
end

local DATE_ORDER = { "Running", "Pinned", "Today", "Yesterday", "Previous 7 days", "Older", "Archived" }

local function filter(reset)
  if reset then state.initial = nil end
  if state.page == "running" then return filter_running() end
  local selected = not reset and state.items[state.selected]
  local id = selected and selected.session_id or (not reset and state.initial)
  state.filter_minute, state.filter_dirty = math.floor(os.time() / 60), false
  local query = state.query:lower()
  local here = (bone.chat.session() or {}).cwd
  local searching = query ~= ""

  -- Each thread lands in one category: Running, Pinned, Archived, else its
  -- day (or its project folder when grouped by project).
  local cats, order, activities, running = {}, {}, {}, false
  local function cat(name, label, sort)
    if not cats[name] then
      cats[name] = { name = name, label = label or name, threads = {}, sort = sort or 0 }
      order[#order + 1] = cats[name]
    end
    return cats[name]
  end
  for _, s in ipairs(state.all) do
    local sid = s.session_id
    if ((s.title or "") .. " " .. (s.cwd or "")):lower():find(query, 1, true) then
      local at = activity(s)
      activities[sid] = at
      running = running or live[sid]
      local c
      if live[sid] then c = cat("Running")
      elseif prefs.pinned[sid] then c = cat("Pinned")
      elseif archived[sid] then c = cat("Archived")
      elseif prefs.group == "project" then
        c = cat("project:" .. (s.cwd or ""), base(s.cwd), (s.cwd == here) and math.huge or 0)
        c.project = true
      else
        c = cat(day_bucket(at))
      end
      c.threads[#c.threads + 1] = s
      if c.project then c.sort = math.max(c.sort, at) end
    end
  end
  local rank = {}
  for i, n in ipairs(DATE_ORDER) do rank[n] = i end
  table.sort(order, function(a, b)
    local ra = rank[a.name] or (a.project and 3) or 99
    local rb = rank[b.name] or (b.project and 3) or 99
    if a.name == "Archived" then ra = 99 end
    if b.name == "Archived" then rb = 99 end
    if ra ~= rb then return ra < rb end
    if a.sort ~= b.sort then return a.sort > b.sort end
    return a.name < b.name
  end)

  state.items, state.cats = {}, order
  begin_rows()
  state.activities, state.running = activities, running
  head_rows()
  append("threads", nil, function()
    prefs.group = prefs.group == "date" and "project" or "date"
    save()
    state.filter_dirty = true
  end)
  if state.loading or #order == 0 then append("status") end
  for ci, c in ipairs(order) do
    table.sort(c.threads, function(a, b)
      local aa, ba = activities[a.session_id], activities[b.session_id]
      if aa ~= ba then return aa > ba end
      return a.session_id < b.session_id
    end)
    local closed = prefs.closed[c.name] and not searching
    append("category", ci, function()
      prefs.closed[c.name] = not prefs.closed[c.name] or nil
      save()
      state.filter_dirty = true
    end)
    if not closed then
      local limit = (searching or state.more[c.name]) and math.huge or SHOWN
      for k, s in ipairs(c.threads) do
        if k > limit then
          append("more", #c.threads - limit, function() state.more[c.name] = true; state.filter_dirty = true end)
          break
        end
        state.items[#state.items + 1] = s
        local i = #state.items
        if s.session_id == id then state.selected = i end
        local line = append("thread", i)
        state.lines[i], state.hits[line] = line, i
      end
    end
  end
  state.selected = math.min(math.max(1, state.selected), #state.items)
end

local function reveal(info)
  info = info or panel:info()
  local first = state.lines[state.selected]
  if not first or not info.height or info.height == 0 then return end
  local top = info.top
  if first < top + 1 then
    top = first - 1
  elseif first > top + info.height - 1 then
    top = first + 1 - info.height
  end
  panel:scroll(top - info.top)
  info.top = top
end

local function choose(index)
  local s = state.items[index]
  if not s then return end
  bone.ui.panel.focus(nil)
  bone.api.open_session(s.session_id)
end

function M.switch_page()
  if not state then return end
  state.initial = nil
  state.pages[state.page] = { items = state.items, selected = state.selected, top = panel:info().top }
  state.page = state.page == "running" and "chats" or "running"
  local saved = state.pages[state.page] or { items = {}, selected = 1, top = 0 }
  state.items, state.selected = saved.items, saved.selected
  filter()
  panel:scroll(saved.top - panel:info().top)
end

-- x on the Processes page: stop the selected shell or sub-agent.
local function stop()
  local j = state.items[state.selected]
  if not j then return end
  if j.shell then
    bone.request("process/cancel", { session_id = j.session_id, id = j.shell.id })
  else
    bone.request("turn/cancel", { session_id = j.session_id })
  end
end

local function move(delta)
  state.initial = nil
  state.selected = math.max(1, math.min(#state.items, state.selected + delta))
  reveal()
end

local function toggle_pin()
  local s = state.page == "chats" and state.items[state.selected]
  if not s then return end
  prefs.pinned[s.session_id] = not prefs.pinned[s.session_id] or nil
  save()
  filter()
  reveal()
end

-- ---- drawing -----------------------------------------------------------------

local function line(spans)
  for _, sp in ipairs(spans) do
    if sp.fill then return spans end
  end
  spans[#spans + 1] = { fill = " ", hl = "SideBg" }
  return spans
end

-- The folded sidebar: one icon per row.
local function render_rail(ctx)
  local out, items = {}, nav()
  state.rail_actions = {}
  local function add(text, hl, action)
    out[#out + 1] = { { "  " .. text, hl }, { fill = " ", hl = "SideBg" } }
    if action then state.rail_actions[#out] = action end
  end
  add("»", "SideIcon", function() M.expand() end)
  for _, n in ipairs(items) do add(n[1], "SideIcon", n[4]) end
  out[#out + 1] = line({})
  local busy = 0
  for _ in pairs(live) do busy = busy + 1 end
  local waiting = 0
  for _ in pairs(unread) do waiting = waiting + 1 end
  if busy > 0 then add(ctx.spinner, "SideAccent", function() M.expand() end) end
  if waiting > 0 then add("●", "SideAccent", function() M.expand() end) end
  while #out < ctx.height - 1 do out[#out + 1] = line({}) end
  add("⚙", "SideIcon", function() bone.cmd("config") end)
  if bone.ui.refresh_in and busy > 0 then bone.ui.refresh_in((bone.ui.spinner and bone.ui.spinner.interval) or 120) end
  return out
end

local function render(ctx)
  for _, s in ipairs(bone.chat.sessions()) do
    if s.session_id and s.running and not live[s.session_id] then
      live[s.session_id] = true
      state.filter_dirty = true
    end
  end
  local current = (bone.chat.session() or {}).session_id
  if current and unread[current] then unread[current] = nil end
  if prefs.rail then return render_rail(ctx) end
  if state.filter_dirty or state.filter_minute ~= math.floor(os.time() / 60) then
    filter()
  end
  if state.initial and state.page == "chats" and not state.loading
      and not state.stats_loading and ctx.height > 0 then
    state.initial = nil
    reveal(ctx)
  end
  local w = ctx.width
  local items = nav()
  local out = state.rows
  for _, l in ipairs(state.visible_rows) do out[l] = empty_row end
  state.visible_rows = {}
  local top = math.min(ctx.top, math.max(0, #out - ctx.height))
  for l = math.max(1, top + 1), math.min(#out, top + ctx.height) do
    local kind, index = state.descriptors[l][1], state.descriptors[l][2]
    local f
    if kind == "top" then
      f = line({ { fill = " ", hl = "SideBg" }, { "«  ", "SideIcon" } })
    elseif kind == "nav" then
      local n = items[index]
      local on = (n.processes and state.page == "running") or (n.search and ctx.focused and state.page == "chats")
      local bg = on and "SideActive" or "SideBg"
      local label, label_hl = n[2], on and "SideActive" or "SideText"
      if n.search and state.query ~= "" then label, label_hl = state.query, "SideAccent" end
      if n.search and ctx.focused and state.query == "" then label, label_hl = "Type to search", "SideActiveDim" end
      local hint = n[3]
      if n.processes then
        local count = state.page == "running" and #state.items or #jobs()
        hint = count > 0 and tostring(count) or hint
      end
      f = line({ { "  ", "SideBg" }, { " " .. n[1] .. "  ", on and "SideActiveDim" or "SideIcon" }, { label, label_hl },
                 { fill = " ", hl = bg }, { hint .. " ", on and "SideActiveDim" or "SideDim" }, { " ", "SideBg" } })
    elseif kind == "threads" then
      f = line({ { "  Threads", "SideDim" }, { fill = " ", hl = "SideBg" },
                 { (prefs.group == "date" and "by date" or "by project") .. " ⇄  ", "SideDim" } })
    elseif kind == "section" then
      f = line({ { "  " .. index.name, "SideDim" } })
    elseif kind == "category" then
      local c = state.cats[index]
      local closed = prefs.closed[c.name] and state.query == ""
      local icon = c.project and "▭ " or (c.name == "Running" and "◜ " or c.name == "Pinned" and "★ " or "")
      f = line({ { "  " .. (closed and "▸ " or "▾ "), "SideDim" }, { icon, "SideIcon" },
                 { bone.text.truncate(c.label, w - 12), c.project and "SideMuted" or "SideHead" },
                 { fill = " ", hl = "SideBg" }, { #c.threads .. "  ", "SideDim" } })
    elseif kind == "thread" then
      local s = state.items[index]
      local sid = s.session_id
      local sel = index == state.selected and ctx.focused
      local bg = (sel and "SideSelect") or (sid == current and "SideActive") or "SideBg"
      local dim = (sel and "SideSelectDim") or (sid == current and "SideActiveDim") or "SideDim"
      local mark = live[sid] and { ctx.spinner .. " ", bg == "SideBg" and "SideAccent" or bg }
        or unread[sid] and { "● ", bg == "SideBg" and "SideAccent" or bg }
        or { "  ", bg }
      local age = live[sid] and "" or ago(state.activities[sid])
      local title = (s.title and s.title:gsub("%s+", " ")) or "untitled"
      f = line({ { "    ", "SideBg" }, mark, { bone.text.truncate(title, math.max(1, w - 10 - #age)), bg == "SideBg" and "SideText" or bg },
                 { fill = " ", hl = bg }, { age .. " ", dim }, { " ", "SideBg" } })
    elseif kind == "more" then
      f = line({ { "      Show " .. index .. " more", "SideDim" } })
    elseif kind == "chat" then
      f = line({ { "  " .. bone.text.truncate(state.titles[state.items[index].chat] or "untitled", w - 4), "SideMuted" } })
    elseif kind == "job" then
      local j = state.items[index]
      local sel = index == state.selected and ctx.focused
      local bg = sel and "SideSelect" or "SideBg"
      f = line({ { "    ", "SideBg" }, { ctx.spinner .. " ", sel and bg or "SideAccent" },
                 { bone.text.truncate(j.title:gsub("%s+", " "), w - 14), sel and bg or "SideText" }, { fill = " ", hl = bg },
                 { bone.util.duration(os.time() - j.started) .. " ", sel and "SideSelectDim" or "SideDim" }, { " ", "SideBg" } })
    elseif kind == "status" then
      f = line({ { "    " .. (state.page == "running" and "Nothing running" or state.loading and "Loading…"
        or (state.query == "" and "No threads yet" or "No matching threads")), "SideDim" } })
    else
      f = line({})
    end
    out[l] = f
    state.visible_rows[#state.visible_rows + 1] = l
  end
  if bone.ui.refresh_in then
    bone.ui.refresh_in(state.running and ((bone.ui.spinner and bone.ui.spinner.interval) or 120) or (60 - os.time() % 60) * 1000)
  end
  -- Keys while it has the keyboard, then Settings, on the last rows while
  -- the list leaves room for them.
  state.settings_line = nil
  local foot = {}
  if ctx.focused then
    foot[#foot + 1] = line({ { "  " .. (state.page == "running" and "↵ open · x stop · tab threads"
      or "↵ open · alt+p pin · alt+g group"), "SideDim" } })
  end
  foot[#foot + 1] = line({ { "  ", "SideBg" }, { " ⚙  ", "SideIcon" }, { "Settings", "SideText" } })
  if #out + #foot <= ctx.height then
    local padded = {}
    for i = 1, ctx.height - #foot do padded[i] = out[i] or line({}) end
    for _, f in ipairs(foot) do padded[#padded + 1] = f end
    state.settings_line = ctx.height
    return padded
  end
  return out
end

local function setup_colors()
  local c = bone.ui.codex_colors or {}
  local side, active, select = c.side or "#121212", c.active or "#262626", c.select or "#2d2d2d"
  local set = bone.hl.set
  set("SideBg", { bg = side })
  set("SideText", { fg = c.fg or "#e3e4e6", bg = side })
  set("SideHead", { fg = c.muted or "#b6b6b6", bg = side, bold = true })
  set("SideMuted", { fg = c.muted or "#b6b6b6", bg = side })
  set("SideDim", { fg = c.dim or "#6d6d6d", bg = side })
  set("SideIcon", { fg = c.icon or "#8b8b8b", bg = side })
  set("SideAccent", { fg = c.accent or "#7aa2f7", bg = side })
  set("SideActive", { fg = c.fg or "#e3e4e6", bg = active })
  set("SideActiveDim", { fg = c.dim or "#6d6d6d", bg = active })
  set("SideSelect", { fg = c.fg or "#ffffff", bg = select })
  set("SideSelectDim", { fg = c.muted or "#b6b6b6", bg = select })
end

-- ---- loading -------------------------------------------------------------------

local function refresh_stats(st, p)
  bone.request("store/query", { sql = [[
    SELECT s.id, s.updated_at, coalesce(u.tokens, 0), coalesce(m.turns, 0)
    FROM sessions s
    LEFT JOIN (SELECT session_id, sum(input_tokens + output_tokens) AS tokens
               FROM usage GROUP BY session_id) u ON u.session_id = s.id
    LEFT JOIN (SELECT session_id, count(*) AS turns FROM messages
               WHERE role = 'user' GROUP BY session_id) m ON m.session_id = s.id
  ]] }, function(res, err)
    if state ~= st or not p:is_open() then return end
    st.stats_loading = false
    if not err and res then
      for _, r in ipairs(res.rows or {}) do
        st.stats[r[1]] = { at = r[2], tokens = r[3], turns = r[4] }
      end
      filter()
    end
  end)
end

local function refresh_list(st, p)
  bone.request("session/list", {}, function(list, err)
    if state ~= st or not p:is_open() then return end
    st.loading = false
    if err then
      bone.notify("cannot list sessions: " .. tostring(err), "error")
      filter()
      return
    end
    st.all = {}
    for _, s in ipairs(list or {}) do
      if s.owner then
        agents.add(s)
      else
        st.all[#st.all + 1] = s
      end
    end
    filter()
  end)
end

-- opts.focus = false opens it without taking the keyboard (at startup).
function M.open(opts)
  opts = opts or {}
  if panel and panel:is_open() then
    if opts.focus == false then return end
    if prefs.rail then M.expand(); panel:focus(); return end
    if bone.ui.panel.focused() == "sessions" then bone.ui.panel.focus(nil) else panel:focus() end
    return
  end
  state = { all = {}, items = {}, stats = {}, lines = {}, hits = {}, actions = {}, more = {}, cats = {},
    selected = 1, query = "", loading = true, stats_loading = true, page = "chats", pages = {},
    initial = (bone.chat.session() or {}).session_id }
  local st = state
  setup_colors()
  panel = bone.ui.panel.open({
    id = "sessions", dock = "left", size = prefs.rail and RAIL or WIDTH, full_height = true, separator = false,
    focus = opts.focus ~= false and not prefs.rail,
    render = render,
    keys = {
      esc = function()
        if state.query ~= "" then state.query = ""; filter(true); return end
        bone.ui.panel.focus(nil)
      end,
      ["ctrl+o"] = function() bone.ui.panel.focus(nil) end,
      ["ctrl+n"] = function() bone.ui.panel.focus(nil); bone.action("new_session") end,
      ["ctrl+b"] = function() M.toggle() end,
      ["alt+p"] = toggle_pin,
      ["alt+g"] = function()
        prefs.group = prefs.group == "date" and "project" or "date"
        save()
        filter()
      end,
      tab = M.switch_page, ["shift+tab"] = M.switch_page,
      enter = function() choose(state.selected) end,
      up = function() move(-1) end, down = function() move(1) end,
      pageup = function() move(-math.max(1, math.floor(panel:info().height / 3))) end,
      pagedown = function() move(math.max(1, math.floor(panel:info().height / 3))) end,
      home = function() move(-#state.items) end, ["end"] = function() move(#state.items) end,
    },
    on_key = function(key)
      if state.page == "running" then
        if key == "x" then stop() return true end
        return false
      elseif bone.text.edit(state.query, key) then
        state.query = bone.text.edit(state.query, key)
      else
        return false
      end
      state.selected = 1
      filter(true)
      panel:scroll("top")
      return true
    end,
  })
  local p = panel
  refresh_list(st, p)
  refresh_stats(st, p)
  bone.request("processes/list", {}, function(res, err)
    if err or not res then return end
    shells = {}
    for _, proc in ipairs(res.processes or {}) do
      if proc.running and proc.terminal then shells[proc.id] = proc end
    end
    if state == st and p:is_open() then filter() end
  end)
  local before = {}
  for id, version in pairs(versions) do before[id] = version end
  bone.request("session/active", {}, function(ids, err)
    if state ~= st or not p:is_open() or err then return end
    local active = {}
    for _, id in ipairs(ids or {}) do active[id] = true end
    for id in pairs(live) do
      if versions[id] == before[id] then live[id] = active[id] end
    end
    for id in pairs(active) do
      if versions[id] == before[id] then live[id] = true end
    end
    filter()
  end)
end

-- Folded into the icon rail, or back to full width.
function M.collapse()
  prefs.rail = true
  save()
  if panel and panel:is_open() then
    if bone.ui.panel.focused() == "sessions" then bone.ui.panel.focus(nil) end
    panel:update({ size = RAIL })
  end
end

function M.expand()
  prefs.rail = nil
  save()
  if panel and panel:is_open() then
    panel:update({ size = WIDTH })
    state.filter_dirty = true
  else
    M.open({ focus = false })
  end
end

-- ctrl+b.
function M.toggle()
  if not panel or not panel:is_open() then return M.open({ focus = false }) end
  if prefs.rail then M.expand() else M.collapse() end
end

local function turn_changed(ev, running)
  local id = ev.session_id
  if not id then return end
  versions[id] = (versions[id] or 0) + 1
  live[id], touched[id] = running or nil, os.time()
  if not running and id ~= (bone.chat.session() or {}).session_id then unread[id] = true end
  if running and archived[id] then
    archived[id] = nil
    bone.state.save("sessions-archived", archived)
  end
  if panel and panel:is_open() then
    filter()
    if running then refresh_list(state, panel) end
    refresh_stats(state, panel)
  end
end
bone.on("turn/started", function(ev) turn_changed(ev, true) end)
bone.on("turn/finished", function(ev) turn_changed(ev, false) end)
local function running_changed()
  if panel and panel:is_open() and state.page == "running" then state.filter_dirty = true end
end
bone.on("session/created", function()
  if panel and panel:is_open() then refresh_list(state, panel) end
end)
bone.on("process/changed", function(ev)
  local proc = ev.process or {}
  if proc.running and proc.terminal then
    shells[proc.id] = proc
  elseif not shells[proc.id] then
    return
  else
    shells[proc.id] = nil
  end
  running_changed()
end)
bone.on("session/updated", function()
  if panel and panel:is_open() then refresh_list(state, panel) end
end)
bone.on("session/deleted", function(ev)
  live[ev.session_id], touched[ev.session_id] = nil, nil
  for id, proc in pairs(shells) do
    if proc.session_id == ev.session_id then shells[id] = nil end
  end
  if panel and panel:is_open() then refresh_list(state, panel) end
end)
bone.on("chat/shown", function()
  if panel and panel:is_open() then state.filter_dirty = true end
end)

bone.on("mouse", function(ev)
  if not panel or not panel:is_open() or ev.panel ~= "sessions" then return end
  state.initial = nil
  if ev.button == "left" and ev.action == "down" then
    if prefs.rail then
      local action = (state.rail_actions or {})[ev.panel_line]
      if action then action() end
      return true
    end
    local index = state.hits[ev.panel_line]
    local action = state.actions[ev.panel_line]
    if index and state.page == "chats" then
      choose(index)
    elseif index then
      state.selected = index
    elseif action then
      action()
    elseif state.settings_line and ev.panel_line == state.settings_line then
      bone.cmd("config")
    end
    return true
  end
end)

return M
