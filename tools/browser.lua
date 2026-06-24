-- browser tool: hand a natural-language task to the browser-use agent.
--
-- Architecture (v4 — browser-use):
--   * Unlike the old patchright tool (primitive navigate/click/type that the host
--     LLM drove step by step), this delegates a whole TASK to browser-use, which
--     runs its OWN agent loop over a real Chromium and returns a final result.
--   * browser-use needs its own LLM. We reuse whatever provider bone is currently
--     using: the active provider's handler/base_url/model come from the host config
--     (ctx.config.list_providers + ctx.conversation.current), and the api key is
--     passed to the runner via an env var so it never lands in argv / `ps`.
--   * An embedded, content-addressed Python runner is written to disk once per
--     version and invoked under `uv run --with browser-use`. uv installs
--     browser-use (and, on first run, its Chromium) into an ephemeral env.
--
-- Provider -> browser-use chat class:
--   handler == "anthropic"  -> ChatAnthropic(model, api_key)
--   otherwise (openai-compat) -> ChatOpenAI(model, api_key, base_url)
--
-- A single tool call is one long-running agent run, so it is bounded by the host's
-- ~300s ctx.shell ceiling. Keep max_steps modest and split very long jobs into
-- smaller tasks.

local BROWSER_USE_VERSION = "0.13.1"

local PYTHON_SCRIPT = [=[
import asyncio, base64, json, os, sys
from pathlib import Path

def bone_dir():
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg) / "bone-rust"
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE")
    if home:
        return Path(home) / ".bone-rust"
    return Path(".bone-rust").resolve()

def emit(obj):
    print(json.dumps(obj, default=str))

def ensure_display(headless):
    # bone is often launched from a tty, so the spawned browser inherits no
    # DISPLAY / WAYLAND_DISPLAY and a headful Chromium has no X server to draw on
    # (no visible window). When running headful and no display is set, point it at
    # a live X server discovered from its socket (Xwayland's :0 works without an
    # auth cookie). Mirrors the old patchright tool's behavior.
    if headless:
        return
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        return
    import glob, re
    nums = sorted({re.sub(r"^.*/X", "", s) for s in glob.glob("/tmp/.X11-unix/X*")})
    nums = [n for n in nums if n.isdigit()]
    if nums:
        os.environ["DISPLAY"] = ":" + nums[0]

def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        p = json.loads(base64.b64decode(raw.encode()).decode()) if raw else {}
    except Exception as e:
        emit({"error": f"bad params payload: {e}"})
        return

    task = (p.get("task") or "").strip()
    if not task:
        emit({"error": "task is required"})
        return

    key = os.environ.get("BONE_BU_KEY", "")
    handler = (p.get("handler") or "openai").strip()
    if handler == "anthropic" and not key:
        emit({"error": "the Anthropic provider has no API key — set one via /config"})
        return

    try:
        from browser_use import Agent, BrowserProfile, ChatOpenAI, ChatAnthropic
    except Exception as e:
        emit({"error": f"browser-use import failed: {e}"})
        return

    model = p.get("model") or ""
    if handler == "anthropic":
        llm = ChatAnthropic(model=model, api_key=key)
    else:
        # All of bone's OpenAI-compatible providers (openai, gemini, deepseek,
        # openrouter, glm, kimi, local, …) share this path; base_url targets them.
        # Local/keyless servers (e.g. llama.cpp) need no real key, but the OpenAI
        # client still wants a non-empty string, so fall back to a placeholder.
        llm = ChatOpenAI(model=model, api_key=key or "sk-local", base_url=p.get("base_url") or None)

    headless = bool(p.get("headless", False))
    ensure_display(headless)

    profile_dir = str(bone_dir() / "data" / "browser" / "profile")
    Path(profile_dir).mkdir(parents=True, exist_ok=True)
    profile = BrowserProfile(
        headless=headless,
        user_data_dir=profile_dir,
        keep_alive=False,
    )

    if p.get("start_url"):
        task = f"First open {p['start_url']}. Then: {task}"

    async def run():
        agent = Agent(
            task=task,
            llm=llm,
            browser_profile=profile,
            use_vision=bool(p.get("vision", True)),
        )
        history = await agent.run(max_steps=int(p.get("max_steps") or 15))
        return history

    try:
        history = asyncio.run(run())
    except Exception as e:
        emit({"error": f"browser-use run failed: {e}"})
        return

    try:
        errors = [e for e in history.errors() if e]
    except Exception:
        errors = []
    try:
        urls = [str(u) for u in history.urls() if u]
    except Exception:
        urls = []
    emit({
        "result": history.final_result(),
        "done": bool(history.is_done()),
        "steps": history.number_of_steps(),
        "urls": urls,
        "errors": errors,
    })

main()
]=]

