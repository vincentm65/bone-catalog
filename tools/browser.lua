-- browser tool: drive a persistent browser with observe/target verbs (v7 — daemon).
--
-- Architecture (v7 — host-driven daemon):
--   * Unlike v4 (browser-use, which ran its OWN autonomous agent loop and only
--     returned a final answer), this exposes a small remote-control protocol:
--     open/observe/click/type/select/press/scroll/wait_for. The host model sees
--     visible text plus stable target IDs, never raw CSS selectors.
--   * No LLM lives in the runner: bone's own model is the loop. All the v4
--     provider/api-key plumbing is gone.
--
-- Persistence — the crux:
--   A browser is long-lived and stateful, but every ctx.shell call is a fresh
--   process. The first verb starts a detached Python daemon (fds -> logfile) that
--   owns a Playwright persistent context. Later verbs send one JSON request to
--   localhost and return one JSON response. This avoids an autonomous loop,
--   keeps Bone's main agent in charge, and works for Chromium and Firefox.
--   Per-engine profile dirs under data/browser/ are reused across runs, so
--   logins and cookies persist between sessions just like the v4 tool.
--
-- `screenshot` remains available for debugging, but the main path is DOM-based
-- observe -> target ID -> action, without requiring vision.

local RUNNER_VERSION = "7.0.0"

local PYTHON_SCRIPT = [=[
import asyncio, base64, json, os, re, signal, subprocess, sys, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

DEFAULT_PORT = 9333
READ_LIMIT = 4000
TARGET_LIMIT = 60
SUPPORTED_BROWSERS = {"chromium", "firefox"}

def bone_dir():
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg) / "bone-rust"
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE")
    if home:
        return Path(home) / ".bone-rust"
    return Path(".bone-rust").resolve()

DATA = bone_dir() / "data" / "browser"
PORT_FILE = DATA / "port"
LEGACY_PORT_FILE = DATA / "cdp_port"
PID_FILE = DATA / "pid"
STATE_FILE = DATA / "state.json"
LOG = DATA / "browser.log"

def emit(obj):
    print(json.dumps(obj, default=str))

def cdp_base(port):
    return "http://127.0.0.1:%d" % port

def port_alive(port):
    try:
        with urllib.request.urlopen(cdp_base(port) + "/health", timeout=1) as r:
            return r.status == 200
    except Exception:
        return False

def post_json(port, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        cdp_base(port) + "/action",
        data=data,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=max(5, int(payload.get("timeout_ms") or 30000) / 1000 + 5)) as r:
        return json.loads(r.read().decode() or "{}")

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

def read_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}

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

