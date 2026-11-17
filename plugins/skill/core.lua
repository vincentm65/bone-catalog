-- skills, core side: a registry of skills (instructions for particular
-- kinds of work) that the model loads when a task calls for them. While a
-- session has any, the system prompt lists them and a `skill` tool returns
-- one's full text and its files. With no skills, nothing changes.
--
--   <config dir>/skills/<name>/SKILL.md          -- found without any setup
--   bone.config.skill_dirs = { "~/work/skills" } -- or other folders instead
--
-- Other plugins and core.lua can use the API below (bone.skill.*).

local front_matter = require("bone.util").front_matter

local NAME = "^[%w_%-%.]+$"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local function home(path)
  return (path:gsub("^~", os.getenv("HOME") or "~"))
end

--- Skills: instructions for particular kinds of work that the model loads
--- when a task calls for them.
---   every <dir>/<name>/SKILL.md of bone.config.skill_dirs (default
---   { "<config dir>/skills" }; front matter: name, description), read
---   again each turn, so one written or removed while bone runs counts at once
---   bone.skill.register { name, description, content = "..." }
---   bone.skill.register { name, description?, path = "dir/with/SKILL.md" or "file.md",
---                         enabled = function(ctx) return ... end }  -- ctx = { session_id, cwd }
---   bone.skill.load_dir("~/skills")   adds a folder to bone.config.skill_dirs
---   bone.skill.unregister(name), bone.skill.list()
--- A skill registered by hand wins over a folder's of the same name.
--- While a session has a skill, the system prompt lists the skills (name and
--- description) and a `skill` tool returns one's full text and its files.
--- bone.config.skills = { prompt = false } or { tool = false } turns either off.
bone.skill = {}
bone._skills = {}
bone.config.skills = { prompt = true, tool = true }
bone.config.skill_dirs = bone.config.skill_dirs or { (bone.config_dir or "~/.bone") .. "/skills" }

local function skill_enabled(s, ctx)
  if s.enabled == nil then
    return true
  end
  local ok, yes = pcall(s.enabled, ctx or {})
  return ok and yes and true or false
end

