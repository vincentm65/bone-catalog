-- Run from the catalog root: luajit tests/subagent_test.lua
local hooks, tool, limit, created = {}, nil, nil, 0
local settings, rpc = {}, {}
local run_impl = function() return { text = "done", outcome = { status = "completed" } } end
bone = {
  config = {},
  settings = { get = function(path)
    if path == "subagent.max_depth" then return limit end
    return settings[path:gsub("^subagent%.", "")]
  end },
  hook = function(name, fn) hooks[name] = fn end,
  tool = { register = function(spec) tool = spec end },
  rpc = { register = function(name, fn) rpc[name] = fn end },
  session = {
    create = function()
      created = created + 1
      return { session_id = "child" .. created }
    end,
    run = function(id) return run_impl(id) end,
  },
}
dofile("plugins/subagent/core.lua")

local function visible(id)
  local result = hooks.request({ session_id = id, tools = {
    { name = "subagent", description = "delegate", parameters = { properties = {} } },
    { name = "read_file" },
  } })
  assert(result.tools[#result.tools].name == "read_file", "other tools remain available")
  return result.tools[1].name == "subagent"
end
local function spawn(id, allowed)
  local before = created
  local result, err = tool.run({ task = "test", prompt = "test" }, { session_id = id })
  if allowed then
    assert(result == "done", err)
    return "child" .. created
  end
  assert(result == nil and err:find("this deep", 1, true))
  assert(created == before, "denied calls must not create sessions")
end

-- Unset settings preserve the old two-level default.
assert(visible("root"))
local child = spawn("root", true)
assert(visible(child))
local grandchild = spawn(child, true)
assert(not visible(grandchild))
spawn(grandchild, false)

-- Zero must not fall back to the default.
limit = 0
assert(not visible("root"))
spawn("root", false)

-- Settings affect existing sessions without reloading.
limit = 1
assert(visible("root"))
assert(not visible(child))
spawn(child, false)
spawn("root", true)
limit = 3
assert(visible(grandchild))
local greatgrandchild = spawn(grandchild, true)
assert(not visible(greatgrandchild))
spawn(greatgrandchild, false)

-- Reset restores the default immediately.
limit = nil
assert(visible(child))
assert(not visible(grandchild))
spawn(grandchild, false)
-- Nesting toggle clamps depth, but must not override depth zero.
limit, settings.allow_nested = 3, false
assert(visible("root") and not visible(child))
spawn(child, false)
limit = 0
assert(not visible("root"))
settings.allow_nested, limit = true, nil

-- Default provider/model/instructions/tool restrictions apply only to children.
settings.provider, settings.model, settings.system = "fast", "small-model", "Default instructions"
settings.tools = "read_file, shell"
local root_request = hooks.request({ session_id = "root", tools = {} })
assert(root_request.provider == nil and root_request.model == nil)
local child_request = hooks.request({ session_id = child, tools = {
  { name = "read_file" }, { name = "shell" }, { name = "write_file" }, { name = "subagent" },
} })
assert(child_request.provider == "fast" and child_request.model == "small-model")
assert(#child_request.tools == 2)
assert(hooks.system({ session_id = child, prompt = "base" }).prompt == "Default instructions\n\nbase")
assert(hooks.tool_call({ session_id = child, name = "write_file" }).deny)
assert(hooks.tool_call({ session_id = "root", name = "write_file" }) == nil)
local result, err = tool.run({ prompt = "test" }, { session_id = child })
assert(result == nil and err:find("not allowed", 1, true))

-- Saved named agents override legacy names and defaults, and appear live.
bone.config.subagents.reviewer = { provider = "legacy" }
settings.agents = { reviewer = {
  description = "Review bugs", system = "Review carefully", provider = "precise",
  model = "large-model", tools = { "read_file" },
} }
assert(tool.run({ name = "reviewer", prompt = "test" }, { session_id = "root" }) == "done")
local reviewer = "child" .. created
local review_request = hooks.request({ session_id = reviewer, tools = { { name = "read_file" }, { name = "shell" } } })
assert(review_request.provider == "precise" and review_request.model == "large-model")
assert(#review_request.tools == 1)
assert(hooks.system({ session_id = reviewer, prompt = "base" }).prompt == "Review carefully\n\nbase")
assert(rpc["subagent/list"]()[1].model == "large-model")
local named_tool = { name = "subagent", description = "delegate", parameters = { properties = {} } }
assert(hooks.request({ session_id = "root", tools = { named_tool } }).tools[1].parameters.properties.name)
assert(named_tool.description:find("reviewer: Review bugs", 1, true))
settings.agents, bone.config.subagents = {}, {}
assert(hooks.request({ session_id = "root", tools = { named_tool } }).tools[1].parameters.properties.name == nil)
settings.agents = { researcher = {} }
assert(hooks.request({ session_id = "root", tools = { named_tool } }).tools[1].parameters.properties.name)
settings.agents = { bad = { tools = "wrong" } }
assert(hooks.request({ session_id = "root", tools = {} }).deny)
result, err = tool.run({ prompt = "test" }, { session_id = "root" })
assert(result == nil and err:find("invalid tools", 1, true))
settings.agents, settings.tools = nil, nil

-- Concurrent reservations are global, fail fast, and are released on finish.
settings.max_concurrent = 1
run_impl = function(id)
  coroutine.yield(id)
  return { text = "done", outcome = { status = "completed" } }
end
local co = coroutine.create(function() return tool.run({ prompt = "test" }, { session_id = "root" }) end)
local ok, running = coroutine.resume(co)
assert(ok and coroutine.status(co) == "suspended")
local before = created
result, err = tool.run({ prompt = "test" }, { session_id = "other-root" })
assert(result == nil and err:find("maximum concurrent", 1, true) and created == before)
assert(coroutine.resume(co))
assert(coroutine.status(co) == "dead")

-- Errors/cancellation do not leak the reserved slot.
run_impl = function() error("run exploded") end
result, err = tool.run({ prompt = "test" }, { session_id = "root" })
assert(result == nil and err:find("run exploded", 1, true))
run_impl = function() return nil, "cancelled" end
result, err = tool.run({ prompt = "test" }, { session_id = "root" })
assert(result == nil and err == "cancelled")
run_impl = function(id) coroutine.yield(id); return nil end
co = coroutine.create(function() return tool.run({ prompt = "test" }, { session_id = "root" }) end)
ok, running = coroutine.resume(co)
assert(ok)
hooks.turn_end({ session_id = "root" })
assert(coroutine.resume(co))
run_impl = function() return { text = "done", outcome = { status = "completed" } } end
result, err = tool.run({ prompt = "test" }, { session_id = "other-root" })
assert(result == nil and err:find("maximum concurrent", 1, true), "cancelled child is still stopping")
hooks.turn_end({ session_id = running })
spawn("other-root", true)
spawn("root", true)

-- Named specs are snapshots; explicit wildcard and deny-all override defaults.
bone.config.subagents.legacy = { tools = { "read_file" } }
assert(tool.run({ name = "legacy", prompt = "test" }, { session_id = "root" }) == "done")
local legacy = "child" .. created
bone.config.subagents.legacy.tools[1] = "*"
assert(hooks.tool_call({ session_id = legacy, name = "shell" }).deny)
settings.tools = "read_file"
settings.agents = { all = { tools = { "*" } }, none = { tools = {} } }
assert(tool.run({ name = "all", prompt = "test" }, { session_id = "root" }) == "done")
assert(hooks.tool_call({ session_id = "child" .. created, name = "shell" }) == nil)
assert(tool.run({ name = "none", prompt = "test" }, { session_id = "root" }) == "done")
assert(hooks.tool_call({ session_id = "child" .. created, name = "read_file" }).deny)
settings.tools, settings.agents = nil, nil

-- Invalid numeric settings fall back instead of crashing.
limit, settings.max_concurrent = "invalid", false
assert(visible("root") and not visible(grandchild))
print("subagent settings, agents, and concurrency tests passed")
