-- firefox_dom: bounded DOM discovery and explicit node actions through its own bridge.

local MAX_REQUEST = 4 * 1024 * 1024
local DEFAULT_ACTION_TIMEOUT = 15000
local MAX_ACTION_TIMEOUT = 30000
local TRANSPORT_GRACE = 7000

local PREDICATE_PROPERTIES = {
  tag = { type = "string" }, id = { type = "string" }, class = {},
  attribute = {}, attributes = {}, attr = {}, text = {}, direct_text = {}, directText = {},
  descendant_text = {}, descendantText = {}, accessible_name = {}, accessibleName = {},
  role = { type = "string" }, visible = { type = "boolean" }, focused = { type = "boolean" },
  focusable = { type = "boolean" }, enabled = { type = "boolean" }, editable = { type = "boolean" },
  selected = { type = "boolean" }, checked = { type = "boolean" }, ancestor = {}, descendant = {},
  rect = {}, rectangle = {},
}
local PREDICATE_NESTED_PROPERTIES = {
  tag = PREDICATE_PROPERTIES.tag, id = PREDICATE_PROPERTIES.id, class = PREDICATE_PROPERTIES.class,
  attribute = PREDICATE_PROPERTIES.attribute, attributes = PREDICATE_PROPERTIES.attributes, attr = PREDICATE_PROPERTIES.attr,
  text = PREDICATE_PROPERTIES.text, direct_text = PREDICATE_PROPERTIES.direct_text, directText = PREDICATE_PROPERTIES.directText,
  descendant_text = PREDICATE_PROPERTIES.descendant_text, descendantText = PREDICATE_PROPERTIES.descendantText,
  accessible_name = PREDICATE_PROPERTIES.accessible_name, accessibleName = PREDICATE_PROPERTIES.accessibleName,
  role = PREDICATE_PROPERTIES.role, visible = PREDICATE_PROPERTIES.visible, focused = PREDICATE_PROPERTIES.focused,
  focusable = PREDICATE_PROPERTIES.focusable, enabled = PREDICATE_PROPERTIES.enabled, editable = PREDICATE_PROPERTIES.editable,
  selected = PREDICATE_PROPERTIES.selected, checked = PREDICATE_PROPERTIES.checked, rect = PREDICATE_PROPERTIES.rect,
  rectangle = PREDICATE_PROPERTIES.rectangle,
}
local PREDICATE_NESTED = { type = "object", additionalProperties = false, properties = PREDICATE_NESTED_PROPERTIES }
local PREDICATES = { type = "object", additionalProperties = false, properties = PREDICATE_PROPERTIES }
PREDICATE_PROPERTIES.ancestor = PREDICATE_NESTED
PREDICATE_PROPERTIES.descendant = PREDICATE_NESTED
local ACTION_FIELDS = {
  tabs = { action = true },
  outline = { action = true, tab_id = true, frame_id = true, scope = true, ref = true, x = true, y = true, width = true, height = true, max_nodes = true, max_text = true, depth = true },
  find = { action = true, tab_id = true, frame_id = true, css = true, predicates = true, within = true, visible = true, limit = true },
  inspect = { action = true, ref = true, depth = true, include = true, max_nodes = true, max_text = true },
  act = { action = true, ref = true, operation = true, value = true, text = true, key = true, code = true, label = true, index = true, x = true, y = true, block = true, inline = true, observe_changes = true, settle_ms = true },
  changes = { action = true, tab_id = true, frame_id = true, since_revision = true, max_nodes = true, max_text = true },
  navigate = { action = true, tab_id = true, url = true, timeout_ms = true, outline = true },
  select_tab = { action = true, tab_id = true },
}
local ACTIONS = { tabs=true, outline=true, find=true, inspect=true, act=true, changes=true, navigate=true, select_tab=true }
local OPERATIONS = { click=true, focus=true, type=true, set_value=true, select=true, press=true, scroll_into_view=true, scroll=true, check=true, uncheck=true, submit=true }

local function error_object(code, message, details)
  return cjson.encode({ ok = false, error = { code = code, message = message, details = details } })
end
local function bad(message) return error_object("invalid_request", message) end
local function type_ok(v, t)
  if t == "number" then return type(v) == "number" end
  if t == "boolean" then return type(v) == "boolean" end
  if t == "string" then return type(v) == "string" end
  return true
end
local function validate_predicates(p, path)
  if type(p) ~= "table" then return bad(path .. " must be an object") end
  for k, v in pairs(p) do
    local schema = PREDICATE_PROPERTIES[k]
    if not schema then return bad("unknown field in " .. path .. ": " .. tostring(k)) end
    if (k == "ancestor" or k == "descendant") and v ~= nil then
      local nested = validate_predicates(v, path .. "." .. k)
      if nested then return nested end
    end
  end
  return nil