def ensure_browser_installed(browser_name):
    # Fast when already installed; downloads on first use. Avoid Playwright's
    # sync API here because the client path runs inside asyncio.run().
    subprocess.run(
        [sys.executable, "-m", "playwright", "install", browser_name],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

def launch_daemon(browser_name, headless, port):
    headless = False
    DATA.mkdir(parents=True, exist_ok=True)
    ensure_display(headless)
    ensure_browser_installed(browser_name)
    args = [
        sys.executable,
        __file__,
        "--server",
        "--port", str(port),
        "--browser", browser_name,
    ]
    # Fully detached: own session and fds -> logfile, NOT the shell pipes that
    # ctx.shell reads to EOF. This lets the daemon outlive the launching call.
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
    STATE_FILE.write_text(json.dumps({"browser": browser_name, "headless": False, "pid": proc.pid, "port": port}))
    for _ in range(150):  # up to ~15s for the debug port to come up
        if port_alive(port):
            return
        if proc.poll() is not None:
            raise RuntimeError("browser daemon exited before opening the port; see " + str(LOG))
        time.sleep(0.1)
    raise RuntimeError("browser daemon did not open the port in time")

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
    for f in (PID_FILE, PORT_FILE, LEGACY_PORT_FILE, STATE_FILE):
        try:
            f.unlink()
        except Exception:
            pass
    return {"ok": True, "action": "stop", "killed": killed}

def css_quote(s):
    return json.dumps(str(s))

def bounded_int(value, default, low, high):
    try:
        n = int(value)
    except Exception:
        return default
    return max(low, min(high, n))

def bounded_value(value, max_chars):
    try:
        raw = json.dumps(value, default=str)
    except Exception:
        raw = json.dumps(str(value))
    if len(raw) <= max_chars:
        return value
    return {"truncated": True, "text": raw[:max_chars]}

async def get_page(ctx):
    pages = ctx.pages
    return pages[0] if pages else await ctx.new_page()

async def observe_page(daemon, page, selector, max_chars, max_targets):
    try:
        await page.wait_for_selector(selector, timeout=1000)
    except Exception:
        pass
    try:
        text = await page.inner_text(selector)
    except Exception:
        text = ""
    truncated = len(text) > max_chars
    targets = await page.evaluate(
        """(limit) => {
            const out = [];
            const seen = new Set();
            const targetAttr = 'data-bone-target';
            const cssPath = (el) => {
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                while (el && el.nodeType === Node.ELEMENT_NODE && parts.length < 5) {
                    let part = el.nodeName.toLowerCase();
                    if (el.classList && el.classList.length) {
                        part += '.' + Array.from(el.classList).slice(0, 2).map(CSS.escape).join('.');
                    }
                    const parent = el.parentElement;
                    if (parent) {
                        const same = Array.from(parent.children).filter(x => x.nodeName === el.nodeName);
                        if (same.length > 1) part += `:nth-of-type(${same.indexOf(el) + 1})`;
                    }
                    parts.unshift(part);
                    el = parent;
                }
                return parts.join(' > ');
            };
            const labelOf = (el) => {
                const aria = el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('placeholder') || '';
                const text = (el.innerText || el.value || '').replace(/\\s+/g, ' ').trim();
                return (aria || text || el.name || el.id || '').slice(0, 120);
            };
            const kindOf = (el) => {
                const tag = el.nodeName.toLowerCase();
                const role = (el.getAttribute('role') || '').toLowerCase();
                const type = (el.getAttribute('type') || '').toLowerCase();
                if (tag === 'select') return 'select';
                if (tag === 'textarea') return 'input';
                if (tag === 'input') {
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (['button', 'submit', 'reset'].includes(type)) return 'button';
                    return 'input';
                }
                if (tag === 'a' || role === 'link') return 'link';
                if (tag === 'button' || role === 'button') return 'button';
                if (el.isContentEditable) return 'input';
                return role || tag;
            };
            const optionList = (el) => {
                if (el.nodeName.toLowerCase() !== 'select') return undefined;
                return Array.from(el.options).slice(0, 50).map(o => ({
                    label: (o.label || o.innerText || o.value || '').trim(),
                    value: o.value,
                    selected: o.selected,
                    disabled: o.disabled
                }));
            };
            const nodes = document.querySelectorAll('a,button,input,textarea,select,[role=button],[role=link],[contenteditable=true]');
            for (const el of nodes) {
                if (out.length >= limit) break;
                const r = el.getBoundingClientRect();
                const style = getComputedStyle(el);
                if (r.width < 1 || r.height < 1 || style.visibility === 'hidden' || style.display === 'none') continue;
                const selector = cssPath(el);
                if (!selector || seen.has(selector)) continue;
                seen.add(selector);
                const id = 't' + String(out.length + 1).padStart(2, '0');
                try { el.setAttribute(targetAttr, id); } catch (_) {}
                out.push({
                    id,
                    selector: '[' + targetAttr + '="' + id + '"]',
                    tag: el.nodeName.toLowerCase(),
                    kind: kindOf(el),
                    role: el.getAttribute('role') || '',
                    label: labelOf(el),
                    href: el.href || '',
                    type: el.getAttribute('type') || '',
                    value: el.value || '',
                    checked: !!el.checked,
                    disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
                    box: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
                    options: optionList(el)
                });
            }
            return out;
        }""",
        max_targets,
    )
    daemon.targets = {}
    public_targets = []
    for t in targets:
        tid = t.get("id")
        if not tid:
            continue
        daemon.targets[tid] = {
            "selector": t.get("selector"),
            "box": t.get("box"),
            "kind": t.get("kind"),
            "label": t.get("label"),
        }
        public = {k: v for k, v in t.items() if k != "selector"}
        public_targets.append(public)
    return text[:max_chars], truncated, public_targets

def target_center(target):
    box = target.get("box") if target else None
    if not isinstance(box, list) or len(box) != 4:
        return None
    return (box[0] + box[2] / 2, box[1] + box[3] / 2)

async def resolve_target(page, p, daemon):
    target_id = p.get("target") or p.get("ref")
    if target_id:
        target = daemon.targets.get(str(target_id))
        if target:
            return target
        return {"missing": str(target_id)}
    selector = p.get("selector")
    if selector:
        return {"selector": str(selector)}
    return None

async def click_target(page, target, timeout):
    selector = target.get("selector")
    if selector:
        try:
            await page.locator(selector).click(timeout=min(timeout, 3000))
            return
        except Exception:
            pass
    center = target_center(target)
    if center:
        await page.mouse.click(center[0], center[1])
        return
    raise RuntimeError("target has no clickable selector or box")

async def observed_result(daemon, page, action, p, extra=None):
    max_chars = bounded_int(p.get("max_chars"), READ_LIMIT, 0, 20000)
    max_targets = bounded_int(p.get("max_targets") or p.get("max_elements"), TARGET_LIMIT, 0, 150)
    text, truncated, targets = await observe_page(daemon, page, "body", max_chars, max_targets)
    out = {
        "ok": True,
        "action": action,
        "url": page.url,
        "title": await page.title(),
        "text": text,
        "truncated": truncated,
        "targets": targets,
        "next": "Use targets[].id for the next browser action; do not invent CSS selectors.",
    }
    if extra:
        out.update(extra)
    return out

async def dispatch(action, p, daemon):
    page = await get_page(daemon.ctx)
    timeout = int(p.get("timeout_ms") or 30000)

    if action == "open":
        url = (p.get("url") or "").strip()
        if not url:
            return {"ok": False, "error": "open requires `url`"}
        if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", url):
            url = "https://" + url
        await page.goto(url, wait_until="domcontentloaded", timeout=timeout)
        text, truncated, targets = await observe_page(
            daemon, page, "body",
            bounded_int(p.get("max_chars"), READ_LIMIT, 0, 20000),
            bounded_int(p.get("max_targets") or p.get("max_elements"), TARGET_LIMIT, 0, 150),
        )
        return {
            "ok": True, "action": "open", "url": page.url, "title": await page.title(),
            "text": text, "truncated": truncated, "targets": targets,
            "next": "Continue with browser actions. Use targets[].id as target for click/type/select/check/uncheck. Do not invent CSS selectors.",
        }

    if action == "observe" or action == "read" or action == "scrape":
        sel = p.get("selector") or "body"
        max_chars = bounded_int(p.get("max_chars"), READ_LIMIT, 0, 20000)
        max_targets = bounded_int(p.get("max_targets") or p.get("max_elements"), TARGET_LIMIT, 0, 150)
        text, truncated, targets = await observe_page(daemon, page, sel, max_chars, max_targets)
        return {
            "ok": True, "action": "observe", "url": page.url, "title": await page.title(),
            "selector": sel, "truncated": truncated, "max_chars": max_chars,
            "text": text, "targets": targets,
            "next": "Use targets[].id as target for click/type/select/check/uncheck; call observe again after actions.",
        }

    if action == "click":
        target = await resolve_target(page, p, daemon)
        if not target:
            return {"ok": False, "error": "click requires `target` from observe"}
        if target.get("missing"):
            return {"ok": False, "error": "unknown target: %s; call observe again" % target["missing"]}
        await click_target(page, target, timeout)
        try:
            await page.wait_for_load_state("domcontentloaded", timeout=min(timeout, 5000))
        except Exception:
            pass
        return await observed_result(daemon, page, "click", p, {"target": p.get("target") or p.get("ref")})

    if action == "type":
        target, text = await resolve_target(page, p, daemon), p.get("text")
        if not target or text is None:
            return {"ok": False, "error": "type requires `target` from observe plus `text`"}
        if target.get("missing"):
            return {"ok": False, "error": "unknown target: %s; call observe again" % target["missing"]}
        selector = target.get("selector")
        filled = False
        if selector:
            try:
                await page.locator(selector).fill(str(text), timeout=min(timeout, 3000))
                filled = True
            except Exception:
                pass
        if not filled:
            await click_target(page, target, timeout)
            mod = "Meta" if sys.platform == "darwin" else "Control"
            try:
                await page.keyboard.press(mod + "+A")
            except Exception:
                pass
            await page.keyboard.type(str(text))
        if p.get("enter"):
            await page.keyboard.press("Enter")
            try:
                await page.wait_for_load_state("domcontentloaded", timeout=min(timeout, 5000))
            except Exception:
                pass
        return await observed_result(daemon, page, "type", p, {"target": p.get("target") or p.get("ref")})

    if action == "select":
        target, value = await resolve_target(page, p, daemon), p.get("value")
        if not target or value is None:
            return {"ok": False, "error": "select requires `target` from observe plus `value`"}
        if target.get("missing"):
            return {"ok": False, "error": "unknown target: %s; call observe again" % target["missing"]}
        selector = target.get("selector")
        if not selector:
            return {"ok": False, "error": "target cannot be selected"}
        try:
            await page.locator(selector).select_option(str(value), timeout=timeout)
        except Exception:
            await page.evaluate(
                """([selector, value]) => {
                    const el = document.querySelector(selector);
                    if (!el) throw new Error('select target disappeared');
                    el.value = value;
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                }""",
                [selector, str(value)],
            )
        return await observed_result(daemon, page, "select", p, {"target": p.get("target") or p.get("ref"), "value": value})

    if action == "check" or action == "uncheck":
        target = await resolve_target(page, p, daemon)
        if not target:
            return {"ok": False, "error": "%s requires `target` from observe" % action}
        if target.get("missing"):
            return {"ok": False, "error": "unknown target: %s; call observe again" % target["missing"]}
        selector = target.get("selector")
        if selector:
            locator = page.locator(selector)
            try:
                if action == "check":
                    await locator.check(timeout=timeout)
                else:
                    await locator.uncheck(timeout=timeout)
            except Exception:
                await click_target(page, target, timeout)
        else:
            await click_target(page, target, timeout)
        return await observed_result(daemon, page, action, p, {"target": p.get("target") or p.get("ref")})

    if action == "scroll":
        amount = bounded_int(p.get("amount"), 700, -5000, 5000)
        direction = (p.get("direction") or "").lower()
        if direction in ("up", "pageup"):
            amount = -abs(amount)
        elif direction in ("down", "pagedown", ""):
            amount = abs(amount)
        await page.mouse.wheel(0, amount)
        return await observed_result(daemon, page, "scroll", p, {"amount": amount})

    if action == "wait_for":
        text = p.get("text")
        if not text:
            return {"ok": False, "error": "wait_for requires `text`"}
        await page.wait_for_function("(needle) => document.body && document.body.innerText.includes(needle)", str(text), timeout=timeout)
        return await observed_result(daemon, page, "wait_for", p, {"matched": text})

    if action == "press":
        key = p.get("key") or p.get("text")
        if not key:
            return {"ok": False, "error": "press requires `key` (e.g. 'Enter')"}
        await page.keyboard.press(key)
        try:
            await page.wait_for_load_state("domcontentloaded", timeout=min(timeout, 5000))
        except Exception:
            pass
        return await observed_result(daemon, page, "press", p, {"key": key})

    if action == "screenshot":
        DATA.mkdir(parents=True, exist_ok=True)
        path = p.get("path") or str(DATA / "shot.png")
        await page.screenshot(path=path, full_page=bool(p.get("full_page")))
        return {
            "ok": True, "action": "screenshot", "path": path, "read_file_path": path,
            "url": page.url,
            "next": "To inspect this screenshot visually, call read_file with exactly read_file_path.",
        }

    if action == "eval":
        js = p.get("js")
        if not js:
            return {"ok": False, "error": "eval requires `js`"}
        value = await page.evaluate(js)
        max_chars = bounded_int(p.get("max_chars"), READ_LIMIT, 0, 20000)
        return {"ok": True, "action": "eval", "value": bounded_value(value, max_chars), "url": page.url}

    if action == "back":
        await page.go_back(wait_until="domcontentloaded", timeout=timeout)
        return await observed_result(daemon, page, "back", p)

    if action == "tabs":
        tabs = []
        for pg in daemon.ctx.pages:
            tabs.append({"url": pg.url, "title": await pg.title()})
        return {"ok": True, "action": "tabs", "tabs": tabs}

    if action == "current_url":
        return {"ok": True, "action": "current", "url": page.url, "title": await page.title()}

    if action == "current":
        return {"ok": True, "action": "current", "url": page.url, "title": await page.title()}

    return {"ok": False, "error": "unknown action: %s" % action}

class BrowserDaemon:
    def __init__(self, browser_name, headless):
        self.browser_name = browser_name
        self.headless = False
        self.pw = None
        self.ctx = None
        self.loop = None
        self.targets = {}

    async def start(self):
        from playwright.async_api import async_playwright
        self.pw = await async_playwright().start()
        browser_type = getattr(self.pw, self.browser_name)
        profile = DATA / ("%s-profile" % self.browser_name)
        profile.mkdir(parents=True, exist_ok=True)
        kwargs = {"headless": self.headless}
        if self.browser_name == "chromium":
            kwargs["args"] = ["--no-first-run", "--no-default-browser-check", "--disable-features=Translate"]
        self.ctx = await browser_type.launch_persistent_context(str(profile), **kwargs)

    async def stop(self):
        try:
            if self.ctx:
                await self.ctx.close()
        finally:
            if self.pw:
                await self.pw.stop()

    async def handle(self, payload):
        global STOP_REQUESTED
        action = (payload.get("action") or "").strip()
        if action == "stop":
            await self.stop()
            for f in (PID_FILE, PORT_FILE, STATE_FILE):
                try:
                    f.unlink()
                except Exception:
                    pass
            STOP_REQUESTED = True
            return {"ok": True, "action": "stop", "killed": True}
        return await dispatch(action, payload, self)

DAEMON = None
STOP_REQUESTED = False

def run_server(argv):
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", action="store_true")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--browser", choices=sorted(SUPPORTED_BROWSERS), required=True)
    args = parser.parse_args(argv)

    DATA.mkdir(parents=True, exist_ok=True)
    ensure_display(False)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    global DAEMON, STOP_REQUESTED
    STOP_REQUESTED = False
    DAEMON = BrowserDaemon(args.browser, False)
    DAEMON.loop = loop
    loop.run_until_complete(DAEMON.start())

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def _send(self, status, obj):
            body = json.dumps(obj, default=str).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self._send(200, {"ok": True, "browser": DAEMON.browser_name})
            else:
                self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self):
            if self.path != "/action":
                self._send(404, {"ok": False, "error": "not found"})
                return
            try:
                n = int(self.headers.get("content-length") or "0")
                payload = json.loads(self.rfile.read(n).decode() or "{}")
                result = loop.run_until_complete(DAEMON.handle(payload))
                self._send(200, result)
            except Exception as e:
                self._send(200, {"ok": False, "error": str(e)})

    httpd = HTTPServer(("127.0.0.1", args.port), Handler)
    httpd.timeout = 0.2
    try:
        while not STOP_REQUESTED:
            httpd.handle_request()
    finally:
        httpd.server_close()

