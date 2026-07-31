-- Run with: lua5.4 tests/computer_test.lua

local encoded = {}
local json_sequence = 0
cjson = {
    encode = function(value)
        json_sequence = json_sequence + 1
        local key = "json-" .. json_sequence
        encoded[key] = value
        return key
    end,
    decode = function(value)
        local decoded = encoded[value]
        assert(decoded ~= nil, "unknown mocked JSON: " .. tostring(value))
        return decoded
    end,
}

local function load_tool()
    local registered
    bone = {
        tool = {
            register = function(spec)
                registered = spec
            end,
        },
    }
    assert(loadfile("tools/computer.lua"))()
    return assert(registered)
end

local function check(condition, message)
    assert(condition, message)
end

local function contains(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

local function uint32(value)
    return string.char(
        (value >> 24) & 255,
        (value >> 16) & 255,
        (value >> 8) & 255,
        value & 255
    )
end

local function fixture_png(width, height, payload)
    local ihdr = uint32(width) .. uint32(height) .. string.char(8, 2, 0, 0, 0)
    return "\137PNG\r\n\26\n"
        .. uint32(#ihdr) .. "IHDR" .. ihdr .. uint32(0)
        .. uint32(#(payload or "pixels")) .. "IDAT" .. (payload or "pixels") .. uint32(0)
        .. uint32(0) .. "IEND" .. uint32(0)
end

local function png_dimensions(image)
    return image:byte(17) * 16777216 + image:byte(18) * 65536
            + image:byte(19) * 256 + image:byte(20),
        image:byte(21) * 16777216 + image:byte(22) * 65536
            + image:byte(23) * 256 + image:byte(24)
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

local function failed_query()
    local result = success("")
    result.exit_code = 1
    result.stderr = "query failed"
    return result
end

local function monitor(name, focused, awake, overrides)
    local value = {
        name = name,
        focused = focused == true,
        x = 0,
        y = 0,
        width = 200,
        height = 100,
        scale = 1,
        transform = 0,
        dpmsStatus = awake ~= false,
        activeWorkspace = { id = focused and 7 or 3 },
    }
    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function window(overrides)
    local value = {
        address = "0xabc",
        workspace = { id = 7 },
        monitor = 0,
        pid = 4242,
        title = "Fixture",
        class = "fixture-app",
        stableId = "fixture-window",
        at = { 10, 20 },
        size = { 120, 60 },
    }
    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function transformed_dimensions(output)
    local width, height = output.width, output.height
    if output.transform % 2 == 1 then
        width, height = height, width
    end
    return width, height
end

local function new_fixture(options)
    options = options or {}
    local fixture = {
        calls = {},
        instance_calls = 0,
        batch_calls = 0,
        panel_calls = 0,
        montage_calls = 0,
        grid_calls = 0,
        resize_calls = 0,
        native_resize_calls = 0,
        instances = options.instances or { "sig-a" },
        snapshots = options.snapshots or {
            { monitors = options.monitors or { monitor("DP-1", true, true) }, window = window() },
        },
        batch_results = options.batch_results or {},
    }

    local ctx = {
        codec = {
            base64_encode = function()
                return "base64-png"
            end,
            sha256 = function()
                return string.rep("a", 64)
            end,
        },
        time = {
            monotonic_ms = function()
                return 1000 + #fixture.calls
            end,
        },
        ui = {
            status = function() end,
            notify = function() end,
        },
        log = {
            info = function() end,
        },
    }

    if options.native_resize ~= false then
        ctx.codec.png_resize = function(_, maximum_width, maximum_height)
            fixture.native_resize_calls = fixture.native_resize_calls + 1
            local source = fixture.last_grim_png
            local width, height = png_dimensions(source)
            local scale = math.min(1, maximum_width / width, maximum_height / height)
            local target_width = math.max(1, math.floor(width * scale + 0.5))
            local target_height = math.max(1, math.floor(height * scale + 0.5))
            return {
                png = fixture_png(target_width, target_height, "native-resize"),
                width = target_width,
                height = target_height,
                resized = true,
            }
        end
    end

    function ctx.exec(program, args, exec_options)
        check(type(program) == "string" and program ~= "", "subprocess program must be direct")
        check(type(args) == "table", "subprocess arguments must use argv")
        check(type(exec_options) == "table", "subprocess options are required")
        check(type(exec_options.timeout_ms) == "number"
            and exec_options.timeout_ms > 0 and exec_options.timeout_ms <= 15000,
            "subprocess timeout must be bounded")
        check(exec_options.redact_args == true, "subprocess arguments must be redacted")
        check(type(exec_options.max_output_bytes) == "number"
            and exec_options.max_output_bytes > 0
            and exec_options.max_output_bytes <= 25 * 1024 * 1024,
            "subprocess output must be bounded")

        local call = { program = program, args = args, options = exec_options }
        fixture.calls[#fixture.calls + 1] = call

        if options.hook then
            local overridden = options.hook(fixture, call)
            if overridden ~= nil then
                return overridden
            end
        end

        if program == "hyprctl" and args[1] == "-j" and args[2] == "instances" then
            fixture.instance_calls = fixture.instance_calls + 1
            local signature = fixture.instances[fixture.instance_calls]
                or fixture.instances[#fixture.instances]
            return success(cjson.encode({ { signature = signature, wl_socket = "wayland-test" } }))
        end
        if program == "hyprctl" and args[1] == "--batch" then
            fixture.batch_calls = fixture.batch_calls + 1
            local overridden = fixture.batch_results[fixture.batch_calls]
            if overridden ~= nil then
                return overridden
            end
            local snapshot = fixture.snapshots[fixture.batch_calls]
                or fixture.snapshots[#fixture.snapshots]
            encoded["[]"] = snapshot.monitors
            encoded["{}"] = snapshot.window
            return success("[]\n{}")
        end
        if program == "grim" then
            check(args[#args] == "-", "grim must write PNG to stdout")
            local output_name
            for index, argument in ipairs(args) do
                if argument == "-o" then
                    output_name = args[index + 1]
                end
            end
            local snapshot = fixture.snapshots[math.min(fixture.batch_calls, #fixture.snapshots)]
            local selected
            for _, output in ipairs(snapshot.monitors) do
                if output.name == output_name then
                    selected = output
                end
            end
            check(selected ~= nil, "grim output must name an existing monitor")
            local width, height = transformed_dimensions(selected)
            fixture.last_grim_png = fixture_png(width, height, output_name)
            return success(fixture.last_grim_png)
        end
        if program == "magick" and args[1] == "montage" then
            fixture.montage_calls = fixture.montage_calls + 1
            local count = #fixture.snapshots[1].monitors
            local columns = math.max(1, math.ceil(math.sqrt(count)))
            local rows = math.ceil(count / columns)
            return success(fixture_png(columns * 640, rows * 400, "sheet"))
        end
        if program == "magick" then
            for index, argument in ipairs(args) do
                if argument == "-resize" then
                    fixture.resize_calls = fixture.resize_calls + 1
                    local width, height = args[index + 1]:match("^(%d+)x(%d+)!$")
                    return success(fixture_png(tonumber(width), tonumber(height), "resize"))
                end
            end
            if args[#args] == "miff:-" then
                fixture.panel_calls = fixture.panel_calls + 1
                return success("mock-miff-panel-" .. fixture.panel_calls)
            end
            fixture.grid_calls = fixture.grid_calls + 1
            return success(exec_options.stdin)
        end
        error("unexpected subprocess: " .. program)
    end

    fixture.ctx = ctx
    fixture.tool = load_tool()
    return fixture
end

local function invoke(fixture, params)
    local envelope = cjson.decode(fixture.tool.execute(params, fixture.ctx))
    return cjson.decode(envelope.content), envelope
end

local function expect_failure(fixture, params, needle)
    local ok, problem = pcall(fixture.tool.execute, params, fixture.ctx)
    check(not ok, "expected request to fail")
    check(contains(tostring(problem), needle), "expected failure containing: " .. needle)
end

local function count_calls(fixture, program)
    local count = 0
    for _, call in ipairs(fixture.calls) do
        if call.program == program then
            count = count + 1
        end
    end
    return count
end

-- Registration exposes only the observe-only public contract.
do
    local tool = load_tool()
    check(tool.name == "computer", "wrong tool name")
    check(tool.safety == "read_only", "tool must be read-only")
    check(tool.stateful == false and tool.state_key == nil, "tool must be stateless")
    check(tool.display.template == "{action}", "display must expose only action")
    check(tool.parameters.additionalProperties == false, "unknown properties must be rejected")
    check(#tool.parameters.required == 1 and tool.parameters.required[1] == "action",
        "only action is required")
    local properties = tool.parameters.properties
    local expected = { action = true, monitor = true, grid = true, trace = true }
    local count = 0
    for name in pairs(properties) do
        check(expected[name], "unexpected public property: " .. tostring(name))
        count = count + 1
    end
    check(count == 4, "expected exactly four public properties")
    check(#properties.action.enum == 1 and properties.action.enum[1] == "observe",
        "observe must be the only action")
end

-- Validation rejects old input/state fields before spawning anything.
do
    for _, params in ipairs({
        { action = "click" },
        { action = "type" },
        { action = "observe", x = 0.5 },
        { action = "observe", y = 0.5 },
        { action = "observe", text = "secret" },
        { action = "observe", target_label = "button" },
        { action = "observe", settle_ms = 100 },
        { action = "observe", authorization = "token" },
    }) do
        local fixture = new_fixture()
        expect_failure(fixture, params, params.action == "observe" and "irrelevant field" or "action must be observe")
        check(#fixture.calls == 0, "invalid request must not spawn subprocesses")
    end
    local fixture = new_fixture()
    expect_failure(fixture, {}, "action must be the exact string")
    expect_failure(fixture, { action = "observe", grid = "yes" }, "grid must be a boolean")
    expect_failure(fixture, { action = "observe", trace = "yes" }, "trace must be a boolean")
end

-- A concrete observation returns one ephemeral PNG and read-only shell guidance.
do
    local fixture = new_fixture()
    local content, envelope = invoke(fixture, { action = "observe" })
    check(content.mode == "monitor_observation" and content.actionable == true,
        "single monitor must be actionable")
    check(content.read_only == true and content.monitor.name == "DP-1", "wrong monitor response")
    check(content.screenshot_captured == true and content.screenshot_attached == true,
        "screenshot flags missing")
    check(envelope.ephemeral_images == true and #envelope.images == 1,
        "response must contain one ephemeral image")
    check(envelope.images[1].media_type == "image/png", "attachment must be PNG")
    check(contains(content.interaction_guidance, "never clicks, types, scrolls, focuses"),
        "read-only guidance missing")
    check(contains(content.interaction_guidance, "one approval-gated shell call"),
        "single-action shell guidance missing")
    check(contains(content.image_instruction, "exactly one atomic visual action"),
        "actionable screenshot rule missing")
    check(count_calls(fixture, "grim") == 1 and fixture.batch_calls == 2,
        "observation must capture between two snapshots")
end

-- Concrete selectors choose focused, other, and named outputs.
do
    local outputs = {
        monitor("HDMI-A-1", false, true, { x = -200 }),
        monitor("DP-1", true, true),
    }
    for selector, expected in pairs({ focused = "DP-1", other = "HDMI-A-1", ["HDMI-A-1"] = "HDMI-A-1" }) do
        local fixture = new_fixture({ monitors = outputs })
        local content = invoke(fixture, { action = "observe", monitor = selector })
        check(content.monitor.name == expected, "selector chose wrong monitor")
    end
end

-- Discovery sorts all outputs, captures only awake ones, and labels sleeping placeholders.
do
    local outputs = {
        monitor("HDMI-A-1", false, false, { x = 200 }),
        monitor("DP-1", true, true),
    }
    local fixture = new_fixture({ monitors = outputs })
    local content, envelope = invoke(fixture, { action = "observe", grid = true })
    check(content.mode == "monitor_discovery" and content.actionable == false,
        "multi-monitor omission must return discovery")
    check(content.available_monitors[1] == "DP-1"
        and content.available_monitors[2] == "HDMI-A-1", "outputs must be sorted")
    check(content.monitors[1].name == "DP-1" and content.monitors[2].power == "asleep",
        "discovery metadata is incomplete")
    check(content.contact_sheet_size.width == 1280 and content.contact_sheet_size.height == 400,
        "two-monitor contact sheet must be 1280x400")
    check(content.grid == false and content.grid_requested == true, "discovery grid handling is wrong")
    check(contains(content.monitor_selection, "non-actionable"), "selection warning missing")
    check(envelope.ephemeral_images == true and #envelope.images == 1,
        "discovery must return one ephemeral image")
    check(count_calls(fixture, "grim") == 1, "only the awake output may be captured")
    check(fixture.panel_calls == 2 and fixture.montage_calls == 1,
        "each output needs a panel and one montage")
    local saw_sleeping_placeholder = false
    for _, call in ipairs(fixture.calls) do
        if call.program == "magick" then
            for _, argument in ipairs(call.args) do
                saw_sleeping_placeholder = saw_sleeping_placeholder
                    or argument == "DISPLAY ASLEEP\nNO SCREENSHOT"
            end
        end
    end
    check(saw_sleeping_placeholder, "sleeping output placeholder was not rendered")
end

-- Explicitly selecting a sleeping output fails before capture.
do
    local fixture = new_fixture({ monitors = { monitor("DP-1", true, false) } })
    expect_failure(fixture, { action = "observe", monitor = "DP-1" }, "is asleep (DPMS off)")
    check(count_calls(fixture, "grim") == 0, "sleeping output must not be captured")
end

-- Grid and trace are optional and preserve a single attachment.
do
    local fixture = new_fixture()
    local content, envelope = invoke(fixture, { action = "observe", grid = true, trace = true })
    check(content.grid == true and fixture.grid_calls == 1, "grid was not rendered")
    check(type(content.trace) == "table" and content.trace.enabled == true,
        "trace was not returned")
    check(content.trace.action == "observe" and content.trace.subprocess_count == #fixture.calls,
        "trace subprocess count is wrong")
    check(content.trace.subprocesses[1].args == nil
        and content.trace.subprocesses[1].stdout == nil, "trace must not expose subprocess data")
    check(#envelope.images == 1, "grid response must have one attachment")
end

-- Metadata changes between pre/post snapshots invalidate the observation.
do
    local fixture = new_fixture({
        snapshots = {
            { monitors = { monitor("DP-1", true, true) }, window = window() },
            { monitors = { monitor("DP-1", true, true) }, window = window({ title = "Changed" }) },
        },
    })
    expect_failure(fixture, { action = "observe" }, "screen context changed during capture")
end

-- Native and ImageMagick model-image resize paths are both bounded and in-memory.
do
    local large = monitor("DP-1", true, true, { width = 2560, height = 1440 })
    local native = new_fixture({ monitors = { large } })
    local native_content = invoke(native, { action = "observe" })
    check(native.native_resize_calls == 1 and native.resize_calls == 0,
        "native resize path was not used")
    check(native_content.attachment_size.width == 1920
        and native_content.attachment_size.height == 1080, "native resize geometry is wrong")

    local fallback = new_fixture({ monitors = { large }, native_resize = false })
    local fallback_content = invoke(fallback, { action = "observe" })
    check(fallback.native_resize_calls == 0 and fallback.resize_calls == 1,
        "ImageMagick resize fallback was not used")
    check(fallback_content.attachment_size.width == 1920
        and fallback_content.attachment_size.height == 1080, "fallback resize geometry is wrong")
end

-- A failed spawned query retries only when discovery reports a changed instance.
do
    local fixture = new_fixture({
        instances = { "sig-old", "sig-new", "sig-new" },
        batch_results = { failed_query() },
    })
    local content = invoke(fixture, { action = "observe" })
    check(content.ok == true and fixture.instance_calls == 3 and fixture.batch_calls == 3,
        "changed instance should retry once and confirm")
    check(fixture.calls[2].options.env.HYPRLAND_INSTANCE_SIGNATURE == "sig-old"
        and fixture.calls[4].options.env.HYPRLAND_INSTANCE_SIGNATURE == "sig-new",
        "retry queries used the wrong Hyprland instances")
end

-- Unchanged instance, unspawned hyprctl, and a second change never retry input/query blindly.
do
    local unchanged = new_fixture({
        instances = { "sig-old", "sig-old" },
        batch_results = { failed_query() },
    })
    expect_failure(unchanged, { action = "observe" }, "instance did not change")
    check(unchanged.instance_calls == 2 and unchanged.batch_calls == 1,
        "unchanged instance must not retry the query")

    local unspawned_result = success("")
    unspawned_result.spawned = false
    local unspawned = new_fixture({ batch_results = { unspawned_result } })
    expect_failure(unspawned, { action = "observe" }, "hyprctl is unavailable")
    check(unspawned.instance_calls == 1 and unspawned.batch_calls == 1,
        "unspawned hyprctl must not rediscover or retry")

    local changed_twice = new_fixture({
        instances = { "sig-old", "sig-new", "sig-third" },
        batch_results = { failed_query() },
    })
    expect_failure(changed_twice, { action = "observe" }, "instance changed again")
    check(changed_twice.instance_calls == 3 and changed_twice.batch_calls == 2,
        "second instance change must reject the observation")
end

print("computer tests passed")
