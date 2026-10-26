-- Tiled windows without a screen: the tree of windows, what each one shows,
-- focus, and what changes them. A frontend draws the tree (tui.lua as layout
-- leaves, gui.lua as nodes) and is passed in as `fe`:
--
--   fe.state         bone.plugin.state(), where the tree is saved
--   fe.apply()       the tree changed: draw it again
--   fe.rects()       { [id] = { x, y, width, height } } from the last frame
--   fe.min           the least a resize leaves a window, in rects() units
--   fe.step, fe.rows_step   a keyboard resize, across and down
--   fe.on_new(id), fe.on_forget(id, win)   mount / release frontend content
--
-- A window holds a chat buffer or a shared panel (terminal, browser, …).
-- active is the pane with the keyboard; chatwin is the last visible chat.
-- Tree nodes: { win = id, w } or { dir = "cols" | "rows", w, kids }.
-- `w` is a share of the parent split.
local M = {}

local PREFIX = bone.settings.get("windows.prefix")
if type(PREFIX) ~= "string" or PREFIX == "" then PREFIX = "alt+w" end
M.PREFIX = PREFIX

function M.new(fe)
  local W = { wins = {}, root = nil, chatwin = nil, active = nil, zoomed = false, unread = {} }
  local st = fe.state
  local wins, unread = W.wins, W.unread
  local seq, switching, started = 0, false, false
  local broadcast, resizing = false, nil

  -- Shared callbacks can reenter us or fail; never leave event following disabled.
  local function changing(fn)
    local before = switching
    switching = true
    local ok, result = pcall(fn)
    switching = before
    if not ok then error(result, 0) end
    return result
  end

  local function current_sid()
    local s = bone.chat.session()
    return s and s.session_id
  end

  function W.count()
    local n = 0
    for _ in pairs(wins) do n = n + 1 end
    return n
  end

  -- The window showing session `sid` (or with `key` = sid).
  function W.win_of(sid, key)
    for id, w in pairs(wins) do
      if sid and w[key or "sid"] == sid then return id end
    end
  end

  function W.panel_win(pid) return W.win_of(pid, "panel") end

  -- The active pane, independently of the chat targeted by chat actions.
  function W.here()
    return W.active or W.chatwin
  end

  -- The focused window shows whatever chat is on screen.
  local function sync()
    local w, s = W.chatwin and wins[W.chatwin], bone.chat.session()
    if w and s then w.sid, w.chat = s.session_id, s.chat end
  end
  W.sync = sync

  -- ---- tree ----------------------------------------------------------------

  -- The node matching `pred`, its parent and its index there.
  local function locate(node, pred, parent, i)
    if not node then return end
    if pred(node) then return node, parent, i end
    for j, k in ipairs(node.kids or {}) do
      local a, b, c = locate(k, pred, node, j)
      if a then return a, b, c end
    end
  end
  W.locate = locate

  function W.leaf(id)
    return locate(W.root, function(n) return n.win == id end)
  end

  local function each_win(node, f)
    if node.win then return f(node.win) end
    for _, k in ipairs(node.kids) do each_win(k, f) end
  end
  W.each_win = each_win

  local function first_win(node)
    local n = locate(node, function(n) return n.win end)
    return n and n.win
  end

  -- Terminals are not saved: their programs end with bone.
  local function encode(node)
    if node.win then
      local win = wins[node.win]
      if win.panel then return nil end
      local chat = bone.chat.session({ session = tostring(win.chat) })
      return { sid = chat and chat.session_id or win.sid, chat = win.chat, w = node.w,
        focus = node.win == W.chatwin or nil, zoom = node.win == W.zoomed or nil }
    end
    local kids = {}
    for _, k in ipairs(node.kids) do kids[#kids + 1] = encode(k) end
    if #kids <= 1 then
      if kids[1] then kids[1].w = node.w end
      return kids[1]
    end
    return { dir = node.dir, w = node.w, kids = kids }
  end

  function W.save()
    if not W.root then return end
    sync()
    st.tree = W.count() > 1 and encode(W.root) or nil
  end

  local function apply()
    if not W.root then return end
    for id, w in pairs(wins) do
      local hidden = W.zoomed and W.zoomed ~= id or false
      if w.panel and bone.ui.panel.get(w.panel) and (w.hidden or false) ~= hidden then
        w.hidden = hidden
        bone.ui.panel.update(w.panel, { hidden = hidden })
      end
    end
    fe.apply()
    W.save()
  end
  W.apply = apply

  -- ---- geometry ------------------------------------------------------------

  local function union(node, r)
    local x0, y0, x1, y1
    each_win(node, function(id)
      local o = r[id]
      if o then
        x0, y0 = math.min(x0 or o.x, o.x), math.min(y0 or o.y, o.y)
        x1, y1 = math.max(x1 or 0, o.x + o.width), math.max(y1 or 0, o.y + o.height)
      end
    end)
    if x0 then return { x = x0, y = y0, width = x1 - x0, height = y1 - y0 } end
  end

  -- The window at a point, in rects() units.
  function W.win_at(x, y)
    for id, o in pairs(fe.rects()) do
      if x >= o.x and x < o.x + o.width and y >= o.y and y < o.y + o.height then return id end
    end
  end

  -- The nearest window in direction h/j/k/l from the one with the keyboard.
  function W.neighbor(dir)
    local r = fe.rects()
    local me = r[W.here()]
    if not me then return end
    local best, score
    for id, o in pairs(r) do
      local gap, off
      if dir == "h" or dir == "l" then
        gap = dir == "h" and me.x - (o.x + o.width) or o.x - (me.x + me.width)
        off = o.y < me.y + me.height and o.y + o.height > me.y and math.abs(o.y - me.y)
      else
        gap = dir == "k" and me.y - (o.y + o.height) or o.y - (me.y + me.height)
        off = o.x < me.x + me.width and o.x + o.width > me.x and math.abs(o.x - me.x)
      end
      if id ~= W.here() and gap >= 0 and off then
        local s = gap * 10000 + off
        if not score or s < score then best, score = id, s end
      end
    end
    return best
  end

  W.bounds = function(node) return union(node, fe.rects()) end

  function W.weight(node)
    local total = 0
    for _, k in ipairs(node.kids) do total = total + k.w end
    return total
  end

  -- Both input paths resize the same measured pair, excluding separators.
  -- In a cramped area the effective minimum shrinks to half the pair.
  function W.resize(split, i, j, along, relative)
    local a, b = split.kids[i], split.kids[j]
    local ra, rb = W.bounds(a), W.bounds(b)
    if not (ra and rb) then return end
    local axis = split.dir == "cols" and "width" or "height"
    local room = ra[axis] + rb[axis]
    if room <= 0 then return end
    local min, share = math.min(fe.min, room / 2), a.w + b.w
    if relative then along = room * a.w / share + along end
    a.w = share * math.max(min, math.min(room - min, along)) / room
    b.w = share - a.w
    apply()
  end

  -- ---- windows -------------------------------------------------------------

  -- A window for session `sid` (nil: a new chat) or shared panel `panel`;
  -- `chat` if its chat is already open.
  local function new_win(sid, panel, chat)
    seq = seq + 1
    local id = seq
    wins[id] = { id = id, sid = sid, panel = panel, chat = chat or not panel and bone.chat.open(sid) or nil }
    if fe.on_new then fe.on_new(id) end
    return id
  end

  -- A forgotten terminal window's program stops (its panel closes).
  local function forget(id)
    local w = wins[id]
    wins[id] = nil
    if W.chatwin == id then W.chatwin = nil end
    if fe.on_forget then fe.on_forget(id, w) end
    if w.panel then bone.ui.panel.close(w.panel) end
  end

  function W.focus(id)
    local w = wins[id]
    if not w then return end
    sync()
    if id ~= W.here() then W.last = W.here() end
    W.active = id
    if W.zoomed and W.zoomed ~= id then W.zoomed = false end
    changing(function()
      if w.panel then
        local p = bone.ui.panel.get(w.panel)
        if p and p:info().hidden then bone.ui.panel.update(w.panel, { hidden = false }) end
        w.hidden = false
        bone.ui.panel.focus(w.panel)
      else
        W.chatwin = id
        if W.panel_win(bone.ui.panel.focused()) then bone.ui.panel.focus(nil) end
        bone.api.open_session(tostring(w.chat))
      end
    end)
    apply()
  end
  local focus = W.focus

  -- Put `node` on `side` of `target` ("left"|"right"|"up"|"down"), taking half
  -- of the target. Left and up insert before it; right and down, after.
  local function graft(node, target, side)
    local dir = (side == "left" or side == "right") and "cols" or "rows"
    local before = side == "left" or side == "up"
    local at, parent, i = W.leaf(target)
    if not at then return end
    if parent and parent.dir == dir then
      at.w = at.w / 2
      node.w = at.w
      table.insert(parent.kids, before and i or i + 1, node)
    else
      node.w = 1
      local s = { dir = dir, w = at.w, kids = before and { node, at } or { at, node } }
      at.w = 1
      if parent then parent.kids[i] = s else W.root = s end
    end
  end

  -- Split window `at` (default: the one with the keyboard, and then the new
  -- window takes focus) along `dir` with a new one showing `sid` (nil: a new
  -- chat), or a shared panel. `chat` reuses an already-open chat buffer.
  function W.split(dir, sid, at, panel, chat)
    sync()
    if sid and W.win_of(sid) then return at or focus(W.win_of(sid)) end
    W.zoomed = false
    local new = { win = new_win(sid, panel, chat), w = 1 }
    graft(new, at or W.here(), dir == "cols" and "right" or "down")
    if not at then return focus(new.win) end
    apply()
  end
  local split = W.split

  -- Lift node `node` (at `i` in `parent`) out of the tree. A split left with
  -- one kid gives way to it; one inside a split of its direction joins it.
  local function lift(parent, i)
    local node = table.remove(parent.kids, i)
    if #parent.kids == 1 then
      local only = parent.kids[1]
      only.w = parent.w
      local _, gp, gi = locate(W.root, function(n) return n == parent end)
      if gp then gp.kids[gi] = only else W.root = only end
      if gp and only.dir == gp.dir then
        table.remove(gp.kids, gi)
        local scale = only.w / W.weight(only)
        for k = #only.kids, 1, -1 do
          only.kids[k].w = only.kids[k].w * scale
          table.insert(gp.kids, gi, only.kids[k])
        end
      end
    end
    return node
  end

  function W.close(id)
    id = id or W.here()
    if not wins[id] then return end
    local _, parent, i = W.leaf(id)
    if not parent and not wins[id].panel then return end
    sync()
    local was = id == W.here()
    if W.zoomed == id then W.zoomed = false end
    if parent then
      lift(parent, i)
    else
      W.root = { win = new_win(current_sid(), nil, bone.chat.session().chat), w = 1 }
    end
    changing(function() forget(id) end)
    if was then focus(W.chatwin or first_win(W.root)) else apply() end
  end

  function W.only()
    sync()
    local keep = W.here()
    changing(function()
      for id in pairs(wins) do if id ~= keep then forget(id) end end
    end)
    W.root, W.zoomed = { win = keep, w = 1 }, false
    apply()
  end

  -- Swap two windows; the focused id stays, so focus follows that chat.
  function W.exchange(a, b)
    if not a or not b or a == b then return end
    local na, nb = W.leaf(a), W.leaf(b)
    if not na or not nb then return end
    na.win, nb.win = nb.win, na.win
    apply()
  end

  -- Move `id` onto `target`: no side swaps them, a side splits `target` in half.
  function W.move_to(id, target, side)
    if not side then return W.exchange(id, target) end
    if id == target or not wins[id] or not wins[target] then return end
    local _, parent, i = W.leaf(id)
    if not parent then return end
    local node = lift(parent, i)
    graft(node, target, side)
    apply()
  end

  local function equalize(node)
    node = node or W.root
    node.w = 1
    for _, k in ipairs(node.kids or {}) do equalize(k) end
    if node == W.root then apply() end
  end
  W.equalize = equalize

  function W.zoom()
    W.zoomed = not W.zoomed and W.here()
    apply()
  end

  -- Every window moves one place along; focus stays with its chat.
  function W.rotate()
    local nodes = {}
    locate(W.root, function(n) nodes[#nodes + 1] = n.win and n or nil end)
    local first = nodes[1].win
    for i = 1, #nodes - 1 do nodes[i].win = nodes[i + 1].win end
    nodes[#nodes].win = first
    apply()
  end

  -- Grow the window with the keyboard by `units` along "cols" or "rows".
  function W.grow(dir, units)
    local child, parent, i = W.leaf(W.here())
    while parent do
      if parent.dir == dir and #parent.kids > 1 then
        local j = i < #parent.kids and i + 1 or i - 1
        return W.resize(parent, i, j, units, true)
      end
      child = parent
      _, parent, i = locate(W.root, function(n) return n == child end)
    end
  end

  -- What a window shows: its session's title, whether it runs, and whether
  -- a turn ended there unseen.
  function W.label(id)
    local w = wins[id]
    if not w then return end
    if w.panel then
      local p = bone.ui.panel.get(w.panel)
      return { name = p and p:info().title or w.panel }
    end
    local s = w.chat and bone.chat.session({ session = tostring(w.chat) })
    local sid = s and s.session_id
    return { name = sid and (s.title or "[untitled]") or "new chat", running = s and s.running,
      unread = sid and unread[sid] or false }
  end

  -- ---- startup and following the chat on screen ----------------------------

  local function restore(t, reloading)
    local function walk(n)
      if n.kids then
        local kids = {}
        for _, k in ipairs(n.kids) do kids[#kids + 1] = walk(k) end
        return { dir = n.dir, w = n.w or 1, kids = kids }
      end
      -- Buffer numbers survive a Lua reload, including chats with no session
      -- yet. They are process-local, so never trust them on a fresh start.
      local existing = reloading and n.chat ~= nil and bone.chat.session({ session = tostring(n.chat) })
      local chat = existing and existing.chat or (n.focus and bone.chat.session().chat)
      local id = new_win(n.sid, nil, chat)
      if n.focus then W.chatwin = id end
      if n.zoom then W.zoomed = id end
      return { win = id, w = n.w or 1 }
    end
    W.root = walk(t)
    W.chatwin = W.chatwin or first_win(W.root)
    W.active = W.chatwin
    -- Show the focused window's session unless a chat was already chosen.
    local want, s = wins[W.chatwin].sid, bone.chat.session()
    if not reloading and want and s and s.new and s.items == 0 then
      changing(function() bone.api.open_session(want) end)
    end
    sync()
  end

  local function start(ev)
    if started then return end
    started = true
    -- A reload validates ready handlers before accepting the new Lua state.
    -- Defer activation so a rejected candidate cannot create/switch chats.
    bone.defer(0, function()
      if fe.start then fe.start() end
      if type(st.tree) == "table" then
        restore(st.tree, ev and ev.reload)
      else
        W.root = { win = new_win(current_sid(), nil, bone.chat.session().chat), w = 1 }
        W.chatwin, W.active = W.root.win, W.root.win
      end
      apply()
    end)
  end

  -- Another way of changing the chat (ctrl+o, a click on a sub-agent, ctrl+n)
  -- changes what the focused window shows, or focuses the window that has it.
  bone.on("chat/shown", function(ev)
    unread[ev.session_id or ""] = nil
    if switching or not W.root then return end
    W.chatwin = W.win_of(ev.chat, "chat") or W.chatwin
    if not W.chatwin then return W.split("cols", ev.session_id, nil, nil, ev.chat) end
    wins[W.chatwin].sid, wins[W.chatwin].chat = ev.session_id, ev.chat
    W.active = W.chatwin
    if W.zoomed then W.zoomed = W.active end
    changing(function()
      if W.panel_win(bone.ui.panel.focused()) then bone.ui.panel.focus(nil) end
    end)
    apply()
  end)

  -- Shared panel focus changes (including terminal escape/toggle) select panes.
  bone.on("focus/changed", function(ev)
    if switching or not W.root or ev.popup then return end
    local id = W.panel_win(ev.panel)
    if ev.panel and not id then return end
    id = id or W.chatwin
    if not id then return W.split("cols", current_sid(), nil, nil, bone.chat.session().chat) end
    focus(id)
  end)

  -- A new chat gets its session id with its first turn.
  bone.on("turn/started", function(ev)
    if W.chatwin and wins[W.chatwin] and ev.session_id == current_sid() then
      wins[W.chatwin].sid = ev.session_id
      W.save()
    end
  end)

  bone.on("turn/finished", function(ev)
    if ev.session_id ~= current_sid() then unread[ev.session_id] = true end
  end)

  bone.on("session/deleted", function(ev)
    if W.root and W.win_of(ev.session_id) then W.close(W.win_of(ev.session_id)) end
  end)

  bone.on("panel/closed", function(ev)
    local id = W.root and W.panel_win(ev.id)
    if id then W.close(id) end
  end)

  -- Optionally watch each sub-agent in a window under its owner's.
  bone.on("session/created", function(ev)
    local o = ev.owner
    if W.root and o and bone.settings.get("windows.subagents") then
      split("rows", ev.session_id, W.win_of(o.session_id) or W.chatwin)
    end
  end)

  -- Broadcast: a message sent in the focused window also goes to every other.
  bone.on("submit", function(ev)
    if not broadcast or not W.root then return end
    for id, w in pairs(wins) do
      if id ~= W.chatwin and w.sid then
        bone.request("queue/add", { session_id = w.sid, text = ev.text, mode = "next" }, function() end)
      end
    end
  end)

  bone.on("ready", start)
  bone.defer(0, start) -- loaded after startup (/plugins load windows)

  bone.plugin.on_shutdown(function()
    W.save()
    if fe.shutdown then fe.shutdown() end
    W.root = nil -- Closing content must not recreate panes during teardown.
    for id in pairs(wins) do forget(id) end
  end)

  -- ---- keys and the command ------------------------------------------------

  -- Change what the focused window shows.
  function W.pick()
    bone.request("session/list", {}, function(list, err)
      if err then return bone.notify(tostring(err), "error") end
      local items = { { new = true } }
      for _, s in ipairs(list or {}) do
        if not s.owner then items[#items + 1] = s end
      end
      bone.ui.select(items, {
        prompt = "Show in this window",
        format = function(s)
          if s.new then return "+ new chat" end
          return (s.title or "[untitled]") .. (W.win_of(s.session_id) and "  · open" or "")
        end,
        on_choice = function(s)
          if s and s.new then bone.action("new_session") elseif s then bone.api.open_session(s.session_id) end
        end,
      })
    end)
  end

  local function step(dir)
    return function() focus(W.neighbor(dir)) end
  end

  local function move(dir)
    return function() W.exchange(W.here(), W.neighbor(dir)) end
  end

  local function cycle()
    local ids = {}
    each_win(W.root, function(id) ids[#ids + 1] = id end)
    for i, id in ipairs(ids) do
      if id == W.here() then return focus(ids[i % #ids + 1]) end
    end
  end

  local keys = {
    v = function() split("cols") end,
    s = function() split("rows") end,
    p = W.pick,
    q = function() W.close() end,
    o = W.only,
    w = cycle,
    h = step("h"), j = step("j"), k = step("k"), l = step("l"),
    left = step("h"), down = step("j"), up = step("k"), right = step("l"),
    H = move("h"), J = move("j"), K = move("k"), L = move("l"),
    [">"] = function() W.grow("cols", fe.step) end,
    ["<"] = function() W.grow("cols", -fe.step) end,
    ["+"] = function() W.grow("rows", fe.rows_step) end,
    ["-"] = function() W.grow("rows", -fe.rows_step) end,
    ["="] = function() equalize() end,
    z = W.zoom,
    r = W.rotate,
    [";"] = function() focus(W.last) end,
    b = function()
      broadcast = not broadcast
      bone.notify(broadcast and "windows: sending to every window" or "windows: sending to the focused window")
    end,
  }
  W.keys = keys
  local DESC = {
    t = "open a terminal in a new window", v = "split right", s = "split below", p = "pick what this window shows", q = "close the window",
    o = "close every other window", w = "focus the next window", [";"] = "focus the previous window",
    h = "focus left", j = "focus down", k = "focus up", l = "focus right",
    left = "focus left", down = "focus down", up = "focus up", right = "focus right",
    H = "swap with the window left", J = "swap with the window below",
    K = "swap with the window above", L = "swap with the window right",
    ["<"] = "narrower (repeat without the prefix)", [">"] = "wider (repeat without the prefix)",
    ["-"] = "shorter (repeat without the prefix)", ["+"] = "taller (repeat without the prefix)",
    ["="] = "make every window the same size", z = "zoom the window, and back",
    r = "rotate the windows", b = "send messages to every window, or not",
  }

  local SUB = {
    vsplit = keys.v, split = keys.s, pick = W.pick, close = keys.q, only = W.only,
    next = cycle, equal = keys["="], zoom = W.zoom, rotate = W.rotate, broadcast = keys.b,
  }
  W.sub = SUB

  -- Map the keys (after a frontend added its own to W.keys and W.sub). Also
  -- while a panel has the keyboard.
  function W.bind()
    local function map(key)
      local f = function() if W.root then keys[key]() end end
      bone.keymap.set(PREFIX .. " " .. key, f, { desc = DESC[key] })
      bone.keymap.set(PREFIX .. " " .. key, f, { context = "panel" })
    end
    -- After a resize, < > + - keep resizing for a second without the prefix.
    bone.keymap.context("wm_resize", { fallback = { "main" } })
    for _, key in ipairs({ "<", ">", "+", "-" }) do
      local f = keys[key]
      keys[key] = function()
        f()
        local at = bone.now()
        resizing = at
        bone.keymap.focus("wm_resize")
        bone.defer(1000, function() if resizing == at then bone.keymap.clear() end end)
      end
      bone.keymap.set(key, keys[key], { context = "wm_resize" })
    end
    for key in pairs(keys) do map(key) end

    local names, letters = {}, {}
    for name in pairs(SUB) do names[#names + 1] = name end
    table.sort(names)
    for _, k in ipairs({ "t", "v", "s", "p", "q", "o", "w", ";", "h j k l", "H J K L", "< > + -", "=", "z", "r", "b" }) do
      if keys[k] or k:find(" ") then letters[#letters + 1] = k end
    end
    bone.cmd.create("win", function(c)
      local f = SUB[(c.args or ""):match("^%s*(%S*)")]
      if not f then
        return bone.notify("/win " .. table.concat(names, "|") .. "  (keys: " .. PREFIX .. " then "
          .. table.concat(letters, " ") .. ")")
      end
      if W.root then f() end
    end, { desc = "Tiled chat windows: split, close, focus, zoom" })
  end

  return W
end

return M
