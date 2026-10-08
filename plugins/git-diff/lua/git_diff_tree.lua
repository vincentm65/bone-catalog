-- Small changed-file tree built from the patch already in memory.
local M = {}
local function unquote(path)
  if path:sub(1, 1) ~= '"' then return path end
  return (path:sub(2, -2):gsub('\\(%d%d%d)', function(n) return string.char(tonumber(n, 8)) end)
    :gsub('\\(.)', { t = '\t', n = '\n', r = '\r', ['\\'] = '\\', ['"'] = '"' }))
end

function M.files(rows)
  local files, file = {}, nil
  for _, row in ipairs(rows) do
    if not row.sign and row.text:match('^diff %-%-git ') then
      local path = row.text:match(' b/(.*)$') or row.text:match(' ("b/.*")$') or row.text
      file = { path = unquote(path):gsub('^b/', ''), rows = {}, added = 0, deleted = 0 }
      files[#files + 1] = file
    end
    if file then
      local path = row.text:match('^%+%+%+ (.*)$')
      if not row.sign and path and path ~= '/dev/null' then file.path = unquote(path):gsub('^b/', '') end
      local renamed = not row.sign and row.text:match('^rename to (.*)$')
      if renamed then file.path = unquote(renamed) end
      file.rows[#file.rows + 1] = row
      if row.sign == '+' then file.added = file.added + 1 end
      if row.sign == '-' then file.deleted = file.deleted + 1 end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

function M.nodes(files, collapsed)
  local root, out = { children = {} }, {}
  for _, file in ipairs(files) do
    local node, path = root, ''
    local parts = {}
    for part in file.path:gmatch('[^/]+') do parts[#parts + 1] = part end
    for i, part in ipairs(parts) do
      path = path == '' and part or path .. '/' .. part
      node.children[part] = node.children[part] or { name = part, path = path, children = {} }
      node = node.children[part]
      if i == #parts then node.file = file end
    end
  end
  local function visit(parent, depth)
    local children = {}
    for _, child in pairs(parent.children) do children[#children + 1] = child end
    table.sort(children, function(a, b)
      if not a.file ~= not b.file then return not a.file end
      return a.name < b.name
    end)
    for _, node in ipairs(children) do
      node.depth = depth
      out[#out + 1] = node
      if not node.file and not collapsed[node.path] then visit(node, depth + 1) end
    end
  end
  visit(root, 0)
  return out
end
return M
