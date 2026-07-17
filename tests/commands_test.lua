-- Run with: lua tests/commands_test.lua
local commands = {}
local before_turn_handlers = {}

cjson = {
   encode = function() return "[]" end,
}

bone = {
   command = {
      register = function(name, spec)
         commands[name] = spec
      end,
   },
   on = function(event, handler)
      if event == "before_turn" then
         before_turn_handlers[#before_turn_handlers + 1] = handler
      end
   end,
}

assert(loadfile("commands/compact.lua"))()
assert(loadfile("commands/usage.lua"))()

assert(commands.compact, "compact command was not registered")
assert(commands.usage, "usage command was not registered")
assert(#before_turn_handlers == 1, "compact should register one before_turn handler")

local usage = commands.usage.handler(nil, {
   usage = {
      snapshot = function()
         return {
            request_count = 1,
            sent = 100,
            received = 25,
            context_length = 80,
            tool_count = 2,
            tool_schema_tokens = 10,
            tool_schema_chars = 38,
            system_prompt_tokens = 20,
            system_prompt_chars = 76,
         }
      end,
   },
})
assert(usage.submit == false)
assert(usage.display:find("Conversation usage", 1, true))
assert(usage.display:find("125 total", 1, true))

print("catalog command tests passed")
