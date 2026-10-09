-- Shows the on-screen chat's latest finished todo call in a drawer under it,
-- and hides when that chat has no unfinished list. /todo syncs it after
-- switching chats.
local MARK = { pending = "· ", in_progress = "▸ ", completed = "✓ " }
local HL = { pending = "Normal", in_progress = "TodoActive", completed = "TodoDone" }
local ICON_HL = { pending = "Dim", in_progress = "Accent", completed = "TodoCheck" }
-- Define styles once, never during render: updates must preserve chat caches.
bone.hl.set("TodoCheck", { fg = "green", bold = true })
bone.hl.set("TodoDone", { link = "Dim", strikethrough = true })
bone.hl.set("TodoActive", { link = "Normal", bold = true })
local panel

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

local function sync()
  local items = list()
  if not items then
    if panel then panel:hide() end
    return
  end
  if panel and panel:is_open() then
    panel:show()
  else
    -- Include the spacer and heading in the auto-sized drawer (max 10 rows).
    panel = bone.ui.panel.open({ id = "todo", dock = "bottom", title = false, render = render, focusable = false })
  end
end

for _, event in ipairs({ "ready", "submit", "tool/finished", "turn/finished" }) do
  bone.on(event, function() bone.defer(0, sync) end)
end
bone.cmd.create("todo", sync, { desc = "show this chat's unfinished todo list" })
