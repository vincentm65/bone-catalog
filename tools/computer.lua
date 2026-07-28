local catalog_description = "Control the active Hyprland monitor with hardened screenshots, freshness checks, and direct input execution."

local STATE_KEY = "computer"
local TIMEOUT_MS = 4000
local MAX_JSON_BYTES = 2 * 1024 * 1024
local MAX_IMAGE_BYTES = 25 * 1024 * 1024
local DEFAULT_SETTLE_MS = 300
local MAX_TEXT_BYTES = 10000

local function fail(message)
    error(message, 0)
end

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function integer(value, name, minimum, maximum)
    if not finite(value) or value % 1 ~= 0 or value < minimum or value > maximum then
        fail(name .. " must be an integer from " .. minimum .. " through " .. maximum)
    end
    return value
end

local function decode_json(raw, message)
    if type(raw) ~= "string" or #raw > MAX_JSON_BYTES then
        fail(message)
    end
    local ok, value = pcall(cjson.decode, raw)
    if not ok or type(value) ~= "table" then
        fail(message)
    end
    return value
end

local function exec_result(ctx, program, args, options)
    local opts = {
        timeout_ms = TIMEOUT_MS,
        max_output_bytes = MAX_JSON_BYTES,
        redact_args = true,
    }
    if options then
        for key, value in pairs(options) do
            opts[key] = value
        end
    end

    local ok, result = pcall(ctx.exec, program, args, opts)
    if not ok or type(result) ~= "table" then
        return nil, "spawn"
    end
    if result.spawned == false then
        return nil, "spawn"
    end
    if result.spawned ~= true then
        return nil, "post"
    end
    if result.timed_out or result.cancelled or result.output_limit_exceeded or result.error then
        return nil, "post"
    end
    if result.signal ~= nil then
        return nil, "post"
    end
    if result.exit_code ~= 0 then
        return nil, "exit"
    end
    if type(result.stdout) ~= "string" then
        return nil, "post"
    end
    return result.stdout
end

local function instance_environment(signature)
    local env = {}
    local wayland = os.getenv("WAYLAND_DISPLAY")
    if wayland and wayland ~= "" then
        env.WAYLAND_DISPLAY = wayland
    end
    if signature then
        env.HYPRLAND_INSTANCE_SIGNATURE = signature
    end
    return env
end

local function discover_signature(ctx, action)
    local raw, kind = exec_result(
        ctx,
        "hyprctl",
        { "-j", "instances" },
        { env = instance_environment() }
    )
    if not raw then
        if kind == "spawn" then
            fail(action .. ": hyprctl is unavailable; install Hyprland and run Bone in the target session")
        end
        fail(action .. ": Hyprland instance discovery failed")
    end

    local instances = decode_json(raw, action .. ": invalid Hyprland instance data")
    local inherited = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    local selected
    for _, instance in ipairs(instances) do
        if type(instance) == "table"
            and type(instance.signature) == "string"
            and instance.signature ~= ""
        then
            if inherited and instance.signature == inherited then
                return instance.signature
            end
            selected = selected or instance.signature
        end
    end
    if not selected then
        fail(action .. ": no Hyprland instance was found")
    end
    return selected
end

local function query_json(ctx, signature, args, action, message)
    local raw, kind = exec_result(ctx, "hyprctl", args, {
        env = instance_environment(signature),
    })
    if not raw then
        return nil, kind
    end
    local ok, value = pcall(decode_json, raw, action .. ": " .. message)
    if not ok then
        fail(value)
    end
    return value
end

