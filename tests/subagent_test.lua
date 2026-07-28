-- Run with: lua tests/subagent_test.lua
local function load_case(depth, agents)
    local commands = {}
    local tools = {}
    package.loaded["ui.menu"] = {
        select = function() error("menu should not open during registration") end,
        text_input = function() error("menu should not open during registration") end,
    }
    package.loaded["ui.pane"] = {
        new = function() error("pane should not open during registration") end,
    }
    bone = {
        agent_depth = depth,
        _subagents = agents,
        command = {
            register = function(name, spec) commands[name] = spec end,
        },
        tool = {
            register = function(spec) tools[spec.name] = spec end,
        },
    }

    assert(loadfile("tools/subagent.lua"))()
    return commands, tools
end

local commands, tools = load_case(0, {})
assert(commands.agents, "no agents: /agents should be registered")
assert(not tools.subagent, "no agents: subagent tool should not be registered")

commands, tools = load_case(0, {
    { name = "reviewer", description = "Review changes" },
})
assert(commands.agents, "enabled agents: /agents should be registered")
assert(tools.subagent, "enabled agents: subagent tool should be registered")

local subagent_tool = tools.subagent
local spawned = 0
local jobs = {}
local ctx = {
    agent = {
        spawn = function()
            spawned = spawned + 1
            return { ok = true, id = "job-" .. spawned }
        end,
        jobs = function() return jobs end,
        cancel = function(id) return { ok = id == "job-1" } end,
    },
}

local result = subagent_tool.execute({
    action = "dispatch",
    tasks = {
        { agent = "reviewer", title = "First", task = "first task" },
        { agent = "reviewer", title = "Second", task = "second task" },
    },
}, ctx)
assert(result:find("job-1", 1, true) and result:find("job-2", 1, true),
    "successful dispatches must return job ids")

result = subagent_tool.execute({ action = "cancel" }, ctx)
assert(type(result) == "string" and result:find("Provide ids", 1, true),
    "empty cancel must return a readable string error")

result = subagent_tool.execute({ action = "cancel", ids = { "job-1", "job-404" } }, ctx)
assert(result:find("job-1: cancelled", 1, true))
assert(result:find("job-404: not running or not found", 1, true))

jobs = {
    {
        id = "job-2",
        agent = "reviewer",
        status = "running",
        started_at = os.time() - 1,
        task = "second task",
    },
}
result = subagent_tool.execute({ action = "status" }, ctx)
assert(result:find("job-2", 1, true), "status must expose the controllable job id")

commands, tools = load_case(1, {
    { name = "reviewer", description = "Review changes" },
})
assert(not commands.agents, "nested VM: /agents should not be registered")
assert(not tools.subagent, "nested VM: subagent tool should not be registered")

print("subagent tests passed")
