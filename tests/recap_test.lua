-- Run with: lua tests/recap_test.lua
local commands = {}
local turn_end_handler

bone = {
   command = {
      register = function(name, spec)
         commands[name] = spec
      end,
   },
   settings = {
      register = function() end,
   },
   on = function(event, handler)
      if event == "turn_end" then turn_end_handler = handler end
   end,
}

assert(loadfile("commands/recap.lua"))()
assert(commands.recap, "recap command was not registered")
assert(turn_end_handler, "recap turn_end handler was not registered")

local request_options
local result = commands.recap.handler("", {
   conversation = {
      history = function()
         return {
            { role = "user", content = "Please fix the bug" },
            { role = "assistant", content = "Fixed and tested it" },
         }
      end,
   },
   llm = {
      complete = function(opts)
         request_options = opts
         return { ok = true, content = "The bug was fixed and tested.", tool_calls = {} }
      end,
   },
})

assert(request_options, "recap should make a private LLM request")
assert(request_options.max_tokens == nil,
   "recap should use the provider's normal output-token behavior")
assert(result.submit == false, "recap output should remain display-only")
assert(result.display == "* Recap: The bug was fixed and tested. *")

print("recap_test: ok")
