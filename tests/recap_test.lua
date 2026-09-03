-- Run with: lua tests/recap_test.lua
local commands = {}
local turn_end_handler
local registered_settings

bone = {
   command = {
      register = function(name, spec)
         commands[name] = spec
      end,
   },
   settings = {
      register = function(spec)
         registered_settings = spec
      end,
   },
   on = function(event, handler)
      if event == "turn_end" then turn_end_handler = handler end
   end,
}

assert(loadfile("commands/recap.lua"))()
assert(commands.recap, "recap command was not registered")
assert(turn_end_handler, "recap turn_end handler was not registered")

-- 0) The idle default is 15 min, and the cap allows at least that much.
assert(registered_settings and registered_settings.namespace == "recap",
   "recap settings were not registered")
local idle_field
for _, f in ipairs(registered_settings.fields) do
   if f.key == "idle_seconds" then idle_field = f end
end
assert(idle_field, "recap.idle_seconds setting must be registered")
assert(idle_field.default == 900,
   "recap idle default should be 15 min (900 s), got " .. tostring(idle_field.default))
assert(idle_field.max and idle_field.max >= 900,
   "recap idle max must allow the 15 min default")
assert(idle_field.min and idle_field.min <= idle_field.default,
   "recap idle default must be within [min, max]")

