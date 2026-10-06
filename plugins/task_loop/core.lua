local store = require("task_loop.state")
local function render(state)
  local out = {}
  for i, task in ipairs(state.tasks) do
    out[#out + 1] = string.format("%s %d. %s", task.done and "[x]" or "[ ]", i, task.text)
  end
  return #out > 0 and table.concat(out, "\n") or "no tasks"
end
bone.tool.register({
  name = "task_loop",
  description = "Write or advance an autonomous checklist for the current session.",
  parameters = {
    type = "object",
    properties = {
      action = { type = "string", enum = { "write", "advance", "complete", "stop", "resume", "clear", "status" } },
      tasks = { type = "array", items = { type = "string" } },
      index = { type = "integer", minimum = 1 },
    },
    required = { "action" },
  },
  needs_approval = false,
  run = function(args, ctx)
    if not ctx or not ctx.session_id or ctx.session_id == "" then
      return nil, "task_loop requires a session"
    end
    local state = store.load(ctx.session_id)
    local action = args.action
    if action == "write" then
      if type(args.tasks) ~= "table" or #args.tasks == 0 then return nil, "write requires tasks" end
      state.tasks = {}
      for _, text in ipairs(args.tasks) do
        if type(text) ~= "string" or text:match("^%s*$") then return nil, "task text must be non-empty" end
        state.tasks[#state.tasks + 1] = { text = text, done = false }
      end
      state.active = true
    elseif action == "advance" then
      for _, task in ipairs(state.tasks) do if not task.done then task.done = true; break end end
      state.active = store.pending(state)
    elseif action == "complete" then
      local i = tonumber(args.index)
      if i and state.tasks[i] then state.tasks[i].done = true else return nil, "unknown task index" end
      state.active = store.pending(state)
    elseif action == "stop" then state.active = false
    elseif action == "resume" then state.active = store.pending(state)
    elseif action == "clear" then state.tasks, state.active = {}, false
    elseif action ~= "status" then return nil, "unknown task_loop action" end
    if action ~= "status" then store.save(ctx.session_id, state) end
    return render(state)
  end,
})
bone.hook("context", function(ev)
  if not ev.session_id then return end
  local state = store.load(ev.session_id)
  if not state.active or #state.tasks == 0 then return end
  table.insert(ev.messages, 2, { role = "system", content = "Task loop:\n" .. render(state) ..
    "\nAdvance the current task, then call task_loop with action=advance when verified." })
  return { messages = ev.messages }
end)
bone.hook("turn_end", function(ev)
  if not ev.session_id then return end
  local state = store.load(ev.session_id)
  if not state.active or ev.outcome.status ~= "completed" then return end
  bone.queue.add(ev.session_id, "Continue the task loop and verify the next actionable item.", "next")
end)
