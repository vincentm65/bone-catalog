-- What the tree can do to files: make a file or a folder, rename, duplicate,
-- and move to the Trash (the desktop's own, through gio or trash-cli, so a
-- mistake is undone where you would look for it). Nothing here deletes.

local M = {}

local function quoted(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end

function M.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  -- A folder does not open for reading everywhere; its listing does.
  return bone.fs.list(path) ~= nil
end

--- Is `name` one a file can have here: not empty, no slash, not . or ..
function M.bad_name(name)
  name = tostring(name or "")
  if name:match("^%s*$") then return "A name is needed." end
  if name == "." or name == ".." then return "That name is taken by the folder itself." end
  if name:find("\0", 1, true) then return "A name cannot hold that character." end
  return nil
end

--- `dir/name`, made empty. `name` may hold slashes: the folders on the way
--- are made too.
function M.new_file(dir, name)
  local why = M.bad_name(name)
  if why then return nil, why end
  local path = dir:gsub("/$", "") .. "/" .. name:gsub("^/+", "")
  if M.exists(path) then return nil, "There is already something called " .. name .. " there." end
  local up = path:match("^(.*)/[^/]+$")
  if up and up ~= "" and not M.exists(up) then
    local ok, err = bone.fs.mkdir(up)
    if not ok and not M.exists(up) then return nil, tostring(err or "The folder could not be made.") end
  end
  local f, err = io.open(path, "wb")
  if not f then return nil, tostring(err) end
  f:close()
  return path
end

function M.new_folder(dir, name)
  local why = M.bad_name(name)
  if why then return nil, why end
  local path = dir:gsub("/$", "") .. "/" .. name:gsub("^/+", ""):gsub("/+$", "")
  if M.exists(path) then return nil, "There is already something called " .. name .. " there." end
  local ok, err = bone.fs.mkdir(path)
  if not ok and not M.exists(path) then return nil, tostring(err or "The folder could not be made.") end
  return path
end

--- Rename `path` to `name` in the same folder.
function M.rename(path, name)
  local why = M.bad_name(name)
  if why then return nil, why end
  if name:find("/", 1, true) then return nil, "A name cannot hold a slash: that would move it." end
  local dir = path:match("^(.*)/[^/]+$") or ""
  local target = (dir == "" and "" or dir) .. "/" .. name
  if target == path then return path end
  -- A change of case alone is a rename on a case-insensitive disk.
  if M.exists(target) and target:lower() ~= path:lower() then
    return nil, "There is already something called " .. name .. " there."
  end
  local ok, err = os.rename(path, target)
  if not ok then return nil, tostring(err) end
  return target
end

--- The name a copy of `path` gets: "name copy.ext", then "name copy 2.ext".
function M.copy_name(path)
  local dir, leaf = path:match("^(.*)/([^/]+)$")
  local stem, ext = leaf:match("^(.+)(%.[^.]+)$")
  if not stem then stem, ext = leaf, "" end -- no extension, or a dotfile
  for n = 1, 99 do
    local name = stem .. (n == 1 and " copy" or (" copy " .. n)) .. ext
    local target = dir .. "/" .. name
    if not M.exists(target) then return target end
  end
  return nil
end

--- A copy of `path` (a file or a whole folder) beside it: `done(target)`, or
--- `done(nil, why)`.
function M.duplicate(path, done)
  local target = M.copy_name(path)
  if not target then return done(nil, "Too many copies already.") end
  bone.job.start("cp -a -- " .. quoted(path) .. " " .. quoted(target), {
    name = "files: duplicate", timeout = 60000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 then done(target) else done(nil, (r and r.stderr) or "The copy failed.") end
    end })
end

--- `path` into the Trash: `done(true)`, or `done(nil, why)`.
function M.trash(path, done)
  local p = quoted(path)
  -- macOS: its own trash command (from 14), else the Finder.
  if (jit and jit.os) == "OSX" then
    bone.job.start("if [ -x /usr/bin/trash ]; then /usr/bin/trash " .. p .. "; else "
      .. "osascript -e 'on run argv' -e 'tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)' "
      .. "-e 'end run' " .. p .. " >/dev/null; fi", { name = "files: trash", timeout = 30000, buffer = true,
      on_exit = function(r)
        if r and r.code == 0 then done(true) else done(nil, ((r and r.stderr) or "It could not be moved to the Trash."):gsub("%s+$", "")) end
      end })
    return
  end
  bone.job.start("if command -v gio >/dev/null 2>&1; then gio trash -- " .. p .. "; "
    .. "elif command -v trash-put >/dev/null 2>&1; then trash-put -- " .. p .. "; "
    .. "elif command -v kioclient5 >/dev/null 2>&1; then kioclient5 move " .. p .. " trash:/; "
    .. "else echo 'There is no Trash tool here (gio or trash-cli).' >&2; exit 3; fi", {
    name = "files: trash", timeout = 30000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 then done(true) else
        done(nil, ((r and r.stderr) or ""):gsub("%s+$", "") ~= "" and (r.stderr:gsub("%s+$", "")) or "It could not be moved to the Trash.")
      end
    end })
end

--- Whether `why` (from trash) says there is no Trash for that place, so
--- only a permanent delete is left.
function M.no_trash(why)
  why = tostring(why or ""):lower()
  return why:find("not supported", 1, true) ~= nil or why:find("no trash", 1, true) ~= nil
    or why:find("unable to find or create trash", 1, true) ~= nil or why:find("trash tool", 1, true) ~= nil
end

--- Delete `path` for good (a folder with everything in it). Only after you
--- said so: the panel asks first.
function M.delete(path, done)
  local P = require("files.platform")
  if path == "" or P.is_root(P.norm(path)) or P.norm(path) == P.home() then return done(nil, "That is not something to delete.") end
  bone.job.start("rm -rf -- " .. quoted(path), { name = "files: delete", timeout = 60000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 then done(true) else done(nil, (r and r.stderr) or "It could not be deleted.") end
    end })
end

return M
