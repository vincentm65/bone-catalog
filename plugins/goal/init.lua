-- /goal — Codex-style autonomous goal loop.
--
-- Persists a goal checklist on disk. Two hooks drive an autonomous loop:
--   before_turn → re-injects the goal + procedure via turn_message (a
--                 transient trailing input item; the iteration counter changes
--                 every turn, so it must stay out of the system prompt to
--                 avoid busting the provider's prefix cache)
--   turn_end    → parses GOAL_STATUS sentinel, submits "Continue" or halts
--
-- The agent decides whether to clarify scope via ask_user before starting
-- work. No hardcoded questions live in this command.
--
-- Esc (failed/cancelled turn) halts the loop automatically. /goal resume
-- picks back up without rewriting the file.
--
-- Lua only. No Rust, no ctx.state (turn_end has minimal ctx).

-- ---------------------------------------------------------------------------
-- State (module-local — shared across handler + hooks via closure)
-- ---------------------------------------------------------------------------

local state = { active = false, path = nil, session_id = nil, iteration = 0 }

-- Native read_file/edit_file safety limits. A whole-file replacement is only
-- valid after every line has been exposed to edit_file's snapshot guard.
local NATIVE_READ_MAX_BYTES = 50 * 1024 * 1024
local NATIVE_READ_MAX_LINES = 1000
local NATIVE_EDITABLE_LINE_CHARS = 2000

-- Session-scoped so multiple CLIs on the same machine/project don't clobber
-- each other's goal file. Falls back to "default" when no session is active.
local function session_id(ctx)
    local sess = ctx.session and ctx.session.current and ctx.session.current()
    return tostring((sess and sess.id) or "default")
end

local function goal_path(ctx)
    local id = session_id(ctx)
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

local function activate(path, id)
    state.active = true
    state.path = path
    state.session_id = id
    state.iteration = 0
end

local function build_md(description)
    return string.format(
        "# Goal\n\n%s\n\nCreated: %s\n\n" ..
        "## Acceptance Criteria\n" ..
        "<!-- Make these concrete. All must be [x] before done. -->\n" ..
        "- [ ] \n\n" ..
        "## Tasks\n" ..
        "<!-- Small, verifiable steps. Check off as you complete. -->\n" ..
        "- [ ] \n\n" ..
        "## Progress\n" ..
        "<!-- One line per completed task, with timestamp. -->\n",
        description, now_ts()
    )
end

local function result_error(result, fallback)
    if not result then return fallback end
    local message = result.content or result.error
    if message and message ~= "" then return tostring(message) end
    return fallback
end

local function normalize_text(text)
    text = tostring(text or "")
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function inspect_editable_text(text)
    local normalized = normalize_text(text)
    local line_count = 0
    local cursor = 1
    while cursor <= #normalized do
        local newline = normalized:find("\n", cursor, true)
        local line
        if newline then
            line = normalized:sub(cursor, newline - 1)
            cursor = newline + 1
        else
            line = normalized:sub(cursor)
            cursor = #normalized + 1
        end
        line_count = line_count + 1
        local chars = utf8.len(line)
        if not chars then
            return nil, string.format("goal file line %d is not valid UTF-8", line_count)
        end
        if chars > NATIVE_EDITABLE_LINE_CHARS then
            return nil, string.format(
                "goal file line %d has %d characters; edit_file can replace only lines of at most %d characters",
                line_count, chars, NATIVE_EDITABLE_LINE_CHARS)
        end
    end
    return line_count
end

local function snapshot_entire_file(ctx, path, expected_lines)
    local start_line = 1
    repeat
        local read = ctx.tools.call("read_file", {
            path = path,
            start_line = start_line,
            max_lines = NATIVE_READ_MAX_LINES,
        }, { approval = "read_only" })
        if not read or not read.ok or read.is_error then
            return false, result_error(read, "read_file failed")
        end
        if expected_lines == 0 then return true end

        local first, last, total = tostring(read.content or "")
            :match("Range:%s+lines%s+(%d+)%-(%d+)%s+of%s+(%d+)")
        first, last, total = tonumber(first), tonumber(last), tonumber(total)
        if not first or not last or not total then
            return false, "read_file returned an unrecognized range while preparing the goal edit"
        end
        if first ~= start_line or last < first then
            return false, "read_file made no progress while preparing the goal edit"
        end
        if total ~= expected_lines then
            return false, "goal file changed while preparing the edit; retry the command"
        end
        start_line = last + 1
    until start_line > expected_lines
    return true
end

local function write_goal(ctx, path, content)
    if #content > NATIVE_READ_MAX_BYTES then
        return false, string.format(
            "new goal file would be %d bytes; read_file's limit is %d bytes",
            #content, NATIVE_READ_MAX_BYTES)
    end
    local _, new_content_err = inspect_editable_text(content)
    if new_content_err then
        return false, "new " .. new_content_err
    end

    if ctx.fs.exists(path) ~= true then
        local ok, err = pcall(ctx.create_file, path, content)
        if not ok then return false, tostring(err) end
        return true
    end

    if ctx.fs.metadata then
        local metadata_ok, metadata = pcall(ctx.fs.metadata, path)
        local size = metadata_ok and type(metadata) == "table" and tonumber(metadata.len) or nil
        if size and size > NATIVE_READ_MAX_BYTES then
            return false, string.format(
                "goal file is %d bytes; read_file's limit is %d bytes",
                size, NATIVE_READ_MAX_BYTES)
        end
    end

    local ok, old = pcall(ctx.read_file, path)
    if not ok then return false, tostring(old) end
    if #old > NATIVE_READ_MAX_BYTES then
        return false, string.format(
            "goal file is %d bytes; read_file's limit is %d bytes",
            #old, NATIVE_READ_MAX_BYTES)
    end
    if old == content then return true end

    local line_count, inspect_err = inspect_editable_text(old)
    if not line_count then return false, inspect_err end
    local snapshotted, snapshot_err = snapshot_entire_file(ctx, path, line_count)
    if not snapshotted then return false, snapshot_err end

    local edited = ctx.tools.call("edit_file", {
        path = path,
        old_text = old,
        new_text = content,
    }, { approval = "danger" })
    if not edited or not edited.ok or edited.is_error then
        return false, result_error(edited, "edit_file failed")
    end
    return true
end

local function final_status(content)
    local line = tostring(content or ""):gsub("%s+$", ""):match("([^\r\n]*)$") or ""
    if line:match("^GOAL_STATUS:%s*done%s*$") then return "done" end
    local reason = line:match("^GOAL_STATUS:%s*blocked:%s*(.-)%s*$")
    if reason ~= nil then return "blocked", reason end
    if line:match("^GOAL_STATUS:%s*working%s*$") then return "working" end
    return nil
end

-- ---------------------------------------------------------------------------
-- before_turn: re-inject goal + procedure every turn
-- ---------------------------------------------------------------------------

bone.on("before_turn", function(_event, ctx)
    if bone.agent_depth ~= 0 then return end
    if not state.active or not state.path then return end

    local current_id = session_id(ctx)
    if current_id ~= state.session_id then
        state.active = false
        bone.log.warn("goal: conversation changed — loop halted")
        return
    end

    if ctx.fs.exists(state.path) ~= true then
        state.active = false
        bone.log.warn("goal: source file disappeared — loop halted: " .. state.path)
        return {
            turn_message = "The autonomous goal loop was halted because its source file no longer exists: "
                .. state.path .. ". Tell the user; do not continue the goal.",
        }
    end
    local ok, content = pcall(ctx.read_file, state.path)
    if not ok then
        state.active = false
        local err = tostring(content)
        bone.log.warn("goal: could not read source file — loop halted: " .. err)
        return {
            turn_message = "The autonomous goal loop was halted because its source file could not be read: "
                .. state.path .. " (" .. err .. "). Tell the user; do not continue the goal.",
        }
    end

    local append = string.format([==[
## Active Goal

You are in an autonomous goal loop (iteration %d). Your source of truth:

File: `%s`

%s

## Procedure (every turn)
1. Call read_file on the source file above, then re-read the goal, acceptance criteria, tasks, and progress.
2. If acceptance criteria are empty or vague, clarify scope first by calling the ask_user tool to ask the user about desired scope and any must-have requirements. Write the clarified scope into the Acceptance Criteria section.
3. Pick the next unchecked task (or acceptance criterion if all tasks are done).
4. Do the task.
5. Verify with relevant builds, tests, linters, manual checks, source inspection, or other evidence.
6. Update that exact source file via edit_file: check off completed items (replace [ ] with [x]).
7. Append a one-line Progress entry with a timestamp.
8. If ALL acceptance criteria are checked, verify the whole goal once more, then end your response with exactly: GOAL_STATUS: done
9. If you hit a genuine blocker you cannot resolve, end with: GOAL_STATUS: blocked: <reason>
10. Otherwise end with: GOAL_STATUS: working
]==], state.iteration, state.path, content)

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

    local status, reason = final_status(content)
    if status == "done" then
        state.active = false
        bone.log.info("goal: complete after " .. state.iteration .. " iterations")
        return
    elseif status == "blocked" then
        state.active = false
        bone.log.warn("goal: blocked — " .. (reason ~= "" and reason or "no reason given"))
        return
    end

    -- working or missing sentinel → continue
    bone.submit("Continue the goal.")
end)

-- ---------------------------------------------------------------------------
-- /goal command
-- ---------------------------------------------------------------------------

bone.command.register("goal", {
    description = "Start, resume, check, or stop an autonomous goal.",
    handler = function(args, ctx)
        local arg = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local current_id = session_id(ctx)
        local path = goal_path(ctx)
        if state.active and state.session_id ~= current_id then
            state.active = false
        end

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
            local ok, err = pcall(ctx.read_file, path)
            if not ok then
                return { display = "Could not read goal file: " .. tostring(err), submit = false }
            end
            activate(path, current_id)
            return "Resume the autonomous goal. Re-read the checklist, pick up where you left off, and follow the procedure in the turn message."
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

        -- /goal <description> — start new goal.
        state.active = false -- stop any existing loop first

        local md = build_md(arg)
        local saved, save_err = write_goal(ctx, path, md)
        if not saved then
            return {
                display = "Could not save goal file: " .. tostring(save_err),
                submit = false,
            }
        end

        activate(path, current_id)

        return string.format(
            "I've set up an autonomous goal. The checklist is at %s. " ..
            "Begin by clarifying scope if needed, then work through the checklist following the procedure in the turn message.",
            path)
    end,
})
