local catalog_description = "Control Hyprland with hardened screenshots, AT-SPI semantic targets, freshness checks, and direct input execution."

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
local INSPECT_RADIUS = 96
local INSPECT_SIZE = 768
local TARGET_PATCH_RADIUS = 24
local TARGET_LOCK_TTL_SECONDS = 60
local SCREENSHOT_TTL_SECONDS = 120
local MAX_LEDGER_ENTRIES = 32
local TILE_COLUMNS = 32
local TILE_ROWS = 18
local TILE_SAMPLE_FACTOR = 3
local POINTER_TOLERANCE = 1
local MAX_TEXT_BYTES = 10000
local MAX_DIAGNOSTIC_BYTES = 1024
local MAX_SEMANTIC_BYTES = 256 * 1024
local MAX_SEMANTIC_TARGETS = 64
local SEMANTIC_TIMEOUT_MS = 2500
local TRACE_VERSION = 1

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
    local now = monotonic_ms(ctx)
    if trace.current_stage then
        trace.current_stage.elapsed_ms = math.max(0, now - trace.current_stage.started_ms)
        trace.current_stage.started_ms = nil
        trace.current_stage = nil
    end
    trace.total_elapsed_ms = math.max(0, now - trace.started_ms)
    trace.started_ms = nil
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
        "workspace", "focused",
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
        or type(state.monitor) ~= "table"
        or type(state.ledger) ~= "table"
        or not finite(state.captured_monotonic_ms)
        or state.captured_monotonic_ms < 0
    then
        fail("invalid computer state; call observe again")
    end
    return state
end

local mutating_actions = {
    move = true, click = true, click_locked = true, semantic_click = true,
    double_click = true, right_click = true, drag = true, scroll = true,
    type = true, key = true,
}

local allowed_fields = {
    observe = { action = true, monitor = true, grid = true, trace = true },
    inspect = {
        action = true, screenshot_id = true, x = true, y = true,
        radius = true, grid = true, trace = true,
    },
    semantic_find = {
        action = true, screenshot_id = true, grid = true, trace = true,
        query = true, roles = true, near = true, max_results = true,
    },
    semantic_click = {
        action = true, screenshot_id = true, semantic_id = true,
        action_token = true, target_label = true, settle_ms = true,
        grid = true, trace = true,
    },
    move = {
        action = true, screenshot_id = true, action_token = true,
        x = true, y = true, settle_ms = true, grid = true, trace = true,
    },
    click = {
        action = true, screenshot_id = true, action_token = true,
        x = true, y = true, target_label = true, settle_ms = true,
        grid = true, trace = true,
    },
    click_locked = {
        action = true, screenshot_id = true, action_token = true,
        target_token = true, target_label = true, settle_ms = true,
        grid = true, trace = true,
    },
    double_click = {
        action = true, screenshot_id = true, action_token = true,
        x = true, y = true, target_label = true, settle_ms = true,
        grid = true, trace = true,
    },
    right_click = {
        action = true, screenshot_id = true, action_token = true,
        x = true, y = true, target_label = true, settle_ms = true,
        grid = true, trace = true,
    },
    drag = {
        action = true, screenshot_id = true, action_token = true,
        start_x = true, start_y = true, end_x = true, end_y = true,
        settle_ms = true, grid = true, trace = true,
    },
    scroll = {
        action = true, screenshot_id = true, action_token = true,
        x = true, y = true, amount = true, settle_ms = true,
        grid = true, trace = true,
    },
    type = {
        action = true, screenshot_id = true, action_token = true,
        text = true, settle_ms = true, grid = true, trace = true,
    },
    key = {
        action = true, screenshot_id = true, action_token = true,
        keys = true, settle_ms = true, grid = true, trace = true,
    },
    wait = {
        action = true, screenshot_id = true, duration_ms = true,
        grid = true, trace = true,
    },
}

local key_args
local settle_duration

local function validate_normalized(value, name)
    if not finite(value) or value < 0 or value > 1 then
        fail(name .. " must be a finite number from 0 through 1")
    end
end

local function validate_semantic_filters(params)
    if params.query ~= nil
        and (type(params.query) ~= "string"
            or #params.query == 0
            or #params.query > 160
            or params.query:find("[%z\1-\31\127]"))
    then
        fail("query must be non-empty printable text of at most 160 bytes")
    end
    if params.roles ~= nil then
        if type(params.roles) ~= "table" or #params.roles == 0 or #params.roles > 16 then
            fail("roles must contain from 1 through 16 semantic role names")
        end
        local seen = {}
        for _, role in ipairs(params.roles) do
            if type(role) ~= "string"
                or #role == 0
                or #role > 40
                or not role:match("^[a-z_]+$")
                or seen[role]
            then
                fail("roles must contain unique lowercase semantic role names")
            end
            seen[role] = true
        end
    end
    if params.near ~= nil then
        if type(params.near) ~= "table" then
            fail("near must contain normalized x and y coordinates")
        end
        for key in pairs(params.near) do
            if key ~= "x" and key ~= "y" and key ~= "radius" then
                fail("near contains an irrelevant field")
            end
        end
        validate_normalized(params.near.x, "near.x")
        validate_normalized(params.near.y, "near.y")
        if params.near.radius ~= nil then
            validate_normalized(params.near.radius, "near.radius")
            if params.near.radius == 0 then
                fail("near.radius must be greater than zero")
            end
        end
    end
    if params.max_results ~= nil then
        integer(params.max_results, "max_results", 1, MAX_SEMANTIC_TARGETS)
    end
end

