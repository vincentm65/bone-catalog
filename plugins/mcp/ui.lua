-- mcp, shared UI: /mcp opens a popup to see, add, sign in to and manage MCP
-- servers: state, errors, and every tool with its description. Servers added
-- here are kept in ~/.bone/mcp.json (loaded by this plugin's core half).
-- One view for the terminal and the desktop app: servers beside the selected
-- one's details, and the Add / Reconnect / Sign in / Sign out / Enable /
-- Remove actions as keys and as buttons.
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
}
local id, st

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
  if st then
    st.note = text and { text = text, bad = bad } or nil
  end
  redraw()
end

local function message(err)
  return type(err) == "table" and tostring(err.message or err.code) or tostring(err)
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
    if spec.disabled and not seen[name] then
      out[#out + 1] = { name = name, state = "disabled", tools = {}, url = spec.url, command = spec.command }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local refresh
refresh = function()
  bone.request("mcp/list", {}, function(list, err)
    if not st then
      return
    end
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
    refresh()
  end)
end

local function request(method, name, done)
  bone.request(method, { name = name }, function(_, err)
    note(err and message(err) or done, err ~= nil)
    refresh()
  end)
end

local function sign_in(s)
  bone.request("mcp/auth", { name = s.name }, function(res, err)
    if err then
      return note(message(err), true)
    end
    st.signing = { name = s.name, url = res.url }
    if not os.getenv("SSH_TTY") and (os.getenv("DISPLAY") or os.getenv("WAYLAND_DISPLAY")) then
      bone.system("xdg-open '" .. res.url:gsub("'", "'\\''") .. "'", {}, function() end)
    end
    note(nil)
    refresh()
  end)
end

local function add(name, target, header)
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
    data.mcpServers[name] = { command = table.remove(argv, 1), args = argv }
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
    if value:match("^https?://") then
      st.input = { step = "header", name = inp.name, target = value, value = "" }
    else
      st.input = nil
      add(inp.name, value, "")
    end
  else
    st.input = nil
    add(inp.name, inp.target, value)
  end
  note(nil)
end

local function on_key(k)
  local s = st.servers[st.sel]
  if st.input then
    local inp = st.input
    if k == "esc" then
      st.input = nil
    elseif k == "enter" then
      submit()
    elseif k == "backspace" then
      inp.value = inp.value:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    elseif k == "ctrl+u" then
      inp.value = ""
    elseif k == "space" then
      inp.value = inp.value .. " "
    elseif #k == 1 or k:match("^[\194-\244][\128-\191]*$") then
      inp.value = inp.value .. k
    end
  elseif st.confirm then
    local go = k == "y" and st.confirm
    st.confirm = nil
    if go then
      go()
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
  elseif k == "r" and s and s.state ~= "disabled" then
    request("mcp/reconnect", s.name, "reconnecting " .. s.name)
  elseif (k == "s" or k == "enter") and s and s.url and s.state ~= "disabled" then
    sign_in(s)
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

-- The selected server: what it is, where it runs, and its tools.
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
  local tools = { kind = "section", title = "Tools  " .. #(s.tool_info or {}) }
  for _, t in ipairs(s.tool_info or {}) do
    tools[#tools + 1] = { kind = "row", { kind = "text", text = t.name, tone = "accent" },
      t.read_only and { kind = "badge", text = "read-only", tone = "dim" } or nil }
    local d = (t.description or ""):gsub("%s+", " ")
    if d ~= "" then tools[#tools + 1] = { kind = "text", text = d, tone = "dim" } end
  end
  if #(s.tool_info or {}) == 0 then tools[#tools + 1] = { kind = "text", text = "No tools reported.", tone = "dim" } end
  add(tools)
  return out
end

local function button(label, key, primary)
  return { kind = "button", label = label, primary = primary, on_press = function() on_key(key) end }
end

local function view()
  if not st then return nil end
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
    bar,
    not (st.input or st.confirm or st.signing)
      and { kind = "hints", text = "a add · r reconnect · s sign in · x sign out · space on/off · d remove · esc" } or nil,
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
  st = { servers = {}, sel = 1 }
  id = bone.ui.popup({ title = "MCP servers", view = view, on_key = on_key, width = 104, height = 26 })
  refresh()
end, { desc = "MCP servers: state, tools, sign-in, add and remove (mcp plugin)" })

bone.cmd.create("mcp-add", function(c)
  local argv = c.argv or {}
  if #argv < 2 or not argv[1]:match("^[%w_%-]+$") then
    return bone.notify("usage: /mcp-add NAME COMMAND [ARGS...]  or  NAME https://URL", "error")
  end
  st = st or { servers = {}, sel = 1 }
  add(argv[1], table.concat(argv, " ", 2), "")
end, { desc = "add an MCP server: /mcp-add NAME COMMAND [ARGS...] or NAME URL" })
