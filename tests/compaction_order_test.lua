-- Regression: sorted catalog loading must run memory injection before automatic compaction.
local handlers = {}
local commands = {}
local loading

local env = setmetatable({
    cjson = { encode = function() return "[]" end },
    bone = {
        cwd = "/work/project",
        command = { register = function(name, spec) commands[name] = spec end },
        settings = { register = function() end },
        on = function(event, handler, opts)
            if event ~= "before_turn" then return end
            local entry = {
                handler = handler,
                owner = loading,
                priority = opts and opts.priority or 0,
            }
            local index = #handlers + 1
            for i, existing in ipairs(handlers) do
                if entry.priority > existing.priority then
                    index = i
                    break
                end
            end
            table.insert(handlers, index, entry)
        end,
    },
}, { __index = _G })

local files = { "commands/compact.lua", "commands/memory.lua" }
assert(files[1] < files[2], "fixture must match the loader's sorted filename order")
for _, path in ipairs(files) do
    loading = path
    assert(loadfile(path, "t", env))()
end

assert(#handlers == 2)
assert(handlers[1].owner == "commands/memory.lua",
    "memory injection must precede automatic compaction")
assert(handlers[2].owner == "commands/compact.lua")
assert(handlers[1].priority > handlers[2].priority)

local base_prompt = "normal provider system prompt"
local memory_text = "<!-- last_updated: 2026-08-18 -->\n- concise responses"
local history = {
    { role = "user", content = "old question" },
    { role = "assistant", content = "old answer " .. string.rep("context ", 4000) },
    { role = "user", content = "current question" },
}
local memory_result = handlers[1].handler(nil, {
    config_dir = "/config",
    cwd = "/work/project",
    fs = { is_file = function(path) return path == "/config/memory/global.md" end },
    read_file = function(path)
        assert(path == "/config/memory/global.md")
        return memory_text
    end,
    conversation = { history = function() return history end },
    log = { warn = function(message) error(message) end },
})
assert(type(memory_result.system_prompt_append) == "string")
local active_prompt = base_prompt .. "\n\n" .. memory_result.system_prompt_append

local private_request
local compact_result = handlers[2].handler(nil, {
    settings = { get = function(path)
        if path == "compact.auto" then return true end
        if path == "compact.trigger_percentage" then return 80 end
        if path == "compact.fallback_context_window_tokens" then return 100000 end
    end },
    config = { get_table = function() return { compact = true } end },
    model = { context_window_tokens = 100000 },
    usage = { snapshot = function() return { context_length = 90000 } end },
    conversation = {
        current = function() return { id = 9001 } end,
        history = function() return history end,
        system_prompt = function() return active_prompt end,
        context_tokens = function(messages) return #messages * 100 end,
    },
    tools = { definitions = function() return {} end },
    llm = { complete = function(options)
        private_request = options.messages
        return { ok = true, content = "## Objective\n- Continue", tool_calls = {} }
    end },
    ui = { status = function() end, notice = function() end },
})

assert(compact_result and compact_result.action == "conversation.replace")
assert(private_request[1].role == "system")
assert(private_request[1].content == active_prompt,
    "private compaction must use the prompt after memory injection")
assert(#private_request == #history + 2)
for i, message in ipairs(history) do
    assert(private_request[i + 1] == message,
        "private compaction must preserve history identity and order")
end
assert(private_request[#private_request].role == "user")
assert(private_request[#private_request].content:find("continuation capsule", 1, true))

print("catalog compaction order test passed")
