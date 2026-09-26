local function comma(n)
  n = math.floor(tonumber(n) or 0)
  local s = tostring(n)
  local sign = ""
  if s:sub(1, 1) == "-" then
    sign = "-"
    s = s:sub(2)
  end
  local out = s
  while true do
    local next_out, changed = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    out = next_out
    if changed == 0 then break end
  end
  return sign .. out
end

local tokens = comma

local function money(n)
  n = tonumber(n) or 0
  if n <= 0 then return nil end
  return string.format("$%.4f", n)
end

local DIM   = "\x1b[2m"
local CYAN  = "\x1b[36m"
local WHITE = "\x1b[37m"
local RESET = "\x1b[0m"

local function heading(title)
  return string.format("%s%s%s", CYAN, title, RESET)
end

local function klabel(label)
  return string.format("%s%-14s%s", DIM, label .. ":", RESET)
end

local function kvalue(v)
  return string.format("%s%s%s", WHITE, v, RESET)
end

local function kdim(v)
  return string.format("%s%s%s", DIM, v, RESET)
end

local function sep()
  return string.format("%s%s%s", DIM, string.rep("─", 52), RESET)
end

bone.command.register("usage", {
  description = "Show token usage for current conversation",
  handler = function(_, ctx)
    local usage = ctx.usage and ctx.usage.snapshot and ctx.usage.snapshot() or nil
    if not usage then
      return { display = "Usage data is unavailable in this context.", submit = false }
    end

    local total = (usage.sent or 0) + (usage.received or 0)
    local lines = {
      heading("Conversation usage"),
      sep(),
      klabel("Requests") .. kvalue(comma(usage.request_count)),
      klabel("Tokens")   .. kvalue(tokens(total) .. " total"),
      klabel("Input")    .. kvalue(tokens(usage.sent)),
      klabel("Output")   .. kvalue(tokens(usage.received)),
      klabel("Context")  .. kvalue(tokens(usage.context_length) .. " current"),
    }

    local sent = usage.sent or 0
    local cached = usage.cached or 0
    if sent > 0 or cached > 0 then
      table.insert(lines, klabel("Cached") .. kvalue(tokens(cached)))
      local cache_rate = sent > 0 and (cached * 100 / sent) or 0
      table.insert(lines, klabel("Cache rate") .. kvalue(string.format("%.1f%% of input", cache_rate)))
      if cached > 0 and cached < sent then
        table.insert(lines, klabel("New input") .. kvalue(tokens(sent - cached)))
      end
    end
    local cost = money(usage.cost)
    if cost then
      table.insert(lines, klabel("Cost") .. kvalue(cost))
    end
    if (usage.request_count or 0) > 0 then
      table.insert(lines, klabel("Avg/req") .. kvalue(tokens((usage.sent or 0) / usage.request_count) .. " in / " .. tokens((usage.received or 0) / usage.request_count) .. " out"))
    end

    table.insert(lines, "")
    table.insert(lines, heading("Known prompt overhead"))
    table.insert(lines, sep())
    table.insert(lines, klabel("Tools")
      .. kvalue(comma(usage.tool_count) .. " tools · ~" .. tokens(usage.tool_schema_tokens) .. " tokens"))
    table.insert(lines, klabel("System")
      .. kvalue("~" .. tokens(usage.system_prompt_tokens) .. " tokens"))

    local overhead_tokens = (usage.tool_schema_tokens or 0)
      + (usage.system_prompt_tokens or 0)
    table.insert(lines, klabel("Known total") .. kvalue("~" .. tokens(overhead_tokens) .. " tokens"))

    if usage.by_provider and #usage.by_provider > 1 then
      table.insert(lines, "")
      table.insert(lines, heading("By provider/model"))
      table.insert(lines, sep())
      for _, p in ipairs(usage.by_provider) do
        local row = string.format(
          "  %s / %s — %s in / %s out",
          kdim(p.provider or "unknown"),
          kvalue(p.model or "unknown"),
          tokens(p.prompt_tokens),
          tokens(p.completion_tokens)
        )
        if (p.cached_tokens or 0) > 0 then
          local p_sent = p.prompt_tokens or 0
          local p_rate = p_sent > 0 and (p.cached_tokens * 100 / p_sent) or 0
          row = row .. " / " .. tokens(p.cached_tokens)
            .. " cached (" .. string.format("%.1f%%", p_rate) .. ")"
        end
        local provider_cost = money(p.cost)
        if provider_cost then
          row = row .. " / " .. kvalue(provider_cost)
        end
        table.insert(lines, row)
      end
    end

    return { display = table.concat(lines, "\n"), submit = false }
  end,
})
