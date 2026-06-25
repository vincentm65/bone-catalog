-- browser tool: drive a persistent Chromium with primitive verbs (v5 — CDP).
--
-- Architecture (v5 — host-driven CDP):
--   * Unlike v4 (browser-use, which ran its OWN autonomous agent loop and only
--     returned a final answer), this exposes primitive verbs — open, read, click,
--     type, screenshot, eval, … — and the BONE host model drives them step by
--     step. Every action is one tool call whose result the host sees, so the run
--     is fully observable and the host can ask the user for input mid-task.
--   * No LLM lives in the runner: bone's own model is the loop. All the v4
--     provider/api-key plumbing is gone.
--
-- Persistence — the crux:
--   A browser is long-lived and stateful, but every ctx.shell call is a fresh
--   process. So the verbs talk to a PERSISTENT Chromium that outlives any single
--   call:
--     * cold start: the runner launches the raw Chromium binary (Playwright's
--       bundled one) DETACHED (start_new_session, fds → logfile, never the
--       inherited shell pipes — otherwise ctx.shell would block until timeout),
--       with --remote-debugging-port. pid+port are recorded under
--       data/browser/.
--     * every verb: connect_over_cdp(port), act on the existing page, then
--       DISCONNECT (browser.close() on a CDP connection does NOT kill the remote
--       Chromium). State (cookies, logins, the open page) stays in the browser.
--     * `stop` kills the recorded pid.
--   The profile dir (data/browser/profile) is reused across runs, so logins and
--   cookies persist between sessions just like the v4 tool.
--
-- After a `screenshot` you get a file path; the host can `read_file` it to see
-- the page visually (read_file renders images).

local RUNNER_VERSION = "5.0.0"

