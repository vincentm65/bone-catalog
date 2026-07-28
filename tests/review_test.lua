-- Run with: lua tests/review_test.lua
local command

bone = {
  command = {
    register = function(name, spec)
      assert(name == "review")
      command = spec
    end,
  },
}

assert(loadfile("commands/review.lua"))()
assert(command)

local function shell_result(stdout, stderr, exit_code)
  return { stdout = stdout or "", stderr = stderr or "", exit_code = exit_code or 0 }
end

local function make_ctx(opts)
  opts = opts or {}
  local reads = {}
  local function shell(cmd)
    if opts.fail_command == cmd then return shell_result("", "forced failure", 1) end
    if cmd == "git rev-parse --is-inside-work-tree" then return shell_result("true\n") end
    if cmd == "git rev-parse --verify HEAD" then return shell_result("abc123\n") end
    if cmd == "git diff HEAD --no-color" then return shell_result(opts.diff or "") end
    if cmd == "git diff HEAD --stat --no-color" then return shell_result(opts.stat or "") end
    if cmd == "git diff HEAD --numstat -z --no-color" then return shell_result(opts.numstat or "") end
    if cmd == "git diff HEAD --name-only -z --no-color" then return shell_result(opts.names or "") end
    if cmd == "git ls-files --others --exclude-standard -z" then
      return shell_result(opts.untracked or "")
    end
    error("unexpected shell command: " .. cmd)
  end
  local files = opts.files or {}
  return {
    shell = shell,
    fs = {
      metadata = function(path)
        local file = assert(files[path], "missing metadata for " .. path)
        if file.metadata_error then error(file.metadata_error) end
        return { len = file.size or #(file.content or "") }
      end,
    },
    read_file = function(path)
      reads[#reads + 1] = path
      local file = assert(files[path], "unexpected read " .. path)
      if file.read_error then error(file.read_error) end
      return file.content
    end,
    ui = { notify = function() end },
    reads = reads,
  }
end

local diff = table.concat({
  "diff --git a/tracked.lua b/tracked.lua",
  "index 1111111..2222222 100644",
  "--- a/tracked.lua",
  "+++ b/tracked.lua",
  "@@ -1 +1 @@",
  "-old",
  "+new",
}, "\n")

local ctx = make_ctx({
  diff = diff,
  stat = " tracked.lua | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)",
  numstat = "1\t1\ttracked.lua\0",
  names = "tracked.lua\0",
  untracked = "small.txt\0large.bin\0",
  files = {
    ["small.txt"] = { content = "hello", size = 5 },
    ["large.bin"] = { content = string.rep("x", 10000), size = 10000 },
  },
})
local result = command.handler("", ctx)
assert(result.submit == true)
assert(result.display:find("hello", 1, true))
assert(result.display:find("large.bin", 1, true))
assert(table.concat(ctx.reads, ",") == "small.txt",
  "large untracked files must be classified by metadata without being read")

local unicode = "dir/a→b.lua"
ctx = make_ctx({
  diff = "diff --git \"a/dir/a\\342\\206\\222b.lua\" \"b/dir/a\\342\\206\\222b.lua\"\n"
    .. string.rep("+changed\n", 1001),
  stat = "1 file changed",
  numstat = "1001\t0\t" .. unicode .. "\0",
  names = unicode .. "\0",
})
result = command.handler("", ctx)
assert(result.display:find("`" .. unicode .. "`", 1, true),
  "NUL-delimited names must label quoted diff headers")
assert(not result.display:find("`diff --git", 1, true))
assert(not result.display:find("+changed", 1, true),
  "oversized diffs must be demoted whole rather than truncated mid-hunk")

local unsafe = "dir/a`\n\t\\b.lua"
ctx = make_ctx({
  diff = "diff --git a/placeholder b/placeholder\n+safe-path-marker",
  stat = "1 file changed",
  numstat = "1\t0\t" .. unsafe .. "\0",
  names = unsafe .. "\0",
})
result = command.handler("", ctx)
assert(result.display:find("dir/a\\x60\\x0A\\x09\\x5Cb.lua", 1, true),
  "backticks, control bytes, and backslashes in paths must use inert byte escapes")

ctx = make_ctx({ fail_command = "git ls-files --others --exclude-standard -z" })
result = command.handler("", ctx)
assert(result.submit == false)
assert(result.display:find("forced failure", 1, true),
  "required Git command errors must abort instead of silently omitting files")

local tracked = {}
local names = {}
local numstat = {}
for i = 1, 4 do
  local path = "f" .. i
  tracked[#tracked + 1] = "diff --git a/" .. path .. " b/" .. path .. "\n"
    .. string.rep("+x\n", 2300)
  names[#names + 1] = path .. "\0"
  numstat[#numstat + 1] = "2300\t0\t" .. path .. "\0"
end
local files, untracked = {}, {}
for i = 1, 12 do
  local path = "u" .. i
  files[path] = { content = string.rep("y", 3000), size = 3000 }
  untracked[#untracked + 1] = path .. "\0"
end
ctx = make_ctx({
  diff = table.concat(tracked),
  stat = "many files changed",
  names = table.concat(names),
  numstat = table.concat(numstat),
  untracked = table.concat(untracked),
  files = files,
})
result = command.handler("", ctx)
local inlined = 0
for _ in result.display:gmatch("full content") do inlined = inlined + 1 end
assert(inlined >= 10, "tracked diff bytes must not be double-counted against untracked files")
assert(#result.display <= 80000, "assembled review prompt should respect its exact total budget")

local huge_stat = {}
for i = 1, 5000 do
  huge_stat[i] = string.format(" file-%04d.lua | 100 %s", i, string.rep("+", 80))
end
ctx = make_ctx({
  diff = "diff --git a/budget.lua b/budget.lua\n+budget-end-marker",
  stat = table.concat(huge_stat, "\n"),
  numstat = "1\t0\tbudget.lua\0",
  names = "budget.lua\0",
})
result = command.handler("", ctx)
assert(#result.display <= 80000, "unbounded --stat output must not escape the prompt budget")
assert(result.display:find("additional --stat line(s) omitted", 1, true))
assert(result.display:find("+budget-end-marker", 1, true),
  "budgeting metadata must leave complete diff hunks available for review")

print("review command tests passed")
