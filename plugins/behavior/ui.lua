-- behavior, frontend side (TUI and GUI):
--   /behavior                 open the knobs as a settings page
--   /behavior <knob> <value>  set one directly: /behavior narrate_every 4,
--                             /behavior verify strict, /behavior detail high

local FIELDS = {
  { header = "Discipline" },
  { key = "narrate_every", label = "Narration nudge", type = "integer", default = 0, min = 0, max = 50,
    desc = "Remind the model to say something after this many silent tool calls; the note repeats until it does (0 = off)." },
  { key = "max_tool_calls", label = "Turn budget", type = "integer", default = 0, min = 0, max = 200,
    desc = "Past this many tool calls in one turn, tell the model to wrap up or summarize state (0 = off)." },
  { key = "repeat_guard", label = "Repeat guard", type = "integer", default = 0, min = 0, max = 20,
    desc = "After this many identical failing commands in a row, tell the model to change approach (0 = off)." },
  { key = "ending", label = "Ending", type = "string", default = "off",
    choices = { "off", "light", "standard", "strict" },
    desc = "light: prefer acting over announcing · standard: never end on a plan · strict: re-read the final reply for unexecuted work." },
  { key = "verify", label = "Verify", type = "string", default = "off",
    choices = { "off", "light", "standard", "strict" },
    desc = "light: prove when cheap · standard: proving command or say unverified · strict: name the command and result in the final message." },
  { key = "scope", label = "Diff scope", type = "string", default = "off",
    choices = { "off", "light", "standard", "strict" },
    desc = "light: stay focused · standard: no refactors or files nobody asked for · strict: justify every extra file touched." },
  { key = "read_before_edit", label = "Read before edit", type = "boolean", default = false,
    desc = "Refuse edit_file on files not read this turn (shell reads do not count)." },
  { header = "Voice" },
  { key = "conciseness", label = "Conciseness", type = "string", default = "normal",
    choices = { "chatty", "normal", "concise", "terse" },
    desc = "chatty: explain as you go · concise: six-line finals, outcome first · terse: three lines, minimum words." },
  { key = "detail", label = "Technical detail", type = "string", default = "medium",
    choices = { "low", "medium", "high" },
    desc = "low: results only · high: explain the mechanism and what was ruled out." },
  { key = "comments", label = "Code comments", type = "string", default = "normal",
    choices = { "none", "sparse", "normal" },
    desc = "none: only the truly non-obvious · sparse: constraints and whys, never what the next line does." },
  { header = "Custom" },
  { key = "custom", label = "Custom rules", type = "string", default = "",
    desc = "Your own rules, one per line or ;-separated; /behavior add <rule> appends one, /behavior clear removes them." },
}

bone.settings.page({ name = "behavior", title = "Behavior", fields = FIELDS })

-- Presets: one command flips a whole board of knobs (saved as settings, so
-- the page shows them and `/behavior preset off` resets them all).
local PRESETS = {
  reviewer = { verify = "strict", scope = "strict", detail = "high", ending = "standard" },
  pair = { narrate_every = 3, conciseness = "chatty", detail = "high" },
  ship = { conciseness = "terse", ending = "strict", verify = "standard" },
}

local function apply_preset(name)
  if name == "off" then
    for _, f in ipairs(FIELDS) do
      if f.key then bone.settings.reset("behavior." .. f.key) end
    end
    return bone.notify("behavior: every knob reset to its default")
  end
  local preset = PRESETS[name]
  if not preset then
    local names = { "off" }
    for n in pairs(PRESETS) do names[#names + 1] = n end
    table.sort(names)
    return bone.notify("behavior: no preset " .. name .. " (" .. table.concat(names, ", ") .. ")", "error")
  end
  local parts = {}
  for k, v in pairs(preset) do
    bone.settings.set("behavior." .. k, v)
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  table.sort(parts)
  bone.notify("behavior preset " .. name .. ": " .. table.concat(parts, ", "))
end

bone.cmd.create("behavior", function(c)
  local knob, value = c.args:match("^(%S+)%s+(.+)$")
  if value then value = value:match("^%s*(.-)%s*$") end
  if not knob then
    local bare = c.args:match("^%s*(%S*)%s*$")
    if bare == "clear" then knob, value = "clear", ""
    elseif bare == "stats" then
      return bone.rpc.call("behavior.stats", {}, function(r, err)
        if err or type(r) ~= "table" then
          return bone.notify("behavior: " .. tostring(err or "no stats"), "error")
        end
        local st = r.stats or {}
        bone.notify(("behavior (%s): %d narration nudges, %d budget notes, %d repeat notes, "
          .. "%d unverified stamps, longest silent streak %d")
          :format(r.model or "?", st.nudges or 0, st.budget or 0, st.repeats or 0,
            st.stamps or 0, st.max_streak or 0))
      end)
    else
      return require("bone.config").open("behavior")
    end
  end
  if knob == "preset" then
    return apply_preset(value or "")
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
  desc = "behavior knobs: narration, discipline levels, conciseness (behavior plugin)",
  complete = function()
    local out = { { value = "add", desc = "append a custom rule: /behavior add <rule text>" },
      { value = "clear", desc = "remove every custom rule added from the app" },
      { value = "preset", desc = "apply a bundle: reviewer, pair, ship, or off to reset all" },
      { value = "stats", desc = "what the plugin did this session (nudges, stamps, streaks)" } }
    for _, f in ipairs(FIELDS) do
      if f.key then
        out[#out + 1] = { value = f.key, desc = f.desc }
      end
    end
    return out
  end,
})