local PYTHON_SCRIPT = [=[
import asyncio, base64, json, os, signal, subprocess, sys, time, urllib.request
from pathlib import Path

DEFAULT_PORT = 9333
READ_LIMIT = 12000  # chars of page text returned by `read`

def bone_dir():
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg) / "bone-rust"
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE")
    if home:
        return Path(home) / ".bone-rust"
    return Path(".bone-rust").resolve()

DATA = bone_dir() / "data" / "browser"
PROFILE = DATA / "profile"
PORT_FILE = DATA / "cdp_port"
PID_FILE = DATA / "pid"
LOG = DATA / "chromium.log"

def emit(obj):
    print(json.dumps(obj, default=str))

def cdp_base(port):
    return "http://127.0.0.1:%d" % port

def port_alive(port):
    try:
        with urllib.request.urlopen(cdp_base(port) + "/json/version", timeout=1) as r:
            return r.status == 200
    except Exception:
        return False

def read_port():
    try:
        return int(PORT_FILE.read_text().strip())
    except Exception:
        return DEFAULT_PORT

def read_pid():
    try:
        return int(PID_FILE.read_text().strip())
    except Exception:
        return None

def ensure_display(headless):
    # bone is usually launched from a tty with no DISPLAY/WAYLAND_DISPLAY, so a
    # headful Chromium has no X server to draw on. Point it at a live X server
    # discovered from its socket (Xwayland's :0 works without an auth cookie).
    if headless:
        return
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        return
    import glob, re
    nums = sorted({re.sub(r"^.*/X", "", s) for s in glob.glob("/tmp/.X11-unix/X*")})
    nums = [n for n in nums if n.isdigit()]
    if nums:
        os.environ["DISPLAY"] = ":" + nums[0]

def chromium_executable():
    # executable_path is available without launching anything. On a fresh
    # environment the browser binary may not be downloaded yet — install it once.
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        exe = p.chromium.executable_path
    if not exe or not Path(exe).exists():
        subprocess.run(
            [sys.executable, "-m", "playwright", "install", "chromium"],
            check=False,
        )
        from playwright.sync_api import sync_playwright as sp2
        with sp2() as p:
            exe = p.chromium.executable_path
    return exe

def launch_chromium(headless, port):
    DATA.mkdir(parents=True, exist_ok=True)
    PROFILE.mkdir(parents=True, exist_ok=True)
    ensure_display(headless)
    exe = chromium_executable()
    args = [
        exe,
        "--remote-debugging-port=%d" % port,
        "--remote-debugging-address=127.0.0.1",
        "--user-data-dir=%s" % PROFILE,
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate",
    ]
    if headless:
        args.append("--headless=new")
    # Fully detached: own session and fds → logfile, NOT the shell pipes that
    # ctx.shell reads to EOF (else the call blocks until timeout). This is what
    # lets the browser outlive the launching shell call.
    logf = open(LOG, "ab")
    proc = subprocess.Popen(
        args,
        stdout=logf,
        stderr=logf,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    PID_FILE.write_text(str(proc.pid))
    PORT_FILE.write_text(str(port))
    for _ in range(150):  # up to ~15s for the debug port to come up
        if port_alive(port):
            return
        if proc.poll() is not None:
            raise RuntimeError("Chromium exited before opening the debug port; see " + str(LOG))
        time.sleep(0.1)
    raise RuntimeError("Chromium did not open the debug port in time")

def do_stop():
    pid = read_pid()
    killed = False
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            killed = True
        except ProcessLookupError:
            pass
        except Exception:
            pass
    for f in (PID_FILE, PORT_FILE):
        try:
            f.unlink()
        except Exception:
            pass
    return {"ok": True, "action": "stop", "killed": killed}

async def get_page(browser):
    ctxs = browser.contexts
    ctx = ctxs[0] if ctxs else await browser.new_context()
    pages = ctx.pages
    return pages[0] if pages else await ctx.new_page()

async def dispatch(action, p, browser):
    page = await get_page(browser)
    timeout = int(p.get("timeout_ms") or 30000)

    if action == "open":
        url = (p.get("url") or "").strip()
        if not url:
            return {"ok": False, "error": "open requires `url`"}
        if "://" not in url:
            url = "https://" + url
        await page.goto(url, wait_until="domcontentloaded", timeout=timeout)
        return {"ok": True, "action": "open", "url": page.url, "title": await page.title()}

    if action == "read":
        sel = p.get("selector") or "body"
        try:
            await page.wait_for_selector(sel, timeout=timeout)
        except Exception:
            pass
        text = await page.inner_text(sel)
        truncated = len(text) > READ_LIMIT
        return {
            "ok": True, "action": "read", "url": page.url, "title": await page.title(),
            "selector": sel, "truncated": truncated, "text": text[:READ_LIMIT],
        }

    if action == "click":
        sel = p.get("selector")
        if not sel:
            return {"ok": False, "error": "click requires `selector`"}
        await page.click(sel, timeout=timeout)
        return {"ok": True, "action": "click", "selector": sel, "url": page.url}

    if action == "type":
        sel, text = p.get("selector"), p.get("text")
        if not sel or text is None:
            return {"ok": False, "error": "type requires `selector` and `text`"}
        await page.fill(sel, text, timeout=timeout)
        if p.get("enter"):
            await page.press(sel, "Enter")
        return {"ok": True, "action": "type", "selector": sel, "url": page.url}

    if action == "press":
        key = p.get("text")
        if not key:
            return {"ok": False, "error": "press requires `text` (the key, e.g. 'Enter')"}
        await page.keyboard.press(key)
        return {"ok": True, "action": "press", "key": key, "url": page.url}

    if action == "screenshot":
        DATA.mkdir(parents=True, exist_ok=True)
        path = p.get("path") or str(DATA / "shot.png")
        await page.screenshot(path=path, full_page=bool(p.get("full_page")))
        return {"ok": True, "action": "screenshot", "path": path, "url": page.url}

    if action == "eval":
        js = p.get("js")
        if not js:
            return {"ok": False, "error": "eval requires `js`"}
        value = await page.evaluate(js)
        return {"ok": True, "action": "eval", "value": value, "url": page.url}

    if action == "back":
        await page.go_back(wait_until="domcontentloaded", timeout=timeout)
        return {"ok": True, "action": "back", "url": page.url, "title": await page.title()}

    if action == "tabs":
        tabs = []
        for ctx in browser.contexts:
            for pg in ctx.pages:
                tabs.append({"url": pg.url, "title": await pg.title()})
        return {"ok": True, "action": "tabs", "tabs": tabs}

    if action == "current_url":
        return {"ok": True, "action": "current_url", "url": page.url, "title": await page.title()}

    return {"ok": False, "error": "unknown action: %s" % action}

async def run(p):
    from playwright.async_api import async_playwright
    port = read_port()
    async with async_playwright() as pw:
        browser = await pw.chromium.connect_over_cdp(cdp_base(port))
        try:
            return await dispatch(p["action"], p, browser)
        finally:
            await browser.close()  # disconnect only; remote Chromium keeps running

def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        p = json.loads(base64.b64decode(raw.encode()).decode()) if raw else {}
    except Exception as e:
        emit({"ok": False, "error": "bad params payload: %s" % e})
        return

    action = (p.get("action") or "").strip()
    if not action:
        emit({"ok": False, "error": "action is required"})
        return

    if action == "stop":
        emit(do_stop())
        return

    # Cold start: launch the persistent Chromium if its debug port is not up.
    port = read_port()
    if not port_alive(port):
        try:
            launch_chromium(bool(p.get("headless", False)), port)
        except Exception as e:
            emit({"ok": False, "error": "could not start browser: %s" % e})
            return

    try:
        emit(asyncio.run(run(p)))
    except Exception as e:
        emit({"ok": False, "action": action, "error": str(e)})

main()
]=]

