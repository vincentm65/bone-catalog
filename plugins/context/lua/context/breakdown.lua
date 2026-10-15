-- Pure accounting: no model calls, transcript writes, or provider dependencies.
local M = {}
local labels = {
  { "system", "System prompt" }, { "summary", "Compaction summary" },
  { "user", "User messages" }, { "assistant", "Assistant messages" },
  { "reasoning", "Reasoning (potential replay)" }, { "calls", "Tool calls" },
  { "results", "Tool results" }, { "definitions", "Tool schemas" },
  { "images", "Images (allowance)" },
}
local function size(s) return type(s) == "string" and #s or 0 end
-- Bytes per token: 4 until a provider's count for this conversation calibrates it.
M.BYTES_PER_TOKEN = 4
function M.tokens(bytes, per) return math.floor((bytes or 0) / (per or M.BYTES_PER_TOKEN) + 0.5) end
-- What a call acts on, for its glimpse: "write_file lua/x.lua", "shell git status".
local TARGETS = { "path", "file_path", "command", "cmd", "pattern", "query", "url", "name", "prompt" }
local function call_glimpse(c)
  local args = c.arguments
  if type(args) == "string" then
    local ok, decoded = pcall(bone.json.decode, args)
    args = ok and decoded or nil
  end
  if type(args) == "table" then
    for _, key in ipairs(TARGETS) do
      if type(args[key]) == "string" and args[key] ~= "" then return tostring(c.name) .. " " .. args[key] end
    end
  end
  return tostring(c.name)
end
-- A one-line glimpse of a message (current view only; nothing is kept).
local function glimpse(m)
  local s = type(m.content) == "string" and m.content or ""
  if s:match("^%s*$") then
    local calls = {}
    for _, c in ipairs(m.tool_calls or {}) do calls[#calls + 1] = call_glimpse(c) end
    s = #calls > 0 and ("→ " .. table.concat(calls, " · ")) or (#(m.images or {}) > 0 and "[image]" or "")
  end
  local cut = #s > 400
  s = s:sub(1, 400):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #s > 160 then s, cut = s:sub(1, 160), true end
  -- Do not end inside a UTF-8 sequence.
  if cut then s = s:gsub("[\192-\255][\128-\191]*$", "") end
  return s
end
function M.new()
  local d = { rows = {}, tools = {}, largest = {}, bytes = 0, messages = 0, image_count = 0 }
  for _, spec in ipairs(labels) do
    d.rows[#d.rows + 1] = { key = spec[1], label = spec[2], bytes = 0, count = 0 }
  end
  return d
end
local function add(d, key, bytes, count)
  for _, row in ipairs(d.rows) do
    if row.key == key then
      row.bytes, row.count = row.bytes + bytes, row.count + (count or 1)
      d.bytes = d.bytes + bytes
      return
    end
  end
end
local function tool(d, name)
  name = name or "(unknown tool)"
  if not d.tools[name] then d.tools[name] = { name = name, definitions = 0, calls = 0, results = 0 } end
  return d.tools[name]
end
function M.definitions(tools)
  local out = {}
  for _, t in ipairs(tools or {}) do
    out[#out + 1] = { name = t.name, bytes = size(t.name) + size(t.description)
      + #bone.json.encode(t.parameters or {}) }
  end
  return out
end
function M.add_definitions(d, definitions)
  for _, t in ipairs(definitions or {}) do
    add(d, "definitions", t.bytes)
    tool(d, t.name).definitions = t.bytes
  end
end
function M.add_system(d, bytes) add(d, "system", bytes) end
function M.messages(d, messages, opts)
  opts = opts or {}
  local names = opts.names or {}
  for _, m in ipairs(messages) do
    for _, c in ipairs(m.tool_calls or {}) do names[c.id] = c.name end
  end
  for i, m in ipairs(messages) do
    local before = d.bytes
    local key = ({ system = "system", user = "user", assistant = "assistant", tool = "results" })[m.role]
    if key then add(d, key, size(m.content)) end
    if m.role == "tool" then
      local t = tool(d, names[m.call_id or m.tool_call_id])
      t.results = t.results + size(m.content)
    end
    if m.role == "assistant" then
      if opts.reasoning ~= false and size(m.reasoning) > 0 then add(d, "reasoning", size(m.reasoning)) end
      for _, c in ipairs(m.tool_calls or {}) do
        local bytes = size(c.name) + (type(c.arguments) == "table" and #bone.json.encode(c.arguments) or size(c.arguments))
        add(d, "calls", bytes)
        local t = tool(d, c.name)
        t.calls = t.calls + bytes
      end
    end
    for _, image in ipairs(m.images or {}) do
      local tiles = math.ceil((image.width or 0) / 512) * math.ceil((image.height or 0) / 512)
      add(d, "images", (85 + 170 * math.min(tiles, 256)) * 4)
      d.image_count = d.image_count + 1
    end
    d.messages = d.messages + 1
    d.largest[#d.largest + 1] = { index = i + (opts.offset or 0), role = m.role,
      name = m.role == "tool" and names[m.call_id or m.tool_call_id] or nil, bytes = d.bytes - before,
      preview = opts.preview and glimpse(m) or nil }
  end
end
function M.current(snapshot, captured, reasoning)
  local d, names, messages = M.new(), {}, {}
  for _, m in ipairs(snapshot.messages) do
    for _, c in ipairs(m.tool_calls or {}) do names[c.id] = c.name end
  end
  local summary = snapshot.summary
  local through = type(summary) == "table" and summary.through or 0
  if through > 0 then
    add(d, "summary", #("Summary of the earlier conversation:\n\n" .. summary.text))
  end
  for i = through + 1, #snapshot.messages do messages[#messages + 1] = snapshot.messages[i] end
  M.messages(d, messages, { offset = through, names = names, reasoning = reasoning, preview = true })
  if captured and captured.system_bytes then M.add_system(d, captured.system_bytes) end
  M.add_definitions(d, captured and captured.definitions)
  d.summarized, d.stored_messages = through, #snapshot.messages
  return d
end
function M.finish(d)
  d.tokens = M.tokens(d.bytes)
  table.sort(d.largest, function(a, b) return a.bytes == b.bytes and a.index < b.index or a.bytes > b.bytes end)
  local tools = {}
  for _, t in pairs(d.tools) do
    t.bytes = t.definitions + t.calls + t.results
    tools[#tools + 1] = t
  end
  table.sort(tools, function(a, b) return a.bytes == b.bytes and a.name < b.name or a.bytes > b.bytes end)
  d.tools = tools
  while #d.largest > 10 do table.remove(d.largest) end
  return d
end
return M
