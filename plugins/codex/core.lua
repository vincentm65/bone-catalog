-- codex: a model provider for the OpenAI Responses API. By default it signs
-- in with your Codex CLI login (~/.codex/auth.json) and talks to the ChatGPT
-- Codex backend, so turns are billed to your ChatGPT plan; with an api_key it
-- talks to api.openai.com instead.
--
--   bone.config.providers.codex = {
--     type = "codex",
--     model = "gpt-6.1-sol",
--     -- reasoning_effort = "medium",  -- low | medium | high | xhigh | max
--     -- fast = true,                  -- priority service tier
--     -- api_key = os.getenv("OPENAI_API_KEY"),  -- use the OpenAI API instead
--     -- base_url = "https://chatgpt.com/backend-api/codex",
--   }
--   bone.config.provider = "codex"

local CODEX_URL = "https://chatgpt.com/backend-api/codex"
local OPENAI_URL = "https://api.openai.com/v1"

local function decode(s)
  local ok, v = pcall(bone.json.decode, s)
  return ok and v or nil
end

-- The Codex CLI's login. Read on every call: the CLI refreshes it in place.
local function codex_auth()
  local f = io.open((os.getenv("CODEX_HOME") or (os.getenv("HOME") .. "/.codex")) .. "/auth.json")
  if not f then
    return nil
  end
  local doc = decode(f:read("*a")) or {}
  f:close()
  local t = doc.tokens or {}
  if not t.access_token or t.access_token == "" then
    return nil
  end
  return t.access_token, t.account_id
end

