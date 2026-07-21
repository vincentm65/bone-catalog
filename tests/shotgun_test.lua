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
  settings = { get = function() return "" end },
})
assert(empty.submit == false)
assert(empty.display:find("/config", 1, true))

local spawned = {}
local result = command.handler("compare these", {
  settings = {
    get = function(path)
      assert(path == "shotgun.targets")
      return "deepseek, openrouter/anthropic/claude-sonnet-4"
    end,
  },
  config = {
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

print("shotgun command tests passed")
