-- Standalone Lua/LuaJIT fixtures; no bone server or third-party modules required.
-- Run from catalog root: luajit tests/fork_test.lua
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local rpc, sessions, saved, creates = {}, {}, 0, 0
local state = {}
local function fixture()
  sessions.a = { info = { session_id = "a", cwd = "/tmp", title = "Source" }, generation = 1,
    model = { provider = "test", model = "pinned" }, summary = { through = 4, text = "summary" }, messages = {
      { role = "user", content = "first", images = { { id = "blob", name = "img" } } },
      { role = "assistant", reasoning_state = { items = { "sealed" } }, tool_calls = { { id = "t1", name = "shell", arguments = { command = "true" } } } },
      { role = "tool", call_id = "t1", content = "ok" },
      { role = "assistant", content = "done" },
      { role = "user", content = "second", images = { { id = "blob2" } } },
      { role = "assistant", content = "answer" },
    } }
end
bone = {
  state = { load = function() return state end, save = function(name, s) assert(name == "fork" and s.edges); saved = saved + 1 end },
  rpc = { register = function(n, fn) rpc[n] = fn end },
  session = { snapshot = function(id) return copy(assert(sessions[id], "missing")) end,
    create = function(opts)
      creates = creates + 1
      local id = "child" .. creates
      sessions[id] = copy(opts); sessions[id].info = { session_id = id, cwd = opts.cwd }
      sessions[id].generation = 1
      return sessions[id].info
    end },
}
fixture(); dofile("plugins/fork/core.lua")
local ctx = { session_id = "a" }
local function tree(args) return rpc["fork.tree"](args or {}, ctx) end
local function create(args) return rpc["fork.create"](args or {}, ctx) end
local function reject(args, pattern)
  local n = creates
  local ok, err = pcall(create, args)
  assert(not ok and tostring(err):find(pattern), tostring(err)); assert(creates == n)
