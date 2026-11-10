-- Behavior: tunable knobs for how the model works and communicates.
-- Configure in core.lua; every knob has a default and can be turned off.
--
--   bone.config.behavior = {
--     narrate_every = 6,           -- nudge after N silent tool calls (0 = off)
--     ending = true,               -- never end a turn on a plan or progress note
--     verify = true,               -- prove changes before finishing, or say "unverified"
--     minimal_diffs = true,        -- change only what the task requires
--     no_unrequested_files = true, -- no new tests/docs/helpers unless asked
--     final_format = true,         -- final message: outcome first, at most 6 lines
--     read_before_edit = false,    -- refuse edit_file on files not read this turn
--   }

local defaults = {
  narrate_every = 6,
  ending = true,
  verify = true,
  minimal_diffs = true,
  no_unrequested_files = true,
  final_format = true,
  read_before_edit = false,
}

local function conf()
  -- Precedence follows bone's convention: choices made in the app
  -- (settings.json, the /behavior page) beat core.lua, which beats defaults.
  local c = bone.config.behavior or {}
  local out = {}
  for k, v in pairs(defaults) do
    local s = bone.settings.get("behavior." .. k)
    if s ~= nil then
      out[k] = s
    elseif c[k] ~= nil then
      out[k] = c[k]
    else
      out[k] = v
    end
  end
  return out
end

-- The working-style contract, assembled from the enabled knobs and appended
-- to the system prompt once per turn.
bone.hook("system", function(ev)
  local c = conf()
  local rules = {}
  if (c.narrate_every or 0) > 0 then
    rules[#rules + 1] = "The user watches your work live. Between batches of tool calls, write one"
      .. " short line saying what you are doing or what you found. Never run long stretches of"
      .. " tools in silence."
  end
  if c.ending then
    rules[#rules + 1] = "A reply without tool calls ends your turn. Never end on a plan, a progress"
      .. " note, or a question a tool could answer; do the work instead. End only when the task is"
      .. " done or you are genuinely blocked on the user."
  end
  if c.verify then
    rules[#rules + 1] = "Before finishing, run the command that proves your change (the failing"
      .. " test, the named script). If you cannot verify, say \"unverified\" plainly in your final"
      .. " message."
  end
  if c.minimal_diffs then
    rules[#rules + 1] = "Change only what the task requires. No reformatting, renaming, comment"
      .. " churn or drive-by refactors."
  end
  if c.no_unrequested_files then
    rules[#rules + 1] = "Do not create files nobody asked for (tests, docs, helper scripts)."
  end
  if c.final_format then
    rules[#rules + 1] = "Final message: lead with what changed and what proved it, in at most six"
      .. " lines. Do not restate the diff."
  end
  if #rules == 0 then return end
  return { prompt = ev.prompt .. "\n\n## Working style\n- " .. table.concat(rules, "\n- ") }
end, { priority = 900 })

-- Mechanics: count tool results since the model last said anything to the
-- user; at every narrate_every-th silent call, append a reminder to the tool
-- result (the same pattern the todo plugin uses for stale checklists).
local silent = {}
local seen = {}

bone.hook("turn_start", function(ev)
  silent[ev.session_id] = 0
  seen[ev.session_id] = {}
end)

bone.hook("turn_end", function(ev)
  silent[ev.session_id] = nil
  seen[ev.session_id] = nil
end)

bone.hook("message", function(ev)
  if (ev.content or "") ~= "" then silent[ev.session_id] = 0 end
end)

bone.hook("tool_call", function(ev)
  local c = conf()
  local s = seen[ev.session_id]
  if s and type(ev.arguments) == "table" and type(ev.arguments.path) == "string" then
    local path = ev.arguments.path:gsub("^%./", "")
    if ev.name == "read_file" or ev.name == "write_file" then
      s[path] = true
    elseif ev.name == "edit_file" and c.read_before_edit and not s[path] then
      return { deny = "behavior: read " .. path .. " with read_file before editing it" }
    end
  end
end)

bone.hook("tool_result", function(ev)
  local c = conf()
  if (c.narrate_every or 0) <= 0 then return end
  local n = (silent[ev.session_id] or 0) + 1
  silent[ev.session_id] = n
  -- Once overdue, the note repeats on every silent call until the model
  -- actually says something; a single reminder is too easy to shrug off.
  if n >= c.narrate_every then
    return { output = (ev.output or "") .. "\n\n[behavior] " .. n .. " tool calls and the user has"
      .. " heard nothing. In your next reply, write one short line about what you are doing or"
      .. " what you found, then continue. This note repeats until you do." }
  end
end)