end
local function validate(p)
  if type(p) ~= "table" or type(p.action) ~= "string" or not ACTIONS[p.action] then return nil, bad("action is required and must be a supported action") end
  local allowed = ACTION_FIELDS[p.action]
  for k in pairs(p) do if not allowed[k] then return nil, bad("unknown field for action '" .. p.action .. "': " .. tostring(k)) end end
  local required = {
    outline = {}, find = {}, inspect = { "ref" }, act = { "ref", "operation" },
    changes = { "since_revision" }, navigate = { "url" }, select_tab = { "tab_id" }, tabs = {},
  }
  for _, k in ipairs(required[p.action]) do if p[k] == nil then return nil, bad("missing required field: " .. k) end end
  if p.action == "act" and (type(p.operation) ~= "string" or not OPERATIONS[p.operation]) then return nil, bad("operation is unsupported") end
  if p.action == "outline" and p.scope == "subtree" and type(p.ref) ~= "string" then return nil, bad("subtree outline requires ref") end
  if p.action == "outline" and p.scope == "region" then for _, k in ipairs({"x","y","width","height"}) do if type(p[k]) ~= "number" then return nil, bad("region outline requires numeric " .. k) end end end
  if p.action == "act" and p.operation == "select" then
    local n = 0; for _, k in ipairs({"label","value","index"}) do if p[k] ~= nil then n = n + 1 end end
    if n ~= 1 then return nil, bad("select requires exactly one of label, value, or index") end
  end
  for _, k in ipairs({"tab_id","frame_id","max_nodes","max_text","depth","limit","since_revision","settle_ms","timeout_ms","index","x","y","width","height"}) do
    if p[k] ~= nil and not type_ok(p[k], "number") then return nil, bad(k .. " must be a number") end
  end
  if p.timeout_ms ~= nil and (p.timeout_ms < 1000 or p.timeout_ms > MAX_ACTION_TIMEOUT) then return nil, bad("timeout_ms must be between 1000 and 30000") end
  if p.action == "find" and p.predicates ~= nil then
    local predicate_error = validate_predicates(p.predicates, "predicates")
    if predicate_error then return nil, predicate_error end
  end
  return p
end
local function shell_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function execute(params, ctx)
  local p, validation = validate(params); if not p then return validation end
  local payload = cjson.encode(p)
  if #payload > MAX_REQUEST then return error_object("response_limit", "request exceeds 4 MiB") end
  local action_timeout = p.action == "navigate" and math.floor(p.timeout_ms or DEFAULT_ACTION_TIMEOUT) or DEFAULT_ACTION_TIMEOUT
  local transport_timeout = action_timeout + TRANSPORT_GRACE
  local py = [[import socket,struct,sys
MAX=4*1024*1024
def exact(sock,n):
  data=b''
  while len(data)<n:
    chunk=sock.recv(min(65536,n-len(data)))
    if not chunk: raise RuntimeError('truncated bridge frame')
    data+=chunk
  return data
payload=sys.argv[2].encode()
if len(payload)>MAX: raise RuntimeError('request exceeds 4 MiB')
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(int(sys.argv[3])/1000); s.connect(sys.argv[1]); s.sendall(struct.pack('>I',len(payload))+payload)
header=exact(s,4); length=struct.unpack('>I',header)[0]
if length>MAX: raise RuntimeError('response exceeds 4 MiB')
data=exact(s,length); s.close(); sys.stdout.buffer.write(data)]]
  local socket = ctx.config_dir .. "/firefox_dom/bone-firefox-dom.sock"
  local cmd = "python3 -c " .. shell_quote(py) .. " " .. shell_quote(socket) .. " " .. shell_quote(payload) .. " " .. tostring(transport_timeout)
  local result = ctx.shell(cmd, { timeout_ms = transport_timeout + 2000 })
  if result.exit_code ~= 0 then return error_object("bridge_unavailable", "dedicated Firefox DOM bridge unavailable", { stderr = (result.stderr or ""):sub(1, 1000) }) end
  local raw = result.stdout or ""
  if raw == "" then return error_object("bridge_protocol", "bridge returned no JSON") end
  local ok = pcall(cjson.decode, raw); if not ok then return error_object("bridge_protocol", "bridge returned invalid JSON") end
  return raw
end

bone.tool.register({
  name = "firefox_dom",
  description = "Inspect and act on ordinary DOM elements in the user's normal Firefox session through a bounded local bridge. Inspect narrowly, act sequentially using returned refs, and never guess an ambiguous node or invent a ref. Responses are structured JSON from the bridge, including explicit truncation and accessibility errors.",
  safety = "danger",
  parameters = {
    type = "object", additionalProperties = false,
    properties = {
      action = { type = "string", enum = { "tabs", "outline", "find", "inspect", "act", "changes", "navigate", "select_tab" }, description = "Required action discriminator." },
      tab_id = { type = "number" }, frame_id = { type = "number" }, scope = { type = "string", enum = { "viewport", "document", "focused", "region", "subtree" } }, ref = { type = "string" }, css = { type = "string" }, predicates = PREDICATES, within = { type = "string" }, visible = { type = "boolean" }, limit = { type = "number" }, depth = { type = "number" }, include = { type = "array", items = { type = "string" } }, max_nodes = { type = "number" }, max_text = { type = "number" }, operation = { type = "string", enum = { "click", "focus", "type", "set_value", "select", "press", "scroll_into_view", "scroll", "check", "uncheck", "submit" } }, value = { type = "string" }, text = { type = "string" }, key = { type = "string" }, code = { type = "string" }, label = { type = "string" }, index = { type = "number" }, block = { type = "string", enum = { "start", "center", "end", "nearest" } }, inline = { type = "string", enum = { "start", "center", "end", "nearest" } }, observe_changes = { type = "boolean" }, settle_ms = { type = "number" }, since_revision = { type = "number" }, url = { type = "string" }, timeout_ms = { type = "number", minimum = 1000, maximum = 30000 }, outline = { type = "boolean" }, x = { type = "number" }, y = { type = "number" }, width = { type = "number" }, height = { type = "number" },
    },
    required = { "action" },
  },
  display = { show = true, args = { "action", "operation", "ref" }, eager = true },
  execute = execute,
})
