-- Run from the catalog root: luajit tests/subagent_tui_test.lua
local commands, handlers, notices, requests = {}, {}, {}, {}
local settings, next_id, next_handler, popup, popup_id = nil, 0, 0
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function finish(err)
  local r = requests[#requests]
  assert(r)
  if not err then settings = copy(r.value) end
  r.callback(err and nil or { subagent = { agents = copy(settings) } }, err)
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
  model = { list = function(cb) cb({ { name = "fast", model = "model-x" } }) end },
  cmd = { create = function(name, fn, opts) commands[name] = fn; assert(opts.desc:find("named subagents")) end },
  text = {
    width = function(s) return #(s:gsub("[\128-\191]", "")) end,
    clip = function(spans, width)
      local out, used = {}, 0
      for _, sp in ipairs(spans) do
        local text, n = "", 0
        for char in sp[1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          if n >= width - used then break end
          text, n = text .. char, n + 1
        end
        if text ~= "" then out[#out + 1] = { text, sp[2] } end
        used = used + n
      end
      return out
    end,
    wrap = function(spans, width)
      local text, hl = spans[1][1], spans[1][2]
      local out, line = {}, ""
      width = math.max(1, width)
      local function n(s) return #(s:gsub("[\128-\191]", "")) end
      for word in (text .. " "):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if n(candidate) > width and line ~= "" then
          out[#out+1] = { { line, hl } }
          line = word
        else line = candidate end
      end
      out[#out+1] = { { line, hl } }
      return out
    end,
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
    box = function(lines) return lines end,
    popup = function(spec)
      next_id = next_id + 1; popup, popup_id = spec, next_id; return popup_id
    end,
    update = function(id) assert(id == popup_id) end,
    is_open = function(open_id) return open_id == popup_id end,
    select = function(items, opts)
      local choice = items[1]
      for _, item in ipairs(items) do
        if item.name == "fast" then choice = item end
      end
      opts.on_choice(choice)
      finish()
    end,
    close = function(id) fire("panel/closed", { id = id, kind = "popup" }) end,
  },
}
dofile("plugins/subagent/ui.lua")
local function command(args) commands.subagents({ args = args or "" }) end
local function key(k) assert(popup.on_key(k)) end
local function paste(text, context) fire("paste", { text = text, context = context or "popup" }) end
local function type_text(text)
  text = text:gsub("\r\n?", "\n")
  local i = 1
  while i <= #text do
    local b = text:byte(i)
    if b == 10 then key("enter")
    elseif b == 9 then key("tab")
    elseif b < 128 then key(text:sub(i, i))
    else
      local n = b >= 240 and 4 or b >= 224 and 3 or 2
      key(text:sub(i, i + n - 1)); i = i + n - 1
    end
    i = i + 1
  end
end
local function render(w, h)
  local out = popup.lines({ width = w or 90, height = h or 20 })
  -- bone.ui.box adds one border row above and below the content.
  -- A 1x1 request still gets the editor's minimum content plus its border.
  assert(#out <= math.max((h or 20) + 2, 5))
  local text = {}
  for _, spans in ipairs(out) do
    local line = ""
    for _, span in ipairs(spans) do line = line .. span[1] end
    -- bone.ui.box adds one cell of border on each side.
    -- The renderer floors the popup at 48 content cells; the border adds two.
    -- The editor floors its content near 48 cells; bone.ui.box then adds a
    -- border, and the footer is one unwrapped line. A 1-cell request cannot
    -- shrink either.
    assert(bone.text.width(line) <= math.max((w or 90) + 2, 66), line)
    text[#text + 1] = line
  end
  return table.concat(text, "\n")
end
local function field(index, value)
  -- index 2..6 is description, system, provider, model, tools.
  -- The first call opens the agent; later calls continue from the current field.
  if index == 2 then key("enter"); key("enter") else key("down") end
  key("enter")
  local shown = render(90, 30)
  if index ~= 4 and not shown:find("Editing", 1, true) and not shown:find("▏", 1, true) then
    error("field " .. index .. " did not open\n" .. shown)
  end
  if index == 4 then return end
  key("ctrl+u"); type_text(value)
  local before = #requests
  if index == 3 then popup.on_key("ctrl+s") else key("enter") end
  if index == 3 and #requests == before then error("system save added no request\n" .. render(90, 30)) end
  local spec = settings and settings.reviewer
  if not spec then error("field " .. index .. " did not save; notices=" .. tostring(notices[#notices] and notices[#notices][1])) end
end
local function error_has(text)
  local notice = notices[#notices]
  if not notice then error("no notice") end
  local message = tostring(notice[1])
  assert(message:find(text, 1, true), message)
end
-- Empty list and all terminal sizes, including an extremely narrow popup.
command()
assert(render():find("No agents yet", 1, true))
for _, size in ipairs({ { 1, 1 }, { 8, 4 }, { 30, 8 }, { 90, 20 } }) do render(size[1], size[2]) end
-- Creating the agent and accepting each field saves immediately.
key("n"); paste("reviewer"); key("enter"); finish()
local function step(label, fn)
  local before = #requests
  fn()
  if #requests == before then error(label .. " made no request; notice=" .. tostring(notices[#notices] and notices[#notices][1])) end
end
step("description", function() field(2, "Reviews code"); finish() end)
step("system", function() field(3, "  First line\r\nSecond \\n literal\tUTF-8: café  "); finish() end)
step("provider", function()
  local before = #requests
  field(4, "  fast  ")
  if #requests == before then finish() end
end)
step("model", function() field(5, "  model-x  "); finish() end)
step("tools", function() field(6, "read_file, shell, read_file"); finish() end)
if not settings or not settings.reviewer then
  local kinds = {}
  for i, r in ipairs(requests) do kinds[i] = type(r.value) == "table" and next(r.value) or type(r.value) end
  error("requests=" .. #requests .. " kinds=" .. table.concat(kinds, ","))
end
local agent = settings.reviewer
assert(agent.description == "Reviews code", agent.description)
assert(agent.provider == "fast", tostring(agent.provider))
assert(agent.model == "model-x", tostring(agent.model))
if agent.system ~= "  First line\nSecond \\n literal\tUTF-8: café  " then
  error("system=" .. string.format("%q", agent.system or ""))
end
local tools = {}
for i, name in ipairs(agent.tools or {}) do tools[i] = tostring(name) end
assert(table.concat(tools, ",") == "read_file,shell,read_file")
assert(render():find("reviewer", 1, true))
-- A failed save reports the error and does not replace the last saved agent.
local saved = copy(settings)
field(5, "other-model")
finish({ message = "disk full" })
assert(settings.reviewer.model == saved.reviewer.model)
-- Clearing a field removes it. Renaming saves the new name immediately.
key("up"); key("x"); finish(); assert(settings.reviewer.model == nil)
key("r"); key("ctrl+u"); type_text("renamed"); key("enter"); finish()
assert(settings.renamed and not settings.reviewer)
local before = #requests
key("r"); key("ctrl+u"); type_text("../bad"); key("enter")
assert(#requests == before)
-- Closing removes the popup handlers.
key("esc"); bone.ui.close(popup_id)
print("subagent_tui_test: ok")
