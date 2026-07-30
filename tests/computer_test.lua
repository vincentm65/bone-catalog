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
assert(observe.description:find(
    "This pair authorizes exactly one computer continuation; every successful continuation returns its replacement pair.",
    1,
    true
))
assert(observe.display.template == "observing screen")
assert(observe.display.show_result == false)
assert(observe.display.args == nil)
assert(observe.display.value_labels == nil)
assert(registered.name == "computer")
assert(registered.description:find(
    "Every click or type action requires the exact screenshot_id/action_token pair and returns its replacement pair after success.",
    1,
    true
))
assert(registrations.computer_doctor == nil)
assert(registered.display.template == "{action} {target_label}")
assert(registered.display.show_result == false)
assert(registered.display.args == nil)
local expected_labels = {
    click = "clicking",
    type = "typing",
}
for action, label in pairs(expected_labels) do
    assert(registered.display.value_labels.action[action] == label)
end
assert(registered.display.value_labels.action.inspect == nil)
assert(registered.safety == "danger")
assert(registered.stateful == true)
assert(registered.parameters.additionalProperties == false)
local expected_properties = {
    action = true,
    screenshot_id = true,
    action_token = true,
    settle_ms = true,
    grid = true,
    trace = true,
    x = true,
    y = true,
    target_label = true,
    text = true,
}
for property in pairs(registered.parameters.properties) do
    assert(expected_properties[property], property)
    expected_properties[property] = nil
end
assert(next(expected_properties) == nil)
local grid_description = "Presentation only: overlay labeled 0.1 coordinate lines with finer 0.05 subdivisions on the returned screenshot; grid itself performs no desktop action or input."
assert(observe.parameters.properties.grid.description == grid_description)
assert(registered.parameters.properties.grid.description == grid_description)
local target_label_schema = assert(registered.parameters.properties.target_label)
assert(target_label_schema.type == "string")
assert(target_label_schema.minLength == 1)
assert(target_label_schema.maxLength == 80)
local observe_recovery = "Call computer_observe before any further computer action; do not reuse the prior screenshot_id/action_token pair."
local function assert_recovery(result, delivery)
    assert(result.input_delivery == delivery)
    assert(result.retry_input == false)
    assert(result.next_action == "observe")
    assert(result.recovery == observe_recovery)
end
local required_fields = {}
for _, field in ipairs(registered.parameters.required) do
    required_fields[field] = true
end
assert(required_fields.action)
assert(required_fields.screenshot_id)
assert(required_fields.action_token)
local action_enum = registered.parameters.properties.action.enum
assert(#action_enum == 2)
assert(action_enum[1] == "click" and action_enum[2] == "type")

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

local function fixture_png(width, height, payload)
    local ihdr = uint32(width) .. uint32(height)
        .. string.char(8, 2, 0, 0, 0)
    return "\137PNG\r\n\26\n"
        .. chunk("IHDR", ihdr)
        .. chunk("IDAT", payload or "compressed")
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
        if program == "ydotool" or program == "sleep" then
            return success()
        end
        if program == "python3" and args[1] == "-c" then
            return success()
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
    if params.action ~= "observe" and params.action_token == nil then
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
    if params.action ~= nil
        and params.action ~= "observe"
        and params.action_token == nil
    then
        params.action_token = fixture.last_action_token
    end
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
    action = "click",
    screenshot_id = fallback_timer_observed.screenshot_id,
    action_token = fallback_timer.last_action_token,
    x = 0.5,
    y = 0.5,
    target_label = "Fallback timer target",
    settle_ms = 25,
})
local fallback_settle_found = false
for _, call in ipairs(calls_for(fallback_timer, "sleep")) do
    fallback_settle_found = fallback_settle_found or call.args[1] == "0.025"
end
assert(fallback_settle_found)

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
    action = "click",
    screenshot_id = "computer-1",
    action_token = "action-" .. string.rep("a", 48),
    x = 0,
    y = 0,
    target_label = "Corrupt-state target",
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

