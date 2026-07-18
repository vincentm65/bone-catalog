-- ask_user — interactive question tool using ui.menu.
--
-- Supports single_select, multi_select, and text_input question types.
-- Questions are rendered in the bottom pane with keyboard-driven
-- selection, optional custom text input, and optional per-option rich previews.
--
-- Two calling modes:
--   1. Single question: { question, options, allow_custom, type, default }
--   2. Multi-question:  { questions = { {question, options, allow_custom, type, default}, ... } }
--      Asks each question sequentially with backtracking navigation.
--      After answering, user can go back to previous questions or proceed.

local menu = require("ui.menu")

local VALID_TYPES = {
    single_select = true,
    multi_select = true,
    text_input = true,
}

local function fail(index, field, message)
    error(string.format("question %d field '%s': %s", index, field, message), 0)
end

local function array_length(value, index, field)
    if type(value) ~= "table" then fail(index, field, "must be an array") end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            fail(index, field, "must be an array")
        end
        count = count + 1
    end
    if count ~= #value then fail(index, field, "must not contain gaps") end
    return count
end

local function get_qtype(q)
    if q.type then return q.type end
    return q.options and #q.options > 0 and "single_select" or "text_input"
end

local function normalize_preview(preview)
    if not preview then return nil end
    local out = { title = preview.title, lines = {} }
    for i, raw in ipairs(preview.lines) do
        if type(raw) == "string" then
            out.lines[i] = raw
        else
            local spans = {}
            for j, value_span in ipairs(raw.spans) do
                spans[j] = {
                    text = value_span.text,
                    fg = value_span.fg,
                    modifiers = value_span.modifiers,
                }
            end
            out.lines[i] = { spans = spans, bg = raw.bg }
        end
    end
    return out
end

local function normalize_options(options)
    local out = {}
    for i, opt in ipairs(options or {}) do
        if type(opt) == "table" then
            out[i] = {
                label = opt.label,
                value = opt.value,
                description = opt.description,
                preview = normalize_preview(opt.preview),
            }
        else
            out[i] = { label = opt, value = opt }
        end
    end
    return out
end

local function validate_preview(preview, index, field)
    if type(preview) ~= "table" then fail(index, field, "must be an object") end
    if preview.title ~= nil and type(preview.title) ~= "string" then
        fail(index, field .. ".title", "must be a string")
    end
    local line_count = array_length(preview.lines, index, field .. ".lines")
    if line_count == 0 then fail(index, field .. ".lines", "must contain at least one line") end
    for line_index, raw in ipairs(preview.lines) do
        local line_field = string.format("%s.lines[%d]", field, line_index)
        if type(raw) == "string" then
            -- Plain preview line.
        elseif type(raw) == "table" then
            local span_count = array_length(raw.spans, index, line_field .. ".spans")
            if span_count == 0 then fail(index, line_field .. ".spans", "must contain at least one span") end
            if raw.bg ~= nil and type(raw.bg) ~= "string" then
                fail(index, line_field .. ".bg", "must be a string")
            end
            for span_index, value_span in ipairs(raw.spans) do
                local span_field = string.format("%s.spans[%d]", line_field, span_index)
                if type(value_span) ~= "table" then fail(index, span_field, "must be an object") end
                if type(value_span.text) ~= "string" then fail(index, span_field .. ".text", "must be a string") end
                if value_span.fg ~= nil and type(value_span.fg) ~= "string" then
                    fail(index, span_field .. ".fg", "must be a string")
                end
                if value_span.modifiers ~= nil then
                    array_length(value_span.modifiers, index, span_field .. ".modifiers")
                    for modifier_index, modifier in ipairs(value_span.modifiers) do
                        if type(modifier) ~= "string" then
                            fail(index, string.format("%s.modifiers[%d]", span_field, modifier_index), "must be a string")
                        end
                    end
                end
            end
        else
            fail(index, line_field, "must be a string or styled line object")
        end
    end
end

local function validate_question(q, index)
    if type(q) ~= "table" then fail(index, "question", "question specification must be an object") end
    if type(q.question) ~= "string" then fail(index, "question", "must be a string") end
    if q.allow_custom ~= nil and type(q.allow_custom) ~= "boolean" then
        fail(index, "allow_custom", "must be a boolean")
    end
    if q.type ~= nil and (type(q.type) ~= "string" or not VALID_TYPES[q.type]) then
        fail(index, "type", "must be single_select, multi_select, or text_input")
    end

    local option_count = 0
    if q.options ~= nil then
        option_count = array_length(q.options, index, "options")
        for i, opt in ipairs(q.options) do
            local field = string.format("options[%d]", i)
            if type(opt) == "string" then
                -- String shorthand is already normalized.
            elseif type(opt) == "table" then
                if type(opt.label) ~= "string" then fail(index, field .. ".label", "must be a string") end
                if opt.value ~= nil and type(opt.value) ~= "string" then
                    fail(index, field .. ".value", "must be a string")
                end
                if opt.description ~= nil and type(opt.description) ~= "string" then
                    fail(index, field .. ".description", "must be a string")
                end
                if opt.preview ~= nil then validate_preview(opt.preview, index, field .. ".preview") end
            else
                fail(index, field, "must be a string or option object")
            end
        end
    end

    local qtype = get_qtype(q)
    if qtype ~= "text_input" and option_count == 0 and q.allow_custom ~= true then
        fail(index, "options", "select questions require options unless allow_custom is true")
    end
    if q.default ~= nil then
        if qtype == "text_input" then fail(index, "default", "does not apply to text_input") end
        if type(q.default) ~= "number" or q.default % 1 ~= 0 then
            fail(index, "default", "must be an integer")
        end
        if q.default < 1 or q.default > option_count then
            fail(index, "default", string.format("must be a valid 1-based option index (1-%d)", option_count))
        end
    end

    q._type = qtype
    q._options = normalize_options(q.options)
    return q
