-- A light syntax colorer for the editor: one line at a time, no state
-- carried between lines. Comments, strings, numbers, keywords and type-like
-- names in the common languages, and headings, code and quotes in
-- Markdown. Colors are the plugin's own groups, linked under the
-- colorscheme (`default`), so a scheme can give them a look of its own.

local M = {}

bone.hl.set("FilesKeyword", { link = "ShellFlag", default = true })
bone.hl.set("FilesString", { link = "ShellString", default = true })
bone.hl.set("FilesNumber", { link = "WarningMsg", default = true })
bone.hl.set("FilesComment", { link = "ShellComment", default = true })
bone.hl.set("FilesType", { link = "ShellPath", default = true })
bone.hl.set("FilesHeading", { link = "MdHeading", default = true })
bone.hl.set("FilesCode", { link = "MdCode", default = true })
bone.hl.set("FilesQuote", { link = "MdQuote", default = true })

local KEYWORDS = {}
for word in ([[
  and as async await break case catch class const continue def default defer
  del do elif else elseif end enum except export extends false finally fn for
  from func function go goto if impl import in interface is lambda let local
  loop match mod module mut new nil none None not null or package pass pub
  raise return self Self static struct super switch then this throw true True
  False try type typeof use var void where while with yield
]]):gmatch("%S+") do KEYWORDS[word] = true end

-- How a file's comments start, by its extension.
local COMMENT = {}
for ext in ("lua sql hs elm"):gmatch("%S+") do COMMENT[ext] = "--" end
for ext in ("c cc cpp cxx h hpp cs go java js jsx mjs ts tsx kt rs scala swift dart zig php css scss json jsonc proto"):gmatch("%S+") do
  COMMENT[ext] = "//"
end
for ext in ("py sh bash zsh fish rb pl toml yaml yml ini conf cfg nix r mk cmake dockerfile env gitignore"):gmatch("%S+") do
  COMMENT[ext] = "#"
end
local BLOCK = {} -- the languages with /* … */ comments
for ext in ("c cc cpp cxx h hpp cs go java js jsx mjs ts tsx kt rs scala swift dart zig php css scss jsonc proto"):gmatch("%S+") do
  BLOCK[ext] = true
end

--- What file `name` is to the colorer: `{ comment, block, markdown }`, or
--- nil for plain text.
function M.lang(name)
  name = tostring(name or ""):lower()
  local ext = name:match("%.([%w]+)$") or name:match("^%.?([%w]+)$") or ""
  if name == "makefile" then ext = "mk" end
  if ext == "md" or ext == "markdown" or ext == "mdown" or ext == "mkd" then
    return { markdown = true }
  end
  if not COMMENT[ext] then return nil end
  return { comment = COMMENT[ext], block = BLOCK[ext] }
end

-- Markdown: a heading, a fence and a quote color the whole line; inline
-- `code` is colored in a line of prose.
local function markdown(line)
  if line:match("^%s*#+%s") or line:match("^%s*#+$") then return { { 0, #line, "FilesHeading" } } end
  if line:match("^%s*```") or line:match("^%s*~~~") then return { { 0, #line, "FilesComment" } } end
  if line:match("^%s*>") then return { { 0, #line, "FilesQuote" } } end
  local runs, at = {}, 0
  for from, to in function() local s, e = line:find("`[^`]+`", at + 1) return s, e end do
    if from - 1 > at then runs[#runs + 1] = { at, from - 1, "Normal" } end
    runs[#runs + 1] = { from - 1, to, "FilesCode" }
    at = to
  end
  if at < #line then runs[#runs + 1] = { at, #line, "Normal" } end
  return runs
end

--- The runs of `line`: `{ from, to, group }` byte ranges (from 0, `to`
--- exclusive) that cover all of it, in order.
function M.runs(line, lang)
  line = tostring(line or "")
  if line == "" then return {} end
  if not lang then return { { 0, #line, "Normal" } } end
  if lang.markdown then return markdown(line) end
  local runs, n, i, plain = {}, #line, 1, nil
  local function push(from, to, group)
    if to <= from then return end
    local last = runs[#runs]
    if last and last[3] == group and last[2] == from then
      last[2] = to
    else
      runs[#runs + 1] = { from, to, group }
    end
  end
  local comment = lang.comment
  while i <= n do
    local c = line:sub(i, i)
    if comment and line:sub(i, i + #comment - 1) == comment then
      push(i - 1, n, "FilesComment")
      break
    elseif lang.block and line:sub(i, i + 1) == "/*" then
      local close = line:find("*/", i + 2, true)
      local to = close and close + 1 or n
      push(i - 1, to, "FilesComment")
      i = to + 1
    elseif c == '"' or c == "'" or c == "`" then
      local j = i + 1
      while j <= n do
        local d = line:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c then
          break
        else
          j = j + 1
        end
      end
      local to = math.min(j, n)
      push(i - 1, to, "FilesString")
      i = to + 1
    elseif c:match("%d") and not (i > 1 and line:sub(i - 1, i - 1):match("[%w_]")) then
      local to = (line:find("[^%w%._]", i) or (n + 1)) - 1
      push(i - 1, to, "FilesNumber")
      i = to + 1
    elseif c:match("[%a_]") then
      local to = (line:find("[^%w_]", i) or (n + 1)) - 1
      local word = line:sub(i, to)
      local group = "Normal"
      if KEYWORDS[word] then
        group = "FilesKeyword"
      elseif word:match("^%u%l") or word:match("^%u%u?%l") then
        group = "FilesType"
      end
      push(i - 1, to, group)
      i = to + 1
    else
      push(i - 1, i, "Normal")
      i = i + 1
    end
  end
  return runs
end

return M
