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
local registrations = {}
bone = {
    tool = {
        register = function(spec)
            registrations[spec.name] = spec
            registered = spec
        end,
    },
}
assert(loadfile("tools/computer.lua"))()
local observe = assert(registrations.computer_observe)
assert(observe.display.template == "observing screen")
assert(observe.display.show_result == false)
assert(observe.display.args == nil)
assert(observe.display.value_labels == nil)
assert(registered.name == "computer")
assert(registrations.computer_doctor == nil)
assert(registered.display.template == "{action} {target_label}")
assert(registered.display.show_result == false)
assert(registered.display.args == nil)
local expected_labels = {
    inspect = "inspecting target",
    semantic_find = "finding accessible controls",
    semantic_click = "clicking accessible control",
    move = "moving pointer",
    click = "clicking",
    click_locked = "clicking locked target",
    double_click = "double-clicking",
    right_click = "right-clicking",
    drag = "dragging",
    scroll = "scrolling",
    type = "typing",
    key = "pressing keys",
    wait = "waiting",
}
for action, label in pairs(expected_labels) do
    assert(registered.display.value_labels.action[action] == label)
end
assert(registered.safety == "danger")
assert(registered.stateful == true)
assert(registered.parameters.additionalProperties == false)
assert(registered.parameters.properties.start_x)
assert(registered.parameters.properties.duration_ms)
assert(registered.parameters.properties.semantic_id)
assert(registered.parameters.properties.semantic_id.pattern == "^atspi:[0-9]+([.][0-9]+)*$")
local target_label_schema = assert(registered.parameters.properties.target_label)
assert(target_label_schema.type == "string")
assert(target_label_schema.minLength == 1)
assert(target_label_schema.maxLength == 80)
local actions = {}
for _, action in ipairs(registered.parameters.properties.action.enum) do
    actions[action] = true
end
assert(actions.semantic_find and actions.semantic_click)

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

local function fixture_png(width, height)
    local ihdr = uint32(width) .. uint32(height)
        .. string.char(8, 2, 0, 0, 0)
    return "\137PNG\r\n\26\n"
        .. chunk("IHDR", ihdr)
        .. chunk("IDAT", "compressed")
        .. chunk("IEND", "")
end

