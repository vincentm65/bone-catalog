-- ask_user, shared half: the queue, the open question, and the answer sent
-- back to the core. The terminal (tui.lua) and the desktop (gui.lua) only
-- draw and supply the typed text. Both frontends load this file first.
--
-- An answer is { value, label, index } for a pick, { values, labels } for
-- multi-select (custom = true when one is typed), or { value, custom = true }
-- for a typed choice. A text question is { value }. "cancelled" stops asking.
-- Questions wait their turn. One belongs to its session's chat: it shows
-- only while that chat is on screen, and is put away (the choice kept)
-- while another chat is.

local M = {}
package.loaded["ask_user.ui"] = M

M.GUARD_MS = 250 -- enter, esc and 1-9 this soon after a question appears do nothing

local queue = {} -- ask/requested events, oldest first
local parked = {} -- ask_id -> { sel, checked, draft?, text? }
local resolved = {} -- ask_id -> true, so a late ask/list cannot bring one back
-- A question put away and then answered elsewhere still owes that chat its
-- prompt draft. Applied the next time the chat is on screen.
local pending_draft = {} -- session_id -> string
local view -- the frontend: show, hide, shutdown, text, refresh, snapshot

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

-- Options as { label, value, desc }, from strings or { label, value, description }.
function M.options(q)
  local out = {}
  local list = type(q) == "table" and type(q.options) == "table" and q.options or {}
  for _, o in ipairs(list) do
    if type(o) == "table" then
      local label = tostring(o.label or o.value or "")
      out[#out + 1] = {
        label = label,
        value = o.value and tostring(o.value) or label,
        desc = o.description,
      }
    else
      out[#out + 1] = { label = tostring(o), value = tostring(o) }
    end
  end
  return out
end

-- Whether a question's chat is the one on screen.
function M.on_screen(ev)
  local s = bone.chat.session()
  return ev.session_id == nil or (s and s.session_id) == ev.session_id
end

function M.text()
  if view and view.text then
    return view.text() or ""
  end
  return M.cur and M.cur.text or ""
end

function M.empty()
  return trim(M.text()) == ""
end

function M.active()
  return M.cur ~= nil and bone.now() - M.cur.opened >= M.GUARD_MS
end

function M.refresh()
  if view and view.refresh then
    view.refresh()
  end
end

-- True when this plugin is showing or holding the question (the desktop
-- overlay must not answer it too).
function M.handling(ask_id)
  local id = tostring(ask_id)
  if M.cur and tostring(M.cur.ev.ask_id) == id then
    return true
  end
  for _, ev in ipairs(queue) do
    if tostring(ev.ask_id) == id then
      return true
    end
  end
  for key in pairs(parked) do
    if tostring(key) == id then
      return true
    end
  end
  return false
end

local function remove(ask_id)
  for i = #queue, 1, -1 do
    if queue[i].ask_id == ask_id then
      table.remove(queue, i)
    end
  end
  parked[ask_id] = nil
end
M.remove = remove

local open_next

local function close()
  if not M.cur then
    return
  end
  local cur = M.cur
  remove(cur.ev.ask_id)
  M.cur = nil
  if view and view.hide then
    view.hide(cur, "close")
  end
  open_next(true)
end
M.close = close

-- Another chat came on screen: put the question away. The frontend decides
-- what happens to the draft it was holding.
function M.park()
  local cur = M.cur
  if not cur then
    return
  end
  local snap = {
    sel = cur.sel,
    checked = cur.checked,
    text = cur.text,
    session_id = cur.ev.session_id,
  }
  if view and view.snapshot then
    local extra = view.snapshot(cur)
    if type(extra) == "table" then
      for k, v in pairs(extra) do
        snap[k] = v
      end
    end
  end
  parked[cur.ev.ask_id] = snap
  M.cur = nil
  if view and view.hide then
    view.hide(cur, "park")
  end
end

function M.respond(answer)
  local cur = M.cur
  if not cur then
    return
  end
  bone.request("ask/respond", { ask_id = cur.ev.ask_id, answer = answer }, function(_, err)
    if err then
      bone.notify("ask_user: " .. (type(err) == "table" and err.message or tostring(err)), "error")
    end
  end)
  close()
end

-- Open the oldest question for the chat on screen, or one put away earlier.
-- `ready`: this question is replacing one the user just finished, so the
-- guard does not start again (their next key is a new one). A question put
-- away and brought back is ready too. A question that just arrived is not:
-- enter, esc and 1-9 wait, so the key that opened it does not answer it.
function M.open_next(ready)
  if M.cur or not view then
    return
  end
  local ev
  for _, e in ipairs(queue) do
    if M.on_screen(e) then
      ev = e
      break
    end
  end
  if not ev then
    return
  end
  local snap = parked[ev.ask_id]
  parked[ev.ask_id] = nil
  M.cur = {
    ev = ev,
    q = ev.question,
    opts = M.options(ev.question),
    sel = snap and snap.sel or 1,
    checked = snap and snap.checked or {},
    opened = (ready or snap) and (bone.now() - M.GUARD_MS) or bone.now(),
    text = snap and snap.text or "",
  }
  if view.show then
    view.show(M.cur, snap)
  end
end
open_next = M.open_next

function M.move(delta)
  local cur = M.cur
  if not cur or #cur.opts == 0 then
    return false
  end
  cur.sel = math.max(1, math.min(#cur.opts, cur.sel + delta))
  M.refresh()
  return true
end

function M.toggle(i)
  local cur = M.cur
  if not cur or not cur.opts[i] then
    return false
  end
  cur.checked[i] = not cur.checked[i] or nil
  cur.sel = i
  return true
end

-- Space toggles a multi-select choice only while the answer is empty, so a
-- space you are typing still goes into the answer.
function M.toggle_space()
  local cur = M.cur
  if not cur or cur.q.type ~= "multi_select" or #cur.opts == 0 or not M.empty() then
    return false
  end
  M.toggle(cur.sel)
  M.refresh()
  return true
end

function M.submit()
  local cur = M.cur
  if not cur then
    return
  end
  local q, opts = cur.q, cur.opts
  local text = trim(M.text())
  if #opts == 0 then
    if text ~= "" then
      M.respond({ value = text })
    end
    return
  end
  if q.type == "multi_select" then
    local values, labels = {}, {}
    for i, o in ipairs(opts) do
      if cur.checked[i] then
        values[#values + 1], labels[#labels + 1] = o.value, o.label
      end
    end
    -- Your own answer goes with the checked ones.
    if text ~= "" then
      values[#values + 1], labels[#labels + 1] = text, text
      return M.respond({ values = values, labels = labels, custom = true })
    end
    if #values == 0 then
      local o = opts[cur.sel]
      values, labels = { o.value }, { o.label }
    end
    return M.respond({ values = values, labels = labels })
  end
  if text ~= "" then
    return M.respond({ value = text, custom = true })
  end
  local o = opts[cur.sel]
  M.respond({ value = o.value, label = o.label, index = cur.sel })
end

-- A click on one option: choose it, or toggle it. The click is that option,
-- even when the text field already has an answer (enter still prefers text).
function M.activate(i)
  local cur = M.cur
  if not cur or not cur.opts[i] then
    return
  end
  cur.sel = i
  if cur.q.type == "multi_select" then
    M.toggle(i)
    M.refresh()
    return
  end
  local o = cur.opts[i]
  M.respond({ value = o.value, label = o.label, index = i })
end

function M.submit_key()
  if M.active() then
    M.submit()
  end
end

function M.cancel()
  if M.cur then
    M.respond("cancelled")
  end
end

function M.cancel_key()
  if M.active() then
    M.cancel()
  end
end

-- 1-9. False: the frontend should type the digit. True: the key was used
-- (or swallowed because the question has only just appeared).
function M.pick_key(n)
  local cur = M.cur
  if not cur or n > #cur.opts or not M.empty() then
    return false
  end
  if not M.active() then
    return true
  end
  if cur.q.type == "multi_select" then
    M.toggle(n)
    M.refresh()
  else
    cur.sel = n
    M.submit()
  end
  return true
end

function M.insert(s)
  local cur = M.cur
  if not cur or s == nil or s == "" then
    return
  end
  cur.text = (cur.text or "") .. s
  M.refresh()
end

function M.backspace()
  local cur = M.cur
  if not cur then
    return
  end
  local s = cur.text or ""
  local i = #s
  while i > 1 and s:byte(i) >= 128 and s:byte(i) < 192 do
    i = i - 1
  end
  cur.text = s:sub(1, math.max(0, i - 1))
  M.refresh()
end

function M.add(ev)
  local q = ev.question
  if type(q) ~= "table" or q.kind ~= "ask_user" or resolved[ev.ask_id] then
    return
  end
  if M.cur and M.cur.ev.ask_id == ev.ask_id then
    return
  end
  for _, e in ipairs(queue) do
    if e.ask_id == ev.ask_id then
      return
    end
  end
  queue[#queue + 1] = ev
  M.open_next()
end

function M.attach(frontend)
  view = frontend
  M.open_next()
end

function M.shutdown()
  if M.cur then
    local cur = M.cur
    M.cur = nil
    if view and view.hide then
      view.hide(cur, "shutdown")
    end
  end
  if view and view.shutdown then
    view.shutdown()
  end
  view = nil
end

bone.on("ask/requested", M.add)

bone.on("ask/resolved", function(ev)
  resolved[ev.ask_id] = true
  if M.cur and M.cur.ev.ask_id == ev.ask_id then
    return close()
  end
  local snap = parked[ev.ask_id]
  remove(ev.ask_id)
  local sid = ev.session_id or (snap and snap.session_id)
  if snap and snap.draft ~= nil and sid ~= nil then
    pending_draft[sid] = snap.draft
  end
end)

bone.on("chat/shown", function()
  if M.cur and not M.on_screen(M.cur.ev) then
    M.park()
  end
  local s = bone.chat.session()
  local sid = s and s.session_id
  if sid and pending_draft[sid] ~= nil then
    local draft = pending_draft[sid]
    pending_draft[sid] = nil
    if view and view.restore_draft then
      view.restore_draft(draft)
    end
  end
  M.open_next()
end)

-- A reload while a question is open: the frontend puts its own pieces back.
-- The fresh state asks again from ask/list.
bone.plugin.on_shutdown(M.shutdown)

-- Questions asked before we were listening (the UI started late, or this
-- plugin reloaded while one was open).
bone.request("ask/list", {}, function(asks)
  for _, ev in ipairs(type(asks) == "table" and asks or {}) do
    M.add(ev)
  end
end)
