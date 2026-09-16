local skill = require("skill")

local function listing(ctx)
  local ok, items, diagnostics = pcall(skill.list, ctx)
  if not ok then
    return nil, "Could not list skills: " .. tostring(items)
  end

  local lines = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = item.name .. ": " .. item.description
  end
  if #lines == 0 then
    lines[1] = "No skills found."
  end
  if diagnostics and diagnostics ~= "" then
    lines[#lines + 1] = "Warnings: " .. diagnostics
  end
  return table.concat(lines, "\n")
end

local function parse(arg)
  local value = tostring(arg or "")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
  if value == "" then
    return nil
  end
  if not value:match("^%S+$") then
    return nil, "Usage: /skill [name]"
  end
  return value
end

if not bone._skill_command_registered then
  bone._skill_command_registered = true
  bone.command.register("skill", {
    description = "List installed skills or inject one skill's instructions",
    handler = function(arg, ctx)
      local name, parse_err = parse(arg)
      if parse_err then
        return { display = parse_err, submit = false }
      end

      if not name then
        local message, err = listing(ctx)
        if not message then
          return { display = err, submit = false }
        end
        return { display = message, submit = false }
      end

      local ok, prompt, err = pcall(skill.read, ctx, name)
      if not ok then
        return { display = "Could not read skill " .. name .. ": " .. tostring(prompt), submit = false }
      end
      if not prompt then
        return { display = "Could not read skill " .. name .. ": " .. tostring(err), submit = false }
      end
      -- A named skill is intentionally submitted as the next model prompt.
      return prompt
    end,
  })
end
return {}
