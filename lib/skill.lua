-- Shared, read-only skill resolver. GNU realpath is required for path guards.
local M = {}

local MAX_DIRS, MAX_SKILLS, MAX_INDEX, MAX_SKILL, MAX_REF = 1000, 100, 16 * 1024, 64 * 1024, 256 * 1024
local WORK = 8 * 1024 * 1024
local function normalize(path)
  path = tostring(path or ".")
  path = path:gsub("/+", "/")
  if #path > 1 then path = path:gsub("/+$", "") end
  return path == "" and "/" or path
end

local function join(a, b)
  return normalize(a):gsub("/$", "") .. "/" .. b
end

local function valid_name(s)
  return type(s) == "string" and #s <= 128
    and s:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

local function valid_file(s)
  if type(s) ~= "string" or s == "" or s:find("[%z\\]") or s:match("^/") then
    return false
  end
  for part in s:gmatch("[^/]+") do
    if part == "." or part == ".." then return false end
  end
  return true
end

function M.frontmatter(text)
  if type(text) ~= "string" then return nil, "SKILL.md is not text" end
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = raw:gsub("\r$", "") end
  if lines[1] ~= "---" then return nil, "missing YAML frontmatter" end
  local close
  for i = 2, #lines do if lines[i] == "---" then close = i; break end end
  if not close then return nil, "unterminated YAML frontmatter" end
  local out, seen = {}, {}
  for i = 2, close - 1 do
    local line = lines[i]
    if not line:match("^%s*$") and not line:match("^%s*#") then
      local key, value = line:match("^([%a][%w_-]*)%s*:%s*(.-)%s*$")
      if not key then
        return nil, "malformed frontmatter line " .. i
      end
      if seen[key] then
        return nil, "duplicate frontmatter key: " .. key
      end
      seen[key] = true
      if value:match("^[|>]") then
        return nil, "multiline frontmatter is unsupported"
      end
      local quote = value:sub(1, 1)
      if quote == '"' or quote == "'" then
        if #value < 2 or value:sub(-1) ~= quote then
          return nil, "malformed quoted frontmatter value"
        end
        value = value:sub(2, -2)
        if value:find(quote, 1, true) or value:find("[%z\r\n\\]") then
          return nil, "quoted escapes and internal quotes are unsupported"
        end
      elseif value:find("[%z\r\n]") or value:match("^[%[%]{}&*!@`]")
        or value:find(":%s") or value:find("%s#") or value:match("^#") then
        return nil, "unsupported plain scalar; use a simple quoted value"
      end
      if key == "name" or key == "description" then
        out[key] = value
      elseif key ~= "" then
        return nil, "unknown frontmatter key: " .. key
      end
    end
  end
  if not valid_name(out.name) then
    return nil, "frontmatter name is missing or invalid"
  end
  if not out.description or #out.description > 512 or out.description:find("[%c\r\n]") then
    return nil, "description is missing, too long, or contains control characters"
  end
  out._close = close
  return out
end

