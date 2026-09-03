-- Experimental autonomous checklist for A/B testing against task_list.
-- State stays conversation-scoped in ctx.state. Dynamic guidance uses a
-- trailing turn_message so task updates do not invalidate the cached prefix.

local STATE_KEY = "task_loop"
local DEFAULT_NAME = "Auto Tasks"
local MAX_ROWS = 15
local VALID_STATUS = { pending = true, in_progress = true, done = true }

local function nonempty(value)
    return type(value) == "string" and not value:match("^%s*$")
end

local function normalize_leaf(entry)
    if type(entry) == "string" then
        if not nonempty(entry) then return nil, "text must be non-empty" end
        return { text = entry, status = "pending" }
    end
    if type(entry) ~= "table" or not nonempty(entry.text or entry[1]) then
        return nil, "need a non-empty string or {text, status}"
    end
    local status = entry.status or "pending"
    if not VALID_STATUS[status] then
        return nil, "status must be pending, in_progress, or done"
    end
    return { text = entry.text or entry[1], status = status }
end

local function normalize_task(entry)
    local task, err = normalize_leaf(entry)
    if not task then return nil, err end
    if type(entry) ~= "table" or entry.subtasks == nil then return task end
    if type(entry.subtasks) ~= "table" or #entry.subtasks == 0 then
        return nil, "subtasks must be a non-empty array"
    end

    task.subtasks = {}
    for i, raw in ipairs(entry.subtasks) do
        if type(raw) == "table" and raw.subtasks ~= nil then
            return nil, string.format("subtask %d cannot contain nested subtasks", i)
        end
        local subtask, problem = normalize_leaf(raw)
        if not subtask then
            return nil, string.format("subtask %d is invalid (%s)", i, problem)
        end
        table.insert(task.subtasks, subtask)
    end
    -- A completed group completes its children. Otherwise the children's
    -- statuses are the source of truth and the group status is derived.
    if task.status == "done" then
        for _, subtask in ipairs(task.subtasks) do subtask.status = "done" end
    end
    return task
end

local function each_leaf(tasks, callback)
    for _, task in ipairs(tasks or {}) do
        if task.subtasks then
            for _, subtask in ipairs(task.subtasks) do callback(subtask, task) end
        else
            callback(task, nil)
        end
    end
end

local function counts(tasks)
    local done, total = 0, 0
    each_leaf(tasks, function(task)
        total = total + 1
        if task.status == "done" then done = done + 1 end
    end)
    return done, total
end

local function is_complete(tasks)
    local done, total = counts(tasks)
    return total > 0 and done == total
end

local function group_status(task)
    if not task.subtasks then return task.status end
    local done, total, active = 0, #task.subtasks, false
    for _, subtask in ipairs(task.subtasks) do
        if subtask.status == "done" then done = done + 1 end
        if subtask.status == "in_progress" then active = true end
    end
    if done == total then return "done" end
    if active or done > 0 then return "in_progress" end
    return "pending"
end

local function ensure_current(tasks)
    local current, first_pending = nil, nil
    each_leaf(tasks, function(task)
        if task.status == "in_progress" and not current then current = task end
        if task.status == "pending" and not first_pending then first_pending = task end
    end)
    if not current and first_pending then first_pending.status = "in_progress" end
end

local function current_task(tasks)
    local current = nil
    each_leaf(tasks, function(task)
        if not current and task.status == "in_progress" then current = task end
    end)
    return current
end

local function load_state(ctx)
    local raw = ctx.state.get(STATE_KEY)
    if not raw or raw == "" then return nil, "No autonomous task list." end
    local ok, state = pcall(cjson.decode, raw)
    if not ok or type(state) ~= "table" or type(state.tasks) ~= "table" or #state.tasks == 0 then
        return nil, "Autonomous task list is invalid."
    end
    return state
end

local function persist(ctx, state)
    ctx.state.set(STATE_KEY, cjson.encode(state))
end

local function styled_line(text, status, indent)
    local prefix, fg, modifiers = "  ○ ", "white", nil
    if status == "done" then
        prefix, fg, modifiers = "  ✓ ", "dark_gray", { "strike" }
    elseif status == "in_progress" then
        prefix, fg, modifiers = "  ◐ ", "white", { "bold" }
    end
    return {
        spans = {
            { text = string.rep("  ", indent or 0) .. prefix,
              fg = status == "done" and "#78B373" or (status == "in_progress" and "#E5C07B" or "dark_gray"),
              modifiers = status ~= "pending" and { "bold" } or nil },
            { text = text, fg = fg, modifiers = modifiers },
        },
    }
