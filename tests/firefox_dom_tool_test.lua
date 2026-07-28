-- Regression checks for the Wave 1F Lua surface and independent identities.
local function read(path)
  local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s
end
local tool = read("tools/firefox_dom.lua")
local command = read("commands/firefox_dom.lua")
local setup = read("firefox_dom/setup.sh")
local readme = read("firefox_dom/README.md")

local function has(s, needle)
  assert(s:find(needle, 1, true), "missing: " .. needle)
end
has(tool, 'name = "firefox_dom"')
has(tool, 'required = { "action" }')
has(tool, "additionalProperties = false")
for _, action in ipairs({ "tabs", "outline", "find", "inspect", "act", "changes", "navigate", "select_tab" }) do has(tool, action) end
for _, operation in ipairs({ "click", "focus", "type", "set_value", "select", "press", "scroll_into_view", "scroll", "check", "uncheck", "submit" }) do has(tool, operation) end
has(tool, "unknown field for action")
has(tool, "predicates = PREDICATES")
has(tool, "struct.pack('>I'")
has(tool, "struct.unpack('>I'")
has(tool, "TRANSPORT_GRACE")
has(tool, "timeout_ms must be between 1000 and 30000")
for _, field in ipairs({ "text = true", "code = true", "x = true", "y = true", "block = true", "inline = true" }) do has(tool, field) end
assert(not tool:find([[outline = { "scope" }]], 1, true), "outline must default to viewport scope")
assert(not tool:find("predicate = true", 1, true), "public schema must use plural predicates")
assert(not tool:find("+b'\\n'", 1, true), "socket transport must not use newline framing")
has(tool, "return raw")
has(tool, "Inspect narrowly, act sequentially")
has(command, 'ctx.config_dir .. "/lua/firefox_dom/setup.sh"')
assert(not command:find("ctx.cwd", 1, true), "installed command must not use checkout cwd")
has(tool, 'ctx.config_dir .. "/firefox_dom/bone-firefox-dom.sock"')
assert(not tool:find("XDG_RUNTIME_DIR", 1, true), "socket must be config-scoped")
has(command, 'register("firefox_dom"')
for _, identity in ipairs({ "dev.bone.firefox_dom", "bone-firefox-dom.sock", "firefox-dom@bone.local", "bone-firefox-dom-0.1.0.zip" }) do
  has(setup, identity); has(readme, identity)
end
for _, verb in ipairs({ "setup", "doctor", "remove" }) do has(command, verb); has(setup, verb) end
has(readme, "sudo")
assert(not setup:find("sudo", 1, true), "setup must not invoke sudo")
has(setup, [[-L "$HOST_DIR"]])
has(setup, [[-L "$MOZILLA_DIR"]])
has(setup, [[-L "$HOST_FILE"]])
has(setup, [[mktemp "$HOST_DIR/.${HOST_ID}.json.tmp.XXXXXX"]])
has(setup, [[mv -- "$manifest_tmp" "$HOST_FILE"]])
has(setup, [[cargo build --release --locked]])
has(setup, [[cp -- "$BINARY_SOURCE" "$BRIDGE"]])
has(setup, [[BONE_FIREFOX_DOM_SOCKET]])
has(setup, [[zipfile.ZipFile]])
for _, check in ipairs({ "launcher: ", "bridge binary: ", "extension package: ", "canonical socket: " }) do has(setup, check) end
has(setup, "canonical socket: stale")
has(setup, "s.connect(sys.argv[1])")
has(readme, "Cargo")
has(readme, "about:addons")
has(readme, "about:debugging")
has(readme, "does not silently alter profiles")
assert(not setup:find("cat >", 1, true), "setup must not use unsafe direct file creation")
assert(not tool:find("browser_bridge", 1, true), "must use a dedicated bridge")

local registered
bone = { tool = { register = function(spec) registered = spec end } }
cjson = {
  encode = function() return "{}" end,
  decode = function() return {} end,
}
assert(loadfile("tools/firefox_dom.lua"))()
local calls = 0
local ctx = {
  config_dir = "/tmp/firefox-dom-tool-test",
  shell = function()
    calls = calls + 1
    return { exit_code = 0, stdout = "{}" }
  end,
}
assert(registered.execute({ action = "outline" }, ctx) == "{}", "outline should default to viewport")
assert(registered.execute({ action = "act", ref = "7:d3:0:n1", operation = "scroll", x = 10, y = 20 }, ctx) == "{}", "scroll offsets should pass validation")
assert(registered.execute({ action = "act", ref = "7:d3:0:n1", operation = "type", text = "hello" }, ctx) == "{}", "text alias should pass validation")
assert(calls == 3)
registered.execute({ action = "navigate", url = "https://example.test", timeout_ms = 500 }, ctx)
assert(calls == 3, "out-of-range timeout must fail before transport")
print("firefox_dom Lua schema and identity tests passed")
