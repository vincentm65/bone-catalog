-- Editing in Neovim, Vim or another editor of your own, in a terminal (the
-- desktop app keeps the built-in editor): the program runs in the term
-- plugin's terminal panel beside the files panel, at the line asked for. A
-- second file goes to the same Neovim or Vim (`:hide e`); when the program
-- ends its panel closes.

local P = require("files.platform")

local M = {}

M.PANEL = "files-editor"

--- The term plugin's terminal module; nil without the term plugin.
function M.terminal()
  local ok, t = pcall(require, "bone.ui.terminal")
  if ok and type(t) == "table" and type(t.open) == "function" then return t end
  return nil
end

local function on_path(name)
  if not name or name == "" then return false end
  local p = io.popen("command -v " .. P.quoted(name) .. " 2>/dev/null")
  local out = p and p:read("*l") or ""
  if p then p:close() end
  return out ~= ""
end

--- The line that runs `kind` (nvim, vim, custom) on `path` at `line`.
function M.command(kind, custom, path, line)
  local q = P.quoted(path)
  line = tonumber(line)
  if kind == "nvim" or kind == "vim" then
    return kind .. (line and (" +" .. line) or "") .. " " .. q
  end
  custom = tostring(custom or "")
  local cmd = custom:gsub("{line}", tostring(line or 1))
  if cmd:find("{file}", 1, true) then
    cmd = cmd:gsub("{file}", (q:gsub("%%", "%%%%")))
  else
    cmd = cmd .. " " .. q
  end
  return cmd
end

--- The program a kind runs, to look for on the PATH.
function M.program(kind, custom)
  if kind == "nvim" or kind == "vim" then return kind end
  return tostring(custom or ""):match("^%s*(%S+)")
end

--- What a path is to :e (spaces and the like escaped).
local function vim_path(path)
  return (path:gsub("([ %%#|\\\"'])", "\\%1"))
end

--- Whether the editor's panel is open with its program running.
function M.running()
  local term = M.terminal()
  local job = term and term.job and term.job(M.PANEL)
  return job ~= nil and job:running() and bone.ui.panel.get(M.PANEL) ~= nil
end

--- Open `path` at `line` in the editor. `tree_left`: the editor's panel takes
--- the window's edge, the files panel (the tree) to its left; else the tree
--- keeps the edge. `done()` runs once the program has ended (its panel
--- closed). Returns true, or nil and why it could not.
function M.open(kind, custom, path, line, tree_left, done)
  local term = M.terminal()
  if not term then
    return nil, "there is no terminal here to run it in (in a terminal, the term plugin gives one)"
  end
  local program = M.program(kind, custom)
  if not on_path(program) then return nil, tostring(program or "the editor") .. " is not on the PATH" end
  -- The same Neovim or Vim takes the next file.
  if (kind == "nvim" or kind == "vim") and M.running() then
    local job = term.job(M.PANEL)
    job:write("\27:hide e " .. vim_path(path) .. "\r")
    if tonumber(line) then job:write(":" .. tonumber(line) .. "\r") end
    local handle = bone.ui.panel.get(M.PANEL)
    if handle and handle.update then
      pcall(handle.update, handle, { title = kind .. " · " .. (path:match("[^/]+$") or path) })
    end
    pcall(bone.ui.panel.focus, M.PANEL)
    return true
  end
  if bone.ui.panel.get(M.PANEL) then pcall(bone.ui.panel.close, M.PANEL) end
  local dir = path:match("^(.*)/[^/]+$") or "."
  local name = path:match("[^/]+$") or path
  local ok, opened = pcall(term.open, {
    -- The files panel spans the window's height at its edge (order 0). To
    -- stand at the edge with the tree on its left, the editor spans it too,
    -- with a lower order (the lower one is nearer the edge); else it sits
    -- inside, beside the chat.
    id = M.PANEL, dock = "right", size = 0.45, focus = true,
    order = tree_left and -1 or 1, full_height = tree_left and true or nil,
    title = (program or "editor") .. " · " .. name,
  }, { cmd = M.command(kind, custom, path, line), cwd = dir })
  if not ok then return nil, tostring(opened) end
  -- A terminal module that is not set up opens nothing.
  if not opened or not bone.ui.panel.get(M.PANEL) then return nil, "the terminal did not open" end
  -- The terminal keeps a finished program's last screen: once the program
  -- has ended, its panel goes, and the files panel hears of it.
  local function watch()
    local job = term.job and term.job(M.PANEL)
    if job and job:running() and bone.ui.panel.get(M.PANEL) then
      bone.defer(500, watch)
      return
    end
    if bone.ui.panel.get(M.PANEL) then pcall(bone.ui.panel.close, M.PANEL) end
    if done then done() end
  end
  bone.defer(800, watch)
  return true
end

return M
