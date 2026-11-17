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
  local captured = requests[id]
  local prompt = captured
  if not prompt then
    local base = os.getenv("BONE_SYSTEM_PROMPT") or bone.config.system_prompt
    if type(base) == "string" then
      prompt = { system_bytes = #(base .. "\n\nWorking directory: " .. s.info.cwd) }
    end
  end
  local cal = calibration[id]
  local compact = bone.settings.get("compact") or {}
  local limit = options.compact_limit
  if limit == nil then limit = compact.limit or (bone.config.compact or {}).limit end
  return {
    session_id = id, title = s.info.title, provider = provider, model = pin.model or options.model,
    current = B.finish(B.current(s, prompt, options.replay_reasoning)),
    request = captured and captured.breakdown, request_at = captured and captured.at,
    usage = usage[id], compact_limit = limit,
    bytes_per_token = cal and cal.per or B.BYTES_PER_TOKEN, calibrated = cal ~= nil,
  }
end)
