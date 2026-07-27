-- /firefox_dom — install and diagnose the independent Firefox DOM bridge.
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
bone.command.register("firefox_dom", {
  description = "Install, diagnose, or remove the Firefox DOM bridge (setup|doctor|remove).",
  handler = function(args, ctx)
    local action = trim(args)
    if action ~= "setup" and action ~= "doctor" and action ~= "remove" then
      return { display = "Usage: /firefox_dom setup|doctor|remove", submit = false }
    end
    local root = ctx.config_dir .. "/firefox_dom"
    local script = ctx.config_dir .. "/lua/firefox_dom/setup.sh"
    local q = function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
    local result = ctx.shell("bash " .. q(script) .. " " .. action .. " --state " .. q(root), { timeout_ms = 120000 })
    local output = (result.stdout or "") .. ((result.stderr or "") ~= "" and "\n" .. result.stderr or "")
    if result.exit_code ~= 0 then return { display = output ~= "" and output or ("firefox_dom " .. action .. " failed"), submit = false } end
    return { display = output ~= "" and output or ("firefox_dom " .. action .. " complete."), submit = false }
  end,
})