-- bone messages -> Responses `instructions` + `input` items.
local function convert(messages)
  local system, input = {}, {}
  for _, m in ipairs(messages) do
    if m.role == "system" then
      system[#system + 1] = m.content
    elseif m.role == "user" then
      input[#input + 1] = { role = "user", content = { { type = "input_text", text = m.content or "" } } }
    elseif m.role == "assistant" then
      if m.content and m.content ~= "" then
        input[#input + 1] = { role = "assistant", content = { { type = "output_text", text = m.content } } }
      end
      for _, c in ipairs(m.tool_calls or {}) do
        local args = c.arguments
        if type(args) ~= "string" then
          args = bone.json.encode(args or {})
        end
        input[#input + 1] = { type = "function_call", call_id = c.id, name = c.name, arguments = args }
      end
    elseif m.role == "tool" then
      input[#input + 1] = { type = "function_call_output", call_id = m.call_id, output = m.content or "" }
    end
  end
  return table.concat(system, "\n\n"), input
end

-- x-codex-turn-state: the backend hands one out on a turn's first response and
-- wants it back on that turn's later calls, keeping them on one cache shard.
local turn_state = {}

local function complete(req, emit)
  local o = req.options
  local instructions, input = convert(req.messages)
  local last = req.messages[#req.messages]
  local sid = req.session_id
  if sid and last and last.role == "user" then
    turn_state[sid] = nil -- a new turn
  end

  local token, account = o.api_key, nil
  local default_url = OPENAI_URL
  if not token or token == "" then
    token, account = codex_auth()
    default_url = CODEX_URL
    if not token then
      error("codex: no login found; run `codex login`, or set api_key on this provider", 0)
    end
  end
  local base = ((o.base_url and o.base_url ~= "") and o.base_url or default_url):gsub("/$", "")

  local tools = {}
  for _, t in ipairs(req.tools) do
    tools[#tools + 1] = { type = "function", name = t.name, description = t.description, parameters = t.parameters, strict = false }
  end
  table.sort(tools, function(a, b) return a.name < b.name end)

  local body = {
    model = o.model,
    instructions = instructions ~= "" and instructions or "You are a helpful assistant.",
    input = input,
    stream = true,
    store = false,
    reasoning = { effort = o.reasoning_effort, summary = "auto" },
    tools = #tools > 0 and tools or nil,
    tool_choice = #tools > 0 and "auto" or nil,
    parallel_tool_calls = #tools > 0 and true or nil,
    prompt_cache_key = sid,
    service_tier = o.fast and "priority" or nil,
  }
  local headers = {
    ["authorization"] = "Bearer " .. token,
    ["content-type"] = "application/json",
    ["accept"] = "text/event-stream",
  }
  if default_url == CODEX_URL then
    headers["originator"] = "codex_cli_rs"
    headers["chatgpt-account-id"] = account
    if sid then
      headers["session-id"] = sid
      headers["thread-id"] = sid
      headers["x-client-request-id"] = sid
      headers["x-codex-turn-state"] = turn_state[sid]
    end
  end

  local s = bone.http_stream({ url = base .. "/responses", method = "POST", headers = headers, body = body })
  if s == nil then
    return nil -- cancelled
  end
  if s.status ~= 200 then
    local text = s:text() or ""
    if s.status == 401 and default_url == CODEX_URL then
      error("codex: HTTP 401, the login has expired; run `codex` once to refresh it (" .. text .. ")", 0)
    end
    error("codex: HTTP " .. s.status .. ": " .. text, 0)
  end
  if sid and not turn_state[sid] and s.headers then
    turn_state[sid] = s.headers["x-codex-turn-state"]
  end

  local result = { content = "", reasoning = "", tool_calls = {}, usage = { input_tokens = 0, output_tokens = 0 } }
  local calls = {} -- output_index -> { id, name, arguments }
  local function finish_call(index, item)
    local c = calls[index] or {}
    calls[index] = nil
    item = item or {}
    local id, name = item.call_id or c.id, item.name or c.name
    local args = (item.arguments and item.arguments ~= "") and item.arguments or c.arguments
    if id and name then
      table.insert(result.tool_calls, { id = id, name = name, arguments = (args and args ~= "") and args or "{}" })
    end
  end

  for data in s:events() do
    local ev = decode(data) or {}
    local kind = ev.type
    if kind == "response.output_text.delta" then
      result.content = result.content .. ev.delta
      emit({ text = ev.delta })
    elseif kind == "response.reasoning_summary_text.delta" then
      result.reasoning = result.reasoning .. ev.delta
      emit({ reasoning = ev.delta })
    elseif kind == "response.reasoning_summary_part.added" and result.reasoning ~= "" then
      result.reasoning = result.reasoning .. "\n\n"
      emit({ reasoning = "\n\n" })
    elseif kind == "response.output_item.added" and ev.item and ev.item.type == "function_call" then
      calls[ev.output_index or 0] = { id = ev.item.call_id, name = ev.item.name, arguments = "" }
    elseif kind == "response.function_call_arguments.delta" then
      local c = calls[ev.output_index or 0]
      if c then
        c.arguments = c.arguments .. (ev.delta or "")
      end
    elseif kind == "response.output_item.done" and ev.item and ev.item.type == "function_call" then
      finish_call(ev.output_index or 0, ev.item)
    elseif kind == "response.completed" then
      local u = ev.response and ev.response.usage
      if u then
        result.usage.input_tokens = u.input_tokens or 0
        result.usage.output_tokens = u.output_tokens or 0
        local cached = u.input_tokens_details and u.input_tokens_details.cached_tokens
        if cached and cached > 0 then
          result.usage.cached_tokens = cached
        end
      end
    elseif kind == "response.failed" or kind == "error" then
      local err = (ev.response and ev.response.error) or ev.error or ev
      error("codex: " .. (err.message or data), 0)
    elseif kind == "response.incomplete" then
      local d = ev.response and ev.response.incomplete_details
      error("codex: response incomplete (" .. ((d and d.reason) or "unknown reason") .. ")", 0)
    end
  end
  for index in pairs(calls) do
    finish_call(index)
  end
  return result
end

bone.provider.register("codex", { complete = complete })

-- With a Codex login, list a `codex` provider unless settings.json already
-- has one; core.lua loads after plugins and may change or replace it.
if not bone.config.providers.codex and codex_auth() then
  bone.config.providers.codex = { type = "codex", model = "gpt-6.1-sol" }
end
