-- Run with: lua tests/memory_test.lua
local command
local before_turn
local files = {}
local history = {}
local agent_prompts = {}
local statuses = {}

local function encode(value)
   local fields = {}
   for _, key in ipairs({ "ts", "cwd", "content", "scope", "source", "last_conversation_id", "updated_at" }) do
      local item = value[key]
      if item ~= nil then
         local rendered = type(item) == "number" and tostring(item)
            or ('"' .. tostring(item):gsub('"', '\\"') .. '"')
         fields[#fields + 1] = '"' .. key .. '":' .. rendered
      end
   end
   return "{" .. table.concat(fields, ",") .. "}"
end

cjson = {
   encode = encode,
   decode = function() return { last_conversation_id = 0 } end,
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
            return { ok = files[args.path] ~= nil, content = files[args.path] }
         end
         assert(name == "edit_file")
         assert(args.mode == nil and args.content == nil, "edit_file received obsolete rewrite arguments")
         assert(type(args.old_text) == "string" and type(args.new_text) == "string",
            "edit_file requires old_text and new_text")
         assert(files[args.path] == args.old_text, "edit_file snapshot mismatch")
         files[args.path] = args.new_text
         return { ok = true, content = "updated" }
      end,
   },
   conversation = { history = function() return history end },
   db = { query = function() return {} end },
   agent = {
      run = function(prompt)
         agent_prompts[#agent_prompts + 1] = prompt
         return {
            ok = true,
            content = "---GLOBAL---\n<!-- last_updated: 2026-07-16 -->\n## Preferences\n- concise\n---PROJECT---\n<!-- last_updated: 2026-07-16 -->\n## Workflow\n- test first\n---END---",
         }
      end,
   },
   ui = { status = function(message) statuses[#statuses + 1] = message end },
   log = { warn = function(message) error(message) end },
}

assert(loadfile("commands/memory.lua"))()
assert(command, "memory command was not registered")
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
assert(files["/config/memory/projects/_work_project.md"]:find("test first", 1, true))
assert(files["/config/memory/inbox.jsonl"] == "")
assert(files["/config/memory/state.json"])
assert(statuses[1] == "Memory: finding new conversations…")
assert(statuses[2] == "Memory: processing 0 new conversation(s)…")
assert(statuses[3] == "Memory: updating scoped memory…")
assert(statuses[4] == "Memory: saving checkpoint…")

-- Show aliases expose both scopes without submitting a turn.
for _, alias in ipairs({ "show", "view", "list" }) do
   local shown = command.handler(alias, ctx)
   assert(shown.submit == false)
   assert(shown.display:find("# User Memory", 1, true))
   assert(shown.display:find("## Global", 1, true))
   assert(shown.display:find("## Current project", 1, true))
end
local usage = command.handler("unknown", ctx)
assert(usage.display:find("Usage: /memory", 1, true))

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

print("memory command tests passed")
