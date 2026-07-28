local PYTHON_SCRIPT = [=[
import base64, contextlib, fcntl, json, os, re, shlex, subprocess, sys
from collections import deque
from pathlib import Path

MAX_PROMPT = 16384
MAX_PATH = 4096
MAX_TAIL = 1000
CONTROL = re.compile(r"[\x00-\x1f\x7f]")

def env(name, default=""):
    return os.environ.get(name, default)

def valid_text(value, maximum, allow_empty=False):
    return (isinstance(value, str) and (allow_empty or bool(value)) and
            len(value) <= maximum and not CONTROL.search(value))

def require_text(value, label, maximum, allow_empty=False):
    if not valid_text(value, maximum, allow_empty):
        fail(f"{label} must be {maximum} characters or fewer and contain no control characters")
    return value

def config_dir():
    value = env("TOOL_CONFIG_DIR")
    if not value:
        fail("Bone config directory is unavailable")
    require_text(value, "Bone config directory", MAX_PATH)
    resolved = str(Path(value).resolve())
    require_text(resolved, "resolved Bone config directory", MAX_PATH)
    return Path(resolved)

@contextlib.contextmanager
def cron_lock():
    path = config_dir() / "runs" / ".cron.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield

def find_bone():
    explicit = env("BONE_BIN")
    if explicit and os.access(explicit, os.X_OK):
        resolved = str(Path(explicit).resolve())
        require_text(resolved, "bone binary path", MAX_PATH)
        return resolved
    for part in env("PATH").split(os.pathsep):
        candidate = Path(part) / "bone"
        if os.access(candidate, os.X_OK):
            resolved = str(candidate.resolve())
            require_text(resolved, "bone binary path", MAX_PATH)
            return resolved
    print("bone binary not found. Set BONE_BIN=/path/to/bone", file=sys.stderr)
    sys.exit(127)

def validate_name(name):
    if not valid_text(name, 128) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        fail("job name must be 128 characters or fewer and contain only letters, numbers, '-' and '_'")

def parse_time(value):
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", value or "")
    if not m: fail("time must be HH:MM")
    hour, minute = int(m.group(1)), int(m.group(2))
    if hour > 23 or minute > 59: fail("time must be between 00:00 and 23:59")
    return hour, minute

def validate_approval(value):
    if value in ("safe", "read_only"):
        return "safe"
    if value == "danger":
        return value
    fail("approval must be safe or danger")

def fail(message, code=2):
    print(message, file=sys.stderr)
    sys.exit(code)

def cron_missing():
    fail("crontab not found. Install cronie or cron.", 127)

def current_crontab():
    try:
        p = subprocess.run(["crontab", "-l"], text=True, capture_output=True)
    except FileNotFoundError:
        cron_missing()
    if p.returncode == 0: return p.stdout
    if "no crontab" in p.stderr.lower(): return ""
    fail(p.stderr.strip() or f"crontab -l exited with {p.returncode}", p.returncode)

def write_crontab(content):
    try:
        p = subprocess.run(["crontab", "-"], input=content, text=True, capture_output=True)
    except FileNotFoundError:
        cron_missing()
    if p.returncode != 0:
        fail(p.stderr.strip() or f"crontab exited with {p.returncode}", p.returncode)

def encode_metadata(job):
    raw = json.dumps(job, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def decode_metadata(value):
    try:
        padded = value + "=" * ((4 - len(value) % 4) % 4)
        decoded = json.loads(base64.urlsafe_b64decode(padded.encode()))
    except Exception:
        return None
    if not isinstance(decoded, dict):
        return None
    limits = {"name": 128, "approval": 16, "cwd": MAX_PATH, "prompt": MAX_PROMPT,
              "log_path": MAX_PATH}
    if any(not valid_text(decoded.get(key), limit, allow_empty=(key != "name"))
           for key, limit in limits.items()):
        return None
    if not re.fullmatch(r"[A-Za-z0-9_-]+", decoded["name"]):
        return None
    if decoded["approval"] not in ("", "safe", "read_only", "danger"):
        return None
    if "config_dir" in decoded and not valid_text(decoded["config_dir"], MAX_PATH, allow_empty=True):
        return None
    return decoded

def parse_cron_line(line):
    marker = "# BONE:"
    if marker not in line: return None
    body, encoded = line.rsplit(marker, 1)
    fields = body.split()
    if len(fields) < 5 or fields[2:5] != ["*", "*", "*"]: return None
    try:
        minute, hour = int(fields[0]), int(fields[1])
    except ValueError: return None
    if not (0 <= minute <= 59 and 0 <= hour <= 23): return None
    meta = decode_metadata(encoded.strip())
    if meta is None:
        name = encoded.strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", name): return None
        meta = {"name": name, "approval": "", "cwd": "", "prompt": "", "log_path": ""}
    meta["minute"] = minute
    meta["hour"] = hour
    return meta

RUNNER = "import base64,os,sys; bone=sys.argv[1]; prompt=base64.urlsafe_b64decode(sys.argv[3]).decode(); os.execv(bone,[bone,'run','--approval',sys.argv[2],'--prompt',prompt])"

def build_cron_line(job):
    prompt = base64.urlsafe_b64encode(job["prompt"].encode()).decode()
    args = [job["python_bin"], "-c", RUNNER, job["bone_bin"], job["approval"], prompt]
    command = "cd " + shlex.quote(job["cwd"]) + " && BONE_DIR=" + shlex.quote(job["config_dir"])
    command += " " + " ".join(shlex.quote(a) for a in args)
    command += " >> " + shlex.quote(job["log_path"]) + " 2>&1"
    # cron translates unescaped '%' before invoking the shell, even inside quotes.
    command = command.replace("%", r"\%")
    meta = {k: job[k] for k in ("name", "approval", "cwd", "prompt", "log_path", "config_dir")}
    return f'{job["minute"]} {job["hour"]} * * * {command} # BONE:{encode_metadata(meta)}'

def list_jobs():
    jobs = [j for j in (parse_cron_line(line) for line in current_crontab().splitlines()) if j]
    if not jobs:
        print("No bone cron jobs.")
        return
    print("NAME\tTIME\tAPPROVAL\tCWD\tPROMPT")
    for j in jobs:
        print(f'{j.get("name", "")}\t{j["hour"]:02d}:{j["minute"]:02d}\t{j.get("approval", "")}\t{j.get("cwd", "")}\t{j.get("prompt", "")}')

def add_job():
    name, time, prompt = env("TOOL_NAME"), env("TOOL_TIME"), env("TOOL_PROMPT")
    approval = validate_approval(env("TOOL_APPROVAL", "safe") or "safe")
    if not name or not time or not prompt:
        fail("Usage: cron add requires name, time, and prompt.")
    validate_name(name)
    require_text(prompt, "prompt", MAX_PROMPT)
    hour, minute = parse_time(time)
    cwd_value = env("TOOL_CWD") or os.getcwd()
    require_text(cwd_value, "working directory", MAX_PATH)
    cwd_path = Path(cwd_value).resolve()
    require_text(str(cwd_path), "resolved working directory", MAX_PATH)
    if not cwd_path.is_dir():
        fail(f"working directory does not exist or is not a directory: {cwd_path}")
    root = config_dir()
    log_dir = root / "runs"
    log_dir.mkdir(parents=True, exist_ok=True)
    python_bin = str(Path(sys.executable).resolve())
    require_text(python_bin, "python binary path", MAX_PATH)
    job = {"name": name, "hour": hour, "minute": minute, "approval": approval,
           "cwd": str(cwd_path), "prompt": prompt, "log_path": str(log_dir / f"{name}.log"),
           "config_dir": str(root), "bone_bin": find_bone(), "python_bin": python_bin}
    with cron_lock():
        existing = current_crontab().splitlines()
        kept = []
        replaced = False
        for line in existing:
            parsed = parse_cron_line(line)
            legacy_tag = line.rstrip().endswith(f"# BONE:{name}")
            if (parsed and parsed.get("name") == name) or legacy_tag:
                replaced = True
                continue
            kept.append(line)
        kept.append(build_cron_line(job))
        write_crontab("\n".join(kept) + "\n")
    verb = "Updated" if replaced else "Added"
    print(f"{verb} cron job {name}.")

def remove_job():
    name = env("TOOL_NAME")
    if not name: fail("Usage: cron remove requires name.")
    validate_name(name)
    removed = False
    with cron_lock():
        kept = []
        for line in current_crontab().splitlines():
            parsed = parse_cron_line(line)
            legacy_tag = line.rstrip().endswith(f"# BONE:{name}")
            if (parsed and parsed.get("name") == name) or legacy_tag: removed = True
            else: kept.append(line)
        if removed:
            write_crontab(("\n".join(kept) + "\n") if kept else "")
    print(f"Removed cron job {name}." if removed else f"No cron job named {name}.")

def show_logs():
    name = env("TOOL_NAME")
    if not name: fail("Usage: cron logs requires name.")
    validate_name(name)
    path = config_dir() / "runs" / f"{name}.log"
    for job in (parse_cron_line(line) for line in current_crontab().splitlines()):
        if job and job.get("name") == name and job.get("log_path"):
            path = Path(job["log_path"])
            break
    tail = env("TOOL_TAIL") or "100"
    try: n = int(tail)
    except ValueError: fail(f"tail must be an integer between 1 and {MAX_TAIL}")
    if not 1 <= n <= MAX_TAIL:
        fail(f"tail must be an integer between 1 and {MAX_TAIL}")
    try:
        with path.open(encoding="utf-8") as handle:
            lines = deque((line.rstrip("\r\n") for line in handle), maxlen=n)
    except (OSError, UnicodeError) as e:
        fail(f"failed to read {path}: {e}", 1)
    print("\n".join(lines))

def help_text():
    print("""Manage Bone scheduled jobs.

  Examples:
    cron(action=list)
    cron(action=add, name=daily-clean, time=09:00, approval=danger, prompt=/clean src/main.rs)
    cron(action=remove, name=daily-clean)
    cron(action=logs, name=daily-clean, tail=100)""")

action = env("TOOL_ACTION")
if action == "list": list_jobs()
elif action == "add": add_job()
elif action in ("remove", "rm"): remove_job()
elif action == "logs": show_logs()
elif action in ("help", "--help", "-h", ""): help_text()
else: fail(f"Unknown cron action: {action}")
]=]

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function execute(params, ctx)
    local values = {
        TOOL_ACTION = params.action or "",
        TOOL_NAME = params.name or "",
        TOOL_TIME = params.time or "",
        TOOL_APPROVAL = params.approval or "safe",
        TOOL_PROMPT = params.prompt or "",
        TOOL_CWD = params.cwd or "",
        TOOL_TAIL = params.tail or "",
        TOOL_CONFIG_DIR = ctx.config_dir or "",
    }
    local names = {
        "TOOL_ACTION", "TOOL_NAME", "TOOL_TIME", "TOOL_APPROVAL",
        "TOOL_PROMPT", "TOOL_CWD", "TOOL_TAIL", "TOOL_CONFIG_DIR",
    }
    local assignments = {}
    for _, name in ipairs(names) do
        assignments[#assignments + 1] = name .. "=" .. shell_quote(values[name])
    end
    local cmd = table.concat(assignments, " ") .. " python3 -c " .. shell_quote(PYTHON_SCRIPT)
    local result = ctx.shell(cmd, { timeout_ms = 300000 })
    if result.exit_code ~= 0 then
        local message = result.stderr
        if not message or message == "" then message = result.stdout end
        if not message or message == "" then message = "cron command exited with " .. tostring(result.exit_code) end
        return "ERROR: " .. message
    end
    return result.stdout or ""
end

bone.tool.register({
    name = "cron",
    description = "Manage Bone scheduled jobs for the user (daily HH:MM schedules). Use this when the user asks to schedule, list, remove, or inspect recurring Bone tasks. Actions: add (requires name, time, prompt), list, remove (requires name), logs (requires name, optional tail). Examples: cron(action=list); cron(action=add, name=daily-clean, time=09:00, approval=danger, prompt=/clean src/main.rs); cron(action=remove, name=daily-clean); cron(action=logs, name=daily-clean, tail=100).",
    parameters = {
        type = "object",
        properties = {
            action = {
                type = "string",
                enum = { "add", "list", "remove", "logs", "help" },
                description = "Action to perform.",
            },
            name = {
                type = "string",
                description = "Job name for add/remove/logs. Use letters, numbers, '-' or '_'.",
            },
            time = {
                type = "string",
                description = "Daily run time in HH:MM 24-hour local time, required for add.",
            },
            approval = {
                type = "string",
                enum = { "safe", "read_only", "danger" },
                description = "Approval mode for add. Defaults to safe; read_only is accepted as a legacy alias for safe.",
            },
            prompt = {
                type = "string",
                description = "Prompt or command invocation for add.",
            },
            cwd = {
                type = "string",
                description = "Working directory for add. Defaults to current directory.",
            },
            tail = {
                type = "integer",
                minimum = 1,
                maximum = 1000,
                description = "Number of log lines for logs. Defaults to 100.",
            },
        },
        required = { "action" },
        additionalProperties = false,
    },
    safety = "danger",
    execute = execute,
})
