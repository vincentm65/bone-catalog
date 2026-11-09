-- The ssh plugin's model: saved profiles, checking them, testing a host and
-- opening a window on it (ssh_window.py does the ssh side).
local M = {}

M.windows = package.config:sub(1, 1) == "\\"
M.home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
local config = os.getenv("BONE_CONFIG_DIR")
if not config or config == "" then config = M.home .. "/.bone" end
M.script = config .. "/plugins/ssh/ssh_window.py"

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end
M.trim = trim

local function expand(path)
  path = trim(path)
  if path:sub(1, 1) == "~" then path = M.home .. path:sub(2) end
  return path
end
M.expand = expand

local function exists(path)
  local f = io.open(path)
  if f then f:close() return true end
  return false
end

-- ── Profiles ─────────────────────────────────────────────────────────────
-- { name, host, user, port, identity, dir, opts, last_used, test }, where
-- test = { ok, text, at } is the last connection test. They live in a file of
-- their own, read each time and written on each change: every bone window
-- (the ones /ssh opens too) loads this plugin, and plugin state, kept per
-- window and saved when it quits, would let one window's copy overwrite
-- another's.

M.file = config .. "/ssh-profiles.json"

local function state()
  local f = io.open(M.file)
  if not f then
    -- Where 3.0.0 kept them.
    local ok, st = pcall(bone.plugin.state, "ssh")
    return { profiles = ok and type(st) == "table" and st.profiles or {} }
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(bone.json.decode, text)
  if not ok or type(data) ~= "table" then return { profiles = {} } end
  data.profiles = data.profiles or {}
  return data
end

local function write(data)
  local tmp = M.file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return bone.notify("ssh: cannot write " .. M.file, "error") end
  f:write(bone.json.encode(data))
  f:close()
  os.remove(M.file) -- Windows' rename does not replace a file
  os.rename(tmp, M.file)
