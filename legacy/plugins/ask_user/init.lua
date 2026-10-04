-- ask_user — interactive question tool using ui.menu.
--
-- Supports single_select, multi_select, and text_input question types.
-- Questions are rendered in the bottom pane with keyboard-driven
-- selection, optional custom text input, and optional per-option rich previews.
--
-- Always call with { questions = { { question, type, options }, ... } }.
-- Questions are asked sequentially with backtracking and review.
-- Legacy flat calls remain accepted at runtime for existing callers.
-- Results: { cancelled, answers = [{ question, type, value | values,
-- label | labels, index, custom }], cancelled_at? }. A cancel keeps the
-- answers given before it. Sub-agent runs get an explicit error; headless
-- top-level runs may cancel because no per-call headless signal is available.
-- catalog_description = "Ask one or more questions using a questions array. Each choice question needs its own options array; text_input needs no options."

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
        fail(index, "options", string.format(
            'questions[%d].options is missing or empty. Add "options": ["Coding", "Gaming"] inside this question, or set "allow_custom": true for custom-only input.',
            index - 1))
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
        error('questions is required. Put every question inside {"questions": [{"question": "Your question", "type": "text_input"}]}.', 0)
    end
    if has_question then return { validate_question(params, 1) }, false end
    if params.options ~= nil then
        error('options must be inside each questions item, not beside questions. Example: {"questions":[{"question":"Pick","type":"single_select","options":["A","B"]}]}', 0)
    end

    local total = array_length(params.questions, 1, "questions")
    if total == 0 then error("field 'questions' must contain at least one question", 0) end
    local questions = {}
    for i, q in ipairs(params.questions) do questions[i] = validate_question(q, i) end
    -- A lone question needs no progress title, back navigation, or review.
    return questions, total > 1
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

