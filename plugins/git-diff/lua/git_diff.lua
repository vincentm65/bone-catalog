-- Unified Git patch parsing and rendering; no Git commands or UI state here.
local M = {}

function M.parse(patch)
  local rows, old, new = {}, nil, nil
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    local a, b = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    local row = { text = line, group = "ToolSummary" }
    if line:match("^diff %-%-git ") then
      old, new = nil, nil
      row.group = "ToolPath"
    elseif a then
      old, new = tonumber(a), tonumber(b)
    elseif old and line:sub(1, 1) == "+" then
      row = { text = line:sub(2), sign = "+", new = new, group = "DiffAdd" }
      new = new + 1
    elseif old and line:sub(1, 1) == "-" then
      row = { text = line:sub(2), sign = "-", old = old, group = "DiffDelete" }
      old = old + 1
    elseif old and line:sub(1, 1) == " " then
      row = { text = line:sub(2), sign = " ", old = old, new = new, group = "ToolOutput" }
      old, new = old + 1, new + 1
    end
    rows[#rows + 1] = row
  end
  if patch:sub(-1) == "\n" or patch == "" then rows[#rows] = nil end
  return rows
end

function M.render(rows, width)
  local out = {}
  local digits = 3
  for _, row in ipairs(rows) do
    digits = math.max(digits, #tostring(row.old or row.new or ""))
    if row.new then digits = math.max(digits, #tostring(row.new)) end
  end
  local previous
  for _, row in ipairs(rows) do
    if #out > 0 and ((row.sign == "+" or row.sign == "-")
      and (previous == "+" or previous == "-") and row.sign ~= previous
      or row.text:match("^@@ ")) then
      out[#out + 1] = {}
    end
    local prefix = " "
    if row.sign then
      prefix = string.format("  %" .. digits .. "s  %" .. digits .. "s  %s  ", row.old or "", row.new or "", row.sign)
      -- Keep room for content even on very narrow layouts.
      if width < 24 then prefix = row.sign .. " " end
    end
    local band = (row.sign == "+" or row.sign == "-") and row.group or nil
    local wrapped = bone.text.wrap({ { row.text, row.group } }, width, {
      first = { { prefix, band or "ToolGutter" } },
      rest = { { string.rep(" ", #prefix), band or "ToolGutter" } },
      pad = band,
    })
    for _, line in ipairs(wrapped) do out[#out + 1] = line end
    previous = row.sign
  end
  return out
end

return M
