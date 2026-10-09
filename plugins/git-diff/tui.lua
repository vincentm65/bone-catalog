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

local function back()
  active = nil
  invalidate()
  panel:scroll("top")
end

local function choose(index)
  selected = math.max(1, math.min(index or selected, #nodes))
  local node = nodes[selected]
  if not node then return end
  if node.file then
    active = node.file
    panel:scroll("top")
  else
    collapsed[node.path] = not collapsed[node.path]
    nodes = tree.nodes(files, collapsed)
  end
  invalidate()
end

local function move(delta)
  if active then return panel:scroll(delta) end
  selected = math.max(1, math.min(selected + delta, #nodes))
  invalidate()
  local info = panel:info()
  local line
  for row, hit in pairs(hits) do
    if hit == selected then line = math.min(line or row, row) end
  end
  line = line or selected + 3
  if line <= info.top then panel:scroll(line - info.top - 1)
  elseif line > info.top + info.height then panel:scroll(line - info.top - info.height) end
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

local function open()
  panel = bone.ui.panel.open({
    id = "git-diff", dock = "right", size = 0.5, full_height = true, focus = true,
    render = function(ctx)
      if not cache or cache_width ~= ctx.width then
        cache, cache_width = render(ctx.width), ctx.width
      end
      return cache
    end,
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
