-- /review [low|high] — review uncommitted changes (staged, unstaged, and
-- untracked) with a verification-first prompt engineered against hallucinated
-- findings and nit spam.
--
-- Diffs are never truncated mid-hunk: files whose diff exceeds the per-file
-- budget are listed for the model to read itself with its own tools instead
-- of shipping a mangled diff.
--
-- Requires: ctx.shell, ctx.read_file, ctx.ui.notify, submit=true to trigger LLM.

-- ---------------------------------------------------------------------------
-- Budgets (chars; ~4 chars/token)
-- ---------------------------------------------------------------------------

local TOTAL_BUDGET     = 80000 -- whole submitted prompt (~20k tokens)
local OVERVIEW_BUDGET  = 12000 -- keep pathological --stat output from crowding out diffs
local PER_FILE_BUDGET  = 8000  -- max inlined diff per file
local UNTRACKED_INLINE = 4000  -- untracked files smaller than this are inlined
local MAX_FILES_INLINE = 30    -- beyond this, remaining files become read-yourself

-- ---------------------------------------------------------------------------
-- Effort levels
-- ---------------------------------------------------------------------------

local EFFORT = {
    low = {
        confidence = "only report defects you are near-certain about — ones you would block a merge over",
        max_findings = 5,
    },
    medium = {
        confidence = "only report findings you would personally flag in a real PR review",
        max_findings = 10,
    },
    high = {
        confidence = "report anything you would at least leave a comment on in a careful PR review; still no style nits",
        max_findings = 20,
    },
}

-- ---------------------------------------------------------------------------
-- Review prompt template
-- ---------------------------------------------------------------------------

local PROMPT_TEMPLATE = [[You are performing a code review of the local uncommitted changes (staged, unstaged, and new files) shown below.

## Ground rules — read carefully

1. VERIFY BEFORE YOU REPORT. Before flagging anything, use your read_file/grep/shell tools to read enough surrounding code to confirm the problem is real: check how the function is called, what invariants hold, whether the "missing" handling exists elsewhere. A finding you have not verified against the actual code must not appear in your report.
2. CONFIDENCE THRESHOLD: {CONFIDENCE}. If you are unsure whether something is a bug, either verify it by reading the code or drop it. Do not pad the review.
3. REPORT AT MOST {MAX_FINDINGS} FINDINGS, ordered by severity. If you find more, keep only the most important.
4. If, after genuinely reading the changes, nothing meets the bar, say so plainly in the Assessment and write "None." under Top issues. That is a good outcome, not a failure. Do not invent findings to appear thorough.

## In scope

- Logic errors: wrong conditions, off-by-one, inverted checks, unhandled cases the surrounding code clearly expects to be handled
- Crashes / correctness: nil or null dereference, unchecked errors on paths that matter, resource leaks, races
- Regressions: behavior the diff changes in a way that breaks existing callers (verify by finding the callers)
- Security: injection, path traversal, committed secrets — only when concretely present in this diff
- Dead code introduced by this change (provably unreachable)

## Explicitly OUT of scope — do not report

- Style, formatting, naming preferences, comment wording
- Subjective architecture opinions ("I would have structured this as...")
- Speculative issues ("this might be a problem if...") — if you cannot demonstrate the failing case from the code, it does not go in the report
- Missing tests, missing docs
- Problems in code the diff does not touch, unless the diff directly breaks it

## Output format

Use exactly these sections, in this order:

## Review report

| File reviewed | Diff stat | Issues |
|---|---:|---:|
| `path/to/file.ext` | +X/-Y | N |

- Include one row for every text file you actually reviewed. Use the supplied diff stats where available; use `new file` for untracked files. Do not invent counts.
- `Issues` is the number of findings from that file included under Top issues.

## Assessment

Write one concise paragraph of 3-5 sentences maximum summarizing the overall quality, risk, and what was verified. If there are no findings, state "No significant issues found."

## Top issues

List findings in descending severity. For each finding:

### [SEVERITY] one-line summary

- SEVERITY is one of: CRITICAL (data loss, security, guaranteed crash), BUG (incorrect behavior), QUESTION (looks wrong but you could not fully confirm — use sparingly)
- **Location:** `path/to/file.ext:LINE` (exact line in the new version)
- **Code:** quote the exact offending lines from the file (not paraphrased)
- **Problem:** what breaks, and the concrete scenario in which it breaks
- **Fix:** the minimal correction, briefly

If there are no findings, write only "None." under Top issues.]]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Run a git command; returns trimmed stdout, or nil + stderr on failure.
local function git(ctx, cmd)
    local result = ctx.shell(cmd, { timeout_ms = 60000 })
    if result.exit_code ~= 0 then
        return nil, trim(result.stderr ~= "" and result.stderr or result.stdout)
    end
    return result.stdout
