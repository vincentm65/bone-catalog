local DEFAULT_NAME = "Tasks"
local MAX_TASKS = 15

local VALID_STATUS = { pending = true, in_progress = true, done = true }

local function styled_line(text, status)
    if status == "done" then
        return {
            spans = {
                { text = "  ✓ ", fg = "#78B373", modifiers = { "bold" } },
                { text = text, fg = "dark_gray", modifiers = { "strike" } },
            },
        }
    end
    if status == "in_progress" then
        return {
            spans = {
                { text = "  ◐ ", fg = "#E5C07B", modifiers = { "bold" } },
                { text = text, fg = "white", modifiers = { "bold" } },
            },
        }
    end
    return {
        spans = {
            { text = "  ○ ", fg = "dark_gray" },
            { text = text, fg = "white" },
        },
    }
end

-- Normalize one task entry into { text = string, status = "pending"|... }.
-- Accepts a bare string (→ pending) or a table { text=, status= }.
local function normalize_task(entry)
    if type(entry) == "string" then
        return { text = entry, status = "pending" }
    end
    if type(entry) == "table" then
        local text = entry.text or entry[1]
        if type(text) ~= "string" or text == "" then
            return nil
        end
        local status = entry.status
        if not VALID_STATUS[status] then
            status = "pending"
        end
        return { text = text, status = status }
    end
    return nil
end

local function empty_pane(name)
    return {
        source = "task_list",
        title = name or DEFAULT_NAME,
        lines = {},
    }
end

local function emit(state, all_done_msg)
    local tasks = state.tasks or {}
    local done = 0
    for _, t in ipairs(tasks) do
        if t.status == "done" then done = done + 1 end
    end
    local total = #tasks
    local name = state.name or DEFAULT_NAME

    local lines = {}
    for _, t in ipairs(tasks) do
        table.insert(lines, styled_line(t.text, t.status))
    end

    local content = { all_done_msg or string.format("%d/%d done", done, total) }
    for _, t in ipairs(tasks) do
        local mark = t.status == "done" and "[x]" or (t.status == "in_progress" and "[~]" or "[ ]")
        table.insert(content, string.format("%s %s", mark, t.text))
    end

    local output = {
        -- Keep the current checklist in the persisted tool result so later
        -- requests retain it without a cache-breaking transient reminder.
        content = table.concat(content, "\n"),
        state = cjson.encode(state),
        pane = {
            source = "task_list",
            title = string.format("%s (%d/%d)", name, done, total),
            visible_rows = 8,
            scroll = 0,
            lines = lines,
        },
    }
    return cjson.encode(output)
end

local function execute(params, ctx)
    local action = params.action or ""

    if action == "clear" then
        ctx.state.clear("task_list")
        return cjson.encode({
            content = "Task list cleared.",
            pane = empty_pane(),
        })
    end

    if action == "complete" then
        local raw = ctx.state.get("task_list")
        if not raw or raw == "" then
            return "ERROR: No active task list to complete."
        end
        local ok, state = pcall(cjson.decode, raw)
        if not ok or type(state) ~= "table" or type(state.tasks) ~= "table" or #state.tasks == 0 then
            return "ERROR: Active task list is unavailable or invalid."
        end
        for _, task in ipairs(state.tasks) do
            task.status = "done"
        end
        ctx.state.set("task_list", cjson.encode(state))
        return emit(state, "All tasks complete.")
    end

    if action == "write" then
        local raw_tasks = params.tasks
        if type(raw_tasks) ~= "table" then
            return "ERROR: 'write' requires a 'tasks' array."
        end
        if #raw_tasks == 0 then
            return "ERROR: Provide at least one task, or use action=clear to remove the list."
        end
        if #raw_tasks > MAX_TASKS then
            return string.format("ERROR: Maximum %d tasks allowed.", MAX_TASKS)
        end

        local tasks = {}
        local in_progress = 0
        for i, entry in ipairs(raw_tasks) do
            local t = normalize_task(entry)
            if not t then
                return string.format("ERROR: Task %d is invalid (need a non-empty string or {text, status}).", i)
            end
            if t.status == "in_progress" then in_progress = in_progress + 1 end
            table.insert(tasks, t)
        end
        if in_progress > 1 then
            return "ERROR: Keep at most one task 'in_progress' at a time."
        end

        local state = { name = params.name or DEFAULT_NAME, tasks = tasks }
        ctx.state.set("task_list", cjson.encode(state))

        local all_done = true
        for _, t in ipairs(tasks) do
            if t.status ~= "done" then all_done = false break end
        end
        if all_done then
            return emit(state, "All tasks complete.")
        end
        return emit(state)
    end

    return "ERROR: Action must be 'write' or 'clear'."
end

bone.tool.register({
    name = "task_list",
    description = "Maintain a visible checklist (TUI pane) for the user. Use it for any task with ~3+ distinct steps or work spanning multiple files. Call 'write' with the FULL list every time — it replaces the whole list, so there are no indices to track. Keep at most one item 'in_progress' (the step you're working on now); flip it to 'done' when finished. Once the work is genuinely complete, call 'complete' to mark the whole current list done. Call 'clear' only when the user confirms. State is host-held; no state arg. Actions: write (pass tasks, optional name, max 15), complete, clear.",
    safety = "read_only",
    -- Host-managed state: the host serializes batched calls and threads the
    -- prior list back in (state_key defaults to the tool name, "task_list").
    stateful = true,
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                description = "'write' (replace the full list), 'complete' (mark every current task done), or 'clear' (remove the list).",
                enum = { "write", "complete", "clear" },
            },
            name = {
                type = "string",
                description = "Optional list title shown in the pane.",
            },
            tasks = {
                type = "array",
                description = "Full ordered task list for 'write'. Each item is either a string (defaults to pending) or { text, status } where status is pending | in_progress | done.",
                items = {
                    oneOf = {
                        { type = "string" },
                        {
                            type = "object",
                            properties = {
                                text = { type = "string" },
                                status = {
                                    type = "string",
                                    enum = { "pending", "in_progress", "done" },
                                },
                            },
                            required = { "text" },
                        },
                    },
                },
            },
        },
        required = { "action" },
        additionalProperties = false,
    },
    display = {
        show = false,
        show_result = false,
        args = { "action", "name", "tasks" },
    },
    execute = execute,
})
