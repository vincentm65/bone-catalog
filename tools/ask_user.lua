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
-- catalog_description = "Ask one question directly, or use questions for several. Every select question must contain its own nested options array unless allow_custom is true."

local menu = require("ui.menu")

local QUESTION_TYPES = { "single_select", "multi_select", "text_input" }
local VALID_TYPES = {}
for _, qtype in ipairs(QUESTION_TYPES) do VALID_TYPES[qtype] = true end

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
    if q.visible_rows ~= nil and (type(q.visible_rows) ~= "number"
            or q.visible_rows % 1 ~= 0 or q.visible_rows < 1) then
        fail(index, "visible_rows", "must be a positive integer")
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
    if result.cancelled == true or result.back == true then return true end
    if qtype == "multi_select" then
        if type(result.values) ~= "table" then return false end
        for _, value in ipairs(result.values) do
            if type(value) ~= "string" then return false end
        end
        return result.custom == nil or type(result.custom) == "string"
    end
    return type(result.value) == "string"
end

local function ask_one(q, ctx, index, total, previous, allow_back, allow_forward)
    local spec = {
        title = total and string.format("Question %d of %d", index, total) or nil,
        progress = total and string.format("Question %d of %d", index, total) or nil,
        allow_back = allow_back == true and index > 1,
        allow_forward = allow_forward == true and total ~= nil and index < total,
        question = q.question,
        -- ui.menu owns option normalization, including string shorthand and
        -- rich previews. Validation above keeps malformed tool input out.
        options = q.options or {},
        default = q.default,
        visible_rows = q.visible_rows,
        allow_custom = q.allow_custom == true,
    }
    if previous then
        if q._type == "single_select" then
            spec.default = previous.selected
            if previous.custom then
                spec.initial = previous.value
                spec.initial_custom = true
            end
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
    if result.cancelled then return nil, true, false end
    if result.back then return result, false, true end
    return result, false, false
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

local function truncate_utf8(value, max_bytes)
    if #value <= max_bytes then return value end
    local cut = math.max(0, max_bytes - 3)
    while cut > 0 do
        local byte = value:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return value:sub(1, cut) .. "..."
end

local function build_review_options(questions, answers)
    local options = { { label = "✓ Submit all answers", value = "submit" } }
    for i, q in ipairs(questions) do
        local short_q = truncate_utf8(q.question, 50)
        local summary = truncate_utf8(answer_summary(answers[i]), 40)
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
    local index = 1
    while index <= #questions do
        local result, cancelled, back = ask_one(
            questions[index],
            ctx,
            index,
            multiple and #questions or nil,
            answers[index],
            multiple,
            multiple and index < #questions
        )
        if cancelled then return nil, true end
        if back then
            answers[index] = result
            index = index - 1
        else
            answers[index] = result
            index = index + 1
        end
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

local QUESTION_PROPERTY = {
    type = "string",
    description = "The question to ask.",
}
local OPTIONS_PROPERTY = {
    type = "array",
    minItems = 1,
    description = "Choices for this question. In multi-question mode, put this array inside "
        .. "the corresponding questions item, not at the top level. Object options may include "
        .. "a description and rich preview; strings are shorthand labels.",
    items = OPTION_ITEMS,
}
local ALLOW_CUSTOM_PROPERTY = {
    type = "boolean",
    description = "Add a 'type your own answer' row below the options.",
}
local DEFAULT_PROPERTY = {
    type = "integer",
    minimum = 1,
    description = "Default selected option index (1-based).",
}
local VISIBLE_ROWS_PROPERTY = {
    type = "integer",
    minimum = 1,
    description = "Requested menu height in rows. Defaults to 12.",
}

-- Separate answer-mode variants make invalid select questions structurally
-- invalid in the advertised schema instead of leaving that rule to execute().
local QUESTION_VARIANTS = {
    {
        title = "Select question with choices",
        type = "object",
        properties = {
            question = QUESTION_PROPERTY,
            options = OPTIONS_PROPERTY,
            allow_custom = ALLOW_CUSTOM_PROPERTY,
            type = {
                type = "string",
                enum = { "single_select", "multi_select" },
                description = "Selection type. Omit for single_select; use multi_select for checkboxes.",
            },
            default = DEFAULT_PROPERTY,
            visible_rows = VISIBLE_ROWS_PROPERTY,
        },
        required = { "question", "options" },
        additionalProperties = false,
    },
    {
        title = "Text question",
        type = "object",
        properties = {
            question = QUESTION_PROPERTY,
            type = {
                type = "string",
                enum = { "text_input" },
                description = "Text input type. This may be omitted when no options are provided.",
            },
            visible_rows = VISIBLE_ROWS_PROPERTY,
        },
        required = { "question" },
        additionalProperties = false,
    },
    {
        title = "Custom-only selection question",
        type = "object",
        properties = {
            question = QUESTION_PROPERTY,
            options = {
                type = "array",
                description = "Optional choices for this question; may be empty when custom input is enabled.",
                items = OPTION_ITEMS,
            },
            allow_custom = {
                type = "boolean",
                enum = { true },
                description = "Must be true when a selection question has no choices.",
            },
            type = {
                type = "string",
                enum = { "single_select", "multi_select" },
            },
            visible_rows = VISIBLE_ROWS_PROPERTY,
        },
        required = { "question", "type", "allow_custom" },
        additionalProperties = false,
    },
}

local QUESTION_SCHEMA = {
    anyOf = QUESTION_VARIANTS,
}

local ROOT_VARIANTS = {}
for _, variant in ipairs(QUESTION_VARIANTS) do ROOT_VARIANTS[#ROOT_VARIANTS + 1] = variant end
ROOT_VARIANTS[#ROOT_VARIANTS + 1] = {
    title = "Multiple questions",
    type = "object",
    properties = {
        questions = {
            type = "array",
            minItems = 1,
            description = "Questions to ask sequentially. Each select question must contain its "
                .. "own options array; do not put options beside the questions array.",
            items = QUESTION_SCHEMA,
        },
    },
    required = { "questions" },
    additionalProperties = false,
}

bone.tool.register({
    name = "ask_user",
    description = "Ask one question directly, or use questions for several. Every select question must contain its own options array unless allow_custom is true.",
    parameters = {
        type = "object",
        anyOf = ROOT_VARIANTS,
    },
    safety = "read_only",
    display = {
        show = false,
        args = { "question", "questions" },
    },
    execute = execute,
})