-- Base64 encoder (Lua has none built in). Operates on raw bytes, so multibyte
-- UTF-8 params round-trip correctly. Used to pass params to the Python runner as
-- a single argv token without shell-escaping pitfalls.
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

local function execute(params, ctx)
    params = params or {}
    local action = type(params.action) == "string" and params.action or ""
    if action == "" then
        return "ERROR: action is required"
    end

    -- The runner is written to disk once per script version (content-addressed
    -- name); params ride as a base64 argv token.
    local runner = ctx.config_dir .. "/_browser_cdp_" .. RUNNER_HASH .. ".py"
    if not ctx.fs.is_file(runner) then
        local ok, err = pcall(ctx.write_file, runner, PYTHON_SCRIPT)
        if not ok then
            return "ERROR: cannot install browser runner at " .. runner .. ": " .. tostring(err)
        end
    end

    local payload = b64encode(cjson.encode({
        action = action,
        url = type(params.url) == "string" and params.url or nil,
        selector = type(params.selector) == "string" and params.selector or nil,
        text = type(params.text) == "string" and params.text or nil,
        js = type(params.js) == "string" and params.js or nil,
        path = type(params.path) == "string" and params.path or nil,
        enter = params.enter and true or false,
        full_page = params.full_page and true or false,
        headless = params.headless and true or false,
        timeout_ms = tonumber(params.timeout_ms) or nil,
    }))

    local cmd = "ANONYMIZED_TELEMETRY=false uv run --no-project --with playwright"
        .. " -- python '" .. runner .. "' '" .. payload .. "'"

    -- First run downloads Playwright's Chromium (slow); steady-state verbs are
    -- quick. Use the host's max budget so a cold start isn't cut off.
    local result = ctx.shell(cmd, { timeout_ms = 300000 })
    if result.exit_code ~= 0 then
        local err = (result.stderr and #result.stderr > 0) and result.stderr or (result.stdout or "")
        return "ERROR: " .. err
    end
    return result.stdout or ""
end

bone.register_tool({
    name = "browser",
    description = [[Drive a persistent Chromium browser one action at a time. YOU are the loop: call this repeatedly — open a page, read it, click/type, read again — deciding each step from the result of the last. The browser stays open and logged-in between calls (cookies and sessions persist), so a later call continues where the previous one left off.

Pick an `action`:
- open        — navigate to `url` (https:// assumed if no scheme).
- read        — return the visible text of the page, or of `selector` if given. Do this after every navigation/click to see what happened.
- click       — click the element matching `selector` (CSS or Playwright text= selector).
- type        — fill `selector` with `text`; pass enter=true to submit.
- press       — send a single key (`text`, e.g. "Enter", "PageDown").
- screenshot  — save a PNG to `path` (default data/browser/shot.png); read_file it to view the page. full_page=true for the whole scroll height.
- eval        — run JavaScript (`js`) in the page and return its value.
- tabs        — list open tabs (url + title).
- current_url — report the active tab's url and title.
- back        — go back one entry in history.
- stop        — close the browser and end the session.

The browser auto-starts on the first action (headful by default so you can watch and so captchas/logins can be solved in the window; pass headless=true on that first call to hide it — it only applies at cold start). First ever run downloads Chromium and is slow; after that, actions are fast.

Each call returns JSON: ok plus action-specific fields (url, title, text, value, path, …) or an error. For multi-step jobs, read between actions and keep the host in the loop for anything ambiguous.]],
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "open", "read", "click", "type", "press", "screenshot", "eval", "tabs", "current_url", "back", "stop" },
                description = "Drive a persistent browser one step at a time: open, read, click, type, screenshot, eval, and more.",
            },
            url = { type = "string", description = "URL for `open` (scheme optional)." },
            selector = { type = "string", description = "CSS or text= selector for read/click/type." },
            text = { type = "string", description = "Text to type (for `type`), or the key name (for `press`)." },
            enter = { type = "boolean", description = "For `type`: press Enter after filling (submit)." },
            js = { type = "string", description = "JavaScript to run for `eval`." },
            path = { type = "string", description = "Output file for `screenshot`." },
            full_page = { type = "boolean", description = "For `screenshot`: capture the full scroll height." },
            headless = { type = "boolean", description = "Only at cold start: launch hidden (default false)." },
            timeout_ms = { type = "number", description = "Per-action timeout in ms (default 30000)." },
        },
        required = { "action" },
        additionalProperties = false,
    },
    safety = "danger",
    -- Eager: show the row as the action starts (a cold-start launch takes a few
    -- seconds), not only when it returns.
    display = { show = true, args = { "action", "url", "selector" }, eager = true },
    execute = execute,
})