end

local function validate_params(params)
    if type(params) ~= "table" then error("parameters must be an object", 0) end
    local has_question = params.question ~= nil
    local has_questions = params.questions ~= nil
    if has_question and has_questions then
        error("fields 'question' and 'questions' are mutually exclusive", 0)
    end
    if not has_question and not has_questions then
        error("exactly one of 'question' or 'questions' is required", 0)
    end
    if has_question then return { validate_question(params, 1) }, false end

    local total = array_length(params.questions, 1, "questions")
    if total == 0 then error("field 'questions' must contain at least one question", 0) end
    local questions = {}
    for i, q in ipairs(params.questions) do questions[i] = validate_question(q, i) end
    return questions, true
end

local function valid_result(result, qtype)
    if type(result) ~= "table" then return false end
    if result.cancelled == true then return true end
    if qtype == "multi_select" then
        if type(result.values) ~= "table" then return false end
        for _, value in ipairs(result.values) do
            if type(value) ~= "string" then return false end
        end
        return result.custom == nil or type(result.custom) == "string"
    end
    return type(result.value) == "string"
end

local function ask_one(q, ctx, index, total, previous)
    local spec = {
        title = total and string.format("Question %d of %d", index, total) or nil,
        question = q.question,
        options = q._options,
        default = q.default,
        allow_custom = q.allow_custom == true,
    }
    if previous then
        if q._type == "single_select" then
            spec.default = previous.selected
        elseif q._type == "multi_select" then
            spec.default = previous.selected
            spec.initial_checked = previous.values
            spec.initial = previous.custom
        else
            spec.initial = previous.value
        end
    end

    local fn = q._type == "single_select" and menu.select
        or q._type == "multi_select" and menu.multi_select
        or menu.text_input
    local ok, result = pcall(fn, ctx, spec)
    if not ok then error(string.format("question %d menu failed: %s", index, tostring(result)), 0) end
    if not valid_result(result, q._type) then
        error(string.format("question %d menu returned a malformed result", index), 0)
    end
    if result.cancelled then return nil, true end
    return result, false
end

