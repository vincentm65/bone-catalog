-- Standalone regression suite; no core, UI, network, or live model required.
-- Run from the catalog checkout: luajit tests/prompt_suggestions_test.lua
local source = debug.getinfo(1, "S").source:sub(2)
local plugin_dir = source:match("^(.*[/\\])") .. "../plugins/prompt-suggestions/"
local function char_count(text)
  return #(text:gsub("[\128-\191]", ""))
end
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function eq(actual, expected, label)
  if actual ~= expected then
    error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
local function ctx(text, fields)
  local c = { text = text or "", focused = true, cursor = { row = 0, col = char_count(text or "") }, images = {}, lines = {text or ""} }
  for k, v in pairs(fields or {}) do c[k] = v end
  return c
end
local conversation = { { role = "user", content = "Fix this test" }, { role = "assistant", content = "Fixed it." } }

local function mock(frontend, opts)
  frontend, opts = frontend or "tui", opts or {}
  local m = { settings = {}, session = { session_id = "a" }, events = {}, messages = {}, calls = {}, notices = {}, sets = {}, submits = 0,
    complete_calls = 0, dismiss_calls = 0, shutdowns = {}, input = ctx(""), marks = { highlights = { { row = 0, from = 0, to = 1, hl = "Custom" } }, custom = "kept" } }
  m.original = {
    placeholder = function() return { { "Original placeholder", "Custom" } } end,
    highlight = function() return m.marks end,
    complete = function() m.complete_calls = m.complete_calls + 1; return "fallback" end,
    dismiss = function() m.dismiss_calls = m.dismiss_calls + 1; return m.dismiss_handled or false end,
  }
  local b = {
    settings = { get = function(key) return m.settings[key] end },
    chat = {
      session = function()
        if not m.session then return nil end
        local copy = {}; for k, v in pairs(m.session) do copy[k] = v end; return copy
      end,
      messages = function(id, cb)
        eq(type(cb), "function", "messages callback")
        m.messages[#m.messages + 1] = { id = id, done = cb }
      end,
    },
    model = { complete = function(req, delta, done)
      eq(delta, nil, "no streaming callback")
      local call = { req = req, done = done, cancels = 0 }
      function call:cancel() self.cancels = self.cancels + 1 end
      m.calls[#m.calls + 1] = call
      return call
    end },
    prompt = {
      info = function() -- Real API returns snapshots, not the mock's input table.
        local copy = {}; for k, v in pairs(m.input) do copy[k] = v end; return copy
      end,
      set = function(text) m.sets[#m.sets + 1] = text; m.input = ctx(text); m:emit("prompt/changed", { text = text }) end,
    },
    ui = { prompt = { placeholder = m.original.placeholder }, prompt_highlight = m.original.highlight,
      actions = { complete = m.original.complete, dismiss = m.original.dismiss,
        submit = function() m.submits = m.submits + 1 end } },
    on = function(event, cb)
      m.events[event] = m.events[event] or {}; table.insert(m.events[event], cb)
    end,
    notify = function(message, level) m.notices[#m.notices + 1] = { message, level } end,
    plugin = { on_shutdown = function(cb) m.shutdowns[#m.shutdowns + 1] = cb end },
  }
  function m.shutdown()
    for _, cb in ipairs(m.shutdowns) do cb() end
  end
  if frontend == "gui" then
    m.invalidations, m.slot_adds, m.context = 0, 0, "main"
    m.slots = {}
    b.has_capability = function(cap) return cap == "gui.nodes" and opts.nodes ~= false end
    b.keymap = { current = function() return m.context end }
    b.ui.panel = { focused = function() return m.panel_focus end }
    b.gui = {
      invalidate = function() m.invalidations = m.invalidations + 1 end,
      focused = function() return m.node_focus end,
      slots = {
        add = function(name, spec)
          m.slot_adds = m.slot_adds + 1
          local list = m.slots[name] or {}
          m.slots[name] = list
          for i, slot in ipairs(list) do
            if slot.id == spec.id then table.remove(list, i) break end
          end
          list[#list + 1] = spec
          return spec.id
        end,
        remove = function(name, id)
          for i, slot in ipairs(m.slots[name] or {}) do
            if slot.id == id then table.remove(m.slots[name], i) return true end
          end
          return false
        end,
        nodes = function(name, slot_ctx)
          local out = {}
          for _, slot in ipairs(m.slots[name] or {}) do
            local node = slot.node
            if type(node) == "function" then node = node(slot_ctx or {}) end
            if type(node) == "table" then out[#out + 1] = node end
          end
          return out
        end,
      },
    }
  end
  m.b = b
  function m:row(extra)
    local slots = self.b.gui and self.b.gui.slots
    if not slots then return nil end
    return (slots.nodes("composer.above", extra or {}))[1]
  end
  function m:emit(event, ev) for _, cb in ipairs(self.events[event] or {}) do cb(ev or {}) end end
  function m:finish(ev)
    self:emit("turn/finished", ev or { session_id = "a", outcome = { status = "completed" } })
  end
  function m:deliver_messages(messages, err, index)
    self.messages[index or #self.messages].done(messages or conversation, err)
  end
  function m:deliver(result, err, index) self.calls[index or #self.calls].done(result, err) end
  function m:predict(text)
    self:finish(); self:deliver_messages(); self:deliver({ content = text or "Run the tests" })
  end
  function m:ghost(c) return self.b.ui.prompt_highlight(c or self.input).ghost end
  function m:placeholder(c) return self.b.ui.prompt.placeholder(c or self.input) end
  function m:absent()
    eq(self:ghost(ctx("")), nil, "no stale ghost")
    eq(self:placeholder(ctx(""))[1][1], "Original placeholder", "no stale placeholder")
  end
  local env = setmetatable({ bone = b }, { __index = _G })
  local loaded = {}
  function env.require(name)
    if loaded[name] ~= nil then return loaded[name] end
    local path = plugin_dir .. "lua/" .. name:gsub("%.", "/") .. ".lua"
    local chunk, err = loadfile(path, "t", env)
    if not chunk then error(err or ("no module " .. name), 2) end
    if setfenv then setfenv(chunk, env) end
    local result = chunk()
    loaded[name] = result == nil and true or result
    return loaded[name]
  end
  local function run(file)
    local chunk, err = loadfile(plugin_dir .. file, "t", env)
    if not chunk then error(err or file, 2) end
    if setfenv then setfenv(chunk, env) end
    chunk()
  end
  run("ui.lua")
  run(frontend .. ".lua")
  return m
end

test("default provider/model omitted; one deferred request after transcript", function()
  local m = mock(); m:finish()
  eq(#m.messages, 1); eq(m.messages[1].id, "a"); eq(#m.calls, 0)
  m:deliver_messages(); eq(#m.calls, 1)
  eq(m.calls[1].req.provider, nil); eq(next(m.calls[1].req.options), nil)
end)
for _, config in ipairs({
  { name = "explicit options trimmed", provider = " provider-x ", model = " model-y ", want_provider = "provider-x", want_model = "model-y" },
  { name = "whitespace defaults", provider = " \t", model = "  " },
  { name = "provider only", provider = "provider-x", want_provider = "provider-x" },
  { name = "model only", model = "model-y", want_model = "model-y" },
}) do
  test(config.name, function()
    local m = mock(); m.settings["prompt-suggestions.provider"] = config.provider; m.settings["prompt-suggestions.model"] = config.model
    m:finish(); m:deliver_messages()
    eq(m.calls[1].req.provider, config.want_provider); eq(m.calls[1].req.options.model, config.want_model)
  end)
end
for _, condition in ipairs({ "disabled", "failed", "cancelled", "missing outcome", "background", "running", "starting", "no session" }) do
  test("does not request: " .. condition, function()
    local m = mock(); local ev = { session_id = "a", outcome = { status = "completed" } }
    if condition == "disabled" then m.settings["prompt-suggestions.enabled"] = false
    elseif condition == "missing outcome" then ev.outcome = nil
    elseif condition == "background" then ev.session_id = "b"
    elseif condition == "no session" then m.session = nil
    elseif condition == "running" or condition == "starting" then m.session[condition] = true
    else ev.outcome.status = condition end
    m:finish(ev); eq(#m.messages, 0); eq(#m.calls, 0)
  end)
end

test("empty placeholder and prefix ghost do not modify input", function()
  local m = mock(); m:predict()
  local p = m:placeholder(); eq(p[1][1], "Run the tests"); eq(p[1][2], "Placeholder")
  eq(m.input.text, ""); eq(#m.sets, 0)
  eq(m:ghost(ctx("Run")), " the tests")
  eq(m.b.ui.prompt_highlight(ctx("Run")).ghost_hl, "Placeholder")
end)
for _, case in ipairs({
  { "divergent text", ctx("Other") }, { "exact suggestion", ctx("Run the tests") },
  { "moved cursor", ctx("Run", { cursor = { row = 0, col = 1 } }) },
  { "other row", ctx("Run", { cursor = { row = 1, col = 3 } }) },
  { "selection", ctx("Run", { selection = { start = 0, ["end"] = 3, text = "Run" } }) },
  { "unfocused", ctx("Run", { focused = false }) }, { "multiline", ctx("Run\n") }, { "slash", ctx("/help") },
}) do
  test("suppression: " .. case[1], function()
    local m = mock(); m:predict(); eq(m:ghost(case[2]), nil)
    eq(m:placeholder(case[2])[1][1], "Original placeholder")
  end)
end
for _, flag in ipairs({ "running", "starting", "disabled" }) do
  test("ready suggestion suppressed while " .. flag, function()
    local m = mock(); m:predict()
    if flag == "disabled" then m.settings["prompt-suggestions.enabled"] = false else m.session[flag] = true end
    m:absent()
  end)
end
test("unicode cursor is character count, not byte count or display width", function()
  local m = mock(); m:predict("修复é🙂 tests")
  eq(m:ghost(ctx("修复é🙂")), " tests")
  eq(m:ghost(ctx("修复é🙂", { cursor = { row = 0, col = #"修复é🙂" } })), nil)
  m.input = ctx("修复é🙂"); eq(m.b.ui.actions.complete(), true); eq(m.sets[1], "修复é🙂 tests")
end)
test("Tab accepts without submitting; then fallback completion preserved", function()
  local m = mock(); m:predict(); m.input = ctx("Run", { focused = false })
  eq(m.b.ui.actions.complete(), true); eq(m.sets[1], "Run the tests"); eq(m.submits, 0); eq(m.complete_calls, 0)
  m:absent(); eq(m.b.ui.actions.complete(), "fallback"); eq(m.complete_calls, 1)
end)
test("ineligible Tab delegates original completion", function()
  local m = mock(); m:predict(); m.input = ctx("Other")
  eq(m.b.ui.actions.complete(), "fallback"); eq(#m.sets, 0); eq(m.complete_calls, 1)
  eq(m:ghost(ctx("Run")), " the tests")
end)
test("Escape honors existing handler before dismissing prediction", function()
  local m = mock(); m:predict(); m.dismiss_handled = true
  eq(m.b.ui.actions.dismiss(), true); eq(m:ghost(ctx("Run")), " the tests")
  m.dismiss_handled = false; eq(m.b.ui.actions.dismiss(), true); m:absent()
  eq(m.b.ui.actions.dismiss(), false); eq(m.dismiss_calls, 3)
end)

-- Each invalidation is checked at all asynchronous stages. Late callbacks are
-- deliberately delivered even after cancel (the real transport can race).
local invalidations = {
  { "submit", function(m) m:emit("submit") end },
  { "turn_started", function(m) m:emit("turn/started", { session_id = "a" }) end },
  { "chat_shown", function(m) m:emit("chat/shown") end },
  { "settings_changed", function(m) m:emit("settings/changed") end },
  { "Escape", function(m) eq(m.b.ui.actions.dismiss(), true) end },
  { "unload", function(m) m.shutdown() end },
}
for _, invalidation in ipairs(invalidations) do
  for _, phase in ipairs({ "messages pending", "model pending", "suggestion ready" }) do
    test(invalidation[1] .. " invalidates " .. phase, function()
      local m = mock(); m:finish()
      if phase ~= "messages pending" then m:deliver_messages() end
      if phase == "suggestion ready" then m:deliver({ content = "Run the tests" }) end
      invalidation[2](m)
      if phase == "messages pending" then
        m:deliver_messages(); eq(#m.calls, 0)
      elseif phase == "model pending" then
        eq(m.calls[1].cancels, 1); m:deliver({ content = "Stale prediction" }); m:deliver(nil, "late error")
      else eq(m.calls[1].cancels, 0) end
      m:absent(); eq(#m.notices, 0)
    end)
  end
end
test("background turn_started does not cancel active request", function()
  local m = mock(); m:finish(); m:deliver_messages(); m:emit("turn/started", { session_id = "b" })
  eq(m.calls[1].cancels, 0); m:deliver({ content = "Run the tests" }); eq(m:ghost(ctx("Run")), " the tests")
end)
test("new prediction cancels older request and ignores stale callback", function()
  local m = mock(); m:finish(); m:deliver_messages(); m:finish(); eq(m.calls[1].cancels, 1)
  m:deliver_messages(); m:deliver({ content = "New prediction" }, nil, 2)
  m:deliver({ content = "Old prediction" }, nil, 1); m:deliver(nil, "old error", 1)
  eq(m:ghost(ctx("New")), " prediction"); eq(#m.notices, 0)
end)
test("new prediction ignores older pending transcript callback", function()
  local m = mock(); m:finish(); m:finish(); m:deliver_messages(nil, nil, 1); eq(#m.calls, 0)
  m:deliver_messages(nil, nil, 2); eq(#m.calls, 1)
end)
for _, change in ipairs({ "session", "running", "starting", "disabled" }) do
  for _, phase in ipairs({ "messages", "model" }) do
    test("late " .. phase .. " callback rejected after " .. change .. " changes", function()
      local m = mock(); m:finish(); if phase == "model" then m:deliver_messages() end
      if change == "session" then m.session.session_id = "b"
      elseif change == "disabled" then m.settings["prompt-suggestions.enabled"] = false
      else m.session[change] = true end
      if phase == "messages" then m:deliver_messages(); eq(#m.calls, 0)
      else m:deliver({ content = "Stale" }) end
      m:absent(); eq(#m.notices, 0)
    end)
  end
end

test("configuration errors notify and leave no suggestion", function()
  local m = mock(); m:finish(); m:deliver_messages(nil, "transcript failed")
  eq(#m.calls, 0); eq(m.notices[1][1], "Prompt suggestions: transcript failed"); eq(m.notices[1][2], "error"); m:absent()
  m:finish(); m:deliver_messages(); m:deliver(nil, "model failed")
  eq(m.notices[2][1], "Prompt suggestions: model failed"); eq(m.notices[2][2], "error"); m:absent()
end)
for _, case in ipairs({
  { "provider overloaded", 'provider error: {"error":{"code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later.","param":null,"type":"service_unavailable_error"},"sequence_number":3,"type":"error"}' },
  { "HTTP 503", "HTTP 503: Service Unavailable" },
  { "HTTP 500", "HTTP 500: Internal Server Error" },
  { "rate limited", "provider error: {\"error\":{\"code\":\"rate_limit_exceeded\"}}" },
  { "transport", "request failed: operation timed out" },
  { "bad gateway", "HTTP 502: {\"error\":{\"type\":\"bad_gateway\"}}" },
}) do
  test("transient provider failure stays quiet: " .. case[1], function()
    local m = mock(); m:finish(); m:deliver_messages(); m:deliver(nil, case[2])
    eq(#m.notices, 0, "no notice"); m:absent()
    m:finish(); m:deliver_messages(); m:deliver({ content = "Run the tests" })
    eq(m:ghost(ctx("Run")), " the tests", "later turns still predict")
  end)
end
test("transcript failures are quiet when transient and reported otherwise", function()
  local m = mock(); m:finish()
  m:deliver_messages(nil, "HTTP 503: Service Unavailable"); eq(#m.calls, 0); eq(#m.notices, 0)
  m:finish(); m:deliver_messages(nil, "session index unavailable")
  eq(#m.calls, 0); eq(#m.notices, 1)
  eq(m.notices[1][1], "Prompt suggestions: session index unavailable")
  m:absent()
end)
for _, case in ipairs({ "HTTP 401: Unauthorized", "HTTP 404: Not Found", "no provider \"x\" in bone.config.providers" }) do
  test("real mistakes are still reported: " .. case, function()
    local m = mock(); m:finish(); m:deliver_messages(); m:deliver(nil, case)
    eq(#m.notices, 1); eq(m.notices[1][2], "error"); m:absent()
  end)
end
for _, case in ipairs({
  { "empty", "" }, { "whitespace", " \t\n " }, { "slash", "/help" }, { "quoted slash", '"/help"' },
  { "multiline", "Run\ntests" }, { "control", "Run\ttests" }, { "NUL", "Run\0tests" },
  { "overlong ASCII", string.rep("x", 161) }, { "overlong unicode", string.rep("界", 161) },
}) do
  test("malformed prediction rejected: " .. case[1], function()
    local m = mock(); m:predict(case[2]); m:absent(); eq(#m.notices, 0)
  end)
end
for _, case in ipairs({ { "missing result", nil }, { "missing content", {} },
  { "numeric content", { content = 42 } }, { "table content", { content = {} } },
  { "boolean content", { content = true } } }) do
  test("malformed response safely ignored: " .. case[1], function()
    local m = mock(); m:finish(); m:deliver_messages(); m:deliver(case[2]); m:absent()
  end)
end
for _, text in ipairs({ '  "Run the tests"  ', " 'Run the tests' " }) do
  test("trim and unquote " .. text, function()
    local m = mock(); m:predict(text); eq(m:placeholder()[1][1], "Run the tests")
  end)
end
test("160 Unicode characters accepted without byte truncation", function()
  local m = mock(); local text = string.rep("界", 160); m:predict(text); eq(m:placeholder()[1][1], text)
end)
test("context filters last eight text messages, clips Unicode, drops private fields", function()
  local m = mock(); local messages = {}
  for i = 1, 12 do
    messages[#messages + 1] = { role = i % 2 == 1 and "user" or "assistant", content = "message " .. i,
      reasoning = "private reasoning", tool_calls = { { name = "secret tool" } }, images = { "image" }, extra = "private" }
    messages[#messages + 1] = { role = "tool", content = "private output" }
  end
  messages[23].content = string.rep("界", 2001)
  messages[#messages + 1] = { role = "system", content = "private system" }
  messages[#messages + 1] = { role = "assistant", content = { { type = "image" } } }
  messages[#messages + 1] = { role = "user", content = " \n " }
  messages[#messages + 1] = { role = "assistant", reasoning = "reasoning only" }
  m:finish(); m:deliver_messages(messages)
  local sent = m.calls[1].req.messages; eq(#sent, 10); eq(sent[1].role, "system")
  eq(sent[10].role, "user"); eq(sent[10].content, "Predict my next prompt, or return nothing.")
  for i = 1, 8 do
    local original = messages[(i + 3) * 2 + 1]; local included = sent[i + 1]
    eq(included.role, original.role)
    eq(included.content, i == 8 and string.rep("界", 2000) or "message " .. (i + 4))
    for key in pairs(included) do if key ~= "role" and key ~= "content" then error("leaked field " .. key) end end
  end
  eq(char_count(messages[23].content), 2001, "source messages unchanged")
end)
test("empty/non-conversational transcript does not request", function()
  local m = mock(); m:finish(); m:deliver_messages({}); eq(#m.calls, 0)
  m:finish(); m:deliver_messages({ { role = "tool", content = "output" }, { role = "user", content = " " } }); eq(#m.calls, 0)
end)

test("original styling retained without mutating original marks", function()
  local m = mock(); m:predict(); local marks = m.b.ui.prompt_highlight(ctx("Run"))
  eq(marks.highlights, m.marks.highlights); eq(marks.custom, "kept"); eq(marks.ghost, " the tests")
  eq(m.marks.ghost, nil); eq(m.marks.ghost_hl, nil)
  if marks == m.marks then error("returned original marks rather than copy") end
  m.marks.ghost = "original ghost"; m.marks.ghost_hl = "OriginalGhost"
  marks = m.b.ui.prompt_highlight(ctx("Run")); eq(marks.ghost, "original ghost"); eq(marks.ghost_hl, "OriginalGhost")
end)
test("Tab preserves another highlighter's visible ghost", function()
  local m = mock(); m:predict(); m.input = ctx("Run")
  m.marks.ghost = "another completion"
  eq(m.b.ui.actions.complete(), "fallback"); eq(#m.sets, 0)
  m.marks.ghost = nil
  eq(m.b.ui.actions.complete(), true); eq(m.sets[1], "Run the tests")
end)
test("ready redecorates replacement prompt, highlight, and actions; repeated ready idempotent", function()
  local m = mock(); local original = {
    placeholder = { { "Replacement placeholder", "Replacement" } },
    highlight = function() return { ghost = "replacement ghost", ghost_hl = "Replacement" } end,
    complete = function() return "replacement complete" end, dismiss = function() return false end,
  }
  m.b.ui.prompt = { placeholder = original.placeholder, custom = 42 }
  m.b.ui.prompt_highlight = original.highlight; m.b.ui.actions.complete = original.complete; m.b.ui.actions.dismiss = original.dismiss
  m:emit("ready"); local decorated = m.b.ui.prompt.placeholder; m:emit("ready"); eq(m.b.ui.prompt.placeholder, decorated)
  eq(m.b.ui.prompt.custom, 42); eq(m:placeholder(), original.placeholder)
  m:predict(); eq(m:placeholder()[1][1], "Run the tests"); eq(m:ghost(ctx("Run")), "replacement ghost")
  m.input = ctx("Run"); eq(m.b.ui.actions.complete(), "replacement complete"); eq(#m.sets, 0)
  m.input = ctx(""); eq(m.b.ui.actions.complete(), true); eq(m.submits, 0)
  eq(m.b.ui.actions.complete(), "replacement complete")
  m.shutdown(); eq(m.b.ui.prompt.placeholder, original.placeholder); eq(m.b.ui.prompt_highlight, original.highlight)
  eq(m.b.ui.actions.complete, original.complete); eq(m.b.ui.actions.dismiss, original.dismiss)
end)
test("unload restores original UI fields and actions exactly", function()
  local m = mock(); m:predict(); m.shutdown()
  eq(m.b.ui.prompt.placeholder, m.original.placeholder); eq(m.b.ui.prompt_highlight, m.original.highlight)
  eq(m.b.ui.actions.complete, m.original.complete); eq(m.b.ui.actions.dismiss, m.original.dismiss)
end)
test("unload preserves subsequent external replacements", function()
  local m = mock(); local external = function() return "external" end
  m.b.ui.prompt.placeholder = external; m.b.ui.prompt_highlight = external
  m.b.ui.actions.complete = external; m.b.ui.actions.dismiss = external; m.shutdown()
  eq(m.b.ui.prompt.placeholder, external); eq(m.b.ui.prompt_highlight, external)
  eq(m.b.ui.actions.complete, external); eq(m.b.ui.actions.dismiss, external)
end)

local function node_texts(node, out)
  out = out or {}
  if type(node) ~= "table" then return out end
  if type(node.text) == "string" then out[#out + 1] = node.text end
  if type(node.spans) == "table" then
    for _, span in ipairs(node.spans) do
      if type(span) == "table" and type(span.text) == "string" then out[#out + 1] = span.text end
    end
  end
  for _, child in ipairs(node) do node_texts(child, out) end
  return out
end
local function find_control(node, label)
  if type(node) ~= "table" then return nil end
  if node.label == label and node.on_click then return node end
  for _, child in ipairs(node) do
    local found = find_control(child, label)
    if found then return found end
  end
end
local function controls(node, out)
  out = out or {}
  if type(node) ~= "table" then return out end
  if node.on_click or node.on_key then out[#out + 1] = node end
  for _, child in ipairs(node) do controls(child, out) end
  return out
end
local function joined(node) return table.concat(node_texts(node), "|") end

test("gui shows the suggestion in the input placeholder without adding controls", function()
  local m = mock("gui")
  eq(m.slot_adds, 0); eq(m.b.ui.prompt.placeholder ~= m.original.placeholder, true)
  m:predict(); eq(m.invalidations > 0, true, "invalidate when the suggestion changes")
  eq(m:placeholder()[1][1], "Run the tests"); eq(m:placeholder()[1][2], "Placeholder")
  eq(m:row(), nil); eq(m.input.text, ""); eq(#m.sets, 0); eq(m.submits, 0)
  eq(m.b.ui.actions.complete(), true, "tab"); eq(m.sets[1], "Run the tests"); eq(m.submits, 0)
end)
test("gui shows a matching suffix as ghost text and Tab accepts it", function()
  local m = mock("gui"); m:predict(); m.input = ctx("Run")
  eq(m:ghost(), " the tests"); eq(m:placeholder()[1][1], "Original placeholder")
  eq(m.b.ui.actions.complete(), true, "tab"); eq(m.sets[1], "Run the tests")
  eq(m.submits, 0); eq(m.complete_calls, 0)
end)
test("gui hides the placeholder and ghost when the input is ineligible", function()
  local m = mock("gui"); m:predict()
  for _, hidden in ipairs({
    ctx("Other"), ctx("Run", { cursor = { row = 0, col = 1 } }), ctx("Run", { selection = { text = "Run" } }),
    ctx("Run\n"), ctx("/help"), ctx("Run the tests"),
  }) do
    m.input = hidden; eq(m:ghost(), nil, "hidden ghost")
    eq(m:placeholder()[1][1], "Original placeholder", "hidden placeholder")
  end
  m.input = ctx(""); m.context = "popup"; eq(m:placeholder()[1][1], "Original placeholder")
  m.context = "main"; m.panel_focus = "term"; eq(m:placeholder()[1][1], "Original placeholder")
  m.panel_focus = nil; m.node_focus = "search"; eq(m:placeholder()[1][1], "Original placeholder")
end)
test("gui Escape dismisses an in-flight or ready prediction", function()
  local m = mock("gui"); m:finish()
  eq(m:placeholder()[1][1], "Original placeholder")
  eq(m.b.ui.actions.dismiss(), true); m:deliver_messages(); eq(#m.calls, 0)
  m:predict(); m.dismiss_handled = true
  eq(m.b.ui.actions.dismiss(), true, "existing handler"); eq(m:ghost(ctx("Run")), " the tests")
  m.dismiss_handled = false; eq(m.b.ui.actions.dismiss(), true); eq(m:ghost(ctx("Run")), nil)
  eq(m.b.ui.actions.dismiss(), false); eq(m.dismiss_calls, 4)
end)
test("gui unicode prefix accepts like the terminal", function()
  local m = mock("gui"); m:predict("修复é🙂 tests")
  m.input = ctx("修复é🙂"); eq(m:ghost(), " tests")
  eq(m.b.ui.actions.complete(), true); eq(m.sets[1], "修复é🙂 tests"); eq(m.submits, 0)
end)
test("gui ready rewraps the prompt and actions without stacking hooks", function()
  local m = mock("gui"); local wrapped = m.b.ui.actions.complete
  m:emit("ready"); eq(m.b.ui.actions.complete, wrapped); eq(m.slot_adds, 0)
  local replacement = {
    placeholder = { { "Replacement placeholder", "Replacement" } },
    highlight = function() return { ghost = "replacement ghost", ghost_hl = "Replacement" } end,
    complete = function() return "replacement complete" end, dismiss = function() return false end,
  }
  m.b.ui.prompt = { placeholder = replacement.placeholder, custom = 42 }
  m.b.ui.prompt_highlight = replacement.highlight; m.b.ui.actions.complete = replacement.complete
  m.b.ui.actions.dismiss = replacement.dismiss
  m:emit("ready"); local decorated = m.b.ui.prompt.placeholder; m:emit("ready")
  eq(m.b.ui.prompt.placeholder, decorated); eq(m.b.ui.prompt.custom, 42)
  m:predict(); m.input = ctx("Other")
  eq(m.b.ui.actions.complete(), "replacement complete"); eq(#m.sets, 0)
  m.input = ctx(""); eq(m.b.ui.actions.complete(), true); eq(m.sets[1], "Run the tests")
  m.shutdown(); eq(m.b.ui.actions.complete, replacement.complete)
  eq(m.b.ui.actions.dismiss, replacement.dismiss)
  eq(m.b.ui.prompt.placeholder, replacement.placeholder); eq(m.b.ui.prompt_highlight, replacement.highlight)
end)
test("gui unload keeps external replacements", function()
  local m = mock("gui"); local external = function() return "external" end
  m.b.ui.prompt.placeholder = external; m.b.ui.prompt_highlight = external
  m.b.ui.actions.complete = external; m.b.ui.actions.dismiss = external; m.shutdown()
  eq(m.b.ui.prompt.placeholder, external); eq(m.b.ui.prompt_highlight, external)
  eq(m.b.ui.actions.complete, external); eq(m.b.ui.actions.dismiss, external)
end)
test("gui installs prompt hooks without requiring node slots", function()
  local m = mock("gui", { nodes = false })
  eq(m.slot_adds, 0); eq(m.b.ui.prompt.placeholder ~= m.original.placeholder, true)
  eq(m.b.ui.prompt_highlight ~= m.original.highlight, true)
  eq(m.b.ui.actions.complete ~= m.original.complete, true); eq(m.b.ui.actions.dismiss ~= m.original.dismiss, true)
  m:finish(); m:deliver_messages(); eq(#m.calls, 1); eq(m.calls[1].req.provider, nil)
  m:deliver({ content = "Run the tests" }); m.input = ctx("")
  eq(m.b.ui.actions.complete(), true); eq(#m.sets, 1)
  eq(m.invalidations > 0, true); eq(m:row(), nil)
end)

local passed, failed = 0, 0
for _, entry in ipairs(tests) do
  local ok, err = pcall(entry[2])
  if ok then passed = passed + 1; print("ok - " .. entry[1])
  else failed = failed + 1; print("FAIL - " .. entry[1] .. "\n  " .. tostring(err)) end
end
print(string.format("\n%d passed, %d failed (%d total)", passed, failed, #tests))
os.exit(failed == 0 and 0 or 1)
