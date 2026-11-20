-- Run from catalog root: luajit tests/term_gui_test.lua
-- The desktop app's side of the multiplexer (term.mux's node and its mouse
-- handler), with a stand-in bone: what a wheel, a click and the right and
-- middle buttons send to the program in a pane.
package.path = "plugins/term/lua/?.lua;" .. package.path

local COLS, ROWS, CW, CH = 80, 24, 8, 18
local RECT = { x = 4, y = 33, w = COLS * CW, h = ROWS * CH } -- the pane in the window
local writes, handlers, asked = {}, {}, {}
local screen = { lines = {}, cursor = { 1, 1 }, mouse = "button_motion", mouse_encoding = "sgr", max = 0, scroll = 0 }
local job = { id = 1 }
function job:write(bytes) writes[#writes + 1] = bytes end
function job:screen(size)
  asked = size or asked
  screen.scroll = math.min(screen.max, size and size.scroll or 0)
  return screen
end
function job:status() return {} end
function job:cancel() end

local panel
bone = {
  has_capability = function(name) return name == "gui.window_nodes" end,
  hl = { set = function() end, get = function() return { fg = "#cccccc", bg = "#101010" } end },
  text = { width = function(s) return #s end },
  job = { start = function() return job end },
  chat = { session = function() return { cwd = "/project" } end },
  ui = { panel = {
    open = function(spec) panel = spec return spec end,
    get = function() return panel end,
    focus = function() end, focused = function() return "terminal" end, close = function() panel = nil end,
  } },
  gui = {
    invalidate = function() end,
    rect = function(id) return id == "term:pane:1" and RECT or nil end,
    window_info = function() return { cell = { w = CW, h = CH } } end,
  },
  on = function(name, fn) handlers[name] = fn return name end, off = function(name) handlers[name] = nil end,
  plugin = {}, o = { font_size = 14 }, now = function() return 0 end, notify = function() end,
}

local mux = require("term.mux")
mux.setup({ encode = function(key) return key end, escape = {}, passthrough = {}, defaults = { dock = "bottom", size = 0.4 } })
mux.new_tab()
local ctx = { width = COLS * CW + 8, height = ROWS * CH + 30 + 1 + 4, cell = { w = CW, h = CH }, focused = true }
local function pane()
  local root = mux.node(ctx)
  for _, n in ipairs(root[#root]) do if n.id == "term:pane:1" then return n end end
end
local function sent()
  local out = table.concat(writes, "|")
  writes = {}
  return out
end
-- Window pixels inside cell (col, row) of the pane.
local function px(col, row) return RECT.x + (col - 1) * CW + 3, RECT.y + (row - 1) * CH + 3 end
local function mouse(action, button, col, row, extra)
  local ev = extra or {}
  ev.action, ev.button = action, button
  if col then ev.px, ev.py = px(col, row) end
  return handlers.mouse(ev)
end
local box = pane()
assert(box and handlers.mouse, "the desktop app has a mouse handler too")

-- The wheel: a step for each 50 points of the frame's travel, at the cell
-- under the pointer (the wheel's mouse event comes before on_scroll).
local up, down = "\27[<64;10;5M", "\27[<65;10;5M"
assert(not mouse("wheel", "up", 10, 5), "the wheel is left to on_scroll")
box.on_scroll(50); assert(sent() == up)
mouse("wheel", "up", 10, 5); box.on_scroll(150); assert(sent() == up:rep(3), "three lines of travel are three steps")
mouse("wheel", "down", 10, 5); box.on_scroll(-100); assert(sent() == down:rep(2))
-- A trackpad's small travel adds up over frames; turning around starts over.
mouse("wheel", "up", 10, 5); box.on_scroll(20); assert(sent() == "")
mouse("wheel", "up", 10, 5); box.on_scroll(20); assert(sent() == "")
mouse("wheel", "up", 10, 5); box.on_scroll(20); assert(sent() == up)
mouse("wheel", "up", 10, 5); box.on_scroll(40); assert(sent() == up, "the 10 left over counted")
mouse("wheel", "down", 10, 5); box.on_scroll(-45); assert(sent() == "", "the other way: nothing carried")
mouse("wheel", "down", 10, 5); box.on_scroll(-5); assert(sent() == down)
-- A frame sends no more than ten, and travel sideways alone is not a step.
mouse("wheel", "up", 10, 5); box.on_scroll(5000); assert(sent() == up:rep(10))
box.on_scroll(0); assert(sent() == "")
-- With no pointer known it is the middle of the pane, not last frame's cell.
box.on_scroll(50); assert(sent() == "\27[<64;40;12M")
-- A program that does not take the mouse: the steps scroll back, three rows each.
screen.mouse, screen.max = "none", 100
box = pane()
box.on_scroll(100); assert(sent() == "")
pane(); assert(asked.scroll == 6)
box.on_scroll(-50); pane(); assert(asked.scroll == 3)
box.on_scroll(-50); pane(); assert(asked.scroll == 0)
screen.mouse = "button_motion"
box = pane()

-- The left button is the pane's own: a release names its button.
box.on_press({ x = 9 * CW + 2, y = 4 * CH + 2 }); assert(sent() == "\27[<0;10;5M")
box.on_release({ x = 9 * CW + 2, y = 4 * CH + 2 }); assert(sent() == "\27[<0;10;5m")
box.on_press({ x = 9 * CW + 2, y = 4 * CH + 2 })
box.on_drag({ x = RECT.x + 15 * CW + 2, y = RECT.y + 4 * CH + 2 })
box.on_release({ x = 15 * CW + 2, y = 4 * CH + 2 })
assert(sent() == "\27[<0;10;5M|\27[<32;16;5M|\27[<0;16;5m")
assert(not mouse("down", "left", 10, 5) and sent() == "", "the mouse handler leaves the left button to the nodes")

-- The right and middle buttons of a program that takes the mouse: press,
-- drag and release, the release where the pointer last was in the pane.
assert(mouse("down", "right", 10, 5) and sent() == "\27[<2;10;5M")
assert(mouse("drag", "right", 12, 7) and sent() == "\27[<34;12;7M")
assert(handlers.mouse({ action = "up", button = "right", px = 0, py = 0 }) and sent() == "\27[<2;12;7m")
assert(not mouse("up", "right", 12, 7) and sent() == "", "a release with nothing held is not the program's")
-- Another button's release while one is held is not that one's.
assert(mouse("down", "right", 10, 5) and not mouse("up", "left", 10, 5) and sent() == "\27[<2;10;5M")
assert(mouse("up", "right", 10, 5) and sent() == "\27[<2;10;5m")
assert(mouse("down", "middle", 3, 2) and mouse("up", "middle", 3, 2) and sent() == "\27[<1;3;2M|\27[<1;3;2m")
-- Not over a pane, under a popup, or a program that does not take the mouse: bone's own click.
assert(not handlers.mouse({ action = "down", button = "right", px = 1, py = 1 }) and sent() == "")
assert(not mouse("down", "right", 10, 5, { popup = 7 }) and sent() == "")
screen.mouse = "none"; pane()
assert(not mouse("down", "right", 10, 5) and not mouse("down", "middle", 10, 5) and sent() == "")
print("term gui tests passed: wheel steps/position/carry/cap/scrollback, left release, right and middle buttons")
