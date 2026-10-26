-- Standalone mocks; run from catalog root: luajit tests/recap_test.lua
local function fixture(settings)
  local f = { settings = settings or {}, events = {}, timers = {}, requests = 0, added = {} }
  bone = {
    -- No bone.o: the plugin must not register global TUI options.
    settings = { get = function(key) return f.settings[key] end },
    ui = { views = {} },
    chat = {
      session = function() return { session_id = "a", running = false } end,
      messages = function(cb)
        f.requests = f.requests + 1
        cb({ { role = "user", content = "Fix the bug" }, { role = "assistant", content = "Fixed" } })
      end,
      add = function(kind, item)
        assert(kind == "recap")
        f.added[#f.added + 1] = item.text
      end,
    },
    model = { complete = function(_, _, cb) cb({ content = " Fixed the bug. " }) end },
    cmd = { create = function(name, fn) assert(name == "recap"); f.command = fn end },
    on = function(event, fn) f.events[event] = fn end,
    defer = function(ms, fn) f.timers[#f.timers + 1] = { ms = ms, run = fn } end,
    notify = function(message) error(message) end,
    plugin = { on_shutdown = function() end },
  }
  function f.finish(status)
    f.events["turn/finished"]({ outcome = { status = status or "completed" } })
  end
  dofile("plugins/recap/ui.lua")
  return f
end

-- Automatic recaps stay off by default, but the command still works.
local f = fixture()
f.finish()
assert(#f.timers == 0)
f.command()
assert(f.requests == 1 and f.added[1] == "Fixed the bug.")

-- Namespaced settings enable automatic recaps and preserve the default delay.
f = fixture({ ["recap.auto"] = true })
f.finish()
assert(#f.timers == 1 and f.timers[1].ms == 900000)
f.timers[1].run()
assert(f.requests == 1 and f.added[1] == "Fixed the bug.")

-- Changes made on the plugin page are read at the next completed turn.
f.settings["recap.idle_ms"] = 1234
f.finish()
assert(f.timers[2].ms == 1234)
f.settings["recap.idle_ms"] = 0
f.finish()
assert(f.timers[3].ms == 0)
f.settings["recap.auto"] = false
f.finish()
assert(#f.timers == 3)

-- Failed turns do not schedule a recap; starting a new turn cancels stale work.
f = fixture({ ["recap.auto"] = true, ["recap.idle_ms"] = 500 })
f.finish("failed")
assert(#f.timers == 0)
f.finish()
f.events["turn/started"]()
f.timers[1].run()
assert(f.requests == 0)
print("recap plugin settings, defaults, command and idle scheduling OK")
