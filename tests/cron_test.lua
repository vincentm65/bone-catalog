-- Run with: lua tests/cron_test.lua
local registered
bone = { tool = { register = function(spec) registered = spec end } }
assert(loadfile("tools/cron.lua"))()
assert(registered, "cron tool was not registered")
assert(registered.safety == "danger")

local tail_schema = registered.parameters.properties.tail
assert(tail_schema.type == "integer" and tail_schema.minimum == 1 and tail_schema.maximum == 1000)
local approval_schema = registered.parameters.properties.approval
assert(approval_schema.enum[1] == "safe" and approval_schema.enum[2] == "read_only")

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function write(path, content)
    local handle = assert(io.open(path, "w"))
    assert(handle:write(content))
    assert(handle:close())
end

local function read(path)
    local handle = io.open(path, "r")
    if not handle then return "" end
    local content = assert(handle:read("*a"))
    assert(handle:close())
    return content
end

local temp_base = os.tmpname()
local root = temp_base .. " cron ü space"
assert(os.execute("mkdir -p " .. quote(root .. "/bin") .. " " .. quote(root .. "/config dir") .. " " .. quote(root .. "/cwd ü 50%")))
local crontab_path = root .. "/crontab"
local writes_path = root .. "/writes"
local marker_path = temp_base .. ".injected"
local backtick_marker_path = temp_base .. ".backtick-injected"
local stdout_path = root .. "/stdout"
local stderr_path = root .. "/stderr"

write(root .. "/bin/crontab", [[#!/bin/sh
if [ "$1" = "-l" ]; then
    if [ -f "$FAKE_CRONTAB" ]; then cat "$FAKE_CRONTAB"; else echo "no crontab for test" >&2; exit 1; fi
elif [ "$1" = "-" ]; then
    cat > "$FAKE_CRONTAB"
    printf x >> "$FAKE_WRITES"
else
    exit 2
fi
]])
write(root .. "/bin/bone", "#!/bin/sh\nexit 0\n")
assert(os.execute("chmod +x " .. quote(root .. "/bin/crontab") .. " " .. quote(root .. "/bin/bone")))

local function shell(command)
    local wrapped = "PATH=" .. quote(root .. "/bin") .. ":\"$PATH\"" ..
        " FAKE_CRONTAB=" .. quote(crontab_path) ..
        " FAKE_WRITES=" .. quote(writes_path) ..
        " " .. command .. " >" .. quote(stdout_path) .. " 2>" .. quote(stderr_path)
    local ok, _, code = os.execute(wrapped)
    return {
        exit_code = ok and 0 or code,
        stdout = read(stdout_path),
        stderr = read(stderr_path),
    }
end

local ctx = { shell = shell, config_dir = root .. "/config dir" }
local function run(params)
    return registered.execute(params, ctx)
end
local function expect_error(params, text)
    local result = run(params)
    assert(result:find("ERROR:", 1, true), result)
    assert(result:find(text, 1, true), result)
    return result
end

local original = table.concat({
    "MAILTO=user@example.test",
    "15 4 * * * /usr/bin/backup",
    "20 5 * * * old-command # BONE:legacy_other",
    "10 3 * * * malformed # BONE:W10",
}, "\n") .. "\n"
write(crontab_path, original)

local prompt = "Review $(touch " .. marker_path .. ") `touch " .. backtick_marker_path .. "` 'single' \"double\" \\ slash 50% café"
local result = run({
    action = "add",
    name = "daily",
    time = "09:07",
    prompt = prompt,
    cwd = root .. "/cwd ü 50%",
})
assert(result == "Added cron job daily.\n", result)
local stored = read(crontab_path)
assert(stored:find("MAILTO=user@example.test", 1, true))
assert(stored:find("/usr/bin/backup", 1, true))
assert(stored:find("# BONE:legacy_other", 1, true))
assert(stored:find("# BONE:W10", 1, true), "malformed metadata line was not preserved")
assert(stored:find("BONE_DIR=", 1, true))
assert(stored:find(root .. "/config dir", 1, true))
assert(stored:find("\\%", 1, true), "cron percent was not escaped")
assert(not stored:find("$(touch", 1, true), "prompt was interpolated into cron shell command")
assert(read(marker_path) == "", "command substitution was executed")
assert(read(backtick_marker_path) == "", "backtick substitution was executed")

result = run({ action = "list" })
assert(result:find("daily\t09:07\tsafe", 1, true), result)
assert(result:find(prompt, 1, true), result)
assert(result:find("legacy_other", 1, true), result)

