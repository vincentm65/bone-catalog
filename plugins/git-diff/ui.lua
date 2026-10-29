-- Read-only Git diff sidebar for the terminal (render) and the desktop app
-- (node). Keys, modes, jobs and limits are shared; the desktop pointer
-- repeats the terminal's mouse hits.
local diff = require("git_diff")
local tree = require("git_diff_tree")
local files, nodes, collapsed, hits = {}, {}, {}, {}
local selected, active = 1, nil
local panel, job, cwd, session_id
local mode, rows = "all", {}
local generation, watcher = 0, 0
local cache, cache_width
local labels = { all = "All tracked", unstaged = "Unstaged", staged = "Staged" }

local function session()
  local s = bone.chat.session()
  return s and s.cwd, s and s.session_id
end

local function set_rows(value)
  rows, cache, cache_width = value, nil, nil
  files, active, selected = tree.files(value), nil, 1
  nodes = tree.nodes(files, collapsed)
  hits = {}
end

local function message(text, group)
  set_rows({ { text = text, group = group or "ToolSummary" } })
end

local function stop_job()
  generation = generation + 1
  local previous = job
  job = nil
  if previous then previous:cancel() end
end

local function invalidate()
  cache, cache_width = nil, nil
end

local function desktop()
  if bone.has_capability and bone.has_capability("gui.nodes") and type(bone.gui) == "table" then
    return bone.gui
  end
end

local function body_id()
  if active or #files == 0 then return "git-diff-body" end
  return "git-diff-tree"
end

local function gui_scroll(id, to)
  local gui = desktop()
  if not gui or not gui.scroll then return end
  gui.scroll(id, to)
end

local function back()
  active = nil
  invalidate()
  panel:scroll("top")
  gui_scroll("git-diff-body", "top")
  gui_scroll("git-diff-tree", "top")
end

