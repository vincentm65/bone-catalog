local alive, serial, picker, pending = true, 0, nil, nil
local function notify(err) bone.notify("fork: " .. tostring(err), "error") end
local function current() return (bone.api.session() or {}).session_id end
local function close()
  if picker then picker:close(); picker = nil end
end
bone.plugin.on_shutdown(function() alive = false; pending = nil; close() end)

-- open_session loads asynchronously. Prefill only once the intended chat is
-- shown, never the old source chat or an unrelated chat the user switched to.
local function prefill()
  if not alive or not pending or current() ~= pending.id then return end
  local p = pending
  pending = nil
  if not bone.prompt.empty() then
    return notify("draft changed while loading; kept your edits instead of restoring the selected message")
  end
  local ok, err = pcall(function()
    if bone.prompt and bone.prompt.set_images then bone.prompt.set_images(p.draft.images or {}) end
    bone.api.prompt_set(p.draft.text or "")
  end)
  if not ok then notify("draft restoration failed; original text/images remain in the source session: " .. tostring(err)) end
end
bone.on("chat/shown", prefill)
local function create(id, n, tree, valid)
  local draft = n and tree.points[n]
  if draft and #(draft.images or {}) > 0 and not (bone.prompt and bone.prompt.set_images) then
    return notify("this TUI cannot restore image attachments; fork was not created")
  end
  bone.rpc.call("fork.create", { session_id = id, before_turn = n, expected = tree.expected }, function(r, err)
    if not valid() then return end
    if err or not r then return notify(err or "no result") end
    if r.warning then notify(r.warning) end
    pending = r.draft and { id = r.info.session_id, draft = r.draft } or nil
    bone.api.open_session(r.info.session_id)
    prefill()
    bone.notify(n and ("New branch before #" .. n .. ": edit the message and send it")
      or "New branch: a copy of this chat")
  end)
end

local function ago(t)
  local s = math.max(0, os.time() - (tonumber(t) or os.time()))
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  if s < 86400 then return math.floor(s / 3600) .. "h ago" end
  return math.floor(s / 86400) .. "d ago"
end
local function bare(title) return title and (title:gsub("^↳ ", "")) end
-- A user message on one line, with its pictures counted.
local function said(text, images)
  text = (text or ""):gsub("%s+", " "):gsub("^ ", "")
  if text == "" then text = images == 1 and "[image]" or "[images]" end
  if images > 0 then text = text .. " · " .. images .. (images == 1 and " image" or " images") end
  return text
end

-- The picker's rows for chat `origin`, newest first, so the first row forks
-- before the latest message: each message, the branches that redid it
-- under it, and last, the chat this one branched from.
local function rows(origin, tree, infos)
  local edges, out = tree.edges or {}, {}
  local mine = infos[origin] or {}
  local at, loose = {}, {}
  for id, e in pairs(edges) do
    if e.parent == origin and (infos[id] or {}).cwd then
      local list = loose
      if e.before_turn then at[e.before_turn] = at[e.before_turn] or {}; list = at[e.before_turn] end
      list[#list + 1] = id
    end
  end
  local function by_age(a, b) return (infos[a].created_at or 0) < (infos[b].created_at or 0) end
  local function branch(id, indent)
    local info, sent = infos[id], (tree.branches or {})[id]
    -- A renamed branch by its name; else by what it sent in place of the
    -- message it was cut at; else (nothing sent yet) just a branch.
    local name = bare(info.title) ~= bare(mine.title) and bare(info.title)
      or sent and said(sent.text, sent.images or 0) or "Branch"
    out[#out + 1] = { text = indent .. "↳ " .. name .. " · " .. ago(info.created_at), open = id }
  end
  local points = tree.points or {}
  for i = #points, 1, -1 do
    local p = points[i]
    local text = said(p.text, #(p.images or {}))
    if not p.safe then text = text .. " · can't fork here" end
    out[#out + 1] = { text = "#" .. p.before_turn .. "  " .. text, point = p }
    table.sort(at[i] or {}, by_age)
    for _, id in ipairs(at[i] or {}) do branch(id, "     ") end
  end
  table.sort(loose, by_age)
  for _, id in ipairs(loose) do branch(id, "") end
  local e = edges[origin]
  if e then
    local parent = infos[e.parent] or {}
    out[#out + 1] = { text = "↰ Branched from: " .. (parent.cwd and (bare(parent.title) or "a chat") or "a chat that is gone")
      .. (e.before_turn and (" · at #" .. e.before_turn) or ""), open = e.parent, missing = not parent.cwd }
  end
  return out
end

local function browse(origin, token)
  local function valid() return alive and serial == token and current() == origin end
  local tree
  local opts = { prompt = "Fork from a message", loading = true, width = 96, height = 6,
    format = function(row) return row.text end,
    footer = "↑↓ move · enter fork or open · esc close" }
  opts.on_choice = function(row)
    picker = nil
    if not row or not valid() then return end
    if row.open then
      if row.missing then return notify("the chat this one branched from is gone") end
      return bone.api.open_session(row.open)
    end
    if not row.point.safe then return notify("a tool call is still open before #" .. row.point.before_turn .. "; fork at another message") end
    create(origin, row.point.before_turn, tree, valid)
  end
  close()
  picker = bone.ui.select({}, opts)
  local handle = picker
  local function fail(err)
    if handle ~= picker then return end
    close()
    notify(err or "no result")
  end
  bone.request("session/list", {}, function(list, err)
    if not valid() or handle ~= picker then return end
    if err then return fail(err) end
    bone.rpc.call("fork.tree", { session_id = origin, sessions = list }, function(r, err2)
      if not valid() or handle ~= picker then return end
      if err2 or not r then return fail(err2) end
      tree = r
      local infos = {}
      for _, info in ipairs(list or {}) do infos[info.session_id] = info end
      for _, info in ipairs(r.sessions or {}) do infos[info.session_id] = infos[info.session_id] or info end
      infos[origin] = r.snapshot.info
      local items = rows(origin, r, infos)
      opts.empty = "No messages to fork from yet"
      opts.height = #items + 5
      picker:set_items(items)
    end)
  end)
end

bone.cmd.create("fork", function(c)
  local origin = current()
  if not origin then return notify("no current session") end
  local arg = (c.args or ""):match("^%s*(.-)%s*$")
  if arg ~= "" and arg ~= "copy" and not arg:match("^[1-9]%d*$") then return notify("usage: /fork [N|copy]") end
  serial = serial + 1
  local token = serial
  close(); pending = nil
  if arg == "" then return browse(origin, token) end
  local function valid() return alive and serial == token and current() == origin end
  bone.rpc.call("fork.tree", { session_id = origin }, function(tree, err)
    if not valid() then return end
    if err or not tree then return notify(err or "no result") end
    create(origin, arg ~= "copy" and tonumber(arg) or nil, tree, valid)
  end)
end, { desc = "Fork from an earlier message, or copy the whole chat: /fork [N|copy]" })
