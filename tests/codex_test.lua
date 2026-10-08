-- Run from the catalog root: luajit tests/codex_test.lua
local saved, command, complete, body, notice, fail
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
  provider = { register = function(name, spec) assert(name == "codex"); complete = spec.complete end },
  json = { decode = function() return {} end },
  http_stream = function(req)
    body = req.body
    return { status = 200, events = function() return function() return nil end end }
  end,
}
dofile("plugins/codex/core.lua")
for attempt = 1, 3 do
  for _, err in ipairs({
    "codex provider: codex: An error occurred while processing your request.",
    "codex: HTTP 429: rate limited",
    "codex: HTTP 503: unavailable",
  }) do
    assert(retry_hook({ error = err, attempt = attempt }).retry == 1000 * 2 ^ (attempt - 1))
  end
end
assert(retry_hook({ error = "codex: HTTP 503", attempt = 4 }) == nil)
assert(retry_hook({ error = "codex: HTTP 401", attempt = 1 }) == nil)
assert(retry_hook({ error = "other: HTTP 503", attempt = 1 }) == nil)
assert(retry_hook({ error = "codex: response incomplete (max_output_tokens)", attempt = 1 }) == nil)
dofile("plugins/codex/tui.lua")
local function tier(fast)
  complete({ options = { fast = fast, api_key = "test", model = "test" }, messages = {}, tools = {} }, function() end)
  return body.service_tier
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
local text = {}
local bars = {}
for _, line in ipairs(page) do
  local parts = {}
  for _, span in ipairs(line) do parts[#parts + 1] = span[1] end
  text[#text + 1] = table.concat(parts)
  if #line == 4 then bars[#bars + 1] = line end
end
assert(#bars == 2)
assert(bars[1][2][1] == string.rep("█", 18) and bars[1][3][1] == string.rep("░", 6))
assert(bars[1][2][2] == "Accent" and bars[2][2][2] == "WarningMsg")
text = table.concat(text, "\n")
assert(text:find("Plan: plus", 1, true))
assert(text:find("5-hour window", 1, true) and not text:find("%% used"))
assert(text:find("75% remaining", 1, true))
assert(text:find("7-day window", 1, true) and text:find("Resets:", 1, true))
assert(text:find("Credits: 10", 1, true))
quota.rate_limit.primary_window.used_percent = 120
commands.usage()
local found = false
for _, line in ipairs(page) do
  if #line == 4 and line[2][2] == "ErrorMsg" then
    assert(line[2][1] == "" and line[3][1] == string.rep("░", 24))
    assert(line[4][1] == "  0% remaining")
    found = true
  end
end
assert(found)
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
io.open = open
print("codex checks passed")