-- Base64 encoder (Lua has none built in). Operates on raw bytes, so multibyte
-- UTF-8 params round-trip correctly. Used to pass the task/url/config to the
-- Python runner as a single argv token without shell-escaping pitfalls.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local a, b, c = s:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local x = math.floor(v / 262144) % 64
        local y = math.floor(v / 4096) % 64
        local z = math.floor(v / 64) % 64
        local w = v % 64
        local chunk = B64:sub(x + 1, x + 1) .. B64:sub(y + 1, y + 1)
        if b then
            chunk = chunk .. B64:sub(z + 1, z + 1)
            chunk = chunk .. (c and B64:sub(w + 1, w + 1) or "=")
        else
            chunk = chunk .. "=="
        end
        out[#out + 1] = chunk
        i = i + 3
    end
    return table.concat(out)
end

-- djb2 hash of a string -> 8 hex chars. Names the runner file by its content so
-- each script version is a distinct file: no overwrite is ever needed (the host
-- sandbox blocks io.open, ctx.write_file won't overwrite) and an upgrade
-- automatically lands a fresh filename.
local function content_hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local RUNNER_HASH = content_hash(PYTHON_SCRIPT)

-- Single-quote a value for use inside a `bash -c` command. Wraps in single quotes
-- and escapes any embedded single quote. Used for the inline api-key env var.
local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Find the provider bone is currently using and return its handler/base_url/
-- model/api_key.
--
-- Inside a TOOL call the host does not populate ctx.conversation.current() or the
-- list_providers() `active` flag (those carry app state only for slash commands),
-- so the reliable signal is the persisted selection: ctx.config.get("providers",
-- "_last_provider"). We resolve that id against list_providers() (which still
-- carries each provider's handler/base_url/model/api_key) and fall back to the
-- conversation/active hints when they happen to be present (e.g. command ctx).
local function active_provider(ctx)
    local providers = {}
    local ok, list = pcall(function() return ctx.config.list_providers() end)
    if ok and type(list) == "table" then
        providers = list
    end

    local conv_provider, conv_model
    local okc, conv = pcall(function() return ctx.conversation.current() end)
    if okc and type(conv) == "table" then
        conv_provider = conv.provider
        conv_model = conv.model
    end

    local last_provider
    local okl, lp = pcall(function() return ctx.config.get("providers", "_last_provider") end)
    if okl and type(lp) == "string" and lp ~= "" then
        last_provider = lp
    end

    local want = conv_provider or last_provider
    local chosen
    for _, row in ipairs(providers) do
        if want and row.id == want then
            chosen = row
            break
        end
        if not chosen and row.active then
            chosen = row
        end
    end
    if not chosen then
        return nil
    end
    return {
        handler = chosen.handler or "openai",
        base_url = chosen.base_url or "",
        model = conv_model or chosen.model or "",
        api_key = chosen.api_key or "",
    }
end

local function execute(params, ctx)
    params = params or {}
    local task = type(params.task) == "string" and params.task or ""
    if task == "" then
        return "ERROR: task is required"
    end

    local prov = active_provider(ctx)
    if not prov then
        return "ERROR: no active provider found — configure one via /config"
    end
    -- Cloud providers need a key; local/keyless OpenAI-compatible servers (e.g.
    -- llama.cpp) don't. Anthropic always does, so only block that case here.
    if prov.api_key == "" and prov.handler == "anthropic" then
        return "ERROR: the Anthropic provider has no API key — set one via /config"
    end

    -- The runner is written to disk once per script version (content-addressed
    -- name); params ride as a base64 argv token. The api key is NOT in the token —
    -- it is passed as an inline env var so it stays out of argv / `ps` output.
    local runner = ctx.config_dir .. "/_browser_runner_" .. RUNNER_HASH .. ".py"
    if not ctx.fs.is_file(runner) then
        local ok, err = pcall(ctx.write_file, runner, PYTHON_SCRIPT)
        if not ok then
            return "ERROR: cannot install browser runner at " .. runner .. ": " .. tostring(err)
        end
    end

    local payload = b64encode(cjson.encode({
        task = task,
        max_steps = tonumber(params.max_steps) or 15,
        headless = params.headless and true or false,
        vision = params.vision ~= false,
        start_url = type(params.start_url) == "string" and params.start_url or nil,
        handler = prov.handler,
        base_url = prov.base_url,
        model = prov.model,
    }))

    local cmd = "ANONYMIZED_TELEMETRY=false BONE_BU_KEY=" .. shquote(prov.api_key)
        .. " uv run --no-project --with 'browser-use==" .. BROWSER_USE_VERSION .. "'"
        .. " -- python '" .. runner .. "' '" .. payload .. "'"

    -- One call is a whole agent run. Use the host's max budget; browser-use's own
    -- max_steps is the real bound on how long the agent works.
    local result = ctx.shell(cmd, { timeout_ms = 300000 })
    if result.exit_code ~= 0 then
        local err = (result.stderr and #result.stderr > 0) and result.stderr or (result.stdout or "")
        return "ERROR: " .. err
    end
    return result.stdout or ""
end

bone.register_tool({
    name = "browser",
    description = [[Delegate a web task to an autonomous browser agent (browser-use driving a real Chromium). You describe the goal in plain language; the agent navigates, clicks, types, reads, and extracts on its own, then returns a final result — you do NOT drive individual clicks.

Give a complete, self-contained task ("Go to news.ycombinator.com and return the titles and points of the top 5 posts", "Search Amazon for a USB-C hub under $30 and report the cheapest with its price and link"). Include any data it needs (search terms, filters, what to extract). It reuses bone's current LLM provider, so make sure that provider's API key is set (/config).

Returns JSON: result (the agent's final answer), done (whether it finished), steps, urls visited, and any errors.

Notes:
- Runs headful by default so you can watch and so captcha/login pages can be solved in the visible window; pass headless=true to hide it.
- One call is one agent run, bounded by ~5 minutes — keep tasks focused and raise/lower max_steps (default 15) to fit. Split very large jobs into several tasks.
- First run downloads browser-use and its Chromium (slower); subsequent runs are fast.
- Set vision=false only if the active provider's model has no image support.]],
    parameters = {
        type = "object",
        properties = {
            task = { type = "string", description = "The web task to complete, in plain language. Be specific about what to do and what to return." },
            max_steps = { type = "number", description = "Max agent steps before it must finish (default 15). Higher = more thorough but slower." },
            headless = { type = "boolean", description = "Run the browser hidden (default false; headful lets the user solve captchas/logins)." },
            vision = { type = "boolean", description = "Let the agent use page screenshots (default true). Set false for non-vision models." },
            start_url = { type = "string", description = "Optional URL to open before starting the task." },
        },
        required = { "task" },
        additionalProperties = false,
    },
    safety = "danger",
    -- Eager: the browser agent runs for minutes; render the row at dispatch so
    -- the user sees it start, not only when it finishes.
    display = { show = true, args = { "task" }, eager = true },
    execute = execute,
})