local function validate_monitor(monitors, action)
    local selected
    for _, monitor in ipairs(monitors) do
        if type(monitor) == "table" and monitor.focused == true then
            if selected then
                fail(action .. ": multiple focused monitors were reported")
            end
            selected = monitor
        end
    end
    if not selected then
        fail(action .. ": no focused monitor was reported")
    end

    if type(selected.name) ~= "string" or selected.name == "" then
        fail(action .. ": invalid monitor geometry")
    end
    for _, key in ipairs({ "x", "y", "width", "height", "transform" }) do
        if not finite(selected[key]) or selected[key] % 1 ~= 0 then
            fail(action .. ": invalid monitor geometry")
        end
    end
    if selected.width <= 0 or selected.height <= 0 then
        fail(action .. ": invalid monitor geometry")
    end
    if not finite(selected.scale) or selected.scale <= 0 then
        fail(action .. ": invalid monitor geometry")
    end

    return {
        name = selected.name,
        x = selected.x,
        y = selected.y,
        width = selected.width,
        height = selected.height,
        scale = selected.scale,
        transform = selected.transform,
    }
end

local function validate_window(window, action)
    if next(window) == nil then
        return { address = "", workspace = 0, monitor = -1 }
    end
    if type(window.address) ~= "string"
        or not window.address:match("^0x[%da-fA-F]+$")
        or type(window.workspace) ~= "table"
        or not finite(window.workspace.id)
        or window.workspace.id % 1 ~= 0
        or not finite(window.monitor)
        or window.monitor % 1 ~= 0
    then
        fail(action .. ": invalid active-window fingerprint")
    end
    return {
        address = window.address,
        workspace = window.workspace.id,
        monitor = window.monitor,
    }
end

local function snapshot_once(ctx, signature, action)
    local monitors, monitor_kind = query_json(
        ctx,
        signature,
        { "-j", "monitors" },
        action,
        "invalid monitor data"
    )
    if not monitors then
        return nil, monitor_kind
    end
    local window, window_kind = query_json(
        ctx,
        signature,
        { "-j", "activewindow" },
        action,
        "invalid active-window data"
    )
    if not window then
        return nil, window_kind
    end
    return {
        monitor = validate_monitor(monitors, action),
        window = validate_window(window, action),
    }
end

local function snapshot_with_race(ctx, action)
    local signature = discover_signature(ctx, action)
    local snapshot, kind = snapshot_once(ctx, signature, action)
    if snapshot then
        return signature, snapshot
    end
    if kind ~= "exit" then
        if kind == "spawn" then
            fail(action .. ": hyprctl is unavailable; action was not sent")
        end
        fail(action .. ": Hyprland query failed; action was not sent")
    end

    local replacement = discover_signature(ctx, action)
    if replacement == signature then
        fail(action .. ": Hyprland query failed; action was not sent")
    end
    local _, sleep_kind = exec_result(ctx, "sleep", { "0.080" })
    if sleep_kind then
        fail(action .. ": Hyprland instance stabilization failed; action was not sent")
    end

    local retry, retry_kind = snapshot_once(ctx, replacement, action)
    if retry then
        local confirmed = discover_signature(ctx, action)
        if confirmed ~= replacement then
            fail("Hyprland instance changed again; action was not sent")
        end
        return replacement, retry
    end

    if retry_kind == "exit" then
        local latest = discover_signature(ctx, action)
        if latest ~= replacement then
            fail("Hyprland instance changed again; action was not sent")
        end
    end
    fail(action .. ": Hyprland query failed after instance change; action was not sent")
end

