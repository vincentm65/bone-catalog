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
local spawn_opts = {}
local jobs = {}
local ctx = {
    agent = {
        spawn = function(_, opts)
            spawned = spawned + 1
            spawn_opts[#spawn_opts + 1] = opts
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
assert(spawn_opts[1].max_concurrency == nil and spawn_opts[2].max_concurrency == nil,
    "dispatch must rely on provider-level concurrency")
assert(subagent_tool.description:find("resolved provider", 1, true),
    "tool description must explain provider-level concurrency")
assert(not subagent_tool.description:find("max_concurrency", 1, true),
    "tool description must not advertise agent-level concurrency")

local file = assert(io.open("tools/subagent.lua", "r"))
local source = file:read("*a")
file:close()
assert(not source:find("max_concurrency", 1, true),
    "/agents must not display or edit agent-level concurrency")

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
        title = "Second",
        -- mlua serializes Rust Option::None as a truthy null userdata.
        activity = debug.upvalueid((function()
            local value
            return function() return value end
        end)(), 1),
    },
}
result = subagent_tool.execute({ action = "status" }, ctx)
assert(result:find("job-2", 1, true), "status must expose the controllable job id")
assert(result:find("Second", 1, true),
    "status must ignore null userdata activity and fall back to the title")

-- ── Context sharing (dispatch opt-in) ───────────────────────────────────────

local function fresh_ctx(provider, history)
    local ctx = { _spawn_opts = {} }
    ctx.agent = {
        spawn = function(_, opts)
            ctx._spawn_opts[#ctx._spawn_opts + 1] = opts
            return { ok = true, id = "job-" .. #ctx._spawn_opts }
        end,
        jobs = function() return {} end,
        cancel = function() return { ok = true } end,
    }
    ctx.runtime = { info = function() return { provider = provider } end }
    ctx.conversation = { history = function() return history end }
    return ctx
end

local function dispatch_opts(tool, ctx, params)
    ctx._spawn_opts = {}
    tool.execute(params, ctx)
    return ctx._spawn_opts[1]
end

commands, tools = load_case(0, {
    { name = "reviewer", description = "Review changes" },
    { name = "local_reviewer", description = "Same provider", provider = "local" },
    { name = "openai_reviewer", description = "Other provider", provider = "openrouter" },
})
local ctx_tool = tools.subagent

local opts = dispatch_opts(ctx_tool, fresh_ctx("local", {
    { role = "user", content = "fix the bug" },
    { role = "assistant", content = "on it" },
}), {
    action = "dispatch",
    include_context = true,
    tasks = { { agent = "reviewer", task = "review it" } },
})
assert(opts and opts.context and #opts.context == 2,
    "include_context=true must share the filtered history")
assert(opts.context[1].role == "user" and opts.context[1].content == "fix the bug")
assert(opts.context[2].role == "assistant" and opts.context[2].content == "on it")

-- Over-budget history keeps the first user frame plus a recent tail, with an
-- omission marker between them, and stays within MAX_CONTEXT_CHARS.
local long = string.rep("x", 9000)
opts = dispatch_opts(ctx_tool, fresh_ctx("local", {
    { role = "user", content = "anchor question" },
    { role = "assistant", content = long },
    { role = "user", content = long },
}), {
    action = "dispatch",
    include_context = true,
    tasks = { { agent = "reviewer", task = "review it" } },
})
assert(opts and opts.context and #opts.context == 3,
    "over-budget history must truncate to first user + marker + tail")
assert(opts.context[1].role == "user" and opts.context[1].content == "anchor question")
assert(opts.context[2].role == "user"
    and opts.context[2].content == "[... earlier conversation omitted ...]",
    "truncation must insert the omission marker after the first user message")
local shared_chars = 0
for _, m in ipairs(opts.context) do shared_chars = shared_chars + #m.content end
assert(shared_chars <= 16000, "shared context must respect MAX_CONTEXT_CHARS")

-- Tool results are dropped and assistant tool_calls stripped.
opts = dispatch_opts(ctx_tool, fresh_ctx("local", {
    { role = "user", content = "task" },
    { role = "assistant", content = "thinking", tool_calls = { { id = "c1", name = "read", arguments = "{}" } } },
    { role = "tool", content = "tool result" },
    { role = "assistant", content = "done" },
}), {
    action = "dispatch",
    include_context = true,
    tasks = { { agent = "reviewer", task = "review it" } },
})
assert(opts and opts.context and #opts.context == 3,
    "tool results must be dropped and remaining messages kept")
assert(opts.context[1].content == "task" and opts.context[2].content == "thinking"
    and opts.context[3].content == "done")
assert(opts.context[2].tool_calls == nil, "assistant tool_calls must be stripped")

-- Explicit context overrides include_context.
opts = dispatch_opts(ctx_tool, fresh_ctx("local", {
    { role = "user", content = "seeded" },
}), {
    action = "dispatch",
    include_context = true,
    context = { { role = "user", content = "explicit only" } },
    tasks = { { agent = "reviewer", task = "review it" } },
})
assert(opts and opts.context and #opts.context == 1
    and opts.context[1].content == "explicit only",
    "explicit context must override include_context")

-- Provider guard: no share across providers; share on matching or nil provider;
-- unknown parent provider cannot be proven mismatched, so it shares.
opts = dispatch_opts(ctx_tool, fresh_ctx("local", {
    { role = "user", content = "secret" },
}), {
    action = "dispatch",
    include_context = true,
    tasks = { { agent = "openai_reviewer", task = "review it" } },
})
assert(not (opts and opts.context), "provider mismatch must not share context")

opts = dispatch_opts(ctx_tool, fresh_ctx("local", {
    { role = "user", content = "shared" },
}), {
    action = "dispatch",
    include_context = true,
    tasks = { { agent = "local_reviewer", task = "review it" } },
})
assert(opts and opts.context and #opts.context == 1,
    "matching provider must share context")

opts = dispatch_opts(ctx_tool, fresh_ctx(nil, {
    { role = "user", content = "shared" },
}), {
    action = "dispatch",
    include_context = true,
    tasks = { { agent = "openai_reviewer", task = "review it" } },
})
assert(opts and opts.context and #opts.context == 1,
    "unknown parent provider must share (cannot prove mismatch)")

-- followup ignores context: opts_for never carries it.
local followup_opts
local followup_ctx = {
    agent = {
        jobs = function() return { { id = "job-9", agent = "reviewer" } } end,
        followup = function(_, _, opts) followup_opts = opts return { ok = true, id = "job-10" } end,
    },
    runtime = { info = function() return { provider = "local" } end },
    conversation = { history = function() return { { role = "user", content = "secret" } } end },
}
ctx_tool.execute({
    action = "followup", id = "job-9", task = "continue", include_context = true,
}, followup_ctx)
assert(followup_opts and followup_opts.context == nil,
    "followup must not consult context")

commands, tools = load_case(1, {
    { name = "reviewer", description = "Review changes" },
})
assert(not commands.agents, "nested VM: /agents should not be registered")
assert(not tools.subagent, "nested VM: subagent tool should not be registered")

print("subagent tests passed")
