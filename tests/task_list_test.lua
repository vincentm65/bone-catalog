-- Run with: lua tests/task_list_test.lua
local registered
bone = { tool = { register = function(spec) registered = spec end } }

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

assert(loadfile("tools/task_list.lua"))()
assert(registered and registered.name == "task_list")

local action_enum = registered.parameters.properties.action.enum
assert(action_enum[1] == "write" and action_enum[2] == "complete" and action_enum[3] == "clear")
local task_variants = registered.parameters.properties.tasks.items.oneOf
assert(task_variants[1].minLength == 1)
assert(task_variants[2].properties.text.minLength == 1)

local state_value
local ctx = {
    state = {
        get = function() return state_value end,
        set = function(_, value) state_value = value return true end,
        clear = function() state_value = nil return true end,
    },
}

local function run(params)
    return registered.execute(params, ctx)
end

local result = run({ action = "write", tasks = { "" } })
assert(result:find("non-empty string", 1, true), result)

result = run({ action = "write", tasks = { " \t\n" } })
assert(result:find("non-empty string", 1, true), result)

result = run({ action = "write", tasks = { { text = "  ", status = "pending" } } })
assert(result:find("non-empty string", 1, true), result)

result = run({ action = "write", tasks = { { text = "ship", status = "completed" } } })
assert(result:find("status must be pending", 1, true), result)

result = run({ action = "write", tasks = { { text = "ship", status = false } } })
assert(result:find("status must be pending", 1, true), result)

result = run({ action = "write", tasks = { { text = "ship" } } })
local envelope = cjson.decode(result)
local state = cjson.decode(envelope.state)
assert(state.tasks[1].status == "pending", "omitted status must still default to pending")

result = run({ action = "complete" })
envelope = cjson.decode(result)
state = cjson.decode(envelope.state)
assert(state.tasks[1].status == "done")
assert(envelope.content:find("All tasks complete", 1, true))

result = run({ action = "nope" })
assert(result:find("'complete'", 1, true), result)

print("task_list tests passed")
