-- Core and TUI share a file for each session, never a global checklist.
local M = {}

function M.key(session_id)
  assert(type(session_id) == "string" and session_id ~= "", "task_loop requires a session")
  return "task_loop." .. bone.sha256(session_id)
end

function M.load(session_id)
  local state = bone.state.load(M.key(session_id), { shared = true })
  state.tasks = state.tasks or {}
  state.active = state.active == true
  return state
end

function M.save(session_id, state)
  bone.state.save(M.key(session_id), state, { shared = true })
end

function M.pending(state)
  for _, task in ipairs(state.tasks) do
    if not task.done then return true end
  end
  return false
end

return M
