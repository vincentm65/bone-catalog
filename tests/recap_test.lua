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

-- 1) Manual happy path (user/assistant only): one user message, no raw replay.
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
-- system + one user message carrying the transcript; no raw history replay
assert(#request_options.messages == 2, "expected system + one user message")
assert(request_options.messages[1].role == "system")
assert(request_options.messages[2].role == "user")
assert(request_options.messages[2].content:find("Please fix the bug") ~= nil)
assert(request_options.messages[2].content:find("Fixed and tested it") ~= nil)

-- 2) Tool-heavy history must not leak tool messages/ids to the provider (HIGH-1).
local tool_opts
local tool_result = commands.recap.handler("", {
   conversation = {
      history = function()
         return {
            { role = "user", content = "Read the file and fix the bug" },
            { role = "assistant", content = "",
              tool_calls = { { id = "c1", name = "read_file", arguments = "{}" } } },
            { role = "tool", content = "<file contents>", tool_call_id = "c1" },
            { role = "assistant", content = "Done, fixed the bug." },
         }
      end,
   },
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
for _, m in ipairs(tool_opts.messages) do
   assert(m.role ~= "tool", "tool role must not be sent to the provider")
   assert(m.tool_call_id == nil, "tool_call_id must not be sent to the provider")
   assert(m.tool_calls == nil, "tool_calls must not be sent to the provider")
end
assert(tool_opts.messages[2].content:find("Read the file and fix the bug") ~= nil)
assert(tool_opts.messages[2].content:find("Done, fixed the bug.") ~= nil)
-- the tool message body and the empty tool-call assistant turn are dropped
assert(tool_opts.messages[2].content:find("file contents") == nil)

-- 3) Auto path: turn_end schedules a deferred recap that fires on the idle timer.
local scheduled = {}
local notices = {}
local auto_ctx = {
   settings = { get = function(k)
      if k == "recap.idle_seconds" then return 60 end
      if k == "recap.auto" then return true end
      return nil
   end },
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
assert(notices[1] == "* Recap: Fixed the login bug. *")

-- 4) A newer turn cancels the pending timer; its stale callback is a no-op.
local scheduled2 = {}
local notices2 = {}
local auto_ctx2 = {
   settings = { get = function(k)
      if k == "recap.idle_seconds" then return 60 end
      if k == "recap.auto" then return true end
      return nil
   end },
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
assert(notices2[1] == "* Recap: Recap A. *")

print("recap_test: ok")
