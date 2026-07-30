-- Run with: lua5.4 tests/computer_geometry_test.lua
--
-- Property-style coverage for the public computer tool's screenshot-to-cursor
-- mapping. The oracle intentionally works in logical monitor space; it does
-- not reproduce computer.lua's source-pixel conversion.

local encoded = {}
local sequence = 0
cjson = {
    encode = function(value)
        sequence = sequence + 1
        local key = "geometry-json-" .. sequence
        encoded[key] = value
        return key
    end,
    decode = function(value)
        local result = encoded[value]
        assert(result ~= nil, "unknown mocked JSON value: " .. tostring(value))
        return result
    end,
}

local registrations = {}
bone = {
    tool = {
        register = function(spec)
            registrations[spec.name] = spec
        end,
    },
}

assert(loadfile("tools/computer.lua"))()
local computer_tool = assert(registrations.computer)

local function check(condition, format_string, ...)
    if not condition then
        error(string.format(format_string, ...), 2)
    end
end

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

local png_cache = {}
local function fixture_png(width, height)
    local key = tostring(width) .. "x" .. tostring(height)
    local cached = png_cache[key]
    if cached then
        return cached
    end
    local ihdr = uint32(width) .. uint32(height) .. string.char(8, 2, 0, 0, 0)
    local png = "\137PNG\r\n\26\n"
        .. chunk("IHDR", ihdr)
        .. chunk("IDAT", "geometry-fixture")
        .. chunk("IEND", "")
    png_cache[key] = png
    return png
end

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

local function positive_round(value)
    return math.floor(value + 0.5)
end

-- Explicitly list all wl_output/Hyprland transforms so the test oracle does
-- not share computer.lua's odd/even transform shortcut.
local transformed_extents = {
    [0] = function(width, height) return width, height end, -- normal
    [1] = function(width, height) return height, width end, -- 90 degrees
    [2] = function(width, height) return width, height end, -- 180 degrees
    [3] = function(width, height) return height, width end, -- 270 degrees
    [4] = function(width, height) return width, height end, -- flipped
    [5] = function(width, height) return height, width end, -- flipped 90
    [6] = function(width, height) return width, height end, -- flipped 180
    [7] = function(width, height) return height, width end, -- flipped 270
}

local function oracle_geometry(monitor)
    local transform = assert(transformed_extents[monitor.transform])
    local pixel_width, pixel_height = transform(monitor.width, monitor.height)
    local logical_width = math.max(1, positive_round(pixel_width / monitor.scale))
    local logical_height = math.max(1, positive_round(pixel_height / monitor.scale))
    return {
        pixel_width = pixel_width,
        pixel_height = pixel_height,
        logical_width = logical_width,
        logical_height = logical_height,
    }
end

-- This is deliberately independent of screenshot pixel centers. A normalized
-- target denotes the nearest point in the monitor's logical rectangle.
local function oracle_cursor(monitor, normalized_x, normalized_y)
    local geometry = oracle_geometry(monitor)
    return monitor.x + positive_round(normalized_x * (geometry.logical_width - 1)),
        monitor.y + positive_round(normalized_y * (geometry.logical_height - 1)),
        geometry
end

local function monitor_by_name(monitors, name)
    for _, monitor in ipairs(monitors) do
        if monitor.name == name then
            return monitor
        end
    end
    error("unknown fixture monitor: " .. tostring(name))
end

local function cursor_from_arguments(args, first)
    local x = tonumber(args[first])
    local y = tonumber(args[first + 1])
    if x and y then
        return x, y
    end
    if type(args[first]) == "string" then
        local left, right = args[first]:match("^%s*(-?%d+)%s+(-?%d+)%s*$")
        if left and right then
            return tonumber(left), tonumber(right)
        end
    end
end

