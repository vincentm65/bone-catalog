-- mcp, core side: which MCP servers run, and how their tools reach the model.
--
--   bone.config.mcp_files = { "~/.config/mcp.json", ".mcp.json" }   -- relative to the config dir
--   bone.config.mcp_options = { lazy = true }                        -- for every server they add
--
-- An entry of such a file may carry its own "tools" ({ allow, deny }),
-- "lazy" and "timeout". A bad entry is skipped and shown in /health; the
-- rest of the file still loads.
--
-- A lazy server starts with the first message. Where the core can leave
-- that to a plugin (bone.mcp.start), it starts when one of its tools is
-- first called instead, as long as its tools are remembered from an earlier
-- run and all of them load on demand (see `needed`).
--
-- Tools on demand. Every tool definition of every server rides along with
-- each request, and a few servers add up to thousands of tokens. Past
-- `mcp.on_demand_above` tokens (setting `mcp.on_demand`: auto, on, off) the
-- model gets two tools in their place: mcp_search, whose description names
-- every server's tools and which answers with descriptions and argument
-- schemas, and mcp_call, which runs one. What the model is sent then stays
-- the same while servers start, stop and restart, so a provider's prompt
-- cache survives them. A tool pinned in /mcp keeps its own definition; one
-- turned off there reaches the model in neither form.

bone.config.mcp_files = {}

local ABOVE = 2000 -- tokens of definitions before "auto" loads them on demand
local MAX_OUTPUT = 40000 -- bytes of one result the model is given
local FULL, ALSO, LISTED, NAMED = 5, 15, 150, 40 -- how much mcp_search says
local META = 1100 -- bytes of the two tools' own definitions, about

local problems = {} -- what went wrong reading the files
local policy = bone.state.load("mcp-policy") -- server -> tool -> "off" | "pin"
local cache = bone.state.load("mcp-tools") -- server -> tool -> { description, parameters, read_only, visible, chars }
local visible = {} -- the model's name for a tool -> { server, tool }
local shown = {} -- session -> "server/tool" -> true: the schemas it has been given
if type(policy) ~= "table" then policy = {} end
if type(cache) ~= "table" then cache = {} end
-- Only what this file wrote: a hand-edited entry of another shape is forgotten.
for server, tools in pairs(cache) do
  if type(tools) ~= "table" then
    cache[server] = nil
  else
    for tool, e in pairs(tools) do
      if type(e) ~= "table" then tools[tool] = nil end
    end
  end
end

local function setting(key)
  return bone.settings.get("mcp." .. key)
end

local function mode()
  local m = setting("on_demand")
  return (m == "on" or m == "off") and m or "auto"
end

local function above()
  return tonumber(setting("on_demand_above")) or ABOVE
end

local function state_of(server, tool)
  local p = policy[server]
  local s = type(p) == "table" and p[tool] or nil
  return (s == "off" or s == "pin") and s or nil
end

