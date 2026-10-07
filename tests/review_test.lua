-- Standalone checks against real Git, without model credentials.
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. quote(root)))
local function write(path, text)
  local f = assert(io.open(root .. "/" .. path, "wb")); f:write(text); f:close()
end
local hooks, calls, cancelled = {}, {}, false
bone = {
  hook = function(name, fn) hooks[name] = fn end,
  system = function(cmd, opts)
    assert(type(cmd) == "string" and opts.timeout == 60000)
    calls[#calls + 1] = cmd
    if cancelled then return nil end
    local errpath = root .. "-stderr"
    local pipe = assert(io.popen("cd " .. quote(opts.cwd) .. " && " .. cmd .. " 2>" .. quote(errpath)))
    local stdout = pipe:read("*a")
    local ok, _, code = pipe:close()
    local f = assert(io.open(errpath)); local stderr = f:read("*a"); f:close(); os.remove(errpath)
    return { code = ok and 0 or code, stdout = stdout, stderr = stderr }
  end,
}
dofile("plugins/review/core.lua")
local function git(args)
  assert(os.execute("cd " .. quote(root) .. " && git " .. args .. " >/dev/null 2>&1"))
end
local function start(text, id, cwd)
  return hooks.turn_start({ session_id = id or "a", cwd = cwd or root, text = text })
end
local function prompt(id)
  local r = hooks.system({ session_id = id or "a", prompt = "original" })
  return r and r.prompt
end
local function contains(text, value) return text:find(value, 1, true) ~= nil end
git("init -b main"); git("config user.email test@example.com"); git("config user.name Test")
write("tracked.lua", "before\n"); git("add tracked.lua"); git("commit -m initial"); git("branch baseline")
write("committed.lua", "committed\n"); git("add committed.lua"); git("commit -m next")
write("staged.lua", "staged-only\n"); git("add staged.lua")
write("tracked.lua", "after\n")
local odd = "odd ' $(touch HACKED) [x].lua"
write(odd, "safe full untracked content\n")
write("binary.dat", "a\0b")
write("large.txt", string.rep("x", 4001))
assert(start("/review") == nil)
local p = assert(prompt())
assert(contains(p, "VERIFY BEFORE YOU REPORT") and contains(p, "REPORT AT MOST 10 FINDINGS"))
assert(contains(p, "## Review report") and contains(p, "## Assessment") and contains(p, "## Top issues"))
assert(contains(p, "only report findings you would personally flag in a real PR review"))
assert(contains(p, "tracked.lua (+1/-1)") and contains(p, "+after"))
assert(contains(p, "safe full untracked content") and contains(p, odd))
assert(contains(p, "binary — skipped") and contains(p, "4001 bytes — read it yourself"))
assert(not contains(p, "staged.lua") and not contains(p, "committed.lua"))
assert(not io.open(root .. "/HACKED"))
assert(prompt("other") == nil)
for effort, count in pairs({ low = 5, medium = 10, high = 20 }) do
  assert(start("/review " .. effort) == nil)
  assert(contains(prompt(), "REPORT AT MOST " .. count .. " FINDINGS"))
end
assert(start("/review baseline high", "b") == nil)
p = prompt("b")
assert(contains(p, "committed.lua") and not contains(p, "safe full untracked content"))
assert(contains(p, "exclude local uncommitted changes") and contains(p, "REPORT AT MOST 20 FINDINGS"))
hooks.turn_end({ session_id = "a" }); assert(prompt() == nil and prompt("b"))
start("ordinary request", "b"); assert(prompt("b") == nil)
for _, args in ipairs({ "--help", "main nope", "low high", "main high extra" }) do
  assert(contains(start("/review " .. args).deny, "usage:"))
end
assert(start("/review nonexistent").deny)
cancelled = true; assert(start("/review") == nil and prompt() == nil); cancelled = false
-- Oversized diffs are omitted whole, never clipped inside a hunk.
write("tracked.lua", string.rep("oversized diff sentinel\n", 500))
assert(start("/review") == nil)
p = prompt(); assert(contains(p, "diff not inlined") and not contains(p, "oversized diff sentinel"))
-- Exercise the total/overview/file-count budgets with atomic entries.
for i = 1, 45 do write("many" .. i .. ".txt", "old\n") end
git("add 'many*.txt'"); git("commit -m many")
for i = 1, 45 do write("many" .. i .. ".txt", string.rep("new" .. i .. "\n", 900)) end
assert(start("/review") == nil)
p = prompt(); assert(#p <= 80000 + #"original\n\n")
assert(contains(p, "diff not inlined"))
-- Literal pathspecs: changing an oddly named tracked file cannot select others.
git("add -- " .. quote(odd)); git("commit -m odd")
write(odd, "odd tracked new content\n")
assert(start("/review") == nil)
assert(contains(prompt(), "+odd tracked new content"))
-- Clean default scope excludes staged-only changes.
git("reset --hard HEAD"); git("clean -fd"); write("only-staged", "staged\n"); git("add only-staged")
assert(start("/review").deny == "no changed files to review")
-- Subdirectory sessions retain the repository-wide scope for every file kind.
git("reset --hard HEAD")
assert(os.execute("mkdir -p " .. quote(root .. "/sub")))
local nested_odd = "sub/odd ' [x] :(glob)*.lua"
write("outside.lua", "outside before\n")
write("sub/inside.lua", "inside before\n")
write(nested_odd, "odd before\n")
git("add -- outside.lua sub"); git("commit -m subdirectory-base"); git("branch sub-base")
write("outside.lua", "outside committed\n")
write("sub/inside.lua", "inside committed\n")
write(nested_odd, "odd committed\n")
git("add -- outside.lua sub"); git("commit -m subdirectory-changes")
write("outside.lua", "outside local\n")
write("sub/inside.lua", "inside local\n")
write(nested_odd, "odd local\n")
write("new-outside.txt", "outside untracked sentinel\n")
write("sub/new-inside.txt", "inside untracked sentinel\n")
write("sub/staged-only.txt", "staged sentinel\n"); git("add sub/staged-only.txt")
write(".gitignore", "ignored.txt\n"); write("sub/ignored.txt", "ignored sentinel\n")
-- A user's diff.relative configuration must not change path coordinates.
git("config diff.relative true")
assert(start("/review", "sub", root .. "/sub") == nil)
p = assert(prompt("sub"))
for _, value in ipairs({ "outside.lua (+1/-1)", "sub/inside.lua (+1/-1)",
    nested_odd .. " (+1/-1)", "+outside local", "+inside local", "+odd local",
    "outside untracked sentinel", "inside untracked sentinel", "sub/new-inside.txt",
    "repository-root-relative", "from the repository root " .. quote(root),
    "git --literal-pathspecs diff --no-relative -- <path>" }) do
  assert(contains(p, value), value)
end
assert(not contains(p, "staged sentinel") and not contains(p, "ignored sentinel"))
assert(start("/review sub-base", "sub", root .. "/sub") == nil)
p = assert(prompt("sub"))
for _, value in ipairs({ "outside.lua (+1/-1)", "sub/inside.lua (+1/-1)",
    nested_odd .. " (+1/-1)", "+outside committed", "+inside committed", "+odd committed",
    "exclude local uncommitted changes", "repository-root-relative",
    "git --literal-pathspecs diff --no-relative", " HEAD -- <path>" }) do
  assert(contains(p, value), value)
end
assert(not contains(p, "+outside local") and not contains(p, "+inside local")
  and not contains(p, "+odd local") and not contains(p, "untracked sentinel")
  and not contains(p, "staged sentinel"))
local command, text, action, notice
bone = {
  cmd = { create = function(name, fn) assert(name == "review"); command = fn end },
  prompt = { set = function(value) text = value end },
  action = function(value) action = value end,
  notify = function(value) notice = value end,
}
dofile("plugins/review/tui.lua")
for _, args in ipairs({ "", "low", "main", "main high", " main medium " }) do
  command({ args = args })
  assert(text == "/review" .. (args ~= "" and " " .. args or "") and action == "submit")
end
command({ args = "main extra" }); assert(contains(notice, "usage:"))
assert(os.execute("rm -rf " .. quote(root)))
print("review plugin checks passed")
