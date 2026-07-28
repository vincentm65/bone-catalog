local catalog_description = "Control the active Hyprland monitor with screenshots and normalized coordinates. Supports observe, mouse, keyboard, scroll, drag, and wait actions."
local STATE_KEY = "computer"
local DEFAULT_SETTLE_MS = 300
local MAX_TEXT_BYTES = 10000

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function fail(message)
    error(message, 0)
end

local function shell(ctx, command, timeout_ms)
    local result = ctx.shell(command, { timeout_ms = timeout_ms or 30000 })
    if result.exit_code ~= 0 then
        local detail = result.stderr
        if not detail or detail == "" then detail = result.stdout end
        if not detail or detail == "" then detail = "exit " .. tostring(result.exit_code) end
        return nil, detail:gsub("%s+$", "")
    end
    return result.stdout or ""
end

local function require_command(ctx, name, setup)
    local _, detail = shell(ctx, "command -v " .. name .. " >/dev/null 2>&1", 5000)
    if detail then fail(name .. " is required. " .. setup) end
end

local function finite_number(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, label, minimum, maximum)
    if not finite_number(value) or value % 1 ~= 0 or value < minimum or value > maximum then
        fail(string.format("%s must be an integer from %d to %d", label, minimum, maximum))
    end
    return value
end

local function decode_object(raw, label)
    local ok, value = pcall(cjson.decode, raw or "")
    if not ok or type(value) ~= "table" then fail(label) end
    return value
end

local function active_monitor(ctx)
    local stdout, detail = shell(ctx, "hyprctl monitors -j", 10000)
    if not stdout then
        fail("hyprctl could not query monitors: " .. detail .. ". Run Bone inside the target Hyprland session and ensure HYPRLAND_INSTANCE_SIGNATURE is available.")
    end
    local monitors = decode_object(stdout, "hyprctl returned invalid monitor JSON")
    local selected
    for _, monitor in ipairs(monitors) do
        if monitor.focused == true then selected = monitor break end
    end
    if not selected then fail("Hyprland reported no focused monitor") end

    local fields = { "x", "y", "width", "height", "scale", "transform" }
    for _, field in ipairs(fields) do
        if not finite_number(selected[field]) then
            fail("Hyprland monitor data is missing numeric " .. field)
        end
    end
    if type(selected.name) ~= "string" or selected.name == "" then
        fail("Hyprland monitor data is missing the monitor name")
    end
    if selected.width <= 0 or selected.height <= 0 or selected.scale <= 0 then
        fail("Hyprland returned invalid monitor dimensions or scale")
    end

    local rotated = selected.transform % 2 == 1
    local pixel_width = rotated and selected.height or selected.width
    local pixel_height = rotated and selected.width or selected.height
    local logical_width = math.floor(pixel_width / selected.scale + 0.5)
    local logical_height = math.floor(pixel_height / selected.scale + 0.5)
    if logical_width < 1 or logical_height < 1 then fail("Hyprland returned unusable monitor geometry") end

    return {
        name = selected.name,
        x = math.floor(selected.x),
        y = math.floor(selected.y),
        width = logical_width,
        height = logical_height,
        pixel_width = math.floor(pixel_width),
        pixel_height = math.floor(pixel_height),
        scale = selected.scale,
        transform = math.floor(selected.transform),
    }
end

