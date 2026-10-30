-- Summary plugin checks; run from catalog root:
--   luajit tests/summary_test.lua
package.path = "plugins/summary/lua/?.lua;" .. package.path

local item = { kind = "assistant", key = "answer", index = 1, text = "the full answer" }
local events, keys = {}, {}
local model_done

bone = {
  chat = {
    session = function() return { session_id = "session" } end,
    items = function() return { item } end,
    item = function() return item end,
    redraw = function() end,
  },
  ui = { views = {
    assistant = function(i) return { { { i.text, "Normal" } } } end,
  } },
  text = { truncate = function(text) return text end },
  model = {
    complete = function(request, _, done)
      assert(request.prompt:find("the full answer", 1, true))
      model_done = done
    end,
  },
  on = function(name, fn) events[name] = fn end,
  defer = function(ms, fn) assert(ms == 0); fn() end,
  keymap = { set = function(name, fn) keys[name] = fn end },
  plugin = { on_shutdown = function() end },
}

dofile("plugins/summary/ui.lua")
events["message/completed"]({ session_id = "session" })
assert(model_done, "the completed answer should be summarized")
model_done({ content = "first line\nsecond line\nthird line\nfourth line" })

local summary = require("summary")
assert(summary.get(item) == "first line\nsecond line\nthird line")
assert(not summary.is_expanded(item))

dofile("plugins/summary/tui.lua")
local collapsed = bone.ui.views.assistant(item, { width = 80 })
assert(collapsed[1][1][1] == "  Summary: first line")
assert(collapsed[#collapsed][1][1]:find("expand", 1, true))
summary.toggle(item)
local expanded = bone.ui.views.assistant(item, { width = 80 })
assert(#expanded > #collapsed)
local full_answer
for _, row in ipairs(expanded) do
  if row[1] and row[1][1] == "  Full answer" then full_answer = true end
end
assert(full_answer, "the expanded view should include the full answer")
assert(keys["ctrl+shift+e"], "the expansion shortcut should be registered")
print("summary: model summaries are capped at three lines and expand/collapse works")
