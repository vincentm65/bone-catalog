-- mcp, TUI side: /mcp opens a popup to see, add, sign in to and manage MCP
-- servers: state, errors, and every tool with its description. Servers added
-- here are kept in ~/.bone/mcp.json (loaded by this plugin's core half).
local FILE = bone.config_dir .. "/mcp.json"
local STATES = {
  ready = { "●", "DiffAdd", "ready" }, starting = { "◐", "WarningMsg", "starting" },
  idle = { "○", "Dim", "idle (starts on first use)" }, disabled = { "○", "Dim", "disabled" },
  auth = { "◆", "WarningMsg", "sign in needed" }, failed = { "✕", "ErrorMsg", "failed" },
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
    st.note = text and { { text, bad and "ErrorMsg" or "Dim" } } or nil
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
  elseif k == "up" or k == "k" then
    st.sel, st.tools_at, st.note = math.max(1, st.sel - 1), 0, nil
  elseif k == "down" or k == "j" then
    st.sel, st.tools_at, st.note = math.min(#st.servers, st.sel + 1), 0, nil
  elseif k == "pageup" or k == "wheelup" then
    st.tools_at = math.max(0, st.tools_at - 5)
  elseif k == "pagedown" or k == "wheeldown" then
    st.tools_at = st.tools_at + 5
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
  end
  redraw()
  return true
end

local function wrap(text, hl, width)
  return bone.text.wrap({ { text, hl } }, math.max(8, width))
end

-- The right-hand side: the selected server and its tools, `height` rows.
local function detail(s, width, height)
  local out = {}
  local function add_lines(lines)
    for _, l in ipairs(lines) do
      out[#out + 1] = l
    end
  end
  if not s then
    return wrap("No MCP servers yet. Press a to add one.", "Dim", width)
  end
  local state = STATES[s.state] or STATES.failed
  out[1] = { { s.name, "Accent" }, { "  " .. state[1] .. " " .. state[3], state[2] } }
  local where = s.url or (s.command and ("$ " .. bone.text.truncate(s.command:gsub("%s+", " "), width * 2 - 4))) or ""
  add_lines(wrap(where .. (s.signed_in and "  · signed in" or "") .. (s.lazy and "  · lazy" or ""), "Dim", width))
  if s.error then
    add_lines(wrap(s.error, "ErrorMsg", width))
  end
  if st.signing and st.signing.name == s.name then
    out[#out + 1] = {}
    add_lines(wrap("Open this address in a browser and approve. If the browser is on another machine, "
      .. "paste the address it ends up on (even if that page fails to load).", "Normal", width))
    add_lines(wrap(st.signing.url, "Accent", width))
    return out
  end
  out[#out + 1] = {}
  out[#out + 1] = { { "Tools", "Accent" }, { "  " .. #(s.tool_info or {}), "Dim" } }
  local rows = {}
  for _, t in ipairs(s.tool_info or {}) do
    rows[#rows + 1] = { { "  " .. t.name, "ToolName" }, { t.read_only and "  read-only" or "", "Dim" } }
    local d = (t.description or ""):gsub("%s+", " ")
    if d ~= "" then
      rows[#rows + 1] = { { "    " .. bone.text.truncate(d, width - 4), "Dim" } }
    end
  end
  local room = math.max(1, height - #out)
  st.tools_at = math.max(0, math.min(st.tools_at, #rows - room))
  for i = st.tools_at + 1, math.min(#rows, st.tools_at + room) do
    out[#out + 1] = rows[i]
  end
  return out
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

local function render(ctx)
  local w = math.max(48, math.min(ctx.width, 104))
  local h = math.max(8, math.min(ctx.height, 26)) - 6
  local inner = w - 4
  local lw = math.min(30, math.floor(inner / 3))
  local rw = inner - lw - 3
  local top = math.max(0, st.sel - h)
  local right = detail(st.servers[st.sel], rw, h)
  local rows = {}
  for i = 1, h do
    local s = st.servers[i + top]
    local l = {}
    if s then
      local state = STATES[s.state] or STATES.failed
      local on = i + top == st.sel
      l = {
        { (on and "› " or "  ") .. state[1] .. " ", on and "Selection" or state[2] },
        { s.name, on and "Selection" or "Normal" },
      }
    end
    local row = fit(l, lw)
    row[#row + 1] = { " │ ", "Dim" }
    for _, sp in ipairs(fit(right[i] or {}, rw)) do
      row[#row + 1] = sp
    end
    rows[i] = row
  end
  rows[#rows + 1] = { { string.rep("─", inner), "Dim" } }
  if st.input then
    rows[#rows + 1] = { { STEPS[st.input.step] .. ": ", "Accent" }, { st.input.value .. "▏", "Normal" } }
    rows[#rows + 1] = { { "enter next · esc cancel", "Dim" } }
  elseif st.confirm then
    rows[#rows + 1] = { { "Remove " .. st.servers[st.sel].name .. " from mcp.json?  y yes · any other key cancels", "WarningMsg" } }
    rows[#rows + 1] = {}
  else
    rows[#rows + 1] = st.note or {}
    rows[#rows + 1] = { { "a add · r reconnect · s sign in · x sign out · space on/off · d remove · esc", "Dim" } }
  end
  return bone.ui.box(rows, { title = "MCP servers", width = w })
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
  st = { servers = {}, sel = 1, tools_at = 0 }
  id = bone.ui.popup({ lines = render, on_key = on_key, width = 104, height = 26 })
  refresh()
end, { desc = "MCP servers: state, tools, sign-in, add and remove (mcp plugin)" })

bone.cmd.create("mcp-add", function(c)
  local argv = c.argv or {}
  if #argv < 2 or not argv[1]:match("^[%w_%-]+$") then
    return bone.notify("usage: /mcp-add NAME COMMAND [ARGS...]  or  NAME https://URL", "error")
  end
  st = st or { servers = {}, sel = 1, tools_at = 0 }
  add(argv[1], table.concat(argv, " ", 2), "")
end, { desc = "add an MCP server: /mcp-add NAME COMMAND [ARGS...] or NAME URL" })
