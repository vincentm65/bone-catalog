-- Run from the catalog root: luajit tests/codex_test.lua
local saved, command, prepare, notice, fail
local commands, rpcs, page = {}, {}
local retry_hook
bone = {
  hook = function(name, fn) assert(name == "request_error"); retry_hook = fn end,
  settings = {
    get = function(path) assert(path == "codex.fast"); return saved end,
    set = function(path, value, cb)
      assert(path == "codex.fast")
      if not fail then saved = value end
      cb({}, fail)
    end,
  },
  cmd = { create = function(name, fn) commands[name] = fn; if name == "fast" then command = fn end end },
  rpc = { register = function(name, fn) rpcs[name] = fn end },
  ui = { pager = function(lines) page = lines end },
  notify = function(text, level) notice = { text, level } end,
  config = { providers = { codex = {} } },
  provider = { register = function(name, spec) assert(name == "codex"); prepare = spec.prepare end },
  json = { decode = function() return {} end },
}
dofile("plugins/codex/core.lua")
for attempt = 1, 3 do
  local err = 'provider error: {"message":"An error occurred while processing your request."}'
  assert(retry_hook({ error = err, attempt = attempt }).retry == 1000 * 2 ^ (attempt - 1))
end
assert(retry_hook({ error = "provider error: overloaded", attempt = 4 }) == nil)
assert(retry_hook({ error = "HTTP 401 Unauthorized", attempt = 1 }) == nil)
assert(retry_hook({ error = "response incomplete: max_output_tokens", attempt = 1 }) == nil)
-- An API key: OpenAI's API, signed in by bone's own Responses provider.
local r = prepare({ options = { api_key = "test", model = "test" }, messages = {}, session_id = "s" })
assert(r.api == "responses" and r.base_url == "https://api.openai.com/v1" and r.headers == nil)
assert(r.body.prompt_cache_key == "s")
dofile("plugins/codex/ui.lua")
local function tier(fast)
  return prepare({ options = { fast = fast, api_key = "test", model = "test" }, messages = {} }).body.service_tier
end
assert(tier(true) == "priority")
assert(tier(false) == nil)
command({ args = "" })
assert(saved == true and tier(false) == "priority")
command({ args = "" })
assert(saved == false and tier(true) == nil)
command({ args = "" })
assert(saved == true and tier(false) == "priority")
command({ args = "off" })
assert(saved == false and tier(true) == nil)
command({ args = " ON " })
assert(saved == true)
command({ args = "invalid" })
assert(saved == true and notice[2] == "error")
fail = "save failed"
command({ args = "off" })
assert(saved == true and notice[2] == "error" and notice[1]:find(fail, 1, true))
local quota = { plan_type = "plus", rate_limit = { primary_window = {
  used_percent = 25, limit_window_seconds = 18000, reset_at = 1900000000,
}, secondary_window = { used_percent = 80, limit_window_seconds = 604800 } }, credits = { balance = "10" } }
bone.rpc.call = function(name, args, cb) assert(name == "codex.usage"); cb(quota) end
assert(commands.usage == commands["codex-usage"])
commands.usage()
-- The page is one element tree: its words, and its meters.
local function read(tree)
  local text, meters = {}, {}
  local function walk(el)
    if type(el) ~= "table" then return end
    if el.kind == "meter" then meters[#meters + 1] = el end
    for _, k in ipairs({ "text", "title", "label" }) do if type(el[k]) == "string" then text[#text + 1] = el[k] end end
    for i = 1, table.maxn(el) do walk(el[i]) end
  end
  walk(tree)
  return table.concat(text, "\n"), meters
end
local text, meters = read(page)
assert(page.kind == "column" and #meters == 2)
assert(meters[1].value == 0.75 and meters[1].tone == "accent" and meters[2].tone == "warning")
assert(text:find("Plan: plus", 1, true))
assert(text:find("5-hour window", 1, true) and not text:find("%% used"))
assert(text:find("75% remaining", 1, true))
assert(text:find("7-day window", 1, true) and text:find("Resets:", 1, true))
assert(text:find("Credits: 10", 1, true))
quota.rate_limit.primary_window.used_percent = 120
commands.usage()
text, meters = read(page)
assert(meters[1].value == 0 and meters[1].tone == "error" and meters[1].label == "0% remaining")
bone.rpc.call = function(name, args, cb) cb(nil, "login expired") end
commands.usage()
assert(notice[1] == "login expired" and notice[2] == "error")
-- Mock auth without reading the user's real credentials.
local open = io.open
io.open = function() return { read = function() return "auth" end, close = function() end } end
bone.json.decode = function(s)
  if s == "auth" then return { tokens = { access_token = "test-token", account_id = "test-account" } } end
  return quota
end
bone.http = function(req)
  assert(req.url == "https://chatgpt.com/backend-api/wham/usage")
  assert(req.headers.authorization == "Bearer test-token")
  assert(req.headers["chatgpt-account-id"] == "test-account")
  return { status = 200, body = "quota" }
end
assert(rpcs["codex.usage"]().rate_limit == quota.rate_limit)
bone.http = function() return { status = 401 } end
local ok, err = pcall(rpcs["codex.usage"])
assert(not ok and err:find("login expired", 1, true))
-- A Codex login: the ChatGPT backend, with the login's token and account.
saved = nil
r = prepare({ options = { model = "test" }, messages = { { role = "user", content = "hi" } }, session_id = "s" })
assert(r.base_url == "https://chatgpt.com/backend-api/codex")
assert(r.headers.authorization == "Bearer test-token" and r.headers["chatgpt-account-id"] == "test-account")
assert(r.headers["session-id"] == "s" and r.body.instructions)
r = prepare({ options = { model = "test" }, messages = { { role = "system", content = "be brief" } } })
assert(r.body.instructions == nil, "the system prompt is the instructions")
io.open = open
print("codex checks passed")