local function same_monitor(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for _, field in ipairs({ "name", "x", "y", "width", "height", "scale", "transform" }) do
        if a[field] ~= b[field] then return false end
    end
    return true
end

local function load_state(ctx)
    local raw = ctx.state.get(STATE_KEY)
    if not raw or raw == "" then return nil end
    local ok, state = pcall(cjson.decode, raw)
    if not ok or type(state) ~= "table" then return nil end
    return state
end

local function normalized_point(params, monitor, prefix)
    prefix = prefix or ""
    local x = integer(params[prefix .. "x"], prefix .. "x", 0, 1000)
    local y = integer(params[prefix .. "y"], prefix .. "y", 0, 1000)
    return monitor.x + math.floor(x * (monitor.width - 1) / 1000 + 0.5),
        monitor.y + math.floor(y * (monitor.height - 1) / 1000 + 0.5)
end

local key_codes = {
    CTRL = 29, LEFTCTRL = 29, SHIFT = 42, LEFTSHIFT = 42, ALT = 56, LEFTALT = 56,
    META = 125, SUPER = 125, ENTER = 28, TAB = 15, ESC = 1, ESCAPE = 1,
    BACKSPACE = 14, DELETE = 111, SPACE = 57, LEFT = 105, RIGHT = 106,
    UP = 103, DOWN = 108, HOME = 102, END = 107, PAGEUP = 104, PAGEDOWN = 109,
    INSERT = 110, CAPSLOCK = 58,
    A = 30, B = 48, C = 46, D = 32, E = 18, F = 33, G = 34, H = 35, I = 23,
    J = 36, K = 37, L = 38, M = 50, N = 49, O = 24, P = 25, Q = 16, R = 19,
    S = 31, T = 20, U = 22, V = 47, W = 17, X = 45, Y = 21, Z = 44,
    ["0"] = 11, ["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5,
    ["5"] = 6, ["6"] = 7, ["7"] = 8, ["8"] = 9, ["9"] = 10,
    F1 = 59, F2 = 60, F3 = 61, F4 = 62, F5 = 63, F6 = 64,
    F7 = 65, F8 = 66, F9 = 67, F10 = 68, F11 = 87, F12 = 88,
}

local function key_arguments(value)
    if type(value) ~= "string" or value == "" or #value > 128 or not value:match("^[A-Za-z0-9+]+$") then
        fail("keys must be a combination such as CTRL+L, ENTER, or SHIFT+F10")
    end
    local codes, seen = {}, {}
    for token in value:upper():gmatch("[^+]+") do
        local code = key_codes[token]
        if not code then fail("unsupported key: " .. token) end
        if seen[code] then fail("duplicate key in combination: " .. token) end
        seen[code] = true
        codes[#codes + 1] = code
    end
    if #codes == 0 then fail("keys must contain at least one supported key") end
    local args = {}
    for _, code in ipairs(codes) do args[#args + 1] = tostring(code) .. ":1" end
    for i = #codes, 1, -1 do args[#args + 1] = tostring(codes[i]) .. ":0" end
    return table.concat(args, " ")
end

local function ydotool(ctx, command)
    local _, detail = shell(ctx, command, 30000)
    if detail then
        fail("ydotool action failed: " .. detail .. ". Ensure ydotoold is running for your user and YDOTOOL_SOCKET points to its socket; Bone will not start or configure the daemon.")
    end
end

local function move_command(x, y)
    return string.format("ydotool mousemove --absolute %d %d", x, y)
end

local function perform_action(params, monitor, ctx)
    local action = params.action
    if action == "move" then
        local x, y = normalized_point(params, monitor)
        ydotool(ctx, move_command(x, y))
    elseif action == "click" or action == "double_click" or action == "right_click" then
        local x, y = normalized_point(params, monitor)
        local click = "ydotool click 0xC0"
        if action == "double_click" then click = "ydotool click --repeat 2 --next-delay 100 0xC0" end
        if action == "right_click" then click = "ydotool click 0xC1" end
        ydotool(ctx, move_command(x, y) .. " && " .. click)
    elseif action == "drag" then
        local x1, y1 = normalized_point(params, monitor, "start_")
        local x2, y2 = normalized_point(params, monitor, "end_")
        local command = move_command(x1, y1) .. " && ydotool click 0x40 && " ..
            move_command(x2, y2) .. " && ydotool click 0x80"
        ydotool(ctx, command)
    elseif action == "scroll" then
        local x, y = normalized_point(params, monitor)
        local amount = integer(params.amount, "amount", -20, 20)
        if amount == 0 then fail("amount must not be zero") end
        local button = amount > 0 and "0xC4" or "0xC5"
        ydotool(ctx, move_command(x, y) .. string.format(" && ydotool click --repeat %d %s", math.abs(amount), button))
    elseif action == "type" then
        if type(params.text) ~= "string" or #params.text == 0 or #params.text > MAX_TEXT_BYTES or params.text:find("\0", 1, true) then
            fail("text must be a non-empty string of at most 10000 bytes without NUL characters")
        end
        ydotool(ctx, "ydotool type --key-delay 12 -- " .. shell_quote(params.text))
    elseif action == "key" then
        ydotool(ctx, "ydotool key " .. key_arguments(params.keys))
    elseif action == "wait" then
        local duration = params.duration_ms
        if duration == nil then duration = 1000 end
        duration = integer(duration, "duration_ms", 0, 10000)
        local _, detail = shell(ctx, string.format("sleep %.3f", duration / 1000), duration + 5000)
        if detail then fail("wait failed: " .. detail) end
        return
    else
        fail("unsupported action: " .. tostring(action))
    end

    local settle = params.settle_ms
    if settle == nil then settle = DEFAULT_SETTLE_MS end
    settle = integer(settle, "settle_ms", 0, 5000)
    local _, detail = shell(ctx, string.format("sleep %.3f", settle / 1000), settle + 5000)
    if detail then fail("post-action wait failed: " .. detail) end
end

local function capture(ctx, monitor, grid)
    local scale = math.min(1, 1600 / monitor.pixel_width, 1200 / monitor.pixel_height)
    local output_width = math.max(1, math.floor(monitor.pixel_width * scale + 0.5))
    local output_height = math.max(1, math.floor(monitor.pixel_height * scale + 0.5))
    local draw = ""
    if grid then
        local lines = {}
        for i = 1, 9 do
            local x = math.floor(output_width * i / 10 + 0.5)
            local y = math.floor(output_height * i / 10 + 0.5)
            lines[#lines + 1] = string.format("line %d,0 %d,%d", x, x, output_height)
            lines[#lines + 1] = string.format("line 0,%d %d,%d", y, output_width, y)
        end
        draw = " -stroke 'rgba(255,255,255,0.22)' -strokewidth 1 -fill none -draw " .. shell_quote(table.concat(lines, " "))
    end
    local geometry = string.format("%d,%d %dx%d", monitor.x, monitor.y, monitor.width, monitor.height)
    local command = "set -eu; src=$(mktemp --suffix=.png); out=$(mktemp --suffix=.jpg); " ..
        "trap 'rm -f \"$src\" \"$out\"' EXIT; " ..
        "grim -t png -g " .. shell_quote(geometry) .. " \"$src\"; " ..
        "magick \"$src\" -resize " .. shell_quote(string.format("%dx%d!", output_width, output_height)) ..
        draw .. " -quality 85 \"$out\"; base64 -w0 \"$out\""
    local data, detail = shell(ctx, command, 30000)
    if not data then fail("screenshot capture failed: " .. detail .. ". Verify grim can capture this Hyprland session and ImageMagick can encode JPEG files.") end
    data = data:gsub("%s+$", "")
    if data == "" then fail("screenshot capture produced no image data") end
    return data
end

local function execute(params, ctx)
    local action = params.action
    local allowed = {
        observe = true, move = true, click = true, double_click = true, right_click = true,
        drag = true, scroll = true, type = true, key = true, wait = true,
    }
    if not allowed[action] then fail("action must be observe, move, click, double_click, right_click, drag, scroll, type, key, wait") end
    if params.grid ~= nil and type(params.grid) ~= "boolean" then fail("grid must be a boolean") end

    require_command(ctx, "hyprctl", "Install Hyprland tools and run Bone inside a Hyprland session.")
    require_command(ctx, "grim", "Install grim with your package manager; Bone will not install it.")
    require_command(ctx, "magick", "Install ImageMagick with your package manager; Bone will not install it.")
    if action ~= "observe" and action ~= "wait" then
        require_command(ctx, "ydotool", "Install ydotool and configure a user ydotoold service; Bone will not perform privileged setup.")
    end

    local monitor = active_monitor(ctx)
    local previous = load_state(ctx)
    if action ~= "observe" then
        if type(params.screenshot_id) ~= "string" or params.screenshot_id == "" then
            fail("screenshot_id is required for GUI actions; call computer(action=observe) first")
        end
        if not previous or params.screenshot_id ~= previous.screenshot_id then
            fail("stale screenshot_id; call computer(action=observe) and retry using the new screenshot_id")
        end
        if not same_monitor(previous.monitor, monitor) then
            fail("active monitor geometry changed since the screenshot; call computer(action=observe) and retry")
        end
        perform_action(params, monitor, ctx)
        monitor = active_monitor(ctx)
        if not same_monitor(previous.monitor, monitor) then
            fail("active monitor geometry changed during the action; call computer(action=observe) before another action")
        end
    end

    local image = capture(ctx, monitor, params.grid == true)
    local generation = previous and tonumber(previous.generation) or 0
    generation = math.floor(generation or 0) + 1
    local state = {
        screenshot_id = "computer-" .. tostring(generation),
        generation = generation,
        monitor = monitor,
    }
    ctx.state.set(STATE_KEY, cjson.encode(state))

    local content = cjson.encode({
        screenshot_id = state.screenshot_id,
        action = action,
        monitor = {
            name = monitor.name, x = monitor.x, y = monitor.y,
            width = monitor.width, height = monitor.height, scale = monitor.scale,
        },
        coordinates = "Use normalized x/y values from 0 to 1000 with this screenshot_id.",
        grid = params.grid == true,
    })
    return cjson.encode({
        content = content,
        images = { { media_type = "image/jpeg", data = image } },
        ephemeral_images = true,
    })
end

bone.tool.register({
    name = "computer",
    catalog_description = catalog_description,
    description = "Observe and control the active Hyprland monitor. Coordinates are normalized from 0 to 1000. Call observe first, then pass its screenshot_id with every action. Each action returns a fresh screenshot and screenshot_id. Use Bone's shell tool, not computer, to launch applications.",
    safety = "danger",
    stateful = true,
    parameters = {
        type = "object",
        properties = {
            action = { type = "string", enum = { "observe", "move", "click", "double_click", "right_click", "drag", "scroll", "type", "key", "wait" } },
            screenshot_id = { type = "string", description = "Fresh ID returned by the previous computer call; required except for observe." },
            x = { type = "integer", minimum = 0, maximum = 1000 },
            y = { type = "integer", minimum = 0, maximum = 1000 },
            start_x = { type = "integer", minimum = 0, maximum = 1000 },
            start_y = { type = "integer", minimum = 0, maximum = 1000 },
            end_x = { type = "integer", minimum = 0, maximum = 1000 },
            end_y = { type = "integer", minimum = 0, maximum = 1000 },
            amount = { type = "integer", minimum = -20, maximum = 20, description = "Scroll steps; positive scrolls up and negative scrolls down." },
            text = { type = "string", minLength = 1, maxLength = 10000 },
            keys = { type = "string", description = "Validated key or combination, for example ENTER, CTRL+L, or SHIFT+F10." },
            duration_ms = { type = "integer", minimum = 0, maximum = 10000, description = "Wait duration; defaults to 1000 ms." },
            settle_ms = { type = "integer", minimum = 0, maximum = 5000, description = "Delay after a GUI action before capture; defaults to 300 ms." },
            grid = { type = "boolean", description = "Overlay a faint 10x10 grid on the returned screenshot. Defaults to false." },
        },
        required = { "action" },
        additionalProperties = false,
    },
    execute = execute,
})
