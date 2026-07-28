-- Run with: lua tests/web_search_test.lua
local registered
bone = { tool = { register = function(spec) registered = spec end } }
assert(loadfile("tools/web_search.lua"))()
assert(registered and registered.name == "web_search")
assert(registered.parameters.properties.query.minLength == 1)

local captured_command
local shell_result
local ctx = {
    shell = function(command, opts)
        captured_command = command
        assert(opts.timeout_ms == 300000)
        return shell_result
    end,
}

local function hex_encode(value)
    local bytes = {}
    for i = 1, #value do bytes[i] = string.format("%02x", value:byte(i)) end
    return table.concat(bytes)
end

local query = "literal $HOME $(printf injected) `whoami` \"quote\" \\\n雪"
shell_result = { stdout = "result\n", stderr = "harmless warning\n", exit_code = 0 }
local result = registered.execute({ query = query, num_results = 7 }, ctx)
assert(result == "result\n", result)
assert(captured_command:find(hex_encode(query), 1, true), "encoded query missing from command")
assert(not captured_command:find("$HOME", 1, true), "environment reference leaked into command")
assert(not captured_command:find("$(", 1, true), "command substitution leaked into command")
assert(not captured_command:find("`", 1, true), "backticks leaked into command")
assert(captured_command:match(" 7$"), captured_command)

shell_result = { stdout = "", stderr = "", exit_code = 0 }
result = registered.execute({ query = "nothing" }, ctx)
assert(result == "No results.", result)

shell_result = { stdout = "", stderr = "network down", exit_code = 2 }
result = registered.execute({ query = "failure" }, ctx)
assert(result:find("exit 2", 1, true) and result:find("network down", 1, true), result)

shell_result = { stdout = "stdout fallback", stderr = "", exit_code = 3 }
result = registered.execute({ query = "failure" }, ctx)
assert(result:find("stdout fallback", 1, true), result)

shell_result = { stdout = "ok", stderr = "", exit_code = 0 }
registered.execute({ query = "low", num_results = 0 }, ctx)
assert(captured_command:match(" 1$"), captured_command)
registered.execute({ query = "high", num_results = 99 }, ctx)
assert(captured_command:match(" 10$"), captured_command)

local ok, err = pcall(registered.execute, { query = " \t\n" }, ctx)
assert(not ok and tostring(err):find("non-empty", 1, true), tostring(err))
ok, err = pcall(registered.execute, { query = "valid", num_results = 1.5 }, ctx)
assert(not ok and tostring(err):find("integer", 1, true), tostring(err))
ok, err = pcall(registered.execute, { query = "valid", num_results = false }, ctx)
assert(not ok and tostring(err):find("integer", 1, true), tostring(err))

print("web_search tests passed")
