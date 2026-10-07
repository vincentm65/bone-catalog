-- Submit the literal command; core instructions never enter the transcript.
bone.cmd.create("review", function(c)
  local args = {}
  for arg in c.args:gmatch("%S+") do args[#args + 1] = arg end
  local efforts = { low = true, medium = true, high = true }
  if #args > 2 or (args[1] and args[1]:sub(1, 1) == "-")
      or (#args == 2 and (efforts[args[1]] or not efforts[args[2]])) then
    return bone.notify("usage: /review [branch] [low|medium|high]", "error")
  end
  bone.prompt.set("/review" .. (c.args ~= "" and (" " .. c.args) or ""))
  bone.action("submit")
end, { desc = "verification-first review: /review [branch] [low|medium|high]" })
