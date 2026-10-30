-- Read-only Git diff sidebar. One view, drawn by the terminal and the
-- desktop app alike; keys, modes, jobs and limits are the plugin's.
local diff = require("git_diff")
local tree = require("git_diff_tree")
local files, nodes, collapsed = {}, {}, {}
local active = nil
local panel, job, cwd, session_id
local mode, rows = "all", {}
local generation, watcher = 0, 0
local shown -- the view's tree, until something changes
local MODES = { "all", "unstaged", "staged" }
local NAMES = { all = "All tracked", unstaged = "Unstaged", staged = "Staged" }

local function session()
  local s = bone.chat.session()
  return s and s.cwd, s and s.session_id
end

local function set_rows(value)
  rows, shown = value, nil
  files, active = tree.files(value), nil
  nodes = tree.nodes(files, collapsed)
end

local function message(text, tone)
  set_rows({ { text = text, tone = tone or "dim" } })
end

local function stop_job()
  generation = generation + 1
  local previous = job
  job = nil
  if previous then previous:cancel() end
end

local function back()
  if not active then return end
  active, shown = nil, nil
  panel:scroll("top")
end

local function choose(index)
  local node = nodes[index]
  if not node then return end
  if node.file then
    active = node.file
    panel:scroll("top")
  else
    collapsed[node.path] = not collapsed[node.path]
    nodes = tree.nodes(files, collapsed)
  end
  shown = nil
end

local function switch_mode()
  mode = mode == "all" and "unstaged" or mode == "unstaged" and "staged" or "all"
end

local function refresh(reset_scroll)
  if not panel or not panel:is_open() then return end
  stop_job()
  cwd, session_id = session()
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
          or result.error or "Unable to read Git diff.", "error")
      elseif result.truncated then
        -- Buffered jobs retain only the tail; don't pretend it is a complete patch.
        message("Diff exceeds the job output limit (4 MiB). Inspect it in a terminal.")
      elseif not result.stdout or result.stdout == "" then
        message("No " .. NAMES[mode]:lower() .. " changes. Untracked files are not included.")
      else
        set_rows(diff.parse(result.stdout))
      end
    end,
  })
end

-- The open file's patch without Git's own header lines.
local function patch_rows()
  local out = {}
  for _, row in ipairs(active and active.rows or rows) do
    if row.sign then
      out[#out + 1] = row
    elseif not active or not (row.text:match("^diff %-%-git ") or row.text:match("^index ")
      or row.text:match("^%-%-%- ") or row.text:match("^%+%+%+ ")) then
      out[#out + 1] = { text = row.text, tone = row.tone or "dim" }
    end
  end
  return out
end

local function build()
  local added, deleted = 0, 0
  for _, file in ipairs(files) do
    added, deleted = added + file.added, deleted + file.deleted
  end
  local current = 1
  for i, m in ipairs(MODES) do if m == mode then current = i end end
  local body
  if active or #files == 0 then
    body = { kind = "diff", rows = patch_rows(), numbers = active ~= nil }
  else
    local items = {}
    for i, node in ipairs(nodes) do
      local file = node.file
      local mark = file and "" or (collapsed[node.path] and "▸ " or "▾ ")
      items[i] = {
        text = string.rep("  ", node.depth) .. mark .. node.name:gsub("%c", " ") .. (file and "" or "/"),
        tone = file and "normal" or "dim",
        detail = file and ("+" .. file.added .. " −" .. file.deleted) or nil,
      }
    end
    body = { kind = "list", items = items, on_press = choose }
  end
  return {
    kind = "column",
    { kind = "tabs", names = { NAMES.all, NAMES.unstaged, NAMES.staged }, current = current,
      on_select = function(i)
        mode = MODES[i]
        refresh(true)
      end },
    { kind = "row",
      { kind = "text", text = #files .. (#files == 1 and " file" or " files"), tone = "dim" },
      { kind = "text", text = "+" .. added, tone = "success" },
      { kind = "text", text = "−" .. deleted, tone = "error" } },
    active and { kind = "button", label = "‹ " .. active.path:gsub("%c", " "), on_press = back } or nil,
    body,
    { kind = "hints", text = active and "b files · r refresh · q close" or "enter open · s mode · r refresh · q close" },
  }
end

local function view()
  shown = shown or build()
  return shown
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

-- The sidebar's share of the window: room for about 110 columns of patch,
-- between a quarter and two fifths, so the chat stays in sight.
local function width()
  local cols
  if bone.has_capability("gui.window") then
    cols = (bone.gui.window_info() or {}).columns
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
    id = "git-diff", dock = "right", size = width(), full_height = true, focus = true, title = "Git diff",
    view = view,
    keys = {
      r = function() refresh(false) end,
      s = function()
        switch_mode()
        refresh(true)
      end,
      b = back,
      q = function(p) p:close() end,
      ["ctrl+d"] = function(p) p:close() end,
    },
    -- After the view's own keys: left goes back from a file's patch.
    on_key = function(key)
      if key == "left" and active then
        back()
        return true
      end
      return false
    end,
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
