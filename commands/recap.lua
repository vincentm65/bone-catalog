-- /recap — brief conversation recap, automatic or on-demand.
--
-- After a configurable idle period (default 60 s), a 1–2 sentence
-- summary of the conversation is shown as a dim line in the
-- scrollback.  Type /recap for an immediate recap.

local RECAP_PROMPT = table.concat({
    "Summarize the conversation so far in 1-2 brief sentences.",
    "Focus on what was accomplished and what is pending.",
    "Be concise. Do not call tools.",
}, " ")

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
            default = 60,
            integer = true,
            min = 5,
            max = 600,
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

local function sanitize_message(msg)
    return { role = msg.role, content = msg.content or "" }
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

    local messages = {
        { role = "system", content = "You summarize coding conversations concisely." },
    }
    for _, msg in ipairs(history) do
        messages[#messages + 1] = sanitize_message(msg)
    end
    messages[#messages + 1] = { role = "user", content = RECAP_PROMPT }

    local result = ctx.llm.complete({
        messages = messages,
        max_tokens = 128,
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

-- ── Automatic recap ──────────────────────────────────────────────

local recap_seq = 0

bone.on("turn_end", function(_, ctx)
    if recap_disabled_in_config(ctx) then return end
    if not recap_auto_enabled(ctx) then return end

    local idle_s = tonumber(ctx.settings.get("recap.idle_seconds")) or 60
    local idle_ms = idle_s * 1000

    recap_seq = recap_seq + 1
    local my_seq = recap_seq

    local remaining = idle_ms
    while remaining > 0 do
        local chunk = math.min(remaining, 60000)
        local ok = pcall(ctx.time.sleep_ms, chunk)
        if not ok then return end
        remaining = remaining - chunk
    end

    -- Skip if a newer turn ended while we were sleeping.
    if my_seq ~= recap_seq then return end

    local text, err = do_recap(ctx)
    if not text then
        if ctx.ui and ctx.ui.notice and err ~= "nothing to recap" then
            ctx.ui.notice("Recap unavailable: " .. err)
        end
        return
    end
    if ctx.ui and ctx.ui.notice then
        ctx.ui.notice("* " .. text .. " *")
    end
end, { timeout_ms = 900000 })

-- ── Manual command ───────────────────────────────────────────────

bone.command.register("recap", {
    description = "Show a brief recap of the conversation",
    handler = function(args, ctx)
        local text, err = do_recap(ctx)
        if text then
            return { display = "* " .. text .. " *", submit = false }
        end
        return { display = "Recap unavailable: " .. (err or "unknown"), submit = false }
    end,
})
