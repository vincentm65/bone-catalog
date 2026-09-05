local skill = require("skill")

local function execute(params, ctx)
  if type(params) ~= "table" then return "ERROR: parameters must be an object" end
  local action = params.action
  if action == "list" then
    local ok, result, diagnostics = pcall(skill.list, ctx)
    if not ok then return "ERROR: could not list skills: " .. tostring(result) end
    if #result == 0 then
      return diagnostics and diagnostics ~= "" and "No skills found.\nWarnings: " .. diagnostics or "No skills found."
    end
    local lines = {}
    for _, item in ipairs(result) do lines[#lines + 1] = item.name .. ": " .. item.description end
    if diagnostics and diagnostics ~= "" then lines[#lines + 1] = "Warnings: " .. diagnostics end
    return table.concat(lines, "\n")
  end
  if action ~= "read" then return "ERROR: action must be list or read" end
  if type(params.name) ~= "string" then return "ERROR: name is required for read" end
  local ok, result, err = pcall(skill.read, ctx, params.name, params.file)
  if not ok then return "ERROR: could not read skill: " .. tostring(result) end
  if not result then return "ERROR: " .. tostring(err) end
  return result
end

if not bone._skill_feature_registered then
  bone._skill_feature_registered = true
  bone.tool.register({
  name = "skill",
  description = "List or safely read local and global skills. Skills are read-only instructions; no scripts are executed.",
  parameters = {
    type = "object", properties = {
      action = {type = "string", enum = {"list", "read"}},
      name = {type = "string"}, file = {type = "string"},
    }, required = {"action"}, additionalProperties = false,
  },
  safety = "read_only", execute = execute,
})

if not bone._skill_before_turn_registered then
  bone._skill_before_turn_registered = true
  bone.on("before_turn", function(_, ctx)
    local ok, block = pcall(skill.index_block, ctx)
    if not ok then
      if ctx.log and ctx.log.warn then pcall(ctx.log.warn, "skill index unavailable: " .. tostring(block)) end
      return nil
    end
    if block then return {system_prompt_append = block} end
    return nil
  end)
  end
end
