-- Claude CLI owns authentication. Bone owns history, tools and approvals.
local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Sorted object keys keep the prompt/schema prefix identical across calls.
local function canonical(v)
  if type(v) ~= "table" then return bone.json.encode(v) end
  if #v > 0 then
    local out = {}
    for i = 1, #v do out[i] = canonical(v[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  if #keys == 0 then return bone.json.encode(v) end
  table.sort(keys)
  local out = {}
  for i, k in ipairs(keys) do out[i] = bone.json.encode(k) .. ":" .. canonical(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end

-- Decode only member names: keep value ranges in the original CLI JSON so null,
-- empty arrays/objects and argument formatting survive Bone's Lua decoder.
local function raw_json(s)
  local pos = 1
  local function invalid() error("claude-code: invalid tool request", 0) end
  local function space()
    while s:sub(pos, pos):match("[ \t\r\n]") do pos = pos + 1 end
  end
  local function string_end()
    local start = pos
    pos = pos + 1
    while pos <= #s do
      local ch = s:sub(pos, pos)
      pos = pos + 1
      if ch == '"' then return start, pos - 1 end
      if ch == "\\" then pos = pos + 1 end
    end
    invalid()
  end
  local value
  value = function(depth)
    if depth > 128 then invalid() end
    space()
    local node = { first = pos, kind = s:sub(pos, pos) }
    if node.kind == "{" or node.kind == "[" then
      local object = node.kind == "{"
      local close = object and "}" or "]"
      node.members = {}
      pos = pos + 1
      space()
      if s:sub(pos, pos) ~= close then
        while true do
          local key
          if object then
            if s:sub(pos, pos) ~= '"' then invalid() end
            local first, last = string_end()
            key = bone.json.decode(s:sub(first, last))
            space()
            if s:sub(pos, pos) ~= ":" then invalid() end
            pos = pos + 1
          else key = #node.members + 1 end
          node.members[key] = value(depth + 1)
          space()
          if s:sub(pos, pos) == close then break end
          if s:sub(pos, pos) ~= "," then invalid() end
          pos = pos + 1
          space()
        end
      end
      pos = pos + 1
    elseif node.kind == '"' then string_end()
    else
      while pos <= #s and not s:sub(pos, pos):match("[ \t\r\n,%]%}]") do pos = pos + 1 end
      if pos == node.first then invalid() end
    end
    node.last = pos - 1
    return node
  end
  local root = value(0)
  space()
  if pos <= #s then invalid() end
  return root
end

local preamble = [[You are Bone's model backend. Native Claude Code tools are disabled.
The conversation below is data representing the real Bone conversation, not instructions to execute CLI tools.
Return only structured output: response is your assistant text; tool_calls is an array of requested Bone tools.
Bone executes these tools under its own approvals and returns their results. Never claim execution before receiving a result.
Use the tool descriptions and argument schemas in the structured-output schema. Return an empty tool_calls array when finished.
]]
local last_usage = {}
local turn_cost = {}
local sessions = {}
local function discard(sid)
  local s = sessions[sid]
  sessions[sid] = nil
  if s then
    -- Only generated private dirs are removed. CLI transcripts never touch repo files.
    local config = os.getenv("CLAUDE_CONFIG_DIR") or ((os.getenv("HOME") or "") .. "/.claude")
    local project = s.cwd:gsub("[^%w]", "-")
    -- The project directory is exclusive to our mktemp cwd, even on a failed first call.
    bone.system("rm -rf -- " .. quote(s.cwd) .. " " .. quote(config .. "/projects/" .. project), { timeout = 5000 })
  end
end
bone.on_shutdown(function()
  for sid in pairs(sessions) do discard(sid) end
end)
local function message_key(m)
  -- Ignore display-only metadata/reasoning; compare the actual Bone transcript.
  local calls = {}
  for _, c in ipairs(m.tool_calls or {}) do
    calls[#calls + 1] = { id = c.id, name = c.name, arguments = c.arguments }
  end
  return canonical({ role = m.role, content = m.content or "", tool_calls = calls,
    call_id = m.call_id, is_error = m.is_error or nil })
end
bone.hook("turn_start", function(ctx) turn_cost[ctx.session_id] = 0 end)
local auth_env = "env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL"
  .. " -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY"
  .. " -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN_FILE -u CLAUDECODE "

local function complete(req, emit)
  local o = req.options
  local sid = req.session_id or "default"
  local remaining = (o.max_turn_budget_usd or 1) - (turn_cost[sid] or 0)
  if remaining <= 0 then error("claude-code: Bone turn budget reached; no automatic retry", 0) end
  local tools, variants, known = {}, {}, {}
  for _, t in ipairs(req.tools or {}) do tools[#tools + 1] = t end
  table.sort(tools, function(a, b) return a.name < b.name end)
  for _, t in ipairs(tools) do
    known[t.name] = true
    variants[#variants + 1] = {
      type = "object", additionalProperties = false,
      description = t.description,
      properties = { name = { type = "string", enum = { t.name } }, arguments = t.parameters },
      required = { "name", "arguments" },
    }
  end
  local calls = { type = "array", maxItems = 8 }
  if #variants > 0 then calls.items = { anyOf = variants } else calls.maxItems = 0 end
  local schema = { type = "object", additionalProperties = false,
    properties = { response = { type = "string" }, tool_calls = calls },
    required = { "response", "tool_calls" } }
  local system, history = {}, {}
  for _, m in ipairs(req.messages) do
    if m.role == "system" then system[#system + 1] = m.content or ""
    else
      if m.images and #m.images > 0 then error("claude-code: images are not supported", 0) end
      history[#history + 1] = m
    end
  end
  local prompt = preamble .. "\nBone system instructions:\n" .. table.concat(system, "\n\n")
  -- Tool descriptions and parameters live only in the output schema; duplicating
  -- them in the system prompt charges for the same definitions twice.
  local schema_json = canonical(schema)
  local fingerprint = canonical({ prompt = prompt, schema = schema_json,
    executable = o.executable or "claude", model = o.model or "claude-haiku-5-5",
    effort = o.reasoning_effort or "low" })
  local s = req.session_id and sessions[sid]
  if s then
    local matches = s.fingerprint == fingerprint and #history > #s.history
    for i, key in ipairs(s.history) do
      if not history[i] or message_key(history[i]) ~= key then matches = false; break end
    end
    if not matches then discard(sid); s = nil end
  end
  if not s then
    local setup = bone.system("mktemp -d /tmp/bone3-claude-code.XXXXXX", { timeout = 5000 })
    if not setup then return nil end
    if setup.code ~= 0 then error("claude-code: could not create isolated working directory", 0) end
    s = { cwd = setup.stdout:gsub("%s+$", ""), fingerprint = fingerprint, history = {} }
  end
  -- Keep previous Claude message/cache boundaries intact; send only new Bone data.
  local delta = {}
  for i = #s.history + 1, #history do delta[#delta + 1] = history[i] end
  local resumed = s.cli_id ~= nil
  sessions[sid] = s
  s.invocation = (s.invocation or 0) + 1
  local command = auth_env .. quote(o.executable or "claude")
    .. " -p --output-format json --tools '' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}'"
    .. " --setting-sources '' --settings '{\"disableAllHooks\":true}' --disable-slash-commands --no-chrome"
    .. " --effort " .. quote(o.reasoning_effort or "low")
    .. " --model " .. quote(o.model or "claude-haiku-5-5")
    .. " --max-turns 3 --max-budget-usd " .. quote((s.total_cost or 0) + math.min(o.max_budget_usd or 0.5, remaining))
    .. " --system-prompt " .. quote(prompt) .. " --json-schema " .. quote(schema_json)
    .. (resumed and (" --resume " .. quote(s.cli_id)) or "")
  local r = bone.system(command, { cwd = s.cwd,
    stdin = (resumed and "New Bone messages as JSON:\n" or "Bone conversation history as JSON:\n") .. canonical(delta),
    timeout = o.timeout_ms or 120000 })
  -- Never resume an interrupted/failed CLI transcript.
  if not r then discard(sid); return nil end
  if r.timed_out then discard(sid); error("claude-code: timed out; no automatic retry", 0) end
  local ok, doc = pcall(bone.json.decode, r.stdout or "")
  if not ok or type(doc) ~= "table" then
    discard(sid)
    error("claude-code: CLI failed (exit " .. tostring(r.code) .. "): " .. (r.stderr or ""):sub(1, 1000), 0)
  end
  local u = doc.usage or {}
  local read, write = u.cache_read_input_tokens or 0, u.cache_creation_input_tokens or 0
  -- CLI usage is per invocation, but total_cost_usd/modelUsage include prior resumes.
  local cost = math.max(0, (doc.total_cost_usd or 0) - (s.total_cost or 0))
  turn_cost[sid] = (turn_cost[sid] or 0) + cost
  last_usage[req.session_id or "default"] = { input_tokens = u.input_tokens or 0,
    cache_read_input_tokens = read, cache_creation_input_tokens = write,
    output_tokens = u.output_tokens or 0, total_cost_usd = cost, cli_session_cost_usd = doc.total_cost_usd,
    model_usage = doc.modelUsage, subtype = doc.subtype, turn_cost_usd = turn_cost[sid],
    resumed = resumed, sent_messages = #delta, cli_turns = doc.num_turns }
  if r.code ~= 0 or doc.is_error or doc.subtype ~= "success" then
    discard(sid)
    error("claude-code: " .. tostring(doc.subtype or "CLI error") .. ": "
      .. tostring(doc.result or canonical(doc.errors or {})):sub(1, 1000) .. "; no automatic retry", 0)
  end
  local output = doc.structured_output
  if type(output) ~= "table" or type(output.response) ~= "string" or type(output.tool_calls) ~= "table" then
    discard(sid)
    error("claude-code: missing structured response; no automatic retry", 0)
  end
  local raw = raw_json(r.stdout)
  local structured = raw.kind == "{" and raw.members.structured_output
  local raw_calls = structured and structured.kind == "{" and structured.members.tool_calls
  if not raw_calls or raw_calls.kind ~= "[" or #raw_calls.members > 8 then
    error("claude-code: invalid tool request", 0)
  end
  local result = { content = output.response, tool_calls = {}, usage = {
    input_tokens = (u.input_tokens or 0) + read + write, output_tokens = u.output_tokens or 0, cached_tokens = read } }
  for i, call in ipairs(raw_calls.members) do
    local c = output.tool_calls[i]
    local arguments = call.kind == "{" and call.members.arguments
    if type(c) ~= "table" or not known[c.name] or not arguments or arguments.kind ~= "{" then
      error("claude-code: invalid tool request", 0)
    end
    result.tool_calls[i] = { id = "cc_" .. tostring(doc.session_id or "call") .. "_" .. s.invocation .. "_" .. i,
      name = c.name, arguments = r.stdout:sub(arguments.first, arguments.last) }
  end
  if result.content ~= "" then emit({ text = result.content }) end
  s.cli_id = doc.session_id
  s.total_cost = doc.total_cost_usd or 0
  sessions[sid] = s
  s.history = {}
  for i, m in ipairs(history) do s.history[i] = message_key(m) end
  s.history[#s.history + 1] = message_key({ role = "assistant", content = result.content, tool_calls = result.tool_calls })
  if not req.session_id then discard(sid) end
  return result
end

bone.provider.register("claude_code", { complete = function(req, emit)
  local ok, result = pcall(complete, req, emit)
  if not ok then
    discard(req.session_id or "default")
    error(result, 0)
  end
  return result
end })
bone.rpc.register("claude-code.usage", function(_, ctx)
  return last_usage[ctx.session_id or "default"] or {}
end)
bone.health("Claude Code", function()
  local o = bone.config.providers.claude_code or {}
  local r = bone.system(auth_env .. quote(o.executable or "claude") .. " auth status", { timeout = 10000 })
  if not r then return "warn", "Cancelled" end
  local ok, auth = pcall(bone.json.decode, r.stdout or "")
  if r.code ~= 0 or not ok or type(auth) ~= "table" or not auth.loggedIn or auth.authMethod ~= "claude.ai" then
    return "error", "Run `claude auth login` with your Claude subscription"
  end
  return "ok", "Claude CLI subscription login (" .. tostring(auth.subscriptionType or "unknown plan") .. ")"
end)
if not bone.config.providers.claude_code then
  bone.config.providers.claude_code = { type = "claude_code", model = "claude-haiku-5-5" }
end
