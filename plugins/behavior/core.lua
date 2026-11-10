-- Behavior: tunable knobs for how the model works and communicates.
-- Disciplines have levels of impact; style fields shape the voice; the
-- mechanics enforce what prompts cannot. Everything defaults to off.
--
--   bone.config.behavior = {
--     narrate_every = 0,          -- nudge after N silent tool calls (0 = off)
--     max_tool_calls = 0,         -- wrap-up note past N tool calls a turn (0 = off)
--     repeat_guard = 0,           -- note after N identical failing commands (0 = off)
--     ending = "off",             -- off | light | standard | strict
--     verify = "off",             -- off | light | standard | strict (standard+ stamps
--                                 --   unverified finals mechanically)
--     scope = "off",              -- off | light | standard | strict
--     tone = "plain",             -- plain | friendly | dry | formal
--     conciseness = "normal",     -- chatty | normal | concise | terse
--     detail = "medium",          -- low | medium | high
--     comments = "normal",        -- none | sparse | normal
--     autonomy = "normal",        -- careful | normal | high
--     read_before_edit = false,   -- refuse edit_file on files not read this turn
--     custom = { "..." },         -- your own rules
--     models = {                  -- per-model overrides, matched against the
--       ["deepseek*"] = { narrate_every = 6 },   -- session's model (* matches any)
--     },
--   }
--
-- Precedence, most specific first: the project's .behavior.json (in the
-- session cwd), a matching `models` profile, app settings (/behavior page),
-- core.lua, defaults. 0.2.0 booleans still work (true = standard, false =
-- off; minimal_diffs/no_unrequested_files fold into scope, final_format into
-- conciseness). `lua/call` name "behavior.stats" returns the session's
-- counters and effective knobs.