local function answer_summary(result)
    if result.values then
        local values = {}
        for _, value in ipairs(result.values) do values[#values + 1] = value end
        if result.custom and result.custom ~= "" then values[#values + 1] = result.custom end
        return table.concat(values, ", ")
    end
    return result.value
end

local function build_review_options(questions, answers)
    local options = { { label = "✓ Submit all answers", value = "submit" } }
    for i, q in ipairs(questions) do
        local short_q = #q.question > 50 and q.question:sub(1, 47) .. "..." or q.question
        local summary = answer_summary(answers[i])
        if #summary > 40 then summary = summary:sub(1, 37) .. "..." end
        options[#options + 1] = {
            label = string.format("Q%d: %s → %s", i, short_q, summary),
            value = tostring(i),
        }
    end
    return options
end

local function review(questions, answers, ctx)
    local ok, result = pcall(menu.select, ctx, {
        title = "Review answers",
        question = "Review your answers. Pick a question to revise, or submit.",
        options = build_review_options(questions, answers),
        allow_custom = false,
    })
    if not ok then error("review menu failed: " .. tostring(result), 0) end
    if type(result) ~= "table" then error("review menu returned a malformed result", 0) end
    if result.cancelled == true then return nil, true end
    if type(result.value) ~= "string" then error("review menu returned a malformed result", 0) end
    if result.value == "submit" then return "submit", false end
    local index = tonumber(result.value)
    if not index or index % 1 ~= 0 or not questions[index] then
        error("review menu returned an unknown choice", 0)
    end
    return index, false
end

local function ask_all(questions, multiple, ctx)
    local answers = {}
    for i, q in ipairs(questions) do
        local result, cancelled = ask_one(q, ctx, i, multiple and #questions or nil)
        if cancelled then return nil, true end
        answers[i] = result
    end
    if not multiple then return answers, false end

    while true do
        local choice, cancelled = review(questions, answers, ctx)
        if cancelled then return nil, true end
        if choice == "submit" then return answers, false end
        local replacement, question_cancelled = ask_one(
            questions[choice], ctx, choice, #questions, answers[choice]
        )
        if question_cancelled then return nil, true end
        answers[choice] = replacement
    end
end

local function encode_answers(questions, results)
    local answers = {}
    for i, q in ipairs(questions) do
        local result = results[i]
        local answer = { question = q.question }
        if q._type == "multi_select" then
            answer.values = {}
            for _, value in ipairs(result.values) do answer.values[#answer.values + 1] = value end
            if result.custom and result.custom ~= "" then
                answer.values[#answer.values + 1] = result.custom
            end
        else
            answer.value = result.value
        end
        answers[i] = answer
    end
    return cjson.encode({ cancelled = false, answers = answers })
end

local function execute(params, ctx)
    local questions, multiple = validate_params(params)
    local ok, results, cancelled = pcall(ask_all, questions, multiple, ctx)
    pcall(menu.clear, ctx)
    if not ok then error(results, 0) end
    if cancelled then return cjson.encode({ cancelled = true, answers = {} }) end
    return encode_answers(questions, results)
end

local PREVIEW_SCHEMA = {
    type = "object",
    ["description"] = "Optional rich preview shown beside this option when it is highlighted.",
    properties = {
        title = { type = "string", ["description"] = "Optional heading shown above the preview." },
        lines = {
            type = "array",
            minItems = 1,
            ["description"] = "Preview content. Plain strings preserve whitespace; styled lines contain spans.",
            items = {
                anyOf = {
                    { type = "string" },
                    {
                        type = "object",
                        properties = {
                            spans = {
                                type = "array",
                                minItems = 1,
                                items = {
                                    type = "object",
                                    properties = {
                                        text = { type = "string" },
                                        fg = { type = "string", ["description"] = "Optional named or hex foreground color." },
                                        modifiers = {
                                            type = "array",
                                            items = { type = "string", enum = { "bold", "dim", "italic", "strike" } },
                                        },
                                    },
                                    required = { "text" },
                                    additionalProperties = false,
                                },
                            },
                            bg = { type = "string", ["description"] = "Optional named or hex line background color." },
                        },
                        required = { "spans" },
                        additionalProperties = false,
                    },
                },
            },
        },
    },
    required = { "lines" },
    additionalProperties = false,
}

local OPTION_ITEMS = {
    anyOf = {
        { type = "string" },
        {
            type = "object",
            properties = {
                label = { type = "string", ["description"] = "The option text shown to the user." },
                value = { type = "string", ["description"] = "Optional value returned instead of the label." },
                description = { type = "string", ["description"] = "Optional one-line explanation of this option." },
                preview = PREVIEW_SCHEMA,
            },
            required = { "label" },
            additionalProperties = false,
        },
    },
}

bone.tool.register({
    name = "ask_user",
    description = "Ask the user one or more questions with selectable options or custom answers. Use the 'questions' array to ask several questions back-to-back in a single call, or use top-level 'question' + 'options' for a single question.",
    parameters = {
        type = "object",
        properties = {
            question = {
                type = "string",
                description = "The question to ask (single-question mode).",
            },
            options = {
                type = "array",
                description = "Options to choose from (single-question mode). Object options may include "
                    .. "a description and a rich preview shown beside the selector. A plain string is "
                    .. "accepted as shorthand for { label = <string> }.",
                items = OPTION_ITEMS,
            },
            allow_custom = {
                type = "boolean",
                description = "Add a 'type your own answer' row below the options. Works with "
                    .. "single_select (pick one option OR type a custom answer).",
            },
            type = {
                type = "string",
                enum = { "single_select", "multi_select", "text_input" },
                description = "Question type. If omitted: 'single_select' when options are given "
                    .. "(use multi_select explicitly for checkboxes), otherwise 'text_input'.",
            },
            default = {
                type = "integer",
                description = "Default selected option index (1-based).",
            },
            questions = {
                type = "array",
                description = "Multiple questions to ask sequentially with backtracking. After answering all, you can revise any question. Each item is an object with {question, options, allow_custom, type, default}.",
                items = {
                    type = "object",
                    properties = {
                        question = { type = "string", description = "The question to ask." },
                        options = {
                            type = "array",
                            description = "Options to choose from. Object options may include a description "
                                .. "and a rich preview shown beside the selector. A plain string is accepted "
                                .. "as shorthand for { label = <string> }.",
                            items = OPTION_ITEMS,
                        },
                        allow_custom = {
                            type = "boolean",
                            description = "Add a 'type your own answer' row below the options.",
                        },
                        type = {
                            type = "string",
                            enum = { "single_select", "multi_select", "text_input" },
                            description = "Question type. If omitted: 'single_select' when "
                                .. "options are given (use multi_select explicitly for "
                                .. "checkboxes), otherwise 'text_input'.",
                        },
                        default = {
                            type = "integer",
                            description = "Default selected option index (1-based).",
                        },
                    },
                    required = { "question" },
                    additionalProperties = false,
                },
            },
        },
        additionalProperties = false,
    },
    safety = "read_only",
    display = {
        show = false,
        args = { "question", "questions" },
    },
    execute = execute,
})
