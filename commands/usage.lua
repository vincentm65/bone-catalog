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

local function tokens(n)
  return comma(n)
end

local function money(n)
  n = tonumber(n) or 0
  if n <= 0 then return nil end
  return string.format("$%.4f", n)
end

local DIM   = "\x1b[2m"
local CYAN  = "\x1b[36m"
local WHITE = "\x1b[37m"
local RESET = "\x1b[0m"

local function header(title)
  return string.format("%s%s%s", CYAN, title, RESET)
end

local function section(title)
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

local MEMORY_MAX_CHARS = 2000
local CHARS_PER_TOKEN = 3.8

local function estimate_tokens(chars)
  return math.ceil(chars / CHARS_PER_TOKEN)
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate_utf8(s, max_bytes)
  if #s <= max_bytes then return s end
  local suffix = "..."
  local limit = math.max(0, max_bytes - #suffix)
  for cut = limit, math.max(limit - 4, 1), -1 do
    local chunk = s:sub(1, cut)
    local ok, len = pcall(utf8.len, chunk)
    if ok and len then return chunk .. suffix end
  end
  return suffix
end

local function project_key(cwd)
  local key = (cwd or "unknown"):gsub("[^%w%._%-]", "_")
  if #key > 96 then key = key:sub(#key - 95) end
  return key ~= "" and key or "unknown"
end

local function memory_overhead(ctx)
  if not ctx.config_dir or not ctx.fs or not ctx.fs.is_file then return nil end

  local root = ctx.config_dir .. "/memory"
  local global_path = root .. "/global.md"
  local global_label = "memory/global.md"
  if not ctx.fs.is_file(global_path) then
    global_path = ctx.config_dir .. "/memory.md"
    global_label = "memory.md"
  end
  local key = project_key(ctx.cwd or bone.cwd)
  local project_path = root .. "/projects/" .. key .. ".md"

  local function read(path)
    if not ctx.fs.is_file(path) then return nil end
    local ok, content = pcall(ctx.read_file, path)
    content = ok and trim(content) or ""
    return content ~= "" and truncate_utf8(content, MEMORY_MAX_CHARS) or nil
  end

  local global = read(global_path)
  local project = read(project_path)
  local sections, files = {}, {}
  if global then
    sections[#sections + 1] = "## Global\n" .. global
    files[#files + 1] = { scope = "Global", path = global_label, chars = #global }
  end
  if project then
    sections[#sections + 1] = "## Current project\n" .. project
    files[#files + 1] = {
      scope = "Project",
      path = "memory/projects/" .. key .. ".md",
      chars = #project,
    }
  end
  if #sections == 0 then return nil end

  local prompt = "# User Memory\nThe following scoped preferences were extracted from past conversations:\n\n"
    .. table.concat(sections, "\n\n")
  return { chars = #prompt, tokens = estimate_tokens(#prompt), files = files }
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
      header("Conversation usage"),
      sep(),
      klabel("Requests") .. kvalue(comma(usage.request_count)),
      klabel("Tokens")   .. kvalue(tokens(total) .. " total"),
      klabel("Input")    .. kvalue(tokens(usage.sent)),
      klabel("Output")   .. kvalue(tokens(usage.received)),
      klabel("Context")  .. kvalue(tokens(usage.context_length) .. " current"),
    }

    if (usage.cached or 0) > 0 then
      table.insert(lines, klabel("Cached") .. kvalue(tokens(usage.cached)))
    end
    local cost = money(usage.cost)
    if cost then
      table.insert(lines, klabel("Cost") .. kvalue(cost))
    end
    if (usage.request_count or 0) > 0 then
      table.insert(lines, klabel("Avg/req") .. kvalue(tokens((usage.sent or 0) / usage.request_count) .. " in / " .. tokens((usage.received or 0) / usage.request_count) .. " out"))
    end

    table.insert(lines, "")
    table.insert(lines, section("Prompt overhead"))
    table.insert(lines, sep())
    table.insert(lines, klabel("Tools")
      .. kvalue(comma(usage.tool_count) .. " tools · ~" .. tokens(usage.tool_schema_tokens) .. " tokens"))
    table.insert(lines, klabel("System")
      .. kvalue("~" .. tokens(usage.system_prompt_tokens) .. " tokens"))

    local memory = memory_overhead(ctx)
    if memory then
      table.insert(lines, klabel("Memory total")
        .. kvalue("~" .. tokens(memory.tokens) .. " tokens"))
      local file_tokens = 0
      for _, file in ipairs(memory.files) do
        local estimated = estimate_tokens(file.chars)
        file_tokens = file_tokens + estimated
        table.insert(lines, klabel("  " .. file.scope)
          .. kvalue("~" .. tokens(estimated) .. " tokens")
          .. kdim(" · " .. file.path))
      end
      table.insert(lines, klabel("  Framing")
        .. kvalue("~" .. tokens(math.max(0, memory.tokens - file_tokens)) .. " tokens"))
    end
    local overhead_tokens = (usage.tool_schema_tokens or 0)
      + (usage.system_prompt_tokens or 0)
      + (memory and memory.tokens or 0)
    table.insert(lines, klabel("Prompt total") .. kvalue("~" .. tokens(overhead_tokens) .. " tokens"))

    if usage.by_provider and #usage.by_provider > 1 then
      table.insert(lines, "")
      table.insert(lines, section("By provider/model"))
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
          row = row .. " / " .. tokens(p.cached_tokens) .. " cached"
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