function M.strip_frontmatter(text)
  local fm = M.frontmatter(text)
  if not fm then return nil, "cannot strip invalid frontmatter" end
  local lines, n = {}, 0
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    local line = raw:gsub("\r$", "")
    n = n + 1
    if n > fm._close then lines[#lines + 1] = line end
  end
  return table.concat(lines, "\n"):gsub("\n$", "")
end

local function call(ctx, fn, ...)
  if not ctx or not ctx.fs or type(ctx.fs[fn]) ~= "function" then return nil, "filesystem API unavailable" end
  local ok, v = pcall(ctx.fs[fn], ...)
  if not ok then return nil, tostring(v) end
  return v
end
local function warn(ctx, diagnostics, msg)
  if msg == nil then msg, diagnostics = diagnostics, nil end
  msg = tostring(msg):sub(1, 512)
  local emit = true
  if diagnostics then
    if #diagnostics >= 10 then emit = false else diagnostics[#diagnostics + 1] = msg end
  end
  if emit and ctx and ctx.log and ctx.log.warn then pcall(ctx.log.warn, msg) end
end
local function guard(ctx, dir, file)
  if not ctx or type(ctx.exec) ~= "function" then return nil, "path guard unavailable (GNU realpath required)" end
  local ok, r = pcall(ctx.exec, "realpath", {"--canonicalize-existing", "--zero", "--", dir, file}, {timeout_ms=5000, max_output_bytes=16384})
  if not ok or type(r) ~= "table" or r.spawned ~= true or r.exit_code ~= 0 or r.cancelled or r.timed_out or r.output_limit_exceeded or type(r.stdout) ~= "string" then
    return nil, "path guard failed or was denied"
  end
  local a, b, rest = r.stdout:match("^(.-)%z(.-)%z(.*)$")
  if not a or not b or rest ~= "" or a == "" or b == "" or not a:match("^/") or not b:match("^/") then return nil, "path guard returned invalid output" end
  local prefix = a:gsub("/+$", "") .. "/"
  if b:sub(1, #prefix) ~= prefix then return nil, "path escapes skill directory" end
  return b
end

local function metadata(ctx, path, limit)
  local m, err = call(ctx, "metadata", path)
  if not m then return nil, err end
  if type(m) ~= "table" or m.kind ~= "file" then return nil, "not a regular file" end
  if type(m.len) ~= "number" or m.len > limit then return nil, "file exceeds size limit" end
  return m
end
local function read(ctx, path, limit, budget)
  local m, err = metadata(ctx, path, limit)
  if not m then return nil, err end
  if budget.used + m.len > WORK then return nil, "skill read work budget exceeded" end
  if type(ctx.read_file) ~= "function" then return nil, "read_file API unavailable" end
  local ok, text = pcall(ctx.read_file, path)
  if not ok or type(text) ~= "string" then return nil, "could not read file" end
  budget.used = budget.used + #text
  if #text > limit then return nil, "file exceeds size limit" end
  return text
end

local function ancestors(ctx)
  local cwd = normalize(ctx.cwd)
  local home = os.getenv("HOME")
  home = home and normalize(home)
  local out = {}
  for _ = 1, 50 do
    out[#out + 1] = cwd
    if call(ctx, "exists", join(cwd, ".git")) or cwd == home or cwd == "/" then break end
    local parent = cwd:match("^(.*)/[^/]+$")
    if not parent or parent == "" then parent = "/" end
    cwd = parent
  end
  return out
end

function M.search_roots(ctx)
  local roots = {}
  for _, dir in ipairs(ancestors(ctx)) do roots[#roots + 1] = join(dir, ".agents/skills") end
  if ctx.config_dir then roots[#roots + 1] = join(ctx.config_dir, "skills") end
  return roots
end

local function discover(ctx, requested)
  local found, order, blocked, diagnostics = {}, {}, {}, {}
  local budget, examined = {used=0}, 0
  local function finish()
    table.sort(order)
    return found, order, diagnostics
  end
  for _, root in ipairs(M.search_roots(ctx)) do
    -- Missing conventional roots are normal, not warnings on every turn.
    local entries, scan_error
    if call(ctx, "exists", root) then entries, scan_error = call(ctx, "read_dir", root) end
    if scan_error then warn(ctx, diagnostics, "cannot scan " .. root .. ": " .. scan_error) end
    for _, entry in ipairs(entries or {}) do
      examined = examined + 1
      if examined > MAX_DIRS or (not requested and #order >= MAX_SKILLS) then
        warn(ctx, diagnostics, "skill discovery limit reached; additional skills omitted")
        return finish()
      end
      local name = entry.name
      if entry.kind == "dir" and valid_name(name) and not blocked[name]
        and (not requested or requested == name) then
        local dir = join(root, name)
        local path = join(dir, "SKILL.md")
        if call(ctx, "exists", path) then
          blocked[name] = true
          local guarded, err = guard(ctx, dir, path)
          local text
          if guarded then text, err = read(ctx, guarded, MAX_SKILL, budget) end
          local fm
          if text then fm, err = M.frontmatter(text) end
          if fm and fm.name ~= name then fm, err = nil, "frontmatter name does not match directory" end
          if fm then
            found[name] = {name=name, description=fm.description, dir=dir, path=path, _text=text}
            order[#order + 1] = name
          else
            warn(ctx, diagnostics, "skipping " .. name .. ": " .. tostring(err))
          end
          if requested then return finish() end
        end
      end
    end
  end
  return finish()
end
function M.list(ctx)
  local found, order, diagnostics = discover(ctx)
  local out = {}
  for _, name in ipairs(order) do
    if #out == MAX_SKILLS then break end
    out[#out + 1] = {name=name, description=found[name].description, dir=found[name].dir}
  end
  return out, table.concat(diagnostics, "\n")
end
function M.resolve(ctx, name)
  if not valid_name(name) then return nil, "invalid skill name" end
  local found, _, diagnostics = discover(ctx, name)
  if not found[name] then
    local detail = table.concat(diagnostics, "\n")
    return nil, detail ~= "" and ("skill not found; " .. detail) or "skill not found"
  end
  return found[name]
end
local function header(ctx, dir)
  local lines = {}
  for _, sub in ipairs({"references", "scripts"}) do
    local path = join(dir, sub)
    local guarded = call(ctx, "exists", path) and guard(ctx, dir, path)
    local entries = guarded and call(ctx, "read_dir", guarded)
    if type(entries) == "table" then
      table.sort(entries, function(a,b) return tostring(a.name) < tostring(b.name) end)
      local names = {}
      for i = 1, math.min(25, #entries) do names[#names + 1] = entries[i].name end
      if #names > 0 then lines[#lines + 1] = sub .. ": " .. table.concat(names, ", ") end
    end
  end
  return lines
end
function M.read(ctx, name, file)
  if not valid_name(name) then return nil, "invalid skill name" end
  if file ~= nil and type(file) ~= "string" then return nil, "file must be a string" end
  if file ~= nil and not valid_file(file) then return nil, "invalid file path" end
  local item, err = M.resolve(ctx, name)
  if not item then return nil, err end
  if file then
    local guarded, guard_error = guard(ctx, item.dir, join(item.dir, file))
    if not guarded then return nil, guard_error end
    return read(ctx, guarded, MAX_REF, {used=0})
  end
  local body, body_error = M.strip_frontmatter(item._text)
  if not body then return nil, body_error end
  local lines = {"Skill: " .. name, "Directory: " .. item.dir}
  for _, line in ipairs(header(ctx, item.dir)) do lines[#lines + 1] = line end
  return table.concat(lines, "\n") .. "\n\n" .. body
end
function M.index_block(ctx)
  local skills = M.list(ctx)
  if #skills == 0 then return nil end
  local lines = {"Available skills (use the skill tool to list/read them):"}
  for _, item in ipairs(skills) do
    local line = "- " .. item.name .. ": " .. item.description
    if #table.concat(lines, "\n") + 1 + #line > MAX_INDEX then break end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end
M._valid_file = valid_file
return M
