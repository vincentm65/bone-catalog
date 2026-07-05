-- /goal — Codex-style autonomous goal loop.
--
-- Persists a goal checklist on disk. Two hooks drive an autonomous loop:
--   before_turn → re-injects the goal + procedure via turn_message (a
--                 transient trailing input item; the iteration counter changes
--                 every turn, so it must stay out of the system prompt to
--                 avoid busting the provider's prefix cache)
--   turn_end    → parses GOAL_STATUS sentinel, submits "Continue" or halts
--
-- Before starting broad/under-specified goals, /goal asks a compact scope
-- question via the catalog ask_user tool when installed. Measurable goals start
-- immediately. If ask_user is unavailable, /goal falls back to a normal chat
-- clarification prompt instead of guessing and running autonomously.
--
-- Esc (failed/cancelled turn) halts the loop automatically. /goal resume
-- picks back up without rewriting the file.
--
-- Lua only. No Rust, no ctx.state (turn_end has minimal ctx).

-- ---------------------------------------------------------------------------
-- State (module-local — shared across handler + hooks via closure)
-- ---------------------------------------------------------------------------

local state = { active = false, path = nil, iteration = 0 }

-- Session-scoped so multiple CLIs on the same machine/project don't clobber
-- each other's goal file. Falls back to "default" when no session is active.
local function goal_path(ctx)
    local sess = ctx.session and ctx.session.current and ctx.session.current()
    local id = tostring((sess and sess.id) or "default")
    -- Sanitize to filename-safe characters.
    id = id:gsub("[^%w%-]", "-")
    return ctx.config_dir .. "/goals/" .. id .. ".md"
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function now_ts()
    return os.date("%Y-%m-%d %H:%M")
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(s)
    return string.lower(s or "")
end

local function has_any(s, patterns)
    for _, pat in ipairs(patterns) do
        if s:find(pat) then return true end
    end
    return false
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function build_md(description, clarification)
    local scope = "- Goal was specific enough to start without clarification.\n"
    if clarification and clarification ~= "" then
        scope = clarification:gsub("\r\n", "\n")
        if not scope:match("\n$") then scope = scope .. "\n" end
    end

    return string.format(
        "# Goal\n\n%s\n\nCreated: %s\n\n" ..
        "## Scope / Clarification\n" ..
        "%s\n" ..
        "## Acceptance Criteria\n" ..
        "<!-- All must be [x] before done. Make these concrete before execution. -->\n" ..
        "- [ ] Define measurable done criteria from the goal and scope above.\n\n" ..
        "## Tasks\n" ..
        "<!-- Small, verifiable steps. Check off as you complete. -->\n" ..
        "- [ ] Turn the goal into a concrete task plan sized to the clarified scope.\n\n" ..
        "## Progress\n" ..
        "<!-- One line per completed task, with timestamp. -->\n",
        description, now_ts(), scope
    )
end

-- Broad goals should not start an autonomous loop until scope/quality is known.
-- Concrete debugging/audit/check/fix goals usually have discoverable scope in
-- the repo and can proceed without interrupting the user.
local function needs_clarification(description)
    local s = lower(description)

    local concrete = has_any(s, {
        "bug", "bugs", "crash", "error", "failing", "failure", "fix", "debug",
        "regression", "test", "tests", "lint", "build", "panic", "exception",
        "audit", "review", "all files", "repo", "repository", "current files",
        "this file", "these files", "specific", "exact", "reproduce"
    })
    if concrete then return false end

    local broad_action = has_any(s, {
        "^make%s", "^build%s", "^create%s", "^design%s", "^implement%s",
        "^improve%s", "^enhance%s", "^polish%s", "^refactor%s", "^rewrite%s",
        " make%s", " build%s", " create%s", " design%s", " improve%s"
    })
    local broad_object = has_any(s, {
        "game", "sandbox", "app", "website", "web app", "ui", "interface",
        "dashboard", "system", "platform", "product", "experience", "feature"
    })
    local vague_quality = has_any(s, {
        "better", "nice", "cool", "good", "great", "polished", "epic",
        "awesome", "full", "complete", "production", "professional"
    })

    return (broad_action and broad_object) or vague_quality
end

local function ask_goal_scope(ctx, description)
    if not (ctx.tools and ctx.tools.call) then
        return nil, "ask_user unavailable"
    end

    local ok, result = pcall(ctx.tools.call, "ask_user", {
        questions = {
            {
                question = "This goal is broad. How far should I take it?",
                options = {
                    { label = "Quick prototype/pass", description = "Smallest useful result; minimal checks." },
                    { label = "Solid complete version/pass", description = "Reasonable scope, useful defaults, verified." },
                    { label = "Polished/deep pass", description = "Broader scope, edge cases, multiple implementation/verification passes." },
                    { label = "You decide reasonable defaults", description = "Proceed autonomously with sensible assumptions." },
                },
                default = 2,
            },
            {
                question = "Any must-have requirements or boundaries?",
                type = "text_input",
                allow_custom = true,
            },
        },
    }, { approval = "safe" })

    if not ok or not result or not result.ok or result.is_error then
        return nil, "ask_user unavailable"
    end

    local content = trim(result.content or "")
    if content == "" or content == "[user cancelled]" then
        return nil, "clarification cancelled"
    end

    return "Clarification answers:\n" .. content .. "\n", nil
end

local function fallback_clarification_prompt(description)
    return string.format([==[
The requested /goal is broad enough that starting autonomously would require guessing:

%s

Ask the user one compact clarification before starting. Cover:
1. desired scope/finish line: quick prototype/pass, solid complete version/pass, polished/deep pass, or "you decide";
2. must-have requirements or boundaries.

Do not begin implementation yet. After the user answers, tell them to run /goal again with the clarified requirements, or with "you decide" if they want defaults.
]==], description)
end

-- ---------------------------------------------------------------------------
-- before_turn: re-inject goal + procedure every turn
-- ---------------------------------------------------------------------------

bone.on("before_turn", function(_event, ctx)
    if bone.agent_depth ~= 0 then return end
    if not state.active or not state.path then return end

    local content = ""
    if ctx.fs.exists(state.path) then
        local ok, text = pcall(ctx.read_file, state.path)
        if ok then content = text end
    end

    local append = string.format([==[
## Active Goal

You are in an autonomous goal loop (iteration %d). Your source of truth:

%s

## Procedure (every turn)
1. Re-read the goal, scope, checklist, and progress above.
2. If acceptance criteria are still vague, make them concrete before doing broad work.
3. Pick the next unchecked task (or acceptance criterion if all tasks are done).
4. Do the task.
5. Verify with relevant builds, tests, linters, manual checks, source inspection, or other evidence.
6. Check off completed items (replace [ ] with [x] via edit_file).
7. Append a one-line Progress entry with a timestamp.
8. If ALL acceptance criteria are checked, verify the whole goal once more, then end your response with exactly: GOAL_STATUS: done
9. If you hit a genuine blocker you cannot resolve, end with: GOAL_STATUS: blocked: <reason>
10. Otherwise end with: GOAL_STATUS: working

Do not stop after a thin MVP unless the clarified scope says prototype/quick pass.
]==], state.iteration, content)

    return { turn_message = append }
end)

-- ---------------------------------------------------------------------------
-- turn_end: the autonomous loop driver
-- ---------------------------------------------------------------------------

bone.on("turn_end", function(event, _ctx)
    if not state.active then return end

    -- Esc / failure / cancellation halts the loop.
    if not event.ok then
        state.active = false
        bone.log.warn("goal: turn failed/cancelled — loop halted at iteration " .. state.iteration)
        return
    end

    local content = event.content or ""
    state.iteration = state.iteration + 1

    local status = content:match("GOAL_STATUS:%s*(%a+)")
    if status == "done" then
        state.active = false
        bone.log.info("goal: complete after " .. state.iteration .. " iterations")
        return
    elseif status == "blocked" then
        state.active = false
        local reason = content:match("GOAL_STATUS:%s*blocked:%s*(.+)$")
        reason = reason and reason:gsub("^%s+", ""):gsub("%s+$", "")
        bone.log.warn("goal: blocked — " .. (reason or "no reason given"))
        return
    end

    -- working or missing sentinel → continue
    bone.api.submit("Continue the goal.")
end)

-- ---------------------------------------------------------------------------
-- /goal command
-- ---------------------------------------------------------------------------

bone.register_command("goal", {
    description = "Start, resume, check, or stop an autonomous goal.",
    handler = function(args, ctx)
        local arg = trim(args or "")
        local path = goal_path(ctx)

        -- /goal stop
        if arg == "stop" then
            if not state.active and ctx.fs.exists(path) ~= true then
                return { display = "No active goal.", submit = false }
            end
            state.active = false
            return { display = "Goal loop stopped. File preserved at " .. path, submit = false }
        end

        -- /goal resume
        if arg == "resume" then
            if ctx.fs.exists(path) ~= true then
                return { display = "No goal file to resume. Use /goal <description>.", submit = false }
            end
            state.active = true
            state.path = path
            state.iteration = 0
            return "Resume the autonomous goal. Re-read the checklist, pick up where you left off, and follow the procedure in the system prompt."
        end

        -- /goal status (or bare /goal)
        if arg == "" or arg == "status" then
            if ctx.fs.exists(path) ~= true then
                return { display = "No active goal. Use /goal <description> to start.", submit = false }
            end
            local ok, content = pcall(ctx.read_file, path)
            if not ok then
                return { display = "Could not read: " .. path, submit = false }
            end
            local header = string.format("Iteration: %d  Active: %s\n\n",
                state.iteration, state.active and "yes" or "no")
            return { display = header .. content, submit = false }
        end

        -- /goal <description> — start new goal. Clarify only when the goal is
        -- broad enough that autonomous execution would mostly be guessing.
        state.active = false -- stop any existing loop first

        local clarification = nil
        if needs_clarification(arg) then
            local answer, err = ask_goal_scope(ctx, arg)
            if not answer then
                if err == "clarification cancelled" then
                    return { display = "Goal not started; clarification was cancelled.", submit = false }
                end
                return fallback_clarification_prompt(arg)
            end
            clarification = answer
        end

        local dir = ctx.config_dir .. "/goals"
        if ctx.fs.exists(dir) ~= true then
            ctx.shell("mkdir -p " .. shell_quote(dir))
        end
        local md = build_md(arg, clarification)
        if ctx.fs.exists(path) then
            ctx.tools.call("edit_file", { path = path, mode = "rewrite", content = md })
        else
            ctx.write_file(path, md)
        end

        state.active = true
        state.path = path
        state.iteration = 0

        return string.format(
            "I've set up an autonomous goal. The checklist is at %s. " ..
            "Begin by making acceptance criteria and tasks concrete from the goal and clarified scope, then work through them following the procedure in the system prompt.",
            path)
    end,
})
