-- Run with: lua tests/memory_test.lua
local command
local before_turn
local files = {}
local history = {}
local agent_prompts = {}
local agent_options = {}
local statuses = {}
local warnings = {}
local after_read_snapshot
local read_snapshots = {}

local function numbered_lines(text)
   text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
   if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
   local lines = {}
   local cursor = 1
   while cursor <= #text do
      local newline = text:find("\n", cursor, true)
      if newline then
         lines[#lines + 1] = text:sub(cursor, newline - 1)
         cursor = newline + 1
      else
         lines[#lines + 1] = text:sub(cursor)
         cursor = #text + 1
      end
   end
   return lines
end

local function encode(value)
   local fields = {}
   for _, key in ipairs({ "ts", "cwd", "content", "scope", "source", "last_conversation_id", "updated_at" }) do
      local item = value[key]
      if item ~= nil then
         local rendered = type(item) == "number" and tostring(item)
            or ('"' .. tostring(item)
               :gsub("\\", "\\\\")
               :gsub('"', '\\"')
               :gsub("\r", "\\r")
               :gsub("\n", "\\n") .. '"')
         fields[#fields + 1] = '"' .. key .. '":' .. rendered
      end
   end
   return "{" .. table.concat(fields, ",") .. "}"
end

cjson = {
   encode = encode,
   decode = function(raw)
      local decoded = {
         last_conversation_id = tonumber(raw:match('"last_conversation_id":(%d+)')),
         cwd = raw:match('"cwd":"([^"]*)"'),
         content = raw:match('"content":"([^"]*)"'),
         scope = raw:match('"scope":"([^"]*)"'),
         source = raw:match('"source":"([^"]*)"'),
      }
      return decoded
   end,
}

bone = {
   cwd = "/work/project",
   on = function(name, handler)
      assert(name == "before_turn")
      before_turn = handler
   end,
   command = {
      register = function(name, spec)
         assert(name == "memory")
         command = spec
      end,
   },
}

local ctx = {
   config_dir = "/config",
   cwd = "/work/project",
   fs = { is_file = function(path) return files[path] ~= nil end },
   read_file = function(path)
      assert(files[path] ~= nil, "missing file: " .. path)
      return files[path]
   end,
   write_file = function(path, content)
      assert(files[path] == nil, "write_file must not overwrite: " .. path)
      files[path] = content
   end,
   tools = {
      call = function(name, args)
         if name == "read_file" then
            local content = files[args.path]
            if content ~= nil then
               assert(args.start_line and args.start_line >= 1)
               assert(args.max_lines and args.max_lines >= 1 and args.max_lines <= 4,
                  "snapshot pages must stay below the read_file output cap")
               local lines = numbered_lines(content)
               local snapshot = read_snapshots[args.path]
               if not snapshot or snapshot.content ~= content then
                  snapshot = { content = content, seen = {} }
                  read_snapshots[args.path] = snapshot
               end
               local last = math.min(#lines, args.start_line + args.max_lines - 1)
               for i = args.start_line, last do
                  assert(utf8.len(lines[i]) <= 2000,
                     "snapshot included a non-editable line")
                  snapshot.seen[i] = true
               end
            end
            if after_read_snapshot then
               if after_read_snapshot(args.path) then
                  after_read_snapshot = nil
               end
            end
            return { ok = content ~= nil, content = content }
         end
         assert(name == "edit_file")
         assert(args.mode == nil and args.content == nil, "edit_file received obsolete rewrite arguments")
         assert(type(args.old_text) == "string" and type(args.new_text) == "string",
            "edit_file requires old_text and new_text")
         assert(files[args.path] == args.old_text, "edit_file snapshot mismatch")
         assert(args.old_text ~= args.new_text, "edit_file must not receive a no-op replacement")
         local snapshot = read_snapshots[args.path]
         assert(snapshot and snapshot.content == args.old_text,
            "edit_file requires a current whole-file snapshot")
         for i = 1, #numbered_lines(args.old_text) do
            assert(snapshot.seen[i], "snapshot omitted line " .. i)
         end
         files[args.path] = args.new_text
         return { ok = true, content = "updated" }
      end,
   },
   conversation = { history = function() return history end },
   db = { query = function() return {} end },
   agent = {
      run = function(prompt, opts)
         agent_prompts[#agent_prompts + 1] = prompt
         agent_options[#agent_options + 1] = opts
         local project = ""
         if prompt:find('"scope":"project"', 1, true) then
            project = "<!-- last_updated: 2026-07-16 -->\n## Workflow\n- test first"
         end
         return {
            ok = true,
            content = "---GLOBAL---\n<!-- last_updated: 2026-07-16 -->\n## Preferences\n- concise\n---PROJECT---\n"
               .. project .. "\n---END---",
         }
      end,
   },
   ui = { status = function(message) statuses[#statuses + 1] = message end },
   log = { warn = function(message) warnings[#warnings + 1] = message end },
}

assert(loadfile("commands/memory.lua"))()
assert(command, "memory command was not registered")
assert(command.description:find("global and current%-project memory"))
assert(command.description:find("both are injected into every turn", 1, true))
assert(before_turn, "before_turn hook was not registered")

-- Cheap capture queues explicit preference-like user messages.
history = { { role = "user", content = "Please remember that I prefer concise answers." } }
local action = before_turn(nil, ctx)
assert(action.system_prompt_append == nil)
local inbox = files["/config/memory/inbox.jsonl"]
assert(inbox and inbox:find("I prefer concise answers", 1, true))
assert(inbox:find('"source":"before_turn"', 1, true))

-- Manual remember accepts scope, merges queued data, stores scoped files, and clears inbox.
local result = command.handler("remember --global Avoid filler", ctx)
assert(result.submit == false)
assert(result.display == "Memory updated.")
assert(agent_prompts[#agent_prompts]:find('"scope":"global"', 1, true))
assert(files["/config/memory/global.md"]:find("concise", 1, true))
assert(files["/config/memory/projects/_work_project.md"] == nil,
   "global and unscoped inputs must not create project memory")
assert(agent_prompts[#agent_prompts]:find("Historical findings are global%-only"))
local merge_opts = agent_options[#agent_options]
assert(type(merge_opts.tools) == "table" and #merge_opts.tools == 0)
assert(merge_opts.max_tokens == 1400)
assert(merge_opts.system_prompt:find("Transform the supplied memory data", 1, true))
assert(merge_opts.wall_timeout_ms == 180000)
assert(files["/config/memory/inbox.jsonl"] == "")
assert(files["/config/memory/state.json"])
assert(statuses[1] == "Memory: finding new conversations…")
assert(statuses[2] == "Memory: processing 0 new conversation(s)…")
assert(statuses[3] == "Memory: updating scoped memory…")
assert(statuses[4] == "Memory: saving checkpoint…")

-- Project memory changes only from an explicitly project-scoped entry.
result = command.handler("remember --project Run tests first", ctx)
assert(result.display == "Memory updated.")
assert(agent_prompts[#agent_prompts]:find('"scope":"project"', 1, true))
assert(files["/config/memory/projects/_work_project.md"]:find("test first", 1, true))

-- The inbox remains bounded without evicting existing complete records.
local overflowed = false
for i = 1, 30 do
   local before = files["/config/memory/inbox.jsonl"]
   history = {
      {
         role = "user",
         content = "remember batch-" .. i .. " " .. string.rep("q", 1700),
      },
   }
   before_turn(nil, ctx)
   if files["/config/memory/inbox.jsonl"] == before then
      overflowed = true
      assert(warnings[#warnings]:find("inbox is full", 1, true))
      break
   end
end
local bounded_inbox = files["/config/memory/inbox.jsonl"]
assert(overflowed, "the test must fill the bounded inbox")
assert(#bounded_inbox <= 40000, #bounded_inbox)
assert(not bounded_inbox:find("batch%-30"),
   "a rejected append must not evict older entries")
for line in bounded_inbox:gmatch("[^\n]+") do
   assert(line:sub(1, 1) == "{" and line:sub(-1) == "}", "partial JSONL record")
   assert(utf8.len(line) <= 1900, "record exceeds the safe edit limit")
end
history = {}
assert(command.handler("", ctx).display == "No changes.")

-- Append retries from a fresh snapshot and does not lose a concurrent writer.
local other_entry = encode({
   ts = "2026-07-16T00:00:00Z", cwd = "/work/other",
   content = "Use the other workflow", scope = "project", source = "manual",
})
files["/config/memory/inbox.jsonl"] = other_entry .. "\n"
local concurrent_entry = encode({
   ts = "2026-07-16T00:00:01Z", cwd = "/work/project",
   content = "Prefer concurrent safety", scope = "global", source = "manual",
})
after_read_snapshot = function(path)
   if path ~= "/config/memory/inbox.jsonl" then return false end
   files[path] = files[path] .. concurrent_entry .. "\n"
   return true
end
history = { { role = "user", content = "Please remember direct answers." } }
before_turn(nil, ctx)
assert(after_read_snapshot == nil)
assert(files["/config/memory/inbox.jsonl"]:find("Prefer concurrent safety", 1, true))
assert(files["/config/memory/inbox.jsonl"]:find("remember direct answers", 1, true))

-- A consume conflict is fail-closed; both original and concurrent records remain.
local late_entry = encode({
   ts = "2026-07-16T00:00:02Z", cwd = "/work/project",
   content = "Prefer late writes", scope = "global", source = "manual",
})
after_read_snapshot = function(path)
   if path ~= "/config/memory/inbox.jsonl" then return false end
   files[path] = files[path] .. late_entry .. "\n"
   return true
end
history = {}
result = command.handler("", ctx)
assert(result.display:find("inbox checkpoint failed", 1, true))
assert(files["/config/memory/inbox.jsonl"]:find("Prefer concurrent safety", 1, true))
assert(files["/config/memory/inbox.jsonl"]:find("Prefer late writes", 1, true))
assert(command.handler("", ctx).display == "No changes.")
assert(files["/config/memory/inbox.jsonl"] == other_entry .. "\n")
assert(files["/config/memory/projects/_work_project.md"]:find("test first", 1, true),
   "a global-only update must not rewrite project memory")

-- A record below the inbox cap but above the host line limit is rejected safely.
local inbox_before_oversize = files["/config/memory/inbox.jsonl"]
result = command.handler("remember --global " .. string.rep("z", 2000), ctx)
assert(result.display:find("safe record size limit", 1, true))
assert(files["/config/memory/inbox.jsonl"] == inbox_before_oversize)

-- A memory file changed during the model call is never overwritten from stale input.
local global_entry = encode({
   ts = "2026-07-16T00:00:03Z", cwd = "/work/project",
   content = "Prefer stable updates", scope = "global", source = "manual",
})
files["/config/memory/inbox.jsonl"] = global_entry .. "\n"
local normal_agent_run = ctx.agent.run
ctx.agent.run = function(prompt, opts)
   agent_prompts[#agent_prompts + 1] = prompt
   agent_options[#agent_options + 1] = opts
   files["/config/memory/global.md"] =
      "<!-- last_updated: 2026-07-16 -->\n## Preferences\n- concurrent edit\n"
   return {
      ok = true,
      content = "---GLOBAL---\n<!-- last_updated: 2026-07-16 -->\n"
         .. "## Preferences\n- model edit\n---PROJECT---\n\n---END---",
   }
end
result = command.handler("", ctx)
assert(result.display:find("changed while memory was being updated", 1, true), result.display)
assert(files["/config/memory/global.md"]:find("concurrent edit", 1, true))
assert(files["/config/memory/inbox.jsonl"] == global_entry .. "\n")
ctx.agent.run = normal_agent_run
assert(command.handler("", ctx).display == "Memory updated.")
assert(files["/config/memory/inbox.jsonl"] == "")

-- Show aliases expose both scopes without submitting a turn.
for _, alias in ipairs({ "show", "view", "list" }) do
   local shown = command.handler(alias, ctx)
   assert(shown.submit == false)
   assert(shown.display:find("# User Memory", 1, true))
   assert(shown.display:find("## Global", 1, true))
   assert(shown.display:find("## Current project", 1, true))
end
local usage = command.handler("unknown", ctx)
assert(usage.display:find("Memory has two scopes", 1, true))
assert(usage.display:find("Global memory applies across all projects", 1, true))
assert(usage.display:find("Project memory applies only to the current working directory", 1, true))
assert(usage.display:find("both are injected into every turn", 1, true))
assert(usage.display:find("/memory remember [--global] <text>", 1, true))
assert(usage.display:find("/memory remember --project <text>", 1, true))

-- Injection is extension-owned and truncates each oversized scope safely.
files["/config/memory/global.md"] = string.rep("x", 2100)
files["/config/memory/projects/_work_project.md"] = string.rep("y", 2100)
history = {}
action = before_turn(nil, ctx)
assert(action.system_prompt_append:find("# User Memory", 1, true))
local global = action.system_prompt_append:match("## Global\n(.-)\n\n## Current project")
local project = action.system_prompt_append:match("## Current project\n(.+)$")
assert(#global == 2000 and global:sub(-3) == "...", #global)
assert(#project == 2000 and project:sub(-3) == "...", #project)

-- Legacy memory remains readable when scoped global memory is absent.
files["/config/memory/global.md"] = nil
files["/config/memory.md"] = "- preserved legacy preference"
action = before_turn(nil, ctx)
assert(action.system_prompt_append:find("preserved legacy preference", 1, true))

-- Extraction failures preserve the checkpoint and inbox so the batch can retry.
local state_path = "/config/memory/state.json"
local inbox_path = "/config/memory/inbox.jsonl"
files[state_path] = '{"last_conversation_id":0}\n'
files[inbox_path] = '{"content":"queued preference"}\n'
local state_before = files[state_path]
local inbox_before = files[inbox_path]
local message_query
ctx.db.query = function(sql)
   if sql:find("FROM conversations", 1, true) then
      return { { id = 7, started_at = "2026-07-17T00:00:00Z" } }
   end
   message_query = sql
   return { { role = "user", content = "I prefer small focused changes." } }
end
ctx.agent.run = function(prompt)
   agent_prompts[#agent_prompts + 1] = prompt
   return { ok = false, error = "temporary provider failure" }
end
result = command.handler("", ctx)
assert(result.submit == false)
assert(result.display:find("checkpoint and inbox unchanged", 1, true))
assert(files[state_path] == state_before)
assert(files[inbox_path] == inbox_before)
assert(message_query:find("role = 'user'", 1, true))
assert(agent_prompts[#agent_prompts]:find("durable global user preferences", 1, true))
assert(agent_prompts[#agent_prompts]:find("I prefer small focused changes", 1, true))
assert(#warnings > 0)

print("memory command tests passed")
