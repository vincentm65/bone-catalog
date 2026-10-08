-- todo: a checklist the model rewrites in full. Nothing is stored: the list
-- is the latest todo call in a chat's own history, so it cannot reach
-- another chat.
local MARK = { pending = "[ ]", in_progress = "[>]", completed = "[x]" }

bone.tool.register({
  name = "todo",
  description = "Track multi-step work as a checklist the user can see. Send the whole list every time,"
    .. " with exactly one item in_progress while working. Skip it for simple tasks.",
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
    local out = {}
    for i, it in ipairs(args.items) do
      if type(it) ~= "table" or type(it.text) ~= "string" or it.text:match("^%s*$") or not MARK[it.status] then
        return nil, "item " .. i .. " needs text and a status: pending, in_progress or completed"
      end
      out[i] = MARK[it.status] .. " " .. it.text
    end
    return #out > 0 and table.concat(out, "\n") or "list cleared"
  end,
})