local valid_png = fixture_png(200, 100)

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
            dpmsStatus = true,
        },
        window = {
            address = "0xabc",
            workspace = { id = 7 },
            monitor = 0,
            pid = 4242,
            title = "SECRET WINDOW TITLE",
            class = "fixture-app",
            stableId = "fixture-window-1",
            at = { -80, -40 },
            size = { 120, 60 },
        },
        cursor_x = 0,
        cursor_y = 0,
        png = valid_png,
        call_sequence = 0,
        random_sequence = 0,
        region_calls = 0,
        tile_versions = {},
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
                if value == fixture.png then
                    return "base64-png"
                end
                assert(type(value) == "string" and value:sub(1, 8) == "\137PNG\r\n\26\n")
                return "base64-png-derived"
            end,
            sha256 = function(value)
                return string.rep(string.format("%08x", crc32(value)), 8)
            end,
            random_hex = function(bytes)
                fixture.random_sequence = fixture.random_sequence + 1
                local unit = string.format("%08x", fixture.random_sequence)
                return (unit:rep(math.ceil(bytes * 2 / #unit))):sub(1, bytes * 2)
            end,
            png_tiles = function(value, columns, rows)
                assert(value == fixture.png)
                local hashes = {}
                for index = 1, columns * rows do
                    hashes[index] = string.rep(string.format(
                        "%08x",
                        crc32(value .. ":" .. index .. ":" .. tostring(fixture.tile_versions[index] or 0))
                    ), 8)
                end
                return {
                    width = fixture.monitor.width,
                    height = fixture.monitor.height,
                    columns = columns,
                    rows = rows,
                    hashes = hashes,
                }
            end,
            png_resize = function()
                error("unexpected native resize for the small fixture")
            end,
            png_region_sha256 = function(value, x, y, width, height)
                assert(value == fixture.png)
                fixture.region_calls = fixture.region_calls + 1
                return {
                    width = width,
                    height = height,
                    sha256 = string.rep(string.format(
                        "%08x",
                        crc32(table.concat({
                            value,
                            tostring(x),
                            tostring(y),
                            tostring(width),
                            tostring(height),
                        }, ":"))
                    ), 8),
                }
            end,
            png_diff = function(before, after)
                if before == after then
                    return {
                        equal = true,
                        changed_pixels = 0,
                        mean_absolute_difference = 0,
                    }
                end
                return {
                    equal = false,
                    changed_pixels = 1,
                    mean_absolute_difference = 0.001,
                    bounds = { x = 0, y = 0, width = 1, height = 1 },
                }
            end,
        },
        time = {
            monotonic_ms = function()
                fixture.monotonic_ms = fixture.monotonic_ms or 1000
                return fixture.monotonic_ms
            end,
            sleep_ms = function(duration)
                fixture.monotonic_ms = (fixture.monotonic_ms or 1000) + duration
                return true
            end,
        },
        config_dir = "/tmp/bone-test-config",
        ui = {
            status = function() end,
            notify = function() end,
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
        if program == "hyprctl" and args[1] == "--batch" then
            encoded["[]"] = { fixture.monitor }
            encoded["{}"] = fixture.window
            return success("[]\n{}")
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
        if program == "hyprctl" and args[1] == "dispatch" and args[2] == "movecursor" then
            fixture.cursor_x = tonumber(args[3])
            fixture.cursor_y = tonumber(args[4])
            return success()
        end
        if program == "ydotool" and args[1] == "mousemove" then
            fixture.cursor_x = tonumber(args[3])
            fixture.cursor_y = tonumber(args[4])
            return success()
        end
        if program == "ydotool" or program == "sleep" then
            return success()
        end
        if program == "python3" and args[1] == "-c" then
            return success()
        end
        if program == "python3" and args[2] == "focused" then
            return success(cjson.encode({
                ok = true,
                available = true,
                typing_safe = true,
                target = {
                    id = "atspi:0.1",
                    fingerprint = "atspi-fp:v1:" .. string.rep("a", 64),
                    role = "entry",
                    name = "Search",
                    actions = {},
                    direct_activation = false,
                    states = {
                        checked = false,
                        editable = true,
                        enabled = true,
                        expanded = false,
                        focusable = true,
                        focused = true,
                        pressed = false,
                        selected = false,
                        sensitive = true,
                        showing = true,
                        visible = true,
                    },
                    bounds = { x = -70, y = -30, width = 40, height = 20 },
                    center = { x = -50, y = -20 },
                },
                visited = 3,
                rejections = {},
            }))
        end
        if program == "grim" then
            return success(fixture.png)
        end
        if program == "magick" then
            if args[#args] == "rgba:-" then
                for index, argument in ipairs(args) do
                    if argument == "-resize" then
                        local width, height = args[index + 1]:match("^(%d+)x(%d+)!$")
                        if width and height then
                            return success(string.rep(
                                "\0",
                                tonumber(width) * tonumber(height) * 4
                            ))
                        end
                    elseif argument == "-crop" then
                        local width, height = args[index + 1]:match("^(%d+)x(%d+)%+")
                        if width and height then
                            return success(string.rep(
                                "\0",
                                tonumber(width) * tonumber(height) * 4
                            ))
                        end
                    end
                end
            end
            for index, argument in ipairs(args) do
                if argument == "-resize" then
                    local width, height = args[index + 1]:match("^(%d+)x(%d+)!$")
                    if width and height then
                        return success(fixture_png(tonumber(width), tonumber(height)))
                    end
                end
            end
            return success(options.stdin or fixture.png)
        end
        error("unexpected exec: " .. tostring(program))
    end

    fixture.ctx = ctx
    return fixture
end

local function envelope(fixture, params)
    local mutating = {
        move = true, click = true, click_locked = true, semantic_click = true,
        double_click = true, right_click = true, drag = true, scroll = true,
        type = true, key = true,
    }
    if mutating[params.action] and params.action_token == nil then
        params.action_token = fixture.last_action_token
    end
    fixture.call_sequence = fixture.call_sequence + 1
    fixture.ctx.call_id = fixture.next_call_id or ("call-" .. fixture.call_sequence)
    fixture.next_call_id = nil
    local result = cjson.decode(registered.execute(params, fixture.ctx))
    local decoded_content = cjson.decode(result.content)
    if type(decoded_content.action_token) == "string" then
        fixture.last_action_token = decoded_content.action_token
    end
    return result
end

local function content(fixture, params)
    return cjson.decode(envelope(fixture, params).content)
end

local function failure(fixture, params, needle)
    fixture.call_sequence = fixture.call_sequence + 1
    fixture.ctx.call_id = fixture.next_call_id or ("failure-call-" .. fixture.call_sequence)
    fixture.next_call_id = nil
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

-- Sleeping outputs reject immediately instead of spawning a screenshot process
-- that Hyprland will leave blocked until timeout.
local sleeping = new_fixture()
sleeping.monitor.dpmsStatus = false
local sleeping_ok, sleeping_problem = pcall(observe.execute, {}, sleeping.ctx)
assert(not sleeping_ok)
assert(tostring(sleeping_problem):find("is asleep (DPMS off)", 1, true))
assert(#calls_for(sleeping, "grim") == 0)
assert(#calls_for(sleeping, "ydotool") == 0)
assert(sleeping.state.computer == nil)

reset_calls(sleeping)
local sleeping_trace = cjson.decode(cjson.decode(
    observe.execute({ trace = true }, sleeping.ctx)
).content)
assert(sleeping_trace.ok == false)
assert(sleeping_trace.reason_code == "output_dpms_off")
assert(#calls_for(sleeping, "grim") == 0)

-- Large monitor overviews use the native bounded resize and retain a
-- feature-detected ImageMagick fallback for older Bone builds.
local native_resize = new_fixture()
native_resize.monitor.width = 3840
native_resize.monitor.height = 2160
native_resize.png = fixture_png(3840, 2160)
native_resize.resize_calls = 0
native_resize.ctx.codec.png_resize = function(value, max_width, max_height)
    assert(value == native_resize.png)
    assert(max_width == 1920 and max_height == 1080)
    native_resize.resize_calls = native_resize.resize_calls + 1
    return {
        png = fixture_png(1920, 1080),
        width = 1920,
        height = 1080,
        resized = true,
    }
end
local native_resize_envelope = envelope(native_resize, { action = "observe" })
local native_resize_result = cjson.decode(native_resize_envelope.content)
assert(native_resize_result.screenshot_geometry.width == 3840)
assert(native_resize_result.screenshot_geometry.attachment_width == 1920)
assert(native_resize_envelope.images[1].width == 1920)
assert(native_resize.resize_calls == 1)
assert(#calls_for(native_resize, "magick") == 0)

local fallback_resize = new_fixture()
fallback_resize.monitor.width = 3840
fallback_resize.monitor.height = 2160
fallback_resize.png = fixture_png(3840, 2160)
fallback_resize.ctx.codec.png_resize = nil
local fallback_resize_envelope = envelope(fallback_resize, { action = "observe" })
assert(fallback_resize_envelope.images[1].width == 1920)
assert(#calls_for(fallback_resize, "magick") == 1)

local fallback_tiles = new_fixture()
fallback_tiles.ctx.codec.png_tiles = nil
content(fallback_tiles, { action = "observe" })
local fallback_tile_calls = calls_for(fallback_tiles, "magick")
assert(#fallback_tile_calls == 1)
assert(fallback_tile_calls[1].args[#fallback_tile_calls[1].args] == "rgba:-")

local fallback_timer = new_fixture()
fallback_timer.ctx.time = nil
local fallback_timer_observed = content(fallback_timer, { action = "observe" })
reset_calls(fallback_timer)
content(fallback_timer, {
    action = "wait",
    screenshot_id = fallback_timer_observed.screenshot_id,
    duration_ms = 25,
})
local fallback_sleep = assert(calls_for(fallback_timer, "sleep")[1])
assert(fallback_sleep.args[1] == "0.025")

-- Observe is the recovery boundary for corrupted or obsolete persisted state.
for _, broken_state in ipairs({
    "not-mocked-json",
    cjson.encode({ version = 1, screenshot_id = "legacy" }),
}) do
    local recovery_fixture = new_fixture()
    recovery_fixture.state.computer = broken_state
    local recovery_observed = content(recovery_fixture, { action = "observe" })
    assert(recovery_observed.screenshot_id == "computer-1")
    assert(cjson.decode(recovery_fixture.state.computer).version == 2)
end
local corrupt_action = new_fixture()
corrupt_action.state.computer = "not-mocked-json"
reset_calls(corrupt_action)
failure(corrupt_action, {
    action = "move",
    screenshot_id = "computer-1",
    action_token = "action-" .. string.rep("a", 48),
    x = 0,
    y = 0,
}, "invalid computer state")
assert(#corrupt_action.calls == 0)

local observed_envelope = envelope(fixture, { action = "observe" })
local observed = cjson.decode(observed_envelope.content)
assert(observed.screenshot_id == "computer-1")
assert(observed.monitor.x == -100 and observed.monitor.y == -50)
assert(observed.monitor.width == 200 and observed.monitor.height == 100)
assert(observed_envelope.ephemeral_images == true)
assert(observed_envelope.images[1].media_type == "image/png")
assert(observed_envelope.images[1].data == "base64-png")
assert(type(observed.action_token) == "string")
local function recursively_contains(value, needle, seen)
    if type(value) == "string" then
        return value:find(needle, 1, true) ~= nil
    end
    if type(value) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[value] then
        return false
    end
    seen[value] = true
    for key, child in pairs(value) do
        if recursively_contains(key, needle, seen)
            or recursively_contains(child, needle, seen)
        then
            return true
        end
    end
    return false
end
local persisted = cjson.decode(fixture.state.computer)
assert(not recursively_contains(persisted, "base64-png"))
assert(not recursively_contains(persisted, "SECRET WINDOW TITLE"))
assert(not recursively_contains(persisted, "fixture-app"))
local first_id = observed.screenshot_id

-- Every subprocess is direct argv, bounded, timed, and redacted.
for _, call in ipairs(fixture.calls) do
    assert(type(call.program) == "string" and type(call.args) == "table")
    assert(type(call.options.timeout_ms) == "number" and call.options.timeout_ms > 0 and call.options.timeout_ms <= 15000)
    assert(call.options.redact_args == true)
    assert(call.options.max_output_bytes <= 25 * 1024 * 1024)
end
local grim = assert(calls_for(fixture, "grim")[1])
assert(grim.args[5] == "-o" and grim.args[6] == "DP-1" and grim.args[7] == "-")

-- Strict per-action fields fail before any process can run.
local validation_cases = {
    { {}, "action must" },
    { { action = 1 }, "action must" },
    { { action = "Observe" }, "action must be observe" },
    { { action = "observe", x = 0.5 }, "irrelevant field" },
    { { action = "move", screenshot_id = first_id, x = 0, y = 0, text = "x" }, "irrelevant field" },
    { { action = "wait", screenshot_id = first_id, settle_ms = 1 }, "irrelevant field" },
    { { action = "semantic_click", screenshot_id = first_id }, "semantic_id is required" },
    { { action = "semantic_click", screenshot_id = first_id, semantic_id = "atspi:0.bad" }, "semantic_id is required" },
    { { action = "semantic_find", screenshot_id = first_id, semantic_id = "atspi:0.1" }, "irrelevant field" },
    { { action = "observe", grid = "yes" }, "grid must" },
    { { action = "observe", monitor = string.rep("x", 257) }, "monitor must be a bounded" },
    { { action = "observe", monitor = "DP-1\0ignored" }, "monitor must be a bounded" },
    { { action = "click", screenshot_id = first_id, x = 0, y = 0, target_label = "" }, "target_label must" },
    { { action = "click", screenshot_id = first_id, x = 0, y = 0, target_label = 1 }, "target_label must" },
    { { action = "click", screenshot_id = first_id, x = 0, y = 0, target_label = string.rep("x", 81) }, "target_label must" },
    { { action = "click", screenshot_id = first_id, x = 0, y = 0, target_label = "Submit\nbutton" }, "target_label must" },
}
for _, case in ipairs(validation_cases) do
    reset_calls(fixture)
    failure(fixture, case[1], case[2])
    assert(#fixture.calls == 0)
end
for _, action in ipairs({
    "observe", "inspect", "semantic_find", "move", "drag", "scroll", "type", "key", "wait",
}) do
    reset_calls(fixture)
    failure(fixture, { action = action, target_label = "visible target" }, "irrelevant field")
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
assert(moved.screenshot_id == first_id, moved.screenshot_id)
assert(moved.action_token ~= observed.action_token)
local move_call = assert(calls_for(fixture, "hyprctl", "dispatch")[1])
assert(move_call.args[3] == "-20", move_call.args[3])
assert(move_call.args[4] == "29", move_call.args[4])
assert(#calls_for(fixture, "hyprctl", "--batch") >= 2)
local current_id = moved.screenshot_id

-- Failed pointer verification is ambiguous and never retries input.
fixture.hook = function(call)
    if call.program == "hyprctl" and call.args[1] == "dispatch" then
        return { spawned = true, timed_out = true, stdout = "", stderr = "SECRET" }
    end
end
reset_calls(fixture)
local move_failure = content(fixture, {
    action = "move", screenshot_id = current_id, x = 0, y = 0, settle_ms = 0,
})
assert(move_failure.input_delivery == "sent_unverified")
assert(move_failure.observation == "pointer_delivery_ambiguous")
assert(move_failure.retry_input == false)
assert(#calls_for(fixture, "hyprctl", "dispatch") == 1)
fixture.hook = nil
local ambiguous_call_id = fixture.ctx.call_id
reset_calls(fixture)
fixture.next_call_id = ambiguous_call_id
local ambiguous_replay = content(fixture, {
    action = "move",
    screenshot_id = current_id,
    action_token = fixture.last_action_token,
    x = 0,
    y = 0,
    settle_ms = 0,
})
assert(ambiguous_replay.replayed == true)
assert(ambiguous_replay.ledger_status == "ambiguous")
assert(ambiguous_replay.retry_input == false)
assert(#calls_for(fixture, "hyprctl", "dispatch") == 0)
reset_calls(fixture)
failure(fixture, {
    action = "move",
    screenshot_id = current_id,
    action_token = fixture.last_action_token,
    x = 0,
    y = 0,
    settle_ms = 0,
}, "authorization is blocked")
assert(#fixture.calls == 0)

local recovered = content(fixture, { action = "observe" })
current_id = recovered.screenshot_id

-- A target-tile race rejects before reservation or input; the same fresh
-- authorization remains usable once the referenced pixels are restored.
local freshness = new_fixture()
local freshness_observed = content(freshness, { action = "observe" })
freshness.tile_versions[1] = 1
reset_calls(freshness)
local freshness_rejected = content(freshness, {
    action = "click",
    screenshot_id = freshness_observed.screenshot_id,
    action_token = freshness.last_action_token,
    x = 0,
    y = 0,
    target_label = "Top-left target",
    settle_ms = 0,
    trace = true,
})
assert(freshness_rejected.ok == false)
assert(freshness_rejected.reason_code == "target_pixels_changed")
assert(freshness_rejected.input_delivery == "not_sent")
assert(freshness_rejected.retry_input == false)
assert(type(freshness_rejected.trace) == "table")
assert(freshness_rejected.trace.reason_code == "target_pixels_changed")
assert(#calls_for(freshness, "hyprctl", "dispatch") == 0)
assert(#calls_for(freshness, "ydotool") == 0)
freshness.tile_versions[1] = 0
reset_calls(freshness)
local freshness_clicked = content(freshness, {
    action = "click",
    screenshot_id = freshness_observed.screenshot_id,
    action_token = freshness.last_action_token,
    x = 0,
    y = 0,
    target_label = "Top-left target",
    settle_ms = 0,
})
assert(freshness_clicked.input_delivery == "sent_unverified")
assert(#calls_for(freshness, "ydotool") == 1)

-- Inject 1,000 perception/action races across the tile grid. Every changed
-- target region must fail before pointer movement or input reservation.
local race_guard = new_fixture()
local race_baseline = content(race_guard, { action = "observe" })
for iteration = 1, 1000 do
    local x = ((iteration * 37) % 1000) / 999
    local y = ((iteration * 61) % 1000) / 999
    local column = math.min(31, math.floor(x * 32))
    local row = math.min(17, math.floor(y * 18))
    local index = row * 32 + column + 1
    race_guard.tile_versions[index] = iteration
    reset_calls(race_guard)
    failure(race_guard, {
        action = "click",
        screenshot_id = race_baseline.screenshot_id,
        action_token = race_guard.last_action_token,
        x = x,
        y = y,
        target_label = "Race-injected target",
        settle_ms = 0,
    }, "pixels around the intended target changed")
    assert(#calls_for(race_guard, "hyprctl", "dispatch") == 0)
    assert(#calls_for(race_guard, "ydotool") == 0)
    race_guard.tile_versions[index] = nil
end

-- Native timer/tile/diff fast paths establish a bounded process baseline:
-- cached observe is at most four processes and a stable coordinate click is
-- at most ten (two transactional captures plus verified input, including one
-- defensive instance rediscovery when the inherited signature disagrees).
local performance = new_fixture()
reset_calls(performance)
local performance_observed = content(performance, {
    action = "observe",
    trace = true,
})
assert(performance_observed.trace.subprocess_count == #performance.calls)
assert(performance_observed.trace.subprocess_count <= 4)
reset_calls(performance)
local performance_clicked = content(performance, {
    action = "click",
    screenshot_id = performance_observed.screenshot_id,
    action_token = performance.last_action_token,
    x = 0.5,
    y = 0.5,
    target_label = "Measured target",
    settle_ms = 0,
    trace = true,
})
assert(performance_clicked.trace.subprocess_count == #performance.calls)
assert(
    performance_clicked.trace.subprocess_count <= 10,
    tostring(performance_clicked.trace.subprocess_count)
)
assert(#performance_clicked.trace.captures == 2)
assert(type(performance_clicked.trace.context_sha256) == "string")
assert(performance_clicked.trace.visual.image_reused == true)
assert(#calls_for(performance, "sleep") == 0)
assert(#calls_for(performance, "magick") == 0)

-- Cancellation before reservation preserves authorization and sends no input.
local cancelled_pre = new_fixture()
local cancelled_pre_observed = content(cancelled_pre, { action = "observe" })
cancelled_pre.hook = function(call)
    if call.program == "grim" then
        return {
            spawned = true,
            cancelled = true,
            stdout = "",
            stderr = "SECRET cancellation detail",
        }
    end
end
reset_calls(cancelled_pre)
local cancelled_problem = failure(cancelled_pre, {
    action = "click",
    screenshot_id = cancelled_pre_observed.screenshot_id,
    action_token = cancelled_pre.last_action_token,
    x = 0.5,
    y = 0.5,
    target_label = "Cancelled target",
    settle_ms = 0,
}, "screenshot cancelled by the host")
assert(not cancelled_problem:find("SECRET", 1, true))
assert(#calls_for(cancelled_pre, "hyprctl", "dispatch") == 0)
assert(#calls_for(cancelled_pre, "ydotool") == 0)
cancelled_pre.hook = nil
reset_calls(cancelled_pre)
local cancelled_pre_retry = content(cancelled_pre, {
    action = "click",
    screenshot_id = cancelled_pre_observed.screenshot_id,
    action_token = cancelled_pre.last_action_token,
    x = 0.5,
    y = 0.5,
    target_label = "Cancelled target",
    settle_ms = 0,
})
assert(cancelled_pre_retry.input_delivery == "sent_unverified")
assert(#calls_for(cancelled_pre, "ydotool") == 1)

-- Cancellation during post-action capture is ambiguous, never retries input,
-- and blocks all further input until an explicit observation recovers state.
local cancelled_post = new_fixture()
local cancelled_post_observed = content(cancelled_post, { action = "observe" })
local cancelled_post_grims = 0
cancelled_post.hook = function(call)
    if call.program == "grim" then
        cancelled_post_grims = cancelled_post_grims + 1
        if cancelled_post_grims == 2 then
            return {
                spawned = true,
                cancelled = true,
                stdout = "",
                stderr = "SECRET cancellation detail",
            }
        end
    end
end
reset_calls(cancelled_post)
local cancelled_post_result = content(cancelled_post, {
    action = "click",
    screenshot_id = cancelled_post_observed.screenshot_id,
    action_token = cancelled_post.last_action_token,
    x = 0.5,
    y = 0.5,
    target_label = "Cancelled target",
    settle_ms = 0,
})
assert(cancelled_post_result.reason_code == "post_action_observation_failed")
assert(cancelled_post_result.input_delivery == "sent_unverified")
assert(cancelled_post_result.retry_input == false)
assert(#calls_for(cancelled_post, "ydotool") == 1)
cancelled_post.hook = nil
reset_calls(cancelled_post)
failure(cancelled_post, {
    action = "click",
    screenshot_id = cancelled_post_observed.screenshot_id,
    action_token = cancelled_post.last_action_token,
    x = 0.5,
    y = 0.5,
    target_label = "Blocked target",
    settle_ms = 0,
}, "authorization is blocked")
assert(#cancelled_post.calls == 0)
content(cancelled_post, { action = "observe" })

-- All non-verifiable input actions report ambiguous delivery after one attempt.
local input_cases = {
    {
        action = "click", params = { x = 0, y = 0, target_label = "Submit button" },
        check = function(calls)
            assert(calls[#calls].args[1] == "click" and calls[#calls].args[#calls[#calls].args] == "0xC0")
        end,
    },
    {
        action = "double_click", params = { x = 0, y = 0, target_label = "Document row" },
        check = function(calls)
            local args = calls[#calls].args
            assert(args[1] == "click" and args[2] == "--repeat" and args[3] == "2")
        end,
    },
    {
        action = "right_click", params = { x = 0, y = 0, target_label = "Document row" },
        check = function(calls)
            assert(calls[#calls].args[#calls[#calls].args] == "0xC1")
        end,
    },
    {
        action = "drag",
        params = { start_x = 0, start_y = 0, end_x = 1, end_y = 1 },
        check = function(calls)
            assert(calls[1].args[2] == "0x40")
            assert(calls[2].args[2] == "0x80")
        end,
    },
    {
        action = "scroll", params = { x = 0, y = 0, amount = -3 },
        check = function(calls)
            local args = calls[#calls].args
            assert(table.concat(args, " ") == "mousemove --wheel -- 0 -3")
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
    local result = content(fixture, params)
    assert(result.input_delivery == "sent_unverified")
    assert(result.semantic_target == "unknown")
    current_id = result.screenshot_id
    case.check(calls_for(fixture, "ydotool"))
end

-- Inspect creates a native-hashed target lock; click_locked rechecks the exact
-- patch, sends one click, and avoids the former ImageMagick hash subprocesses.
local locked = new_fixture()
local locked_observed = content(locked, { action = "observe" })
reset_calls(locked)
local inspected_envelope = envelope(locked, {
    action = "inspect",
    screenshot_id = locked_observed.screenshot_id,
    x = 0.5,
    y = 0.5,
    radius = 64,
})
local inspected = cjson.decode(inspected_envelope.content)
assert(type(inspected.target_lock.target_token) == "string")
assert(inspected.target_lock.screenshot_id == inspected.screenshot_id)
assert(inspected.target_lock.patch_sha256:match("^[0-9a-f]+$"))
assert(#inspected_envelope.images == 2)
assert(#calls_for(locked, "magick") == 2)
assert(locked.region_calls == 1)
reset_calls(locked)
local locked_clicked = content(locked, {
    action = "click_locked",
    screenshot_id = inspected.screenshot_id,
    action_token = locked.last_action_token,
    target_token = inspected.target_lock.target_token,
    target_label = "Inspected target",
    settle_ms = 0,
})
assert(locked_clicked.input_delivery == "sent_unverified")
assert(#calls_for(locked, "ydotool") == 1)
assert(#calls_for(locked, "magick") == 0)
assert(locked.region_calls == 2)
assert(cjson.decode(locked.state.computer).target_lock == nil)

local fallback_lock = new_fixture()
fallback_lock.ctx.codec.png_region_sha256 = nil
local fallback_lock_observed = content(fallback_lock, { action = "observe" })
reset_calls(fallback_lock)
local fallback_inspected = content(fallback_lock, {
    action = "inspect",
    screenshot_id = fallback_lock_observed.screenshot_id,
    x = 0.5,
    y = 0.5,
    radius = 64,
})
assert(#calls_for(fallback_lock, "magick") == 3)
reset_calls(fallback_lock)
local fallback_locked_clicked = content(fallback_lock, {
    action = "click_locked",
    screenshot_id = fallback_inspected.screenshot_id,
    action_token = fallback_lock.last_action_token,
    target_token = fallback_inspected.target_lock.target_token,
    target_label = "Compatibility target",
    settle_ms = 0,
})
assert(fallback_locked_clicked.input_delivery == "sent_unverified")
assert(#calls_for(fallback_lock, "magick") == 1)
assert(#calls_for(fallback_lock, "ydotool") == 1)

-- Locked clicks accept target descriptions before independently verifying the lock.
reset_calls(fixture)
failure(fixture, {
    action = "click_locked",
    screenshot_id = current_id,
    action_token = fixture.last_action_token,
    target_token = "missing-token",
    target_label = "Submit button",
}, "target token is stale")
assert(#calls_for(fixture, "ydotool") == 0)

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

local function fixture_semantic_fingerprint(seed)
    local encoded = {}
    for index = 1, #seed do
        encoded[#encoded + 1] = string.format("%02x", seed:byte(index))
    end
    return "atspi-fp:v1:" .. (table.concat(encoded) .. string.rep("0", 64)):sub(1, 64)
end

local function semantic_target(overrides)
    local target = {
        id = "atspi:0.2.1",
        role = "button",
        name = "Apply",
        states = {
            checked = false,
            editable = false,
            enabled = true,
            expanded = false,
            focusable = true,
            focused = false,
            pressed = false,
            selected = false,
            sensitive = true,
            showing = true,
            visible = true,
        },
        bounds = { x = -70, y = -30, width = 40, height = 20 },
        center = { x = -50, y = -20 },
        actions = {},
        direct_activation = false,
    }
    for key, value in pairs(overrides or {}) do
        target[key] = value
    end
    if not (overrides and overrides.fingerprint) then
        target.fingerprint = fixture_semantic_fingerprint(
            table.concat({ target.id, target.role, target.name }, "|")
        )
    end
    return target
end

local function semantic_fixture(resolve_target, discovered_target)
    local semantic = new_fixture()
    local target = discovered_target or semantic_target()
    semantic.hook = function(call)
        if call.program == "python3" then
            assert(call.args[1] == "/tmp/bone-test-config/lua/scripts/computer_atspi.py")
            assert(call.options.timeout_ms == 2500)
            assert(call.options.max_output_bytes == 256 * 1024)
            if call.args[2] == "discover" then
                return success(cjson.encode({
                    ok = true,
                    available = true,
                    targets = { target },
                    visited = 4,
                    truncated = false,
                    limits = { depth = 16, nodes = 512, results = 64 },
                }))
            end
            assert(call.args[2] == "resolve" or call.args[2] == "activate")
            local request = cjson.decode(call.options.stdin)
            assert(request.target_id == target.id)
            assert(request.fingerprint == target.fingerprint)
            assert(request.expected.name == nil)
            assert(type(request.expected.name_sha256) == "string")
            if call.args[2] == "activate" then
                return success(cjson.encode({
                    ok = true,
                    activated = true,
                    delivery = "delivered",
                    action = "click",
                    target = resolve_target or target,
                }))
            end
            return success(cjson.encode({ ok = true, target = resolve_target or target }))
        end
    end
    local baseline = content(semantic, { action = "observe" })
    local found = content(semantic, {
        action = "semantic_find", screenshot_id = baseline.screenshot_id,
    })
    assert(found.semantic.available == true)
    assert(found.semantic.targets[1].id == target.id)
    assert(found.semantic.targets[1].states.enabled == true)
    assert(found.semantic.targets[1].states.focusable == true)
    return semantic, found, target
end

-- Semantic discovery falls back cleanly when AT-SPI or calibration is unavailable.
for _, reason in ipairs({
    "focused application is not exposed through AT-SPI",
    "focused AT-SPI window bounds could not be calibrated",
}) do
    local fallback = new_fixture()
    fallback.hook = function(call)
        if call.program == "python3" then
            return success(cjson.encode({ ok = true, available = false, reason = reason, targets = {} }))
        end
    end
    local baseline = content(fallback, { action = "observe" })
    local found = content(fallback, {
        action = "semantic_find", screenshot_id = baseline.screenshot_id,
    })
    assert(found.semantic.available == false)
    assert(found.semantic.reason == reason)
    assert(#found.semantic.targets == 0)
    assert(found.semantic_instruction:find("screenshot coordinates", 1, true))
    assert(#calls_for(fallback, "ydotool") == 0)
end

-- Discovery output is bounded and rejects duplicate IDs.
for _, targets in ipairs({
    { semantic_target(), semantic_target() },
    (function()
        local many = {}
        for index = 1, 65 do
            many[index] = semantic_target({ id = "atspi:0." .. index })
        end
        return many
    end)(),
}) do
    local bounded = new_fixture()
    bounded.hook = function(call)
        if call.program == "python3" then
            return success(cjson.encode({ ok = true, available = true, targets = targets }))
        end
    end
    local baseline = content(bounded, { action = "observe" })
    failure(bounded, {
        action = "semantic_find", screenshot_id = baseline.screenshot_id,
    }, #targets > 64 and "invalid semantic helper result" or "duplicate semantic target id")
    assert(#calls_for(bounded, "ydotool") == 0)
end

-- Helper diagnostics are bounded before they can enter results, state, or traces.
do
    local bounded_diagnostics = new_fixture()
    bounded_diagnostics.hook = function(call)
        if call.program == "python3" then
            return success(cjson.encode({
                ok = true,
                available = true,
                targets = { semantic_target() },
                visited = -1,
                matched = 100001,
                rejections = { hidden = 2, invalid = -1, fractional = 1.5 },
            }))
        end
    end
    local baseline = content(bounded_diagnostics, { action = "observe" })
    local found = content(bounded_diagnostics, {
        action = "semantic_find", screenshot_id = baseline.screenshot_id,
    })
    assert(found.semantic.visited == nil)
    assert(found.semantic.matched == nil)
    assert(found.semantic.rejections.hidden == 2)
    assert(found.semantic.rejections.invalid == nil)
    assert(found.semantic.rejections.fractional == nil)
end

-- Defense in depth rejects non-actionable targets even if a helper returns one.
for _, state_name in ipairs({ "enabled", "sensitive", "showing", "visible" }) do
    local unsafe_semantic = new_fixture()
    unsafe_semantic.hook = function(call)
        if call.program == "python3" then
            local target = semantic_target()
            target.states[state_name] = false
            return success(cjson.encode({ ok = true, available = true, targets = { target } }))
        end
    end
    local unsafe_baseline = content(unsafe_semantic, { action = "observe" })
    failure(unsafe_semantic, {
        action = "semantic_find", screenshot_id = unsafe_baseline.screenshot_id,
    }, "not safely actionable")
    assert(#calls_for(unsafe_semantic, "ydotool") == 0)
end

-- Password names are redacted again at the Lua trust boundary.
local password_semantic = new_fixture()
password_semantic.hook = function(call)
    if call.program == "python3" then
        return success(cjson.encode({
            ok = true,
            available = true,
            targets = { semantic_target({ role = "password_text", name = "SECRET password name" }) },
        }))
    end
end
local password_baseline = content(password_semantic, { action = "observe" })
local protected = content(password_semantic, {
    action = "semantic_find", screenshot_id = password_baseline.screenshot_id,
})
assert(protected.semantic.targets[1].name == "[protected]")
assert(protected.semantic.targets[1].role == "password_text")

-- Unknown IDs, changed identity/state/bounds, and uncalibrated centers reject before input.
local semantic_unknown, unknown_found = semantic_fixture()
reset_calls(semantic_unknown)
failure(semantic_unknown, {
    action = "semantic_click",
    screenshot_id = unknown_found.screenshot_id,
    action_token = semantic_unknown.last_action_token,
    semantic_id = "atspi:0.9",
}, "stale or unknown")
assert(#calls_for(semantic_unknown, "python3") == 0)
assert(#calls_for(semantic_unknown, "ydotool") == 0)

local mismatch_cases = {
    { semantic_target({ name = "Changed" }), "identity changed" },
    { semantic_target({ role = "menu_item" }), "identity changed" },
    { semantic_target({ states = semantic_target().states }), "not safely actionable", "enabled" },
    { semantic_target({ center = { x = -69, y = -30 } }), "bounds are not safely clickable" },
}
mismatch_cases[3][1].states.enabled = false
for _, case in ipairs(mismatch_cases) do
    local changed, found = semantic_fixture(case[1])
    reset_calls(changed)
    failure(changed, {
        action = "semantic_click",
        screenshot_id = found.screenshot_id,
        action_token = changed.last_action_token,
        semantic_id = "atspi:0.2.1",
        settle_ms = 0,
    }, case[2])
    assert(#calls_for(changed, "ydotool") == 0)
    assert(#calls_for(changed, "hyprctl", "dispatch") == 0)
end

-- A verified semantic click consumes discovery and sends one ordinary left click at the resolved center.
local semantic_click, semantic_found = semantic_fixture()
reset_calls(semantic_click)
local clicked = content(semantic_click, {
    action = "semantic_click",
    screenshot_id = semantic_found.screenshot_id,
    semantic_id = "atspi:0.2.1",
    target_label = "Apply button",
    settle_ms = 0,
})
assert(clicked.semantic_target == "verified")
assert(clicked.semantic_verification.id == "atspi:0.2.1")
local semantic_moves = calls_for(semantic_click, "hyprctl", "dispatch")
assert(#semantic_moves == 1)
assert(semantic_moves[1].args[3] == "-50" and semantic_moves[1].args[4] == "-20")
local semantic_clicks = calls_for(semantic_click, "ydotool")
assert(#semantic_clicks == 1)
assert(semantic_clicks[1].args[1] == "click")
assert(semantic_clicks[1].args[#semantic_clicks[1].args] == "0xC0")
assert(cjson.decode(semantic_click.state.computer).semantic == nil)
reset_calls(semantic_click)
failure(semantic_click, {
    action = "semantic_click",
    screenshot_id = clicked.screenshot_id,
    action_token = semantic_click.last_action_token,
    semantic_id = "atspi:0.2.1",
}, "semantic targets are unavailable")
assert(#calls_for(semantic_click, "ydotool") == 0)

-- Direct AT-SPI activation is reserved once, avoids coordinate input, and
-- replays the ledger outcome without launching the helper again.
local direct_target = semantic_target({
    actions = { "click" },
    direct_activation = true,
})
local direct_semantic, direct_found = semantic_fixture(nil, direct_target)
local direct_token = direct_semantic.last_action_token
local direct_call_id = "semantic-direct-call"
direct_semantic.next_call_id = direct_call_id
reset_calls(direct_semantic)
local direct_clicked = content(direct_semantic, {
    action = "semantic_click",
    screenshot_id = direct_found.screenshot_id,
    action_token = direct_token,
    semantic_id = direct_target.id,
    target_label = "Apply button",
    settle_ms = 0,
})
assert(direct_clicked.input_delivery == "delivered")
assert(#calls_for(direct_semantic, "python3") == 1)
assert(calls_for(direct_semantic, "python3")[1].args[2] == "activate")
assert(#calls_for(direct_semantic, "hyprctl", "dispatch") == 0)
assert(#calls_for(direct_semantic, "ydotool") == 0)
local direct_next_token = direct_semantic.last_action_token
reset_calls(direct_semantic)
direct_semantic.next_call_id = direct_call_id
local direct_replay = content(direct_semantic, {
    action = "semantic_click",
    screenshot_id = direct_found.screenshot_id,
    action_token = direct_token,
    semantic_id = direct_target.id,
    target_label = "Apply button",
    settle_ms = 0,
})
assert(direct_replay.replayed == true)
assert(direct_replay.ledger_status == "completed")
assert(direct_replay.action_token == direct_next_token)
assert(#direct_semantic.calls == 0)
reset_calls(direct_semantic)
direct_semantic.next_call_id = direct_call_id
failure(direct_semantic, {
    action = "semantic_click",
    screenshot_id = direct_found.screenshot_id,
    action_token = direct_semantic.last_action_token,
    semantic_id = direct_target.id,
    target_label = "Different request",
    settle_ms = 0,
}, "call_id was already used with different parameters")
assert(#direct_semantic.calls == 0)

-- Spawn failures are known not delivered; post-spawn failures are ambiguous.
fixture.hook = function(call)
    if call.program == "ydotool" then
        return { spawned = false, error = "SECRET argv diagnostic" }
    end
end
reset_calls(fixture)
local spawn_result = content(fixture, {
    action = "type", screenshot_id = current_id,
    action_token = fixture.last_action_token,
    text = "SECRET text",
})
assert(spawn_result.input_delivery == "not_delivered")
assert(spawn_result.reason_code == "ydotool_unavailable")
assert(spawn_result.retry_input == false)
assert(not cjson.encode(spawn_result):find("SECRET", 1, true))
assert(#calls_for(fixture, "ydotool") == 1)
current_id = content(fixture, { action = "observe" }).screenshot_id
fixture.hook = function(call)
    if call.program == "ydotool" then
        return { spawned = true, timed_out = true, stdout = "SECRET", stderr = "SECRET" }
    end
end
reset_calls(fixture)
local timeout_result = content(fixture, {
    action = "type", screenshot_id = current_id, text = "SECRET text",
})
assert(timeout_result.observation == "input_delivery_ambiguous")
assert(timeout_result.retry_input == false)
assert(#calls_for(fixture, "ydotool") == 1)
current_id = content(fixture, { action = "observe" }).screenshot_id
fixture.hook = function(call)
    if call.program == "ydotool" then
        return { spawned = true, timed_out = true, stdout = "", stderr = "SECRET" }
    end
end
reset_calls(fixture)
local click_failure = content(fixture, {
    action = "click", screenshot_id = current_id, x = 0, y = 0,
})
assert(click_failure.observation == "input_delivery_ambiguous")
assert(click_failure.retry_input == false)
assert(#calls_for(fixture, "ydotool") == 1)
fixture.hook = nil
current_id = content(fixture, { action = "observe" }).screenshot_id

-- Stale IDs and changed fingerprints reject before input.
reset_calls(fixture)
failure(fixture, {
    action = "move", screenshot_id = "computer-old",
    action_token = fixture.last_action_token,
    x = 0, y = 0,
}, "stale screenshot_id")
assert(#fixture.calls == 0)
fixture.window.workspace.id = 8
reset_calls(fixture)
failure(fixture, {
    action = "move", screenshot_id = current_id,
    action_token = fixture.last_action_token,
    x = 0, y = 0,
}, "screen context changed")
assert(#calls_for(fixture, "ydotool") == 0)
fixture.window.workspace.id = 7

-- Wait is non-input, returns a fresh screenshot, and grid uses direct ImageMagick.
reset_calls(fixture)
local before_wait_ms = fixture.monotonic_ms
local before_wait_token = fixture.last_action_token
local waited_envelope = envelope(fixture, {
    action = "wait", screenshot_id = current_id, duration_ms = 25, grid = true,
})
local waited = cjson.decode(waited_envelope.content)
assert(waited.screenshot_id == current_id)
assert(waited.action_token ~= before_wait_token)
assert(#calls_for(fixture, "ydotool") == 0)
assert(#calls_for(fixture, "sleep") == 0)
assert(fixture.monotonic_ms == before_wait_ms + 25)
local magick = assert(calls_for(fixture, "magick")[1])
assert(magick.options.stdin == fixture.png)
assert(magick.options.timeout_ms == 4000)
current_id = waited.screenshot_id

-- Invalid and boundary PNGs are rejected without leaking bytes.
local png_cases = {
    "not png",
    "\137PNG\r\n\26\n" .. uint32(0x02000000) .. "IDAT" .. string.rep("x", 8),
}
for _, broken_png in ipairs(png_cases) do
    local broken = new_fixture()
    broken.png = broken_png
    broken.ctx.codec.base64_encode = function()
        error("invalid image reached encoder")
    end
    local problem = failure(broken, { action = "observe" }, "screenshot")
    assert(#problem < 256)
    assert(not problem:find(broken_png, 1, true))
end

local zero = new_fixture()
zero.monitor.width = 0
failure(zero, { action = "observe" }, "invalid monitor geometry")
assert(#calls_for(zero, "grim") == 0)

-- Hyprland query race: one retry only after an ordinary spawned failure and a
-- changed selected signature, using the native cancellable timer.
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
    if call.program == "hyprctl" and call.args[1] == "--batch" then
        monitor_queries = monitor_queries + 1
        if monitor_queries == 1 then
            return { spawned = true, stdout = "", stderr = "SECRET", exit_code = 1 }
        end
    end
end
local race_observed = content(race, { action = "observe" })
assert(race_observed.screenshot_id == "computer-1")
assert(monitor_queries == 3)
assert(#calls_for(race, "sleep") == 0)
assert(race.monotonic_ms == 1080)

local unchanged = new_fixture()
unchanged.signature = "sig-b"
local unchanged_queries = 0
unchanged.hook = function(call)
    if call.program == "hyprctl" and call.args[1] == "--batch" then
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
    if call.program == "hyprctl" and call.args[1] == "--batch" then
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
    if call.program == "hyprctl" and call.args[1] == "--batch" then
        change_queries = change_queries + 1
        if change_queries == 1 then
            return { spawned = true, stdout = "", stderr = "SECRET", exit_code = 1 }
        end
    end
end
failure(changed_twice, { action = "observe" }, "Hyprland instance changed again; action was not sent")
assert(change_queries == 2)
assert(#calls_for(changed_twice, "sleep") == 0)
assert(changed_twice.monotonic_ms == 1080)

print("computer tests passed")
