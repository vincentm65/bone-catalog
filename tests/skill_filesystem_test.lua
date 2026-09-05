-- Standalone: lua5.4 tests/skill_filesystem_test.lua   (run from repo root)
-- Real-filesystem harness for lib/skill.lua: real temp dirs, real GNU realpath
-- (spawned via io.popen with safely shell-quoted argv), real stat/ls for ctx.fs.
-- Creates only its own mktemp directory and removes it on exit.
package.path = "./lib/?.lua;" .. package.path
local skill = require("skill")

local function die(msg) error("FAIL: " .. tostring(msg), 0) end
local checks = 0
local function ok(cond, msg)
  if not cond then die(msg) end
  checks = checks + 1
end

-- ---------- shell helpers (test-only) ----------
local function shquote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function shrun(cmd)
  local h = io.popen(cmd .. " 2>/dev/null")
  if not h then return nil end
  local out = h:read("a") or ""
  h:close()
  return out
end
local function run(argv)
  local line = table.concat(argv, " ")
  local h = assert(io.popen(line .. " 2>/dev/null"))
  local out = h:read("a") or ""
  local success, _, code = h:close()
  return success and 0 or (code or 255), out
end
local function w(path, s)
  local h, e = io.open(path, "w")
  if not h then die("cannot write " .. path .. ": " .. tostring(e)) end
  h:write(s)
  h:close()
end
local function rm(p)
  local h = io.popen("rm -rf " .. shquote(p) .. " 2>/dev/null")
  h:close()
end

