-- Standalone mocks; run from catalog root: luajit tests/context_test.lua
local root = arg[1] or "plugins/context"
package.path = root .. "/lua/?.lua;" .. package.path
local hooks, rpc, settings = {}, {}, {}
local snap = { info = { cwd = "/tmp", title = "Test" }, messages = {}, model = { provider = "test", model = "mock" } }
bone = {
  json = { encode = function() return "{}" end },
  hook = function(name, fn) hooks[name] = fn end,
  rpc = { register = function(name, fn) rpc[name] = fn end },
  settings = { get = function(key) return settings[key] end },
  session = { snapshot = function() return snap end },
  config = { system_prompt = "system", provider = "test", providers = { test = { model = "mock" } }, compact = { limit = 1000 } },
}
local B = require("context.breakdown")
local function row(d, key)
  for _, r in ipairs(d.rows) do if r.key == key then return r end end
  error("missing row " .. key)
end
local messages = {
  { role = "user", content = "abcd" },
  { role = "assistant", content = "abcdefgh", reasoning = "abcd", tool_calls = { { id = "1", name = "read", arguments = "{}" } } },
  { role = "tool", call_id = "1", content = "abcdefghijkl" },
  { role = "user", content = "", images = { { width = 512, height = 512 } } },
}
local d = B.new()
B.messages(d, messages)
B.add_definitions(d, { { name = "read", bytes = 20 } })
assert(d.bytes == 4 + 8 + 4 + 6 + 12 + 255 * 4 + 20)
assert(d.image_count == 1 and row(d, "images").bytes == 1020)
d = B.finish(d)
assert(d.tools[1].name == "read" and d.tools[1].calls == 6 and d.tools[1].results == 12)
assert(d.tools[1].definitions == 20 and d.largest[1].index == 4)
assert(d.tokens == B.tokens(d.bytes))
local no_reasoning = B.new()
B.messages(no_reasoning, messages, { reasoning = false })
assert(row(no_reasoning, "reasoning").bytes == 0)
local compacted = B.finish(B.current({ messages = messages, summary = { through = 2, text = "summary" } },
  { system_bytes = 8, definitions = {} }, false))
