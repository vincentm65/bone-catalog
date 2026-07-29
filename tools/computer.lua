local catalog_description = "Control Hyprland with hardened screenshots, AT-SPI semantic targets, freshness checks, and direct input execution."

local STATE_KEY = "computer"
local EXEC_TIMEOUT_MS = 4000
local SLEEP_TIMEOUT_MARGIN_MS = 1000
local CAPTURE_TIMEOUT_MS = 15000
local MAX_JSON_BYTES = 2 * 1024 * 1024
local MAX_IMAGE_BYTES = 25 * 1024 * 1024
local MODEL_IMAGE_MAX_WIDTH = 1920
local MODEL_IMAGE_MAX_HEIGHT = 1080
local DEFAULT_SETTLE_MS = 80
local CLICK_SETTLE_MS = 120
local PRE_CLICK_SETTLE_MS = 50
local CLICK_HOLD_MS = 30
local INSPECT_RADIUS = 96
local INSPECT_SIZE = 768
local TARGET_PATCH_RADIUS = 24
local TARGET_LOCK_TTL_SECONDS = 60
local SCREENSHOT_TTL_SECONDS = 120
local MAX_TEXT_BYTES = 10000
local MAX_DIAGNOSTIC_BYTES = 1024
local MAX_SEMANTIC_BYTES = 256 * 1024
local MAX_SEMANTIC_TARGETS = 64
local SEMANTIC_TIMEOUT_MS = 2500

local function fail(message)
    error(message, 0)
end

local function bounded_diagnostic(value)
    if value == nil then
        return nil
    end
    local text = tostring(value):gsub("[%z\1-\8\11\12\14-\31\127]", "?")
    if #text > MAX_DIAGNOSTIC_BYTES then
        text = text:sub(1, MAX_DIAGNOSTIC_BYTES) .. "..."
    end
    return text
end

