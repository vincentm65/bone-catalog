-- Run from catalog root: luajit tests/git_diff_test.lua
package.path = "plugins/git-diff/lua/?.lua;" .. package.path
local diff = require("git_diff")
local tree = require("git_diff_tree")
local parsed = diff.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -2,2 +3,2 @@\n context\n-old\n+new\n\\ No newline at end of file\n")
assert(#parsed == 8)
assert(parsed[5].old == 2 and parsed[5].new == 3)
assert(parsed[6].old == 3 and parsed[6].sign == "-")
assert(parsed[7].new == 4 and parsed[7].sign == "+")
assert(parsed[8].tone == "dim" and parsed[1].tone == "accent")
assert(#diff.parse("") == 0)
assert(diff.parse("@@ -0,0 +1 @@\n+你好\n")[2].new == 1)
assert(diff.parse("diff --git a/a b/b\nsimilarity index 100%\nrename from a\nrename to b\n")[4].text == "rename to b")
assert(diff.parse("Binary files a/a and b/a differ\n")[1].tone == "dim")

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
  has_capability = function() return false end,
  cmd = { create = function(name, fn) commands[name] = fn end },
  keymap = { set = function(key, action) keys_set = { key = key, action = action } end },
  on = function(name, fn) events[name] = fn end,
  notify = function(text) error(text) end,
  defer = function(_, fn) timers[#timers + 1] = fn end,
  plugin = { on_shutdown = function(fn) shutdown = fn end },
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
-- The view's words, in order, and its elements by kind.
local function text()
  local out = {}
  local function walk(el)
    if type(el) ~= "table" then return end
    for _, k in ipairs({ "text", "label" }) do if type(el[k]) == "string" then out[#out + 1] = el[k] end end
    for _, n in ipairs(el.names or {}) do out[#out + 1] = n end
    for _, it in ipairs(el.items or {}) do out[#out + 1] = it.text .. (it.detail and ("  " .. it.detail) or "") end
    for _, r in ipairs(el.rows or {}) do out[#out + 1] = r.text end
    for i = 1, table.maxn(el) do walk(el[i]) end
  end
  walk(panel.spec.view())
  return table.concat(out, "\n")
end
local function find(kind)
  local function walk(el)
    if type(el) ~= "table" then return end
    if el.kind == kind then return el end
    for i = 1, table.maxn(el) do
      local f = walk(el[i])
      if f then return f end
    end
  end
  return walk(panel.spec.view())
end
-- Press the file tree's first entry that is a file (or the one named).
local function open(name)
  local list = assert(find("list"), "no file tree")
  for i, it in ipairs(list.items) do
    if not it.text:match("/$") and (not name or it.text:find(name, 1, true)) then return list.on_press(i) end
  end
  error("no file " .. tostring(name))
end
local function contains(s, needle) return s:find(needle, 1, true) ~= nil end

dofile("plugins/git-diff/ui.lua")
shell("git init; git config user.email test@example.com; git config user.name Test")
write("tracked", "before\n"); shell("git add tracked")
commands.diff({ args = "" })
-- Two fifths of a window of unknown width, so the chat stays in sight.
assert(panel.spec.dock == "right" and panel.spec.size == 0.4 and panel.spec.full_height)
assert(keys_set.key == "ctrl+d" and keys_set.action == "/diff")
finish(jobs[#jobs]); open(); assert(contains(text(), "before")) -- unborn HEAD
shell("git commit -m initial")
write("tracked", "staged\n"); shell("git add tracked")
write("tracked", "unstaged\n")
commands.diff({ args = "refresh" }); finish(jobs[#jobs]); open()
assert(contains(text(), "unstaged") and contains(text(), "before"))
assert(panel.spec.title == "Git diff")
assert(not contains(text(), "diff --git") and not contains(text(), "index "))
-- The patch is a diff element with line numbers; the totals are tones.
local patch = find("diff")
local add, del = false, false
for _, r in ipairs(patch.rows) do add, del = add or r.sign == "+", del or r.sign == "-" end
assert(patch.numbers and add and del)
assert(contains(text(), "+1") and contains(text(), "−1"))
-- Modes are tabs; a press switches and reloads.
local tabs = find("tabs")
assert(tabs.names[1] == "All tracked" and tabs.current == 1)
panel.spec.keys.s(); finish(jobs[#jobs]); open(); assert(contains(text(), "staged") and contains(text(), "unstaged"))
panel.spec.keys.s(); finish(jobs[#jobs]); open(); assert(contains(text(), "staged") and not contains(text(), "unstaged"))
assert(find("tabs").current == 3)
-- Back to the files: b, left, or the button over the patch.
panel.spec.keys.b(); assert(contains(text(), "tracked") and not find("diff"))
open(); assert(find("button") and find("diff"))
assert(panel.spec.on_key("left") and not find("diff"))
open(); find("button").on_press(); assert(not find("diff"))
assert(panel.spec.on_key("pageup") == false)
tabs = find("tabs"); tabs.on_select(1); finish(jobs[#jobs]); assert(find("tabs").current == 1)
local sample = diff.parse('diff --git a/src/a.lua b/src/a.lua\n--- a/src/a.lua\n+++ b/src/a.lua\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b b/b\n')
local fs = tree.files(sample)
assert(#fs == 2 and fs[2].path == "src/a.lua" and fs[2].added == 1 and fs[2].deleted == 1)
assert(#tree.nodes(fs, {}) == 3 and #tree.nodes(fs, { src = true }) == 2)
local quoted = tree.files(diff.parse('diff --git "a/sp ace" "b/sp ace"\n+++ "b/sp ace"\n'))
assert(quoted[1].path == "sp ace")
commands.diff({ args = "refresh" })
jobs[#jobs].opts.on_exit({ state = "exited", code = 0, stdout =
  'diff --git a/a b/a\n@@ -1 +1,2 @@\n-old\n+new\n+extra\ndiff --git a/b b/b\n@@ -1 +1 @@\n-old\n+new\n' })
assert(contains(text(), "+3") and contains(text(), "−2"))
open()
assert(contains(text(), "+3") and contains(text(), "−2"))
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
print("git-diff parser, view, real Git modes, and lifecycle checks passed")
