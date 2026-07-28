-- Run with: lua5.4 tests/computer_test.lua
local encoded = {}
local sequence = 0
local cjson = {
    encode = function(value)
        sequence = sequence + 1
        local key = "json-" .. sequence
        encoded[key] = value
        return key
    end,
    decode = function(value)
        local decoded = encoded[value]
        if not decoded then error("unknown mocked JSON value") end
        return decoded
    end,
}
package.preload.cjson = function() return cjson end

local registered
bone = { tool = { register = function(spec) registered = spec end } }
assert(loadfile("tools/computer.lua"))()
assert(registered and registered.name == "computer")
assert(registered.safety == "danger")
assert(registered.stateful == true)
assert(registered.parameters.additionalProperties == false)

local monitor = {
    name = "DP-1", focused = true, x = 100, y = 200,
    width = 2000, height = 1000, scale = 2, transform = 0,
}
local state_values = {}
local commands = {}
local failures = {}
local image_data = "jpeg-base64-data"

local function monitor_json()
    return cjson.encode({ monitor })
end

local ctx = {
    state = {
        get = function(key) return state_values[key] end,
        set = function(key, value) state_values[key] = value end,
    },
    shell = function(command, opts)
        commands[#commands + 1] = { command = command, timeout_ms = opts.timeout_ms }
        for prefix, detail in pairs(failures) do
            if command:sub(1, #prefix) == prefix then
                return { stdout = "", stderr = detail, exit_code = 1 }
            end
        end
        if command == "hyprctl monitors -j" then
            return { stdout = monitor_json(), stderr = "", exit_code = 0 }
        end
        if command:sub(1, 6) == "set -e" then
            return { stdout = image_data .. "\n", stderr = "", exit_code = 0 }
        end
        return { stdout = "", stderr = "", exit_code = 0 }
    end,
}

local function reset_commands()
    commands = {}
end

local function command_matching(needle)
    for _, entry in ipairs(commands) do
        if entry.command:find(needle, 1, true) then return entry.command end
    end
    return nil
end

local function input_command()
    for _, entry in ipairs(commands) do
        if entry.command:sub(1, 8) == "ydotool " then return entry.command end
    end
    return nil
end

local function call(params)
    local raw = registered.execute(params, ctx)
    local envelope = cjson.decode(raw)
    local content = cjson.decode(envelope.content)
    assert(envelope.ephemeral_images == true)
    assert(#envelope.images == 1)
    assert(envelope.images[1].media_type == "image/jpeg")
    assert(envelope.images[1].data == image_data)
    return content
end

local function current_id()
    return cjson.decode(state_values.computer).screenshot_id
end

local function action(params)
    params.screenshot_id = current_id()
    reset_commands()
    return call(params)
end

-- Observe captures the focused monitor, defaults to a clean image, and stores
-- only freshness/geometry metadata (never image bytes).
local observed = call({ action = "observe" })
assert(observed.screenshot_id == "computer-1")
assert(observed.monitor.name == "DP-1")
assert(observed.monitor.width == 1000 and observed.monitor.height == 500)
local capture = assert(command_matching("grim -t png"))
assert(capture:find("'100,200 1000x500'", 1, true), capture)
assert(capture:find("'1600x800!'", 1, true), capture)
assert(not capture:find("-draw", 1, true), "clean screenshots must not draw a grid")
assert(not state_values.computer:find(image_data, 1, true), "base64 leaked into state")

-- Pointer coordinates are normalized against the screenshot geometry.
action({ action = "move", x = 500, y = 1000 })
assert(command_matching("ydotool mousemove --absolute 600 699"))
action({ action = "click", x = 0, y = 0 })
assert(command_matching("ydotool mousemove --absolute 100 200 && ydotool click 0xC0"))
action({ action = "double_click", x = 10, y = 20 })
assert(command_matching("ydotool click --repeat 2 --next-delay 100 0xC0"))
action({ action = "right_click", x = 10, y = 20 })
assert(command_matching("ydotool click 0xC1"))
action({ action = "drag", start_x = 0, start_y = 0, end_x = 1000, end_y = 1000 })
local drag = assert(command_matching("ydotool click 0x40"))
assert(drag:find("mousemove --absolute 100 200", 1, true), drag)
assert(drag:find("mousemove --absolute 1099 699", 1, true), drag)
assert(drag:find("ydotool click 0x80", 1, true), drag)
action({ action = "scroll", x = 500, y = 500, amount = -3 })
assert(command_matching("ydotool click --repeat 3 0xC5"))

-- Text remains one safely quoted shell argument, and keys become only validated
-- numeric evdev events.
local hostile = "it's $(touch /tmp/computer-test-injected); `id`"
action({ action = "type", text = hostile })
local typed = assert(command_matching("ydotool type"))
assert(typed:find("'it'\"'\"'s $(touch /tmp/computer-test-injected); `id`'", 1, true), typed)
action({ action = "key", keys = "CTRL+L" })
assert(command_matching("ydotool key 29:1 38:1 38:0 29:0"))
action({ action = "wait", duration_ms = 25 })
assert(command_matching("sleep 0.025"))
assert(not input_command(), "wait must not synthesize input")

-- Grid is opt-in and every successful action yields a new screenshot ID.
local before_grid = current_id()
action({ action = "move", x = 1, y = 1, grid = true, settle_ms = 0 })
assert(current_id() ~= before_grid)
assert(command_matching("-draw"), "grid capture must include a draw operation")
assert(command_matching("sleep 0.000"), "explicit settle delay was ignored")

-- Stale IDs and changed geometry are rejected before input is sent.
local ok, err = pcall(registered.execute, { action = "click", screenshot_id = "computer-old", x = 1, y = 1 }, ctx)
assert(not ok and tostring(err):find("stale screenshot_id", 1, true), tostring(err))
monitor.x = 101
ok, err = pcall(registered.execute, { action = "click", screenshot_id = current_id(), x = 1, y = 1 }, ctx)
assert(not ok and tostring(err):find("geometry changed", 1, true), tostring(err))
monitor.x = 100

-- Invalid coordinates, key names, and input fields never reach ydotool.
local function expect_validation(params, needle)
    params.screenshot_id = current_id()
    reset_commands()
    local valid, problem = pcall(registered.execute, params, ctx)
    assert(not valid and tostring(problem):find(needle, 1, true), tostring(problem))
    assert(not input_command(), "invalid input reached ydotool")
end
expect_validation({ action = "move", x = 1001, y = 0 }, "x must be")
expect_validation({ action = "scroll", x = 0, y = 0, amount = 0 }, "must not be zero")
expect_validation({ action = "key", keys = "CTRL+UNKNOWN" }, "unsupported key")
expect_validation({ action = "key", keys = "CTRL+CTRL" }, "duplicate key")
expect_validation({ action = "type", text = "" }, "non-empty string")

-- Missing programs, Hyprland access, capture failures, and daemon failures are
-- actionable and do not attempt installation or privileged setup.
local function expect_failure(prefix, params, needle)
    failures = { [prefix] = "mock failure" }
    local valid, problem = pcall(registered.execute, params, ctx)
    failures = {}
    assert(not valid and tostring(problem):find(needle, 1, true), tostring(problem))
    assert(not tostring(problem):find("sudo", 1, true), tostring(problem))
end
expect_failure("command -v hyprctl", { action = "observe" }, "Hyprland")
expect_failure("command -v grim", { action = "observe" }, "grim is required")
expect_failure("command -v magick", { action = "observe" }, "ImageMagick")
expect_failure("command -v ydotool", { action = "click", screenshot_id = current_id(), x = 1, y = 1 }, "ydotool is required")
expect_failure("hyprctl monitors -j", { action = "observe" }, "HYPRLAND_INSTANCE_SIGNATURE")
expect_failure("set -eu", { action = "observe" }, "screenshot capture failed")
expect_failure("ydotool mousemove", { action = "click", screenshot_id = current_id(), x = 1, y = 1 }, "ydotoold")

print("computer tests passed")
