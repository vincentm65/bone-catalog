-- behavior, frontend side (TUI and GUI):
--   /behavior                 open the knobs as a settings page
--   /behavior <knob> <value>  set one directly: /behavior narrate_every 4,
--                             /behavior verify off

local FIELDS = {
  { key = "narrate_every", label = "Narrate every", type = "integer", default = 6, min = 0, max = 50,
    desc = "Remind the model to tell the user something after this many silent tool calls (0 turns it off)." },
  { key = "ending", label = "Ending discipline", type = "boolean", default = true,
    desc = "Never end a turn on a plan or a progress note." },
  { key = "verify", label = "Verify before finishing", type = "boolean", default = true,
    desc = "Run the command that proves the change, or say \"unverified\"." },
  { key = "minimal_diffs", label = "Minimal diffs", type = "boolean", default = true,
    desc = "Change only what the task requires; no drive-by refactors." },
  { key = "no_unrequested_files", label = "No unrequested files", type = "boolean", default = true,
    desc = "No new tests, docs or helper scripts unless asked." },
  { key = "final_format", label = "Compact final answers", type = "boolean", default = true,
    desc = "Lead with what changed and what proved it, at most six lines." },
  { key = "read_before_edit", label = "Read before edit", type = "boolean", default = false,
    desc = "Refuse edit_file on files the model has not read this turn." },
}

bone.settings.page({ name = "behavior", title = "Behavior", fields = FIELDS })

bone.cmd.create("behavior", function(c)
  local knob, value = c.args:match("^(%S+)%s+(%S+)$")
  if not knob then
    return require("bone.config").open("behavior")
  end
  local known
  for _, f in ipairs(FIELDS) do
    if f.key == knob then known = f end
  end
  if not known then
    return bone.notify("behavior: unknown knob " .. knob, "error")
  end
  local v
  if value == "on" or value == "true" then
    v = true
  elseif value == "off" or value == "false" then
    v = false
  else
    v = tonumber(value)
  end
  if v == nil or (known.type == "integer") ~= (type(v) == "number") then
    return bone.notify("usage: /behavior " .. knob .. (known.type == "integer" and " N" or " on|off"), "error")
  end
  bone.settings.set("behavior." .. knob, v, function(_, err)
    if err then
      return bone.notify("behavior: " .. tostring(err), "error")
    end
    bone.notify("behavior." .. knob .. " = " .. tostring(v))
  end)
end, {
  desc = "behavior knobs: narration, ending, verify, diffs (behavior plugin)",
  complete = function()
    local out = {}
    for _, f in ipairs(FIELDS) do
      out[#out + 1] = { value = f.key, desc = f.desc }
    end
    return out
  end,
})
