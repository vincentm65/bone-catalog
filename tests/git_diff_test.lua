-- Run from catalog root: luajit tests/git_diff_test.lua
package.path = "plugins/git-diff/lua/?.lua;" .. package.path
local diff = require("git_diff")
local tree = require("git_diff_tree")
local parsed = diff.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -2,2 +3,2 @@\n context\n-old\n+new\n\\ No newline at end of file\n")
assert(#parsed == 8)
assert(parsed[5].old == 2 and parsed[5].new == 3)
assert(parsed[6].old == 3 and parsed[6].group == "DiffDelete")
assert(parsed[7].new == 4 and parsed[7].group == "DiffAdd")
assert(parsed[8].group == "ToolSummary")
assert(#diff.parse("") == 0)
assert(diff.parse("@@ -0,0 +1 @@\n+你好\n")[2].new == 1)
assert(diff.parse("diff --git a/a b/b\nsimilarity index 100%\nrename from a\nrename to b\n")[4].text == "rename to b")
assert(diff.parse("Binary files a/a and b/a differ\n")[1].group == "ToolSummary")

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local root = os.tmpname(); os.remove(root)
assert(os.execute("mkdir -p " .. quote(root)) == 0)
local function write(name, text)
  local f = assert(io.open(root .. "/" .. name, "wb")); f:write(text); f:close()
end
local function shell(cmd)
  assert(os.execute("cd " .. quote(root) .. " && " .. cmd .. " >/dev/null 2>&1") == 0)
end
local session = { cwd = root, session_id = "one" }
local commands, events, jobs, timers, shutdown = {}, {}, {}, {}, nil
local panel
bone = {
  chat = { session = function() return session end },
  cmd = { create = function(name, fn) commands[name] = fn end },
  on = function(name, fn) events[name] = fn end,
  notify = function(text) error(text) end,
  defer = function(_, fn) timers[#timers + 1] = fn end,
  plugin = { on_shutdown = function(fn) shutdown = fn end },
  text = { wrap = function(spans, width, opts)
    assert(width > 0)
    return { { type(opts.first) == "table" and opts.first[1] or { opts.first }, spans[1], { fill = " ", hl = opts.pad } } }
  end },
  ui = { panel = { open = function(spec)
    panel = { spec = spec, opened = true }
    function panel:is_open() return self.opened end
    function panel:update(value) self.title = value.title end
    function panel:scroll(value) self.top = value end
    function panel:info() return { top = 0, height = 20 } end
    function panel:focus() self.focused = true end
    function panel:close() self.opened = false; self.spec.on_close() end
    return panel
  end } },
  job = { start = function(cmd, opts)
    local job = { cmd = cmd, opts = opts }
    function job:cancel() self.cancelled = true end
    jobs[#jobs + 1] = job
    return job
  end },
}
local function finish(job)
  local out, err, status = root .. "/out", root .. "/err", root .. "/status"
  os.execute("cd " .. quote(job.opts.cwd) .. " && ( " .. job.cmd .. " ) >" .. quote(out) .. " 2>" .. quote(err) .. "; echo $? >" .. quote(status))
  local function read(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end
  job.opts.on_exit({ state = "exited", code = tonumber(read(status)), stdout = read(out), stderr = read(err) })
end
local function text()
  local lines = panel.spec.render({ width = 80 })
  local out = {}
  for _, line in ipairs(lines) do out[#out + 1] = (line[2] or line[1] or { "" })[1] end
  return table.concat(out, "\n"), lines
end
local function contains(s, needle) return s:find(needle, 1, true) ~= nil end

dofile("plugins/git-diff/tui.lua")
shell("git init; git config user.email test@example.com; git config user.name Test")
write("tracked", "before\n"); shell("git add tracked")
commands.diff({ args = "" })
assert(panel.spec.dock == "right" and panel.spec.size == 0.5 and panel.spec.full_height)
finish(jobs[#jobs]); panel.spec.keys.enter(); assert(contains(text(), "before")) -- unborn HEAD
shell("git commit -m initial")
write("tracked", "staged\n"); shell("git add tracked")
write("tracked", "unstaged\n")
commands.diff({ args = "refresh" }); finish(jobs[#jobs]); panel.spec.keys.enter()
assert(contains(text(), "unstaged") and contains(text(), "before"))
assert(panel.title == "Git diff")
assert(not contains(text(), "diff --git") and not contains(text(), "index "))
local spaced = diff.render(parsed, 80)
assert(spaced[6][1][1] == "    2    3     " and spaced[6][1][2] == "ToolGutter")
assert(#spaced[4] == 0 and #spaced[8] == 0) -- hunk and deletion/addition gaps
local _, lines = text()
local add, del = false, false
assert(lines[2][2][1] == "+1 added" and lines[2][2][2] == "DiffAdd")
assert(lines[2][4][1] == "−1 removed" and lines[2][4][2] == "DiffDelete")
for _, line in ipairs(lines) do
  add = add or (line[3] or {}).hl == "DiffAdd"
  del = del or (line[3] or {}).hl == "DiffDelete"
end
assert(add and del)
panel.spec.render({ width = 12 }) -- narrow prefix
panel.spec.keys.s(); finish(jobs[#jobs]); panel.spec.keys.enter(); assert(contains(text(), "staged") and contains(text(), "unstaged"))
panel.spec.keys.s(); finish(jobs[#jobs]); panel.spec.keys.enter(); assert(contains(text(), "staged") and not contains(text(), "unstaged"))
panel.spec.keys.b(); assert(contains(text(), "tracked"))
assert(events.mouse({ panel = "git-diff", panel_line = 4, button = "left", action = "down" }))
assert(panel.focused and contains(text(), "staged"))
panel.spec.keys.left(); panel.spec.keys.down(); panel.spec.keys.right()
assert(contains(text(), "staged"))
local sample = diff.parse('diff --git a/src/a.lua b/src/a.lua\n--- a/src/a.lua\n+++ b/src/a.lua\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b b/b\n')
local fs = tree.files(sample)
assert(#fs == 2 and fs[2].path == "src/a.lua" and fs[2].added == 1 and fs[2].deleted == 1)
assert(#tree.nodes(fs, {}) == 3 and #tree.nodes(fs, { src = true }) == 2)
local quoted = tree.files(diff.parse('diff --git "a/sp ace" "b/sp ace"\n+++ "b/sp ace"\n'))
assert(quoted[1].path == "sp ace")
commands.diff({ args = "refresh" })
jobs[#jobs].opts.on_exit({ state = "exited", code = 0, stdout =
  'diff --git a/a b/a\n@@ -1 +1,2 @@\n-old\n+new\n+extra\ndiff --git a/b b/b\n@@ -1 +1 @@\n-old\n+new\n' })
local _, totals = text()
assert(totals[2][2][1] == "+3 added" and totals[2][4][1] == "−2 removed")
panel.spec.keys.enter()
local _, opened = text()
assert(opened[2][2][1] == "+3 added" and opened[2][4][1] == "−2 removed")
local count = #jobs
events["turn/finished"]({ session_id = "other" }); assert(#jobs == count)
events["turn/finished"]({ session_id = "one" }); assert(#jobs == count + 1)
local stale = jobs[#jobs]
commands.diff({ args = "refresh" }); assert(stale.cancelled)
stale.opts.on_exit({ state = "exited", code = 0, stdout = "STALE\n" }); assert(not contains(text(), "STALE"))
local current = jobs[#jobs]
session = { cwd = root .. "/missing", session_id = "two" }
current.opts.on_exit({ state = "exited", code = 0, stdout = "WRONG SESSION\n" })
assert(not contains(text(), "WRONG SESSION"))
local timer = table.remove(timers, 1); timer()
assert(jobs[#jobs].opts.cwd == session.cwd)
jobs[#jobs].opts.on_exit({ state = "timed_out", timed_out = true }); assert(contains(text(), "timed out"))
commands.diff({ args = "refresh" })
jobs[#jobs].opts.on_exit({ state = "exited", code = 0, stdout = "partial", truncated = true })
assert(contains(text(), "4 MiB"))
commands.diff({ args = "refresh" }); current = jobs[#jobs]
panel.spec.keys.q(panel); assert(current.cancelled and not panel:is_open())
current.opts.on_exit({ state = "exited", code = 0, stdout = "CLOSED" })
count = #jobs
for _, fn in ipairs(timers) do fn() end
assert(#jobs == count)
session = { cwd = root, session_id = "one" }
commands.diff({ args = "" }); current = jobs[#jobs]
shutdown(); assert(current.cancelled)
assert(os.execute("rm -rf " .. quote(root)) == 0)
print("git-diff parser, rendering, real Git modes, and lifecycle checks passed")