local function validate_request(params)
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
    local requires_screenshot = params.action ~= "observe"
    if requires_screenshot
        and (type(params.screenshot_id) ~= "string"
            or #params.screenshot_id == 0
            or #params.screenshot_id > 128)
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
        and (type(params.target_token) ~= "string"
            or #params.target_token == 0
            or #params.target_token > 128)
    then
        fail("target_token is required for click_locked; call inspect first")
    end
    local action = params.action
    if action == "inspect" or action == "move" or action == "click"
        or action == "double_click" or action == "right_click" or action == "scroll"
    then
        validate_normalized(params.x, "x")
        validate_normalized(params.y, "y")
    elseif action == "drag" then
        validate_normalized(params.start_x, "start_x")
        validate_normalized(params.start_y, "start_y")
        validate_normalized(params.end_x, "end_x")
        validate_normalized(params.end_y, "end_y")
    end
    if action == "inspect" and params.radius ~= nil then
        integer(params.radius, "radius", 32, 256)
    elseif action == "scroll" then
        local amount = integer(params.amount, "amount", -20, 20)
        if amount == 0 then
            fail("amount must not be zero")
        end
    elseif action == "type" then
        if type(params.text) ~= "string"
            or #params.text == 0
            or #params.text > MAX_TEXT_BYTES
            or params.text:find("\0", 1, true)
        then
            fail("text must be a non-empty string of at most 10000 bytes without NUL")
        end
    elseif action == "key" then
        key_args(params.keys)
    elseif action == "wait" then
        integer(params.duration_ms or 1000, "duration_ms", 0, 10000)
    elseif action == "semantic_find" then
        validate_semantic_filters(params)
    end
    if mutating_actions[action] then
        settle_duration(params, action)
        if type(params.action_token) ~= "string"
            or #params.action_token < 16
            or #params.action_token > 128
        then
            fail("action_token is required for input actions; copy it from the immediately preceding successful observation")
        end
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

key_args = function(value)
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

local function sanitized_count(value, maximum)
    if finite(value)
        and value % 1 == 0
        and value >= 0
        and value <= maximum
    then
        return value
    end
    return nil
end

local function sanitized_numeric_map(value, maximum)
    local result = {}
    if type(value) ~= "table" then
        return result
    end
    for key, count in pairs(value) do
        if type(key) == "string"
            and #key > 0
            and #key <= 48
            and key:match("^[a-z0-9_]+$")
            and finite(count)
            and count % 1 == 0
            and count >= 0
            and count <= maximum
        then
            result[key] = count
        end
    end
    return result
end

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
        or type(target.fingerprint) ~= "string"
        or not target.fingerprint:match("^atspi%-fp:v1:[0-9a-f]+$")
        or #target.fingerprint ~= 76
        or type(target.role) ~= "string"
        or #target.role == 0 or #target.role > 64
        or type(target.name) ~= "string"
        or #target.name > 256
        or type(target.states) ~= "table"
        or type(target.bounds) ~= "table"
        or type(target.center) ~= "table"
        or type(target.actions) ~= "table"
        or type(target.direct_activation) ~= "boolean"
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
    local seen_actions = {}
    for _, name in ipairs(target.actions) do
        if type(name) ~= "string"
            or #name == 0
            or #name > 40
            or not name:match("^[a-z_]+$")
            or seen_actions[name]
        then
            fail(action .. ": invalid semantic helper result")
        end
        seen_actions[name] = true
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

local function semantic_call(ctx, operation, snapshot, expected, params)
    local helper = semantic_helper_path(ctx)
    if not helper then
        return nil, "semantic helper location is unavailable"
    end
    local request = { window = snapshot.window }
    if expected then
        request.target_id = expected.id
        request.fingerprint = expected.fingerprint
        request.expected = expected
    end
    if operation == "discover" and params then
        request.query = params.query
        request.roles = params.roles
        request.max_results = params.max_results
        if params.near then
            local x, y = normalized_point(params.near, snapshot.monitor)
            local _, _, logical_width, logical_height = monitor_dimensions(snapshot.monitor)
            request.near = {
                x = x,
                y = y,
                radius = params.near.radius
                    and math.max(1, math.floor(
                        params.near.radius * math.min(logical_width, logical_height) + 0.5
                    ))
                    or nil,
            }
        end
    end
    local raw, kind, detail = exec_result(ctx, "python3", { helper, operation }, {
        stdin = json.encode(request),
        timeout_ms = SEMANTIC_TIMEOUT_MS,
        max_output_bytes = MAX_SEMANTIC_BYTES,
        env = instance_environment(),
    })
    if not raw then
        if kind == "spawn" then
            return nil, "Python 3 is unavailable", "python_unavailable"
        end
        return nil, "AT-SPI helper failed safely", "helper_execution_failed"
    end
    local ok, result = pcall(decode_json, raw, "invalid semantic helper output")
    if not ok or type(result) ~= "table" then
        return nil, "invalid semantic helper output", "helper_output_invalid"
    end
    if result.ok ~= true then
        return nil,
            bounded_diagnostic(result.reason) or "semantic target verification failed",
            bounded_diagnostic(result.reason_code) or "semantic_failure"
    end
    return result
end

local function semantic_discover(ctx, snapshot, params)
    local result, reason, reason_code = semantic_call(ctx, "discover", snapshot, nil, params)
    if not result then
        return {
            available = false,
            reason = reason,
            reason_code = reason_code,
            targets = {},
        }
    end
    if result.available ~= true then
        return {
            available = false,
            reason = bounded_diagnostic(result.reason) or "focused application is not accessible",
            reason_code = bounded_diagnostic(result.reason_code) or "semantic_unavailable",
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
        if seen[target.fingerprint] then
            fail("semantic_find: duplicate semantic target fingerprint")
        end
        seen[target.fingerprint] = true
    end
    local semantic = {
        available = true,
        targets = result.targets,
        truncated = result.truncated == true,
        visited = sanitized_count(result.visited, 100000),
        matched = sanitized_count(result.matched, 100000),
        rejections = sanitized_numeric_map(result.rejections, 100000),
        limits = sanitized_numeric_map(result.limits, 100000),
    }
    local trace = ctx.__computer_trace
    if type(trace) == "table" then
        trace.semantic = {
            visited = semantic.visited,
            matched = semantic.matched,
            returned = #semantic.targets,
            truncated = semantic.truncated,
            rejections = semantic.rejections,
        }
    end
    return semantic
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
    local result, reason = semantic_call(ctx, "resolve", snapshot, expected)
    if not result then
        fail("semantic_click: " .. reason .. "; action was not sent")
    end
    local current = validate_semantic_target(result.target, snapshot, "semantic_click")
    if current.fingerprint ~= expected.fingerprint
        or current.role ~= expected.role
    then
        fail("semantic_click: semantic target identity changed; action was not sent")
    end
    return current
end

local function semantic_activate(ctx, snapshot, expected)
    local result, reason, reason_code = semantic_call(ctx, "activate", snapshot, expected)
    if not result then
        post_input_failure(reason_code or "activation_delivery_ambiguous", reason)
    end
    if result.activated ~= true or result.delivery ~= "delivered" then
        post_input_failure("activation_delivery_ambiguous", "invalid activation result")
    end
    local current = validate_semantic_target(result.target, snapshot, "semantic_click")
    if current.fingerprint ~= expected.fingerprint or current.role ~= expected.role then
        post_input_failure("activation_identity_mismatch", "activated target identity changed")
    end
    current.delivery = "delivered"
    current.activation_action = result.action
    current.state_changed = result.state_changed
    current.direct = true
    return current
end

local function semantic_focus_for_typing(ctx, snapshot)
    local result, reason, reason_code = semantic_call(ctx, "focused", snapshot)
    if not result
        or result.available ~= true
        or result.typing_safe ~= true
        or type(result.target) ~= "table"
    then
        fail("type: accessible focus could not be verified ("
            .. tostring(reason_code or (result and result.reason_code) or reason) .. "); action was not sent")
    end
    return validate_semantic_target(result.target, snapshot, "type")
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
            if semantic_target.direct == true then
                settle(ctx, action, settle_duration(params, action))
                return
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
            if type(ctx.time) == "table" and type(ctx.time.sleep_ms) == "function" then
                local ok, problem = pcall(ctx.time.sleep_ms, duration)
                if not ok then
                    fail("wait failed (" .. bounded_diagnostic(problem) .. ")")
                end
            else
                local _, kind, detail = exec_result(
                    ctx,
                    "sleep",
                    { string.format("%.3f", duration / 1000) },
                    { timeout_ms = duration + SLEEP_TIMEOUT_MARGIN_MS }
                )
                if kind then
                    fail("wait failed (" .. detail .. ")")
                end
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

local function capture(ctx, signature, monitor, _grid, action)
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

local function stable_observation(ctx, action, requested_monitor, signature, capture_action)
    local before
    if signature then
        local kind
        before, kind = snapshot_once(ctx, signature, action, requested_monitor)
        if not before then
            fail(action .. ": stable observation metadata failed before capture (" .. tostring(kind) .. ")")
        end
    else
        signature, before = snapshot_with_race(ctx, action, requested_monitor)
    end

    local image, image_hash, width, height, cursor_visible = capture(
        ctx,
        signature,
        before.monitor,
        false,
        capture_action or action
    )
    local after, kind = snapshot_once(ctx, signature, action, before.monitor.name)
    if not after then
        fail(action .. ": stable observation metadata failed after capture (" .. tostring(kind) .. ")")
    end
    if not same_snapshot(before, after) then
        fail(action .. ": screen context changed during capture; action was not sent")
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
    for row = 0, TILE_ROWS - 1 do
        for column = 0, TILE_COLUMNS - 1 do
            local parts = {}
            for sample_row = 0, TILE_SAMPLE_FACTOR - 1 do
                local offset = (row * TILE_SAMPLE_FACTOR + sample_row) * stride
                    + column * TILE_SAMPLE_FACTOR * 4
                parts[#parts + 1] = pixels:sub(
                    offset + 1,
                    offset + TILE_SAMPLE_FACTOR * 4
                )
            end
            hashes[#hashes + 1] = image_sha256(
                ctx,
                table.concat(parts),
                action .. " target region"
            )
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
    local action = params.action
    if action == "drag" then
        return {
            tile_index(prior.tile_grid, params.start_x, params.start_y),
            tile_index(prior.tile_grid, params.end_x, params.end_y),
        }
    end
    if action == "move" or action == "click" or action == "double_click"
        or action == "right_click" or action == "scroll"
    then
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
        fail(params.action .. ": referenced target-region fingerprints are unavailable; call computer_observe again")
    end
    local seen = {}
    for _, index in ipairs(coordinate_tiles(params, prior)) do
        if not seen[index] then
            seen[index] = true
            if type(prior.tile_grid.hashes[index]) ~= "string"
                or prior.tile_grid.hashes[index] ~= current.hashes[index]
            then
                fail(params.action .. ": pixels around the intended target changed; action was not sent. Call computer_observe again")
            end
        end
    end
end

local function target_patch_hash(ctx, image, width, height, center_x, center_y, action)
    local patch_left = math.max(0, center_x - TARGET_PATCH_RADIUS)
    local patch_top = math.max(0, center_y - TARGET_PATCH_RADIUS)
    local patch_right = math.min(width - 1, center_x + TARGET_PATCH_RADIUS)
    local patch_bottom = math.min(height - 1, center_y + TARGET_PATCH_RADIUS)
    local patch_width = patch_right - patch_left + 1
    local patch_height = patch_bottom - patch_top + 1
    if type(ctx.codec.png_region_sha256) == "function" then
        local ok, result = pcall(
            ctx.codec.png_region_sha256,
            image,
            patch_left,
            patch_top,
            patch_width,
            patch_height
        )
        if not ok then
            fail(action .. ": native target patch hashing failed ("
                .. (bounded_diagnostic(result) or "native codec failure") .. ")")
        end
        if type(result) ~= "table"
            or result.width ~= patch_width
            or result.height ~= patch_height
            or type(result.sha256) ~= "string"
            or #result.sha256 ~= 64
            or not result.sha256:match("^[0-9a-f]+$")
        then
            fail(action .. ": native target patch hashing returned invalid data")
        end
        return result.sha256, {
            x = patch_left,
            y = patch_top,
            width = patch_width,
            height = patch_height,
        }
    end
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

local input_actions = mutating_actions

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
    local created_at = monotonic_ms(ctx)
    local token = "target-" .. random_hex(ctx, 16, table.concat({
        screenshot_id,
        operation_id,
        image_hash,
        tostring(geometry.source_x),
        tostring(geometry.source_y),
    }, ":"))
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
        created_monotonic_ms = created_at,
        expires_monotonic_ms = created_at + TARGET_LOCK_TTL_SECONDS * 1000,
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
        or not finite(lock.expires_monotonic_ms)
    then
        fail("click_locked: target lock geometry is invalid; action was not sent. Call inspect again")
    end
    if monotonic_ms(ctx) > lock.expires_monotonic_ms then
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
        and type(authorization) == "table"
        and authorization.consumed ~= true
        and type(authorization.token) == "string"
    return json.encode({
        content = json.encode({
            operation_id = entry.operation_id,
            call_id = entry.call_id,
            action = entry.action,
            replayed = true,
            ledger_status = entry.status,
            screenshot_id = outcome.screenshot_id,
            input_delivery = outcome.input_delivery
                or (entry.status == "completed" and "sent_unverified" or "not_repeated"),
            visual_change = outcome.visual_change,
            reason_code = outcome.reason_code
                or (entry.status == "completed" and "completed_replay" or "replay_blocked"),
            retry_input = false,
            action_token = resumable and authorization.token or nil,
            next_call = resumable and {
                tool = "computer",
                screenshot_id = state.screenshot_id,
                action_token = authorization.token,
                required = true,
            } or nil,
            next_action = resumable and nil or "observe",
        }),
    })
end

local function check_call_replay(state, call_id, digest)
    local entry = ledger_entry(state, call_id)
    if not entry then
        return nil
    end
    if entry.params_sha256 ~= digest then
        fail("call_id was already used with different parameters; action was not sent")
    end
    return replay_response(entry, state)
end

local function reserve_action(ctx, state, params, operation_id, call_id, digest)
    local authorization = state.authorization
    if type(authorization) ~= "table"
        or authorization.consumed == true
        or authorization.token ~= params.action_token
    then
        fail("action_token is stale, consumed, or unavailable; action was not sent. Call computer_observe again")
    end
    authorization.consumed = true
    authorization.consumed_by = digest
    authorization.consumed_monotonic_ms = monotonic_ms(ctx)
    state.blocked_reason = nil
    if params.action == "click_locked" then
        state.target_lock = nil
    elseif params.action == "semantic_click" then
        state.semantic = nil
    end
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
            .. bounded_diagnostic(problem) .. ")")
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

local function semantic_state_for_storage(ctx, salt, semantic)
    if type(semantic) ~= "table" then
        return nil
    end
    local stored = {
        available = semantic.available == true,
        reason = bounded_diagnostic(semantic.reason),
        truncated = semantic.truncated == true,
        visited = semantic.visited,
        matched = semantic.matched,
        rejections = semantic.rejections,
        targets = {},
    }
    for _, target in ipairs(semantic.targets or {}) do
        stored.targets[#stored.targets + 1] = {
            id = target.id,
            fingerprint = target.fingerprint,
            role = target.role,
            name_sha256 = digest_fields(ctx, "semantic target", {
                salt,
                target.name or "",
            }),
            states = {
                enabled = target.states and target.states.enabled == true,
                sensitive = target.states and target.states.sensitive == true,
                showing = target.states and target.states.showing == true,
                visible = target.states and target.states.visible == true,
            },
            bounds = target.bounds,
            center = target.center,
            actions = target.actions,
            direct_activation = target.direct_activation == true,
        }
    end
    return stored
end

local function save_response(
    ctx, prior, signature, snapshot, params, grid, operation_id, call_id,
    image, image_hash, width, height, cursor_visible,
    inspection_image, inspection_geometry, before_image, before_hash, locked_target,
    semantic, semantic_target
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
    local target_lock
    if inspection_geometry then
        target_lock = target_lock_for_inspection(
            ctx, params, snapshot, screenshot_id, operation_id, image_hash,
            inspection_geometry, width, height
        )
    end
    local captured_at = monotonic_ms(ctx)
    local privacy_salt = prior and prior.privacy_salt
        or random_hex(ctx, 16, operation_id)
    local action_token = "action-" .. random_hex(ctx, 24, table.concat({
        operation_id,
        screenshot_id,
        image_hash,
        tostring(captured_at),
    }, ":"))
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
            token = action_token,
            issued_monotonic_ms = captured_at,
            consumed = false,
        },
        ledger = prior and prior.ledger or {},
        target_lock = target_lock,
        semantic = semantic_state_for_storage(ctx, privacy_salt, semantic),
    }

    local pixel_width, pixel_height, logical_width, logical_height = monitor_dimensions(snapshot.monitor)
    local attachment_width, attachment_height = model_image_dimensions(width, height)
    local force_attachment = action == "observe"
        or action == "inspect"
        or (prior and prior.grid ~= grid)
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
    local input_delivery = input_actions[action]
        and (semantic_target and semantic_target.delivery or "sent_unverified")
        or "not_applicable"
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
            input_delivery = input_delivery,
            visual_change = evidence,
            reason_code = "completed",
            finished_monotonic_ms = captured_at,
        })
    end
    ctx.state.set(STATE_KEY, json.encode(state))

    local content = {
        screenshot_id = screenshot_id,
        action_token = action_token,
        next_call = {
            tool = "computer",
            screenshot_id = screenshot_id,
            action_token = action_token,
            required = true,
        },
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
        monitor_selection = "To inspect another monitor, call observe with monitor set to its name or 'other'.",
        coordinates = "Use finite normalized coordinates from 0 through 1 with this screenshot_id.",
        screenshot_captured = true,
        screenshot_attached = not unchanged or force_attachment,
        visual_change = evidence,
        change_bounds = change_bounds,
        input_delivery = input_delivery,
        semantic_target = semantic_target and "verified" or (input_actions[action] and "unknown" or "not_applicable"),
        grid = grid,
        reason_code = "completed",
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
            ttl_seconds = TARGET_LOCK_TTL_SECONDS,
            expires_in_ms = math.max(
                0,
                target_lock.expires_monotonic_ms - monotonic_ms(ctx)
            ),
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
        content.trace = trace_finish(ctx, "completed")
        return json.encode({ content = json.encode(content) })
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
    content.trace = trace_finish(ctx, "completed")
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

local function input_observation_failure(
    ctx, state, action, operation_id, call_id, reason, _detail
)
    block_after_input(ctx, state, call_id, reason)
    return json.encode({
        content = json.encode({
            operation_id = operation_id,
            call_id = call_id,
            action = action,
            input_delivery = "sent_unverified",
            semantic_target = "unknown",
            screenshot_captured = false,
            observation = reason,
            reason_code = reason,
            retry_input = false,
            next_action = "observe",
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
            semantic_target = "unknown",
            screenshot_captured = false,
            observation = reason,
            reason_code = reason,
            retry_input = false,
            next_action = "observe",
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
        fail("computer input requires a bounded host call_id; action was not sent")
    end
    local prior
    if action == "observe" then
        local loaded, value = pcall(load_state, ctx)
        prior = loaded and value or nil
    else
        prior = load_state(ctx)
        if not prior or params.screenshot_id ~= prior.screenshot_id then
            fail("stale screenshot_id; call computer_observe and copy its fresh screenshot_id")
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
            fail("computer input authorization is blocked after "
                .. tostring(prior.blocked_reason) .. "; call computer_observe again")
        end
        if monotonic_ms(ctx) - prior.captured_monotonic_ms
            > SCREENSHOT_TTL_SECONDS * 1000
        then
            fail("screenshot_id expired; action was not sent. Call computer_observe again")
        end
        if input_actions[action] then
            local authorization = prior.authorization
            if type(authorization) ~= "table"
                or authorization.consumed == true
                or authorization.token ~= params.action_token
            then
                fail("action_token is stale, consumed, or unavailable; action was not sent. Call computer_observe again")
            end
        end
    end

    local signature
    local before
    local before_image
    local before_hash
    local before_width
    local before_height
    local locked_target
    local semantic
    local semantic_target
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
    elseif action == "wait" then
        trace_stage(ctx, "context_preflight")
        status(ctx, "checking screen context")
        signature, before = snapshot_with_race(ctx, action, prior.monitor.name)
        local signature_hash = digest_fields(
            ctx, action, { prior.privacy_salt, signature }
        )
        local current_context = context_fingerprint(
            ctx, action, prior.privacy_salt, signature, before
        )
        if signature_hash ~= prior.signature_sha256
            or current_context ~= prior.context_sha256
        then
            fail("screen context changed; action was not sent")
        end
        trace_stage(ctx, "wait")
        perform_action(params, ctx, signature, before)
        trace_stage(ctx, "stable_observation")
        status(ctx, "taking stable screenshot")
        signature, final_snapshot, final_image, final_hash,
            final_width, final_height, final_cursor_visible = stable_observation(
                ctx, action, prior.monitor.name, signature, action
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
            fail("screen context changed; action was not sent")
        end

        status(ctx, action_status[action])
        if action == "inspect" then
            trace_stage(ctx, "inspect")
            local inspected_ok
            inspected_ok, final_image, final_snapshot = pcall(
                inspect_image,
                ctx,
                before_image,
                before_width,
                before_height,
                params
            )
            if not inspected_ok then
                fail(final_image)
            end
            local inspection_image = final_image
            local inspection_geometry = final_snapshot
            final_snapshot = before
            final_image = before_image
            final_hash = before_hash
            final_width = before_width
            final_height = before_height
            final_cursor_visible = false
            trace_stage(ctx, "persist_response")
            return save_response(
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
                inspection_image,
                inspection_geometry,
                nil,
                nil,
                nil,
                nil,
                nil
            )
        elseif action == "semantic_find" then
            trace_stage(ctx, "semantic_discovery")
            semantic = semantic_discover(ctx, before, params)
            final_snapshot = before
            final_image = before_image
            final_hash = before_hash
            final_width = before_width
            final_height = before_height
            final_cursor_visible = false
        else
            trace_stage(ctx, "freshness_validation")
            status(ctx, "validating target freshness")
            local current_tiles = image_tiles(
                ctx, before_image, before_width, before_height, action
            )
            validate_coordinate_freshness(params, prior, current_tiles)
            if action == "click_locked" then
                locked_target = validate_target_lock(
                    ctx,
                    params,
                    prior,
                    before,
                    before_image,
                    before_width,
                    before_height
                )
            elseif action == "semantic_click" then
                local expected = stored_semantic_target(prior, params.semantic_id)
                if expected.direct_activation == true then
                    semantic_target = expected
                else
                    trace_stage(ctx, "semantic_resolution")
                    semantic_target = semantic_resolve(ctx, before, expected)
                end
            elseif action == "type" then
                trace_stage(ctx, "typing_focus_verification")
                semantic_focus_for_typing(ctx, before)
            end

            trace_stage(ctx, "reserve_input")
            reserve_action(ctx, prior, params, operation_id, call_id, digest)
            trace_stage(ctx, "input")
            local performed
            local perform_error
            if action == "semantic_click" and semantic_target.direct_activation == true then
                performed, perform_error = pcall(function()
                    semantic_target = semantic_activate(
                        ctx, before, semantic_target
                    )
                    perform_action(
                        params,
                        ctx,
                        signature,
                        before,
                        locked_target,
                        semantic_target
                    )
                end)
            else
                performed, perform_error = pcall(
                    perform_action,
                    params,
                    ctx,
                    signature,
                    before,
                    locked_target,
                    semantic_target
                )
            end
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
                if type(perform_error) == "table" and perform_error.marker == POST_INPUT_FAILURE then
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
        nil,
        nil,
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
        { "stale screenshot_id", "stale_screenshot" },
        { "screenshot_id expired", "observation_expired" },
        { "action_token is stale", "action_token_stale" },
        { "call_id was already used", "call_id_conflict" },
        { "authorization is blocked", "authorization_blocked" },
        { "screen context changed", "context_changed" },
        { "pixels around the intended target changed", "target_pixels_changed" },
        { "target token is stale", "target_lock_stale" },
        { "semantic_", "semantic_rejected" },
        { "AT-SPI", "semantic_unavailable" },
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
                trace = trace,
            }),
        })
    end
    ctx.ui.notify("computer - failed: " .. message, "error")
    fail(message)
end

local function execute_observe(params, ctx)
    params.action = "observe"
    return execute(params, ctx)
end

local function doctor_check(ok, reason_code, details)
    local check = {
        ok = ok == true,
        reason_code = reason_code,
    }
    if type(details) == "table" then
        for key, value in pairs(details) do
            check[key] = value
        end
    end
    return check
end

local function doctor_atspi_details(result)
    local details = {
        available = result.available == true,
        reason_code = bounded_diagnostic(result.reason_code),
        checks = {},
    }
    local allowed = {
        python = { "ok", "version" },
        gi = { "ok", "version" },
        atspi_bindings = { "ok", "api", "version" },
        session_bus = { "ok" },
        desktop = { "ok", "applications" },
        focused_application = { "ok" },
        window_calibration = { "ok" },
    }
    for name, fields in pairs(allowed) do
        local source = type(result.checks) == "table" and result.checks[name] or nil
        if type(source) == "table" then
            local target = {}
            for _, field in ipairs(fields) do
                local value = source[field]
                if field == "ok" and type(value) == "boolean" then
                    target.ok = value
                elseif field == "applications"
                    and finite(value) and value >= 0 and value <= 100000
                then
                    target.applications = math.floor(value)
                elseif type(value) == "string" then
                    target[field] = bounded_diagnostic(value)
                end
            end
            details.checks[name] = target
        end
    end
    return details
end

local function doctor_atspi(ctx, snapshot)
    local helper = semantic_helper_path(ctx)
    if not helper then
        return doctor_check(false, "semantic_helper_unavailable")
    end
    local request = {}
    if type(snapshot) == "table" then
        request.window = snapshot.window
    end
    local raw, kind = exec_result(ctx, "python3", { helper, "doctor" }, {
        stdin = json.encode(request),
        timeout_ms = SEMANTIC_TIMEOUT_MS,
        max_output_bytes = MAX_SEMANTIC_BYTES,
        env = instance_environment(),
    })
    if not raw then
        return doctor_check(
            false,
            kind == "spawn" and "python_unavailable" or "atspi_doctor_failed"
        )
    end
    local decoded, result = pcall(decode_json, raw, "invalid AT-SPI doctor output")
    if not decoded or type(result) ~= "table" or result.ok ~= true then
        return doctor_check(false, "atspi_doctor_output_invalid")
    end
    local details = doctor_atspi_details(result)
    return doctor_check(
        result.available == true,
        details.reason_code or (result.available == true and "ready" or "atspi_unavailable"),
        details
    )
end

local YDOTOOL_SOCKET_PROBE = [[
import errno
import socket
import sys

probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
probe.settimeout(0.5)
try:
    probe.connect(sys.argv[1])
except OSError as error:
    if error.errno in (errno.EACCES, errno.EPERM):
        raise SystemExit(3)
    if error.errno == errno.ENOENT:
        raise SystemExit(4)
    if error.errno == errno.ECONNREFUSED:
        raise SystemExit(5)
    if error.errno == errno.ETIMEDOUT:
        raise SystemExit(6)
    raise SystemExit(7)
finally:
    probe.close()
]]

local function doctor_hyprland_reason(problem)
    local message = tostring(problem)
    if message:find("multiple Hyprland instances", 1, true) then
        return "hyprland_instance_ambiguous"
    elseif message:find("no Hyprland instance", 1, true) then
        return "hyprland_instance_unavailable"
    elseif message:find("hyprctl is unavailable", 1, true) then
        return "hyprctl_missing_or_not_executable"
    end
    return "hyprland_discovery_failed"
end

local function doctor_capture_reason(problem)
    local message = tostring(problem)
    if message:find("grim is unavailable", 1, true) then
        return "grim_missing_or_not_executable"
    elseif message:find("geometry mismatch", 1, true)
        or message:find("invalid monitor geometry", 1, true)
    then
        return "screenshot_geometry_invalid"
    elseif message:find("screen context changed", 1, true) then
        return "screen_context_unstable"
    elseif message:find("hyprctl is unavailable", 1, true) then
        return "hyprctl_missing_or_not_executable"
    end
    return "stable_capture_failed"
end

local function doctor_socket_reason(kind, detail)
    if kind == nil then
        return "ready"
    elseif kind == "spawn" then
        return "python_unavailable"
    end
    local diagnostic = tostring(detail)
    if diagnostic:find("exit_code=3", 1, true) then
        return "ydotool_socket_permission_denied"
    elseif diagnostic:find("exit_code=4", 1, true) then
        return "ydotool_socket_missing"
    elseif diagnostic:find("exit_code=5", 1, true) then
        return "ydotool_daemon_unavailable"
    elseif diagnostic:find("exit_code=6", 1, true) then
        return "ydotool_socket_timeout"
    end
    return "ydotool_socket_unreachable"
end

local function doctor_socket_path()
    local configured = os.getenv("YDOTOOL_SOCKET")
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    local runtime = os.getenv("XDG_RUNTIME_DIR")
    if type(runtime) == "string" and runtime ~= "" then
        return runtime .. "/.ydotool_socket"
    end
    return nil
end

local function execute_doctor(params, ctx)
    if type(params) ~= "table" then
        fail("computer_doctor parameters must be an object")
    end
    for key in pairs(params) do
        if key ~= "monitor" and key ~= "trace" then
            fail("computer_doctor received an unsupported field")
        end
    end
    if params.monitor ~= nil
        and (type(params.monitor) ~= "string"
            or params.monitor == ""
            or #params.monitor > 256
            or params.monitor:find("\0", 1, true))
    then
        fail("monitor must be a bounded non-empty output name, 'focused', or 'other'")
    end
    if params.trace ~= nil and type(params.trace) ~= "boolean" then
        fail("trace must be boolean")
    end
    if type(ctx.exec) ~= "function"
        or type(ctx.codec) ~= "table"
        or type(ctx.codec.sha256) ~= "function"
    then
        fail("computer_doctor requires a newer Bone build with ctx.exec and ctx.codec support")
    end

    local operation_id = "computer-doctor-" .. random_hex(
        ctx, 12, tostring(monotonic_ms(ctx))
    )
    trace_begin(ctx, params.trace, operation_id, ctx.call_id, "doctor")
    local checks = {}
    checks.runtime = doctor_check(
        type(ctx.time) == "table"
            and type(ctx.time.monotonic_ms) == "function"
            and type(ctx.time.sleep_ms) == "function"
            and type(ctx.codec.random_hex) == "function"
            and type(ctx.codec.png_tiles) == "function"
            and type(ctx.codec.png_resize) == "function"
            and type(ctx.codec.png_region_sha256) == "function"
            and type(ctx.codec.png_diff) == "function",
        "native_runtime_primitives",
        {
            native_timer = type(ctx.time) == "table"
                and type(ctx.time.sleep_ms) == "function",
            secure_random = type(ctx.codec.random_hex) == "function",
            native_png_tiles = type(ctx.codec.png_tiles) == "function",
            native_png_resize = type(ctx.codec.png_resize) == "function",
            native_png_region = type(ctx.codec.png_region_sha256) == "function",
            native_png_diff = type(ctx.codec.png_diff) == "function",
        }
    )

    trace_stage(ctx, "hyprland_discovery")
    local discovered, signature = pcall(
        discover_signature, ctx, "computer_doctor", true
    )
    checks.hyprland_discovery = doctor_check(
        discovered,
        discovered and "ready" or doctor_hyprland_reason(signature)
    )

    local snapshot
    if discovered then
        trace_stage(ctx, "stable_capture")
        local captured
        local image
        local image_hash
        local width
        local height
        captured, signature, snapshot, image, image_hash, width, height = pcall(
            stable_observation,
            ctx,
            "computer_doctor",
            params.monitor,
            signature,
            "computer_doctor"
        )
        local capture_reason = captured and "ready"
            or doctor_capture_reason(signature)
        checks.hyprland_queries = doctor_check(
            captured,
            capture_reason
        )
        checks.screenshot = doctor_check(
            captured,
            capture_reason,
            captured and {
                width = width,
                height = height,
                bytes = #image,
                sha256 = image_hash,
            } or nil
        )
        if captured then
            trace_stage(ctx, "cursor_calibration")
            local cursor_ok, cursor = pcall(
                query_json,
                ctx,
                signature,
                { "-j", "cursorpos" },
                "computer_doctor",
                "invalid cursor position"
            )
            cursor_ok = cursor_ok and type(cursor) == "table"
                and finite(cursor.x) and finite(cursor.y)
            local monitor = snapshot.monitor
            local _, _, logical_width, logical_height =
                monitor_dimensions(monitor)
            checks.cursor_calibration = doctor_check(
                cursor_ok,
                cursor_ok and "ready" or "cursor_query_failed",
                cursor_ok and {
                    on_selected_monitor = cursor.x >= monitor.x
                        and cursor.x < monitor.x + logical_width
                        and cursor.y >= monitor.y
                        and cursor.y < monitor.y + logical_height,
                    transform = monitor.transform,
                    scale = monitor.scale,
                } or nil
            )
        else
            snapshot = nil
            checks.cursor_calibration = doctor_check(false, "stable_capture_unavailable")
        end
    else
        checks.hyprland_queries = doctor_check(false, "hyprland_discovery_unavailable")
        checks.screenshot = doctor_check(false, "hyprland_discovery_unavailable")
        checks.cursor_calibration = doctor_check(false, "hyprland_discovery_unavailable")
    end

    trace_stage(ctx, "dependency_checks")
    local _, magick_kind = exec_result(ctx, "magick", { "-version" }, {
        timeout_ms = EXEC_TIMEOUT_MS,
        max_output_bytes = 16 * 1024,
    })
    checks.image_magick = doctor_check(
        magick_kind == nil,
        magick_kind == nil and "ready"
            or (magick_kind == "spawn" and "imagemagick_missing" or "imagemagick_failed")
    )

    local _, ydotool_kind = exec_result(ctx, "ydotool", { "--help" }, {
        timeout_ms = EXEC_TIMEOUT_MS,
        max_output_bytes = 64 * 1024,
    })
    checks.ydotool_binary = doctor_check(
        ydotool_kind ~= "spawn",
        ydotool_kind == "spawn" and "ydotool_missing"
            or (ydotool_kind == nil and "ready" or "ydotool_help_failed")
    )

    local socket_path = doctor_socket_path()
    if type(socket_path) ~= "string"
        or socket_path == ""
        or #socket_path > 4096
        or socket_path:find("\0", 1, true)
    then
        checks.ydotool_socket = doctor_check(false, "ydotool_socket_path_unavailable")
    else
        local _, socket_kind, socket_detail = exec_result(
            ctx,
            "python3",
            { "-c", YDOTOOL_SOCKET_PROBE, socket_path },
            {
                timeout_ms = EXEC_TIMEOUT_MS,
                max_output_bytes = 4096,
            }
        )
        checks.ydotool_socket = doctor_check(
            socket_kind == nil,
            doctor_socket_reason(socket_kind, socket_detail)
        )
    end

    trace_stage(ctx, "atspi")
    checks.atspi = doctor_atspi(ctx, snapshot)

    local coordinate_ready = checks.hyprland_discovery.ok
        and checks.hyprland_queries.ok
        and checks.screenshot.ok
        and checks.cursor_calibration.ok
        and checks.ydotool_binary.ok
        and checks.ydotool_socket.ok
    local presentation_ready = checks.image_magick.ok
        or checks.runtime.native_png_resize == true
    local target_lock_ready = checks.image_magick.ok
        or checks.runtime.native_png_region == true
    local grid_ready = checks.image_magick.ok
    local full_ready = coordinate_ready and presentation_ready
    local reason_code = full_ready and "ready" or "computer_dependencies_unavailable"
    return json.encode({
        content = json.encode({
            operation_id = operation_id,
            ok = full_ready,
            coordinate_ready = coordinate_ready,
            presentation_ready = presentation_ready,
            target_lock_ready = target_lock_ready,
            grid_ready = grid_ready,
            semantic_ready = checks.atspi.ok,
            reason_code = reason_code,
            checks = checks,
            privacy = "No screenshot pixels, window titles, typed text, command arguments, or accessibility names are included.",
            trace = trace_finish(ctx, reason_code),
        }),
    })
end

bone.tool.register({
    name = "computer_observe",
    description = "Start or recover computer control. Capture a stable selected Hyprland monitor observation, always attach its PNG, and return separate screenshot_id and single-use action_token values. Call this before computer and again after any failed or cancelled computer operation.",
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
            trace = {
                type = "boolean",
                description = "Include a bounded privacy-safe stage/process timing trace.",
            },
        },
        additionalProperties = false,
    },
    execute = execute_observe,
})

