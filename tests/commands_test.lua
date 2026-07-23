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
         if path == "compact.context_window_tokens" then return 100000 end
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
local context_window_field = settings_page.fields[3]
assert(context_window_field.key == "context_window_tokens")
assert(context_window_field.type == "number")
assert(context_window_field.default == 100000)
assert(context_window_field.integer == true)
assert(context_window_field.min == 10000)
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
local agent_calls = 0
local summary_prompts = {}
local long_turn = { { role = "user", content = "Fix the compaction bug" } }
for i = 1, 100 do
   long_turn[#long_turn + 1] = { role = "assistant", content = "", tool_calls = {
      { id = "call-" .. i, name = "read_file", arguments = { path = "src/main.rs" } },
   } }
   long_turn[#long_turn + 1] = {
      role = "tool",
      content = "tool result " .. i,
      tool_call_id = "call-" .. i,
   }
end
long_turn[#long_turn + 1] = { role = "assistant", content = "Continue debugging next" }
local compact = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function() return long_turn end,
      context_tokens = function(messages) return #messages * 1000 end,
   },
   agent = {
      run = function(prompt)
         agent_calls = agent_calls + 1
         summary_prompts[#summary_prompts + 1] = prompt
         return { ok = true, content = table.concat(summary, "\n\n") }
      end,
   },
})
assert(compact.action == "conversation.replace", compact.display)
assert(agent_calls == 1)
assert(#compact.messages == 1, "compaction should replace all raw messages with one checkpoint")
assert(compact.messages[1].role == "user")
local checkpoint = compact.messages[1].content
assert(checkpoint:find("[Context checkpoint v1]", 1, true))
assert(checkpoint:find("Objective", 1, true))
assert(summary_prompts[1]:find("Fix the compaction bug", 1, true))
assert(summary_prompts[1]:find("tool_call_id=call%-100"))
assert(summary_prompts[1]:find("tool result 100", 1, true))
assert(summary_prompts[1]:find("Continue debugging next", 1, true))
assert(compact.display:find("continuation checkpoint created", 1, true))

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
assert(#auto_result.messages == 1, "automatic compaction should preserve no raw messages")
assert(#auto_statuses == 1 and auto_statuses[1]:find("Compacting context", 1, true),
   "automatic compaction should emit transient progress")
assert(#auto_notices == 1 and auto_notices[1]:find("continuation checkpoint created", 1, true),
   "automatic compaction should emit a persistent success notice")

local incremental_prompt
local previous_checkpoint = "[Context checkpoint v1]\n\n## Objective\n- Existing objective"
local incremental = commands.compact.handler("", {
   settings = settings(),
   conversation = {
      history = function()
         return {
            { role = "user", content = previous_checkpoint },
            { role = "assistant", content = "Ran validation" },
            { role = "tool", content = "tests passed", tool_call_id = "call-test" },
         }
      end,
      context_tokens = function(messages) return #messages * 1000 end,
   },
   agent = {
      run = function(prompt)
         incremental_prompt = prompt
         return { ok = true, content = table.concat(summary, "\n\n") }
      end,
   },
})
assert(incremental.action == "conversation.replace", incremental.display)
assert(#incremental.messages == 1)
assert(incremental_prompt:find(previous_checkpoint, 1, true),
   "incremental compaction should fold from the previous checkpoint")
assert(incremental_prompt:find("Ran validation", 1, true))
assert(incremental_prompt:find("tests passed", 1, true))

local fallback_notices = {}
local fallback_history_calls = 0
local fallback_result = before_turn_handlers[1](nil, {
   settings = settings({ ["compact.context_window_tokens"] = 200000 }),
   config = { get_table = function() return {} end },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 43 } end,
      history = function()
         fallback_history_calls = fallback_history_calls + 1
         return {}
      end,
   },
   ui = { notice = function(message) fallback_notices[#fallback_notices + 1] = message end },
})
assert(not fallback_result)
assert(fallback_history_calls == 0,
   "the configured context capacity should control the automatic threshold")
assert(#fallback_notices == 0,
   "the configured fallback capacity should keep automatic compaction enabled")

local unavailable_notices = {}
local unavailable_result = before_turn_handlers[1](nil, {
   settings = {
      get = function(path)
         if path == "compact.auto" then return true end
         if path == "compact.trigger_percentage" then return 80 end
      end,
   },
   config = { get_table = function() return {} end },
   usage = { snapshot = function() return { context_length = 90000 } end },
   conversation = {
      current = function() return { id = 44 } end,
      history = function() error("history should not be read without a threshold") end,
   },
   ui = { notice = function(message) unavailable_notices[#unavailable_notices + 1] = message end },
})
assert(not unavailable_result)
assert(#unavailable_notices == 0,
   "unavailable context capacity should not emit an inaccurate warning")

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
         local content = retry_calls < 2 and table.concat(oversized, "\n\n")
            or table.concat(summary, "\n\n")
         return { ok = true, content = content }
      end,
   },
})
assert(retried.action == "conversation.replace", retried.display)
assert(retry_calls == 2, "oversized checkpoints should get one bounded compression attempt")
assert(retry_prompts[1]:find("within 4000 tokens", 1, true))
assert(retry_prompts[2]:find("fit within 3200 tokens", 1, true))
assert(table.concat(retry_limits, ",") == "4000,3200",
   "summary and compression generation must use their requested capsule targets")

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
assert(failed_calls == 2, "oversized checkpoints should stop after one bounded compression attempt")
assert(not failed.action, "failed compaction must preserve the original conversation")
assert(failed.display:find(" > 4000 tokens)", 1, true),
   "failure should report measured and configured checkpoint sizes")

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
assert(plain(usage.display):find("Prompt total: ~30 tokens", 1, true),
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
assert(usage_text:find("Prompt total: ~71 tokens", 1, true),
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

print("catalog command tests passed")
