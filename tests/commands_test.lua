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
local fallback_field = settings_page.fields[3]
assert(fallback_field.key == "fallback_context_window_tokens")
assert(fallback_field.default == 100000)
assert(fallback_field.integer == true)
assert(fallback_field.min == 1)
assert(#before_turn_handlers == 1, "compact should register one before_turn handler")

local headings = {
   "Objective",
   "Constraints",
   "Current state",
   "Artifacts and validation",
   "Next actions",
}
local summary = {}
for _, heading in ipairs(headings) do
   summary[#summary + 1] = "## **" .. heading .. ":**\n- value"
end
local base_system_prompt = "Bone base system prompt"
local tool_definitions = {
   { name = "read_file", description = "Read a file", parameters = {} },
}
local agent_calls = 0
local summary_prompt_seen
local summary_options
local oversized_turn_text = string.rep("older context detail ", 1500)
local recent_user = { role = "user", content = "recent question" }
local recent_call = { role = "assistant", content = "", tool_calls = {
   { id = "call-recent", name = "read_file", arguments = { path = "src/main.rs" } },
} }
local recent_tool = { role = "tool", content = "recent tool result", tool_call_id = "call-recent" }
local recent_answer = { role = "assistant", content = "recent answer" }
local compact_history = {
   { role = "user", content = "old question" },
   { role = "assistant", content = "old answer " .. oversized_turn_text },
   recent_user,
   recent_call,
   recent_tool,
   recent_answer,
}
local compact = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function() return compact_history end,
      context_tokens = function(messages) return #messages * 1000 end,
      system_prompt = function() return base_system_prompt end,
   },
   tools = { definitions = function() return tool_definitions end },
   llm = {
      complete = function(opts)
         agent_calls = agent_calls + 1
         summary_prompt_seen = opts.messages[#opts.messages].content
         summary_options = opts
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
})
assert(compact.action == "conversation.replace", compact.display)
assert(agent_calls == 1, "compaction should make exactly one summarization call")
assert(summary_options.max_tokens == nil, "compaction should use the provider's output default")
assert(summary_options.tools == tool_definitions, "compaction should pass the current tool definitions")
assert(#summary_options.messages == #compact_history + 2)
assert(summary_options.messages[1].role == "system")
assert(summary_options.messages[1].content == base_system_prompt)
for i, message in ipairs(compact_history) do
   assert(summary_options.messages[i + 1] == message,
      "compaction should preserve history message identity and order")
end
assert(summary_options.messages[#summary_options.messages].role == "user")
assert(#compact.messages == 5, "compaction should preserve the newest complete turn")
assert(compact.messages[1].role == "user")
local checkpoint = compact.messages[1].content
assert(checkpoint:find("[Context checkpoint v1]", 1, true))
assert(checkpoint:find("Objective", 1, true))
assert(checkpoint:find("Resume the current user request from this checkpoint", 1, true))
assert(checkpoint:find("does not complete the active task", 1, true))
assert(summary_prompt_seen:find("Target approximately 4000 tokens", 1, true),
   "compaction should request the capped output target")
assert(summary_prompt_seen:find("before the final 4 messages", 1, true),
   "compaction should identify the verbatim recent suffix")
assert(summary_options.messages[4] == recent_user)
assert(compact.messages[2] == recent_user)
assert(compact.messages[3] == recent_call)
assert(compact.messages[4] == recent_tool)
assert(compact.messages[5] == recent_answer)
assert(compact.display:find("4 recent messages preserved", 1, true))

local huge_turn_history = { { role = "user", content = "huge completed turn" } }
for i = 2, 400 do
   huge_turn_history[#huge_turn_history + 1] = {
      role = "assistant",
      content = string.rep("x", 100) .. tostring(i),
   }
end
local current_user = { role = "user", content = "current request" }
huge_turn_history[#huge_turn_history + 1] = current_user
local huge_prompt
local huge_options
local huge_turn_result = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function() return huge_turn_history end,
      context_tokens = function(messages) return #messages * 1000 end,
      system_prompt = function() return base_system_prompt end,
   },
   llm = {
      complete = function(opts)
         huge_options = opts
         huge_prompt = opts.messages[#opts.messages].content
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
})
assert(huge_turn_result.action == "conversation.replace", huge_turn_result.display)
assert(#huge_turn_result.messages == 2,
   "an oversized completed turn should be summarized instead of retained")
assert(huge_turn_result.messages[2] == current_user,
   "the current user message should remain verbatim")
assert(huge_options.messages[2] == huge_turn_history[1],
   "the oversized completed turn should remain in the request history")
assert(huge_options.messages[#huge_options.messages - 1] == current_user,
   "the preserved current user message should remain in the request history")
assert(huge_prompt:find("before the final 1 messages", 1, true),
   "the instruction should exclude the preserved current user message from the capsule")

local auto_statuses = {}
local auto_notices = {}
local auto_calls = 0
local auto_options
local auto_recent_user = { role = "user", content = "recent automatic question" }
local auto_recent_assistant = { role = "assistant", content = "recent automatic answer" }
local auto_history = {
   { role = "user", content = "old automatic question" },
   { role = "assistant", content = "old automatic answer " .. oversized_turn_text },
   auto_recent_user,
   auto_recent_assistant,
}
local auto_result = before_turn_handlers[1](nil, {
   settings = settings(),
   config = { get_table = function() return { compact = true } end },
   model = { context_window_tokens = 100000 },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 42 } end,
      history = function() return auto_history end,
      context_tokens = function(messages) return #messages * 100 end,
      system_prompt = function() return base_system_prompt end,
   },
   tools = { definitions = function() return tool_definitions end },
   llm = {
      complete = function(opts)
         auto_calls = auto_calls + 1
         auto_options = opts
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
   ui = {
      status = function(message) auto_statuses[#auto_statuses + 1] = message end,
      notice = function(message) auto_notices[#auto_notices + 1] = message end,
   },
})
assert(auto_result.action == "conversation.replace")
assert(auto_calls == 1, "automatic compaction should make exactly one summarization call")
assert(auto_options.max_tokens == nil)
assert(auto_options.tools == tool_definitions)
assert(#auto_options.messages == #auto_history + 2)
assert(auto_options.messages[1].content == base_system_prompt)
assert(auto_options.messages[#auto_options.messages].content:find("before the final 2 messages", 1, true))
assert(#auto_result.messages == 3, "automatic compaction should preserve the newest turn")
assert(auto_result.messages[2] == auto_recent_user)
assert(auto_result.messages[3] == auto_recent_assistant)
assert(#auto_statuses == 1 and auto_statuses[1]:find("Compacting context", 1, true),
   "automatic compaction should emit transient progress")
assert(#auto_notices == 1 and auto_notices[1]:find("Context compacted", 1, true),
   "automatic compaction should emit a persistent success notice")

local missing_commands_result = before_turn_handlers[1](nil, {
   settings = settings(),
   config = { get_table = function() return nil end },
   model = { context_window_tokens = 100000 },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 48 } end,
      history = function() return auto_history end,
      context_tokens = function(messages) return #messages * 100 end,
      system_prompt = function() return base_system_prompt end,
   },
   llm = {
      complete = function()
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
   ui = { notice = function() end },
})
assert(missing_commands_result and missing_commands_result.action == "conversation.replace",
   "a missing commands config table should not disable automatic compaction")

local disabled_history_reads = 0
local disabled_result = before_turn_handlers[1](nil, {
   settings = settings(),
   config = { get_table = function() return { compact = false } end },
   model = { context_window_tokens = 100000 },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 49 } end,
      history = function()
         disabled_history_reads = disabled_history_reads + 1
         return auto_history
      end,
   },
})
assert(disabled_result == nil)
assert(disabled_history_reads == 0,
   "the canonical commands.compact=false value should disable automatic compaction")

local fallback_history_reads = 0
local fallback_result = before_turn_handlers[1](nil, {
   settings = settings({ ["compact.fallback_context_window_tokens"] = 200000 }),
   config = { get_table = function() return {} end },
   model = nil,
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 47 } end,
      history = function()
         fallback_history_reads = fallback_history_reads + 1
         return auto_history
      end,
   },
})
assert(fallback_result == nil)
assert(fallback_history_reads == 0,
   "configured fallback capacity should control the trigger when model capacity is unavailable")

local incremental_calls = 0
local incremental_prompt
local incremental_options
local previous_checkpoint = "[Context checkpoint v1]\n\n## Objective\n- Existing objective"
local incremental_recent_user = { role = "user", content = "current question" }
local incremental_recent_assistant = { role = "assistant", content = "current answer" }
local incremental_history = {
   { role = "user", content = previous_checkpoint },
   { role = "user", content = "completed older task" },
   { role = "assistant", content = "older validation passed " .. oversized_turn_text },
   incremental_recent_user,
   incremental_recent_assistant,
}
local incremental = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function() return incremental_history end,
      context_tokens = function(messages) return #messages * 1000 end,
      system_prompt = function() return base_system_prompt end,
   },
   tools = { definitions = function() return tool_definitions end },
   llm = {
      complete = function(opts)
         incremental_calls = incremental_calls + 1
         incremental_prompt = opts.messages[#opts.messages].content
         incremental_options = opts
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
})
assert(incremental.action == "conversation.replace", incremental.display)
assert(incremental_calls == 1, "incremental compaction should make exactly one call")
assert(incremental_options.max_tokens == nil)
assert(incremental_options.tools == tool_definitions)
assert(#incremental.messages == 3)
assert(incremental.messages[2] == incremental_recent_user)
assert(incremental.messages[3] == incremental_recent_assistant)
assert(incremental_options.messages[2] == incremental_history[1],
   "incremental compaction should keep the previous checkpoint in history")
assert(incremental_options.messages[3] == incremental_history[2])
assert(incremental_options.messages[4] == incremental_history[3])
assert(incremental_options.messages[5] == incremental_recent_user)
assert(incremental_options.messages[6] == incremental_recent_assistant)
assert(incremental_prompt:find("before the final 2 messages", 1, true),
   "incremental compaction should exclude the recent suffix through the final instruction")

local function snapshot_history(history)
   local snapshot = {}
   for i, message in ipairs(history) do
      snapshot[i] = {
         message = message,
         role = message.role,
         content = message.content,
         tool_call_id = message.tool_call_id,
         tool_calls = message.tool_calls,
      }
   end
   return snapshot
end

local function assert_history_unchanged(history, snapshot, label)
   assert(#history == #snapshot, label .. " changed history length")
   for i, original in ipairs(snapshot) do
      local message = history[i]
      assert(message == original.message, label .. " replaced original message " .. i)
      assert(message.role == original.role, label .. " changed role " .. i)
      assert(message.content == original.content, label .. " changed content " .. i)
      assert(message.tool_call_id == original.tool_call_id, label .. " changed tool call id " .. i)
      assert(message.tool_calls == original.tool_calls, label .. " changed tool calls " .. i)
   end
end

local failure_history = {
   { role = "user", content = "old failure question" },
   { role = "assistant", content = "old failure answer " .. oversized_turn_text },
   { role = "user", content = "recent failure question" },
   { role = "assistant", content = "recent failure answer" },
}
local failure_originals = snapshot_history(failure_history)
for _, case in ipairs({
   { label = "missing active system prompt" },
   { label = "empty active system prompt", system_prompt = function() return "" end },
}) do
   local calls = 0
   local conversation = {
      history = function() return failure_history end,
      context_tokens = function(messages) return #messages * 1000 end,
      system_prompt = case.system_prompt,
   }
   local result = commands.compact.handler("", {
      settings = settings(),
      conversation = conversation,
      llm = {
         complete = function()
            calls = calls + 1
            return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
         end,
      },
   })
   assert(calls == 0, case.label .. " must not invoke the summarizer")
   assert(not result.action, case.label .. " must preserve the original conversation")
   assert(result.display:find("active system prompt is unavailable", 1, true))
   assert_history_unchanged(failure_history, failure_originals, case.label)
end

local function rejected_compaction(label, llm_complete, values, token_counter, expected_calls)
   local calls = 0
   local options
   local result = commands.compact.handler("", {
      settings = settings(values),
      conversation = {
         history = function() return failure_history end,
         context_tokens = token_counter,
         system_prompt = function() return base_system_prompt end,
      },
      llm = {
         complete = function(opts)
            calls = calls + 1
            options = opts
            return llm_complete(opts, calls)
         end,
      },
   })
   assert(calls == (expected_calls or 1), label .. " made an unexpected number of summarization calls")
   assert(options.max_tokens == nil, label .. " should use the provider's output default")
   assert(type(options.tools) == "table" and next(options.tools) == nil,
      label .. " should disable tools")
   assert(not result.action, label .. " must preserve the original conversation")
   assert(result.display:find("original context preserved", 1, true))
   assert_history_unchanged(failure_history, failure_originals, label)
   return result
end

local missing = rejected_compaction("missing summary result", function() return nil end)
assert(missing.display:find("summarizer returned no result", 1, true))

local failed = rejected_compaction("failed summary", function()
   return { ok = false, error = "incomplete response: max_output_tokens reached" }
end)
assert(failed.display:find("max_output_tokens reached", 1, true),
   "transport and stream failures should not trigger a repair")

local cancelled = rejected_compaction("cancelled summary", function()
   return { ok = false, cancelled = true, error = "cancelled" }
end)
assert(cancelled.display:find("cancelled", 1, true))

local malformed = rejected_compaction("malformed summary", function()
   return { ok = true, content = {}, tool_calls = {} }
end)
assert(malformed.display:find("malformed content", 1, true))

local empty = rejected_compaction("empty summary", function()
   return { ok = true, content = "  \n\t", tool_calls = {} }
end, nil, nil, 2)
assert(empty.display:find("summary repair failed", 1, true))
assert(empty.display:find("empty summary", 1, true))

local repair_calls = 0
local repaired = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function() return failure_history end,
      context_tokens = function(messages) return #messages * 1000 end,
      system_prompt = function() return base_system_prompt end,
   },
   llm = {
      complete = function(opts)
         repair_calls = repair_calls + 1
         assert(opts.max_tokens == nil)
         assert(type(opts.tools) == "table" and next(opts.tools) == nil)
         if repair_calls == 1 then
            return { ok = true, content = "ignored", tool_calls = { { name = "read_file" } } }
         end
         assert(opts.messages[#opts.messages].content:find(
            "Repair the previous failed attempt", 1, true))
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
})
assert(repair_calls == 2, "tool-call output should trigger exactly one repair")
assert(repaired.action == "conversation.replace", repaired.display)

local failed_tool_repair = rejected_compaction("failed tool-call repair", function(_, call)
   if call == 1 then
      return { ok = true, content = "ignored", tool_calls = { { name = "read_file" } } }
   end
   return { ok = false, error = "repair transport failed" }
end, nil, nil, 2)
assert(failed_tool_repair.display:find("summary repair failed", 1, true))
assert(failed_tool_repair.display:find("repair transport failed", 1, true))

local large_checkpoint = string.rep("large checkpoint detail ", 99) .. "large checkpoint detail"
local large = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function() return failure_history end,
      context_tokens = function(messages) return #messages * 1000 end,
      system_prompt = function() return base_system_prompt end,
   },
   llm = {
      complete = function(opts)
         assert(opts.max_tokens == nil, "large summary should use the provider's output default")
         return { ok = true, content = large_checkpoint, tool_calls = {} }
      end,
   },
})
assert(large.action == "conversation.replace", large.display)
assert(large.messages[1].content:find(large_checkpoint, 1, true),
   "large summary should be accepted without output-size rejection")
assert_history_unchanged(failure_history, failure_originals, "large summary")

local nonshrinking = rejected_compaction("non-shrinking summary", function()
   return { ok = true, content = table.concat(summary, "\n\n") }
end, nil, function(messages)
   if #messages == 0 then return 0 end
   if #messages == 1 then return 100 end
   return 4000
end)
assert(nonshrinking.display:find("Compaction rejected", 1, true))

-- Automatic retry state resets on every unavailable, unchanged, or rejected path.
local reset_snapshot_length = 90000
local reset_model = { context_window_tokens = 100000 }
local reset_history_available = true
local reset_history_has_older = true
local reset_history_reads = 0
local reset_agent_calls = 0
local reset_recent_user = { role = "user", content = "reset recent question" }
local reset_recent_assistant = { role = "assistant", content = "reset recent answer" }
local reset_full_history = {
   { role = "user", content = "reset old question" },
   { role = "assistant", content = "reset old answer " .. oversized_turn_text },
   reset_recent_user,
   reset_recent_assistant,
}
local reset_auto_ctx = {
   settings = settings(),
   config = { get_table = function() return {} end },
   model = reset_model,
   usage = { snapshot = function() return { context_length = reset_snapshot_length } end },
   conversation = {
      current = function() return { id = 43 } end,
      system_prompt = function() return base_system_prompt end,
      history = function()
         reset_history_reads = reset_history_reads + 1
         if not reset_history_available then return nil end
         if not reset_history_has_older then return { reset_recent_user, reset_recent_assistant } end
         return reset_full_history
      end,
      context_tokens = function(messages)
         if #messages == 0 then return 0 end
         if #messages == 1 then return 100 end
         return 89000
      end,
   },
   llm = {
      complete = function()
         reset_agent_calls = reset_agent_calls + 1
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
   ui = { notice = function() end },
}
assert(before_turn_handlers[1](nil, reset_auto_ctx).action == "conversation.replace")
assert(reset_agent_calls == 1)
assert(before_turn_handlers[1](nil, reset_auto_ctx) == nil)
assert(reset_agent_calls == 1, "successful compaction should suppress an immediate duplicate attempt")
reset_auto_ctx.model = nil
reset_snapshot_length = 93000
assert(before_turn_handlers[1](nil, reset_auto_ctx).action == "conversation.replace")
assert(reset_agent_calls == 2,
   "fallback context capacity should trigger compaction when model capacity is unavailable")
reset_auto_ctx.model = reset_model
reset_snapshot_length = 79000
assert(before_turn_handlers[1](nil, reset_auto_ctx) == nil)
reset_snapshot_length = 90000
assert(before_turn_handlers[1](nil, reset_auto_ctx).action == "conversation.replace")
assert(reset_agent_calls == 3, "dropping below threshold should reset automatic retry state")
reset_snapshot_length = 93000
reset_history_available = false
assert(before_turn_handlers[1](nil, reset_auto_ctx) == nil)
reset_history_available = true
assert(before_turn_handlers[1](nil, reset_auto_ctx).action == "conversation.replace")
assert(reset_agent_calls == 4, "unavailable history should allow an immediate retry")
reset_history_has_older = false
assert(before_turn_handlers[1](nil, reset_auto_ctx) == nil)
reset_history_has_older = true
assert(before_turn_handlers[1](nil, reset_auto_ctx).action == "conversation.replace")
assert(reset_agent_calls == 5,
   "history already within the recent budget should allow an immediate retry")

local retry_agent_ok = false
local retry_agent_calls = 0
local retry_history = {
   { role = "user", content = "retry old question" },
   { role = "assistant", content = "retry old answer " .. oversized_turn_text },
   { role = "user", content = "retry recent question" },
   { role = "assistant", content = "retry recent answer" },
}
local retry_originals = snapshot_history(retry_history)
local retry_auto_ctx = {
   settings = settings(),
   config = { get_table = function() return {} end },
   model = { context_window_tokens = 100000 },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 44 } end,
      system_prompt = function() return base_system_prompt end,
      history = function() return retry_history end,
      context_tokens = function(messages)
         if #messages == 0 then return 0 end
         if #messages == 1 then return 100 end
         return 1000
      end,
   },
   llm = {
      complete = function(opts)
         retry_agent_calls = retry_agent_calls + 1
         assert(opts.max_tokens == nil)
         assert(type(opts.tools) == "table" and next(opts.tools) == nil)
         if retry_agent_ok then
            return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
         end
         return { ok = false, error = "temporary failure" }
      end,
   },
   ui = { notice = function() end },
}
assert(before_turn_handlers[1](nil, retry_auto_ctx) == nil)
assert_history_unchanged(retry_history, retry_originals, "failed automatic summary")
retry_agent_ok = true
local retry_auto_result = before_turn_handlers[1](nil, retry_auto_ctx)
assert(retry_auto_result and retry_auto_result.action == "conversation.replace",
   "failed automatic compaction should be retryable at the same context length")
assert(retry_agent_calls == 2,
   "each automatic summary attempt should invoke the summarizer exactly once")

local large_auto_calls = 0
local large_auto_ctx = {
   settings = settings(),
   config = { get_table = function() return {} end },
   model = { context_window_tokens = 100000 },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 45 } end,
      system_prompt = function() return base_system_prompt end,
      history = function() return retry_history end,
      context_tokens = function(messages)
         if #messages == 0 then return 0 end
         if #messages == 1 then return 500 end
         return 1000
      end,
   },
   llm = {
      complete = function(opts)
         large_auto_calls = large_auto_calls + 1
         assert(opts.max_tokens == nil)
         return { ok = true, content = string.rep("large checkpoint ", 1000), tool_calls = {} }
      end,
   },
   ui = { notice = function() end },
}
local large_auto_result = before_turn_handlers[1](nil, large_auto_ctx)
assert(large_auto_result and large_auto_result.action == "conversation.replace",
   "large automatic output should be accepted without output-size rejection")
