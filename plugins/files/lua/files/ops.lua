-- What a file manager does to files, several at a time: copy and move into
-- a folder, move to the Trash and put back, extract and compress — each as
-- a batch that reports how far it is, harms nothing that is already there
-- (a name that is taken gets "copy" after it: both are kept), and can be
-- taken back (M.undo). The tree's own small things (a new file, a rename)
-- stay in files.fileops; they are written into the same journal.
--
-- Nothing here draws: the panel asks, and is told.

local P = require("files.platform")
local fileops = require("files.fileops")

local M = {}

--- What copy or cut holds for a paste: { paths = { … }, cut = bool }.
M.clip = nil
--- What can be taken back, the newest last: { label, undo = fn(done) }.
M.journal = {}
M.JOURNAL = 30
--- While a batch runs: { label, at, total, name }.
M.busy = nil
--- Called as a batch moves on, for the panel to draw it.
M.on_change = function() end

local q = P.quoted

local function leaf(path) return (path:gsub("/+$", "")):match("[^/]+$") or path end
local function dir_of(path)
  local d = (path:gsub("/+$", "")):match("^(.*)/[^/]+$")
  if d == "" then return "/" end
  return d or "."
end
local function join(dir, name)
  return (dir:sub(-1) == "/" and dir or dir .. "/") .. name
end
M.leaf, M.dir_of, M.join = leaf, dir_of, join

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return bone.fs.list(path) ~= nil
end
M.exists = exists

--- A place for `name` in `dir` that nothing has: its own name, else "name
--- copy.ext", "name copy 2.ext"… `promised` holds the places this batch has
--- already given out.
function M.free(dir, name, promised)
  local function taken(p) return exists(p) or (promised and promised[p]) end
  local target = join(dir, name)
  if not taken(target) then return target end
  local stem, ext = name:match("^(.+)(%.[^.]+)$")
  if not stem then stem, ext = name, "" end -- no extension, or a dotfile
  for n = 1, 999 do
    local try = join(dir, stem .. (n == 1 and " copy" or (" copy " .. n)) .. ext)
    if not taken(try) then return try end
  end
  return nil
end

local function run(cmd, name, done)
  bone.job.start(cmd, { name = "files: " .. name, timeout = 30 * 60 * 1000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 then return done(true, r.stdout or "") end
      local why = ((r and r.stderr) or ""):gsub("%s+$", "")
      done(false, why ~= "" and why or ("it ended with " .. tostring(r and (r.code or r.state) or "nothing")))
    end })
end

