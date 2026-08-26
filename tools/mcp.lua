-- Standalone stdio MCP client for Bone.
--
-- Configure one server under MCP in /config. The server is started for every
-- operation and receives initialize, initialized, and the requested operation
-- in one stdin batch. This works only with servers that process that batch in
-- order and exit when stdin closes; Bone's Lua process API cannot perform the
-- interactive MCP initialization sequence or retain a server session.

local catalog_description = "List and call tools on a configured stdio MCP server. This standalone client starts the server for each operation and requires a server that accepts a batched initialization sequence and exits on stdin EOF."

local DEFAULT_PROTOCOL_VERSION = "2024-11-05"
local DEFAULT_TIMEOUT_MS = 120000
local DEFAULT_MAX_OUTPUT_BYTES = 10 * 1024 * 1024
local INIT_ID = 1
local REQUEST_ID = 2

bone.settings.define("mcp", {
    title = "MCP",
    fields = {
        command = {
            label = "Server command",
            type = "string",
            default = "",
        },
        arguments = {
            label = "Server arguments (JSON array)",
            type = "string",
            default = "[]",
        },
        protocol_version = {
            label = "Protocol version",
            type = "string",
            default = DEFAULT_PROTOCOL_VERSION,
        },
        timeout_ms = {
            label = "Timeout (milliseconds)",
            type = "number",
            integer = true,
            min = 1000,
            max = 3600000,
            default = DEFAULT_TIMEOUT_MS,
        },
        max_output_bytes = {
            label = "Maximum output bytes",
            type = "number",
            integer = true,
            min = 1024,
            max = 25 * 1024 * 1024,
            default = DEFAULT_MAX_OUTPUT_BYTES,
        },
    },
})

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function setting(ctx, key, default)
    if not (ctx.settings and ctx.settings.get) then return default end
    local value = ctx.settings.get("mcp." .. key)
    if value == nil then return default end
    return value
end

local function decode_arguments(raw)
    raw = trim(raw)
    if raw == "" then raw = "[]" end
    if not raw:match("^%[") then
        error("MCP server arguments must be a JSON array of strings", 0)
    end

    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or type(decoded) ~= "table" then
        error("MCP server arguments must be a JSON array of strings", 0)
    end

    local count = 0
    for key, value in pairs(decoded) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or type(value) ~= "string" then
            error("MCP server arguments must be a JSON array of strings", 0)
        end
        count = count + 1
    end
    if count ~= #decoded then
        error("MCP server arguments must be a JSON array of strings", 0)
    end
    return decoded
end

local function bounded_integer(value, default, minimum, maximum)
    value = tonumber(value)
    if not value or value % 1 ~= 0 then return default end
    return math.max(minimum, math.min(maximum, value))
end

local function diagnostic(value)
    value = trim(value)
    if #value > 2000 then value = value:sub(1, 2000) .. "... (truncated)" end
    return value
end

local function encode_error(value)
    local ok, encoded = pcall(cjson.encode, value)
    if ok then return encoded end
    return tostring(value or "unknown MCP error")
end

