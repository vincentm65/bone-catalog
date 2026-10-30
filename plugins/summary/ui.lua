local summary = require("summary")

local function current_assistant()
  return bone.chat.items({ kind = "assistant", last = 1 })[1]
end

local function redraw(item)
  if item and item.index then
    bone.chat.redraw(item.index)
  else
    bone.chat.redraw()
  end
end

local function summarize(item)
  if not item or not tostring(item.text or ""):match("%S") then return end
  local session = bone.chat.session()
  local session_id = session and session.session_id
  local key = summary.key(item)
  if summary.pending[key] then return end
  summary.pending[key] = true

  bone.model.complete({
    system = "Summarize the assistant answer for a human reader. Return only one to three concise lines. Do not use a heading, preamble, or more than three lines.",
    prompt = "Assistant answer:\n\n" .. item.text,
  }, nil, function(result)
    summary.pending[key] = nil
    local current_session = bone.chat.session()
    if session_id and (not current_session or current_session.session_id ~= session_id) then return end
    local current = bone.chat.item(item.index) or item
    summary.set(current, result and result.content or "")
    redraw(current)
  end)
end

-- The transcript has received the completed item by the time this deferred
-- callback runs. Intermediate assistant messages used for tool calls have no
-- text and are ignored.
bone.on("message/completed", function(ev)
  local session = bone.chat.session()
  if not session or (ev and ev.session_id and ev.session_id ~= session.session_id) then return end
  bone.defer(0, function()
    summarize(current_assistant())
  end)
end)

local function toggle(item)
  if not item or item.kind ~= "assistant" then return false end
  summary.toggle(item)
  redraw(item)
  return true
end

if not bone.api_info or bone.api_info().side == "tui" then
  bone.on("mouse", function(ev)
    if ev.action == "down" and ev.button == "left" and ev.index then
      return toggle(bone.chat.item(ev.index))
    end
  end)
end

bone.keymap.set("ctrl+shift+e", function()
  return toggle(current_assistant())
end, { desc = "expand or collapse the latest answer" })
