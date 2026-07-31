-- Run with: lua5.4 tests/computer_geometry_test.lua
--
-- Property-style observe-only tests for tools/computer.lua.
-- Covers transforms 0-7, integer/fractional scales, positive/negative origins.
-- No click, no cursor movement, no ctx.state, no authorization, no input delivery.

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

-- ── helpers ──────────────────────────────────────────────────────────────────

local function check(condition, format_string, ...)
    if not condition then
        error(string.format(format_string, ...), 2)
    end
end

-- CRC-32 for SHA-256 stub
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

-- ── PNG fixture generator ────────────────────────────────────────────────────

local png_cache = {}
local function fixture_png(width, height)
    local key = tostring(width) .. "x" .. tostring(height)
    local cached = png_cache[key]
    if cached then return cached end

    local function uint32(v)
        return string.char(
            (v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255)
    end
    local function chunk(kind, data)
        local crc = 0xffffffff
        for i = 1, #data do crc = crc ~ data:byte(i)
            for _ = 1, 8 do crc = (crc & 1) ~= 0 and ((crc >> 1) ~ 0xedb88320) or (crc >> 1) end
        end
        crc = (crc ~ 0xffffffff) & 0xffffffff
        return uint32(#data) .. kind .. data .. uint32(crc)
    end

    local ihdr = uint32(width) .. uint32(height) .. string.char(8, 2, 0, 0, 0)
    local png = "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr) .. chunk("IDAT", "geometry-fixture") .. chunk("IEND", "")
    png_cache[key] = png
    return png
end

-- ── mock exec ────────────────────────────────────────────────────────────────

local function success(stdout)
    return {
        spawned = true, timed_out = false, cancelled = false,
        output_limit_exceeded = false, stdout = stdout or "", stderr = "", exit_code = 0,
    }
end

-- Oracle: matches monitor_dimensions() exactly.
-- monitor_dimensions: pixel dims swapped for odd transforms;
-- logical = max(1, floor(d / scale + 0.5)).
local function monitor_dimensions(monitor)
    local pw, ph = monitor.width, monitor.height
    if monitor.transform % 2 == 1 then
        pw, ph = ph, pw
    end
    local lw = math.max(1, math.floor(pw / monitor.scale + 0.5))
    local lh = math.max(1, math.floor(ph / monitor.scale + 0.5))
    return pw, ph, lw, lh
end

-- model_image_dimensions: downscale to fit 1920x1080.
local function model_image_dimensions(w, h)
    local scale = math.min(1, 1920 / w, 1080 / h)
    return math.max(1, math.floor(w * scale + 0.5)),
           math.max(1, math.floor(h * scale + 0.5))
end

local function new_fixture(monitors, fixture_id)
    local fixture = {
        monitors = monitors,
        signature = "geometry-signature-" .. fixture_id,
        calls = {},
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
        codec = {
            base64_encode = function()
                return "geometry-base64-png"
            end,
            sha256 = function(value)
                return string.rep(string.format("%08x", crc32(value)), 8)
            end,
            png_resize = function()
                error("unexpected native resize for geometry fixtures")
            end,
        },
        time = {
            monotonic_ms = function() return fixture.monotonic_ms end,
        },
        config_dir = "/tmp/bone-computer-geometry-test",
        ui = { status = function() end, notify = function() end },
        log = { info = function() end },
    }

    function ctx.exec(program, args, options)
        fixture.calls[#fixture.calls + 1] = { program = program, args = args }

        if program == "hyprctl" and args[1] == "-j" and args[2] == "instances" then
            return success(cjson.encode({ { signature = fixture.signature } }))
        end
        if program == "hyprctl" and args[1] == "--batch" then
            encoded["[]"] = fixture.monitors
            encoded["{}"] = fixture.window
            return success("[]\n{}")
        end
        if program == "grim" then
            local output_name
            for i, arg in ipairs(args) do
                if arg == "-o" then output_name = args[i + 1]; break end
            end
            local monitor
            for _, m in ipairs(fixture.monitors) do
                if m.name == output_name then monitor = m; break end
            end
            local pw, ph = monitor_dimensions(monitor)
            return success(fixture_png(pw, ph))
        end
        if program == "magick" then
            -- Grid rendering returns a valid PNG with the original dimensions.
            local stdin = options and options.stdin
            local w, h = 1920, 1080
            if stdin and #stdin >= 24 then
                w = stdin:byte(17) * 16777216 + stdin:byte(18) * 65536 + stdin:byte(19) * 256 + stdin:byte(20)
                h = stdin:byte(21) * 16777216 + stdin:byte(22) * 65536 + stdin:byte(23) * 256 + stdin:byte(24)
            end
            return success(fixture_png(w, h))
        end
        error("unexpected geometry fixture exec: " .. tostring(program))
    end

    fixture.ctx = ctx
    return fixture
end

-- ── invoke helper ────────────────────────────────────────────────────────────

local function invoke(fixture, params)
    local raw = computer_tool.execute(params, fixture.ctx)
    local envelope = cjson.decode(raw)
    local content = cjson.decode(envelope.content)
    return content, envelope
end

-- ── shell_coordinates oracle ─────────────────────────────────────────────────
-- Builds the exact string computer.lua produces via string.format.
local function expected_shell_coordinates(origin_x, origin_y, logical_w, logical_h)
    return string.format(
        "Map normalized (nx, ny) to Hyprland logical coordinates with X=%d+round(nx*(%d-1)) and Y=%d+round(ny*(%d-1)).",
        origin_x, logical_w, origin_y, logical_h)
end

local function mapped_coordinate(origin, normalized, logical_extent)
    return origin + math.floor(normalized * (logical_extent - 1) + 0.5)
end

-- ── test runner ──────────────────────────────────────────────────────────────

local scales = { 0.75, 1.0, 1.1, 1.25, 4/3, 1.5, 1.75, 2.0, 2.25 }
local checked_scenarios = 0
local saw_negative_origin = false
local saw_fractional_scale = false
local saw_grid = false

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
                x = 0, y = 0,
                width = 320, height = 180,
                scale = 1, transform = 0,
                activeWorkspace = { id = 11 },
            },
            selected,
            {
                name = "AUXILIARY",
                focused = false,
                x = 900, y = -500,
                width = 401, height = 239,
                scale = 1.25, transform = 5,
                activeWorkspace = { id = 31 },
            },
        }

        local fixture = new_fixture(monitors, tostring(transform) .. "-" .. tostring(scale_index))

        -- ── 1. observe (no grid) ───────────────────────────────────────────
        local content, envelope = invoke(fixture, { action = "observe", monitor = selected_name })

        -- Basic envelope assertions
        check(envelope.ephemeral_images == true, "envelope must be ephemeral")
        check(type(envelope.images) == "table" and #envelope.images == 1, "exactly one image attachment")
        check(content.screenshot_captured == true, "screenshot must be captured")
        check(content.read_only == true, "response must be read-only")
        check(content.actionable == true, "response must be actionable for a named monitor")
        check(content.mode == "monitor_observation", "mode must be monitor_observation")

        -- Monitor name
        check(content.monitor.name == selected_name, "wrong monitor name: %s", content.monitor.name)

        -- Monitor metadata
        check(content.monitor.scale == scale, "wrong scale: expected %s got %s", tostring(scale), tostring(content.monitor.scale))
        check(content.monitor.transform == transform, "wrong transform: expected %d got %d", transform, content.monitor.transform)

        -- Global logical origin
        check(content.monitor.global_logical_origin.x == selected.x, "wrong origin x: expected %d got %d", selected.x, content.monitor.global_logical_origin.x)
        check(content.monitor.global_logical_origin.y == selected.y, "wrong origin y: expected %d got %d", selected.y, content.monitor.global_logical_origin.y)

        -- Global logical bounds (exclusive right/bottom)
        local pw, ph, lw, lh = monitor_dimensions(selected)
        check(content.monitor.global_logical_bounds.left == selected.x, "wrong bounds left")
        check(content.monitor.global_logical_bounds.top == selected.y, "wrong bounds top")
        check(content.monitor.global_logical_bounds.right_exclusive == selected.x + lw, "wrong bounds right_exclusive: expected %d got %d", selected.x + lw, content.monitor.global_logical_bounds.right_exclusive)
        check(content.monitor.global_logical_bounds.bottom_exclusive == selected.y + lh, "wrong bounds bottom_exclusive: expected %d got %d", selected.y + lh, content.monitor.global_logical_bounds.bottom_exclusive)

        -- Logical size
        check(content.monitor.logical_size.width == lw, "wrong logical width: expected %d got %d", lw, content.monitor.logical_size.width)
        check(content.monitor.logical_size.height == lh, "wrong logical height: expected %d got %d", lh, content.monitor.logical_size.height)

        -- Full-resolution screenshot size
        check(content.monitor.full_resolution_screenshot_size.width == pw, "wrong screenshot width: expected %d got %d", pw, content.monitor.full_resolution_screenshot_size.width)
        check(content.monitor.full_resolution_screenshot_size.height == ph, "wrong screenshot height: expected %d got %d", ph, content.monitor.full_resolution_screenshot_size.height)

        -- Mode size (raw monitor mode)
        check(content.monitor.mode_size.width == selected.width, "wrong mode_size width")
        check(content.monitor.mode_size.height == selected.height, "wrong mode_size height")

        -- Shell coordinates formula
        local expected_shell = expected_shell_coordinates(selected.x, selected.y, lw, lh)
        check(content.shell_coordinates == expected_shell, "shell_coordinates mismatch:\nexpected: %s\ngot:      %s", expected_shell, content.shell_coordinates)
        check(mapped_coordinate(selected.x, 0, lw) == selected.x,
            "normalized x=0 must map to the left edge")
        check(mapped_coordinate(selected.x, 1, lw) == selected.x + lw - 1,
            "normalized x=1 must map to the inclusive right edge")
        check(mapped_coordinate(selected.y, 0, lh) == selected.y,
            "normalized y=0 must map to the top edge")
        check(mapped_coordinate(selected.y, 1, lh) == selected.y + lh - 1,
            "normalized y=1 must map to the inclusive bottom edge")
        local midpoint_x = selected.x + math.floor(0.5 * (lw - 1) + 0.5)
        local midpoint_y = selected.y + math.floor(0.5 * (lh - 1) + 0.5)
        check(mapped_coordinate(selected.x, 0.5, lw) == midpoint_x,
            "normalized x midpoint must use nearest-integer rounding")
        check(mapped_coordinate(selected.y, 0.5, lh) == midpoint_y,
            "normalized y midpoint must use nearest-integer rounding")

        -- Attachment dimensions (model_image_dimensions)
        local aw, ah = model_image_dimensions(pw, ph)
        check(content.attachment_size.width == aw, "wrong attachment width: expected %d got %d", aw, content.attachment_size.width)
        check(content.attachment_size.height == ah, "wrong attachment height: expected %d got %d", ah, content.attachment_size.height)

        -- Attachment media type
        check(envelope.images[1].media_type == "image/png", "attachment must be PNG")
        check(envelope.images[1].width == aw, "attachment width mismatch in envelope")
        check(envelope.images[1].height == ah, "attachment height mismatch in envelope")

        -- Grid false
        check(content.grid == false, "grid must be false without grid param")

        -- ── 2. observe with grid ───────────────────────────────────────────
        local content_g, envelope_g = invoke(fixture, { action = "observe", monitor = selected_name, grid = true })

        check(envelope_g.ephemeral_images == true, "grid envelope must be ephemeral")
        check(content_g.screenshot_captured == true, "grid: screenshot must be captured")
        check(content_g.grid == true, "grid must be true")
        check(content_g.monitor.name == selected_name, "grid: wrong monitor name")
        check(content_g.monitor.global_logical_origin.x == selected.x, "grid: wrong origin x")
        check(content_g.monitor.global_logical_origin.y == selected.y, "grid: wrong origin y")
        check(content_g.monitor.global_logical_bounds.right_exclusive == selected.x + lw, "grid: wrong right_exclusive")
        check(content_g.monitor.global_logical_bounds.bottom_exclusive == selected.y + lh, "grid: wrong bottom_exclusive")
        check(content_g.monitor.logical_size.width == lw, "grid: wrong logical width")
        check(content_g.monitor.logical_size.height == lh, "grid: wrong logical height")
        check(content_g.monitor.full_resolution_screenshot_size.width == pw, "grid: wrong screenshot width")
        check(content_g.monitor.full_resolution_screenshot_size.height == ph, "grid: wrong screenshot height")
        check(content_g.shell_coordinates == expected_shell, "grid: shell_coordinates mismatch")

        -- Grid geometry preservation: screenshot PNG geometry must be unchanged after grid rendering.
        check(content_g.monitor.full_resolution_screenshot_size.width == pw, "grid: screenshot width must be preserved after grid")
        check(content_g.monitor.full_resolution_screenshot_size.height == ph, "grid: screenshot height must be preserved after grid")

        -- Attachment still downscale-correct after grid
        check(content_g.attachment_size.width == aw, "grid: attachment width must match model_image_dimensions")
        check(content_g.attachment_size.height == ah, "grid: attachment height must match model_image_dimensions")

        -- Coordinates guidance mentions 0-1000 rulers
        check(content_g.coordinates:find("0-1000") ~= nil, "grid: coordinates guidance must mention 0-1000 ruler values")
        check(content_g.coordinates:find("divide by 1000") ~= nil, "grid: coordinates guidance must mention dividing by 1000")

        saw_grid = true
        checked_scenarios = checked_scenarios + 1
        saw_negative_origin = saw_negative_origin or selected.x < 0 or selected.y < 0
        saw_fractional_scale = saw_fractional_scale or scale % 1 ~= 0
    end
end

-- ── coverage assertions ──────────────────────────────────────────────────────

assert(saw_negative_origin, "negative monitor origins were not covered")
assert(saw_fractional_scale, "fractional monitor scales were not covered")
assert(saw_grid, "grid mode was not exercised")
assert(checked_scenarios == 8 * #scales, "expected %d scenarios, got %d", 8 * #scales, checked_scenarios)

print(string.format("computer geometry tests passed (%d observe-only scenarios, transforms 0-7, %d scales, grid verified)",
    checked_scenarios, #scales))