assert(large_auto_calls == 1,
   "large automatic output should not trigger an internal repair call")

local allow_auto_shrink = false
local nonshrinking_auto_calls = 0
local nonshrinking_auto_ctx = {
   settings = settings(),
   config = { get_table = function() return {} end },
   model = { context_window_tokens = 100000 },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 46 } end,
      system_prompt = function() return base_system_prompt end,
      history = function() return retry_history end,
      context_tokens = function(messages)
         if #messages == 0 then return 0 end
         if #messages == 1 then return 100 end
         return allow_auto_shrink and 7000 or 90000
      end,
   },
   llm = {
      complete = function(opts)
         nonshrinking_auto_calls = nonshrinking_auto_calls + 1
         assert(opts.max_tokens == nil)
         return { ok = true, content = table.concat(summary, "\n\n"), tool_calls = {} }
      end,
   },
   ui = { notice = function() end },
}
assert(before_turn_handlers[1](nil, nonshrinking_auto_ctx) == nil)
assert_history_unchanged(retry_history, retry_originals, "non-shrinking automatic summary")
allow_auto_shrink = true
local shrinking_auto_result = before_turn_handlers[1](nil, nonshrinking_auto_ctx)
assert(shrinking_auto_result and shrinking_auto_result.action == "conversation.replace",
   "rejected non-shrinking output should be retryable at the same context length")