bone.tool.register({
    name = "computer_doctor",
    description = "Run read-only, privacy-safe diagnostics for the Hyprland computer tool. Checks compositor selection, stable PNG capture and geometry, cursor calibration, ImageMagick, ydotool and its socket, Python/GI/AT-SPI, and Bone native timer/image primitives without emitting input.",
    safety = "read_only",
    display = {
        template = "checking computer control",
        show_result = true,
    },
    parameters = {
        type = "object",
        properties = {
            monitor = {
                type = "string",
                description = "Hyprland output name, 'focused' (default), or 'other' when exactly two monitors are enabled.",
            },
            trace = {
                type = "boolean",
                description = "Include a bounded privacy-safe stage/process timing trace.",
            },
        },
        additionalProperties = false,
    },
    execute = execute_doctor,
})

bone.tool.register({
    name = "computer",
    catalog_description = catalog_description,
    description = "Act on a stable observation returned by computer_observe or the immediately preceding successful computer call. Every input action requires both screenshot_id and its single-use action_token. Semantic controls are re-resolved by fingerprint and directly activated through AT-SPI when supported. Input is reserved before delivery, sent at most once, and never automatically retried.",
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
            action_token = {
                type = "string",
                minLength = 16,
                maxLength = 128,
                description = "Input actions only. Copy the single-use action_token from the immediately preceding successful observation.",
            },
            semantic_id = {
                type = "string",
                minLength = 7,
                maxLength = 160,
                pattern = "^atspi:[0-9]+([.][0-9]+)*$",
                description = "semantic_click only: exact target id returned by the preceding semantic_find.",
            },
            query = {
                type = "string",
                minLength = 1,
                maxLength = 160,
                description = "semantic_find only: bounded case-insensitive accessible-name query.",
            },
            roles = {
                type = "array",
                minItems = 1,
                maxItems = 16,
                uniqueItems = true,
                items = {
                    type = "string",
                    enum = {
                        "button", "check_box", "combo_box", "entry",
                        "password_text", "link", "list_item", "menu_item",
                        "page_tab", "radio_button", "slider", "spin_button",
                        "toggle_button", "tree_item",
                    },
                },
                description = "semantic_find only: include only these canonical roles.",
            },
            near = {
                type = "object",
                properties = {
                    x = { type = "number", minimum = 0, maximum = 1 },
                    y = { type = "number", minimum = 0, maximum = 1 },
                    radius = {
                        type = "number",
                        exclusiveMinimum = 0,
                        maximum = 1,
                    },
                },
                required = { "x", "y" },
                additionalProperties = false,
                description = "semantic_find only: rank/filter near a normalized monitor coordinate.",
            },
            max_results = {
                type = "integer",
                minimum = 1,
                maximum = MAX_SEMANTIC_TARGETS,
                description = "semantic_find only: maximum ranked targets to return.",
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
            trace = {
                type = "boolean",
                description = "Include a bounded privacy-safe stage/process timing trace.",
            },
        },
        required = { "action", "screenshot_id" },
        additionalProperties = false,
    },
    execute = execute,
})