end

local function text_lines(tasks)
    local lines = {}
    for _, task in ipairs(tasks) do
        local status = group_status(task)
        local mark = status == "done" and "[x]" or (status == "in_progress" and "[~]" or "[ ]")
        table.insert(lines, string.format("%s %s", mark, task.text))
        for _, subtask in ipairs(task.subtasks or {}) do
            local submark = subtask.status == "done" and "[x]"
                or (subtask.status == "in_progress" and "[~]" or "[ ]")
            table.insert(lines, string.format("  %s %s", submark, subtask.text))
        end
    end
    return lines
end

local function emit(state, message)
    local done, total = counts(state.tasks)
    local lines = {}
    for _, task in ipairs(state.tasks) do
        table.insert(lines, styled_line(task.text, group_status(task), 0))
        for _, subtask in ipairs(task.subtasks or {}) do
            table.insert(lines, styled_line(subtask.text, subtask.status, 1))
        end
    end
    local content = { message or string.format("%d/%d done; autonomous loop %s.",
        done, total, state.active and "active" or "stopped") }
    for _, line in ipairs(text_lines(state.tasks)) do table.insert(content, line) end
    return cjson.encode({
        content = table.concat(content, "\n"),
        state = cjson.encode(state),
        pane = {
            source = STATE_KEY,
            title = string.format("%s (%d/%d%s)", state.name or DEFAULT_NAME, done, total,
                state.active and ", auto" or ""),
            visible_rows = 10,
            scroll = 0,
            lines = lines,
        },
    })
end

local function empty_pane()
    return { source = STATE_KEY, title = DEFAULT_NAME, lines = {} }
end

local function execute(params, ctx)
    local action = params.action or ""

    if action == "clear" then
        ctx.state.clear(STATE_KEY)
        return cjson.encode({ content = "Autonomous task list cleared.", pane = empty_pane() })
    end

    if action == "write" then
        if type(params.tasks) ~= "table" or #params.tasks == 0 then
            return "ERROR: write requires at least one task."
        end
        local tasks, rows, in_progress = {}, 0, 0
        for i, entry in ipairs(params.tasks) do
            local task, problem = normalize_task(entry)
            if not task then return string.format("ERROR: Task %d is invalid (%s).", i, problem) end
            rows = rows + 1 + #(task.subtasks or {})
            each_leaf({ task }, function(leaf)
                if leaf.status == "in_progress" then in_progress = in_progress + 1 end
            end)
            table.insert(tasks, task)
        end
        if rows > MAX_ROWS then return string.format("ERROR: Maximum %d displayed rows allowed.", MAX_ROWS) end
        if in_progress > 1 then return "ERROR: Keep at most one actionable item in_progress." end
        ensure_current(tasks)
        local state = {
            name = nonempty(params.name) and params.name or DEFAULT_NAME,
            tasks = tasks,
            active = not is_complete(tasks),
            iteration = 0,
        }
        persist(ctx, state)
        return emit(state, state.active and "Autonomous task loop started." or "All tasks complete.")
    end

    local state, problem = load_state(ctx)
    if not state then return "ERROR: " .. problem end

    if action == "advance" then
        local current = current_task(state.tasks)
        if not current then
            if is_complete(state.tasks) then return emit(state, "All tasks complete.") end
            return "ERROR: No task is in_progress; use resume or write the full list."
        end
        current.status = "done"
        ensure_current(state.tasks)
        state.active = not is_complete(state.tasks)
        persist(ctx, state)
        local message = nil
        if not state.active then message = "All tasks complete; autonomous loop stopped." end
        return emit(state, message)
    end

    if action == "complete" then
        each_leaf(state.tasks, function(task) task.status = "done" end)
        state.active = false
        persist(ctx, state)
        return emit(state, "All tasks complete; autonomous loop stopped.")
    end

    if action == "stop" then
        state.active = false
        state.blocked_reason = nonempty(params.reason) and params.reason or nil
        persist(ctx, state)
        return emit(state, state.blocked_reason and ("Loop stopped: " .. state.blocked_reason)
            or "Autonomous task loop stopped; checklist preserved.")
    end

    if action == "resume" then
        if is_complete(state.tasks) then return emit(state, "All tasks are already complete.") end
        ensure_current(state.tasks)
        state.active = true
        state.blocked_reason = nil
        persist(ctx, state)
        return emit(state, "Autonomous task loop resumed.")
    end

    return "ERROR: Action must be write, advance, complete, stop, resume, or clear."
