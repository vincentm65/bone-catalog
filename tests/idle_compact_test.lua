-- Standalone mocks; run from catalog root: lua tests/idle_compact_test.lua
-- Also works with LuaJIT; no server or third-party modules required.
local real_time = os.time
local function fixture()
  local f = { now = 0, state = {}, current = 0, timers = {}, requests = {},
    events = {}, notices = {}, settings = {}, chats = {
      [0] = { chat = 0, session_id = "a", title = "Chat A" },
      [1] = { chat = 1, session_id = "b", title = "Chat B" },
    } }
  os.time = function() return f.now end
  bone = {
    plugin = {
      state = function() return f.state end,
      on_shutdown = function(fn) f.shutdown = fn end,
    },
    settings = { get = function(key) return f.settings[key] end },
    chat = { session = function(opts)
      local s
      if not opts then s = f.chats[f.current]
      else
        for _, chat in pairs(f.chats) do
          if chat.session_id == opts.session then s = chat; break end
        end
        s = s or f.chats[tonumber(opts.session)]
      end
      if not s then return end
      local copy = {}; for k, v in pairs(s) do copy[k] = v end
      return copy -- Real APIs return snapshots, not live mutable state.
    end },
    on = function(event, fn) f.events[event] = fn end,
    defer = function(ms, fn)
      assert(ms == 60000); f.timers[#f.timers + 1] = fn
    end,
    request = function(method, args, cb)
      assert(method == "store/query" or method == "session/compact")
      f.requests[#f.requests + 1] = { method = method, args = args, cb = cb }
    end,
    notify = function(text, level) f.notices[#f.notices + 1] = { text, level } end,
    util = { tokens = tostring },
  }
  function f.emit(event, sid) f.events[event]({ session_id = sid }) end
  function f.submit(chat)
    if chat ~= nil then f.current = chat end
    f.emit("submit")
  end
  function f.tick(seconds)
    f.now = f.now + (seconds or 60)
    assert(table.remove(f.timers, 1), "missing timer")()
  end
  function f.reply(method, result, err)
    local request = assert(table.remove(f.requests, 1), "missing " .. method)
    assert(request.method == method, request.method)
    request.cb(result, err)
    return request.args
  end
  function f.usage(tokens, err)
    return f.reply("store/query", { rows = tokens and { { tokens } } or {} }, err)
  end
  function f.compact(err)
    return f.reply("session/compact", err and nil or { tokens_before = 60000, tokens_after = 4000 }, err)
  end
  function f.idle()
    f.submit(); f.tick(45 * 60)
    assert(#f.requests == 1 and f.requests[1].method == "store/query")
  end
  dofile("plugins/idle_compact/tui.lua")
  return f
end

-- Defaults, request targeting, no duplicates during either asynchronous phase,
-- success marks done on the notification or reply; a new reply resets idle.
local f = fixture()
f.submit(); f.tick(44 * 60); assert(#f.requests == 0)
f.tick(); f.tick(); f.tick(); assert(#f.requests == 1)
assert(f.usage("60000").params[1] == "a")
assert(not f.state.last.done)
f.tick(); f.tick(); assert(#f.requests == 1)
f.emit("session/compacted", "a"); assert(f.state.last.done)
assert(f.compact().session_id == "a")
assert(f.state.last.done and #f.notices == 1)
assert(f.notices[1][1]:find("Chat A", 1, true))
f.tick(3600); assert(#f.requests == 0)
f.emit("turn/finished", "a"); f.tick(44 * 60); assert(#f.requests == 0)
f.tick(); assert(#f.requests == 1)
print("idle defaults, async deduplication, success and reply reset OK")

-- Revalidate ALL idle predicates after the usage query, not just before it.
local invalidations = {
  closed = function(x) x.chats[0] = nil end,
  running = function(x) x.chats[0].running = true end,
  starting = function(x) x.chats[0].starting = true end,
  reply = function(x) x.emit("turn/finished", "a") end,
  submitted = function(x) x.submit() end,
  other_candidate = function(x) x.submit(1) end,
  compacted = function(x) x.emit("session/compacted", "a") end,
  longer_timeout = function(x) x.settings["idle_compact.minutes"] = 90 end,
  shutdown = function(x) x.shutdown() end,
}
for name, change in pairs(invalidations) do
  f = fixture(); f.idle(); change(f); f.usage(60000)
  assert(#f.requests == 0 and #f.notices == 0, name)
end
-- In particular, turn/finished mutates the same candidate table in place.
f = fixture(); f.idle(); local last = f.state.last
f.emit("turn/finished", "a"); assert(f.state.last == last)
f.usage(60000); f.tick(45 * 60); assert(#f.requests == 1)
f.usage(60000); assert(#f.requests == 1)
print("delayed usage revalidates open/running/starting/elapsed/candidate/done/lifecycle OK")

-- Low/missing/failed usage results release the guard and retry on a later tick.
for _, tokens in ipairs({ false, 49999, "invalid" }) do
  f = fixture(); f.idle(); f.usage(tokens or nil)
  assert(#f.requests == 0 and not f.state.last.done)
  f.tick(); assert(#f.requests == 1)
end
f = fixture(); f.idle(); f.usage(60000, { message = "query failed" })
assert(#f.requests == 0 and not f.state.last.done)
f.tick(); f.settings["idle_compact.threshold"] = 70000
f.usage(60000); assert(#f.requests == 0)
f.settings["idle_compact.threshold"] = 50000
f.tick(); f.usage(50000); assert(#f.requests == 1)
print("missing/low/invalid/error usage and live threshold settings OK")

-- A failed compaction must NOT mark the idle stretch done, and must retry.
for _, err in ipairs({ "compact failed", { message = "compact failed" } }) do
  f = fixture(); f.idle(); f.usage(60000)
  f.tick(); assert(#f.requests == 1)
  f.compact(err)
  assert(not f.state.last.done and f.notices[1][2] == "error")
  assert(f.notices[1][1]:find("compact failed", 1, true))
  f.tick(); f.usage(60000); f.compact()
  assert(f.state.last.done and #f.notices == 2)
end
print("compaction errors release pending and retry without marking done OK")

-- Activity during compaction must not let its notification (which the core
-- emits before the RPC reply) or callback mark a newer stretch done.
-- The per-session guard still prevents another pending request.
for _, event in ipairs({ "submit", "turn/finished" }) do
  f = fixture(); f.idle(); f.usage(60000)
  f.now = f.now + 1; f.emit(event, "a")
  f.tick(45 * 60); assert(#f.requests == 1)
  f.emit("session/compacted", "a"); assert(not f.state.last.done, event)
  f.compact(); assert(not f.state.last.done, event)
  f.tick(); assert(#f.requests == 1)
end
f = fixture(); f.idle(); f.usage(60000); f.shutdown(); f.compact()
assert(not f.state.last.done and #f.notices == 0)
f.tick(); assert(#f.requests == 0 and #f.timers == 0)
print("late compaction notifications/callbacks preserve newer activity and respect shutdown OK")

-- External compaction still ends an ordinary idle stretch without a request.
f = fixture(); f.submit(); f.emit("session/compacted", "a")
assert(f.state.last.done)
f.tick(45 * 60); assert(#f.requests == 0)
print("external compaction during ordinary idle marks done OK")

-- A new chat already has a stable buffer number (including zero) at submit.
-- The create response assigns its session before turn/started handlers run.
-- Focus and unrelated server events must not change which chat we submitted to.
f = fixture(); f.chats[0].session_id = nil
f.submit(0); assert(f.state.last.chat == 0 and not f.state.last.session_id)
f.current = 1
f.emit("turn/started", "b"); assert(not f.state.last.session_id)
f.chats[0].session_id = "new-a"
f.emit("turn/started", "new-a"); assert(f.state.last.session_id == "new-a")
f.now = 100; f.emit("turn/finished", "new-a"); assert(f.state.last.at == 100)
f.tick(45 * 60); assert(f.usage(60000).params[1] == "new-a")
assert(f.compact().session_id == "new-a")
assert(f.current == 1 and f.state.last.done)
-- A later submission supersedes an unresolved new chat, never rebound by it.
f = fixture(); f.chats[0].session_id = nil
f.submit(0); f.submit(1); f.chats[0].session_id = "new-a"
f.emit("turn/started", "new-a"); assert(f.state.last.session_id == "b")
f.tick(45 * 60); assert(f.usage(60000).params[1] == "b")
-- A missing captured buffer must not fall back to the focused chat.
f = fixture(); f.chats[0].session_id = nil; f.submit(0)
f.current = 1; f.chats[0] = nil; f.emit("turn/started", "b")
assert(not f.state.last.session_id)
print("new-chat identity survives focus changes; unrelated/obsolete events ignored OK")
os.time = real_time
print("idle_compact: all regressions passed")
