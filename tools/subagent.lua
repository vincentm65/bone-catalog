-- Sub-agent tool: manage named agents, discovery, dispatch, and status reporting.
-- Catalog description = "Manage named sub-agents and delegate tasks to them."
--
-- The /agents manager is active in top-level sessions. The model-facing tool
-- is created only when sub-agents are registered via bone.subagent.register.
--
-- The live status pane is rendered natively in Rust (src/ui/subagent_pane.rs)
-- so it stays responsive even while this tool blocks the Lua VM.

-- cjson is a global injected by Rust (encode/decode via serde_json)

-- ---------------------------------------------------------------------------
-- Early exits
-- ---------------------------------------------------------------------------

-- Sub-agents must not spawn nested sub-agents: never register either surface
-- inside a sub-agent VM.
if bone.agent_depth and bone.agent_depth > 0 then
    return
end

-- ---------------------------------------------------------------------------
-- /agents command
-- ---------------------------------------------------------------------------

local menu = require("ui.menu")
local pane = require("ui.pane")

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function optional(value)
    value = trim(value)
    if value == "" then return nil end
    return value
end

local function notify(ctx, message, level)
    if ctx and ctx.ui and type(ctx.ui.notify) == "function" then
        ctx.ui.notify(message, level or "info")
    end
end

local function ask(ctx, spec)
    local ok, result = pcall(menu.select, ctx, spec)
    if not ok then
        notify(ctx, "Agent manager failed: " .. tostring(result), "error")
        return nil
    end
    if type(result) ~= "table" or result.cancelled then return nil end
    return result
end

local function edit_text(ctx, label, initial)
    local ok, result = pcall(menu.text_input, ctx, {
        title = "Sub-agents",
        question = "Edit " .. label,
        initial = tostring(initial or ""),
    })
    if not ok then
        notify(ctx, "Could not edit " .. label .. ": " .. tostring(result), "error")
        return nil
    end
    if type(result) ~= "table" or result.cancelled then return nil end
    return result.value or ""
end

local function copy_agent(agent)
    return {
        name = agent and agent.name or "",
        description = agent and agent.description or "",
        system_prompt = agent and agent.system_prompt or nil,
        provider = agent and agent.provider or nil,
        model = agent and agent.model or nil,
        approval = agent and agent.approval or "safe",
        timeout_ms = agent and agent.timeout_ms or nil,
        max_concurrency = agent and agent.max_concurrency or 1,
        enabled = agent == nil or agent.enabled ~= false,
        source = "config",
    }
end

local function validate(draft)
    if not draft.name:match("^[A-Za-z0-9_-]+$") then
        return "Name may contain only letters, numbers, underscores, and hyphens."
    end
    if trim(draft.description) == "" then
        return "Description must not be empty."
    end
    if draft.timeout_ms ~= nil then
        local timeout = tonumber(draft.timeout_ms)
        if not timeout or timeout % 1 ~= 0 or timeout < 1 or timeout > 900000 then
            return "Timeout must be blank or an integer from 1 through 900000."
        end
        draft.timeout_ms = timeout
    end
    local max_concurrency = tonumber(draft.max_concurrency)
    if not max_concurrency or max_concurrency % 1 ~= 0 or max_concurrency < 1 then
        return "Max concurrency must be a positive integer."
    end
    draft.max_concurrency = max_concurrency
    return nil
end

local function editor_options(draft, is_new)
    return {
        { label = "Name", description = is_new and draft.name or draft.name .. " (fixed)", value = "name" },
        { label = "Description", description = draft.description, value = "description" },
        { label = "System prompt", description = draft.system_prompt or "(blank)", value = "system_prompt" },
        { label = "Provider", description = draft.provider or "inherit", value = "provider" },
        { label = "Model", description = draft.model or "inherit", value = "model" },
        { label = "Approval", description = draft.approval, value = "approval" },
        { label = "Timeout", description = draft.timeout_ms and tostring(draft.timeout_ms) .. " ms" or "default", value = "timeout" },
        { label = "Max concurrency", description = tostring(draft.max_concurrency), value = "max_concurrency" },
        { label = "Enabled", description = draft.enabled and "yes" or "no", value = "enabled" },
        { label = "Save", description = "Persist to subagents.yaml", value = "save" },
    }