assert(nonshrinking_auto_calls == 2,
   "non-shrinking output should not trigger extra summarization calls")

local usage_snapshot = {
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
local function usage_ctx(files)
   return {
      config_dir = "/config",
      cwd = "/work/project",
      fs = { is_file = function(path) return files and files[path] ~= nil end },
      read_file = function(path) return files[path] end,
      usage = { snapshot = function() return usage_snapshot end },
   }
end

local usage = commands.usage.handler(nil, usage_ctx())
local function plain(text)
   return text:gsub("\27%[[0-9;]*m", "")
end
assert(usage.submit == false)
assert(usage.display:find("Conversation usage", 1, true))
assert(usage.display:find("125 total", 1, true))
assert(not usage.display:find("Memory total:", 1, true))
assert(plain(usage.display):find("Tools:        2 tools · ~10 tokens", 1, true))
assert(plain(usage.display):find("System:       ~20 tokens", 1, true))
assert(plain(usage.display):find("Known total:  ~30 tokens", 1, true),
   "prompt total should include tool and system overhead")
assert(not plain(usage.display):find("Global:", 1, true))
assert(not plain(usage.display):find("Project:", 1, true))
assert(not plain(usage.display):find("chars", 1, true),
   "prompt overhead should omit noisy character counts")

local memory_files = {
   ["/config/memory/global.md"] = "  global preference  ",
   ["/config/memory/projects/_work_project.md"] = "project preference",
}
usage = commands.usage.handler(nil, usage_ctx(memory_files))
local usage_text = plain(usage.display)
assert(usage_text:find("Memory total: ~41 tokens", 1, true),
   "usage should label the complete injected memory overhead")
assert(usage_text:find("  Global:     ~5 tokens · memory/global.md", 1, true),
   "usage should show indented global memory tokens and path")
assert(usage_text:find("  Project:    ~5 tokens · memory/projects/_work_project.md", 1, true),
   "usage should show indented current-project memory tokens and path")
assert(usage_text:find("  Framing:    ~31 tokens", 1, true),
   "usage should explain memory wrapper and heading overhead")
assert(usage_text:find("Known total:  ~71 tokens", 1, true),
   "prompt total should include reconstructed memory overhead")
assert(not usage_text:find("chars", 1, true))

memory_files["/config/memory/global.md"] = nil
memory_files["/config/memory.md"] = "legacy preference"
memory_files["/config/memory/projects/_work_project.md"] = nil
usage = commands.usage.handler(nil, usage_ctx(memory_files))
usage_text = plain(usage.display)
assert(usage_text:find("Global:", 1, true), "legacy memory should be labeled global")
assert(usage_text:find("memory.md", 1, true), "usage should report legacy global memory fallback")
assert(not usage_text:find("Project:", 1, true), "usage should omit absent project memory")

memory_files["/config/memory/global.md"] = ""
memory_files["/config/memory.md"] = "must not be injected"
memory_files["/config/memory/projects/_work_project.md"] = "project preference"
usage = commands.usage.handler(nil, usage_ctx(memory_files))
usage_text = plain(usage.display)
assert(not usage_text:find("memory.md", 1, true),
   "an existing scoped global file should suppress legacy fallback")
assert(not usage_text:find("Global:", 1, true), "usage should omit empty global memory")
assert(usage_text:find("Project:", 1, true))
assert(usage_text:find("memory/projects/_work_project.md", 1, true))

memory_files["/config/memory/global.md"] = string.rep("x", 2100)
memory_files["/config/memory/projects/_work_project.md"] = nil
usage = commands.usage.handler(nil, usage_ctx(memory_files))
assert(plain(usage.display):find("  Global:     ~527 tokens · memory/global.md", 1, true),
   "usage should apply the same memory truncation as prompt injection")

local loaded_themes = {}
local previewed_themes = {}
local theme_notices = {}
local current_theme = "nord"
bone.theme = {
   list = function() return { "catppuccin", "nord" } end,
   load = function(name)
      loaded_themes[#loaded_themes + 1] = name
      current_theme = name
   end,
   preview = function(name)
      previewed_themes[#previewed_themes + 1] = name or "<configured>"
   end,
}
bone.settings.get = function(path)
   assert(path == "theme.name")
   return current_theme
end
bone.settings.reset = function() error("themes should not reset settings directly") end
local selection = 0
local menu_stub
package.preload["ui.menu"] = function()
   menu_stub = {
      select = function(_, spec)
         selection = selection + 1
         assert(spec.default == 2, "selector should start on the active theme")
         spec.on_change("catppuccin")
         if selection == 1 then return { cancelled = true } end
         return { value = "catppuccin" }
      end,
      clear = function() end,
   }
   return menu_stub
end
assert(loadfile("commands/themes.lua"))()
local theme_ctx = {
   ui = {
      notify = function(message, level)
         theme_notices[#theme_notices + 1] = { message = message, level = level }
      end,
   },
}
commands.themes.handler("", theme_ctx)
assert(#loaded_themes == 0, "navigation and cancellation must not persist a theme")
assert(table.concat(previewed_themes, ",") == "catppuccin,<configured>",
   "cancellation should restore the configured theme through preview(nil)")
commands.themes.handler("", theme_ctx)
assert(table.concat(loaded_themes, ",") == "catppuccin",
   "confirmation should persist only the final selection once")
assert(table.concat(previewed_themes, ",") == "catppuccin,<configured>,catppuccin",
   "confirmed navigation should still preview before the one persistent load")

local loaded_before_bad_args = #loaded_themes
commands.themes.handler("apply", theme_ctx)
assert(theme_notices[#theme_notices].level == "error")
assert(theme_notices[#theme_notices].message == "Usage: /themes [apply <name>|<name>]")
commands.themes.handler("apply catppuccin extra", theme_ctx)
assert(theme_notices[#theme_notices].level == "error")
assert(theme_notices[#theme_notices].message == "Usage: /themes [apply <name>|<name>]")
assert(#loaded_themes == loaded_before_bad_args,
   "malformed theme arguments must not be interpreted as theme names")

menu_stub.select = function() error("picker transport failed") end
commands.themes.handler("", theme_ctx)
assert(theme_notices[#theme_notices].level == "error")
assert(theme_notices[#theme_notices].message:find("picker transport failed", 1, true))
assert(previewed_themes[#previewed_themes] == "<configured>",
   "picker failures must restore the configured theme")

menu_stub.select = function(_, spec)
   spec.on_change("catppuccin")
   return { value = "catppuccin" }
end
bone.theme.load = function() error("settings write failed") end
commands.themes.handler("", theme_ctx)
assert(theme_notices[#theme_notices].level == "error")
assert(theme_notices[#theme_notices].message:find("settings write failed", 1, true))
assert(previewed_themes[#previewed_themes] == "<configured>",
   "apply failures must restore the configured theme")

print("catalog command tests passed")
