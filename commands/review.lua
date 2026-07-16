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
    return nil, "Usage: /review [low|high]"
end

--- Split a full `git diff` output into per-file records {path, body}.
--- Scans line-by-line; a new record starts at each `diff --git` header.
--- Quoted paths (spaces/escapes) fall back to the raw header line as label.
local function split_diff(diff_text)
    local files = {}
    local current = nil
    for line in (diff_text .. "\n"):gmatch("(.-)\n") do
        local path = line:match('^diff %-%-git a/.* b/(.+)$')
        local header = line:match("^diff %-%-git ")
        if header then
            if current then
                current.diff = table.concat(current.lines, "\n")
                current.lines = nil
                files[#files + 1] = current
            end
            current = { path = path or line, lines = { line } }
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

--- Parse `git diff --numstat` into path -> "+X/-Y" (binary files show "-").
local function parse_numstat(numstat)
    local stats = {}
    for line in numstat:gmatch("[^\n]+") do
        local added, deleted, path = line:match("^(%S+)\t(%S+)\t(.+)$")
        if path then
            if added == "-" then
                stats[path] = "binary"
            else
                stats[path] = "+" .. added .. "/-" .. deleted
            end
        end
    end
    return stats
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

    local diff_parts, stat_parts, numstat_parts = {}, {}, {}
    for _, base in ipairs(bases) do
        local diff, derr = git(ctx, base .. " --no-color")
        if not diff then
            return nil, derr or "git diff failed"
        end
        local stat = git(ctx, base .. " --stat --no-color") or ""
        local numstat = git(ctx, base .. " --numstat --no-color") or ""
        if trim(diff) ~= "" then
            diff_parts[#diff_parts + 1] = diff
            stat_parts[#stat_parts + 1] = trim(stat)
            numstat_parts[#numstat_parts + 1] = trim(numstat)
        end
    end

    local files = split_diff(table.concat(diff_parts, "\n"))
    local stats = parse_numstat(table.concat(numstat_parts, "\n"))

    local untracked = {}
    local ls = git(ctx, "git ls-files --others --exclude-standard") or ""
    for path in ls:gmatch("[^\n]+") do
        local entry = { path = path }
        local rok, content = pcall(ctx.read_file, path)
        if not rok then
            entry.unreadable = true
        else
            entry.size = #content
            if content:sub(1, 8192):find("%z") then
                entry.binary = true
            else
                entry.content = content
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

local function build_prompt(effort, changes)
    local level = EFFORT[effort]
    local rules = PROMPT_TEMPLATE
        :gsub("{CONFIDENCE}", level.confidence)
        :gsub("{MAX_FINDINGS}", tostring(level.max_findings))

    local out = { rules }
    local total = #rules

    local function emit(text)
        out[#out + 1] = text
        total = total + #text
    end

    -- Change overview: --stat is small, always inlined in full.
    local overview = "\n\n## Change overview\n\n```\n"
        .. (changes.stat ~= "" and changes.stat or "(no tracked changes)")
        .. "\n```\nUntracked (new) files: " .. #changes.untracked
    emit(overview)

    -- Tracked diffs: inline within budgets; oversized or overflow files are
    -- demoted to read-yourself entries (never truncated mid-hunk).
    local read_yourself = {}
    local inlined = {}
    local inline_count = 0
    for _, f in ipairs(changes.files) do
        if f.binary then
            read_yourself[#read_yourself + 1] =
                "- `" .. f.path .. "` (binary — skipped, do not review)"
        else
            local block = "\n### " .. f.path .. "\n\n````diff\n" .. f.diff .. "\n````"
            if #f.diff <= PER_FILE_BUDGET
                and inline_count < MAX_FILES_INLINE
                and total + #block <= TOTAL_BUDGET
            then
                inlined[#inlined + 1] = block
                inline_count = inline_count + 1
                total = total + #block
            else
                local st = changes.stats[f.path]
                read_yourself[#read_yourself + 1] = string.format(
                    "- `%s` (%s — diff too large to inline)",
                    f.path, st or "large")
            end
        end
    end

    if #inlined > 0 then
        emit("\n\n## Diffs\n" .. table.concat(inlined, "\n"))
    end

    if #read_yourself > 0 then
        emit("\n\n## Files you must read yourself\n\n"
            .. "The following changed files are listed without a diff body. For each "
            .. "non-binary one, you MUST read the file (and run `git diff HEAD -- <path>` "
            .. "via shell if you need the exact hunks) before commenting on it. "
            .. "Never guess at its contents.\n\n"
            .. table.concat(read_yourself, "\n"))
    end

    -- Untracked files: small text files inlined in full, the rest listed.
    if #changes.untracked > 0 then
        local parts = {}
        for _, u in ipairs(changes.untracked) do
            if u.unreadable then
                parts[#parts + 1] = "- `" .. u.path .. "` (unreadable — skipped)"
            elseif u.binary then
                parts[#parts + 1] = "- `" .. u.path .. "` (binary — skipped, do not review)"
            elseif u.size <= UNTRACKED_INLINE and total + u.size <= TOTAL_BUDGET then
                local block = "- `" .. u.path .. "` (new file, full content):\n\n````\n"
                    .. u.content .. "\n````"
                parts[#parts + 1] = block
                total = total + #block
            else
                parts[#parts + 1] = string.format(
                    "- `%s` (new file, %d bytes — read it yourself before commenting)",
                    u.path, u.size)
            end
        end
        emit("\n\n## Untracked (new) files\n\n" .. table.concat(parts, "\n"))
    end

    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- /review command
-- ---------------------------------------------------------------------------

bone.command.register("review", {
    description = "Review uncommitted changes for real bugs (verification-first; /review [low|high])",
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