local function new_fixture(monitors, selected_name, fixture_id)
    local fixture = {
        monitors = monitors,
        selected_name = selected_name,
        signature = "geometry-signature-" .. fixture_id,
        state = {},
        calls = {},
        cursor_x = 0,
        cursor_y = 0,
        cursor_moves = {},
        call_sequence = 0,
        random_sequence = 0,
        monotonic_ms = 1000,
        window = {
            address = "0xabc",
            workspace = { id = 11 },
            monitor = 0,
            pid = 4242,
            title = "Geometry fixture",
            class = "geometry-fixture",
            stableId = "geometry-window",
            at = { 10, 20 },
            size = { 160, 90 },
        },
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
            base64_encode = function()
                return "geometry-base64-png"
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
                local monitor = monitor_by_name(fixture.monitors, fixture.selected_name)
                local geometry = oracle_geometry(monitor)
                local hashes = {}
                for index = 1, columns * rows do
                    hashes[index] = string.rep(string.format(
                        "%08x", crc32(value .. ":" .. tostring(index))
                    ), 8)
                end
                return {
                    width = geometry.pixel_width,
                    height = geometry.pixel_height,
                    columns = columns,
                    rows = rows,
                    hashes = hashes,
                }
            end,
            png_resize = function()
                error("unexpected native resize for geometry fixtures")
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
                return fixture.monotonic_ms
            end,
            sleep_ms = function(duration)
                fixture.monotonic_ms = fixture.monotonic_ms + duration
                return true
            end,
        },
        config_dir = "/tmp/bone-computer-geometry-test",
        ui = {
            status = function() end,
            notify = function() end,
        },
        log = {
            info = function() end,
        },
    }

    function ctx.exec(program, args, options)
        fixture.calls[#fixture.calls + 1] = {
            program = program,
            args = args,
            options = options,
        }

        if program == "hyprctl" and args[1] == "-j" and args[2] == "instances" then
            return success(cjson.encode({ { signature = fixture.signature } }))
        end
        if program == "hyprctl" and args[1] == "--batch" then
            encoded["[]"] = fixture.monitors
            encoded["{}"] = fixture.window
            return success("[]\n{}")
        end
        if program == "hyprctl" and args[1] == "-j" and args[2] == "monitors" then
            return success(cjson.encode(fixture.monitors))
        end
        if program == "hyprctl" and args[1] == "-j" and args[2] == "activewindow" then
            return success(cjson.encode(fixture.window))
        end
        if program == "hyprctl"
            and ((args[1] == "-j" and args[2] == "cursorpos") or args[1] == "cursorpos")
        then
            if args[1] == "-j" then
                return success(cjson.encode({ x = fixture.cursor_x, y = fixture.cursor_y }))
            end
            return success(tostring(fixture.cursor_x) .. ", " .. tostring(fixture.cursor_y))
        end
        if program == "hyprctl" and args[1] == "dispatch" and args[2] == "movecursor" then
            local x, y = cursor_from_arguments(args, 3)
            assert(x and y, "invalid mocked movecursor arguments")
            fixture.cursor_x = x
            fixture.cursor_y = y
            fixture.cursor_moves[#fixture.cursor_moves + 1] = { x = x, y = y }
            return success()
        end
        if program == "grim" then
            local output_name
            for index, argument in ipairs(args) do
                if argument == "-o" then
                    output_name = args[index + 1]
                    break
                end
            end
            local monitor = monitor_by_name(fixture.monitors, output_name)
            local geometry = oracle_geometry(monitor)
            return success(fixture_png(geometry.pixel_width, geometry.pixel_height))
        end
        if program == "ydotool" then
            return success()
        end
        if program == "sleep" then
            return success()
        end
        error("unexpected geometry fixture exec: " .. tostring(program))
    end

    fixture.ctx = ctx
    return fixture
end

local function invoke(fixture, params)
    fixture.call_sequence = fixture.call_sequence + 1
    fixture.ctx.call_id = string.format(
        "geometry-%s-%d",
        fixture.signature,
        fixture.call_sequence
    )

    local envelope = cjson.decode(computer_tool.execute(params, fixture.ctx))
    local content = cjson.decode(envelope.content)
    check(content.screenshot_id == nil, "response exposed internal screenshot ID")
    check(content.action_token == nil, "response exposed internal authorization")
    check(content.next_call == nil, "response exposed internal continuation state")
    check(content.screenshot_captured == true, "successful call did not capture a screenshot")
    check(envelope.ephemeral_images == true, "screenshot attachment was not ephemeral")
    check(type(envelope.images) == "table" and #envelope.images == 1, "missing screenshot attachment")
    return content, envelope
end

local scales = {
    0.75,
    1.0,
    1.1,
    1.25,
    4 / 3,
    1.5,
    1.75,
    2.0,
    2.25,
}

local function property_points(monitor, transform, scale_index)
    local geometry = oracle_geometry(monitor)
    local points = {
        -- Corners.
        { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 },
        -- Edge midpoints and asymmetric edge points.
        { 0, 0.5 }, { 1, 0.5 }, { 0.5, 0 }, { 0.5, 1 },
        { 0, 0.137 }, { 1, 0.863 }, { 0.271, 0 }, { 0.729, 1 },
        -- Interior points that are sensitive to fractional-scale rounding.
        { 0.5, 0.5 }, { 0.1, 0.9 }, { 1 / 3, 2 / 3 },
        { 0.618034, 0.381966 }, { 0.000001, 0.999999 },
        -- One source-pixel inset from each oriented edge.
        {
            1 / math.max(1, geometry.pixel_width - 1),
            1 / math.max(1, geometry.pixel_height - 1),
        },
        {
            (geometry.pixel_width - 2) / math.max(1, geometry.pixel_width - 1),
            (geometry.pixel_height - 2) / math.max(1, geometry.pixel_height - 1),
        },
    }

    -- A deterministic diagonal permutation supplies property-like coverage
    -- without randomness or test-order dependence.
    for index = 0, 10 do
        points[#points + 1] = {
            index / 10,
            ((index * 7 + transform * 3 + scale_index * 5) % 11) / 10,
        }
    end
    return points
end

local checked_points = 0
local checked_scenarios = 0
local saw_negative_origin = false
local saw_fractional_scale = false
local saw_transform = {}

for transform = 0, 7 do
    for scale_index, scale in ipairs(scales) do
        local selected_name = string.format("TARGET-%d-%d", transform, scale_index)
        local negative = (transform + scale_index) % 2 == 0
        local selected = {
            name = selected_name,
            focused = false,
            x = negative and (-2400 - transform * 61 - scale_index * 19)
                or (1700 + transform * 53 + scale_index * 17),
            y = (scale_index % 3 == 0) and (-1300 - transform * 23)
                or (-700 + scale_index * 31),
            width = 503 + transform * 17 + scale_index * 7,
            height = 307 + transform * 11 + scale_index * 5,
            scale = scale,
            transform = transform,
            activeWorkspace = { id = 20 + transform },
        }
        local monitors = {
            {
                name = "FOCUSED",
                focused = true,
                x = 0,
                y = 0,
                width = 320,
                height = 180,
                scale = 1,
                transform = 0,
                activeWorkspace = { id = 11 },
            },
            selected,
            {
                name = "AUXILIARY",
                focused = false,
                x = 900,
                y = -500,
                width = 401,
                height = 239,
                scale = 1.25,
                transform = 5,
                activeWorkspace = { id = 31 },
            },
        }
        local fixture = new_fixture(
            monitors,
            selected_name,
            tostring(transform) .. "-" .. tostring(scale_index)
        )
        local current = invoke(fixture, {
            action = "observe",
            monitor = selected_name,
        })
        check(current.monitor.name == selected_name, "wrong monitor selected: %s", current.monitor.name)

        local geometry = oracle_geometry(selected)
        check(
            current.screenshot_geometry.width == geometry.pixel_width
                and current.screenshot_geometry.height == geometry.pixel_height,
            "transform %d scale %.6f returned incorrect screenshot extent",
            transform,
            scale
        )
        check(
            current.screenshot_geometry.logical_width == geometry.logical_width
                and current.screenshot_geometry.logical_height == geometry.logical_height,
            "transform %d scale %.6f returned incorrect logical extent",
            transform,
            scale
        )

        for point_index, point in ipairs(property_points(selected, transform, scale_index)) do
            fixture.cursor_moves = {}
            local clicked = invoke(fixture, {
                action = "click",
                x = point[1],
                y = point[2],
                settle_ms = 0,
            })
            check(
                #fixture.cursor_moves == 1,
                "transform %d scale %.6f point %d sent %d cursor moves",
                transform,
                scale,
                point_index,
                #fixture.cursor_moves
            )
            local actual = fixture.cursor_moves[1]
            local expected_x, expected_y = oracle_cursor(selected, point[1], point[2])
            local local_x = actual.x - selected.x
            local local_y = actual.y - selected.y

            check(
                local_x >= 0 and local_x < geometry.logical_width
                    and local_y >= 0 and local_y < geometry.logical_height,
                "cursor escaped selected monitor: transform=%d scale=%.6f point=(%.6f,%.6f) actual=(%d,%d) bounds=(%d,%d %dx%d)",
                transform,
                scale,
                point[1],
                point[2],
                actual.x,
                actual.y,
                selected.x,
                selected.y,
                geometry.logical_width,
                geometry.logical_height
            )
            check(
                math.abs(actual.x - expected_x) <= 1
                    and math.abs(actual.y - expected_y) <= 1,
                "cursor exceeded one logical pixel of oracle: transform=%d scale=%.6f point=(%.6f,%.6f) expected=(%d,%d) actual=(%d,%d)",
                transform,
                scale,
                point[1],
                point[2],
                expected_x,
                expected_y,
                actual.x,
                actual.y
            )
            check(
                clicked.monitor.name == selected_name,
                "click response changed selected monitor from %s to %s",
                selected_name,
                tostring(clicked.monitor.name)
            )
            checked_points = checked_points + 1
        end

        checked_scenarios = checked_scenarios + 1
        saw_transform[transform] = true
        saw_negative_origin = saw_negative_origin or selected.x < 0 or selected.y < 0
        saw_fractional_scale = saw_fractional_scale or scale % 1 ~= 0
    end
end

for transform = 0, 7 do
    assert(saw_transform[transform], "missing transform coverage: " .. transform)
end
assert(saw_negative_origin, "negative monitor origins were not covered")
assert(saw_fractional_scale, "fractional monitor scales were not covered")
assert(checked_scenarios == 8 * #scales)
assert(checked_points > 2000)

print(string.format(
    "computer geometry tests passed (%d points across %d mixed-monitor scenarios)",
    checked_points,
    checked_scenarios
))
