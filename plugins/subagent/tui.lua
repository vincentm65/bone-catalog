-- /subagents: a popup to create and tune named agents. Agents on the left,
-- the selected one's settings on the right; every change is saved at once
-- (subagent.agents in settings). Blank fields inherit the defaults.
local PATH = "subagent.agents"
local FIELDS = {
  { "description", "Description", "what the model reads to decide when to hand work to this agent" },
  { "system", "System prompt", "instructions placed before the normal system prompt" },
  { "provider", "Provider", "one of your configured providers (enter to pick)" },
  { "model", "Model", "model ID on that provider" },
  { "tools", "Allowed tools", "comma-separated names · * all tools · none no tools" },
}
local id, st

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function message(err)
  return type(err) == "table" and tostring(err.message or err.code) or tostring(err)
end

local function redraw()
  if id and bone.ui.is_open(id) then
    bone.ui.update(id, {})
  end
end

local function note(text, bad)
  st.note = text and { { text, bad and "ErrorMsg" or "Dim" } } or nil
  redraw()
end

local function tools_text(list)
  if list == nil then
    return ""
  end
  return #list == 0 and "none" or table.concat(list, ", ")
end

local function parse_tools(text)
  text = trim(text)
  if text == "" then
    return nil
  elseif text == "none" or text == "[]" then
    return {}
  end
  local list = {}
  for tool in (text .. ","):gmatch("(.-),") do
    tool = trim(tool)
    if not tool:match("^[%w_*][%w_.:/-]*$") then
      return nil, "tools are comma-separated names, * or none"
    end
    list[#list + 1] = tool
  end
  return list
end

local function names()
  local out = {}
  for name in pairs(st.agents) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

local function load()
  local agents = bone.settings.get(PATH)
  if agents ~= nil and type(agents) ~= "table" then
    return nil, PATH .. " is not an object; fix settings.json before editing agents"
  end
  return agents or {}
end

-- Write every agent back; the page keeps its in-memory copy on failure.
local function save(done)
  local function after(_, err)
    note(err and ("not saved: " .. message(err)) or done, err ~= nil)
  end
  if next(st.agents) == nil then
    bone.settings.reset(PATH, after)
  else
    bone.settings.set(PATH, st.agents, after)
  end
end

local function open_field(name, key)
  local spec = st.agents[name]
  local value = spec[key]
  if key == "tools" then
    value = tools_text(value)
  end
  st.input = { name = name, key = key, value = value or "" }
  st.note = nil
end

local function accept()
  local inp = st.input
  local spec = st.agents[inp.name]
  local value = inp.value
  if inp.key == "tools" then
    local list, err = parse_tools(value)
    if err then
      return note(err, true)
    end
    spec.tools = list
  elseif inp.key == "rename" or inp.key == "new" then
    value = trim(value)
    if not value:match("^[%w][%w_-]*$") or #value > 64 then
      return note("names are letters, digits, - and _ (start with a letter or digit)", true)
    end
    if st.agents[value] and value ~= inp.name then
      return note("there is already an agent named " .. value, true)
    end
    if inp.key == "new" then
      st.agents[value] = {}
      st.focus = "fields"
    else
      st.agents[value], st.agents[inp.name] = spec, nil
    end
    st.sel_name = value
  else
    spec[inp.key] = trim(value) ~= "" and (inp.key == "system" and value or trim(value)) or nil
  end
  st.input = nil
  save(inp.key == "new" and ("created " .. value) or "saved")
end

local function pick_provider(name)
  bone.model.list(function(list, err)
    if err then
      return note(message(err), true)
    end
    local items = { { name = "", model = "use the session's provider" } }
    for _, p in ipairs(list or {}) do
      items[#items + 1] = p
    end
    bone.ui.select(items, {
      prompt = "provider for " .. name,
      format = function(p) return p.name == "" and "(inherit)" or (p.name .. "  " .. (p.model or "")) end,
      on_choice = function(p)
        if p and st.agents[name] then
          st.agents[name].provider = p.name ~= "" and p.name or nil
          save("saved")
        end
      end,
    })
  end)
end

local function current()
  local list = names()
  local name = st.sel_name
  if not (name and st.agents[name]) then
    name = list[math.max(1, math.min(st.sel, #list))]
  end
  return name, list
end

local function on_key(k)
  local name, list = current()
  local inp = st.input
  if inp then
    local multiline = inp.key == "system"
    if k == "esc" then
      st.input = nil
    elseif k == "ctrl+s" or (k == "enter" and not multiline) then
      accept()
    elseif k == "enter" or k == "shift+enter" then
      inp.value = inp.value .. "\n"
    elseif k == "backspace" then
      inp.value = inp.value:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    elseif k == "ctrl+u" then
      inp.value = ""
    elseif k == "space" then
      inp.value = inp.value .. " "
    elseif k == "tab" then
      inp.value = inp.value .. "\t"
    elseif #k == 1 or k:match("^[\194-\244][\128-\191]*$") then
      inp.value = inp.value .. k
    end
  elseif st.confirm then
    st.confirm = nil
    if k == "y" and name then
      st.agents[name], st.sel_name = nil, nil
      st.focus = "list"
      save("deleted " .. name)
    end
  elseif k == "q" or (k == "esc" and st.focus == "list") then
    bone.ui.close(id)
  elseif k == "esc" or k == "left" or k == "h" then
    st.focus = "list"
  elseif st.focus == "list" then
    if k == "up" or k == "k" then
      st.sel, st.sel_name = math.max(1, st.sel - 1), nil
    elseif k == "down" or k == "j" then
      st.sel, st.sel_name = math.min(#list, st.sel + 1), nil
    elseif k == "n" or (k == "enter" and #list == 0) then
      st.input = { key = "new", name = "", value = "" }
    elseif (k == "enter" or k == "right" or k == "tab" or k == "l") and name then
      st.focus, st.field = "fields", 1
    elseif k == "r" and name then
      st.input = { key = "rename", name = name, value = name }
    elseif k == "d" and name then
      st.confirm = true
    end
  else
    if k == "up" or k == "k" then
      st.field = math.max(1, st.field - 1)
    elseif k == "down" or k == "j" or k == "tab" then
      st.field = math.min(#FIELDS, st.field + 1)
    elseif k == "enter" or k == "e" then
      local key = FIELDS[st.field][1]
      if key == "provider" then
        pick_provider(name)
      else
        open_field(name, key)
      end
    elseif k == "x" or k == "delete" then
      st.agents[name][FIELDS[st.field][1]] = nil
      save("cleared (inherits the default)")
    elseif k == "r" then
      st.input = { key = "rename", name = name, value = name }
    elseif k == "d" then
      st.confirm = true
    end
  end
  redraw()
  return true
end

-- Spans clipped or padded to exactly `width` cells (the box wraps otherwise).
local function fit(spans, width)
  local used = 0
  for _, sp in ipairs(spans) do
    used = used + bone.text.width(sp[1])
  end
  local out = used > width and bone.text.clip(spans, width) or { unpack(spans) }
  out[#out + 1] = { string.rep(" ", math.max(0, width - used)), "Normal" }
  return out
end

-- The right side: an agent's fields, the one being edited with a cursor.
local function detail(name, width, height)
  local out = {}
  if not name then
    return bone.text.wrap({ { "No agents yet. Press n to create one: a name, then a prompt, and the model "
      .. "can hand it work with the subagent tool.", "Dim" } }, width)
  end
  local spec = st.agents[name]
  out[1] = { { name, "Accent" } }
  for i, f in ipairs(FIELDS) do
    local key, label = f[1], f[2]
    local on = st.focus == "fields" and st.field == i
    local editing = st.input and st.input.name == name and st.input.key == key
    out[#out + 1] = {}
    out[#out + 1] = { { (on and "› " or "  ") .. label, on and "Selection" or "Normal" },
      { on and ("  " .. f[3]) or "", "Dim" } }
    local value = editing and (st.input.value .. "▏")
      or (key == "tools" and tools_text(spec.tools) or spec[key] or "")
    local hl = "Normal"
    if value == "" then
      value, hl = "inherits the default", "Dim"
    end
    local shown = {}
    for line in (value .. "\n"):gmatch("(.-)\n") do
      for _, l in ipairs(bone.text.wrap({ { line, hl } }, width - 4, { first = "    ", rest = "    " })) do
        shown[#shown + 1] = l
      end
    end
    local limit = editing and 8 or 4
    for n, line in ipairs(shown) do
      if n > limit then
        out[#out + 1] = { { "    …", "Dim" } }
        break
      end
      out[#out + 1] = line
    end
  end
  return out
end

local function render(ctx)
  local w = math.max(48, math.min(ctx.width, 104))
  local h = math.max(8, math.min(ctx.height, 28)) - 6
  local inner = w - 4
  local lw = math.min(26, math.floor(inner / 3))
  local rw = inner - lw - 3
  local name, list = current()
  local right = detail(name, rw, h)
  -- Keep the field being edited in view.
  local first = 1
  for i, l in ipairs(right) do
    if st.input and l[1] and l[1][1]:find("^›") then
      first = math.max(1, i - h + 8)
    end
  end
  local rows = {}
  for i = 1, h do
    local item = list[i]
    local l = {}
    if item then
      local on = item == name
      l = { { (on and (st.focus == "list" and "› " or "▸ ") or "  ") .. item, on and st.focus == "list" and "Selection" or "Normal" } }
    elseif i == #list + 1 then
      l = { { "  n  new agent", "Dim" } }
    end
    local row = fit(l, lw)
    row[#row + 1] = { " │ ", "Dim" }
    for _, sp in ipairs(fit(right[i + first - 1] or {}, rw)) do
      row[#row + 1] = sp
    end
    rows[i] = row
  end
  rows[#rows + 1] = { { string.rep("─", inner), "Dim" } }
  if st.input then
    local k = st.input.key
    rows[#rows + 1] = { { k == "new" and "New agent name: " or k == "rename" and "New name: " or "Editing: ", "Accent" },
      { (k == "new" or k == "rename") and (st.input.value .. "▏") or "", "Normal" } }
    rows[#rows + 1] = { { (k == "system" and "enter newline · ctrl+s save" or "enter save")
      .. " · ctrl+u clear · esc cancel", "Dim" } }
  elseif st.confirm then
    rows[#rows + 1] = { { "Delete " .. tostring(name) .. "?  y yes · any other key cancels", "WarningMsg" } }
    rows[#rows + 1] = {}
  else
    rows[#rows + 1] = st.note or {}
    rows[#rows + 1] = { { st.focus == "list"
      and "↑↓ choose · enter edit · n new · r rename · d delete · esc close"
      or "↑↓ field · enter edit · x inherit · r rename · d delete · esc back", "Dim" } }
  end
  return bone.ui.box(rows, { title = "Subagents", width = w })
end

bone.on("paste", function(ev)
  if st and id and bone.ui.is_open(id) and st.input then
    local text = (ev.text or ""):gsub("\r\n?", "\n")
    if st.input.key ~= "system" then
      text = text:gsub("%s+", " ")
    end
    st.input.value = st.input.value .. text
    redraw()
  end
end)

local function open(arg)
  if id and bone.ui.is_open(id) then
    bone.ui.close(id)
  end
  local agents, err = load()
  if not agents then
    return bone.notify(err, "error")
  end
  st = { agents = agents, sel = 1, focus = "list", field = 1 }
  if arg and arg ~= "" then
    if st.agents[arg] then
      st.sel_name, st.focus = arg, "fields"
    else
      st.input = { key = "new", name = "", value = arg }
    end
  end
  id = bone.ui.popup({ lines = render, on_key = on_key, width = 104, height = 28 })
end

bone.cmd.create("subagents", function(c)
  open(trim((c.args or ""):gsub("^add%s*", "")))
end, { desc = "Create and tune named subagents: prompt, provider, model, tools" })
