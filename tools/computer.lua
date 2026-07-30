local catalog_description = "Control Hyprland through hardened screenshot observation, normalized-coordinate clicks, and typing."

local STATE_KEY = "computer"
local STATE_VERSION = 2
local EXEC_TIMEOUT_MS = 4000
local SLEEP_TIMEOUT_MARGIN_MS = 1000
local CAPTURE_TIMEOUT_MS = 15000
local MAX_JSON_BYTES = 2 * 1024 * 1024
local MAX_IMAGE_BYTES = 25 * 1024 * 1024
local MODEL_IMAGE_MAX_WIDTH = 1920
local MODEL_IMAGE_MAX_HEIGHT = 1080
local DEFAULT_SETTLE_MS = 80
local CLICK_SETTLE_MS = 120
local CLICK_HOLD_MS = 30
local SCREENSHOT_TTL_SECONDS = 120
local MAX_LEDGER_ENTRIES = 32
local TILE_COLUMNS = 32
local TILE_ROWS = 18
local TILE_SAMPLE_FACTOR = 3
local POINTER_TOLERANCE = 1
local MAX_TEXT_BYTES = 10000
local MAX_DIAGNOSTIC_BYTES = 1024
local TRACE_VERSION = 1
local OBSERVE_RECOVERY = "Call computer with action='observe' before any further computer action."

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

