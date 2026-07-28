-- /shotgun — fan a prompt out to several provider sub-agents, then let the
-- primary chat agent synthesize their answers into one final reply.
--
-- Configure fan-out targets in /config under Shotgun. Targets are a
-- comma-separated list of provider ids, optionally followed by /model:
--
--   deepseek, minimax, openrouter/anthropic/claude-sonnet-4
--
-- Usage: /shotgun <prompt>
--   The prompt is sent to every configured provider as an independent
--   sub-agent (visible in the normal subagent pane). When they finish, their
--   answers are handed back to the current chat model, which reviews them and
--   writes the final synthesized answer as its normal turn.

bone.settings.register({
  namespace = "shotgun",
  title = "Shotgun",
  fields = {
    {
      key = "targets",
      label = "Reviewer targets",
      type = "string",
      default = "",
    },
  },
})

local CONFIG = {
  timeout_ms = 300000,
  max_result_chars = 50000,
  max_synthesis_chars = 100000,
  reviewer_guide = table.concat({
    "Answer the prompt below directly and on its merits.",
    "Show your reasoning, not just a verdict: state the key assumptions, the evidence or",
    "logic behind your answer, and the main tradeoffs.",
    "Call out anything you are uncertain about and what would change your mind.",
    "Be concrete and specific. Do not hedge to cover every case; commit to a best answer.",
  }, "\n"),
  synthesis_guide = table.concat({
    "Below are independent answers from several reviewers to my prompt.",
    "Weigh them on the strength of their reasoning and evidence, NOT by how many agree:",
    "the reviewers share blind spots, so a shared conclusion is not automatically more reliable.",
    "- Adopt the strongest argument regardless of which reviewer made it.",
    "- If reviewers conflict on a verifiable fact, say so and verify rather than picking a side.",
    "- Flag anything only one reviewer caught and judge it on its merits.",
    "- Note genuine uncertainty instead of papering over it.",
    "End with a clear recommendation or final answer, in your own words.",
  }, "\n"),
}

local function trim(s)
  return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate(s, max)
  s = tostring(s or "")
  if #s <= max then return s end
  local suffix = "\n... (truncated)"
  if max <= #suffix then return suffix:sub(1, max) end
  local limit = max - #suffix
  for cut = limit, math.max(0, limit - 4), -1 do
    local prefix = s:sub(1, cut)
    local ok, length = pcall(utf8.len, prefix)
    if ok and length then return prefix .. suffix end
  end
  return suffix
end