end

bone.tool.register({
    name = "task_loop",
    description = "Autonomous visible checklist for driving multi-step work. Use only when the user asks for autonomous multi-step execution or explicitly requests task_loop. write starts the loop; after every response Bone automatically continues while actionable items remain. Call advance immediately after verifying the current item. Call stop with a reason when genuinely blocked. Supports one level of subtasks. State is host-held; write always receives the FULL list. Actions: write, advance, complete, stop, resume, clear.",
    safety = "read_only",
    stateful = true,
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "write", "advance", "complete", "stop", "resume", "clear" },
            },
            name = { type = "string", description = "Optional pane title for write." },
            reason = { type = "string", description = "Optional blocker reason for stop." },
            tasks = {
                type = "array",
                description = "Full list for write. Items may have one level of subtasks. Maximum 15 displayed rows total.",
                items = {
                    oneOf = {
                        { type = "string", minLength = 1 },
                        {
                            type = "object",
                            properties = {
                                text = { type = "string", minLength = 1 },
                                status = { type = "string", enum = { "pending", "in_progress", "done" } },
                                subtasks = {
                                    type = "array",
                                    minItems = 1,
                                    items = {
                                        oneOf = {
                                            { type = "string", minLength = 1 },
                                            {
                                                type = "object",
                                                properties = {
                                                    text = { type = "string", minLength = 1 },
                                                    status = { type = "string", enum = { "pending", "in_progress", "done" } },
                                                },
                                                required = { "text" },
                                                additionalProperties = false,
                                            },
                                        },
                                    },
                                },
                            },
                            required = { "text" },
                            additionalProperties = false,
                        },
                    },
                },
            },
        },
        required = { "action" },
        additionalProperties = false,
    },
    display = { show = false, show_result = false, args = { "action", "name", "tasks", "reason" } },
    execute = execute,
})

bone.on("before_turn", function(_event, ctx)
    if ctx.runtime.info().agent_depth ~= 0 then return end
    local state = load_state(ctx)
    if not state or not state.active or is_complete(state.tasks) then return end

    local done, total = counts(state.tasks)
    local current = current_task(state.tasks)
    local reminder = {
        string.format("## Autonomous Task Loop (%d/%d done)", done, total),
        "This checklist is the source of truth:",
        table.concat(text_lines(state.tasks), "\n"),
        "",
        "Work only on the current [~] item. Verify it, then call task_loop(action=advance) immediately.",
        "Do not claim completion while items remain. If genuinely blocked, call task_loop(action=stop, reason=...).",
        "The host will start another turn automatically until the checklist is complete or stopped.",
    }
    if current then table.insert(reminder, 2, "Current item: " .. current.text) end
    return { turn_message = table.concat(reminder, "\n") }
end)

bone.on("turn_end", function(event, ctx)
    if ctx.runtime.info().agent_depth ~= 0 then return end
    local state = load_state(ctx)
    if not state or not state.active then return end

    if not event.ok then
        state.active = false
        persist(ctx, state)
        bone.log.warn("task_loop: turn failed or was cancelled; loop stopped")
        return
    end

    if is_complete(state.tasks) then
        state.active = false
        persist(ctx, state)
        bone.log.info("task_loop: complete")
        return
    end

    local final_line = tostring(event.content or ""):gsub("%s+$", ""):match("([^\r\n]*)$") or ""
    local reason = final_line:match("^TASK_LOOP_STATUS:%s*blocked:%s*(.-)%s*$")
    if reason ~= nil then
        state.active = false
        state.blocked_reason = reason ~= "" and reason or "unspecified blocker"
        persist(ctx, state)
        bone.log.warn("task_loop: blocked — " .. state.blocked_reason)
        return
    end

    state.iteration = (tonumber(state.iteration) or 0) + 1
    persist(ctx, state)
    bone.submit("Continue the autonomous task list from its current in-progress item.")
end)
