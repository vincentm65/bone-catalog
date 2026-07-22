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

commands, tools = load_case(1, {
    { name = "reviewer", description = "Review changes" },
})
assert(not commands.agents, "nested VM: /agents should not be registered")
assert(not tools.subagent, "nested VM: subagent tool should not be registered")

print("subagent tests passed")
