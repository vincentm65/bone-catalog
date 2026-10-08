-- Plugin-owned named-agent editor. Blank optional fields inherit defaults;
-- tools '*' explicitly allows all, and 'none' / '[]' denies all. System prompts
-- use reversible \n / \t / \\ escapes; multiline paste preserves prompts.
local PATH = "subagent.agents"
local FIELDS = {
  { "name", "Name" }, { "description", "Description" },
  { "system", "System prompt" }, { "provider", "Provider" },
  { "model", "Model" }, { "tools", "Allowed tools" },
}
local active_close
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function errtext(err)
  return type(err) == "table" and tostring(err.message or err.code or "settings error") or tostring(err)
end
local function read_agents()
  local agents = bone.settings.get(PATH)
  if agents == nil then return {} end
  if type(agents) ~= "table" then return nil, PATH .. " must be an object; refusing to overwrite it" end
  for name, spec in pairs(agents) do
    if type(name) ~= "string" or type(spec) ~= "table" then
      return nil, PATH .. " must map names to agent objects; refusing to overwrite it"
    end
    for _, key in ipairs({ "description", "system", "provider", "model" }) do
      if spec[key] ~= nil and type(spec[key]) ~= "string" then
        return nil, "Invalid " .. key .. " for " .. name .. "; fix the saved settings first"
      end
    end
    if spec.tools ~= nil then
      if type(spec.tools) ~= "table" then return nil, "Invalid tools for " .. name end
      local n = 0
      for k, tool in pairs(spec.tools) do
        n = n + 1
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or type(tool) ~= "string" or trim(tool) == "" then
          return nil, "Tools for " .. name .. " must be a list of nonempty strings"
        end
      end
      if n ~= #spec.tools then return nil, "Tools for " .. name .. " must be a dense list" end
    end
  end
  return copy(agents)
