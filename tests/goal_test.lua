-- Run with: lua tests/goal_test.lua
local command
local hooks = {}
local submitted = {}
local logs = { info = {}, warn = {} }

bone = {
  agent_depth = 0,
  command = {
    register = function(name, spec)
      assert(name == "goal")
      command = spec
    end,
  },
  on = function(name, handler) hooks[name] = handler end,
  submit = function(prompt) submitted[#submitted + 1] = prompt end,
  log = {
    info = function(message) logs.info[#logs.info + 1] = message end,
    warn = function(message) logs.warn[#logs.warn + 1] = message end,
  },
}

assert(loadfile("commands/goal.lua"))()
assert(command and hooks.before_turn and hooks.turn_end)

local files = {}
local tool_calls = {}
local edit_error
local read_error
local metadata_sizes = {}
local snapshots = {}

local function normalize_text(text)
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function numbered_lines(text)
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

local function ctx(id)
  return {
    config_dir = "/config",
    session = { current = function() return { id = id } end },
    fs = {
      exists = function(path) return files[path] ~= nil end,
      metadata = function(path)
        return { len = metadata_sizes[path] or #assert(files[path]) }
      end,
    },
    read_file = function(path)
      if read_error then error(read_error) end
      assert(files[path] ~= nil, "missing file " .. path)
      return files[path]
    end,
    create_file = function(path, content)
      assert(files[path] == nil)
      files[path] = content
      return true
    end,
    tools = {
      call = function(name, args, opts)
        tool_calls[#tool_calls + 1] = { name = name, args = args, opts = opts }
        if name == "read_file" then
          local content = normalize_text(assert(files[args.path]))
          local lines = numbered_lines(content)
          local snapshot = snapshots[args.path]
          if not snapshot or snapshot.text ~= content then
            snapshot = { text = content, seen = {} }
            snapshots[args.path] = snapshot
          end
          local first = args.start_line or 1
          local last = math.min(#lines, first + (args.max_lines or 1000) - 1)
          for line = first, last do
            if utf8.len(lines[line]) <= 2000 then snapshot.seen[line] = true end
          end
          if #lines == 0 then
            return { ok = true, content = "Range: empty file; 0 lines total" }
          end
          return {
            ok = true,
            content = string.format("Range: lines %d-%d of %d", first, last, #lines),
          }
        end
        assert(name == "edit_file")
        assert(args.mode == nil and args.content == nil)
        assert(args.old_text == files[args.path])
        assert(type(args.new_text) == "string")
        if edit_error then return { ok = false, content = edit_error, is_error = true } end
        local old = normalize_text(args.old_text)
        local snapshot = snapshots[args.path]
        if not snapshot or snapshot.text ~= old then
          return { ok = false, content = "file changed since read", is_error = true }
        end
        for line = 1, #numbered_lines(old) do
          if not snapshot.seen[line] then
            return {
              ok = false,
              content = "old_text includes lines that were not shown",
              is_error = true,
            }
          end
        end
        files[args.path] = args.new_text
        return { ok = true, content = "edited" }
      end,
    },
  }
end

local first = command.handler("ship the feature", ctx(7))
assert(type(first) == "string" and first:find("turn message", 1, true))
local path = "/config/goals/7.md"
assert(files[path] and files[path]:find("ship the feature", 1, true))

local rejected_new = command.handler(string.rep("x", 2001), ctx(9))
assert(rejected_new.submit == false)
assert(rejected_new.display:find("new goal file line", 1, true))
assert(files["/config/goals/9.md"] == nil,
  "new goals must not create files that native edit_file cannot replace later")

tool_calls = {}
local replaced = command.handler("replace the feature", ctx(7))
assert(type(replaced) == "string")
assert(#tool_calls == 2)
assert(tool_calls[1].name == "read_file")
assert(tool_calls[1].opts.approval == "read_only")
assert(tool_calls[2].name == "edit_file")
assert(tool_calls[2].opts.approval == "danger")
assert(files[path]:find("replace the feature", 1, true))

local progress = {}
for i = 1, 1205 do progress[i] = "progress " .. i end
files[path] = table.concat(progress, "\n")
snapshots[path] = nil
tool_calls = {}
local long_replaced = command.handler("replace a long goal file", ctx(7))
assert(type(long_replaced) == "string")
assert(#tool_calls == 3)
assert(tool_calls[1].name == "read_file" and tool_calls[1].args.start_line == 1)
assert(tool_calls[2].name == "read_file" and tool_calls[2].args.start_line == 1001,
  "whole-file replacement must expose every native read_file range")
assert(tool_calls[3].name == "edit_file")

files[path] = "# Goal\n" .. string.rep("x", 2001) .. "\n"
snapshots[path] = nil
local overlong = command.handler("must diagnose an overlong line", ctx(7))
assert(overlong.submit == false)
assert(overlong.display:find("line 2", 1, true) and overlong.display:find("2000", 1, true),
  "non-editable native read_file lines need an actionable diagnostic")

files[path] = "# Goal\n\nsmall\n"
metadata_sizes[path] = 50 * 1024 * 1024 + 1
local oversized = command.handler("must diagnose an oversized file", ctx(7))
assert(oversized.submit == false)
assert(oversized.display:find("read_file's limit", 1, true))
metadata_sizes[path] = nil

edit_error = "approval denied"
local failed = command.handler("must not activate", ctx(7))
assert(failed.submit == false)
assert(failed.display:find("approval denied", 1, true))
assert(hooks.before_turn(nil, ctx(7)) == nil, "failed persistence must leave the loop stopped")
edit_error = nil

assert(type(command.handler("working goal", ctx(7))) == "string")
local injected = hooks.before_turn(nil, ctx(7))
assert(injected.turn_message:find("File: `/config/goals/7.md`", 1, true))
assert(injected.turn_message:find("Call read_file", 1, true))

hooks.turn_end({
  ok = true,
  content = "An example is GOAL_STATUS: done\n\nGOAL_STATUS: working",
})
assert(#submitted == 1 and submitted[1] == "Continue the goal.")
hooks.turn_end({ ok = true, content = "Finished.\n\nGOAL_STATUS: done\n" })
assert(#submitted == 1, "only a final-line done sentinel may complete the goal")
assert(hooks.before_turn(nil, ctx(7)) == nil)

assert(type(command.handler("unreadable goal", ctx(7))) == "string")
read_error = "disk unavailable"
local halted = hooks.before_turn(nil, ctx(7))
assert(halted.turn_message:find("loop was halted", 1, true))
hooks.turn_end({ ok = true, content = "GOAL_STATUS: working" })
assert(#submitted == 1, "a source read failure must stop continuation")
read_error = nil

assert(type(command.handler("session-bound goal", ctx(7))) == "string")
assert(hooks.before_turn(nil, ctx(8)) == nil)
hooks.turn_end({ ok = true, content = "GOAL_STATUS: working" })
assert(#submitted == 1, "switching conversations must stop the prior loop")

print("goal command tests passed")