async def run(p):
    # Client path: ensure a daemon exists and forward one action.
    action = (p.get("action") or "").strip()
    port = read_port()
    if action == "stop":
        if port_alive(port):
            return post_json(port, p)
        return do_stop()

    requested_browser = (p.get("browser") or read_state().get("browser") or "chromium").strip().lower()
    if requested_browser not in SUPPORTED_BROWSERS:
        return {"ok": False, "error": "browser must be 'chromium' or 'firefox'"}
    state = read_state()
    if port_alive(port):
        running = state.get("browser") or "chromium"
        if running != requested_browser:
            return {
                "ok": False,
                "error": "browser daemon is running %s; call stop before starting %s" % (running, requested_browser),
            }
    else:
        # Clean up stale daemon/CDP state before binding the default port. This
        # also handles upgrades from the older Chromium CDP implementation.
        do_stop()
        launch_daemon(requested_browser, False, port)
    return post_json(port, p)

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--server":
        run_server(sys.argv[1:])
        return

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
    local runner = ctx.config_dir .. "/_browser_daemon_" .. RUNNER_HASH .. ".py"
    if not ctx.fs.is_file(runner) then
        local ok, err = pcall(ctx.write_file, runner, PYTHON_SCRIPT)
        if not ok then
            return "ERROR: cannot install browser runner at " .. runner .. ": " .. tostring(err)
        end
    end

    local payload = b64encode(cjson.encode({
        action = action,
        browser = type(params.browser) == "string" and params.browser or nil,
        url = type(params.url) == "string" and params.url or nil,
        selector = type(params.selector) == "string" and params.selector or nil,
        ref = type(params.ref) == "string" and params.ref or nil,
        target = type(params.target) == "string" and params.target or nil,
        text = type(params.text) == "string" and params.text or nil,
        key = type(params.key) == "string" and params.key or nil,
        value = type(params.value) == "string" and params.value or nil,
        js = type(params.js) == "string" and params.js or nil,
        path = type(params.path) == "string" and params.path or nil,
        direction = type(params.direction) == "string" and params.direction or nil,
        amount = tonumber(params.amount) or nil,
        enter = params.enter and true or false,
        full_page = params.full_page and true or false,
        headless = false,
        max_chars = tonumber(params.max_chars) or nil,
        max_elements = tonumber(params.max_elements) or nil,
        max_targets = tonumber(params.max_targets) or nil,
        timeout_ms = tonumber(params.timeout_ms) or nil,
    }))

    local cmd = "ANONYMIZED_TELEMETRY=false uv run --no-project --with playwright"
        .. " -- python '" .. runner .. "' '" .. payload .. "'"

    -- First run downloads Playwright's selected browser (slow); steady-state verbs are
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
    description = [[Drive a persistent browser through a small observe/target remote-control API. Use this for tasks where the user asks you to browse, use a website, shop, order, log in, inspect a live page, or interact with dynamic web UI. YOU are the loop: call open, then observe, then act on target IDs, then observe again. The browser stays open and logged-in between calls (cookies and sessions persist), so a later call continues where the previous one left off.

Normal flow:
1. open a URL.
2. observe the page. The result contains visible text and `targets`, each with an `id`, kind, label, state, and bounding box.
3. Use `target=<id>` for click/type/select/check/uncheck. Do not invent CSS selectors.
4. observe again after every action.

When working on an active browser task, keep using browser actions for page state and interaction. Do not fall back to shell/curl/grep/Python to scrape the same page unless the user explicitly asks for shell-level inspection or the browser tool returns a blocking error. For page internals, use browser eval; for visible state, use observe. Screenshots exist only for debugging and should not be the default path.

Pick an `action`:
- open        — navigate to `url` (https:// assumed if no scheme) and return an observation.
- observe     — return bounded visible text plus target IDs for visible links/buttons/inputs/selects.
- click       — click `target` from observe.
- type        — type/fill `target` with `text`; pass enter=true to submit.
- select      — choose `value` in a select `target`.
- check/uncheck — set a checkbox/radio target.
- press       — send a single key (`key`, e.g. "Enter", "PageDown").
- scroll      — scroll up/down by `amount` pixels, then observe.
- wait_for    — wait until visible page text contains `text`.
- screenshot  — save a PNG to `path` (default data/browser/shot.png) and returns `read_file_path`; call read_file with that exact path to view it. full_page=true for the whole scroll height.
- eval        — run JavaScript (`js`) in the page and return its value.
- tabs        — list open tabs (url + title).
- current     — report the active tab's url and title.
- back        — go back one entry in history.
- stop        — close the browser and end the session.

The browser auto-starts on the first action and is always headful/visible so you can watch it and solve captchas/logins in the window. Headless mode is intentionally disabled; any supplied headless value is ignored. Use browser="chromium" or browser="firefox" on the first call (default chromium); call stop before switching. First ever run downloads the selected Playwright browser and is slow; after that, actions are fast.

Each call returns JSON: ok plus action-specific fields (url, title, text, targets, value, path, …) or an error. Target IDs are refreshed by each observation; if a target is unknown, call observe again. For multi-step jobs, observe between actions and keep the host in the loop for anything ambiguous.]],
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "open", "observe", "read", "scrape", "click", "type", "select", "check", "uncheck", "press", "scroll", "wait_for", "screenshot", "eval", "tabs", "current", "current_url", "back", "stop" },
                description = "Drive a persistent browser one step at a time: open, observe, click target IDs, type, select, scroll, wait, eval, and more.",
            },
            browser = {
                type = "string",
                enum = { "chromium", "firefox" },
                description = "Browser engine to start on cold start (default chromium). Call stop before switching engines.",
            },
            url = { type = "string", description = "URL for `open` (scheme optional)." },
            target = { type = "string", description = "Target id from observe, e.g. t03. Use this for click/type/select/check/uncheck." },
            selector = { type = "string", description = "Advanced fallback CSS/Playwright selector. Prefer target ids from observe." },
            ref = { type = "string", description = "Backward-compatible alias for target." },
            text = { type = "string", description = "Text to type (for `type`), or the key name (for `press`)." },
            key = { type = "string", description = "Key name for `press`, e.g. Enter, Escape, PageDown." },
            value = { type = "string", description = "Option value for `select`." },
            direction = { type = "string", enum = { "up", "down" }, description = "Direction for `scroll`." },
            amount = { type = "number", description = "Pixels for `scroll` (default 700)." },
            enter = { type = "boolean", description = "For `type`: press Enter after filling (submit)." },
            js = { type = "string", description = "JavaScript to run for `eval`." },
            path = { type = "string", description = "Output file for `screenshot`." },
            full_page = { type = "boolean", description = "For `screenshot`: capture the full scroll height." },
            max_chars = { type = "number", description = "For open/observe/read/scrape/eval: max visible-text/result characters returned (default 4000)." },
            max_targets = { type = "number", description = "For open/observe/read/scrape: max visible targets returned (default 60)." },
            max_elements = { type = "number", description = "Deprecated alias for max_targets." },
            timeout_ms = { type = "number", description = "Per-action timeout in ms (default 30000)." },
        },
        required = { "action" },
        additionalProperties = false,
    },
    safety = "danger",
    -- Eager: show the row as the action starts (a cold-start launch takes a few
    -- seconds), not only when it returns.
    display = { show = true, args = { "action", "browser", "url", "target", "text" }, eager = true },
    execute = execute,
})
