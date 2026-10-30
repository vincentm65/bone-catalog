local M = {
  summaries = {},
  expanded = {},
  pending = {},
}

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function session_key(item)
  local session = bone.chat.session()
  return (session and session.session_id or "new") .. ":" .. tostring(item.key or item.index)
end

-- Keep the model's answer to a maximum of three logical summary lines. Empty
-- lines are omitted so the summary always has at least one line when text is
-- available.
function M.normalize(text)
  local out = {}
  for line in (trim(text) .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      out[#out + 1] = line
      if #out == 3 then break end
    end
  end
  return table.concat(out, "\n")
end

function M.fallback(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      out[#out + 1] = line
      if #out == 3 then break end
    end
  end
  return M.normalize(table.concat(out, "\n"))
end

function M.key(item)
  return session_key(item)
end

function M.get(item)
  local key = session_key(item)
  if not M.summaries[key] or M.summaries[key] == "" then
    M.summaries[key] = M.fallback(item.text)
  end
  return M.summaries[key]
end

function M.set(item, text)
  local value = M.normalize(text)
  if value ~= "" then
    M.summaries[session_key(item)] = value
  end
end

function M.is_expanded(item)
  return M.expanded[session_key(item)] == true
end

function M.toggle(item)
  local key = session_key(item)
  M.expanded[key] = not M.expanded[key]
end

return M
