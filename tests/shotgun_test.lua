local command
local page

bone = {
  command = {
    register = function(name, spec)
      assert(name == "shotgun")
      command = spec
    end,
  },
  settings = {
    register = function(spec) page = spec end,
  },
}

assert(loadfile("commands/shotgun.lua"))()
assert(command, "shotgun command was not registered")
assert(page and page.namespace == "shotgun")
assert(#page.fields == 1 and page.fields[1].key == "targets")
assert(page.fields[1].type == "string" and page.fields[1].default == "")

local empty = command.handler("prompt", {
  config = { get = function() return "" end },
})
assert(empty.submit == false)
assert(empty.display:find("/config", 1, true))

local spawned = {}
local result = command.handler("compare these", {
  config = {
    get = function(ns, key)
      assert(ns == "shotgun" and key == "targets")
      return "deepseek, openrouter/anthropic/claude-sonnet-4"
    end,
    list_providers = function()
      return {
        { id = "deepseek", model = "deepseek-chat" },
        { id = "openrouter", model = "default-model" },
      }
    end,
  },
  agent = {
    spawn = function(_, opts)
      spawned[#spawned + 1] = opts
      return { ok = true, id = "job-" .. #spawned }
    end,
    wait = function()
      return {
        jobs = {
          { id = "job-1", status = "done", result = "first answer" },
          { id = "job-2", status = "done", result = "second answer" },
        },
        pending = {},
      }
    end,
    cancel = function() end,
  },
})

assert(#spawned == 2)
assert(spawned[1].provider == "deepseek" and spawned[1].model == nil)
assert(spawned[2].provider == "openrouter")
assert(spawned[2].model == "anthropic/claude-sonnet-4")
assert(result.submit == true)
assert(result.content:find("first answer", 1, true))
assert(result.content:find("second answer", 1, true))
assert(result.content:find("## Reviewer 1", 1, true))
assert(result.content:find("## Reviewer 2", 1, true))

local cancelled_ids = {}
local wait_calls = 0
local cancelled = command.handler("cancel this", {
  config = {
    get = function() return "deepseek, openrouter" end,
    list_providers = function()
      return {
        { id = "deepseek", model = "deepseek-chat" },
        { id = "openrouter", model = "default-model" },
      }
    end,
  },
  agent = {
    spawn = function(_, opts)
      return { ok = true, id = opts.provider .. "-job" }
    end,
    wait = function()
      wait_calls = wait_calls + 1
      if wait_calls == 1 then
        return {
          cancelled = true,
          jobs = {},
          pending = { "deepseek-job", "openrouter-job" },
        }
      end
      return { jobs = {}, pending = {} }
    end,
    cancel = function(id) cancelled_ids[#cancelled_ids + 1] = id end,
  },
})
assert(cancelled.submit == false and cancelled.display == "shotgun: cancelled")
assert(table.concat(cancelled_ids, ",") == "deepseek-job,openrouter-job",
  "cancelling shotgun must cancel every pending reviewer")
assert(wait_calls == 2, "cancelled reviewer jobs should be drained")

local large_targets = {}
local large_providers = {}
for i = 1, 30 do
  large_targets[#large_targets + 1] = "p" .. i
  large_providers[#large_providers + 1] = { id = "p" .. i, model = "m" .. i }
end
local next_job = 0
local large = command.handler("large synthesis", {
  config = {
    get = function() return table.concat(large_targets, ",") end,
    list_providers = function() return large_providers end,
  },
  agent = {
    spawn = function()
      next_job = next_job + 1
      return { ok = true, id = "large-" .. next_job }
    end,
    wait = function(ids)
      local jobs = {}
      for _, id in ipairs(ids) do
        jobs[#jobs + 1] = { id = id, status = "done", result = string.rep("→", 50000) }
      end
      return { jobs = jobs, pending = {} }
    end,
    cancel = function() end,
  },
})
assert(large.submit == true)
assert(large.content:find("## Reviewer 30", 1, true),
  "reviewer labels must remain valid beyond 26 targets")
assert(#large.content <= 100100, "synthesis prompt must have an aggregate size bound")
assert(utf8.len(large.content), "reviewer truncation must not split UTF-8 code points")

print("shotgun command tests passed")
