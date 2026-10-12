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

-- Only where requests go and how they sign in are Codex's own: bone's
-- Responses provider builds and sends them, keeping the model's encrypted
-- reasoning between calls and reporting a stream that breaks off.
local function prepare(req)
  local o = req.options
  local fast = bone.settings.get("codex.fast")
  if fast == nil then fast = o.fast end
  local sid = req.session_id
  local body = { prompt_cache_key = sid, service_tier = fast and "priority" or nil }
  local base_url = o.base_url ~= "" and o.base_url or nil
  if o.api_key and o.api_key ~= "" then
    return { api = "responses", base_url = base_url or OPENAI_URL, body = body }
  end
  local token, account = codex_auth()
  if not token then
    error("codex: no login found; run `codex login`, or set api_key on this provider", 0)
  end
  -- The Codex backend wants instructions even without a system prompt.
  local system = false
  for _, m in ipairs(req.messages) do
    system = system or m.role == "system"
  end
  if not system then
    body.instructions = "You are a helpful assistant."
  end
  return {
    api = "responses",
    base_url = base_url or CODEX_URL,
    headers = {
      authorization = "Bearer " .. token,
      originator = "codex_cli_rs",
      ["chatgpt-account-id"] = account,
      ["session-id"] = sid,
      ["thread-id"] = sid,
      ["x-client-request-id"] = sid,
    },
    body = body,
  }
end

bone.provider.register("codex", { prepare = prepare })

-- Retry the backend's transient failures inside a stream after 1s, 2s, then
-- 4s (HTTP 429 and 5xx are retried already). The core only invokes this hook
-- before text or reasoning has streamed.
bone.hook("request_error", function(ev)
  local err = ev.error or ""
  local transient = err:find("An error occurred while processing your request", 1, true)
    or err:find("overloaded", 1, true)
  if transient and ev.attempt <= 3 then
    return { retry = 1000 * 2 ^ (ev.attempt - 1) }
  end
end)

-- Fetch account quotas on the core; login credentials never reach the TUI.
bone.rpc.register("codex.usage", function()
  local token, account = codex_auth()
  if not token then
    error("codex: no login found; run `codex login` (usage requires a ChatGPT login, not an API key)", 0)
  end
  local res = bone.http({
    url = "https://chatgpt.com/backend-api/wham/usage",
    headers = { authorization = "Bearer " .. token, ["chatgpt-account-id"] = account },
    timeout = 15000,
  })
  if not res then return nil end
  if res.status ~= 200 then
    error(res.status == 401 and "codex: login expired; run `codex` to refresh it"
      or ("codex: usage request failed (HTTP " .. res.status .. ")"), 0)
  end
  local usage = decode(res.body)
  if type(usage) ~= "table" then error("codex: invalid usage response", 0) end
  -- Only expose quota fields, never account details or credentials.
  return { plan_type = usage.plan_type, rate_limit = usage.rate_limit,
    code_review_rate_limit = usage.code_review_rate_limit, credits = usage.credits }
end)

-- With a Codex login, list a `codex` provider unless settings.json already
-- has one; core.lua loads after plugins and may change or replace it.
if not bone.config.providers.codex and codex_auth() then
  bone.config.providers.codex = { type = "codex", model = "gpt-6.1-sol" }
end
