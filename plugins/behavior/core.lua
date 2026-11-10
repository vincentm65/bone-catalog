-- Behavior: tunable knobs for how the model works and communicates.
-- Each discipline has levels of impact; style fields shape the voice.
-- Configure from the app (/behavior), settings.json, or core.lua:
--
--   bone.config.behavior = {
--     narrate_every = 0,          -- nudge after N silent tool calls (0 = off)
--     ending = "off",             -- off | light | standard | strict
--     verify = "off",             -- off | light | standard | strict
--     scope = "off",              -- off | light | standard | strict
--     tone = "plain",             -- plain | friendly | dry | formal
--     conciseness = "normal",     -- chatty | normal | concise | terse
--     detail = "medium",          -- low | medium | high
--     comments = "normal",        -- none | sparse | normal
--     autonomy = "normal",        -- careful | normal | high
--     read_before_edit = false,   -- refuse edit_file on files not read this turn
--   }
--
-- Everything defaults to off (the neutral level): installed, the plugin does
-- nothing until a knob is raised. App choices (settings.json, the /behavior
-- page) beat core.lua, which beats these defaults. 0.2.0 booleans still work:
-- true means "standard", false means "off" (minimal_diffs /
-- no_unrequested_files fold into scope).

local defaults = {
  narrate_every = 0,
  ending = "off",
  verify = "off",
  scope = "off",
  tone = "plain",
  conciseness = "normal",
  detail = "medium",
  comments = "normal",
  autonomy = "normal",
  read_before_edit = false,
}

-- The rule each field contributes per level. A missing level is silence:
-- the model's default behavior is already that level.
local RULES = {
  ending = {
    light = "Prefer not to end a turn on a plan: if you state a next step, usually do it first.",
    standard = "A reply without tool calls ends your turn. Never end on a plan, a progress note,"
      .. " or a question a tool could answer; do the work instead. End only when the task is done"
      .. " or you are genuinely blocked on the user.",
    strict = "A reply without tool calls ends your turn. Never end on a plan, a progress note, or"
      .. " a question a tool could answer. Before your final reply, re-read it: if it speaks in"
      .. " future tense about your own work, execute that work instead of sending it.",
  },
  verify = {
    light = "When a cheap command can prove your change works, run it before finishing.",
    standard = "Before finishing, run the command that proves your change (the failing test, the"
      .. " named script). If you cannot verify, say \"unverified\" plainly in your final message.",
    strict = "Never claim success you have not proved this turn. Before finishing, run the command"
      .. " that demonstrates the change and name it, with its result, in your final message; if"
      .. " nothing can prove it, lead the final message with \"unverified\".",
  },
  scope = {
    light = "Keep changes focused on the task at hand.",
    standard = "Change only what the task requires: no reformatting, renaming, comment churn or"
      .. " drive-by refactors, and no new files nobody asked for (tests, docs, helpers).",
    strict = "Change only what the task requires: no reformatting, renaming or refactors beside"
      .. " the point, and no new files nobody asked for. If you must touch a file beyond the"
      .. " obvious ones, name it in your final message with a one-line reason.",
  },
  tone = {
    friendly = "Write warmly and conversationally.",
    dry = "Keep a dry, matter-of-fact voice: no enthusiasm, no apologies, no filler.",
    formal = "Write formally and precisely.",
  },
  conciseness = {
    chatty = "Explain as you go; thoroughness beats brevity.",
    concise = "Keep every message short. Final message: lead with what changed and what proved"
      .. " it, in at most six lines; do not restate the diff.",
    terse = "Minimum words everywhere. Progress notes are one line. Final message: at most three"
      .. " lines, outcome first, nothing restated.",
  },
  detail = {
    low = "State results; skip mechanism and background unless asked.",
    high = "Explain the mechanism behind findings and fixes: why it broke, why the fix is right,"
      .. " and what you ruled out.",
  },
  comments = {
    none = "Write no code comments unless the code is genuinely non-obvious.",
    sparse = "Comment only what the code cannot say: constraints, invariants and whys — never"
      .. " what the next line does.",
  },
  autonomy = {
    careful = "When a decision is ambiguous or hard to reverse, stop and ask the user before"
      .. " acting on it.",
    high = "Proceed on reasonable assumptions without asking, and state each assumption in one"
      .. " line. Ask only when a wrong guess would destroy work or data.",
  },
}

-- 0.2.0 compatibility: booleans for the old keys.
local function compat(c)
  local out = {}
  for k, v in pairs(c) do
    out[k] = v
  end
  for _, k in ipairs({ "ending", "verify" }) do
    if type(out[k]) == "boolean" then
      out[k] = out[k] and "standard" or "off"
    end
  end
  if out.scope == nil and (out.minimal_diffs ~= nil or out.no_unrequested_files ~= nil) then
    local on = out.minimal_diffs ~= false and out.no_unrequested_files ~= false
    out.scope = on and "standard" or "off"
  end
  if out.conciseness == nil and out.final_format ~= nil then
    out.conciseness = out.final_format and "concise" or "normal"
  end
  return out
end

local function conf()
  local c = compat(bone.config.behavior or {})
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
  -- Settings saved by the 0.2.0 page: booleans for the leveled keys, and the
  -- old key names (only when the new key was never set anywhere).
  for _, k in ipairs({ "ending", "verify", "scope" }) do
    if type(out[k]) == "boolean" then
      out[k] = out[k] and "standard" or "off"
    end
  end
  if bone.settings.get("behavior.scope") == nil and c.scope == nil then
    local md = bone.settings.get("behavior.minimal_diffs")
    local nf = bone.settings.get("behavior.no_unrequested_files")
    if md ~= nil or nf ~= nil then
      out.scope = (md ~= false and nf ~= false) and "standard" or "off"
    end
  end
  if bone.settings.get("behavior.conciseness") == nil and c.conciseness == nil
    and bone.settings.get("behavior.final_format") then
    out.conciseness = "concise"
  end
  return out
end

bone.hook("system", function(ev)
  local c = conf()
  local rules = {}
  if (tonumber(c.narrate_every) or 0) > 0 then
    rules[#rules + 1] = "The user watches your work live. Between batches of tool calls, write one"
      .. " short line saying what you are doing or what you found. Never run long stretches of"
      .. " tools in silence."
  end
  for _, field in ipairs({ "ending", "verify", "scope", "tone", "conciseness", "detail",
    "comments", "autonomy" }) do
    local rule = RULES[field][tostring(c[field])]
    if rule then
      rules[#rules + 1] = rule
    end
  end
  if #rules == 0 then
    return
  end
  return { prompt = ev.prompt .. "\n\n## Working style\n- " .. table.concat(rules, "\n- ") }
end, { priority = 900 })

-- Mechanics: count tool results since the model last said anything to the
-- user; once overdue, the note repeats on every silent call until it speaks.
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
  local every = tonumber(conf().narrate_every) or 0
  if every <= 0 then return end
  local n = (silent[ev.session_id] or 0) + 1
  silent[ev.session_id] = n
  if n >= every then
    return { output = (ev.output or "") .. "\n\n[behavior] " .. n .. " tool calls and the user has"
      .. " heard nothing. In your next reply, write one short line about what you are doing or"
      .. " what you found, then continue. This note repeats until you do." }
  end
end)
