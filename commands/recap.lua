-- /recap — brief conversation recap, automatic or on-demand.
--
-- After a configurable idle period (default 15 min), a 1–2 sentence
-- summary of the conversation is shown as a dim, italic line in the
-- scrollback.  Type /recap for an immediate recap.

local RECAP_PROMPT = table.concat({
    "Summarize the conversation so far in 1-2 brief sentences.",
    "Focus on what was accomplished and what is pending.",
    "Be concise. Do not call tools.",
}, " ")

local SYSTEM_PROMPT = table.concat({
    "You summarize coding conversations concisely.",
    "The transcript contains only user and assistant text; tool activity is omitted.",
}, " ")

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Render each line as markdown emphasis so transcript system/notice lines
-- (muted markdown) show the recap as a dim italic block. Asterisks inside the
-- LLM text are escaped so they stay literal.
local function italic_lines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line == "" then
            out[#out + 1] = ""
        else
            out[#out + 1] = "*" .. line:gsub("%*", "\\*") .. "*"
        end
    end
    return table.concat(out, "\n")
end

bone.settings.register({
    namespace = "recap",
    title = "Recap",
    fields = {
        {
            key = "auto",
            label = "Automatic recap",
            type = "bool",
            default = true,
        },
        {
            key = "idle_seconds",
            label = "Idle delay (seconds)",
            type = "number",
            default = 900,
            integer = true,
            min = 5,
            max = 3600,
        },
    },
})

local function recap_disabled_in_config(ctx)
    if not ctx.config or not ctx.config.get_table then return false end
    local commands = ctx.config.get_table("commands")
    if type(commands) ~= "table" then return false end
    return commands.recap == false
end

local function recap_auto_enabled(ctx)
    if not ctx.settings or not ctx.settings.get then return true end
    return ctx.settings.get("recap.auto") ~= false
end

-- Project the transcript to user/assistant text only. Tool activity (role
-- "tool" messages and assistant tool_calls / tool_call_id) is dropped so the
-- recap request never sends provider-invalid tool_result / tool_use sequences
-- (which is what replaying the raw transcript did for tool-heavy sessions).
local function build_transcript(history)
    local lines = {}
    for _, msg in ipairs(history) do
        local content = trim(msg.content)
        if content ~= "" then
            if msg.role == "user" then
                lines[#lines + 1] = "User: " .. content
            elseif msg.role == "assistant" then
                lines[#lines + 1] = "Assistant: " .. content
            end
        end
    end
    return table.concat(lines, "\n\n")
end

local function request_recap(ctx, messages)
    local result = ctx.llm.complete({
        messages = messages,
    })
    if type(result) ~= "table" then
        return nil, "recap LLM returned no result"
    end
    if result.cancelled then
        return nil, result.error or "recap cancelled"
    end
    if not result.ok then
        return nil, result.error or "recap failed"
    end
    if result.tool_calls and next(result.tool_calls) ~= nil then
        return nil, "recap LLM returned tool calls"
    end
    local content = trim(result.content)
    if content == "" then
        return nil, "recap LLM returned an empty summary"
    end
    return content
end

local function do_recap(ctx)
    if not ctx.conversation or not ctx.conversation.history then
        return nil, "conversation history is not available"
    end
    local history = ctx.conversation.history()
    if not history or #history < 2 then
        return nil, "nothing to recap"
    end
    if not ctx.llm or not ctx.llm.complete then
        return nil, "private LLM completion is unavailable"
    end

    local transcript = build_transcript(history)
    if transcript == "" then
        return nil, "nothing to recap"
    end

    -- A single user message carrying the transcript. Keeping it to system + one
    -- user turn avoids provider role-alternation constraints entirely.
    local messages = {
        { role = "system", content = SYSTEM_PROMPT },
        { role = "user", content = "Transcript:\n\n" .. transcript .. "\n\n" .. RECAP_PROMPT },
    }

    local content, err = request_recap(ctx, messages)
    if content then return content end

    -- Retry once: resend the same user message with a repair nudge. Appending a
    -- second user message (as before) can violate providers that require
    -- alternating roles, so the nudge is folded into the existing message.
    messages[2].content = messages[2].content
        .. "\n\nYour last reply was empty. Please provide the recap now."
    content, err = request_recap(ctx, messages)
    if not content then
        return nil, err or "recap failed"
    end
    return content
end

-- ── Automatic recap ──────────────────────────────────────────────

local recap_seq = 0
local pending_timer = nil

local function run_recap(ctx)
    local text, err = do_recap(ctx)
    if not text then
        if ctx.ui and ctx.ui.notice and err ~= "nothing to recap" then
            ctx.ui.notice("Recap unavailable: " .. err)
        end
        return
    end
    if ctx.ui and ctx.ui.notice then
        ctx.ui.notice(italic_lines("Recap: " .. text))
    end
end

-- Schedule a recap to run once the conversation has been idle for `idle_ms`.
-- The wait happens on a background thread (ctx.time.after), so the turn_end
-- handler returns immediately and the Lua VM is free to serve commands, tools,
-- and other event handlers while the user is idle. A newer turn cancels the
-- outstanding timer; the seq check is the backstop if cancel races the fire.
local function schedule_auto_recap(ctx, idle_ms)
    if not ctx.time or not ctx.time.after then return end

    recap_seq = recap_seq + 1
    local my_seq = recap_seq

    if pending_timer and pending_timer.cancel then
        pcall(pending_timer.cancel)
    end
    pending_timer = ctx.time.after(idle_ms, function()
        if my_seq ~= recap_seq then return end
        if recap_disabled_in_config(ctx) then return end
        if not recap_auto_enabled(ctx) then return end
        run_recap(ctx)
    end)
end

bone.on("turn_end", function(_, ctx)
    if recap_disabled_in_config(ctx) then return end
    if not recap_auto_enabled(ctx) then return end

    local idle_s = tonumber(ctx.settings.get("recap.idle_seconds")) or 900
    schedule_auto_recap(ctx, idle_s * 1000)
end)

-- ── Manual command ───────────────────────────────────────────────

bone.command.register("recap", {
    description = "Show a brief recap of the conversation",
    handler = function(args, ctx)
        local text, err = do_recap(ctx)
        if text then
            return { display = italic_lines("Recap: " .. text), submit = false }
        end
        return { display = "Recap unavailable: " .. (err or "unknown"), submit = false }
    end,
})