end
function M.profiles()
  local list = {}
  for _, p in ipairs(state().profiles) do list[#list + 1] = p end
  -- The ones used last first; never used ones by name.
  table.sort(list, function(a, b)
    if (a.last_used or 0) ~= (b.last_used or 0) then return (a.last_used or 0) > (b.last_used or 0) end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

function M.find(name)
  for _, p in ipairs(state().profiles) do
    if p.name == name then return p end
  end
end

--- Save `p`, replacing the profile called `old` (its name before editing).
function M.put(p, old)
  local data = state()
  for i, q in ipairs(data.profiles) do
    if q.name == (old or p.name) then data.profiles[i] = p; return write(data) end
  end
  data.profiles[#data.profiles + 1] = p
  write(data)
end

function M.remove(name)
  local data = state()
  for i, q in ipairs(data.profiles) do
    if q.name == name then table.remove(data.profiles, i); return write(data) end
  end
end

--- Set `fields` on profile `p` and save them to its saved copy.
function M.touch(p, fields)
  for k, v in pairs(fields) do p[k] = v end
  local data = state()
  for _, q in ipairs(data.profiles) do
    if q.name == p.name then
      for k, v in pairs(fields) do q[k] = v end
      return write(data)
    end
  end
end
--- `user@host:port`, as a person writes it.
function M.target(p)
  local s = trim(p.host)
  if trim(p.user) ~= "" then s = trim(p.user) .. "@" .. s end
  if trim(p.port) ~= "" then s = s .. ":" .. trim(p.port) end
  return s
end

-- ── The form's fields ────────────────────────────────────────────────────

M.FIELDS = {
  { key = "name", label = "Name", required = true, placeholder = "e.g. work desktop",
    hint = "What /ssh and the window title call it" },
  { key = "host", label = "Host", required = true, placeholder = "devbox, devbox.tailnet.ts.net or 192.168.1.20",
    hint = "A host name, an IP address or a Host from ~/.ssh/config; user@host fills in User" },
  { key = "user", label = "User", placeholder = "ssh's default",
    hint = "The login name on that machine (spaces are fine)" },
  { key = "port", label = "Port", placeholder = "22" },
  { key = "identity", label = "Key file", placeholder = "ssh's default keys and agent",
    hint = "The private key to log in with, e.g. ~/.ssh/id_ed25519" },
  { key = "dir", label = "Start directory", placeholder = "the home directory there",
    hint = "Where new chats start on that machine" },
  { key = "opts", label = "More ssh options", placeholder = "e.g. -o ProxyJump=bastion",
    hint = "Added to every ssh command" },
}

--- What is wrong with each field of `form` ({ key = message }), or nil.
--- `old` is the profile's name before editing.
function M.check(form, old)
  local errors = {}
  local name, host = trim(form.name), trim(form.host)
  if name == "" then
    errors.name = "Required"
  elseif name ~= old and M.find(name) then
    errors.name = "Another profile has this name"
  end
  if host == "" then
    errors.host = "Required"
  elseif host:find("%s") then
    errors.host = "No spaces in a host name"
  end
  local port = trim(form.port)
  if port ~= "" then
    local n = tonumber(port)
    if not n or n ~= math.floor(n) or n < 1 or n > 65535 then errors.port = "A number from 1 to 65535" end
  end
  local key = trim(form.identity)
  if key ~= "" and not exists(expand(key)) then errors.identity = "No such file on this machine" end
  return next(errors) and errors or nil
end

--- A profile from a form that passed `check`.
function M.from_form(form, base)
  local p = {}
  for k, v in pairs(base or {}) do p[k] = v end
  for _, f in ipairs(M.FIELDS) do p[f.key] = trim(form[f.key]) end
  return p
end

-- ── ~/.ssh/config ────────────────────────────────────────────────────────

--- Host aliases from ~/.ssh/config: { name, hostname, user, port, identity }.
function M.config_hosts()
  local out, current = {}, {}
  local f = io.open(M.home .. "/.ssh/config")
  if not f then return out end
  for line in f:lines() do
    local key, value = line:match("^%s*(%S+)%s+(.-)%s*$")
    key = key and key:lower()
    if key == "host" then
      current = {}
      for name in value:gmatch("%S+") do
        if not name:find("[*?!]") then
          local h = { name = name }
          out[#out + 1] = h
          current[#current + 1] = h
        end
      end
    elseif key and value and value ~= "" then
      value = value:gsub('^"(.*)"$', "%1")
      for _, h in ipairs(current) do
        if key == "hostname" then h.hostname = value
        elseif key == "user" then h.user = value
        elseif key == "port" then h.port = value
        elseif key == "identityfile" then h.identity = value end
      end
    end
  end
  f:close()
  return out
end

--- A key this machine logs in with, to put on the other one: path, text.
function M.public_key()
  for _, name in ipairs({ "id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub" }) do
    local path = M.home .. "/.ssh/" .. name
    local f = io.open(path)
    if f then
      local text = trim(f:read("*a"))
      f:close()
      return path, text
    end
  end
end

-- ── Commands ─────────────────────────────────────────────────────────────

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function ps_quote(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end
-- One argument as Windows' CreateProcess reads it.
local function win_arg(s)
  s = tostring(s)
  if s ~= "" and not s:find('[%s"]') then return s end
  return '"' .. s:gsub('(\\*)"', '%1%1\\"'):gsub("(\\+)$", "%1%1") .. '"'
end

--- ssh_window.py's arguments for profile `p`.
local function args(p)
  local a = {}
  local function opt(flag, v)
    if trim(v) ~= "" then a[#a + 1] = flag; a[#a + 1] = trim(v) end
  end
  opt("--user", p.user)
  opt("--port", p.port)
  opt("--identity", p.identity and expand(p.identity))
  opt("--ssh-opts", p.opts)
  opt("--cwd", p.dir)
  opt("--name", p.name)
  a[#a + 1] = trim(p.host)
  return a
end

local function python() return M.windows and "python" or "python3" end

--- Check `p`'s host: done({ ok, kind, home, bone } or { ok = false, error }).
function M.probe(p, done)
  local a = args(p)
  table.insert(a, 1, "--probe")
  local cmd
  if M.windows then
    local parts = { "&", ps_quote(python()), ps_quote(M.script) }
    for _, v in ipairs(a) do parts[#parts + 1] = ps_quote(v) end
    cmd = table.concat(parts, " ")
  else
    local parts = { python(), "-B", sh_quote(M.script) }
    for _, v in ipairs(a) do parts[#parts + 1] = sh_quote(v) end
    cmd = table.concat(parts, " ")
  end
  bone.system(cmd, { timeout = 60000 }, function(r, err)
    local out = r and r.stdout and r.stdout:match("(%b{})%s*$")
    local ok, res = pcall(bone.json.decode, out or "")
    if ok and type(res) == "table" then return done(res) end
    local why = err or (r and r.timed_out and "timed out")
      or (r and trim(r.stderr) ~= "" and trim(r.stderr):match("([^\n]+)$"))
      or ("cannot run " .. python())
    done({ ok = false, error = why })
  end)
end

--- How to fix what a test or a launch said (nil when there is nothing to add).
function M.advice(err)
  err = err or ""
  if err:find("Permission denied") then
    return "The other machine does not accept this machine's key. Add the public key below to its "
      .. "~/.ssh/authorized_keys (on Windows, for an administrator: C:\\ProgramData\\ssh\\administrators_authorized_keys).", true
  elseif err:find("Could not resolve") then
    return "Check the host name. A Tailscale name needs MagicDNS, or use its 100.x address."
  elseif err:find("timed out") or err:find("did not answer") or err:find("No route") then
    return "The machine is off, asleep or out of reach, or a firewall blocks ssh's port."
  elseif err:find("refused") then
    return "Nothing listens for ssh there. On Windows, start the OpenSSH Server service."
  elseif err:find("Host key verification failed") then
    return "This machine has never seen that host's key. Run ssh to it once in a terminal and accept it."
  elseif err:find("REMOTE HOST IDENTIFICATION HAS CHANGED") then
    return "That host's key changed. If you expected it, remove the old one with ssh-keygen -R <host>."
  elseif err:find("no bone") then
    return "Install bone there: npm install -g bone-agent."
  elseif err:find("cannot run python") then
    return M.windows and "Install Python 3 so that `python` runs from PowerShell."
      or "Install python3 on this machine."
  end
end

--- Open a window on `p`'s machine. done(err) once it is started (err nil)
--- or could not be; a failure after that is reported by notification.
function M.launch(p, done)
  local f = io.open(M.script)
  if not f then return done(M.script .. " is missing") end
  f:close()
  local tmpdir = M.windows and (os.getenv("TEMP") or M.home) or "/tmp"
  local sep = M.windows and "\\" or "/"
  local stamp = os.time() .. "-" .. math.random(100000, 999999)
  -- The launcher writes how starting went to `status`; stderr goes to `log`.
  local status = tmpdir .. sep .. "bone-ssh-" .. stamp .. ".json"
  local log = tmpdir .. sep .. "bone-ssh-" .. stamp .. ".log"
  local a = args(p)
  table.insert(a, 1, status)
  table.insert(a, 1, "--status")
  local cmd
  if M.windows then
    -- bone.system runs PowerShell; its parent is this bone.
    local parts = { win_arg(M.script), "--bone", "@@BONE@@" }
    for _, v in ipairs(a) do parts[#parts + 1] = win_arg(v) end
    cmd = "$p = (Get-CimInstance Win32_Process -Filter \"ProcessId=$PID\").ParentProcessId; "
      .. "$exe = (Get-Process -Id $p).Path; "
      .. "$a = " .. ps_quote(table.concat(parts, " ")) .. ".Replace('@@BONE@@', '\"' + $exe + '\"'); "
      .. "Start-Process -WindowStyle Hidden -FilePath python -ArgumentList $a "
      .. "-RedirectStandardError " .. ps_quote(log)
  else
    -- $PPID is this bone, so the new window runs the same build; setsid -f
    -- detaches it, so this window can close.
    local parts = { "setsid -f python3 -B", sh_quote(M.script), '--bone "$(readlink -f /proc/$PPID/exe)"' }
    for _, v in ipairs(a) do parts[#parts + 1] = sh_quote(v) end
    cmd = table.concat(parts, " ") .. " >" .. sh_quote(log) .. " 2>&1 </dev/null"
  end
  bone.system(cmd, {}, function(r, err)
    if not r or r.code ~= 0 then
      return done(err or (r and trim(r.stderr)) or "cannot start the launcher")
    end
    done(nil)
    -- Look every 2 s, for up to 2 minutes, for the window being up or why
    -- not; the log's last line is the last resort.
    local tries = 0
    local function check()
      tries = tries + 1
      local f = io.open(status)
      local text = f and f:read("*a")
      if f then f:close() end
      local ok, res = pcall(bone.json.decode, text or "")
      if ok and type(res) == "table" then
        os.remove(status)
        os.remove(log)
        if res.ok then return end
        local hint = M.advice(res.error)
        return bone.notify("ssh " .. p.name .. ": " .. tostring(res.error) .. (hint and ("\n" .. hint) or ""), "error")
      end
      if tries < 60 then return bone.defer(2000, check) end
      local lf = io.open(log)
      local last = lf and (lf:read("*a") or ""):match("([^\r\n]+)[\r\n]*$")
      if lf then lf:close() end
      bone.notify("ssh " .. p.name .. ": no window after 2 minutes" .. (last and (": " .. last) or ""), "error")
    end
    bone.defer(1000, check)
  end)
end
return M