end

local function parse_effort(args)
    local arg = trim(args):lower()
    if arg == "" then
        return "medium"
    end
    if EFFORT[arg] then
        return arg
    end
    return nil, "Usage: /review [low|medium|high]"
end

local function split_nul(text)
    local values = {}
    for value in tostring(text or ""):gmatch("([^%z]+)%z") do
        values[#values + 1] = value
    end
    return values
end

local function display_path(path)
    local out = {}
    local value = tostring(path or "")
    for i = 1, #value do
        local byte = value:byte(i)
        if byte < 32 or byte == 127 or byte == 96 or byte == 92 then
            out[#out + 1] = string.format("\\x%02X", byte)
        else
            out[#out + 1] = value:sub(i, i)
        end
    end
    return table.concat(out)
end

--- Split a full `git diff` output into per-file records {path, diff}.
--- Scans line-by-line; a new record starts at each `diff --git` header.
--- `paths` comes from `git diff --name-only -z`, avoiding header quoting.
local function split_diff(diff_text, paths)
    local files = {}
    local current = nil
    local path_index = 0
    for line in (diff_text .. "\n"):gmatch("(.-)\n") do
        local header = line:match("^diff %-%-git ")
        if header then
            if current then
                current.diff = table.concat(current.lines, "\n")
                current.lines = nil
                files[#files + 1] = current
            end
            path_index = path_index + 1
            current = {
                path = paths[path_index] or line:match('^diff %-%-git a/.* b/(.+)$') or line,
                lines = { line },
            }
        elseif current then
            current.lines[#current.lines + 1] = line
        end
    end
    if current then
        current.diff = table.concat(current.lines, "\n")
        current.lines = nil
        files[#files + 1] = current
    end
    for _, f in ipairs(files) do
        f.binary = f.diff:find("\nBinary files ") ~= nil
            or f.diff:find("\nGIT binary patch") ~= nil
    end
    return files
end

local function next_nul(text, start)
    local finish = text:find("\0", start, true)
    if not finish then return nil, #text + 1 end
    return text:sub(start, finish - 1), finish + 1
end

--- Parse `git diff --numstat -z` into path -> "+X/-Y".
--- Rename/copy records encode an empty path followed by old and new paths.
local function parse_numstat(numstat)
    local stats = {}
    local cursor = 1
    while cursor <= #numstat do
        local record
        record, cursor = next_nul(numstat, cursor)
        if not record then break end
        local added, deleted, path = record:match("^([^\t]+)\t([^\t]+)\t(.*)$")
        if path == "" then
            local _old
            _old, cursor = next_nul(numstat, cursor)
            path, cursor = next_nul(numstat, cursor)
        end
        if path and path ~= "" then
            if added == "-" then
                stats[path] = "binary"
            else
                stats[path] = "+" .. added .. "/-" .. deleted
            end
        end
    end
    return stats
end

local function merge_map(into, values)
    for key, value in pairs(values) do into[key] = value end
end

local function append_all(into, values)
    for _, value in ipairs(values) do into[#into + 1] = value end
end

local function error_text(err)
    local message = trim(tostring(err or "unknown error")):gsub("[%c]+", " ")
    if #message > 200 then message = message:sub(1, 197) .. "..." end
    return message
end

--- Gather staged + unstaged + untracked changes. Returns a table
--- { stat, stats, files = {{path, diff, binary}}, untracked = {{path, size,
---   content?, binary?, unreadable?}} } or nil + error message.
local function collect_changes(ctx)
    local ok, err = git(ctx, "git rev-parse --is-inside-work-tree")
    if not ok then
        return nil, "not a git repository (" .. (err or "?") .. ")"
    end

    -- Fresh repos (no commits) have no HEAD to diff against; fall back to
    -- diffing the index and worktree separately.
    local bases
    if git(ctx, "git rev-parse --verify HEAD") then
        bases = { "git diff HEAD" }
    else
        bases = { "git diff --cached", "git diff" }
    end

    local files, stats, stat_parts = {}, {}, {}
    for _, base in ipairs(bases) do
        local diff, derr = git(ctx, base .. " --no-color")
        if not diff then
            return nil, derr or "git diff failed"
        end
        local stat, serr = git(ctx, base .. " --stat --no-color")
        if not stat then return nil, serr or "git diff --stat failed" end
        local numstat, nerr = git(ctx, base .. " --numstat -z --no-color")
        if not numstat then return nil, nerr or "git diff --numstat failed" end
        local names, name_err = git(ctx, base .. " --name-only -z --no-color")
        if not names then return nil, name_err or "git diff --name-only failed" end
        if trim(diff) ~= "" then
            stat_parts[#stat_parts + 1] = trim(stat)
            append_all(files, split_diff(diff, split_nul(names)))
            merge_map(stats, parse_numstat(numstat))
        end
    end

    local untracked = {}
    local ls, lerr = git(ctx, "git ls-files --others --exclude-standard -z")
    if not ls then return nil, lerr or "git ls-files failed" end
    for _, path in ipairs(split_nul(ls)) do
        local entry = { path = path }
        local should_read = true
        if ctx.fs and ctx.fs.metadata then
            local mok, metadata = pcall(ctx.fs.metadata, path)
            if not mok or type(metadata) ~= "table" then
                entry.unreadable = true
                entry.error = error_text(metadata)
                should_read = false
            else
                entry.size = tonumber(metadata.len) or 0
                should_read = entry.size <= UNTRACKED_INLINE
            end
        end
        if should_read then
            local rok, content = pcall(ctx.read_file, path)
            if not rok then
                entry.unreadable = true
                entry.error = error_text(content)
            else
                entry.size = #content
                if content:sub(1, 8192):find("%z") then
                    entry.binary = true
                else
                    entry.content = content
                end
            end
        end
        untracked[#untracked + 1] = entry
    end

    return {
        stat = trim(table.concat(stat_parts, "\n")),
        stats = stats,
        files = files,
        untracked = untracked,
    }
end

-- ---------------------------------------------------------------------------
-- Prompt assembly
-- ---------------------------------------------------------------------------

local function split_lines(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function render_list(prefix, items, kept, omitted, suffix, note_for)
    local body = {}
    for i = 1, kept do body[#body + 1] = items[i] end
    if omitted > 0 then body[#body + 1] = note_for(omitted) end
    return prefix .. table.concat(body, "\n") .. (suffix or "")
end

--- Fit a prefix, ordered atomic items, an omission note, and suffix into
--- `budget`. Items are never truncated and only a contiguous prefix is kept.
local function bounded_list(prefix, items, suffix, budget, note_for)
    suffix = suffix or ""
    if #prefix + #suffix > budget then return nil, 0, #items end

    local kept, body_size = 0, 0
    for i, item in ipairs(items) do
        local next_size = body_size + (kept > 0 and 1 or 0) + #item
        local remaining = #items - i
        local note_size = remaining > 0 and (1 + #note_for(remaining)) or 0
        if #prefix + next_size + note_size + #suffix <= budget then
            kept = i
            body_size = next_size
        else
            break
        end
    end

    local omitted = #items - kept
    while omitted > 0 do
        local note_size = #note_for(omitted) + (kept > 0 and 1 or 0)
        if #prefix + body_size + note_size + #suffix <= budget then break end
        if kept == 0 then return nil, 0, #items end
        body_size = body_size - #items[kept] - (kept > 1 and 1 or 0)
        kept = kept - 1
        omitted = #items - kept
    end

    return render_list(prefix, items, kept, omitted, suffix, note_for), kept, omitted
end

local function build_prompt(effort, changes)
    local level = EFFORT[effort]
    local rules = PROMPT_TEMPLATE
        :gsub("{CONFIDENCE}", level.confidence)
        :gsub("{MAX_FINDINGS}", tostring(level.max_findings))

    local out = { rules }
    local total = #rules

    local function emit(text)
        if not text or total + #text > TOTAL_BUDGET then return false end
        out[#out + 1] = text
        total = total + #text
        return true
    end

    -- Change overview: stat lines are atomic, but pathological output is
    -- summarized so it cannot consume the entire review prompt.
    local stat_lines = changes.stat ~= "" and split_lines(changes.stat)
        or { "(no tracked changes)" }
    local overview = bounded_list(
        "\n\n## Change overview\n\n```\n",
        stat_lines,
        "\n```\nUntracked (new) files: " .. #changes.untracked,
        math.min(OVERVIEW_BUDGET, TOTAL_BUDGET - total),
        function(omitted)
            return string.format(
                "... %d additional --stat line(s) omitted; run `git diff --stat` to inspect them.",
                omitted)
        end)
    emit(overview)

    -- Tracked diffs: inline within budgets; oversized or overflow files are
    -- demoted to read-yourself entries (never truncated mid-hunk).
    local read_yourself = {}
    local inlined = {}
    local inline_count = 0
    local inline_size = #"\n\n## Diffs\n\n"
    for _, f in ipairs(changes.files) do
        local label = display_path(f.path)
        if f.binary then
            read_yourself[#read_yourself + 1] =
                "- `" .. label .. "` (binary — skipped, do not review)"
        else
            local block = "### " .. label .. "\n\n````diff\n" .. f.diff .. "\n````"
            local separator = #inlined > 0 and 2 or 0
            if #f.diff <= PER_FILE_BUDGET
                and inline_count < MAX_FILES_INLINE
                and total + inline_size + separator + #block <= TOTAL_BUDGET
            then
                inlined[#inlined + 1] = block
                inline_count = inline_count + 1
                inline_size = inline_size + separator + #block
            else
                local st = changes.stats[f.path]
                read_yourself[#read_yourself + 1] = string.format(
                    "- `%s` (%s — diff not inlined)",
                    label, st or "large")
            end
        end
    end

    if #inlined > 0 then
        emit("\n\n## Diffs\n\n" .. table.concat(inlined, "\n\n"))
    end

    if #read_yourself > 0 then
        local section = bounded_list(
            "\n\n## Files you must read yourself\n\n"
                .. "The following changed files are listed without a diff body. For each "
                .. "non-binary one, you MUST read the file and use `git diff -- <path>` plus "
                .. "`git diff --cached -- <path>` when you need exact hunks before commenting. "
                .. "Never guess at its contents.\n\n",
            read_yourself,
            "",
            TOTAL_BUDGET - total,
            function(omitted)
                return string.format(
                    "- ... %d additional changed file(s); run Git status/diff commands to inspect them.",
                    omitted)
            end)
        emit(section)
    end

    -- First fit compact metadata for as many untracked files as possible, then
    -- spend remaining room upgrading small text files to full-content blocks.
    if #changes.untracked > 0 then
        local items, full_content = {}, {}
        local prefix = "\n\n## Untracked (new) files\n\n"
        for _, u in ipairs(changes.untracked) do
            local label = display_path(u.path)
            local size = tonumber(u.size) or #(u.content or "")
            if u.unreadable then
                items[#items + 1] =
                    "- `" .. label .. "` (unreadable: " .. (u.error or "unknown error") .. " — skipped)"
            elseif u.binary then
                items[#items + 1] = "- `" .. label .. "` (binary — skipped, do not review)"
            else
                items[#items + 1] = string.format(
                    "- `%s` (new file, %d bytes — read it yourself before commenting)",
                    label, size)
            end
            if not u.unreadable and not u.binary and u.content and size <= UNTRACKED_INLINE then
                full_content[#items] = "- `" .. label .. "` (new file, full content):\n\n````\n"
                    .. u.content .. "\n````"
            end
        end

        local note_for = function(omitted)
            return string.format(
                "- ... %d additional untracked file(s); run `git ls-files --others --exclude-standard` to inspect them.",
                omitted)
        end
        local budget = TOTAL_BUDGET - total
        local section, kept, omitted = bounded_list(prefix, items, "", budget, note_for)
        if section then
            local section_size = #section
            for i = 1, kept do
                local full = full_content[i]
                if full then
                    local delta = #full - #items[i]
                    if delta <= 0 or section_size + delta <= budget then
                        items[i] = full
                        section_size = section_size + delta
                    end
                end
            end
            emit(render_list(prefix, items, kept, omitted, "", note_for))
        end
    end

    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- /review command
-- ---------------------------------------------------------------------------

bone.command.register("review", {
    description = "Review uncommitted changes for real bugs (verification-first; /review [low|medium|high])",
    handler = function(args, ctx)
        local effort, uerr = parse_effort(args)
        if not effort then
            return { display = uerr, submit = false }
        end

        local changes, cerr = collect_changes(ctx)
        if not changes then
            ctx.ui.notify("review: " .. cerr, "error")
            return { display = "Review aborted: " .. cerr, submit = false }
        end

        if #changes.files == 0 and #changes.untracked == 0 then
            return {
                display = "Working tree is clean — nothing to review.",
                submit = false,
                display_role = "assistant",
            }
        end

        return { display = build_prompt(effort, changes), submit = true }
    end,
})
