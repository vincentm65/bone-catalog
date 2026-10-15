-- Run from the catalog root: luajit tests/codex_app_test.lua
-- Load the real defaults with mocked host APIs; no terminal or server needed.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") .. "../"
local deferred, refreshes, room = {}, 0, 160
local function noop() end
local function find(list, name)
  for _, e in ipairs(list or {}) do
    if type(e) == "table" then
      if e[1] == name then return e end
      local found = find(e.rows, name) or find(e.cols, name)
      if found then return found end
    elseif e == name then return e end
  end
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

package.loaded["bone.ui.sessions"] = { toggle = noop, open = noop }
bone = {
  builtin = noop,
  hl = { set = noop },
  state = { load = function() return {} end },
  keymap = { set = noop },
  on = noop,
  defer = function(ms, fn)
    assert(ms == 0)
    deferred[#deferred + 1] = fn
  end,
  ui = {
    views = {}, regions = {},
    refresh_in = function(ms) assert(ms == 0); refreshes = refreshes + 1 end,
    geometry = function()
      local left, right = find(bone.ui.layout, "pad_l"), find(bone.ui.layout, "pad_r")
      return { leaves = {
        { name = "sessions", width = 28 }, -- Not part of the middle column.
        { name = "pad_l", width = left.size },
        { name = find(bone.ui.layout, "ask_user") and "ask_user" or "prompt", width = room - left.size - right.size },
        { name = "pad_r", width = right.size },
      } }
    end,
  },
}
dofile(root .. "tuis/codex-app/tui/defaults.lua")

local function render()
  bone.ui.regions.pad_l.render()
  bone.ui.regions.pad_r.render()
end
local function settle(expected, label, already_correct)
  local layout, before = bone.ui.layout, refreshes
  render()
  assert(#deferred == 1 or (already_correct and #deferred == 0), label .. ": expected one deferred margin update")
  local pending = deferred; deferred = {}
  for _, fn in ipairs(pending) do fn() end
  assert(bone.ui.layout == layout, label .. ": must preserve current layout identity")
  assert(find(layout, "pad_l").size == expected, label .. ": stale left margin")
  assert(find(layout, "pad_r").size == expected, label .. ": stale right margin")
  assert(refreshes == before + #pending, label .. ": one refresh per update")
  for _ = 1, 5 do render() end
  assert(#deferred == 0 and refreshes == before + #pending, label .. ": must not continuously redraw")
end

settle(32, "initial wide thread")
-- Match ask_user's ownership: retain the actual original layout, edit a deep
-- copy while asking, then restore the saved table (not a newly built layout).
local saved = bone.ui.layout
local question = copy(saved)
local middle = question[3].cols[2].rows
for i, entry in ipairs(middle) do
  if entry == "prompt" then middle[i] = "ask_user" end
end
middle[#middle + 1] = { "plugin_extra", size = 2 }
bone.ui.layout = question
settle(32, "question layout at unchanged width", true)
room = 120
settle(12, "resize while asking")
assert(find(question, "ask_user") and not find(question, "prompt"), "must not replace the question")
assert(find(question, "plugin_extra").size == 2, "must preserve plugin regions")
assert(find(saved, "pad_l").size == 32 and find(saved, "pad_r").size == 32, "saved layout still has old margins")
bone.ui.layout = saved
settle(12, "restore actual saved layout after resize")
assert(find(saved, "prompt") and not find(saved, "ask_user"), "restored composer must remain intact")
room = 80
settle(1, "narrow thread")
room = 180
settle(42, "widen thread again")
print("codex-app margin checks passed")
