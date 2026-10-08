-- Run from the catalog root: luajit tests/subagent_tui_test.lua
local commands, handlers, notices, requests = {}, {}, {}, {}
local settings, next_id, next_handler, popup, popup_id = nil, 0, 0
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function fire(name, ev)
  local snapshot = copy(handlers)
  for _, h in pairs(snapshot) do if h.name == name then h.fn(ev) end end
end
bone = {
  settings = {
    get = function(path) assert(path == "subagent.agents"); return settings end,
    set = function(path, value, callback)
      assert(path == "subagent.agents")
      requests[#requests + 1] = { value = copy(value), callback = callback }
    end,
  },
  on = function(name, fn)
    next_handler = next_handler + 1; handlers[next_handler] = { name = name, fn = fn }; return next_handler
  end,
  off = function(id) handlers[id] = nil end,
  notify = function(text, level) notices[#notices + 1] = { text, level } end,
  cmd = { create = function(name, fn, opts) commands[name] = fn; assert(opts.desc:find("named subagents")) end },
  text = {
    width = function(s) return #(s:gsub("[\128-\191]", "")) end,
    truncate = function(s, width)
      local out, n = {}, 0
      for char in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if n == width then break end
        out[#out + 1], n = char, n + 1
      end
      return table.concat(out)
    end,
  },
  ui = {
    popup = function(spec)
      next_id = next_id + 1; popup, popup_id = spec, next_id; return popup_id
    end,
    update = function(id) assert(id == popup_id) end,
    close = function(id) fire("panel/closed", { id = id, kind = "popup" }) end,
  },
}
dofile("plugins/subagent/tui.lua")
local function command(args) commands.subagents({ args = args or "" }) end
local function key(k) assert(popup.on_key(k)) end
local function paste(text, context) fire("paste", { text = text, context = context or "popup" }) end
local function render(w, h)
  local out = popup.lines({ width = w or 90, height = h or 20 })
  assert(#out <= (h or 20))
  local text = {}
  for _, spans in ipairs(out) do
    local line = ""
    for _, span in ipairs(spans) do line = line .. span[1] end
    assert(bone.text.width(line) <= (w or 90))
    text[#text + 1] = line
  end
  return table.concat(text, "\n")
end
local function field(index, value)
  -- Set selected detail field using Home-like navigation.
  for _ = 1, 6 do key("up") end
  for _ = 2, index do key("down") end
  key("enter"); key("ctrl+u"); paste(value); key("enter")
end
local function finish(err)
  local r = requests[#requests]
  assert(r)
  if not err then settings = copy(r.value) end
  r.callback(err and nil or { subagent = { agents = copy(settings) } }, err)
end
local function error_has(text)
  assert(notices[#notices][2] == "error")
  assert(notices[#notices][1]:find(text, 1, true), notices[#notices][1])
end
-- Empty list and all terminal sizes, including an extremely narrow popup.
command()
assert(render():find("No named agents", 1, true))
for _, size in ipairs({ { 1, 1 }, { 8, 4 }, { 30, 8 }, { 90, 20 } }) do render(size[1], size[2]) end
key("a"); paste("reviewer"); key("enter")
field(2, "Reviews code")
field(3, "  First line\r\nSecond \\n literal\tUTF-8: café  ")
field(4, "  fast  ")
field(5, "  model-x  ")
field(6, "read_file, shell, read_file")
key("s")
assert(#requests == 1)
local agent = requests[1].value.reviewer
assert(agent.description == "Reviews code" and agent.provider == "fast" and agent.model == "model-x")
assert(agent.system == "  First line\nSecond \\n literal\tUTF-8: café  ")
assert(#agent.tools == 2 and agent.tools[1] == "read_file" and agent.tools[2] == "shell")
assert(settings == nil, "no local saved mutation before callback")
key("s"); assert(#requests == 1, "duplicate save blocked while busy")
assert(render():find("Saving", 1, true))
finish(); assert(render():find("reviewer", 1, true))
-- Saved multiline prompts survive edit/accept untouched. Typed escapes work.
for _ = 1, 6 do key("up") end
key("down"); key("down"); key("enter"); key("enter"); key("s"); finish()
assert(settings.reviewer.system == agent.system)
field(3, "")
for _ = 1, 6 do key("up") end
key("down"); key("down"); key("enter")
for char in ("hello\\nworld\\t!\\\\"):gmatch(".") do key(char) end
key("enter"); key("s"); finish()
assert(settings.reviewer.system == "hello\nworld\t!\\")
-- Optional whitespace fields omitted; '*' explicitly overrides restrictive defaults.
field(2, "  "); field(3, "\n  "); field(4, " "); field(5, ""); field(6, " * ")
key("s"); finish()
assert(settings.reviewer.description == nil and settings.reviewer.system == nil)
assert(settings.reviewer.provider == nil and settings.reviewer.model == nil)
assert(#settings.reviewer.tools == 1 and settings.reviewer.tools[1] == "*")
assert(render():find("Allowed tools: *", 1, true))
-- Deny-all has a visible representation and survives untouched save/reopen.
for _, value in ipairs({ "none", " [] " }) do
  field(6, value); key("s"); finish()
  assert(type(settings.reviewer.tools) == "table" and next(settings.reviewer.tools) == nil)
  assert(render():find("Allowed tools: none", 1, true))
  key("q"); command("reviewer"); key("s"); finish()
  assert(type(settings.reviewer.tools) == "table" and next(settings.reviewer.tools) == nil)
end
-- Explicit blank drops the restriction to inherit defaults.
field(6, "  "); key("s"); finish(); assert(settings.reviewer.tools == nil)
assert(render():find("Allowed tools: (inherit)", 1, true))
assert(render():find("none/[] = deny all", 1, true))
-- Rename is staged until save; fresh unrelated changes are retained.
key("r"); key("ctrl+u"); paste("renamed"); key("enter")
settings.parallel = { description = "changed elsewhere" }
key("s")
assert(requests[#requests].value.reviewer == nil)
assert(requests[#requests].value.renamed and requests[#requests].value.parallel)
finish(); assert(settings.renamed and not settings.reviewer)
-- Reject invalid name and duplicate rename without a request.
local before = #requests
key("r"); key("ctrl+u"); paste("../bad"); key("enter"); key("s")
error_has("Name:"); assert(#requests == before)
field(1, "parallel"); key("s"); error_has("already exists"); assert(#requests == before)
field(1, "renamed")
for _, tools in ipairs({ "shell,", ",shell", "shell,,read_file", "*,shell", "bad tool" }) do
  field(6, tools); key("s"); error_has("Tools:"); assert(#requests == before)
end
field(6, "")
-- Provider/model strings may be independent; no model provider forced.
field(5, "other-model"); key("s")
assert(requests[#requests].value.renamed.model == "other-model")
assert(requests[#requests].value.renamed.provider == nil)
finish({ message = "disk full" }); error_has("disk full")
assert(settings.renamed.model == nil, "failed save must leave saved data untouched")
assert(render():find("other-model", 1, true), "failed save keeps draft")
key("s"); finish()
-- Same-agent changes or removal are conflicts, never silent overwrites.
settings.renamed.description = "external"
field(2, "ours"); before = #requests; key("s")
error_has("changed or was removed"); assert(#requests == before)
key("esc"); assert(render():find("Discard unsaved", 1, true)); key("n")
assert(render():find("Description: ours", 1, true))
key("esc"); key("y"); key("r")
command("renamed"); key("d"); assert(render():find("Delete 'renamed'", 1, true))
key("n"); assert(#requests == before)
key("d"); key("y"); assert(#requests == before + 1)
assert(requests[#requests].value.renamed == nil and requests[#requests].value.parallel)
finish(); assert(render():find("parallel", 1, true))
-- Addition collision checked against current settings, not just opening snapshot.
command("add new-agent"); key("enter")
settings["new-agent"] = {}
before = #requests; key("s"); error_has("already exists"); assert(#requests == before)
field(1, "valid_agent-2"); key("s"); finish()
-- ASCII-only name validation.
field(1, "café"); before = #requests; key("s"); error_has("Name:"); assert(#requests == before)
-- UTF-8 cursor deletion, insertion, clear and cancel are local until acceptance.
field(1, "valid_agent-2")
for _ = 1, 6 do key("up") end
key("down"); key("enter"); key("ctrl+u"); paste("é文Z")
key("left"); key("backspace"); key("home"); key("delete"); key("end"); key("space"); key("enter")
assert(render():find("Description: Z ", 1, true))
local existing_popup = popup_id
command("list"); error_has("Save or discard"); assert(popup_id == existing_popup)
assert(render():find("Description: Z ", 1, true))
key("enter"); key("ctrl+u"); paste("discard field"); key("esc")
assert(not render():find("discard field", 1, true))
-- Paste ignores prompt context and other focused popups; handlers cleaned up.
key("enter"); key("ctrl+u"); paste("ignored", "main")
fire("panel/opened", { id = 999, kind = "popup", focus = true }); paste("wrong popup")
fire("panel/closed", { id = 999 }); paste("correct"); key("enter")
assert(render():find("Description: correct", 1, true))
-- Actual bone3 events: opened/updated carry popup id and focus; focus/changed
-- carries { context, popup = boolean, panel }. Nonfocused popups can later focus.
key("enter"); key("ctrl+u")
fire("panel/opened", { id = 1000, kind = "popup", focus = false }); paste("a")
fire("panel/updated", { id = 1000, kind = "popup", focus = true })
fire("focus/changed", { context = "popup", popup = true }); paste("blocked")
fire("panel/updated", { id = 1000, kind = "popup", focus = false })
fire("focus/changed", { context = "popup", popup = true }); paste("b")
-- Own popup focus changes also matter even when no other popup was opened.
fire("panel/updated", { id = popup_id, kind = "popup", focus = false })
fire("focus/changed", { context = "main", popup = false }); paste("blocked")
fire("panel/updated", { id = popup_id, kind = "popup", focus = true })
fire("focus/changed", { context = "popup", popup = true }); paste("c")
-- Lower z popups do not steal focus despite newer ids; z updates can steal it.
fire("panel/updated", { id = 1000, kind = "popup", focus = true, z = -1 }); paste("e")
fire("panel/updated", { id = 1000, kind = "popup", focus = true, z = 1 }); paste("blocked")
fire("panel/updated", { id = popup_id, kind = "popup", focus = true, z = 2 }); paste("f")
-- Id-bearing focus events are supported as well.
fire("focus/changed", { context = "popup", popup = 1000 }); paste("blocked")
fire("focus/changed", { context = "popup", popup = popup_id }); paste("d")
fire("panel/closed", { id = 1000 })
key("enter"); assert(render():find("Description: abcefd", 1, true))
key("q"); key("y"); assert(next(handlers) == nil)
-- No overwrite of malformed structured settings.
for _, invalid in ipairs({ "not an object", { [1] = {} }, { broken = "not a spec" },
    { broken = { system = 3 } }, { broken = { tools = "shell" } }, { broken = { tools = { bad = "shell" } } } }) do
  settings = invalid; before = #requests; command(); error_has(""); assert(#requests == before)
  assert(next(handlers) == nil)
end
settings = {}; command("missing"); error_has("No saved agent")
-- Close during pending request is safe, and last-agent deletion writes an object.
settings = { only = {} }; command("only"); key("d"); key("y")
assert(next(requests[#requests].value) == nil)
existing_popup = popup_id
command("list"); error_has("Save or discard"); assert(popup_id == existing_popup)
key("esc"); assert(next(handlers) == nil); finish()
assert(next(settings) == nil)
-- List is sorted and scrolls; saved settings and unknown spec fields preserved.
settings = {}
for i = 1, 30 do settings[string.format("agent%02d", i)] = { description = "agent " .. i } end
settings.agent01.extension = { future = true }
command(); assert(render():find("agent01", 1, true))
key("pagedown"); key("pagedown"); assert(render():find("agent29", 1, true))
command("agent01"); field(2, "updated"); key("s"); finish()
assert(settings.agent01.extension.future)
key("esc"); key("q"); assert(next(handlers) == nil)
print("subagent_tui_test: ok")
