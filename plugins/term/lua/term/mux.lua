-- A terminal multiplexer in one panel: tabs, each a tree of split panes, each
-- pane a shell (or a command) in a pseudo-terminal. The same model draws as a
-- terminal's lines (render) and as the desktop's nodes (node).
--
-- Keys, while the panel has the keyboard (no prefix):
--   alt+t new tab · alt+1..9 a tab · alt+[ alt+] the tab before, after
--   alt+\ split right · alt+/ split below (alt+- too, in a terminal) · alt+arrows move between panes
--   alt+shift+arrows move the divider · alt+z zoom the pane · alt+x close it (alt+w is the windows plugin's)
-- The terminal module's escape keys (ctrl+]) give the keyboard back to the
-- prompt, and its passthrough keys (a window manager's prefix) go to the
-- keymaps. Every color is a highlight group linked to the scheme's.

local M = {}
local vt = require("term.vt")

local ID = "terminal"
local GUI = bone.has_capability and bone.has_capability("gui.window_nodes") or false
local base -- the frontend's terminal module: encode, escape, passthrough

local tabs = {} -- { name?, root, focus = pane, zoom = pane? }
local at = 0    -- the tab shown
local panes = {} -- every pane, by id
local next_id = 0
local active = false

-- ---- groups ----------------------------------------------------------------

local function groups()
  local set = bone.hl.set
  set("TermCursor", { link = "Normal", reverse = true, default = true })
  set("TermBorder", { link = "Dim", default = true })
  set("TermBorderActive", { link = "Accent", default = true })
  set("TermTab", { link = "Dim", default = true })
  set("TermTabActive", { link = "Selection", default = true })
  set("TermBar", { link = "Normal", default = true })
end

local function redraw()
  if GUI then pcall(bone.gui.invalidate, 0) else pcall(bone.ui.refresh) end
end

-- ---- the tree --------------------------------------------------------------

local function leaf(p) return { pane = p } end

--- The leaves of `node`, in order.
local function leaves(node, out)
  out = out or {}
  if node.pane then out[#out + 1] = node.pane
  else leaves(node.a, out) leaves(node.b, out) end
  return out
end

--- The node holding pane `p` and its parent (nil at the root).
local function find(node, p, parent)
  if node.pane == p then return node, parent end
  if node.pane then return nil end
  local n, par = find(node.a, p, node)
  if n then return n, par end
  return find(node.b, p, node)
end

local function tab() return tabs[at] end

-- ---- panes -----------------------------------------------------------------

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- What runs in the pane in front: the foreground program (nvim, htop), or
--- the folder's name while it is the shell itself. Read once a second.
local function pane_name(p)
  local now = os.time()
  if p.named_at ~= now then
    p.named_at = now
    local ok, st = pcall(p.job.status, p.job)
    local pid = ok and st and st.pid
    local stat = pid and read("/proc/" .. pid .. "/stat")
    -- Field 8 (after the command in parentheses) is the terminal's foreground group.
    local fg = stat and tonumber(stat:match("%) %S+ %S+ %S+ %S+ %S+ (%S+)"))
    if fg and fg > 0 and fg ~= pid then
      local comm = read("/proc/" .. fg .. "/comm")
      p.fg_name = comm and comm:gsub("%s+$", "") or p.fg_name
    elseif pid and not p.command then
      local h = io.popen("readlink /proc/" .. pid .. "/cwd 2>/dev/null")
      local dir = h and h:read("*l")
      if h then h:close() end
      local home = os.getenv("HOME")
      p.fg_name = (dir and dir == home) and "~" or (dir and dir:match("([^/]+)/*$")) or p.fg_name
    end
  end
  local name = p.fg_name or p.label or "shell"
  if bone.text.width(name) > 24 then name = name:sub(1, 23) .. "…" end
  return name
end

--- The folder the pane's shell is in now (a new pane starts there).
local function pane_cwd(p)
  local ok, st = pcall(p.job.status, p.job)
  local pid = ok and st and st.pid
  if not pid then return p.cwd end
  local h = io.popen("readlink /proc/" .. pid .. "/cwd 2>/dev/null")
  local dir = h and h:read("*l")
  if h then h:close() end
  return (dir and dir ~= "") and dir or p.cwd
end

local close_pane

-- The shell a pane runs: $SHELL, else /bin/sh. On Windows $SHELL counts
-- only when it names a file there (Git Bash sets a Unix one); else
-- PowerShell 7 (pwsh) on the PATH, Windows PowerShell, then %ComSpec%.
local function default_shell()
  local function file(path)
    local f = path and path ~= "" and io.open(path, "rb")
    if f then f:close() return true end
    return false
  end
  local env = os.getenv("SHELL")
  if package.config:sub(1, 1) ~= "\\" then return { (env and env ~= "") and env or "/bin/sh" } end
  if file(env) then return { env } end
  for dir in (os.getenv("PATH") or ""):gmatch("[^;]+") do
    if file(dir .. "\\pwsh.exe") then return { dir .. "\\pwsh.exe", "-NoLogo" } end
  end
  local ps = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
  if file(ps) then return { ps, "-NoLogo" } end
  return { os.getenv("ComSpec") or "cmd.exe" }
end

local function new_pane(opts)
  opts = opts or {}
  next_id = next_id + 1
  local p = { id = next_id, scroll = 0, cwd = opts.cwd, label = opts.label, command = opts.cmd ~= nil }
  local session = bone.chat.session()
  p.cwd = p.cwd or (session and session.cwd)
  p.job = bone.job.start(opts.cmd or default_shell(), {
    name = "term:" .. p.id,
    pty = { width = 80, height = 24 },
    cwd = p.cwd,
    on_exit = function(r)
      if not active or panes[p.id] ~= p then return end
      if p.command then
        -- A command's last screen stays, marked, until the pane is closed.
        p.exited = r.code or r.signal or 0
        p.screen = p.job:screen() or p.screen
        if r.error or (r.code and r.code ~= 0) then
          bone.notify(r.error or ((r.cmd or "command") .. " exited with " .. tostring(r.code or ("signal " .. tostring(r.signal)))), "error")
        end
        redraw()
      else
        close_pane(p)
      end
    end,
  })
  panes[p.id] = p
  return p
end

local function release(p)
  if panes[p.id] ~= p then return end
  panes[p.id] = nil -- before cancel, which can call on_exit
  pcall(p.job.cancel, p.job)
end

-- ---- the panel ------------------------------------------------------------

local panel_spec

--- Ask the windows plugin to make the panel a window: in the desktop app
--- through the library window's attach_panel, in a terminal through the
--- terminal module's. Without it the panel stays docked.
local function as_window()
  if GUI then
    local ok, win = pcall(require, "bone.nodes.window")
    if ok and type(win) == "table" and type(win.attach_panel) == "function" then pcall(win.attach_panel, ID) end
  elseif type(base.attach_panel) == "function" then
    pcall(base.attach_panel, ID)
  end
end

local function ensure_panel(focus)
  local panel = bone.ui.panel.get(ID)
  if panel then
    pcall(panel.show, panel)
    if focus then pcall(bone.ui.panel.focus, ID) end
    return panel
  end
  panel = bone.ui.panel.open(panel_spec(focus))
  as_window()
  if focus then pcall(bone.ui.panel.focus, ID) end
  return panel
end

--- Whether the multiplexer is loaded (other plugins open it then).
function M.is_active() return active end

local function close_panel()
  if bone.ui.panel.get(ID) then pcall(bone.ui.panel.close, ID) end
end

function M.new_tab(opts)
  local p = new_pane(opts)
  table.insert(tabs, at + 1, { root = leaf(p), focus = p })
  at = at + 1
  ensure_panel(true)
  redraw()
  return p
end

local function split(dir)
  local t = tab()
  if not t then return end
  local node = find(t.root, t.focus)
  if not node then return end
  local p = new_pane({ cwd = pane_cwd(t.focus) })
  -- The leaf becomes a split: the old pane first, the new one beside or below.
  node.dir, node.ratio = dir, 0.5
  node.a, node.b, node.pane = leaf(t.focus), leaf(p), nil
  t.focus, t.zoom = p, nil
  redraw()
end

close_pane = function(p)
  release(p)
  for i, t in ipairs(tabs) do
    local node, parent = find(t.root, p)
    if node then
      if not parent then
        table.remove(tabs, i)
        if at > #tabs then at = #tabs elseif at > i then at = at - 1 end
        if #tabs == 0 then
          at = 0
          close_panel()
          return
        end
      else
        local other = parent.a == node and parent.b or parent.a
        for k in pairs(parent) do parent[k] = nil end
        for k, v in pairs(other) do parent[k] = v end
        if t.focus == p then t.focus = leaves(parent)[1] end
        if t.zoom == p then t.zoom = nil end
      end
      break
    end
  end
  redraw()
end

-- ---- where everything goes -----------------------------------------------

--- Each pane's cell rectangle and each divider, for tab `t` in w × h cells.
local function layout(t, w, h)
  local out = { panes = {}, seps = {} }
  local function place(node, x, y, w_, h_)
    if node.pane then
      out.panes[#out.panes + 1] = { pane = node.pane, x = x, y = y, w = w_, h = h_ }
      return
    end
    if node.dir == "row" then
      if w_ < 3 then return place(node.a, x, y, w_, h_) end
      local aw = math.max(1, math.min(w_ - 2, math.floor((w_ - 1) * node.ratio + 0.5)))
      place(node.a, x, y, aw, h_)
      out.seps[#out.seps + 1] = { dir = "row", x = x + aw, y = y, len = h_, node = node, span = w_, from = x }
      place(node.b, x + aw + 1, y, w_ - aw - 1, h_)
    else
      if h_ < 3 then return place(node.a, x, y, w_, h_) end
      local ah = math.max(1, math.min(h_ - 2, math.floor((h_ - 1) * node.ratio + 0.5)))
      place(node.a, x, y, w_, ah)
      out.seps[#out.seps + 1] = { dir = "col", x = x, y = y + ah, len = w_, node = node, span = h_, from = y }
      place(node.b, x, y + ah + 1, w_, h_ - ah - 1)
    end
  end
  if t.zoom then
    out.panes[1] = { pane = t.zoom, x = 0, y = 0, w = w, h = h }
  else
    place(t.root, 0, 0, w, h)
  end
  return out
end

--- The pane next to the focused one in a direction (by the rectangles drawn last).
local function neighbour(dx, dy)
  local t = tab()
  local L = t and t.last_layout
  if not L then return nil end
  local cur
  for _, r in ipairs(L.panes) do if r.pane == t.focus then cur = r end end
  if not cur then return nil end
  local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
  local best, best_d
  for _, r in ipairs(L.panes) do
    if r.pane ~= t.focus then
      local ok
      if dx > 0 then ok = r.x >= cur.x + cur.w and r.y < cur.y + cur.h and r.y + r.h > cur.y
      elseif dx < 0 then ok = r.x + r.w <= cur.x and r.y < cur.y + cur.h and r.y + r.h > cur.y
      elseif dy > 0 then ok = r.y >= cur.y + cur.h and r.x < cur.x + cur.w and r.x + r.w > cur.x
      else ok = r.y + r.h <= cur.y and r.x < cur.x + cur.w and r.x + r.w > cur.x end
      if ok then
        local d = math.abs(r.x + r.w / 2 - cx) + math.abs(r.y + r.h / 2 - cy)
        if not best_d or d < best_d then best, best_d = r.pane, d end
      end
    end
  end
  return best
end

--- The split holding `target` (nil at the root).
local function parent_of(root, target, par)
  if root == target then return par end
  if root.pane then return nil end
  return parent_of(root.a, target, root) or parent_of(root.b, target, root)
end

--- Move the nearest divider of that kind around the focused pane: right and
--- down move it right and down.
local function resize(dir, by)
  local t = tab()
  if not t or t.zoom then return end
  local parent = parent_of(t.root, (find(t.root, t.focus)))
  while parent do
    if parent.dir == dir then
      parent.ratio = math.max(0.1, math.min(0.9, parent.ratio + by))
      return
    end
    parent = parent_of(t.root, parent)
  end
end

-- ---- keys ----------------------------------------------------------------

local CSI = "\27["

local function write(p, bytes)
  if not p or p.exited then return end
  p.scroll, p.sel = 0, nil
  p.job:write(bytes)
end

local ACTIONS = {
  ["alt+t"] = function() M.new_tab({ cwd = tab() and pane_cwd(tab().focus) }) end,
  ["alt+\\"] = function() split("row") end,
  ["alt+|"] = function() split("row") end,
  ["alt+/"] = function() split("col") end,
  ["alt+-"] = function() split("col") end, -- the terminal's too (the desktop app keeps alt+- to itself)
  ["alt+_"] = function() split("col") end,
  ["alt+z"] = function()
    local t = tab()
    if t and #leaves(t.root) > 1 then t.zoom = (not t.zoom) and t.focus or nil end
  end,
  ["alt+x"] = function() if tab() then close_pane(tab().focus) end end,
  ["alt+["] = function() if #tabs > 1 then at = (at - 2) % #tabs + 1 end end,
  ["alt+]"] = function() if #tabs > 1 then at = at % #tabs + 1 end end,
  ["alt+left"] = function() local n = neighbour(-1, 0) if n then tab().focus, tab().zoom = n, nil end end,
  ["alt+right"] = function() local n = neighbour(1, 0) if n then tab().focus, tab().zoom = n, nil end end,
  ["alt+up"] = function() local n = neighbour(0, -1) if n then tab().focus, tab().zoom = n, nil end end,
  ["alt+down"] = function() local n = neighbour(0, 1) if n then tab().focus, tab().zoom = n, nil end end,
  ["alt+shift+left"] = function() resize("row", -0.05) end,
  ["alt+shift+right"] = function() resize("row", 0.05) end,
  ["alt+shift+up"] = function() resize("col", -0.05) end,
  ["alt+shift+down"] = function() resize("col", 0.05) end,
}
for n = 1, 9 do
  ACTIONS["alt+" .. n] = function() if tabs[n] then at = n end end
end

function M.key(key)
  if not active then return false end
  if base.passthrough and base.passthrough[key] then return false end
  if base.escape and base.escape[key] then
    bone.ui.panel.focus(nil)
    return true
  end
  local act = ACTIONS[key]
  if act then
    act()
    redraw()
    return true
  end
  local t = tab()
  local p = t and t.focus
  if not p then return true end
  if key == "ctrl+c" and p.sel then
    -- With a selection, ctrl+c copies it (and ends it) instead of
    -- interrupting the program. Key names fold shift into letters, so
    -- ctrl+shift+c arrives as this too.
    local text = vt.sel_text(p)
    if text and bone.clipboard then bone.clipboard.copy(text) end
    p.sel = nil
  elseif vt.scroll(p, key) then -- scrolled back
  elseif p.exited and key == "enter" then close_pane(p)
  else
    local bytes = base.encode(key, p.screen and p.screen.app_cursor)
    if bytes then write(p, bytes) end
  end
  redraw()
  return true
end

function M.paste(text)
  local t = tab()
  local p = t and t.focus
  if not p then return end
  write(p, vt.paste(p.screen, text))
  redraw()
end

-- ---- drawing: the screens ------------------------------------------------

local function screen_of(p, w, h)
  if p.exited then return p.screen end
  local s = p.job:screen({ width = math.max(1, w), height = math.max(1, h), scroll = p.scroll }) or p.screen
  if s then p.screen, p.scroll = s, s.scroll or p.scroll end
  return s
end

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

--- A line's spans cut or padded to exactly `w` cells.
local function fit(line, w)
  local out, used = {}, 0
  for _, item in ipairs(line or {}) do
    if used >= w then break end
    local text = item[1] or ""
    local tw = bone.text.width(text)
    if used + tw <= w then
      out[#out + 1] = item
      used = used + tw
    else
      local cut = ""
      for ch in text:gmatch(CHAR) do
        local cw = bone.text.width(ch)
        if used + cw > w then break end
        cut, used = cut .. ch, used + cw
      end
      if cut ~= "" then out[#out + 1] = { cut, item[2] } end
      break
    end
  end
  if used < w then out[#out + 1] = { string.rep(" ", w - used) } end
  return out
end

--- Pane `r`'s lines at its size, with the cursor when it has the keyboard.
local function pane_lines(r, focused)
  local s = screen_of(r.pane, r.w, r.h)
  local lines = {}
  for i = 1, r.h do lines[i] = (s and s.lines[i]) or {} end
  if focused and s and s.cursor and not r.pane.exited then
    local row, col = s.cursor[1], s.cursor[2]
    if row >= 1 and row <= r.h then lines[row] = vt.with_cursor(lines[row], col) end
  end
  if r.pane.exited then
    lines[r.h] = { { " exited " .. tostring(r.pane.exited) .. " · enter closes ", "TermTabActive" } }
  end
  return lines
end

--- Whether a divider cell touches the focused pane's edge.
local function lit(sep, i, f)
  if not f then return false end
  if sep.dir == "row" then
    local y = sep.y + i
    return y >= f.y and y < f.y + f.h and (sep.x == f.x - 1 or sep.x == f.x + f.w)
  end
  local x = sep.x + i
  return x >= f.x and x < f.x + f.w and (sep.y == f.y - 1 or sep.y == f.y + f.h)
end

local function tab_title(i, t)
  local name = t.name or pane_name(t.focus)
  local n = #leaves(t.root)
  return tostring(i) .. " " .. name .. (n > 1 and (" ·" .. n) or "") .. (t.zoom and (GUI and " · zoomed" or " ⤢") or "")
end

-- ---- the terminal's drawing ----------------------------------------------

local tui_map -- what the last frame drew where: tabs and panes

function M.render(ctx)
  if not active then return {} end
  local W, H = math.max(1, ctx.width or 80), math.max(2, ctx.height or 24)
  local lines = {}
  -- The tab bar: the tabs, a +, and the keys at the right when there is room.
  local bar, x = {}, 0
  tui_map = { tabs = {}, panes = {}, seps = {}, plus = nil }
  for i, t in ipairs(tabs) do
    local label = " " .. tab_title(i, t) .. " "
    local w = bone.text.width(label)
    bar[#bar + 1] = { label, i == at and "TermTabActive" or "TermTab" }
    tui_map.tabs[#tui_map.tabs + 1] = { from = x, to = x + w - 1, tab = i }
    x = x + w
    bar[#bar + 1] = { " " }
    x = x + 1
  end
  bar[#bar + 1] = { " + ", "TermTab" }
  tui_map.plus = { from = x, to = x + 2 }
  x = x + 3
  local hint = "alt+t tab · alt+\\ alt+/ split · alt+arrows move · alt+z zoom · alt+x close · ctrl+] prompt "
  if W - x > bone.text.width(hint) + 2 then
    bar[#bar + 1] = { string.rep(" ", W - x - bone.text.width(hint)) }
    bar[#bar + 1] = { hint, "TermBorder" }
  end
  lines[1] = fit(bar, W)
  local t = tab()
  if not t then return lines end
  local L = layout(t, W, H - 1)
  t.last_layout = L
  local focus_rect
  for _, r in ipairs(L.panes) do if r.pane == t.focus then focus_rect = r end end
  -- Each row is made of the segments that cross it, left to right.
  local rows = {}
  for y = 1, H - 1 do rows[y] = {} end
  local function put(y, x0, items) local row = rows[y + 1] if row then row[#row + 1] = { x0, items } end end
  for _, r in ipairs(L.panes) do
    local pl = pane_lines(r, ctx.focused and r.pane == t.focus)
    for i = 1, r.h do put(r.y + i - 1, r.x, fit(pl[i], r.w)) end
    tui_map.panes[#tui_map.panes + 1] = r
  end
  local many = #L.panes > 1
  for _, sep in ipairs(L.seps) do
    tui_map.seps[#tui_map.seps + 1] = sep
    if sep.dir == "row" then
      for i = 0, sep.len - 1 do
        put(sep.y + i, sep.x, { { "│", (many and lit(sep, i, focus_rect)) and "TermBorderActive" or "TermBorder" } })
      end
    else
      local items, run, run_on = {}, "", nil
      for i = 0, sep.len - 1 do
        local on = many and lit(sep, i, focus_rect)
        if run ~= "" and on ~= run_on then
          items[#items + 1] = { run, run_on and "TermBorderActive" or "TermBorder" }
          run = ""
        end
        run, run_on = run .. "─", on
      end
      if run ~= "" then items[#items + 1] = { run, run_on and "TermBorderActive" or "TermBorder" } end
      put(sep.y, sep.x, items)
    end
  end
  for y = 1, H - 1 do
    table.sort(rows[y], function(a, b) return a[1] < b[1] end)
    local line, col = {}, 0
    for _, seg in ipairs(rows[y]) do
      if seg[1] > col then line[#line + 1] = { string.rep(" ", seg[1] - col) } end
      for _, item in ipairs(seg[2]) do line[#line + 1] = item end
      local w = 0
      for _, item in ipairs(seg[2]) do w = w + bone.text.width(item[1] or "") end
      col = math.max(col, seg[1] + w)
    end
    lines[y + 1] = line
  end
  -- Programs keep writing: draw again soon while any pane is shown.
  bone.ui.refresh_in(50)
  return lines
end

local drag_sep -- the divider a press took hold of

--- A mouse event over the panel, in the terminal. True when it was the panel's.
function M.mouse(ev)
  if not active or ev.panel ~= ID or not tui_map then return false end
  local info = bone.ui.panel.get(ID) and bone.ui.panel.get(ID):info() or {}
  local line = ev.panel_line
  local col = ev.panel_col or ((ev.x and info.col) and (ev.x - info.col + 1)) or ev.col
  if not line or not col or line < 1 then return false end
  local cx, cy = col - 1, line - 2 -- cells from the panes' top left
  if ev.action == "up" then drag_sep = nil end
  if drag_sep and ev.action == "drag" then
    local s = drag_sep
    local pos = s.dir == "row" and cx or cy
    s.node.ratio = math.max(0.1, math.min(0.9, (pos - s.from) / math.max(1, s.span - 1)))
    redraw()
    return true
  end
  if line == 1 then
    if ev.action ~= "down" then return true end
    for _, r in ipairs(tui_map.tabs) do
      if cx >= r.from and cx <= r.to then
        if ev.button == "middle" then close_pane(tabs[r.tab].focus) else at = r.tab end
        bone.ui.panel.focus(ID)
        redraw()
        return true
      end
    end
    if tui_map.plus and cx >= tui_map.plus.from and cx <= tui_map.plus.to then M.new_tab() end
    return true
  end
  local t = tab()
  if not t then return false end
  if ev.action == "down" then
    for _, s in ipairs(tui_map.seps) do
      local on = (s.dir == "row" and cx == s.x and cy >= s.y and cy < s.y + s.len)
        or (s.dir == "col" and cy == s.y and cx >= s.x and cx < s.x + s.len)
      if on then drag_sep = s return true end
    end
  end
  for _, r in ipairs(tui_map.panes) do
    if cx >= r.x and cx < r.x + r.w and cy >= r.y and cy < r.y + r.h then
      local p = r.pane
      if ev.action == "down" and t.focus ~= p then t.focus = p end
      local bytes = vt.mouse(p.screen, ev.action, ev.button, cx - r.x + 1, cy - r.y + 1)
      if bytes then
        bone.ui.panel.focus(ID)
        write(p, bytes)
      elseif ev.action == "wheel" then
        vt.scroll(p, "wheel" .. ev.button)
      elseif ev.action == "down" then
        bone.ui.panel.focus(ID)
      end
      redraw()
      return true
    end
  end
  return false
end

-- ---- the desktop's drawing -----------------------------------------------

local function color(group, key)
  local g = bone.hl.get(group) or {}
  return g[key or "fg"]
end

local BAR_H = 30

local gui_drag -- { sep, x0, y0, ratio0, px } while a divider is dragged

-- A pane on a grid of character cells: every run of text exactly as wide as
-- its cells, so a wide or fallback glyph cannot shift what follows, and
-- backgrounds fill their cells. Where the program does not take the mouse, a
-- drag selects (a double click a word, a triple click a line) and the release
-- copies it.
local function gui_pane(r, cell, focused, size)
  local p = r.pane
  local s = screen_of(p, r.w, r.h)
  local box = { id = "term:pane:" .. p.id, position = "absolute", left = r.x * cell.w, top = r.y * cell.h,
    width = r.w * cell.w, height = r.h * cell.h, direction = "column", overflow = "hidden" }
  local look = vt.look(cell, size, r.w)
  local sel = { vt.sel_range(p) }
  local cursor = focused and not p.exited and s and s.cursor
  for i = 1, r.h do
    local row = (s and s.lines[i]) or {}
    if p.exited and i == r.h then
      row = { { " exited " .. tostring(p.exited) .. " · enter closes ", "TermTabActive" } }
    end
    box[#box + 1] = vt.row_node(row, i - p.scroll, sel, cursor and cursor[1] == i and cursor[2] or nil, look)
  end
  local function clamp(c, rw)
    return math.max(1, math.min(r.w, c)), math.max(1, math.min(r.h, rw))
  end
  local function at_cell(pt)
    return clamp(math.floor((pt and pt.x or 0) / cell.w) + 1, math.floor((pt and pt.y or 0) / cell.h) + 1)
  end
  box.on_press = function(pt)
    local t = tab()
    if t then t.focus = p end
    pcall(bone.ui.panel.focus, ID)
    local c, rw = at_cell(pt)
    p.press_at, p.drag_at = { c, rw }, nil
    for _, q in pairs(panes) do q.sel = nil end
    local bytes = vt.mouse(p.screen, "down", "left", c, rw)
    p.reporting = bytes ~= nil
    if bytes then write(p, bytes) else vt.sel_start(p, rw - p.scroll, c) end
    redraw()
  end
  -- The pointer in the window while the button is held.
  box.on_drag = function(pt)
    local rect = pt and bone.gui.rect(box.id)
    if not rect then return end
    local c = math.floor((pt.x - rect.x) / cell.w) + 1
    local rw = math.floor((pt.y - rect.y) / cell.h) + 1
    if p.reporting then
      c, rw = clamp(c, rw)
      if p.drag_at and p.drag_at[1] == c and p.drag_at[2] == rw then return end
      p.drag_at = { c, rw }
      local bytes = vt.mouse(p.screen, "drag", "left", c, rw)
      if bytes then write(p, bytes) end
    elseif p.sel then
      -- Past the top scrolls back, past the bottom forward again.
      local max = p.screen and p.screen.max or 0
      if rw < 1 then p.scroll = math.min(max, p.scroll + 1)
      elseif rw > r.h and p.scroll > 0 then p.scroll = p.scroll - 1 end
      c, rw = clamp(c, rw)
      p.sel.b = { rw - p.scroll, c }
      redraw()
    end
  end
  box.on_release = function(pt)
    if p.reporting then
      local c, rw = at_cell(pt)
      if p.drag_at then c, rw = p.drag_at[1], p.drag_at[2]
      elseif not pt and p.press_at then c, rw = p.press_at[1], p.press_at[2] end
      local bytes = vt.mouse(p.screen, "up", "left", c, rw)
      if bytes then write(p, bytes) end
    else
      vt.sel_finish(p)
    end
    p.reporting, p.drag_at = false, nil
    redraw()
  end
  box.on_scroll = function(dy)
    local up = (dy or 0) > 0
    local c, rw = math.floor(r.w / 2), math.floor(r.h / 2)
    local bytes = vt.mouse(p.screen, "wheel", up and "up" or "down", c, rw)
    if bytes then write(p, bytes) else vt.scroll(p, up and "wheelup" or "wheeldown") end
    redraw()
    return true
  end
  box.cursor = "text"
  return box
end

local function gui_sep(sep, cell, on)
  local line = on and color("Accent") or color("Dim") or "#555555"
  local node
  if sep.dir == "row" then
    node = { position = "absolute", left = sep.x * cell.w, top = sep.y * cell.h, width = cell.w,
      height = sep.len * cell.h, direction = "row", justify = "center", align = "stretch", cursor = "col-resize",
      { width = 1, bg = line, opacity = on and 0.9 or 0.35 } }
  else
    node = { position = "absolute", left = sep.x * cell.w, top = sep.y * cell.h, width = sep.len * cell.w,
      height = cell.h, direction = "column", justify = "center", align = "stretch", cursor = "row-resize",
      { height = 1, bg = line, opacity = on and 0.9 or 0.35 } }
  end
  node.on_press = function() gui_drag = { sep = sep } end
  node.on_drag = function(pt)
    local d = gui_drag
    if not d or d.sep ~= sep or not pt then return end
    if not d.x0 then d.x0, d.y0, d.ratio0 = pt.x, pt.y, sep.node.ratio return end
    local moved = sep.dir == "row" and (pt.x - d.x0) / cell.w or (pt.y - d.y0) / cell.h
    sep.node.ratio = math.max(0.1, math.min(0.9, d.ratio0 + moved / math.max(1, sep.span - 1)))
    redraw()
  end
  node.on_release = function() gui_drag = nil end
  return node
end

local function gui_tab(i, t, on)
  local close = { width = 16, height = 16, radius = 4, direction = "row", align = "center", justify = "center",
    opacity = on and 0.8 or 0, hover = { opacity = 1, bg = color("Dim") and (color("Dim") .. "22") or nil },
    { text = "×", size = 13, color = color("Dim") } }
  close.on_click = function()
    local tt = tabs[i]
    if tt then for _, p in ipairs(leaves(tt.root)) do close_pane(p) end end
  end
  local node = { direction = "row", align = "center", gap = 6, height = 24, padding = { 0, 6, 0, 10 }, radius = 6,
    bg = on and color("Visual", "bg") or nil, shrink = 0, cursor = "pointer",
    hover = { bg = on and color("Visual", "bg") or ((color("Dim") or "#888888") .. "18") },
    { text = tab_title(i, t), size = 12, hl = on and "Normal" or nil, color = (not on) and color("Dim") or nil,
      bold = on, wrap = false },
    close }
  node.on_click = function() at = i pcall(bone.ui.panel.focus, ID) redraw() end
  node.on_middle = function() close.on_click() end
  return node
end

function M.node(ctx)
  if not active then return { grow = 1 } end
  groups()
  local cell = ctx.cell or (bone.gui.window_info() or {}).cell or { w = 8, h = 18 }
  local size = bone.o.font_size or 14
  local W, H = tonumber(ctx.width) or 800, tonumber(ctx.height) or 400
  local root = { direction = "column", grow = 1 }
  local bar = { direction = "row", align = "center", gap = 2, height = BAR_H, padding = { 0, 6 }, shrink = 0 }
  for i, t in ipairs(tabs) do bar[#bar + 1] = gui_tab(i, t, i == at) end
  local plus = { width = 24, height = 24, radius = 6, direction = "row", align = "center", justify = "center",
    cursor = "pointer", tooltip = "New tab (alt+t)", hover = { bg = (color("Dim") or "#888888") .. "18" },
    { text = "+", size = 15, color = color("Dim") } }
  plus.on_click = function() M.new_tab() end
  bar[#bar + 1] = plus
  bar[#bar + 1] = { grow = 1 }
  bar[#bar + 1] = { text = "alt+\\ alt+/ split · alt+arrows move · alt+z zoom · alt+x close", size = 11,
    color = color("Dim"), opacity = 0.7, wrap = false, shrink = 1, text_overflow = "ellipsis" }
  root[#root + 1] = bar
  root[#root + 1] = { height = 1, bg = color("Dim") or "#444444", opacity = 0.25, shrink = 0 }
  local t = tab()
  if not t then return root end
  local cols = math.max(1, math.floor((W - 8) / cell.w))
  local rows = math.max(1, math.floor((H - BAR_H - 1 - 4) / cell.h))
  local L = layout(t, cols, rows)
  t.last_layout = L
  local focus_rect
  for _, r in ipairs(L.panes) do if r.pane == t.focus then focus_rect = r end end
  local area = { width = cols * cell.w, height = rows * cell.h, margin = { 2, 4, 2, 4 } }
  for _, r in ipairs(L.panes) do area[#area + 1] = gui_pane(r, cell, ctx.focused and r.pane == t.focus, size) end
  local many = #L.panes > 1
  for _, sep in ipairs(L.seps) do
    local on = many and focus_rect and (lit(sep, 0, focus_rect) or lit(sep, math.floor(sep.len / 2), focus_rect)
      or lit(sep, sep.len - 1, focus_rect))
    area[#area + 1] = gui_sep(sep, cell, on)
  end
  root[#root + 1] = area
  return root
end

-- ---- the panel spec, and the life of it ----------------------------------

panel_spec = function(focus)
  local p = {}
  for k, v in pairs(base.defaults or { dock = "bottom", size = 0.4 }) do p[k] = v end
  p.id = ID
  p.title = false
  p.focusable = true
  p.focus = focus ~= false
  p.render = M.render
  if GUI then p.node = M.node end
  p.on_key = M.key
  p.on_close = function()
    -- Closing the panel stops every program in it.
    for _, pane in pairs(panes) do release(pane) end
    tabs, at = {}, 0
  end
  return p
end

--- Show the terminal panel with the keyboard (a first tab when there is none),
--- or give the keyboard back to the prompt when it already has it.
function M.toggle()
  if not active then return end
  if #tabs == 0 then return M.new_tab() end
  if bone.ui.panel.focused() == ID then
    bone.ui.panel.focus(nil)
    return
  end
  ensure_panel(true)
  redraw()
end

--- A new tab running `cmd` (a shell when nil).
function M.open(cmd)
  if not active then return end
  return M.new_tab({ cmd = cmd, label = cmd and (cmd:match("^%s*(%S+)") or cmd) or nil })
end

function M.close_all()
  for _, p in pairs(panes) do release(p) end
  tabs, at = {}, 0
  close_panel()
end

local handlers = {}
local generation -- the token of the load that set it up

--- Set it up over `terminal_module`. Returns a token: shutdown(token) from an
--- older load (a late callback after a reload) then leaves this one alone.
function M.setup(terminal_module)
  if active then return generation end
  base = terminal_module
  active = true
  generation = {}
  groups()
  handlers[#handlers + 1] = bone.on("paste", function(ev)
    if active and ev.context == "panel" and bone.ui.panel.focused() == ID and type(ev.text) == "string" then
      M.paste(ev.text)
      return true
    end
  end)
  if not GUI then
    handlers[#handlers + 1] = bone.on("mouse", function(ev) return M.mouse(ev) end)
  end
  return generation
end

function M.shutdown(token)
  if not active or (token and token ~= generation) then return end
  for _, h in ipairs(handlers) do pcall(bone.off, h) end
  handlers = {}
  M.close_all()
  active = false
end

return M
