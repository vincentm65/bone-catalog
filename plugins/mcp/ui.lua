-- mcp, shared UI: /mcp opens a popup to see, add, sign in to and manage MCP
-- servers and their tools. Servers added here are kept in ~/.bone/mcp.json
-- (loaded by this plugin's core half), which also says how each tool reaches
-- the model: on, pinned (always loaded) or off.
-- One view for the terminal and the desktop app: servers beside the selected
-- one's details, enter for its tools, and every action as a key and a button.
-- Outside the popup: a message when a server needs a sign-in or fails, a line
-- on the new-chat screen while one does, and MCP calls drawn in the chat as
-- "server › tool arguments".
local FILE = bone.config_dir .. "/mcp.json"
local STATES = {
  ready = { "●", "success", "ready" }, starting = { "◐", "warning", "starting" },
  idle = { "○", "dim", "idle (starts on first use)" }, disabled = { "○", "dim", "disabled" },
  auth = { "◆", "warning", "sign in needed" }, failed = { "✕", "error", "failed" },
}
local STEPS = {
  name = "Name (letters, digits, _ -)",
  target = "Command and arguments, or an https:// URL",
  header = "Authorization header value (blank: sign in with OAuth)",
  env = "Environment for it: KEY=value KEY2=value (blank: none)",
}
local MODES = { auto = "on", on = "off", off = "auto" }
local WIDTH, HEIGHT = 104, 26
local SHOWN = 10 -- a server's tools named beside it; enter shows them all
local id, st
local observe

local function read_config()
  local f = io.open(FILE, "r")
  if not f then
    return { mcpServers = {} }
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(bone.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil, "cannot parse " .. FILE
  end
  data.mcpServers = data.mcpServers or data.servers or {}
  return data
end

local function redraw()
  if id and bone.ui.is_open(id) then
    bone.ui.update(id, {})
  end
end

local function note(text, bad)
  if not (id and bone.ui.is_open(id)) then -- /mcp-add, or a reply after the popup closed
    return text and bone.notify("mcp: " .. text, bad and "error" or nil)
  end
  st.note = text and { text = text, bad = bad } or nil
  redraw()
end

local function message(err)
  return type(err) == "table" and tostring(err.message or err.code) or tostring(err)
end

local function tok(n)
  n = tonumber(n) or 0
  return n < 1000 and ("~" .. n) or string.format("~%.1fk", n / 1000)
end

local function brief(text, max)
  text = tostring(text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #text <= max then return text end
  local cut = text:sub(1, max)
  return (cut:gsub("[\194-\244]?[\128-\191]*$", "")) .. "…"
end

-- The core's servers, plus the disabled ones only mcp.json knows about.
local function merged(list)
  local out, seen = {}, {}
  for _, s in ipairs(list or {}) do
    seen[s.name] = true
    out[#out + 1] = s
  end
  local cfg = read_config()
  for name, spec in pairs(cfg and cfg.mcpServers or {}) do
    if type(spec) == "table" and spec.disabled and not seen[name] then
      out[#out + 1] = { name = name, state = "disabled", tools = {}, url = spec.url, command = spec.command }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- A server's tools as the core half remembers them (with sizes, states and
-- arguments; kept while the server is down), else as the server lists them.
local function tools_of(s)
  local known = st.info and type(st.info.servers) == "table" and st.info.servers[s.name]
  if known and #(known.tools or {}) > 0 then return known.tools end
  local out = {}
  for _, t in ipairs(s.tool_info or {}) do
    out[#out + 1] = { name = t.name, description = t.description, read_only = t.read_only, state = "on" }
  end
  return out
end

local function filtered(tools)
  local want = (st.filter or ""):lower()
  if want == "" then return tools end
  local out = {}
  for _, t in ipairs(tools) do
    if t.name:lower():find(want, 1, true) or (t.description or ""):lower():find(want, 1, true) then
      out[#out + 1] = t
    end
  end
  return out
end

-- The tools on screen, and which of them is selected.
local function shown_tools()
  local s = st.servers[st.sel]
  local tools = s and filtered(tools_of(s)) or {}
  local at = 1
  for i, t in ipairs(tools) do
    if t.name == st.tool then at = i end
  end
  return tools, at, s
end

local refresh
refresh = function()
  bone.request("mcp/list", {}, function(list, err)
    if not st then
      return
    end
    if list then observe(list) end
    st.servers = merged(list)
    st.sel = math.max(1, math.min(st.sel, #st.servers))
    local cur = st.servers[st.sel]
    if st.signing and cur and cur.name == st.signing.name and cur.state == "ready" then
      st.signing = nil
      note("signed in to " .. cur.name)
    elseif err then
      note(message(err), true)
    end
    redraw()
    -- Sizes and tool states, from the core half (absent when it is not loaded).
    bone.rpc.call("mcp.info", {}, function(info)
      if not st then return end
      st.info = type(info) == "table" and info or nil
      redraw()
    end)
    -- Keep watching while something is starting or a sign-in is open.
    local busy = st.signing ~= nil
    for _, s in ipairs(st.servers) do
      busy = busy or s.state == "starting"
    end
    if busy then
      bone.defer(1000, function()
        if id and bone.ui.is_open(id) then
          refresh()
        end
      end)
    end
  end)
end

-- Save mcp.json, then have the core pick it up.
local function save(data, done)
  local ok, err = bone.fs.write(FILE, bone.json.encode(data) .. "\n")
  if not ok then
    return note(tostring(err), true)
  end
  bone.request("core/reload", {}, function(_, e)
    note(e and ("saved, but reload failed: " .. message(e)) or done, e ~= nil)
    if st then refresh() end
  end)
end

local function request(method, name, done)
  bone.request(method, { name = name }, function(_, err)
    note(err and message(err) or done, err ~= nil)
    refresh()
  end)
end

-- Open `url` in the user's browser, where there is one here.
local function open_url(url)
  local os_name = type(jit) == "table" and jit.os or ""
  if package.config:sub(1, 1) == "\\" then
    bone.system("Start-Process '" .. url:gsub("'", "''") .. "'", {}, function() end)
  elseif os_name == "OSX" then
    bone.system("open '" .. url:gsub("'", "'\\''") .. "'", {}, function() end)
  elseif not os.getenv("SSH_TTY") and (os.getenv("DISPLAY") or os.getenv("WAYLAND_DISPLAY")) then
    bone.system("xdg-open '" .. url:gsub("'", "'\\''") .. "'", {}, function() end)
  end
end

local function sign_in(s)
  bone.request("mcp/auth", { name = s.name }, function(res, err)
    if err then
      return note(message(err), true)
    end
    st.signing = { name = s.name, url = res.url }
    if not os.getenv("SSH_TTY") then open_url(res.url) end
    note(nil)
    refresh()
  end)
end

-- "KEY=value KEY2=value two" as a table; a value runs to the next KEY=.
local function parse_env(text)
  local starts = {}
  for pos, key in text:gmatch("()([%a_][%w_]*)=") do
    if pos == 1 or text:sub(pos - 1, pos - 1):match("%s") then
      starts[#starts + 1] = { pos = pos, key = key }
    end
  end
  if #starts == 0 or starts[1].pos ~= 1 then
    return nil, "write it as KEY=value KEY2=value"
  end
  local env = {}
  for i, s in ipairs(starts) do
    local value = text:sub(s.pos + #s.key + 1, starts[i + 1] and starts[i + 1].pos - 1 or #text)
    value = value:match("^%s*(.-)%s*$")
    env[s.key] = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
  end
  return env
end

local function add(name, target, header, env)
  local data, err = read_config()
  if not data then
    return note(err, true)
  end
  if data.mcpServers[name] then
    return note("a server named " .. name .. " already exists", true)
  end
  if target:match("^https?://") then
    data.mcpServers[name] = { url = target, headers = header ~= "" and { Authorization = header } or nil }
  else
    local argv = {}
    for word in target:gmatch("%S+") do
      argv[#argv + 1] = word
    end
    data.mcpServers[name] = { command = table.remove(argv, 1), args = argv, env = env and next(env) and env or nil }
  end
  save(data, "added " .. name)
end

local function change(s, fn, done)
  local data, err = read_config()
  if not data then
    return note(err, true)
  end
  if not data.mcpServers[s.name] then
    return note(s.name .. " is defined in core.lua or another file; edit it there", true)
  end
  fn(data.mcpServers)
  save(data, done)
end

-- How one tool reaches the model: "on", "off" or "pin".
local function set_tool(s, t, state)
  t.state = state -- at once; the core's answer follows
  bone.rpc.call("mcp.set", { server = s.name, tool = t.name, state = state }, function(info, err)
    if not st then return end
    if err or type(info) ~= "table" then
      note(err and message(err) or "the mcp plugin's core half is not loaded", true)
      return refresh()
    end
    st.info = info
    redraw()
  end)
end

local function submit()
  local inp = st.input
  local value = inp.value:match("^%s*(.-)%s*$")
  if inp.step == "name" then
    if not value:match("^[%w_%-]+$") then
      return note("names are letters, digits, _ and -", true)
    end
    st.input = { step = "target", name = value, value = "" }
  elseif inp.step == "target" then
    if value == "" then
      return note("give a command or a URL", true)
    end
    st.input = { step = value:match("^https?://") and "header" or "env", name = inp.name, target = value, value = "" }
  elseif inp.step == "env" then
    local env, err = {}, nil
    if value ~= "" then env, err = parse_env(value) end
    if not env then return note(err, true) end
    st.input = nil
    add(inp.name, inp.target, "", env)
  else
    st.input = nil
    add(inp.name, inp.target, value)
  end
  note(nil)
end

-- `value` after key `k` typed into it, or nil when `k` types nothing.
local function typed(value, k)
  if k == "backspace" then
    return (value:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""))
  elseif k == "ctrl+u" then
    return ""
  elseif k == "space" then
    return value .. " "
  elseif #k == 1 or k:match("^[\194-\244][\128-\191]*$") then
    return value .. k
  end
end

local function on_key(k)
  local s = st.servers[st.sel]
  if st.input then
    local inp = st.input
    if k == "esc" then
      st.input = nil
    elseif k == "enter" then
      submit()
    else
      inp.value = typed(inp.value, k) or inp.value
    end
  elseif st.filtering then
    -- Every key is the filter's while it is typed into; the arrows still move.
    local tools, at = shown_tools()
    if k == "esc" then
      st.filter, st.filtering = "", false
    elseif k == "enter" then
      st.filtering = false
    elseif k == "up" or k == "down" then
      local to = tools[at + (k == "up" and -1 or 1)]
      if to then st.tool = to.name end
    else
      st.filter = typed(st.filter, k) or st.filter
    end
  elseif st.confirm then
    local go = k == "y" and st.confirm
    st.confirm = nil
    if go then
      go()
    end
  elseif st.view == "tools" then
    local tools, at = shown_tools()
    local t = tools[at]
    if k == "esc" or k == "q" or k == "left" then
      if st.filter ~= "" then
        st.filter = ""
      else
        st.view, st.tool, st.top = "servers", nil, nil
      end
    elseif k == "/" then
      st.filtering, st.note = true, nil
    elseif k == "space" and t and s then
      set_tool(s, t, t.state == "off" and "on" or "off")
    elseif k == "p" and t and s then
      set_tool(s, t, t.state == "pin" and "on" or "pin")
    else
      return false
    end
  elseif k == "esc" or k == "q" then
    if st.signing then
      st.signing = nil
    else
      bone.ui.close(id)
    end
  elseif k == "c" and st.signing then
    if bone.clipboard then
      bone.clipboard.copy(st.signing.url)
      note("copied the sign-in address")
    else
      note("copying needs a newer Bone; select the address with the mouse instead", true)
    end
  elseif k == "a" then
    st.input, st.note = { step = "name", value = "" }, nil
  elseif k == "l" then
    local next_mode = MODES[st.info and st.info.mode or "auto"] or "auto"
    bone.settings.set("mcp.on_demand", next_mode, function(_, err)
      if err then note(message(err), true) end
      if st then refresh() end
    end)
  elseif k == "r" and s and s.state ~= "disabled" then
    request("mcp/reconnect", s.name, "reconnecting " .. s.name)
  elseif (k == "s" or (k == "enter" and s and s.state == "auth")) and s and s.url and s.state ~= "disabled" then
    sign_in(s)
  elseif (k == "enter" or k == "t" or k == "right") and s and #tools_of(s) > 0 then
    st.view, st.filter, st.filtering, st.tool, st.top, st.note = "tools", "", false, nil, nil, nil
  elseif k == "x" and s and s.signed_in then
    request("mcp/sign_out", s.name, "signed out of " .. s.name)
  elseif k == "space" and s then
    local on = s.state == "disabled"
    change(s, function(all) all[s.name].disabled = (not on) or nil end, (on and "enabled " or "disabled ") .. s.name)
  elseif k == "d" and s then
    st.confirm = function()
      change(s, function(all) all[s.name] = nil end, "removed " .. s.name)
    end
  else
    -- Not ours: the window scrolls.
    return false
  end
  redraw()
  return true
end

local function button(label, key, primary)
  return { kind = "button", label = label, primary = primary, on_press = function() on_key(key) end }
end

-- What a tool's state means for the model, as a badge (nil when it is the usual).
local function state_badge(t)
  if t.state == "off" then return { text = "off", tone = "dim" } end
  if t.state == "pin" then return { text = "pinned", tone = "accent" } end
  return nil
end

-- A server's tools in a line: how many, how large, how they are loaded.
local function tools_title(s, tools)
  local size, off, pinned = 0, 0, 0
  for _, t in ipairs(tools) do
    if t.state == "off" then off = off + 1 else size = size + (t.tokens or 0) end
    if t.state == "pin" then pinned = pinned + 1 end
  end
  local parts = { "Tools  " .. #tools }
  if size > 0 then parts[#parts + 1] = tok(size) .. " tokens" end
  if pinned > 0 then parts[#parts + 1] = pinned .. " pinned" end
  if off > 0 then parts[#parts + 1] = off .. " off" end
  return table.concat(parts, " · ")
end

-- The selected server: what it is, where it runs, and its tools by name.
local function detail(s)
  local state = STATES[s.state] or STATES.failed
  local out = { kind = "column",
    { kind = "row", { kind = "text", text = s.name, strong = true },
      { kind = "badge", text = state[3], tone = state[2] },
      s.signed_in and { kind = "badge", text = "signed in", tone = "dim" } or nil,
      s.lazy and { kind = "badge", text = "lazy", tone = "dim" } or nil },
  }
  local function add(el) out[#out + 1] = el end
  local where = s.url or (s.command and ("$ " .. s.command:gsub("%s+", " "))) or ""
  if where ~= "" then add({ kind = "code", text = where }) end
  if s.error then add({ kind = "text", text = s.error, tone = "error" }) end
  if st.signing and st.signing.name == s.name then
    add({ kind = "text", text = "Open this address in a browser and approve. If the browser is on another machine, "
      .. "paste the address it ends up on (even if that page fails to load)." })
    add({ kind = "code", text = st.signing.url })
    return out
  end
  local all = tools_of(s)
  local tools = { kind = "section", title = tools_title(s, all) }
  for i = 1, math.min(#all, SHOWN) do
    local t = all[i]
    local badge = state_badge(t)
    tools[#tools + 1] = { kind = "row",
      { kind = "text", text = t.name, tone = t.state == "off" and "dim" or "accent" },
      badge and { kind = "badge", text = badge.text, tone = badge.tone } or nil,
      { kind = "text", text = brief(t.description, 200), tone = "dim", truncate = true } }
  end
  if #all > SHOWN then
    tools[#tools + 1] = { kind = "text", text = "… and " .. (#all - SHOWN) .. " more · enter shows them all", tone = "dim" }
  elseif #all == 0 then
    tools[#tools + 1] = { kind = "text", text = "No tools reported.", tone = "dim" }
  end
  add(tools)
  return out
end

-- How the tool definitions reach the model, and what that costs each request.
local function loading()
  local i = st.info
  if not i or (tonumber(i.tokens) or 0) == 0 then return nil end
  local text
  if i.on_demand then
    text = "Tools load on demand (" .. i.mode .. "): " .. tok(i.sent) .. " of " .. tok(i.tokens)
      .. " tokens of definitions in each request"
  else
    text = "Every tool is loaded (" .. i.mode .. (i.mode == "auto" and (", on demand above " .. tok(i.above)) or "")
      .. "): " .. tok(i.tokens) .. " tokens of definitions in each request"
  end
  return { kind = "row", { kind = "text", text = text, tone = "dim" }, button("Change", "l") }
end

-- One tool in full: what it does and what it takes.
local function tool_detail(t)
  local badge = state_badge(t)
  local out = { kind = "column",
    { kind = "row", { kind = "text", text = t.name, strong = true },
      badge and { kind = "badge", text = badge.text, tone = badge.tone }
        or (st.info and st.info.on_demand and { kind = "badge", text = "on demand", tone = "dim" } or nil),
      t.read_only and { kind = "badge", text = "read-only", tone = "dim" } or nil,
      t.tokens and { kind = "badge", text = tok(t.tokens) .. " tokens", tone = "dim" } or nil },
  }
  local d = brief(t.description, 360)
  if d ~= "" then out[#out + 1] = { kind = "text", text = d } end
  local args = type(t.args) == "table" and t.args or nil
  if args then
    local section = { kind = "section", title = "Arguments  " .. #args }
    for i = 1, math.min(#args, 6) do
      local a = args[i]
      section[#section + 1] = { kind = "row", { kind = "text", text = a.name, tone = "accent" },
        { kind = "text", text = a.type or "any", tone = "dim" },
        a.required and { kind = "badge", text = "required", tone = "dim" } or nil }
    end
    if #args > 6 then
      section[#section + 1] = { kind = "text", text = "… and " .. (#args - 6) .. " more", tone = "dim" }
    elseif #args == 0 then
      section[#section + 1] = { kind = "text", text = "None.", tone = "dim" }
    end
    out[#out + 1] = section
  end
  return out
end

-- A server's tools: a window of the list (the selected one kept off its
-- edges, so the arrows always have somewhere to go) beside the selected one.
local function tools_view(ctx)
  local tools, at, s = shown_tools()
  if not s then
    st.view = "servers"
    return nil
  end
  local state = STATES[s.state] or STATES.failed
  local rows = math.max(5, math.min(HEIGHT, ctx and ctx.rows or HEIGHT) - 12)
  local top = 1
  if #tools > rows then
    top = st.top or 1
    if at - top < 1 then top = at - 1 end
    if top + rows - 1 - at < 1 then top = at - rows + 2 end
    top = math.max(1, math.min(top, #tools - rows + 1))
  end
  st.top = top
  local last = math.min(#tools, top + rows - 1)
  local items = {}
  for i = top, last do
    local t = tools[i]
    local badge = state_badge(t)
    items[#items + 1] = { text = t.name, on = t.state ~= "off", tone = t.state == "off" and "dim" or "normal",
      badges = badge and t.state == "pin" and { badge } or nil }
  end
  local t = tools[at]
  if t then st.tool = t.name end
  local side = { kind = "column",
    { kind = "text", text = top > 1 and ("↑ " .. (top - 1) .. " more") or "", tone = "dim" },
    { kind = "list", items = items, selected = at - top + 1, empty = "No tool matches.",
      on_select = function(i)
        local to = tools[top + i - 1]
        if to then st.tool, st.note = to.name, nil end
      end },
    { kind = "text", text = last < #tools and ("↓ " .. (#tools - last) .. " more") or "", tone = "dim" },
  }
  local bar
  if st.filtering then
    bar = { kind = "hints", text = "type to filter · ↑↓ move · enter keep · esc clear" }
  else
    bar = { kind = "row" }
    if t then
      bar[#bar + 1] = button(t.state == "off" and "Turn on" or "Turn off", "space", true)
      bar[#bar + 1] = button(t.state == "pin" and "Unpin" or "Pin", "p")
    end
    bar[#bar + 1] = button("Filter", "/")
    bar[#bar + 1] = button("Back", "esc")
  end
  return {
    kind = "column",
    { kind = "row", { kind = "text", text = s.name, strong = true },
      { kind = "badge", text = state[3], tone = state[2] },
      { kind = "text", text = tools_title(s, tools_of(s)), tone = "dim" } },
    (st.filtering or st.filter ~= "") and { kind = "field", label = "Filter", value = st.filter,
      editing = st.filtering } or nil,
    { kind = "split", side, t and tool_detail(t) or { kind = "text", text = "", tone = "dim" } },
    st.note and { kind = "text", text = st.note.text, tone = st.note.bad and "error" or "dim" } or nil,
    { kind = "divider" },
    bar,
    not st.filtering and { kind = "hints",
      text = "space on/off · p pin (always loaded) · / filter · esc back" } or nil,
  }
end

local function view(ctx)
  if not st then return nil end
  if st.view == "tools" and not st.input and not st.confirm then
    local tree = tools_view(ctx)
    if tree then return tree end
  end
  local servers = st.servers or {}
  local s = servers[st.sel]
  local items = {}
  for i, sv in ipairs(servers) do
    local state = STATES[sv.state] or STATES.failed
    items[i] = { text = state[1] .. " " .. sv.name, tone = state[2] == "success" and "normal" or state[2] }
  end
  local body = s and {
    kind = "split",
    { kind = "list", items = items, selected = st.sel,
      on_select = function(i) st.sel, st.note = i, nil end },
    detail(s),
  } or { kind = "text", text = "No MCP servers yet. Add a command or an https:// URL.", tone = "dim" }
  local bar
  if st.input then
    bar = { kind = "field", label = STEPS[st.input.step] or "", value = st.input.value, editing = true,
      hint = "enter next · esc cancel" }
  elseif st.confirm and s then
    bar = { kind = "row", { kind = "text", text = "Remove " .. s.name .. " from mcp.json?", tone = "warning" },
      button("Remove", "y", true), button("Cancel", "n") }
  elseif st.signing then
    bar = { kind = "row", button("Copy address", "c", true), button("Cancel sign-in", "esc"),
      { kind = "hints", text = "c copy address · paste the redirected address · esc cancel" } }
  else
    bar = { kind = "row", button("Add", "a", true) }
    if s and #tools_of(s) > 0 then bar[#bar + 1] = button("Tools", "t") end
    if s and s.state ~= "disabled" then bar[#bar + 1] = button("Reconnect", "r") end
    if s and s.url and s.state ~= "disabled" then bar[#bar + 1] = button("Sign in", "s") end
    if s and s.signed_in then bar[#bar + 1] = button("Sign out", "x") end
    if s then
      bar[#bar + 1] = button(s.state == "disabled" and "Enable" or "Disable", "space")
      bar[#bar + 1] = button("Remove", "d")
    end
  end
  return {
    kind = "column",
    body,
    st.note and { kind = "text", text = st.note.text, tone = st.note.bad and "error" or "dim" } or nil,
    { kind = "divider" },
    not (st.input or st.confirm or st.signing) and loading() or nil,
    bar,
    not (st.input or st.confirm or st.signing)
      and { kind = "hints", text = "enter tools · a add · r reconnect · s/x sign in/out · space on/off · d remove · l loading · esc" } or nil,
  }
end

bone.on("paste", function(ev)
  if not st or not id or not bone.ui.is_open(id) then
    return
  end
  local text = (ev.text or ""):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
  if st.input then
    st.input.value = st.input.value .. text
    redraw()
  elseif st.filtering then
    st.filter = st.filter .. text
    redraw()
  elseif st.signing then
    bone.request("mcp/auth_code", { name = st.signing.name, code = text }, function(_, err)
      note(err and message(err) or "checking the sign-in…", err ~= nil)
      refresh()
    end)
  end
end)

bone.cmd.create("mcp", function()
  if id and bone.ui.is_open(id) then
    return bone.ui.close(id)
  end
  st = { servers = {}, sel = 1, view = "servers", filter = "" }
  id = bone.ui.popup({ title = "MCP servers", view = view, on_key = on_key, width = WIDTH, height = HEIGHT })
  refresh()
end, { desc = "MCP servers: state, tools, sign-in, add and remove (mcp plugin)" })

bone.cmd.create("mcp-add", function(c)
  local argv = c.argv or {}
  if #argv < 2 or not argv[1]:match("^[%w_%-]+$") then
    return bone.notify("usage: /mcp-add NAME COMMAND [ARGS...]  or  NAME https://URL", "error")
  end
  add(argv[1], table.concat(argv, " ", 2), "")
end, { desc = "add an MCP server: /mcp-add NAME COMMAND [ARGS...] or NAME URL" })

-- ---- outside the popup --------------------------------------------------------

-- A call's arguments in a few words: key=value, the long ones cut.
local function preview(args, room)
  if type(args) ~= "table" then return "" end
  local keys = {}
  for k in pairs(args) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local parts, used = {}, 0
  for _, k in ipairs(keys) do
    local v = args[k]
    local shown
    if type(v) == "table" then
      shown = v[1] ~= nil and ("[" .. #v .. "]") or "{…}"
    elseif type(v) == "string" then
      shown = brief(v, 40)
    elseif type(v) == "number" or type(v) == "boolean" then
      shown = tostring(v)
    end
    if shown then
      local part = k .. "=" .. shown
      if used + #part > room and #parts > 0 then
        parts[#parts + 1] = "…"
        break
      end
      parts[#parts + 1] = part
      used = used + #part + 1
    end
  end
  return table.concat(parts, " ")
end

-- A call of `tool` on `server` in the chat: "server › tool arguments" over
-- the frontend's own drawing of the result.
local function call_content(item, ctx, server, tool, args)
  local title = {
    { tostring(server or "mcp"), "Dim" }, { " › ", "Dim" }, { tostring(tool or "?"), "ToolName" },
  }
  local words = preview(args, math.min(80, math.max(20, (ctx.width or 80) - 40)))
  if words ~= "" then title[#title + 1] = { "  " .. words, "ToolArgs" } end
  if type(bone.ui.tool_content) == "function" then
    -- The terminal's frame draws a failed call's output itself.
    local built = bone.ui.tool_content(item, ctx)
    return { title = title, body = not item.is_error and built.body or nil }
  end
  local lines, n = {}, 0
  for line in (tostring(item.output or "") .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n <= (ctx.tool_expanded and 200 or 5) then lines[n] = line end
  end
  if n > #lines then lines[#lines + 1] = "⋮ +" .. (n - #lines) .. " more lines" end
  return { title = title, lines = item.done and lines or nil }
end

local function mcp_call_view(item, ctx)
  local a = type(item.arguments) == "table" and item.arguments or {}
  local inner = a.arguments
  if type(inner) ~= "table" then
    inner = {}
    for k, v in pairs(a) do
      if k ~= "server" and k ~= "tool" and k ~= "arguments" then inner[k] = v end
    end
  end
  return call_content(item, ctx, a.server, a.tool, inner)
end

local seen = {} -- server -> its state when last looked at
local views = {} -- the model's name for a tool -> the view drawn for it here
local alive, round = true, 0

-- What changed since the servers were last looked at: say when one needs a
-- sign-in, fails or is back, and draw the tools called by their own names.
observe = function(list)
  local now = {}
  for _, s in ipairs(list or {}) do
    now[s.name] = s.state
    local was = seen[s.name]
    if was ~= s.state then
      if s.state == "auth" then
        bone.notify("mcp: " .. s.name .. " needs a sign-in (/mcp)")
      elseif s.state == "failed" then
        bone.notify("mcp: " .. s.name .. " failed" .. (s.error and (": " .. brief(s.error, 120)) or "") .. " (/mcp)", "error")
      elseif s.state == "ready" and (was == "auth" or was == "failed") then
        bone.notify("mcp: " .. s.name .. " is back")
      end
    end
  end
  seen = now
  local want = {}
  for _, s in ipairs(list or {}) do
    for i, name in ipairs(s.tools or {}) do
      local info = (s.tool_info or {})[i]
      if info then want[name] = { server = s.name, tool = info.name } end
    end
  end
  -- A server that is down keeps the views of its tools: its calls are still in the chat.
  for name, ref in pairs(want) do
    if not views[name] and bone.ui.tool_views[name] == nil then
      views[name] = function(item, ctx)
        return call_content(item, ctx, ref.server, ref.tool, item.arguments)
      end
      bone.ui.tool_views[name] = views[name]
    end
  end
end

local function watch()
  round = round + 1
  local mine = round
  bone.request("mcp/list", {}, function(list)
    if not alive or mine ~= round then return end
    if not list then return end
    observe(list)
    -- Nothing to watch without servers; a reload starts it again.
    if #list == 0 then return end
    local busy = false
    for _, s in ipairs(list) do busy = busy or s.state == "starting" end
    bone.defer(busy and 2000 or 10000, function()
      if alive and mine == round then watch() end
    end)
  end)
end

bone.ui.tool_views.mcp_call = mcp_call_view

bone.ui.new_chat.mcp = function()
  local names, lines = {}, {}
  for name in pairs(seen) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if seen[name] == "auth" then
      lines[#lines + 1] = { { "MCP: " .. name .. " needs a sign-in · /mcp", "WarningMsg" } }
    elseif seen[name] == "failed" then
      lines[#lines + 1] = { { "MCP: " .. name .. " failed · /mcp", "ErrorMsg" } }
    end
  end
  return lines
end

bone.on("ready", watch)
bone.on("core/reloaded", watch)
bone.on("tool/finished", function(ev)
  -- A sign-in that ran out shows up as a failed call: look now, not in a while.
  if ev and ev.is_error and next(seen) ~= nil then watch() end
end)

bone.plugin.on_shutdown(function()
  alive = false
  if bone.ui.tool_views.mcp_call == mcp_call_view then bone.ui.tool_views.mcp_call = nil end
  for name, fn in pairs(views) do
    if bone.ui.tool_views[name] == fn then bone.ui.tool_views[name] = nil end
  end
  bone.ui.new_chat.mcp = nil
end)
