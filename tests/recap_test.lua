-- Standalone mocks; run from catalog root: luajit tests/recap_test.lua
local function fixture(settings)
  local f = { settings = settings or {}, events = {}, timers = {}, requests = 0, added = {} }
  bone = {
    -- No bone.o: the plugin must not register global TUI options.
    settings = { get = function(key) return f.settings[key] end },
    ui = { views = {} },
    chat = {
      session = function(opts)
        local id = opts and opts.session or "a"
        return { session_id = id, running = f.running == id }
      end,
      messages = function(session_id, cb)
        if type(session_id) == "function" then session_id, cb = nil, session_id end
        f.requests = f.requests + 1
        f.asked = session_id
        cb({ { role = "user", content = "Fix the bug" }, { role = "assistant", content = "Fixed" } })
      end,
      add = function(kind, item, opts)
        assert(kind == "recap")
        f.added[#f.added + 1] = item.text
        f.added_session = opts and opts.session
      end,
    },
    model = { complete = function(_, _, cb) cb({ content = " Fixed the bug. " }) end },
    cmd = { create = function(name, fn) assert(name == "recap"); f.command = fn end },
    on = function(event, fn) f.events[event] = fn end,
    defer = function(ms, fn) f.timers[#f.timers + 1] = { ms = ms, run = fn } end,
    notify = function(message) error(message) end,
    plugin = { on_shutdown = function() end },
  }
  function f.finish(status, sid)
    f.events["turn/finished"]({
      session_id = sid or "a", outcome = { status = status or "completed" },
    })
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
assert(f.requests == 1 and f.added[1] == "Fixed the bug." and f.asked == "a" and f.added_session == "a")

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
f.events["turn/started"]({ session_id = "a" })
f.timers[1].run()
assert(f.requests == 0)
-- A turn in another chat does not cancel this one, and the recap stays on it.
f.finish(nil, "a")
f.events["turn/started"]({ session_id = "b" })
f.timers[2].run()
assert(f.requests == 1 and f.asked == "a" and f.added_session == "a")
print("recap plugin settings, defaults, command and idle scheduling OK")