end
local function encode(s)
  return (s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"))
end
local function decode(s)
  return (s:gsub("\\(.)", function(c)
    return ({ n = "\n", r = "\r", t = "\t", ["\\"] = "\\" })[c] or ("\\" .. c)
  end))
end
local function draft(name, spec)
  return { name = name or "", description = spec.description or "", system = spec.system or "",
    provider = spec.provider or "", model = spec.model or "",
    tools = spec.tools and (#spec.tools == 0 and "none" or table.concat(spec.tools, ", ")) or "" }
end
local function validate(d, original)
  local name = trim(d.name)
  if #name < 1 or #name > 64 or not name:match("^[%w][%w_-]*$") then
    return nil, "Name: 1–64 ASCII letters/digits, '-' or '_'; start with a letter/digit"
  end
  local spec = copy(original or {})
  for _, key in ipairs({ "description", "system", "provider", "model" }) do
    local value = key == "system" and d[key] or trim(d[key])
    spec[key] = trim(value) ~= "" and value or nil
  end
  local tools = trim(d.tools)
  spec.tools = nil
  if tools == "*" then spec.tools = { "*" }
  elseif tools == "none" or tools == "[]" then spec.tools = {}
  elseif tools ~= "" then
    local list, seen = {}, {}
    for tool in (tools .. ","):gmatch("(.-),") do
      tool = trim(tool)
      if tool == "" or not tool:match("^[%w_][%w_.:/-]*$") then
        return nil, "Tools: comma-separated names, blank to inherit, '*' for all, 'none' / '[]' for none; no empty entries"
      end
      if not seen[tool] then list[#list + 1], seen[tool] = tool, true end
    end
    spec.tools = list
  end
  return name, spec
end
-- UTF-8 byte boundaries: cursor is the byte position before the next character.
local function previous(s, p)
  p = math.max(1, p - 1)
  while p > 1 and s:byte(p) >= 128 and s:byte(p) < 192 do p = p - 1 end
  return p
end
local function following(s, p)
  p = math.min(#s + 1, p + 1)
  while p <= #s and s:byte(p) >= 128 and s:byte(p) < 192 do p = p + 1 end
  return p
end
local function open(wanted, adding)
  if active_close and not active_close(false) then return end
  local agents, err = read_agents()
  if not agents then return bone.notify(err, "error") end
  local st = { agents = agents, names = {}, sel = 1, page = "list", rows = 10 }
  local id, paste_event, opened_event, updated_event, closed_event, focus_event, closed
  local popup_focus, popup_z, focus_popup = {}, {}, nil
  local function owns_paste()
    if focus_popup == false then return false end
    if type(focus_popup) == "number" then return focus_popup == id end
    -- bone3 focus/changed currently supplies a boolean popup flag, not its id.
    -- panel/opened and panel/updated supply { id, kind = 'popup', focus, z };
    -- bone3 orders focused popups by z, then id (newer wins ties).
    if popup_focus[id] == false then return false end
    local own_z = popup_z[id] or 0
    for other, focused in pairs(popup_focus) do
      local z = popup_z[other] or 0
      if focused and (z > own_z or (z == own_z and other > id)) then return false end
    end
    return true
  end
  local function redraw() if id and not closed then bone.ui.update(id, {}) end end
  local function note(text, failure)
    st.note = text
    bone.notify(text, failure and "error" or "info")
    redraw()
  end
  local function names(select)
    st.names = {}; for name in pairs(st.agents) do st.names[#st.names + 1] = name end
    table.sort(st.names)
    st.sel = math.max(1, math.min(st.sel, #st.names))
    for i, name in ipairs(st.names) do if name == select then st.sel = i end end
  end
  local function close(force)
    if closed then return true end
    if force == false and (st.busy or (st.draft and (not equal(st.draft, st.initial) or st.input))) then
      note("Save or discard the current editor before opening another /subagents popup", true)
      return false
    end
    closed = true
    if paste_event then bone.off(paste_event) end
    if opened_event then bone.off(opened_event) end
    if updated_event then bone.off(updated_event) end
    if focus_event then bone.off(focus_event) end
    if closed_event then bone.off(closed_event) end
    if active_close == close then active_close = nil end
    if id then bone.ui.close(id) end
    return true
  end
  local function detail(name)
    st.page, st.sel, st.source = "detail", 1, name
    st.original = name and copy(st.agents[name]) or nil
    st.draft = draft(name, st.original or {})
    st.initial, st.input, st.note = copy(st.draft), nil, nil
  end
  local function back()
    local select = st.source
    st.page, st.draft, st.input, st.ask, st.note = "list", nil, nil, nil, nil
    names(select)
  end
  local function leave(action)
    if st.page == "detail" and not equal(st.draft, st.initial) then
      st.ask = { text = "Discard unsaved changes? y yes · n/esc cancel", action = action }
    else action() end
  end
  local function refresh()
    local value, failure = read_agents()
    if not value then return note(failure, true) end
    st.agents = value; names(); st.note = nil
  end
  local function persist(deleting)
    if st.busy then return end
    local name, spec
    if not deleting then
      name, spec = validate(st.draft, st.original)
      if not name then return note(spec, true) end
    end
    local latest, failure = read_agents()
    if not latest then return note(failure, true) end
    if st.source and not equal(latest[st.source], st.original) then
      return note("Agent changed or was removed elsewhere. Cancel and refresh before saving.", true)
    end
    if not deleting and name ~= st.source and latest[name] ~= nil then
      return note("An agent named '" .. name .. "' already exists; choose a different name", true)
    end
    if st.source then latest[st.source] = nil end
    if not deleting then latest[name] = spec end
    st.busy = true
    bone.settings.set(PATH, latest, function(_, save_err)
      st.busy = false
      if save_err then return note("Could not save agents: " .. errtext(save_err), true) end
      bone.notify(deleting and "Deleted agent " .. st.source or "Saved agent " .. name)
      if closed then return end
      st.agents = latest
      if deleting then back() else detail(name) end
      redraw()
    end)
    redraw()
  end
  local function edit()
    local key = FIELDS[st.sel][1]
    local value = key == "system" and encode(st.draft[key]) or st.draft[key]
    st.input = { key = key, value = value, cursor = #value + 1 }
    st.note = nil
  end
  local function insert(text)
    local e = st.input
    e.value = e.value:sub(1, e.cursor - 1) .. text .. e.value:sub(e.cursor)
    e.cursor = e.cursor + #text
  end
  local function on_key(k)
    if st.busy then
      if k == "esc" or k == "ctrl+c" then close() end
      return true
    end
    if st.ask then
      if k == "y" then local action = st.ask.action; st.ask = nil; action()
      elseif k == "n" or k == "esc" or k == "ctrl+c" then st.ask = nil end
    elseif st.input then
      local e = st.input
      if k == "esc" then st.input = nil
      elseif k == "enter" or k == "ctrl+s" then
        st.draft[e.key] = e.key == "system" and decode(e.value) or e.value
        st.input = nil
        if k == "ctrl+s" then persist(false) end
      elseif k == "shift+enter" and e.key == "system" then insert("\\n")
      elseif k == "left" then e.cursor = previous(e.value, e.cursor)
      elseif k == "right" then e.cursor = following(e.value, e.cursor)
      elseif k == "home" or k == "ctrl+a" then e.cursor = 1
      elseif k == "end" or k == "ctrl+e" then e.cursor = #e.value + 1
      elseif k == "ctrl+u" then e.value, e.cursor = "", 1
      elseif k == "backspace" and e.cursor > 1 then
        local p = previous(e.value, e.cursor)
        e.value, e.cursor = e.value:sub(1, p - 1) .. e.value:sub(e.cursor), p
      elseif k == "delete" then e.value = e.value:sub(1, e.cursor - 1) .. e.value:sub(following(e.value, e.cursor))
      elseif k == "space" then insert(" ")
      elseif k:match("^[%z\1-\127\194-\244][\128-\191]*$") and not k:find("[%z\1-\31\127]") then insert(k) end
    elseif k == "ctrl+c" or k == "q" then leave(close)
    elseif k == "esc" then leave(st.page == "detail" and back or close)
    elseif k == "up" or k == "k" or k == "shift+tab" or k == "backtab" or k == "wheelup" then st.sel = math.max(1, st.sel - 1)
    elseif k == "down" or k == "j" or k == "tab" or k == "wheeldown" then
      st.sel = math.min(st.page == "list" and math.max(1, #st.names) or #FIELDS, st.sel + 1)
    elseif k == "pageup" or k == "pagedown" then
      st.sel = math.max(1, math.min(st.page == "list" and math.max(1, #st.names) or #FIELDS,
        st.sel + (k == "pageup" and -st.rows or st.rows)))
    elseif st.page == "list" then
      if k == "a" then detail(nil); edit()
      elseif k == "r" then refresh()
      elseif (k == "enter" or k == "e") and st.names[st.sel] then detail(st.names[st.sel]) end
    else
      if k == "enter" or k == "e" then edit()
      elseif k == "r" then st.sel = 1; edit()
      elseif k == "s" or k == "ctrl+s" then persist(false)
      elseif k == "d" and st.source then
        st.ask = { text = "Delete '" .. st.source .. "'? y delete · n/esc cancel", action = function() persist(true) end }
      end
    end
    redraw()
    return true
  end
  local function render(ctx)
    local w, h = math.max(1, ctx.width), math.max(1, ctx.height)
    local out = {}
    local function line(text, hl)
      out[#out + 1] = { { bone.text.truncate(text:gsub("[%z\1-\31\127]", " "), w), hl or "Normal" } }
    end
    line("Subagents · " .. (st.page == "list" and "named agents" or (st.source or "new agent")), "Accent")
    line("Blank = inherit · tools: names, * = all, none/[] = deny all · save to apply", "Dim")
    st.rows = math.max(1, h - 6)
    local total = st.page == "list" and #st.names or #FIELDS
    local first = math.max(1, st.sel - st.rows + 1)
    if st.page == "list" and total == 0 then line("No named agents. Press a to add one.", "Dim") end
    for i = first, math.min(total, first + st.rows - 1) do
      local text
      if st.page == "list" then
        local name = st.names[i]
        text = name .. (st.agents[name].description and (" — " .. st.agents[name].description) or "")
      else
        local key, label = FIELDS[i][1], FIELDS[i][2]
        local value = key == "system" and encode(st.draft[key]) or st.draft[key]
        if st.input and i == st.sel then
          local e = st.input
          local before = e.value:sub(1, e.cursor - 1)
          local available = math.max(1, w - bone.text.width(label) - 7)
          while bone.text.width(before) > available do before = before:sub(following(before, 1)) end
          value = before .. "▏" .. e.value:sub(e.cursor)
        elseif value == "" then value = key == "name" and "(required)" or "(inherit)" end
        text = label .. ": " .. value
      end
      line((i == st.sel and "› " or "  ") .. text, i == st.sel and "Selection" or "Normal")
    end
    line(st.busy and "Saving…" or (st.ask and st.ask.text or st.note or ""), st.note and "ErrorMsg" or "Accent")
    if st.input then
      line("Enter accept · Esc cancel field · Ctrl+U clear · ←→ Home/End edit · Ctrl+S save", "Dim")
      line(st.input.key == "system" and "System: \\n newline · \\t tab · \\\\ literal backslash · multiline paste supported"
        or st.input.key == "tools" and "Tools: blank inherits defaults · * explicitly allows all · none or [] denies all"
        or "Paste supported · blank fields inherit defaults", "Dim")
    elseif st.page == "list" then
      line("↑↓/j/k select · Enter detail/edit · a add · r refresh · q/Esc close", "Dim")
      line("/subagents [name] · /subagents add [name] · settings: subagent.agents", "Dim")
    else
      line("↑↓/Tab field · Enter edit · r rename · s/Ctrl+S save · d delete · Esc back", "Dim")
      line("System supports multiline paste / escaped \\n; provider/model blanks inherit", "Dim")
    end
    -- The renderer must remain within the terminal, including narrow windows.
    while #out > h do table.remove(out, math.max(1, #out - 3)) end
    return out
  end
  names()
  if adding then detail(nil); st.draft.name = wanted or ""; edit()
  elseif wanted and wanted ~= "" then
    if not st.agents[wanted] then return bone.notify("No saved agent named '" .. wanted .. "'", "error") end
    detail(wanted)
  end
  id = bone.ui.popup({ lines = render, on_key = on_key, width = 90, height = 20 })
  popup_focus[id] = true
  active_close = close
  paste_event = bone.on("paste", function(ev)
    if closed or ev.context ~= "popup" or not owns_paste() or not st.input or st.busy or st.ask then return end
    local text = (ev.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text:find("%z") then return note("Paste contains NUL bytes", true) end
    if st.input.key == "system" then text = encode(text)
    else text = text:gsub("[\n\t]", " ") end
    insert(text); redraw()
  end)
  local function popup_changed(ev)
    if ev.kind == "popup" then
      popup_focus[ev.id] = ev.focus == true
      popup_z[ev.id] = ev.z or popup_z[ev.id] or 0
    end
  end
  opened_event = bone.on("panel/opened", popup_changed)
  updated_event = bone.on("panel/updated", popup_changed)
  focus_event = bone.on("focus/changed", function(ev)
    -- Also accept id-bearing events; boolean bone3 events use the stack above.
    focus_popup = ev.popup_id or ev.popup
  end)
  closed_event = bone.on("panel/closed", function(ev)
    popup_focus[ev.id] = nil
    popup_z[ev.id] = nil
    if focus_popup == ev.id then focus_popup = nil end
    if ev.id == id then close(true) end
  end)
  return id
end
bone.cmd.create("subagents", function(c)
  local arg = trim(c.args or "")
  if arg == "" or arg == "list" then return open() end
  if arg == "add" then return open(nil, true) end
  local name = arg:match("^add%s+(.+)$")
  if name then return open(trim(name), true) end
  return open(arg)
end, { desc = "Edit named subagents: custom prompts, provider/model, allowed tools; [name] or add [name]" })
