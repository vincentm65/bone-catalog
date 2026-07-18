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

local headings = {
   "Current objective",
   "User constraints and preferences",
   "Verified facts and decisions",
   "Files and symbols",
   "Commands and validation",
   "Completed work",
   "Unresolved issues",
   "Pending tasks / next action",
   "Critical verbatim details",
}
local summary = {}
for _, heading in ipairs(headings) do
   summary[#summary + 1] = "## **" .. heading .. ":**\n- value"
end
local agent_calls = 0
local compact = commands.compact.handler("", {
   config = {
      get = function(_, key)
         if key == "compact_keep_tokens" then return "1" end
      end,
   },
   conversation = {
      history = function()
         return {
            { role = "user", content = "old question" },
            { role = "assistant", content = "old answer" },
            { role = "user", content = "recent question" },
            { role = "assistant", content = "recent answer" },
         }
      end,
      context_tokens = function(messages) return #messages * 1000 end,
   },
   agent = {
      run = function()
         agent_calls = agent_calls + 1
         return { ok = true, content = table.concat(summary, "\n\n") }
      end,
   },
})
assert(compact.action == "conversation.replace", compact.display)
assert(agent_calls == 1, "normalized Markdown headings should not require a repair pass")
local checkpoint = compact.messages[1].content
assert(checkpoint:find("\nCurrent objective:\n", 1, true))
assert(not checkpoint:find("##", 1, true))
assert(not checkpoint:find("**", 1, true))

local oversized = {}
for _, heading in ipairs(headings) do
   oversized[#oversized + 1] = heading .. ":\n- " .. string.rep("detail ", 200)
end
local retry_calls = 0
local retry_prompts = {}
local retried = commands.compact.handler("", {
   config = {
      get = function(_, key)
         if key == "compact_keep_tokens" then return "1" end
         if key == "compact_checkpoint_tokens" then return "500" end
      end,
   },
   conversation = {
      history = function()
         return {
            { role = "user", content = "old question" },
            { role = "assistant", content = "old answer" },
            { role = "user", content = "recent question" },
            { role = "assistant", content = "recent answer" },
         }
      end,
      context_tokens = function(messages)
         if #messages == 1 then return math.ceil(#messages[1].content / 4) end
         return #messages * 1000
      end,
   },
   agent = {
      run = function(prompt)
         retry_calls = retry_calls + 1
         retry_prompts[#retry_prompts + 1] = prompt
         local content = retry_calls < 3 and table.concat(oversized, "\n\n")
            or table.concat(summary, "\n\n")
         return { ok = true, content = content }
      end,
   },
})
assert(retried.action == "conversation.replace", retried.display)
assert(retry_calls == 3, "oversized checkpoints should be compressed more than once")
assert(retry_prompts[1]:find("within 500 tokens", 1, true))
assert(retry_prompts[2]:find("within 400 tokens", 1, true))
assert(retry_prompts[3]:find("within 300 tokens", 1, true))

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
