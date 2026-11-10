-- behavior, frontend side (TUI and GUI):
--   /behavior                 open the knobs as a settings page
--   /behavior <knob> <value>  set one directly: /behavior narrate_every 4,
--                             /behavior verify strict, /behavior tone dry

local FIELDS = {
  { key = "narrate_every", label = "Narrate every", type = "integer", default = 0, min = 0, max = 50,
    desc = "Remind the model to tell the user something after this many silent tool calls (0 turns it off)." },
  { key = "ending", label = "Ending discipline", type = "string", default = "off",
    choices = { "off", "light", "standard", "strict" },
    desc = "How firmly a turn may not end on a plan or a progress note." },
  { key = "verify", label = "Verify before finishing", type = "string", default = "off",
    choices = { "off", "light", "standard", "strict" },
    desc = "How firmly changes must be proved by a command before the turn ends." },
  { key = "scope", label = "Diff scope", type = "string", default = "off",
    choices = { "off", "light", "standard", "strict" },
    desc = "How tightly changes stay on task: no drive-by refactors or unrequested files." },
  { key = "tone", label = "Tone", type = "string", default = "plain",
    choices = { "plain", "friendly", "dry", "formal" },
    desc = "The voice of everything the model writes to the user." },
  { key = "conciseness", label = "Conciseness", type = "string", default = "normal",
    choices = { "chatty", "normal", "concise", "terse" },
    desc = "How much the model says, from explain-as-you-go to three-line finals." },
  { key = "detail", label = "Technical detail", type = "string", default = "medium",
    choices = { "low", "medium", "high" },
    desc = "How much mechanism and reasoning answers carry." },
  { key = "comments", label = "Code comments", type = "string", default = "normal",
    choices = { "none", "sparse", "normal" },
    desc = "Comment policy for code the model writes." },
  { key = "autonomy", label = "Autonomy", type = "string", default = "normal",
    choices = { "careful", "normal", "high" },
    desc = "Ask first on ambiguity, or proceed on stated assumptions." },
  { key = "read_before_edit", label = "Read before edit", type = "boolean", default = false,
    desc = "Refuse edit_file on files the model has not read this turn." },
  { key = "custom", label = "Custom rules", type = "string", default = "",
    desc = "Your own working-style rules, one per line or ;-separated; `/behavior add <rule>` appends one." },
}

bone.settings.page({ name = "behavior", title = "Behavior", fields = FIELDS })

bone.cmd.create("behavior", function(c)
  local knob, value = c.args:match("^(%S+)%s+(.+)$")
  if value then value = value:match("^%s*(.-)%s*$") end
  if not knob then
    if c.args:match("^%s*clear%s*$") then knob, value = "clear", "" else
      return require("bone.config").open("behavior")
    end
  end
  if knob == "add" or knob == "clear" then
    -- /behavior add <rule>: append a custom rule; /behavior clear: drop them.
    local now = bone.settings.get("behavior.custom")
    local next_
    if knob == "clear" then
      next_ = ""
    else
      if not value or value == "" then
        return bone.notify("usage: /behavior add <rule text>", "error")
      end
      now = type(now) == "string" and now or ""
      next_ = now == "" and value or (now .. "\n" .. value)
    end
    return bone.settings.set("behavior.custom", next_, function(_, err)
      if err then
        return bone.notify("behavior: " .. tostring(err), "error")
      end
      bone.notify(knob == "clear" and "behavior: custom rules cleared"
        or ("behavior: added rule — " .. value))
    end)
  end
  local known
  for _, f in ipairs(FIELDS) do
    if f.key == knob then known = f end
  end
  if not known then
    return bone.notify("behavior: unknown knob " .. knob, "error")
  end
  local v
  if known.type == "integer" then
    v = tonumber(value)
  elseif known.type == "boolean" then
    if value == "on" or value == "true" then v = true end
    if value == "off" or value == "false" then v = false end
  elseif known.choices then
    for _, choice in ipairs(known.choices) do
      if value == choice then v = value end
    end
  else
    v = value
  end
  if v == nil then
    local usage = known.type == "integer" and "N"
      or known.type == "boolean" and "on|off"
      or (known.choices and table.concat(known.choices, "|"))
      or "<text>"
    return bone.notify("usage: /behavior " .. knob .. " " .. usage, "error")
  end
  bone.settings.set("behavior." .. knob, v, function(_, err)
    if err then
      return bone.notify("behavior: " .. tostring(err), "error")
    end
    bone.notify("behavior." .. knob .. " = " .. tostring(v))
  end)
end, {
  desc = "behavior knobs: narration, discipline levels, tone, conciseness (behavior plugin)",
  complete = function()
    local out = { { value = "add", desc = "append a custom rule: /behavior add <rule text>" },
      { value = "clear", desc = "remove every custom rule added from the app" } }
    for _, f in ipairs(FIELDS) do
      out[#out + 1] = { value = f.key, desc = f.desc }
    end
    return out
  end,
})