end

local function edit_agent(ctx, agent)
    local is_new = agent == nil
    local draft = copy_agent(agent)
    local selected = 1
    while true do
        local result = ask(ctx, {
            title = "Sub-agents",
            question = (is_new and "Add config agent" or "Edit agent: " .. draft.name),
            options = editor_options(draft, is_new),
            default = selected,
            visible_rows = 14,
        })
        if not result then return false end
        selected = result.selected or selected
        local field = result.value
        if field == "name" then
            if is_new then
                local value = edit_text(ctx, "name", draft.name)
                if value ~= nil then draft.name = trim(value) end
            else
                notify(ctx, "Existing names are fixed; create a new agent to rename it.", "warn")
            end
        elseif field == "description" then
            local value = edit_text(ctx, "description", draft.description)
            if value ~= nil then draft.description = value end
        elseif field == "system_prompt" then
            local value = edit_text(ctx, "system prompt", draft.system_prompt)
            if value ~= nil then draft.system_prompt = optional(value) end
        elseif field == "provider" then
            local value = edit_text(ctx, "provider", draft.provider)
            if value ~= nil then draft.provider = optional(value) end
        elseif field == "model" then
            local value = edit_text(ctx, "model", draft.model)
            if value ~= nil then draft.model = optional(value) end
        elseif field == "approval" then
            draft.approval = draft.approval == "danger" and "safe" or "danger"
        elseif field == "timeout" then
            local value = edit_text(ctx, "timeout in milliseconds (blank for default)", draft.timeout_ms)
            if value ~= nil then draft.timeout_ms = optional(value) end
        elseif field == "max_concurrency" then
            local value = edit_text(ctx, "max concurrent jobs", draft.max_concurrency)
            if value ~= nil then draft.max_concurrency = trim(value) end
        elseif field == "enabled" then
            draft.enabled = not draft.enabled
        elseif field == "save" then
            draft.description = trim(draft.description)
            local problem = validate(draft)
            if problem then
                notify(ctx, problem, "warn")
            else
                local ok, err = pcall(ctx.config.upsert_subagent, draft)
                if ok then return true end
                notify(ctx, "Could not save agent: " .. tostring(err), "error")
            end
        end
    end
end

local function agent_option(agent)
    local status = agent.enabled and "enabled" or "disabled"
    local source = agent.source == "config" and "config" or "Lua"
    local prompt = agent.system_prompt or "(none)"
    return {
        label = agent.name,
        value = agent.name,
        description = string.format("%s · %s · %s", status, source, agent.description or ""),
        search_text = table.concat({ agent.name, status, source, agent.description or "" }, " "),
        preview = {
            title = agent.name,
            lines = {
                agent.description or "",
                "Source: " .. source,
                "Enabled: " .. (agent.enabled and "yes" or "no"),
                "Provider: " .. (agent.provider or "inherit"),
                "Model: " .. (agent.model or "inherit"),
                "Approval: " .. (agent.approval or "safe"),
                "Timeout: " .. (agent.timeout_ms and tostring(agent.timeout_ms) .. " ms" or "default"),
                "Max concurrency: " .. tostring(agent.max_concurrency or 1),
                "System prompt:",
                prompt,
            },
        },
    }
end