-- 1) Manual happy path preserves the normal provider-facing prefix.
local request_options
local system_prompt = "You are the active coding assistant."
local history = {
   { role = "user", content = "Please fix the bug" },
   { role = "assistant", content = "Fixed and tested it" },
}
local tool_definitions = {
   { type = "function", name = "read_file", description = "Read a file" },
}
local result = commands.recap.handler("", {
   conversation = {
      system_prompt = function() return system_prompt end,
      history = function() return history end,
   },
   tools = { definitions = function() return tool_definitions end },
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
assert(result.display == "*Recap: The bug was fixed and tested.*",
   "recap display should be per-line markdown emphasis, got: " .. tostring(result.display))
assert(#request_options.messages == #history + 2,
   "expected system + unchanged history + recap instruction")
assert(request_options.messages[1].role == "system")
assert(request_options.messages[1].content == system_prompt,
   "recap should use the active conversation system prompt")
for i, message in ipairs(history) do
   assert(request_options.messages[i + 1] == message,
      "history message " .. i .. " should be forwarded unchanged")
end
local recap_message = request_options.messages[#request_options.messages]
assert(recap_message.role == "user")
assert(recap_message.content ==
   "Summarize the conversation so far in 1-2 brief sentences. " ..
   "Focus on what was accomplished and what is pending. Be concise. Do not call tools.")
assert(request_options.tools == tool_definitions,
   "tool definitions should be forwarded unchanged")

-- 1b) Multi-line summaries are wrapped per line (a single *…* pair would only
-- italicize the first markdown paragraph); asterisks in the LLM text are escaped.
local multi_result = commands.recap.handler("", {
   conversation = {
      history = function()
         return { { role = "user", content = "a" }, { role = "assistant", content = "b" } }
      end,
   },
   llm = { complete = function()
      return { ok = true, content = "First line.\nSecond line has *stars*.", tool_calls = {} }
   end },
})
assert(multi_result.display == "*Recap: First line.*\n*Second line has \\*stars\\*.*",
   "per-line emphasis expected, got: " .. tostring(multi_result.display))

-- 2) Tool-heavy history and definitions remain intact in the cacheable prefix.
local tool_opts
local tool_history = {
   { role = "user", content = "Read the file and fix the bug" },
   { role = "assistant", content = "",
     tool_calls = { { id = "c1", name = "read_file", arguments = "{}" } } },
   { role = "tool", content = "<file contents>", tool_call_id = "c1" },
   { role = "assistant", content = "Done, fixed the bug." },
}
local recap_tools = {
   { type = "function", name = "read_file", description = "Read a file" },
}
local tool_result = commands.recap.handler("", {
   conversation = {
      system_prompt = function() return system_prompt end,
      history = function() return tool_history end,
   },
   tools = { definitions = function() return recap_tools end },
   llm = {
      complete = function(opts)
         tool_opts = opts
         return { ok = true, content = "Read the file, found the bug, fixed it.", tool_calls = {} }
      end,
   },
})
assert(tool_result.display:find("Recap:") ~= nil,
   "recap should succeed with tool history: " .. tostring(tool_result.display))
assert(tool_opts, "tool-history recap should make a request")
assert(tool_opts.messages[1].content == system_prompt)
for i, message in ipairs(tool_history) do
   assert(tool_opts.messages[i + 1] == message,
      "tool-history message " .. i .. " should be forwarded unchanged")
end
assert(tool_opts.messages[3].tool_calls[1].id == "c1",
   "assistant tool calls should be preserved")
assert(tool_opts.messages[4].role == "tool",
   "tool result role should be preserved")
assert(tool_opts.messages[4].tool_call_id == "c1",
   "tool result call ID should be preserved")
assert(tool_opts.tools == recap_tools,
   "tool definitions should be forwarded unchanged with tool history")

-- 3) Auto path: turn_end schedules a deferred recap that fires on the idle timer.
local scheduled = {}
local notices = {}
local auto_ctx = {
   config = {
      get = function(ns, key)
         if ns == "recap" and key == "idle_seconds" then return 60 end
         if ns == "recap" and key == "auto" then return true end
         return nil
      end,
      get_table = function() return {} end,
   },
   time = { after = function(delay, cb)
      table.insert(scheduled, { delay = delay, cb = cb })
      return { cancel = function() end }
   end },
   ui = { notice = function(msg) table.insert(notices, msg) end },
   conversation = {
      history = function()
         return {
            { role = "user", content = "Fix the login bug" },
            { role = "assistant", content = "Fixed and tested login." },
         }
      end,
   },
   llm = { complete = function()
      return { ok = true, content = "Fixed the login bug.", tool_calls = {} }
   end },
}
turn_end_handler({}, auto_ctx)
assert(#scheduled == 1, "turn_end should schedule exactly one deferred recap")
assert(scheduled[1].delay == 60000, "idle delay should be 60s in ms")
assert(notices[1] == nil, "no recap notice before the idle timer fires")
scheduled[1].cb()
assert(#notices == 1, "one notice after the idle timer fires")
assert(notices[1] == "*Recap: Fixed the login bug.*",
   "auto notice should be per-line markdown emphasis, got: " .. tostring(notices[1]))

-- 4) A newer turn cancels the pending timer; its stale callback is a no-op.
local scheduled2 = {}
local notices2 = {}
local auto_ctx2 = {
   config = {
      get = function(ns, key)
         if ns == "recap" and key == "idle_seconds" then return 60 end
         if ns == "recap" and key == "auto" then return true end
         return nil
      end,
      get_table = function() return {} end,
   },
   time = { after = function(_, cb)
      table.insert(scheduled2, cb)
      return { cancel = function() end }
   end },
   ui = { notice = function(msg) table.insert(notices2, msg) end },
   conversation = {
      history = function()
         return { { role = "user", content = "a" }, { role = "assistant", content = "b" } }
      end,
   },
   llm = { complete = function()
      return { ok = true, content = "Recap A.", tool_calls = {} }
   end },
}
turn_end_handler({}, auto_ctx2)
turn_end_handler({}, auto_ctx2)
assert(#scheduled2 == 2, "each turn_end schedules a timer")
assert(notices2[1] == nil, "no notice before any timer fires")
scheduled2[1]()
assert(notices2[1] == nil, "stale timer callback should be a no-op")
scheduled2[2]()
assert(#notices2 == 1, "the latest timer should produce one notice")
assert(notices2[1] == "*Recap: Recap A.*",
   "stale-timer notice should be per-line markdown emphasis, got: " .. tostring(notices2[1]))

print("recap_test: ok")
