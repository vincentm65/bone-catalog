local function hex_encode(value)
    local bytes = {}
    for i = 1, #value do
        bytes[i] = string.format("%02x", value:byte(i))
    end
    return table.concat(bytes)
end

local function execute(params, ctx)
    local query = params.query
    if type(query) ~= "string" or query:match("^%s*$") then
        error("query must be a non-empty string", 0)
    end

    local num_results = params.num_results
    if num_results == nil then num_results = 5 end
    if type(num_results) ~= "number" or num_results % 1 ~= 0 then
        error("num_results must be an integer", 0)
    end
    num_results = math.max(1, math.min(10, num_results))

    -- Only hexadecimal query bytes enter the shell command. Decode them in
    -- Python so shell metacharacters remain literal search text.
    local cmd = string.format(
        "uv run --with ddgs -- python3 -c 'import json, sys; from ddgs import DDGS; query = bytes.fromhex(sys.argv[1]).decode(\"utf-8\"); num = int(sys.argv[2]); [print(json.dumps(r)) for r in DDGS().text(query, max_results=num)]' %s %d",
        hex_encode(query), num_results
    )

    local result = ctx.shell(cmd, { timeout_ms = 300000 })
    local exit_code = result.exit_code or -1
    if exit_code ~= 0 then
        local detail = result.stderr
        if not detail or detail == "" then detail = result.stdout end
        if not detail or detail == "" then detail = "no error output" end
        return string.format("ERROR: web search failed (exit %s): %s", tostring(exit_code), detail)
    end
    if not result.stdout or result.stdout == "" then return "No results." end
    return result.stdout
end

bone.tool.register({
    name = "web_search",
    description = "Search the web for information using DuckDuckGo. Returns titles, URLs and summaries. Useful for looking up documentation, current events, technical topics, and general knowledge.",
    parameters = {
        type = "object",
        properties = {
            query = {
                type = "string",
                minLength = 1,
                description = "The search query",
            },
            num_results = {
                type = "integer",
                minimum = 1,
                maximum = 10,
                description = "Number of results to return (default 5).",
            },
        },
        required = { "query" },
        additionalProperties = false,
    },
    safety = "read_only",
    execute = execute,
})
