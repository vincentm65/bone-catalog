-- Run with: lua tests/history_test.lua
local captured_command
local captured_menu
local now = os.time()
local menu_result = { cancelled = true }
local menu_error
local list_error
local messages_error
local stored_messages = {}
local clear_calls = 0

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
      total_message_count = 4, total_token_count = 1234, status = "interrupted",
   },
   {
      id = 43, provider = "anthropic", model = "claude-test",
      started_at = utc(os.time(yesterday)), last_activity = utc(os.time(yesterday)),
      preview = "Yesterday row", user_count = 1, assistant_count = 1,
      total_message_count = 2, total_token_count = 25, status = "completed",
   },
   {
      id = 44, provider = "local", model = "test",
      started_at = utc(now - 400 * 86400), last_activity = utc(now - 400 * 86400),
      preview = nil, user_count = 0, assistant_count = 0,
      total_message_count = 0, total_token_count = 0, status = "empty",
   },
}

package.preload["history"] = function()
   return {
      list = function(_, limit)
         assert(limit == 50, "history should request 50 rows")
         if list_error then error(list_error) end
         return rows
      end,
      messages = function(_, id, limit)
         assert(id == 42)
         assert(limit == 1000)
         if messages_error then error(messages_error) end
         return stored_messages
      end,
   }
end
package.preload["ui.menu"] = function()
   return {
      select = function(_, spec)
         captured_menu = spec
         if menu_error then error(menu_error) end
         return menu_result
      end,
      clear = function() clear_calls = clear_calls + 1 end,
   }
end

bone = {
   command = {
      register = function(name, spec)
         assert(name == "history")
         captured_command = spec
      end,
   },
}

assert(loadfile("commands/history.lua"))()
assert(captured_command, "history command was not registered")
local notices = {}
local ctx = {
   ui = {
      notify = function(message, level)
         notices[#notices + 1] = { message = message, level = level }
      end,
   },
}
captured_command.handler(nil, ctx)

assert(captured_menu.title == "History")
assert(captured_menu.searchable == true)
assert(captured_menu.question == "Recent conversations — Enter resume · Esc cancel")
assert(#captured_menu.options == 3)

local recent = captured_menu.options[1]
assert(recent.label == " Fix the bug ")
assert(recent.description:find("5m ago", 1, true), recent.description)
assert(recent.description:find("openai/gpt-test", 1, true))
assert(recent.description:find("#42", 1, true))
assert(recent.description:find("4 messages", 1, true))
assert(recent.description:find("1,234 tokens", 1, true))
assert(recent.description:find("No response", 1, true))
assert(recent.search_text:find("gpt-test", 1, true))
assert(recent.value == 42)
assert(recent.label_modifiers[1] == "bold")
assert(#recent.description_spans == 9)

assert(captured_menu.options[2].description:find("Yesterday 14:20", 1, true))
local old = captured_menu.options[3]
assert(old.label == "(no user message)")
assert(old.description:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d"))
assert(old.description:find("Empty", 1, true))

-- Successful selection preserves the released-client payload shape.
stored_messages = {
   { role = "user", content = "[Context summary] old state" },
   { role = "system", content = "not model history" },
   { role = "user", content = "Fix it" },
   {
      role = "assistant", content = "", tool_calls = {
         { id = "call-1", name = "read_file", arguments = { path = "src/main.rs" } },
      },
   },
   {
      role = "tool", content = "contents", tool_name = "read_file",
      tool_call_id = "call-1",
   },
}
menu_result = { value = 42 }
local loaded = captured_command.handler(nil, ctx)
assert(loaded.action == "conversation.load")
assert(loaded.conversation_id == 42)
assert(loaded.submit == false)
assert(#loaded.messages == 3)
assert(loaded.messages[1].role == "user" and loaded.messages[1].content == "Fix it")
assert(loaded.messages[2].tool_calls[1].id == "call-1")
assert(loaded.messages[3].name == "read_file")
assert(loaded.messages[3].tool_call_id == "call-1")

-- Every picker exit clears the menu, and failures surface useful notifications.
menu_error = "picker exploded"
assert(captured_command.handler(nil, ctx) == nil)
assert(notices[#notices].message:find("picker exploded", 1, true))
assert(notices[#notices].level == "error")
menu_error = nil

messages_error = "message query failed"
assert(captured_command.handler(nil, ctx) == nil)
assert(notices[#notices].message:find("#42", 1, true))
assert(notices[#notices].message:find("message query failed", 1, true))
messages_error = nil

list_error = "list query failed"
assert(captured_command.handler(nil, ctx) == nil)
assert(notices[#notices].message:find("list query failed", 1, true))
list_error = nil

local saved_rows = rows
rows = {}
assert(captured_command.handler(nil, ctx) == nil)
assert(notices[#notices].message == "No conversation history found.")
assert(notices[#notices].level == "warn")
rows = saved_rows
assert(clear_calls == 4, clear_calls)

print("history command tests passed")