local function same_snapshot(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    for _, key in ipairs({ "name", "x", "y", "width", "height", "scale", "transform" }) do
        if left.monitor[key] ~= right.monitor[key] then
            return false
        end
    end
    for _, key in ipairs({ "address", "workspace", "monitor" }) do
        if left.window[key] ~= right.window[key] then
            return false
        end
    end
    return true
end

local function load_state(ctx)
    local raw = ctx.state.get(STATE_KEY)
    if raw == nil or raw == "" then
        return nil
    end
    local state = decode_json(raw, "invalid computer state; call observe again")
    if type(state.screenshot_id) ~= "string"
        or type(state.signature) ~= "string"
        or not finite(state.generation)
        or state.generation % 1 ~= 0
        or type(state.snapshot) ~= "table"
        or type(state.snapshot.monitor) ~= "table"
        or type(state.snapshot.window) ~= "table"
    then
        fail("invalid computer state; call observe again")
    end
    return state
end

local allowed_fields = {
    observe = { action = true, grid = true },
    move = { action = true, screenshot_id = true, x = true, y = true, settle_ms = true, grid = true },
    click = { action = true, screenshot_id = true, x = true, y = true, settle_ms = true, grid = true },
    double_click = { action = true, screenshot_id = true, x = true, y = true, settle_ms = true, grid = true },
    right_click = { action = true, screenshot_id = true, x = true, y = true, settle_ms = true, grid = true },
    drag = {
        action = true, screenshot_id = true,
        start_x = true, start_y = true, end_x = true, end_y = true,
        settle_ms = true, grid = true,
    },
    scroll = {
        action = true, screenshot_id = true, x = true, y = true, amount = true,
        settle_ms = true, grid = true,
    },
    type = { action = true, screenshot_id = true, text = true, settle_ms = true, grid = true },
    key = { action = true, screenshot_id = true, keys = true, settle_ms = true, grid = true },
    wait = { action = true, screenshot_id = true, duration_ms = true, grid = true },
}

local function validate_common(params)
    if type(params) ~= "table" or type(params.action) ~= "string" then
        fail("action must be an exact supported string")
    end
    local fields = allowed_fields[params.action]
    if not fields then
        fail("action must be observe, move, click, double_click, right_click, drag, scroll, type, key, or wait")
    end
    for key in pairs(params) do
        if type(key) ~= "string" or not fields[key] then
            fail("irrelevant field for " .. params.action .. ": " .. tostring(key))
        end
    end
    if params.grid ~= nil and type(params.grid) ~= "boolean" then
        fail("grid must be a boolean")
    end
    if params.action ~= "observe"
        and (type(params.screenshot_id) ~= "string" or params.screenshot_id == "")
    then
        fail("screenshot_id is required; call observe first")
    end
end

local function normalized_point(params, monitor, prefix)
    prefix = prefix or ""
    local x = params[prefix .. "x"]
    local y = params[prefix .. "y"]
    if not finite(x) or x < 0 or x > 1 then
        fail(prefix .. "x must be a finite number from 0 through 1")
    end
    if not finite(y) or y < 0 or y > 1 then
        fail(prefix .. "y must be a finite number from 0 through 1")
    end
    return monitor.x + math.floor(x * (monitor.width - 1) + 0.5),
        monitor.y + math.floor(y * (monitor.height - 1) + 0.5)
end

local key_codes = {
    CTRL = 29, LEFTCTRL = 29, SHIFT = 42, LEFTSHIFT = 42,
    ALT = 56, LEFTALT = 56, META = 125, SUPER = 125,
    ENTER = 28, TAB = 15, ESC = 1, ESCAPE = 1, BACKSPACE = 14,
    DELETE = 111, SPACE = 57, LEFT = 105, RIGHT = 106, UP = 103,
    DOWN = 108, HOME = 102, END = 107, PAGEUP = 104, PAGEDOWN = 109,
    INSERT = 110, CAPSLOCK = 58,
    A = 30, B = 48, C = 46, D = 32, E = 18, F = 33, G = 34,
    H = 35, I = 23, J = 36, K = 37, L = 38, M = 50, N = 49,
    O = 24, P = 25, Q = 16, R = 19, S = 31, T = 20, U = 22,
    V = 47, W = 17, X = 45, Y = 21, Z = 44,
    ["0"] = 11, ["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5,
    ["5"] = 6, ["6"] = 7, ["7"] = 8, ["8"] = 9, ["9"] = 10,
    F1 = 59, F2 = 60, F3 = 61, F4 = 62, F5 = 63, F6 = 64,
    F7 = 65, F8 = 66, F9 = 67, F10 = 68, F11 = 87, F12 = 88,
}

local function key_args(value)
    if type(value) ~= "string"
        or value == ""
        or #value > 128
        or not value:match("^[A-Za-z0-9+]+$")
    then
        fail("keys must be a combination such as CTRL+L, ENTER, or SHIFT+F10")
    end
    local codes = {}
    local seen = {}
    for token in value:upper():gmatch("[^+]+") do
        local code = key_codes[token]
        if not code then
            fail("unsupported key")
        end
        if seen[code] then
            fail("duplicate key")
        end
        seen[code] = true
        codes[#codes + 1] = code
    end
    local args = { "key" }
    for _, code in ipairs(codes) do
        args[#args + 1] = tostring(code) .. ":1"
    end
    for index = #codes, 1, -1 do
        args[#args + 1] = tostring(codes[index]) .. ":0"
    end
    return args
end

local function run_delivery(ctx, action, args)
    local _, kind = exec_result(ctx, "ydotool", args)
    if kind == "spawn" then
        fail(action .. ": ydotool is unavailable; configure a user ydotoold service")
    end
    if kind then
        fail(action .. ": ambiguous delivery")
    end
end

local function run_after_delivery(ctx, action, args)
    local ok = pcall(run_delivery, ctx, action, args)
    if not ok then
        fail(action .. ": ambiguous delivery")
    end
end

local function verify_pointer(ctx, signature, action, expected_x, expected_y)
    local value, kind = query_json(
        ctx,
        signature,
        { "-j", "cursorpos" },
        action,
        "invalid pointer position"
    )
    if not value or kind then
        fail(action .. ": ambiguous delivery")
    end
    if not finite(value.x) or not finite(value.y)
        or math.floor(value.x + 0.5) ~= expected_x
        or math.floor(value.y + 0.5) ~= expected_y
    then
        fail(action .. ": ambiguous delivery")
    end
end

local function move_and_verify(ctx, signature, action, x, y)
    run_delivery(ctx, action, { "mousemove", "--absolute", tostring(x), tostring(y) })
    verify_pointer(ctx, signature, action, x, y)
end

local function settle(ctx, action, duration)
    if duration == 0 then
        return
    end
    local _, kind = exec_result(ctx, "sleep", { string.format("%.3f", duration / 1000) })
    if kind then
        fail(action .. ": ambiguous delivery")
    end
end

local function perform_action(params, ctx, signature, snapshot)
    local action = params.action
    local monitor = snapshot.monitor
    if action == "move" then
        local x, y = normalized_point(params, monitor)
        move_and_verify(ctx, signature, action, x, y)
        settle(ctx, action, integer(params.settle_ms or DEFAULT_SETTLE_MS, "settle_ms", 0, 5000))
        return
    end
    if action == "click" or action == "double_click" or action == "right_click" then
        local x, y = normalized_point(params, monitor)
        move_and_verify(ctx, signature, action, x, y)
        if action == "double_click" then
            run_after_delivery(ctx, action, { "click", "--repeat", "2", "--next-delay", "100", "0xC0" })
        elseif action == "right_click" then
            run_after_delivery(ctx, action, { "click", "0xC1" })
        else
            run_after_delivery(ctx, action, { "click", "0xC0" })
        end
        fail(action .. ": ambiguous delivery")
    end
    if action == "drag" then
        local start_x, start_y = normalized_point(params, monitor, "start_")
        local end_x, end_y = normalized_point(params, monitor, "end_")
        move_and_verify(ctx, signature, action, start_x, start_y)
        run_after_delivery(ctx, action, { "click", "0x40" })
        run_after_delivery(ctx, action, { "mousemove", "--absolute", tostring(end_x), tostring(end_y) })
        run_after_delivery(ctx, action, { "click", "0x80" })
        fail(action .. ": ambiguous delivery")
    end
    if action == "scroll" then
        local x, y = normalized_point(params, monitor)
        local amount = integer(params.amount, "amount", -20, 20)
        if amount == 0 then
            fail("amount must not be zero")
        end
        move_and_verify(ctx, signature, action, x, y)
        run_after_delivery(ctx, action, {
            "click", "--repeat", tostring(math.abs(amount)),
            amount > 0 and "0xC4" or "0xC5",
        })
        fail(action .. ": ambiguous delivery")
    end
    if action == "type" then
        if type(params.text) ~= "string"
            or #params.text == 0
            or #params.text > MAX_TEXT_BYTES
            or params.text:find("\0", 1, true)
        then
            fail("text must be a non-empty string of at most 10000 bytes without NUL")
        end
        run_delivery(ctx, action, { "type", "--key-delay", "12", "--", params.text })
        fail(action .. ": ambiguous delivery")
    end
    if action == "key" then
        run_delivery(ctx, action, key_args(params.keys))
        fail(action .. ": ambiguous delivery")
    end
    if action == "wait" then
        local duration = integer(params.duration_ms or 1000, "duration_ms", 0, 10000)
        if duration > 0 then
            local _, kind = exec_result(ctx, "sleep", { string.format("%.3f", duration / 1000) })
            if kind then
                fail(action .. ": ambiguous delivery")
            end
        end
        return
    end
    fail("unsupported action")
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

local function uint32(data, offset)
    return data:byte(offset) * 16777216
        + data:byte(offset + 1) * 65536
        + data:byte(offset + 2) * 256
        + data:byte(offset + 3)
end

local function validate_png(data, action)
    if type(data) ~= "string"
        or #data > MAX_IMAGE_BYTES
        or data:sub(1, 8) ~= "\137PNG\r\n\26\n"
    then
        fail(action .. ": screenshot was not a valid bounded PNG")
    end

    local position = 9
    local saw_header = false
    local saw_data = false
    while position <= #data do
        if position + 11 > #data then
            fail(action .. ": screenshot PNG was truncated")
        end
        local length = uint32(data, position)
        position = position + 4
        if length > MAX_IMAGE_BYTES or position + length + 7 > #data then
            fail(action .. ": invalid PNG chunk length")
        end
        local chunk_type = data:sub(position, position + 3)
        local chunk_data = data:sub(position + 4, position + 3 + length)
        local expected_crc = uint32(data, position + 4 + length)
        if crc32(chunk_type .. chunk_data) ~= expected_crc then
            fail(action .. ": screenshot PNG CRC mismatch")
        end

        if chunk_type == "IHDR" then
            if saw_header or length ~= 13 or position ~= 13 then
                fail(action .. ": invalid PNG header")
            end
            if uint32(chunk_data, 1) == 0 or uint32(chunk_data, 5) == 0 then
                fail(action .. ": invalid PNG dimensions")
            end
            saw_header = true
        elseif chunk_type == "IDAT" then
            if not saw_header then
                fail(action .. ": invalid PNG data ordering")
            end
            saw_data = true
        elseif chunk_type == "IEND" then
            if length ~= 0 or not saw_header or not saw_data or position + 8 ~= #data + 1 then
                fail(action .. ": invalid PNG end")
            end
            return data
        end
        position = position + length + 8
    end
    fail(action .. ": PNG end chunk was missing")
end

local function grid_draw(width, height)
    local lines = {}
    for index = 1, 9 do
        local x = math.floor(index * (width - 1) / 10 + 0.5)
        local y = math.floor(index * (height - 1) / 10 + 0.5)
        lines[#lines + 1] = string.format("line %d,0 %d,%d", x, x, height - 1)
        lines[#lines + 1] = string.format("line 0,%d %d,%d", y, width - 1, y)
    end
    return table.concat(lines, " ")
end

local function capture(ctx, signature, monitor, grid, action)
    local image, kind = exec_result(ctx, "grim", {
        "-t", "png",
        "-g", string.format("%d,%d %dx%d", monitor.x, monitor.y, monitor.width, monitor.height),
        "-",
    }, {
        env = instance_environment(signature),
        max_output_bytes = MAX_IMAGE_BYTES,
    })
    if not image then
        if kind == "spawn" then
            fail(action .. ": grim is unavailable; install grim")
        end
        fail(action .. ": screenshot capture failed")
    end
    image = validate_png(image, action)

    if grid then
        local rendered, render_kind = exec_result(ctx, "magick", {
            "png:-", "-stroke", "rgba(255,255,255,0.22)",
            "-strokewidth", "1", "-fill", "none",
            "-draw", grid_draw(monitor.width, monitor.height), "png:-",
        }, {
            stdin = image,
            max_output_bytes = MAX_IMAGE_BYTES,
        })
        if not rendered then
            if render_kind == "spawn" then
                fail(action .. ": ImageMagick is unavailable; install ImageMagick")
            end
            fail(action .. ": grid rendering failed")
        end
        image = validate_png(rendered, action)
    end
    return image
end

local function save_response(ctx, prior, signature, snapshot, action, grid, image)
    local generation = prior and prior.generation + 1 or 1
    local screenshot_id = "computer-" .. tostring(generation)
    ctx.state.set(STATE_KEY, cjson.encode({
        screenshot_id = screenshot_id,
        generation = generation,
        signature = signature,
        snapshot = snapshot,
    }))
    return cjson.encode({
        content = cjson.encode({
            screenshot_id = screenshot_id,
            action = action,
            monitor = snapshot.monitor,
            coordinates = "Use finite normalized coordinates from 0 through 1 with this screenshot_id.",
            grid = grid,
        }),
        images = {
            {
                media_type = "image/png",
                data = ctx.codec.base64_encode(image),
            },
        },
        ephemeral_images = true,
    })
end

local function execute(params, ctx)
    validate_common(params)
    local action = params.action
    local prior = load_state(ctx)
    if action ~= "observe" then
        if not prior or params.screenshot_id ~= prior.screenshot_id then
            fail("stale screenshot_id; call observe and use the fresh screenshot_id")
        end
    end

    local signature, before = snapshot_with_race(ctx, action)
    if action ~= "observe" then
        if signature ~= prior.signature or not same_snapshot(before, prior.snapshot) then
            fail("screen context changed; action was not sent")
        end
        perform_action(params, ctx, signature, before)
    end

    local after = before
    if action ~= "observe" then
        local ok, next_signature, next_snapshot = pcall(snapshot_with_race, ctx, action)
        if not ok
            or next_signature ~= signature
            or not same_snapshot(before, next_snapshot)
        then
            fail(action .. ": ambiguous delivery")
        end
        after = next_snapshot
    end

    local ok, image = pcall(capture, ctx, signature, after.monitor, params.grid == true, action)
    if not ok then
        if action == "observe" or action == "wait" then
            fail(image)
        end
        fail(action .. ": ambiguous delivery")
    end
    return save_response(ctx, prior, signature, after, action, params.grid == true, image)
end

bone.tool.register({
    name = "computer",
    catalog_description = catalog_description,
    description = "Observe and control the active Hyprland monitor. Coordinates are finite normalized values from 0 through 1. Call observe first and pass the fresh screenshot_id to later actions. Input delivery is never retried.",
    safety = "danger",
    stateful = true,
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "observe", "move", "click", "double_click", "right_click", "drag", "scroll", "type", "key", "wait" },
            },
            screenshot_id = { type = "string" },
            x = { type = "number", minimum = 0, maximum = 1 },
            y = { type = "number", minimum = 0, maximum = 1 },
            start_x = { type = "number", minimum = 0, maximum = 1 },
            start_y = { type = "number", minimum = 0, maximum = 1 },
            end_x = { type = "number", minimum = 0, maximum = 1 },
            end_y = { type = "number", minimum = 0, maximum = 1 },
            amount = { type = "integer", minimum = -20, maximum = 20 },
            text = { type = "string", minLength = 1, maxLength = 10000 },
            keys = { type = "string" },
            duration_ms = { type = "integer", minimum = 0, maximum = 10000 },
            settle_ms = { type = "integer", minimum = 0, maximum = 5000 },
            grid = { type = "boolean" },
        },
        required = { "action" },
        additionalProperties = false,
    },
    execute = execute,
})
