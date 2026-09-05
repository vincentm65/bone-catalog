-- Standalone: lua tests/skill_test.lua
package.path = "./lib/?.lua;" .. package.path
local files = {
  ["/home/p/.agents/skills/local/SKILL.md"] = "---\nname: local\ndescription: local skill\n---\nLocal body",
  ["/global/skills/local/SKILL.md"] = "---\nname: local\ndescription: global skill\n---\nGlobal body",
  ["/global/skills/other/SKILL.md"] = "---\nname: other\ndescription: other skill\n---\nOther body",
}
local dirs = { ["/home/p/.agents/skills"]={"local"}, ["/global/skills"]={"local","other"} }
local function entries(path)
  local out = {}
  for _, n in ipairs(dirs[path] or {}) do out[#out+1]={name=n,path=path.."/"..n,kind="dir"} end
  return out
end
local logs = {}
local function ctx_for(opts)
  opts=opts or {}
  local ctx = {cwd=opts.cwd or "/home/p/src", config_dir="/global", log={warn=function(s) logs[#logs+1]=s end}}
  ctx.fs = {
    exists=function(p) return p=="/home/p/.git" or dirs[p] ~= nil or files[p] ~= nil end,
    read_dir=function(p) return entries(p) end,
    metadata=function(p) local s=files[p]; if not s then error("missing") end; return {kind="file",len=#s} end,
    is_file=function(p) return files[p] ~= nil end,
  }
  ctx.read_file=function(p) if opts.read_fail then error("read denied") end; return files[p] end
  ctx.exec=function(program, args)
    assert(program=="realpath" and args[2]=="--zero")
    if opts.exec_fail then return {exit_code=1,stdout="",error="denied"} end
    local d,f=args[4],args[5]
    if opts.escape then return {spawned=true,exit_code=0,stdout=d.."\0/outside/secret\0"} end
    return {spawned=true,exit_code=0,stdout=d.."\0"..f.."\0"}
  end
  return ctx
end
local skill=require("skill")
local fm=assert(skill.frontmatter("---\r\nname: x\r\ndescription: 'one line'\r\n---\r\nbody"))
assert(fm.name=="x" and fm.description=="one line")
assert(not skill.frontmatter("---\nname: x\ndescription: |\n---\n"))
assert(not skill.frontmatter("---\nname: x\nname: y\ndescription: ok\n---\n"))
assert(not skill.frontmatter("---\nname: x\ndescription: \"a \\\" b\"\n---\n"))
assert(not skill._valid_file("../x") and not skill._valid_file("/x") and not skill._valid_file("a\\x"))
local ctx=ctx_for()
assert(not skill.read(ctx,"local",false), "false file must be rejected")
local list=assert(skill.list(ctx)); assert(#list==2 and list[1].name=="local")
assert(skill.read(ctx,"local"):find("Local body",1,true), "nearest project skill must win")
assert(skill.read(ctx,"other"):find("Other body",1,true))
local escaped=skill.read(ctx,"local","../secret"); assert(escaped==nil)
local denied=skill.read(ctx,"other",nil); assert(denied:find("Other body",1,true))
local noexec=ctx_for({exec_fail=true}); assert(skill.list(noexec)==nil or #skill.list(noexec)==0)
local denied_explicit, denied_err=skill.read(noexec,"local"); assert(denied_explicit==nil and tostring(denied_err):find("guard",1,true))
local symlink=ctx_for({escape=true}); assert(skill.read(symlink,"local")==nil, "canonical escape must be rejected")
local badread=ctx_for({read_fail=true}); assert(#skill.list(badread)==0)

local registered, command, hook
bone={tool={register=function(s) registered=s end}, command={register=function(n,s) command=s end}, on=function(n,h) assert(n=="before_turn"); hook=h end}
package.loaded["skill"]=skill
assert(loadfile("tools/skill.lua"))()
assert(registered and registered.safety=="read_only" and hook)
assert(registered.execute({action="list"},ctx):find("local: local skill",1,true))
local zero=hook(nil, {cwd="/none",config_dir="/none",fs=ctx.fs,exec=ctx.exec,read_file=ctx.read_file,log=ctx.log})
assert(zero==nil, "zero skills must not append")
package.loaded["skill"]=skill
assert(loadfile("commands/skill.lua"))()
local notified
local command_ctx={fs=ctx.fs,exec=ctx.exec,read_file=ctx.read_file,cwd=ctx.cwd,config_dir=ctx.config_dir,log=ctx.log}
local result=command.handler("",command_ctx); assert(result.submit==false and result.display:find("local",1,true))
local prompt=command.handler("local",command_ctx)
assert(type(prompt)=="string" and prompt:find("Directory:",1,true) and prompt:find("Local body",1,true))

-- Empty conventional roots must be quiet, including read_dir implementations
-- that raise on missing paths (as the native API does).
local empty = ctx_for({cwd="/empty"})
empty.config_dir = "/empty-config"
empty.fs.exists = function() return false end
empty.fs.read_dir = function() error("missing directory") end
local empty_items, empty_diagnostics = skill.list(empty)
assert(#empty_items == 0 and empty_diagnostics == "")
assert(command.handler("missing", empty).submit == false)
assert(command.handler("two names", ctx).submit == false)
assert(registered.execute({action="bad"}, ctx):find("ERROR", 1, true))
assert(registered.execute({action="read",name="local",file=false}, ctx):find("ERROR", 1, true))
assert(hook(nil, ctx).system_prompt_append:find("local: local skill", 1, true))

-- Boundaries are inclusive, and trailing slashes must not bypass HOME.
local roots = skill.search_roots(ctx)
assert(#roots == 3 and roots[2] == "/home/p/.agents/skills")
local getenv = os.getenv
os.getenv = function(key) if key == "HOME" then return "/test-home/" end; return getenv(key) end
local home_roots = skill.search_roots({cwd="/test-home///",config_dir="/global",fs=empty.fs})
os.getenv = getenv
assert(#home_roots == 2 and home_roots[1] == "/test-home/.agents/skills")
local root_roots = skill.search_roots({cwd="/",config_dir="/global",fs=empty.fs})
assert(#root_roots == 2 and root_roots[1] == "/.agents/skills")

-- Malformed nearest candidates reserve their name: no global fallback.
local local_path = "/home/p/.agents/skills/local/SKILL.md"
local original = files[local_path]
files[local_path] = "---\nname: mismatch\ndescription: wrong\n---\nbody"
local mismatch, mismatch_error = skill.read(ctx, "local")
assert(not mismatch and mismatch_error:find("does not match", 1, true))
files[local_path] = original

for _, value in ipairs({"|-", ">+", "[nested]", "{nested}", "&anchor", '"bad\\nescape"'}) do
  assert(not skill.frontmatter("---\nname: x\ndescription: " .. value .. "\n---\n"), value)
end
assert(not skill.frontmatter("---\nname: x\ndescription: ok\nunknown: value\n---\n"))
assert(not skill.frontmatter("---\nname: x\ndescription: ok"))
assert(not skill.frontmatter("---\nname: x\ndescription: " .. string.rep("a", 513) .. "\n---\n"))
for _, path in ipairs({"/abs", "../x", "a/../x", "a/./b", "a\\b", "a\0b"}) do
  assert(not skill.read(ctx,"local",path), path)
end
for _, result in ipairs({
  {spawned=false,exit_code=0,stdout="/a\0/a/b\0"},
  {spawned=true,exit_code=0,stdout="relative\0relative/b\0"},
  {spawned=true,exit_code=0,stdout="/a\0/a/b\0extra"},
  {spawned=true,exit_code=0,stdout="/a\0/ab/file\0"},
  {spawned=true,exit_code=0,stdout="/a\0/a/b\0",output_limit_exceeded=true},
}) do
  local invalid = ctx_for()
  invalid.exec = function() return result end
  assert(not skill.read(invalid,"local"))
end

-- Reads reject oversized/nonregular files before touching content.
local capped = ctx_for()
local reads = 0
capped.read_file = function() reads = reads + 1; error("must not read") end
capped.fs.metadata = function() return {kind="file",len=65537} end
assert(not skill.read(capped,"local") and reads == 0)
capped.fs.metadata = function() return {kind="other",len=0} end
assert(not skill.read(capped,"local") and reads == 0)

-- Native read_dir order is lexical. Build enough fixtures to hit count and
-- index byte limits, then ensure explicit reads still reach unindexed names.
local old_files, old_dirs = files, dirs
files, dirs = {}, {["/global/skills"]={}}
for i = 1, 110 do
  local name = string.format("s%03d", i)
  dirs["/global/skills"][i] = name
  files["/global/skills/" .. name .. "/SKILL.md"] = "---\nname: " .. name
    .. "\ndescription: " .. string.rep("d", 512) .. "\n---\nbody"
end
local many = ctx_for({cwd="/empty"})
local many_items, many_diagnostics = skill.list(many)
assert(#many_items == 100 and many_diagnostics:find("limit", 1, true))
assert(#skill.index_block(many) <= 16 * 1024)
assert(skill.read(many,"s110"), "explicit reads should not inherit the index count cap")

-- Invalid candidates still consume the aggregate read budget. Warnings are
-- bounded, and no content read happens after the 8 MiB budget is exhausted.
files, dirs = {}, {["/global/skills"]={}}
for i = 1, 140 do
  local name = string.format("bad%03d", i)
  dirs["/global/skills"][i] = name
  files["/global/skills/" .. name .. "/SKILL.md"] = string.rep("x", 65536)
end
local budget_ctx = ctx_for({cwd="/empty"})
reads = 0
budget_ctx.read_file = function(path) reads = reads + 1; return files[path] end
local before_logs = #logs
local budget_items, budget_diagnostics = skill.list(budget_ctx)
assert(#budget_items == 0 and reads == 128)
assert(#logs - before_logs <= 10 and #budget_diagnostics <= 10 * 513)
files, dirs = old_files, old_dirs
print("skill tests passed")