-- These are assigned after the display-width helpers below. Forward locals let
-- ask_one keep all question-flow decisions in one place without changing the
-- core menu implementation.
local pad_menu_width
local prepare_menu_spec
local ask_text_input
local CUSTOM_VALUE = "\001ask_user_custom"

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

    -- ui.menu's custom row uses the same codepoint-count wrapper as its other
    -- rows. On the real TUI, replace that row with a normal choice and open
    -- the display-width-aware local input pane after it is chosen. The
    -- fallback keeps the lightweight offline menu harness compatible.
    local live_pane = type(ctx) == "table" and type(ctx.ui) == "table"
        and type(ctx.ui.pane) == "function"
    local custom_menu = live_pane and q._type ~= "text_input" and q.allow_custom == true
    local custom_index
    if custom_menu and #(q.options or {}) == 0 then
        local initial = previous and (q._type == "multi_select" and previous.custom or previous.value) or nil
        local custom = ask_text_input(ctx, {
            title = spec.title,
            progress = spec.progress,
            question = q.question,
            initial = initial,
            allow_back = spec.allow_back,
            allow_forward = spec.allow_forward,
        })
        if type(custom) ~= "table"
            or (not custom.cancelled and not custom.back and type(custom.value) ~= "string") then
            error(string.format("question %d text input returned a malformed result", index), 0)
        end
        if custom.cancelled then return nil, true, false end
        if custom.back then
            if q._type == "multi_select" then
                local draft = custom.value ~= "" and custom.value or nil
                local result = { back = true, values = {}, selected = 1 }
                if draft then result.custom = draft end
                return result, false, true
            end
            return { back = true, value = custom.value, custom = true, selected = 1 }, false, true
        end
        if q._type == "multi_select" then
            return { values = {}, custom = custom.value, selected = 1 }, false, false
        end
        return { value = custom.value, custom = true, selected = 1 }, false, false
    end
    if custom_menu then
        spec.options = {}
        for i, opt in ipairs(q.options or {}) do spec.options[i] = opt end
        custom_index = #spec.options + 1
        spec.options[custom_index] = { label = "Type your own answer", value = CUSTOM_VALUE }
        spec.allow_custom = false
        if previous and previous.custom then
            if q._type == "single_select" then
                spec.default = custom_index
            elseif q._type == "multi_select" then
                local checked = {}
                for _, value in ipairs(spec.initial_checked or {}) do checked[#checked + 1] = value end
                checked[#checked + 1] = CUSTOM_VALUE
                spec.initial_checked = checked
            end
        end
    end

    local fn = q._type == "single_select" and menu.select
        or q._type == "multi_select" and menu.multi_select
        or ask_text_input
    local ok, result = pcall(fn, ctx, prepare_menu_spec(spec))
    if not ok then error(string.format("question %d menu failed: %s", index, tostring(result)), 0) end
    if not valid_result(result, q._type) then
        error(string.format("question %d menu returned a malformed result", index), 0)
    end

    local custom_selected = false
    if custom_menu and not result.cancelled then
        if q._type == "single_select" then
            custom_selected = result.value == CUSTOM_VALUE or result.selected == custom_index
        else
            for _, value in ipairs(result.values or {}) do
                if value == CUSTOM_VALUE then custom_selected = true break end
            end
        end
    end

    local function without_custom(values)
        local out = {}
        for _, value in ipairs(values or {}) do
            if value ~= CUSTOM_VALUE then out[#out + 1] = value end
        end
        return out
    end

    if result.cancelled then return nil, true, false end
    if result.back and custom_selected then
        if q._type == "multi_select" then
            local draft = previous and previous.custom or nil
            local backed = { back = true, values = without_custom(result.values), selected = result.selected }
            if draft and draft ~= "" then backed.custom = draft end
            return backed, false, true
        end
        return {
            back = true,
            value = previous and previous.value or "",
            custom = true,
            selected = custom_index,
        }, false, true
    end
    if result.back then return result, false, true end

    if custom_selected then
        local initial = previous and (q._type == "multi_select" and previous.custom or previous.value) or nil
        local custom = ask_text_input(ctx, {
            title = spec.title,
            progress = spec.progress,
            question = q.question,
            initial = initial,
            allow_back = spec.allow_back,
            allow_forward = spec.allow_forward,
        })
        if type(custom) ~= "table"
            or (not custom.cancelled and not custom.back and type(custom.value) ~= "string") then
            error(string.format("question %d text input returned a malformed result", index), 0)
        end
        if custom.cancelled then return nil, true, false end
        if q._type == "multi_select" then
            local values = without_custom(result.values)
            if custom.back then
                local backed = { back = true, values = values, selected = result.selected }
                if custom.value ~= "" then backed.custom = custom.value end
                return backed, false, true
            end
            local answered = { values = values, selected = result.selected }
            if custom.value ~= "" then answered.custom = custom.value end
            return answered, false, false
        end
        if custom.back then
            return { back = true, value = custom.value, custom = true, selected = custom_index }, false, true
        end
        return { value = custom.value, custom = true, selected = custom_index }, false, false
    end
    return result, false, false
end

-- The host cjson is serde-backed and encodes every empty table as `{}`.
-- Mark arrays explicitly so empty lists still serialize as `[]`.
local ARRAY_MT = {}
local function array(value) return setmetatable(value or {}, ARRAY_MT) end

local function json_encode(value)
    if type(value) ~= "table" then return cjson.encode(value) end
    local parts = {}
    if getmetatable(value) == ARRAY_MT then
        for i = 1, #value do parts[i] = json_encode(value[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = cjson.encode(key) .. ":" .. json_encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Mirror ui.menu option normalization: strings are both label and value;
-- objects return value, falling back to label.
local function option_at(q, index)
    local opt = q.options and index and q.options[index]
    if type(opt) == "string" then return { label = opt, value = opt } end
    if type(opt) == "table" then return { label = opt.label, value = opt.value or opt.label } end
    return nil
end

local function find_option(q, value, hint)
    local opt = option_at(q, hint)
    if opt and opt.value == value then return opt, hint end
    for i = 1, #(q.options or {}) do
        opt = option_at(q, i)
        if opt.value == value then return opt, i end
    end
    return nil, nil
end

local function encode_answer(q, result)
    local answer = { question = q.question, type = q._type }
    if q._type == "multi_select" then
        answer.values, answer.labels = array(), array()
        for _, value in ipairs(result.values) do
            local opt = find_option(q, value)
            answer.values[#answer.values + 1] = value
            answer.labels[#answer.labels + 1] = opt and opt.label or value
        end
        if result.custom and result.custom ~= "" then answer.custom = result.custom end
    elseif q._type == "single_select" then
        answer.value = result.value
        answer.custom = result.custom == true
        if not answer.custom then
            local opt, index = find_option(q, result.value, result.selected)
            if opt then answer.label, answer.index = opt.label, index end
        end
    else
        answer.value = result.value
    end
    return answer
end

local function answer_summary(q, result)
    local answer = encode_answer(q, result)
    if q._type == "multi_select" then
        local parts = {}
        for _, label in ipairs(answer.labels) do parts[#parts + 1] = label end
        if answer.custom then parts[#parts + 1] = answer.custom end
        return table.concat(parts, ", ")
    end
    return answer.label or answer.value
end

-- Terminal display width of one codepoint: 0 for combining marks and
-- zero-width joiners/selectors, 2 for East Asian wide/fullwidth and emoji.
local WIDE_RANGES = {
    { 0x1100, 0x115F }, { 0x2E80, 0x303E }, { 0x3041, 0x33FF }, { 0x3400, 0x4DBF },
    { 0x4E00, 0x9FFF }, { 0xA000, 0xA4CF }, { 0xAC00, 0xD7A3 }, { 0xF900, 0xFAFF },
    { 0xFE30, 0xFE4F }, { 0xFF00, 0xFF60 }, { 0xFFE0, 0xFFE6 },
    -- Emoji presentation characters outside the supplementary emoji blocks.
    { 0x231A, 0x231B }, { 0x23E9, 0x23F3 }, { 0x23F8, 0x23FA },
    { 0x25FD, 0x25FE }, { 0x2614, 0x2615 }, { 0x2648, 0x2653 },
    { 0x267F, 0x267F }, { 0x2693, 0x2693 }, { 0x26A1, 0x26A1 },
    { 0x26AA, 0x26AB }, { 0x26BD, 0x26BE }, { 0x26C4, 0x26C5 },
    { 0x26CE, 0x26CE }, { 0x26D4, 0x26D4 }, { 0x26EA, 0x26EA },
    { 0x26F2, 0x26F3 }, { 0x26F5, 0x26F5 }, { 0x26FA, 0x26FA },
    { 0x26FD, 0x26FD }, { 0x2705, 0x2705 }, { 0x270A, 0x270B },
    { 0x2728, 0x2728 }, { 0x274C, 0x274C }, { 0x274E, 0x274E },
    { 0x2753, 0x2755 }, { 0x2757, 0x2757 }, { 0x2795, 0x2797 },
    { 0x27B0, 0x27B0 }, { 0x27BF, 0x27BF }, { 0x2B1B, 0x2B1C },
    { 0x2B50, 0x2B50 }, { 0x2B55, 0x2B55 }, { 0x1F300, 0x1F64F },
    { 0x1F900, 0x1F9FF }, { 0x1FA70, 0x1FAFF }, { 0x20000, 0x3FFFD },
}

local function utf8_chars(value)
    local chars = {}
    for ch in tostring(value or ""):gmatch("[\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = ch
    end
    return chars
end

local function codepoint_width(cp)
    if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x0483 and cp <= 0x0489)
        or (cp >= 0x0591 and cp <= 0x05BD) or cp == 0x05BF
        or (cp >= 0x05C1 and cp <= 0x05C2) or (cp >= 0x05C4 and cp <= 0x05C5)
        or cp == 0x05C7 or (cp >= 0x0610 and cp <= 0x061A)
        or (cp >= 0x064B and cp <= 0x065F) or (cp >= 0x0670 and cp <= 0x0670)
        or (cp >= 0x06D6 and cp <= 0x06ED) or (cp >= 0x0711 and cp <= 0x0711)
        or (cp >= 0x0730 and cp <= 0x074A) or (cp >= 0x07A6 and cp <= 0x07B0)
        or (cp >= 0x07EB and cp <= 0x07F3) or (cp >= 0x0816 and cp <= 0x0819)
        or (cp >= 0x081B and cp <= 0x0823) or (cp >= 0x0825 and cp <= 0x0827)
        or (cp >= 0x0829 and cp <= 0x082D) or (cp >= 0x0859 and cp <= 0x085B)
        or (cp >= 0x08D3 and cp <= 0x0903) or (cp >= 0x093A and cp <= 0x093C)
        or (cp >= 0x093E and cp <= 0x094F) or (cp >= 0x0951 and cp <= 0x0957)
        or (cp >= 0x0962 and cp <= 0x0963) or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF)
        or (cp >= 0x2DE0 and cp <= 0x2DFF) or (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0xFE20 and cp <= 0xFE2F) or (cp >= 0xE0100 and cp <= 0xE01EF)
        or (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0x200B and cp <= 0x200F) then
        return 0
    end
    for _, range in ipairs(WIDE_RANGES) do
        if cp >= range[1] and cp <= range[2] then return 2 end
    end
    return 1
end

-- Split into { char, width } pairs after collapsing whitespace.
local function display_chars(value)
    local chars = {}
    for ch in tostring(value or ""):gsub("%s+", " "):gmatch("[\1-\127\194-\244][\128-\191]*") do
        local ok, cp = pcall(utf8.codepoint, ch)
        chars[#chars + 1] = { ch, ok and codepoint_width(cp) or 1 }
    end
    return chars
end

local function display_width(value)
    local total = 0
    for _, c in ipairs(display_chars(value)) do total = total + c[2] end
    return total
end

-- Truncate to max_width terminal columns, ending with an ellipsis when shortened.
local function truncate_width(value, max_width)
    local chars = display_chars(value)
    local total, parts = 0, {}
    for _, c in ipairs(chars) do
        total = total + c[2]
        parts[#parts + 1] = c[1]
    end
    if total <= max_width then return table.concat(parts) end
    local out, used = {}, 0
    for _, c in ipairs(chars) do
        if used + c[2] > max_width - 1 then break end
        out[#out + 1] = c[1]
        used = used + c[2]
    end
    return table.concat(out) .. "…"
end

-- Both width sources can be wrong: ctx.ui.width() is 0 after a hot reload and
-- can hold a stale value; bone.api.ui.term_width() describes the runtime's own tty.
-- Use the narrowest positive answer: over-truncating is harmless, while an
-- over-wide row gets clipped by the terminal and loses its ellipsis.
local function terminal_width(ctx)
    local best
    local function consider(fn)
        if type(fn) ~= "function" then return end
        local ok, width = pcall(fn)
        if ok and type(width) == "number" and width > 0 and (not best or width < best) then
            best = width
        end
    end
    local ui = type(ctx) == "table" and ctx.ui or nil
    if type(ui) == "table" then consider(ui.width) end
    local api = type(bone) == "table" and bone.api or nil
    local api_ui = type(api) == "table" and api.ui or nil
    if type(api_ui) == "table" then consider(api_ui.term_width) end
    return best or 80
end

-- ui.menu wraps by UTF-8 codepoint count. Keep its public behavior, but add
-- invisible zero-width padding after display-wide characters so its counter
-- tracks terminal columns for static menu content. The original option/value
-- strings are never padded in the returned answers.
local WIDTH_PAD = "\226\128\139" -- U+200B ZERO WIDTH SPACE

local function char_width(ch)
    local ok, cp = pcall(utf8.codepoint, ch)
    return ok and codepoint_width(cp) or 1
end

pad_menu_width = function(value)
    value = tostring(value or "")
    local chars, out = utf8_chars(value), {}
    for i, ch in ipairs(chars) do
        out[#out + 1] = ch
        local width = char_width(ch)
        if width > 1 then
            local next_width = chars[i + 1] and char_width(chars[i + 1]) or 1
            -- A selector/combining mark already consumes a codepoint while
            -- remaining zero-width, so do not over-pad emoji graphemes.
            if next_width ~= 0 then
                for _ = 2, width do out[#out + 1] = WIDTH_PAD end
            end
        end
    end
    return table.concat(out)
end

local function prepare_preview(value)
    if type(value) ~= "table" then return value end
    local out = {}
    if value.title ~= nil then out.title = pad_menu_width(value.title) end
    out.lines = {}
    for _, raw in ipairs(value.lines or {}) do
        if type(raw) == "string" then
            out.lines[#out.lines + 1] = pad_menu_width(raw)
        elseif type(raw) == "table" then
            local styled = { spans = {}, bg = raw.bg }
            for _, value_span in ipairs(raw.spans or {}) do
                local copied = {}
                for key, item in pairs(value_span) do copied[key] = item end
                copied.text = pad_menu_width(value_span.text)
                styled.spans[#styled.spans + 1] = copied
            end
            out.lines[#out.lines + 1] = styled
        end
    end
    return out
end

local function prepare_options(options)
    local out = {}
    for i, opt in ipairs(options or {}) do
        if type(opt) == "table" then
            local copied = {}
            for key, item in pairs(opt) do copied[key] = item end
            local label = opt.label or opt.value or i
            copied.label = pad_menu_width(label)
            -- Preserve the unpadded fallback value used by ui.menu.
            copied.value = opt.value or opt.label or tostring(i)
            if opt.description ~= nil then copied.description = pad_menu_width(opt.description) end
            if opt.description_spans then
                copied.description_spans = {}
                for _, value_span in ipairs(opt.description_spans) do
                    local span_copy = {}
                    for key, item in pairs(value_span) do span_copy[key] = item end
                    span_copy.text = pad_menu_width(value_span.text)
                    copied.description_spans[#copied.description_spans + 1] = span_copy
                end
            end
            if opt.preview ~= nil then copied.preview = prepare_preview(opt.preview) end
            out[i] = copied
        else
            out[i] = { label = pad_menu_width(opt), value = opt }
        end
    end
    return out
end

prepare_menu_spec = function(spec)
    local out = {}
    for key, value in pairs(spec or {}) do out[key] = value end
    for _, key in ipairs({ "title", "progress", "question" }) do
        if spec and spec[key] ~= nil then out[key] = pad_menu_width(spec[key]) end
    end
    if spec and spec.options ~= nil then out.options = prepare_options(spec.options) end
    return out
end

-- The local text input uses terminal display columns rather than ui.menu's
-- codepoint count. It is also used as the custom-answer editor for choice
-- questions on the real TUI.
local function raw_display_chars(value)
    local out = {}
    for _, ch in ipairs(utf8_chars(value)) do out[#out + 1] = { ch, char_width(ch) } end
    return out
end

local function is_break_char(ch)
    return ch == " " or ch == "\t"
end

local function wrap_display_chars(chars, max_width)
    max_width = math.max(1, tonumber(max_width) or 1)
    if #chars == 0 then return { "" } end
    local rows, start = {}, 1
    while start <= #chars do
        local stop, used = start - 1, 0
        for i = start, #chars do
            local width = chars[i][2]
            if stop >= start and used + width > max_width then break end
            stop, used = i, used + width
        end
        if stop < start then stop = start end
        if stop < #chars then
            for i = stop, start + 1, -1 do
                if is_break_char(chars[i][1]) then
                    stop = i
                    break
                end
            end
        end
        local parts = {}
        for i = start, stop do parts[#parts + 1] = chars[i][1] end
        rows[#rows + 1] = table.concat(parts)
        start = stop + 1
    end
    return rows
end

local function wrap_display_input(value, cursor, max_width)
    local chars = raw_display_chars(value)
    cursor = math.max(0, math.min(tonumber(cursor) or #chars, #chars))
    table.insert(chars, cursor + 1, { "█", 1 })
    return wrap_display_chars(chars, max_width)
end

local function append_display_wrapped(lines, text, width, fg, modifiers)
    for _, segment in ipairs(wrap_display_chars(raw_display_chars(text), width)) do
        lines[#lines + 1] = { spans = { { text = segment, fg = fg, modifiers = modifiers or {} } } }
    end
end

local function edit_input(value, cursor, key, code, pmod)
    local chars = utf8_chars(value)
    cursor = math.max(0, math.min(tonumber(cursor) or #chars, #chars))
    if pmod.is_text_key(key) then
        local incoming = utf8_chars(key.char)
        for i, ch in ipairs(incoming) do table.insert(chars, cursor + i, ch) end
        return table.concat(chars), cursor + #incoming
    elseif code == "Backspace" and cursor > 0 then
        table.remove(chars, cursor)
        return table.concat(chars), cursor - 1
    elseif code == "Delete" and cursor < #chars then
        table.remove(chars, cursor + 1)
        return table.concat(chars), cursor
    elseif code == "Left" then
        return value, math.max(0, cursor - 1)
    elseif code == "Right" then
        return value, math.min(#chars, cursor + 1)
    elseif code == "Home" then
        return value, 0
    elseif code == "End" then
        return value, #chars
    end
    return nil, cursor
end

ask_text_input = function(ctx, spec)
    local live_pane = type(ctx) == "table" and type(ctx.ui) == "table"
        and type(ctx.ui.pane) == "function" and type(ctx.ui.key) == "function"
    if not live_pane then
        return menu.text_input(ctx, prepare_menu_spec(spec))
    end
    local ok, pmod = pcall(require, "ui.pane")
    if not ok or type(pmod) ~= "table" then
        return menu.text_input(ctx, prepare_menu_spec(spec))
    end

    local p = pmod.new(ctx, { id = "interact", title = spec.title or "Input" })
    local input = tostring(spec.initial or "")
    local cursor = #utf8_chars(input)
    while true do
        local width = math.max(1, math.floor(tonumber(terminal_width(ctx)) or 80))
        local lines = {}
        if spec.progress and spec.progress ~= "" then
            append_display_wrapped(lines, spec.progress, width, "cyan", { "bold" })
        end
        if spec.question and spec.question ~= "" then
            append_display_wrapped(lines, spec.question, width, "white", { "bold" })
        end
        local segments = wrap_display_input(input, cursor, math.max(1, width - 2))
        for i, segment in ipairs(segments) do
            local prefix = i == 1 and "> " or "  "
            lines[#lines + 1] = {
                spans = {
                    { text = prefix, fg = "white", modifiers = { "bold" } },
                    { text = segment, fg = "white", modifiers = { "bold" } },
                },
            }
        end
        local hints = { "Left/Right move", "Home/End", "Enter submit" }
        if spec.allow_back then hints[#hints + 1] = "Alt+Left back" end
        if spec.allow_forward then hints[#hints + 1] = "Alt+Right next" end
        hints[#hints + 1] = "Esc cancel"
        append_display_wrapped(lines, table.concat(hints, " · "), width, "darkgray")
        lines[#lines + 1] = ""
        p:set_lines(lines, math.min(24, math.max(3, #lines)))

        local key = pmod.wait_key(ctx)
        if not key then return { cancelled = true } end
        local code = pmod.key_name(key)
        if spec.allow_back and key.alt and code == "Left" then
            return { back = true, value = input }
        elseif spec.allow_forward and key.alt and code == "Right" then
            return { value = input }
        elseif code == "Esc" then
            return { cancelled = true }
        elseif code == "Enter" then
            return { value = input }
        else
            local edited
            edited, cursor = edit_input(input, cursor, key, code, pmod)
            if edited ~= nil then input = edited end
        end
    end
end

-- Fit "Qn: question → answer" into one terminal row. The answer keeps
-- priority; the question shrinks first, down to about 40% of the space.
local function review_label(i, question, summary, width)
    local prefix = string.format("Q%d: ", i)
    -- 3 columns for the menu cursor marker, 1 spare, 3 for " → ".
    local budget = math.max(10, width - 4 - #prefix - 3)
    local qw, aw = display_width(question), display_width(summary)
    local q_budget, a_budget = qw, aw
    if qw + aw > budget then
        q_budget = math.min(qw, math.max(8, math.floor(budget * 0.4)))
        a_budget = budget - q_budget
        if aw < a_budget then
            a_budget = aw
            q_budget = budget - aw
        end
    end
    return prefix .. truncate_width(question, math.max(1, q_budget))
        .. " → " .. truncate_width(summary, math.max(1, a_budget))
end

local function build_review_options(questions, answers, width)
    local options = { { label = "✓ Submit all answers", value = "submit" } }
    for i, q in ipairs(questions) do
        options[#options + 1] = {
            label = review_label(i, q.question, answer_summary(q, answers[i]), width),
            value = tostring(i),
        }
    end
    return options
end

local function review(questions, answers, ctx)
    local review_spec = {
        title = "Review answers",
        question = "Review your answers. Pick a question to revise, or submit.",
        options = build_review_options(questions, answers, terminal_width(ctx)),
        allow_custom = false,
    }
    local ok, result = pcall(menu.select, ctx, prepare_menu_spec(review_spec))
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

-- Returns answers, cancelled, cancelled_at. cancelled_at is the 1-based
-- question index, or nil when the user cancelled from the review screen.
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
        if cancelled then return answers, true, index end
        -- A back result keeps the in-progress draft for when the user returns.
        answers[index] = result
        index = back and index - 1 or index + 1
    end
    if not multiple then return answers, false end

    while true do
        local choice, cancelled = review(questions, answers, ctx)
        if cancelled then return answers, true, nil end
        if choice == "submit" then return answers, false end
        local replacement, question_cancelled = ask_one(
            questions[choice], ctx, choice, #questions, answers[choice]
        )
        if question_cancelled then return answers, true, nil end
        answers[choice] = replacement
    end
end

-- A sub-agent has no attached user. ui.menu would read no key and report a
-- cancellation, which misleads the model, so fail explicitly.
-- Use the per-call depth from ctx.runtime.info(): the boot globals
-- bone.agent_depth/bone.headless are fixed when the VM boots, and automatic
-- hot reloads boot with headless=true even inside the TUI.
local function call_agent_depth(ctx)
    local runtime = type(ctx) == "table" and ctx.runtime or nil
    if type(runtime) == "table" and type(runtime.info) == "function" then
        local ok, info = pcall(runtime.info)
        if ok and type(info) == "table" then return tonumber(info.agent_depth) or 0 end
    end
    return 0
end

local function interactive(ctx)
    if call_agent_depth(ctx) > 0 then return false end
    return type(ctx) == "table" and type(ctx.ui) == "table"
end

local function execute(params, ctx)
    local questions, multiple = validate_params(params)
    if not interactive(ctx) then
        error("ask_user needs an interactive user, but none is attached (sub-agent run). "
            .. "Choose a reasonable default, state the assumption, and list open questions in your final answer.", 0)
    end
    local ok, results, cancelled, cancelled_at = pcall(ask_all, questions, multiple, ctx)
    pcall(menu.clear, ctx)
    if not ok then error(results, 0) end

    -- On cancel, keep only answers completed before the cancelled question;
    -- drafts left by back-navigation beyond it are not answers.
    local answered = #questions
    if cancelled and cancelled_at then answered = cancelled_at - 1 end
    local answers = array()
    for i = 1, answered do answers[i] = encode_answer(questions[i], results[i]) end
    local out = { cancelled = cancelled == true, answers = answers }
    if cancelled and cancelled_at then out.cancelled_at = cancelled_at end
    return json_encode(out)
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

-- Keep one root object with a required questions array. Question variants
-- carry their own required fields so choice options cannot be omitted.
local QUESTION_PROPERTIES = {
    question = QUESTION_PROPERTY,
    options = OPTIONS_PROPERTY,
    allow_custom = ALLOW_CUSTOM_PROPERTY,
    type = {
        type = "string",
        enum = QUESTION_TYPES,
        description = "Required answer type: single_select for one choice, multi_select for checkboxes, text_input for free text.",
    },
    default = DEFAULT_PROPERTY,
    visible_rows = VISIBLE_ROWS_PROPERTY,
}

local function question_variant(types, custom_only)
    local properties = {}
    for key, value in pairs(QUESTION_PROPERTIES) do properties[key] = value end
    properties.type = { type = "string", enum = types }
    local required = { "question", "type" }
    if types[1] == "text_input" then
        properties.default = nil
        properties.options = nil
        properties.allow_custom = nil
    elseif custom_only then
        properties.allow_custom = { type = "boolean", enum = { true } }
        required[#required + 1] = "allow_custom"
    else
        properties.options = {
            type = "array", minItems = 1, items = OPTION_ITEMS,
            description = "Required choices for THIS question, for example [\"Coding\", \"Gaming\"].",
        }
        required[#required + 1] = "options"
    end
    return { type = "object", properties = properties, required = required, additionalProperties = false }
end

local ROOT_PROPERTIES = {
    questions = {
        type = "array",
        minItems = 1,
        description = "Always put every question here, even when asking only one. Each choice question contains its own options.",
        items = {
            anyOf = {
                question_variant({ "single_select", "multi_select" }),
                question_variant({ "text_input" }),
                question_variant({ "single_select", "multi_select" }, true),
            },
        },
    },
}

bone.tool.register({
    name = "ask_user",
    description = 'Ask one or more questions. Always use {"questions": [...]}, even for one question. '
        .. 'Each question needs question and type. Each single_select or multi_select needs its own options array '
        .. '(unless allow_custom is true); text_input needs no options. Never put options outside a question. '
        .. 'Example: {"questions":[{"question":"Which activities do you enjoy?","type":"multi_select",'
        .. '"options":["Coding","Gaming","Music"]},{"question":"What are you building?","type":"text_input"}]} '
        .. 'Returns {"cancelled":bool,"answers":[...]}: each answer has question and type; single_select adds value, '
        .. 'label, index, and custom (true when typed); multi_select adds values, labels, and custom (typed text, if any); '
        .. 'text_input adds value. On cancel, answers holds only questions answered first and cancelled_at is the 1-based '
        .. 'question index (absent when cancelled from review).',
    parameters = {
        type = "object",
        properties = ROOT_PROPERTIES,
        required = { "questions" },
        additionalProperties = false,
    },
    safety = "read_only",
    display = {
        show = false,
        args = { "question", "questions" },
    },
    execute = execute,
})