local function sorted(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- `s` up to byte `i`, ending on a whole character.
local function head(s, i)
  while i > 0 do
    local b = s:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return s:sub(1, i)
end

-- `s` from byte `i`, starting on a whole character.
local function tail(s, i)
  while true do
    local b = s:byte(i)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i + 1
  end
  return s:sub(i)
end

local function brief(text, max)
  text = tostring(text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #text <= max then return text end
  return head(text, max - 1) .. "…"
end

-- ---- the servers --------------------------------------------------------------

-- Add the servers of a JSON file in the common "mcpServers" format, each
-- with its own options over `opts`.
local function load(path, opts, optional)
  local f = io.open((path:gsub("^~", os.getenv("HOME") or "~")), "r")
  if not f then
    if not optional then problems[#problems + 1] = "cannot open " .. path end
    return
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(bone.json.decode, text)
  if not ok or type(data) ~= "table" then
    problems[#problems + 1] = "cannot parse " .. path
    return
  end
  opts = type(opts) == "table" and opts or {}
  local servers = data.mcpServers or data.servers
  for _, name in ipairs(sorted(type(servers) == "table" and servers or {})) do
    local spec = servers[name]
    if type(spec) == "table" and not spec.disabled then
      local lazy = spec.lazy
      if lazy == nil then lazy = opts.lazy end
      local added, err = pcall(bone.mcp.add, name, spec, {
        tools = type(spec.tools) == "table" and spec.tools or opts.tools,
        lazy = lazy,
        -- Not started for a turn by the core: `needed` says when.
        on_call = lazy and bone.mcp.start ~= nil or nil,
        timeout = tonumber(spec.timeout) or opts.timeout,
        client_id = spec.client_id or opts.client_id,
      })
      if not added then
        problems[#problems + 1] = path .. ": " .. tostring(name) .. ": " .. tostring(err):gsub("^.-:%d+: ", "")
      end
    end
  end
end

-- The servers as they are now, by name. What a ready one offers replaces
-- what was remembered of it; a server that is down keeps its last tools, so
-- the model is told the same while it restarts. True when the memory changed.
local function sync()
  local ok, list = pcall(bone.mcp.list)
  local live, dirty = {}, false
  for _, s in ipairs(ok and type(list) == "table" and list or {}) do
    live[s.name] = s
    if s.state == "ready" then
      local old, new, names = cache[s.name] or {}, {}, s.tools or {}
      for i, info in ipairs(s.tool_info or {}) do
        local e = old[info.name] or {}
        local desc, ro = info.description or "", info.read_only and true or nil
        if e.description ~= desc or e.visible ~= names[i] or e.read_only ~= ro then
          e.description, e.visible, e.read_only, dirty = desc, names[i], ro, true
        end
        new[info.name] = e
      end
      for name in pairs(old) do
        dirty = dirty or new[name] == nil
      end
      cache[s.name] = new
    end
  end
  for name in pairs(cache) do
    if not live[name] then cache[name], dirty = nil, true end
  end
  visible = {}
  for server, tools in pairs(cache) do
    for tool, e in pairs(tools) do
      if e.visible then visible[e.visible] = { server = server, tool = tool } end
    end
  end
  return live, dirty
end

local function remember(dirty)
  if dirty then pcall(bone.state.save, "mcp-tools", cache) end
end

-- The server's tool a definition is of: { server, tool }, and what is
-- remembered of it. A built-in or Lua tool of the same name is not one (the
-- core sends that in its place), and reads differently.
local function tool_of(t)
  local ref = visible[t.name]
  local e = ref and cache[ref.server] and cache[ref.server][ref.tool]
  if e and (t.description or "") == (e.description or "") then return ref, e end
end

-- An empty table the core made from a JSON list, which it writes as a list
-- again: it marks those with a metatable. An older core marks none.
local function list(t)
  return getmetatable(t) ~= nil
end

-- Lua has one empty table where JSON has `[]` and `{}`, and a schema that
-- has been through a hook comes out with `"required": {}` unless the core
-- marks its lists. Drop the unmarked empty lists a schema can do without,
-- in place; `names` when the keys of `node` are a schema's own names (its
-- properties) and not keywords.
local LISTS = { required = true, enum = true, anyOf = true, oneOf = true, allOf = true, examples = true, type = true }
local MAPS = { properties = true, patternProperties = true, definitions = true, ["$defs"] = true }
local function tidy(node, names)
  for key, value in pairs(node) do
    if type(value) == "table" then
      if next(value) == nil and not names and LISTS[key] and not list(value) then
        node[key] = nil
      else
        tidy(value, not names and MAPS[key] or false)
      end
    end
  end
end

-- Keep the schemas of the definitions about to be sent: the only place the
-- core hands them over. True when one is new or changed.
local function capture(tools)
  local dirty = false
  for _, t in ipairs(tools or {}) do
    local _, e = tool_of(t)
    if e and type(t.parameters) == "table" then
      tidy(t.parameters)
      local chars = #t.name + #(t.description or "") + #bone.json.encode(t.parameters)
      if e.chars ~= chars or e.parameters == nil then
        e.parameters, e.chars, dirty = t.parameters, chars, true
      end
    end
  end
  return dirty
end

-- A definition's size in bytes (a guess until its schema has been seen).
local function cost(tool, e)
  return e.chars or (#tool + #(e.description or "") + 120)
end

-- Bytes of the definitions that are on, of those among them that can load
-- on demand, and how many those are.
local function sizes()
  local all, lazy, n = 0, 0, 0
  for server, tools in pairs(cache) do
    for tool, e in pairs(tools) do
      local st = state_of(server, tool)
      if st ~= "off" then
        local c = cost(tool, e)
        all = all + c
        if st ~= "pin" then lazy, n = lazy + c, n + 1 end
      end
    end
  end
  return all, lazy, n
end

local function on_demand()
  local m = mode()
  local _, lazy, n = sizes()
  if m == "off" or n == 0 then return false end
  return m == "on" or lazy / 4 > above()
end

-- ---- finding tools --------------------------------------------------------------

local SEARCH = "Look up the tools of the connected MCP servers. Their definitions are not loaded "
  .. "until you ask: give words to match, or tool names, and get each tool's description and "
  .. "argument schema; then run it with mcp_call. An empty query lists every tool."

-- The tools mcp_call reaches, by server: names only, so the description
-- changes when a server's tools do and not when it restarts.
local function index()
  local lines = {}
  for _, server in ipairs(sorted(cache)) do
    local names = {}
    for _, tool in ipairs(sorted(cache[server])) do
      if state_of(server, tool) == nil then names[#names + 1] = tool end
    end
    if #names > 0 then
      local more = #names - NAMED
      lines[#lines + 1] = "- " .. server .. ": " .. table.concat(names, ", ", 1, math.min(#names, NAMED))
        .. (more > 0 and (", and " .. more .. " more") or "")
    end
  end
  return #lines > 0 and ("\n\nServers and their tools:\n" .. table.concat(lines, "\n")) or ""
end

-- Every name a tool may be asked for by -> the tools it can mean.
local function aliases()
  local map = {}
  local function add(key, ref)
    local l = map[key] or {}
    for _, have in ipairs(l) do
      if have == ref then return end
    end
    l[#l + 1] = ref
    map[key] = l
  end
  for server, tools in pairs(cache) do
    for tool, e in pairs(tools) do
      if state_of(server, tool) ~= "off" then
        local ref = { server = server, tool = tool, e = e }
        add(tool, ref)
        for _, sep in ipairs({ "/", ".", ":", "_", "__" }) do add(server .. sep .. tool, ref) end
        add("mcp__" .. server .. "__" .. tool, ref)
        if e.visible then add(e.visible, ref) end
      end
    end
  end
  return map
end

-- The tools matching `query`'s words, best first; all of them without any.
local function rank(query, only)
  local terms = {}
  for w in query:lower():gmatch("%w+") do terms[#terms + 1] = w end
  local hits = {}
  for server, tools in pairs(cache) do
    if not only or only == server then
      for tool, e in pairs(tools) do
        if state_of(server, tool) ~= "off" then
          local name, desc, score = tool:lower(), (e.description or ""):lower(), 0
          for _, term in ipairs(terms) do
            local stem = #term > 3 and (term:gsub("s$", "")) or term
            if name == term then
              score = score + 8
            elseif name:find(stem, 1, true) then
              score = score + 4
            end
            if server:lower():find(term, 1, true) then score = score + 1 end
            if desc:find(stem, 1, true) then score = score + 1 end
          end
          if score > 0 or #terms == 0 then
            hits[#hits + 1] = { server = server, tool = tool, e = e, score = score }
          end
        end
      end
    end
  end
  table.sort(hits, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.server ~= b.server then return a.server < b.server end
    return a.tool < b.tool
  end)
  return hits
end

local function schema_of(e)
  if type(e.parameters) ~= "table" then return nil end
  local copy = {}
  for k, v in pairs(e.parameters) do
    if k ~= "$schema" then copy[k] = v end
  end
  return bone.json.encode(copy)
end

local function seen(session, ref)
  local s = shown[session or ""] or {}
  shown[session or ""] = s
  local key = ref.server .. "/" .. ref.tool
  local before = s[key] == true
  s[key] = true
  return before
end

-- A tool in full: what mcp_call needs to run it.
local function describe(ref, session)
  seen(session, ref)
  local out = { "[" .. ref.server .. "] " .. ref.tool }
  local desc = (ref.e.description or ""):match("^%s*(.-)%s*$")
  if desc ~= "" then out[#out + 1] = desc end
  if state_of(ref.server, ref.tool) == "pin" and ref.e.visible then
    out[#out + 1] = "(already loaded: call it as " .. ref.e.visible .. ")"
  end
  out[#out + 1] = "arguments: " .. (schema_of(ref.e) or "(not known yet: its server has not connected since it was added)")
  return table.concat(out, "\n")
end

local function one_line(ref)
  local d = brief(ref.e.description, 100)
  return "- [" .. ref.server .. "] " .. ref.tool .. (d ~= "" and (": " .. d) or "")
end

local HOW = 'Run one with mcp_call: { "server": "…", "tool": "…", "arguments": { … } }'

local function search(args, ctx)
  args, ctx = type(args) == "table" and args or {}, ctx or {}
  remember(select(2, sync()))
  local query = type(args.query) == "string" and args.query:match("^%s*(.-)%s*$") or ""
  local only = type(args.server) == "string" and args.server ~= "" and args.server or nil
  if only and not cache[only] then
    return nil, "no MCP server named " .. only .. " (servers: " .. table.concat(sorted(cache), ", ") .. ")"
  end
  local limit = math.max(1, math.min(10, math.floor(tonumber(args.limit) or FULL)))

  -- Tool names, each one known: those tools, in full.
  local map, exact, any = aliases(), {}, false
  for token in query:gmatch("[^%s,]+") do
    any = true
    local found = {}
    for _, ref in ipairs(map[token] or {}) do
      if not only or ref.server == only then found[#found + 1] = ref end
    end
    if #found == 0 then
      exact = nil
      break
    end
    for _, ref in ipairs(found) do exact[#exact + 1] = ref end
  end
  if any and exact then
    local out = {}
    for i = 1, math.min(#exact, 10) do out[#out + 1] = describe(exact[i], ctx.session_id) end
    out[#out + 1] = HOW
    return table.concat(out, "\n\n")
  end

  local hits = rank(query, only)
  if #hits == 0 then
    local counts = {}
    for _, server in ipairs(sorted(cache)) do
      local n = 0
      for tool in pairs(cache[server]) do
        if state_of(server, tool) ~= "off" then n = n + 1 end
      end
      counts[#counts + 1] = server .. " (" .. plural(n, "tool") .. ")"
    end
    return "No MCP tool matches " .. string.format("%q", query) .. ". Servers: "
      .. (#counts > 0 and table.concat(counts, ", ") or "none connected yet")
      .. ". Try other words, or an empty query to list every tool."
  end
  local out = {}
  if query == "" then
    for i = 1, math.min(#hits, LISTED) do out[#out + 1] = one_line(hits[i]) end
    if #hits > LISTED then
      out[#out + 1] = "… and " .. (#hits - LISTED) .. " more: narrow it with a query or `server`."
    end
    out[#out + 1] = "\nAsk again with a tool's name for its argument schema."
    return table.concat(out, "\n")
  end
  for i = 1, math.min(#hits, limit) do out[#out + 1] = describe(hits[i], ctx.session_id) end
  if #hits > limit then
    local also = { "Also matching:" }
    for i = limit + 1, math.min(#hits, limit + ALSO) do also[#also + 1] = one_line(hits[i]) end
    out[#out + 1] = table.concat(also, "\n")
  end
  out[#out + 1] = HOW
  return table.concat(out, "\n\n")
end

-- ---- running tools --------------------------------------------------------------

local function kind(v)
  if v == bone.json.null then return "null" end
  if type(v) ~= "table" then return type(v) end
  return (v[1] ~= nil or next(v) == nil) and "an array" or "an object"
end

local function fits(want, v)
  local t = type(v)
  if want == "string" or want == "boolean" then return t == want end
  if want == "number" then return t == "number" end
  if want == "integer" then return t == "number" and v % 1 == 0 end
  if want == "array" then return t == "table" and (v[1] ~= nil or next(v) == nil) end
  if want == "object" then return t == "table" and v[1] == nil end
  return true
end

-- What is plainly wrong with `args` for a tool with `schema`, or nil: only
-- the top level, and only what its server would refuse too.
local function wrong(schema, args)
  if type(schema) ~= "table" then return nil end
  local missing = {}
  for _, key in ipairs(type(schema.required) == "table" and schema.required or {}) do
    if args[key] == nil then missing[#missing + 1] = tostring(key) end
  end
  if #missing > 0 then
    return "missing " .. (#missing == 1 and "argument " or "arguments ") .. table.concat(missing, ", ")
  end
  local props = type(schema.properties) == "table" and schema.properties or nil
  if not props then return nil end
  local unknown = {}
  for _, key in ipairs(sorted(args)) do
    local p, v = props[key], args[key]
    if p == nil then
      unknown[#unknown + 1] = tostring(key)
    elseif type(p) == "table" and type(p.type) == "string" and v ~= bone.json.null and not fits(p.type, v) then
      return "argument " .. tostring(key) .. " must be " .. p.type .. ", not " .. kind(v)
    end
  end
  if #unknown > 0 and schema.additionalProperties == false then
    return "unknown " .. (#unknown == 1 and "argument " or "arguments ") .. table.concat(unknown, ", ")
      .. " (it takes: " .. table.concat(sorted(props), ", ") .. ")"
  end
  return nil
end

-- The same one empty table, in a call's arguments: an empty list the core
-- did not mark would reach the server as `{}`. Leave out the ones the schema
-- calls arrays (and does not require), in place and in the objects under
-- them.
local function without_empty_lists(schema, args)
  local props = type(schema) == "table" and type(schema.properties) == "table" and schema.properties or nil
  if not props then return end
  local required = {}
  for _, key in ipairs(type(schema.required) == "table" and schema.required or {}) do required[key] = true end
  for key, value in pairs(args) do
    local p = props[key]
    if type(value) == "table" and type(p) == "table" then
      if next(value) == nil then
        if p.type == "array" and not required[key] and not list(value) then args[key] = nil end
      elseif p.type == "object" then
        without_empty_lists(p, value)
      end
    end
  end
end

-- A result the model can afford: the start and the end of a long one, the
-- whole of it in a file it can read.
local function cap(text, id)
  local max = tonumber(setting("max_output")) or MAX_OUTPUT
  if max <= 0 or #text <= max then return text end
  local last = math.min(2000, math.floor(max / 5))
  local first = max - last
  local dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local path = dir .. "/bone-mcp-" .. tostring(id or os.time()):gsub("[^%w_%-]", "_") .. ".txt"
  local f = io.open(path, "w")
  if f then
    f:write(text)
    f:close()
  end
  return head(text, first)
    .. "\n\n[… the output is " .. #text .. " bytes; this is its first " .. first .. " and last " .. last .. "."
    .. (f and (" All of it is in " .. path .. ": read parts with read_file or search it with the shell.")
      or " Ask for less at a time.")
    .. " …]\n\n"
    .. tail(text, #text - last + 1)
end

-- Why a server cannot be used now, for the model.
local function unavailable(server, live)
  local s = live[server]
  if not s then return "MCP server " .. server .. " is not configured any more." end
  if s.state == "auth" then
    return "MCP server " .. server .. " needs the user to sign in (they can with /mcp)."
  end
  return "MCP server " .. server .. " is not running (" .. tostring(s.state)
    .. (s.error and (": " .. s.error) or "") .. "). Its tools are back when it is; the user can check it with /mcp."
end

local function locate(server, tool)
  if type(tool) ~= "string" or tool == "" then
    return nil, "mcp_call needs `tool`: a tool's name, as mcp_search gives it"
  end
  server = type(server) == "string" and server ~= "" and server or nil
  if server and cache[server] and cache[server][tool] then
    if state_of(server, tool) == "off" then
      return nil, tool .. " is turned off for the " .. server .. " server (the user can turn it on in /mcp)."
    end
    return { server = server, tool = tool, e = cache[server][tool] }
  end
  local found = aliases()[tool] or {}
  if server then
    local there = {}
    for _, ref in ipairs(found) do
      if ref.server == server then there[#there + 1] = ref end
    end
    if #there > 0 then found = there end
  end
  if #found == 1 then return found[1] end
  if #found > 1 then
    local on = {}
    for _, ref in ipairs(found) do on[#on + 1] = ref.server end
    return nil, tool .. " is a tool of several servers (" .. table.concat(on, ", ") .. "): say which with `server`."
  end
  local near, names = rank(tool, server and cache[server] and server or nil), {}
  for i = 1, math.min(#near, 5) do names[#names + 1] = "[" .. near[i].server .. "] " .. near[i].tool end
  return nil, "No MCP tool named " .. tool .. (server and (" on " .. server) or "") .. "."
    .. (#names > 0 and (" Close: " .. table.concat(names, ", ") .. ".") or "")
    .. " Find tools with mcp_search."
end

local function call(args, ctx)
  args, ctx = type(args) == "table" and args or {}, ctx or {}
  local live, dirty = sync()
  remember(dirty)
  local ref, why = locate(args.server, args.tool)
  if not ref then return nil, why end
  local name = "[" .. ref.server .. "] " .. ref.tool

  local a = args.arguments
  if a == bone.json.null then a = nil end
  if type(a) == "string" then
    local ok, decoded = pcall(bone.json.decode, a)
    if not ok or type(decoded) ~= "table" then
      return nil, "`arguments` must be an object (the tool's arguments), not a string"
    end
    a = decoded
  elseif a == nil then
    -- Arguments given beside `server` and `tool` instead of under `arguments`.
    a = {}
    for k, v in pairs(args) do
      if k ~= "server" and k ~= "tool" then a[k] = v end
    end
  end
  if type(a) ~= "table" or a[1] ~= nil then
    return nil, "`arguments` must be an object: the tool's arguments by name"
  end

  -- The schema once, with whatever went wrong, for a model that guessed.
  local function with_schema(text)
    local schema = schema_of(ref.e)
    if seen(ctx.session_id, ref) or not schema then return text end
    return text .. "\n\n" .. name .. " takes: " .. schema
  end

  local problem = wrong(ref.e.parameters, a)
  if problem then return nil, with_schema(name .. ": " .. problem) end
  without_empty_lists(ref.e.parameters, a)
  local ok, r = pcall(bone.mcp.call, ref.server, ref.tool, next(a) ~= nil and a or nil)
  if not ok then
    local s = live[ref.server]
    if not s or s.state ~= "ready" then
      live = sync()
      if not live[ref.server] or live[ref.server].state ~= "ready" then
        return nil, unavailable(ref.server, live)
      end
    end
    return nil, name .. ": " .. tostring(r):gsub("^.-:%d+: ", "")
  end
  local text = cap(tostring(r.text or ""), ctx.call_id)
  if r.is_error then return nil, with_schema(text ~= "" and text or (name .. " failed without saying why")) end
  return text ~= "" and text or "(no output)"
end

-- ---- what the model is sent -------------------------------------------------

-- A tool turned off is not run, whoever asks for it by its own name. Added
-- once there is one to refuse: a hook on every call of every tool otherwise.
local guarded = false
local function guard()
  if guarded then return end
  local any = false
  for _, tools in pairs(policy) do
    for _, state in pairs(type(tools) == "table" and tools or {}) do any = any or state == "off" end
  end
  if not any then return end
  guarded = true
  bone.hook("tool_call", function(ev)
    local m = ev.mcp
    if type(m) == "table" and state_of(m.server, m.tool) == "off" then
      return { deny = tostring(m.tool) .. " is turned off for the " .. tostring(m.server)
        .. " server (the user can turn it on in /mcp)." }
    end
  end)
end

-- Whether a server that waits for its first call has to be up for the turn
-- after all: its tools (or their schemas) are not known yet, the definitions
-- are sent as they are, or one of them is pinned. All of that comes from the
-- server itself.
local function needed(server)
  local tools = cache[server]
  if type(tools) ~= "table" or next(tools) == nil or not on_demand() then return true end
  for tool, e in pairs(tools) do
    local st = state_of(server, tool)
    if st == "pin" or (st ~= "off" and e.parameters == nil) then return true end
  end
  return false
end

local function activate()
  if bone.mcp.start then
    bone.hook("turn_start", function()
      local ok, servers = pcall(bone.mcp.list)
      for _, s in ipairs(ok and type(servers) == "table" and servers or {}) do
        if s.state == "idle" and needed(s.name) then pcall(bone.mcp.start, s.name) end
      end
    end)
  end

  bone.tool.register({
    name = "mcp_search",
    description = SEARCH,
    parallel = true,
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "Words to look for in tool names and descriptions, or tool names. Empty lists every tool." },
        server = { type = "string", description = "Only this server's tools." },
        limit = { type = "integer", description = "How many tools to give in full (default 5, at most 10)." },
      },
    },
    run = search,
  })

  bone.tool.register({
    name = "mcp_call",
    description = "Run a tool of an MCP server. Look it up with mcp_search first: `arguments` must follow the schema that gives.",
    parameters = {
      type = "object",
      properties = {
        server = { type = "string", description = "The server's name." },
        tool = { type = "string", description = "The tool's name on that server." },
        arguments = { type = "object", description = "The tool's arguments, as its schema says." },
      },
      required = { "server", "tool" },
    },
    run = call,
  })

  bone.hook("request", function(ev)
    local _, dirty = sync()
    remember(capture(ev.tools) or dirty)
    local lazy = on_demand()
    local out = {}
    for _, t in ipairs(ev.tools or {}) do
      local ref, keep = tool_of(t), true
      if t.name == "mcp_search" or t.name == "mcp_call" then
        keep = lazy
        if keep and t.name == "mcp_search" then t.description = SEARCH .. index() end
      elseif ref then
        local st = state_of(ref.server, ref.tool)
        keep = st ~= "off" and (not lazy or st == "pin")
      end
      if keep then out[#out + 1] = t end
    end
    return { tools = out }
  end)

  guard()

  -- Tools called by their own names: the same limit on long results, and a
  -- reason when their server is down (the core only says "unknown tool").
  bone.hook("tool_result", function(ev)
    local ref = visible[ev.name]
    if not ref or type(ev.output) ~= "string" then return end
    if ev.is_error and ev.output:find("^Unknown tool") then
      return { output = unavailable(ref.server, (sync())) }
    end
    local text = cap(ev.output, ev.id)
    if text ~= ev.output then return { output = text } end
  end)
end

-- ---- for /mcp -------------------------------------------------------------------

-- A schema's arguments: { name, type, required }, the required ones first.
local function arguments_of(schema)
  if type(schema) ~= "table" or type(schema.properties) ~= "table" then return nil end
  local required = {}
  for _, key in ipairs(type(schema.required) == "table" and schema.required or {}) do required[key] = true end
  local out = {}
  for _, key in ipairs(sorted(schema.properties)) do
    local p = schema.properties[key]
    local t = type(p) == "table" and p.type or nil
    if type(t) == "table" then t = table.concat(t, " | ") end
    if type(p) == "table" and type(p.enum) == "table" then t = "one of " .. #p.enum end
    out[#out + 1] = { name = tostring(key), type = type(t) == "string" and t or "any", required = required[key] or nil }
  end
  table.sort(out, function(a, b)
    if (a.required or false) ~= (b.required or false) then return a.required == true end
    return a.name < b.name
  end)
  return out
end

local function tokens(bytes)
  return math.ceil(bytes / 4)
end

-- How tools are loaded, and every remembered tool with its size and state.
local function info()
  remember(select(2, sync()))
  local all, lazy = sizes()
  local deferred = on_demand()
  local out = {
    mode = mode(), on_demand = deferred, above = above(),
    tokens = tokens(all),
    sent = tokens(deferred and (all - lazy + META + #index()) or all),
    servers = {},
  }
  for server, tools in pairs(cache) do
    local s, bytes = { tools = {} }, 0
    for _, tool in ipairs(sorted(tools)) do
      local e = tools[tool]
      local st = state_of(server, tool) or "on"
      if st ~= "off" then bytes = bytes + cost(tool, e) end
      s.tools[#s.tools + 1] = {
        name = tool, state = st, tokens = tokens(cost(tool, e)), description = e.description,
        read_only = e.read_only, args = arguments_of(e.parameters),
      }
    end
    s.tokens = tokens(bytes)
    out.servers[server] = s
  end
  return out
end

bone.rpc.register("mcp.info", info)

--- { server, tool, state = "on" | "off" | "pin" }: how one tool reaches the model.
bone.rpc.register("mcp.set", function(args)
  args = type(args) == "table" and args or {}
  local server, tool, state = args.server, args.tool, args.state
  assert(type(server) == "string" and type(tool) == "string", "mcp.set: { server, tool, state }")
  assert(state == "on" or state == "off" or state == "pin", "mcp.set: state is on, off or pin")
  local p = type(policy[server]) == "table" and policy[server] or {}
  p[tool] = state ~= "on" and state or nil
  policy[server] = next(p) ~= nil and p or nil
  local ok, err = pcall(bone.state.save, "mcp-policy", policy)
  if not ok then error("cannot save the tool's state: " .. tostring(err), 0) end
  guard()
  return info()
end)

bone.on_ready(function()
  -- The TUI's /mcp-add command keeps its small, user-owned config here.
  load(bone.config_dir .. "/mcp.json", bone.config.mcp_options, true)
  for _, file in ipairs(bone.config.mcp_files or {}) do
    local path = file
    if not path:match("^[/~]") then
      path = bone.config_dir .. "/" .. path
    end
    load(path, bone.config.mcp_options)
  end
  for _, problem in ipairs(problems) do print("mcp plugin: " .. problem) end
  local configured = type(bone._mcp) ~= "table" or next(bone._mcp) ~= nil
  if #problems > 0 or configured then
    bone.health("mcp tools", function()
      if #problems > 0 then return "warn", table.concat(problems, "; ") end
      local i = info()
      if i.tokens == 0 then return "ok", "no tools known yet" end
      return "ok", (i.on_demand and "on demand" or "all loaded") .. " (" .. i.mode .. "): about " .. i.sent
        .. " of " .. i.tokens .. " tokens of definitions in each request"
    end)
  end
  -- Without servers nothing is added to what the model is sent.
  if configured then activate() end
end)