local function server_config(ctx)
    local command = trim(setting(ctx, "command", ""))
    if command == "" then
        error("MCP server is not configured; set MCP > Server command in /config", 0)
    end

    return {
        command = command,
        arguments = decode_arguments(setting(ctx, "arguments", "[]")),
        protocol_version = trim(setting(ctx, "protocol_version", DEFAULT_PROTOCOL_VERSION)),
        timeout_ms = bounded_integer(
            setting(ctx, "timeout_ms", DEFAULT_TIMEOUT_MS),
            DEFAULT_TIMEOUT_MS,
            1000,
            3600000
        ),
        max_output_bytes = bounded_integer(
            setting(ctx, "max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES),
            DEFAULT_MAX_OUTPUT_BYTES,
            1024,
            25 * 1024 * 1024
        ),
    }
end

local function rpc(ctx, method, params)
    local server = server_config(ctx)
    if server.protocol_version == "" then server.protocol_version = DEFAULT_PROTOCOL_VERSION end

    -- Decode an empty object so cjson preserves {} instead of encoding an empty
    -- Lua sequence as [].
    local empty_object = cjson.decode("{}")
    local messages = {
        cjson.encode({
            jsonrpc = "2.0",
            id = INIT_ID,
            method = "initialize",
            params = {
                protocolVersion = server.protocol_version,
                capabilities = empty_object,
                clientInfo = { name = "bone", version = tostring(bone.version or "unknown") },
            },
        }),
        cjson.encode({
            jsonrpc = "2.0",
            method = "notifications/initialized",
        }),
        cjson.encode({
            jsonrpc = "2.0",
            id = REQUEST_ID,
            method = method,
            params = params or empty_object,
        }),
    }

    local result = ctx.exec(server.command, server.arguments, {
        stdin = table.concat(messages, "\n") .. "\n",
        timeout_ms = server.timeout_ms,
        max_output_bytes = server.max_output_bytes,
    })

    if not result.spawned then
        return nil, "failed to start MCP server: " .. diagnostic(result.error)
    end
    if result.cancelled then return nil, "MCP request was cancelled" end
    if result.output_limit_exceeded then return nil, "MCP server exceeded the output limit" end

    local initialize_error
    local response
    for line in tostring(result.stdout or ""):gmatch("[^\r\n]+") do
        local ok, message = pcall(cjson.decode, line)
        if ok and type(message) == "table" then
            if message.id == INIT_ID and message.error ~= nil then
                initialize_error = encode_error(message.error)
            elseif message.id == REQUEST_ID then
                response = message
            end
        end
    end

    if response then
        if response.error ~= nil then return nil, "MCP error: " .. encode_error(response.error) end
        return response.result, nil
    end
    if initialize_error then return nil, "MCP initialization failed: " .. initialize_error end
    -- No response line was captured. If we timed out, the server likely stayed
    -- alive past stdin EOF instead of exiting; say so and point at the knob.
    if result.timed_out then
        return nil,
            "MCP server timed out after " .. tostring(server.timeout_ms)
                .. "ms with no response; if it stays alive past stdin EOF, lower MCP timeout_ms"
    end

    local detail = diagnostic(result.stderr)
    if detail == "" then detail = diagnostic(result.stdout) end
    if detail == "" then detail = "no response for JSON-RPC id " .. tostring(REQUEST_ID) end
    if result.exit_code ~= nil and result.exit_code ~= 0 then
        detail = "server exited " .. tostring(result.exit_code) .. ": " .. detail
    end
    return nil, detail
end

local function list_tools(_, ctx)
    local result, err = rpc(ctx, "tools/list", cjson.decode("{}"))
    if err then return "ERROR: " .. err end
    return cjson.encode(result)
end

local function call_tool(params, ctx)
    local name = trim(params.tool)
    if name == "" then error("tool must be a non-empty string", 0) end

    local arguments = params.arguments
    if arguments == nil then arguments = cjson.decode("{}") end
    local result, err = rpc(ctx, "tools/call", {
        name = name,
        arguments = arguments,
    })
    if err then return "ERROR: " .. err end
    -- Wrap in the tool-output envelope. A bare MCP result is a JSON object
    -- with a top-level "content" key (an array), which the host would
    -- misparse as its own envelope and reduce to an empty string.
    return cjson.encode({ content = cjson.encode(result) })
end

bone.tool.register({
    name = "mcp_list",
    description = "List the tools and input schemas exposed by the configured stdio MCP server. Call this before mcp_call when the available tool names or arguments are unknown.",
    parameters = {
        type = "object",
        additionalProperties = false,
    },
    safety = "read_only",
    execute = list_tools,
})

bone.tool.register({
    name = "mcp_call",
    description = "Call a tool on the configured stdio MCP server. Use mcp_list first to discover the exact tool name and argument schema.",
    parameters = {
        type = "object",
        properties = {
            tool = {
                type = "string",
                minLength = 1,
                description = "Exact MCP tool name returned by mcp_list.",
            },
            arguments = {
                type = "object",
                description = "Arguments matching the MCP tool's input schema.",
            },
        },
        required = { "tool" },
        additionalProperties = false,
    },
    safety = "danger",
    execute = call_tool,
})
