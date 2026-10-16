-- grok: a model provider for xAI's Grok over the Responses API. By default it
-- signs in with your Grok Build CLI login (~/.grok/auth.json) and talks to the
-- endpoint Grok Build uses, so turns count against your Grok plan; with an
-- api_key it talks to api.x.ai instead.
--
--   bone.config.providers.grok = {
--     type = "grok",
--     model = "grok-4.7",
--     -- reasoning_effort = "medium",
--     -- api_key = os.getenv("XAI_API_KEY"),  -- use the xAI API instead
--     -- base_url = "https://cli-chat-proxy.grok.com/v1",
--   }
--   bone.config.provider = "grok"

local PLAN_URL = "https://cli-chat-proxy.grok.com/v1"
local XAI_URL = "https://api.x.ai/v1"

local function grok_bin()
  local home = os.getenv("GROK_HOME") or (os.getenv("HOME") .. "/.grok")
  local f = io.open(home .. "/bin/grok")
  if f then
    f:close()
    return home .. "/bin/grok"
  end
  return "grok"
end

-- The plan endpoint refuses clients older than it supports, so requests
-- claim the installed Grok CLI's version (it updates itself).
local function cli_version()
  local ok, v = pcall(function()
    local h = io.popen(grok_bin() .. " --version 2>/dev/null")
    local out = h and h:read("*a") or ""
    if h then h:close() end
    return out:match("(%d+%.%d+%.%d+)")
  end)
  return ok and v or "1.0.60"
end
local CLI_VERSION = cli_version()

local function decode(s)
  local ok, v = pcall(bone.json.decode, s)
  return ok and v or nil
end

local function auth_path()
  local p = os.getenv("GROK_AUTH_PATH")
  if p and p ~= "" then
    return p
  end
  return (os.getenv("GROK_HOME") or (os.getenv("HOME") .. "/.grok")) .. "/auth.json"
end

-- "2026-10-16T12:34:56.789Z" (or with an offset) → Unix time, or nil.
local function parse_time(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec, rest = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?%d*(.*)$")
  if not y then
    return nil
  end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec, isdst = false })
  -- os.time reads the table as local time; shift it back to UTC.
  local now = os.time()
  t = t + os.difftime(now, os.time(os.date("!*t", now)))
  local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
  if sign then
    t = t - (sign == "+" and 1 or -1) * (tonumber(oh) * 3600 + tonumber(om) * 60)
  end
  return t
end

-- The Grok Build CLI's login: a map of sign-ins, each with a bearer `key`.
-- Read on every call: the CLI refreshes it in place. Returns the token with
-- the latest expiry, and that expiry.
local function grok_auth()
  local f = io.open(auth_path())
  if not f then
    return nil
  end
  local doc = decode(f:read("*a")) or {}
  f:close()
  local best, best_exp
  for _, a in pairs(type(doc) == "table" and doc or {}) do
    if type(a) == "table" and type(a.key) == "string" and a.key ~= "" then
      local exp = parse_time(a.expires_at) or math.huge
      if not best or exp > best_exp then
        best, best_exp = a.key, exp
      end
    end
  end
  return best, best_exp
end

-- Tokens last hours and only a running Grok CLI renews them. Any CLI command
-- renews one within its early-invalidation window, so widen that past ours,
-- run a quick one and read the token again.
local function fresh_auth()
  local token, exp = grok_auth()
  if token and exp < os.time() + 300 then
    os.execute("GROK_AUTH_EARLY_INVALIDATION_SECS=600 " .. grok_bin() .. " models >/dev/null 2>&1")
    token, exp = grok_auth()
  end
  return token, token and exp < os.time()
end

-- Only where requests go and how they sign in are Grok's own: bone's
-- Responses provider builds and sends them.
local function prepare(req)
  local o = req.options
  local base_url = o.base_url ~= "" and o.base_url or nil
  -- xAI routes by this id to a server holding its cached prefixes. Caching
  -- matches on prefixes, so one id for every session costs nothing and lets a
  -- new session reuse the system prompt and tools the last one cached.
  local headers = { ["x-grok-conv-id"] = o.cache_key or "bone" }
  if o.api_key and o.api_key ~= "" then
    return { api = "responses", base_url = base_url or XAI_URL, headers = headers }
  end
  local token, expired = fresh_auth()
  if not token then
    error("grok: no login found; run `grok login`, or set api_key on this provider", 0)
  end
  if expired then
    error("grok: login expired and could not be renewed; run `grok login`", 0)
  end
  headers.authorization = "Bearer " .. token
  headers["x-xai-token-auth"] = "xai-grok-cli"
  headers["x-grok-client-version"] = o.client_version or CLI_VERSION
  return { api = "responses", base_url = base_url or os.getenv("GROK_CLI_CHAT_PROXY_BASE_URL") or PLAN_URL, headers = headers }
end

bone.provider.register("grok", { prepare = prepare })

-- With a Grok login, list a `grok` provider unless settings.json already has
-- one; core.lua loads after plugins and may change or replace it.
if not bone.config.providers.grok and grok_auth() then
  bone.config.providers.grok = { type = "grok", model = "grok-4.7" }
end