--- `step(item, next)` for each of `items`, one after another, M.busy
--- saying where it is; then `finish()`.
local function batch(label, items, step, finish)
  M.busy = { label = label, at = 0, total = #items }
  local i = 0
  local function next_one()
    i = i + 1
    if i > #items then
      M.busy = nil
      M.on_change()
      return finish()
    end
    M.busy.at, M.busy.name = i, leaf(tostring(items[i]))
    M.on_change()
    step(items[i], next_one)
  end
  next_one()
end

local function remember(label, undo)
  M.journal[#M.journal + 1] = { label = label, undo = undo }
  while #M.journal > M.JOURNAL do table.remove(M.journal, 1) end
end
M.remember = remember

local function count(n, one, many)
  return n .. " " .. (n == 1 and one or (many or (one .. "s")))
end
M.count = count

--- Take back things this made a moment ago (copies, an extracted folder,
--- an archive): to the Trash, and where there is no Trash, deleted — they
--- are what the undo is of, and what they were made from is still there.
local function discard(paths, after)
  M.trash(paths, function(r)
    if #r.no_trash == 0 then return after({ made = r.made, failed = r.failed }) end
    M.delete(r.no_trash, function(d)
      local made, failed = r.made, r.failed
      for _, m in ipairs(d.made) do made[#made + 1] = m end
      for _, f in ipairs(d.failed) do failed[#failed + 1] = f end
      after({ made = made, failed = failed })
    end)
  end, true)
end
M.discard = discard

-- ---- copy and move -------------------------------------------------------------

--- Copy (or with `move`, move) `paths` into the folder `dest`.
--- `done(result)`: { made = { { from, to } }, failed = { { path, why } },
--- skipped = n (already there), renamed = n (a name was taken: both kept) }.
function M.transfer(paths, dest, move, done)
  if M.busy then return done({ made = {}, failed = { { path = "", why = "another operation is still running" } }, skipped = 0, renamed = 0 }) end
  dest = dest:gsub("(.)/+$", "%1")
  local result = { made = {}, failed = {}, skipped = 0, renamed = 0, dest = dest, move = move }
  local promised = {}
  batch(move and "Moving" or "Copying", paths, function(path, next_one)
    path = path:gsub("(.)/+$", "%1")
    if dest == path or dest:sub(1, #path + 1) == path .. "/" then
      result.failed[#result.failed + 1] = { path = path, why = "a folder cannot go into itself" }
      return next_one()
    end
    if move and dir_of(path) == dest then
      result.skipped = result.skipped + 1
      return next_one()
    end
    if not exists(path) then
      result.failed[#result.failed + 1] = { path = path, why = "it is no longer there" }
      return next_one()
    end
    local target = M.free(dest, leaf(path), promised)
    if not target then
      result.failed[#result.failed + 1] = { path = path, why = "too many copies of that name already" }
      return next_one()
    end
    promised[target] = true
    if leaf(target) ~= leaf(path) then result.renamed = result.renamed + 1 end
    run((move and "mv -- " or "cp -a -- ") .. q(path) .. " " .. q(target), move and "move" or "copy", function(ok, why)
      if ok then result.made[#result.made + 1] = { from = path, to = target }
      else result.failed[#result.failed + 1] = { path = path, why = why } end
      next_one()
    end)
  end, function()
    local made = result.made
    if #made > 0 then
      if move then
        remember("Moved " .. count(#made, "item") .. " to " .. leaf(dest), function(after)
          -- Each one back where it was (beside whatever took its place since).
          local back = { made = {}, failed = {} }
          batch("Moving back", made, function(m, next_one)
            local home = M.free(dir_of(m.from), leaf(m.from))
            if not home or not exists(m.to) then
              back.failed[#back.failed + 1] = { path = m.to, why = "it is no longer there" }
              return next_one()
            end
            run("mv -- " .. q(m.to) .. " " .. q(home), "move back", function(ok, why)
              if ok then back.made[#back.made + 1] = { from = m.to, to = home }
              else back.failed[#back.failed + 1] = { path = m.to, why = why } end
              next_one()
            end)
          end, function() after(back) end)
        end)
      else
        remember("Copied " .. count(#made, "item") .. " to " .. leaf(dest), function(after)
          -- The copies go to the Trash: nothing is deleted to take a copy back.
          local copies = {}
          for _, m in ipairs(made) do copies[#copies + 1] = m.to end
          discard(copies, after)
        end)
      end
    end
    done(result)
  end)
end

-- ---- the Trash --------------------------------------------------------------------

--- Whether the desktop's Trash can be listed and put back from (gio).
function M.can_restore()
  if M.gio == nil then
    local p = io.popen("command -v gio 2>/dev/null")
    local out = p and p:read("*l") or ""
    if p then p:close() end
    M.gio = out ~= ""
  end
  return M.gio
end

--- The Trash's entries for `originals` (the paths things were at): for
--- each, the newest one that came from there. `done({ [path] = uri })`.
local function trash_uris(originals, done)
  if not M.can_restore() then return done({}) end
  run("gio trash --list", "trash list", function(ok, out)
    local found = {}
    if ok then
      local want = {}
      for _, p in ipairs(originals) do want[p] = true end
      for line in out:gmatch("[^\n]+") do
        local uri, path = line:match("^(%S+)\t(.+)$")
        -- Later lines are later entries: the last one from a place wins.
        if uri and want[path] then found[path] = uri end
      end
    end
    done(found)
  end)
end

--- `paths` to the Trash. `done(result)`: { made = { { from } }, failed,
--- no_trash = { path… } (places with no Trash: only deleting is left, and
--- that is asked first) }. `quiet`: not written in the journal.
function M.trash(paths, done, quiet)
  if M.busy then return done({ made = {}, failed = { { path = "", why = "another operation is still running" } }, no_trash = {} }) end
  local result = { made = {}, failed = {}, no_trash = {} }
  batch("Moving to the Trash", paths, function(path, next_one)
    fileops.trash(path, function(ok, why)
      if ok then result.made[#result.made + 1] = { from = path }
      elseif fileops.no_trash(why) then result.no_trash[#result.no_trash + 1] = path
      else result.failed[#result.failed + 1] = { path = path, why = why } end
      next_one()
    end)
  end, function()
    if #result.made > 0 and not quiet and M.can_restore() then
      local gone = {}
      for _, m in ipairs(result.made) do gone[#gone + 1] = m.from end
      remember("Moved " .. count(#gone, "item") .. " to the Trash", function(after)
        trash_uris(gone, function(uris)
          local back = { made = {}, failed = {} }
          batch("Putting back", gone, function(path, next_one)
            local uri = uris[path]
            if not uri then
              back.failed[#back.failed + 1] = { path = path, why = "it is not in the Trash any more" }
              return next_one()
            end
            run("gio trash --restore " .. q(uri), "put back", function(ok, why)
              if ok then back.made[#back.made + 1] = { to = path }
              else back.failed[#back.failed + 1] = { path = path, why = why } end
              next_one()
            end)
          end, function() after(back) end)
        end)
      end)
    end
    done(result)
  end)
end

--- Delete `paths` for good. Only after the panel asked.
function M.delete(paths, done)
  local result = { made = {}, failed = {} }
  batch("Deleting", paths, function(path, next_one)
    fileops.delete(path, function(ok, why)
      if ok then result.made[#result.made + 1] = { from = path }
      else result.failed[#result.failed + 1] = { path = path, why = tostring(why) } end
      next_one()
    end)
  end, function() done(result) end)
end

--- Where the desktop keeps what was thrown away from the home folder.
function M.trash_dir()
  local data = os.getenv("XDG_DATA_HOME")
  if not data or data == "" then data = P.home() .. "/.local/share" end
  return data .. "/Trash/files"
end

--- Is `path` something lying in the Trash?
function M.in_trash(path)
  local dir = M.trash_dir()
  return path:sub(1, #dir + 1) == dir .. "/" and not path:sub(#dir + 2):find("/", 1, true)
end

--- Put what lies in the Trash at `paths` back where it came from.
--- `done(result)`: made = { { to } }, failed.
function M.put_back(paths, done)
  local result = { made = {}, failed = {} }
  if not M.can_restore() then
    for _, p in ipairs(paths) do result.failed[#result.failed + 1] = { path = p, why = "gio is needed to put things back" } end
    return done(result)
  end
  run("gio trash --list", "trash list", function(ok, out)
    local from = {}
    if ok then
      for line in out:gmatch("[^\n]+") do
        local uri, path = line:match("^(%S+)\t(.+)$")
        if uri then from[uri] = path end
      end
    end
    batch("Putting back", paths, function(path, next_one)
      local uri = "trash:///" .. leaf(path):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
      if not from[uri] then
        result.failed[#result.failed + 1] = { path = path, why = "the Trash does not say where it came from" }
        return next_one()
      end
      run("gio trash --restore " .. q(uri), "put back", function(done_ok, why)
        if done_ok then result.made[#result.made + 1] = { to = from[uri] }
        else result.failed[#result.failed + 1] = { path = path, why = why } end
        next_one()
      end)
    end, function() done(result) end)
  end)
end

--- Empty the Trash, for good. Only after the panel asked.
function M.empty_trash(done)
  run("gio trash --empty", "empty trash", function(ok, why) done(ok, why) end)
end

-- ---- archives ---------------------------------------------------------------------

local ARCHIVE = { ".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".7z", ".rar",
  ".jar", ".gz", ".xz", ".bz2", ".zst" }

--- The archive's name without what makes it one ("a.tar.gz" → "a"), or nil
--- when `name` is not an archive this can open.
function M.archive_stem(name)
  local lower = name:lower()
  local best
  for _, ext in ipairs(ARCHIVE) do
    if #lower > #ext and lower:sub(-#ext) == ext and (not best or #ext > #best) then best = ext end
  end
  if not best then return nil end
  return name:sub(1, #name - #best), best
end

--- Extract `archive` beside itself, into a folder of its own name (so an
--- archive with a hundred loose files makes one folder, not a hundred
--- files). `done(folder)`, or `done(nil, why)`.
function M.extract(archive, done)
  local stem, ext = M.archive_stem(leaf(archive))
  if not stem then return done(nil, "that is not an archive this can open") end
  local target = M.free(dir_of(archive), stem)
  if not target then return done(nil, "no name is free for its folder") end
  M.busy = { label = "Extracting", at = 1, total = 1, name = leaf(archive) }
  M.on_change()
  local cmd
  if ext == ".gz" or ext == ".xz" or ext == ".bz2" or ext == ".zst" then
    -- One file squeezed, not a folder of them: the file, beside it.
    local tool = ({ [".gz"] = "gzip", [".xz"] = "xz", [".bz2"] = "bzip2", [".zst"] = "zstd" })[ext]
    cmd = tool .. " -dc -- " .. q(archive) .. " > " .. q(target)
  else
    cmd = "mkdir -p -- " .. q(target) .. " && { bsdtar -xf " .. q(archive) .. " -C " .. q(target)
      .. " || { rmdir -- " .. q(target) .. " 2>/dev/null; exit 1; }; }"
  end
  run(cmd, "extract", function(ok, why)
    M.busy = nil
    M.on_change()
    if not ok then return done(nil, why) end
    remember("Extracted " .. leaf(archive), function(after) discard({ target }, after) end)
    done(target)
  end)
end

--- `paths` (all in one folder) into a .zip beside them: named after the
--- one thing, or "Archive.zip". `done(zip)`, or `done(nil, why)`.
function M.compress(paths, done)
  if #paths == 0 then return done(nil, "nothing was chosen") end
  local dir = dir_of(paths[1])
  local names = {}
  for _, p in ipairs(paths) do
    if dir_of(p) ~= dir then return done(nil, "the things to compress are in different folders") end
    names[#names + 1] = q(leaf(p))
  end
  local target = M.free(dir, (#paths == 1 and leaf(paths[1]) or "Archive") .. ".zip")
  if not target then return done(nil, "no name is free for the archive") end
  M.busy = { label = "Compressing", at = 1, total = 1, name = leaf(target) }
  M.on_change()
  run("cd " .. q(dir) .. " && bsdtar -a -cf " .. q(target) .. " -- " .. table.concat(names, " "), "compress", function(ok, why)
    M.busy = nil
    M.on_change()
    if not ok then
      os.remove(target)
      return done(nil, why)
    end
    remember("Compressed to " .. leaf(target), function(after) discard({ target }, after) end)
    done(target)
  end)
end

-- ---- taking it back ---------------------------------------------------------------

--- Take the last thing back. `done(label, result)`, or `done(nil)` when
--- there is nothing (or something is still running).
function M.undo(done)
  if M.busy then return done(nil, "another operation is still running") end
  local last = table.remove(M.journal)
  if not last then return done(nil, "nothing to take back") end
  last.undo(function(result) done(last.label, result or { made = {}, failed = {} }) end)
end

return M