local function enabled_skills(ctx)
  local out = {}
  for _, s in pairs(bone._skills) do
    if skill_enabled(s, ctx) then
      out[#out + 1] = s
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

local function dirs()
  local out = {}
  for _, dir in ipairs(bone.config.skill_dirs or {}) do
    out[#out + 1] = (home(dir):gsub("/$", ""))
  end
  return out
end

-- The folders' skills as they are now: new ones in, removed ones out. The
-- first folder wins a name; a skill registered by hand is left alone.
local function scan()
  local seen = {}
  for _, dir in ipairs(dirs()) do
    for _, e in ipairs(bone.fs.list(dir) or {}) do
      local path = dir .. "/" .. e.name
      local text = e.type == "dir" and read_file(path .. "/SKILL.md")
      if text then
        local meta = front_matter(text)
        local name = type(meta.name) == "string" and meta.name:match(NAME) and meta.name or e.name
        local had = bone._skills[name]
        if name:match(NAME) and not seen[name] and (not had or had.scanned) then
          seen[name] = true
          bone._skills[name] = {
            name = name,
            description = tostring(meta.description or ""),
            path = path .. "/SKILL.md",
            dir = path,
            scanned = true,
          }
        end
      end
    end
  end
  for name, sk in pairs(bone._skills) do
    if sk.scanned and not seen[name] then
      bone._skills[name] = nil
    end
  end
end

-- The full text of a skill, and the files that come with it.
local function skill_text(s)
  local body = s.content
  if not body then
    local text = read_file(s.path)
    if not text then
      return nil, "cannot read " .. s.path
    end
    local _, rest = front_matter(text)
    body = rest
  end
  local out = { "# Skill: " .. s.name, "", body }
  if s.dir then
    local files = {}
    for _, e in ipairs(bone.fs.list(s.dir) or {}) do
      if e.name ~= "SKILL.md" and e.name:sub(1, 1) ~= "." then
        files[#files + 1] = s.dir .. "/" .. e.name .. (e.type == "dir" and "/" or "")
      end
    end
    if #files > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "Files that come with this skill (read them when the steps above need them):"
      for _, f in ipairs(files) do
        out[#out + 1] = "- " .. f
      end
    end
  end
  return table.concat(out, "\n")
end

local skill_tool = {
  name = "skill",
  description = "Load the full instructions of one of the skills listed in the system prompt.",
  parameters = {
    type = "object",
    properties = { name = { type = "string", description = "The skill's name" } },
    required = { "name" },
  },
  needs_approval = false,
  run = function(args, ctx)
    local name = tostring(args.name or "")
    local sk = bone._skills[name]
    if not sk or not skill_enabled(sk, ctx) then
      scan() -- written since this turn began?
      sk = bone._skills[name]
    end
    if not sk or not skill_enabled(sk, ctx) then
      local names = {}
      for _, candidate in ipairs(enabled_skills(ctx)) do
        names[#names + 1] = candidate.name
      end
      local available = #names > 0 and (". Available skills: " .. table.concat(names, ", ")) or ""
      return nil, "no skill named " .. name .. available
    end
    return skill_text(sk)
  end,
}

-- First among system hooks, so later ones see (and may change) the list.
bone.hook("system", function(ev)
  local cfg = bone.config.skills or {}
  if cfg.prompt == false then
    return
  end
  scan()
  local list = enabled_skills(ev)
  if #list == 0 then
    return
  end
  -- Lua tools are fixed when the config loads: until a reload, skills that
  -- came after it are read from their files.
  local tool = bone._tools.skill == skill_tool
  local lines = {
    ev.prompt,
    "",
    "## Skills",
    "",
    "Skills are instructions for particular kinds of work. When a task matches one, "
      .. (tool and "call the `skill` tool with its name" or "read its file")
      .. " before starting, then follow it.",
    "",
  }
  for _, sk in ipairs(list) do
    local where = (not tool and sk.path) and (" (" .. sk.path .. ")") or ""
    lines[#lines + 1] = "- " .. sk.name .. ": " .. sk.description .. where
  end
  return { prompt = table.concat(lines, "\n") }
end, { priority = 1000 })

-- Once the config is final: the folders it names, and the tool when there
-- are skills or a folder for them.
bone.on_ready(function()
  scan()
  local cfg = bone.config.skills or {}
  if cfg.tool == false or bone._tools.skill then
    return
  end
  local any = next(bone._skills) ~= nil
  for _, dir in ipairs(dirs()) do
    any = any or bone.fs.list(dir) ~= nil
  end
  if any then
    bone.tool.register(skill_tool)
  end
end)

function bone.skill.register(spec)
  assert(type(spec) == "table" and type(spec.name) == "string" and spec.name:match(NAME),
    "bone.skill.register { name = [A-Za-z0-9_-.]+, description, content or path }")
  assert(spec.content or spec.path, "skill " .. spec.name .. " needs content or a path")
  local sk = { name = spec.name, description = spec.description, content = spec.content, enabled = spec.enabled }
  if spec.path then
    local path = home(spec.path):gsub("/$", "")
    if path:match("%.md$") then
      sk.path, sk.dir = path, nil
    else
      sk.path, sk.dir = path .. "/SKILL.md", path
    end
    if not sk.description then
      local meta = front_matter(read_file(sk.path) or "")
      sk.description = meta.description
    end
  end
  sk.description = sk.description or ""
  bone._skills[sk.name] = sk
end

--- Add a folder of <name>/SKILL.md to bone.config.skill_dirs. Returns how
--- many skills it has.
function bone.skill.load_dir(dir)
  local want = home(dir):gsub("/$", "")
  local list = bone.config.skill_dirs or {}
  local have = false
  for _, d in ipairs(dirs()) do
    have = have or d == want
  end
  if not have then
    list[#list + 1] = want
    bone.config.skill_dirs = list
  end
  scan()
  local n = 0
  for _, sk in pairs(bone._skills) do
    if sk.scanned and sk.dir:sub(1, #want + 1) == want .. "/" then
      n = n + 1
    end
  end
  return n
end

--- A folder's skill comes back while its SKILL.md is there.
function bone.skill.unregister(name)
  bone._skills[name] = nil
end

function bone.skill.list()
  scan()
  local out = {}
  for _, sk in ipairs(enabled_skills(nil)) do
    out[#out + 1] = { name = sk.name, description = sk.description, path = sk.path }
  end
  return out
end

function bone.skill._all()
  scan()
  local out = {}
  local names = {}
  for name in pairs(bone._skills) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local sk = bone._skills[name]
    out[#out + 1] = { name = sk.name, description = sk.description, path = sk.path }
  end
  return out
end

-- For the TUI and GUI half: the skills, and where new ones go.
bone.rpc.register("skills.list", function()
  return { skills = bone.skill._all(), dirs = dirs() }
end)
