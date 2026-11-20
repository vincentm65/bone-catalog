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

-- A short stand-in for a long string (a message, the prompt): its length and
-- two rolling hashes. Saved sessions keep these instead of whole transcripts.
local function digest(s)
  local a, b = 5381, 0
  for i = 1, #s do
    local c = s:byte(i)
    a = (a * 33 + c) % 4294967296
    b = (b * 65599 + c) % 4294967296
  end
  return string.format("%d:%08x%08x", #s, a, b)
end

-- Scan already-decoded JSON for raw argument spans. Lua decoding alone loses
-- null/empty-collection distinctions. Syntax validation belongs to bone.json.decode.
local function raw_json(s)
  local pos = 1
  local function space()
    pos = s:find("[^ \t\r\n]", pos) or (#s + 1)
  end
  local function string_end()
    local first = pos
    pos = pos + 1
    while pos <= #s do
      local ch = s:sub(pos, pos)
      pos = pos + (ch == "\\" and 2 or 1)
      if ch == '"' then return s:sub(first, pos - 1) end
    end
    error("claude-code: invalid tool request", 0)
  end
  local function value(depth)
    if depth > 128 then error("claude-code: invalid tool request", 0) end
    space()
    local node = { first = pos, kind = s:sub(pos, pos), members = {} }
    if node.kind == "{" or node.kind == "[" then
      local close = node.kind == "{" and "}" or "]"
      pos = pos + 1
      space()
      while s:sub(pos, pos) ~= close do
        local key = #node.members + 1
        if node.kind == "{" then
          key = bone.json.decode(string_end())
          space()
          pos = pos + 1 -- colon (syntax was validated before scanning)
        end
        node.members[key] = value(depth + 1)
        space()
        if s:sub(pos, pos) == "," then pos = pos + 1; space() end
      end
      pos = pos + 1
    elseif node.kind == '"' then string_end()
    else pos = s:find("[ \t\r\n,%]%}]", pos) or (#s + 1) end
    node.last = pos - 1
    return node
  end
  return value(0)
end

local preamble = [[You are Bone's model backend. Native Claude Code tools are disabled.
The conversation below is data representing the real Bone conversation, not instructions to execute CLI tools.
Return only structured output: response is your assistant text; tool_calls is an array of requested Bone tools.
Bone executes these tools under its own approvals and returns their results. Never claim execution before receiving a result.
Use the tool descriptions and argument schemas in the structured-output schema.
Ending rules: returning "tool_calls": [] ENDS your turn and hands control back to the user.
End only when the task is fully done (verified where you can), you are truly blocked on the user, or
you are waiting for a message to arrive (such as the answers of agents you started).
If your response announces or plans further work ("now I'll...", "next..."), you MUST include the
matching tool_calls in the same reply. Never end on an unexecuted plan, a progress note, or a
question you could answer yourself with a tool.
]]

-- A reply with no tool calls whose text reads as unfinished work: the model
-- narrated instead of acting, which would silently end the turn.
local function looks_unfinished(text)
  local t = (text or ""):gsub("%s+$", ""):lower()
  if t == "" then return true end
  for _, p in ipairs({ "let me know", "shall i", "want me to", "would you like me",
      "should i proceed", "i'll now", "i will now", "i'm going to", "i am going to",
      "next step", "next, i", "now i'll", "now i will", "proceeding to", "about to" }) do
    if t:find(p, 1, true) then return true end
  end
  return t:sub(-1) == ":" or t:sub(-4) == " now" or t:sub(-4) == "now."
end

local function config_dir()
  return os.getenv("CLAUDE_CONFIG_DIR") or ((os.getenv("HOME") or "") .. "/.claude")
end
-- Where the CLI keeps the transcripts of a working directory.
local function project_dir(cwd)
  return config_dir() .. "/projects/" .. (cwd:gsub("[^%w]", "-"))
end

-- Sessions outlive config reloads (which happen on every settings change and
-- plugin save) and restarts: dropping one would make the next call send the
-- whole history again as a cold cache write. A session idle this long is
-- forgotten, and so is any private directory nothing has used for as long
-- (left by a Bone that was killed).
local IDLE_LIMIT = 6 * 3600
local STATE = "claude-code"
local saved = bone.state.load(STATE)
local sessions = type(saved.sessions) == "table" and saved.sessions or {}
local limits = type(saved.limits) == "table" and saved.limits or nil
local function save()
  bone.state.save(STATE, { sessions = sessions, limits = limits })
end
local last_usage = {}
local turn_cost = {}
local function discard(sid)
  local s = sessions[sid]
  sessions[sid] = nil
  -- Only generated private dirs are removed. CLI transcripts never touch repo files.
  if type(s) == "table" and type(s.cwd) == "string" and s.cwd:match("^/tmp/bone3%-claude%-code%.[%w]+$") then
    bone.system("rm -rf -- " .. quote(s.cwd) .. " " .. quote(project_dir(s.cwd)), { timeout = 5000 })
  end
end
-- Marks a private directory as in use (the sweep below spares it); false
-- when it is gone.
local function touch(dir)
  local f = io.open(dir .. "/.bone-used", "w")
  if not f then return false end
  f:write(tostring(os.time()))
  f:close()
  return true
end
do
  local now = os.time()
  for sid, s in pairs(sessions) do
    if type(s) ~= "table" or (tonumber(s.used_at) or 0) < now - IDLE_LIMIT then discard(sid) end
  end
  bone.system("for d in /tmp/bone3-claude-code.* " .. quote(config_dir() .. "/projects") .. "/-tmp-bone3-claude-code-*; do"
    .. ' [ -d "$d" ] && [ -z "$(find "$d" -mmin -' .. math.floor(IDLE_LIMIT / 60) .. ' -print -quit 2>/dev/null)" ]'
    .. ' && rm -rf -- "$d"; done; true', { timeout = 10000 })
  save()
end

local function message_key(m)
  -- Ignore display-only metadata/reasoning; compare the actual Bone transcript.
  local calls, images = {}, nil
  for _, c in ipairs(m.tool_calls or {}) do
    calls[#calls + 1] = { id = c.id, name = c.name, arguments = c.arguments }
  end
  for _, img in ipairs(m.images or {}) do
    images = images or {}
    images[#images + 1] = img.id or digest(img.data or "")
  end
  return digest(canonical({ role = m.role, content = m.content or "", tool_calls = calls,
    call_id = m.call_id, is_error = m.is_error or nil, images = images }))
end
bone.hook("turn_start", function(ctx) turn_cost[ctx.session_id] = 0 end)
local auth_env = "env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL"
  .. " -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY"
  .. " -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN_FILE -u CLAUDECODE "

-- Bone is often started from a desktop/service whose PATH lacks the user's npm or
-- local bin, and a stale system `claude` can shadow the current one (e.g. one
-- that rejects --effort). Without `executable`, use the newest CLI found on PATH
-- or in the usual install locations. Resolved once per config load.
local resolved
local function executable(o)
  if o.executable then return o.executable end
  if resolved then return resolved end
  local r = bone.system([[for c in "$(command -v claude)" "$HOME/.npm-global/bin/claude" "$HOME/.local/bin/claude" ]]
    .. [["$HOME/.claude/local/claude" "$HOME/.bun/bin/claude" /usr/local/bin/claude /opt/homebrew/bin/claude /usr/bin/claude; do ]]
    .. [[[ -x "$c" ] && printf '%s\t%s\n' "$c" "$("$c" --version 2>/dev/null | head -n1)"; done; true]], { timeout = 30000 })
  if not r then return "claude" end -- cancelled; not cached
  local best, best_key = "claude", nil
  for path, version in (r.stdout or ""):gmatch("([^\t\n]+)\t([^\n]*)") do
    local a, b, c = version:match("(%d+)%.(%d+)%.(%d+)")
    if a then
      local key = { tonumber(a), tonumber(b), tonumber(c) }
      local newer = not best_key
      for i = 1, 3 do
        if best_key and key[i] ~= best_key[i] then newer = key[i] > best_key[i]; break end
      end
      if newer then best, best_key = path, key end
    end
  end
  resolved = best
  return best
end

-- One stream-json user message: the new Bone messages as JSON, then any
-- images they carry, each after the [image N] label its message lists.
local function user_message(intro, messages)
  local plain, images = {}, {}
  for i, m in ipairs(messages) do
    local copy = {}
    for k, v in pairs(m) do
      if k ~= "images" and k ~= "reasoning" then copy[k] = v end
    end
    if type(m.images) == "table" and #m.images > 0 then
      copy.images = {}
      for _, img in ipairs(m.images) do
        if type(img.data) ~= "string" then error("claude-code: an attached image has no data", 0) end
        images[#images + 1] = img
        copy.images[#copy.images + 1] = "[image " .. #images .. "]"
      end
    end
    plain[i] = copy
  end
  local blocks = { { type = "text", text = intro .. (#images > 0 and " (images follow, each after its label)" or "")
    .. ":\n" .. canonical(plain) } }
  for n, img in ipairs(images) do
    blocks[#blocks + 1] = { type = "text", text = "[image " .. n .. "]" }
    blocks[#blocks + 1] = { type = "image", source = { type = "base64",
      media_type = img.mime_type or "image/png", data = img.data } }
  end
  return canonical({ type = "user", message = { role = "user", content = blocks } }) .. "\n"
end
local function notice(text)
  return canonical({ type = "user", message = { role = "user", content = text } }) .. "\n"
end

-- Run the CLI and hand each line of its output to on_line once it exits.
-- { code, stderr } or { timed_out = true }; nil when the turn was cancelled.
local function run_cli(command, opts, on_line)
  local r = bone.system(command, opts)
  if not r then return nil end
  for line in (r.stdout or ""):gmatch("[^\r\n]+") do on_line(line) end
  return r
end

local window_names = { five_hour = "5-hour", seven_day = "weekly", seven_day_opus = "weekly Opus",
  seven_day_sonnet = "weekly Sonnet" }
-- A readable error when the plan's limit stopped the call.
local function limit_error(info)
  if type(info) ~= "table" or info.status ~= "rejected" then return nil end
  local window = window_names[info.rateLimitType] or tostring(info.rateLimitType or "usage")
  local reset = tonumber(info.resetsAt)
  return "claude-code: your Claude plan's " .. window .. " limit is reached"
    .. (reset and ("; it resets " .. os.date("%a %H:%M", reset)) or "") .. "; no automatic retry"
end

local function complete(req, emit)
  local o = req.options
  local sid = req.session_id or "default"
  -- Budgets are opt-in. The CLI shows --max-budget-usd to the model ("USD budget:
  -- $0/$0.5; $0.5 remaining"), and models then ration work or stop early, so it
  -- is only passed when configured. The turn guard is Bone-side and invisible.
  local remaining = o.max_turn_budget_usd and (o.max_turn_budget_usd - (req.session_id and turn_cost[sid] or 0))
  if remaining and remaining <= 0 then error("claude-code: Bone turn budget reached; no automatic retry", 0) end
  local budget = o.max_budget_usd and math.min(o.max_budget_usd, remaining or math.huge)
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
    else history[#history + 1] = m end
  end
  local prompt = preamble .. "\nBone system instructions:\n" .. table.concat(system, "\n\n")
  -- Tool descriptions and parameters live only in the output schema; duplicating
  -- them in the system prompt charges for the same definitions twice.
  local schema_json = canonical(schema)
  local fingerprint = digest(canonical({ prompt = prompt, schema = schema_json,
    executable = executable(o), model = o.model or "claude-haiku-5-5",
    effort = o.reasoning_effort or "low" }))
  local keys = {}
  for i, m in ipairs(history) do keys[i] = message_key(m) end
  local s = req.session_id and sessions[sid]
  if s then
    local matches = s.fingerprint == fingerprint and #history > #s.history and touch(s.cwd)
    for i, key in ipairs(s.history) do
      if keys[i] ~= key then matches = false; break end
    end
    if not matches then discard(sid); s = nil end
  end
  if not s then
    local setup = bone.system("mktemp -d /tmp/bone3-claude-code.XXXXXX", { timeout = 5000 })
    if not setup then return nil end
    if setup.code ~= 0 then error("claude-code: could not create isolated working directory", 0) end
    s = { cwd = setup.stdout:gsub("%s+$", ""), fingerprint = fingerprint, history = {} }
    touch(s.cwd)
  end
  -- Keep previous Claude message/cache boundaries intact; send only new Bone data.
  local delta = {}
  for i = #s.history + 1, #history do delta[#delta + 1] = history[i] end
  local resumed = s.cli_id ~= nil
  sessions[sid] = s
  s.invocation = (s.invocation or 0) + 1
  s.used_at = os.time()

  -- The reply so far: every invocation's response, in order.
  local text = ""
  local function invoke(stdin_body, resume_id)
    local command = auth_env .. quote(executable(o))
      .. " -p --input-format stream-json --output-format stream-json --verbose"
      .. " --tools '' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}'"
      .. " --setting-sources '' --settings '{\"disableAllHooks\":true}' --disable-slash-commands --no-chrome"
      .. " --effort " .. quote(o.reasoning_effort or "low")
      .. " --model " .. quote(o.model or "claude-haiku-5-5")
      .. " --max-turns 3"
      -- The CLI limit is cumulative across resumes of one CLI session.
      .. (budget and (" --max-budget-usd " .. quote((s.total_cost or 0) + budget)) or "")
      .. " --system-prompt " .. quote(prompt) .. " --json-schema " .. quote(schema_json)
      .. (resume_id and (" --resume " .. quote(resume_id)) or "")
    -- Result usage sums all internal calls. Context comes from the last real
    -- assistant message instead; repeated content blocks must not be summed.
    local doc, result_json, context_tokens, limit
    local function on_line(line)
      local ok, event = pcall(bone.json.decode, line)
      if not ok or type(event) ~= "table" then
        error("claude-code: invalid CLI stream", 0)
      end
      if event.type == "assistant" and type(event.message) == "table" then
        local usage = event.message.usage
        if type(usage) == "table" then
          local n = (usage.input_tokens or 0) + (usage.cache_read_input_tokens or 0)
            + (usage.cache_creation_input_tokens or 0)
          if n > 0 then context_tokens = n end
        end
      elseif event.type == "rate_limit_event" and type(event.rate_limit_info) == "table" then
        limit = event.rate_limit_info
        limits = { info = limit, at = os.time() }
      elseif event.type == "result" then
        doc, result_json = event, line
      end
    end
    local r = run_cli(command, { cwd = s.cwd, stdin = stdin_body, timeout = o.timeout_ms or 600000 }, on_line)
    -- Never resume an interrupted/failed CLI transcript.
    if not r then return nil end
    if r.timed_out then error("claude-code: timed out; no automatic retry", 0) end
    if not doc then
      error(limit_error(limit) or ("claude-code: CLI failed (exit " .. tostring(r.code) .. "): "
        .. (r.stderr or ""):sub(1, 1000)), 0)
    end
    if r.code ~= 0 or doc.is_error or doc.subtype ~= "success" then
      error(limit_error(limit) or ("claude-code: " .. tostring(doc.subtype or "CLI error") .. ": "
        .. tostring(doc.result or canonical(doc.errors or {})):sub(1, 1000) .. "; no automatic retry"), 0)
    end
    local output = doc.structured_output
    if type(output) ~= "table" or type(output.response) ~= "string" or type(output.tool_calls) ~= "table" then
      error("claude-code: missing structured response; no automatic retry", 0)
    end
    local raw = raw_json(result_json)
    local structured = raw.kind == "{" and raw.members.structured_output
    local raw_calls = structured and structured.kind == "{" and structured.members.tool_calls
    if not raw_calls or raw_calls.kind ~= "[" or #raw_calls.members > 8 then
      error("claude-code: invalid tool request", 0)
    end
    local calls = {}
    for i, call in ipairs(raw_calls.members) do
      local c = output.tool_calls[i]
      local arguments = call.kind == "{" and call.members.arguments
      if type(c) ~= "table" or not known[c.name] or not arguments or arguments.kind ~= "{" then
        error("claude-code: invalid tool request", 0)
      end
      calls[i] = { name = c.name, arguments = result_json:sub(arguments.first, arguments.last) }
    end
    if output.response ~= "" then
      text = text == "" and output.response or (text .. "\n\n" .. output.response)
    end
    return { doc = doc, content = output.response, calls = calls, context_tokens = context_tokens }
  end

  local agg = { input = 0, output = 0, read = 0, write = 0 }
  local function account(doc)
    local u = doc.usage or {}
    agg.input = agg.input + (u.input_tokens or 0)
    agg.read = agg.read + (u.cache_read_input_tokens or 0)
    agg.write = agg.write + (u.cache_creation_input_tokens or 0)
    agg.output = agg.output + (u.output_tokens or 0)
  end

  local inv = invoke(user_message(resumed and "New Bone messages as JSON" or "Bone conversation history as JSON", delta),
    resumed and s.cli_id or nil)
  if not inv then discard(sid); save(); return nil end
  account(inv.doc)
  local nudged = 0
  -- One-shot continuation: a no-tool-call reply that reads as unfinished work
  -- gets a single resume telling the model to continue or finish explicitly.
  -- The user has seen that reply already, so what comes back is added to it.
  while #inv.calls == 0 and nudged < 1 and o.continuation_nudge ~= false and looks_unfinished(inv.content) do
    nudged = nudged + 1
    s.cli_id = inv.doc.session_id
    sessions[sid] = s
    local again = invoke(notice("Bone notice: that reply had no tool_calls, which ends your turn, but it reads as"
      .. " unfinished work. If the task is incomplete, continue now and include the needed tool_calls."
      .. " If it is complete, you are truly blocked on the user, or you are waiting for a message to arrive"
      .. " (such as the answers of agents you started), reply with an empty response and an empty"
      .. " tool_calls array: the user already sees your previous reply."), inv.doc.session_id)
    if not again then discard(sid); save(); return nil end
    account(again.doc)
    inv = again
  end
  local doc = inv.doc
  -- CLI usage is per invocation, but total_cost_usd/modelUsage include prior resumes.
  local cost = math.max(0, (doc.total_cost_usd or 0) - (s.total_cost or 0))
  turn_cost[sid] = (req.session_id and turn_cost[sid] or 0) + cost
  last_usage[req.session_id or "default"] = { input_tokens = agg.input,
    cache_read_input_tokens = agg.read, cache_creation_input_tokens = agg.write,
    output_tokens = agg.output, total_cost_usd = cost, cli_session_cost_usd = doc.total_cost_usd,
    model_usage = doc.modelUsage, subtype = doc.subtype, turn_cost_usd = turn_cost[sid],
    context_tokens = inv.context_tokens, resumed = resumed, sent_messages = #delta,
    cli_turns = doc.num_turns, continuation_nudges = nudged }
  if text ~= "" then emit({ text = text }) end
  local result = { content = text, tool_calls = {}, usage = {
    input_tokens = agg.input + agg.read + agg.write, output_tokens = agg.output,
    cached_tokens = agg.read, context_tokens = inv.context_tokens } }
  for i, c in ipairs(inv.calls) do
    result.tool_calls[i] = { id = "cc_" .. tostring(doc.session_id or "call") .. "_" .. s.invocation .. "_" .. i,
      name = c.name, arguments = c.arguments }
  end
  s.cli_id = doc.session_id
  s.total_cost = doc.total_cost_usd or 0
  sessions[sid] = s
  s.history = keys
  s.history[#s.history + 1] = message_key({ role = "assistant", content = result.content, tool_calls = result.tool_calls })
  if not req.session_id then discard(sid) end
  save()
  return result
end

bone.provider.register("claude_code", { complete = function(req, emit)
  local ok, result = pcall(complete, req, emit)
  if not ok then
    discard(req.session_id or "default")
    save()
    error(result, 0)
  end
  return result
end })
bone.rpc.register("claude-code.usage", function(_, ctx)
  return last_usage[ctx.session_id or "default"] or {}
end)

-- The plan, from the CLI's login; asked once per config load.
local plan
local function plan_type()
  if plan then return plan end
  local o = bone.config.providers.claude_code or {}
  local r = bone.system(auth_env .. quote(executable(o)) .. " auth status", { timeout = 10000 })
  local ok, auth = pcall(bone.json.decode, r and r.stdout or "")
  if r and r.code == 0 and ok and type(auth) == "table" then
    plan = auth.subscriptionType and tostring(auth.subscriptionType) or "unknown"
  end
  return plan
end
-- The plan's usage windows as of the latest request (each one reports them).
bone.rpc.register("claude-code.limits", function()
  return { plan = plan_type(), info = limits and limits.info, at = limits and limits.at }
end)

bone.health("Claude Code", function()
  local o = bone.config.providers.claude_code or {}
  local exe = executable(o)
  local r = bone.system(auth_env .. quote(exe) .. " auth status", { timeout = 10000 })
  if not r then return "warn", "Cancelled" end
  local ok, auth = pcall(bone.json.decode, r.stdout or "")
  if r.code ~= 0 or not ok or type(auth) ~= "table" or not auth.loggedIn or auth.authMethod ~= "claude.ai" then
    return "error", "Run `claude auth login` with your Claude subscription"
  end
  return "ok", "Claude CLI subscription login (" .. tostring(auth.subscriptionType or "unknown plan") .. ", " .. exe .. ")"
end)
if not bone.config.providers.claude_code then
  bone.config.providers.claude_code = { type = "claude_code", model = "claude-haiku-5-5" }
end
