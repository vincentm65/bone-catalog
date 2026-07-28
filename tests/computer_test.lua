-- Run with: lua5.4 tests/computer_test.lua

local encoded = {}
local sequence = 0
cjson = {
    encode = function(value)
        sequence = sequence + 1
        local key = "json-" .. sequence
        encoded[key] = value
        return key
    end,
    decode = function(value)
        local result = encoded[value]
        if result == nil then
            error("unknown mocked JSON")
        end
        return result
    end,
}

local registered
bone = {
    tool = {
        register = function(spec)
            registered = spec
        end,
    },
}
assert(loadfile("tools/computer.lua"))()
assert(registered.name == "computer")
assert(registered.safety == "danger")
assert(registered.stateful == true)
assert(registered.parameters.additionalProperties == false)
assert(registered.parameters.properties.start_x)
assert(registered.parameters.properties.duration_ms)

local function crc32(data)
    local crc = 0xffffffff
    for index = 1, #data do
        crc = crc ~ data:byte(index)
        for _ = 1, 8 do
            crc = (crc & 1) ~= 0 and ((crc >> 1) ~ 0xedb88320) or (crc >> 1)
        end
    end
    return (crc ~ 0xffffffff) & 0xffffffff
end

local function uint32(value)
    return string.char(
        (value >> 24) & 255,
        (value >> 16) & 255,
        (value >> 8) & 255,
        value & 255
    )
end