local function shotgun_targets(ctx)
  local entries = {}
  local configured = ctx.settings.get("shotgun.targets") or ""
  for raw_target in tostring(configured):gmatch("[^,]+") do
    local target = trim(raw_target)
    local provider, model = target:match("^([^/]+)/(.+)$")
    if not provider then provider = target end
    if provider ~= "" then
      entries[#entries + 1] = { provider = provider, model = model }
    end
  end
  return entries
end

local function provider_map(ctx)
  local map = {}
  if not (ctx.config and ctx.config.list_providers) then return map end
  for _, provider in ipairs(ctx.config.list_providers() or {}) do
    map[provider.id] = provider
  end
  return map
end

local function model_for(entry, providers)
  if entry.model and entry.model ~= "" then return entry.model end
  local provider = providers[entry.provider]
  return provider and provider.model or nil
end

local function describe_entry(entry, providers)
  local model = model_for(entry, providers)
  if model and model ~= "" then
    return tostring(entry.provider) .. "/" .. tostring(model)
  end
  return tostring(entry.provider)
end

local function agent_opts(provider, model, label)
  local opts = { timeout_ms = CONFIG.timeout_ms }
  if provider and provider ~= "" then opts.provider = provider end
  if model and model ~= "" then opts.model = model end
  if label then opts.agent = label end
  return opts
end

local function reviewer_prompt(task)
  return CONFIG.reviewer_guide .. "\n\n## Prompt\n" .. task
end

local function synthesis_prompt(task, analyses, errors)
  local parts = { CONFIG.synthesis_guide, "", "## My prompt", task }
  local error_parts = {}
  if #errors > 0 then
    error_parts = { "", "## Reviewers that did not respond" }
    for _, err in ipairs(errors) do
      error_parts[#error_parts + 1] = "- " .. err
    end
  end

  -- Label reviewers numerically rather than by model id, so the synthesizer weighs
  -- arguments on their merits instead of deferring to a "trusted" brand. The job
  -- pane still shows the real provider/model labels for traceability.
  local fixed = #table.concat(parts, "\n") + #table.concat(error_parts, "\n")
  local headers = {}
  for i = 1, #analyses do
    headers[i] = "\n## Reviewer " .. i
    fixed = fixed + #headers[i] + 1
  end
  local per_reviewer = math.max(0,
    math.floor((CONFIG.max_synthesis_chars - fixed) / math.max(1, #analyses)))

  for i, text in ipairs(analyses) do
    parts[#parts + 1] = ""
    parts[#parts + 1] = "## Reviewer " .. i
    parts[#parts + 1] = truncate(text, math.min(CONFIG.max_result_chars, per_reviewer))
  end
  for _, part in ipairs(error_parts) do parts[#parts + 1] = part end
  return truncate(table.concat(parts, "\n"), CONFIG.max_synthesis_chars)
end

-- After cancellation/timeout, drain the still-pending jobs so their late
-- results don't auto-inject as a stray chat turn.
local function drain_pending(ctx, pending)
  if not (pending and #pending > 0) then return end
  for _, id in ipairs(pending) do
    ctx.agent.cancel(id)
  end
  ctx.agent.wait(pending, { timeout_ms = 10000 })
end

bone.command.register("shotgun", {
  description = "Fan a prompt out to configured providers; the chat agent synthesizes the answers",
  handler = function(arg, ctx)
    local task = trim(arg)
    if task == "" then
      return { display = "shotgun: provide a prompt, e.g. /shotgun should we cache this?", submit = false }
    end

    local entries = shotgun_targets(ctx)
    if #entries == 0 then
      return {
        display = table.concat({
          "shotgun: no targets configured.",
          "",
          "Set Shotgun > Reviewer targets in /config using comma-separated provider or provider/model entries.",
        }, "\n"),
        submit = false,
      }
    end

    local providers = provider_map(ctx)
    local prompt = reviewer_prompt(task)
    local ids = {}
    local labels = {}
    local errors = {}

    for i, entry in ipairs(entries) do
      if not providers[entry.provider] then
        errors[#errors + 1] = tostring(entry.provider) .. ": unknown provider"
      else
        local label = describe_entry(entry, providers)
        local spawned = ctx.agent.spawn(prompt, agent_opts(entry.provider, entry.model, "shotgun " .. label .. " #" .. i))
        if spawned and spawned.ok then
          ids[#ids + 1] = spawned.id
          labels[spawned.id] = label
        else
          errors[#errors + 1] = label .. ": " .. tostring(spawned and spawned.error or "spawn failed")
        end
      end
    end

    if #ids == 0 then
      return { display = "shotgun: no reviewers started.\n- " .. table.concat(errors, "\n- "), submit = false }
    end

    local waited = ctx.agent.wait(ids, { timeout_ms = CONFIG.timeout_ms })
    if waited and waited.cancelled then
      drain_pending(ctx, waited.pending or ids)
      return { display = "shotgun: cancelled", submit = false }
    end

    local analyses = {}
    if waited and type(waited.jobs) == "table" then
      for _, job in ipairs(waited.jobs) do
        local label = labels[job.id] or job.agent or job.id
        if job.status == "done" then
          analyses[#analyses + 1] = job.result or ""
        else
          errors[#errors + 1] = label .. ": " .. tostring(job.result or "error")
        end
      end
    end
    if waited and type(waited.pending) == "table" then
      for _, id in ipairs(waited.pending) do
        errors[#errors + 1] = (labels[id] or id) .. ": timed out"
      end
      drain_pending(ctx, waited.pending)
    end

    if #analyses == 0 then
      return { display = "shotgun: no reviewer responded.\n- " .. table.concat(errors, "\n- "), submit = false }
    end

    return { content = synthesis_prompt(task, analyses, errors), submit = true }
  end,
})