assert(compacted.messages == 2 and compacted.summarized == 2 and compacted.stored_messages == 4)
assert(row(compacted, "summary").bytes == #("Summary of the earlier conversation:\n\nsummary"))
assert(row(compacted, "user").bytes == 0 and row(compacted, "assistant").bytes == 0)
assert(compacted.tools[1].name == "read", "results must resolve calls in the compacted prefix")
assert(compacted.largest[1].index == 4)
assert(B.finish(B.current({ messages = {}, summary = false }, nil)).tokens == 0)
local unicode = B.new()
B.messages(unicode, { { role = "user", content = "éé" } })
assert(unicode.bytes == 4)
local ties = B.new()
for i = 1, 20 do B.messages(ties, { { role = "user", content = "abcd" } }, { offset = i - 1 }) end
B.finish(ties)
assert(#ties.largest == 10 and ties.largest[1].index == 1 and ties.largest[10].index == 10)

dofile(root .. "/core.lua")
snap.messages = messages
local get = rpc["context.get"]
local first = get({}, { session_id = "one" })
assert(first.request == nil and first.current.stored_messages == 4)
assert(first.compact_limit == 1000 and row(first.current, "definitions").bytes == 0)
assert(#first.notes >= 3)
hooks.request({ session_id = "one", messages = { { role = "system", content = "abcd" }, messages[1] },
  tools = { { name = "read", description = "desc", parameters = {} } } })
hooks.message({ session_id = "one", usage = { input_tokens = 30, cached_tokens = 10 } })
local captured = get({}, { session_id = "one" })
assert(captured.request and captured.request.messages == 2)
assert(captured.usage.input_tokens == 30)
assert(row(captured.current, "system").bytes == 4)
assert(row(captured.current, "definitions").bytes == 10)
assert(get({}, { session_id = "two" }).request == nil, "request data must be session-local")
settings["providers.test"] = { replay_reasoning = false, compact_limit = 0 }
local disabled = get({}, { session_id = "one" })
assert(row(disabled.current, "reasoning").bytes == 0 and disabled.compact_limit == 0)
snap.summary = { through = 2, text = "summary" }
assert(get({}, { session_id = "one" }).current.summarized == 2)
snap.summary = nil
bone.config.system_prompt = function() error("must not evaluate dynamic prompts") end
assert(row(get({}, { session_id = "three" }).current, "system").bytes == 0)
assert(not pcall(get, {}, {}), "missing session should fail clearly")

-- More than the activity table's 15-tool cap, including unused schemas and
-- a long MCP-style name. Keep the accounting separate from call/result costs.
local offered = {}
for i = 1, 20 do
  offered[#offered + 1] = { name = string.format("unused_%02d", i), description = string.rep("x", i * 40), parameters = {} }
end
local long_tool = "mcp_server_with_a_long_name__tool_with_a_long_name"
offered[#offered + 1] = { name = long_tool, description = string.rep("x", 1200), parameters = {} }
hooks.request({ session_id = "many", messages = {}, tools = offered })
local many = get({}, { session_id = "many" })
assert(#many.request.tools == #offered and #many.current.tools == #offered + 1)
local schema_total = 0
for _, t in ipairs(many.request.tools) do
  assert(t.calls == 0 and t.results == 0 and t.bytes == t.definitions)
  schema_total = schema_total + t.definitions
end
assert(row(many.request, "definitions").bytes == schema_total)
hooks.request({ session_id = "empty", messages = {}, tools = {} })

-- Exercise TUI callbacks, refresh races, render/scroll/resize, and teardown.
local command, shutdown, callbacks, events, windows, next_window = nil, nil, {}, {}, {}, 0
local session_id = "one"
bone.api = { session = function() return { session_id = session_id } end }
bone.plugin = { on_shutdown = function(fn) shutdown = fn end }
bone.settings.page = function() end
bone.notify = function(message) error(message) end
bone.rpc.call = function(_, args, cb) callbacks[#callbacks + 1] = { cb = cb, id = args.session_id } end
bone.cmd = { create = function(name, fn) assert(name == "context"); command = fn end }
bone.on = function(name, fn) events[name] = fn end
bone.text = { wrap = function(spans, width)
    local lines, line, used = {}, {}, 0
    for _, span in ipairs(spans) do
      local text = span[1]
      while #text > 0 do
        local take = math.min(#text, width - used)
        line[#line + 1] = { text:sub(1, take), span[2] }
        text, used = text:sub(take + 1), used + take
        if used == width then lines[#lines + 1], line, used = line, {}, 0 end
      end
    end
    if #line > 0 then lines[#lines + 1] = line end
    return lines
  end, width = function(s) return #s end, truncate = function(s, w) return s:sub(1, w) end }
bone.hl = { set = function() end, get = function() return {} end }
bone.ui = {
  popup = function(spec) next_window = next_window + 1; windows[next_window] = spec; return next_window end,
  close = function(id) windows[id] = nil end,
  is_open = function(id) return windows[id] ~= nil end,
  update = function() end,
}
dofile(root .. "/tui.lua")
local function rendered(w, h)
  local spec = assert(windows[next_window])
  local lines = spec.lines({ width = w or 100, height = h or 30 })
  local texts = {}
  for _, l in ipairs(lines) do
    for _, span in ipairs(l) do texts[#texts + 1] = type(span) == "table" and (span[1] or span.fill or "") or span end
  end
  return table.concat(texts, "\n")
end
command({ args = "" })
assert(rendered():find("Loading context", 1, true))
callbacks[#callbacks].cb(captured)
assert(rendered():find("estimated current context", 1, true))
local function schemas(text)
  local start = assert(text:find(" Tool schemas ", 1, true))
  return text:sub(start, (text:find(" Tool costs ", start, true) or text:find(" Largest messages ", start, true)
    or assert(text:find(" Notes ", start, true))) - 1)
end
assert(schemas(rendered(100, 200)):find("read", 1, true))
windows[next_window].on_key("tab")
assert(rendered():find("last request", 1, true))
windows[next_window].on_key("end")
assert(rendered():find("opaque reasoning", 1, true))
rendered(35, 10)
windows[next_window].on_key("r")
local stale = callbacks[#callbacks]
session_id = "two"
events["chat/shown"]({ session_id = "two" })
stale.cb(captured)
assert(rendered():find("Loading context", 1, true), "ignore stale RPC results after switching chats")
callbacks[#callbacks].cb(get({}, { session_id = "two" }))
assert(rendered():find("No request observed", 1, true))
windows[next_window].on_key("q")
assert(not windows[next_window])
command({ args = "" })
callbacks[#callbacks].cb(many)
local schema_text = schemas(rendered(100, 200))
for _, t in ipairs(offered) do assert(schema_text:find(t.name, 1, true), "missing offered tool " .. t.name) end
assert(schema_text:find("21 tools", 1, true) and schema_text:find("share of all tool schemas", 1, true))
assert(schema_text:find(long_tool, 1, true) < schema_text:find("unused_20", 1, true))
assert(schema_text:find("unused_20", 1, true) < schema_text:find("unused_01", 1, true), "sort schemas by weight")
assert(schema_text:find(tostring(B.tokens(#long_tool + 1200 + 2)), 1, true), "show estimated schema tokens")
assert(not schema_text:find("read", 1, true), "history-only tools must not appear as offered schemas")
local narrow = schemas(rendered(35, 200))
assert(not narrow:find(long_tool, 1, true), "long tool names must wrap on narrow screens")
assert(narrow:gsub("%s", ""):find(long_tool, 1, true), "do not truncate long tool names")
windows[next_window].on_key("tab")
assert(schemas(rendered(100, 200)):find("unused_01", 1, true), "list schemas in request view too")
windows[next_window].on_key("q")
command({ args = "" })
callbacks[#callbacks].cb(get({}, { session_id = "two" }))
assert(schemas(rendered(100, 200)):find("unknown until", 1, true))
windows[next_window].on_key("r")
callbacks[#callbacks].cb(get({}, { session_id = "empty" }))
assert(schemas(rendered(100, 200)):find("No tool schemas were offered", 1, true))
windows[next_window].on_key("q")
command({ args = "request" })
shutdown()
callbacks[#callbacks].cb(captured)
assert(not windows[next_window], "shutdown must close the popup and ignore pending callbacks")
print("context: accounting, compaction, RPC isolation, TUI rendering, refresh races and shutdown passed")