local function chunk(kind, data)
    return uint32(#data) .. kind .. data .. uint32(crc32(kind .. data))
end

local ihdr = uint32(4) .. uint32(3) .. string.char(8, 2, 0, 0, 0)
local valid_png = "\137PNG\r\n\26\n"
    .. chunk("IHDR", ihdr)
    .. chunk("IDAT", "compressed")
    .. chunk("IEND", "")

local function success(stdout)
    return {
        spawned = true,
        timed_out = false,
        cancelled = false,
        output_limit_exceeded = false,
        stdout = stdout or "",
        stderr = "",
        exit_code = 0,
    }
end

local function new_fixture()
    local fixture = {
        calls = {},
        state = {},
        signature = "sig-a",
        monitor = {
            name = "DP-1",
            focused = true,
            x = -100,
            y = -50,
            width = 200,
            height = 100,
            scale = 1.25,
            transform = 0,
        },
        window = {
            address = "0xabc",
            workspace = { id = 7 },
            monitor = 0,
            title = "SECRET WINDOW TITLE",
        },
        cursor_x = 0,
        cursor_y = 0,
        png = valid_png,
    }

    local ctx = {
        state = {
            get = function(key)
                return fixture.state[key]
            end,
            set = function(key, value)
                fixture.state[key] = value
            end,
        },
        codec = {
            base64_encode = function(value)
                assert(value == fixture.png)
                return "base64-png"
            end,
        },
    }

    function ctx.exec(program, args, options)
        local call = { program = program, args = args, options = options }
        fixture.calls[#fixture.calls + 1] = call
        if fixture.hook then
            local override = fixture.hook(call, fixture)
            if override ~= nil then
                return override
            end
        end
        if program == "hyprctl" and args[1] == "-j" and args[2] == "instances" then
            return success(cjson.encode({ { signature = fixture.signature } }))
        end
        if program == "hyprctl" and args[1] == "-j" and args[2] == "monitors" then
            return success(cjson.encode({ fixture.monitor }))
        end
        if program == "hyprctl" and args[1] == "-j" and args[2] == "activewindow" then
            return success(cjson.encode(fixture.window))
        end
        if program == "hyprctl" and args[1] == "-j" and args[2] == "cursorpos" then
            return success(cjson.encode({ x = fixture.cursor_x, y = fixture.cursor_y }))
        end
        if program == "ydotool" and args[1] == "mousemove" then
            fixture.cursor_x = tonumber(args[3])
            fixture.cursor_y = tonumber(args[4])
            return success()
        end
        if program == "ydotool" or program == "sleep" then
            return success()
        end
        if program == "grim" or program == "magick" then
            return success(fixture.png)
        end
        error("unexpected exec: " .. tostring(program))
    end

    fixture.ctx = ctx
    return fixture
end

local function envelope(fixture, params)
    return cjson.decode(registered.execute(params, fixture.ctx))
end

local function content(fixture, params)
    return cjson.decode(envelope(fixture, params).content)
end

local function failure(fixture, params, needle)
    local ok, problem = pcall(registered.execute, params, fixture.ctx)
    assert(not ok, "expected failure")
    problem = tostring(problem)
    assert(problem:find(needle, 1, true), problem)
    return problem
end

local function calls_for(fixture, program, first_arg)
    local found = {}
    for _, call in ipairs(fixture.calls) do
        if call.program == program and (first_arg == nil or call.args[1] == first_arg) then
            found[#found + 1] = call
        end
    end
    return found
end

local function reset_calls(fixture)
    fixture.calls = {}
end

local fixture = new_fixture()
local observed_envelope = envelope(fixture, { action = "observe" })
local observed = cjson.decode(observed_envelope.content)
assert(observed.screenshot_id == "computer-1")
assert(observed.monitor.x == -100 and observed.monitor.y == -50)
assert(observed.monitor.width == 200 and observed.monitor.height == 100)
assert(observed_envelope.ephemeral_images == true)
assert(observed_envelope.images[1].media_type == "image/png")
assert(observed_envelope.images[1].data == "base64-png")
assert(not fixture.state.computer:find("base64-png", 1, true))
assert(not fixture.state.computer:find("SECRET WINDOW TITLE", 1, true))
local first_id = observed.screenshot_id

-- Every subprocess is direct argv, bounded, timed, and redacted.
for _, call in ipairs(fixture.calls) do
    assert(type(call.program) == "string" and type(call.args) == "table")
    assert(call.options.timeout_ms == 4000)
    assert(call.options.redact_args == true)
    assert(call.options.max_output_bytes <= 25 * 1024 * 1024)
end
local grim = assert(calls_for(fixture, "grim")[1])
assert(grim.args[4] == "-100,-50 200x100")

-- Strict per-action fields fail before any process can run.
local validation_cases = {
    { {}, "action must" },
    { { action = 1 }, "action must" },
    { { action = "Observe" }, "action must be observe" },
    { { action = "observe", x = 0.5 }, "irrelevant field" },
    { { action = "move", screenshot_id = first_id, x = 0, y = 0, text = "x" }, "irrelevant field" },
    { { action = "wait", screenshot_id = first_id, settle_ms = 1 }, "irrelevant field" },
    { { action = "observe", grid = "yes" }, "grid must" },
}
for _, case in ipairs(validation_cases) do
    reset_calls(fixture)
    failure(fixture, case[1], case[2])
    assert(#fixture.calls == 0)
end

-- Coordinate validation preserves negative origins and uses floor(value + 0.5).
for _, bad in ipairs({ -0.01, 1.01, math.huge, -math.huge, 0 / 0, "0.5" }) do
    reset_calls(fixture)
    failure(fixture, {
        action = "move", screenshot_id = first_id, x = bad, y = 0,
    }, "x must be a finite number")
    assert(#calls_for(fixture, "ydotool") == 0)
end
reset_calls(fixture)
local moved = content(fixture, {
    action = "move", screenshot_id = first_id, x = 0.5, y = 1, settle_ms = 0,
})
assert(moved.screenshot_id == "computer-2")
local move_call = assert(calls_for(fixture, "ydotool", "mousemove")[1])
assert(move_call.args[3] == "0", move_call.args[3])
assert(move_call.args[4] == "49", move_call.args[4])
assert(#calls_for(fixture, "hyprctl", "-j") >= 7)
local current_id = moved.screenshot_id

-- Failed pointer verification is ambiguous and never retries input.
fixture.hook = function(call)
    if call.program == "hyprctl" and call.args[2] == "cursorpos" then
        return success(cjson.encode({ x = 999, y = 999 }))
    end
end
reset_calls(fixture)
failure(fixture, {
    action = "move", screenshot_id = current_id, x = 0, y = 0, settle_ms = 0,
}, "move: ambiguous delivery")
assert(#calls_for(fixture, "ydotool", "mousemove") == 1)
fixture.hook = nil

-- All non-verifiable input actions report ambiguous delivery after one attempt.
local input_cases = {
    {
        action = "click", params = { x = 0, y = 0 },
        check = function(calls)
            assert(calls[#calls].args[1] == "click" and calls[#calls].args[2] == "0xC0")
        end,
    },
    {
        action = "double_click", params = { x = 0, y = 0 },
        check = function(calls)
            local args = calls[#calls].args
            assert(args[1] == "click" and args[2] == "--repeat" and args[3] == "2")
        end,
    },
    {
        action = "right_click", params = { x = 0, y = 0 },
        check = function(calls)
            assert(calls[#calls].args[2] == "0xC1")
        end,
    },
    {
        action = "drag",
        params = { start_x = 0, start_y = 0, end_x = 1, end_y = 1 },
        check = function(calls)
            assert(calls[2].args[2] == "0x40")
            assert(calls[3].args[3] == "99" and calls[3].args[4] == "49")
            assert(calls[4].args[2] == "0x80")
        end,
    },
    {
        action = "scroll", params = { x = 0, y = 0, amount = -3 },
        check = function(calls)
            local args = calls[#calls].args
            assert(args[2] == "--repeat" and args[3] == "3" and args[4] == "0xC5")
        end,
    },
    {
        action = "type", params = { text = "SECRET typed $(payload)" },
        check = function(calls)
            local call = calls[#calls]
            assert(call.args[#call.args] == "SECRET typed $(payload)")
            assert(call.options.redact_args == true)
        end,
    },
    {
        action = "key", params = { keys = "CTRL+L" },
        check = function(calls)
            local args = calls[#calls].args
            assert(table.concat(args, " ") == "key 29:1 38:1 38:0 29:0")
        end,
    },
}
for _, case in ipairs(input_cases) do
    reset_calls(fixture)
    local params = { action = case.action, screenshot_id = current_id, settle_ms = 0 }
    for key, value in pairs(case.params) do
        params[key] = value
    end
    local problem = failure(fixture, params, case.action .. ": ambiguous delivery")
    assert(not problem:find("SECRET typed", 1, true))
    case.check(calls_for(fixture, "ydotool"))
end

-- Invalid input is rejected before ydotool runs.
local invalid_inputs = {
    { { action = "scroll", screenshot_id = current_id, x = 0, y = 0, amount = 0 }, "amount must not" },
    { { action = "type", screenshot_id = current_id, text = "" }, "text must" },
    { { action = "key", screenshot_id = current_id, keys = "CTRL+UNKNOWN" }, "unsupported key" },
    { { action = "key", screenshot_id = current_id, keys = "CTRL+CTRL" }, "duplicate key" },
    { { action = "drag", screenshot_id = current_id, start_x = 0, start_y = 0, end_x = 2, end_y = 0 }, "end_x must" },
}
for _, case in ipairs(invalid_inputs) do
    reset_calls(fixture)
    failure(fixture, case[1], case[2])
    assert(#calls_for(fixture, "ydotool") == 0)
end

-- Spawn failures are known not delivered; post-spawn failures are ambiguous.
fixture.hook = function(call)
    if call.program == "ydotool" then
        return { spawned = false, error = "SECRET argv diagnostic" }
    end
end
reset_calls(fixture)
local spawn_problem = failure(fixture, {
    action = "type", screenshot_id = current_id, text = "SECRET text",
}, "ydotool is unavailable")
assert(not spawn_problem:find("SECRET", 1, true))
assert(#calls_for(fixture, "ydotool") == 1)
fixture.hook = function(call)
    if call.program == "ydotool" then
        return { spawned = true, timed_out = true, stdout = "SECRET", stderr = "SECRET" }
    end
end
reset_calls(fixture)
local timeout_problem = failure(fixture, {
    action = "type", screenshot_id = current_id, text = "SECRET text",
}, "type: ambiguous delivery")
assert(not timeout_problem:find("SECRET", 1, true))
assert(#calls_for(fixture, "ydotool") == 1)
local partial_count = 0
fixture.hook = function(call, state)
    if call.program == "ydotool" then
        partial_count = partial_count + 1
        if partial_count == 2 then
            return { spawned = false, error = "SECRET" }
        end
        if call.args[1] == "mousemove" then
            state.cursor_x = tonumber(call.args[3])
            state.cursor_y = tonumber(call.args[4])
        end
        return success()
    end
end
reset_calls(fixture)
failure(fixture, {
    action = "click", screenshot_id = current_id, x = 0, y = 0,
}, "click: ambiguous delivery")
assert(partial_count == 2)
fixture.hook = nil

-- Stale IDs and changed fingerprints reject before input.
reset_calls(fixture)
failure(fixture, {
    action = "move", screenshot_id = "computer-old", x = 0, y = 0,
}, "stale screenshot_id")
assert(#fixture.calls == 0)
fixture.window.workspace.id = 8
reset_calls(fixture)
failure(fixture, {
    action = "move", screenshot_id = current_id, x = 0, y = 0,
}, "screen context changed")
assert(#calls_for(fixture, "ydotool") == 0)
fixture.window.workspace.id = 7

-- Wait is non-input, returns a fresh screenshot, and grid uses direct ImageMagick.
reset_calls(fixture)
local waited_envelope = envelope(fixture, {
    action = "wait", screenshot_id = current_id, duration_ms = 25, grid = true,
})
local waited = cjson.decode(waited_envelope.content)
assert(waited.screenshot_id == "computer-3")
assert(#calls_for(fixture, "ydotool") == 0)
local sleep_call = assert(calls_for(fixture, "sleep")[1])
assert(sleep_call.args[1] == "0.025")
local magick = assert(calls_for(fixture, "magick")[1])
assert(magick.options.stdin == fixture.png)
assert(magick.options.timeout_ms == 4000)
current_id = waited.screenshot_id

-- Invalid and boundary PNGs are rejected without leaking bytes.
local png_cases = {
    { "not png", "valid bounded PNG" },
    { valid_png:sub(1, #valid_png - 1), "PNG" },
    { valid_png:sub(1, 20) .. "X" .. valid_png:sub(22), "CRC" },
    { "\137PNG\r\n\26\n" .. uint32(0x02000000) .. "IDAT" .. string.rep("x", 8), "chunk length" },
}
for _, case in ipairs(png_cases) do
    local broken = new_fixture()
    broken.png = case[1]
    broken.ctx.codec.base64_encode = function()
        error("invalid image reached encoder")
    end
    local problem = failure(broken, { action = "observe" }, case[2])
    assert(#problem < 256)
    assert(not problem:find(case[1], 1, true))
end

local zero = new_fixture()
zero.monitor.width = 0
failure(zero, { action = "observe" }, "invalid monitor geometry")
assert(#calls_for(zero, "grim") == 0)

-- Hyprland query race: one retry only after an ordinary spawned failure and a
-- changed selected signature, with an exact direct sleep argv.
local race = new_fixture()
local discoveries = 0
local monitor_queries = 0
race.hook = function(call, state)
    if call.program == "hyprctl" and call.args[2] == "instances" then
        discoveries = discoveries + 1
        local signature = discoveries == 1 and "sig-a" or "sig-b"
        state.signature = signature
        return success(cjson.encode({ { signature = signature } }))
    end
    if call.program == "hyprctl" and call.args[2] == "monitors" then
        monitor_queries = monitor_queries + 1
        if monitor_queries == 1 then
            return { spawned = true, stdout = "", stderr = "SECRET", exit_code = 1 }
        end
    end
end
local race_observed = content(race, { action = "observe" })
assert(race_observed.screenshot_id == "computer-1")
assert(monitor_queries == 2)
local race_sleeps = calls_for(race, "sleep")
assert(#race_sleeps == 1 and race_sleeps[1].args[1] == "0.080")

local unchanged = new_fixture()
local unchanged_queries = 0
unchanged.hook = function(call)
    if call.program == "hyprctl" and call.args[2] == "monitors" then
        unchanged_queries = unchanged_queries + 1
        return { spawned = true, stdout = "", stderr = "SECRET", exit_code = 1 }
    end
end
failure(unchanged, { action = "observe" }, "Hyprland query failed; action was not sent")
assert(unchanged_queries == 1)
assert(#calls_for(unchanged, "sleep") == 0)

local unspawned = new_fixture()
local unspawned_queries = 0
unspawned.hook = function(call)
    if call.program == "hyprctl" and call.args[2] == "monitors" then
        unspawned_queries = unspawned_queries + 1
        return { spawned = false, error = "SECRET" }
    end
end
failure(unspawned, { action = "observe" }, "hyprctl is unavailable")
assert(unspawned_queries == 1)
assert(#calls_for(unspawned, "sleep") == 0)

local changed_twice = new_fixture()
local change_discoveries = 0
local change_queries = 0
changed_twice.hook = function(call, state)
    if call.program == "hyprctl" and call.args[2] == "instances" then
        change_discoveries = change_discoveries + 1
        local signatures = { "sig-a", "sig-b", "sig-c" }
        local signature = signatures[change_discoveries] or "sig-c"
        state.signature = signature
        return success(cjson.encode({ { signature = signature } }))
    end
    if call.program == "hyprctl" and call.args[2] == "monitors" then
        change_queries = change_queries + 1
        if change_queries == 1 then
            return { spawned = true, stdout = "", stderr = "SECRET", exit_code = 1 }
        end
    end
end
failure(changed_twice, { action = "observe" }, "Hyprland instance changed again; action was not sent")
assert(change_queries == 2)
assert(#calls_for(changed_twice, "sleep") == 1)

print("computer tests passed")
