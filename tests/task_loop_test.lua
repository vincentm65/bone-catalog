-- Run with: lua tests/task_loop_test.lua
local registered
local hooks = {}
local closed = {}
local submitted = {}
bone = {
    tool = { register = function(spec) registered = spec end },
    on = function(event, handler) hooks[event] = handler end,
    submit = function(prompt) table.insert(submitted, prompt) end,
    log = { info = function() end, warn = function() end },
    api = { ui = { close = function(id) table.insert(closed, id) end } },
}

local encoded = {}
local sequence = 0
cjson = {
    encode = function(value)
        sequence = sequence + 1
        local key = "json-" .. sequence
        encoded[key] = value
        return key
    end,
    decode = function(value)
        local decoded = encoded[value]
        if not decoded then error("unknown mocked JSON value") end
        return decoded
    end,
}

assert(loadfile("tools/task_loop.lua"))()
assert(registered and registered.name == "task_loop")
assert(registered.stateful == true)

local action_enum = registered.parameters.properties.action.enum
assert(#action_enum == 6, "expected six actions, got " .. #action_enum)

local state_value
local ctx = {
    state = {
        get = function() return state_value end,
        set = function(_, value) state_value = value return true end,
        clear = function() state_value = nil return true end,
    },
    runtime = { info = function() return { agent_depth = 0 } end },
    log = { info = function() end, warn = function() end },
}

local function run(params)
    return registered.execute(params, ctx)
end

local function decode_state(result)
    local envelope = cjson.decode(result)
    return cjson.decode(envelope.state), envelope
end

-- write: rejects an empty list and blank tasks.
local result = run({ action = "write", tasks = {} })
assert(result:find("at least one task", 1, true), result)

result = run({ action = "write", tasks = { "   " } })
assert(result:find("text must be non-empty", 1, true), result)

-- write: rejects an unknown status.
result = run({ action = "write", tasks = { { text = "ship", status = "shipped" } } })
assert(result:find("status must be pending", 1, true), result)

-- write: defaults to pending, marks the first item current, loop active.
result = run({ action = "write", tasks = { "design", "build", "test" } })
local state, envelope = decode_state(result)
assert(state.tasks[1].status == "in_progress", "first item becomes current")
assert(state.tasks[2].status == "pending", "second item stays pending")
assert(state.active == true, "loop must be active while work remains")
assert(envelope.pane and envelope.pane.source == "task_loop")

-- write: at most one actionable item may be in_progress.
result = run({ action = "write", tasks = {
    { text = "a", status = "in_progress" },
    { text = "b", status = "in_progress" },
} })
assert(result:find("at most one actionable item", 1, true), result)

-- write: subtasks normalize and the first leaf becomes current.
result = run({ action = "write", tasks = { { text = "phase", subtasks = { "one", "two" } } } })
state, _ = decode_state(result)
assert(state.tasks[1].subtasks[1].text == "one")
assert(state.tasks[1].subtasks[1].status == "in_progress", "first subtask becomes current")
assert(state.tasks[1].subtasks[2].status == "pending")

-- write: nested subtasks are rejected.
result = run({ action = "write", tasks = {
    { text = "a", subtasks = { { text = "b", subtasks = { "c" } } } },
} })
assert(result:find("cannot contain nested subtasks", 1, true), result)

-- advance: completes the current leaf and promotes the next.
result = run({ action = "write", tasks = { "a", "b" } })
result = run({ action = "advance" })
state, envelope = decode_state(result)
assert(state.tasks[1].status == "done")
assert(state.tasks[2].status == "in_progress", "next item becomes current")
assert(envelope.content:find("1/2 done", 1, true), envelope.content)

-- complete: marks every leaf done and stops the loop.
result = run({ action = "write", tasks = { "a", "b" } })
result = run({ action = "complete" })
state, envelope = decode_state(result)
assert(state.tasks[1].status == "done" and state.tasks[2].status == "done")
assert(state.active == false)
assert(envelope.content:find("All tasks complete", 1, true), envelope.content)

-- stop: pauses the loop and records the reason.
result = run({ action = "write", tasks = { "a", "b" } })
result = run({ action = "stop", reason = "waiting on review" })
state, envelope = decode_state(result)
assert(state.active == false)
assert(state.blocked_reason == "waiting on review")
assert(envelope.content:find("Loop stopped", 1, true), envelope.content)

-- resume: re-activates a stopped (incomplete) loop.
result = run({ action = "resume" })
state, envelope = decode_state(result)
assert(state.active == true)
assert(state.blocked_reason == nil)
assert(envelope.content:find("resumed", 1, true), envelope.content)

-- clear: removes host state.
result = run({ action = "clear" })
assert(state_value == nil, "clear must drop host state")
assert(cjson.decode(result).content:find("cleared", 1, true))

-- unknown action is rejected (needs existing state to reach the check).
result = run({ action = "write", tasks = { "a" } })
result = run({ action = "nope" })
assert(result:find("must be write", 1, true), result)

-- lifecycle hooks are registered.
assert(type(hooks.before_turn) == "function", "before_turn hook required")
assert(type(hooks.turn_end) == "function", "turn_end hook required")

-- before_turn: emits a reminder only while the loop is active and never
-- touches the pane.
result = run({ action = "write", tasks = { "a", "b" } })
local reminder = hooks.before_turn({}, ctx)
assert(reminder and reminder.turn_message, "expected a turn_message while active")
assert(reminder.turn_message:find("Autonomous Task Loop", 1, true), reminder.turn_message)
assert(#closed == 0, "active loop must not close the pane")

-- before_turn: a finished loop clears host state and closes the pane on the
-- next real user turn instead of lingering.
result = run({ action = "complete" })
assert(hooks.before_turn({}, ctx) == nil, "no reminder once complete")
assert(state_value == nil, "finished loop state must clear on the next user turn")
assert(#closed == 1 and closed[1] == "task_loop", "finished loop pane must close")

-- before_turn: a stopped (incomplete) loop keeps its state and pane for a
-- later resume.
result = run({ action = "write", tasks = { "a", "b" } })
result = run({ action = "stop", reason = "blocked" })
assert(hooks.before_turn({}, ctx) == nil, "no reminder while stopped")
assert(state_value ~= nil, "stopped loop must keep its checklist for resume")
assert(#closed == 1, "stopped loop pane must not close")

-- turn_end: a cancelled turn (Esc) halts the loop without submitting the
-- continuation prompt; the checklist survives for a later resume.
result = run({ action = "write", tasks = { "a", "b" } })
hooks.turn_end({ ok = false, cancelled = true, error = "turn cancelled", content = "" }, ctx)
state = cjson.decode(state_value)
assert(state.active == false, "cancelled turn must stop the loop")
assert(#submitted == 0, "cancelled turn must not submit the continuation prompt")
assert(#closed == 1, "cancelled loop must keep its checklist for resume")
assert(hooks.before_turn({}, ctx) == nil, "no reminder while stopped")

-- turn_end: a failed turn halts the loop the same way.
result = run({ action = "resume" })
hooks.turn_end({ ok = false, error = "provider error", content = "" }, ctx)
state = cjson.decode(state_value)
assert(state.active == false, "failed turn must stop the loop")
assert(#submitted == 0, "failed turn must not submit the continuation prompt")

-- turn_end: a normal turn without a stop sentinel still continues.
result = run({ action = "resume" })
hooks.turn_end({ ok = true, content = "worked on a" }, ctx)
assert(#submitted == 1, "normal turn must keep the loop going")
assert(submitted[1]:find("Continue the autonomous task list", 1, true), submitted[1])

print("task_loop tests passed")