-- Response presentation and persistence failures after input preserve only
-- privacy-safe observation metadata and require a fresh observation.
do
    local presentation = new_fixture()
    local baseline = content(presentation, { action = "observe" })
    presentation.ctx.codec.base64_encode = function()
        error("SECRET presentation failure")
    end
    presentation.hook = function(call, state)
        if call.program == "ydotool" then
            state.png = fixture_png(200, 100, "changed")
        end
    end
    reset_calls(presentation)
    local failed = content(presentation, {
        action = "click",
        screenshot_id = baseline.screenshot_id,
        x = 0.5,
        y = 0.5,
        target_label = "Presentation failure target",
        settle_ms = 0,
    })
    assert(failed.reason_code == "response_persistence_failed")
    assert_recovery(failed, "sent_unverified")
    assert(failed.observation_detail == "detail_redacted=true")
    assert(not recursively_contains(failed, "SECRET"))
    assert(#calls_for(presentation, "ydotool") == 1)

    local persistence = new_fixture()
    baseline = content(persistence, { action = "observe" })
    local state_set = persistence.ctx.state.set
    local set_count = 0
    persistence.ctx.state.set = function(key, value)
        set_count = set_count + 1
        if set_count == 2 then
            error("SECRET state failure")
        end
        return state_set(key, value)
    end
    reset_calls(persistence)
    failed = content(persistence, {
        action = "click",
        screenshot_id = baseline.screenshot_id,
        x = 0.5,
        y = 0.5,
        target_label = "Persistence failure target",
        settle_ms = 0,
    })
    assert(failed.reason_code == "response_persistence_failed")
    assert_recovery(failed, "sent_unverified")
    assert(failed.observation_detail == "detail_redacted=true")
    assert(not recursively_contains(failed, "SECRET"))
    assert(#calls_for(persistence, "ydotool") == 1)
end

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
    { { action = "click", action_token = "action-" .. string.rep("a", 48), x = 0, y = 0 }, "screenshot_id is required" },
    { { action = "click", screenshot_id = first_id, action_token = false, x = 0, y = 0 }, "action_token is required" },
    { { action = "type", screenshot_id = first_id, action_token = false, text = "x" }, "action_token is required" },
    { { action = "click", screenshot_id = first_id, x = 0, y = 0, text = "x" }, "irrelevant field" },
    { { action = "type", screenshot_id = first_id, text = "x", x = 0 }, "irrelevant field" },
    { { action = "type", screenshot_id = first_id, text = "x", target_label = "visible target" }, "irrelevant field" },
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
    "inspect", "semantic_find", "semantic_click", "click_locked", "move",
    "double_click", "right_click", "drag", "scroll", "key", "wait",
}) do
    reset_calls(fixture)
    failure(fixture, { action = action }, "action must be observe, click, or type")
    assert(#fixture.calls == 0)
end

fixture.next_call_id = string.rep("x", 257)
reset_calls(fixture)
local call_id_problem = failure(fixture, {
    action = "click", screenshot_id = first_id, x = 0, y = 0,
    target_label = "Call-id target",
}, "computer input requires a bounded host call_id")
assert(call_id_problem == "computer input requires a bounded host call_id; action was not sent. " .. observe_recovery)
assert(#fixture.calls == 0)

-- Reservation failures send no input and redact host state errors.
do
    local reservation = new_fixture()
    local baseline = content(reservation, { action = "observe" })
    reservation.ctx.state.set = function()
        error("SECRET state failure")
    end
    reset_calls(reservation)
    local problem = failure(reservation, {
        action = "type",
        screenshot_id = baseline.screenshot_id,
        text = "SECRET text",
        settle_ms = 0,
    }, "could not reserve single-use input authorization")
    assert(problem == "type: could not reserve single-use input authorization; action was not sent (detail_redacted=true). " .. observe_recovery)
    assert(not problem:find("SECRET", 1, true))
    assert(#calls_for(reservation, "ydotool") == 0)
end

-- Coordinate validation preserves negative origins and uses floor(value + 0.5).
for _, bad in ipairs({ -0.01, 1.01, math.huge, -math.huge, 0 / 0, "0.5" }) do
    reset_calls(fixture)
    failure(fixture, {
        action = "click", screenshot_id = first_id, x = bad, y = 0,
        target_label = "Coordinate target",
    }, "x must be a finite number")
    assert(#calls_for(fixture, "ydotool") == 0)
end
reset_calls(fixture)
local clicked = content(fixture, {
    action = "click", screenshot_id = first_id, x = 0.5, y = 1, settle_ms = 0,
    target_label = "Boundary target",
})
assert(clicked.screenshot_id == first_id, clicked.screenshot_id)
assert(clicked.action_token ~= observed.action_token)
local move_call = assert(calls_for(fixture, "hyprctl", "dispatch")[1])
assert(move_call.args[3] == "-20", move_call.args[3])
assert(move_call.args[4] == "29", move_call.args[4])
assert(#calls_for(fixture, "hyprctl", "--batch") >= 2)
assert(#calls_for(fixture, "ydotool") == 1)
local current_id = clicked.screenshot_id

-- Failed pointer verification is ambiguous and never retries input.
fixture.hook = function(call)
    if call.program == "hyprctl" and call.args[1] == "dispatch" then
        return { spawned = true, timed_out = true, stdout = "", stderr = "SECRET" }
    end
end
reset_calls(fixture)
local pointer_failure = content(fixture, {
    action = "click", screenshot_id = current_id, x = 0, y = 0, settle_ms = 0,
    target_label = "Ambiguous pointer target",
})
assert(pointer_failure.observation == "pointer_delivery_ambiguous")
assert_recovery(pointer_failure, "sent_unverified")
assert(pointer_failure.observation_detail == "timed_out=true, stderr_bytes=6")
assert(not recursively_contains(pointer_failure, "SECRET"))
assert(#calls_for(fixture, "hyprctl", "dispatch") == 1)
assert(#calls_for(fixture, "ydotool") == 0)
fixture.hook = nil
local ambiguous_call_id = fixture.ctx.call_id
reset_calls(fixture)
fixture.next_call_id = ambiguous_call_id
local ambiguous_replay = content(fixture, {
    action = "click",
    screenshot_id = current_id,
    action_token = fixture.last_action_token,
    x = 0,
    y = 0,
    target_label = "Ambiguous pointer target",
    settle_ms = 0,
})
assert(ambiguous_replay.replayed == true)
assert(ambiguous_replay.ledger_status == "ambiguous")
assert(ambiguous_replay.retry_input == false)
assert(#calls_for(fixture, "hyprctl", "dispatch") == 0)
reset_calls(fixture)
failure(fixture, {
    action = "click",
    screenshot_id = current_id,
    action_token = fixture.last_action_token,
    x = 0,
    y = 0,
    target_label = "Ambiguous pointer target",
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

-- A completed input replay is recognized before current-screen freshness
-- checks, so a successful action that changed the screenshot is never sent
-- again and can still return its recorded result.
local changed_replay = new_fixture()
local changed_replay_observed = content(changed_replay, { action = "observe" })
local changed_replay_token = changed_replay.last_action_token
local changed_replay_call_id = "changed-screen-replay"
changed_replay.hook = function(call, active)
    if call.program == "ydotool" then
        active.png = fixture_png(200, 100, "changed pixels")
    end
end
changed_replay.next_call_id = changed_replay_call_id
reset_calls(changed_replay)
local changed_replay_clicked = content(changed_replay, {
    action = "click",
    screenshot_id = changed_replay_observed.screenshot_id,
    action_token = changed_replay_token,
    x = 0.5,
    y = 0.5,
    target_label = "Changing target",
    settle_ms = 0,
})
assert(changed_replay_clicked.screenshot_id ~= changed_replay_observed.screenshot_id)
changed_replay.hook = nil
changed_replay.next_call_id = changed_replay_call_id
reset_calls(changed_replay)
local changed_screen_replay = content(changed_replay, {
    action = "click",
    screenshot_id = changed_replay_observed.screenshot_id,
    action_token = changed_replay_token,
    x = 0.5,
    y = 0.5,
    target_label = "Changing target",
    settle_ms = 0,
})
assert(changed_screen_replay.replayed == true)
assert(changed_screen_replay.ledger_status == "completed")
assert(changed_screen_replay.screenshot_id == changed_replay_clicked.screenshot_id)
assert(changed_screen_replay.action_token == changed_replay.last_action_token)
assert(#changed_replay.calls == 0)

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
assert_recovery(cancelled_post_result, "sent_unverified")
assert(cancelled_post_result.observation_detail == "cancelled=true, stderr_bytes=26")
assert(not recursively_contains(cancelled_post_result, "SECRET"))
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

-- Click and type report ambiguous delivery after one successful attempt.
local input_cases = {
    {
        action = "click", params = { x = 0, y = 0, target_label = "Submit button" },
        check = function(calls)
            local args = calls[#calls].args
            assert(args[1] == "click")
            assert(args[2] == "--next-delay" and args[3] == "30")
            assert(args[#args] == "0xC0")
        end,
    },
    {
        action = "type", params = { text = "SECRET typed $(payload)" },
        check = function(calls)
            local call = calls[#calls]
            assert(call.args[1] == "type")
            assert(call.args[2] == "--key-delay" and call.args[3] == "12")
            assert(call.args[#call.args] == "SECRET typed $(payload)")
            assert(call.options.redact_args == true)
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
    current_id = result.screenshot_id
    case.check(calls_for(fixture, "ydotool"))
end

-- Invalid input is rejected before ydotool runs.
local invalid_inputs = {
    { { action = "type", screenshot_id = current_id, text = "" }, "text must" },
    { { action = "click", screenshot_id = current_id, y = 0 }, "x must" },
    { { action = "click", screenshot_id = current_id, x = 0, y = 2 }, "y must" },
    { { action = "click", screenshot_id = current_id, x = 0, y = 0, target_label = "" }, "target_label must" },
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
local spawn_result = content(fixture, {
    action = "type", screenshot_id = current_id,
    action_token = fixture.last_action_token,
    text = "SECRET text",
})
assert(spawn_result.reason_code == "ydotool_unavailable")
assert_recovery(spawn_result, "not_delivered")
assert(not recursively_contains(spawn_result, "SECRET"))
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
assert(timeout_result.reason_code == "input_delivery_ambiguous")
assert_recovery(timeout_result, "sent_unverified")
assert(timeout_result.observation_detail == "timed_out=true, stderr_bytes=6")
assert(not cjson.encode(timeout_result):find("SECRET", 1, true))
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
    action = "click", screenshot_id = "computer-old",
    action_token = fixture.last_action_token,
    x = 0, y = 0, target_label = "Stale target",
}, "stale screenshot_id")
assert(#fixture.calls == 0)
fixture.window.workspace.id = 8
reset_calls(fixture)
failure(fixture, {
    action = "click", screenshot_id = current_id,
    action_token = fixture.last_action_token,
    x = 0, y = 0, target_label = "Changed-context target",
}, "screen context changed")
assert(#calls_for(fixture, "ydotool") == 0)
fixture.window.workspace.id = 7

-- Observe returns fresh authorization, and grid is presentation-only.
reset_calls(fixture)
local before_grid_ms = fixture.monotonic_ms
local before_grid_token = fixture.last_action_token
local grid_envelope = cjson.decode(observe.execute({ grid = true }, fixture.ctx))
local gridded = cjson.decode(grid_envelope.content)
fixture.last_action_token = gridded.action_token
assert(gridded.screenshot_id == current_id)
assert(gridded.action_token ~= before_grid_token)
assert(#calls_for(fixture, "ydotool") == 0)
assert(#calls_for(fixture, "sleep") == 0)
assert(fixture.monotonic_ms == before_grid_ms)
local magick = assert(calls_for(fixture, "magick")[1])
assert(magick.options.stdin == fixture.png)
assert(magick.options.timeout_ms == 4000)
current_id = gridded.screenshot_id

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
