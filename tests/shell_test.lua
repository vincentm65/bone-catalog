-- Run from catalog root: luajit tests/shell_test.lua
local events, commands, jobs, items, notices = {}, {}, {}, {}, {}
local session = { chat = 0, cwd = "/tmp/project", session_id = "one" }
local shutdown, fail, fail_add
bone = {
  on = function(name, fn) events[name] = fn end,
  cmd = { create = function(name, fn) commands[name] = fn end },
  notify = function(text) notices[#notices + 1] = text end,
  plugin = { on_shutdown = function(fn) shutdown = fn end },
  chat = {
    session = function() return session end,
    add = function(kind, fields)
      if fail_add then error("chat failed") end
      assert(kind == "shell")
      local id = #items + 1
      items[id] = { text = fields.text, chat = session.chat }
      return id
    end,
    update = function(id, fields) items[id].text = fields.text end,
  },
  job = { start = function(command, opts)
    if fail then error("job failed") end
    local job = { command = command, opts = opts }
    function job:cancel() self.cancelled = true end
    jobs[#jobs + 1] = job
    return job
  end },
}
dofile("plugins/shell/tui.lua")
local function submit(text, images) return events.submit({ text = text, images = images }) end
local function contains(text, part) return text:find(part, 1, true) ~= nil end
assert(submit("hello") == nil)
assert(submit("/term pwd") == nil)
assert(submit(" !pwd") == nil)
assert(submit("!!explain this") == "!explain this")
assert(#jobs == 0 and #items == 0)
assert(submit("!") == false and contains(notices[#notices], "Usage"))
assert(submit("! \n\t") == false and #jobs == 0)
assert(submit("!pwd", { { id = "image" } }) == false and #jobs == 0)
assert(submit("!pwd", {}) == false)
assert(jobs[1].command == "pwd" and jobs[1].opts.cwd == "/tmp/project")
assert(not jobs[1].opts.buffer and not jobs[1].opts.pty)
assert(contains(items[1].text, "[running]"))
-- Callbacks update the original item, not the chat currently on screen.
session = { chat = 1, cwd = "/elsewhere", session_id = "two" }
jobs[1].opts.on_stdout("/tmp/pro")
jobs[1].opts.on_stdout("ject\n")
jobs[1].opts.on_stderr("warning\n")
jobs[1].opts.on_exit({ state = "exited", code = 3 })
assert(items[1].chat == 0 and contains(items[1].text, "/tmp/project\nwarning"))
assert(contains(items[1].text, "[exit 3]"))
assert(submit("!printf 'a b' | cat\nexit 7") == false)
assert(jobs[2].command == "printf 'a b' | cat\nexit 7")
jobs[2].opts.on_stdout("\27[31mred\27[0m\r\n\0plain")
assert(contains(items[2].text, "red\nplain") and not items[2].text:find("\27"))
assert(submit("!sleep 30") == false)
session = { chat = 0 }
commands["shell-cancel"]()
assert(not jobs[2].cancelled and not jobs[3].cancelled)
session = { chat = 1 }
commands["shell-cancel"]()
assert(jobs[2].cancelled and jobs[3].cancelled)
jobs[3].opts.on_exit({ state = "cancelled" })
assert(contains(items[3].text, "[cancelled]"))
-- New chats inherit the TUI cwd, without creating a core session.
session = { chat = 2, new = true }
assert(submit("!pwd") == false and jobs[4].opts.cwd == nil)
jobs[4].opts.on_exit({ state = "failed", error = "missing shell" })
assert(contains(items[4].text, "failed: missing shell"))
fail = true
assert(submit("!bad") == false and contains(items[5].text, "job failed"))
fail = false; fail_add = true
assert(submit("!pwd") == false and contains(notices[#notices], "chat failed"))
fail_add = false
-- Bounded output, including a multibyte character crossing the limit.
assert(submit("!large") == false)
jobs[5].opts.on_stdout(string.rep("a", 65535))
jobs[5].opts.on_stdout("éoverflow")
assert(contains(items[6].text, "[output truncated at 64 KiB]"))
assert(not contains(items[6].text, "é") and not contains(items[6].text, "overflow"))
local before = items[6].text
jobs[5].opts.on_stderr("ignored")
assert(items[6].text == before)
jobs[5].opts.on_exit({ state = "exited", code = 0 })
assert(contains(items[6].text, "[exit 0]"))
assert(submit("!sleep 60") == false)
shutdown()
assert(contains(items[7].text, "cancelled (plugin unloaded)"))
before = items[7].text
jobs[6].opts.on_stdout("late")
jobs[6].opts.on_exit({ state = "exited", code = 0 })
assert(items[7].text == before)
print("shell tests passed: interception/escape/cwd/output/errors/limits/chat switching/cancel/unload")
