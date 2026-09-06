-- Injects a skill index into the system prompt each turn; read skills with read_file.
local skill = require("skill")

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