result = run({
    action = "add",
    name = "daily",
    time = "10:08",
    approval = "read_only",
    prompt = "updated café",
    cwd = root .. "/cwd ü 50%",
})
assert(result == "Updated cron job daily.\n", result)
stored = read(crontab_path)
local _, daily_count = stored:gsub("daily", "")
assert(daily_count >= 1)
result = run({ action = "list" })
assert(result:find("daily\t10:08\tsafe", 1, true), result)

local before = read(crontab_path)
local writes_before = #read(writes_path)
result = run({ action = "remove", name = "missing" })
assert(result == "No cron job named missing.\n", result)
assert(read(crontab_path) == before)
assert(#read(writes_path) == writes_before, "missing removal rewrote crontab")

result = run({ action = "remove", name = "daily" })
assert(result == "Removed cron job daily.\n", result)
stored = read(crontab_path)
assert(not stored:find("updated café", 1, true))
assert(stored:find("MAILTO=user@example.test", 1, true))
assert(stored:find("# BONE:legacy_other", 1, true))

result = run({ action = "remove", name = "legacy_other" })
assert(result == "Removed cron job legacy_other.\n", result)
assert(not read(crontab_path):find("# BONE:legacy_other", 1, true))

local function base64url(value)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    local out = {}
    for i = 1, #value, 3 do
        local a, b, c = value:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        if b then out[#out + 1] = alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) end
        if c then out[#out + 1] = alphabet:sub(n % 64 + 1, n % 64 + 1) end
    end
    return table.concat(out)
end

local custom_log = root .. "/stored log ü.txt"
write(custom_log, "one\ntwo\nthree\nfour\n")
local metadata = string.format(
    '{"name":"stored","approval":"safe","cwd":"/tmp","prompt":"x","log_path":"%s"}',
    custom_log)
write(crontab_path, "0 1 * * * true # BONE:" .. base64url(metadata) .. "\n")
result = run({ action = "logs", name = "stored", tail = 2 })
assert(result == "three\nfour\n", result)
expect_error({ action = "logs", name = "stored", tail = 0 }, "between 1 and 1000")
expect_error({ action = "logs", name = "stored", tail = 1001 }, "between 1 and 1000")
expect_error({ action = "logs", name = "stored", tail = 1.5 }, "between 1 and 1000")

write(crontab_path, "")
expect_error({ action = "add", name = "bad name", time = "01:00", prompt = "ok", cwd = root }, "job name")
expect_error({ action = "add", name = string.rep("a", 129), time = "01:00", prompt = "ok", cwd = root }, "128")
expect_error({ action = "add", name = "bad", time = "25:00", prompt = "ok", cwd = root }, "between 00:00 and 23:59")
expect_error({ action = "add", name = "bad", time = "9:0", prompt = "ok", cwd = root }, "HH:MM")
expect_error({ action = "add", name = "bad", time = "01:00", approval = "unknown", prompt = "ok", cwd = root }, "safe or danger")
expect_error({ action = "add", name = "bad", time = "01:00", prompt = "ok", cwd = root .. "/missing" }, "does not exist")
expect_error({ action = "add", name = "bad", time = "01:00", prompt = "line1\nline2", cwd = root }, "control characters")
expect_error({ action = "add", name = "bad", time = "01:00", prompt = "tab\there", cwd = root }, "control characters")
expect_error({ action = "add", name = "bad", time = "01:00", prompt = "ok", cwd = root .. "\rbad" }, "control characters")
expect_error({ action = "add", name = "bad", time = "01:00", prompt = string.rep("x", 16385), cwd = root }, "16384")
assert(read(crontab_path) == "", "invalid input changed crontab")
result = run({ action = "add", name = "danger_job", time = "02:03", approval = "danger", prompt = "ok", cwd = root })
assert(result == "Added cron job danger_job.\n", result)
assert(run({ action = "list" }):find("danger_job\t02:03\tdanger", 1, true))
assert(run({ action = "remove", name = "danger_job" }) == "Removed cron job danger_job.\n")

local captured
local mock_ctx = {
    config_dir = "/authoritative config",
    shell = function(command)
        captured = command
        return { exit_code = 0, stdout = "ok", stderr = "warning" }
    end,
}
result = registered.execute({ action = "list", prompt = "$(touch " .. marker_path .. ") ' ` \\" }, mock_ctx)
assert(result == "ok", result)
assert(captured:find("TOOL_CONFIG_DIR='/authoritative config'", 1, true))
assert(captured:find(" python3 %-c "))
assert(not captured:find("uv run", 1, true))

mock_ctx.shell = function()
    return { exit_code = 9, stdout = "", stderr = "failed cleanly" }
end
result = registered.execute({ action = "list" }, mock_ctx)
assert(result == "ERROR: failed cleanly", result)

assert(os.execute("rm -rf " .. quote(root) .. " " .. quote(marker_path) .. " " .. quote(backtick_marker_path)))
print("cron tests passed")
