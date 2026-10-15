local B = require("context.breakdown")
-- Keep only accounting, not copies of conversations or prompts. Reloading clears it.
local requests, usage, calibration = {}, {}, {}

bone.hook("request", function(ev)
  local definitions = B.definitions(ev.tools)
  local d = B.new()
  B.messages(d, ev.messages)
  B.add_definitions(d, definitions)
  requests[ev.session_id] = {
    at = os.time(), definitions = definitions, breakdown = B.finish(d),
    system_bytes = ev.messages[1] and ev.messages[1].role == "system" and #(ev.messages[1].content or "") or nil,
  }
end, { priority = -1000000 })

-- The provider's count for the request just observed calibrates bytes per
-- token for this conversation, as Bone's own compaction estimate does.
bone.hook("message", function(ev)
  local u = ev.usage
  if type(u) ~= "table" then return end
  usage[ev.session_id] = u
  local sent, counted = requests[ev.session_id], tonumber(u.context_tokens) or tonumber(u.input_tokens)
  if sent and counted and counted > 0 then
    local per = sent.breakdown.bytes / counted
    if per >= 1 and per <= 10 then calibration[ev.session_id] = { per = per, tokens = counted } end
  end
end, { priority = -1000000 })

bone.rpc.register("context.get", function(args, ctx)
  local id = (args or {}).session_id or ctx.session_id
  assert(type(id) == "string" and id ~= "", "context: no conversation selected")
  local s = bone.session.snapshot(id)
  local pin = type(s.model) == "table" and s.model or {}
  local provider = pin.provider or bone.settings.get("provider") or bone.config.provider
  local options = {}
  for k, v in pairs((bone.config.providers or {})[provider] or {}) do options[k] = v end
  for k, v in pairs(bone.settings.get("providers." .. tostring(provider)) or {}) do options[k] = v end
  local captured, notes = requests[id], {}
  local prompt = captured
  if not prompt then
    local base = os.getenv("BONE_SYSTEM_PROMPT") or bone.config.system_prompt
    if type(base) == "string" then
      prompt = { system_bytes = #(base .. "\n\nWorking directory: " .. s.info.cwd) }
      notes[#notes + 1] = "System prompt is from configuration; system hooks have not been observed yet."
    else
      notes[#notes + 1] = "Dynamic system prompt unavailable until this conversation makes a model request."
    end
  end
  if not captured then
    notes[#notes + 1] = "Tool schemas are unknown until this conversation's next model request (not in the total)."
  else
    notes[#notes + 1] = "System prompt and tool schemas are from this conversation's last observed request."
  end
  local cal = calibration[id]
  if cal then
    notes[#notes + 1] = ("Calibrated: the provider counted %d tokens for the last observed request (%.2f bytes/token)."):format(cal.tokens, cal.per)
  else
    notes[#notes + 1] = "Uncalibrated: 4 bytes/token until the provider reports a count for this conversation."
  end
  notes[#notes + 1] = "Provider framing, opaque reasoning and later request rewrites can differ."
  if options.replay_reasoning ~= false then
    notes[#notes + 1] = "Text reasoning is included as potential replay; the provider may omit it."
  end
  if s.active_turn then notes[#notes + 1] = "A turn is running; unsaved streaming output is not included." end
  local compact = bone.settings.get("compact") or {}
  local limit = options.compact_limit
  if limit == nil then limit = compact.limit or (bone.config.compact or {}).limit end
  return {
    session_id = id, title = s.info.title, provider = provider, model = pin.model or options.model,
    current = B.finish(B.current(s, prompt, options.replay_reasoning)),
    request = captured and captured.breakdown, request_at = captured and captured.at,
    usage = usage[id], compact_limit = limit, notes = notes,
    bytes_per_token = cal and cal.per or B.BYTES_PER_TOKEN, calibrated = cal ~= nil,
  }
end)
