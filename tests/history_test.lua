-- Run with: lua tests/history_test.lua
local captured_command
local captured_menu
local now = os.time()

local function utc(epoch)
   return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local yesterday = os.date("*t", now)
yesterday.day = yesterday.day - 1
yesterday.hour = 14
yesterday.min = 20
yesterday.sec = 0

local rows = {
   {
      id = 42, provider = "openai", model = "gpt-test",
      started_at = utc(now - 300), last_activity = utc(now - 300),
      preview = "  Fix\n  the bug  ", user_count = 2, assistant_count = 1,
      total_message_count = 4, status = "interrupted",
   },
   {
      id = 43, provider = "anthropic", model = "claude-test",
      started_at = utc(os.time(yesterday)), last_activity = utc(os.time(yesterday)),
      preview = "Yesterday row", user_count = 1, assistant_count = 1,
      total_message_count = 2, status = "completed",
   },
   {
      id = 44, provider = "local", model = "test",
      started_at = utc(now - 400 * 86400), last_activity = utc(now - 400 * 86400),
      preview = nil, user_count = 0, assistant_count = 0,
      total_message_count = 0, status = "empty",
   },
}

package.preload["history"] = function()
   return {
      list = function(_, limit)
         assert(limit == 50, "history should request 50 rows")
         return rows
      end,
      messages = function() return {} end,
   }
end
package.preload["ui.menu"] = function()
   return {
      select = function(_, spec)
         captured_menu = spec
         return { cancelled = true }
      end,
      clear = function() end,
   }
end

bone = {
   register_command = function(name, spec)
      assert(name == "history")
      captured_command = spec
   end,
}

assert(loadfile("commands/history.lua"))()
assert(captured_command, "history command was not registered")
captured_command.handler(nil, { ui = { notify = function() end } })

assert(captured_menu.title == "History")
assert(captured_menu.searchable == true)
assert(captured_menu.question == "Recent conversations — Enter resume · Esc cancel")
assert(#captured_menu.options == 3)

local recent = captured_menu.options[1]
assert(recent.label == " Fix the bug ")
assert(recent.description:find("5m ago", 1, true), recent.description)
assert(recent.description:find("openai/gpt-test", 1, true))
assert(recent.description:find("#42", 1, true))
assert(recent.description:find("2u · 1a · 4 total", 1, true))
assert(recent.description:find("No response", 1, true))
assert(recent.search_text:find("gpt-test", 1, true))
assert(recent.value == 42)

assert(captured_menu.options[2].description:find("Yesterday 14:20", 1, true))
local old = captured_menu.options[3]
assert(old.label == "(no user message)")
assert(old.description:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d"))
assert(old.description:find("Empty", 1, true))

print("history command tests passed")
