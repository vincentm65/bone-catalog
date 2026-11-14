-- The core half of the files plugin: the things the desktop half cannot do
-- by itself — reading a PDF's text, handing a file to the desktop's own
-- application, keeping score of the files this session's agent changed, and
-- saying what a file holds on disk right now (which is how the editor can
-- tell that the file moved under it).

local pdf = require("files.pdf")
local platform = require("files.platform")

-- ---- helpers --------------------------------------------------------------

--- A single quote around a path, for the shell.
local function quoted(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- Run a command: its result, or nil and the reason.
local function run(command, timeout)
  local r = bone.system(command, { timeout = timeout })
  if not r then return nil, "the command did not run" end
  if r.timed_out then return nil, "the command took too long" end
  return r
end

--- `path` as an absolute one, against the session's own directory.
--- Forward slashes on Windows too, as the desktop half writes its paths.
local function absolute(path, cwd)
  path = platform.norm(tostring(path or ""):match("^%s*(.-)%s*$"))
  if path == "" then return nil end
  if path == "~" then return platform.home() end
  if path:sub(1, 2) == "~/" then return platform.home() .. path:sub(2) end
  if platform.is_absolute(path) then return path end
  cwd = platform.norm(tostring(cwd or ""))
  if cwd == "" then return path end
  return (cwd:sub(-1) == "/" and cwd or cwd .. "/") .. path
end

-- ---- what the agent changed -----------------------------------------------

-- Only the tools that write. `shell` can change anything, but its arguments
-- name no path, so guessing there would mark more files than it changed.
local WRITE_TOOLS = { edit_file = true, write_file = true }
local MARK_LIMIT, SESSION_LIMIT = 60, 12

-- session_id -> { path -> { path, tool, at, writes } }, saved after each turn.
local marks = bone.state.load("files")
local pending = {}  -- a tool call's id -> { path, tool }, until it finishes

local function count(list)
  local n = 0
  for _ in pairs(list) do n = n + 1 end
  return n
end

local function remember(session_id, path, tool)
  if not session_id then return end
  local by_path = marks[session_id]
  if not by_path then
    by_path = {}
    marks[session_id] = by_path
  end
  local found = by_path[path]
  if found then
    found.at, found.tool = os.time(), tool
    found.writes = (found.writes or 1) + 1
  else
    by_path[path] = { path = path, tool = tool, at = os.time(), writes = 1 }
  end
  -- The recent changes are the useful ones: keep the list bounded.
  if count(by_path) > MARK_LIMIT then
    local oldest, at
    for p, m in pairs(by_path) do
      if not at or m.at < at then at, oldest = m.at, p end
    end
    if oldest then by_path[oldest] = nil end
  end
end

-- `tool_call` has the working directory and `tool_result` does not, so a
-- write is held here until it is known to have succeeded.
bone.hook("tool_call", function(ev)
  if not WRITE_TOOLS[ev.name] then return end
  local path = absolute(ev.arguments and ev.arguments.path, ev.cwd)
  if path and ev.id then pending[ev.id] = { path = path, tool = ev.name } end
end)

bone.hook("tool_result", function(ev)
  local held = ev.id and pending[ev.id]
  pending[ev.id] = nil
  if not held or ev.is_error then return end
  remember(ev.session_id, held.path, held.tool)
end)

bone.hook("turn_end", function()
  local sessions = {}
  for id in pairs(marks) do sessions[#sessions + 1] = id end
  table.sort(sessions, function(a, b)
    local function newest(id)
      local at = 0
      for _, m in pairs(marks[id]) do at = math.max(at, tonumber(m.at) or 0) end
      return at
    end
    return newest(a) > newest(b)
  end)
  for i = SESSION_LIMIT + 1, #sessions do marks[sessions[i]] = nil end
  pcall(bone.state.save, "files", marks)
end)

--- What this session changed, newest first. The desktop half marks those
--- files in the tree and warns before it overwrites one.
bone.rpc.register("files.touched", function(args, ctx)
  local by_path = (ctx and marks[ctx.session_id]) or {}
  local out = {}
  for path, m in pairs(by_path) do
    out[#out + 1] = { path = path, tool = m.tool, at = m.at, writes = m.writes or 1 }
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.path < b.path
  end)
  return { paths = out, cwd = (ctx and ctx.cwd) or "" }
end)

--- What a file holds right now: its hash and size, so a caller can tell
--- whether it is still what it read.
bone.rpc.register("files.hash", function(args)
  local path = tostring(args.path or "")
  if path == "" then return { error = "No file was named." } end
  local file, err = io.open(path, "rb")
  if not file then return { error = "There is no such file: " .. path } end
  local content = file:read("*a")
  file:close()
  if content == nil then return { error = "The file could not be read: " .. path } end
  return { hash = bone.sha256(content), size = #content }
end)

-- ---- reading a PDF, and opening a file with the desktop's own app --------

--- The text of a PDF, read here: the file's objects, its streams and the
--- text they hold.
bone.rpc.register("files.pdftext", function(args, ctx)
  local text, err = pdf.text(tostring(args.path or ""))
  if not text then
    return { error = "The PDF could not be read: " .. tostring(err or "it is not a PDF") }
  end
  return { text = text }
end)

--- Open a file with the desktop's own app (the system's default one).
bone.rpc.register("files.open", function(args, ctx)
  local path = tostring(args.path or "")
  local file = io.open(path, "rb")
  if not file then
    return { error = "There is no such file: " .. path }
  end
  file:close()
  -- The app is started in the background and its output is kept away from
  -- ours: it may live much longer than the command that started it.
  -- `open` on macOS, xdg-open elsewhere.
  local opener = (jit and jit.os == "OSX") and "open" or "xdg-open"
  local r, err = run(
    opener .. " " .. quoted(path) .. " >/dev/null 2>&1 </dev/null &", 5000)
  if not r then return { error = err } end
  if r.code ~= 0 then
    local why = (r.stderr or ""):gsub("%s+$", "")
    return { error = "Could not open the file: " .. (why ~= "" and why or ("exit code " .. tostring(r.code))) }
  end
  return { opened = true }
end)

bone.health("files", function()
  local opener = (jit and jit.os == "OSX") and "open" or "xdg-open"
  local r, err = run("command -v " .. opener .. " >/dev/null 2>&1", 3000)
  if not r then return "warn", "could not check for " .. opener .. " (" .. tostring(err) .. ")" end
  if r.code ~= 0 then
    return "warn", opener .. " is not on PATH: opening a file with the desktop's own app will not work"
  end
  local ff = run("command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1", 3000)
  local video = (ff and ff.code == 0) and "ffmpeg is there for videos" or "no ffmpeg: a video offers to install or fetch it"
  return true, opener .. " is available · " .. video
end)

--- The agent writes the files it names so the panel can open them: under a
--- reply in the desktop app each one is a chip that does (files.link_files).
bone.hook("system", function(ev)
  local ok, on = pcall(bone.settings.get, "files.link_files")
  if ok and on == false then return nil end
  return { prompt = (ev.prompt or "") .. "\n\nWhen you mention a file of the project, write its path in backticks, "
    .. "relative to the working directory, with the line when it matters: `src/app.lua:42` or `src/app.lua:12-40`. "
    .. "The user can open it from there in their files panel." }
end)
