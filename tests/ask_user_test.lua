-- Run with: lua tests/ask_user_test.lua
local registered
local calls = {}
local responses = {}

local function json_escape(value)
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
end
local function json_encode(value)
    local kind = type(value)
    if kind == "string" then return json_escape(value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind ~= "table" then error("unsupported JSON value") end
    local max, count = 0, 0
    for key in pairs(value) do
        count = count + 1
        if type(key) == "number" and key > max then max = key end
    end
    if count == 0 or max == count then
        local parts = {}
        for i = 1, max do parts[i] = json_encode(value[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = json_escape(key) .. ":" .. json_encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
cjson = { encode = json_encode }

local menu = {}
local function reply(kind, _, spec)
    calls[#calls + 1] = { kind = kind, spec = spec }
    local result = table.remove(responses, 1)
    if type(result) == "function" then return result() end
    assert(result ~= nil, "missing mocked menu response")
    return result
end
function menu.select(ctx, spec) return reply("select", ctx, spec) end
function menu.multi_select(ctx, spec) return reply("multi_select", ctx, spec) end
function menu.text_input(ctx, spec) return reply("text_input", ctx, spec) end
function menu.clear() calls[#calls + 1] = { kind = "clear" } end

package.loaded["ui.menu"] = menu
bone = { tool = { register = function(spec) registered = spec end } }
assert(loadfile("tools/ask_user.lua"))()
assert(registered, "ask_user tool was not registered")

local properties = registered.parameters.properties
assert(properties.type and properties.default.type == "integer")
assert(properties.visible_rows and properties.visible_rows.minimum == 1)
assert(properties.options.items.anyOf, "top-level options must accept strings or objects")
assert(properties.options.items.anyOf[2].properties.preview,
    "object options must expose rich previews")
assert(properties.questions.items.properties.options.items.anyOf,
    "question options must accept strings or objects")
assert(properties.questions.items.properties.visible_rows.minimum == 1)

local ctx = { ui = {} }
local function run(params, mocked)
    calls, responses = {}, mocked or {}
    return registered.execute(params, ctx)
end
local function expect_error(params, pattern, mocked)
    calls, responses = {}, mocked or {}
    local ok, err = pcall(registered.execute, params, ctx)
    assert(not ok, "expected tool error")
    assert(tostring(err):find(pattern, 1, true), tostring(err))
    return err
end

local result = run({
    question = "Pick one",
    options = {
        "A",
        {
            label = "Bee",
            value = "B",
            description = "second",
            preview = {
                title = "Bee diagram",
                lines = {
                    "A ──▶ B",
                    { spans = { { text = "ready", fg = "#78B373", modifiers = { "bold" } } } },
                },
            },
        },
    },
    default = 2,
    visible_rows = 18,
}, { { value = "B", selected = 2 } })
assert(result:find('"cancelled":false', 1, true))
assert(result:find('"question":"Pick one"', 1, true))
assert(result:find('"value":"B"', 1, true))
assert(calls[1].kind == "select" and calls[1].spec.default == 2)
assert(calls[1].spec.visible_rows == 18)
assert(calls[1].spec.options[2].value == "B")
assert(calls[1].spec.options[2].description == "second")
assert(calls[1].spec.options[2].preview.title == "Bee diagram")
assert(calls[1].spec.options[2].preview.lines[1] == "A ──▶ B")
assert(calls[1].spec.options[2].preview.lines[2].spans[1].fg == "#78B373")
assert(calls[1].spec.options[2].preview.lines[2].spans[1].modifiers[1] == "bold")

result = run({
    question = "Adaptive preview",
    options = {
        { label = "Short", preview = { lines = { "one" } } },
        { label = "Diagram", preview = { lines = { "1", "2", "3" } } },
    },
}, { { value = "Short", selected = 1 } })
assert(calls[1].spec.visible_rows == nil, "preview menus must use the core adaptive height")

result = run({ question = "No preview", options = { "A" } }, { { value = "A", selected = 1 } })
assert(calls[1].spec.visible_rows == nil, "ordinary menus must retain their default height")

result = run({ question = "Notes", type = "text_input" }, {
    { value = "first line\nsecond line" },
})
assert(result:find('"value":"first line\\nsecond line"', 1, true), result)

result = run({ question = "Cancel", options = { "A" } }, { { cancelled = true } })
assert(result:find('"cancelled":true', 1, true), result)
assert(result:find('"answers":[]', 1, true), result)

local questions = {
    { question = "Single?", options = { "A", "C" }, visible_rows = 16 },
    { question = "Many?", type = "multi_select", options = { "B", "D" }, allow_custom = true },
    { question = "Text?", type = "text_input" },
}
result = run({ questions = questions }, {
    { value = "A", selected = 1 },
    { values = { "B" }, custom = "old custom", selected = 2 },
    { value = "old\ntext" },
    { value = "1" },
    { value = "C", selected = 2 },
    { value = "2" },
    { values = { "D" }, custom = "new custom", selected = 1 },
    { value = "3" },
    { value = "new\ntext" },
    { value = "submit" },
})
assert(calls[1].spec.title == "Question 1 of 3")
assert(calls[1].spec.visible_rows == 16)
assert(calls[5].spec.default == 1, "single-select selection was not restored")
assert(calls[7].spec.default == 2, "multi-select highlight was not restored")
assert(calls[7].spec.initial_checked[1] == "B", "multi-select checks were not restored")
assert(calls[7].spec.initial == "old custom", "multi-select custom text was not restored")
assert(calls[9].spec.initial == "old\ntext", "text input was not restored")
assert(result:find('"value":"C"', 1, true), result)
assert(result:find('"values":["D","new custom"]', 1, true), result)
assert(result:find('"value":"new\\ntext"', 1, true), result)
assert(not result:find('"value":"A"', 1, true), "revised answer was not replaced")

expect_error({ question = "Bad", type = "single", options = { "A" } },
    "question 1 field 'type'")
expect_error({ question = "Bad", type = "multi", options = { "A" } },
    "question 1 field 'type'")
expect_error({ question = "Bad", type = "single_select" },
    "question 1 field 'options'")
expect_error({ question = "Bad", options = { "A" }, default = 1.5 },
    "question 1 field 'default': must be an integer")
expect_error({ question = "Bad", options = { "A" }, default = 2 },
    "question 1 field 'default': must be a valid 1-based option index")
expect_error({ question = "Bad", options = { "A" }, visible_rows = 0 },
    "question 1 field 'visible_rows': must be a positive integer")
expect_error({ question = "Bad", type = "text_input", default = 1 },
    "question 1 field 'default': does not apply")
expect_error({ question = "One", questions = { { question = "Two" } } },
    "fields 'question' and 'questions' are mutually exclusive")
expect_error({ questions = { { question = "Bad", options = { { description = "missing label" } } } } },
    "question 1 field 'options[1].label'")
expect_error({ question = "Bad", options = { { label = "A", preview = { lines = {} } } } },
    "question 1 field 'options[1].preview.lines': must contain at least one line")
expect_error({ question = "Bad", options = { {
    label = "A", preview = { lines = { { spans = { { text = 1 } } } } },
} } }, "question 1 field 'options[1].preview.lines[1].spans[1].text'")
assert(#calls == 0, "validation must finish before opening or clearing UI")

expect_error({ questions = {
    { question = "First", options = { "A" } },
} }, "review menu failed: transport down", {
    { value = "A", selected = 1 },
    function() error("transport down", 0) end,
})

print("ask_user tests passed")
