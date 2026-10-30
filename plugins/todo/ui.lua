-- Shows the on-screen chat's latest finished todo call in a drawer under it,
-- and hides when that chat has no unfinished list. One view, drawn by the
-- terminal and the desktop app alike. Syncs automatically when switching
-- chats; /todo also syncs it manually.
local STATE = { pending = "todo", in_progress = "active", completed = "done" }
local panel

-- The latest finished, successful todo call in this chat's history. A still
-- running call is skipped, so the drawer keeps the previous list until the
-- new one finishes. No window limit: the list must survive any number of
-- later tool calls. The view is drawn every frame, so probe only the newest
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

-- The drawer: the list as a checklist. Clicks do not edit.
local function view()
  local items = list()
  if not items then
    bone.defer(0, function() if panel then panel:hide() end end)
    return nil
  end
  local checks = {}
  for i, it in ipairs(items) do checks[i] = { text = tostring(it.text), state = STATE[it.status] } end
  return { kind = "checklist", items = checks }
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
    panel = bone.ui.panel.open({ id = "todo", dock = "bottom", focusable = false, view = view })
  end
  panel:update({ title = title })
end

for _, event in ipairs({ "ready", "chat/shown", "submit", "tool/finished", "turn/finished" }) do
  bone.on(event, function() bone.defer(0, sync) end)
end
bone.cmd.create("todo", sync, { desc = "show this chat's unfinished todo list" })
