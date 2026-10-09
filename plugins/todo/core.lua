-- todo: a checklist the model rewrites in full. Nothing is stored: the list
-- is the latest todo call in a chat's own history, so it cannot reach
-- another chat.
local MARK = { pending = "[ ]", in_progress = "[>]", completed = "[x]" }
-- Tool results without a todo update before the list is mentioned again.
local STALE_AFTER = 8

-- Per session, in memory only: { open = n, active = text, since = calls }.
-- Lost on restart, which only means no reminder until the next todo call.
local live = {}

bone.tool.register({
  name = "todo",
  description = "Track multi-step work as a checklist the user can see. Send the whole list every time,"
    .. " with exactly one item in_progress while working. Mark each item completed as soon as it is done,"
    .. " and finish or clear the list before your final answer. Skip it for simple tasks.",
  parameters = {
    type = "object",
    properties = {
      title = { type = "string", description = "A short title for this checklist. Send it with each update." },
      items = {
        type = "array",
        items = {
          type = "object",
          properties = {
            text = { type = "string" },
            status = { type = "string", enum = { "pending", "in_progress", "completed" } },
          },
          required = { "text", "status" },
        },
      },
    },
    required = { "items" },
  },
  needs_approval = false,
  run = function(args)
    if type(args.items) ~= "table" then return nil, "items must be a list" end
    if args.title ~= nil and (type(args.title) ~= "string" or args.title:match("^%s*$")) then
      return nil, "title must be a non-empty string"
    end
    local out, open = {}, 0
    for i, it in ipairs(args.items) do
      if type(it) ~= "table" or type(it.text) ~= "string" or it.text:match("^%s*$") or not MARK[it.status] then
        return nil, "item " .. i .. " needs text and a status: pending, in_progress or completed"
      end
      out[i] = MARK[it.status] .. " " .. it.text
      if it.status ~= "completed" then open = open + 1 end
    end
    if #out == 0 then return "list cleared" end
    if open > 0 then out[#out + 1] = open .. " open; mark each completed as you finish it." end
    return table.concat(out, "\n")
  end,
})

-- Remind a model that has gone quiet on its list, by appending one line to an
-- ordinary tool result. The line is stored with that result, so the request
-- prefix (and the provider's prompt cache) is never rewritten.
bone.hook("tool_result", function(ev)
  local sid = ev.session_id
  if ev.name == "todo" then
    if ev.is_error then return end
    local items = type(ev.arguments) == "table" and ev.arguments.items
    local open, active = 0, nil
    for _, it in ipairs(type(items) == "table" and items or {}) do
      if type(it) == "table" and it.status ~= "completed" then
        open = open + 1
        if it.status == "in_progress" and type(it.text) == "string" then active = active or it.text end
      end
    end
    live[sid] = open > 0 and { open = open, active = active, since = 0 } or nil
    return
  end
  local s = live[sid]
  if not s then return end
  s.since = s.since + 1
  if s.since < STALE_AFTER or ev.is_error or type(ev.output) ~= "string" then return end
  s.since = 0
  local note = ("[todo: %d open%s. Mark finished items completed.]"):format(
    s.open, s.active and (', in progress "' .. s.active .. '"') or "")
  return { output = ev.output .. "\n\n" .. note }
end)
