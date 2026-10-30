-- /subagents: a popup to create and tune named agents. Agents on the left,
-- the selected one's settings on the right; every change is saved at once
-- (subagent.agents in settings). Blank fields inherit the defaults.
-- One view for the terminal and the desktop app: the agents beside the
-- selected one's fields. Move through both, press a field to edit it (x
-- makes it inherit the default), and New / Rename / Delete for the agent.
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
  st.note = text and { text = text, bad = bad } or nil
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
  local name = current()
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
      save("deleted " .. name)
    end
  elseif k == "q" or k == "esc" then
    bone.ui.close(id)
  elseif k == "n" then
    st.input = { key = "new", name = "", value = "" }
  elseif k == "r" and name then
    st.input = { key = "rename", name = name, value = name }
  elseif k == "d" and name then
    st.confirm = true
  else
    -- Not ours: the cursor and the window have it.
    return false
  end
  redraw()
  return true
end

-- At most `n` lines of `text`, then an ellipsis.
local function preview(text, n)
  local out, count = {}, 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    count = count + 1
    if count > n then
      out[#out + 1] = "…"
      break
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

local function button(label, key, primary)
  return { kind = "button", label = label, primary = primary, on_press = function() on_key(key) end }
end

-- The selected agent's fields; the one being edited takes the keys.
local function fields(name)
  local spec = st.agents[name]
  local out = { kind = "column", { kind = "text", text = name, tone = "accent", strong = true } }
  for _, f in ipairs(FIELDS) do
    local key = f[1]
    local editing = st.input and st.input.name == name and st.input.key == key
    local value = editing and st.input.value or (key == "tools" and tools_text(spec.tools) or spec[key] or "")
    out[#out + 1] = {
      kind = "field", label = f[2], value = editing and value or preview(value, 4), editing = editing,
      empty = "inherits the default",
      hint = editing and ((key == "system" and "enter newline · ctrl+s save" or "enter save") .. " · ctrl+u clear · esc cancel")
        or (f[3] .. " · enter edit · x inherit"),
      on_press = function()
        if key == "provider" then pick_provider(name) else open_field(name, key) end
        redraw()
      end,
      on_key = function(k)
        if k ~= "x" and k ~= "delete" then return false end
        spec[key] = nil
        save("cleared (inherits the default)")
        return true
      end,
    }
  end
  return out
end

local function view()
  if not st then return nil end
  local name, list = current()
  local selected = 1
  local items = {}
  for i, n in ipairs(list) do
    items[i] = { text = n }
    if n == name then selected = i end
  end
  local side = #list > 0 and { kind = "list", items = items, selected = selected,
    on_select = function(i) st.sel, st.sel_name = i, list[i] end }
    or { kind = "text", text = "No agents", tone = "dim" }
  local main = name and fields(name) or { kind = "text", tone = "dim",
    text = "No agents yet. Press n to create one: a name, then a prompt, and the model can hand it work with the subagent tool." }
  local bar
  local k = st.input and st.input.key
  if k == "new" or k == "rename" then
    bar = { kind = "field", label = k == "new" and "New agent name" or "New name", value = st.input.value,
      editing = true, hint = "enter save · ctrl+u clear · esc cancel" }
  elseif st.confirm and name then
    bar = { kind = "row", { kind = "text", text = "Delete " .. name .. "?", tone = "warning" },
      button("Delete", "y", true), button("Cancel", "n") }
  elseif not st.input then
    bar = { kind = "row",
      button("New agent", "n", not name),
      name and button("Rename", "r") or nil,
      name and button("Delete", "d") or nil,
      { kind = "hints", text = "↑↓ move · enter edit · x inherit · n new · r rename · d delete · esc close" } }
  end
  return {
    kind = "column",
    { kind = "split", side, main },
    st.note and { kind = "text", text = st.note.text, tone = st.note.bad and "error" or "dim" } or nil,
    bar and { kind = "divider" } or nil,
    bar,
  }
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
  st = { agents = agents, sel = 1 }
  if arg and arg ~= "" then
    if st.agents[arg] then
      st.sel_name = arg
    else
      st.input = { key = "new", name = "", value = arg }
    end
  end
  id = bone.ui.popup({ title = "Subagents", view = view, on_key = on_key, width = 104, height = 28 })
end

bone.cmd.create("subagents", function(c)
  open(trim((c.args or ""):gsub("^add%s*", "")))
end, { desc = "Create and tune named subagents: prompt, provider, model, tools" })