local defaults = {
  narrate_every = 0,
  max_tool_calls = 0,
  repeat_guard = 0,
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

-- Per-session state: turn-local trackers plus session-cumulative stats.
local S = {}

local function state(sid)
  local s = S[sid]
  if not s then
    s = { silent = 0, total = 0, seen = {}, dirty = false, fail_cmd = nil, fail_n = 0,
      project = nil, stats = { nudges = 0, budget = 0, repeats = 0, stamps = 0, max_streak = 0 } }
    S[sid] = s
  end
  return s
end

-- 0.2.0 compatibility: booleans for the old keys.
local function compat(c)
  local out = {}
  for k, v in pairs(c) do
    out[k] = v
  end
  for _, k in ipairs({ "ending", "verify", "scope" }) do
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

-- The session's model, for `models` profiles: pinned model first, then the
-- configured provider's.
local function session_model(sid)
  local ok, snap = pcall(bone.session.snapshot, sid)
  local m = ok and snap and snap.model or nil
  if type(m) == "table" then m = m.model or m.name end
  if type(m) ~= "string" or m == "" then
    local p = bone.config.providers and bone.config.providers[bone.config.provider]
    m = p and p.model
  end
  return type(m) == "string" and m or ""
end

local function glob_match(pattern, text)
  local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"):gsub("%*", ".*") .. "$"
  return text:lower():match(lua:lower()) ~= nil
end

local function model_profile(sid)
  local models = (bone.config.behavior or {}).models
  if type(models) ~= "table" then return nil end
  local name = session_model(sid)
  if name == "" then return nil end
  for pattern, knobs in pairs(models) do
    if type(pattern) == "string" and type(knobs) == "table" and glob_match(pattern, name) then
      return knobs
    end
  end
end

-- Effective knobs: defaults < core.lua < app settings < models profile <
-- the project's .behavior.json.
local function conf(sid)
  local c = compat(bone.config.behavior or {})
  local profile = sid and compat(model_profile(sid) or {}) or {}
  local project = sid and S[sid] and compat(S[sid].project or {}) or {}
  local out = {}
  for k, v in pairs(defaults) do
    local s = bone.settings.get("behavior." .. k)
    if project[k] ~= nil then
      out[k] = project[k]
    elseif profile[k] ~= nil then
      out[k] = profile[k]
    elseif s ~= nil then
      out[k] = s
    elseif c[k] ~= nil then
      out[k] = c[k]
    else
      out[k] = v
    end
  end
  for _, k in ipairs({ "ending", "verify", "scope" }) do
    if type(out[k]) == "boolean" then
      out[k] = out[k] and "standard" or "off"
    end
  end
  if bone.settings.get("behavior.scope") == nil and c.scope == nil and project.scope == nil
    and profile.scope == nil then
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
  -- Custom rules are additive across every layer.
  out.custom = {}
  local seen_rule = {}
  local function add(v)
    if type(v) == "string" then
      for line in v:gmatch("[^\n;]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not seen_rule[line] then
          seen_rule[line] = true
          out.custom[#out.custom + 1] = line
        end
      end
    elseif type(v) == "table" then
      for _, s in ipairs(v) do add(s) end
    end
  end
  add(c.custom)
  add(bone.settings.get("behavior.custom"))
  add(profile.custom)
  add(project.custom)
  return out
end

bone.hook("system", function(ev)
  local c = conf(ev.session_id)
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
  for _, rule in ipairs(c.custom) do
    rules[#rules + 1] = rule
  end
  if #rules == 0 then
    return
  end
  return { prompt = ev.prompt .. "\n\n## Working style\n- " .. table.concat(rules, "\n- ") }
end, { priority = 900 })

bone.hook("turn_start", function(ev)
  local s = state(ev.session_id)
  s.silent, s.total, s.seen, s.dirty, s.fail_cmd, s.fail_n = 0, 0, {}, false, nil, 0
  -- The project may pin its own knobs in <cwd>/.behavior.json.
  s.project = nil
  if type(ev.cwd) == "string" then
    local f = io.open(ev.cwd .. "/.behavior.json", "r")
    if f then
      local body = f:read("*a")
      f:close()
      local ok, data = pcall(bone.json.decode, body)
      if ok and type(data) == "table" then s.project = data end
    end
  end
end)

bone.hook("message", function(ev)
  local s = state(ev.session_id)
  if (ev.content or "") ~= "" then
    if s.silent > s.stats.max_streak then s.stats.max_streak = s.silent end
    s.silent = 0
  end
  -- The final reply of a turn carries no tool calls. If edits were made and
  -- no command ran afterwards, say so where the model cannot: on the answer.
  if (ev.tool_calls == nil or #ev.tool_calls == 0) and s.dirty and (ev.content or "") ~= "" then
    local level = conf(ev.session_id).verify
    if level == "standard" or level == "strict" then
      s.stats.stamps = s.stats.stamps + 1
      return { content = "⚠ unverified: files were edited and no command ran afterwards.\n\n"
        .. ev.content }
    end
  end
end)

bone.hook("tool_call", function(ev)
  local c = conf(ev.session_id)
  local s = state(ev.session_id)
  if type(ev.arguments) == "table" and type(ev.arguments.path) == "string" then
    local path = ev.arguments.path:gsub("^%./", "")
    if ev.name == "read_file" or ev.name == "write_file" then
      s.seen[path] = true
    elseif ev.name == "edit_file" and c.read_before_edit and not s.seen[path] then
      return { deny = "behavior: read " .. path .. " with read_file before editing it" }
    end
  end
  if ev.name == "shell" and type(ev.arguments) == "table" then
    s.cmd = ev.arguments.command
  end
end)

bone.hook("tool_result", function(ev)
  local c = conf(ev.session_id)
  local s = state(ev.session_id)
  s.total = s.total + 1
  s.silent = s.silent + 1
  local notes = {}
  local every = tonumber(c.narrate_every) or 0
  if every > 0 and s.silent >= every then
    s.stats.nudges = s.stats.nudges + 1
    notes[#notes + 1] = s.silent .. " tool calls and the user has heard nothing. In your next"
      .. " reply, write one short line about what you are doing or what you found, then continue."
      .. " This note repeats until you do."
  end
  local budget = tonumber(c.max_tool_calls) or 0
  if budget > 0 and s.total >= budget and (s.total - budget) % 5 == 0 then
    s.stats.budget = s.stats.budget + 1
    notes[#notes + 1] = s.total .. " tool calls this turn. Wrap up: finish directly, or stop and"
      .. " summarize what is done and what remains."
  end
  if ev.name == "edit_file" or ev.name == "write_file" then
    if not ev.is_error then s.dirty = true end
  elseif ev.name == "shell" then
    -- A failing command is not a failing tool call: the shell tool returns
    -- is_error = false and reports "[exit code: N]" in the output instead.
    local code = tonumber((ev.output or ""):match("%[exit code: (%d+)%]%s*$"))
    if ev.is_error or (code and code ~= 0) then
      local cmd = s.cmd
      if cmd ~= nil and cmd == s.fail_cmd then
        s.fail_n = s.fail_n + 1
      else
        s.fail_cmd, s.fail_n = cmd, 1
      end
      local guard = tonumber(c.repeat_guard) or 0
      if guard > 0 and s.fail_n >= guard and (s.fail_n - guard) % guard == 0 then
        s.stats.repeats = s.stats.repeats + 1
        notes[#notes + 1] = "that command has now failed " .. s.fail_n .. " times in a row. Stop"
          .. " retrying it: change the approach, or explain what blocks you."
      end
    else
      s.fail_cmd, s.fail_n = nil, 0
      s.dirty = false
    end
  end
  if #notes > 0 then
    local out = ev.output or ""
    for _, n in ipairs(notes) do
      out = out .. "\n\n[behavior] " .. n
    end
    return { output = out }
  end
end)

bone.hook("turn_end", function(ev)
  local s = S[ev.session_id]
  if s and s.silent > s.stats.max_streak then s.stats.max_streak = s.silent end
end)

bone.rpc.register("behavior.stats", function(args, ctx)
  local sid = (args and args.session_id) or ctx.session_id
  local s = sid and S[sid]
  return { stats = s and s.stats or {}, effective = conf(sid), model = sid and session_model(sid) or "" }
end)
