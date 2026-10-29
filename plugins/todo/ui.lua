-- Shows the on-screen chat's latest finished todo call in a drawer under it,
-- and hides when that chat has no unfinished list. The same drawer is drawn
-- in the terminal (render) and the desktop app (node). Syncs automatically
-- when switching chats; /todo also syncs it manually.
local MARK = { pending = "· ", in_progress = "▸ ", completed = "✓ " }
local HL = { pending = "Normal", in_progress = "TodoActive", completed = "TodoDone" }
local ICON_HL = { pending = "Dim", in_progress = "Accent", completed = "TodoCheck" }
-- Define styles once, never during render: updates must preserve chat caches.
-- Only where the colorscheme or config has not (bone.hl.get resolves any
-- name, so ask bone.hl.names), and from the theme: the check is DiffAdd's
-- green without its band.
local defined = {}
for _, name in ipairs(bone.hl.names()) do defined[name] = true end
local function define(name, spec)
  if not defined[name] then bone.hl.set(name, spec) end
end
define("TodoCheck", { fg = (bone.hl.get("DiffAdd") or {}).fg, bold = true })
define("TodoDone", { link = "Dim", strikethrough = true })
define("TodoActive", { link = "Normal", bold = true })
local panel

-- The desktop library's checklist, when it has one, so the list looks like
-- the rest of the window; the plain rows below otherwise.
local has_widgets, widgets = pcall(require, "bone.nodes.widgets")
has_widgets = has_widgets and type(widgets.checklist) == "function"
local STATE = { pending = "todo", in_progress = "active", completed = "done" }

local function gui()
  return bone.has_capability and bone.has_capability("gui.nodes") and panel and panel.update
end

-- The latest finished, successful todo call in this chat's history. A still
-- running call is skipped, so the drawer keeps the previous list until the
-- new one finishes. No window limit: the list must survive any number of
-- later tool calls. The render runs every frame, so probe only the newest
-- call first: if it is finished and successful it alone decides, and the whole
-- history is walked only while a call is running or failed.
local function scan(calls)
  for i = #calls, 1, -1 do
    local c = calls[i]
    if c.done then
      local args = c.arguments
      if not c.is_error and type(args) == "table" and type(args.items) == "table" then
        local done = 0
        for _, it in ipairs(args.items) do
          if it.status == "completed" then done = done + 1 end
        end
        -- Stop at the latest successful call, even if it clears/completes the list.
        if done == #args.items then return nil end
        local title = type(args.title) == "string" and args.title:gsub("%s+", " ") or ""
        return args.items, "Todo " .. done .. "/" .. #args.items .. (title ~= "" and " — " .. title or "")
      end
    end
  end
end

local function list()
  local calls = bone.chat.items({ kind = "tool", name = "todo", last = 1 }) or {}
  local c = calls[1]
  if c and c.done and not c.is_error and type(c.arguments) == "table" and type(c.arguments.items) == "table" then
    return scan({ c })
  end
  return scan(bone.chat.items({ kind = "tool", name = "todo" }) or {})
end

local function render()
  local items, title = list()
  if not items then
    bone.defer(0, function() if panel then panel:hide() end end)
    return {}
  end
  local lines = { { { "", "Normal" } }, { { title, "PanelTitle" }, { fill = " ", hl = "PanelTitle" } } }
  for _, it in ipairs(items) do
    local hl = HL[it.status] or "Normal"
    lines[#lines + 1] = {
      { MARK[it.status] or "· ", ICON_HL[it.status] or "Dim" },
      { tostring(it.text), hl },
      { fill = " ", hl = "Normal" },
    }
  end
  return lines
end

-- Desktop drawer: the same title, marks and hide rules. Clicks do not edit.
local function todo_node()
  local items = list()
  if not items then
    bone.defer(0, function() if panel then panel:hide() end end)
    return nil
  end
  -- The title is the panel's, drawn over it.
  if has_widgets then
    local checks = {}
    for _, it in ipairs(items) do checks[#checks + 1] = { text = tostring(it.text), state = STATE[it.status] } end
    return widgets.checklist(checks)
  end
  local rows = { direction = "column", gap = 3 }
  for _, it in ipairs(items) do
    local status = it.status
    rows[#rows + 1] = {
      direction = "row", gap = 6, align = "center",
      { text = MARK[status] or "· ", hl = ICON_HL[status] or "Dim", font = "mono", wrap = false },
      {
        text = tostring(it.text), hl = HL[status] or "Normal", grow = 1, wrap = true,
        bold = status == "in_progress" or nil, strike = status == "completed" or nil,
      },
    }
  end
  return rows
end

local function sync()
  local items, title = list()
  if not items then
    if panel then panel:hide() end
    return
  end
  if panel and panel:is_open() then
    panel:show()
  else
    -- Include the spacer and heading in the auto-sized drawer (max 10 rows).
    panel = bone.ui.panel.open({
      id = "todo", dock = "bottom", title = false, render = render, focusable = false, node = todo_node,
    })
  end
  -- The terminal draws the title as the first lines; the desktop draws the
  -- panel's own over it, and fits the panel to the list.
  if gui() then panel:update({ title = title }) end
end

for _, event in ipairs({ "ready", "chat/shown", "submit", "tool/finished", "turn/finished" }) do
  bone.on(event, function() bone.defer(0, sync) end)
end
bone.cmd.create("todo", sync, { desc = "show this chat's unfinished todo list" })
