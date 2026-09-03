-- Run with: lua tests/mcp_test.lua
local registered = {}
local settings_page

bone = {
    version = "test",
    settings = {
        define = function(namespace, page)
            assert(namespace == "mcp")
            settings_page = page
        end,
    },
    tool = {
        register = function(spec) registered[spec.name] = spec end,
    },
}

local decoded = {
    ["{}"] = {},
    ['["--root","/tmp"]'] = { "--root", "/tmp" },
    INIT_OK = { jsonrpc = "2.0", id = 1, result = { protocolVersion = "2024-11-05" } },
    LIST_OK = { jsonrpc = "2.0", id = 2, result = { tools = { { name = "read_file" } } } },
    CALL_OK = { jsonrpc = "2.0", id = 2, result = { content = { { type = "text", text = "done" } } } },
    CALL_ERROR = { jsonrpc = "2.0", id = 2, error = { code = -32601, message = "missing" } },
}

cjson = {
    decode = function(value)
        local result = decoded[value]
        if result == nil then error("invalid JSON: " .. tostring(value)) end
        return result
    end,
    encode = function(value)
        if type(value) ~= "table" then return tostring(value) end
        if value.method == "initialize" then return "INIT" end
        if value.method == "notifications/initialized" then return "INITIALIZED" end
        if value.method == "tools/list" then return "LIST" end
        if value.method == "tools/call" then return "CALL" end
        if value.content ~= nil and type(value.content) == "string" then
            return "ENVELOPE:" .. value.content
        end
        if value.tools then return "TOOLS_RESULT" end
        if value.content then return "CALL_RESULT" end
        if value.code then return "RPC_ERROR" end
        return "OBJECT"
    end,
}

assert(loadfile("tools/mcp.lua"))()
assert(settings_page and settings_page.fields.command.default == "")
assert(registered.mcp_list and registered.mcp_call)
assert(registered.mcp_list.safety == "read_only")
assert(registered.mcp_call.safety == "danger")

local values = {
    ["mcp.command"] = "mcp-server",
    ["mcp.arguments"] = '["--root","/tmp"]',
    ["mcp.protocol_version"] = "2024-11-05",
    ["mcp.timeout_ms"] = 5000,
    ["mcp.max_output_bytes"] = 4096,
}
local exec_result = { spawned = true, stdout = "INIT_OK\nLIST_OK\n", stderr = "", exit_code = 0 }
local captured
local ctx = {
    config = { get = function(ns, key) return values[ns .. "." .. key] end },
    exec = function(program, args, opts)
        captured = { program = program, args = args, opts = opts }
        return exec_result
    end,
}

local result = registered.mcp_list.execute({}, ctx)
assert(result == "TOOLS_RESULT", result)
assert(captured.program == "mcp-server")
assert(captured.args[1] == "--root" and captured.args[2] == "/tmp")
assert(captured.opts.stdin == "INIT\nINITIALIZED\nLIST\n", captured.opts.stdin)
assert(captured.opts.timeout_ms == 5000)
assert(captured.opts.max_output_bytes == 4096)

exec_result.stdout = "server log\nINIT_OK\nCALL_OK\n"
result = registered.mcp_call.execute({ tool = "read_file", arguments = { path = "a.txt" } }, ctx)
assert(result == "ENVELOPE:CALL_RESULT", result)
assert(captured.opts.stdin == "INIT\nINITIALIZED\nCALL\n", captured.opts.stdin)

exec_result.stdout = "INIT_OK\nCALL_ERROR\n"
result = registered.mcp_call.execute({ tool = "missing" }, ctx)
assert(result == "ERROR: MCP error: RPC_ERROR", result)

-- Server stays alive (times out) but already emitted the answer: salvage it.
exec_result = { spawned = true, timed_out = true, stdout = "INIT_OK\nLIST_OK\n", stderr = "" }
result = registered.mcp_list.execute({}, ctx)
assert(result == "TOOLS_RESULT", result)

-- Server times out with nothing captured: report the timeout and the knob.
exec_result = { spawned = true, timed_out = true, stdout = "", stderr = "" }
result = registered.mcp_list.execute({}, ctx)
assert(
    result == "ERROR: MCP server timed out after 5000ms with no response; if it stays alive past stdin EOF, lower MCP timeout_ms",
    result
)

values["mcp.command"] = "  "
local ok, err = pcall(registered.mcp_list.execute, {}, ctx)
assert(not ok and tostring(err):find("not configured", 1, true), tostring(err))

values["mcp.command"] = "mcp-server"
values["mcp.arguments"] = "not json"
ok, err = pcall(registered.mcp_list.execute, {}, ctx)
assert(not ok and tostring(err):find("JSON array", 1, true), tostring(err))

ok, err = pcall(registered.mcp_call.execute, { tool = " \t" }, ctx)
assert(not ok and tostring(err):find("non-empty", 1, true), tostring(err))

print("mcp tests passed")