local function privacy_safe_observation_detail(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    local details = {}
    for _, key in ipairs({
        "runtime_error", "timed_out", "cancelled", "output_limit_exceeded",
    }) do
        if text:find(key .. "=true", 1, true) then
            details[#details + 1] = key .. "=true"
        end
    end
    for _, key in ipairs({ "stderr_bytes", "exit_code", "signal" }) do
        local number = text:match(key .. "=(%-?%d+)")
        if number then
            details[#details + 1] = key .. "=" .. number
        end
    end
    if #details == 0 then
        details[1] = "detail_redacted=true"
    end
    return bounded_diagnostic(table.concat(details, ", "))
end

local function exec_diagnostic(result, call_error)
    result = type(result) == "table" and result or {}
    local details = {}
    if call_error ~= nil or result.error ~= nil then
        details[#details + 1] = "runtime_error=true"
    end
    if type(result.stderr) == "string" and #result.stderr > 0 then
        details[#details + 1] = "stderr_bytes=" .. tostring(#result.stderr)
    end
    if result.exit_code ~= nil then
        details[#details + 1] = "exit_code=" .. tostring(result.exit_code)
    end
    if result.signal ~= nil then
        details[#details + 1] = "signal=" .. tostring(result.signal)
    end
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

local function monotonic_ms(ctx)
    if type(ctx.time) == "table" and type(ctx.time.monotonic_ms) == "function" then
        local ok, value = pcall(ctx.time.monotonic_ms)
        if ok and finite(value) and value >= 0 then
            return math.floor(value)
        end
    end
    return math.floor(os.clock() * 1000)
end

local function random_hex(ctx, bytes, seed)
    if type(ctx.codec) == "table" and type(ctx.codec.random_hex) == "function" then
        local ok, value = pcall(ctx.codec.random_hex, bytes)
        if ok and type(value) == "string" and #value == bytes * 2
            and value:match("^[0-9a-f]+$")
        then
            return value
        end
    end
    local value = table.concat({
        tostring(seed or ""),
        tostring(monotonic_ms(ctx)),
        tostring(os.time()),
        tostring(os.clock()),
        tostring({}),
    }, ":")
    local ok, hash = pcall(ctx.codec.sha256, value)
    if not ok or type(hash) ~= "string" or #hash ~= 64 then
        fail("secure token generation failed")
    end
    return hash:sub(1, bytes * 2)
end

local function trace_begin(ctx, enabled, operation_id, call_id, action)
    ctx.__computer_trace_finalized = false
    ctx.__computer_trace = {
        enabled = enabled == true,
        version = TRACE_VERSION,
        operation_id = operation_id,
        call_id = call_id,
        action = action,
        started_ms = monotonic_ms(ctx),
        subprocess_count = 0,
        subprocesses = {},
        stages = {},
    }
end

local function trace_stage(ctx, name)
    local trace = ctx.__computer_trace
    if type(trace) ~= "table" then
        return
    end
    local now = monotonic_ms(ctx)
    local previous = trace.current_stage
    if previous then
        previous.elapsed_ms = math.max(0, now - previous.started_ms)
        previous.started_ms = nil
    end
    local stage = { name = name, started_ms = now }
    trace.stages[#trace.stages + 1] = stage
    trace.current_stage = stage
end

local function trace_finish(ctx, reason_code)
    local trace = ctx.__computer_trace
    if type(trace) ~= "table" then
        return nil
    end
    if ctx.__computer_trace_finalized ~= true then
        local now = monotonic_ms(ctx)
        if trace.current_stage then
            trace.current_stage.elapsed_ms = math.max(0, now - trace.current_stage.started_ms)
            trace.current_stage.started_ms = nil
            trace.current_stage = nil
        end
        trace.total_elapsed_ms = math.max(0, now - trace.started_ms)
        trace.started_ms = nil
        ctx.__computer_trace_finalized = true
    end
    trace.reason_code = reason_code
    if not trace.enabled then
        return nil
    end
    return trace
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

    local trace = ctx.__computer_trace
    local started_ms = monotonic_ms(ctx)
    if type(trace) == "table" then
        trace.subprocess_count = trace.subprocess_count + 1
    end
    local function record(category, result)
        if type(trace) ~= "table" then
            return
        end
        result = type(result) == "table" and result or {}
        trace.subprocesses[#trace.subprocesses + 1] = {
            dependency = program,
            category = category,
            elapsed_ms = math.max(0, monotonic_ms(ctx) - started_ms),
            stdin_bytes = type(opts.stdin) == "string" and #opts.stdin or 0,
            stdout_bytes = type(result.stdout) == "string" and #result.stdout or 0,
            stderr_bytes = type(result.stderr) == "string" and #result.stderr or 0,
        }
    end

    local ok, result = pcall(ctx.exec, program, args, opts)
    if not ok then
        record("runtime_error")
        return nil, "post", exec_diagnostic(nil, result)
    end
    if type(result) ~= "table" then
        record("invalid_result")
        return nil, "post", "invalid execution result"
    end
    if result.spawned == false then
        record("spawn", result)
        return nil, "spawn", exec_diagnostic(result)
    end
    if result.spawned ~= true then
        record("invalid_result", result)
        return nil, "post", exec_diagnostic(result)
    end
    if result.cancelled then
        record("cancelled", result)
        return nil, "cancelled", exec_diagnostic(result)
    end
    if result.timed_out or result.output_limit_exceeded or result.error then
        record(result.timed_out and "timeout"
            or (result.output_limit_exceeded and "output_limit" or "runtime_error"), result)
        return nil, "post", exec_diagnostic(result)
    end
    if result.signal ~= nil then
        record("signal", result)
        return nil, "post", exec_diagnostic(result)
    end
    if result.exit_code ~= 0 then
        record("nonzero_exit", result)
        return nil, "exit", exec_diagnostic(result)
    end
    if type(result.stdout) ~= "string" then
        record("invalid_result", result)
        return nil, "post", exec_diagnostic(result)
    end
    record("ok", result)
    return result.stdout
end

local instance_displays = {}
local cached_signature

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
    if not rediscover
        and type(cached_signature) == "string"
        and cached_signature ~= ""
        and (not inherited or inherited == "" or inherited == cached_signature)
    then
        return cached_signature
    end

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
    local candidates = {}
    for _, instance in ipairs(instances) do
        if type(instance) == "table" then
            local signature = instance.signature or instance.instance
            if type(signature) == "string" and signature ~= "" then
                if type(instance.wl_socket) == "string" and instance.wl_socket ~= "" then
                    instance_displays[signature] = instance.wl_socket
                end
                candidates[#candidates + 1] = signature
                if inherited and signature == inherited then
                    selected = signature
                end
            end
        end
    end
    if #candidates == 0 then
        fail(action .. ": no Hyprland instance was found")
    end
    if not selected then
        if #candidates ~= 1 then
            fail(action .. ": multiple Hyprland instances are available and none is explicitly selected")
        end
        selected = candidates[1]
    end
    cached_signature = selected
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

    if selected.dpmsStatus ~= nil and type(selected.dpmsStatus) ~= "boolean" then
        fail(action .. ": invalid monitor power state")
    end
    if selected.dpmsStatus == false then
        fail(
            action .. ": selected monitor " .. selected.name
                .. " is asleep (DPMS off); wake the display before calling "
                .. "computer with action='observe' again. Do not retry while the display is asleep"
        )
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
        dpms = selected.dpmsStatus ~= false,
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
        cached_signature = nil
        fail(action .. ": Hyprland query failed; action was not sent")
    end
    if type(ctx.time) == "table" and type(ctx.time.sleep_ms) == "function" then
        local slept = pcall(ctx.time.sleep_ms, 80)
        if not slept then
            fail(action .. ": Hyprland instance stabilization failed; action was not sent")
        end
    else
        local _, sleep_kind = exec_result(ctx, "sleep", { "0.080" })
        if sleep_kind then
            fail(action .. ": Hyprland instance stabilization failed; action was not sent")
        end
    end

    local retry, retry_kind = snapshot_once(ctx, replacement, action, requested_monitor)
    if retry then
        local confirmed = discover_signature(ctx, action, true)
        if confirmed ~= replacement then
            fail("Hyprland instance changed again; action was not sent")
        end
        cached_signature = replacement
        return replacement, retry
    end

    if retry_kind == "exit" then
        local latest = discover_signature(ctx, action, true)
        if latest ~= replacement then
            fail("Hyprland instance changed again; action was not sent")
        end
    end
    cached_signature = nil
    fail(action .. ": Hyprland query failed after instance change; action was not sent")
end

local function same_snapshot(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    for _, key in ipairs({
        "name", "x", "y", "width", "height", "scale", "transform",
        "workspace", "focused", "dpms",
    }) do
        if left.monitor[key] ~= right.monitor[key] then
            return false
        end
    end
    if #left.available_monitors ~= #right.available_monitors then
        return false
    end
    for index, name in ipairs(left.available_monitors) do
        if right.available_monitors[index] ~= name then
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

local function digest_fields(ctx, action, fields)
    local encoded = {}
    for index, value in ipairs(fields) do
        local text = tostring(value)
        encoded[index] = tostring(#text) .. ":" .. text
    end
    local ok, hash = pcall(ctx.codec.sha256, table.concat(encoded, "|"))
    if not ok or type(hash) ~= "string" or #hash ~= 64 then
        fail(action .. ": fingerprinting failed")
    end
    return hash
end

local function context_fingerprint(ctx, action, salt, signature, snapshot)
    local monitor = snapshot.monitor
    local window = snapshot.window
    local fields = {
        salt,
        signature,
        monitor.name,
        monitor.x, monitor.y, monitor.width, monitor.height,
        string.format("%.9f", monitor.scale),
        monitor.transform,
        monitor.workspace or "none",
        monitor.focused,
        table.concat(snapshot.available_monitors, "\0"),
        window.address,
        window.workspace,
        window.monitor,
        window.pid or 0,
        window.title or "",
        window.class or "",
        window.stable_id or "",
        window.x or 0,
        window.y or 0,
        window.width or 0,
        window.height or 0,
    }
    return digest_fields(ctx, action, fields)
end

local function stored_monitor(snapshot)
    local monitor = snapshot.monitor
    return {
        name = monitor.name,
        x = monitor.x,
        y = monitor.y,
        width = monitor.width,
        height = monitor.height,
        scale = monitor.scale,
        transform = monitor.transform,
        workspace = monitor.workspace,
        focused = monitor.focused,
    }
end

local function load_state(ctx)
    local raw = ctx.state.get(STATE_KEY)
    if raw == nil or raw == "" then
        return nil
    end
    local state = decode_json(raw, "invalid computer state; call observe again")
    if state.version ~= STATE_VERSION then
        fail("computer state uses an obsolete authorization format; call observe again")
    end
    if type(state.screenshot_id) ~= "string"
        or type(state.signature_sha256) ~= "string"
        or #state.signature_sha256 ~= 64
        or type(state.context_sha256) ~= "string"
        or #state.context_sha256 ~= 64
        or type(state.privacy_salt) ~= "string"
        or #state.privacy_salt < 16
        or not finite(state.generation)
        or state.generation % 1 ~= 0
        or not finite(state.operation_generation)
        or state.operation_generation % 1 ~= 0
        or type(state.monitor) ~= "table"
        or type(state.ledger) ~= "table"
        or not finite(state.captured_monotonic_ms)
        or state.captured_monotonic_ms < 0
    then
        fail("invalid computer state; call observe again")
    end
    return state
end

local input_actions = {
    click = true,
    type = true,
}

local allowed_fields = {
    observe = { action = true, monitor = true, grid = true, trace = true },
    click = {
        action = true, x = true, y = true, target_label = true,
        settle_ms = true, grid = true, trace = true,
    },
    type = {
        action = true, text = true, settle_ms = true, grid = true, trace = true,
    },
}

local settle_duration

local function validate_normalized(value, name)
    if not finite(value) or value < 0 or value > 1 then
        fail(name .. " must be a finite number from 0 through 1")
    end
end

local function validate_request(params)
    if type(params) ~= "table" or type(params.action) ~= "string" then
        fail("action must be an exact supported string")
    end
    local fields = allowed_fields[params.action]
    if not fields then
        fail("action must be observe, click, or type")
    end
    for key in pairs(params) do
        if type(key) ~= "string" or not fields[key] then
            fail("irrelevant field for " .. params.action .. ": " .. tostring(key))
        end
    end
    if params.grid ~= nil and type(params.grid) ~= "boolean" then
        fail("grid must be a boolean")
    end
    if params.trace ~= nil and type(params.trace) ~= "boolean" then
        fail("trace must be a boolean")
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
        and (type(params.monitor) ~= "string"
            or params.monitor == ""
            or #params.monitor > 256
            or params.monitor:find("\0", 1, true))
    then
        fail("monitor must be a bounded non-empty output name, 'focused', or 'other'")
    end
    local action = params.action
    if action == "click" then
        validate_normalized(params.x, "x")
        validate_normalized(params.y, "y")
    elseif action == "type" then
        if type(params.text) ~= "string"
            or #params.text == 0
            or #params.text > MAX_TEXT_BYTES
            or params.text:find("\0", 1, true)
        then
            fail("text must be a non-empty string of at most 10000 bytes without NUL")
        end
    end
    if input_actions[action] then
        settle_duration(params, action)
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

local POST_INPUT_FAILURE = {}
local INPUT_NOT_DELIVERED = {}

local function post_input_failure(reason, detail)
    error({ marker = POST_INPUT_FAILURE, reason = reason, detail = detail }, 0)
end

local function input_not_delivered(reason, detail)
    error({ marker = INPUT_NOT_DELIVERED, reason = reason, detail = detail }, 0)
end

local function run_delivery(ctx, action, args)
    local _, kind, detail = exec_result(ctx, "ydotool", args)
    if kind == "spawn" then
        input_not_delivered(
            "ydotool_unavailable",
            action .. ": ydotool is unavailable; configure a user ydotoold service"
        )
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
        if kind == "spawn" then
            input_not_delivered(
                "hyprctl_unavailable",
                action .. ": hyprctl could not be started"
            )
        end
        post_input_failure("pointer_delivery_ambiguous", detail)
    end
    local position, query_kind = query_json(
        ctx,
        signature,
        { "-j", "cursorpos" },
        action,
        "invalid cursor position"
    )
    if not position then
        post_input_failure("pointer_verification_unavailable", query_kind)
    end
    if not finite(position.x) or not finite(position.y) then
        post_input_failure("pointer_verification_invalid", "cursor position was malformed")
    end
    local actual_x = math.floor(position.x + 0.5)
    local actual_y = math.floor(position.y + 0.5)
    local trace = ctx.__computer_trace
    if type(trace) == "table" then
        trace.pointer = {
            requested_x = x,
            requested_y = y,
            actual_x = actual_x,
            actual_y = actual_y,
        }
    end
    if math.abs(actual_x - x) > POINTER_TOLERANCE
        or math.abs(actual_y - y) > POINTER_TOLERANCE
    then
        post_input_failure(
            "pointer_position_mismatch",
            string.format("requested=(%d,%d), actual=(%d,%d)", x, y, actual_x, actual_y)
        )
    end
    return actual_x, actual_y
end

local function settle(ctx, action, duration)
    if duration == 0 then
        return
    end
    if type(ctx.time) == "table" and type(ctx.time.sleep_ms) == "function" then
        local ok, problem = pcall(ctx.time.sleep_ms, duration)
        if not ok then
            post_input_failure("input_settle_failed", bounded_diagnostic(problem))
        end
        return
    end
    local _, kind, detail = exec_result(
        ctx,
        "sleep",
        { string.format("%.3f", duration / 1000) },
        { timeout_ms = math.max(EXEC_TIMEOUT_MS, duration + SLEEP_TIMEOUT_MARGIN_MS) }
    )
    if kind then
        post_input_failure("input_settle_failed", detail)
    end
end

settle_duration = function(params, action)
    local default = action == "click" and CLICK_SETTLE_MS or DEFAULT_SETTLE_MS
    return integer(params.settle_ms or default, "settle_ms", 0, 5000)
end

local function log_target(ctx, action, normalized_x, normalized_y, x, y)
    accuracy_log(ctx, string.format(
        "%s target normalized=(%.6f,%.6f) mapped=(%d,%d)",
        action, normalized_x, normalized_y, x, y
    ))
end

local function perform_action(params, ctx, signature, snapshot)
    local action = params.action
    local monitor = snapshot.monitor
    if action == "type" and not monitor.focused then
        input_not_delivered("monitor_not_focused")
    end
    if action == "click" then
        local x, y = normalized_point(params, monitor)
        log_target(ctx, action, params.x, params.y, x, y)
        move_and_verify(ctx, signature, action, x, y)
        run_delivery(ctx, action, {
            "click", "--next-delay", tostring(CLICK_HOLD_MS), "0xC0",
        })
        settle(ctx, action, settle_duration(params, action))
        return
    end
    if action == "type" then
        run_delivery(ctx, action, { "type", "--key-delay", "12", "--", params.text })
        settle(ctx, action, settle_duration(params, action))
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

local function capture(ctx, signature, monitor, _grid, action)
    local cursor_visible = false
    local _, _, logical_width, logical_height = monitor_dimensions(monitor)
    local grim_args = { "-t", "png", "-s", tostring(monitor.scale) }
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
            fail(action .. ": screenshot cancelled by the host; no new observation was produced. Do not retry during this cancelled turn; begin the next active turn by calling computer with action='observe' (" .. detail .. ")")
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

    local image_hash = image_sha256(ctx, image, action)
    local trace = ctx.__computer_trace
    if type(trace) == "table" then
        trace.captures = type(trace.captures) == "table" and trace.captures or {}
        trace.captures[#trace.captures + 1] = {
            width = width,
            height = height,
            bytes = #image,
            sha256 = image_hash,
            cursor_visible = cursor_visible,
        }
    end
    return image, image_hash, width, height, cursor_visible
end

local function render_grid(ctx, image, width, height, action)
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
    rendered, rendered_width, rendered_height = validate_png(rendered, action)
    if rendered_width ~= width or rendered_height ~= height then
        fail(action .. ": grid rendering changed screenshot geometry")
    end
    return rendered
end

local function stable_observation_failure(message, capture_action)
    message = tostring(message)
    if capture_action == "validation" or not input_actions[capture_action] then
        if not message:find("action was not sent", 1, true) then
            message = message .. "; action was not sent"
        end
        if not message:find(OBSERVE_RECOVERY, 1, true) then
            message = message .. ". " .. OBSERVE_RECOVERY
        end
    end
    fail(message)
end

local function stable_observation(ctx, action, requested_monitor, signature, capture_action)
    local before
    if signature then
        local kind
        before, kind = snapshot_once(ctx, signature, action, requested_monitor)
        if not before then
            stable_observation_failure(
                action .. ": stable observation metadata failed before capture (" .. tostring(kind) .. ")",
                capture_action
            )
        end
    else
        local observed
        observed, signature, before = pcall(
            snapshot_with_race, ctx, action, requested_monitor
        )
        if not observed then
            stable_observation_failure(signature, capture_action)
        end
    end

    local captured, image, image_hash, width, height, cursor_visible = pcall(
        capture,
        ctx,
        signature,
        before.monitor,
        false,
        capture_action or action
    )
    if not captured then
        stable_observation_failure(image, capture_action)
    end
    local after, kind = snapshot_once(ctx, signature, action, before.monitor.name)
    if not after then
        stable_observation_failure(
            action .. ": stable observation metadata failed after capture (" .. tostring(kind) .. ")",
            capture_action
        )
    end
    if not same_snapshot(before, after) then
        stable_observation_failure(
            action .. ": screen context changed during capture",
            capture_action
        )
    end
    return signature, after, image, image_hash, width, height, cursor_visible
end

local function image_tiles(ctx, image, width, height, action)
    if type(ctx.codec.png_tiles) == "function" then
        local ok, result = pcall(ctx.codec.png_tiles, image, TILE_COLUMNS, TILE_ROWS)
        if ok and type(result) == "table"
            and result.width == width
            and result.height == height
            and result.columns == TILE_COLUMNS
            and result.rows == TILE_ROWS
            and type(result.hashes) == "table"
            and #result.hashes == TILE_COLUMNS * TILE_ROWS
        then
            for _, hash in ipairs(result.hashes) do
                if type(hash) ~= "string" or #hash ~= 64 then
                    fail(action .. ": native PNG tile fingerprinting returned invalid data")
                end
            end
            return result
        elseif ok then
            fail(action .. ": native PNG tile fingerprinting returned invalid data")
        else
            fail(action .. ": native PNG tile fingerprinting failed ("
                .. (bounded_diagnostic(result) or "native codec failure") .. ")")
        end
    end

    local sample_width = TILE_COLUMNS * TILE_SAMPLE_FACTOR
    local sample_height = TILE_ROWS * TILE_SAMPLE_FACTOR
    local pixels, kind, detail = exec_result(ctx, "magick", {
        "png:-",
        "-filter", "box",
        "-resize", string.format("%dx%d!", sample_width, sample_height),
        "-depth", "8",
        "rgba:-",
    }, {
        stdin = image,
        max_output_bytes = sample_width * sample_height * 4,
    })
    if not pixels or #pixels ~= sample_width * sample_height * 4 then
        fail(action .. ": target-region fingerprinting failed ("
            .. (bounded_diagnostic(detail or kind) or "invalid pixel data") .. ")")
    end
    local hashes = {}
    local stride = sample_width * 4
    local tile_pixel_width = TILE_SAMPLE_FACTOR
    local tile_pixel_height = TILE_SAMPLE_FACTOR
    for row = 0, TILE_ROWS - 1 do
        for column = 0, TILE_COLUMNS - 1 do
            local r, g, b = 0, 0, 0
            local pixel_count = 0
            for ty = 0, tile_pixel_height - 1 do
                for tx = 0, tile_pixel_width - 1 do
                    local offset = ((row * tile_pixel_height + ty) * stride)
                        + ((column * tile_pixel_width + tx) * 4)
                        + 1
                    r = r + pixels:byte(offset)
                    g = g + pixels:byte(offset + 1)
                    b = b + pixels:byte(offset + 2)
                    pixel_count = pixel_count + 1
                end
            end
            r = math.floor(r / pixel_count + 0.5)
            g = math.floor(g / pixel_count + 0.5)
            b = math.floor(b / pixel_count + 0.5)
            local qr = math.min(63, math.floor(r / 4))
            local qg = math.min(63, math.floor(g / 4))
            local qb = math.min(63, math.floor(b / 4))
            local hash = string.format("%02x%02x%02x", qr, qg, qb)
            hashes[#hashes + 1] = hash
        end
    end
    return {
        width = width,
        height = height,
        columns = TILE_COLUMNS,
        rows = TILE_ROWS,
        hashes = hashes,
    }
end

local function tile_index(grid, normalized_x, normalized_y)
    local column = math.min(
        grid.columns - 1,
        math.floor(normalized_x * grid.columns)
    )
    local row = math.min(
        grid.rows - 1,
        math.floor(normalized_y * grid.rows)
    )
    return row * grid.columns + column + 1
end

local function coordinate_tiles(params, prior)
    if params.action == "click" then
        return { tile_index(prior.tile_grid, params.x, params.y) }
    end
    return {}
end

local function validate_coordinate_freshness(params, prior, current)
    if type(prior.tile_grid) ~= "table"
        or type(prior.tile_grid.hashes) ~= "table"
        or prior.tile_grid.columns ~= current.columns
        or prior.tile_grid.rows ~= current.rows
        or prior.tile_grid.width ~= current.width
        or prior.tile_grid.height ~= current.height
    then
        fail(params.action .. ": referenced target-region fingerprints are unavailable; action was not sent. " .. OBSERVE_RECOVERY)
    end
    local seen = {}
    for _, index in ipairs(coordinate_tiles(params, prior)) do
        if not seen[index] then
            seen[index] = true
            if type(prior.tile_grid.hashes[index]) ~= "string"
                or prior.tile_grid.hashes[index] ~= current.hashes[index]
            then
                fail(params.action .. ": pixels around the intended target changed; action was not sent. " .. OBSERVE_RECOVERY)
            end
        end
    end
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
    if type(ctx.codec.png_resize) == "function" then
        local ok, result = pcall(
            ctx.codec.png_resize,
            image,
            MODEL_IMAGE_MAX_WIDTH,
            MODEL_IMAGE_MAX_HEIGHT
        )
        if not ok then
            fail(action .. ": native model screenshot resize failed ("
                .. (bounded_diagnostic(result) or "native codec failure") .. ")")
        end
        if type(result) ~= "table"
            or type(result.png) ~= "string"
            or result.width ~= target_width
            or result.height ~= target_height
            or result.resized ~= true
        then
            fail(action .. ": native model screenshot resize returned invalid data")
        end
        local resized
        local resized_width
        local resized_height
        resized, resized_width, resized_height = validate_png(result.png, action)
        if resized_width ~= target_width or resized_height ~= target_height then
            fail(action .. ": native model screenshot resize produced invalid geometry")
        end
        return resized, resized_width, resized_height
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

local function changed_bounds(ctx, before_image, after_image, width, height, _operation_id)
    if before_image == nil
        or after_image == nil
        or type(ctx.codec.png_diff) ~= "function"
    then
        return nil
    end
    local ok, result = pcall(ctx.codec.png_diff, before_image, after_image)
    if not ok or type(result) ~= "table" then
        return nil
    end
    if result.equal == true then
        return false
    end
    local bounds = result.bounds
    if type(bounds) ~= "table" then
        return nil
    end
    local x = bounds.x
    local y = bounds.y
    local box_width = bounds.width
    local box_height = bounds.height
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

local function canonical_value(value)
    local kind = type(value)
    if kind == "string" then
        return "s" .. tostring(#value) .. ":" .. value
    elseif kind == "number" then
        return "n" .. string.format("%.17g", value)
    elseif kind == "boolean" then
        return value and "b1" or "b0"
    elseif kind == "nil" then
        return "z"
    elseif kind ~= "table" then
        fail("request contains an unsupported value")
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)
    local encoded = { "t" }
    for _, key in ipairs(keys) do
        encoded[#encoded + 1] = canonical_value(key)
        encoded[#encoded + 1] = canonical_value(value[key])
    end
    return table.concat(encoded)
end

local function request_digest(ctx, params)
    return digest_fields(ctx, params.action, { canonical_value(params) })
end

local function ledger_entry(state, call_id)
    for _, entry in ipairs(state.ledger or {}) do
        if type(entry) == "table" and entry.call_id == call_id then
            return entry
        end
    end
    return nil
end

local function append_ledger(state, entry)
    state.ledger = type(state.ledger) == "table" and state.ledger or {}
    state.ledger[#state.ledger + 1] = entry
    while #state.ledger > MAX_LEDGER_ENTRIES do
        table.remove(state.ledger, 1)
    end
end

local function replay_response(entry, state)
    local outcome = type(entry.outcome) == "table" and entry.outcome or {}
    local authorization = type(state) == "table" and state.authorization or nil
    local resumable = type(state) == "table"
        and entry.status == "completed"
        and outcome.screenshot_id == state.screenshot_id
        and outcome.operation_generation == state.operation_generation
        and type(authorization) == "table"
        and authorization.consumed ~= true
    return json.encode({
        content = json.encode({
            operation_id = entry.operation_id,
            call_id = entry.call_id,
            action = entry.action,
            replayed = true,
            ledger_status = entry.status,
            input_delivery = outcome.input_delivery
                or (entry.status == "completed" and "sent_unverified" or "not_repeated"),
            visual_change = outcome.visual_change,
            reason_code = outcome.reason_code
                or (entry.status == "completed" and "completed_replay" or "replay_blocked"),
            retry_input = false,
            next_action = resumable and nil or "observe",
            recovery = resumable and nil or OBSERVE_RECOVERY,
        }),
    })
end

local function check_call_replay(state, call_id, digest)
    local entry = ledger_entry(state, call_id)
    if not entry then
        return nil
    end
    if entry.params_sha256 ~= digest then
        fail("call_id was already used with different parameters; action was not sent. " .. OBSERVE_RECOVERY)
    end
    return replay_response(entry, state)
end

local function reserve_action(ctx, state, params, operation_id, call_id, digest)
    local authorization = state.authorization
    if type(authorization) ~= "table" or authorization.consumed == true then
        fail("latest computer observation is unavailable or already consumed; action was not sent. " .. OBSERVE_RECOVERY)
    end
    authorization.consumed = true
    authorization.consumed_by = digest
    authorization.consumed_monotonic_ms = monotonic_ms(ctx)
    state.blocked_reason = nil
    append_ledger(state, {
        call_id = call_id,
        operation_id = operation_id,
        action = params.action,
        params_sha256 = digest,
        status = "in_flight",
        started_monotonic_ms = monotonic_ms(ctx),
    })
    local ok, problem = pcall(ctx.state.set, STATE_KEY, json.encode(state))
    if not ok then
        fail(params.action .. ": could not reserve single-use input authorization; action was not sent ("
            .. privacy_safe_observation_detail(problem) .. "). " .. OBSERVE_RECOVERY)
    end
end

local function finish_ledger(state, call_id, status, outcome)
    local entry = ledger_entry(state, call_id)
    if not entry then
        return
    end
    entry.status = status
    entry.finished_monotonic_ms = outcome.finished_monotonic_ms
    entry.outcome = {
        screenshot_id = outcome.screenshot_id,
        operation_generation = outcome.operation_generation,
        input_delivery = outcome.input_delivery,
        visual_change = outcome.visual_change,
        reason_code = outcome.reason_code,
    }
end

local function block_after_input(ctx, state, call_id, reason_code)
    state.authorization = nil
    state.blocked_reason = reason_code
    finish_ledger(state, call_id, "ambiguous", {
        input_delivery = "sent_unverified",
        reason_code = reason_code,
        finished_monotonic_ms = monotonic_ms(ctx),
    })
    pcall(ctx.state.set, STATE_KEY, json.encode(state))
end

local function save_response(
    ctx, prior, signature, snapshot, params, grid, operation_id, call_id,
    image, image_hash, width, height, cursor_visible, before_image, before_hash
)
    local action = params.action
    local exact_unchanged = prior and prior.image_sha256 == image_hash
    local unchanged = prior
        and prior.image_width == width
        and prior.image_height == height
        and exact_unchanged
    local generation = unchanged and prior.generation or (prior and prior.generation + 1 or 1)
    local operation_generation = prior and (prior.operation_generation or 0) + 1 or 1
    local screenshot_id = unchanged and prior.screenshot_id or "computer-" .. tostring(generation)
    local captured_at = monotonic_ms(ctx)
    local privacy_salt = prior and prior.privacy_salt
        or random_hex(ctx, 16, operation_id)
    local tile_grid = image_tiles(ctx, image, width, height, action)
    local state = {
        version = STATE_VERSION,
        screenshot_id = screenshot_id,
        generation = generation,
        operation_generation = operation_generation,
        privacy_salt = privacy_salt,
        signature_sha256 = digest_fields(ctx, action, { privacy_salt, signature }),
        context_sha256 = context_fingerprint(
            ctx, action, privacy_salt, signature, snapshot
        ),
        monitor = stored_monitor(snapshot),
        image_sha256 = image_hash,
        image_width = width,
        image_height = height,
        geometry_fingerprint = geometry_fingerprint(ctx, snapshot.monitor, width, height, action),
        captured_monotonic_ms = captured_at,
        cursor_visible = cursor_visible,
        grid = grid,
        tile_grid = tile_grid,
        authorization = {
            issued_monotonic_ms = captured_at,
            consumed = false,
        },
        ledger = prior and prior.ledger or {},
    }

    local pixel_width, pixel_height, logical_width, logical_height = monitor_dimensions(snapshot.monitor)
    local attachment_width, attachment_height = model_image_dimensions(width, height)
    local target = point_metadata(
        params, snapshot, width, height, nil, attachment_width, attachment_height
    )
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
    local input_delivery = input_actions[action] and "sent_unverified" or "not_applicable"
    local trace = ctx.__computer_trace
    if type(trace) == "table" then
        trace.context_sha256 = state.context_sha256
        trace.instance_sha256 = state.signature_sha256
        trace.visual = {
            evidence = evidence,
            bounds = change_bounds,
            image_reused = unchanged == true,
        }
    end
    if input_actions[action] then
        finish_ledger(state, call_id, "completed", {
            screenshot_id = screenshot_id,
            operation_generation = operation_generation,
            input_delivery = input_delivery,
            visual_change = evidence,
            reason_code = "completed",
            finished_monotonic_ms = captured_at,
        })
    end

    local content = {
        operation_id = operation_id,
        call_id = call_id,
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
        monitor_selection = "To observe another monitor, call computer with action='observe' and monitor set to its name or 'other'.",
        coordinates = "Use finite normalized coordinates from 0 through 1 with the attached screenshot.",
        screenshot_captured = true,
        screenshot_attached = true,
        visual_change = evidence,
        change_bounds = change_bounds,
        input_delivery = input_delivery,
        grid = grid,
        reason_code = "completed",
    }
    content.target = target
    if input_actions[action] then
        content.settle_ms = settle_duration(params, action)
    end
    local presentation_image = grid and render_grid(ctx, image, width, height, action) or image
    local attached_image
    attached_image, attachment_width, attachment_height = model_image(
        ctx, presentation_image, width, height, action
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
    if input_actions[action] then
        content.image_instruction = "A fresh downscaled post-action PNG is attached. Input was sent but not independently verified; inspect the image to determine whether the intended UI effect occurred. The attached screenshot is the basis for the next action, and coordinates remain normalized to the full monitor."
    else
        content.image_instruction = "A downscaled PNG screenshot is attached; inspect it directly before choosing normalized full-monitor coordinates for the next action."
    end
    content.trace = trace_finish(ctx, "completed")
    local response = json.encode({
        content = json.encode(content),
        images = images,
        ephemeral_images = true,
    })

    -- Prepare the complete response before rotating the implicit observation.
    -- If image presentation or encoding fails, the prior observation remains current.
    ctx.state.set(STATE_KEY, json.encode(state))
    return response
end

local action_status = {
    click = "clicking",
    type = "typing",
}

local function status(ctx, message)
    ctx.ui.status("computer - " .. message)
end

local function input_observation_failure(
    ctx, state, action, operation_id, call_id, reason, detail
)
    block_after_input(ctx, state, call_id, reason)
    return json.encode({
        content = json.encode({
            operation_id = operation_id,
            call_id = call_id,
            action = action,
            input_delivery = "sent_unverified",
            screenshot_captured = false,
            observation = reason,
            observation_detail = privacy_safe_observation_detail(detail),
            reason_code = reason,
            retry_input = false,
            next_action = "observe",
            recovery = OBSERVE_RECOVERY,
            trace = trace_finish(ctx, reason),
        }),
    })
end

local function input_not_delivered_response(
    ctx, state, action, operation_id, call_id, reason
)
    state.blocked_reason = nil
    finish_ledger(state, call_id, "not_delivered", {
        input_delivery = "not_delivered",
        reason_code = reason,
        finished_monotonic_ms = monotonic_ms(ctx),
    })
    pcall(ctx.state.set, STATE_KEY, json.encode(state))
    return json.encode({
        content = json.encode({
            operation_id = operation_id,
            call_id = call_id,
            action = action,
            input_delivery = "not_delivered",
            screenshot_captured = false,
            observation = reason,
            reason_code = reason,
            retry_input = false,
            next_action = "observe",
            recovery = OBSERVE_RECOVERY,
            trace = trace_finish(ctx, reason),
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
    validate_request(params)
    local action = params.action
    local call_id = type(ctx.call_id) == "string" and ctx.call_id ~= ""
        and ctx.call_id
        or nil
    if input_actions[action] and (not call_id or #call_id > 256) then
        fail("computer input requires a bounded host call_id; action was not sent. " .. OBSERVE_RECOVERY)
    end
    local prior
    if action == "observe" then
        local loaded, value = pcall(load_state, ctx)
        prior = loaded and value or nil
    else
        prior = load_state(ctx)
        if not prior then
            fail("no current computer observation; action was not sent. " .. OBSERVE_RECOVERY)
        end
    end
    local operation_generation = prior and (prior.operation_generation or 0) + 1 or 1
    local operation_id = "computer-op-" .. random_hex(
        ctx,
        12,
        tostring(call_id or "") .. ":" .. tostring(operation_generation)
    )
    trace_begin(ctx, params.trace, operation_id, call_id, action)

    local digest
    if input_actions[action] then
        digest = request_digest(ctx, params)
        local replay = check_call_replay(prior, call_id, digest)
        if replay then
            trace_finish(ctx, "call_replay")
            return replay
        end
    end
    if action ~= "observe" then
        if prior.blocked_reason then
            fail("computer input is blocked after "
                .. tostring(prior.blocked_reason)
                .. "; action was not sent. " .. OBSERVE_RECOVERY)
        end
        if monotonic_ms(ctx) - prior.captured_monotonic_ms
            > SCREENSHOT_TTL_SECONDS * 1000
        then
            fail("latest computer observation expired; action was not sent. " .. OBSERVE_RECOVERY)
        end
        local authorization = prior.authorization
        if type(authorization) ~= "table" or authorization.consumed == true then
            fail("latest computer observation is unavailable or already consumed; action was not sent. " .. OBSERVE_RECOVERY)
        end
    end

    local signature
    local before
    local before_image
    local before_hash
    local before_width
    local before_height
    local final_snapshot
    local final_image
    local final_hash
    local final_width
    local final_height
    local final_cursor_visible

    if action == "observe" then
        trace_stage(ctx, "stable_observation")
        status(ctx, "taking stable screenshot")
        signature, final_snapshot, final_image, final_hash,
            final_width, final_height, final_cursor_visible = stable_observation(
                ctx, action, params.monitor, nil, action
            )
    else
        trace_stage(ctx, "stable_pre_action_observation")
        status(ctx, "checking stable screen context")
        signature, before, before_image, before_hash,
            before_width, before_height = stable_observation(
                ctx, action, prior.monitor.name, nil, "validation"
            )
        local signature_hash = digest_fields(
            ctx, action, { prior.privacy_salt, signature }
        )
        local current_context = context_fingerprint(
            ctx, action, prior.privacy_salt, signature, before
        )
        if signature_hash ~= prior.signature_sha256
            or current_context ~= prior.context_sha256
        then
            fail("screen context changed; action was not sent. " .. OBSERVE_RECOVERY)
        end

        trace_stage(ctx, "freshness_validation")
        status(ctx, "validating target freshness")
        local current_tiles = image_tiles(
            ctx, before_image, before_width, before_height, action
        )
        validate_coordinate_freshness(params, prior, current_tiles)

        status(ctx, action_status[action])
        trace_stage(ctx, "reserve_input")
        reserve_action(ctx, prior, params, operation_id, call_id, digest)
        trace_stage(ctx, "input")
        local performed, perform_error = pcall(
            perform_action, params, ctx, signature, before
        )
        if not performed then
            if type(perform_error) == "table"
                and perform_error.marker == INPUT_NOT_DELIVERED
            then
                return input_not_delivered_response(
                    ctx,
                    prior,
                    action,
                    operation_id,
                    call_id,
                    perform_error.reason
                )
            end
            if type(perform_error) == "table"
                and perform_error.marker == POST_INPUT_FAILURE
            then
                return input_observation_failure(
                    ctx,
                    prior,
                    action,
                    operation_id,
                    call_id,
                    perform_error.reason,
                    perform_error.detail
                )
            end
            return input_observation_failure(
                ctx,
                prior,
                action,
                operation_id,
                call_id,
                "input_execution_failed",
                perform_error
            )
        end

        trace_stage(ctx, "stable_post_action_observation")
        status(ctx, "taking stable post-action screenshot")
        local observed
        observed, signature, final_snapshot, final_image, final_hash,
            final_width, final_height, final_cursor_visible = pcall(
                stable_observation,
                ctx,
                action,
                before.monitor.name,
                signature,
                action
            )
        if not observed then
            return input_observation_failure(
                ctx,
                prior,
                action,
                operation_id,
                call_id,
                "post_action_observation_failed",
                signature
            )
        end
    end

    trace_stage(ctx, "persist_response")
    status(ctx, "screenshot ready")
    local saved, response = pcall(
        save_response,
        ctx,
        prior,
        signature,
        final_snapshot,
        params,
        params.grid == true,
        operation_id,
        call_id,
        final_image,
        final_hash,
        final_width,
        final_height,
        final_cursor_visible,
        before_image,
        before_hash
    )
    if saved then
        return response
    end
    if input_actions[action] then
        return input_observation_failure(
            ctx,
            prior,
            action,
            operation_id,
            call_id,
            "response_persistence_failed",
            response
        )
    end
    fail(response)
end

local function failure_reason_code(message)
    local rules = {
        { "no current computer observation", "stale_screenshot" },
        { "latest computer observation expired", "observation_expired" },
        { "latest computer observation is unavailable or already consumed", "observation_consumed" },
        { "call_id was already used", "call_id_conflict" },
        { "computer input is blocked after", "authorization_blocked" },
        { "screen context changed", "context_changed" },
        { "pixels around the intended target changed", "target_pixels_changed" },
        { "DPMS off", "output_dpms_off" },
        { "Hyprland", "hyprland_unavailable" },
        { "hyprctl", "hyprctl_unavailable" },
        { "grim", "screenshot_unavailable" },
        { "ImageMagick", "imagemagick_unavailable" },
        { "ydotool", "ydotool_unavailable" },
        { "cancelled", "cancelled" },
    }
    for _, rule in ipairs(rules) do
        if message:find(rule[1], 1, true) then
            return rule[2]
        end
    end
    return "request_rejected"
end

local function execute(params, ctx)
    ctx.__computer_trace = nil
    local ok, result = pcall(execute_inner, params, ctx)
    if ok then
        return result
    end
    local message = tostring(result)
    local reason_code = failure_reason_code(message)
    local trace = trace_finish(ctx, reason_code)
    if trace and type(params) == "table" and params.trace == true then
        return json.encode({
            content = json.encode({
                ok = false,
                action = params.action,
                input_delivery = "not_sent",
                reason_code = reason_code,
                retry_input = false,
                next_action = "observe",
                recovery = OBSERVE_RECOVERY,
                trace = trace,
            }),
        })
    end
    ctx.ui.notify("computer - failed: " .. message, "error")
    fail(message)
end

bone.tool.register({
    name = "computer",
    catalog_description = catalog_description,
    description = "Observe or control the selected Hyprland monitor. Click and type target the latest screenshot returned by the preceding successful computer call. Each call verifies the current screen context and returns a fresh screenshot. After any failed, cancelled, or ambiguous input, observe again before further input. Input is serialized, reserved before delivery, sent at most once, and never automatically retried.",
    safety = "danger",
    stateful = true,
    state_key = STATE_KEY,
    display = {
        template = "{action} {target_label}",
        value_labels = {
            action = {
                observe = "observing screen",
                click = "clicking",
                type = "typing",
            },
        },
        show_result = false,
    },
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                description = "Action to perform. Observe starts or recovers control; click and type use the latest returned screenshot.",
                enum = { "observe", "click", "type" },
            },
            monitor = {
                type = "string",
                description = "Observe only: Hyprland output name, 'focused' (default), or 'other' when exactly two monitors are enabled.",
            },
            settle_ms = {
                type = "integer", minimum = 0, maximum = 5000,
                description = "Click/type only: delay after input before capturing the refreshed screenshot.",
            },
            grid = {
                type = "boolean",
                description = "Presentation only: overlay labeled 0.1 coordinate lines with finer 0.05 subdivisions on the returned screenshot.",
            },
            trace = {
                type = "boolean",
                description = "Include a bounded privacy-safe stage/process timing trace.",
            },
            x = {
                type = "number", minimum = 0, maximum = 1,
                description = "Click only: normalized horizontal coordinate on the latest full-monitor screenshot.",
            },
            y = {
                type = "number", minimum = 0, maximum = 1,
                description = "Click only: normalized vertical coordinate on the latest full-monitor screenshot.",
            },
            target_label = {
                type = "string",
                minLength = 1,
                maxLength = 80,
                description = "Click only: concise non-sensitive description of the visible target for the transcript label; does not affect target selection.",
            },
            text = {
                type = "string",
                minLength = 1,
                maxLength = 10000,
                description = "Type only: text to enter in the currently focused window.",
            },
        },
        required = { "action" },
        additionalProperties = false,
    },
    execute = execute,
})