local function choose(index)
  selected = math.max(1, math.min(index or selected, #nodes))
  local node = nodes[selected]
  if not node then return end
  if node.file then
    active = node.file
    panel:scroll("top")
    gui_scroll("git-diff-body", "top")
  else
    collapsed[node.path] = not collapsed[node.path]
    nodes = tree.nodes(files, collapsed)
  end
  invalidate()
end

local function move(delta)
  if active then
    local gui = desktop()
    if gui and gui.scroll then
      local info = gui.scroll_info and gui.scroll_info(body_id())
      gui.scroll(body_id(), math.max(0, ((info and info.offset) or 0) + delta * 18))
    end
    return panel:scroll(delta)
  end
  selected = math.max(1, math.min(selected + delta, #nodes))
  invalidate()
  local info = panel:info()
  -- Placed in the terminal. The desktop dock does not publish a cell height;
  -- adding nil there would throw, and the node scroller below moves instead.
  if info.height then
    local line
    for row, hit in pairs(hits) do
      if hit == selected then line = math.min(line or row, row) end
    end
    line = line or selected + 3
    if line <= info.top then panel:scroll(line - info.top - 1)
    elseif line > info.top + info.height then panel:scroll(line - info.top - info.height) end
  end
  local gui = desktop()
  if gui and gui.scroll and gui.scroll_info and #nodes > 0 then
    local view = gui.scroll_info("git-diff-tree")
    if view then
      local y, h = (selected - 1) * 22, 22
      if y < (view.offset or 0) then gui.scroll("git-diff-tree", y)
      elseif y + h > (view.offset or 0) + (view.viewport or 0) then
        gui.scroll("git-diff-tree", math.max(0, y + h - (view.viewport or 0)))
      end
    end
  end
end

local function render(width)
  hits = { [1] = "mode", [3] = "back" }
  local added, deleted = 0, 0
  for _, file in ipairs(files) do
    added, deleted = added + file.added, deleted + file.deleted
  end
  local out = {
    { { " " .. labels[mode], "PopupTitle" }, { "  ·  " .. #files .. (#files == 1 and " file" or " files"), "ToolSummary" } },
    { { " Total: ", "ToolSummary" }, { "+" .. added .. " added", "DiffAdd" },
      { "  ", "ToolSummary" }, { "−" .. deleted .. " removed", "DiffDelete" } },
    { { active and (" ‹ Files / " .. active.path:gsub("%c", " ")) or " Enter open   s mode   r refresh   q close", "ToolSummary" } },
  }
  if active or #files == 0 then
    local body = rows
    if active then
      body = {}
      for _, row in ipairs(active.rows) do
        if row.sign or not (row.text:match("^diff %-%-git ") or row.text:match("^index ")
          or row.text:match("^%-%-%- ") or row.text:match("^%+%+%+ ")) then body[#body + 1] = row end
      end
    end
    for _, line in ipairs(diff.render(body, width)) do out[#out + 1] = line end
  else
    for i, node in ipairs(nodes) do
      local file = node.file
      local label = string.rep("  ", node.depth) .. (file and "  " or collapsed[node.path] and "▸ " or "▾ ") .. node.name
      label = label:gsub("%c", " ")
      local group = i == selected and "Selection" or file and "ToolPath" or "ToolSummary"
      local spans = { { label .. (file and "" or "/"), group } }
      if file then
        spans[#spans + 1] = { string.format("  +%d −%d", file.added, file.deleted), i == selected and group or "ToolSummary" }
      end
      for _, line in ipairs(bone.text.wrap(spans, width, { first = " ", pad = i == selected and group or nil })) do
        out[#out + 1] = line
        hits[#out] = i
      end
    end
  end
  return out
end

local function press(node, fn)
  node.on_click = function()
    if panel and panel.focus then panel:focus() end
    fn()
  end
  node.cursor = "pointer"
  node.role = "button"
  node.focusable = false
  return node
end

local function filtered_rows()
  local body = {}
  for _, row in ipairs(active.rows) do
    if row.sign or not (row.text:match("^diff %-%-git ") or row.text:match("^index ")
      or row.text:match("^%-%-%- ") or row.text:match("^%+%+%+ ")) then body[#body + 1] = row end
  end
  return body
end

local function diff_nodes(list, ctx)
  local out, previous = {}, nil
  local digits = 3
  for _, row in ipairs(list) do
    digits = math.max(digits, #tostring(row.old or row.new or ""))
    if row.new then digits = math.max(digits, #tostring(row.new)) end
  end
  local cell = (ctx.cell and ctx.cell.w) or 8
  local narrow = math.floor((ctx.width or 400) / cell) < 24
  for _, row in ipairs(list) do
    if #out > 0 and ((row.sign == "+" or row.sign == "-")
      and (previous == "+" or previous == "-") and row.sign ~= previous
      or (row.text or ""):match("^@@ ")) then
      out[#out + 1] = { height = 8 }
    end
    if row.sign then
      -- The gutter stays put; the code beside it uses the rest of the dock
      -- and wraps there, so the highlight is a full-width band.
      local prefix = narrow and (row.sign .. " ")
        or string.format("  %" .. digits .. "s  %" .. digits .. "s  %s  ", row.old or "", row.new or "", row.sign)
      local band = (row.sign == "+" or row.sign == "-") and row.group or nil
      out[#out + 1] = {
        direction = "row", align = "start", bg = band,
        { text = prefix, font = "mono", size = 12, wrap = false, shrink = 0, hl = band or "ToolGutter" },
        { text = row.text, font = "mono", size = 12, wrap = true, grow = 1, shrink = 1, selectable = true, hl = row.group },
      }
    else
      out[#out + 1] = {
        { text = row.text, font = "mono", size = 12, wrap = true, width = "100%", selectable = true, hl = row.group or "Dim" },
      }
    end
    previous = row.sign
  end
  return out
end

local function switch_mode()
  mode = mode == "all" and "unstaged" or mode == "unstaged" and "staged" or "all"
end
local function refresh(reset_scroll)
  if not panel or not panel:is_open() then return end
  stop_job()
  cwd, session_id = session()
  panel:update({ title = "Git diff" })
  if reset_scroll then panel:scroll("top") end
  if not cwd then return message("No session working directory.") end
  message("Loading Git diff…")
  local token, requested_cwd, requested_session = generation, cwd, session_id
  local command = "git rev-parse --show-toplevel >/dev/null || exit $?\n"
  local flags = "git --no-pager diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "
  if mode == "all" then
    command = command .. 'base=HEAD\nif ! git rev-parse --verify HEAD >/dev/null 2>&1; then base=$(git hash-object -t tree /dev/null) || exit $?; fi\n' .. flags .. '"$base" --'
  elseif mode == "staged" then
    command = command .. flags .. "--cached --"
  else
    command = command .. flags .. "--"
  end
  job = bone.job.start(command, {
    name = "git-diff", cwd = cwd, timeout = 10000, buffer = true,
    on_exit = function(result)
      local current_cwd, current_session = session()
      if token ~= generation or not panel or not panel:is_open()
        or current_cwd ~= requested_cwd or current_session ~= requested_session then return end
      job = nil
      if result.state ~= "exited" or result.code ~= 0 then
        message(result.timed_out and "Git diff timed out. Press r to retry."
          or (result.stderr and result.stderr ~= "" and result.stderr)
          or result.error or "Unable to read Git diff.", "Error")
      elseif result.truncated then
        -- Buffered jobs retain only the tail; don't pretend it is a complete patch.
        message("Diff exceeds the job output limit (4 MiB). Inspect it in a terminal.")
      elseif not result.stdout or result.stdout == "" then
        message("No " .. labels[mode]:lower() .. " changes. Untracked files are not included.")
      else
        set_rows(diff.parse(result.stdout))
      end
    end,
  })
end

-- There is no session-switch UI event: watch session identity while open.
-- Git itself runs only on open, session change, completed turns, or explicit refresh.
local function watch(token)
  bone.defer(500, function()
    if token ~= watcher or not panel or not panel:is_open() then return end
    local next_cwd, next_session = session()
    if next_cwd ~= cwd or next_session ~= session_id then refresh(true) end
    watch(token)
  end)
end

local function close()
  watcher = watcher + 1
  stop_job()
  panel = nil
  set_rows({})
end

-- Page keys and the wheel are the panel's in the terminal. In the desktop
-- app they move the node scroller; returning false keeps the terminal path.
local function on_key(key)
  local gui = desktop()
  if not gui or not gui.scroll then return false end
  local id = body_id()
  local info = gui.scroll_info and gui.scroll_info(id)
  local offset = (info and info.offset) or 0
  if key == "pageup" or key == "pagedown" then
    local dy = ((info and info.viewport) or 240) * 0.9
    if key == "pageup" then dy = -dy end
    gui.scroll(id, math.max(0, offset + dy))
    return true
  end
  if key == "home" then gui.scroll(id, "top") return true end
  if key == "end" then gui.scroll(id, "end") return true end
  if key == "wheelup" then gui.scroll(id, math.max(0, offset - 3 * 18)) return true end
  if key == "wheeldown" then gui.scroll(id, offset + 3 * 18) return true end
  return false
end

-- The desktop library's widgets, when it has them: the patch, rows, mode
-- switch and key hints then look like the rest of the window. Without them
-- (another library) the plain nodes below stand in.
local has_widgets, widgets = pcall(require, "bone.nodes.widgets")
local has_style, style = pcall(require, "bone.nodes.style")
has_widgets = has_widgets and has_style and type(widgets.diff) == "function"
local MODES = { "all", "unstaged", "staged" }

local function styled_node()
  local added, deleted = 0, 0
  for _, file in ipairs(files) do
    added, deleted = added + file.added, deleted + file.deleted
  end
  local current = 1
  for i, m in ipairs(MODES) do if m == mode then current = i end end
  local patch = active or #files == 0
  local body = { id = body_id(), grow = 1, height = 0, direction = "column", overflow = "scroll" }
  if patch then
    local list = {}
    for _, row in ipairs(active and filtered_rows() or rows) do
      list[#list + 1] = row.sign and row or { text = row.text, hl = row.group }
    end
    body[#body + 1] = widgets.diff(list, { numbers = active ~= nil })
  else
    for i, entry in ipairs(nodes) do
      local index, file, on = i, entry.file, i == selected
      local mark = file and "" or (collapsed[entry.path] and "▸ " or "▾ ")
      body[#body + 1] = widgets.press({
        direction = "row", gap = style.space.lg, align = "center", radius = style.radius.sm,
        padding = { style.space.xs, style.space.md, style.space.xs, style.space.md + (entry.depth or 0) * 14 },
        bg = on and "Selection" or nil, focusable = false,
        { text = mark .. entry.name:gsub("%c", " ") .. (file and "" or "/"), size = style.size.caption,
          hl = file and "Normal" or "Dim", grow = 1, width = 0, wrap = false, text_overflow = "ellipsis" },
        file and { text = "+" .. file.added .. " −" .. file.deleted, size = style.size.small, hl = "Dim",
          font = "mono", wrap = false, shrink = 0 } or nil,
      }, function() if panel then panel:focus() end choose(index) end, "option")
    end
  end
  return {
    direction = "column", grow = 1, gap = style.space.md, overflow = "hidden",
    widgets.segmented({ "All tracked", "Unstaged", "Staged" }, current, function(i)
      mode = MODES[i]
      refresh(true)
    end),
    {
      direction = "row", gap = style.space.md, align = "center", padding = { 0, style.space.xs },
      { text = #files .. (#files == 1 and " file" or " files"), size = style.size.small, hl = "Dim", wrap = false },
      { text = "+" .. added, size = style.size.small, hl = "DiffAdd", wrap = false },
      { text = "−" .. deleted, size = style.size.small, hl = "DiffDelete", wrap = false },
    },
    active and widgets.link("‹ " .. active.path:gsub("%c", " "), back, { size = style.size.small, wrap = false,
      text_overflow = "ellipsis" }) or nil,
    body,
    widgets.hints(active and "b files · r refresh · q close" or "enter open · s mode · r refresh · q close", { 0, 0 }),
  }
end

local function gui_node(ctx)
  if has_widgets then return styled_node() end
  ctx = ctx or {}
  local added, deleted = 0, 0
  for _, file in ipairs(files) do
    added, deleted = added + file.added, deleted + file.deleted
  end
  local patch = active or #files == 0
  local body = {
    id = body_id(), grow = 1, direction = "column", overflow = "scroll",
    gap = patch and 0 or 1,
  }
  if patch then
    local list = active and filtered_rows() or rows
    for _, line in ipairs(diff_nodes(list, ctx)) do body[#body + 1] = line end
  else
    for i, entry in ipairs(nodes) do
      local index = i
      local file = entry.file
      local mark = file and "  " or (collapsed[entry.path] and "▸ " or "▾ ")
      local label = mark .. entry.name:gsub("%c", " ") .. (file and "" or "/")
      local on = i == selected
      local row = press({
        direction = "row", gap = 12, align = "center", radius = 4,
        padding = { 2, 8, 2, 8 + (entry.depth or 0) * 14 },
        bg = on and "Selection" or nil,
        {
          text = label, font = "mono", grow = 1, shrink = 1, wrap = false, text_overflow = "ellipsis",
          hl = on and "Selection" or (file and "ToolPath" or "ToolSummary"),
        },
      }, function() choose(index) end)
      if file then
        row[#row + 1] = {
          text = string.format("+%d −%d", file.added, file.deleted), font = "mono", wrap = false, shrink = 0,
          hl = on and "Selection" or "Dim",
        }
      end
      body[#body + 1] = row
    end
  end
  local back_text = active and ("‹ Files / " .. active.path:gsub("%c", " "))
    or "Enter open   s mode   r refresh   q close"
  return {
    direction = "column", grow = 1, gap = 6, overflow = "hidden",
    press({
      direction = "row", gap = 8, align = "center",
      { text = labels[mode], hl = "PopupTitle", bold = true, wrap = false },
      { text = "·  " .. #files .. (#files == 1 and " file" or " files"), hl = "Dim", wrap = false },
    }, function()
      switch_mode()
      refresh(true)
    end),
    {
      direction = "row", gap = 8, align = "center",
      { text = "Total:", hl = "Dim" },
      { text = "+" .. added .. " added", hl = "DiffAdd" },
      { text = "−" .. deleted .. " removed", hl = "DiffDelete" },
    },
    press({
      width = "100%", text = back_text, hl = "Dim", wrap = false, text_overflow = "ellipsis",
    }, back),
    body,
  }
end

-- The sidebar's share of the window: room for about 110 columns of patch,
-- between a quarter and two fifths, so the chat stays in sight.
local function width()
  local cols
  local gui = desktop()
  if gui and gui.window_info then
    cols = (gui.window_info() or {}).columns
  elseif bone.ui.geometry then
    local ok, g = pcall(bone.ui.geometry)
    for _, leaf in ipairs(ok and g and g.leaves or {}) do
      cols = math.max(cols or 0, leaf.x + leaf.width)
    end
  end
  if not cols or cols <= 0 then return 0.4 end
  return math.max(0.25, math.min(0.4, 110 / cols))
end

local function open()
  panel = bone.ui.panel.open({
    id = "git-diff", dock = "right", size = width(), full_height = true, focus = true,
    render = function(ctx)
      if not cache or cache_width ~= ctx.width then
        cache, cache_width = render(ctx.width), ctx.width
      end
      return cache
    end,
    node = gui_node,
    on_key = on_key,
    keys = {
      r = function() refresh(false) end,
      s = function()
        switch_mode()
        refresh(true)
      end,
      up = function() move(-1) end,
      down = function() move(1) end,
      k = function() move(-1) end,
      j = function() move(1) end,
      enter = function() if not active then choose() end end,
      right = function() if not active then choose() end end,
      space = function() if not active then choose() end end,
      left = back,
      b = back,
      q = function(p) p:close() end,
      ["ctrl+d"] = function(p) p:close() end,
    },
    on_close = close,
  })
  refresh(true)
  watcher = watcher + 1
  watch(watcher)
end

bone.cmd.create("diff", function(args)
  local arg = (args.args or ""):match("^%s*(.-)%s*$")
  if arg ~= "" and arg ~= "refresh" then
    return bone.notify("Usage: /diff [refresh]", "error")
  end
  if panel and panel:is_open() then
    if arg == "refresh" then refresh(false) else panel:close() end
  else
    open()
  end
end, { desc = "toggle the right Git diff sidebar (/diff refresh to refresh)" })
bone.keymap.set("ctrl+d", "/diff")

bone.on("resize", function()
  if panel and panel:is_open() then panel:update({ size = width() }) end
end)

bone.on("mouse", function(ev)
  if not panel or not panel:is_open() or ev.panel ~= "git-diff"
    or ev.button ~= "left" or ev.action ~= "down" then return end
  local hit = hits[ev.panel_line]
  if not hit then return end
  panel:focus()
  if hit == "mode" then switch_mode(); refresh(true)
  elseif hit == "back" then back()
  else choose(hit) end
  return true
end)
bone.on("turn/finished", function(ev)
  if panel and panel:is_open() and (not ev.session_id or ev.session_id == session_id) then
    refresh(false)
  end
end)

bone.plugin.on_shutdown(function()
  -- Plugin ownership also removes the panel, command, handlers, and jobs.
  watcher = watcher + 1
  stop_job()
  panel = nil
end)