local function list_options(agents)
    local options = {}
    for _, agent in ipairs(agents) do options[#options + 1] = agent_option(agent) end
    if #options == 0 then
        options[1] = {
            label = "No sub-agents",
            value = "__empty",
            description = "Press n to add a config agent.",
            preview = { title = "Sub-agents", lines = { "No agents are registered." } },
        }
    end
    return options
end

local function find_listed_agent(agents, name)
    for _, agent in ipairs(agents) do
        if agent.name == name then return agent end
    end
    return nil
end

local function confirm_delete(ctx, agent)
    local result = ask(ctx, {
        title = "Sub-agents",
        question = "Delete config agent '" .. agent.name .. "'?",
        options = {
            { label = "Delete", value = "delete", description = "Remove it from subagents.yaml" },
            { label = "Cancel", value = "cancel" },
        },
        default = 2,
    })
    return result and result.value == "delete"
end

local function run_agents(ctx)
    local changed = false
    local selected = 1
    while true do
        local listed, agents = pcall(bone.subagent.list)
        if not listed then
            notify(ctx, "Could not list agents: " .. tostring(agents), "error")
            break
        end
        local result = ask(ctx, {
            title = "Sub-agents",
            question = "Enter edit · n add · Space toggle · d delete · Esc close",
            options = list_options(agents),
            default = selected,
            action_keys = { n = "add", [" "] = "toggle", d = "delete" },
            preview = { focusable = false },
            visible_rows = 18,
        })
        if not result then break end
        selected = result.selected or selected

        if result.value == "add" then
            if edit_agent(ctx, nil) then changed = true end
        else
            local option = list_options(agents)[selected]
            local agent = option and find_listed_agent(agents, option.value) or nil
            if agent then
                if result.value == "toggle" then
                    local ok, err = pcall(function()
                        ctx.config.set_subagent_enabled(agent.name, not agent.enabled)
                    end)
                    if ok then changed = true else notify(ctx, "Could not update agent: " .. tostring(err), "error") end
                elseif result.value == "delete" then
                    if agent.source ~= "config" then
                        notify(ctx, "Lua-defined agents must be promoted by editing them before deletion.", "warn")
                    elseif confirm_delete(ctx, agent) then
                        local ok, err = pcall(ctx.config.delete_subagent, agent.name)
                        if ok then changed = true else notify(ctx, "Could not delete agent: " .. tostring(err), "error") end
                    end
                elseif edit_agent(ctx, agent) then
                    changed = true
                end
            end
        end
    end

    pane.new(ctx, { id = "interact" }):close()
    if changed then return { action = "config.reload_tools", submit = false } end
    return nil
end

bone.command.register("agents", {
    description = "manage named sub-agents",
    handler = function(_, ctx)
        return run_agents(ctx)
    end,
})

local subagents = bone._subagents
if not subagents or #subagents == 0 then
    return
end

-- Headless mode (CLI): background job auto-injection is unavailable, so
-- dispatch must always block for results.
local headless = bone.headless and true or false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Numeric part of a "job-N" id (0 when malformed).
local function job_id_number(id)
    return tonumber((id or ""):match("(%d+)$")) or 0
end

--- Build a human-readable status string for a single job.
local function job_status(job)
    if not job then
        return "○ idle"
    end

    if job.status == "queued" then
        return "⧗ queued"
    end
    if job.status == "running" then
        local elapsed = os.time() - job.started_at
        local task = job.activity or (job.title ~= nil and job.title ~= "" and job.title or (job.task or ""))
        if #task > 40 then
            task = task:sub(1, 37) .. "..."
        end
        local sent = job.token_sent or 0
        local received = job.token_received or 0
        return string.format("◑ running %s (%ds) %s/%s in/out", task, elapsed, sent, received)
    end
    -- done → treat as idle
    if job.status == "done" then
        local sent = job.token_sent or 0
        local received = job.token_received or 0
        if sent > 0 or received > 0 then
            return string.format("○ idle (%s/%s in/out)", sent, received)
        end
        return "○ idle"
    end
    -- error
    return "✗ error"
end

local function find_agent(name)
    for _, agent in ipairs(subagents) do
        if agent.name == name then return agent end
    end
end

local function opts_for(agent, title)
    local opts = {
        agent = agent.name,
        title = title or "",
        system_prompt = agent.system_prompt,
        provider = agent.provider,
        model = agent.model,
        approval = agent.approval,
        timeout_ms = agent.timeout_ms,
        max_concurrency = agent.max_concurrency or 1,
    }
    if agent.tools and #agent.tools > 0 then opts.tools = agent.tools end
    return opts
end

--- Build a status summary string for one agent (latest job by id).
local function agent_status(agent, jobs)
    local latest = nil
    for _, j in ipairs(jobs) do
        if j.agent == agent.name then
            if not latest or job_id_number(j.id) > job_id_number(latest.id) then
                latest = j
            end
        end
    end
    return job_status(latest)
end

-- ---------------------------------------------------------------------------
-- Build dynamic tool description
-- ---------------------------------------------------------------------------

local function build_description()
    local parts = {
        "Delegate tasks to registered sub-agents. Each agent runs in its own isolated context and only sees the task text you give it — write self-contained tasks (include file paths, goals, constraints, and the expected output format).",
        "",
        "Registered agents:",
    }
    for _, agent in ipairs(subagents) do
        local extras = {}
        if agent.approval then
            extras[#extras + 1] = "approval: " .. agent.approval
        end
        if agent.max_concurrency and agent.max_concurrency > 1 then
            extras[#extras + 1] = "concurrency: " .. agent.max_concurrency
        end
        local suffix = #extras > 0 and (" [" .. table.concat(extras, ", ") .. "]") or ""
        parts[#parts + 1] = string.format("  - %s: %s%s", agent.name, agent.description, suffix)
    end
    parts[#parts + 1] = ""
    if headless then
        parts[#parts + 1] = table.concat({
            "Actions:",
            '- dispatch: start one or more tasks (one tasks[] entry each, run in parallel). Blocks until all dispatched tasks finish and returns their results.',
            '- followup: continue a finished job with its context intact. Provide id and task; blocks and returns the result.',
            '- wait: block until previously dispatched jobs finish. Waits on the given ids[] (or all running jobs when omitted) and returns their results.',
            '- cancel: stop running jobs by id. Sets a per-job cancel flag.',
            '- status: non-blocking snapshot of job progress. Use sparingly; never call status in a loop.',
            "",
            "Rules:",
            "- Batch independent tasks into a single dispatch call to maximize parallelism.",
            "- Each agent runs up to its `max_concurrency` jobs at a time (default 1); dispatching beyond the cap queues tasks.",
        }, "\n")
    else
        parts[#parts + 1] = table.concat({
            "Actions:",
            '- dispatch: start one or more tasks (one tasks[] entry each, run in parallel).',
            '  - If you need the results to continue, or you have nothing else productive to do, set wait=true: the call blocks and returns the results directly. This is the right choice for fan-out/fan-in work (e.g. dispatching research and then synthesizing it).',
            '  - Omit wait ONLY when you have separate, independent work to do that does NOT overlap the dispatched tasks: dispatch returns immediately and you continue on that other work. Finished results are delivered automatically in a later message — do NOT poll for them, and NEVER fabricate or assume results you have not received.',
            '- wait: block until previously dispatched jobs finish. Waits on the given ids[] (or all running jobs when omitted) and returns their results. Use when you reach a point where you need pending results before continuing.',
            '- followup: continue a finished job with its context intact. Provide id and task; set wait=true when the next step depends on it.',
            '- cancel: stop running jobs by id. Sets a per-job cancel flag.',
            '- status: non-blocking snapshot of job progress. Use sparingly; never call status in a loop.',
            "",
            "Rules:",
            "- Batch independent tasks into a single dispatch call to maximize parallelism.",
            "- Each agent runs up to its `max_concurrency` jobs at a time (default 1); dispatching beyond the cap queues tasks.",
            "- NEVER duplicate the work you delegated. Once a task is dispatched, do not read the same files, run the same searches, or research the same questions yourself — that wastes context and defeats the purpose of delegating. Let the sub-agent do it.",
        }, "\n")
    end
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Result formatting helpers
-- ---------------------------------------------------------------------------

-- Per-job character budget for results returned by wait (mirrors the Rust
-- auto-injection limit).
local MAX_RESULT_CHARS = 16000

--- Truncate to a byte budget without splitting a UTF-8 sequence.
local function truncate_result(s, max)
    if #s <= max then
        return s
    end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "\n[... truncated]"
end

--- Format a ctx.agent.wait outcome into a report for the model.
local function format_wait_outcome(outcome)
    local parts = {}
    for _, job in ipairs(outcome.jobs or {}) do
        local sym = job.status == "done" and "done" or "ERROR"
        local body = truncate_result(job.result or "", MAX_RESULT_CHARS)
        if job.result_file then
            body = body .. string.format("\n[full output saved to: %s]", job.result_file)
        end
        parts[#parts + 1] = string.format(
            "## %s (%s) — %s\n%s",
            job.agent ~= "" and job.agent or "agent",
            job.id,
            sym,
            body
        )
    end
    if outcome.cancelled then
        parts[#parts + 1] = "Wait cancelled by user; jobs keep running and their results will arrive automatically."
    elseif outcome.timed_out then
        parts[#parts + 1] = string.format(
            "Wait timed out with jobs still running: %s. Their results will arrive automatically in a later message — do not assume their outcome.",
            table.concat(outcome.pending or {}, ", ")
        )
    end
    if #parts == 0 then
        parts[#parts + 1] = "No jobs to wait on."
    end
    return table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------------
-- Tool execute function
-- ---------------------------------------------------------------------------

local function execute(params, ctx)
    local action = params.action or ""

    if action == "dispatch" then
        local tasks = params.tasks or {}
        if #tasks == 0 then
            return "ERROR: Provide tasks for 'dispatch'."
        end

        local results = {}
        local dispatched_ids = {}
        local ok_count = 0
        local err_count = 0

        for _, t in ipairs(tasks) do
            local agent_name = t.agent or ""
            local task_desc = t.task or ""
            local title = t.title or ""

            -- Look up the agent definition
            local agent_def = find_agent(agent_name)

            if agent_def then
                -- Build spawn opts from the agent definition.
                local opts = opts_for(agent_def, title)

                local result = ctx.agent.spawn(task_desc, opts)
                if result.ok then
                    results[#results + 1] = string.format(
                        "dispatched %s → %s", result.id, agent_name
                    )
                    dispatched_ids[#dispatched_ids + 1] = result.id
                    ok_count = ok_count + 1
                else
                    results[#results + 1] = string.format(
                        "REJECTED: %s — %s", agent_name, result.error or "unknown"
                    )
                    err_count = err_count + 1
                end
            else
                results[#results + 1] = string.format(
                    "REJECTED: unknown agent '%s'", agent_name
                )
                err_count = err_count + 1
            end
        end

        local summary = string.format(
            "Dispatched %d, rejected %d", ok_count, err_count
        )
        if err_count > 0 then
            summary = summary .. "\n" .. table.concat(results, "\n")
        end

        -- Blocking dispatch: wait for the dispatched jobs and return results.
        -- Headless mode always blocks (no background auto-injection there).
        local should_wait = params.wait or headless
        if should_wait and #dispatched_ids > 0 then
            local outcome = ctx.agent.wait(dispatched_ids, { timeout_ms = params.timeout_ms })
            if outcome.ok then
                summary = summary .. "\n\n" .. format_wait_outcome(outcome)
            else
                summary = summary .. "\n\nERROR waiting: " .. (outcome.error or "unknown")
            end
        end

        return summary
    end

    if action == "followup" then
        local prior, task = params.id or "", params.task or ""
        if prior == "" or task == "" then
            return "ERROR: Provide id and task for 'followup'."
        end
        local prior_job
        for _, job in ipairs(ctx.agent.jobs()) do
            if job.id == prior then prior_job = job break end
        end
        local agent_def = prior_job and find_agent(prior_job.agent)
        if not agent_def then return "ERROR: Job or registered agent not found." end
        local result = ctx.agent.followup(prior, task, opts_for(agent_def, params.title))
        if not result.ok then return "ERROR: " .. (result.error or "unknown") end
        if params.wait or headless then
            local outcome = ctx.agent.wait({ result.id }, { timeout_ms = params.timeout_ms })
            if not outcome.ok then return "ERROR: " .. (outcome.error or "unknown") end
            return format_wait_outcome(outcome)
        end
        return string.format("dispatched followup %s → %s", result.id, agent_def.name)
    end

    if action == "wait" then
        local outcome = ctx.agent.wait(params.ids, { timeout_ms = params.timeout_ms })
        if not outcome.ok then
            return "ERROR: " .. (outcome.error or "unknown")
        end
        return format_wait_outcome(outcome)
    end

    if action == "cancel" then
        local ids = params.ids or {}
        if #ids == 0 then
            return { ok = false, error = "Provide ids for 'cancel'." }
        end
        local parts = {}
        for _, id in ipairs(ids) do
            local result = ctx.agent.cancel(id)
            parts[#parts + 1] = string.format(
                "%s: %s", id, result.ok and "cancelled" or "not found"
            )
        end
        return table.concat(parts, "\n")
    end

    if action == "status" then
        local jobs = ctx.agent.jobs()
        local parts = { "Sub-agent status:" }
        for _, agent in ipairs(subagents) do
            parts[#parts + 1] = string.format("  %s: %s", agent.name, agent_status(agent, jobs))
        end
        return table.concat(parts, "\n")
    end

    return "ERROR: Action must be 'dispatch', 'followup', 'wait', 'cancel' or 'status'."
end

-- ---------------------------------------------------------------------------
-- Register the tool
-- ---------------------------------------------------------------------------

bone.tool.register({
    name = "subagent",
    description = build_description(),
    safety = "read_only",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "dispatch", "followup", "wait", "cancel", "status" },
                description = "dispatch tasks, followup a finished job, wait, cancel, or inspect status",
            },
            tasks = {
                type = "array",
                description = "dispatch only: list of tasks to start in parallel. Each item: {agent: string, title: string, task: string}",
                items = {
                    type = "object",
                    properties = {
                        agent = {
                            type = "string",
                            description = "Registered agent name",
                        },
                        title = {
                            type = "string",
                            description = "Short (≤ ~8 word) human-readable summary of the task, shown in the UI (live pane + tool-call row). E.g. \"Review unstaged changes for bugs\".",
                        },
                        task = {
                            type = "string",
                            description = "Self-contained task description for the agent (it sees nothing else)",
                        },
                    },
                    required = { "agent", "title", "task" },
                    additionalProperties = false,
                },
            },
            wait = {
                type = "boolean",
                description = "dispatch only: block until the dispatched tasks finish and return the results. Use when your next step depends on them.",
            },
            id = {
                type = "string",
                description = "followup only: completed job id whose context should be continued",
            },
            task = {
                type = "string",
                description = "followup only: new self-contained task to continue with",
            },
            title = {
                type = "string",
                description = "followup only: short human-readable title",
            },
            ids = {
                type = "array",
                items = { type = "string" },
                description = "wait/cancel: job ids to wait for (omit to wait for all running jobs) / job ids to cancel",
            },
            timeout_ms = {
                type = "integer",
                description = "dispatch(wait=true)/wait: max time to block in milliseconds (default 300000)",
            },
        },
        required = { "action" },
        additionalProperties = false,
    },
    display = {
        show = true,
        show_result = false,
        -- Dispatch/wait calls block until the agents finish, so render the row
        -- at call time rather than on completion.
        eager = true,
        -- Dispatch label: each task's title (falling back to its task text).
        -- For non-dispatch actions `tasks` is absent, so the template yields
        -- nothing and the row falls back to the `args` label below.
        template = "dispatch: {tasks[].title|task}",
        args = { "action", "tasks", "wait", "ids" },
    },
    execute = execute,
})