-- ---------- fixture: one mktemp dir, removed at exit ----------
local tmp = (shrun("mktemp -d") or ""):gsub("%s+$", "")
ok(#tmp > 0 and tmp:match("^/") ~= nil, "mktemp -d returned a path")
ok(tmp:match("^/home/") == nil, "temp dir must not live in the home tree")
local cleanup = function() rm(tmp) end
os.setlocale("C")
local cleanup_guard <close> = setmetatable({}, { __close = cleanup })

local proj = tmp .. "/proj"
local cfg = tmp .. "/cfg"
local outside = tmp .. "/outside"
local sibling = tmp .. "/proj/.agents/skills/esc-outside"
os.execute("mkdir -p " .. shquote(proj .. "/src") .. " " .. shquote(cfg) .. " " .. shquote(outside) .. " " .. shquote(sibling) .. " " .. shquote(proj .. "/.agents/skills") .. " >/dev/null 2>&1")
ok(io.open(proj .. "/src") ~= nil, "fixture directories created")

local function skill_md(dir, name, desc, body)
  os.execute("mkdir -p " .. shquote(dir .. "/" .. name) .. " >/dev/null 2>&1")
  w(dir .. "/" .. name .. "/SKILL.md",
    "---\nname: " .. name .. "\ndescription: " .. desc .. "\n---\n" .. body .. "\n")
end
-- .git as a plain file marker (not a real repo): discovery must stop here
w(proj .. "/.git", "# fake git marker\n")
-- a skill ABOVE the boundary: must never be discovered
local parentskills = tmp .. "/.agents/skills"
os.execute("mkdir -p " .. shquote(parentskills) .. " >/dev/null 2>&1")
skill_md(parentskills, "outside", "above boundary skill", "OUTSIDE-BODY")
w(outside .. "/secret.txt", "TOP-SECRET\n")
w(sibling .. "/leak.txt", "SIBLING-LEAK\n")
os.execute("mkdir -p " .. shquote(cfg .. "/skills/leak-skill") .. " >/dev/null 2>&1")
w(cfg .. "/skills/leak-skill/SKILL.md", "---\nname: leak-skill\ndescription: outside skill\n---\nOutside body\n")

-- project skills (nearest)
skill_md(proj .. "/.agents/skills", "alpha", "project alpha", "ALPHA-BODY")
skill_md(proj .. "/.agents/skills", "local", "project local", "PROJ-LOCAL")
-- global skills
skill_md(cfg .. "/skills", "local", "global local", "GLOBAL-LOCAL")
skill_md(cfg .. "/skills", "global-only", "global skill", "GLOBAL-BODY")
-- references skill with a real reference file
local refdir = proj .. "/.agents/skills/refs/references"
os.execute("mkdir -p " .. shquote(refdir) .. " >/dev/null 2>&1")
skill_md(proj .. "/.agents/skills", "refs", "refs skill", "REFS-BODY")
w(refdir .. "/note.txt", "REF-NOTE\n")
-- escape fixtures
local escdir = proj .. "/.agents/skills/esc"
os.execute("mkdir -p " .. shquote(escdir .. "/references") .. " >/dev/null 2>&1")
skill_md(proj .. "/.agents/skills", "esc", "escape skill", "ESC-BODY")
w(escdir .. "/references/ok.txt", "ESC-OK\n")
os.execute("ln -s " .. shquote(tmp .. "/outside") .. " " .. shquote(escdir .. "/references/link") .. " >/dev/null 2>&1")
ok(io.open(escdir .. "/references/link/secret.txt") ~= nil, "escape symlink fixture resolves")
-- SKILL.md itself is a symlink pointing outside
local esmd = proj .. "/.agents/skills/badlink"
os.execute("mkdir -p " .. shquote(esmd) .. " >/dev/null 2>&1")
w(outside .. "/fake.md", "---\nname: badlink\ndescription: fake\n---\nFAKE\n")
os.execute("ln -s " .. shquote(outside .. "/fake.md") .. " " .. shquote(esmd .. "/SKILL.md") .. " >/dev/null 2>&1")
-- dangling SKILL.md (exists as an entry, realpath --canonicalize-existing fails)
local dang = proj .. "/.agents/skills/dangling"
os.execute("mkdir -p " .. shquote(dang) .. " >/dev/null 2>&1")
os.execute("ln -s " .. shquote(tmp .. "/outside/gone.md") .. " " .. shquote(dang .. "/SKILL.md") .. " >/dev/null 2>&1")
-- FIFO reference: must be classified non-regular and never read
local fifodir = proj .. "/.agents/skills/fifoskill"
os.execute("mkdir -p " .. shquote(fifodir .. "/references") .. " >/dev/null 2>&1")
skill_md(proj .. "/.agents/skills", "fifoskill", "fifo skill", "FIFO-BODY")
os.execute("mkfifo " .. shquote(fifodir .. "/references/pipe") .. " >/dev/null 2>&1")
ok(shrun("test -p " .. shquote(fifodir .. "/references/pipe") .. " && echo y") == "y\n",
   "FIFO fixture created")

-- ---------- ctx with real fs + real realpath exec ----------
local function kind_of(p)
  local s = shrun("stat -L -c %F " .. shquote(p))
  if not s then return nil end
  s = s:gsub("%s+$", "")
  if s:match("^directory$") then return "dir" end
  if s:match("^regular file$") then return "file" end
  if s:match("^fifo$") then return "fifo" end
  if s:match("^symbolic link$") then return "link" end
  return "other"
end
local function make_ctx()
  local ctx = { cwd = proj .. "/src", config_dir = cfg, log = { warn = function() end } }
  ctx.fs = {
    exists = function(p)
      return (shrun("test -e " .. shquote(p) .. " && echo y") or ""):match("y") ~= nil
    end,
    read_dir = function(p)
      local s = shrun("ls -1A " .. shquote(p))
      local out = {}
      for name in (s or ""):gmatch("[^\n]+") do
        if name ~= "" then
          local k = kind_of(p .. "/" .. name)
          if k then
            local len = 0
            if k == "file" or k == "fifo" then
              len = tonumber(shrun("stat -L -c %s " .. shquote(p .. "/" .. name))) or 0
            end
            out[#out + 1] = { name = name, path = p .. "/" .. name, kind = k, len = len }
          end
        end
      end
      return out
    end,
    metadata = function(p)
      local s = shrun("stat -L -c '%F %s' " .. shquote(p))
      if not s then error("stat failed for " .. p) end
      local ftype, size = s:match("^(.-)%s+(%d+)%s*$")
      local k = kind_of(p)
      return { kind = k, len = tonumber(size) or 0 }
    end,
  }
  ctx.read_file = function(p)
    local h, e = io.open(p, "r")
    if not h then error(e) end
    local s = h:read("a")
    h:close()
    return s
  end
  ctx.exec = function(program, args, _opts)
    assert(program == "realpath", "only realpath is expected from skill.lua")
    local argv = { "realpath" }
    for _, a in ipairs(args) do argv[#argv + 1] = shquote(a) end
    local rc, out = run(argv)
    return {spawned=true, exit_code=rc, stdout=out}
  end
  return ctx
end
local function names(list)
  local out = {}
  for i, s in ipairs(list) do out[i] = s.name end
  table.sort(out)
  return out
end
local function expect_err(value, err, needle, label)
  ok(value == nil and type(err) == "string" and err:find(needle, 1, true) ~= nil,
     label .. " (err=" .. tostring(err) .. ")")
end

-- ---------- 1. discovery + nearest/global precedence ----------
local ctx = make_ctx()
local list = skill.list(ctx)
ok(type(list) == "table" and #list >= 6, "list returns items")
local got = names(list)
ok(got[1] == "alpha" and #got == 7, "all discovered skills present: " .. table.concat(got, ","))
local byname = {}
for _, s in ipairs(list) do byname[s.name] = s end
ok(byname["local"].dir == proj .. "/.agents/skills/local",
   "list reports nearest (project) dir for duplicate skill")
ok(byname["local"].description == "project local", "nearest description wins")
ok(byname["global-only"].dir == cfg .. "/skills/global-only", "global skill found via config_dir")
ok(byname["alpha"] and byname["leak-skill"] and byname["esc"] and byname["refs"] and byname["fifoskill"],
   "project and global entries all listed")
-- .git file marker boundary: skill outside the project must NOT be discovered
ok(byname["outside"] == nil, "skills outside the .git boundary are not discovered")

-- ---------- 2. read: header-stripped body and raw reference ----------
local body, rerr = skill.read(ctx, "local")
ok(body and body:find("Directory:", 1, true) and body:find("PROJ-LOCAL", 1, true),
   "read includes directory header and nearest body: " .. tostring(rerr))
local gbody = skill.read(ctx, "global-only")
ok(gbody and gbody:find("GLOBAL-BODY", 1, true), "read global skill body")
local ref, referr = skill.read(ctx, "refs", "references/note.txt")
ok(ref == "REF-NOTE\n", "read reference file raw (no strip) (got " .. tostring(ref) .. ")")
local traversal, traversal_error = skill.read(ctx, "refs", "../outside/secret.txt")
expect_err(traversal, traversal_error, "invalid", "traversal file arg rejected")
local absent, absent_error = skill.read(ctx, "nosuchskill")
expect_err(absent, absent_error, "not found", "missing skill errors")

-- ---------- 3. canonical symlink escape (incl. sibling prefix dir) ----------
local esc, escerr = skill.read(ctx, "esc", "references/link/secret.txt")
expect_err(esc, escerr, "escape", "canonical symlink escape denied")
-- sibling directory whose name shares the prefix of the skill dir
local sib2, sib2err = skill.read(ctx, "esc", "../leak-skill-outside/leak.txt")
expect_err(sib2, sib2err, "invalid", "sibling dir outside skill root rejected at path validation")
-- real symlink to sibling prefix dir (name shares prefix of skill dir)
os.execute("ln -s " .. shquote(sibling) .. " " .. shquote(escdir .. "/references/siblink") .. " >/dev/null 2>&1")
local sib3, sib3err = skill.read(ctx, "esc", "references/siblink/leak.txt")
expect_err(sib3, sib3err, "escape", "sibling-prefix symlink escape denied by realpath")
-- benign reference in the same skill still reads
local okref = skill.read(ctx, "esc", "references/ok.txt")
ok(okref == "ESC-OK\n", "benign reference in escape-prone skill still reads")

-- ---------- 4. SKILL.md escape: symlinked SKILL.md denied everywhere ----------
local badlist = skill.list(make_ctx())
local bad = {}
for _, s in ipairs(badlist) do bad[s.name] = true end
ok(bad["badlink"] == nil, "skill whose SKILL.md symlinks outside is not listed")
local bl, blerr = skill.read(ctx, "badlink")
expect_err(bl, blerr, "escape", "reading SKILL.md symlink escape denied")

-- ---------- 5. realpath denial (dangling canonical target) ----------
local dl, dlerr = skill.read(ctx, "dangling")
expect_err(dl, dlerr, "not found", "dangling SKILL.md is absent to native exists")
local denied_ctx = make_ctx()
denied_ctx.exec = function() error("approval denied") end
local denied, denied_error = skill.read(denied_ctx, "local")
expect_err(denied, denied_error, "guard", "approval denial fails closed")
local dlist = skill.list(make_ctx())
local dn = {}
for _, s in ipairs(dlist) do dn[s.name] = true end
ok(dn["dangling"] == nil, "dangling skill skipped from list")

-- ---------- 6. non-regular file check: FIFO must not be read ----------
local fctx = make_ctx()
local fbody = skill.read(fctx, "fifoskill")
ok(type(fbody) == "string" and fbody:find("FIFO-BODY", 1, true) ~= nil,
   "fifo skill body reads (SKILL.md is regular)")
ok(fbody:find("Directory:", 1, true) ~= nil, "fifo skill body contains Directory: header")
-- ctx.fs.metadata must classify the FIFO accurately (test-only fs impl)
local fmeta = fctx.fs.metadata(fifodir .. "/references/pipe")
ok(type(fmeta) == "table" and fmeta.kind == "fifo" and fmeta.len == 0,
   "ctx.fs.metadata reports accurate kind=fifo len=0 for FIFO")
-- Intercept ctx.read_file: a correct implementation rejects kind ~= "file"
-- before ever opening the path; a broken one would call read_file on the FIFO
-- (which would block on a real FIFO) and the flag would be set.
local fifo_read_flag = false
local real_read_file = fctx.read_file
fctx.read_file = function(p)
  if p == fifodir .. "/references/pipe" then
    fifo_read_flag = true
    error("read_file intercepted on FIFO path")
  end
  return real_read_file(p)
end
local fref, freferr = skill.read(fctx, "fifoskill", "references/pipe")
expect_err(fref, freferr, "not a regular file", "FIFO reference rejected as non-regular before open")
ok(fifo_read_flag == false, "ctx.read_file was never called for the FIFO path")

-- Header listings must not enumerate an escaped optional directory.
os.execute("ln -s " .. shquote(outside) .. " " .. shquote(fifodir .. "/scripts"))
local guarded_body = skill.read(make_ctx(), "fifoskill")
ok(guarded_body and not guarded_body:find("secret.txt", 1, true),
   "header does not list names outside skill directory")

-- ---------- done: verify cleanup ----------
cleanup()
ok(io.open(tmp) == nil, "mktemp directory was removed (only our own dir)")
io.write(string.format("skill_filesystem tests passed (%d checks)\n", checks))
