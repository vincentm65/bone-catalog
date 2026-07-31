local catalog_description = "Observe Hyprland monitors through stable ephemeral screenshots and labeled discovery contact sheets."

local EXEC_TIMEOUT_MS = 4000
local CAPTURE_TIMEOUT_MS = 15000
local MAX_JSON_BYTES = 2 * 1024 * 1024
local MAX_IMAGE_BYTES = 25 * 1024 * 1024
local MODEL_IMAGE_MAX_WIDTH = 1920
local MODEL_IMAGE_MAX_HEIGHT = 1080
local CONTACT_PANEL_WIDTH = 640
local CONTACT_PANEL_HEIGHT = 400
local MAX_DIAGNOSTIC_BYTES = 1024
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

local function trace_begin(ctx, enabled, action)
    ctx.__computer_trace_finalized = false
    ctx.__computer_trace = {
        enabled = enabled == true,
        version = TRACE_VERSION,
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

local function validate_monitor_record(monitor, action)
    if type(monitor) ~= "table"
        or type(monitor.name) ~= "string"
        or monitor.name == ""
        or #monitor.name > 256
        or monitor.name:find("\0", 1, true)
    then
        fail(action .. ": invalid monitor identity")
    end
    if monitor.dpmsStatus ~= nil and type(monitor.dpmsStatus) ~= "boolean" then
        fail(action .. ": invalid monitor power state")
    end
    for _, key in ipairs({ "x", "y", "width", "height", "transform" }) do
        if not finite(monitor[key]) or monitor[key] % 1 ~= 0 then
            fail(action .. ": invalid monitor geometry")
        end
    end
    if monitor.width <= 0
        or monitor.height <= 0
        or monitor.transform < 0
        or monitor.transform > 7
        or not finite(monitor.scale)
        or monitor.scale <= 0
    then
        fail(action .. ": invalid monitor geometry")
    end
    local workspace
    if monitor.activeWorkspace ~= nil then
        workspace = type(monitor.activeWorkspace) == "table"
            and monitor.activeWorkspace.id
            or nil
        if not finite(workspace) or workspace % 1 ~= 0 then
            fail(action .. ": invalid monitor workspace")
        end
    end
    return {
        name = monitor.name,
        x = monitor.x,
        y = monitor.y,
        width = monitor.width,
        height = monitor.height,
        scale = monitor.scale,
        transform = monitor.transform,
        workspace = workspace,
        focused = monitor.focused == true,
        dpms = monitor.dpmsStatus ~= false,
    }
end

local function validate_monitor(monitors, action, requested)
    local focused
    local inventory = {}
    local by_name = {}
    for _, raw_monitor in ipairs(monitors) do
        local monitor = validate_monitor_record(raw_monitor, action)
        if by_name[monitor.name] then
            fail(action .. ": duplicate monitor name was reported")
        end
        by_name[monitor.name] = monitor
        inventory[#inventory + 1] = monitor
        if monitor.focused then
            if focused then
                fail(action .. ": multiple focused monitors were reported")
            end
            focused = monitor
        end
    end
    if #inventory == 0 then
        fail(action .. ": no monitors were reported")
    end
    table.sort(inventory, function(left, right)
        return left.name < right.name
    end)
    local available = {}
    for index, monitor in ipairs(inventory) do
        available[index] = monitor.name
    end
    local available_text = table.concat(available, ", ")

    local selected
    if requested == nil then
        if #inventory == 1 then
            selected = inventory[1]
        else
            return nil, available, inventory
        end
    elseif requested == "focused" then
        selected = focused
    elseif requested == "other" then
        if #inventory ~= 2 or not focused then
            fail(action .. ": 'other' requires exactly two monitors; available monitors: " .. available_text)
        end
        selected = inventory[1].name == focused.name and inventory[2] or inventory[1]
    elseif type(requested) ~= "string" or requested == "" then
        fail("monitor must be a non-empty output name, 'focused', or 'other'")
    else
        selected = by_name[requested]
    end

    if not selected then
        if requested == nil or requested == "focused" then
            fail(action .. ": no focused monitor was reported")
        end
        fail(action .. ": monitor was not found; available monitors: " .. available_text)
    end
    if not selected.dpms then
        fail(
            action .. ": selected monitor " .. selected.name
                .. " is asleep (DPMS off); wake the display before calling "
                .. "computer with action='observe' again. Do not retry while the display is asleep"
        )
    end
    return selected, available, inventory
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
    local monitor, available_monitors, monitors = validate_monitor(
        monitors, action, requested_monitor
    )
    return {
        monitor = monitor,
        monitors = monitors,
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
    if kind == "spawn" then
        fail(action .. ": hyprctl is unavailable; no observation was produced")
    end
    if kind ~= "exit" then
        fail(action .. ": Hyprland query failed; no observation was produced")
    end

    local replacement = discover_signature(ctx, action, true)
    if replacement == signature then
        cached_signature = nil
        fail(action .. ": Hyprland query failed and the instance did not change; no observation was produced")
    end

    local retry, retry_kind = snapshot_once(ctx, replacement, action, requested_monitor)
    if retry then
        local confirmed = discover_signature(ctx, action, true)
        if confirmed ~= replacement then
            cached_signature = nil
            fail(action .. ": Hyprland instance changed again; no observation was produced")
        end
        cached_signature = replacement
        return replacement, retry
    end

    if retry_kind == "exit" then
        local latest = discover_signature(ctx, action, true)
        if latest ~= replacement then
            cached_signature = nil
            fail(action .. ": Hyprland instance changed again; no observation was produced")
        end
    end
    cached_signature = nil
    if retry_kind == "spawn" then
        fail(action .. ": hyprctl became unavailable after the instance changed; no observation was produced")
    end
    fail(action .. ": Hyprland query failed after the instance changed; no observation was produced")
end

local function same_monitor(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return left == right
    end
    for _, key in ipairs({
        "name", "x", "y", "width", "height", "scale", "transform",
        "workspace", "focused", "dpms",
    }) do
        if left[key] ~= right[key] then
            return false
        end
    end
    return true
end

local function same_snapshot(left, right)
    if type(left) ~= "table" or type(right) ~= "table"
        or not same_monitor(left.monitor, right.monitor)
        or #left.monitors ~= #right.monitors
    then
        return false
    end
    for index, monitor in ipairs(left.monitors) do
        if not same_monitor(monitor, right.monitors[index]) then
            return false
        end
    end
    for _, key in ipairs({
        "address", "workspace", "monitor", "pid", "title", "class",
        "stable_id", "x", "y", "width", "height",
    }) do
        if left.window[key] ~= right.window[key] then
            return false
        end
    end
    return true
end

local allowed_fields = {
    action = true,
    monitor = true,
    grid = true,
    trace = true,
}

local function validate_request(params)
    if type(params) ~= "table" or type(params.action) ~= "string" then
        fail("action must be the exact string 'observe'")
    end
    if params.action ~= "observe" then
        fail("action must be observe")
    end
    for key in pairs(params) do
        if type(key) ~= "string" or not allowed_fields[key] then
            fail("irrelevant field for observe: " .. tostring(key))
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
    if params.grid ~= nil and type(params.grid) ~= "boolean" then
        fail("grid must be a boolean")
    end
    if params.trace ~= nil and type(params.trace) ~= "boolean" then
        fail("trace must be a boolean")
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

local function accuracy_log(ctx, message)
    if os.getenv("BONE_IMAGE_DEBUG") == "1" then
        ctx.log.info("computer accuracy: " .. message)
    end
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

local function ruler_position(index, divisions, extent)
    return math.floor(index * (extent - 1) / divisions + 0.5)
end

local function ruler_guides(width, height)
    local lines = {}
    for index = 1, 3 do
        local x = ruler_position(index, 4, width)
        local y = ruler_position(index, 4, height)
        lines[#lines + 1] = string.format("line %d,0 %d,%d", x, x, height - 1)
        lines[#lines + 1] = string.format("line 0,%d %d,%d", y, width - 1, y)
    end
    return table.concat(lines, " ")
end

local function ruler_ticks(width, height, point_size)
    local lines = {}
    local minor_length = math.max(4, math.floor(point_size * 0.4))
    local major_length = math.max(minor_length + 2, math.floor(point_size * 0.75))
    for index = 0, 20 do
        local length = index % 5 == 0 and major_length or minor_length
        local x = ruler_position(index, 20, width)
        local y = ruler_position(index, 20, height)
        lines[#lines + 1] = string.format(
            "line %d,0 %d,%d", x, x, math.min(length, height - 1)
        )
        lines[#lines + 1] = string.format(
            "line 0,%d %d,%d", y, math.min(length, width - 1), y
        )
    end
    return table.concat(lines, " "), major_length
end

local function ruler_labels(width, height, point_size, tick_length)
    local labels = {}
    local top_y = math.min(height - 1, point_size + 2)
    local left_x = math.min(width - 1, tick_length + 3)
    for index = 0, 4 do
        local value = tostring(index * 250)
        local x = ruler_position(index, 4, width)
        local y = ruler_position(index, 4, height)
        local label_width = math.ceil(#value * point_size * 0.62)
        local label_x = math.max(0, math.min(
            x - math.floor(label_width / 2),
            math.max(0, width - label_width - 2)
        ))
        local label_y = math.min(
            math.max(0, height - 3),
            math.max(point_size, y + math.floor(point_size * 0.35))
        )
        labels[#labels + 1] = string.format("text %d,%d '%s'", label_x, top_y, value)
        if index > 0 then
            labels[#labels + 1] = string.format("text %d,%d '%s'", left_x, label_y, value)
        end
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

local function capture(ctx, signature, monitor, action)
    local _, _, logical_width, logical_height = monitor_dimensions(monitor)
    local grim_args = {
        "-t", "png",
        "-s", tostring(monitor.scale),
        "-o", monitor.name,
        "-",
    }

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
            fail(action .. ": screenshot capture was cancelled; no observation was produced (" .. detail .. ")")
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

    local trace = ctx.__computer_trace
    if type(trace) == "table" then
        trace.captures = type(trace.captures) == "table" and trace.captures or {}
        trace.captures[#trace.captures + 1] = {
            monitor = monitor.name,
            width = width,
            height = height,
            bytes = #image,
            sha256 = image_sha256(ctx, image, action),
        }
    end
    return image, width, height
end

local function render_grid(ctx, image, width, height, action)
    local point_size = math.min(24, math.max(12, math.floor(math.min(width, height) / 80)))
    local ticks, major_tick_length = ruler_ticks(width, height, point_size)
    local rendered, render_kind, render_detail = exec_result(ctx, "magick", {
        "png:-",
        "-stroke", "rgba(255,255,255,0.16)", "-strokewidth", "1", "-fill", "none",
        "-draw", ruler_guides(width, height),
        "-stroke", "rgba(0,0,0,0.72)", "-strokewidth", "3", "-draw", ticks,
        "-stroke", "rgba(255,255,255,0.88)", "-strokewidth", "1", "-draw", ticks,
        "-font", "DejaVu-Sans", "-pointsize", tostring(point_size),
        "-stroke", "rgba(0,0,0,0.85)", "-strokewidth", "1",
        "-fill", "rgba(255,255,255,0.92)",
        "-draw", ruler_labels(width, height, point_size, major_tick_length),
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

local function stable_observation(ctx, action, requested_monitor)
    local signature, before = snapshot_with_race(ctx, action, requested_monitor)
    local captures
    local image
    local width
    local height

    if before.monitor then
        image, width, height = capture(ctx, signature, before.monitor, action)
    else
        captures = {}
        for _, monitor in ipairs(before.monitors) do
            if monitor.dpms then
                local monitor_image, monitor_width, monitor_height = capture(
                    ctx, signature, monitor, action
                )
                captures[monitor.name] = {
                    image = monitor_image,
                    width = monitor_width,
                    height = monitor_height,
                }
            end
        end
    end

    local after, kind = snapshot_once(
        ctx,
        signature,
        action,
        before.monitor and before.monitor.name or nil
    )
    if not after then
        fail(action .. ": stable observation metadata failed after capture ("
            .. tostring(kind) .. "); no observation was produced")
    end
    if not same_snapshot(before, after) then
        fail(action .. ": screen context changed during capture; no observation was produced")
    end
    return signature, after, image, width, height, captures
end

local function contact_label(monitor)
    local name = monitor.name:gsub("[%z\1-\31\127]", "?"):gsub("%%", "%%%%")
    local workspace = monitor.workspace == nil and "none" or tostring(monitor.workspace)
    return string.format(
        "%s | focused: %s | workspace: %s | power: %s",
        name,
        monitor.focused and "yes" or "no",
        workspace,
        monitor.dpms and "on" or "asleep"
    )
end

local function contact_panel(ctx, monitor, capture_record, action)
    local body_height = CONTACT_PANEL_HEIGHT - 60
    local caption_args = {
        "(",
        "-background", "#1f2937",
        "-fill", "white",
        "-font", "DejaVu-Sans",
        "-pointsize", "18",
        "-gravity", "center",
        "-size", string.format("%dx%d", CONTACT_PANEL_WIDTH, 60),
        "caption:" .. contact_label(monitor),
        ")",
        "-append",
        "miff:-",
    }
    local args
    local options = {
        timeout_ms = CAPTURE_TIMEOUT_MS,
        max_output_bytes = MAX_IMAGE_BYTES,
    }
    if capture_record then
        args = {
            "png:-",
            "-thumbnail", string.format(
                "%dx%d>", CONTACT_PANEL_WIDTH - 24, body_height - 24
            ),
            "-background", "#111827",
            "-gravity", "center",
            "-extent", string.format("%dx%d", CONTACT_PANEL_WIDTH, body_height),
        }
        options.stdin = capture_record.image
    else
        args = {
            "-size", string.format("%dx%d", CONTACT_PANEL_WIDTH, body_height),
            "xc:#111827",
            "-fill", "#9ca3af",
            "-font", "DejaVu-Sans",
            "-pointsize", "24",
            "-gravity", "center",
            "-annotate", "+0+0", "DISPLAY ASLEEP\nNO SCREENSHOT",
        }
    end
    for _, argument in ipairs(caption_args) do
        args[#args + 1] = argument
    end

    local panel, kind, detail = exec_result(ctx, "magick", args, options)
    if not panel then
        if kind == "spawn" then
            fail(action .. ": ImageMagick is unavailable; install ImageMagick ("
                .. detail .. ")")
        end
        fail(action .. ": monitor contact panel rendering failed (" .. detail .. ")")
    end
    if panel == "" then
        fail(action .. ": monitor contact panel rendering returned no image")
    end
    return panel
end

local function contact_sheet(ctx, snapshot, captures, action)
    local panels = {}
    local stream_bytes = 0
    for _, monitor in ipairs(snapshot.monitors) do
        local panel = contact_panel(ctx, monitor, captures[monitor.name], action)
        stream_bytes = stream_bytes + #panel
        if stream_bytes > MAX_IMAGE_BYTES then
            fail(action .. ": monitor contact sheet exceeded the in-memory image limit")
        end
        panels[#panels + 1] = panel
    end

    local columns = math.max(1, math.ceil(math.sqrt(#panels)))
    local rows = math.ceil(#panels / columns)
    local sheet, kind, detail = exec_result(ctx, "magick", {
        "montage",
        "miff:-",
        "-tile", string.format("%dx%d", columns, rows),
        "-geometry", string.format(
            "%dx%d+0+0", CONTACT_PANEL_WIDTH, CONTACT_PANEL_HEIGHT
        ),
        "-background", "#111827",
        "png:-",
    }, {
        stdin = table.concat(panels),
        timeout_ms = CAPTURE_TIMEOUT_MS,
        max_output_bytes = MAX_IMAGE_BYTES,
    })
    if not sheet then
        if kind == "spawn" then
            fail(action .. ": ImageMagick is unavailable; install ImageMagick ("
                .. detail .. ")")
        end
        fail(action .. ": monitor contact sheet rendering failed (" .. detail .. ")")
    end

    local width
    local height
    sheet, width, height = validate_png(sheet, action)
    local expected_width = columns * CONTACT_PANEL_WIDTH
    local expected_height = rows * CONTACT_PANEL_HEIGHT
    if width ~= expected_width or height ~= expected_height then
        fail(string.format(
            "%s: monitor contact sheet geometry mismatch; expected %dx%d but ImageMagick returned %dx%d",
            action, expected_width, expected_height, width, height
        ))
    end
    return sheet, width, height
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

local READ_ONLY_GUIDANCE = "computer is read-only: it never clicks, types, scrolls, focuses windows, or persists images. Interaction uses one approval-gated shell call for one atomic visual action based only on the newest actionable screenshot; prefer hyprctl for compositor/window operations, ydotool for ordinary pointer movement/click/scroll, and wtype for keys/text. Never chain visual actions or reuse coordinates. Wait briefly, observe again, and treat the next screenshot as confirmation."

local function monitor_report(monitor, screenshot_width, screenshot_height)
    local _, _, logical_width, logical_height = monitor_dimensions(monitor)
    local report = {
        name = monitor.name,
        focused = monitor.focused,
        workspace = monitor.workspace,
        power = monitor.dpms and "on" or "asleep",
        scale = monitor.scale,
        transform = monitor.transform,
        mode_size = {
            width = monitor.width,
            height = monitor.height,
        },
        global_logical_origin = {
            x = monitor.x,
            y = monitor.y,
        },
        global_logical_bounds = {
            left = monitor.x,
            top = monitor.y,
            right_exclusive = monitor.x + logical_width,
            bottom_exclusive = monitor.y + logical_height,
        },
        logical_size = {
            width = logical_width,
            height = logical_height,
        },
    }
    if screenshot_width and screenshot_height then
        report.full_resolution_screenshot_size = {
            width = screenshot_width,
            height = screenshot_height,
        }
    end
    return report
end

local function attachment(ctx, image, width, height, action)
    local attached_image
    local attached_width
    local attached_height
    attached_image, attached_width, attached_height = model_image(
        ctx, image, width, height, action
    )
    local hash = image_sha256(ctx, attached_image, action)
    local ok, encoded = pcall(ctx.codec.base64_encode, attached_image)
    if not ok or type(encoded) ~= "string" or encoded == "" then
        fail(action .. ": screenshot encoding failed")
    end
    image_debug(ctx, attached_image, encoded, hash)
    return {
        media_type = "image/png",
        data = encoded,
        width = attached_width,
        height = attached_height,
        sha256 = hash,
    }, attached_width, attached_height
end

local function concrete_response(ctx, snapshot, params, image, width, height)
    local action = params.action
    local grid = params.grid == true
    local presentation = image
    if grid then
        trace_stage(ctx, "grid")
        presentation = render_grid(ctx, image, width, height, action)
    end

    trace_stage(ctx, "attachment")
    local attached, attachment_width, attachment_height = attachment(
        ctx, presentation, width, height, action
    )
    local monitor = monitor_report(snapshot.monitor, width, height)
    local origin = monitor.global_logical_origin
    local logical = monitor.logical_size
    local content = {
        ok = true,
        action = action,
        mode = "monitor_observation",
        actionable = true,
        read_only = true,
        reason_code = "completed",
        monitor = monitor,
        available_monitors = snapshot.available_monitors,
        attachment_size = {
            width = attachment_width,
            height = attachment_height,
        },
        grid = grid,
        coordinates = grid
            and "Choose normalized coordinates from the attached screenshot. Ruler labels are 0-1000 presentation values; divide by 1000."
            or "Choose normalized coordinates from the attached screenshot in the range 0 through 1.",
        shell_coordinates = string.format(
            "Map normalized (nx, ny) to Hyprland logical coordinates with X=%d+round(nx*(%d-1)) and Y=%d+round(ny*(%d-1)).",
            origin.x, logical.width, origin.y, logical.height
        ),
        interaction_guidance = READ_ONLY_GUIDANCE,
        image_instruction = "This is the newest actionable screenshot. It permits exactly one atomic visual action through approval-gated shell, followed by a brief wait and a new observation.",
        screenshot_captured = true,
        screenshot_attached = true,
        ephemeral_images = true,
    }
    content.trace = trace_finish(ctx, "completed")
    return json.encode({
        content = json.encode(content),
        images = { attached },
        ephemeral_images = true,
    })
end

local function discovery_response(ctx, snapshot, params, captures)
    trace_stage(ctx, "contact_sheet")
    local image, width, height = contact_sheet(
        ctx, snapshot, captures, params.action
    )
    trace_stage(ctx, "attachment")
    local attached, attachment_width, attachment_height = attachment(
        ctx, image, width, height, params.action
    )
    local monitors = {}
    for index, monitor in ipairs(snapshot.monitors) do
        monitors[index] = monitor_report(monitor)
    end
    local content = {
        ok = true,
        action = params.action,
        mode = "monitor_discovery",
        actionable = false,
        read_only = true,
        reason_code = "monitor_selection_required",
        available_monitors = snapshot.available_monitors,
        monitors = monitors,
        contact_sheet_size = {
            width = width,
            height = height,
        },
        attachment_size = {
            width = attachment_width,
            height = attachment_height,
        },
        grid = false,
        grid_requested = params.grid == true,
        monitor_selection = "This contact sheet is non-actionable. Observe again with monitor set to a concrete output name before using coordinates.",
        interaction_guidance = READ_ONLY_GUIDANCE,
        image_instruction = "Use labels only to choose a concrete output. Do not derive or use coordinates from this contact sheet.",
        screenshot_captured = true,
        screenshot_attached = true,
        ephemeral_images = true,
    }
    content.trace = trace_finish(ctx, "monitor_selection_required")
    return json.encode({
        content = json.encode(content),
        images = { attached },
        ephemeral_images = true,
    })
end

local function status(ctx, message)
    if type(ctx.ui) == "table" and type(ctx.ui.status) == "function" then
        ctx.ui.status("computer - " .. message)
    end
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
    trace_begin(ctx, params.trace, params.action)
    trace_stage(ctx, "stable_observation")
    status(ctx, "taking stable screenshot")

    local _, snapshot, image, width, height, captures = stable_observation(
        ctx, params.action, params.monitor
    )
    status(ctx, "screenshot ready")
    if snapshot.monitor then
        return concrete_response(ctx, snapshot, params, image, width, height)
    end
    return discovery_response(ctx, snapshot, params, captures)
end

local function failure_reason_code(message)
    local rules = {
        { "screen context changed", "context_changed" },
        { "DPMS off", "output_dpms_off" },
        { "Hyprland", "hyprland_unavailable" },
        { "hyprctl", "hyprctl_unavailable" },
        { "grim", "screenshot_unavailable" },
        { "ImageMagick", "imagemagick_unavailable" },
        { "screenshot PNG", "invalid_screenshot" },
        { "screenshot geometry mismatch", "geometry_mismatch" },
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
    ctx.__computer_trace_finalized = nil
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
                read_only = true,
                reason_code = reason_code,
                interaction_guidance = READ_ONLY_GUIDANCE,
                trace = trace,
            }),
        })
    end
    if type(ctx.ui) == "table" and type(ctx.ui.notify) == "function" then
        ctx.ui.notify("computer - failed: " .. message, "error")
    end
    fail(message)
end

bone.tool.register({
    name = "computer",
    catalog_description = catalog_description,
    description = "Observe-only Hyprland screenshots with stable metadata checks and labeled multi-monitor discovery. The tool is read-only and never clicks, types, scrolls, focuses, or persists images. Use one approval-gated shell action based on the newest concrete screenshot, wait briefly, then observe again.",
    safety = "read_only",
    stateful = false,
    display = {
        template = "{action}",
        value_labels = {
            action = {
                observe = "observing screen",
            },
        },
        show_result = false,
    },
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                description = "Observe Hyprland monitors. This is the only supported action.",
                enum = { "observe" },
            },
            monitor = {
                type = "string",
                description = "Hyprland output name, 'focused', or 'other' when exactly two monitors are enabled. If omitted with multiple monitors, returns a non-actionable labeled contact sheet; observe a concrete output before using coordinates.",
            },
            grid = {
                type = "boolean",
                description = "Presentation only: overlay sparse edge rulers labeled 0–1000 with subtle quarter guides. Convert a displayed ruler value with normalized = ruler_value / 1000.",
            },
            trace = {
                type = "boolean",
                description = "Include a bounded privacy-safe stage/process timing trace.",
            },
        },
        required = { "action" },
        additionalProperties = false,
    },
    execute = execute,
})
