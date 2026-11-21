-- Standalone mocks; run from catalog root: luajit tests/chat_titler_test.lua

local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3
      or (c >= 0xF0 and c < 0xF5) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local b = s:byte(j)
      if b < 0x80 or b > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end

-- Core half ---------------------------------------------------------------

local C -- the core fixture
local function core(opts)
  opts = opts or {}
  C = {
    rpc = {}, settings = opts.settings or {}, sessions = {}, calls = {}, saved = 0,
    state = opts.state or {},
    models = opts.models or {
      { name = "local", model = "flash", current = true, reasoning_effort = "medium" },
      { name = "cheap", model = "mini" },
    },
    reply = opts.reply or "Fix login redirect bug",
  }
  bone = {
    state = {
      load = function(name) assert(name == "chat-titler"); return C.state end,
      save = function(name, s) assert(name == "chat-titler" and s.named); C.saved = C.saved + 1 end,
    },
    settings = { get = function(key) return C.settings[key] end },
    rpc = { register = function(name, fn) C.rpc[name] = fn end },
    session = {
      snapshot = function(id)
        local s = assert(C.sessions[id], "no session " .. id)
        return copy({ info = s.info, messages = s.messages, model = s.model })
      end,
      info = function(id)
        if C.on_info then C.on_info(id) end
        return copy(C.sessions[id].info)
      end,
    },
    model = {
      list = function() return copy(C.models) end,
      complete = function(req)
        C.calls[#C.calls + 1] = req
        for _, m in ipairs(req.messages) do assert(valid_utf8(m.content), "invalid UTF-8 sent to the model") end
        if C.fail then return nil, C.fail end
        return { content = type(C.reply) == "function" and C.reply(req) or C.reply }
      end,
    },
  }
  C.mod = dofile("plugins/chat-titler/core.lua")
  return C
end

local function chat(id, first, extra)
  local s = { info = { session_id = id, cwd = "/w", title = nil }, messages = {
    { role = "user", content = first },
    { role = "assistant", content = "", tool_calls = { { id = "t1", name = "shell" } } },
    { role = "tool", call_id = "t1", content = "ok" },
    { role = "assistant", content = "Fixed the redirect in auth.ts." },
  } }
  s.info.title = C.mod.derived_title(s.messages)
  for k, v in pairs(extra or {}) do s.info[k] = v end
  C.sessions[id] = s
  return s
end

local function call(args) return C.rpc["chat-titler.title"](args) end

-- derived_title matches the core's title_of (session.rs), including the cut
-- at 80 characters that 1.0.x missed (it looked for a utf8 library LuaJIT
-- does not have, so every long first line counted as a hand rename).
core()
local d = C.mod.derived_title
-- Real titles from the core's index.
assert(d({ { role = "user", content = "is our chat titler plugin neweer on catalog or locally. spawna subagent to reviee it" } })
  == "is our chat titler plugin neweer on catalog or locally. spawna subagent to revie…")
assert(d({ { role = "user", content = "Hi" } }) == "Hi")
assert(d({ { role = "assistant", content = "x" }, { role = "user", content = "\n \t\n  fix the bug  \r\nplease" } }) == "fix the bug")
assert(d({ { role = "user", content = "\194\160 spaced\226\128\131" } }) == "spaced") -- NBSP, em space
assert(d({ { role = "user", content = "  ", images = { { name = "Screenshot 1" } } } }) == "Screenshot 1")
assert(d({ { role = "user", content = "" } }) == nil)
local cjk = string.rep("修复聊天标题", 20) -- 120 characters
local t = d({ { role = "user", content = cjk } })
assert(valid_utf8(t) and t == string.rep("修复聊天标题", 13) .. "修复…", t)
assert(d({ { role = "user", content = string.rep("a", 80) } }) == string.rep("a", 80))
assert(d({ { role = "user", content = string.rep("a", 81) } }) == string.rep("a", 80) .. "…")

-- clean: one line, no label, quotes, markdown or closing period, cut at a
-- word on a character boundary.
local clean = C.mod.clean
assert(clean('"Fix login bug."', 48) == "Fix login bug")
assert(clean("“Fix login bug”", 48) == "Fix login bug")
assert(clean("Title: **Fix login bug**\n\nThis names the task.", 48) == "Fix login bug")
assert(clean("<think>hmm</think>\n# Fix login bug", 48) == "Fix login bug")
assert(clean("Why are chats untitled?", 48) == "Why are chats untitled?")
assert(clean("€uro pricing table", 48) == "€uro pricing table") -- 1.0.x ate half the €
assert(clean("ab cd ef gh ijklmnop", 10) == "ab cd ef…")
assert(clean("abcdefghijklmnopqrstuvwxyz", 10) == "abcdefghi…")
t = clean("修复聊天标题问题的代码示例", 7)
assert(valid_utf8(t) and t == "修复聊天标题…", t)
assert(clean("   \n  ", 48) == "")

-- A new chat gets a title from the chat's own provider, low effort, and the
-- prompt ends with the user's turn (no assistant prefill).
core()
chat("a", "the login page redirects forever after the oauth callback, can you look")
local r = call({ session_id = "a", turn_id = 1, indexed = true })
assert(r.title == "Fix login redirect bug" and r.provider == "local", tostring(r.skip))
local req = C.calls[1]
assert(req.provider == "local" and req.options.reasoning_effort == "low" and not req.options.model)
assert(#req.messages == 2 and req.messages[2].role == "user")
assert(req.messages[2].content:find("User: the login page", 1, true))
assert(req.messages[2].content:find("Assistant: Fixed the redirect", 1, true))
assert(not req.messages[2].content:find("is titled", 1, true))
assert(C.state.named.a.title == "Fix login redirect bug" and C.saved == 1)

-- Another window's call for the same turn makes no second model call.
assert(call({ session_id = "a", turn_id = 1, indexed = true }).skip == "claimed" and #C.calls == 1)

-- The title landed (the UI set it): the index now has it as `renamed`.
C.sessions.a.info.title = "Fix login redirect bug"
-- Without retitle a chat is named once.
r = call({ session_id = "a", turn_id = 2, indexed = true, renamed = "Fix login redirect bug" })
assert(r.skip == "already titled" and #C.calls == 1)
-- With retitle the model sees the current title and may keep it.
C.settings["chat-titler.retitle"] = true
C.reply = function(q) return q.messages[2].content:match('titled "([^"]+)"') end
r = call({ session_id = "a", turn_id = 3, indexed = true, renamed = "Fix login redirect bug" })
assert(r.skip == "unchanged" and #C.calls == 2)
C.reply = "OAuth callback loop"
r = call({ session_id = "a", turn_id = 4, indexed = true, renamed = "Fix login redirect bug" })
assert(r.title == "OAuth callback loop")

-- A hand rename is never touched, retitle or not.
C.sessions.a.info.title = "My login bug"
r = call({ session_id = "a", turn_id = 5, indexed = true, renamed = "My login bug" })
assert(r.skip == "titled by hand" and #C.calls == 3)

-- A rename while the model runs wins.
core()
chat("b", "make the sidebar narrower")
C.on_info = function(id) C.sessions[id].info.title = "Sidebar" end
r = call({ session_id = "b", turn_id = 1, indexed = true })
assert(r.skip == "renamed meanwhile" and not C.state.named.b)

-- Without the index (fallback): a long first line still counts as the
-- core's own title (the 1.0.x bug), and our own title as ours.
core()
chat("c", "When a chat is running in the dev tui and gui, can we have a clock going instead of the spinner please")
assert(C.sessions.c.info.title:find("…$"))
r = call({ session_id = "c", turn_id = 1 })
assert(r.title == "Fix login redirect bug", tostring(r.skip))
C.sessions.c.info.title = r.title
C.settings["chat-titler.retitle"] = true
C.reply = "Clock instead of spinner"
assert(call({ session_id = "c", turn_id = 2 }).title == "Clock instead of spinner")
C.sessions.c.info.title = "Mine"
assert(call({ session_id = "c", turn_id = 3 }).skip == "titled by hand")

-- Sub-agents are left to the subagent tool.
core()
chat("s", "Run the command", { owner = { session_id = "a", name = "Worker" } })
assert(call({ session_id = "s", turn_id = 1, indexed = true }).skip:find("sub%-agent") and #C.calls == 0)

-- A failed call raises (the UI reports it), frees the chat, and the next
-- turn tries again since the title is still the core's own.
core()
chat("e", "hello")
C.fail = "connection refused"
local ok, err = pcall(call, { session_id = "e", turn_id = 1, indexed = true })
assert(not ok and tostring(err):find("connection refused"))
C.fail = nil
assert(call({ session_id = "e", turn_id = 2, indexed = true }).title)

-- A call still running makes others for that chat skip, not queue.
core()
chat("f", "hello")
local inner
C.reply = function()
  inner = call({ session_id = "f", turn_id = 2, indexed = true })
  return "Greeting"
end
assert(call({ session_id = "f", turn_id = 1, indexed = true }).title == "Greeting")
assert(inner.skip == "busy")

-- Provider choice: the chat's pinned model, the settings, effort only where
-- the entry sends one.
core()
chat("g", "hello").model = { provider = "cheap", model = "mini-2" }
call({ session_id = "g", turn_id = 1, indexed = true })
req = C.calls[1]
assert(req.provider == "cheap" and req.options.model == "mini-2" and not req.options.reasoning_effort)
core({ settings = { ["chat-titler.provider"] = "local", ["chat-titler.model"] = "tiny", ["chat-titler.effort"] = "" } })
chat("h", "hello").model = { provider = "cheap", model = "mini-2" }
call({ session_id = "h", turn_id = 1, indexed = true })
req = C.calls[1]
assert(req.provider == "local" and req.options.model == "tiny" and not req.options.reasoning_effort)
core({ settings = { ["chat-titler.provider"] = "gone" } })
chat("i", "hello")
ok, err = pcall(call, { session_id = "i", turn_id = 1, indexed = true })
assert(not ok and tostring(err):find("no provider gone"))

-- Later messages count, agent reports do not; long ones are cut whole
-- characters at a time.
core()
local s = chat("j", string.rep("é", 2000))
for i = 1, 5 do
  s.messages[#s.messages + 1] = { role = "user", content = "follow up " .. i }
  s.messages[#s.messages + 1] = { role = "user", source = "agent", content = "AGENT REPORT" }
end
call({ session_id = "j", turn_id = 1, indexed = true })
local sent = C.calls[1].messages[2].content
assert(sent:find("[…]", 1, true) and sent:find("follow up 3", 1, true) and sent:find("follow up 5", 1, true))
assert(not sent:find("follow up 2", 1, true) and not sent:find("AGENT REPORT", 1, true))

-- The remembered titles stay bounded.
local named = {}
for i = 1, 600 do named["old" .. i] = { title = "t", at = i } end
core({ state = { named = named } })
chat("k", "hello")
call({ session_id = "k", turn_id = 1, indexed = true })
local n = 0
for _ in pairs(C.state.named) do n = n + 1 end
assert(n == 500 and C.state.named.k and not C.state.named.old1)

-- UI half ------------------------------------------------------------------

local U
local function ui(settings, rows, core_reply)
  U = { events = {}, requests = {}, notices = {}, settings = settings or {} }
  bone = {
    settings = { get = function(key) return U.settings[key] end },
    on = function(event, fn) U.events[event] = fn end,
    notify = function(msg, level) U.notices[#U.notices + 1] = { msg = msg, level = level } end,
    request = function(method, params, cb)
      U.requests[#U.requests + 1] = { method = method, params = params }
      if method == "store/query" then
        assert(params.params[1] == "a")
        cb(rows and { columns = { "renamed", "sub" }, rows = rows } or nil, rows == nil and "no index" or nil)
      elseif method == "lua/call" then
        assert(params.name == "chat-titler.title" and not params.session_id)
        cb(core_reply(params.args))
      elseif method == "session/set" then
        cb({}, nil)
      end
    end,
  }
  dofile("plugins/chat-titler/ui.lua")
  return U
end
local function finish(status) U.events["turn/finished"]({ session_id = "a", turn_id = 7, outcome = { status = status or "completed" } }) end
local function methods() local m = {}; for _, q in ipairs(U.requests) do m[#m + 1] = q.method end; return table.concat(m, " ") end

local args
ui(nil, { { nil, 0 } }, function(a) args = a; return { title = "Greeting" } end)
finish()
assert(methods() == "store/query lua/call session/set")
assert(args.session_id == "a" and args.turn_id == 7 and args.indexed and args.renamed == nil)
assert(U.requests[3].params.title == "Greeting" and #U.notices == 0)

ui(nil, { { "By hand", 0 } }, function(a) args = a; return { skip = "titled by hand" } end)
finish()
assert(methods() == "store/query lua/call" and args.renamed == "By hand")

ui(nil, { { nil, 1 } }, function() error("a sub-agent must not be sent") end)
finish()
assert(methods() == "store/query")

ui(nil, nil, function(a) args = a; return { title = "X" } end) -- no index: core falls back
finish()
assert(methods() == "store/query lua/call session/set" and not args.indexed)

ui(nil, { { nil, 0 } }, function() error("not for a failed turn") end)
finish("failed"); finish("cancelled")
assert(#U.requests == 0)

ui({ ["chat-titler.auto"] = false }, { { nil, 0 } }, function() error("auto is off") end)
finish()
assert(#U.requests == 0)

ui(nil, { { nil, 0 } }, function() return nil, "no function chat-titler.title registered with bone.rpc" end)
finish(); finish()
assert(#U.notices == 1 and U.notices[1].msg:find("/plugins reload chat%-titler") and U.notices[1].level == "error")

ui({ ["chat-titler.debug"] = true }, { { nil, 0 } }, function() return { skip = "claimed" } end)
finish()
assert(#U.notices == 1 and U.notices[1].level == nil)

print("chat_titler_test: ok")
