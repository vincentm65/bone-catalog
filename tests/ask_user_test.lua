-- Run from the catalog root: luajit tests/ask_user_test.lua
-- Loads ui.lua, then the terminal half, then the desktop half.

local function same(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function assert_same(a, b, note)
  assert(same(a, b), (note or "mismatch") .. ": " .. tostring(a) .. " vs " .. tostring(b))
end

-- Core: answer shapes, cancellation, plain strings. ------------------------------

do
  local registered
  local scripted
  bone = {
    tool = { register = function(spec) registered = spec end },
    ask = function(spec)
      assert(spec.kind == "ask_user", "question spec must name ask_user")
      local next_answer = table.remove(scripted, 1)
      return next_answer
    end,
  }
  dofile("plugins/ask_user/core.lua")
  local function run(args, answers)
    scripted = answers
    return registered.run(args)
  end
  local ok, err = run({}, {})
  assert(ok == nil and err:find("at least one", 1, true), err)
  ok, err = run({ questions = { "nope" } }, {})
  assert(ok == nil and err:find("question text", 1, true), err)

  local result = run({
    questions = { { question = "Pick", options = { "A", { label = "Bee", value = "B" } } } },
  }, { { value = "B", label = "Bee", index = 2 } })
  assert(result.cancelled == false)
  assert_same(result.answers[1], {
    question = "Pick", type = "single_select", value = "B", label = "Bee", index = 2,
  })

  result = run({ questions = { { question = "Many", type = "multi_select", options = { "A" } } } }, {
    { values = { "A", "own" }, labels = { "A", "own" }, custom = true },
  })
  assert(result.answers[1].custom == true)
  assert_same(result.answers[1].values, { "A", "own" })

  result = run({ questions = { { question = "Notes", type = "text_input" } } }, { "plain" })
  assert(result.answers[1].value == "plain" and result.answers[1].custom == nil)

  result = run({
    questions = {
      { question = "First", options = { "A" } },
      { question = "Second", options = { "B" } },
    },
  }, { { value = "A", label = "A", index = 1 }, "cancelled" })
  assert(result.cancelled == true and result.cancelled_at == 2)
  assert(#result.answers == 1)

  result = run({ questions = { { question = "Stop", options = { "A" } } } }, { nil })
  assert(result.cancelled == true and #result.answers == 0)
  result = run({ questions = { { question = "Stop", options = { "A" } } } }, { { cancelled = true } })
  assert(result.cancelled == true)
end

-- Frontend fakes. ----------------------------------------------------------------

local now = 10000
local prompt = "draft"
local session = { session_id = "s" }
local handlers = {}
local shutdowns = {}
local requests = {}
local notes = {}
local list_cb
local focused
local keys = {}
local popups = {}
local next_popup = 0
local layout

local function fire(event, data)
  for _, fn in ipairs(handlers[event] or {}) do
    fn(data or {})
  end
end

local function shutdown()
  for i = #shutdowns, 1, -1 do
    shutdowns[i]()
  end
end

local function lines_text(lines)
  local parts = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.text) == "string" then
      parts[#parts + 1] = node.text
    end
    if type(node[1]) == "table" and type(node[1][1]) == "string" then
      for _, span in ipairs(node) do
        if type(span) == "table" and type(span[1]) == "string" then
          parts[#parts + 1] = span[1]
        elseif type(span) == "table" then
          walk(span)
        end
      end
    else
      for _, child in ipairs(node) do
        walk(child)
      end
    end
  end
  walk(lines)
  return table.concat(parts, "\n")
end

local function find_node(node, id)
  if type(node) ~= "table" then
    return nil
  end
  if node.id == id then
    return node
  end
  for _, child in ipairs(node) do
    local found = find_node(child, id)
    if found then
      return found
    end
  end
end

bone = {
  now = function()
    return now
  end,
  has_capability = function()
    return false
  end,
  notify = function(msg, level)
    notes[#notes + 1] = { msg, level }
  end,
  on = function(event, fn)
    handlers[event] = handlers[event] or {}
    handlers[event][#handlers[event] + 1] = fn
  end,
  request = function(method, params, cb)
    requests[#requests + 1] = { method = method, params = params, cb = cb }
    if method == "ask/list" then
      list_cb = cb
    end
  end,
  plugin = { on_shutdown = function(fn) shutdowns[#shutdowns + 1] = fn end },
  chat = { session = function() return session end },
  hl = {
    get = function() return { fg = "#fff", bg = "#111" } end,
    set = function() end,
  },
  text = {
    wrap = function(spans) return { spans } end,
    truncate = function(s) return s end,
    width = function(s) return #tostring(s) end,
  },
  prompt = {
    get = function() return prompt end,
    set = function(s) prompt = s end,
    info = function()
      return { text = prompt, lines = { prompt }, cursor = { row = 0, col = #prompt } }
    end,
  },
  keymap = {
    context = function(name, spec)
      keys[name] = { spec = spec, map = {} }
    end,
    set = function(key, fn, opts)
      keys[opts.context].map[key] = fn
    end,
    focus = function(name) focused = name end,
    clear = function() focused = nil end,
  },
  ui = {
    prompt = { background = "Prompt", padding = { 0, 1 }, prefix = "> ", border = "rounded" },
    regions = {},
    popup = function(spec)
      next_popup = next_popup + 1
      popups[next_popup] = spec
      spec.open = true
      return next_popup
    end,
    close = function(id)
      if popups[id] then
        popups[id].open = false
      end
    end,
    is_open = function(id)
      return popups[id] ~= nil and popups[id].open == true
    end,
  },
  gui = {
    invalidate = function() end,
    focused = function() return nil end,
  },
}
layout = { { rows = { "chat", "prompt" } }, "statusline" }
bone.ui.layout = layout

local ask_handlers_before = 0
dofile("plugins/ask_user/ui.lua")
dofile("plugins/ask_user/tui.lua")
assert(handlers["ask/requested"] and #handlers["ask/requested"] == 1, "one ask/requested handler")
assert(list_cb, "ask/list runs from ui.lua")
assert(bone.ui.regions.ask_user.size == "auto" and bone.ui.regions.ask_user.max == 40)

local function key(name)
  local fn = keys.ask_user.map[name]
  assert(fn, "missing key " .. name)
  return fn()
end

local function question(fields)
  local ev = {
    ask_id = fields.ask_id,
    session_id = fields.session_id,
    question = {
      kind = "ask_user",
      text = fields.text,
      type = fields.type,
      options = fields.options,
      index = fields.index,
      total = fields.total,
    },
  }
  return ev
end

local function answer()
  local req = requests[#requests]
  assert(req.method == "ask/respond", "expected ask/respond")
  return req.params.answer, req
end

-- Late ask/list, before any direct event: the question opens in the prompt.
list_cb({ question({ ask_id = 1, session_id = "s", text = "Pick one", options = { "A", "Bee" } }) })
assert(prompt == "", "opening a question clears the prompt")
assert(focused == "ask_user")
assert(bone.ui.layout ~= layout and bone.ui.layout[1].rows[2] == "ask_user", "prompt slot becomes the question")
assert(layout[1].rows[2] == "prompt", "the saved layout is not edited in place")
local drawn = lines_text(bone.ui.regions.ask_user.render({ width = 40 }))
assert(drawn:find("Pick one", 1, true) and drawn:find("Bee", 1, true), drawn)

-- The key that opened it does not answer. Arrows still move.
key("enter")
assert(requests[#requests].method == "ask/list", "enter during the guard does not answer")
key("down")
now = now + 1000
key("1")
local picked = answer()
assert_same(picked, { value = "A", label = "A", index = 1 })
assert(prompt == "draft" and bone.ui.layout == layout, "draft and layout come back")
assert(focused == nil)

-- Custom text wins over the highlight. A plain multi-select omits custom.
fire("ask/requested", question({
  ask_id = 2, session_id = "s", text = "Choose", type = "single_select",
  options = { { label = "Bee", value = "B", description = "second" } },
}))
assert(prompt == "")
drawn = lines_text(bone.ui.regions.ask_user.render({ width = 60 }))
assert(drawn:find("second", 1, true), drawn)
prompt = "  own  "
now = now + 1000
key("enter")
assert_same(answer(), { value = "own", custom = true })
assert(prompt == "draft")

fire("ask/requested", question({
  ask_id = 3, session_id = "s", text = "Many", type = "multi_select", options = { "A", "B", "C" },
}))
now = now + 1000
assert(key("space") == nil)
key("down")
prompt = ""
key("2")
prompt = "extra"
key("enter")
local multi = answer()
assert(multi.custom == true)
assert_same(multi.values, { "A", "B", "extra" })
assert_same(multi.labels, { "A", "B", "extra" })

-- Empty multi-select confirms the highlighted row, with no custom flag.
fire("ask/requested", question({
  ask_id = 4, session_id = "s", text = "One of", type = "multi_select", options = { "A", "B" },
}))
now = now + 1000
key("down")
key("enter")
multi = answer()
assert(multi.custom == nil)
assert_same(multi.values, { "B" })
assert_same(multi.labels, { "B" })

-- Text question, cancel, queue, and a question for another chat.
fire("ask/requested", question({ ask_id = 5, session_id = "s", text = "Notes", type = "text_input" }))
now = now + 1000
assert(key("space") == false, "space in a text question is typed")
prompt = "  hello  "
key("enter")
assert_same(answer(), { value = "hello" })

fire("ask/requested", question({ ask_id = 6, session_id = "s", text = "Stop?", options = { "A" } }))
fire("ask/requested", question({ ask_id = 7, session_id = "s", text = "Next?", options = { "Z" } }))
fire("ask/requested", question({ ask_id = 6, session_id = "s", text = "Stop?", options = { "A" } }))
now = now + 1000
key("esc")
assert(answer() == "cancelled")
assert(requests[#requests].params.ask_id == 6)
-- The queued question opens, and the prompt draft saved on open is restored after it.
prompt = "kept"
-- The cancel restored "draft", then the next question cleared it. Put a typed answer in.
prompt = "nope"
key("enter")
assert(answer() == "nope" or type(answer()) == "table")
-- Guard: re-read. enter after esc should have opened question 7 immediately, and
-- the prompt was cleared, so "nope" was typed after open. That submits custom text.
assert_same(answer(), { value = "nope", custom = true })

fire("ask/requested", question({ ask_id = 8, session_id = "other", text = "Hidden", options = { "H" } }))
assert(bone.ui.layout == layout, "another chat's question waits")
fire("ask/requested", { ask_id = 9, question = { kind = "confirm", text = "Allow?" } })
assert(bone.ui.layout == layout, "questions that are not ask_user are ignored")
-- The other chat's question would open as soon as that chat is shown.
fire("ask/resolved", { ask_id = 8 })

-- Parking keeps the typed answer in the prompt and restores the choice.
fire("ask/requested", question({ ask_id = 10, session_id = "s", text = "Park", type = "multi_select", options = { "A", "B" } }))
assert(prompt == "")
now = now + 1000
key("space")
key("down")
prompt = "typed"
local while_open = bone.ui.layout
session = { session_id = "other" }
fire("chat/shown")
assert(bone.ui.layout == layout, "leaving the chat gives the prompt row back")
assert(prompt == "typed", "parking does not touch the prompt")
assert(focused == nil)
prompt = "other draft"
session = { session_id = "s" }
prompt = "typed"
fire("chat/shown")
assert(bone.ui.layout == while_open or bone.ui.layout[1].rows[2] == "ask_user")
assert(prompt == "typed", "coming back does not clear the parked answer")
key("enter")
multi = answer()
assert(multi.custom == true)
assert_same(multi.values, { "A", "typed" })
assert(prompt == "draft")

-- Resolved elsewhere closes the field. A parked question is dropped too.
fire("ask/requested", question({ ask_id = 11, session_id = "s", text = "Gone", options = { "A" } }))
fire("ask/resolved", { ask_id = 11 })
assert(bone.ui.layout == layout and prompt == "draft")
fire("ask/requested", question({ ask_id = 12, session_id = "s", text = "Away", options = { "A" } }))
session = { session_id = "other" }
fire("chat/shown")
fire("ask/resolved", { ask_id = 12 })
session = { session_id = "s" }
fire("chat/shown")
assert(bone.ui.layout == layout, "a resolved parked question does not return")

-- Digits type once the answer is non-empty. Respond errors are reported.
fire("ask/requested", question({ ask_id = 13, session_id = "s", text = "Digit", options = { "A" } }))
now = now + 1000
prompt = "x"
assert(key("1") == false)
prompt = ""
key("enter")
local req = requests[#requests]
req.cb(nil, { message = "nope" })
assert(notes[#notes][1]:find("nope", 1, true) and notes[#notes][2] == "error")

-- Reload puts the prompt and layout back and drops the region.
fire("ask/requested", question({ ask_id = 14, session_id = "s", text = "Reload", options = { "A", "B" } }))
prompt = "half"
shutdown()
assert(bone.ui.layout == layout)
assert(prompt == "draft")
assert(bone.ui.regions.ask_user == nil)
fire("ask/resolved", { ask_id = 14 })

-- Desktop half: same handler, its own window, overlay suppressed. ---------------

local overlay_nodes
local builtin = {
  nodes = function()
    return {
      { text = "toast" },
      {
        z = 10, block_input = true, label = "Reload",
        { id = "ask:14", text = "old" },
      },
      {
        z = 10, block_input = true, label = "Pick",
        { id = "ask:20", text = "ours" },
        { text = "allow" },
      },
      {
        z = 10, block_input = true, label = "Allow shell?",
        { id = "ask:21", text = "approve" },
      },
      nil,
    }
  end,
}
package.loaded["bone.nodes.overlays"] = builtin
overlay_nodes = builtin.nodes
bone.has_capability = function(name)
  return name == "gui.nodes"
end
local asked = #handlers["ask/requested"]
dofile("plugins/ask_user/gui.lua")
assert(#handlers["ask/requested"] == asked, "the desktop half must not listen for ask/requested again")
assert(builtin.nodes ~= overlay_nodes, "the built-in overlay is wrapped while the plugin is loaded")

local function popup()
  return popups[next_popup]
end

local function tree()
  return popup().node({ width = 400, height = 500 })
end

fire("ask/requested", question({
  ask_id = 20, session_id = "s", text = "Pick a color", index = 1, total = 2,
  options = {
    { label = "Red", value = "r", description = "warm" },
    "Blue",
  },
}))
assert(popup() and popup().open, "a question opens a popup")
assert(prompt == "draft", "the desktop question does not take the composer draft")
local root = tree()
assert(root.id == "ask_user:dialog" and root.role == "dialog")
assert(find_node(root, "ask_user:input").text_input.placeholder:find("own", 1, true))
assert(lines_text(root):find("Question 1 of 2", 1, true))
assert(lines_text(root):find("warm", 1, true))
local shown = builtin.nodes({})
local ids = {}
for _, node in ipairs(shown) do
  if type(node) == "table" and node[1] and type(node[1]) == "table" then
    ids[#ids + 1] = node[1].id
  end
end
assert(ids[1] == nil or ids[1] ~= "ask:20")
local saw_ours, saw_approve, saw_toast = false, false, false
for _, node in ipairs(shown) do
  if type(node) == "table" and node.text == "toast" then
    saw_toast = true
  end
  local child = type(node) == "table" and node[1]
  if type(child) == "table" and child.id == "ask:20" then
    saw_ours = true
  end
  if type(child) == "table" and child.id == "ask:21" then
    saw_approve = true
  end
end
assert(saw_toast and saw_approve and not saw_ours, "only our question's built-in card is hidden")

-- Pointer: clicking an option chooses it, even if text was typed.
local input = find_node(tree(), "ask_user:input")
input.text_input.on_change("typed")
find_node(tree(), "ask_user:opt:2").on_click()
assert_same(answer(), { value = "Blue", label = "Blue", index = 2 })
assert(not popup().open)

-- Keys on the window: move, 1-9, space, enter, esc. Text field focus types.
fire("ask/requested", question({
  ask_id = 22, session_id = "s", text = "Several", type = "multi_select",
  options = { "A", "B", "C" },
}))
now = now + 1000
local gui_focused = nil
bone.gui.focused = function() return gui_focused end
assert(popup().on_key("1") == true)
popup().on_key("down")
popup().on_key("space")
-- Not empty: space types, and 9 types, once the field has text from space? 
-- space toggled while empty. Insert a letter from the dialog keys.
popup().on_key("z")
assert(popup().on_key("9") == true)
find_node(tree(), "ask_user:submit").on_click()
multi = answer()
assert(multi.custom == true)
assert_same(multi.values, { "A", "B", "z9" })

fire("ask/requested", question({ ask_id = 23, session_id = "s", text = "Field", options = { "A", "B" } }))
now = now + 1000
gui_focused = "ask_user:input"
assert(popup().on_key("up") == true)
assert(popup().on_key("backspace") == false, "backspace edits the field")
local field = find_node(tree(), "ask_user:input")
field.text_input.on_change("own")
field.text_input.on_submit("own")
assert_same(answer(), { value = "own", custom = true })

-- esc cancels. A question for another chat closes the window and comes back.
fire("ask/requested", question({ ask_id = 24, session_id = "s", text = "Leave", options = { "A" } }))
now = now + 1000
gui_focused = nil
popup().on_key("x")
popup().on_key("esc")
assert(answer() == "cancelled")

fire("ask/requested", question({ ask_id = 25, session_id = "s", text = "Away", type = "text_input" }))
local id = next_popup
find_node(tree(), "ask_user:input").text_input.on_change("kept")
session = { session_id = "other" }
fire("chat/shown")
assert(not popups[id].open, "leaving the chat closes the window")
session = { session_id = "s" }
fire("chat/shown")
assert(popup().open)
assert(find_node(tree(), "ask_user:input").text_input.value == "kept")
find_node(tree(), "ask_user:submit").on_click()
assert_same(answer(), { value = "kept" })

-- Empty answer does not send. Cancel does.
fire("ask/requested", question({ ask_id = 26, session_id = "s", text = "Empty", type = "text_input" }))
local before = #requests
find_node(tree(), "ask_user:submit").on_click()
assert(#requests == before, "an empty text answer is not sent")
find_node(tree(), "ask_user:cancel").on_click()
assert(answer() == "cancelled")

-- Shutdown restores the built-in overlay.
assert(builtin.nodes == package.loaded["bone.nodes.overlays"].nodes)
shutdown()
assert(builtin.nodes == overlay_nodes, "shutdown restores the built-in question card")

print("ask_user tests passed")
