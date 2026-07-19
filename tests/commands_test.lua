-- Run with: lua tests/commands_test.lua
local commands = {}
local before_turn_handlers = {}
local settings_page

cjson = {
   encode = function() return "[]" end,
}

bone = {
   command = {
      register = function(name, spec)
         commands[name] = spec
      end,
   },
   settings = {
      register = function(page)
         settings_page = page
      end,
   },
   on = function(event, handler)
      if event == "before_turn" then
         before_turn_handlers[#before_turn_handlers + 1] = handler
      end
   end,
}

local function settings(values)
   values = values or {}
   return {
      get = function(path)
         if values[path] ~= nil then return values[path] end
         if path == "compact.auto" then return true end
         if path == "compact.trigger_percentage" then return 80 end
         if path == "compact.fallback_context_window_tokens" then return 100000 end
      end,
   }
end

assert(loadfile("commands/compact.lua"))()
assert(loadfile("commands/usage.lua"))()

assert(commands.compact, "compact command was not registered")
assert(commands.usage, "usage command was not registered")
assert(settings_page and settings_page.namespace == "compact", "compact settings were not registered")
assert(#settings_page.fields == 3, "compact should expose exactly three settings")
assert(settings_page.fields[1].key == "auto")
assert(settings_page.fields[2].key == "trigger_percentage")
assert(settings_page.fields[3].key == "fallback_context_window_tokens")
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
   settings = settings(),
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
assert(agent_calls == 1, "manual compaction should ignore the recent-context budget")
assert(agent_calls == 1, "normalized Markdown headings should not require a repair pass")
local checkpoint = compact.messages[1].content
assert(checkpoint:find("\nCurrent objective:\n", 1, true))
assert(not checkpoint:find("##", 1, true))
assert(not checkpoint:find("**", 1, true))

local auto_statuses = {}
local auto_notices = {}
local large_message = string.rep("context ", 10000)
local auto_result = before_turn_handlers[1](nil, {
   settings = settings({ ["compact.trigger_percentage"] = 80 }),
   config = {
      get_table = function() return {} end,
   },
   usage = {
      snapshot = function() return { context_length = 90000 } end,
   },
   conversation = {
      current = function() return { id = 42 } end,
      history = function()
         return {
            { role = "user", content = large_message },
            { role = "assistant", content = large_message },
            { role = "user", content = large_message },
            { role = "assistant", content = large_message },
         }
      end,
      context_tokens = function(messages) return #messages * 100 end,
   },
   agent = {
      run = function() return { ok = true, content = table.concat(summary, "\n\n") } end,
   },
   ui = {
      status = function(message) auto_statuses[#auto_statuses + 1] = message end,
      notice = function(message) auto_notices[#auto_notices + 1] = message end,
   },
})
assert(auto_result.action == "conversation.replace")
assert(#auto_statuses == 1 and auto_statuses[1]:find("Compacting context", 1, true),
   "automatic compaction should emit transient progress")
assert(#auto_notices == 1 and auto_notices[1]:find("Context compacted", 1, true),
   "automatic compaction should emit a persistent success notice")

local oversized = {}
for _, heading in ipairs(headings) do
   oversized[#oversized + 1] = heading .. ":\n- " .. string.rep("detail ", 5000)
end
local retry_calls = 0
local retry_prompts = {}
local retry_limits = {}
local retried = commands.compact.handler("", {
   settings = settings(),
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
         if #messages == 0 then return 4800 end
         if #messages == 1 then return 4800 + math.ceil(#messages[1].content / 4) end
         return 4800 + #messages * 2000
      end,
   },
   agent = {
      run = function(prompt, opts)
         retry_calls = retry_calls + 1
         retry_prompts[#retry_prompts + 1] = prompt
         retry_limits[#retry_limits + 1] = opts.max_tokens
         local content = retry_calls < 3 and table.concat(oversized, "\n\n")
            or table.concat(summary, "\n\n")
         return { ok = true, content = content }
      end,
   },
})
assert(retried.action == "conversation.replace", retried.display)
assert(retry_calls == 3, "oversized checkpoints should be compressed more than once")
assert(retry_prompts[1]:find("within 10000 tokens", 1, true))
assert(retry_prompts[2]:find("within 8000 tokens", 1, true))
assert(retry_prompts[3]:find("within 6000 tokens", 1, true))
assert(table.concat(retry_limits, ",") == "8000,8000,6000",
   "compression generation must be capped to its requested checkpoint target")

local failed_calls = 0
local failed = commands.compact.handler("", {
   settings = settings(),
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
      run = function()
         failed_calls = failed_calls + 1
         return { ok = true, content = table.concat(oversized, "\n\n") }
      end,
   },
})
assert(failed_calls == 4, "oversized checkpoints should exhaust three bounded compression attempts")
assert(not failed.action, "failed compaction must preserve the original conversation")
assert(failed.display:find(" > 10000 tokens)", 1, true),
   "failure should report measured and configured checkpoint sizes")

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