local function exec_diagnostic(result, call_error)
    result = type(result) == "table" and result or {}
    local details = {}
    local function add(name, value)
        value = bounded_diagnostic(value)
        if value and value ~= "" then
            details[#details + 1] = name .. "=" .. value
        end
    end

    add("error", call_error or result.error)
    add("stderr", result.stderr)
    add("exit_code", result.exit_code)
    add("signal", result.signal)
    if result.timed_out then
        details[#details + 1] = "timed_out=true"
    end
    if result.cancelled then
        details[#details + 1] = "cancelled=true"
    end
    if result.output_limit_exceeded then
        details[#details + 1] = "output_limit_exceeded=true"
    end
    if #details == 0 then
        details[1] = "unknown execution failure"
    end
    return table.concat(details, ", ")
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

local json = cjson

local function decode_json(raw, message)
    if type(raw) ~= "string" or #raw > MAX_JSON_BYTES then
        fail(message)
    end
    local ok, value = pcall(json.decode, raw)
    if not ok or type(value) ~= "table" then
        fail(message)
    end
    return value
end

local function exec_result(ctx, program, args, options)
    local opts = {
        timeout_ms = EXEC_TIMEOUT_MS,
        max_output_bytes = MAX_JSON_BYTES,
        redact_args = true,
    }
    if options then
        for key, value in pairs(options) do
            opts[key] = value
        end
    end

    local ok, result = pcall(ctx.exec, program, args, opts)
    if not ok then
        return nil, "post", exec_diagnostic(nil, result)
    end
    if type(result) ~= "table" then
        return nil, "post", "invalid execution result"
    end
    if result.spawned == false then
        return nil, "spawn", exec_diagnostic(result)
    end
    if result.spawned ~= true then
        return nil, "post", exec_diagnostic(result)
    end
    if result.cancelled then
        return nil, "cancelled", exec_diagnostic(result)
    end
    if result.timed_out or result.output_limit_exceeded or result.error then
        return nil, "post", exec_diagnostic(result)
    end
    if result.signal ~= nil then
        return nil, "post", exec_diagnostic(result)
    end
    if result.exit_code ~= 0 then
        return nil, "exit", exec_diagnostic(result)
    end
    if type(result.stdout) ~= "string" then
        return nil, "post", exec_diagnostic(result)
    end
    return result.stdout
end

local instance_displays = {}

local function instance_environment(signature)
    local env = {}
    local wayland = signature and instance_displays[signature] or os.getenv("WAYLAND_DISPLAY")
    if wayland and wayland ~= "" then
        env.WAYLAND_DISPLAY = wayland
    end
    if signature then
        env.HYPRLAND_INSTANCE_SIGNATURE = signature
    end
    return env
end

local function discover_signature(ctx, action, rediscover)
    local inherited = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")

    local raw, kind, detail = exec_result(
        ctx,
        "hyprctl",
        { "-j", "instances" },
        { env = instance_environment() }
    )
    if not raw then
        if kind == "spawn" then
            fail(action .. ": hyprctl is unavailable; install Hyprland and run Bone in the target session (" .. detail .. ")")
        end
        fail(action .. ": Hyprland instance discovery failed (" .. detail .. ")")
    end

    local instances = decode_json(raw, action .. ": invalid Hyprland instance data")
    local selected
    for _, instance in ipairs(instances) do
        if type(instance) == "table" then
            local signature = instance.signature or instance.instance
            if type(signature) == "string" and signature ~= "" then
                if type(instance.wl_socket) == "string" and instance.wl_socket ~= "" then
                    instance_displays[signature] = instance.wl_socket
                end
                if inherited and signature == inherited then
                    return signature
                end
                selected = selected or signature
            end
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

local function validate_monitor(monitors, action, requested)
    local focused
    local selected
    local other
    local other_count = 0
    local available = {}

    for _, monitor in ipairs(monitors) do
        if type(monitor) == "table" and type(monitor.name) == "string" and monitor.name ~= "" then
            available[#available + 1] = monitor.name
            if monitor.focused == true then
                if focused then
                    fail(action .. ": multiple focused monitors were reported")
                end
                focused = monitor
            else
                other = monitor
                other_count = other_count + 1
            end
            if requested == monitor.name then
                selected = monitor
            end
        end
    end
    table.sort(available)
    local available_text = table.concat(available, ", ")

    if requested == nil or requested == "focused" then
        selected = focused
    elseif requested == "other" then
        if other_count ~= 1 then
            fail(action .. ": 'other' requires exactly two monitors; available monitors: " .. available_text)
        end
        selected = other
    elseif type(requested) ~= "string" or requested == "" then
        fail("monitor must be a non-empty output name, 'focused', or 'other'")
    end

    if not selected then
        if requested == nil or requested == "focused" then
            fail(action .. ": no focused monitor was reported")
        end
        fail(action .. ": monitor was not found; available monitors: " .. available_text)
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
    local workspace
    if selected.activeWorkspace ~= nil then
        workspace = type(selected.activeWorkspace) == "table" and selected.activeWorkspace.id or nil
        if not finite(workspace) or workspace % 1 ~= 0 then
            fail(action .. ": invalid monitor workspace")
        end
    end

    return {
        name = selected.name,
        x = selected.x,
        y = selected.y,
        width = selected.width,
        height = selected.height,
        scale = selected.scale,
        transform = selected.transform,
        workspace = workspace,
        focused = selected.focused == true,
    }, available
end

local function validate_window(window, action)
    if next(window) == nil then
        return { address = "", workspace = 0, monitor = -1 }
    end
    local position = window.at
    local size = window.size
    if type(window.address) ~= "string"
        or not window.address:match("^0x[%da-fA-F]+$")
        or type(window.workspace) ~= "table"
        or not finite(window.workspace.id)
        or window.workspace.id % 1 ~= 0
        or not finite(window.monitor)
        or window.monitor % 1 ~= 0
        or not finite(window.pid)
        or window.pid % 1 ~= 0
        or window.pid <= 0
        or type(window.title) ~= "string"
        or #window.title > 4096
        or type(window.class) ~= "string"
        or #window.class > 1024
        or type(window.stableId) ~= "string"
        or window.stableId == ""
        or #window.stableId > 256
        or type(position) ~= "table"
        or not finite(position[1]) or position[1] % 1 ~= 0
        or not finite(position[2]) or position[2] % 1 ~= 0
        or type(size) ~= "table"
        or not finite(size[1]) or size[1] % 1 ~= 0 or size[1] <= 0
        or not finite(size[2]) or size[2] % 1 ~= 0 or size[2] <= 0
    then
        fail(action .. ": invalid active-window fingerprint")
    end
    return {
        address = window.address,
        workspace = window.workspace.id,
        monitor = window.monitor,
        pid = window.pid,
        title = window.title,
        class = window.class,
        stable_id = window.stableId,
        x = position[1],
        y = position[2],
        width = size[1],
        height = size[2],
    }
end

local function json_value_end(raw, start_index)
    local first = raw:sub(start_index, start_index)
    if first ~= "[" and first ~= "{" then
        return nil
    end
    local depth = 0
    local quoted = false
    local escaped = false
    for index = start_index, #raw do
        local byte = raw:byte(index)
        if quoted then
            if escaped then
                escaped = false
            elseif byte == 92 then
                escaped = true
            elseif byte == 34 then
                quoted = false
            end
        elseif byte == 34 then
            quoted = true
        elseif byte == 91 or byte == 123 then
            depth = depth + 1
        elseif byte == 93 or byte == 125 then
            depth = depth - 1
            if depth == 0 then
                return index
            elseif depth < 0 then
                return nil
            end
        end
    end
    return nil
end

local function split_snapshot_json(raw, action)
    local first_start = raw:find("%S")
    local first_end = first_start and json_value_end(raw, first_start)
    local second_start = first_end and raw:find("%S", first_end + 1)
    local second_end = second_start and json_value_end(raw, second_start)
    if not first_end
        or raw:sub(first_start, first_start) ~= "["
        or not second_end
        or raw:sub(second_start, second_start) ~= "{"
        or raw:find("%S", second_end + 1)
    then
        fail(action .. ": invalid batched Hyprland data")
    end
    return raw:sub(first_start, first_end), raw:sub(second_start, second_end)
end

local function snapshot_once(ctx, signature, action, requested_monitor)
    local raw, kind = exec_result(ctx, "hyprctl", {
        "--batch", "j/monitors;j/activewindow",
    }, {
        env = instance_environment(signature),
    })
    if not raw then
        return nil, kind
    end
    local monitors_raw, window_raw = split_snapshot_json(raw, action)
    local monitors = decode_json(monitors_raw, action .. ": invalid monitor data")
    local window = decode_json(window_raw, action .. ": invalid active-window data")
    local monitor, available_monitors = validate_monitor(monitors, action, requested_monitor)
    return {
        monitor = monitor,
        available_monitors = available_monitors,
        window = validate_window(window, action),
    }
end

local function snapshot_with_race(ctx, action, requested_monitor)
    local signature = discover_signature(ctx, action)
    local snapshot, kind = snapshot_once(ctx, signature, action, requested_monitor)
    if snapshot then
        return signature, snapshot
    end
    if kind ~= "exit" then
        if kind == "spawn" then
            fail(action .. ": hyprctl is unavailable; action was not sent")
        end
        fail(action .. ": Hyprland query failed; action was not sent")
    end

    local replacement = discover_signature(ctx, action, true)
    if replacement == signature then
        fail(action .. ": Hyprland query failed; action was not sent")
    end
    local _, sleep_kind = exec_result(ctx, "sleep", { "0.080" })
    if sleep_kind then
        fail(action .. ": Hyprland instance stabilization failed; action was not sent")
    end

    local retry, retry_kind = snapshot_once(ctx, replacement, action, requested_monitor)
    if retry then
        local confirmed = discover_signature(ctx, action, true)
        if confirmed ~= replacement then
            fail("Hyprland instance changed again; action was not sent")
        end
        return replacement, retry
    end

    if retry_kind == "exit" then
        local latest = discover_signature(ctx, action, true)
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
    for _, key in ipairs({ "address", "workspace", "monitor", "pid", "title", "class", "stable_id", "x", "y", "width", "height" }) do
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
    observe = { action = true, screenshot_id = true, monitor = true, grid = true },
    inspect = { action = true, screenshot_id = true, x = true, y = true, radius = true, grid = true },
    semantic_find = { action = true, screenshot_id = true, grid = true },
    semantic_click = {
        action = true, screenshot_id = true, semantic_id = true,
        target_label = true, settle_ms = true, grid = true,
    },
    move = { action = true, screenshot_id = true, x = true, y = true, settle_ms = true, grid = true },
    click = {
        action = true, screenshot_id = true, x = true, y = true,
        target_label = true, settle_ms = true, grid = true,
    },
    click_locked = {
        action = true, screenshot_id = true, target_token = true,
        target_label = true, settle_ms = true, grid = true,
    },
    double_click = {
        action = true, screenshot_id = true, x = true, y = true,
        target_label = true, settle_ms = true, grid = true,
    },
    right_click = {
        action = true, screenshot_id = true, x = true, y = true,
        target_label = true, settle_ms = true, grid = true,
    },
    drag = {
        action = true, screenshot_id = true,
        start_x = true, start_y = true, end_x = true, end_y = true,
        settle_ms = true, grid = true,
    },
    scroll = {
        action = true, screenshot_id = true, x = true, y = true,
        amount = true, settle_ms = true, grid = true,
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
        fail("action must be observe, inspect, semantic_find, semantic_click, move, click, click_locked, double_click, right_click, drag, scroll, type, key, or wait")
    end
    for key in pairs(params) do
        if type(key) ~= "string" or not fields[key] then
            fail("irrelevant field for " .. params.action .. ": " .. tostring(key))
        end
    end
    if params.grid ~= nil and type(params.grid) ~= "boolean" then
        fail("grid must be a boolean")
    end
    if params.target_label ~= nil
        and (type(params.target_label) ~= "string"
            or #params.target_label == 0
            or #params.target_label > 80
            or params.target_label:find("[\r\n]"))
    then
        fail("target_label must be a non-empty single-line description of at most 80 bytes")
    end
    if params.action == "observe"
        and params.monitor ~= nil
        and (type(params.monitor) ~= "string" or params.monitor == "")
    then
        fail("monitor must be a non-empty output name, 'focused', or 'other'")
    end
    local requires_screenshot = params.action ~= "observe"
    if requires_screenshot
        and (type(params.screenshot_id) ~= "string" or params.screenshot_id == "")
    then
        fail("screenshot_id is required for every non-observe action; call computer_observe first and copy its exact screenshot_id")
    end
    if params.action == "semantic_click"
        and (type(params.semantic_id) ~= "string"
            or #params.semantic_id == 0
            or #params.semantic_id > 160
            or not params.semantic_id:match("^atspi:%d+[%d%.]*$"))
    then
        fail("semantic_id is required for semantic_click; call semantic_find first")
    end
    if params.action == "click_locked"
        and (type(params.target_token) ~= "string" or params.target_token == "")
    then
        fail("target_token is required for click_locked; call inspect first")
    end
end

local function monitor_dimensions(monitor)
    if monitor.transform < 0 or monitor.transform > 7 then
        fail("invalid monitor transform")
    end
    local pixel_width = monitor.width
    local pixel_height = monitor.height
    if monitor.transform % 2 == 1 then
        pixel_width, pixel_height = pixel_height, pixel_width
    end
    return pixel_width,
        pixel_height,
        math.max(1, math.floor(pixel_width / monitor.scale + 0.5)),
        math.max(1, math.floor(pixel_height / monitor.scale + 0.5))
end

local function geometry_fingerprint(ctx, monitor, image_width, image_height, action)
    local ok, hash = pcall(ctx.codec.sha256, table.concat({
        monitor.name,
        tostring(monitor.x), tostring(monitor.y),
        tostring(monitor.width), tostring(monitor.height),
        string.format("%.9f", monitor.scale),
        tostring(monitor.transform),
        tostring(image_width), tostring(image_height),
    }, ":"))
    if not ok or type(hash) ~= "string" or #hash ~= 64 then
        fail(action .. ": geometry fingerprinting failed")
    end
    return hash
end

-- Grim returns output-oriented pixels. Hyprland transform values 0-7 determine
-- that oriented extent; compositor cursor coordinates then use the same
-- top-left-oriented logical axes, scaled and offset into the global layout.
local function source_point(monitor, image_width, image_height, source_x, source_y)
    local oriented_width, oriented_height, logical_width, logical_height = monitor_dimensions(monitor)
    if image_width ~= oriented_width or image_height ~= oriented_height then
        fail("screenshot geometry no longer matches the monitor")
    end
    source_x = math.max(0, math.min(image_width - 1, math.floor(source_x + 0.5)))
    source_y = math.max(0, math.min(image_height - 1, math.floor(source_y + 0.5)))
    local local_x = math.floor((source_x + 0.5) / monitor.scale)
    local local_y = math.floor((source_y + 0.5) / monitor.scale)
    local_x = math.max(0, math.min(logical_width - 1, local_x))
    local_y = math.max(0, math.min(logical_height - 1, local_y))
    return monitor.x + local_x, monitor.y + local_y
end

local function accuracy_log(ctx, message)
    if os.getenv("BONE_IMAGE_DEBUG") == "1" then
        ctx.log.info("computer accuracy: " .. message)
    end
end

local function normalized_source(params, monitor, prefix)
    prefix = prefix or ""
    local x = params[prefix .. "x"]
    local y = params[prefix .. "y"]
    if not finite(x) or x < 0 or x > 1 then
        fail(prefix .. "x must be a finite number from 0 through 1")
    end
    if not finite(y) or y < 0 or y > 1 then
        fail(prefix .. "y must be a finite number from 0 through 1")
    end
    local width, height = monitor_dimensions(monitor)
    return math.floor(x * (width - 1) + 0.5),
        math.floor(y * (height - 1) + 0.5), width, height
end

local function normalized_point(params, monitor, prefix)
    local source_x, source_y, width, height = normalized_source(params, monitor, prefix)
    return source_point(monitor, width, height, source_x, source_y)
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

local POST_INPUT_FAILURE = {}

local function post_input_failure(reason, detail)
    error({ marker = POST_INPUT_FAILURE, reason = reason, detail = detail }, 0)
end

local function run_delivery(ctx, action, args)
    local _, kind, detail = exec_result(ctx, "ydotool", args)
    if kind == "spawn" then
        fail(action .. ": ydotool is unavailable; configure a user ydotoold service")
    end
    if kind then
        post_input_failure("input_delivery_ambiguous", detail)
    end
end

local function move_and_verify(ctx, signature, action, x, y)
    local _, kind, detail = exec_result(ctx, "hyprctl", {
        "dispatch", "movecursor", tostring(x), tostring(y),
    }, {
        env = instance_environment(signature),
    })
    if kind then
        post_input_failure("pointer_delivery_ambiguous", detail)
    end
end

local function settle(ctx, action, duration)
    if duration == 0 then
        return
    end
    local _, kind, detail = exec_result(ctx, "sleep", { string.format("%.3f", duration / 1000) }, {
        timeout_ms = math.max(EXEC_TIMEOUT_MS, duration + SLEEP_TIMEOUT_MARGIN_MS),
    })
    if kind then
        post_input_failure("input_settle_failed", detail)
    end
end

local function settle_duration(params, action)
    local default = (action == "click" or action == "click_locked" or action == "semantic_click" or action == "double_click" or action == "right_click")
        and CLICK_SETTLE_MS
        or DEFAULT_SETTLE_MS
    return integer(params.settle_ms or default, "settle_ms", 0, 5000)
end

local function log_target(ctx, action, normalized_x, normalized_y, x, y)
    accuracy_log(ctx, string.format(
        "%s target normalized=(%.6f,%.6f) mapped=(%d,%d)",
        action, normalized_x, normalized_y, x, y
    ))
end

local semantic_state_keys = {
    "checked", "editable", "enabled", "expanded", "focusable", "focused",
    "pressed", "selected", "sensitive", "showing", "visible",
}

local function semantic_point_on_monitor(monitor, x, y)
    local _, _, width, height = monitor_dimensions(monitor)
    return x >= monitor.x and x < monitor.x + width
        and y >= monitor.y and y < monitor.y + height
end

local function validate_semantic_target(target, snapshot, action)
    if type(target) ~= "table"
        or type(target.id) ~= "string"
        or #target.id > 160
        or not target.id:match("^atspi:%d+[%d%.]*$")
        or type(target.role) ~= "string"
        or #target.role == 0 or #target.role > 64
        or type(target.name) ~= "string"
        or #target.name > 256
        or type(target.states) ~= "table"
        or type(target.bounds) ~= "table"
        or type(target.center) ~= "table"
    then
        fail(action .. ": invalid semantic helper result")
    end
    if target.role == "password_text" then
        target.name = "[protected]"
    end
    for _, key in ipairs(semantic_state_keys) do
        if type(target.states[key]) ~= "boolean" then
            fail(action .. ": invalid semantic helper result")
        end
    end
    local bounds = target.bounds
    local center = target.center
    for _, value in ipairs({ bounds.x, bounds.y, bounds.width, bounds.height, center.x, center.y }) do
        if not finite(value) or value % 1 ~= 0 then
            fail(action .. ": invalid semantic helper result")
        end
    end
    local window = snapshot.window
    if bounds.width <= 0 or bounds.height <= 0
        or bounds.x < window.x or bounds.y < window.y
        or bounds.x + bounds.width > window.x + window.width
        or bounds.y + bounds.height > window.y + window.height
        or center.x ~= bounds.x + math.floor(bounds.width / 2)
        or center.y ~= bounds.y + math.floor(bounds.height / 2)
        or not semantic_point_on_monitor(snapshot.monitor, center.x, center.y)
    then
        fail(action .. ": semantic target bounds are not safely clickable")
    end
    if not target.states.visible or not target.states.showing
        or not target.states.sensitive or not target.states.enabled
    then
        fail(action .. ": semantic target is not safely actionable")
    end
    return target
end

local function semantic_helper_path(ctx)
    if type(ctx.config_dir) ~= "string"
        or ctx.config_dir == ""
        or ctx.config_dir:find("\0", 1, true)
    then
        return nil
    end
    return ctx.config_dir .. "/lua/scripts/computer_atspi.py"
end

local function semantic_call(ctx, operation, snapshot, expected)
    local helper = semantic_helper_path(ctx)
    if not helper then
        return nil, "semantic helper location is unavailable"
    end
    local request = { window = snapshot.window }
    if expected then
        request.target_id = expected.id
        request.expected = expected
    end
    local raw, kind, detail = exec_result(ctx, "python3", { helper, operation }, {
        stdin = json.encode(request),
        timeout_ms = SEMANTIC_TIMEOUT_MS,
        max_output_bytes = MAX_SEMANTIC_BYTES,
        env = instance_environment(),
    })
    if not raw then
        if kind == "spawn" then
            return nil, "Python 3 is unavailable"
        end
        return nil, "AT-SPI helper failed (" .. bounded_diagnostic(detail or kind) .. ")"
    end
    local ok, result = pcall(decode_json, raw, "invalid semantic helper output")
    if not ok or type(result) ~= "table" then
        return nil, "invalid semantic helper output"
    end
    if result.ok ~= true then
        return nil, bounded_diagnostic(result.reason) or "semantic target verification failed"
    end
    return result
end

local function semantic_discover(ctx, snapshot)
    local result, reason = semantic_call(ctx, "discover", snapshot)
    if not result then
        return { available = false, reason = reason, targets = {} }
    end
    if result.available ~= true then
        return {
            available = false,
            reason = bounded_diagnostic(result.reason) or "focused application is not accessible",
            targets = {},
        }
    end
    if type(result.targets) ~= "table" or #result.targets > MAX_SEMANTIC_TARGETS then
        fail("semantic_find: invalid semantic helper result")
    end
    local seen = {}
    for _, target in ipairs(result.targets) do
        validate_semantic_target(target, snapshot, "semantic_find")
        if seen[target.id] then
            fail("semantic_find: duplicate semantic target id")
        end
        seen[target.id] = true
    end
    return {
        available = true,
        targets = result.targets,
        truncated = result.truncated == true,
        visited = finite(result.visited) and result.visited or nil,
        limits = result.limits,
        window = result.window,
    }
end

local function stored_semantic_target(prior, semantic_id)
    local semantic = prior.semantic
    if type(semantic) ~= "table" or type(semantic.targets) ~= "table" then
        fail("semantic_click: semantic targets are unavailable; call semantic_find again")
    end
    local found
    for _, target in ipairs(semantic.targets) do
        if type(target) == "table" and target.id == semantic_id then
            if found then
                fail("semantic_click: semantic target id is ambiguous; call semantic_find again")
            end
            found = target
        end
    end
    if not found then
        fail("semantic_click: semantic target is stale or unknown; call semantic_find again")
    end
    return found
end

local function semantic_resolve(ctx, snapshot, expected)
    validate_semantic_target(expected, snapshot, "semantic_click")
    local result, reason = semantic_call(ctx, "resolve", snapshot, expected)
    if not result then
        fail("semantic_click: " .. reason .. "; action was not sent")
    end
    local current = validate_semantic_target(result.target, snapshot, "semantic_click")
    if current.id ~= expected.id
        or current.role ~= expected.role
        or current.name ~= expected.name
    then
        fail("semantic_click: semantic target identity changed; action was not sent")
    end
    for _, key in ipairs(semantic_state_keys) do
        if current.states[key] ~= expected.states[key] then
            fail("semantic_click: semantic target states changed; action was not sent")
        end
    end
    for _, key in ipairs({ "x", "y", "width", "height" }) do
        if current.bounds[key] ~= expected.bounds[key] then
            fail("semantic_click: semantic target bounds changed; action was not sent")
        end
    end
    return current
end

local function perform_action(params, ctx, signature, snapshot, target_lock, semantic_target)
    local action = params.action
    local monitor = snapshot.monitor
    if (action == "type" or action == "key") and not monitor.focused then
        fail(action .. ": selected monitor is not focused; action was not sent")
    end
    if action == "move" then
        local x, y = normalized_point(params, monitor)
        log_target(ctx, action, params.x, params.y, x, y)
        move_and_verify(ctx, signature, action, x, y)
        settle(ctx, action, settle_duration(params, action))
        return
    end
    if action == "click" or action == "click_locked" or action == "semantic_click" or action == "double_click" or action == "right_click" then
        local x
        local y
        if action == "semantic_click" then
            if type(semantic_target) ~= "table" then
                fail("semantic_click: verified semantic target is unavailable; action was not sent")
            end
            x = semantic_target.center.x
            y = semantic_target.center.y
            accuracy_log(ctx, string.format(
                "semantic_click target id=%s role=%s mapped=(%d,%d)",
                semantic_target.id, semantic_target.role, x, y
            ))
        elseif action == "click_locked" then
            if type(target_lock) ~= "table" then
                fail("click_locked: target lock is unavailable; call inspect again")
            end
            x = target_lock.logical_x
            y = target_lock.logical_y
            accuracy_log(ctx, string.format(
                "click_locked target token=%s source=(%d,%d) mapped=(%d,%d)",
                target_lock.token, target_lock.source_x, target_lock.source_y, x, y
            ))
        else
            x, y = normalized_point(params, monitor)
            log_target(ctx, action, params.x, params.y, x, y)
        end
        move_and_verify(ctx, signature, action, x, y)
        settle(ctx, action, PRE_CLICK_SETTLE_MS)
        if action == "double_click" then
            run_delivery(ctx, action, { "click", "--repeat", "2", "--next-delay", "100", "0xC0" })
        elseif action == "right_click" then
            run_delivery(ctx, action, { "click", "--next-delay", tostring(CLICK_HOLD_MS), "0xC1" })
        else
            run_delivery(ctx, action, { "click", "--next-delay", tostring(CLICK_HOLD_MS), "0xC0" })
        end
        settle(ctx, action, settle_duration(params, action))
        return
    end
    if action == "drag" then
        local start_x, start_y = normalized_point(params, monitor, "start_")
        local end_x, end_y = normalized_point(params, monitor, "end_")
        log_target(ctx, action .. " start", params.start_x, params.start_y, start_x, start_y)
        log_target(ctx, action .. " end", params.end_x, params.end_y, end_x, end_y)
        move_and_verify(ctx, signature, action, start_x, start_y)
        run_delivery(ctx, action, { "click", "0x40" })
        local moved = pcall(move_and_verify, ctx, signature, action, end_x, end_y)
        local released = pcall(run_delivery, ctx, action, { "click", "0x80" })
        if not moved or not released then
            post_input_failure("drag_delivery_ambiguous", "drag movement or button release failed after button press")
        end
        settle(ctx, action, settle_duration(params, action))
        return
    end
    if action == "scroll" then
        local x, y = normalized_point(params, monitor)
        local amount = integer(params.amount, "amount", -20, 20)
        if amount == 0 then
            fail("amount must not be zero")
        end
        log_target(ctx, action, params.x, params.y, x, y)
        move_and_verify(ctx, signature, action, x, y)
        run_delivery(ctx, action, {
            "mousemove", "--wheel", "--", "0", tostring(amount),
        })
        settle(ctx, action, settle_duration(params, action))
        return
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
        settle(ctx, action, settle_duration(params, action))
        return
    end
    if action == "key" then
        run_delivery(ctx, action, key_args(params.keys))
        settle(ctx, action, settle_duration(params, action))
        return
    end
    if action == "wait" then
        local duration = integer(params.duration_ms or 1000, "duration_ms", 0, 10000)
        if duration > 0 then
            local _, kind, detail = exec_result(ctx, "sleep", { string.format("%.3f", duration / 1000) }, {
                timeout_ms = duration + SLEEP_TIMEOUT_MARGIN_MS,
            })
            if kind then
                fail("wait failed (" .. detail .. ")")
            end
        end
        return
    end
    fail("unsupported action")
end

local function uint32(data, offset)
    return data:byte(offset) * 16777216
        + data:byte(offset + 1) * 65536
        + data:byte(offset + 2) * 256
        + data:byte(offset + 3)
end

local function validate_png(data, action)
    if type(data) ~= "string"
        or #data < 24
        or #data > MAX_IMAGE_BYTES
        or data:sub(1, 8) ~= "\137PNG\r\n\26\n"
        or data:sub(13, 16) ~= "IHDR"
    then
        fail(action .. ": screenshot was not a valid bounded PNG")
    end
    local width = uint32(data, 17)
    local height = uint32(data, 21)
    if width == 0 or height == 0 or not data:find("IEND", -12, true) then
        fail(action .. ": screenshot PNG was truncated")
    end
    return data, width, height
end

local function grid_lines(width, height, divisions, odd_only)
    local lines = {}
    for index = 1, divisions - 1 do
        if not odd_only or index % 2 == 1 then
            local x = math.floor(index * (width - 1) / divisions + 0.5)
            local y = math.floor(index * (height - 1) / divisions + 0.5)
            lines[#lines + 1] = string.format("line %d,0 %d,%d", x, x, height - 1)
            lines[#lines + 1] = string.format("line 0,%d %d,%d", y, width - 1, y)
        end
    end
    return table.concat(lines, " ")
end

local function grid_labels(width, height, point_size)
    local labels = {}
    for index = 1, 9 do
        local x = math.floor(index * (width - 1) / 10 + 0.5)
        local y = math.floor(index * (height - 1) / 10 + 0.5)
        local value = string.format("%.1f", index / 10)
        labels[#labels + 1] = string.format("text %d,%d '%s'", x + 3, point_size + 2, value)
        labels[#labels + 1] = string.format("text 3,%d '%s'", math.max(point_size, y - 3), value)
    end
    return table.concat(labels, " ")
end

local function image_sha256(ctx, image, action)
    local ok, hash = pcall(ctx.codec.sha256, image)
    if not ok or type(hash) ~= "string" or #hash ~= 64 then
        fail(action .. ": screenshot hashing failed")
    end
    return hash
end

local function capture(ctx, signature, monitor, grid, action)
    local cursor_visible = action == "move"
    local _, _, logical_width, logical_height = monitor_dimensions(monitor)
    local grim_args = { "-t", "png", "-s", tostring(monitor.scale) }
    if cursor_visible then
        grim_args[#grim_args + 1] = "-c"
    end
    grim_args[#grim_args + 1] = "-o"
    grim_args[#grim_args + 1] = monitor.name
    grim_args[#grim_args + 1] = "-"

    local image, kind, detail = exec_result(ctx, "grim", grim_args, {
        env = instance_environment(signature),
        timeout_ms = CAPTURE_TIMEOUT_MS,
        max_output_bytes = MAX_IMAGE_BYTES,
    })
    if not image then
        if kind == "spawn" then
            fail(action .. ": grim is unavailable; install grim (" .. detail .. ")")
        end
        if kind == "cancelled" then
            fail(action .. ": screenshot cancelled by the host; no new screenshot_id was produced. Do not retry during this cancelled turn; begin the next active turn with computer_observe (" .. detail .. ")")
        end
        fail(action .. ": screenshot capture failed (" .. detail .. ")")
    end

    local width
    local height
    image, width, height = validate_png(image, action)
    local expected_width, expected_height = monitor_dimensions(monitor)
    accuracy_log(ctx, string.format(
        "%s geometry monitor=%s mode=%dx%d scale=%.6f transform=%d expected_png=%dx%d actual_png=%dx%d logical=%dx%d origin=(%d,%d)",
        action, monitor.name, monitor.width, monitor.height, monitor.scale, monitor.transform,
        expected_width, expected_height, width, height, logical_width, logical_height,
        monitor.x, monitor.y
    ))
    if width ~= expected_width or height ~= expected_height then
        fail(string.format(
            "%s: screenshot geometry mismatch; expected %dx%d for monitor %s but grim returned %dx%d",
            action, expected_width, expected_height, monitor.name, width, height
        ))
    end

    if grid then
        local point_size = math.min(24, math.max(12, math.floor(math.min(width, height) / 80)))
        local rendered, render_kind, render_detail = exec_result(ctx, "magick", {
            "png:-",
            "-stroke", "rgba(255,255,255,0.14)", "-strokewidth", "1", "-fill", "none",
            "-draw", grid_lines(width, height, 20, true),
            "-stroke", "rgba(255,255,255,0.35)", "-draw", grid_lines(width, height, 10, false),
            "-font", "DejaVu-Sans", "-pointsize", tostring(point_size),
            "-stroke", "rgba(0,0,0,0.85)", "-strokewidth", "2",
            "-fill", "rgba(255,255,255,0.92)", "-draw", grid_labels(width, height, point_size),
            "png:-",
        }, {
            stdin = image,
            max_output_bytes = MAX_IMAGE_BYTES,
        })
        if not rendered then
            if render_kind == "spawn" then
                fail(action .. ": ImageMagick is unavailable; install ImageMagick (" .. render_detail .. ")")
            end
            fail(action .. ": grid rendering failed (" .. render_detail .. ")")
        end
        local rendered_width
        local rendered_height
        image, rendered_width, rendered_height = validate_png(rendered, action)
        if rendered_width ~= width or rendered_height ~= height then
            fail(action .. ": grid rendering changed screenshot geometry")
        end
    end
    return image, image_sha256(ctx, image, action), width, height, cursor_visible
end

local function target_patch_hash(ctx, image, width, height, center_x, center_y, action)
    local patch_left = math.max(0, center_x - TARGET_PATCH_RADIUS)
    local patch_top = math.max(0, center_y - TARGET_PATCH_RADIUS)
    local patch_right = math.min(width - 1, center_x + TARGET_PATCH_RADIUS)
    local patch_bottom = math.min(height - 1, center_y + TARGET_PATCH_RADIUS)
    local patch_width = patch_right - patch_left + 1
    local patch_height = patch_bottom - patch_top + 1
    local patch, kind, detail = exec_result(ctx, "magick", {
        "png:-",
        "-crop", string.format("%dx%d+%d+%d", patch_width, patch_height, patch_left, patch_top),
        "+repage", "-depth", "8", "rgba:-",
    }, {
        stdin = image,
        max_output_bytes = patch_width * patch_height * 4,
    })
    if not patch then
        fail(action .. ": target patch capture failed (" .. bounded_diagnostic(detail or kind) .. ")")
    end
    if #patch ~= patch_width * patch_height * 4 then
        fail(action .. ": target patch had invalid geometry")
    end
    return image_sha256(ctx, patch, action), {
        x = patch_left,
        y = patch_top,
        width = patch_width,
        height = patch_height,
    }
end

local function inspect_image(ctx, image, width, height, params)
    local radius = integer(params.radius or INSPECT_RADIUS, "radius", 32, 256)
    local center_x = math.floor(params.x * (width - 1) + 0.5)
    local center_y = math.floor(params.y * (height - 1) + 0.5)
    local left = math.max(0, center_x - radius)
    local top = math.max(0, center_y - radius)
    local right = math.min(width - 1, center_x + radius)
    local bottom = math.min(height - 1, center_y + radius)
    local crop_width = right - left + 1
    local crop_height = bottom - top + 1

    local clean, kind, detail = exec_result(ctx, "magick", {
        "png:-",
        "-crop", string.format("%dx%d+%d+%d", crop_width, crop_height, left, top),
        "+repage", "-filter", "Lanczos",
        "-resize", string.format("%dx%d!", INSPECT_SIZE, INSPECT_SIZE),
        "png:-",
    }, {
        stdin = image,
        max_output_bytes = MAX_IMAGE_BYTES,
    })
    if not clean then
        if kind == "spawn" then
            fail("inspect: ImageMagick is unavailable; install ImageMagick (" .. detail .. ")")
        end
        fail("inspect: target crop rendering failed (" .. detail .. ")")
    end
    local clean_width
    local clean_height
    clean, clean_width, clean_height = validate_png(clean, "inspect")
    if clean_width ~= INSPECT_SIZE or clean_height ~= INSPECT_SIZE then
        fail("inspect: target crop had invalid geometry")
    end

    local display_x = math.floor((center_x - left + 0.5) * INSPECT_SIZE / crop_width)
    local display_y = math.floor((center_y - top + 0.5) * INSPECT_SIZE / crop_height)
    display_x = math.max(0, math.min(INSPECT_SIZE - 1, display_x))
    display_y = math.max(0, math.min(INSPECT_SIZE - 1, display_y))
    local inner = 28
    local outer = 56
    local ticks = string.format(
        "line %d,%d %d,%d line %d,%d %d,%d line %d,%d %d,%d line %d,%d %d,%d",
        math.max(0, display_x - outer), display_y, math.max(0, display_x - inner), display_y,
        math.min(INSPECT_SIZE - 1, display_x + inner), display_y, math.min(INSPECT_SIZE - 1, display_x + outer), display_y,
        display_x, math.max(0, display_y - outer), display_x, math.max(0, display_y - inner),
        display_x, math.min(INSPECT_SIZE - 1, display_y + inner), display_x, math.min(INSPECT_SIZE - 1, display_y + outer)
    )
    local rendered, render_kind, render_detail = exec_result(ctx, "magick", {
        "png:-",
        "-stroke", "rgba(255,64,64,0.95)", "-strokewidth", "3", "-fill", "none",
        "-draw", ticks,
        "png:-",
    }, {
        stdin = clean,
        max_output_bytes = MAX_IMAGE_BYTES,
    })
    if not rendered then
        fail("inspect: target annotation failed (" .. bounded_diagnostic(render_detail or render_kind) .. ")")
    end
    local inspected
    local inspected_width
    local inspected_height
    inspected, inspected_width, inspected_height = validate_png(rendered, "inspect")
    if inspected_width ~= INSPECT_SIZE or inspected_height ~= INSPECT_SIZE then
        fail("inspect: annotated crop had invalid geometry")
    end

    local patch_sha256, patch_bounds = target_patch_hash(
        ctx, image, width, height, center_x, center_y, "inspect"
    )

    return inspected, {
        radius = radius,
        source_x = center_x,
        source_y = center_y,
        source_bounds = { x = left, y = top, width = crop_width, height = crop_height },
        display_x = display_x,
        display_y = display_y,
        width = inspected_width,
        height = inspected_height,
        magnification_x = INSPECT_SIZE / crop_width,
        magnification_y = INSPECT_SIZE / crop_height,
        annotation = "four exterior ticks; center remains unobscured",
        patch_bounds = patch_bounds,
        patch_sha256 = patch_sha256,
    }
end

local function model_image_dimensions(width, height)
    local scale = math.min(1, MODEL_IMAGE_MAX_WIDTH / width, MODEL_IMAGE_MAX_HEIGHT / height)
    return math.max(1, math.floor(width * scale + 0.5)),
        math.max(1, math.floor(height * scale + 0.5))
end

local function model_image(ctx, image, width, height, action)
    local target_width, target_height = model_image_dimensions(width, height)
    if target_width == width and target_height == height then
        return image, width, height
    end
    local resized, kind, detail = exec_result(ctx, "magick", {
        "png:-", "-filter", "Lanczos",
        "-resize", string.format("%dx%d!", target_width, target_height),
        "png:-",
    }, {
        stdin = image,
        max_output_bytes = MAX_IMAGE_BYTES,
    })
    if not resized then
        if kind == "spawn" then
            fail(action .. ": ImageMagick is unavailable; install ImageMagick (" .. detail .. ")")
        end
        fail(action .. ": model screenshot resize failed (" .. detail .. ")")
    end
    local resized_width
    local resized_height
    resized, resized_width, resized_height = validate_png(resized, action)
    if resized_width ~= target_width or resized_height ~= target_height then
        fail(action .. ": model screenshot resize produced invalid geometry")
    end
    return resized, resized_width, resized_height
end

local function image_debug(ctx, image, encoded, hash)
    if os.getenv("BONE_IMAGE_DEBUG") ~= "1" then
        return
    end
    ctx.log.info(string.format(
        "computer image capture: media_type=image/png base64_bytes=%d decoded_bytes=%d png=%dx%d sha256=%s",
        #encoded,
        #image,
        uint32(image, 17),
        uint32(image, 21),
        hash
    ))
end

local input_actions = {
    move = true, click = true, click_locked = true, semantic_click = true,
    double_click = true, right_click = true,
    drag = true, scroll = true, type = true, key = true,
}

local function point_metadata(params, snapshot, width, height, prefix, attachment_width, attachment_height)
    prefix = prefix or ""
    if params[prefix .. "x"] == nil or params[prefix .. "y"] == nil then
        return nil
    end
    local logical_x, logical_y = normalized_point(params, snapshot.monitor, prefix)
    local point = {
        normalized_x = params[prefix .. "x"],
        normalized_y = params[prefix .. "y"],
        logical_x = logical_x,
        logical_y = logical_y,
        screenshot_x = math.floor(params[prefix .. "x"] * (width - 1) + 0.5),
        screenshot_y = math.floor(params[prefix .. "y"] * (height - 1) + 0.5),
    }
    if attachment_width and attachment_height then
        point.attachment_x = math.floor(params[prefix .. "x"] * (attachment_width - 1) + 0.5)
        point.attachment_y = math.floor(params[prefix .. "y"] * (attachment_height - 1) + 0.5)
    end
    return point
end

local function target_lock_for_inspection(
    ctx, params, snapshot, screenshot_id, operation_id, image_hash, geometry, width, height
)
    local logical_x, logical_y = source_point(
        snapshot.monitor, width, height, geometry.source_x, geometry.source_y
    )
    local created_at = os.time()
    local token = "target-" .. image_sha256(ctx, table.concat({
        screenshot_id,
        operation_id,
        image_hash,
        tostring(geometry.source_x),
        tostring(geometry.source_y),
        tostring(created_at),
    }, ":"), "inspect"):sub(1, 24)
    return {
        token = token,
        screenshot_id = screenshot_id,
        monitor = snapshot.monitor.name,
        geometry_fingerprint = geometry_fingerprint(ctx, snapshot.monitor, width, height, "inspect"),
        normalized_x = params.x,
        normalized_y = params.y,
        source_x = geometry.source_x,
        source_y = geometry.source_y,
        logical_x = logical_x,
        logical_y = logical_y,
        image_width = width,
        image_height = height,
        radius = geometry.radius,
        patch_bounds = geometry.patch_bounds,
        patch_sha256 = geometry.patch_sha256,
        created_at = created_at,
        expires_at = created_at + TARGET_LOCK_TTL_SECONDS,
    }
end

local function validate_target_lock(ctx, params, prior, snapshot, image, width, height)
    local lock = prior.target_lock
    if type(lock) ~= "table" or lock.token ~= params.target_token then
        fail("click_locked: target token is stale, consumed, or unknown; action was not sent. Call inspect again")
    end
    if lock.screenshot_id ~= prior.screenshot_id
        or lock.monitor ~= snapshot.monitor.name
        or lock.image_width ~= width
        or lock.image_height ~= height
        or lock.geometry_fingerprint ~= geometry_fingerprint(ctx, snapshot.monitor, width, height, "click_locked")
        or not finite(lock.source_x)
        or not finite(lock.source_y)
        or not finite(lock.logical_x)
        or not finite(lock.logical_y)
        or not finite(lock.expires_at)
    then
        fail("click_locked: target lock geometry is invalid; action was not sent. Call inspect again")
    end
    if os.time() > lock.expires_at then
        fail("click_locked: target lock expired; action was not sent. Call inspect again")
    end
    local current_hash, current_bounds = target_patch_hash(
        ctx, image, width, height, lock.source_x, lock.source_y, "click_locked"
    )
    local bounds = lock.patch_bounds
    if type(bounds) ~= "table"
        or bounds.x ~= current_bounds.x
        or bounds.y ~= current_bounds.y
        or bounds.width ~= current_bounds.width
        or bounds.height ~= current_bounds.height
        or current_hash ~= lock.patch_sha256
    then
        fail("click_locked: pixels around the locked target changed; action was not sent. Call inspect again")
    end
    return lock
end

local function cleanup_files(ctx, paths)
    exec_result(ctx, "rm", { "-f", "--", paths[1], paths[2] }, {
        timeout_ms = EXEC_TIMEOUT_MS,
        max_output_bytes = MAX_DIAGNOSTIC_BYTES,
    })
end

local function changed_bounds(ctx, before_image, after_image, width, height, operation_id)
    if type(ctx.write_file) ~= "function" or before_image == nil or after_image == nil then
        return nil
    end
    local suffix = image_sha256(ctx, table.concat({
        tostring(operation_id),
        image_sha256(ctx, before_image, "change detection"),
        image_sha256(ctx, after_image, "change detection"),
        tostring(os.time()),
        tostring(os.clock()),
    }, ":"), "change detection"):sub(1, 20)
    local paths = {
        "/tmp/bone-computer-" .. suffix .. "-before.png",
        "/tmp/bone-computer-" .. suffix .. "-after.png",
    }
    local first_ok = pcall(ctx.write_file, paths[1], before_image)
    local second_ok = first_ok and pcall(ctx.write_file, paths[2], after_image)
    if not first_ok or not second_ok then
        cleanup_files(ctx, paths)
        return nil
    end
    local mean_raw = exec_result(ctx, "magick", {
        paths[1], paths[2],
        "-compose", "difference", "-composite",
        "-format", "%[fx:mean]", "info:",
    }, {
        max_output_bytes = MAX_DIAGNOSTIC_BYTES,
    })
    local mean = mean_raw and tonumber(mean_raw)
    if not mean then
        cleanup_files(ctx, paths)
        return nil
    end
    if mean == 0 then
        cleanup_files(ctx, paths)
        return false
    end
    local raw = exec_result(ctx, "magick", {
        paths[1], paths[2],
        "-compose", "difference", "-composite", "-threshold", "0", "-trim",
        "-format", "%@", "info:",
    }, {
        max_output_bytes = MAX_DIAGNOSTIC_BYTES,
    })
    cleanup_files(ctx, paths)
    if not raw then
        return nil
    end
    local box_width, box_height, x, y = raw:match("^(%d+)x(%d+)%+(%d+)%+(%d+)")
    box_width = tonumber(box_width)
    box_height = tonumber(box_height)
    x = tonumber(x)
    y = tonumber(y)
    if not box_width or not box_height or not x or not y
        or box_width < 1 or box_height < 1
        or x + box_width > width or y + box_height > height
    then
        return nil
    end
    return { x = x, y = y, width = box_width, height = box_height }
end

local function classify_change(bounds, target, width, height)
    if not bounds then
        return "changed_unlocalized"
    end
    if bounds.width * bounds.height >= width * height * 0.35 then
        return "major_scene_change"
    end
    if target then
        local margin = 32
        if target.screenshot_x >= bounds.x - margin
            and target.screenshot_x < bounds.x + bounds.width + margin
            and target.screenshot_y >= bounds.y - margin
            and target.screenshot_y < bounds.y + bounds.height + margin
        then
            return "changed_near_target"
        end
    end
    return "changed_elsewhere"
end

local function save_response(
    ctx, prior, signature, snapshot, params, grid, operation_id,
    image, image_hash, width, height, cursor_visible,
    inspection_image, inspection_geometry, before_image, before_hash, locked_target,
    semantic, semantic_target
)
    local action = params.action
    local exact_unchanged = prior and prior.image_sha256 == image_hash
    local unchanged = prior
        and prior.grid == grid
        and prior.cursor_visible == cursor_visible
        and prior.image_width == width
        and prior.image_height == height
        and exact_unchanged
    local generation = unchanged and prior.generation or (prior and prior.generation + 1 or 1)
    local operation_generation = prior and (prior.operation_generation or 0) + 1 or 1
    local screenshot_id = unchanged and prior.screenshot_id or "computer-" .. tostring(generation)
    local target_lock
    if inspection_geometry then
        target_lock = target_lock_for_inspection(
            ctx, params, snapshot, screenshot_id, operation_id, image_hash,
            inspection_geometry, width, height
        )
    end
    local captured_at = os.time()
    ctx.state.set(STATE_KEY, json.encode({
        screenshot_id = screenshot_id,
        generation = generation,
        operation_generation = operation_generation,
        signature = signature,
        snapshot = snapshot,
        image_sha256 = image_hash,
        image_width = width,
        image_height = height,
        geometry_fingerprint = geometry_fingerprint(ctx, snapshot.monitor, width, height, action),
        captured_at = captured_at,
        cursor_visible = cursor_visible,
        grid = grid,
        target_lock = target_lock,
        semantic = semantic,
    }))

    local pixel_width, pixel_height, logical_width, logical_height = monitor_dimensions(snapshot.monitor)
    local attachment_width, attachment_height = model_image_dimensions(width, height)
    local force_attachment = action == "observe" or action == "inspect"
    local target = point_metadata(
        params, snapshot, width, height, nil, attachment_width, attachment_height
    )
    if locked_target then
        target = {
            normalized_x = locked_target.normalized_x,
            normalized_y = locked_target.normalized_y,
            logical_x = locked_target.logical_x,
            logical_y = locked_target.logical_y,
            screenshot_x = locked_target.source_x,
            screenshot_y = locked_target.source_y,
            attachment_x = math.floor(locked_target.normalized_x * (attachment_width - 1) + 0.5),
            attachment_y = math.floor(locked_target.normalized_y * (attachment_height - 1) + 0.5),
            target_token = locked_target.token,
        }
    end
    if semantic_target then
        target = {
            semantic_id = semantic_target.id,
            role = semantic_target.role,
            name = semantic_target.name,
            logical_x = semantic_target.center.x,
            logical_y = semantic_target.center.y,
            bounds = semantic_target.bounds,
        }
    end
    local evidence
    local change_bounds
    if before_hash then
        if before_hash == image_hash then
            evidence = "unchanged"
        else
            local detected_bounds = changed_bounds(ctx, before_image, image, width, height, operation_id)
            if detected_bounds == false then
                evidence = "unchanged"
            else
                change_bounds = detected_bounds
                evidence = classify_change(change_bounds, target, width, height)
            end
        end
    elseif not prior then
        evidence = "baseline"
    else
        evidence = exact_unchanged and "unchanged" or "changed_elsewhere"
    end
    local content = {
        screenshot_id = screenshot_id,
        next_call = {
            tool = "computer",
            screenshot_id = screenshot_id,
            required = true,
        },
        operation_id = operation_id,
        action = action,
        monitor = snapshot.monitor,
        screenshot_geometry = {
            width = width,
            height = height,
            expected_width = pixel_width,
            expected_height = pixel_height,
            logical_width = logical_width,
            logical_height = logical_height,
            attachment_width = attachment_width,
            attachment_height = attachment_height,
        },
        cursor_visible = cursor_visible,
        available_monitors = snapshot.available_monitors,
        monitor_selection = "To inspect another monitor, call observe with monitor set to its name or 'other'.",
        coordinates = "Use finite normalized coordinates from 0 through 1 with this screenshot_id.",
        screenshot_captured = true,
        screenshot_attached = not unchanged or force_attachment,
        visual_change = evidence,
        change_bounds = change_bounds,
        input_delivery = input_actions[action] and "sent_unverified" or "not_applicable",
        semantic_target = semantic_target and "verified" or (input_actions[action] and "unknown" or "not_applicable"),
        grid = grid,
    }
    if semantic then
        content.semantic = semantic
        content.semantic_instruction = semantic.available
            and "Use an exact semantic target id with semantic_click. Targets are scoped to the focused window and will be re-resolved before input."
            or "AT-SPI targeting is unavailable for this focused window. Continue with screenshot coordinates."
    end
    if semantic_target then
        content.semantic_verification = {
            id = semantic_target.id,
            role = semantic_target.role,
            name = semantic_target.name,
            states = semantic_target.states,
            bounds = semantic_target.bounds,
            center = semantic_target.center,
        }
    end
    content.target = target
    if action == "drag" then
        content.start_target = point_metadata(
            params, snapshot, width, height, "start_", attachment_width, attachment_height
        )
        content.end_target = point_metadata(
            params, snapshot, width, height, "end_", attachment_width, attachment_height
        )
    end
    if input_actions[action] then
        content.settle_ms = settle_duration(params, action)
    end
    if inspection_geometry then
        content.inspection_geometry = inspection_geometry
        content.target_lock = {
            target_token = target_lock.token,
            expires_at = target_lock.expires_at,
            ttl_seconds = TARGET_LOCK_TTL_SECONDS,
            screenshot_id = target_lock.screenshot_id,
            monitor = target_lock.monitor,
            geometry_fingerprint = target_lock.geometry_fingerprint,
            normalized_x = target_lock.normalized_x,
            normalized_y = target_lock.normalized_y,
            source_x = target_lock.source_x,
            source_y = target_lock.source_y,
            logical_x = target_lock.logical_x,
            logical_y = target_lock.logical_y,
            patch_bounds = target_lock.patch_bounds,
            patch_sha256 = target_lock.patch_sha256,
        }
        content.next_call.target_token = target_lock.token
        content.next_call.locked_action = "click_locked"
    end
    if unchanged then
        content.image_reused_from = prior.screenshot_id
    end

    if unchanged and not force_attachment then
        content.image_instruction = input_actions[action]
            and "Input was delivered and a fresh post-action screenshot was captured, but no visual change was detected. This does not establish whether the intended UI target was activated. Continue using the prior image and this screenshot_id."
            or "A fresh screenshot was captured, but visual content was unchanged, so no duplicate image was attached. Continue using the prior image and this screenshot_id."
        return json.encode({ content = json.encode(content) })
    end

    local attached_image
    attached_image, attachment_width, attachment_height = model_image(
        ctx, image, width, height, action
    )
    local attached_hash = image_sha256(ctx, attached_image, action)
    local encoded = ctx.codec.base64_encode(attached_image)
    image_debug(ctx, attached_image, encoded, attached_hash)
    local images = {
        {
            media_type = "image/png",
            data = encoded,
            width = attachment_width,
            height = attachment_height,
            sha256 = attached_hash,
        },
    }
    if inspection_image then
        images[#images + 1] = {
            media_type = "image/png",
            data = ctx.codec.base64_encode(inspection_image),
            width = inspection_geometry.width,
            height = inspection_geometry.height,
            sha256 = image_sha256(ctx, inspection_image, "inspect"),
        }
        content.image_instruction = "Two PNGs are attached: a downscaled current full-monitor screenshot and a magnified crop rendered from the native capture with a red crosshair. Inspect the crop before choosing whether to click. Coordinates remain normalized to the full monitor."
    elseif cursor_visible then
        content.image_instruction = "A downscaled PNG screenshot with the pointer visible is attached. Verify that the pointer is centered on the intended target before clicking; coordinates remain normalized to the full monitor."
    elseif input_actions[action] then
        content.image_instruction = "A fresh downscaled post-action PNG is attached. Input was sent but not independently verified; inspect the image to determine whether the intended UI effect occurred. Coordinates remain normalized to the full monitor."
    else
        content.image_instruction = "A downscaled PNG screenshot is attached; inspect it directly before choosing normalized full-monitor coordinates."
    end
    return json.encode({
        content = json.encode(content),
        images = images,
        ephemeral_images = true,
    })
end

local action_status = {
    inspect = "inspecting target",
    semantic_find = "discovering accessible controls",
    semantic_click = "verifying and clicking accessible control",
    move = "moving pointer",
    click = "clicking",
    click_locked = "validating and clicking locked target",
    double_click = "double-clicking",
    right_click = "right-clicking",
    drag = "dragging",
    scroll = "scrolling",
    type = "typing",
    key = "pressing keys",
    wait = "waiting",
}

local function status(ctx, message)
    ctx.ui.status("computer - " .. message)
end

local function input_observation_failure(action, operation_id, reason, detail)
    return json.encode({
        content = json.encode({
            operation_id = operation_id,
            action = action,
            input_delivery = "sent_unverified",
            semantic_target = "unknown",
            screenshot_captured = false,
            observation = reason,
            detail = bounded_diagnostic(detail),
            retry_input = false,
            next_action = "observe",
        }),
    })
end

local function execute_inner(params, ctx)
    if type(ctx.exec) ~= "function"
        or type(ctx.codec) ~= "table"
        or type(ctx.codec.base64_encode) ~= "function"
        or type(ctx.codec.sha256) ~= "function"
        or type(json) ~= "table"
        or type(json.encode) ~= "function"
        or type(json.decode) ~= "function"
    then
        fail("computer requires a newer Bone build with ctx.exec and ctx.codec support; rebuild or update Bone")
    end
    validate_common(params)
    local action = params.action
    local prior = load_state(ctx)
    if action ~= "observe" then
        if not prior or params.screenshot_id ~= prior.screenshot_id then
            fail("stale screenshot_id; call computer_observe and copy its fresh screenshot_id")
        end
        if not finite(prior.captured_at)
            or os.time() - prior.captured_at > SCREENSHOT_TTL_SECONDS
        then
            fail("screenshot_id expired; action was not sent. Call computer_observe again")
        end
    end
    local operation_generation = prior and (prior.operation_generation or 0) + 1 or 1
    local operation_id = type(ctx.call_id) == "string" and ctx.call_id ~= ""
        and ctx.call_id
        or "computer-op-" .. tostring(operation_generation)

    status(ctx, "checking screen context")
    local requested_monitor
    if action == "observe" then
        requested_monitor = params.monitor
    else
        requested_monitor = prior.snapshot.monitor.name
    end
    local signature, before = snapshot_with_race(ctx, action, requested_monitor)
    local before_image
    local before_hash
    local locked_target
    local semantic
    local semantic_target
    if action ~= "observe" then
        if signature ~= prior.signature or not same_snapshot(before, prior.snapshot) then
            fail("screen context changed; action was not sent")
        end
        status(ctx, action_status[action])
        if action == "inspect" then
            normalized_point(params, before.monitor)
        elseif action == "semantic_find" then
            semantic = semantic_discover(ctx, before)
        else
            if input_actions[action] then
                if action == "click_locked" and (params.grid == true) ~= (prior.grid == true) then
                    fail("click_locked: grid mode differs from the inspected screenshot; action was not sent. Call inspect again")
                end
                status(ctx, "validating fresh pixels")
                local captured, fresh_image, fresh_hash, fresh_width, fresh_height = pcall(
                    capture, ctx, signature, before.monitor, params.grid == true, "validation"
                )
                if not captured then
                    fail(action .. ": pre-action screenshot failed; action was not sent (" .. bounded_diagnostic(fresh_image) .. ")")
                end
                before_image = fresh_image
                before_hash = fresh_hash
                if action == "click_locked" then
                    locked_target = validate_target_lock(
                        ctx, params, prior, before, fresh_image, fresh_width, fresh_height
                    )
                    prior.target_lock = nil
                    local consumed, consume_error = pcall(ctx.state.set, STATE_KEY, json.encode(prior))
                    if not consumed then
                        fail("click_locked: could not consume target lock; action was not sent (" .. bounded_diagnostic(consume_error) .. ")")
                    end
                elseif action == "semantic_click" then
                    local expected = stored_semantic_target(prior, params.semantic_id)
                    semantic_target = semantic_resolve(ctx, before, expected)
                    prior.semantic = nil
                    local consumed, consume_error = pcall(ctx.state.set, STATE_KEY, json.encode(prior))
                    if not consumed then
                        fail("semantic_click: could not consume semantic target; action was not sent (" .. bounded_diagnostic(consume_error) .. ")")
                    end
                end
            end
            local performed, perform_error = pcall(
                perform_action, params, ctx, signature, before, locked_target, semantic_target
            )
            if not performed then
                if type(perform_error) == "table" and perform_error.marker == POST_INPUT_FAILURE then
                    return input_observation_failure(
                        action,
                        operation_id,
                        perform_error.reason,
                        perform_error.detail
                    )
                end
                fail(perform_error)
            end
        end
    end

    local after = before
    if action ~= "observe" and action ~= "inspect" and action ~= "semantic_find" then
        status(ctx, "refreshing screen context")
        local ok, next_signature, next_snapshot = pcall(
            snapshot_with_race,
            ctx,
            action,
            before.monitor.name
        )
        if not ok or next_signature ~= signature then
            if action == "wait" then
                fail("wait: screen refresh failed")
            end
            return input_observation_failure(
                action,
                operation_id,
                "screen_refresh_failed",
                not ok and next_signature or "Hyprland instance changed"
            )
        end
        after = next_snapshot
    end

    status(ctx, "taking screenshot")
    local ok, image, image_hash, width, height, cursor_visible = pcall(
        capture,
        ctx,
        signature,
        after.monitor,
        params.grid == true,
        action
    )
    if not ok then
        if action == "observe" or action == "inspect" or action == "semantic_find" or action == "wait" then
            fail(image)
        end
        return input_observation_failure(
            action,
            operation_id,
            "screenshot_capture_failed",
            image
        )
    end
    local inspection_image
    local inspection_geometry
    if action == "inspect" then
        local inspected_ok
        inspected_ok, inspection_image, inspection_geometry = pcall(
            inspect_image,
            ctx,
            image,
            width,
            height,
            params
        )
        if not inspected_ok then
            fail(inspection_image)
        end
    end
    status(ctx, "screenshot ready")
    local saved, response = pcall(
        save_response,
        ctx,
        prior,
        signature,
        after,
        params,
        params.grid == true,
        operation_id,
        image,
        image_hash,
        width,
        height,
        cursor_visible,
        inspection_image,
        inspection_geometry,
        before_image,
        before_hash,
        locked_target,
        semantic,
        semantic_target
    )
    if saved then
        return response
    end
    if input_actions[action] then
        return input_observation_failure(
            action,
            operation_id,
            "response_persistence_failed",
            response
        )
    end
    fail(response)
end

local function execute(params, ctx)
    local ok, result = pcall(execute_inner, params, ctx)
    if ok then
        return result
    end
    local message = tostring(result)
    ctx.ui.notify("computer - failed: " .. message, "error")
    fail(message)
end

local function execute_observe(params, ctx)
    params.action = "observe"
    return execute(params, ctx)
end

bone.tool.register({
    name = "computer_observe",
    description = "Start or recover computer control. Capture the selected Hyprland monitor, always attach its PNG, and return screenshot_id. Call this before computer and again after any failed or cancelled computer operation.",
    safety = "read_only",
    stateful = true,
    state_key = STATE_KEY,
    display = {
        template = "observing screen",
        show_result = false,
    },
    parameters = {
        type = "object",
        properties = {
            monitor = {
                type = "string",
                description = "Hyprland output name, 'focused' (default), or 'other' when exactly two monitors are enabled.",
            },
            grid = {
                type = "boolean",
                description = "Overlay labeled 0.1 coordinate lines with finer 0.05 subdivisions.",
            },
        },
        additionalProperties = false,
    },
    execute = execute_observe,
})

bone.tool.register({
    name = "computer",
    catalog_description = catalog_description,
    description = "Act on the screenshot returned by computer_observe or the immediately preceding successful computer call. Use semantic_find to list verified AT-SPI controls in the focused window and semantic_click to click one after fresh re-resolution. Screenshot coordinates remain available for inaccessible applications. screenshot_id is always required: copy it exactly from the prior result. For click actions, supply a concise non-sensitive target_label for the transcript. Input is sent once and never retried automatically.",
    safety = "danger",
    stateful = true,
    state_key = STATE_KEY,
    display = {
        template = "{action} {target_label}",
        value_labels = {
            action = {
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
            },
        },
        show_result = false,
    },
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                description = "Action to perform on the referenced screenshot.",
                enum = { "inspect", "semantic_find", "semantic_click", "move", "click", "click_locked", "double_click", "right_click", "drag", "scroll", "type", "key", "wait" },
            },
            screenshot_id = {
                type = "string",
                minLength = 1,
                description = "Required. Copy the exact screenshot_id from computer_observe or the immediately preceding successful computer call.",
            },
            semantic_id = {
                type = "string",
                minLength = 7,
                maxLength = 160,
                pattern = "^atspi:[0-9]+([.][0-9]+)*$",
                description = "semantic_click only: exact target id returned by the preceding semantic_find.",
            },
            target_label = {
                type = "string",
                minLength = 1,
                maxLength = 80,
                description = "Click actions only: concise non-sensitive description of the visible target for the transcript label; does not affect target selection.",
            },
            target_token = {
                type = "string",
                minLength = 1,
                description = "click_locked only: copy the exact target_token returned by inspect.",
            },
            x = {
                type = "number", minimum = 0, maximum = 1,
                description = "Inspect/move/click/double_click/right_click/scroll only: normalized horizontal coordinate. For scroll, target a visible scrollable region.",
            },
            y = {
                type = "number", minimum = 0, maximum = 1,
                description = "Inspect/move/click/double_click/right_click/scroll only: normalized vertical coordinate. For scroll, target a visible scrollable region.",
            },
            radius = {
                type = "integer", minimum = 32, maximum = 256,
                description = "Inspect only: crop radius in source screenshot pixels; defaults to 96.",
            },
            start_x = { type = "number", minimum = 0, maximum = 1, description = "Drag only." },
            start_y = { type = "number", minimum = 0, maximum = 1, description = "Drag only." },
            end_x = { type = "number", minimum = 0, maximum = 1, description = "Drag only." },
            end_y = { type = "number", minimum = 0, maximum = 1, description = "Drag only." },
            amount = {
                type = "integer", minimum = -20, maximum = 20,
                description = "Scroll only: non-zero vertical wheel steps at x/y; positive scrolls up and negative scrolls down.",
            },
            text = { type = "string", minLength = 1, maxLength = 10000, description = "Type only." },
            keys = { type = "string", description = "Key only." },
            duration_ms = {
                type = "integer", minimum = 0, maximum = 10000,
                description = "Wait only: delay before the refreshed screenshot.",
            },
            settle_ms = {
                type = "integer", minimum = 0, maximum = 5000,
                description = "Input actions, including scroll: delay after input before refreshing the screenshot.",
            },
            grid = { type = "boolean", description = "Overlay labeled 0.1 coordinate lines with finer 0.05 subdivisions on the returned screenshot." },
        },
        required = { "action", "screenshot_id" },
        additionalProperties = false,
    },
    execute = execute,
})
