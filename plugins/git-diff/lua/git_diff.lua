-- Unified Git patch parsing; no Git commands or UI state here. Rows are a
-- diff element's: { sign, text, old, new } for the patch, { text, tone }
-- for Git's own lines.
local M = {}

function M.parse(patch)
  local rows, old, new = {}, nil, nil
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    local a, b = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    local row = { text = line, tone = "dim" }
    if line:match("^diff %-%-git ") then
      old, new = nil, nil
      row.tone = "accent"
    elseif a then
      old, new = tonumber(a), tonumber(b)
    elseif old and line:sub(1, 1) == "+" then
      row = { text = line:sub(2), sign = "+", new = new }
      new = new + 1
    elseif old and line:sub(1, 1) == "-" then
      row = { text = line:sub(2), sign = "-", old = old }
      old = old + 1
    elseif old and line:sub(1, 1) == " " then
      row = { text = line:sub(2), sign = " ", old = old, new = new }
      old, new = old + 1, new + 1
    end
    rows[#rows + 1] = row
  end
  if patch:sub(-1) == "\n" or patch == "" then rows[#rows] = nil end
  return rows
end

return M
