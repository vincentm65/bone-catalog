-- /memory — quiet incremental memory builder.
--
-- Keeps global memory updated from prior user messages and maintains explicit
-- per-project preferences without turning the main chat into a memory-maintenance
-- turn. Cheap before_turn capture only queues explicit preference-like user
-- messages; model work happens when /memory is run.

local EXTRACT_BUDGET_CHARS = 80000
local MAX_MSG_CHARS = 4000
local MAX_INBOX_CHARS = 40000
local MEMORY_MAX_TOKENS = 500
local MEMORY_MAX_CHARS = 2000  -- ~4 chars/token approximation

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function status(ctx, message)
    if ctx.ui and ctx.ui.status then
        ctx.ui.status(message)
    end
end

local function split_words(arg)
    local words = {}
    for word in (arg or ""):gmatch("%S+") do
        words[#words + 1] = word
    end
    return words
end

local function truncate_utf8(s, max_bytes)
    if #s <= max_bytes then
        return s
    end
    local suffix = "..."
    local limit = math.max(0, max_bytes - #suffix)
    for cut = limit, math.max(limit - 4, 1), -1 do
        local chunk = s:sub(1, cut)
        local ok, len = pcall(utf8.len, chunk)
        if ok and len then
            return chunk .. suffix
        end
    end
    return suffix
end

local function project_key(cwd)
    local key = (cwd or "unknown"):gsub("[^%w%._%-]", "_")
    if #key > 96 then
        key = key:sub(#key - 95)
    end
    if key == "" then
        return "unknown"
    end
    return key
end

local function paths(ctx)
    local root = ctx.config_dir .. "/memory"
    return {
        root = root,
        global = root .. "/global.md",
        project = root .. "/projects/" .. project_key(ctx.cwd or bone.cwd) .. ".md",
        inbox = root .. "/inbox.jsonl",
        state = root .. "/state.json",
        legacy_memory = ctx.config_dir .. "/memory.md",
        legacy_last_run = ctx.config_dir .. "/memory.last_run",
    }
end

local function read_optional(ctx, path)
    if not ctx.fs.is_file(path) then
        return ""
    end
    local ok, content = pcall(ctx.read_file, path)
    if ok and content then
        return content
    end
    return ""
end

local function read_scoped_or_legacy(ctx, scoped_path, legacy_path)
    if ctx.fs.is_file(scoped_path) then
        return read_optional(ctx, scoped_path)
    end
    return read_optional(ctx, legacy_path)
end

local function write_or_rewrite(ctx, path, content)
    if not ctx.fs.is_file(path) then
        local ok, err = pcall(ctx.write_file, path, content)
        return ok, err
    end
    local read = ctx.tools.call("read_file", { path = path }, { approval = "read_only" })
    if not read or not read.ok then
        return false, "read_file failed"
    end
    local old = ctx.read_file(path)
    local res = ctx.tools.call("edit_file", {
        path = path,
        old_text = old,
        new_text = content,
    }, { approval = "danger" })
    return res and res.ok, res and res.content or "edit_file failed"
end

local function state_read(ctx, p)
    local raw = read_optional(ctx, p.state)
    if raw == "" then
        local legacy = trim(read_optional(ctx, p.legacy_last_run))
        return { last_conversation_id = 0, last_started_at = legacy ~= "" and legacy or nil }
    end
    local ok, parsed = pcall(cjson.decode, raw)
    if ok and type(parsed) == "table" then
        parsed.last_conversation_id = tonumber(parsed.last_conversation_id) or 0
        return parsed
    end
    return { last_conversation_id = 0 }
end

local function state_write(ctx, p, state)
    state.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    return write_or_rewrite(ctx, p.state, cjson.encode(state) .. "\n")
end

local function user_message_lines(ctx, cid)
    local msg_ok, msg_rows = pcall(ctx.db.query,
        "SELECT role, content FROM messages WHERE conversation_id = ? "
        .. "AND role = 'user' AND tool_name IS NULL ORDER BY seq ASC",
        { cid })
    if not msg_ok or type(msg_rows) ~= "table" then
        return nil, tostring(msg_rows or "invalid message query result")
    end
    local lines = {}
    for _, msg in ipairs(msg_rows) do
        local content = truncate_utf8(msg.content or "", MAX_MSG_CHARS)
        lines[#lines + 1] = "[user] " .. content
    end
    return lines
end

local function extraction_prompt(transcript)
    return table.concat({
        "You are distilling durable global user preferences from prior user messages.",
        "",
        "Extract ONLY stable global preferences such as communication style, coding style, tools/workflow, and dislikes.",
        "",
        "Rules:",
        "- Output terse bullets, one signal per line, prefixed with '- '.",
        "- Ignore project-specific conventions, one-off task details, and incidental remarks.",
        "- Treat only user messages as evidence.",
        "- If there is nothing durable worth remembering, output exactly: NONE",
        "",
        "--- User messages ---",
        transcript,
    }, "\n")
end

local function extract(ctx, transcript)
    status(ctx, "Memory: distilling conversation history…")
    local run_result = ctx.agent.run(extraction_prompt(transcript), { timeout_ms = 120000 })
    if not run_result.ok then
        local err = run_result.error or "unknown"
        ctx.log.warn("memory: extraction failed: " .. err)
        return false, nil, err
    end
    local content = trim(run_result.content or "")
    if content == "" or content:upper() == "NONE" then
        return true, nil, nil
    end
    return true, content, nil
end

local function merge_prompt(current_global, current_project, findings, inbox, cwd)
    return table.concat({
        "You update the assistant memory files. Output only the two replacement files between exact markers.",
        "",
        "Current cwd: " .. (cwd or "unknown"),
        "",
        "Rules:",
        "- Historical findings are global-only; never use them to change project memory.",
        "- Global memory: stable user preferences only; no project-specific facts.",
        "- Project memory may change only from inbox entries with scope=project for this cwd.",
        "- Inbox entries with scope=global or no scope may change global memory only.",
        "- Ignore project-scoped inbox entries whose cwd does not match the current cwd.",
        "- Add only clear durable signals. Prefer repeated/corrective signals over one-offs.",
        "- Remove contradicted/stale items.",
        "- Keep each file under " .. MEMORY_MAX_TOKENS .. " tokens (~" .. MEMORY_MAX_CHARS .. " chars).",
        "- Start each non-empty file with: <!-- last_updated: YYYY-MM-DD -->",
        "- Use concise markdown sections. Drop empty sections.",
        "- If a file should stay empty, leave its marker body empty.",
        "",
        "--- CURRENT_GLOBAL ---",
        current_global,
        "--- CURRENT_PROJECT ---",
        current_project,
        "--- FINDINGS ---",
        findings,
        "--- INBOX ---",
        inbox,
        "--- OUTPUT FORMAT ---",
        "---GLOBAL---",
        "<global markdown>",
        "---PROJECT---",
        "<project markdown>",
        "---END---",
    }, "\n")
end

local function enforce_cap(content)
    if #content <= MEMORY_MAX_CHARS then
        return content
    end
    local header = "<!-- last_updated: " .. os.date("%Y-%m-%d") .. " -->"
    local budget = MEMORY_MAX_CHARS - #header - 1
    local body = content:gsub("^<!%-%-.-%-%->\n?", "")
    return header .. "\n" .. truncate_utf8(body, budget)
end

local function parse_merge_output(content)
    local global = content:match("%-%-%-GLOBAL%-%-%-\n(.-)\n%-%-%-PROJECT%-%-%-")
    local project = content:match("%-%-%-PROJECT%-%-%-\n(.-)\n%-%-%-END%-%-%-")
    if global == nil or project == nil then
        return nil, nil
    end
    return trim(global), trim(project)
end

local function final_merge(ctx, p, findings_text, inbox_text)
    local current_global = read_scoped_or_legacy(ctx, p.global, p.legacy_memory)
    local current_project = read_optional(ctx, p.project)

    status(ctx, "Memory: updating scoped memory…")
    local result = ctx.agent.run(
        merge_prompt(current_global, current_project, findings_text, inbox_text, ctx.cwd),
        { timeout_ms = 120000 })
    if not result.ok then
        return false, "merge failed: " .. (result.error or "unknown")
    end

    local new_global, new_project = parse_merge_output(result.content or "")
    if new_global == nil then
        return false, "merge output missing markers"
    end
    new_global = enforce_cap(new_global)
    new_project = enforce_cap(new_project)

    local changed = false
    if trim(current_global) ~= new_global then
        local ok, err = write_or_rewrite(ctx, p.global, new_global ~= "" and (new_global .. "\n") or "")
        if not ok then
            return false, tostring(err)
        end
        changed = true
    end
    if trim(current_project) ~= new_project then
        local ok, err = write_or_rewrite(ctx, p.project, new_project ~= "" and (new_project .. "\n") or "")
        if not ok then
            return false, tostring(err)
        end
        changed = true
    end

    return true, changed and "Memory updated." or "No changes."
end

local function load_inbox(ctx, p)
    local inbox = read_optional(ctx, p.inbox)
    if #inbox > MAX_INBOX_CHARS then
        inbox = inbox:sub(#inbox - MAX_INBOX_CHARS + 1)
    end
    return inbox
end

local function clear_inbox(ctx, p)
    if not ctx.fs.is_file(p.inbox) then
        return true
    end
    return write_or_rewrite(ctx, p.inbox, "")
end

local function append_inbox(ctx, p, content, scope, source)
    local old = read_optional(ctx, p.inbox)
    local entry = cjson.encode({
        ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        cwd = ctx.cwd,
        content = content,
        scope = scope,
        source = source,
    }) .. "\n"
    return write_or_rewrite(ctx, p.inbox, old .. entry)
end

local function memory_prompt(ctx, p)
    local global = trim(read_scoped_or_legacy(ctx, p.global, p.legacy_memory))
    local project = trim(read_optional(ctx, p.project))
    local sections = {}
    if global ~= "" then
        sections[#sections + 1] = "## Global\n" .. truncate_utf8(global, MEMORY_MAX_CHARS)
    end
    if project ~= "" then
        sections[#sections + 1] = "## Current project\n" .. truncate_utf8(project, MEMORY_MAX_CHARS)
    end
    if #sections == 0 then
        return nil
    end
    return "# User Memory\nThe following scoped preferences were extracted from past conversations:\n\n"
        .. table.concat(sections, "\n\n")
end

local function show_memory(ctx, p)
    local prompt = memory_prompt(ctx, p)
    return prompt or "No memory saved for global or current project."
end

local function parse_remember(arg)
    local text = trim(arg or "")
    if text == "" then
        return nil, nil, "Usage: /memory remember [--global|--project] <text>"
    end
    local scope
    if text:find("^%-%-global%s+") then
        scope = "global"
        text = trim(text:gsub("^%-%-global%s+", "", 1))
    elseif text:find("^%-%-project%s+") then
        scope = "project"
        text = trim(text:gsub("^%-%-project%s+", "", 1))
    end
    if text == "" then
        return nil, nil, "Usage: /memory remember [--global|--project] <text>"
    end
    return text, scope, nil
end

local function capture_candidate(text)
    local lower = text:lower()
    local patterns = {
        "remember", "forget", "always", "never", "i prefer", "i like", "i hate",
        "don't", "do not", "stop", "instead", "going forward"
    }
    for _, pat in ipairs(patterns) do
        if lower:find(pat, 1, true) then
            return true
        end
    end
    return false
end

bone.on("before_turn", function(_, ctx)
    local p = paths(ctx)
    local history = ctx.conversation.history()
    if type(history) == "table" and #history > 0 then
        local msg = history[#history]
        if msg and msg.role == "user" then
            local content = trim(msg.content or "")
            if content ~= "" and #content <= 2000 and capture_candidate(content) then
                local ok, err = append_inbox(ctx, p, content, nil, "before_turn")
                if not ok then
                    ctx.log.warn("memory: inbox append failed: " .. tostring(err))
                end
            end
        end
    end
    return { system_prompt_append = memory_prompt(ctx, p) }
end)

bone.command.register("memory", {
    description = "Update global memory from recent user messages and explicit scoped preferences.",
    handler = function(arg, ctx)
        local p = paths(ctx)
        local words = split_words(arg)
        local subcmd = words[1] and words[1]:lower() or ""

        if subcmd == "show" or subcmd == "view" or subcmd == "list" then
            return { display = show_memory(ctx, p), submit = false }
        end

        if subcmd == "remember" then
            local rest = trim((arg or ""):gsub("^%s*%S+", "", 1))
            local text, scope, usage = parse_remember(rest)
            if not text then
                return { display = usage, submit = false }
            end
            local ok, err = append_inbox(ctx, p, text, scope, "manual")
            if not ok then
                return { display = "Memory error: " .. tostring(err), submit = false }
            end
        elseif subcmd ~= "" then
            return { display = "Usage: /memory [show|view|list|remember [--global|--project] <text>]", submit = false }
        end

        status(ctx, "Memory: finding new conversations…")
        local state = state_read(ctx, p)

        local cids_ok, cids_rows
        if state.last_conversation_id and state.last_conversation_id > 0 then
            cids_ok, cids_rows = pcall(ctx.db.query,
                "SELECT id, started_at FROM conversations WHERE id > ? ORDER BY id ASC",
                { state.last_conversation_id })
        elseif state.last_started_at then
            cids_ok, cids_rows = pcall(ctx.db.query,
                "SELECT id, started_at FROM conversations WHERE started_at > ? ORDER BY id ASC",
                { state.last_started_at })
        else
            cids_ok, cids_rows = pcall(ctx.db.query,
                "SELECT id, started_at FROM conversations ORDER BY id ASC", {})
        end

        if not cids_ok or type(cids_rows) ~= "table" then
            return { display = "Error querying conversations: " .. tostring(cids_rows), submit = false }
        end
        status(ctx, string.format("Memory: processing %d new conversation(s)…", #cids_rows))

        local findings = {}
        local pending = {}
        local pending_chars = 0
        local max_id = state.last_conversation_id or 0
        local extraction_error

        local function distill(transcript)
            local extract_ok, distilled, err = extract(ctx, transcript)
            if not extract_ok then
                extraction_error = err or "unknown"
                return false
            end
            if distilled then
                findings[#findings + 1] = distilled
            end
            return true
        end

        local function flush_pending()
            if pending_chars == 0 then return true end
            local transcript = table.concat(pending, "\n")
            pending = {}
            pending_chars = 0
            return distill(transcript)
        end

        for _, row in ipairs(cids_rows) do
            if extraction_error then break end
            local cid = tonumber(row.id) or 0
            if cid > max_id then
                max_id = cid
            end
            local lines, lines_err = user_message_lines(ctx, cid)
            if lines_err then
                extraction_error = "could not read conversation " .. tostring(cid) .. ": " .. lines_err
                break
            end
            if lines and #lines > 0 then
                local header = "## Conversation " .. tostring(cid)
                local body = header .. "\n" .. table.concat(lines, "\n")
                if #body > EXTRACT_BUDGET_CHARS then
                    if not flush_pending() then break end
                    local chunk = { header }
                    local chunk_chars = #header
                    for _, line in ipairs(lines) do
                        if chunk_chars + #line + 1 > EXTRACT_BUDGET_CHARS and #chunk > 1 then
                            if not distill(table.concat(chunk, "\n")) then break end
                            chunk = { header }
                            chunk_chars = #header
                        end
                        chunk[#chunk + 1] = line
                        chunk_chars = chunk_chars + #line + 1
                    end
                    if not extraction_error and #chunk > 1
                        and not distill(table.concat(chunk, "\n")) then
                        break
                    end
                else
                    if pending_chars + #body + 1 > EXTRACT_BUDGET_CHARS
                        and not flush_pending() then
                        break
                    end
                    pending[#pending + 1] = body
                    pending_chars = pending_chars + #body + 1
                end
            end
        end
        if not extraction_error then
            flush_pending()
        end
        if extraction_error then
            return {
                display = "Memory processing failed; checkpoint and inbox unchanged: " .. extraction_error,
                submit = false,
            }
        end

        local inbox_text = load_inbox(ctx, p)
        if #findings == 0 and trim(inbox_text) == "" then
            state.last_conversation_id = max_id
            status(ctx, "Memory: saving checkpoint…")
            local state_ok, state_err = state_write(ctx, p, state)
            if not state_ok then
                return { display = "Memory checkpoint failed: " .. tostring(state_err), submit = false }
            end
            return { display = string.format("Processed %d conversation(s). No durable preferences found.", #cids_rows), submit = false }
        end

        local ok, message = final_merge(ctx, p, table.concat(findings, "\n\n"), inbox_text)
        if not ok then
            return { display = "Memory error: " .. tostring(message), submit = false }
        end

        state.last_conversation_id = max_id
        status(ctx, "Memory: saving checkpoint…")
        local state_ok, state_err = state_write(ctx, p, state)
        if not state_ok then
            return { display = "Memory updated, but checkpoint failed: " .. tostring(state_err), submit = false }
        end
        local inbox_ok, inbox_err = clear_inbox(ctx, p)
        if not inbox_ok then
            return { display = "Memory updated, but inbox clear failed: " .. tostring(inbox_err), submit = false }
        end
        return { display = message, submit = false }
    end,
})
