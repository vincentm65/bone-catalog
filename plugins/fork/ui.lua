local alive, serial, window, pending = true, 0, nil, nil
local function notify(err) bone.notify("fork: " .. tostring(err), "error") end
local function current() return (bone.api.session() or {}).session_id end
-- The desktop library's widgets and sizes. Without them (an older bone) the
-- same calls make bare nodes: the layout and presses stay, the look does not.
local has_w, W = pcall(require, "bone.nodes.widgets")
local has_s, S = pcall(require, "bone.nodes.style")
if not (has_w and has_s and type(W.list) == "function" and bone.gui and bone.gui.scroll_item) then
  S = { size = {}, radius = {}, space = { xs = 2, sm = 4, md = 8, lg = 12, xl = 16 } }
  local function press(node, click, role)
    node.on_click, node.cursor, node.role = click, "pointer", role or "button"
    return node
  end
  local function choices(names, current, pick)
    local row = { direction = "row", gap = 12 }
    for i, name in ipairs(names) do
      row[i] = press({ text = name, hl = i == current and "Normal" or "Dim", selected = i == current },
        function() pick(i) end, "option")
    end
    return row
  end
  W = {
    press = press,
    title = function(text) return { text = text, bold = true } end,
    note = function(text, _, hl) return { text = text, hl = hl or "Dim" } end,
    pill = function(text, o) return { text = text, hl = (o or {}).hl or "Accent" } end,
    divider = function() return { height = 1 } end,
    hints = function(text) return { text = text, hl = "Dim" } end,
    button = function(label, click, primary, _, o)
      local node = press({ text = label, hl = primary and "Accent" or "Normal" }, click)
      for k, v in pairs(o or {}) do node[k] = v end
      return node
    end,
    checkbox = function(on) return { text = on and "☑" or "☐", hl = on and "Accent" or "Dim", role = "checkbox", selected = on } end,
    link = function(text, click) return press({ text = text, hl = "Accent" }, click, "link") end,
    icon_button = function(glyph, label, click) return press({ text = glyph, label = label }, click) end,
    segmented = choices,
    tabs = choices,
    surface = function(o) return o or {} end,
    entry = function(on, children, click)
      local node = { direction = "column", bg = on and "Selection" or nil, selected = on }
      for _, c in ipairs(children) do node[#node + 1] = c end
      return click and press(node, click, "option") or node
    end,
    list = function(list_id, items, _, opts)
      local col = { id = list_id, direction = "column", grow = 1, overflow = "scroll" }
      for i, item in ipairs(items) do col[i] = item end
      if not (opts and opts.footer) then return col end
      return { direction = "column", grow = 1, col, opts.footer }
    end,
    field = function(label, value, o)
      o = o or {}
      local node = { text = label .. ": " .. value .. (o.editing and "▏" or "") }
      return o.click and press(node, o.click) or node
    end,
  }
end
local function close()
  if window then bone.ui.close(window); window = nil end
end
bone.plugin.on_shutdown(function() alive = false; pending = nil; close() end)

-- open_session loads asynchronously. Prefill only once the intended chat is
-- shown, never the old source chat or an unrelated chat the user switched to.
local function prefill()
  if not alive or not pending or current() ~= pending.id then return end
  local p = pending
  pending = nil
  if not bone.prompt.empty() then
    return notify("draft changed while loading; kept your edits instead of restoring the selected message")
  end
  local ok, err = pcall(function()
    if bone.prompt and bone.prompt.set_images then bone.prompt.set_images(p.draft.images or {}) end
    bone.api.prompt_set(p.draft.text or "")
  end)
  if not ok then notify("draft restoration failed; original text/images remain in the source session: " .. tostring(err)) end
end
bone.on("chat/shown", prefill)
local function create(id, n, tree, valid, done)
  local draft = n and tree.points[n]
  if draft and #(draft.images or {}) > 0 and not (bone.prompt and bone.prompt.set_images) then
    if done then done(false) end
    return notify("this TUI cannot restore image attachments; fork was not created")
  end
  bone.rpc.call("fork.create", { session_id = id, before_turn = n, expected = tree.expected }, function(r, err)
    if not valid() then return end
    if err or not r then if done then done(false) end; return notify(err or "no result") end
    if r.warning then notify(r.warning) end
    close()
    pending = r.draft and { id = r.info.session_id, draft = r.draft } or nil
    bone.api.open_session(r.info.session_id)
    prefill()
  end)
end

local function popup(origin, token)
  local st = { selected = 1, top = 1, page = 12, rows = {}, expanded = {}, cache = {},
    infos = {}, edges = {}, loading = {}, status = "Loading family…", busy = false }
  local function valid() return alive and serial == token and window and bone.ui.is_open(window) and current() == origin end
  local rebuild, fetch
  rebuild = function()
    local selected = st.rows[st.selected]
    local key = selected and selected.key
    local root, seen = origin, {}
    while st.edges[root] and not seen[root] do seen[root] = true; root = st.edges[root].parent end
    local children = {}
    for id, e in pairs(st.edges) do
      children[e.parent] = children[e.parent] or {}
      children[e.parent][#children[e.parent] + 1] = id
    end
    for _, ids in pairs(children) do table.sort(ids) end
    st.rows, seen = {}, {}
    local function visit(id, depth)
      if seen[id] then return end
      seen[id] = true
      st.rows[#st.rows + 1] = { key = id, id = id, depth = depth, parent = st.edges[id] and st.edges[id].parent }
      if not st.expanded[id] then return end
      local tree = st.cache[id]
      for _, p in ipairs(tree and tree.points or {}) do
        -- A child copied the prefix immediately before this user point.
        for _, child in ipairs(children[id] or {}) do
          if st.edges[child].before_turn == p.before_turn then visit(child, depth + 1) end
        end
        st.rows[#st.rows + 1] = { key = id .. ":" .. p.before_turn, id = id, depth = depth + 1, point = p, parent = id }
      end
      -- Whole copies, unknown/legacy cutoffs and unloaded/missing parents.
      for _, child in ipairs(children[id] or {}) do visit(child, depth + 1) end
    end
    visit(root, 0)
    for i, row in ipairs(st.rows) do if row.key == key then st.selected = i end end
    st.selected = math.max(1, math.min(st.selected, #st.rows))
  end
  fetch = function(id, sessions, initial)
    if st.loading[id] then return end
    st.loading[id] = true
    bone.rpc.call("fork.tree", { session_id = id, sessions = sessions }, function(r, err)
      if not valid() then return end
      st.loading[id] = nil
      if err or not r then st.status, st.failed = "Cannot load branch", true; return notify(err or "no result") end
      st.status, st.cache[id] = "", r
      for sid, e in pairs(r.edges or {}) do st.edges[sid] = e end
      for _, info in ipairs(r.sessions or {}) do
        if not st.infos[info.session_id] then st.infos[info.session_id] = info end
      end
      st.infos[id] = r.snapshot.info
      if initial then
        local ancestor, seen = origin, {}
        while ancestor and not seen[ancestor] do
          seen[ancestor], st.expanded[ancestor] = true, true
          ancestor = st.edges[ancestor] and st.edges[ancestor].parent
        end
      end
      rebuild()
      if initial then for i, row in ipairs(st.rows) do if row.key == origin then st.selected = i end end end
      if bone.ui.update and window then bone.ui.update(window, {}) end
    end)
  end
  local function move(n) st.selected = math.max(1, math.min(#st.rows, st.selected + n)) end
  local function right()
    local row = st.rows[st.selected]
    if not row or row.point then return end
    st.expanded[row.id] = true
    rebuild()
    if not st.cache[row.id] and (st.infos[row.id] or {}).cwd then fetch(row.id) end
  end
  local function left()
    local row = st.rows[st.selected]
    if not row then return end
    if not row.point and st.expanded[row.id] then st.expanded[row.id] = nil; rebuild(); return end
    for i, r in ipairs(st.rows) do if r.key == row.parent then st.selected = i; return end end
  end
  local function enter()
    if st.busy then return end
    local row = st.rows[st.selected]
    if not row then return end
    if not row.point then
      if not (st.infos[row.id] or {}).cwd then return notify("ancestor session is missing") end
      close(); bone.api.open_session(row.id); return
    end
    if not row.point.safe then return notify("unsafe steering cutoff: unresolved tool calls") end
    st.busy = true
    create(row.id, row.point.before_turn, st.cache[row.id], valid, function() st.busy = false end)
  end
  -- What a row is, for both frontends; each lays it out its own way.
  local function describe(row)
    if row.point then
      local p = row.point
      return { point = true, turn = p.before_turn, images = #(p.images or {}), unsafe = not p.safe,
        text = (p.text ~= "" and p.text or "[image message]"):gsub("%s+", " ") }
    end
    local info, e = st.infos[row.id] or {}, st.edges[row.id]
    return { open = st.expanded[row.id], current = row.id == origin, loading = st.loading[row.id],
      missing = not info.cwd, text = info.title or row.id,
      edge = e and (e.before_turn and ("before #" .. e.before_turn) or e.legacy and "legacy (unknown cutoff)" or "copy") }
  end
  local function row_label(row)
    local d = describe(row)
    if d.point then
      local label = "↳ " .. d.turn .. "  " .. d.text
      if d.images > 0 then label = label .. "  [" .. d.images .. " image(s)]" end
      if d.unsafe then label = label .. " [unsafe cutoff]" end
      return label
    end
    local label = (d.open and "▾ " or "▸ ") .. d.text
    if d.current then label = label .. "  ●" end
    if d.edge then label = label .. "  ← " .. d.edge end
    if d.loading then label = label .. " …" end
    if d.missing then label = label .. " [missing]" end
    return label
  end
  local function fold(row)
    if st.expanded[row.id] then st.expanded[row.id] = nil; rebuild() else right() end
  end
  local function touch()
    if bone.ui.update and window then bone.ui.update(window, {}) end
  end
  -- A press selects a row and folds a session; a double press opens or forks.
  local function pick(i, row)
    return function()
      st.selected = i
      if not row.point then fold(row) end
      touch()
    end
  end
  local function choose(i)
    return function() st.selected = i; enter(); touch() end
  end
  local function action()
    local row = st.rows[st.selected]
    if not row then return "Open", false end
    if row.point then return st.busy and "Creating…" or "Fork here", row.point.safe and not st.busy end
    return "Open", (st.infos[row.id] or {}).cwd ~= nil
  end

  -- The desktop library's window: entries, pills and buttons look like the
  -- rest of the app; only the row contents are fork's.
  local function session_row(d, on)
    local row = { direction = "row", align = "center", gap = S.space.md }
    local function add(node) row[#row + 1] = node end
    add({ text = d.open and "▾" or "▸", hl = "Dim", size = S.size.caption, width = 12, shrink = 0, wrap = false })
    add({ text = d.text, hl = d.missing and "Dim" or "Normal", size = S.size.body, bold = on or nil,
      grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" })
    if d.edge then add({ text = d.edge, hl = "Dim", size = S.size.small, wrap = false, shrink = 0 }) end
    if d.loading and W.spinner then add(W.spinner(14)) end
    if d.current then add(W.pill("CURRENT")) end
    if d.missing then add(W.pill("MISSING", { hl = "ErrorMsg", bg = "Selection" })) end
    return row
  end
  local function point_row(d, on)
    local row = { direction = "row", align = "center", gap = S.space.md }
    local function add(node) row[#row + 1] = node end
    add({ text = "#" .. d.turn, hl = "Dim", font = "mono", size = S.size.small, width = 28, shrink = 0, wrap = false })
    add({ text = d.text, hl = on and "Normal" or "Dim", size = S.size.caption,
      grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" })
    if d.images > 0 then
      add(W.pill(d.images .. (d.images == 1 and " IMAGE" or " IMAGES"), { hl = "Dim", bg = "Selection" }))
    end
    if d.unsafe then add(W.pill("UNSAFE", { hl = "WarningMsg", bg = "Selection" })) end
    return row
  end
  local function styled_node()
    local items = { W.title("Fork") }
    local status = st.failed and "ErrorMsg" or "Dim"
    items[#items + 1] = W.note(#st.rows == 0 and st.status
      or "This chat's branches, and the messages each one can fork before.", { 0, 6 }, status)
    local at
    for i, row in ipairs(st.rows) do
      local on, d = i == st.selected, describe(row)
      local entry = W.entry(on, { d.point and point_row(d, on) or session_row(d, on) }, pick(i, row))
      entry.padding = { 6, 12, 6, 12 + math.min(row.depth or 0, 12) * 18 }
      entry.on_double_click = choose(i)
      items[#items + 1] = entry
      if on then at = #items end
    end
    local label, ready = action()
    local keys = W.hints("↑↓ move · ←→ fold · enter open/fork · esc close", { 0, 0 })
    keys.grow, keys.width = 1, 0
    local footer = {
      direction = "row", align = "center", gap = S.space.md, margin = { 10, 0, 0, 0 },
      keys,
      W.button(label, function() if ready then enter() end end, ready),
      W.button("Close", close),
    }
    -- A fixed card, like the app's other windows: one sized to its rows
    -- would open at their estimate and jump when they are measured.
    return W.list("fork:rows", items, at, { footer = footer })
  end

  close()
  window = bone.ui.popup{
    width = 84, height = 22, anchor = "screen", guard = 100,
    lines = function(ctx)
      local width = math.max(8, math.min(84, ctx.width))
      st.page = math.max(1, math.min(18, ctx.height - 4))
      st.top = math.max(1, math.min(st.top, st.selected))
      if st.selected >= st.top + st.page then st.top = st.selected - st.page + 1 end
      local lines = {}
      for i = st.top, math.min(#st.rows, st.top + st.page - 1) do
        local row = st.rows[i]
        local text = string.rep("  ", math.min(row.depth, 12)) .. row_label(row)
        text = bone.text.truncate(text, width - 4)
        lines[#lines + 1] = { { text, i == st.selected and "Selection" or row.point and "Dim" or "Normal" } }
      end
      if #lines == 0 then lines[1] = { { st.status, "Dim" } } end
      lines[#lines + 1] = { { st.busy and "Creating…" or "↑↓/wheel move · ←→ fold · Enter open/fork · Esc close", "Dim" } }
      return bone.ui.box(lines, { title = "Fork · session family", width = width })
    end,
    keys = { esc = close, q = close, up = function() move(-1) end, down = function() move(1) end,
      wheelup = function() move(-3) end, wheeldown = function() move(3) end,
      pageup = function() move(-st.page) end, pagedown = function() move(st.page) end,
      home = function() move(-#st.rows) end, ["end"] = function() move(#st.rows) end,
      left = left, right = right, enter = enter },
    node = function()
      return styled_node()
    end,
  }
  bone.request("session/list", {}, function(list, err)
    if not valid() then return end
    if err then st.status, st.failed = "Cannot list sessions", true; return notify(err) end
    for _, info in ipairs(list or {}) do st.infos[info.session_id] = info end
    fetch(origin, list, true)
  end)
end

bone.cmd.create("fork", function(c)
  local origin = current()
  if not origin then return notify("no current session") end
  local arg = (c.args or ""):match("^%s*(.-)%s*$")
  if arg ~= "" and arg ~= "copy" and not arg:match("^[1-9]%d*$") then return notify("usage: /fork [N|copy]") end
  serial = serial + 1
  local token = serial
  close(); pending = nil
  if arg == "" then return popup(origin, token) end
  local function valid() return alive and serial == token and current() == origin end
  bone.rpc.call("fork.tree", { session_id = origin }, function(tree, err)
    if not valid() then return end
    if err or not tree then return notify(err or "no result") end
    create(origin, arg ~= "copy" and tonumber(arg) or nil, tree, valid)
  end)
end, { desc = "Browse forks, fork before user message N, or copy the whole session" })