end
local t = tree()
assert(#t.points == 2 and t.points[2].copied_count == 4 and t.points[2].safe)
for _, n in ipairs({ 0, -1, 1.5, 3, "2" }) do reject({ before_turn = n }, n == 3 and "out of range" or "positive integer") end
local r = create({ before_turn = 2, expected = t.expected })
local child = sessions[r.info.session_id]
assert(#child.messages == 4 and child.summary.through == 4 and child.model.model == "pinned")
assert(child.messages[2].reasoning_state.items[1] == "sealed" and child.messages[1].images[1].id == "blob")
assert(r.draft.text == "second" and r.draft.images[1].id == "blob2" and not child.owner and not child.parent)
assert(saved == 1 and tree().edges[r.info.session_id].before_turn == 2)
assert(not sessions[create({ before_turn = 1 }).info.session_id].summary)
local whole = create({})
assert(#sessions[whole.info.session_id].messages == 6)
sessions.a.messages[1].content = "changed without generation bump"
reject({ expected = t.expected }, "source changed")
fixture(); t = tree(); sessions.a.generation = 2
reject({ expected = t.expected }, "source changed")
sessions.a.active_turn = 7
reject({}, "wait for the source")
assert(create({ before_turn = 1 })) -- active source is safe for an early complete prefix
fixture(); table.remove(sessions.a.messages, 3) -- cutoff before second user now leaves t1 unresolved
assert(not tree().points[2].safe)
reject({ before_turn = 2 }, "unresolved tool calls")
reject({}, "unresolved tool calls")
fixture(); sessions.a.info.parent = "legacy-root"
local legacy = tree({ sessions = { { session_id = "sibling", parent = "legacy-root" } } })
assert(legacy.edges.a.legacy and legacy.edges.sibling.parent == "legacy-root")
assert(#legacy.sessions >= 3 and saved >= 5)
-- Parsed fields deliberately cannot represent the nested null/empty-array
-- distinctions. The create API must receive the exact original JSON strings.
fixture()
sessions.a.raw_messages = {
  '{"role":"user","content":"first","images":[{"id":"blob","name":"img"}]}',
  '{"role":"assistant","reasoning_state":{"items":[null,[],{"sealed":null}]},"tool_calls":[{"id":"t1","name":"shell","arguments":{"command":"true","nullable":null,"empty":[]}}]}',
  '{"role":"tool","call_id":"t1","content":"ok"}',
  '{"role":"assistant","content":"done"}',
  '{"role":"user","content":"second","images":[{"id":"blob2"}]}',
  '{"role":"assistant","content":"answer"}',
}
t = tree()
r = create({ before_turn = 2, expected = t.expected })
child = sessions[r.info.session_id]
assert(#child.messages == 4 and child.summary.through == 4)
for i = 1, 4 do assert(type(child.messages[i]) == "string" and child.messages[i] == sessions.a.raw_messages[i]) end
assert(r.draft.text == "second" and r.draft.images[1].id == "blob2")
whole = sessions[create({}).info.session_id]
for i = 1, 6 do assert(whole.messages[i] == sessions.a.raw_messages[i]) end
-- Raw fingerprints catch changes invisible in the parsed snapshot.
sessions.a.raw_messages[2] = sessions.a.raw_messages[2]:gsub('"sealed":null', '"sealed":[]')
reject({ expected = t.expected }, "source changed")
t = tree()
sessions.a.messages[2].reasoning_state = {} -- a lossy decoded representation is not the identity
assert(create({ before_turn = 2, expected = t.expected }))
table.remove(sessions.a.messages, 3); table.remove(sessions.a.raw_messages, 3)
assert(not tree().points[2].safe)
reject({ before_turn = 2 }, "unresolved tool calls")
reject({}, "unresolved tool calls")
print("core: exact raw JSON/parsed copy, model/summary, bounds, stale views, active/tool safety, family/legacy OK")

-- Async TUI fixture: RPCs are queued, rendering must not issue one.
fixture(); state.edges = {}
local queue, shown, shutdown, command, id = {}, nil, nil, nil, "a"
local prompt, images, notices, opens = "source draft", {}, {}, 0
bone.api = { session = function() return { session_id = id } end,
  prompt_set = function(text) prompt = text end,
  open_session = function(target) opens = opens + 1; id = nil; prompt, images = "", {}; shown.target = target end }
bone.prompt = { set_images = function(refs) images = refs end,
  empty = function() return prompt == "" and #images == 0 end }
bone.plugin = { on_shutdown = function(fn) shutdown = fn end }
bone.on = function(event, fn) if event == "chat/shown" then shown = { fn = fn } end end
bone.notify = function(text) notices[#notices + 1] = text end
bone.cmd = { create = function(name, fn) assert(name == "fork"); command = fn end }
-- The picker: what /fork opened, its rows once loaded, and a choice made.
local pickers, listing = {}, nil
bone.ui = { select = function(items, opts)
  local h = { opts = opts, items = items, open = true }
  function h:set_items(new) self.items = new end
  function h:close() self.open = false end
  pickers[#pickers + 1] = h
  return h
end }
bone.rpc.call = function(name, args, cb) queue[#queue + 1] = function()
  local ok, result = pcall(rpc[name], args, ctx); cb(ok and result or nil, not ok and result or nil)
end end
bone.request = function(name, args, cb) assert(name == "session/list"); queue[#queue + 1] = function() cb(listing or { sessions.a.info }) end end
local function flush() local fn = table.remove(queue, 1); assert(fn); fn() end
local function run(arg) command({ args = arg }) end
local function shown_child() id = shown.target; shown.fn() end
local function picker() return pickers[#pickers] end
local function texts()
  local out = {}
  for _, row in ipairs(picker().items) do out[#out + 1] = picker().opts.format(row) end
  return table.concat(out, "\n")
end
local function choose(pattern)
  for _, row in ipairs(picker().items) do
    if picker().opts.format(row):find(pattern, 1, true) then picker():close(); return picker().opts.on_choice(row) end
  end
  error("no row " .. pattern .. " in\n" .. texts())
end
dofile("plugins/fork/ui.lua")
run("2"); flush(); flush()
assert(prompt == "" and id == nil)
shown_child(); assert(prompt == "second" and images[1].id == "blob2")
-- User edits made while the destination loads must never be overwritten.
id = "a"; run("2"); flush(); flush()
prompt, images = "new user draft", { { id = "new-image" } }
shown_child(); assert(prompt == "new user draft" and images[1].id == "new-image")
assert(notices[#notices]:find("kept your edits", 1, true))
-- Newest first: the first row forks before the latest message. Drawing the
-- rows makes no RPC.
id = "a"; run(""); assert(picker().opts.loading)
flush(); flush()
local n = #queue; texts(); assert(#queue == n)
assert(texts():match("^#2  second · 1 image\n#1  first · 1 image$"), texts())
choose("#1") -- the first user point: an empty prefix
assert(#queue == 1)
local before = opens
run(""); flush(); assert(opens == before) -- a newer /fork drops the older create's result
picker().opts.on_choice(nil); flush(); assert(#queue == 0)
-- Branches sit under the message they redid; a branch with no cut, last.
state.edges = {
  first = { parent = "a", before_turn = 1 },
  second = { parent = "a", before_turn = 2 },
  legacy = { parent = "a", legacy = true },
}
listing = { sessions.a.info,
  { session_id = "first", cwd = "/tmp", title = "↳ Source", created_at = os.time() },
  { session_id = "second", cwd = "/tmp", title = "Renamed", created_at = os.time() },
  { session_id = "legacy", cwd = "/tmp", title = "Old copy", created_at = os.time() } }
sessions.first = { info = listing[2], messages = { { role = "user", content = "first, again" } } }
run(""); flush(); flush()
local text = texts()
assert(text:find("^#2  second[^\n]*\n +↳ Renamed · just now\n#1  first[^\n]*\n +↳ first, again · just now\n↳ Old copy · just now$"), text)
choose("Renamed"); assert(opens == before + 1 and shown.target == "second")
-- A chat whose source is gone says so, and cannot open it.
id = "a"; listing = nil; sessions.first = nil
state.edges = { a = { parent = "missing", before_turn = 2 } }
run(""); flush(); flush(); text = texts()
assert(text:find("↰ Branched from: a chat that is gone · at #2$"), text)
choose("Branched from"); assert(notices[#notices]:find("gone") and opens == before + 1)
-- A malformed legacy cycle shows its parent once and ends.
state.edges = { a = { parent = "loop", legacy = true }, loop = { parent = "a", legacy = true } }
run(""); flush(); flush(); text = texts()
local _, parents = text:gsub("↰", "")
assert(parents == 1, text)
picker().opts.on_choice(nil)
run("copy"); shutdown(); flush(); assert(#queue == 0 and opens == before + 1)
print("view: newest-first rows, branch placement and names, missing/cyclic parents, delayed prefill, no render RPC, stale/unload guards OK")
